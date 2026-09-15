#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/manifest"

# WorktreeCreate replaces /new-worktree Steps 1-4 (Guard, create the worktree
# and branch, trust it with mise, warm the build caches, verify green) - see
# statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 4. Step 5 (the
# tmux window) is a separate script (Phase 5), invoked by the SKILL.md only
# after this script reports success.
#
# Never force: a pre-existing branch or worktree directory is `blocked` with
# needs: "human" - see the wurk:branch SKILL.md's create-and-warm step. This
# script has no path that deletes a branch or a directory to make room for a
# new one. The single exception is ADOPTION (wu-mya.3), and it is narrow
# because it loosens that safety default: see #adopt_refusal_reason.
#
# The one branch this script ever moves is the local default branch, and
# only forward: the base preflight (#preflight, parallelism.preflight)
# fast-forwards a local default that is strictly behind the remote and
# refuses one that has commits of its own.
module WorktreeCreate
  class << self
    def run(argv, io: $stdout)
      parser, options = Cli.build("worktree_create.rb [options] <name>") do |opts|
        opts.on("--base REF", "cut the branch from REF instead of the default branch (stacked work: the parent branch)") do |v|
          options[:base] = v
        end
      end
      args = Cli.parse!(parser, argv)
      name = args.first
      usage_error!("worktree_create.rb [options] <name>", parser) if name.to_s.strip.empty?

      env = Envelope.new(script: "worktree_create")
      dry_run = options[:dry_run]

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest

      # This whole script is the `worktree-per-issue` half of wurk:branch.
      # Under `branch-in-place` there is no worktree to create, and saying so
      # is better than half-working: a project that switched models would
      # otherwise get a stray sibling directory nothing else knows about.
      unless manifest.parallelism_model == "worktree-per-issue"
        env.block!(
          code: "wrong_parallelism_model",
          message: "parallelism.model is #{manifest.parallelism_model.inspect}; worktree_create.rb only implements worktree-per-issue"
        )
        return env.emit(io)
      end

      # worktrees_dir is optional in the schema because branch-in-place has no
      # use for it, which makes it required-in-practice here: without it the
      # expand_path below would resolve to the repo root itself and the new
      # worktree would land inside the checkout it was branched from.
      unless manifest.worktrees_dir
        env.block!(
          code: "missing_worktrees_dir",
          message: "parallelism.worktrees_dir is not set in #{manifest.path}; worktree-per-issue needs somewhere to put the worktree"
        )
        return env.emit(io)
      end

      root = main_checkout_root(env)
      unless root
        env.block!(code: "not_main_checkout", message: "worktree_create.rb must be run from the main checkout, not a worktree")
        return env.emit(io)
      end

      # worktrees_dir is relative to the repo root, so "../foo-worktrees"
      # lands beside the checkout - the layout every consumer repo uses -
      # while still allowing an absolute path.
      worktrees_root = File.expand_path(manifest.worktrees_dir, root)
      path = File.join(worktrees_root, name)

      # --- Guard ----------------------------------------------------------

      adopt = false

      if branch_exists?(env, root: root, name: name)
        # The branch is already there. Adoption is the one way past this, and
        # only when there is nothing left to decide - see
        # #adopt_refusal_reason for the conditions and why each mismatch is
        # still a human's call.
        reason = adopt_refusal_reason(env, root: root, path: path, name: name)
        if reason
          env.block!(code: "branch_exists", message: "branch #{name} already exists; #{reason}", needs: "human")
          return env.emit(io)
        end
        adopt = true
      elsif Dir.exist?(path)
        # A directory with no branch of this name is a stray sibling: there is
        # no workspace here to adopt, only a name collision.
        env.block!(code: "worktree_dir_exists", message: "#{path} already exists", needs: "human")
        return env.emit(io)
      end

      if adopt
        # Nothing is cut on the adopt path, so the whole base-ref ladder is
        # moot: no fetch, no default-branch fallback, and base_ref stays nil
        # rather than naming a ref this run never used. An explicit --base
        # cannot be honored either, and saying so beats both silence and
        # pretending the existing branch was cut from it.
        if options[:base]
          env.warn(
            code: "base_ignored_on_adopt",
            message: "--base #{options[:base]} does not apply: #{name} already exists and is being adopted, not cut"
          )
        end

        env.data[:name] = name
        env.data[:path] = path
        env.data[:base_ref] = nil
        env.data[:action] = "adopted"
        env.data[:dry_run] = dry_run

        if dry_run
          record_dry_run_steps(env, manifest, root: root, path: path, worktrees_root: worktrees_root,
                                base_ref: nil, name: name, adopt: true)
          return env.emit(io)
        end

        return create_and_warm(env, io, manifest, root: root, path: path, worktrees_root: worktrees_root,
                                base_ref: nil, name: name, adopt: true)
      end

      # An explicit --base wins over the default-branch ladder: stacked work
      # cuts each branch from its parent, not from main (wu-gt5). The ref is
      # verified after the fetch so a remote parent pushed from another
      # machine still resolves; a ref that resolves nowhere blocks before
      # any mutation, since a typo'd parent silently cut from the wrong
      # base is exactly the stacking defect this flag exists to prevent.
      explicit_base = options[:base]
      base_ref = explicit_base || manifest.remote_default_branch
      fetch_res = Sh.run(%w[git fetch origin], chdir: root, envelope: env)
      unless fetch_res.success?
        if explicit_base
          env.warn(
            code: "fetch_failed",
            message: "git fetch origin failed (offline?); cutting #{name} from #{explicit_base} as known locally"
          )
        else
          base_ref = manifest.default_branch
          env.warn(
            code: "fetch_failed",
            message: "git fetch origin failed (offline?); cutting #{name} from local " \
                     "#{manifest.default_branch} instead of #{manifest.remote_default_branch}"
          )
        end
      end

      if explicit_base
        verify_res = Sh.run(["git", "rev-parse", "--verify", "--quiet", "#{explicit_base}^{commit}"], chdir: root, envelope: env)
        unless verify_res.success?
          env.block!(code: "base_ref_not_found", message: "--base #{explicit_base} does not resolve to a commit", needs: "human")
          return env.emit(io)
        end
      end

      # The base preflight runs on every cut, --base included: it is about
      # the local default branch's hygiene, which the next worktree, the
      # next refresh, and every merge-base a human runs by hand all read.
      if manifest.preflight?
        passed = preflight(env, manifest, root: root, dry_run: dry_run, fetched: fetch_res.success?)
        return env.emit(io) unless passed
      else
        env.data[:preflight] = { "status" => "disabled" }
      end

      env.data[:name] = name
      env.data[:path] = path
      env.data[:base_ref] = base_ref
      env.data[:action] = "created"
      env.data[:dry_run] = dry_run

      if dry_run
        record_dry_run_steps(env, manifest, root: root, path: path, worktrees_root: worktrees_root, base_ref: base_ref, name: name)
        return env.emit(io)
      end

      create_and_warm(env, io, manifest, root: root, path: path, worktrees_root: worktrees_root, base_ref: base_ref, name: name)
    end

    private

    def branch_exists?(env, root:, name:)
      res = Sh.run(["git", "branch", "--list", name], chdir: root, envelope: env)
      res.success? && !res.out.to_s.strip.empty?
    end

    # The base preflight (parallelism.preflight, default true). A measured
    # incident on an upstream harness: worktrees cut from a stale local
    # default branch forked two and three merges behind the remote, one
    # rebuilt a sibling's just-merged work, and an infrastructure plan read
    # newer resources as phantom destroys. This is that harness's preflight
    # in this script's shape:
    #
    # - asserts local default == origin/default by sha, after the fetch above;
    # - self-repairs ONLY a zero-commit stale local default, by fast-forward
    #   (`git merge --ff-only` when the main checkout has it checked out,
    #   `git update-ref` with the old-value guard when nothing does);
    # - refuses when the local default has commits the remote lacks - that
    #   is a merge-forward for a human, never something to reset here - and
    #   when it is checked out in some other worktree, whose tree this script
    #   must not touch.
    #
    # The upstream harness also asserted `merge-base --is-ancestor
    # origin/default HEAD` after creating the worktree. Here that assertion
    # is made BEFORE the cut, on the sha comparison itself: a base that
    # passed it is origin/default or equal to it, so the post-create check
    # would be a tautology on the default-branch cut, and on a --base cut it
    # would refuse every stacked parent that is merely behind main - which
    # /wurk:refresh and /wurk:mr's rebase already handle. Checking before the
    # cut also keeps the never-delete rule intact: a refusal leaves no
    # half-made worktree behind.
    #
    # Returns true when the cut may proceed. On refusal the envelope carries
    # the machine-readable reason twice: `blocked[].code` is preflight_refused
    # and `data.preflight.reason` names which condition (see docs/manifest.md
    # for the vocabulary). Exit code is the contract's 1 (blocked), never 2 -
    # 2 is a usage error with no envelope (skills/wurk:kit/REFERENCE.md).
    def preflight(env, manifest, root:, dry_run:, fetched:)
      default = manifest.default_branch
      remote = manifest.remote_default_branch
      local_sha = rev_parse(env, root, "refs/heads/#{default}")
      remote_sha = rev_parse(env, root, "refs/remotes/#{remote}")

      report = { "local_sha" => local_sha, "remote_sha" => remote_sha, "remote_fresh" => fetched }
      env.data[:preflight] = report

      unless fetched
        env.warn(
          code: "preflight_stale_remote",
          message: "git fetch origin failed; the preflight compared #{default} against #{remote} as last fetched"
        )
      end

      # Nothing to compare: a fresh clone that never fetched, or a default
      # branch nobody has checked out locally. Neither is the incident's
      # shape, so this reports rather than refuses.
      if local_sha.nil? || remote_sha.nil?
        missing = local_sha.nil? ? default : remote
        report["status"] = "skipped"
        report["reason"] = "ref_missing"
        env.warn(code: "preflight_skipped", message: "#{missing} does not resolve; nothing to compare the base against")
        return true
      end

      if local_sha == remote_sha
        report["status"] = "in_sync"
        return true
      end

      behind = Sh.run(["git", "merge-base", "--is-ancestor", local_sha, remote_sha], chdir: root, envelope: env)
      unless behind.success?
        return refuse_preflight(
          env, report, "local_default_diverged",
          "local #{default} (#{local_sha[0, 12]}) has commits #{remote} (#{remote_sha[0, 12]}) does not; " \
          "merge it forward before cutting a worktree from it"
        )
      end

      # Zero own commits, strictly behind: the one repair this preflight
      # makes itself.
      checkout = worktree_path_for_branch(env, root: root, name: default)
      if checkout && File.expand_path(checkout) != File.expand_path(root)
        return refuse_preflight(
          env, report, "default_checked_out_elsewhere",
          "local #{default} is behind #{remote} and checked out at #{checkout}; fast-forward it there first"
        )
      end

      ff = if checkout
             ["git", "merge", "--ff-only", remote_sha]
           else
             ["git", "update-ref", "refs/heads/#{default}", remote_sha, local_sha]
           end

      if dry_run
        report["status"] = "stale"
        report["repair"] = Sh.render(ff, chdir: root)
        env.commands << report["repair"]
        return true
      end

      ff_res = Sh.run(ff, chdir: root, envelope: env)
      unless ff_res.success?
        return refuse_preflight(
          env, report, "fast_forward_failed",
          err_or(ff_res, "#{Sh.render(ff)} failed") + "; local #{default} is still behind #{remote}"
        )
      end

      report["status"] = "fast_forwarded"
      true
    end

    def refuse_preflight(env, report, reason, message)
      report["status"] = "refused"
      report["reason"] = reason
      env.block!(code: "preflight_refused", message: message, needs: "human")
      false
    end

    # The full sha of a ref, or nil when it does not resolve.
    def rev_parse(env, root, ref)
      res = Sh.run(["git", "rev-parse", "--verify", "--quiet", ref], chdir: root, envelope: env)
      return nil unless res.success?

      sha = res.out.to_s.strip
      sha.empty? ? nil : sha
    end

    # The adoption gate, and the only loosening of the never-force default
    # above. Returns nil when the existing branch's workspace can simply be
    # adopted, or a sentence naming the mismatch that keeps it blocked.
    #
    # Adoption requires ALL of: the branch exists (the caller already checked),
    # git has a worktree registered for that branch, that worktree is at
    # exactly the expected path under parallelism.worktrees_dir, the directory
    # is really there, and the tree is clean. That is the case the first
    # worktree-per-issue consumer hit - a worktree it had made by hand before
    # adopting wurk - and in it there is nothing for a human to decide.
    #
    # Every other combination stays blocked, because each one hides a decision
    # this script must not make: a dirty tree holds uncommitted work only a
    # human can judge; the branch checked out somewhere else would leave two
    # directories for one branch, one of them unknown to /wurk:cleanup; a
    # registered worktree whose directory is gone is a prunable entry, not a
    # workspace; a branch with no worktree at all may be someone else's
    # in-flight work.
    def adopt_refusal_reason(env, root:, path:, name:)
      checkout = worktree_path_for_branch(env, root: root, name: name)
      return "no worktree is checked out for it (expected #{path})" unless checkout

      unless File.expand_path(checkout) == File.expand_path(path)
        return "it is checked out at #{checkout}, not at #{path}"
      end
      return "#{path} is not a directory" unless Dir.exist?(path)

      status = Sh.run(%w[git status --porcelain], chdir: path, envelope: env)
      return "git status in #{path} could not be read" unless status.success?
      return "#{path} has uncommitted changes" unless status.out.to_s.strip.empty?

      nil
    end

    # The path of the worktree git has registered for `name`, or nil when no
    # worktree carries that branch. `git worktree list --porcelain` emits one
    # blank-line-separated stanza per worktree, `worktree <path>` first and
    # `branch refs/heads/<name>` present only for a non-detached one.
    def worktree_path_for_branch(env, root:, name:)
      res = Sh.run(%w[git worktree list --porcelain], chdir: root, envelope: env)
      return nil unless res.success?

      current = nil
      res.out.to_s.each_line do |raw|
        line = raw.strip
        if line.start_with?("worktree ")
          current = line[("worktree ".length)..-1]
        elsif line == "branch refs/heads/#{name}"
          return current
        end
      end

      nil
    end

    # A pre-existing branch or directory is blocked before this ever runs, so
    # the guard checks above always execute for real (they are reads, not
    # mutations, and dry-run reporting an accurate guard result is more
    # useful than a guess). Only what follows here - the worktree add, the
    # mise trust, the cache warm, and the verify - is mutating, and that is
    # what --dry-run records without executing.
    def record_dry_run_steps(env, manifest, root:, path:, worktrees_root:, base_ref:, name:, adopt: false)
      unless adopt
        env.commands << Sh.render(["mkdir", "-p", worktrees_root])
        env.commands << Sh.render(["git", "worktree", "add", path, "-b", name, "--no-track", base_ref], chdir: root)
      end
      trust = trust_argv(manifest, path)
      env.commands << Sh.render(trust) if trust
      record_clone_dry_run(env, manifest.warm_clone, root: root, path: path)
      manifest.warm.each { |cmd| env.commands << Sh.render(cmd, chdir: path) }
      env.commands << Sh.render(manifest.gate_loop, chdir: gate_chdir(manifest, path))
    end

    # Mirrors clone_caches below command-for-command, so --dry-run reports
    # exactly the sequence a real run would execute. Flat entries (no "/")
    # still land in one multi-source cp - cp only flattens to a source's
    # basename when the destination is an existing directory, and a flat
    # entry's basename *is* its relative path, so batching them costs
    # nothing and keeps the common case (deps, _build, vendor, build) to two
    # rendered commands instead of two per entry. A nested entry (priv/plts)
    # cannot share that batch: cp would drop its "priv/" parent the same way
    # the bug did, so each one gets its own mkdir -p of the destination
    # parent plus its own single-source cp naming the full destination path.
    def record_clone_dry_run(env, clone, root:, path:)
      return if clone.empty?

      flat, nested = partition_clone(clone)
      record_cp_dry_run(env, flat, dest: "#{path}/", chdir: root) unless flat.empty?

      nested.each do |entry|
        dest = File.join(path, entry)
        env.commands << Sh.render(["mkdir", "-p", File.dirname(dest)])
        record_cp_dry_run(env, [entry], dest: dest, chdir: root)
      end
    end

    def record_cp_dry_run(env, sources, dest:, chdir:)
      env.commands << Sh.render(["cp", "-Rfc"] + sources + [dest], chdir: chdir)
      env.commands << "(fallback if -c is unsupported) " +
                       Sh.render(["cp", "-Rf"] + sources + [dest], chdir: chdir)
    end

    # A warm_clone entry with no "/" (deps, _build, vendor, build) is already
    # its own relative path, so it belongs in the flat batch; anything with a
    # "/" (priv/plts) needs its own destination and its own mkdir -p first.
    def partition_clone(clone)
      clone.partition { |entry| !entry.include?("/") }
    end

    # `parallelism.trust` is the one command run *about* the new worktree
    # rather than inside it (mise trusts a mise.toml per directory path, not
    # per repo), so its argv carries a literal {path} token. Documented in
    # wurk docs/manifest.md; nothing else templates.
    def trust_argv(manifest, path)
      argv = manifest.trust_argv
      argv && argv.map { |a| a.gsub("{path}", path) }
    end

    # The gate command runs in the new worktree - under gate.cwd inside it
    # when the project gates from a subdirectory (wurk docs/manifest.md). One
    # helper so the dry-run render and the real run cannot disagree about
    # where.
    def gate_chdir(manifest, path)
      manifest.gate_chdir(root: path) || path
    end

    # Adoption skips exactly the two creating steps (the worktrees_root mkdir
    # and the `git worktree add`) and nothing else: the trust, the cache
    # clone, the warm commands and the gate all run, because every one of them
    # is idempotent and the point of adopting is a workspace that is warm and
    # verified green, not merely present.
    def create_and_warm(env, io, manifest, root:, path:, worktrees_root:, base_ref:, name:, adopt: false)
      unless adopt
        mkdir_res = Sh.run(["mkdir", "-p", worktrees_root], envelope: env)
        unless mkdir_res.success?
          env.block!(code: "mkdir_failed", message: err_or(mkdir_res, "mkdir -p #{worktrees_root} failed"))
          return env.emit(io)
        end

        add_res = Sh.run(["git", "worktree", "add", path, "-b", name, "--no-track", base_ref], chdir: root, envelope: env)
        unless add_res.success?
          env.block!(code: "worktree_add_failed", message: err_or(add_res, "git worktree add failed"))
          return env.emit(io)
        end
      end

      # A toolchain manager may trust its config per directory path rather
      # than per repo (mise does), so the freshly created worktree path is
      # untrusted even though it is the same repo content - without this, the
      # first managed command run there prompts to trust the config and hangs
      # a non-interactive session the same way an unaliased -i flag does.
      trust = trust_argv(manifest, path)
      if trust
        trust_res = Sh.run(trust, envelope: env, timeout: manifest.parallelism_timeout_seconds)
        env.warn(code: "trust_failed", message: err_or(trust_res, "#{Sh.render(trust)} failed")) unless trust_res.success?
      end

      warm(env, manifest, root: root, path: path)

      manifest.warm.each do |cmd|
        res = Sh.run(cmd, chdir: path, envelope: env, timeout: manifest.parallelism_timeout_seconds)
        env.warn(code: "warm_failed", message: err_or(res, "#{Sh.render(cmd)} failed")) unless res.success?
      end

      quality_res = Sh.run(manifest.gate_loop, chdir: gate_chdir(manifest, path), envelope: env,
                            timeout: manifest.gate_timeout_seconds)

      # The gate command itself never got a chance to run: a typo'd gate.cwd
      # or a gate command missing from PATH (Sh::Result#start_failed?, see
      # lib/sh.rb). That is a misconfiguration for a human to fix, not a
      # failing test suite, so it blocks with the same code gate.rb uses for
      # the identical condition (gate.rb's gate_command_could_not_start)
      # rather than reading as an ordinary red quality_green: false.
      # quality_res.err is already the self-describing sentence Sh emits
      # (command and, when set, chdir), so it becomes the message as-is.
      if quality_res.start_failed?
        env.data[:quality_green] = false
        env.block!(code: "gate_command_could_not_start", message: quality_res.err, needs: "human")
        return env.emit(io)
      end

      env.data[:quality_green] = quality_res.success?
      env.data[:quality_output] = quality_res.out.to_s unless quality_res.success?
      env.fail! unless quality_res.success?

      env.emit(io)
    end

    # On APFS, cp -c uses copy-on-write clonefiles, so this is nearly instant
    # and costs almost no disk; not every filesystem supports -c, so a plain
    # recursive copy is the fallback.
    #
    # `parallelism.warm_globs` names caches expensive enough that their
    # absence is worth reporting (this repo: the dialyzer PLT). Absent, a
    # first full gate in the worktree simply rebuilds them - which is why
    # this warns and never blocks.
    def warm(env, manifest, root:, path:)
      clone = manifest.warm_clone
      if clone.empty?
        env.data[:caches_cloned] = nil
      else
        failed = clone_caches(env, clone, root: root, path: path)
        env.data[:caches_cloned] = failed.empty?
        unless failed.empty?
          env.warn(code: "cache_clone_failed", message: "could not clone #{failed.join(', ')} into #{path}")
        end
      end

      missing = manifest.warm_globs.reject { |glob| Dir.glob(File.join(root, glob)).any? }
      env.data[:warm_caches_present] = manifest.warm_globs.empty? ? nil : missing.empty?

      missing.each do |glob|
        env.warn(
          code: "warm_cache_missing",
          message: "nothing matches #{glob} in #{root}; the first full gate run in the worktree will rebuild it"
        )
      end
    end

    # Flat entries clone in one shot, same as before. Nested entries each get
    # their own mkdir -p of the destination parent and their own single-source
    # cp naming the full destination path - batching them into the flat cp
    # would silently drop each one's parent directory (see partition_clone).
    # Returns the entries that failed to clone, empty when all of them did;
    # `warm` turns a non-empty result into a single cache_clone_failed
    # warning rather than blocking the worktree.
    def clone_caches(env, clone, root:, path:)
      flat, nested = partition_clone(clone)
      failed = []

      if !flat.empty? && !cp_with_fallback(env, flat, dest: "#{path}/", chdir: root)
        failed.concat(flat)
      end

      nested.each do |entry|
        dest = File.join(path, entry)
        mkdir_res = Sh.run(["mkdir", "-p", File.dirname(dest)], envelope: env)
        if !mkdir_res.success? || !cp_with_fallback(env, [entry], dest: dest, chdir: root)
          failed << entry
        end
      end

      failed
    end

    # On APFS, cp -c uses copy-on-write clonefiles, so this is nearly instant
    # and costs almost no disk; not every filesystem supports -c, so a plain
    # recursive copy is the fallback.
    def cp_with_fallback(env, sources, dest:, chdir:)
      cp_res = Sh.run(["cp", "-Rfc"] + sources + [dest], chdir: chdir, envelope: env)
      cp_res = Sh.run(["cp", "-Rf"] + sources + [dest], chdir: chdir, envelope: env) unless cp_res.success?
      cp_res.success?
    end

    def main_checkout_root(env)
      git_dir = Sh.run(%w[git rev-parse --git-dir], envelope: env)
      common_dir = Sh.run(%w[git rev-parse --git-common-dir], envelope: env)
      toplevel = Sh.run(%w[git rev-parse --show-toplevel], envelope: env)
      return nil unless git_dir.success? && common_dir.success? && toplevel.success?

      is_main = File.expand_path(git_dir.out.to_s.strip) == File.expand_path(common_dir.out.to_s.strip)
      return nil unless is_main

      toplevel.out.to_s.strip
    end

    def err_or(result, fallback)
      msg = result.err.to_s.strip
      msg.empty? ? fallback : msg
    end

    def usage_error!(usage_line, parser)
      warn "usage: #{usage_line}\n\n#{parser}"
      exit 2
    end
  end
end

exit WorktreeCreate.run(ARGV) if __FILE__ == $PROGRAM_NAME

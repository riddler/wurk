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
# needs: "human" - see new-worktree/SKILL.md Step 1. This script has no path
# that deletes a branch or a directory to make room for a new one.
module WorktreeCreate
  class << self
    def run(argv, io: $stdout)
      parser, options = Cli.build("worktree_create.rb [options] <name>")
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

      branch_res = Sh.run(["git", "branch", "--list", name], chdir: root, envelope: env)
      if branch_res.success? && !branch_res.out.to_s.strip.empty?
        env.block!(code: "branch_exists", message: "branch #{name} already exists", needs: "human")
        return env.emit(io)
      end

      if Dir.exist?(path)
        env.block!(code: "worktree_dir_exists", message: "#{path} already exists", needs: "human")
        return env.emit(io)
      end

      base_ref = manifest.remote_default_branch
      fetch_res = Sh.run(%w[git fetch origin], chdir: root, envelope: env)
      unless fetch_res.success?
        base_ref = manifest.default_branch
        env.warn(
          code: "fetch_failed",
          message: "git fetch origin failed (offline?); cutting #{name} from local " \
                   "#{manifest.default_branch} instead of #{manifest.remote_default_branch}"
        )
      end

      env.data[:name] = name
      env.data[:path] = path
      env.data[:base_ref] = base_ref
      env.data[:dry_run] = dry_run

      if dry_run
        record_dry_run_steps(env, manifest, root: root, path: path, worktrees_root: worktrees_root, base_ref: base_ref, name: name)
        return env.emit(io)
      end

      create_and_warm(env, io, manifest, root: root, path: path, worktrees_root: worktrees_root, base_ref: base_ref, name: name)
    end

    private

    # A pre-existing branch or directory is blocked before this ever runs, so
    # the guard checks above always execute for real (they are reads, not
    # mutations, and dry-run reporting an accurate guard result is more
    # useful than a guess). Only what follows here - the worktree add, the
    # mise trust, the cache warm, and the verify - is mutating, and that is
    # what --dry-run records without executing.
    def record_dry_run_steps(env, manifest, root:, path:, worktrees_root:, base_ref:, name:)
      env.commands << Sh.render(["mkdir", "-p", worktrees_root])
      env.commands << Sh.render(["git", "worktree", "add", path, "-b", name, "--no-track", base_ref], chdir: root)
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

    def create_and_warm(env, io, manifest, root:, path:, worktrees_root:, base_ref:, name:)
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

      # A toolchain manager may trust its config per directory path rather
      # than per repo (mise does), so the freshly created worktree path is
      # untrusted even though it is the same repo content - without this, the
      # first managed command run there prompts to trust the config and hangs
      # a non-interactive session the same way an unaliased -i flag does.
      trust = trust_argv(manifest, path)
      if trust
        trust_res = Sh.run(trust, envelope: env)
        env.warn(code: "trust_failed", message: err_or(trust_res, "#{Sh.render(trust)} failed")) unless trust_res.success?
      end

      warm(env, manifest, root: root, path: path)

      manifest.warm.each do |cmd|
        res = Sh.run(cmd, chdir: path, envelope: env)
        env.warn(code: "warm_failed", message: err_or(res, "#{Sh.render(cmd)} failed")) unless res.success?
      end

      quality_res = Sh.run(manifest.gate_loop, chdir: gate_chdir(manifest, path), envelope: env)
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

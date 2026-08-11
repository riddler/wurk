#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/manifest"

# RebaseOnto is the shared rebase-with-repair block that /wurk:mr
# deferred to /wurk:refresh by prose cross-reference - defined once here
# so it cannot drift, and reused directly (as a library call, not shelled out
# to) by worktree_refresh.rb and, in a later phase, /wurk:mr's own
# script. See statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 4.
#
# A conflict is always blocked with needs: "human", the conflicting files
# named. There is no resolve path - CLAUDE.md's authority table is explicit
# that resolving a rebase conflict unasked is unauthorized, so this script
# does not offer one even as dead code.
#
# Assumes the manifest's remote default branch has already been fetched by
# the caller: a standalone run does no fetch of its own (see #run), and
# worktree_refresh.rb fetches once for the whole sweep rather than once per
# worktree.
module RebaseOnto
  class << self
    # Runs the block against the worktree at `path`, recording every command
    # into `env`. Returns a result hash:
    #   {status: "rebased", target: <sha>, lock_changed: bool, repaired: bool|nil}
    #   {status: "conflict", files: [...]}
    #   {status: "dry_run"} when dry_run: true - nothing was executed.
    #
    # `manifest` supplies the repair recipe (which lockfile moving means the
    # build is stale, and what to run about it) and the warm-cache globs.
    # worktree_refresh.rb passes the one it already loaded; a standalone run
    # loads its own in #run.
    def perform(path, env, manifest, dry_run: false)
      return dry_run_steps(path, env, manifest) if dry_run

      before_res = Sh.run(%w[git rev-parse HEAD], chdir: path, envelope: env)
      before = before_res.out.to_s.strip

      rebase_res = Sh.run(["git", "rebase", manifest.remote_default_branch], chdir: path, envelope: env)

      unless rebase_res.success?
        # Capture the conflicting files first, then abort - the abort clears
        # the conflict state, so a report assembled afterward has nothing
        # left to name if this order is reversed. This ordering is the whole
        # point of the extraction; see rebase_onto_test.rb.
        diff_res = Sh.run(%w[git diff --name-only --diff-filter=U], chdir: path, envelope: env)
        files = diff_res.out.to_s.each_line.map(&:strip).reject(&:empty?)
        Sh.run(%w[git rebase --abort], chdir: path, envelope: env)
        env.block!(code: "rebase_conflict", message: "conflict in #{files.join(', ')}", needs: "human")
        return { status: "conflict", files: files }
      end

      target_res = Sh.run(["git", "rev-parse", manifest.remote_default_branch], chdir: path, envelope: env)
      target = target_res.out.to_s.strip

      repair = repair_after(path, env, manifest, before: before)

      { status: "rebased", target: target, lock_changed: repair[:lock_changed], repaired: repair[:repaired] }
    end

    # The post-rebase half, public so rebase_resolve.rb can run it after
    # continuing a rebase it resolved. Extracted, not duplicated: a second
    # copy of the repair recipe is exactly the drift this file was created to
    # prevent (see the header).
    #
    # git diff --quiet exits 0 when there is no difference (the fast path: no
    # repair commands, no cache work) and non-zero when the lockfile named by
    # parallelism.repair_when moved. A repo that configures no repair_when
    # has no such fast/slow split to make.
    def repair_after(path, env, manifest, before:)
      lock_changed = false
      if manifest.repair_when
        lock_res = Sh.run(
          ["git", "diff", "--quiet", before, "HEAD", "--", manifest.repair_when],
          chdir: path, envelope: env
        )
        lock_changed = !lock_res.success?
      end

      repaired = nil
      if lock_changed
        # Stops at the first failure rather than pressing on: the commands
        # are a recipe, and step two of a repair is meaningless once step
        # one did not happen. `repaired` stays nil when none are configured
        # ("not attempted"), which is not the same claim as false.
        repaired = manifest.repair.all? { |cmd| Sh.run(cmd, chdir: path, envelope: env).success? } unless manifest.repair.empty?
        copy_warm_caches(path, env, manifest)
      end

      { lock_changed: lock_changed, repaired: repaired }
    end

    def run(argv, io: $stdout)
      parser, options = Cli.build("rebase_onto.rb [options] <path>")
      args = Cli.parse!(parser, argv)
      path = args.first
      usage_error!("rebase_onto.rb [options] <path>", parser) if path.to_s.strip.empty?

      env = Envelope.new(script: "rebase_onto")

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest

      result = perform(path, env, manifest, dry_run: options[:dry_run])

      env.data[:path] = path
      result.each { |k, v| env.data[k.to_s] = v }

      env.emit(io)
    end

    private

    def dry_run_steps(path, env, manifest)
      env.commands << Sh.render(%w[git rev-parse HEAD], chdir: path)
      env.commands << Sh.render(["git", "rebase", manifest.remote_default_branch], chdir: path)
      env.commands << "(on conflict) " + Sh.render(%w[git diff --name-only --diff-filter=U], chdir: path)
      env.commands << "(on conflict) " + Sh.render(%w[git rebase --abort], chdir: path)
      prefix = manifest.repair_when ? "(if #{manifest.repair_when} moved) " : "(on repair) "
      manifest.repair.each { |cmd| env.commands << prefix + Sh.render(cmd, chdir: path) }
      { status: "dry_run" }
    end

    # Targeted copy of the caches named by parallelism.warm_globs, never a
    # wholesale re-clone of the warm_clone directories - that would clobber
    # a worktree's own incremental build state and force a full rebuild.
    # Best-effort: a missing or stale cache is a warning, never a block,
    # because the next full gate run in the worktree rebuilds it.
    #
    # Each glob is repo-root-relative and the match keeps its relative path
    # on the way across, so a cache nested three directories deep lands
    # where the worktree's own build expects it.
    def copy_warm_caches(path, env, manifest)
      return if manifest.warm_globs.empty?

      main = main_checkout_for(path, env)
      unless main
        env.warn(code: "warm_cache_source_unknown", message: "could not determine the main checkout to copy warm caches from")
        return
      end

      manifest.warm_globs.each { |glob| copy_one_glob(glob, main, path, env) }
    end

    def copy_one_glob(glob, main, path, env)
      matches = Dir.glob(File.join(main, glob))
      if matches.empty?
        env.warn(
          code: "warm_cache_missing",
          message: "nothing matches #{glob} in #{main} to copy; the next full gate run in #{path} will rebuild it"
        )
        return
      end

      matches.each do |src|
        relative = src.sub(/\A#{Regexp.escape(main)}\/?/, "")
        dest = File.join(path, relative)
        result = Sh.run(["cp", "-f", src, dest], envelope: env)
        env.warn(code: "warm_cache_copy_failed", message: "cp #{src} -> #{dest} failed") unless result.success?
      end
    end

    def main_checkout_for(path, env)
      list_res = Sh.run(%w[git worktree list --porcelain], chdir: path, envelope: env)
      return nil unless list_res.success?

      # git-worktree(1): the main working tree is always listed first.
      first_line = list_res.out.to_s.each_line.first.to_s
      return nil unless first_line.start_with?("worktree ")

      first_line.sub("worktree ", "").strip
    end

    def usage_error!(usage_line, parser)
      warn "usage: #{usage_line}\n\n#{parser}"
      exit 2
    end
  end
end

exit RebaseOnto.run(ARGV) if __FILE__ == $PROGRAM_NAME

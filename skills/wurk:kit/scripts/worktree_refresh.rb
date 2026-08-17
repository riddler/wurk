#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "stringio"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/manifest"
require_relative "lib/forge"
require_relative "worktree_survey"
require_relative "rebase_onto"

# WorktreeRefresh is the /wurk:refresh sweep: enumerate live worktrees,
# fetch origin once, then per worktree skip-if-current / refuse-if-dirty /
# rebase_onto / confirm green. See
# statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 4.
#
# Result vocabulary is preserved exactly from refresh-worktree/SKILL.md:
# "rebased onto <sha>, lock unchanged, loop green" / "current, skipped" /
# "conflict in <file>, aborted, unchanged" / "dirty, skipped" / "red".
module WorktreeRefresh
  class << self
    def run(argv, io: $stdout)
      parser, options = Cli.build("worktree_refresh.rb [options] [name]")
      args = Cli.parse!(parser, argv)
      target = args.first
      dry_run = options[:dry_run]

      env = Envelope.new(script: "worktree_refresh")

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest

      # Guarded here as well as inside worktree_survey.rb: this sweep depends
      # on the per-worktree request lookup for its rebase-worthiness signal,
      # so it says in its own voice which forge that lookup needs rather than
      # relaying a nested "survey_failed".
      return env.emit(io) unless Forge.guard!(env, manifest, doing: "the per-worktree request lookup")

      worktrees, error = enumerate(env, target)
      if error
        env.block!(code: error[:code], message: error[:message])
        return env.emit(io)
      end

      if worktrees.empty?
        env.data[:results] = []
        env.data[:origin_main] = nil
        return env.emit(io)
      end

      # One fetch for the whole sweep. Offline is a hard stop: refreshing
      # against a stale remote default branch would rebase worktrees onto
      # the commit they are already on and report success for nothing.
      fetch_res = Sh.run(%w[git fetch origin], envelope: env)
      unless fetch_res.success?
        env.block!(
          code: "offline",
          message: "git fetch origin failed; refreshing against a stale #{manifest.remote_default_branch} " \
                    "would report success for nothing"
        )
        return env.emit(io)
      end

      # `origin_main` is the historical field name (kept for /wurk:refresh's
      # reading of it); the value is the manifest's remote default branch,
      # not necessarily literal origin/main.
      origin_main_res = Sh.run(["git", "rev-parse", manifest.remote_default_branch], envelope: env)
      env.data[:origin_main] = origin_main_res.success? ? origin_main_res.out.to_s.strip : nil

      results = worktrees.map { |wt| refresh_one(wt["path"], wt["branch"], env, manifest, dry_run: dry_run) }
      env.data[:results] = results

      # start_with?("red") also catches confirm_green's "red, gate could not
      # start: ..." variant above, not just the bare "red" - both are
      # failures, they differ only in whether the cause is known.
      env.fail! if results.any? { |r| r[:result].to_s.start_with?("red") }
      env.emit(io)
    end

    private

    def enumerate(env, target)
      survey_io = StringIO.new
      WorktreeSurvey.run([], io: survey_io)
      survey_env = JSON.parse(survey_io.string)
      env.commands.concat(survey_env["commands"] || [])

      unless survey_env["ok"]
        message = (survey_env["blocked"] || []).map { |b| b["message"] }.join("; ")
        return [nil, { code: "survey_failed", message: message.empty? ? "worktree_survey failed" : message }]
      end

      worktrees = survey_env.dig("data", "worktrees") || []
      if target
        worktrees = worktrees.select { |w| File.basename(w["path"].to_s) == target || w["branch"] == target }
        return [nil, { code: "no_matching_worktree", message: "no live worktree matches #{target.inspect}" }] if worktrees.empty?
      end

      [worktrees, nil]
    end

    # Both checks re-run here, after the fetch above, rather than reusing
    # worktree_survey's precomputed fields - those were computed before this
    # sweep's fetch and would read a stale remote default branch, which is
    # exactly the failure mode this skill exists to prevent (see
    # refresh-worktree/SKILL.md Step 3a: the current-check happens after the
    # fetch, not at enumeration time).
    def refresh_one(path, branch, env, manifest, dry_run:)
      ancestor_res = Sh.run(
        ["git", "merge-base", "--is-ancestor", manifest.remote_default_branch, "HEAD"],
        chdir: path, envelope: env
      )
      return { path: path, branch: branch, result: "current, skipped" } if ancestor_res.success?

      status_res = Sh.run(%w[git status --porcelain], chdir: path, envelope: env)
      if status_res.success? && !status_res.out.to_s.strip.empty?
        return { path: path, branch: branch, result: "dirty, skipped" }
      end

      rebase_result = RebaseOnto.perform(path, env, manifest, dry_run: dry_run)

      case rebase_result[:status]
      when "conflict"
        { path: path, branch: branch, result: "conflict in #{rebase_result[:files].join(', ')}, aborted, unchanged" }
      when "dry_run"
        env.commands << Sh.render(manifest.gate_loop, chdir: gate_chdir(manifest, path))
        { path: path, branch: branch, result: "dry run" }
      else
        confirm_green(path, branch, rebase_result, env, manifest)
      end
    end

    def confirm_green(path, branch, rebase_result, env, manifest)
      quality_res = Sh.run(manifest.gate_loop, chdir: gate_chdir(manifest, path), envelope: env)

      # The gate command itself never got a chance to run: a typo'd gate.cwd
      # or a gate command missing from PATH (Sh::Result#start_failed?, see
      # lib/sh.rb). A bare "red" would read as this worktree's tests
      # failing, when it is really a misconfiguration to fix - so this names
      # the concrete cause instead. quality_res.err is already Sh's
      # self-describing sentence (command and, when set, chdir), so it goes
      # into the result string as-is, the same way gate.rb uses res.err
      # verbatim for its gate_command_could_not_start block.
      if quality_res.start_failed?
        return { path: path, branch: branch, result: "red, gate could not start: #{quality_res.err}" }
      end
      return { path: path, branch: branch, result: "red" } unless quality_res.success?

      lock_note = rebase_result[:lock_changed] ? "lock repaired" : "lock unchanged"
      { path: path, branch: branch, result: "rebased onto #{rebase_result[:target]}, #{lock_note}, loop green" }
    end

    # The gate command runs in the refreshed worktree - under gate.cwd inside
    # it when the project gates from a subdirectory (wurk docs/manifest.md).
    # One helper so the dry-run render and the real run cannot disagree about
    # where. Kept as its own private method rather than sharing
    # worktree_create.rb's - Manifest#gate_chdir is already the shared
    # definition site, and the `|| path` fallback is one expression.
    def gate_chdir(manifest, path)
      manifest.gate_chdir(root: path) || path
    end
  end
end

exit WorktreeRefresh.run(ARGV) if __FILE__ == $PROGRAM_NAME

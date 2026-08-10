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
require_relative "pr_state"

# WorktreeCleanup is the /wurk:cleanup sweep, minus the two pieces that
# stay at the skill boundary on purpose (see
# statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 4):
#
# - Closing beads: this script never calls `bd close`. It emits
#   `data.beads_to_close`, gathered from `pr_state.rb beads` over each merged
#   PR's commits, and the SKILL.md performs the close - `bd close` is
#   agent-authorized only against a verified merge, and keeping the call at
#   the skill boundary is what keeps that trigger visible.
# - tmux quiescing: Phase 5's script, invoked by the SKILL.md between this
#   script's check phase and its removal phase.
#
# Merge detection goes entirely through pr_state.rb (via worktree_survey.rb,
# which already queries it per worktree) - never git ancestry. This repo
# allows rebase merging only, so a merged branch's tip is never an ancestor
# of main; see pr_state.rb's header comment for the verified failure modes.
#
# Never remove a dirty worktree, and never delete a branch `git worktree
# remove` itself would refuse - that refusal is a feature. This script has no
# forceful override of either refusal anywhere in it.
module WorktreeCleanup
  class << self
    def run(argv, io: $stdout)
      parser, options = Cli.build("worktree_cleanup.rb [options] [name]")
      args = Cli.parse!(parser, argv)
      target = args.first
      dry_run = options[:dry_run]

      env = Envelope.new(script: "worktree_cleanup")

      # Guarded here as well as inside worktree_survey.rb: this is the script
      # that deletes branches on the strength of a merge signal, so it says
      # in its own voice which forge that signal has to come from rather
      # than relaying a nested "survey_failed".
      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest
      return env.emit(io) unless Forge.guard!(env, manifest, doing: "merge detection")

      worktrees, error = enumerate(env, target)
      if error
        env.block!(code: error[:code], message: error[:message])
        return env.emit(io)
      end

      if worktrees.empty?
        env.data[:results] = []
        env.data[:beads_to_close] = []
        return env.emit(io)
      end

      results = []
      beads_to_close = []

      worktrees.each do |wt|
        result, beads = cleanup_one(wt, env, dry_run: dry_run)
        results << result
        beads_to_close.concat(beads)
      end

      env.data[:results] = results
      env.data[:beads_to_close] = beads_to_close.uniq.sort

      # Remote branches are usually already gone - GitHub deletes them on
      # merge. Cleanup here is purely local, once per sweep, not per
      # worktree.
      if dry_run
        env.commands << Sh.render(%w[git fetch --prune])
      else
        Sh.run(%w[git fetch --prune], envelope: env)
      end

      env.emit(io)
    end

    private

    # gh failure stops the whole sweep here (unlike worktree_survey.rb and
    # worktree_refresh.rb, which degrade or continue on a per-worktree gh
    # failure) - without PR state there is no safe merge signal, and this
    # script is the one that deletes branches on the strength of that signal.
    def enumerate(env, target)
      survey_io = StringIO.new
      WorktreeSurvey.run([], io: survey_io)
      survey_env = JSON.parse(survey_io.string)
      env.commands.concat(survey_env["commands"] || [])

      unless survey_env["ok"]
        message = (survey_env["blocked"] || []).map { |b| b["message"] }.join("; ")
        return [nil, { code: "survey_failed", message: message.empty? ? "worktree_survey failed" : message }]
      end

      unless survey_env.dig("data", "gh_available")
        return [nil, { code: "gh_unavailable", message: "gh is unavailable; without PR state there is no safe merge signal" }]
      end

      worktrees = survey_env.dig("data", "worktrees") || []
      if target
        worktrees = worktrees.select { |w| File.basename(w["path"].to_s) == target || w["branch"] == target }
        return [nil, { code: "no_matching_worktree", message: "no live worktree matches #{target.inspect}" }] if worktrees.empty?
      end

      [worktrees, nil]
    end

    def cleanup_one(wt, env, dry_run:)
      path = wt["path"]
      branch = wt["branch"]
      pr = wt["pr"]

      unless pr && pr["state"] == "MERGED"
        return [{ path: path, branch: branch, result: "not merged (no PR, open, or closed unmerged), kept" }, []]
      end

      status_res = Sh.run(%w[git status --porcelain], chdir: path, envelope: env)
      if status_res.success? && !status_res.out.to_s.strip.empty?
        return [{ path: path, branch: branch, result: "dirty, skipped" }, []]
      end

      head_res = Sh.run(%w[git rev-parse HEAD], chdir: path, envelope: env)
      local_head = head_res.out.to_s.strip
      if head_res.success? && local_head != pr["head_oid"]
        return [
          { path: path, branch: branch, result: "commits after merge (#{local_head} != #{pr['head_oid']}), skipped" },
          []
        ]
      end

      beads = beads_for(pr, env)

      if dry_run
        env.commands << Sh.render(["git", "worktree", "remove", path])
        env.commands << Sh.render(%w[git worktree prune])
        env.commands << Sh.render(["git", "branch", "-D", branch])
        return [{ path: path, branch: branch, result: "merged in PR ##{pr['number']}, would remove" }, beads]
      end

      remove(path, branch, pr, beads, env)
    end

    def beads_for(pr, env)
      result = PrState.beads_for_pr(pr["number"], env: env)
      unless result.available
        env.warn(code: "beads_lookup_failed", message: "could not read commits for PR ##{pr['number']}: #{result.error}")
        return []
      end

      result.beads
    end

    # Order matters: the branch cannot be deleted while a worktree has it
    # checked out, so remove is always first.
    def remove(path, branch, pr, beads, env)
      remove_res = Sh.run(["git", "worktree", "remove", path], envelope: env)
      unless remove_res.success?
        env.warn(code: "worktree_remove_failed", message: err_or(remove_res, "git worktree remove #{path} failed"))
        return [{ path: path, branch: branch, result: "remove failed, skipped" }, []]
      end

      Sh.run(%w[git worktree prune], envelope: env)

      # -D is correct here and only here: the merge check above confirmed
      # the commits are on origin/main under different SHAs (this repo
      # allows rebase merging only, so `git branch -d` would refuse).
      branch_res = Sh.run(["git", "branch", "-D", branch], envelope: env)
      env.warn(code: "branch_delete_failed", message: err_or(branch_res, "git branch -D #{branch} failed")) unless branch_res.success?

      [{ path: path, branch: branch, result: "merged in PR ##{pr['number']}, removed" }, beads]
    end

    def err_or(result, fallback)
      msg = result.err.to_s.strip
      msg.empty? ? fallback : msg
    end
  end
end

exit WorktreeCleanup.run(ARGV) if __FILE__ == $PROGRAM_NAME

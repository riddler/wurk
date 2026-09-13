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
require_relative "request_state"

# WorktreeCleanup is the /wurk:cleanup sweep, minus the two pieces that
# stay at the skill boundary on purpose (see
# statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 4):
#
# - Closing beads: this script never calls `bd close`. It emits
#   `data.beads_to_close`, gathered from `request_state.rb beads` over each
#   merged PR's commits, and the SKILL.md performs the close - `bd close` is
#   agent-authorized only against a verified merge, and keeping the call at
#   the skill boundary is what keeps that trigger visible.
# - tmux quiescing: Phase 5's script, invoked by the SKILL.md between this
#   script's check phase and its removal phase.
#
# Merge detection goes entirely through request_state.rb (via
# worktree_survey.rb, which already queries it per worktree) - never git
# ancestry. This repo allows rebase merging only, so a merged branch's tip is
# never an ancestor of main; see request_state.rb's header comment for the
# verified failure modes.
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

      # Fetched before the check phase, and on a dry run too. The
      # patch-equivalence probe below can only see commits reachable from
      # the merge target in this checkout, so a stale remote-tracking ref
      # would make it refuse a worktree whose work has landed - the failure
      # this check exists to stop reporting. The dry run joins in because
      # /wurk:cleanup selects candidates on the dry run and removes them by
      # name afterwards: the two must decide against the same refs. A fetch
      # writes only remote-tracking refs, and touches no branch, no
      # worktree, and no bead; that bound is the carve-out ADR-0006's
      # "Amendment (2026-09-13)" makes to its dry-run rule, and the same
      # record lists what a dry run still must not do.
      fetch_res = Sh.run(%w[git fetch --prune], envelope: env)
      unless fetch_res.success?
        # A failed fetch is not fatal - the sweep still refuses rather than
        # removes - but it must not be silent. Every probe below then judges
        # against whatever refs this checkout already had, and a refusal on
        # stale refs reads exactly like a genuine divergence: the false skip
        # wu-mya.9 removed. Named for the condition, not for the rejected
        # fallback of the same name in ADR-0006's amendment.
        env.warn(code: "refs_not_fetched",
                 message: "#{err_or(fetch_res, 'git fetch --prune failed')}; " \
                          "patch-equivalence decisions below may rest on stale refs")
      end

      results = []
      beads_to_close = []

      worktrees.each do |wt|
        result, beads = cleanup_one(wt, manifest, env, dry_run: dry_run)
        results << result
        beads_to_close.concat(beads)
      end

      env.data[:results] = results
      env.data[:beads_to_close] = beads_to_close.uniq.sort

      env.emit(io)
    end

    # Whether every commit this worktree carries already has a
    # patch-equivalent on `upstream`. Three states, because "could not
    # tell" must not read as "nothing left": :equivalent (safe to remove),
    # :diverged (a commit is not upstream under any sha), :unknown (the
    # probe itself failed).
    #
    # This is NOT the ancestry check request_state.rb's header bans, in
    # two respects. Direction: the forge has already said this request
    # merged, and git is consulted only to REFUSE - it can never declare a
    # merge here, so its failure mode is a kept worktree, not a silent
    # no-op. Power: `git cherry` matches on patch id, so it answers
    # correctly in exactly the case plain ancestry gets wrong, a rebase
    # that replayed the commits under new shas. Plain ancestry is
    # subsumed - when a tip is an ancestor, `upstream..HEAD` is empty and
    # the output below is empty too.
    #
    # Same probe /wurk:cleanup's SKILL.md tells an operator to run by
    # hand, with the same all-"-" rule; it moved in here because the skip
    # it disambiguates reads like unlanded work and mostly never got
    # probed.
    def patch_equivalence(path, upstream, env)
      result = Sh.run(["git", "cherry", upstream, "HEAD"], chdir: path, envelope: env)
      return [:unknown, err_or(result, "git cherry #{upstream} HEAD failed")] unless result.success?

      unmatched = result.out.to_s.each_line.map(&:strip).select { |line| line.start_with?("+") }
      return [:diverged, "#{unmatched.length} commit(s) not on #{upstream}"] unless unmatched.empty?

      [:equivalent, nil]
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

      unless survey_env.dig("data", "forge_available")
        return [nil, { code: "forge_unavailable", message: "the forge CLI is unavailable; without request state there is no safe merge signal" }]
      end

      worktrees = survey_env.dig("data", "worktrees") || []
      if target
        worktrees = worktrees.select { |w| File.basename(w["path"].to_s) == target || w["branch"] == target }
        return [nil, { code: "no_matching_worktree", message: "no live worktree matches #{target.inspect}" }] if worktrees.empty?
      end

      [worktrees, nil]
    end

    def cleanup_one(wt, manifest, env, dry_run:)
      path = wt["path"]
      branch = wt["branch"]
      request = wt["request"]

      unless request && request["state"] == Forge::REQUEST_MERGED
        return [{ path: path, branch: branch, result: "not merged (no request, open, or closed unmerged), kept" }, []]
      end

      status_res = Sh.run(%w[git status --porcelain], chdir: path, envelope: env)
      if status_res.success? && !status_res.out.to_s.strip.empty?
        return [{ path: path, branch: branch, result: "dirty, skipped" }, []]
      end

      head_res = Sh.run(%w[git rev-parse HEAD], chdir: path, envelope: env)
      local_head = head_res.out.to_s.strip

      rewritten = false
      if head_res.success? && local_head != request["head_oid"]
        upstream = manifest.remote_default_branch
        state, detail = patch_equivalence(path, upstream, env)

        if state == :diverged
          return [{ path: path, branch: branch,
                    result: "commits after merge (#{local_head} != #{request['head_oid']}), skipped" }, []]
        end

        if state == :unknown
          env.warn(code: "patch_equivalence_unknown",
                    message: "could not compare #{path} against #{upstream}: #{detail}")
          return [{ path: path, branch: branch,
                    result: "commits after merge (#{local_head} != #{request['head_oid']}), unverified, skipped" }, []]
        end

        rewritten = true
      end

      beads = beads_for(request, env)
      label = rewritten ? " (local tip rewritten, patches already on #{manifest.remote_default_branch})" : ""

      if dry_run
        env.commands << Sh.render(["git", "worktree", "remove", path])
        env.commands << Sh.render(%w[git worktree prune])
        env.commands << Sh.render(["git", "branch", "-D", branch])
        return [{ path: path, branch: branch, result: "merged in request ##{request['number']}#{label}, would remove" }, beads]
      end

      remove(path, branch, request, beads, label, env)
    end

    def beads_for(request, env)
      result = RequestState.beads_for_pr(request["number"], env: env)
      unless result.available
        env.warn(code: "beads_lookup_failed", message: "could not read commits for request ##{request['number']}: #{result.error}")
        return []
      end

      result.beads
    end

    # Order matters: the branch cannot be deleted while a worktree has it
    # checked out, so remove is always first.
    def remove(path, branch, request, beads, label, env)
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

      [{ path: path, branch: branch, result: "merged in request ##{request['number']}#{label}, removed" }, beads]
    end

    def err_or(result, fallback)
      msg = result.err.to_s.strip
      msg.empty? ? fallback : msg
    end
  end
end

exit WorktreeCleanup.run(ARGV) if __FILE__ == $PROGRAM_NAME

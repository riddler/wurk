#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/refs"
require_relative "lib/manifest"
require_relative "lib/forge"
require_relative "request_state"

# WorktreeSurvey is one survey standing in for three near-identical ones:
# /wurk:next Step 2, /wurk:refresh Step 1, and /wurk:cleanup
# Step 1. See statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 2.
module WorktreeSurvey
  # A bead status that says the work this worktree exists for is finished.
  # bd reports open / in_progress / blocked / closed; only the last one is a
  # worktree that has outlived its reason to exist.
  CLOSED_BEAD_STATUSES = %w[closed].freeze

  # Blocked codes this survey raises ABOUT THE TREE rather than about its own
  # reading of the tree. A caller that consumes the survey as a data source
  # (select_batch.rb, worktree_refresh.rb, worktree_cleanup.rb) still holds a
  # complete, correct worktree list when one of these is present, so it keeps
  # working and relays the entry as a warning for the human. Enumerated here
  # with a reason each, never a flag that turns the check off:
  #
  # - closed_bead_worktree: the remedy its message names IS
  #   worktree_cleanup.rb, so treating it as fatal there would wall off the
  #   one fix the refusal offers.
  ADVISORY_BLOCKED_CODES = %w[closed_bead_worktree].freeze

  class << self
    # Splits a parsed survey envelope's blocked[] for an in-process caller:
    # relays the advisory entries (above) into the caller's envelope as
    # warnings, and returns the entries that are genuinely fatal for it.
    def absorb_advisories(survey_env, env)
      blocked = survey_env["blocked"] || []
      advisory, fatal = blocked.partition { |b| ADVISORY_BLOCKED_CODES.include?(b["code"]) }
      advisory.each { |b| env.warn(code: b["code"], message: b["message"]) }
      fatal
    end

    # Parses `git worktree list --porcelain` into an array of
    # {path:, branch:, head:} hashes. `branch:` is nil for a detached HEAD
    # entry.
    def parse_porcelain(text)
      entries = []
      current = nil

      text.to_s.each_line do |raw|
        line = raw.chomp
        if line.empty?
          entries << current if current
          current = nil
          next
        end

        current ||= {}
        if line.start_with?("worktree ")
          current[:path] = line.sub("worktree ", "")
        elsif line.start_with?("branch refs/heads/")
          current[:branch] = line.sub("branch refs/heads/", "")
        elsif line.start_with?("branch ")
          current[:branch] = line.sub("branch ", "")
        elsif line == "detached"
          current[:branch] = nil
        elsif line.start_with?("HEAD ")
          current[:head] = line.sub("HEAD ", "")
        end
      end
      entries << current if current

      entries
    end

    def decompose_bead(branch)
      return nil unless branch

      m = branch.match(/\A(#{Refs.bead_id})-/)
      m && m[1]
    end

    # One `bd show` per worktree, feeding both the area labels and the bead's
    # status. Returns {available:, areas:, status:}. `available` is false when
    # the tracker could not answer at all - no bd on PATH, an unreadable db,
    # or a reply that is not the one-element array bd documents - and then the
    # closed-bead check below degrades to a warning rather than a block. A
    # survey that refused to run without a tracker would take /wurk:next and
    # /wurk:refresh down with it.
    def bead_record(bead, env)
      return { available: true, areas: [], status: nil } unless bead

      result = Sh.run(["bd", "show", bead, "--json"], envelope: env)
      return { available: false, areas: [], status: nil } unless result.success?

      parsed = JSON.parse(result.out)
      return { available: false, areas: [], status: nil } unless parsed.is_a?(Array) && parsed.first

      issue = parsed.first
      labels = issue["labels"] || []
      { available: true,
        areas: labels.select { |l| l.start_with?("area:") },
        status: issue["status"] }
    rescue JSON::ParserError
      { available: false, areas: [], status: nil }
    end

    # The refusal a live worktree for a closed bead earns. It names the path,
    # the bead and one command, and it removes nothing: a worktree can hold
    # unpushed work, and worktree_cleanup.rb removes only on the forge's
    # merged signal, which a tracker status lookup cannot stand in for.
    def closed_bead_message(worktree)
      "#{worktree[:path]} is a live worktree for bead #{worktree[:bead]}, whose tracker " \
        "status is closed - a finished campaign left it behind. Fix: confirm it holds no " \
        "unpushed work, then remove it with `worktree_cleanup.rb #{worktree[:branch]}` " \
        "(which removes only on the forge's merged signal), or keep it deliberately and " \
        "say so in the run's journal. Nothing here removes it for you."
    end

    def run(argv, io: $stdout)
      parser, _options = Cli.build("worktree_survey.rb [options]")
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "worktree_survey")

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest
      return env.emit(io) unless Forge.guard!(env, manifest, doing: "the per-worktree PR lookup")

      list_res = Sh.run(%w[git worktree list --porcelain], envelope: env)
      unless list_res.success?
        env.block!(code: "git_worktree_list_failed", message: list_res.err.to_s.strip)
        return env.emit(io)
      end

      entries = parse_porcelain(list_res.out)
      # git-worktree(1): the main working tree is always listed first. It is
      # never a survey target - it is not a per-issue branch, and removing
      # it would take the repository with it.
      main_checkout = entries.first ? entries.first[:path] : nil
      rest = entries[1..-1] || []

      forge_available = true
      tracker_available = true
      degraded = []
      worktrees = []

      rest.each do |entry|
        worktree, forge_available, tracker_available =
          survey_one(entry, env, manifest, forge_available, tracker_available)
        worktrees << worktree
        degraded << entry[:path] unless forge_available
      end

      # The closed-bead check. Four consecutive campaigns each surveyed the
      # same worktree for a bead closed days earlier, each correctly declined
      # to stash it (a worktree is not stashable) and to delete it, and each
      # journaled it as unrelated dirt and moved on; it went away only when an
      # operator ruled on it five days later. Both inputs are already in hand
      # here, so the survey says it once, in the voice a run has to route on.
      worktrees.each do |worktree|
        next unless CLOSED_BEAD_STATUSES.include?(worktree[:bead_status])

        env.block!(code: "closed_bead_worktree", message: closed_bead_message(worktree), needs: "human")
      end

      env.data[:main_checkout] = main_checkout
      env.data[:worktrees] = worktrees
      env.data[:forge_available] = forge_available
      env.data[:degraded] = degraded

      env.emit(io)
    end

    private

    # Surveys one worktree entry. `forge_available` is the running flag from
    # the caller; once false, no further gh call is attempted for any
    # subsequent worktree ("say so once, not once per worktree" - the
    # warning fires on the call that first discovers gh is down, not
    # again). `tracker_available` is the same running flag for bd, and for the
    # same reason - one warning per run, not one per worktree; unlike the
    # forge flag it never stops the lookup, because the area labels behind it
    # are what a batch selection reads. Returns [worktree_hash,
    # forge_available_after_this_call, tracker_available_after_this_call].
    def survey_one(entry, env, manifest, forge_available, tracker_available)
      path = entry[:path]
      branch = entry[:branch]
      bead = decompose_bead(branch)

      status_res = Sh.run(%w[git status --porcelain], chdir: path, envelope: env)
      if status_res.success?
        dirty = !status_res.out.to_s.strip.empty?
      else
        dirty = false
        env.warn(code: "status_failed", message: "git status failed in #{path}")
      end

      # `ancestor_of_origin_main` is the historical field name (kept for
      # select_batch.rb and /wurk:cleanup's reading of it); the value is
      # ancestry against the manifest's remote default branch.
      ancestor_res = Sh.run(
        ["git", "merge-base", "--is-ancestor", manifest.remote_default_branch, "HEAD"],
        chdir: path, envelope: env
      )
      ancestor_of_origin_main = ancestor_res.success?

      record = bead_record(bead, env)
      areas = record[:areas]
      if !record[:available] && tracker_available
        tracker_available = false
        env.warn(
          code: "tracker_unavailable",
          message: "the tracker did not answer for #{bead}; bead status is unknown for this run, " \
                   "so the closed-bead check is reported as a warning and blocks nothing"
        )
      end

      request = nil
      stale = false

      if forge_available
        result = RequestState.query_merged(branch.to_s, env: env)
        if result.available
          if result.merged
            request = { number: result.number, state: Forge::REQUEST_MERGED,
                         head_oid: result.head_oid, merged_at: result.merged_at }
            stale = true
          end
        else
          forge_available = false
          env.warn(
            code: "forge_unavailable",
            message: "the forge CLI is unavailable, falling back to the raw worktree list for request state: #{result.error}"
          )
        end
      end

      # holds_areas distinct from areas is the fix for the 2026-08-05
      # phantom collision: a stale (already-merged) worktree still has the
      # areas its bead is labeled with, but holds none of them - they are
      # free for a new batch to claim.
      holds_areas = stale ? [] : areas

      worktree = {
        path: path,
        branch: branch,
        bead: bead,
        bead_status: record[:status],
        areas: areas,
        dirty: dirty,
        ancestor_of_origin_main: ancestor_of_origin_main,
        request: request,
        stale: stale,
        holds_areas: holds_areas
      }

      [worktree, forge_available, tracker_available]
    end
  end
end

exit WorktreeSurvey.run(ARGV) if __FILE__ == $PROGRAM_NAME

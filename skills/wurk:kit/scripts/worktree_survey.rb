#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/refs"
require_relative "lib/manifest"
require_relative "lib/forge"
require_relative "pr_state"

# WorktreeSurvey is one survey standing in for three near-identical ones:
# /wurk:next Step 2, /wurk:refresh Step 1, and /wurk:cleanup
# Step 1. See statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 2.
module WorktreeSurvey
  class << self
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

    def areas_for(bead, env)
      return [] unless bead

      result = Sh.run(["bd", "show", bead, "--json"], envelope: env)
      return [] unless result.success?

      parsed = JSON.parse(result.out)
      return [] unless parsed.is_a?(Array) && parsed.first

      labels = parsed.first["labels"] || []
      labels.select { |l| l.start_with?("area:") }
    rescue JSON::ParserError
      []
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

      gh_available = true
      degraded = []
      worktrees = []

      rest.each do |entry|
        worktree, gh_available = survey_one(entry, env, manifest, gh_available)
        worktrees << worktree
        degraded << entry[:path] unless gh_available
      end

      env.data[:main_checkout] = main_checkout
      env.data[:worktrees] = worktrees
      env.data[:gh_available] = gh_available
      env.data[:degraded] = degraded

      env.emit(io)
    end

    private

    # Surveys one worktree entry. `gh_available` is the running flag from
    # the caller; once false, no further gh call is attempted for any
    # subsequent worktree ("say so once, not once per worktree" - the
    # warning fires on the call that first discovers gh is down, not
    # again). Returns [worktree_hash, gh_available_after_this_call].
    def survey_one(entry, env, manifest, gh_available)
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

      areas = areas_for(bead, env)

      pr = nil
      stale = false

      if gh_available
        result = PrState.query_merged(branch.to_s, env: env)
        if result.available
          if result.merged
            pr = { number: result.number, state: "MERGED", head_oid: result.head_oid, merged_at: result.merged_at }
            stale = true
          end
        else
          gh_available = false
          env.warn(
            code: "gh_unavailable",
            message: "gh unavailable, falling back to the raw worktree list for PR state: #{result.error}"
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
        areas: areas,
        dirty: dirty,
        ancestor_of_origin_main: ancestor_of_origin_main,
        pr: pr,
        stale: stale,
        holds_areas: holds_areas
      }

      [worktree, gh_available]
    end
  end
end

exit WorktreeSurvey.run(ARGV) if __FILE__ == $PROGRAM_NAME

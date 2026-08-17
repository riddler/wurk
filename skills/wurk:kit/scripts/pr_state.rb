#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/refs"
require_relative "lib/manifest"
require_relative "lib/forge"

# PrState is the one place that knows PR-merge detection is gh-based, and
# that git ancestry is *wrong* here under this repo's rebase-merge-only
# setting.
#
# Wrong alternative #1: `@{upstream}` / `git branch --merged origin/main`.
# Rebase merging replays a branch's commits onto main as new SHAs, so a
# merged branch's tip is *never* an ancestor of main - ancestry-based
# detection silently no-ops forever while looking like it works. Verified on
# PRs #2, #3 and #6 (cleanup-worktrees/SKILL.md L15-38): main carried
# b5e9104/873aa20/96dda3e while the branch tips were
# 53b5ede/638f29c/62f9875, and `--merged` listed only main.
#
# Wrong alternative #2: `origin/main..HEAD` (a commit-range check) to infer
# "nothing left to merge". Same ancestry assumption, same failure.
#
# So: ask GitHub, never git. On `gh` failure or an unauthenticated call this
# script (and PrState.query_merged/beads_for_pr) reports "not available" -
# it must never fall back to ancestry as a substitute.
module PrState
  QueryResult = Struct.new(:available, :merged, :number, :merged_at, :head_oid, :error, keyword_init: true)
  BeadsResult = Struct.new(:available, :beads, :error, keyword_init: true)

  class << self
    # Queries gh for the merged-PR state of `branch`. `available: false`
    # means gh itself failed, was unavailable, or unauthenticated - callers
    # must treat that as "unknown", never as "not merged".
    def query_merged(branch, env: nil)
      result = Sh.run(
        ["gh", "pr", "list", "--state", "merged", "--head", branch,
         "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
        envelope: env
      )

      return QueryResult.new(available: false, merged: nil, error: result.err.to_s.strip) unless result.success?

      text = result.out.to_s.strip
      return QueryResult.new(available: true, merged: false) if text.empty? || text == "null"

      json = JSON.parse(text)
      QueryResult.new(
        available: true,
        merged: true,
        number: json["number"],
        merged_at: json["mergedAt"],
        head_oid: json["headRefOid"]
      )
    rescue JSON::ParserError => e
      QueryResult.new(available: false, merged: nil, error: "unparseable gh output: #{e.message}")
    end

    # Extracts the beads a merged PR's commits reference, via the single
    # Refs definition site (lib/refs.rb) - so this and repo_state.rb's
    # unpushed-commit scan cannot drift.
    def beads_for_pr(number, env: nil)
      result = Sh.run(
        ["gh", "pr", "view", number.to_s, "--json", "commits", "--jq", ".commits[].messageBody"],
        envelope: env
      )

      return BeadsResult.new(available: false, beads: nil, error: result.err.to_s.strip) unless result.success?

      BeadsResult.new(available: true, beads: Refs.beads_from_messages([result.out.to_s]), error: nil)
    end

    def run(argv, io: $stdout)
      parser, _options = Cli.build("pr_state.rb [options] (<branch> | beads <pr-number>)")
      args = Cli.parse!(parser, argv)

      env = Envelope.new(script: "pr_state")

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest
      return env.emit(io) unless Forge.guard!(env, manifest, doing: "PR state")

      if args.first == "beads"
        return run_beads(args[1], env, io, parser)
      end

      run_branch(args.first, env, io, parser)
    end

    private

    def run_beads(number, env, io, parser)
      if number.to_s.strip.empty?
        warn "usage: pr_state.rb beads <pr-number>\n\n#{parser}"
        exit 2
      end

      result = beads_for_pr(number, env: env)
      unless result.available
        env.block!(code: "forge_unavailable", message: "gh pr view failed: #{result.error}")
        return env.emit(io)
      end

      env.data[:number] = number
      env.data[:beads] = result.beads
      env.emit(io)
    end

    def run_branch(branch, env, io, parser)
      if branch.to_s.strip.empty?
        warn "usage: pr_state.rb [options] <branch>\n\n#{parser}"
        exit 2
      end

      result = query_merged(branch, env: env)
      unless result.available
        env.block!(code: "forge_unavailable", message: "gh pr list failed or is unauthenticated: #{result.error}")
        return env.emit(io)
      end

      env.data[:branch] = branch
      env.data[:merged] = result.merged
      if result.merged
        env.data[:number] = result.number
        env.data[:merged_at] = result.merged_at
        env.data[:head_oid] = result.head_oid
      end

      env.emit(io)
    end
  end
end

exit PrState.run(ARGV) if __FILE__ == $PROGRAM_NAME

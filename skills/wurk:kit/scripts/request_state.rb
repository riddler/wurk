#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/refs"
require_relative "lib/manifest"
require_relative "lib/forge"

# RequestState is the one place that knows PR/MR-merge detection is
# forge-based, and that git ancestry is *wrong* here - verified independently
# on GitHub and GitLab.
#
# Wrong alternative #1: `@{upstream}` / `git branch --merged origin/main`.
# Rebase merging replays a branch's commits onto main as new SHAs, so a
# merged branch's tip is *never* an ancestor of main - ancestry-based
# detection silently no-ops forever while looking like it works. Verified on
# GitHub PRs #2, #3 and #6 (cleanup-worktrees/SKILL.md L15-38): main carried
# b5e9104/873aa20/96dda3e while the branch tips were 53b5ede/638f29c/62f9875,
# and `--merged` listed only main. Verified again on GitLab, and more often:
# over the 25 most recent merged MRs per project, the recorded head was NOT an
# ancestor of the target in 19/25 for gitlab-org/cli (merge: squash on), 13/25
# for wireshark/wireshark (fast-forward), 0/25 for freedesktop-sdk/freedesktop-sdk
# (rebase-merge) - the failure isn't specific to one merge setting. Decisive
# case: wireshark/wireshark !26206, MR head 45cc0108 (parent e0127775) landed
# on master as 2a99fbbb (parent a9e15236) with a byte-identical commit
# message; merge_base(45cc0108, master) is e0127775, not 45cc0108. Full method
# and counts: docs/research/260817-wu-mya.2-gitlab-merged-request-detection.md
#
# Wrong alternative #2: `origin/main..HEAD` (a commit-range check) to infer
# "nothing left to merge". Same ancestry assumption, same failure.
#
# Wrong alternative #3: treating "has a merge commit" as the merged signal.
# Under GitLab's fast-forward merge method a merged MR's merge-commit field is
# an empty string, not null or absent - verified on every fast-forward-merged
# MR sampled. The forge's own merged state is the only reliable signal (which
# is why `Forge::REQUEST_MERGED` is GitLab's own spelling of that state; only
# the GitHub side needs a mapping).
#
# So: ask the forge, never git. On a forge-CLI failure or an unauthenticated
# call this script (and RequestState.query_merged/beads_for_pr) reports "not
# available" - it must never fall back to ancestry as a substitute.
#
# worktree_cleanup.rb's patch-equivalence probe is not a counter-example to
# that rule: it runs only after the forge has already said merged, and it can
# only REFUSE a removal, never declare a merge. ADR-0017 states the
# direction-and-power distinction that keeps the two apart.
module RequestState
  QueryResult = Struct.new(:available, :merged, :number, :merged_at, :head_oid, :error, keyword_init: true)
  BeadsResult = Struct.new(:available, :beads, :error, keyword_init: true)

  class << self
    # Queries the forge for the merged-request state of `branch`.
    # `available: false` means the forge CLI itself failed, was unavailable,
    # or unauthenticated - callers must treat that as "unknown", never as
    # "not merged". `kind:` defaults to the manifest's forge, which is what
    # every caller wants; it is a keyword so a test can be explicit.
    def query_merged(branch, env: nil, kind: nil)
      case forge_kind(kind)
      when "gitlab" then query_merged_on_gitlab(branch, env)
      else query_merged_on_github(branch, env)
      end
    end

    # Extracts the beads a merged request's commits reference, via the single
    # Refs definition site (lib/refs.rb) - so this and repo_state.rb's
    # unpushed-commit scan cannot drift.
    def beads_for_pr(number, env: nil, kind: nil)
      case forge_kind(kind)
      when "gitlab" then beads_for_pr_on_gitlab(number, env)
      else beads_for_pr_on_github(number, env)
      end
    end

    def query_merged_on_github(branch, env)
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
      QueryResult.new(available: false, merged: nil, error: "unparseable forge output: #{e.message}")
    end

    def beads_for_pr_on_github(number, env)
      result = Sh.run(
        ["gh", "pr", "view", number.to_s, "--json", "commits", "--jq", ".commits[].messageBody"],
        envelope: env
      )

      return BeadsResult.new(available: false, beads: nil, error: result.err.to_s.strip) unless result.success?

      BeadsResult.new(available: true, beads: Refs.beads_from_messages([result.out.to_s]), error: nil)
    end

    # The GitLab side of the same two questions. Four differences from the
    # GitHub adapter, each verified live in
    # docs/research/260817-wu-mya.2-gitlab-merged-request-detection.md:
    #
    # 1. There is no `--state` flag; merged-only is its own boolean flag, and
    #    the default state is "opened", so the flag is not optional.
    # 2. There is no field allow-list. The list command emits the raw REST
    #    object, so the field names are the API's (`iid`, `merged_at`, `sha`),
    #    and `diff_refs` is not among them on the list payload.
    # 3. `--source-branch` matches on the branch NAME alone, across projects,
    #    so a fork's identically named branch is a false positive. Hence the
    #    same-project filter below.
    # 4. Machine output is emitted on failure too - an error OBJECT where the
    #    success shape is an array, with a non-zero exit - so success is read
    #    off the exit status, never off stdout being parseable. Hence the
    #    `success?` gate first and the "is it an Array" check after.
    #
    # `state == Forge::REQUEST_MERGED` is the only merged signal used here:
    # under a fast-forward merge method the merge-commit field is the empty
    # string, and ancestry is wrong on both forges (see this file's header).
    def query_merged_on_gitlab(branch, env)
      result = Sh.run(
        ["glab", "mr", "list", "--merged", "--source-branch", branch, "--output", "json"],
        envelope: env
      )

      return QueryResult.new(available: false, merged: nil, error: result.err.to_s.strip) unless result.success?

      text = result.out.to_s.strip
      return QueryResult.new(available: true, merged: false) if text.empty? || text == "null"

      requests = JSON.parse(text)
      unless requests.is_a?(Array)
        return QueryResult.new(available: false, merged: nil,
                               error: "unexpected forge output: a list of requests was expected, got #{requests.class}")
      end

      request = select_merged_request(requests)
      return QueryResult.new(available: true, merged: false) unless request

      QueryResult.new(
        available: true,
        merged: true,
        number: request["iid"],
        merged_at: request["merged_at"],
        head_oid: request["sha"]
      )
    rescue JSON::ParserError => e
      QueryResult.new(available: false, merged: nil, error: "unparseable forge output: #{e.message}")
    end

    # DECISION (wu-mya.7), selection when one source branch carries several
    # merged requests: take the one with the greatest `merged_at`, decided in
    # Ruby over the whole list, not the list's first element.
    #
    # This is a real case, not a hypothetical: a renovate branch in
    # gitlab-org/cli carried 23 merged requests at once (research section 1),
    # and the list arrives ordered by `created_at` descending, so its first
    # element is the most recently OPENED request, not the most recently
    # merged. Those differ exactly when an older request is merged after a
    # newer one is opened, which is the normal shape of a long-lived shared
    # branch. The alternative - asking the forge for the order with its
    # order/sort flags and keeping the first element - was rejected for two
    # reasons: the whole list has to be fetched and walked in Ruby anyway for
    # the fork filter below, so server-side ordering buys nothing; and it
    # would put the tie-break in flags whose effect the research could accept
    # but not observe changing the output, where a reader cannot see it.
    # Deciding here costs one pass over a short array and is greppable.
    def select_merged_request(requests)
      merged = requests.select do |request|
        request.is_a?(Hash) && request["state"] == Forge::REQUEST_MERGED && same_project?(request)
      end

      merged.max_by { |request| request["merged_at"].to_s }
    end

    # Discards a request whose source branch lives in a fork: the list filter
    # matches the branch name in any project, so a fork contribution named
    # like a local branch would otherwise report a local branch as merged.
    # Only a MISMATCH is evidence of a fork - an absent id proves nothing, and
    # dropping those would report a merged request as unmerged, the one
    # failure this file exists to prevent.
    def same_project?(request)
      source = request["source_project_id"]
      target = request["target_project_id"]
      return true if source.nil? || target.nil?

      source == target
    end

    # DECISION (wu-mya.7), pagination: the commits request is paginated, at
    # 20 per page by default, so it is always made with pagination on. A
    # branch of more than 20 commits would otherwise silently yield the beads
    # of its newest 20 only - a wrong answer that looks like a right one,
    # since nothing downstream can tell a short branch from a truncated page.
    # The cost is one extra round trip per 20 commits on long branches and
    # none at all on short ones.
    #
    # Paginated output stays a single JSON array: the CLI documents its
    # default output as pretty-printed JSON with "arrays output as a single
    # JSON array" (verified from `glab api --help`, glab 1.117.0), so the
    # pages arrive concatenated into one array rather than as one document
    # per page. The `is_a?(Array)` check below is what would catch that
    # assumption breaking, rather than a truncated read passing silently.
    #
    # This request has no server-side filter flag at all, so message
    # extraction happens in Ruby. That stays inside ADR-0006: `json` is
    # stdlib. `message` here is the full commit message rather than the body
    # alone, which Refs handles unchanged - it anchors per line on the
    # trailer key, and a subject line cannot match it.
    def beads_for_pr_on_gitlab(number, env)
      result = Sh.run(
        ["glab", "api", "--paginate", "projects/:id/merge_requests/#{number}/commits"],
        envelope: env
      )

      return BeadsResult.new(available: false, beads: nil, error: result.err.to_s.strip) unless result.success?

      text = result.out.to_s.strip
      return BeadsResult.new(available: true, beads: [], error: nil) if text.empty?

      commits = JSON.parse(text)
      unless commits.is_a?(Array)
        return BeadsResult.new(available: false, beads: nil,
                               error: "unexpected forge output: a list of commits was expected, got #{commits.class}")
      end

      messages = commits.map { |commit| commit.is_a?(Hash) ? commit["message"].to_s : "" }
      BeadsResult.new(available: true, beads: Refs.beads_from_messages(messages), error: nil)
    rescue JSON::ParserError => e
      BeadsResult.new(available: false, beads: nil, error: "unparseable forge output: #{e.message}")
    end

    def run(argv, io: $stdout)
      parser, _options = Cli.build("request_state.rb [options] (<branch> | beads <pr-number>)")
      args = Cli.parse!(parser, argv)

      env = Envelope.new(script: "request_state")

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest
      return env.emit(io) unless Forge.guard!(env, manifest, doing: "PR state")

      if args.first == "beads"
        return run_beads(args[1], env, io, parser)
      end

      run_branch(args.first, env, io, parser)
    end

    private

    # The forge whose adapter answers a query: the manifest is the authority
    # (every caller has already passed Forge.guard!), and an explicit kind: is
    # the test seam.
    def forge_kind(kind)
      kind || Manifest.current.forge_kind
    end

    def run_beads(number, env, io, parser)
      if number.to_s.strip.empty?
        warn "usage: request_state.rb beads <pr-number>\n\n#{parser}"
        exit 2
      end

      result = beads_for_pr(number, env: env)
      unless result.available
        env.block!(code: "forge_unavailable", message: "the forge request-commits lookup failed: #{result.error}")
        return env.emit(io)
      end

      env.data[:number] = number
      env.data[:beads] = result.beads
      env.emit(io)
    end

    def run_branch(branch, env, io, parser)
      if branch.to_s.strip.empty?
        warn "usage: request_state.rb [options] <branch>\n\n#{parser}"
        exit 2
      end

      result = query_merged(branch, env: env)
      unless result.available
        env.block!(code: "forge_unavailable", message: "the forge request lookup failed or is unauthenticated: #{result.error}")
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

exit RequestState.run(ARGV) if __FILE__ == $PROGRAM_NAME

#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/manifest"
require_relative "lib/forge"

# ReadyIdle lists the open requests (PRs on GitHub, MRs on GitLab) that are
# ready to merge and have sat that way for a while: not a draft, no conflict,
# no reviewer block the forge exposes, a green pipeline, and no activity for
# at least the idle threshold. Each row carries how long it has been idle and
# how far its head is behind the default branch.
#
# Why it exists: an open green request is invisible until someone looks.
# Requests have sat green for over a day with nothing saying so, because no
# report computes idle hours or drift behind the default branch. This script
# is the pure read that answers "what is waiting on a human right now".
#
# Two rules carry the weight, and both are about not lying with an empty
# answer:
#
# 1. A scan that could not finish never reports a list. When the forge read
#    fails, its output does not parse, a per-request read fails, or the list
#    may have been truncated, the envelope blocks `scan_incomplete`,
#    `data.scan_complete` is false, and `data.ready` is ABSENT - not `[]`.
#    An empty list means "nothing is waiting"; a caller that got one from a
#    broken scan would stop looking at exactly the requests this exists to
#    surface.
# 2. Drift is only exact against a fresh fetch. When the fetch is skipped
#    (`--no-fetch`, `--dry-run`) or fails, every row's `drift_lower_bound` is
#    true and a warning says why: the local remote-tracking ref may be behind
#    origin, so `behind` can only undercount.
#
# Read-only: the forge is only listed and viewed, and git only fetches
# (remote-tracking refs, never refs/heads/) and counts. The contract test's
# banned operations do not appear here.
module ReadyIdle
  DEFAULT_IDLE_HOURS = Manifest::DEFAULTS.fetch("forge.ready_idle_hours")

  # The page size of the GitHub list. `gh pr list` has no "everything" flag,
  # so a returned count equal to this limit is read as a possibly truncated
  # scan rather than as the whole set - see `list_on_github`.
  GITHUB_LIST_LIMIT = 500

  GITHUB_FIELDS = %w[number title headRefName headRefOid isDraft mergeable reviewDecision
                     statusCheckRollup updatedAt].join(",")

  # The kit's own pipeline vocabulary, the same for both forges. `none` is a
  # request with no checks or pipeline at all, and it is NOT green: a request
  # nothing has verified is not ready just because nothing has failed.
  PIPELINE_SUCCESS = "success"
  PIPELINE_FAILED = "failed"
  PIPELINE_RUNNING = "running"
  PIPELINE_NONE = "none"

  # GitHub check conclusions and status-context states, upper-cased. The
  # rollup mixes CheckRun entries (`status`, `conclusion`) and StatusContext
  # entries (`state`). A value in neither list below is treated as failed -
  # unknown is never green.
  GITHUB_GREEN = %w[SUCCESS NEUTRAL SKIPPED].freeze
  GITHUB_PENDING = %w[PENDING EXPECTED QUEUED IN_PROGRESS WAITING REQUESTED].freeze

  # GitLab head_pipeline statuses that mean the pipeline ended without
  # passing. Every other non-success status (created, pending, running,
  # manual, scheduled, ...) is still running.
  GITLAB_FAILED = %w[failed canceled canceling].freeze

  # GitLab detailed_merge_status values that are a reviewer's block.
  GITLAB_REVIEW_BLOCKS = %w[requested_changes not_approved].freeze

  # Skip reasons, in the order they are checked. The first one that applies
  # is the one reported, so a request appears in `data.skipped` once.
  SKIP_REASONS = %w[draft conflict mergeability_unknown review_blocked not_idle
                    pipeline_failed pipeline_running no_pipeline].freeze

  # A request normalized out of either forge's payload into the kit's own
  # words. `pipeline` is nil on GitLab until it is read, because the list
  # payload carries none - see `pipeline_on_gitlab`.
  Request = Struct.new(:number, :title, :branch, :head, :draft, :conflict, :mergeability_known,
                       :review_blocked, :pipeline, :updated_at, keyword_init: true)

  # Raised by an adapter when the scan cannot finish. Caught once, in `run`,
  # which turns it into the `scan_incomplete` block.
  class ScanIncomplete < StandardError; end

  class << self
    # `now:` is the clock seam for tests; nil means the wall clock.
    def run(argv, io: $stdout, now: nil)
      options = { fetch: true, repo: nil, idle_hours: nil }
      parser, options = Cli.build("ready_idle.rb [options]", options) do |opts|
        opts.on("--idle-hours N", Float, "idle threshold in hours (default: forge.ready_idle_hours, else 2.0)") do |v|
          options[:idle_hours] = v
        end
        opts.on("--no-fetch", "do not fetch origin first; drift becomes a lower bound") do
          options[:fetch] = false
        end
        opts.on("--repo DIR", "the checkout to scan (default: the working directory)") do |v|
          options[:repo] = v
        end
      end
      args = Cli.parse!(parser, argv)
      usage!(parser, "unexpected argument: #{args.first}") unless args.empty?
      validate_options!(parser, options)

      env = Envelope.new(script: "ready_idle")
      env.data[:scan_complete] = false

      manifest = Manifest.require!(env, start: options[:repo] || Dir.pwd)
      return env.emit(io) unless manifest
      return env.emit(io) unless Forge.guard!(env, manifest, doing: "ready-idle scan")

      scan(env, manifest, options, now || Time.now)
      env.emit(io)
    end

    # The forge-specific list reads. Each returns an array of Request, or
    # raises ScanIncomplete naming what failed.
    def list_requests(kind, env, chdir)
      case kind
      when "gitlab" then list_on_gitlab(env, chdir)
      else list_on_github(env, chdir)
      end
    end

    def list_on_github(env, chdir)
      result = Sh.run(
        ["gh", "pr", "list", "--state", "open", "--limit", GITHUB_LIST_LIMIT.to_s, "--json", GITHUB_FIELDS],
        chdir: chdir, timeout: 120, envelope: env
      )
      raise ScanIncomplete, "gh pr list failed: #{failure_text(result)}" unless result.success?

      requests = parse_array(result.out, "gh pr list")
      if requests.length >= GITHUB_LIST_LIMIT
        raise ScanIncomplete, "gh pr list returned #{requests.length} requests, the list limit, so the list may be truncated"
      end

      requests.map { |raw| request_from_github(raw) }
    end

    def request_from_github(raw)
      raise ScanIncomplete, "gh pr list returned a non-object entry: #{raw.inspect}" unless raw.is_a?(Hash)

      mergeable = raw["mergeable"].to_s.upcase
      Request.new(
        number: raw["number"],
        title: raw["title"].to_s,
        branch: raw["headRefName"].to_s,
        head: raw["headRefOid"].to_s,
        draft: raw["isDraft"] == true,
        conflict: mergeable == "CONFLICTING",
        mergeability_known: %w[MERGEABLE CONFLICTING].include?(mergeable),
        review_blocked: raw["reviewDecision"].to_s.upcase == "CHANGES_REQUESTED",
        pipeline: pipeline_from_rollup(raw["statusCheckRollup"]),
        updated_at: parse_time(raw["updatedAt"], raw["number"])
      )
    end

    # Folds a statusCheckRollup into the kit's pipeline vocabulary. Failed
    # outranks running, which outranks success: one red check makes the
    # request red whatever else is still going.
    def pipeline_from_rollup(rollup)
      entries = Array(rollup)
      return PIPELINE_NONE if entries.empty?

      states = entries.map { |entry| check_state(entry) }
      return PIPELINE_FAILED if states.include?(PIPELINE_FAILED)
      return PIPELINE_RUNNING if states.include?(PIPELINE_RUNNING)

      PIPELINE_SUCCESS
    end

    # One rollup entry. A CheckRun whose status is not COMPLETED has no
    # conclusion yet and is running; otherwise the conclusion (CheckRun) or
    # the state (StatusContext) decides.
    def check_state(entry)
      return PIPELINE_FAILED unless entry.is_a?(Hash)

      status = entry["status"].to_s.upcase
      return PIPELINE_RUNNING if !status.empty? && status != "COMPLETED"

      value = (entry["conclusion"] || entry["state"]).to_s.upcase
      return PIPELINE_RUNNING if value.empty? || GITHUB_PENDING.include?(value)
      return PIPELINE_SUCCESS if GITHUB_GREEN.include?(value)

      PIPELINE_FAILED
    end

    # GitLab emits the raw REST objects, and machine output on failure too
    # (an error object, non-zero exit), so success is read off the exit
    # status first and the Array shape checked after - the same two gates
    # request_state.rb's GitLab adapter uses. `--paginate` keeps the pages
    # one JSON array, so a long list is not truncated at the first page.
    def list_on_gitlab(env, chdir)
      result = Sh.run(
        ["glab", "api", "--paginate", "projects/:id/merge_requests?state=opened"],
        chdir: chdir, timeout: 120, envelope: env
      )
      raise ScanIncomplete, "glab api merge_requests failed: #{failure_text(result)}" unless result.success?

      parse_array(result.out, "glab api merge_requests").map { |raw| request_from_gitlab(raw) }
    end

    def request_from_gitlab(raw)
      raise ScanIncomplete, "glab api merge_requests returned a non-object entry: #{raw.inspect}" unless raw.is_a?(Hash)

      Request.new(
        number: raw["iid"],
        title: raw["title"].to_s,
        branch: raw["source_branch"].to_s,
        head: raw["sha"].to_s,
        draft: raw["draft"] == true || raw["work_in_progress"] == true,
        conflict: raw["has_conflicts"] == true,
        mergeability_known: true,
        review_blocked: GITLAB_REVIEW_BLOCKS.include?(raw["detailed_merge_status"].to_s),
        pipeline: nil,
        updated_at: parse_time(raw["updated_at"], raw["iid"])
      )
    end

    # The list payload carries no pipeline, so one request is read per
    # surviving candidate. Called only after the cheaper disqualifiers, so
    # the read count is the number of plausible rows, not of open requests.
    def pipeline_on_gitlab(number, env, chdir)
      label = "glab api merge_requests/#{number}"
      result = Sh.run(["glab", "api", "projects/:id/merge_requests/#{number}"],
                      chdir: chdir, envelope: env)
      raise ScanIncomplete, "#{label} failed: #{failure_text(result)}" unless result.success?

      payload = parse_json(result.out, label)
      raise ScanIncomplete, "#{label} returned #{payload.class}, not a request object" unless payload.is_a?(Hash)

      pipeline = payload["head_pipeline"]
      return PIPELINE_NONE unless pipeline.is_a?(Hash)

      status = pipeline["status"].to_s
      return PIPELINE_SUCCESS if status == "success"
      return PIPELINE_FAILED if GITLAB_FAILED.include?(status)

      PIPELINE_RUNNING
    end

    private

    def usage!(parser, message)
      warn "#{message}\n\n#{parser}"
      exit 2
    end

    def validate_options!(parser, options)
      hours = options[:idle_hours]
      if !hours.nil? && !(hours.finite? && hours.positive?)
        usage!(parser, "--idle-hours must be a positive number of hours, got #{hours}")
      end

      repo = options[:repo]
      return if repo.nil? || File.directory?(repo)

      usage!(parser, "--repo must be an existing directory, got #{repo}")
    end

    def scan(env, manifest, options, now)
      chdir = options[:repo]
      kind = manifest.forge_kind
      env.data[:forge] = kind
      env.data[:default_branch] = manifest.default_branch
      resolve_threshold(env, manifest, options)
      lower_bound = !fetch_origin(env, options, chdir)

      requests = list_requests(kind, env, chdir)
      ready, skipped = classify(requests, env, kind, chdir, env.data[:idle_hours], now)
      rows = ready.map { |request| row_for(request, env, manifest, chdir, lower_bound, now) }

      env.data[:scan_complete] = true
      env.data[:ready] = rows.sort_by { |row| [-row[:hours_idle], row[:number].to_i] }
      env.data[:skipped] = skipped
    rescue ScanIncomplete => e
      env.data[:scan_complete] = false
      env.data.delete(:ready)
      env.block!(
        code: "scan_incomplete",
        message: "the ready-idle scan could not finish: #{e.message}. Do not read this as zero " \
                 "ready requests - check the forge CLI is installed and authenticated for this repo " \
                 "(and reachable), then rerun"
      )
    end

    # Flag over manifest over the kit default. The source is recorded so a
    # reader can tell a deliberate threshold from the fallback one.
    def resolve_threshold(env, manifest, options)
      if options[:idle_hours]
        env.data[:idle_hours] = options[:idle_hours]
        env.data[:idle_hours_source] = "flag"
      elsif !manifest.dig_raw("forge.ready_idle_hours").nil?
        env.data[:idle_hours] = manifest.ready_idle_hours.to_f
        env.data[:idle_hours_source] = "manifest"
      else
        env.data[:idle_hours] = DEFAULT_IDLE_HOURS
        env.data[:idle_hours_source] = "default"
      end
    end

    # Returns true when the drift numbers are exact, false when they are a
    # lower bound. A dry run records the fetch it would have made and runs
    # nothing; every read still runs because nothing here mutates.
    def fetch_origin(env, options, chdir)
      argv = %w[git fetch origin]
      if options[:dry_run] || !options[:fetch]
        env.commands << Sh.render(argv, chdir: chdir) if options[:dry_run]
        why = options[:dry_run] ? "--dry-run" : "--no-fetch"
        env.data[:fetched] = false
        env.warn(code: "fetch_skipped",
                 message: "origin was not fetched (#{why}), so behind counts are a lower bound; " \
                          "rerun without #{why} for exact drift")
        return false
      end

      result = Sh.run(argv, chdir: chdir, envelope: env)
      env.data[:fetched] = result.success?
      return true if result.success?

      env.warn(code: "fetch_failed",
               message: "git fetch origin failed (#{failure_text(result)}), so behind counts are a lower " \
                        "bound; rerun when origin is reachable for exact drift")
      false
    end

    def classify(requests, env, kind, chdir, threshold, now)
      ready = []
      skipped = []
      requests.each do |request|
        reason = cheap_disqualifier(request, threshold, now)
        if reason.nil?
          request.pipeline = pipeline_on_gitlab(request.number, env, chdir) if kind == "gitlab"
          reason = pipeline_disqualifier(request.pipeline)
        end

        if reason
          skipped << { number: request.number, reason: reason }
        else
          ready << request
        end
      end
      [ready, skipped]
    end

    # Everything decidable from the list payload alone. Idleness is
    # compared on the unrounded hours; the row reports them rounded.
    def cheap_disqualifier(request, threshold, now)
      return "draft" if request.draft
      return "conflict" if request.conflict
      return "mergeability_unknown" unless request.mergeability_known
      return "review_blocked" if request.review_blocked
      return "not_idle" if hours_since(request.updated_at, now) < threshold

      nil
    end

    def pipeline_disqualifier(pipeline)
      case pipeline
      when PIPELINE_SUCCESS then nil
      when PIPELINE_FAILED then "pipeline_failed"
      when PIPELINE_NONE then "no_pipeline"
      else "pipeline_running"
      end
    end

    def row_for(request, env, manifest, chdir, lower_bound, now)
      behind = behind_count(request, env, manifest, chdir)
      {
        number: request.number,
        title: request.title,
        branch: request.branch,
        head: request.head,
        hours_idle: hours_since(request.updated_at, now).round(1),
        behind: behind,
        pipeline: request.pipeline,
        drift_lower_bound: lower_bound || behind.nil?
      }
    end

    # Commits on the remote default branch that the request's head lacks.
    # A head that is not in the local object store (a fork's branch, or a
    # push since the last fetch) makes rev-list fail; that row gets a null
    # count rather than a guess.
    def behind_count(request, env, manifest, chdir)
      remote = manifest.remote_default_branch
      result = Sh.run(["git", "rev-list", "--count", "#{request.head}..#{remote}"],
                      chdir: chdir, envelope: env)
      count = result.success? ? Integer(result.out.to_s.strip, exception: false) : nil
      return count unless count.nil?

      env.warn(code: "drift_unknown",
               message: "could not count commits behind #{remote} for request #{request.number} " \
                        "(head #{request.head} or #{remote} is not present locally); fetch origin " \
                        "and the request's branch, then rerun")
      nil
    end

    def hours_since(time, now)
      (now - time) / 3600.0
    end

    def parse_time(value, number)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      raise ScanIncomplete, "request #{number} has no parseable updated-at timestamp (#{value.inspect})"
    end

    def parse_json(text, label)
      JSON.parse(text.to_s)
    rescue JSON::ParserError => e
      raise ScanIncomplete, "#{label} printed unparseable output: #{e.message}"
    end

    def parse_array(text, label)
      parsed = parse_json(text, label)
      return parsed if parsed.is_a?(Array)

      raise ScanIncomplete, "#{label} printed #{parsed.class}, not a list of requests"
    end

    def failure_text(result)
      return "timed out" if result.timed_out?

      text = result.err.to_s.strip
      text.empty? ? "exit #{result.status && result.status.exitstatus}" : text
    end
  end
end

exit ReadyIdle.run(ARGV) if __FILE__ == $PROGRAM_NAME

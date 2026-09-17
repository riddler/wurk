#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require_relative "lib/envelope"
require_relative "lib/cli"
require_relative "lib/user_config"

# SessionMetrics turns Claude Code session transcripts into harness metrics:
# how many tool calls ran and how many came back an error, which skills
# fired, how many tokens each model burned, and where a session sat still.
#
# Why it exists: every harness-improvement decision in this repo today rests
# on prose evidence - a journal line, a report, a retro bead. Prose cannot
# answer "is the failure rate going up" or "which tool is the expensive one",
# and a decision that cannot be checked against a number is a decision that
# gets re-argued. This script is the measured channel beside the written one.
#
# It is read-only in the strongest sense the kit has: it opens transcripts,
# counts, and emits an envelope of counts. It never writes a transcript,
# never shells out, never calls the network, and never puts a line of session
# CONTENT into its output. What leaves here is names and numbers - tool
# names, skill names, model ids, counts, durations, session ids - because
# the envelope is read by a conductor and may land in a journal.
#
# Two subcommands:
#
#   report   every metric, per session and in total.
#   signals  only the items over a threshold, so a healthy window emits an
#            empty list. This is the one a scheduler polls.
#
# THE THREE MEASUREMENT RULES
#
# A naive "gap between consecutive records" stall metric is wrong in three
# separate ways, and each way produces a number that looks plausible:
#
# 1. FLOOR AND CEILING. A gap under the floor is ordinary latency - a model
#    thinking, a gate running. A gap over the ceiling is a human who closed
#    the laptop and came back tomorrow; counting that as a stall makes an
#    overnight break the largest incident in the window. Only a gap between
#    the two is a stall.
#
# 2. TURN BOUNDARY. A gap that ends at a fresh user turn is idle time
#    BETWEEN turns - the session was waiting for a person, which is not the
#    harness stalling. But a user record is not automatically a fresh turn:
#    a record whose content carries tool_result blocks is the harness
#    handing a tool's output back mid-turn, and a long gap before that is
#    exactly the stall worth seeing. The distinction is the content, not
#    the record type.
#
# 3. AGENT VS INTERACTIVE. In an interactive session the gaps are human
#    think time and mean nothing about the harness. In an agent session
#    nobody is thinking, so the same gap is a real stall. They are reported
#    separately and only the agent ones become signals.
#
# Parsing is defensive throughout: an unknown field is ignored, a malformed
# line is counted and skipped, an unreadable file is a warning, and a record
# with no usable timestamp is left out of the gap pass rather than crashing
# it. A transcript is an append-only log written by a program that ships
# faster than this one; it will grow fields, and none of them are a reason
# for a metrics run to die.
module SessionMetrics
  # Where transcripts live, relative to the machine's home directory.
  DEFAULT_SUBDIR = File.join(".claude", "projects")

  # Rule 1. Below the floor is latency; at or above the ceiling is a human
  # closing and resuming the session.
  STALL_FLOOR_SECONDS = 300
  STALL_CEILING_SECONDS = 4 * 60 * 60

  # The failure-rate threshold, and the minimum sample it needs. One error
  # out of two results is a 50% failure rate and means nothing.
  FAILURE_RATE_THRESHOLD = 0.20
  FAILURE_RATE_MIN_RESULTS = 5

  # Record types that count as session activity for the gap pass. The
  # transcript carries other record kinds - editor state, queue bookkeeping,
  # attachments - and a gap is about the conversation, not about them.
  CONVERSATION_TYPES = %w[user assistant system].freeze

  # Rule 3's human evidence. A prompt source outside this list is something
  # other than a person at a keyboard; an ABSENT prompt source is treated as
  # human, because an older transcript that never wrote the field must not
  # be reclassified as automation on the strength of a missing key.
  HUMAN_PROMPT_SOURCES = %w[typed suggestion_accepted].freeze

  # Rule 3's blind spot, and the minimum sample that makes it legible. The
  # classifier reads fields this kit does not own, and the conservative
  # reading of an absent `promptSource` is indistinguishable from the
  # reading of a transcript writer that stopped emitting it: every session
  # classifies interactive, every agent stall disappears, and the window
  # reports healthy because it is blind. Below this many transcripts, a
  # window carrying no classification evidence at all is ordinary - a
  # handful of old files, or one hand-made fixture - so the guard needs a
  # sample for the same reason the failure rate does.
  CLASSIFICATION_MIN_TRANSCRIPTS = 5

  # The tool whose calls name a skill, and the input key carrying the name.
  SKILL_TOOL = "Skill"
  SKILL_INPUT_KEY = "skill"

  # usage field -> the token bucket it feeds.
  TOKEN_FIELDS = {
    "input_tokens" => "input",
    "output_tokens" => "output",
    "cache_creation_input_tokens" => "cache_creation",
    "cache_read_input_tokens" => "cache_read"
  }.freeze

  TOKEN_BUCKETS = TOKEN_FIELDS.values.freeze

  # price component -> the token bucket it prices. Prices are quoted per
  # million tokens (see docs/machine-config.md).
  PRICE_COMPONENTS = {
    "input" => "input",
    "output" => "output",
    "cache_write" => "cache_creation",
    "cache_read" => "cache_read"
  }.freeze

  TOKENS_PER_PRICE_UNIT = 1_000_000.0

  class << self
    # The default transcripts root for this machine. HOME-anchored, like the
    # machine config itself: there is one home directory and no walk-up.
    def default_root(home = ENV["HOME"] || Dir.home)
      File.join(home, DEFAULT_SUBDIR)
    end

    # Every transcript under `root`, or the single `file` when one is named.
    # A missing root is an empty list, not an error - "this machine has no
    # transcripts" is a complete answer.
    def transcript_paths(root: nil, file: nil)
      return [file] if file

      return [] unless root && Dir.exist?(root)

      Dir.glob(File.join(root, "**", "*.jsonl")).sort
    end

    # Reads one transcript into a summary hash. Never raises on content: a
    # line that is not JSON, or is JSON but not an object, is counted in
    # `malformed_lines` and skipped.
    # `evidence`, when given, is an array the classification-availability
    # pass appends one boolean to per transcript read. It rides beside the
    # summary rather than inside it: the question it answers is about the
    # WRITER of the file, not about the window's numbers, and the summary
    # shape is read by callers that have no use for it.
    def read_session(path, since: nil, evidence: nil)
      records = []
      malformed = 0

      File.foreach(path) do |line|
        next if line.strip.empty?

        record = parse_line(line)
        if record.nil?
          malformed += 1
          next
        end
        records << record
      end

      evidence << classification_evidence?(records) unless evidence.nil?
      summarize(path, records, malformed, since)
    end

    # nil for anything that is not a JSON object - the caller counts it.
    def parse_line(line)
      parsed = JSON.parse(line)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError, ArgumentError
      nil
    end

    def summarize(path, records, malformed, since)
      timed = records.map { |r| [r, record_time(r)] }
      timed = timed.select { |pair| pair[1].nil? || pair[1] >= since } if since

      kept = timed.map { |pair| pair[0] }

      summary = {
        "session" => session_id(path, kept),
        "project" => File.basename(File.dirname(path)),
        "path" => path,
        "kind" => classify(kept),
        "records" => kept.length,
        "malformed_lines" => malformed
      }

      summary.merge!(tool_counts(kept))
      summary["skills"] = skill_counts(kept)
      summary["tokens"] = token_counts(kept)
      summary.merge!(gap_counts(timed.select { |pair| pair[1] }, summary["kind"]))
      summary["first_seen"] = iso(timed.map { |pair| pair[1] }.compact.min)
      summary["last_seen"] = iso(timed.map { |pair| pair[1] }.compact.max)
      summary
    end

    # The session id the transcript claims, falling back to its filename.
    # The filename is the id in practice; the fallback is for a hand-made or
    # concatenated file.
    def session_id(path, records)
      claimed = records.map { |r| r["sessionId"] }.compact.first
      claimed.is_a?(String) && !claimed.strip.empty? ? claimed : File.basename(path, ".jsonl")
    end

    def record_time(record)
      stamp = record["timestamp"]
      return nil unless stamp.is_a?(String)

      Time.parse(stamp)
    rescue ArgumentError, TypeError
      nil
    end

    def iso(time)
      time && time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    # --- rule 3: agent vs interactive ---------------------------------------
    #
    # Interactive unless the transcript positively shows automation and shows
    # no human. The asymmetry is deliberate and it is the safe direction: a
    # session wrongly called "agent" manufactures stall signals out of a
    # person's lunch break, while one wrongly called "interactive" only
    # withholds a signal. When the evidence is thin, withhold.

    def classify(records)
      starts = records.select { |r| turn_start?(r) }
      human = starts.any? do |r|
        !r.key?("promptSource") || HUMAN_PROMPT_SOURCES.include?(r["promptSource"])
      end
      return "interactive" if human

      automation = starts.any? || records.any? { |r| r["isSidechain"] == true }
      automation ? "agent" : "interactive"
    end

    # Whether this transcript carries anything the classifier can read at
    # all. `promptSource` and `isSidechain` are written by the transcript
    # writer, not by this kit, and the classifier's conservative default
    # means their DISAPPEARANCE is silent: every session would read
    # interactive and every agent stall would vanish, leaving a window that
    # looks healthy because nothing in it could be measured. Presence is
    # what is checked, not value - a `promptSource` of any kind proves the
    # writer still emits the field, which is the only thing this answers.
    #
    # The whole file is checked, not the `--since` slice: "does the writer
    # emit this field" is a fact about the file, and a narrow window that
    # happens to contain no turn start says nothing either way.
    def classification_evidence?(records)
      records.any? { |r| r.key?("promptSource") || r["isSidechain"] == true }
    end

    # --- rule 2: turn boundary ----------------------------------------------
    #
    # A fresh user turn: a user record whose content carries no tool_result
    # block. A user record that DOES carry one is the harness returning a
    # tool's output mid-turn, and counts like any other activity.

    def turn_start?(record)
      record["type"] == "user" && !tool_result_blocks(record).any?
    end

    def tool_result_blocks(record)
      content_blocks(record).select { |b| b["type"] == "tool_result" }
    end

    def content_blocks(record)
      message = record["message"]
      return [] unless message.is_a?(Hash)

      content = message["content"]
      return [] unless content.is_a?(Array)

      content.select { |b| b.is_a?(Hash) }
    end

    # --- tool calls and failures --------------------------------------------

    def tool_counts(records)
      calls = Hash.new(0)
      results = 0
      errors = 0

      records.each do |record|
        content_blocks(record).each do |block|
          case block["type"]
          when "tool_use"
            name = block["name"]
            calls[name.is_a?(String) && !name.empty? ? name : "(unnamed)"] += 1
          when "tool_result"
            results += 1
            errors += 1 if block["is_error"] == true
          end
        end
      end

      {
        "tool_calls" => sort_counts(calls),
        "tool_calls_total" => calls.values.inject(0) { |a, b| a + b },
        "tool_results" => results,
        "tool_errors" => errors,
        "tool_failure_rate" => rate(errors, results)
      }
    end

    def skill_counts(records)
      fired = Hash.new(0)
      records.each do |record|
        content_blocks(record).each do |block|
          next unless block["type"] == "tool_use" && block["name"] == SKILL_TOOL

          input = block["input"]
          name = input.is_a?(Hash) ? input[SKILL_INPUT_KEY] : nil
          fired[name.is_a?(String) && !name.empty? ? name : "(unnamed)"] += 1
        end
      end
      sort_counts(fired)
    end

    # --- tokens --------------------------------------------------------------

    def token_counts(records)
      by_model = {}
      records.each do |record|
        message = record["message"]
        next unless message.is_a?(Hash)

        usage = message["usage"]
        next unless usage.is_a?(Hash)

        model = message["model"]
        model = "(unknown)" unless model.is_a?(String) && !model.empty?
        bucket = by_model[model] ||= empty_tokens
        TOKEN_FIELDS.each do |field, name|
          value = usage[field]
          bucket[name] += value if value.is_a?(Integer)
        end
      end
      by_model
    end

    def empty_tokens
      TOKEN_BUCKETS.inject({}) { |h, name| h.merge(name => 0) }
    end

    # --- rule 1 + rule 2: gaps ----------------------------------------------
    #
    # `timed` is [record, Time] pairs; only conversation records participate.
    # The record that ENDS a gap decides what the gap was, which is what
    # makes rule 2 expressible at all.

    def gap_counts(timed, session_kind)
      ordered = timed.select { |pair| CONVERSATION_TYPES.include?(pair[0]["type"]) }
      ordered = ordered.each_with_index.sort_by { |pair, index| [pair[1], index] }.map { |pair, _i| pair }

      stalls = []
      idle_between_turns = 0
      resumptions = 0

      ordered.each_cons(2) do |(_prev, prev_time), (record, time)|
        seconds = (time - prev_time).to_i
        next if seconds < STALL_FLOOR_SECONDS

        if seconds >= STALL_CEILING_SECONDS
          resumptions += 1
          next
        end

        if turn_start?(record)
          idle_between_turns += 1
          next
        end

        stalls << { "seconds" => seconds, "at" => iso(time), "kind" => gap_kind(session_kind, record) }
      end

      {
        "stalls" => stalls,
        "agent_stalls" => stalls.count { |s| s["kind"] == "agent" },
        "interactive_stalls" => stalls.count { |s| s["kind"] == "interactive" },
        "idle_between_turns" => idle_between_turns,
        "resumptions" => resumptions
      }
    end

    # A sidechain record belongs to a subagent whatever the session around it
    # is, so its gaps are agent gaps even inside an interactive session.
    def gap_kind(session_kind, record)
      record["isSidechain"] == true ? "agent" : session_kind
    end

    # --- totals --------------------------------------------------------------

    def totals(sessions)
      calls = Hash.new(0)
      skills = Hash.new(0)
      tokens = {}
      results = 0
      errors = 0

      sessions.each do |s|
        s["tool_calls"].each { |name, n| calls[name] += n }
        s["skills"].each { |name, n| skills[name] += n }
        s["tokens"].each do |model, buckets|
          bucket = tokens[model] ||= empty_tokens
          TOKEN_BUCKETS.each { |name| bucket[name] += buckets[name].to_i }
        end
        results += s["tool_results"]
        errors += s["tool_errors"]
      end

      {
        "sessions" => sessions.length,
        "agent_sessions" => sessions.count { |s| s["kind"] == "agent" },
        "interactive_sessions" => sessions.count { |s| s["kind"] == "interactive" },
        "records" => sessions.inject(0) { |a, s| a + s["records"] },
        "malformed_lines" => sessions.inject(0) { |a, s| a + s["malformed_lines"] },
        "tool_calls" => sort_counts(calls),
        "tool_calls_total" => calls.values.inject(0) { |a, b| a + b },
        "tool_results" => results,
        "tool_errors" => errors,
        "tool_failure_rate" => rate(errors, results),
        "skills" => sort_counts(skills),
        "tokens" => tokens,
        "agent_stalls" => sessions.inject(0) { |a, s| a + s["agent_stalls"] },
        "interactive_stalls" => sessions.inject(0) { |a, s| a + s["interactive_stalls"] },
        "idle_between_turns" => sessions.inject(0) { |a, s| a + s["idle_between_turns"] },
        "resumptions" => sessions.inject(0) { |a, s| a + s["resumptions"] }
      }
    end

    # --- cost ----------------------------------------------------------------
    #
    # The kit ships NO price table. Prices change, they differ per account,
    # and a number baked into a repo is a number that is silently wrong
    # later - so an absent table means cost is null, never a guess, and a
    # model the table does not cover makes the total null rather than
    # quietly pricing part of the window.

    def cost(tokens_by_model, prices)
      by_model = {}
      unpriced = []
      total = 0.0

      tokens_by_model.each do |model, buckets|
        price = prices[model]
        amount = price.is_a?(Hash) ? price_for(buckets, price) : nil
        if amount.nil?
          unpriced << model
          by_model[model] = nil
        else
          by_model[model] = round_cents(amount)
          total += amount
        end
      end

      {
        "currency" => "USD",
        "priced" => prices.any?,
        "by_model" => by_model,
        "unpriced_models" => unpriced.sort,
        "total" => (prices.any? && unpriced.empty? && !tokens_by_model.empty?) ? round_cents(total) : nil
      }
    end

    # nil when a bucket with tokens in it has no price component. A zero
    # bucket needs no price: a model billed nothing for cache reads in this
    # window is fully priced without a cache_read entry.
    def price_for(buckets, price)
      amount = 0.0
      PRICE_COMPONENTS.each do |component, bucket_name|
        count = buckets[bucket_name].to_i
        next if count.zero?

        per_million = price[component]
        return nil unless per_million.is_a?(Numeric)

        amount += (count / TOKENS_PER_PRICE_UNIT) * per_million
      end
      amount
    end

    def round_cents(amount)
      (amount * 10_000).round / 10_000.0
    end

    # --- the telemetry sink --------------------------------------------------
    #
    # An opt-in hook may write error events to a path named in the machine
    # config. The path is read ABSENT-SAFE on purpose: the hook ships after
    # this script, and a configured-but-not-yet-written sink is the normal
    # state, not a fault.

    def error_events(path, since: nil)
      result = { "path" => path, "exists" => false, "count" => 0, "malformed_lines" => 0 }
      return result unless path && File.file?(path)

      result["exists"] = true
      File.foreach(path) do |line|
        next if line.strip.empty?

        record = parse_line(line)
        if record.nil?
          result["malformed_lines"] += 1
          next
        end
        next unless error_event?(record)

        time = record_time(record)
        next if since && time && time < since

        result["count"] += 1
      end
      result
    rescue SystemCallError, IOError
      result
    end

    # The sink's shape is owned by whatever writes it; this is the smallest
    # agreement that lets a count exist before that writer does.
    def error_event?(record)
      record["is_error"] == true || record["level"] == "error"
    end

    # --- signals -------------------------------------------------------------
    #
    # A session id does NOT identify a transcript. A parent session and the
    # sidechain files its subagents write all carry the same `sessionId`, so
    # one window can produce several signal items keyed alike with different
    # numbers behind them. Each item is accurate per transcript, and a reader
    # keying on the session id reads the set as one finding sighted twice -
    # which matters, because a recurrence bar counts INDEPENDENT runs and
    # two items off one session are not two runs.
    #
    # So an item names both: the session id it belongs to and the transcript
    # it was measured from, and `sessions_by_id` below gives the reader who
    # keys on the session id exactly one row. Neither reader has to know
    # about the other's key.

    def signals(sessions, events, root: nil)
      items = []

      sessions.each do |s|
        if s["tool_results"] >= FAILURE_RATE_MIN_RESULTS && s["tool_failure_rate"].to_f >= FAILURE_RATE_THRESHOLD
          items << {
            "kind" => "tool_failure_rate",
            "session" => s["session"],
            "transcript" => relative_transcript(s["path"], root),
            "project" => s["project"],
            "results" => s["tool_results"],
            "errors" => s["tool_errors"],
            "rate" => s["tool_failure_rate"]
          }
        end

        agent = s["stalls"].select { |g| g["kind"] == "agent" }
        next if agent.empty?

        items << {
          "kind" => "agent_stall",
          "session" => s["session"],
          "transcript" => relative_transcript(s["path"], root),
          "project" => s["project"],
          "count" => agent.length,
          "longest_seconds" => agent.map { |g| g["seconds"] }.max,
          "latest_at" => agent.map { |g| g["at"] }.compact.max
        }
      end

      if events["count"].positive?
        items << { "kind" => "error_events", "path" => events["path"], "count" => events["count"] }
      end

      items
    end

    # A transcript path as the reader should quote it: relative to the
    # transcripts root, which is the form that is stable across machines and
    # short enough to sit in a signal item. Anything outside the root - and
    # everything under `--file`, which has no root - is left exactly as it
    # came in rather than rewritten into a `../..` walk that identifies
    # nothing. A summary with no path at all answers nil.
    def relative_transcript(path, root)
      return nil unless path.is_a?(String)
      return path unless root.is_a?(String) && !root.empty?

      prefix = root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
      path.start_with?(prefix) ? path[prefix.length..] : path
    end

    # One row per session id, with the per-transcript detail nested inside
    # it. The row's counts are the session's - summed across every transcript
    # that claims the id - so a reader keying on the session id gets one row
    # and one set of numbers, and a reader who needs to know which file a
    # number came from reads the nested list.
    #
    # Deliberately NOT rolled up: `kind`. Rule 3's classification is per
    # transcript by construction (a sidechain file classifies differently
    # from the parent it belongs to), and a session-level `kind` would have
    # to invent a tie-break that no caller asked for. The agent and
    # interactive stall counts are already reported apart, which is what a
    # caller actually reads.
    #
    # Rows keep the order of the sessions handed in, which the CLI has
    # already sorted, so two runs over one window are byte-identical.
    def sessions_by_id(sessions, root: nil)
      rows = {}

      sessions.each do |s|
        row = rows[s["session"]] ||= {
          "session" => s["session"],
          "project" => s["project"],
          "transcript_count" => 0,
          "records" => 0,
          "tool_results" => 0,
          "tool_errors" => 0,
          "agent_stalls" => 0,
          "interactive_stalls" => 0,
          "transcripts" => []
        }

        row["transcript_count"] += 1
        row["records"] += s["records"].to_i
        row["tool_results"] += s["tool_results"].to_i
        row["tool_errors"] += s["tool_errors"].to_i
        row["agent_stalls"] += s["agent_stalls"].to_i
        row["interactive_stalls"] += s["interactive_stalls"].to_i
        row["transcripts"] << {
          "transcript" => relative_transcript(s["path"], root),
          "kind" => s["kind"],
          "records" => s["records"],
          "tool_results" => s["tool_results"],
          "tool_errors" => s["tool_errors"],
          "agent_stalls" => s["agent_stalls"],
          "first_seen" => s["first_seen"],
          "last_seen" => s["last_seen"]
        }
      end

      rows.each_value do |row|
        seen = row["transcripts"]
        row["tool_failure_rate"] = rate(row["tool_errors"], row["tool_results"])
        row["first_seen"] = seen.map { |t| t["first_seen"] }.compact.min
        row["last_seen"] = seen.map { |t| t["last_seen"] }.compact.max
      end

      rows.values
    end

    # --- small helpers -------------------------------------------------------

    def rate(errors, results)
      return nil if results.zero?

      ((errors.to_f / results) * 10_000).round / 10_000.0
    end

    # Descending by count, then by name, so two runs over the same window
    # produce byte-identical output.
    def sort_counts(counts)
      counts.sort_by { |name, n| [-n, name] }.inject({}) { |h, (name, n)| h.merge(name => n) }
    end
  end
end

# The CLI: `session_metrics.rb <report|signals> [--dir DIR] [--file PATH]
# [--since ISO8601] [--max-sessions N]`. Read-only, so no --dry-run applies.
module SessionMetricsCli
  SUBCOMMANDS = %w[report signals].freeze
  USAGE = "session_metrics.rb <report|signals> [--dir DIR] [--file PATH] " \
          "[--since ISO8601] [--max-sessions N]"

  # How many per-session rows `report` includes before it truncates. The
  # totals are never truncated; only the detail rows are, because a machine
  # with a year of transcripts would otherwise put megabytes through a
  # contract that promises ONE JSON object.
  DEFAULT_MAX_SESSIONS = 50

  class << self
    def run(argv, io: $stdout)
      argv = argv.dup
      subcommand = argv.shift
      unless SUBCOMMANDS.include?(subcommand)
        warn "usage: #{USAGE}"
        exit 2
      end

      options = { max_sessions: DEFAULT_MAX_SESSIONS }
      parser, options = Cli.build(USAGE, options) do |opts|
        opts.on("--dir DIR", "transcripts root (default ~/#{SessionMetrics::DEFAULT_SUBDIR})") { |v| options[:dir] = v }
        opts.on("--file PATH", "read this one transcript instead of a root") { |v| options[:file] = v }
        opts.on("--since ISO8601", "ignore records older than this") { |v| options[:since] = v }
        opts.on("--max-sessions N", Integer, "per-session rows in report (0 = all)") { |v| options[:max_sessions] = v }
      end
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "session_metrics")
      env.data[:subcommand] = subcommand

      user_config = UserConfig.require!(env)
      return env.emit(io) unless user_config

      since = parse_since(env, options[:since])
      return env.emit(io) if since == :invalid

      paths = resolve_paths(env, options)
      return env.emit(io) if paths == :invalid

      evidence = []
      sessions = read_sessions(env, paths, since, evidence)
      events = SessionMetrics.error_events(user_config.metrics_error_events_path, since: since)

      env.data[:window] = {
        "root" => options[:file] ? nil : root_for(options),
        "file" => options[:file],
        "since" => since ? since.utc.strftime("%Y-%m-%dT%H:%M:%SZ") : nil,
        "transcripts" => paths.length
      }

      totals = SessionMetrics.totals(sessions)
      env.data[:totals] = totals
      env.data[:cost] = SessionMetrics.cost(totals["tokens"], user_config.metrics_prices)
      env.data[:error_events] = events

      warn_about_prices(env, env.data[:cost])
      warn_about_malformed(env, totals)
      warn_about_classification(env, evidence)

      root = options[:file] ? nil : root_for(options)

      case subcommand
      when "report" then add_report(env, sessions, options, root)
      when "signals" then add_signals(env, sessions, events, root)
      end

      env.emit(io)
    end

    private

    def root_for(options)
      options[:dir] || SessionMetrics.default_root
    end

    def resolve_paths(env, options)
      if options[:file]
        unless File.file?(options[:file])
          env.block!(code: "transcript_missing", message: "no transcript at #{options[:file]}")
          return :invalid
        end
        return [options[:file]]
      end

      root = root_for(options)
      unless Dir.exist?(root)
        env.warn(code: "transcripts_root_missing", message: "no transcripts directory at #{root}")
        return []
      end

      SessionMetrics.transcript_paths(root: root)
    end

    def parse_since(env, raw)
      return nil if raw.nil?

      Time.parse(raw)
    rescue ArgumentError, TypeError
      env.block!(code: "since_unparseable", message: "--since is not a parseable timestamp")
      :invalid
    end

    def read_sessions(env, paths, since, evidence = nil)
      sessions = []
      paths.each do |path|
        begin
          sessions << SessionMetrics.read_session(path, since: since, evidence: evidence)
        rescue SystemCallError, IOError => e
          env.warn(code: "transcript_unreadable", message: "#{path}: #{e.class}")
        end
      end
      sessions.sort_by { |s| [s["last_seen"].to_s, s["session"].to_s] }.reverse
    end

    # The rollup is built from the rows that are already in the envelope -
    # here the ones that survived the cap, in `add_signals` the sessions the
    # emitted items name - so it can never push an envelope past the size
    # `--max-sessions` was set to hold. A rollup over the untruncated list
    # would put back exactly the rows the cap just removed.
    def add_report(env, sessions, options, root)
      limit = options[:max_sessions].to_i
      shown = limit.positive? ? sessions.first(limit) : sessions
      env.data[:sessions] = shown
      env.data[:sessions_by_id] = SessionMetrics.sessions_by_id(shown, root: root)
      return unless shown.length < sessions.length

      env.warn(code: "sessions_truncated",
               message: "showing #{shown.length} of #{sessions.length} sessions; pass --max-sessions 0 for all")
    end

    def add_signals(env, sessions, events, root)
      items = SessionMetrics.signals(sessions, events, root: root)
      env.data[:signals] = items

      ids = items.map { |item| item["session"] }.compact
      signalling = sessions.select { |s| ids.include?(s["session"]) }
      env.data[:sessions_by_id] = SessionMetrics.sessions_by_id(signalling, root: root)
    end

    def warn_about_prices(env, cost)
      return if cost["priced"] && cost["unpriced_models"].empty?

      message =
        if cost["priced"]
          "no price for #{cost['unpriced_models'].join(', ')}; total cost is null"
        else
          "no metrics.prices in the machine config; cost is null (see docs/machine-config.md)"
        end
      env.warn(code: "cost_unavailable", message: message)
    end

    def warn_about_malformed(env, totals)
      return if totals["malformed_lines"].zero?

      env.warn(code: "malformed_lines",
               message: "#{totals['malformed_lines']} transcript lines did not parse and were skipped")
    end

    # The agent-vs-interactive rule reads fields this kit does not own, so
    # it can go blind without failing: if the transcript writer stops
    # emitting promptSource, every session classifies interactive, every
    # agent stall disappears, and `signals` answers with the same empty
    # list a genuinely healthy window produces. This is the one thing that
    # tells those two empty lists apart, which is why it warns rather than
    # blocks - the counts in the envelope are still true, it is only the
    # classification that has nothing behind it.
    def warn_about_classification(env, evidence)
      return if evidence.length < SessionMetrics::CLASSIFICATION_MIN_TRANSCRIPTS
      return if evidence.any?

      env.warn(code: "agent_classification_unavailable",
               message: "none of the #{evidence.length} transcripts in this window carries promptSource " \
                        "or isSidechain, so every session classified interactive and no agent stall can " \
                        "be reported; the transcript writer may no longer emit promptSource - re-verify " \
                        "the classification rule against a current transcript before trusting an empty " \
                        "signals list")
    end
  end
end

exit SessionMetricsCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

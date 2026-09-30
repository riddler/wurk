#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require_relative "lib/envelope"
require_relative "lib/cli"
require_relative "lib/user_config"
require_relative "lib/typesafe"
require_relative "lib/finding_severity"

# The finding_severity Jev site: after a pre-request review round, count the
# round's findings by level for the worker's report (data.findings_by_level,
# copied into reviewRound.findingsByLevel) and, when the site is not off, ask
# Jev for each finding's severity beside the reporting agent's own rank. The
# contract is kit REFERENCE.md's "`finding_severity.rb`: the finding_severity
# Jev site"; the client contract it builds on is "typesafe.rb: the Jev
# client and the call-site contract".
#
# One deliberate difference from report_triage.rb: the count is code's job
# and exists in every mode, so off still reads the findings file - locally,
# to count. Off never touches the key, the ledger, the logs or the network.
# Every path but a usage error or an invalid machine config exits 0. No
# manifest and no Sh: the only external effect is the library's HTTPS
# requests. run returns the exit code and never calls exit.
module FindingSeverityCli
  USAGE = <<~TEXT
    usage: finding_severity.rb --findings PATH --source LABEL [--threshold N] [--dry-run]

    Count a review round's findings by level, and (unless the site is off) ask
    Jev each finding's severity beside the reporting agent's own rank. The field
    a caller copies into its report is data.findings_by_level. A critic's
    must-fix is never downgraded; only on mode with a threshold met can Jev
    raise a level. Exit 0 on every fallback; 1 only for an invalid machine
    config; 2 for usage.

    --findings PATH  a JSON array of the round's findings, one object each:
                     {"agent", "rank", "mustFix", "text"} (see REFERENCE.md)
    --source LABEL   the text's source label, e.g. repo:<repo directory basename>
    --threshold N    the eval tooling's enabled threshold for data.threshold_key,
                     a number in (0, 1]; without one, on mode raises nothing
    --dry-run        show the first request with Authorization redacted; send
                     and write nothing
  TEXT
  HELP_FLAGS = %w[--help -h].freeze
  REQUEST_COMMAND = "POST #{Typesafe::ENDPOINT}"
  # Outcomes a live call reaches only by sending the request. Mirrors
  # TypesafeCli::SENT (the test asserts they match).
  SENT = %w[ok unauthorized rejected rate_limited overloaded other_status
            timeout transport undecodable model_mismatch].freeze
  # Requests one invocation may send. A round with more findings than this
  # falls back (reason call_cap) for the rest: one call per finding, under a
  # per-site deadline each, must stay a bounded step.
  MAX_CALLS = 25

  class << self
    def run(argv, io: $stdout, http_class: Net::HTTP)
      argv = argv.dup
      return help(io) if (argv & HELP_FLAGS).any?

      options, code = parse(argv)
      return code if code

      env = Envelope.new(script: "finding_severity")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      severity(env, config, options, http_class)
      env.emit(io)
    end

    private

    def help(io)
      io.puts USAGE
      0
    end

    # Exit 2, plain text on stderr, no envelope. Fixed strings only.
    def usage_error(message)
      warn "finding_severity.rb: #{message}\n\n#{USAGE}"
      2
    end

    # [options, nil] or [nil, exit_code].
    def parse(argv)
      options = {}
      parser, options = Cli.build("finding_severity.rb", options) do |opts|
        opts.on("--findings PATH") { |v| options[:findings] = v }
        opts.on("--source LABEL") { |v| options[:source] = v }
        opts.on("--threshold N") { |v| options[:threshold] = v }
      end
      rest = parser.parse!(argv)
      return [nil, usage_error("unexpected argument")] unless rest.empty?

      missing = %i[findings source].select { |k| options[k].nil? }
      return [nil, usage_error("missing #{missing.map { |k| "--#{k}" }.join(', ')}")] unless missing.empty?
      return [nil, usage_error("--source must be a label")] unless options[:source].match?(Typesafe::LABEL)

      unless options[:threshold].nil?
        options[:threshold] = threshold_of(options[:threshold])
        return [nil, usage_error("--threshold must be a number in (0, 1]")] if options[:threshold].nil?
      end
      [options, nil]
    rescue OptionParser::ParseError => e
      [nil, usage_error(e.message)]
    end

    def threshold_of(text)
      value = Float(text)
      value.finite? && value > 0 && value <= 1 ? value : nil
    rescue ArgumentError, TypeError
      nil
    end

    def severity(env, config, options, http_class)
      d = env.data
      mode = Typesafe.site_mode(config, FindingSeverity::SITE)
      base(d, config, options, mode)
      findings = read_findings(options[:findings])
      if findings.nil?
        env.warn(code: "findings_unreadable",
                 message: "the findings file could not be read or is not a JSON array of " \
                          "objects; nothing was counted or sent")
        d[:summary_line] = summary_line(d)
        return
      end

      entries = findings.each_with_index.map { |f, i| entry_for(f, i) }
      d[:findings] = entries
      if mode == "off"
        # Off is the hot path: counted locally, nothing called or written.
        d[:outcome] = "site_off"
        entries.each { |e| e[:action] = "site_off" }
      else
        judge_all(env, config, options, mode, findings, entries, http_class)
      end
      d[:findings_by_level] = FindingSeverity.counts(entries.map { |e| e[:level] })
      d[:raised] = entries.count { |e| e[:action] == "raised" }
      d[:summary_line] = summary_line(d)
    end

    # Every data key, at its default, so the envelope's shape never depends
    # on the path taken.
    def base(d, config, options, mode)
      d[:site] = FindingSeverity::SITE
      d[:mode] = mode
      d[:outcome] = nil
      d[:threshold_key] = Typesafe.threshold_key(site: FindingSeverity::SITE,
                                                 question_set: FindingSeverity::QUESTION_SET,
                                                 model: config.typesafe_model)
      d[:findings_path] = options[:findings]
      d[:findings] = []
      d[:findings_by_level] = nil
      d[:raised] = 0
      d[:calls] = 0
      d[:threshold] = options[:threshold]
      d[:cost_usd] = nil
      d[:dry_run] = options[:dry_run] ? true : false
      d[:outcome_lines_written] = 0
      d[:summary_line] = nil
    end

    # The parsed array, or nil when the file cannot be read, is not JSON, or
    # is not an array of objects. Never echoes the file's text.
    def read_findings(path)
      parsed = JSON.parse(File.binread(path).force_encoding(Encoding::UTF_8))
      return nil unless parsed.is_a?(Array) && parsed.all? { |f| f.is_a?(Hash) }

      parsed
    rescue JSON::ParserError, EncodingError, SystemCallError, IOError
      nil
    end

    # One finding's envelope entry: labels and numbers only, never its text.
    def entry_for(finding, index)
      agent = finding["agent"]
      critic = FindingSeverity.critic_level(finding)
      { index: index, agent: agent.is_a?(String) && agent.match?(Typesafe::LABEL) ? agent : nil,
        critic_level: critic, jev_level: nil, jev_confidence: nil, level: critic,
        agreement: "n/a", action: nil, reason: nil, call_id: nil }
    end

    # One call per finding with text. The first non-ok outcome stops the
    # calls: every later finding falls back (reason stopped) rather than
    # spend or wait again against a failing service.
    def judge_all(env, config, options, mode, findings, entries, http_class)
      d = env.data
      stopped = nil
      findings.each_with_index do |finding, i|
        e = entries[i]
        input = FindingSeverity.input_for(finding, source: options[:source])
        if input.nil?
          e[:action] = "skipped"
          e[:reason] = "nothing_to_judge"
        elsif stopped
          fallback(e, "stopped")
        elsif d[:calls] >= MAX_CALLS
          fallback(e, "call_cap")
        else
          result = call_one(env, config, options, mode, input, e, http_class)
          stopped = result.outcome unless result.outcome == "ok"
        end
      end
      d[:outcome] ||= "ok" if d[:calls].positive?
      fallback_warnings(env, entries)
    rescue SystemCallError, IOError => e
      env.warn(code: "state_dir_error",
               message: "reading or writing typesafe.state_dir failed (#{e.class.name}); every " \
                        "finding keeps its critic's level")
      entries.each { |entry| fallback(entry, "state_dir_error") }
    end

    def call_one(env, config, options, mode, input, entry, http_class)
      d = env.data
      result = Typesafe.judge(config: config, input: input, site: FindingSeverity::SITE,
                              dry_run: options[:dry_run], http_class: http_class)
      fill_result(env, entry, result, options[:dry_run])
      if options[:dry_run] && result.outcome == "ok"
        d[:request] ||= result.request
        entry[:action] = "dry_run"
        return result
      end

      read = FindingSeverity.interpret(result, mode: mode, critic_level: entry[:critic_level],
                                               threshold: options[:threshold])
      read.each { |k, v| entry[k.to_sym] = v }
      record(config, d, entry, result) unless options[:dry_run]
      result
    end

    def fill_result(env, entry, result, dry_run)
      d = env.data
      d[:outcome] = result.outcome unless result.outcome == "ok" || d[:outcome]
      entry[:call_id] = result.call_id
      d[:threshold_key] = result.threshold_key || d[:threshold_key]
      d[:cost_usd] = (d[:cost_usd] || 0) + result.cost_usd if result.cost_usd
      sent = dry_run ? result.outcome == "ok" : SENT.include?(result.outcome)
      if sent
        d[:calls] += 1
        env.commands << REQUEST_COMMAND unless env.commands.include?(REQUEST_COMMAND)
      end
      Array(result.warnings).each { |w| client_warning(env, w) }
    end

    # The caller's outcome line: decision = the critic's own level, agreement
    # from the read. Labels only.
    def record(config, d, entry, result)
      return if result.call_id.nil? || result.outcome == "site_off"

      Typesafe.record_outcome(config: config, call_id: result.call_id, site: FindingSeverity::SITE,
                              action: entry[:action], decision: entry[:critic_level],
                              agreement: entry[:agreement])
      d[:outcome_lines_written] += 1
    end

    # Back to the critic's own level: a fallback is never read as an answer.
    def fallback(entry, reason)
      entry[:jev_level] = nil
      entry[:jev_confidence] = nil
      entry[:agreement] = "n/a"
      entry[:level] = entry[:critic_level]
      entry[:action] = "fallback"
      entry[:reason] = reason
    end

    # One warning per distinct fallback reason, naming labels only.
    def fallback_warnings(env, entries)
      reasons = entries.select { |e| e[:action] == "fallback" }.map { |e| e[:reason] }.uniq
      reasons.each do |reason|
        env.warn(code: "jev_fallback",
                 message: "Jev gave no usable answer for some findings (#{reason}); they keep " \
                          "their critic's level. A fallback is never read as an answer.")
      end
    end

    def client_warning(env, warning)
      code, count = warning.split(":", 2)
      return if env.warnings.any? { |w| w[:code] == code }

      case code
      when "key_mode_open"
        env.warn(code: code, message: "the key file is group- or world-readable; chmod 600 it")
      when "ledger_malformed"
        env.warn(code: code, message: "#{count} line(s) of this month's ledger are not JSON objects; " \
                                      "they count as unmeasurable spend (see budget_exhausted)")
      else
        env.warn(code: code, message: "client warning #{code}")
      end
    end

    # One line for a bead note or a journal. Labels and numbers only: never
    # finding text.
    def summary_line(d)
      counts = d[:findings_by_level]
      return "[probe] finding_severity: findings unreadable; nothing counted" if counts.nil?

      fallbacks = d[:findings].count { |e| e[:action] == "fallback" }
      "[probe] finding_severity: #{d[:findings].size} finding(s), mode #{d[:mode]}; " \
        "must-fix #{counts['mustFix']}, should-fix #{counts['shouldFix']}, note #{counts['note']}, " \
        "unranked #{counts['unranked']}; raised #{d[:raised]}, fallbacks #{fallbacks}"
    end
  end
end

exit FindingSeverityCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

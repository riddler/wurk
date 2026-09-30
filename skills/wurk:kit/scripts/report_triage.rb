#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require_relative "lib/envelope"
require_relative "lib/cli"
require_relative "lib/user_config"
require_relative "lib/typesafe"
require_relative "lib/report_triage"

# The report_triage Jev site: after the conductor has classified a worker's
# report (done, blocked or stuck), ask Jev the same question and route on one
# field, data.add_needs_you. The contract is kit REFERENCE.md's
# "`report_triage.rb`: the report_triage Jev site"; the client contract it
# builds on is "typesafe.rb: the Jev client and the call-site contract".
#
# Unlike typesafe.rb, off is not a block here: a dark site is the ordinary
# state, so every path but a usage error or an invalid machine config exits
# 0, and every fallback leaves the caller's sweep exactly as it was. No
# manifest and no Sh: the only external effect is the library's one HTTPS
# request. run returns the exit code and never calls exit.
module ReportTriageCli
  USAGE = <<~TEXT
    usage: report_triage.rb --report PATH --conductor done|blocked|stuck --source LABEL
                            [--threshold N] [--dry-run]

    Ask Jev to triage one worker report after the conductor's own read. The one
    field a caller routes on is data.add_needs_you: true only in on mode, when
    the conductor said done and Jev says blocked or stuck with confidence at or
    above --threshold. Everything else changes nothing. Exit 0 on every
    fallback; 1 only for an invalid machine config; 2 for usage.

    --report PATH      the worker's report file (read only when the site is not off)
    --conductor CLASS  the conductor's own classification: done, blocked or stuck
    --source LABEL     the text's source label, e.g. repo:<repo directory basename>
    --threshold N      the eval tooling's enabled threshold for data.threshold_key,
                       a number in (0, 1]; without one, on mode adds nothing
    --dry-run          show the request with Authorization redacted; send and
                       write nothing
  TEXT
  HELP_FLAGS = %w[--help -h].freeze
  REQUEST_COMMAND = "POST #{Typesafe::ENDPOINT}"
  # Outcomes a live call reaches only by sending the request. Mirrors
  # TypesafeCli::SENT (the test asserts they match).
  SENT = %w[ok unauthorized rejected rate_limited overloaded other_status
            timeout transport undecodable model_mismatch].freeze

  class << self
    def run(argv, io: $stdout, http_class: Net::HTTP)
      argv = argv.dup
      return help(io) if (argv & HELP_FLAGS).any?

      options, code = parse(argv)
      return code if code

      env = Envelope.new(script: "report_triage")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      triage(env, config, options, http_class)
      env.emit(io)
    end

    private

    def help(io)
      io.puts USAGE
      0
    end

    # Exit 2, plain text on stderr, no envelope. Fixed strings only.
    def usage_error(message)
      warn "report_triage.rb: #{message}\n\n#{USAGE}"
      2
    end

    # [options, nil] or [nil, exit_code].
    def parse(argv)
      options = {}
      parser, options = Cli.build("report_triage.rb", options) do |opts|
        opts.on("--report PATH") { |v| options[:report] = v }
        opts.on("--conductor CLASS") { |v| options[:conductor] = v }
        opts.on("--source LABEL") { |v| options[:source] = v }
        opts.on("--threshold N") { |v| options[:threshold] = v }
      end
      rest = parser.parse!(argv)
      return [nil, usage_error("unexpected argument")] unless rest.empty?

      missing = %i[report conductor source].select { |k| options[k].nil? }
      return [nil, usage_error("missing #{missing.map { |k| "--#{k}" }.join(', ')}")] unless missing.empty?
      unless ReportTriage::CLASSES.include?(options[:conductor])
        return [nil, usage_error("--conductor must be one of #{ReportTriage::CLASSES.join(', ')}")]
      end
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

    def triage(env, config, options, http_class)
      d = env.data
      mode = Typesafe.site_mode(config, ReportTriage::SITE)
      base(d, config, options, mode)
      # Off is the hot path: the report is never read, nothing is called or
      # written.
      if mode == "off"
        d[:outcome] = "site_off"
        d[:action] = "site_off"
        return
      end

      report, digest = read_report(options[:report])
      d[:report_digest] = digest
      if report == :unreadable
        env.warn(code: "report_unreadable",
                 message: "the report could not be read or is not JSON; nothing was sent and the " \
                          "sweep is unchanged")
        return finish(d, "fallback", "report_unreadable")
      end

      input = ReportTriage.input_for(report, source: options[:source])
      return finish(d, "skipped", "nothing_to_judge") if input.nil?

      call(env, config, options, mode, input, http_class)
    end

    # Every data key, at its default, so the envelope's shape never depends
    # on the path taken.
    def base(d, config, options, mode)
      d[:site] = ReportTriage::SITE
      d[:mode] = mode
      d[:outcome] = nil
      d[:reason] = nil
      d[:call_id] = nil
      d[:threshold_key] = Typesafe.threshold_key(site: ReportTriage::SITE,
                                                 question_set: ReportTriage::QUESTION_SET,
                                                 model: config.typesafe_model)
      d[:report] = options[:report]
      d[:report_digest] = nil
      d[:conductor] = options[:conductor]
      d[:jev_class] = nil
      d[:jev_confidence] = nil
      d[:urgency] = nil
      d[:agreement] = "n/a"
      d[:action] = nil
      d[:add_needs_you] = false
      d[:threshold] = options[:threshold]
      d[:cost_usd] = nil
      d[:dry_run] = options[:dry_run] ? true : false
      d[:outcome_line_written] = false
      d[:journal_line] = nil
    end

    # [parsed, digest]; parsed is :unreadable when the file cannot be read or
    # parsed. The digest (first 16 hex of the file's SHA256) ties a triage to
    # one version of the report.
    def read_report(path)
      bytes = File.binread(path)
      digest = Digest::SHA256.hexdigest(bytes)[0, 16]
      [JSON.parse(bytes.dup.force_encoding(Encoding::UTF_8)), digest]
    rescue JSON::ParserError, EncodingError
      [:unreadable, digest]
    rescue SystemCallError, IOError
      [:unreadable, nil]
    end

    def call(env, config, options, mode, input, http_class)
      d = env.data
      result = Typesafe.judge(config: config, input: input, site: ReportTriage::SITE,
                              dry_run: options[:dry_run], http_class: http_class)
      fill_result(env, result, options[:dry_run])
      if options[:dry_run]
        d[:request] = result.request if result.request
        return finish(d, "dry_run", nil) if result.outcome == "ok"
      end

      read = ReportTriage.interpret(result, mode: mode, conductor: options[:conductor],
                                            threshold: options[:threshold])
      read.each { |k, v| d[k.to_sym] = v }
      fallback_warning(env, d[:reason], result.reason) if d[:action] == "fallback"
      record(config, d, result) unless options[:dry_run]
      d[:journal_line] = journal_line(d)
    rescue SystemCallError, IOError => e
      env.warn(code: "state_dir_error",
               message: "reading or writing typesafe.state_dir failed (#{e.class.name}); the sweep " \
                        "is unchanged")
      d[:jev_class] = nil
      d[:jev_confidence] = nil
      d[:urgency] = nil
      d[:agreement] = "n/a"
      d[:add_needs_you] = false
      finish(d, "fallback", "state_dir_error")
    end

    def fill_result(env, result, dry_run)
      d = env.data
      d[:outcome] = result.outcome
      d[:reason] = result.reason
      d[:call_id] = result.call_id
      d[:threshold_key] = result.threshold_key || d[:threshold_key]
      d[:cost_usd] = result.cost_usd
      sent = dry_run ? result.outcome == "ok" : SENT.include?(result.outcome)
      env.commands << REQUEST_COMMAND if sent
      Array(result.warnings).each { |w| client_warning(env, w) }
    end

    # The caller's outcome line: decision = the conductor's own class,
    # agreement from the read. Labels only.
    def record(config, d, result)
      return if result.call_id.nil? || result.outcome == "site_off"

      Typesafe.record_outcome(config: config, call_id: result.call_id, site: ReportTriage::SITE,
                              action: d[:action], decision: d[:conductor],
                              agreement: d[:agreement])
      d[:outcome_line_written] = true
    end

    def finish(d, action, reason)
      d[:action] = action
      d[:reason] = reason unless reason.nil?
      d[:add_needs_you] = false
      d[:journal_line] = journal_line(d)
      nil
    end

    # The detail is the client's reason label (budget_unset, an exception
    # class), never text.
    def fallback_warning(env, reason, detail)
      named = detail.nil? || detail == reason ? reason : "#{reason}: #{detail}"
      env.warn(code: "jev_fallback",
               message: "Jev gave no usable answer (#{named}); the sweep is unchanged. A fallback " \
                        "is never read as an answer.")
    end

    def client_warning(env, warning)
      code, count = warning.split(":", 2)
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

    # One line for the conductor's journal. Labels and numbers only: never
    # report text.
    def journal_line(d)
      jev = d[:jev_class] ? "#{d[:jev_class]} #{format('%.2f', d[:jev_confidence])}" : "-"
      urgency = d[:urgency] ? format("%.1f", d[:urgency]) : "-"
      changed =
        if d[:add_needs_you] then "added needs-you item"
        elsif d[:action] == "fallback" then "jev fell back (#{d[:reason]}); changed nothing"
        else "changed nothing"
        end
      "[probe] report_triage #{File.basename(d[:report].to_s)}@#{d[:report_digest] || '-'}: " \
        "conductor #{d[:conductor]}, jev #{jev}, urgency #{urgency}, mode #{d[:mode]}, " \
        "action #{d[:action]}; #{changed}"
    end
  end
end

exit ReportTriageCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

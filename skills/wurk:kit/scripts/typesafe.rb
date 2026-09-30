#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require_relative "lib/envelope"
require_relative "lib/cli"
require_relative "lib/user_config"
require_relative "lib/typesafe"

# The CLI over lib/typesafe.rb: `call` asks Jev one gated question set,
# `outcome` records what the caller did next. The contract (modes, the
# closed outcome set, the fallback rule, budget, logs, caller rules) is
# REFERENCE.md's "typesafe.rb: the Jev client and the call-site contract".
#
# No manifest (the typesafe section is machine config, so this works from
# any directory) and no Sh (the only external effect is one HTTPS request,
# made by the library through Net::HTTP). run returns the exit code and
# never calls exit, so tests drive it in-process.
module TypesafeCli
  SUBCOMMANDS = %w[call outcome].freeze
  USAGE = <<~TEXT
    usage: typesafe.rb call    [--site NAME] --input PATH|-  [--dry-run]
           typesafe.rb outcome --call-id ID --site NAME --action LABEL
                               [--decision LABEL] [--agreement agree|disagree|n/a] [--dry-run]

    call     one gated Jev call; the envelope's data.outcome is the one field
             a caller routes on ("ok", or a member of the closed outcome set).
             No --site is an ad-hoc probe call. --input - reads stdin.
    outcome  append the caller's outcome line (labels only) for a call_id.
    --dry-run  call: report the outcome up to the request and the request
               itself with Authorization redacted; send and write nothing.
               outcome: report the line in data.line; write nothing.
  TEXT
  HELP_FLAGS = %w[--help -h].freeze
  REQUEST_COMMAND = "POST #{Typesafe::ENDPOINT}"
  # Outcomes a live call can only reach by sending the request.
  SENT = %w[ok unauthorized rejected rate_limited overloaded other_status
            timeout transport undecodable model_mismatch].freeze
  FALLBACK = "Fall back: do what this site did before Jev existed; this is never an answer."

  class << self
    def run(argv, io: $stdout, stdin: $stdin, http_class: Net::HTTP)
      argv = argv.dup
      return usage_error("a subcommand is required") if argv.empty?
      return help(io) if HELP_FLAGS.include?(argv.first)

      sub = argv.shift
      return usage_error("unknown subcommand") unless SUBCOMMANDS.include?(sub)
      return help(io) if (argv & HELP_FLAGS).any?

      sub == "call" ? run_call(argv, io, stdin, http_class) : run_outcome(argv, io)
    end

    private

    def help(io)
      io.puts USAGE
      0
    end

    # Exit 2, plain text on stderr, no envelope. Messages are fixed strings
    # or library labels, never caller text.
    def usage_error(message)
      warn "typesafe.rb: #{message}\n\n#{USAGE}"
      2
    end

    # [options, nil] or [nil, exit_code] on a usage error.
    def parse(argv, sub)
      options = {}
      parser, options = Cli.build("typesafe.rb #{sub}", options) do |opts|
        yield opts, options
      end
      rest = parser.parse!(argv)
      return [nil, usage_error("unexpected argument")] unless rest.empty?

      [options, nil]
    rescue OptionParser::ParseError => e
      [nil, usage_error(e.message)]
    end

    # --- call ---------------------------------------------------------------

    def run_call(argv, io, stdin, http_class)
      options, code = parse(argv, "call") do |opts, o|
        opts.on("--site NAME", "the call site (omit for an ad-hoc probe)") { |v| o[:site] = v }
        opts.on("--input PATH", "input JSON file, or - for stdin") { |v| o[:input] = v }
      end
      return code if code
      return usage_error("call needs --input PATH|-") if options[:input].nil?

      env = Envelope.new(script: "typesafe")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      site = options[:site]
      input = nil
      unreadable = nil
      # A dark site never reads its input: the mode check is the hot path.
      unless Typesafe.site_mode(config, site) == "off"
        input, unreadable = read_input(options[:input], stdin)
      end

      result = Typesafe.judge(config: config, input: input, site: site,
                              dry_run: options[:dry_run], http_class: http_class)
      fill_call(env, config, result, options[:dry_run], unreadable)
      env.emit(io)
    rescue SystemCallError, IOError => e
      state_error(env, e, io, call: true)
    end

    # [parsed, nil] or [nil, detail]. A parse failure reports the parser's
    # POSITION only: its message quotes the input, and the input is caller
    # text. A read failure reports the exception class only.
    def read_input(path, stdin)
      text = path == "-" ? stdin.read : File.read(path)
      [JSON.parse(text.to_s), nil]
    rescue JSON::ParserError, EncodingError => e
      [nil, "the input is not valid JSON#{parse_position(e)}"]
    rescue SystemCallError, IOError => e
      [nil, "the input could not be read (#{e.class.name})"]
    end

    def parse_position(error)
      match = error.message.to_s.match(/\bat line \d+ column \d+/)
      match ? " (#{match[0]})" : ""
    end

    def fill_call(env, config, result, dry_run, unreadable)
      d = env.data
      d[:outcome] = result.outcome
      d[:reason] = result.reason
      d[:call_id] = result.call_id
      d[:site] = result.site
      d[:mode] = result.mode
      d[:model] = config.typesafe_model
      d[:served_model] = result.served_model
      d[:answers] = result.answers
      d[:usage] = result.usage
      d[:cost_usd] = result.cost_usd
      d[:cost_estimated] = result.cost_estimated
      d[:elapsed_ms] = result.elapsed_ms
      d[:http_status] = result.http_status
      d[:retry_after] = result.retry_after
      d[:threshold_key] = result.threshold_key
      d[:dry_run] = dry_run ? true : false
      d[:request] = result.request if dry_run

      sent = dry_run ? result.outcome == "ok" : SENT.include?(result.outcome)
      env.commands << REQUEST_COMMAND if sent
      Array(result.warnings).each { |w| warn_for(env, w) }
      return if result.outcome == "ok"

      env.block!(code: result.outcome, message: message_for(result, unreadable),
                 needs: Typesafe::NEEDS_NONE.include?(result.outcome) ? "none" : "human")
    end

    def warn_for(env, warning)
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

    # Condition, then the move. Labels, numbers and config key names only:
    # never input text, the key, or the key path.
    def message_for(result, unreadable)
      site = result.site ? "site #{result.site}" : "the probe call"
      status = result.http_status ? " (HTTP #{result.http_status})" : ""
      text =
        case result.outcome
        when "site_off"
          "#{site} is off (the default). Set typesafe.sites.<name>.mode to shadow in the machine " \
          "config to start calling it."
        when "source_restricted"
          "the input's source is listed in typesafe.restricted_sources; nothing was sent. " \
          "Do not relabel the text to get it through."
        when "input_invalid"
          detail = unreadable || "field #{result.reason} is missing or malformed"
          "#{detail}. Fix the caller's input (state, questions, question_set, source) and call again."
        when "key_missing"
          "no usable key at typesafe.key_path (#{result.reason}). An operator puts the key file " \
          "there, mode 600; the key never goes in the config."
        when "budget_exhausted" then budget_message(result.reason)
        when "rate_limited_local"
          "typesafe.budget.per_minute calls were already made in the last 60s. The next call " \
          "after the window may proceed."
        when "unauthorized"
          "the provider refused the key#{status}. An operator checks or replaces the key file."
        when "rejected"
          "the provider rejected the request#{status}. Fix the question set (type, criteria) " \
          "and bump its version."
        when "rate_limited"
          after = result.retry_after ? "; Retry-After #{result.retry_after}" : ""
          "the provider rate-limited the call#{status}#{after}. The client never retries."
        when "overloaded" then "the provider is overloaded#{status}. The client never retries."
        when "other_status" then "the provider answered an unexpected status#{status}."
        when "timeout"
          "no answer within the site's deadline_ms (#{result.reason}). Raise " \
          "typesafe.sites.<name>.deadline_ms only if this persists."
        when "transport" then "the request failed in transport (#{result.reason})."
        when "undecodable" then "the provider's 200 body had no readable answers."
        when "model_mismatch"
          "the provider served a model other than the pinned typesafe.model (see " \
          "data.served_model); its answers were discarded. Re-pin only after re-running the evals."
        else "outcome #{result.outcome}."
        end
      "#{text} #{FALLBACK}"
    end

    def budget_message(reason)
      case reason
      when "budget_unset"
        "no typesafe.budget.monthly_usd in the machine config, so no live call is allowed. " \
        "An operator sets one to enable calls."
      when "price_unknown"
        "the pinned model has no metrics.prices row quoting both input and output (unknown " \
        "price is could-not-measure, never free). An operator adds the row; write output: 0 if free."
      when "spend_unmeasurable"
        "this month's ledger has a malformed or null-cost line, so spend cannot be measured. " \
        "An operator checks the provider's bill, then fixes or removes that line."
      when "cap_reached"
        "this call could push this month's spend past typesafe.budget.monthly_usd. Wait for " \
        "the next month or have an operator raise the cap."
      else "the local budget refused the call (#{reason})."
      end
    end

    # A failure reading or writing the state dir escapes the library as a
    # SystemCallError. Reported as an envelope block naming only the
    # exception class: its message carries a path, and a backtrace could
    # carry more. data.outcome stays null - no closed-set outcome was
    # reached, and a caller treats that like any other non-ok outcome.
    def state_error(env, error, io, call: false)
      env ||= Envelope.new(script: "typesafe")
      env.data[:outcome] = nil if call
      env.block!(code: "state_dir_error",
                 message: "reading or writing typesafe.state_dir failed (#{error.class.name}). " \
                          "Make the state dir readable and writable by this user, or point " \
                          "typesafe.state_dir at one that is; a live call's spend may be missing " \
                          "from the ledger. #{FALLBACK}",
                 needs: "human")
      env.emit(io)
    end

    # --- outcome ------------------------------------------------------------

    def run_outcome(argv, io)
      options, code = parse(argv, "outcome") do |opts, o|
        opts.on("--call-id ID", "the call_id from the call's envelope") { |v| o[:call_id] = v }
        opts.on("--site NAME", "the call site") { |v| o[:site] = v }
        opts.on("--action LABEL", "what the caller did next (a label)") { |v| o[:action] = v }
        opts.on("--decision LABEL", "the caller's own decision (a label)") { |v| o[:decision] = v }
        opts.on("--agreement VALUE", "agree, disagree or n/a") { |v| o[:agreement] = v }
      end
      return code if code

      missing = %i[call_id site action].select { |k| options[k].nil? }
      unless missing.empty?
        return usage_error("outcome needs #{missing.map { |k| "--#{k.to_s.tr('_', '-')}" }.join(', ')}")
      end

      env = Envelope.new(script: "typesafe")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      begin
        line = Typesafe.record_outcome(config: config, call_id: options[:call_id],
                                       site: options[:site], action: options[:action],
                                       decision: options[:decision],
                                       agreement: options[:agreement],
                                       dry_run: options[:dry_run])
      rescue ArgumentError => e
        # The library's label rule: fixed messages, no caller text.
        return usage_error(e.message)
      end
      env.data[:line] = line
      env.data[:dry_run] = options[:dry_run] ? true : false
      env.data[:written] = !options[:dry_run]
      env.emit(io)
    rescue SystemCallError, IOError => e
      state_error(env, e, io)
    end
  end
end

exit TypesafeCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require_relative "lib/envelope"
require_relative "lib/cli"
require_relative "lib/user_config"
require_relative "lib/typesafe"
require_relative "lib/typesafe_eval"

# The CLI over lib/typesafe_eval.rb: the corpus builder and the terminal
# labeller a Jev call site is evaluated with. The contract (corpus format,
# redaction, the builder, the labeller) is REFERENCE.md's "typesafe_eval.rb:
# Jev eval, thresholds and the on-gate".
#
# No manifest (the typesafe section is machine config, so this works from
# any directory) and no Sh (nothing here starts a process). run returns the
# exit code and never calls exit, so tests drive it in-process. Prompts go
# to `prompt` (stderr), answers come from `stdin`, the one envelope goes to
# `io`. The envelope carries counts and labels only, never case text.
module TypesafeEvalCli
  USAGE = <<~TEXT
    usage: typesafe_eval.rb corpus build --site NAME --question-set FILE --out PATH
                            (--from-dir DIR [--glob PAT] --source LABEL |
                             --from-jsonl FILE --source LABEL)...
                            [--redact-key KEY]... [--dry-run]
           typesafe_eval.rb label --corpus PATH [--relabel] [--dry-run]
           typesafe_eval.rb run --corpus PATH [--dry-run]
           typesafe_eval.rb sweep --run PATH --corpus PATH [--apply] [--dry-run]
           typesafe_eval.rb gate --site NAME --question-set ID@VERSION
           typesafe_eval.rb threshold --key THRESHOLD_KEY --labels L1[,L2...] [--dry-run]
           typesafe_eval.rb fixtures run --fixtures PATH [--dry-run]
           typesafe_eval.rb fixtures check --fixtures PATH... [--dry-run]

    corpus build  read-only sources -> one corpus file for a site and question
                  set. Every source needs a --source label, given after its
                  --from-dir or --from-jsonl. A restricted source label
                  (typesafe.restricted_sources) refuses the build before any
                  source is read. Self-stated labels are redacted (--redact-key
                  names the fields that state one).
    label         walk unlabelled cases on the terminal; a label is saved as
                  it is given. A number or a label name records it, s skips,
                  q or end of input stops.
    --dry-run     corpus build: report the counts, write nothing.
                  label: record nothing.
                  run: check the first case up to the request; send nothing.
                  sweep: with --apply, report the store entry; write nothing.
                  threshold: accepted; it writes nothing anyway.
    run           send every labelled case through the client (probe calls,
                  the client's own budget) and write a run file under the
                  state dir. The first case that is not ok stops the run,
                  which is then partial.
    sweep         per label, the smallest confidence threshold whose Wilson
                  95% lower bound on precision is >= 0.90 with >= 10 routed
                  cases, else n/a. --apply stores it under the run's
                  threshold key; a partial run is refused.
    gate          read-only: exit 0 only when the site's current threshold key
                  has an enabled threshold AND the shadow evidence bar is met
                  (>= 3 days, >= 35 accepted judgments, Wilson lower bound
                  >= 0.90 on shadow agreement). Advisory: it changes nothing.
    threshold     read-only: the number a site's --threshold takes for the
                  labels it routes on - the LARGEST of those labels' stored
                  thresholds under the key, or n/a (null, exit 0) when any of
                  them has none. n/a means: pass no --threshold.
    fixtures      run a site's synthetic fixture set on demand (run), or run
                  each set only when the model id changed since its last
                  run (check). Failure is exit 1 and a block; nothing is
                  scheduled. --dry-run reports what would run and sends
                  nothing.
  TEXT
  HELP_FLAGS = %w[--help -h].freeze
  REQUEST_COMMAND = "POST #{Typesafe::ENDPOINT}"
  SUBCOMMANDS = %w[corpus label run sweep gate threshold fixtures].freeze

  class << self
    def run(argv, io: $stdout, stdin: $stdin, prompt: $stderr, http_class: Net::HTTP, now: nil, sleeper: nil)
      argv = argv.dup
      return usage_error("a subcommand is required") if argv.empty?
      return help(io) if HELP_FLAGS.include?(argv.first)

      sub = argv.shift
      return usage_error("unknown subcommand") unless SUBCOMMANDS.include?(sub)
      return help(io) if (argv & HELP_FLAGS).any?

      case sub
      when "corpus" then run_corpus(argv, io)
      when "label" then run_label(argv, io, stdin, prompt)
      when "run" then run_eval(argv, io, clock_args(http_class, now, sleeper))
      when "sweep" then run_sweep(argv, io, now)
      when "gate" then run_gate(argv, io, now)
      when "threshold" then run_threshold(argv, io)
      else run_fixtures(argv, io, clock_args(http_class, now, sleeper))
      end
    end

    private

    # Only the injected pieces: the library supplies its own defaults.
    def clock_args(http_class, now, sleeper)
      args = { http_class: http_class }
      args[:now] = now if now
      args[:sleeper] = sleeper if sleeper
      args
    end

    def help(io)
      io.puts USAGE
      0
    end

    # Exit 2, plain text on stderr, no envelope. Messages are fixed strings
    # or option-parser labels, never case text.
    def usage_error(message)
      warn "typesafe_eval.rb: #{message}\n\n#{USAGE}"
      2
    end

    # [options, nil] or [nil, exit_code] on a usage error.
    def parse(argv, sub)
      options = {}
      parser, options = Cli.build("typesafe_eval.rb #{sub}", options) do |opts|
        yield opts, options
      end
      rest = parser.parse!(argv)
      return [nil, usage_error("unexpected argument")] unless rest.empty?

      [options, nil]
    rescue OptionParser::ParseError => e
      [nil, usage_error(e.message)]
    end

    def refuse(env, refusal, io)
      env.block!(code: refusal.code, message: refusal.message, needs: "human")
      env.emit(io)
    end

    # A failure reading or writing a path escapes the library as a
    # SystemCallError. Reported by exception class only: the message carries
    # a path.
    def io_error(env, error, io)
      env ||= Envelope.new(script: "typesafe_eval")
      env.block!(code: "io_error",
                 message: "reading or writing a corpus or source path failed (#{error.class.name}). " \
                          "Check the path exists and is readable and writable by this user.",
                 needs: "human")
      env.emit(io)
    end

    # --- corpus build -------------------------------------------------------

    def run_corpus(argv, io)
      return usage_error("corpus needs the build subcommand") unless argv.first == "build"

      argv.shift
      options, code = parse_build(argv)
      return code if code

      env = Envelope.new(script: "typesafe_eval")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      build(env, config, options, io)
    rescue SystemCallError, IOError => e
      io_error(env, e, io)
    end

    def parse_build(argv)
      sources = []
      options, code = parse(argv, "corpus build") do |opts, o|
        o[:sources] = sources
        o[:redact_keys] = []
        opts.on("--site NAME", "the call site the corpus is for") { |v| o[:site] = v }
        opts.on("--question-set FILE", "the question-set file") { |v| o[:question_set] = v }
        opts.on("--out PATH", "the corpus file to write") { |v| o[:out] = v }
        opts.on("--from-dir DIR", "a directory source (one case per file)") do |v|
          sources << { kind: "dir", path: v }
        end
        opts.on("--from-jsonl FILE", "a JSONL source (one case per line)") do |v|
          sources << { kind: "jsonl", path: v }
        end
        opts.on("--glob PAT", "glob within the last --from-dir") { |v| attach(o, sources, :glob, v) }
        opts.on("--source LABEL", "source label of the last --from-*") { |v| attach(o, sources, :source, v) }
        opts.on("--redact-key KEY", "a field that states a label; repeatable") { |v| o[:redact_keys] << v }
      end
      return [nil, code] if code

      problem = build_problem(options, sources)
      problem ? [nil, usage_error(problem)] : [options, nil]
    end

    # Sets a per-source option on the most recent --from-* source.
    def attach(options, sources, key, value)
      if sources.empty?
        options[:problem] ||= "--#{key == :glob ? 'glob' : 'source'} needs a --from-dir or --from-jsonl before it"
      else
        sources.last[key] = value
      end
    end

    # The first usage problem with parsed build options, or nil.
    def build_problem(options, sources)
      missing = %i[site question_set out].select { |k| options[k].nil? }
      return "corpus build needs #{missing.map { |k| "--#{k.to_s.tr('_', '-')}" }.join(', ')}" unless missing.empty?
      return "--site must match [a-z0-9][a-z0-9_-]{0,63}" unless options[:site].match?(UserConfig::TYPESAFE_NAME)
      return "corpus build needs a --from-dir or --from-jsonl source" if sources.empty?

      return options[:problem] if options[:problem]
      bad = sources.find { |s| s[:glob] && s[:kind] != "dir" }
      return "--glob applies to --from-dir only" if bad

      sources.any? { |s| s[:source].nil? } ? "every source needs a --source label" : nil
    end

    def build(env, config, options, io)
      corpus = TypesafeEval.build_corpus(
        config: config, question_set_file: options[:question_set], site: options[:site],
        sources: options[:sources], redact_keys: options[:redact_keys], out: options[:out]
      )
      TypesafeEval.write_corpus(options[:out], corpus) unless options[:dry_run]
      fill_build(env, corpus, options)
      env.emit(io)
    rescue TypesafeEval::Refusal => e
      refuse(env, e, io)
    end

    def fill_build(env, corpus, options)
      d = env.data
      d[:site] = corpus["site"]
      d[:question_set] = corpus["question_set"]
      d[:question] = corpus["question"]
      d[:cases] = corpus["cases"].size
      d[:redactions] = corpus["cases"].map { |c| c["redactions"] }.sum
      d[:labels_kept] = corpus["cases"].count { |c| !c["label"].nil? }
      d[:digest] = TypesafeEval.corpus_digest(corpus)
      d[:out] = options[:out]
      d[:dry_run] = options[:dry_run] ? true : false
    end

    # --- label --------------------------------------------------------------

    def run_label(argv, io, stdin, prompt)
      options, code = parse(argv, "label") do |opts, o|
        opts.on("--corpus PATH", "the corpus file") { |v| o[:corpus] = v }
        opts.on("--relabel", "walk already-labelled cases too") { o[:relabel] = true }
      end
      return code if code
      return usage_error("label needs --corpus") if options[:corpus].nil?

      env = Envelope.new(script: "typesafe_eval")
      summary = TypesafeEval.label(corpus_path: options[:corpus], input: stdin, prompt: prompt,
                                   relabel: options[:relabel] ? true : false,
                                   dry_run: options[:dry_run])
      env.data.merge!(summary)
      env.data[:corpus] = options[:corpus]
      env.data[:dry_run] = options[:dry_run] ? true : false
      env.emit(io)
    rescue TypesafeEval::Refusal => e
      refuse(env, e, io)
    rescue SystemCallError, IOError => e
      io_error(env, e, io)
    end

    # --- run ----------------------------------------------------------------

    def run_eval(argv, io, injected)
      options, code = parse(argv, "run") do |opts, o|
        opts.on("--corpus PATH", "the labelled corpus file") { |v| o[:corpus] = v }
      end
      return code if code
      return usage_error("run needs --corpus") if options[:corpus].nil?

      env = Envelope.new(script: "typesafe_eval")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      summary = TypesafeEval.run(config: config, corpus_path: options[:corpus],
                                 dry_run: options[:dry_run], **injected)
      fill_run(env, summary)
      env.emit(io)
    rescue TypesafeEval::RunInterrupted => e
      fill_run(env, e.summary, block: false)
      env.block!(code: "run_interrupted",
                 message: "the run was interrupted; the run file was closed as incomplete and " \
                          "cannot be applied. Re-run the whole corpus.",
                 needs: "human")
      env.emit(io)
    rescue TypesafeEval::Refusal => e
      refuse(env, e, io)
    rescue SystemCallError, IOError => e
      io_error(env, e, io)
    end

    def fill_run(env, summary, block: true)
      d = env.data
      summary.each { |k, v| d[k] = v unless k == :sent }
      summary[:sent].to_i.times { env.commands << REQUEST_COMMAND }
      return fill_dry_run(env, summary) if summary[:dry_run]
      return if summary[:complete] || !block

      stop = summary[:stop_reason]
      env.block!(code: "run_incomplete",
                 message: "the run stopped at the first case that was not ok (#{stop}) and is " \
                          "partial: it cannot be applied. Fix the cause and re-run the whole corpus.",
                 needs: Typesafe::NEEDS_NONE.include?(stop) ? "none" : "human")
    end

    def fill_dry_run(env, summary)
      return if summary[:outcome] == "ok"

      env.block!(code: summary[:outcome],
                 message: "the first case would be refused before any request " \
                          "(#{summary[:outcome]}: #{summary[:reason]}); a live run would stop there.",
                 needs: Typesafe::NEEDS_NONE.include?(summary[:outcome]) ? "none" : "human")
    end

    # --- sweep --------------------------------------------------------------

    def run_sweep(argv, io, now)
      options, code = parse(argv, "sweep") do |opts, o|
        opts.on("--run PATH", "the run file") { |v| o[:run] = v }
        opts.on("--corpus PATH", "the corpus file the run used") { |v| o[:corpus] = v }
        opts.on("--apply", "store the thresholds under the run's key") { o[:apply] = true }
      end
      return code if code
      return usage_error("sweep needs --run and --corpus") if options[:run].nil? || options[:corpus].nil?

      env = Envelope.new(script: "typesafe_eval")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      sweep(env, config, options, now)
      env.emit(io)
    rescue TypesafeEval::Refusal => e
      refuse(env, e, io)
    rescue SystemCallError, IOError => e
      io_error(env, e, io)
    end

    def sweep(env, config, options, now)
      corpus = TypesafeEval.load_corpus(options[:corpus])
      lines = TypesafeEval.read_run(options[:run])
      reasons = TypesafeEval.partial_reasons(lines, corpus: corpus, config: config)
      d = env.data
      d[:threshold_key] = TypesafeEval.corpus_threshold_key(config, corpus)
      d[:labels] = TypesafeEval.sweep_run(lines, corpus: corpus)
      d[:partial_reasons] = reasons
      d[:applied] = false
      d[:dry_run] = options[:dry_run] ? true : false
      return sweep_report(env, reasons) unless options[:apply]
      return partial_block(env, reasons) unless reasons.empty?

      args = { config: config, run_lines: lines, corpus: corpus, dry_run: options[:dry_run] }
      args[:now] = now if now
      stored = TypesafeEval.apply(**args)
      d[:applied] = stored[:written]
      d[:entry] = stored[:entry]
      d[:store] = TypesafeEval.thresholds_path(config)
    end

    def sweep_report(env, reasons)
      return if reasons.empty?

      env.warn(code: "partial_run",
               message: "the run is partial (#{reasons.join(', ')}); this report is not applicable")
    end

    def partial_block(env, reasons)
      env.block!(code: "partial_run",
                 message: "the run is partial (#{reasons.join(', ')}); nothing was stored. " \
                          "Re-run the whole corpus against the current corpus and pinned model.",
                 needs: "human")
    end

    # --- gate ---------------------------------------------------------------

    QSET_ARG = /\A(.+)@([0-9]+)\z/.freeze

    def run_gate(argv, io, now)
      options, code = parse(argv, "gate") do |opts, o|
        opts.on("--site NAME", "the call site") { |v| o[:site] = v }
        opts.on("--question-set ID@VERSION", "the question set the site runs") { |v| o[:qset] = v }
      end
      return code if code

      qset = gate_question_set(options)
      return usage_error("gate needs --site NAME and --question-set ID@VERSION") unless qset

      env = Envelope.new(script: "typesafe_eval")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      args = { config: config, site: options[:site], question_set: qset }
      args[:now] = now if now
      fill_gate(env, TypesafeEval.on_gate(**args))
      env.emit(io)
    end

    # {"id", "version"} or nil when a flag is missing or malformed.
    def gate_question_set(options)
      site, arg = options.values_at(:site, :qset)
      return nil unless site.is_a?(String) && site.match?(UserConfig::TYPESAFE_NAME) && arg.is_a?(String)

      match = QSET_ARG.match(arg)
      return nil unless match && match[1].match?(UserConfig::TYPESAFE_NAME) && match[2].to_i.positive?

      { "id" => match[1], "version" => match[2].to_i }
    end

    def fill_gate(env, report)
      d = env.data
      %i[allowed threshold_key enabled_labels accepted disagreed span_s first_routed_at].each do |k|
        d[k] = report[k]
      end
      d[:lower_bound] = report[:lower_bound].nil? ? nil : report[:lower_bound].round(6)
      d[:shortfall] = report[:shortfall]
      if report[:malformed].positive?
        env.warn(code: "decision_lines_malformed",
                 message: "#{report[:malformed]} decision line(s) were unreadable and skipped")
      end
      return if report[:allowed]

      env.block!(code: report[:code], message: gate_message(report), needs: "none")
    end

    def gate_message(report)
      if report[:code] == "no_enabled_threshold"
        "no enabled threshold is stored for #{report[:threshold_key]}: run the eval and apply a " \
        "complete sweep for this question set and pinned model. Keep the site in shadow meanwhile."
      else
        "shadow evidence is short for #{report[:threshold_key]} (#{report[:shortfall].join(', ')}): " \
        "#{report[:accepted]} accepted, #{report[:disagreed]} disagreed, #{report[:span_s]} s of span. " \
        "Keep collecting shadow evidence."
      end
    end

    # --- threshold ----------------------------------------------------------

    def run_threshold(argv, io)
      options, code = parse(argv, "threshold") do |opts, o|
        opts.on("--key THRESHOLD_KEY", "the site's data.threshold_key") { |v| o[:key] = v }
        opts.on("--labels L1,L2", "the labels the site routes on") { |v| o[:labels] = v }
      end
      return code if code

      labels = threshold_labels(options[:labels])
      key = options[:key]
      unless key.is_a?(String) && !key.strip.empty? && labels
        return usage_error("threshold needs --key THRESHOLD_KEY and --labels L1[,L2...]")
      end

      env = Envelope.new(script: "typesafe_eval")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      fill_threshold(env, TypesafeEval.threshold_lookup(config: config, threshold_key: key, labels: labels),
                     options)
      env.emit(io)
    end

    # The comma-separated labels, or nil when the list is empty or has a
    # blank item.
    def threshold_labels(arg)
      return nil unless arg.is_a?(String)

      labels = arg.split(",", -1).map(&:strip)
      labels.empty? || labels.any?(&:empty?) ? nil : labels.uniq
    end

    # n/a is an answer, not a failure: no block, exit 0.
    def fill_threshold(env, report, options)
      d = env.data
      %i[threshold_key labels threshold reason na_labels].each { |k| d[k] = report[k] }
      d[:dry_run] = options[:dry_run] ? true : false
    end

    # --- fixtures -----------------------------------------------------------

    def run_fixtures(argv, io, injected)
      verb = argv.first
      return usage_error("fixtures needs run or check") unless %w[run check].include?(verb)

      argv.shift
      options, code = parse(argv, "fixtures #{verb}") do |opts, o|
        o[:fixtures] = []
        opts.on("--fixtures PATH", "a fixture set file (repeatable for check)") { |v| o[:fixtures] << v }
      end
      return code if code
      return usage_error("fixtures #{verb} needs --fixtures") if options[:fixtures].empty?
      return usage_error("fixtures run takes one --fixtures") if verb == "run" && options[:fixtures].size > 1

      env = Envelope.new(script: "typesafe_eval")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      fixtures(env, config, verb, options, injected)
      env.emit(io)
    rescue TypesafeEval::Refusal => e
      refuse(env, e, io)
    rescue SystemCallError, IOError => e
      io_error(env, e, io)
    end

    def fixtures(env, config, verb, options, injected)
      dry = options[:dry_run] ? true : false
      env.data[:dry_run] = dry
      if verb == "run"
        run = TypesafeEval.run_fixtures(config: config, fixtures_path: options[:fixtures].first,
                                        dry_run: dry, **injected)
        fill_fixture_run(env, run)
        fixture_block(env, [run]) unless dry
      else
        sets = TypesafeEval.check_fixtures(config: config, fixtures_paths: options[:fixtures],
                                           dry_run: dry, **injected)
        fill_fixture_check(env, sets)
        fixture_block(env, sets.map { |s| s[:run] }.compact) unless dry
      end
    end

    # A run's own keys go into data; the request lines go to commands.
    def fill_fixture_run(env, run, into = env.data)
      run.each { |k, v| into[k] = v unless k == :sent }
      run[:sent].to_i.times { env.commands << REQUEST_COMMAND }
    end

    def fill_fixture_check(env, sets)
      env.data[:sets] = sets.map do |s|
        entry = { path: s[:path], set_key: s[:set_key], triggered: s[:triggered], reason: s[:reason] }
        if s[:run]
          entry[:run] = {}
          fill_fixture_run(env, s[:run], entry[:run])
        end
        entry
      end
    end

    def fixture_block(env, runs)
      failed = runs.reject { |r| r[:passed] }
      return if failed.empty?

      detail = failed.map do |r|
        bad = r[:results].reject { |x| x[:passed] }.map { |x| "#{x[:id]}=#{x[:outcome]}" }
        "#{r[:set_key]}: #{bad.join(', ')}"
      end
      env.block!(code: "fixture_failed",
                 message: "fixture(s) failed (id=outcome; ok means the label or confidence was wrong): " \
                          "#{detail.join('; ')}",
                 needs: "human")
    end
  end
end

exit TypesafeEvalCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

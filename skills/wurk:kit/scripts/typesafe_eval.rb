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
  TEXT
  HELP_FLAGS = %w[--help -h].freeze
  SUBCOMMANDS = %w[corpus label].freeze

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
      else run_label(argv, io, stdin, prompt)
      end
    end

    private

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
  end
end

exit TypesafeEvalCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

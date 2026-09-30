#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require_relative "lib/envelope"
require_relative "lib/cli"
require_relative "lib/sh"
require_relative "lib/user_config"
require_relative "lib/typesafe"
require_relative "lib/bead_dedupe"

# The bead_dedupe Jev site: before a bead is filed, list the open beads it
# may duplicate. Keyword overlap picks up to --max-candidates candidates in
# plain code; Jev answers one yes/no per candidate pair. The one field a
# caller routes on is data.likely_duplicates. The contract is kit
# REFERENCE.md's "`bead_dedupe.rb`: the bead_dedupe Jev site".
#
# The script never files, refuses, closes, edits, links or blocks anything:
# its only tracker access is one read (bd list). Filing goes ahead in every
# mode and on every outcome, so every path but a usage error or an invalid
# machine config exits 0. run returns the exit code and never calls exit.
module BeadDedupeCli
  USAGE = <<~TEXT
    usage: bead_dedupe.rb --title TEXT --source LABEL
                          [--description TEXT | --description-file PATH]
                          [--candidates PATH] [--max-candidates N]
                          [--threshold N] [--dry-run]

    Before filing a bead, find open beads it may duplicate: keyword overlap picks
    the candidates, then Jev answers one yes/no per candidate pair. The field a
    caller routes on is data.likely_duplicates: non-empty only in on mode, for a
    candidate whose yes probability is at or above --threshold. Nothing here
    files, refuses or blocks a filing. Exit 0 on every fallback; 1 only for an
    invalid machine config; 2 for usage.

    --title TEXT             the new bead's title
    --source LABEL           the text's source label, e.g. repo:<repo directory basename>
    --description TEXT       the new bead's description
    --description-file PATH  read the description from a file instead
    --candidates PATH        a JSON array of {id, title, description} to search
                             instead of the tracker's open beads (bd list)
    --max-candidates N       at most N Jev calls, 1 to #{BeadDedupe::MAX_CANDIDATES_LIMIT} (default #{BeadDedupe::DEFAULT_MAX_CANDIDATES})
    --threshold N            the eval tooling's enabled threshold for
                             data.threshold_key, a number in (0, 1]; without
                             one, on mode flags nothing
    --dry-run                show the first request with Authorization
                             redacted; send and write nothing
  TEXT
  HELP_FLAGS = %w[--help -h].freeze
  REQUEST_COMMAND = "POST #{Typesafe::ENDPOINT}"
  # Outcomes a live call reaches only by sending the request. Mirrors
  # TypesafeCli::SENT (the test asserts they match).
  SENT = %w[ok unauthorized rejected rate_limited overloaded other_status
            timeout transport undecodable model_mismatch].freeze
  # The tracker read: every bead not yet closed. Read only; the status list
  # is one comma-separated value because bd overwrites a repeated --status.
  LIST_ARGV = ["bd", "list", "--status", "open,in_progress,blocked", "--json", "--limit", "0"].freeze
  LIST_TIMEOUT_S = 30
  # The caller's own decision in the outcome line: the filer files as it did
  # before this site existed.
  DECISION = "filed_unlinked"

  class << self
    def run(argv, io: $stdout, http_class: Net::HTTP)
      argv = argv.dup
      return help(io) if (argv & HELP_FLAGS).any?

      options, code = parse(argv)
      return code if code

      env = Envelope.new(script: "bead_dedupe")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      dedupe(env, config, options, http_class)
      env.emit(io)
    end

    private

    def help(io)
      io.puts USAGE
      0
    end

    # Exit 2, plain text on stderr, no envelope. Fixed strings only.
    def usage_error(message)
      warn "bead_dedupe.rb: #{message}\n\n#{USAGE}"
      2
    end

    # [options, nil] or [nil, exit_code].
    def parse(argv)
      options = {}
      parser, options = Cli.build("bead_dedupe.rb", options) do |opts|
        opts.on("--title TEXT") { |v| options[:title] = v }
        opts.on("--source LABEL") { |v| options[:source] = v }
        opts.on("--description TEXT") { |v| options[:description] = v }
        opts.on("--description-file PATH") { |v| options[:description_file] = v }
        opts.on("--candidates PATH") { |v| options[:candidates] = v }
        opts.on("--max-candidates N") { |v| options[:max] = v }
        opts.on("--threshold N") { |v| options[:threshold] = v }
      end
      rest = parser.parse!(argv)
      return [nil, usage_error("unexpected argument")] unless rest.empty?

      missing = %i[title source].select { |k| options[k].nil? }
      return [nil, usage_error("missing #{missing.map { |k| "--#{k}" }.join(', ')}")] unless missing.empty?
      return [nil, usage_error("--title must not be blank")] if options[:title].strip.empty?
      return [nil, usage_error("--source must be a label")] unless options[:source].match?(Typesafe::LABEL)
      if options[:description] && options[:description_file]
        return [nil, usage_error("pass --description or --description-file, not both")]
      end

      options[:max] = max_of(options[:max])
      return [nil, usage_error("--max-candidates must be an integer from 1 to #{BeadDedupe::MAX_CANDIDATES_LIMIT}")] if options[:max].nil?

      unless options[:threshold].nil?
        options[:threshold] = threshold_of(options[:threshold])
        return [nil, usage_error("--threshold must be a number in (0, 1]")] if options[:threshold].nil?
      end
      [options, nil]
    rescue OptionParser::ParseError => e
      [nil, usage_error(e.message)]
    end

    def max_of(text)
      return BeadDedupe::DEFAULT_MAX_CANDIDATES if text.nil?

      value = Integer(text, 10)
      value >= 1 && value <= BeadDedupe::MAX_CANDIDATES_LIMIT ? value : nil
    rescue ArgumentError, TypeError
      nil
    end

    def threshold_of(text)
      value = Float(text)
      value.finite? && value > 0 && value <= 1 ? value : nil
    rescue ArgumentError, TypeError
      nil
    end

    def dedupe(env, config, options, http_class)
      d = env.data
      mode = Typesafe.site_mode(config, BeadDedupe::SITE)
      base(d, config, options, mode)
      # Off is the hot path: nothing is read (not the description file, not
      # the tracker), nothing is called or written.
      if mode == "off"
        d[:outcome] = "site_off"
        d[:action] = "site_off"
        return
      end

      description = read_description(env, options)
      return finish(d, "skipped", "description_unreadable") if description == :unreadable

      pool = load_candidates(env, options)
      return finish(d, "skipped", pool.to_s) if pool.is_a?(Symbol)

      ranked = BeadDedupe.rank(new_title: options[:title], new_description: description,
                               candidates: pool, max: options[:max])
      d[:searched] = pool.size
      return finish(d, "skipped", "no_candidates") if ranked.empty?

      judge_all(env, config, options, mode, description, ranked, http_class)
    end

    # Every data key, at its default, so the envelope's shape never depends
    # on the path taken.
    def base(d, config, options, mode)
      d[:site] = BeadDedupe::SITE
      d[:mode] = mode
      d[:outcome] = nil
      d[:reason] = nil
      d[:action] = nil
      d[:threshold_key] = Typesafe.threshold_key(site: BeadDedupe::SITE,
                                                 question_set: BeadDedupe::QUESTION_SET,
                                                 model: config.typesafe_model)
      d[:threshold] = options[:threshold]
      d[:max_candidates] = options[:max]
      d[:searched] = nil
      d[:candidates] = []
      d[:likely_duplicates] = []
      d[:calls] = 0
      d[:cost_usd] = nil
      d[:dry_run] = options[:dry_run] ? true : false
      d[:journal_line] = nil
    end

    def read_description(env, options)
      return options[:description].to_s if options[:description_file].nil?

      File.read(options[:description_file])
    rescue SystemCallError, IOError => e
      env.warn(code: "description_unreadable",
               message: "the description file could not be read (#{e.class.name}); nothing was " \
                        "sent and filing is unchanged")
      :unreadable
    end

    # An Array of candidate hashes, or a Symbol naming why there is none.
    def load_candidates(env, options)
      if options[:candidates]
        parsed = parse_array(read_file(options[:candidates]))
        return parsed unless parsed.nil?

        env.warn(code: "candidates_unreadable",
                 message: "the --candidates file could not be read or is not a JSON array; " \
                          "nothing was sent and filing is unchanged")
        return :candidates_unreadable
      end

      result = Sh.run(LIST_ARGV.dup, timeout: LIST_TIMEOUT_S, envelope: env)
      parsed = result.success? ? parse_array(result.out) : nil
      return parsed unless parsed.nil?

      env.warn(code: "candidate_search_failed",
               message: "bd list failed or returned no JSON array; nothing was sent and filing " \
                        "is unchanged")
      :candidate_search_failed
    end

    def read_file(path)
      File.read(path)
    rescue SystemCallError, IOError
      nil
    end

    def parse_array(text)
      return nil if text.nil?

      parsed = JSON.parse(text)
      parsed.is_a?(Array) ? parsed : nil
    rescue JSON::ParserError, EncodingError
      nil
    end

    # One Jev call per ranked candidate, best first. The first non-ok outcome
    # stops the run: the rest are not_judged, so a failing or refusing client
    # costs one attempt, not one per candidate.
    def judge_all(env, config, options, mode, description, ranked, http_class)
      d = env.data
      stopped = nil
      ranked.each do |cand|
        entry = { "id" => cand["id"], "title_overlap" => cand["title_overlap"],
                  "body_overlap" => cand["body_overlap"], "jev_yes" => nil,
                  "action" => "not_judged", "reason" => stopped, "call_id" => nil }
        d[:candidates] << entry
        next if stopped

        stopped = judge_one(env, config, options, mode, description, cand, entry, http_class)
      end
      d[:likely_duplicates] = d[:candidates].select { |c| c["action"] == "flagged" }.map { |c| c["id"] }
      fallbacks = d[:candidates].count { |c| c["action"] == "fallback" }
      top = if options[:dry_run] && stopped.nil? then "dry_run"
            elsif fallbacks.positive? then "fallback"
            else "judged"
            end
      finish(d, top, stopped)
    rescue SystemCallError, IOError => e
      env.warn(code: "state_dir_error",
               message: "reading or writing typesafe.state_dir failed (#{e.class.name}); filing " \
                        "is unchanged")
      d[:candidates].each do |c|
        next unless c["action"] == "flagged"

        c["action"] = "fallback"
        c["reason"] = "state_dir_error"
      end
      d[:likely_duplicates] = []
      finish(d, "fallback", "state_dir_error")
    end

    # Fills entry; returns nil to go on, or the outcome label that stops the
    # run.
    def judge_one(env, config, options, mode, description, cand, entry, http_class)
      d = env.data
      input = BeadDedupe.input_for(new_title: options[:title], new_description: description,
                                   candidate: cand, source: options[:source])
      result = Typesafe.judge(config: config, input: input, site: BeadDedupe::SITE,
                              dry_run: options[:dry_run], http_class: http_class)
      fill_result(env, result, options[:dry_run])
      entry["call_id"] = result.call_id
      if options[:dry_run] && result.outcome == "ok"
        d[:request] ||= result.request
        entry["action"] = "dry_run"
        entry["reason"] = nil
        return nil
      end

      read = BeadDedupe.interpret(result, mode: mode, threshold: options[:threshold])
      entry["jev_yes"] = read["jev_yes"]
      entry["action"] = read["action"]
      entry["reason"] = read["reason"]
      if read["action"] == "fallback"
        fallback_warning(env, read["reason"], result.reason)
      end
      record(config, entry, result) unless options[:dry_run]
      result.outcome == "ok" ? nil : result.outcome
    end

    def fill_result(env, result, dry_run)
      d = env.data
      d[:outcome] = result.outcome
      d[:threshold_key] = result.threshold_key || d[:threshold_key]
      sent = dry_run ? false : SENT.include?(result.outcome)
      if sent
        d[:calls] += 1
        env.commands << REQUEST_COMMAND unless env.commands.include?(REQUEST_COMMAND)
      elsif dry_run && result.outcome == "ok"
        env.commands << REQUEST_COMMAND unless env.commands.include?(REQUEST_COMMAND)
      end
      unless result.cost_usd.nil?
        d[:cost_usd] = (d[:cost_usd] || 0) + result.cost_usd
      end
      Array(result.warnings).each { |w| client_warning(env, w) }
    end

    # The caller's outcome line: decision = what the filer does anyway
    # (files, unlinked), action = this pair's action. Labels only.
    def record(config, entry, result)
      return if result.call_id.nil? || result.outcome == "site_off"

      Typesafe.record_outcome(config: config, call_id: result.call_id, site: BeadDedupe::SITE,
                              action: entry["action"], decision: DECISION, agreement: "n/a")
    end

    def finish(d, action, reason)
      d[:action] = action
      d[:reason] = reason unless reason.nil?
      d[:journal_line] = journal_line(d)
      nil
    end

    # The detail is the client's reason label (budget_unset, an exception
    # class), never text.
    def fallback_warning(env, reason, detail)
      named = detail.nil? || detail == reason ? reason : "#{reason}: #{detail}"
      env.warn(code: "jev_fallback",
               message: "Jev gave no usable answer (#{named}); filing is unchanged. A fallback " \
                        "is never read as a no.")
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

    # One line for a journal. Ids, labels and numbers only: never bead text.
    def journal_line(d)
      judged = d[:candidates].reject { |c| c["jev_yes"].nil? }
                             .map { |c| "#{c['id']} #{format('%.2f', c['jev_yes'])}" }
      flagged = d[:likely_duplicates].empty? ? "flagged nothing" : "flagged #{d[:likely_duplicates].join(' ')}"
      extra = d[:reason] ? " (#{d[:reason]})" : ""
      "[probe] bead_dedupe: #{d[:candidates].size} candidate(s), jev #{judged.empty? ? '-' : judged.join(', ')}, " \
        "mode #{d[:mode]}, action #{d[:action]}#{extra}; #{flagged}; filing unchanged"
    end
  end
end

exit BeadDedupeCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

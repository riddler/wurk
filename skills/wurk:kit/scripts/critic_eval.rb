#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/cli"

# CriticEval scores SAVED review-agent output against a labeled fixture
# corpus, so a consumer can say whether one of its review agents has earned
# the authority /wurk:mr already gives a must-fix finding: the round blocks
# the request on it. Nothing else in the kit measures that, and an agent
# whose must-fix findings are half noise trains a reader to wave the round
# through - which costs more than no round at all.
#
# It never runs a model. The agent run is a hand-run or skill-driven step
# that saves each case's output to a file; this script only reads those
# files, applies the corpus labels, and reports precision and recall. That
# split is deliberate and is the contract (ADR-0006): a script is
# deterministic and step-scoped, so the same saved outputs score the same
# way twice, and a red bar is never a model having a bad afternoon.
#
# It is also read-only: it reports the numbers and whether they clear the
# bar. Whether to promote an advisory agent to blocking is the reader's
# call (ADR-0008); a script that flipped a manifest field on a score would
# be making that call for them.
#
# Corpus layout (docs/recipes/review-agents.md, "Trusting a critic"):
#
#   <corpus>/<case-id>/diff       the diff the agent was given
#   <corpus>/<case-id>/meta.json  {"label": "bad"|"good", ...}
#   <outputs>/<case-id>.md        that case's saved agent output
module CriticEval
  # The severity vocabulary /wurk:mr honors, strongest first. A consumer
  # whose agents ship another vocabulary passes --severity for the word its
  # agents use as the blocking rank; the scoring is the same shape either
  # way, which is why this list is a default and not a validation.
  SEVERITIES = %w[must-fix should-fix note].freeze

  DEFAULT_SEVERITY = "must-fix"
  DEFAULT_BAR = 0.8

  LABELS = %w[bad good].freeze

  class << self
    # Every finding in a saved agent output, as
    # [{severity:, line:, text:, body:}]. :text is the severity-bearing
    # line itself; :body is that line plus the lines under it, which is
    # where an agent puts what it actually found.
    #
    # Two rules, both about the shapes agent output really takes:
    #
    # - One severity per line. A line naming two or more is not a finding:
    #   an agent's output routinely restates the whole vocabulary
    #   ("Severity: must-fix / should-fix / note") in a header or a legend,
    #   and counting that as three findings would score the template
    #   rather than the review. The cost is a real finding that names a
    #   second severity in passing on its own line, the rarer shape.
    # - A finding runs until the next finding or the next heading. The
    #   severity and the explanation are almost never the same line
    #   ("3. lib/a.rb:14 - must-fix" with the prose under it), so a
    #   corpus's expected substring has to be matched against the block,
    #   not the one line that carries the rank.
    def findings(text, severities: SEVERITIES)
      lines = text.to_s.lines
      starts = []
      lines.each_with_index do |raw, idx|
        hits = severities.select { |sev| raw =~ severity_matcher(sev) }
        starts << [idx, hits.first] if hits.length == 1
      end

      starts.each_with_index.map do |(idx, severity), n|
        next_start = starts[n + 1] ? starts[n + 1][0] : lines.length
        stop = body_end(lines, idx, next_start)
        {
          severity: severity,
          line: idx + 1,
          text: lines[idx].rstrip,
          body: lines[idx...stop].join.rstrip
        }
      end
    end

    # Where a finding's block stops: the next finding, or the first
    # heading before it - a "## Checks that passed" section under the last
    # finding is not part of that finding.
    def body_end(lines, start_idx, next_start)
      ((start_idx + 1)...next_start).each do |i|
        return i if lines[i] =~ /\A\s{0,3}\#{1,6}\s/
      end
      next_start
    end

    # Word-boundary and case-insensitive, so `**must-fix**`, `- must-fix:`
    # and `MUST-FIX` all count, while `must-fix-later` does not. \b does
    # not close a hyphenated word on its own (the hyphen is already a
    # boundary), so the tail is spelled as "not an identifier character".
    def severity_matcher(severity)
      /(?<![\w-])#{Regexp.escape(severity)}(?![\w-])/i
    end

    # The findings that would block a request: the ones ranked at the
    # blocking severity. Nothing here promotes an unranked line or a weaker
    # one, the same rule /wurk:mr states for the live round.
    def blocking(findings, severity)
      findings.select { |f| f[:severity] == severity }
    end

    # Scores one case. Returns
    # {id:, label:, outcome:, matched:, findings_count:, blocking_count:}
    # where outcome is one of "hit", "miss", "false_positive",
    # "true_negative".
    #
    # A bad case is a hit when the agent produced at least one blocking
    # finding that also satisfies the case's `expect.contains` substring,
    # when it names one. The substring is what keeps a hit honest: an agent
    # that ranks everything must-fix would otherwise score a perfect recall
    # by accident, and the corpus's whole job is to tell that apart from
    # an agent that found the planted defect.
    def score_case(id:, meta:, findings:, severity:)
      blocking_findings = blocking(findings, severity)
      wanted = expected_substring(meta)
      matched = blocking_findings.select { |f| wanted.nil? || f[:body].downcase.include?(wanted) }

      outcome =
        if meta["label"] == "bad"
          matched.empty? ? "miss" : "hit"
        else
          blocking_findings.empty? ? "true_negative" : "false_positive"
        end

      {
        id: id,
        label: meta["label"],
        outcome: outcome,
        expected: wanted,
        findings_count: findings.length,
        blocking_count: blocking_findings.length
      }
    end

    def expected_substring(meta)
      expect = meta["expect"]
      return nil unless expect.is_a?(Hash)

      value = expect["contains"].to_s.strip
      value.empty? ? nil : value.downcase
    end

    # The case's own blocking severity: `expect.severity` when the case
    # names one, otherwise the run's severity. A corpus can hold a case
    # that is only ever a should-fix and still be scored against an agent
    # whose bar is must-fix.
    def case_severity(meta, default)
      expect = meta["expect"]
      return default unless expect.is_a?(Hash)

      value = expect["severity"].to_s.strip
      value.empty? ? default : value
    end

    # Counts -> {precision:, recall:} as floats rounded to four places, or
    # nil for a ratio with no denominator. nil is not zero and not one:
    # "this corpus cannot measure precision" is a different statement from
    # "this agent's precision is zero", and a caller that rounds the
    # difference away reports a bar cleared or failed on nothing.
    def metrics(counts)
      positives = counts[:hit] + counts[:false_positive]
      actual_bad = counts[:hit] + counts[:miss]

      {
        precision: positives.zero? ? nil : ratio(counts[:hit], positives),
        recall: actual_bad.zero? ? nil : ratio(counts[:hit], actual_bad)
      }
    end

    def ratio(numerator, denominator)
      (numerator.to_f / denominator).round(4)
    end

    def empty_counts
      { hit: 0, miss: 0, false_positive: 0, true_negative: 0 }
    end

    # Whether a scored run clears the bar. false when either ratio is
    # unmeasurable - an unmeasured half is not a passed half.
    def meets_bar?(metrics, bar)
      return false if metrics[:precision].nil? || metrics[:recall].nil?

      metrics[:precision] >= bar && metrics[:recall] >= bar
    end

    # The case directories of a corpus: every direct child holding a
    # meta.json, sorted, so a run over the same corpus reports in the same
    # order twice.
    def case_ids(corpus_dir)
      Dir.children(corpus_dir)
         .select { |name| File.exist?(File.join(corpus_dir, name, "meta.json")) }
         .sort
    end

    # Whether this case belongs to the agent being scored. A case with no
    # `agent` key belongs to every agent - a corpus that starts with one
    # critic should not have to be relabeled when a second one arrives.
    def for_agent?(meta, agent)
      return true if agent.nil?

      named = meta["agent"].to_s.strip
      named.empty? || named == agent
    end
  end
end

# CLI wrapper.
class CriticEvalCli
  class << self
    def run(argv, io = $stdout)
      options = {
        corpus: nil,
        outputs: nil,
        agent: nil,
        severity: CriticEval::DEFAULT_SEVERITY,
        bar: CriticEval::DEFAULT_BAR
      }

      parser, options = Cli.build(
        "critic_eval.rb --corpus DIR --outputs DIR [--agent NAME] [--severity WORD] [--bar N]",
        options
      ) do |opts|
        opts.on("--corpus DIR", "labeled fixture corpus (a directory of case directories)") { |v| options[:corpus] = v }
        opts.on("--outputs DIR", "directory of saved agent outputs, one <case-id>.md per case") { |v| options[:outputs] = v }
        opts.on("--agent NAME", "score only the cases this agent owns") { |v| options[:agent] = v }
        opts.on("--severity WORD", "the rank treated as blocking (default must-fix)") { |v| options[:severity] = v }
        opts.on("--bar N", "the precision/recall bar (default 0.8)") { |v| options[:bar] = Float(v) }
      end
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "critic_eval")

      return env.emit(io) unless check_dirs(env, options)

      score(env, options)
      env.emit(io)
    rescue ArgumentError => e
      warn "invalid --bar: #{e.message}"
      exit 2
    end

    def check_dirs(env, options)
      { corpus: "--corpus", outputs: "--outputs" }.each do |key, flag|
        value = options[key].to_s.strip
        if value.empty?
          env.block!(code: "missing_#{key}", message: "#{flag} is required")
          next
        end
        env.block!(code: "#{key}_not_found", message: "no such directory: #{value}") unless File.directory?(value)
      end
      env.blocked.empty?
    end

    def score(env, options)
      corpus = options[:corpus]
      outputs = options[:outputs]
      counts = CriticEval.empty_counts
      cases = []
      seen_outputs = []

      CriticEval.case_ids(corpus).each do |id|
        meta = read_meta(env, corpus, id)
        next if meta.nil?
        next unless CriticEval.for_agent?(meta, options[:agent])

        unless CriticEval::LABELS.include?(meta["label"])
          env.block!(code: "bad_label", message: "#{id}/meta.json: label must be one of #{CriticEval::LABELS.join(', ')}")
          next
        end

        output_path = File.join(outputs, "#{id}.md")
        unless File.file?(output_path)
          env.block!(code: "missing_output", message: "no saved output for case #{id} (expected #{output_path})")
          next
        end
        seen_outputs << "#{id}.md"

        severity = CriticEval.case_severity(meta, options[:severity])
        # A consumer vocabulary the default list does not carry still has to
        # be findable, or every case scores as a miss on a spelling.
        vocabulary = CriticEval::SEVERITIES | [severity, options[:severity]]
        findings = CriticEval.findings(File.read(output_path), severities: vocabulary)
        scored = CriticEval.score_case(id: id, meta: meta, findings: findings, severity: severity)
        scored[:severity] = severity
        counts[scored[:outcome].to_sym] += 1
        cases << scored
      end

      warn_unmatched(env, outputs, seen_outputs)
      report(env, options, counts, cases)
    end

    def read_meta(env, corpus, id)
      path = File.join(corpus, id, "meta.json")
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      env.block!(code: "bad_meta", message: "#{path}: #{e.message}")
      nil
    end

    # A saved output with no case in the corpus is a warning, never a
    # block: it is usually a case that was removed or an agent's output
    # saved under a typo'd name, and neither invalidates the run.
    def warn_unmatched(env, outputs, seen)
      stray = Dir.children(outputs).select { |f| f.end_with?(".md") } - seen
      return if stray.empty?

      env.warn(code: "unmatched_output", message: "saved output with no case in the corpus: #{stray.sort.join(', ')}")
    end

    def report(env, options, counts, cases)
      metrics = CriticEval.metrics(counts)
      meets = CriticEval.meets_bar?(metrics, options[:bar])

      env.data[:corpus] = options[:corpus]
      env.data[:outputs] = options[:outputs]
      env.data[:agent] = options[:agent]
      env.data[:severity] = options[:severity]
      env.data[:bar] = options[:bar]
      env.data[:counts] = counts
      env.data[:precision] = metrics[:precision]
      env.data[:recall] = metrics[:recall]
      env.data[:meets_bar] = meets
      env.data[:cases] = cases

      if cases.empty?
        env.warn(code: "empty_corpus", message: "no cases scored - nothing was measured")
      else
        warn_unmeasurable(env, metrics)
      end

      return if cases.empty? || meets

      env.warn(
        code: "below_trust_bar",
        message: "precision #{fmt(metrics[:precision])} / recall #{fmt(metrics[:recall])} " \
                 "is below the #{options[:bar]} bar - run this agent advisory, not blocking"
      )
    end

    def warn_unmeasurable(env, metrics)
      if metrics[:precision].nil?
        env.warn(code: "precision_unmeasured",
                 message: "no blocking findings at all - precision has no denominator")
      end
      return unless metrics[:recall].nil?

      env.warn(code: "recall_unmeasured", message: "no cases labeled bad - recall has no denominator")
    end

    def fmt(value)
      value.nil? ? "n/a" : value.to_s
    end
  end
end

exit CriticEvalCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

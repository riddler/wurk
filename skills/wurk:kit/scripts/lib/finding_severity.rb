# frozen_string_literal: true

# The finding_severity Jev site: a second opinion on the severity of each
# finding a pre-request review round returned, and the per-level count a
# worker's report carries (reviewRound.findingsByLevel). Built to the site
# pattern in kit REFERENCE.md ("`report_triage.rb`: the report_triage Jev
# site", "The site pattern"); its own contract is the section
# "`finding_severity.rb`: the finding_severity Jev site".
#
# This module is pure: it maps a critic's own rank to a level, builds the
# input, reads the answer and counts. The CLI (finding_severity.rb) does the
# I/O, the gating and the logging.
module FindingSeverity
  SITE = "finding_severity"
  # Index = the score level Jev answers with, lowest first.
  LEVELS = %w[note should-fix must-fix].freeze
  # A finding whose reporting agent stated no level in the kit vocabulary.
  # It ranks below note: an unranked finding is not a blocker (wurk:mr's
  # review-round rule), and any level Jev gives it is a raise.
  UNRANKED = "unranked"
  # The report field's keys, per level, in the report JSON's camelCase.
  BUCKETS = { "must-fix" => "mustFix", "should-fix" => "shouldFix", "note" => "note",
              UNRANKED => "unranked" }.freeze

  # ANY change to the question's instructions or criteria below is a new
  # QUESTION_SET version (the call-site contract's rule): a threshold is keyed
  # by site + question-set id@version + pinned model, so a reworded question
  # must start unthresholded.
  QUESTION_SET = { "id" => "finding_severity", "version" => 1 }.freeze

  # \x60 is a backtick, escaped so contract_test.rb's backtick-execution
  # scan does not read the quoted state key as a shell-out. Each level is a
  # concrete situation that stands on its own.
  QUESTIONS = {
    "severity" => {
      "type" => "score",
      "instructions" => "A code reviewer wrote \x60finding\x60 about a proposed change to a " \
                        "codebase, before the change is merged. Judging only from " \
                        "\x60finding\x60, how serious is what it describes?",
      "criteria" => [
        "A real observation the author may reasonably decline: naming, style, a clearer " \
        "wording, or a possible improvement. Nothing the change does is wrong.",
        "The change works for what it was asked to do, but a reviewer will ask for this " \
        "before approving: an edge case unlikely to be hit soon, a weak or misleading test, " \
        "or documentation that no longer matches the code.",
        "The change should not merge with this in it: it breaks behavior the task asked for, " \
        "loses or corrupts data, exposes a secret, bypasses a safety check, or leaves a " \
        "test that cannot fail guarding behavior the task depends on."
      ]
    }.freeze
  }.freeze

  ACTIONS = %w[site_off skipped dry_run shadow_logged raised no_change fallback].freeze

  class << self
    # The level the reporting agent gave, in the kit vocabulary. The agent's
    # own must-fix declaration wins over any label; a label outside the
    # vocabulary (another consumer's words) or none at all is unranked. Code
    # does this mapping; Jev never sees the label (sending a self-stated
    # label makes the judgment label-reading).
    def critic_level(finding)
      return UNRANKED unless finding.is_a?(Hash)
      return "must-fix" if finding["mustFix"] == true

      rank = finding["rank"]
      return UNRANKED unless rank.is_a?(String)

      label = rank.strip.downcase.tr(" _", "--")
      LEVELS.include?(label) ? label : UNRANKED
    end

    def rank_of(level)
      level == UNRANKED ? -1 : LEVELS.index(level)
    end

    # {"finding" => text} or nil when there is nothing to judge. Only the
    # finding's own prose: never its rank (a self-stated label), its agent
    # (identity), or any other field.
    def state_for(finding)
      return nil unless finding.is_a?(Hash)

      text = finding["text"]
      return nil unless text.is_a?(String) && !text.strip.empty?

      { "finding" => text }
    end

    # The Typesafe.judge input, or nil when there is nothing to judge. The
    # source label is always set: the privacy refusal depends on it.
    def input_for(finding, source:)
      state = state_for(finding)
      return nil if state.nil?

      { "state" => state, "questions" => QUESTIONS, "question_set" => QUESTION_SET,
        "source" => source }
    end

    # Reads one Typesafe::Result against the critic's own level. Jev may add
    # caution, never remove it: `level` is never below critic_level, a
    # critic's must-fix stays must-fix whatever Jev says, and only on mode
    # with a threshold met can Jev RAISE a level. Shadow never acts.
    def interpret(result, mode:, critic_level:, threshold:)
      out = { "jev_level" => nil, "jev_confidence" => nil, "agreement" => "n/a",
              "level" => critic_level, "action" => "fallback", "reason" => nil }
      # A failure is never read as an answer.
      unless result.outcome == "ok"
        out["reason"] = result.outcome
        return out
      end

      answers = result.answers.is_a?(Hash) ? result.answers : {}
      level, confidence = severity_answer(answers["severity"])
      if level.nil?
        out["reason"] = "answer_malformed"
        return out
      end

      out["jev_level"] = level
      out["jev_confidence"] = confidence
      out["agreement"] = agreement(critic_level, level)
      if mode == "on"
        decide_on(out, critic_level, level, confidence, threshold)
      else
        out["action"] = "shadow_logged"
      end
      out
    end

    # "agree", "disagree", or "n/a" for an unranked critic (nothing to agree
    # with).
    def agreement(critic_level, jev_level)
      return "n/a" if critic_level == UNRANKED

      critic_level == jev_level ? "agree" : "disagree"
    end

    # The report field: a count per bucket, every bucket present. Counting is
    # code, never Jev.
    def counts(levels)
      out = {}
      BUCKETS.each_value { |key| out[key] = 0 }
      levels.each { |level| out[BUCKETS.fetch(level)] += 1 }
      out
    end

    private

    # [level, probability] from a score answer, or [nil, nil] when malformed.
    # The level is the most probable one (a tie goes to the higher level:
    # the cautious read); its probability is the confidence a threshold is
    # compared with.
    def severity_answer(answer)
      return [nil, nil] unless answer.is_a?(Hash)

      probs = answer["probabilities"]
      return [nil, nil] unless probs.is_a?(Hash)

      best = nil
      LEVELS.each_index do |i|
        p = probs[i.to_s]
        return [nil, nil] unless p.is_a?(Numeric) && p >= 0 && p <= 1

        best = i if best.nil? || p >= probs[best.to_s]
      end
      [LEVELS[best], probs[best.to_s].to_f]
    end

    # The on-mode rule: raise ONLY when Jev's level is above the critic's and
    # Jev's confidence meets the eval tooling's threshold. Every other case
    # keeps the critic's level.
    def decide_on(out, critic_level, level, confidence, threshold)
      reason =
        if critic_level == "must-fix" then "critic_must_fix" # never downgraded
        elsif rank_of(level) <= rank_of(critic_level) then "jev_not_higher" # never lowers
        elsif threshold.nil? then "no_threshold"
        elsif confidence < threshold then "below_threshold"
        end
      if reason
        out["action"] = "no_change"
        out["reason"] = reason
      else
        out["action"] = "raised"
        out["level"] = level
      end
    end
  end
end

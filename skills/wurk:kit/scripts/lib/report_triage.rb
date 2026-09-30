# frozen_string_literal: true

# The report_triage Jev site: a second opinion on a worker's report file,
# asked after the conductor has classified the report itself. It is the first
# call site built on lib/typesafe.rb and the pattern later sites copy (kit
# REFERENCE.md, "`report_triage.rb`: the report_triage Jev site" and its
# "The site pattern" checklist).
#
# This module is pure: it builds the input and reads the answer. The CLI
# (report_triage.rb) does the I/O, the gating and the logging.
module ReportTriage
  SITE = "report_triage"
  CLASSES = %w[done blocked stuck].freeze
  # The classes that already surface a report to the operator.
  FLAGGED = %w[blocked stuck].freeze

  # ANY change to a question's instructions or criteria below is a new
  # QUESTION_SET version (the call-site contract's rule): a threshold is keyed
  # by site + question-set id@version + pinned model, so a reworded question
  # must start unthresholded rather than inherit a threshold measured against
  # different words.
  QUESTION_SET = { "id" => "report_triage", "version" => 1 }.freeze

  # \x60 is a backtick, escaped so contract_test.rb's backtick-execution
  # scan does not read the quoted state key as a shell-out.
  QUESTIONS = {
    "state" => {
      "type" => "choice",
      "instructions" => "A worker agent wrote \x60report\x60 when it stopped working one task. " \
                        "Judging only from \x60report\x60, where does that task stand?",
      "criteria" => {
        "done" => "The work the task asked for is finished: the report records what was " \
                  "built or changed, and no open question, dependency or deferred item in " \
                  "it waits on anyone.",
        "blocked" => "The worker stopped because it needs something outside itself: a " \
                     "decision or ruling from a person, a permission it was not given, or " \
                     "another task that must land first.",
        "stuck" => "The work is not finished and the report names no outside dependency " \
                   "that would unblock it: an unexplained failure, a test that stays red, " \
                   "the same attempt repeated, or a gap the worker could not fill."
      }
    }.freeze,
    "urgency" => {
      "type" => "score",
      "instructions" => "How soon must the operator act on \x60report\x60?",
      "criteria" => [
        "Nothing to do: the report needs no action from the operator.",
        "Read at the next review: worth reading, but nothing waits on the operator.",
        "Something waits on the operator: a question or decision in the report holds " \
        "further work until the operator answers it.",
        "Act now: work is stopped, broken or unsafe until the operator responds."
      ]
    }.freeze
  }.freeze

  # The report fields sent to Jev: the worker's own prose about where it
  # stands. Deliberately NOT sent:
  # - `status`: a self-stated label. Sending it makes the judgment
  #   label-reading, which measures nothing the conductor does not already
  #   have (the same reason eval corpora redact self-stated labels).
  # - `gate`, `committed`: facts code already has; nothing to judge.
  # - identity: bead, repo, branch, sha, mr, repos_touched, scopeAuthority.
  #   Identity and counting stay out of Jev; code owns them.
  # - any field not listed here, including a later optional report field: it
  #   is excluded until a new question-set version adds it on purpose.
  PROSE_FIELDS = %w[openQuestions judgementCalls discoveredDeps notesWritten].freeze
  # reviewRound is otherwise counts and agent names; only its deferred list
  # is prose.
  REVIEW_PROSE_FIELDS = %w[deferred].freeze

  ACTIONS = %w[fallback shadow_logged needs_you_added no_change].freeze

  class << self
    # {"report" => {whitelisted, non-empty prose}} or nil when there is
    # nothing to judge (not a Hash, or every prose field absent or blank).
    def state_for(report)
      return nil unless report.is_a?(Hash)

      out = {}
      PROSE_FIELDS.each do |name|
        value = prose(report[name])
        out[name] = value unless value.nil?
      end
      review = report["reviewRound"]
      if review.is_a?(Hash)
        kept = {}
        REVIEW_PROSE_FIELDS.each do |name|
          value = prose(review[name])
          kept[name] = value unless value.nil?
        end
        out["reviewRound"] = kept unless kept.empty?
      end
      out.empty? ? nil : { "report" => out }
    end

    # The Typesafe.judge input, or nil when there is nothing to judge. The
    # source label is always set: the privacy refusal depends on it.
    def input_for(report, source:)
      state = state_for(report)
      return nil if state.nil?

      { "state" => state, "questions" => QUESTIONS, "question_set" => QUESTION_SET,
        "source" => source }
    end

    # Reads a Typesafe::Result against the conductor's own class. Jev may add
    # caution, never remove it: there is no action here that clears, removes,
    # downgrades or marks anything done, and add_needs_you is the only field
    # that can change what the caller does. Urgency is recorded and journaled
    # only; it never adds an item in this question-set version.
    def interpret(result, mode:, conductor:, threshold:)
      out = { "jev_class" => nil, "jev_confidence" => nil, "urgency" => nil,
              "agreement" => "n/a", "add_needs_you" => false, "action" => "fallback",
              "reason" => nil }
      # A failure is never read as an answer.
      unless result.outcome == "ok"
        out["reason"] = result.outcome
        return out
      end

      answers = result.answers.is_a?(Hash) ? result.answers : {}
      choice, confidence = state_answer(answers["state"])
      if choice.nil?
        out["reason"] = "answer_malformed"
        return out
      end

      out["jev_class"] = choice
      out["jev_confidence"] = confidence
      out["urgency"] = urgency_answer(answers["urgency"])
      out["agreement"] = choice == conductor ? "agree" : "disagree"
      if mode == "on"
        decide_on(out, choice, confidence, conductor, threshold)
      else
        # Shadow never acts: the conductor's own read is the decision.
        out["action"] = "shadow_logged"
      end
      out
    end

    private

    # nil for absent, blank or unusable values; a non-blank string; or an
    # array of non-blank strings (a discoveredDeps entry contributes its
    # summary only - its owningRepo and existingBead are identity).
    def prose(value)
      case value
      when String
        value.strip.empty? ? nil : value
      when Array
        items = []
        value.each do |item|
          text = item.is_a?(Hash) ? item["summary"] : item
          items << text if text.is_a?(String) && !text.strip.empty?
        end
        items.empty? ? nil : items
      end
    end

    # [choice, probability] or [nil, nil] when the state answer is malformed.
    def state_answer(answer)
      return [nil, nil] unless answer.is_a?(Hash)

      choice = answer["choice"]
      return [nil, nil] unless CLASSES.include?(choice)

      probs = answer["probabilities"]
      prob = probs.is_a?(Hash) ? probs[choice] : nil
      return [nil, nil] unless prob.is_a?(Numeric) && prob >= 0 && prob <= 1

      [choice, prob.to_f]
    end

    # The score as a float within the question's level range, else nil.
    def urgency_answer(answer)
      return nil unless answer.is_a?(Hash)

      score = answer["score"]
      max = QUESTIONS["urgency"]["criteria"].size - 1
      return nil unless score.is_a?(Numeric) && score >= 0 && score <= max

      score.to_f
    end

    # The on-mode rule: add ONLY when the conductor said done, Jev says
    # blocked or stuck, and Jev's confidence meets the eval tooling's
    # threshold. Every other case changes nothing.
    def decide_on(out, choice, confidence, conductor, threshold)
      reason =
        if choice == "done" then "jev_done" # Jev never clears or downgrades.
        elsif FLAGGED.include?(conductor) then "conductor_flagged" # already surfaced
        elsif threshold.nil? then "no_threshold"
        elsif confidence < threshold then "below_threshold"
        end
      if reason
        out["action"] = "no_change"
        out["reason"] = reason
      else
        out["action"] = "needs_you_added"
        out["add_needs_you"] = true
      end
    end
  end
end

# frozen_string_literal: true

# The bead_dedupe Jev site: before a bead is filed, find the open beads it
# might duplicate. Candidate search is plain code (title and description
# token overlap, counted here, never in Jev); Jev then answers one yes/no
# (a Noul) per candidate pair. It follows the site pattern in kit
# REFERENCE.md ("`report_triage.rb`: the report_triage Jev site", "The site
# pattern"); its own contract is "`bead_dedupe.rb`: the bead_dedupe Jev
# site".
#
# This module is pure: it ranks candidates, builds the input and reads the
# answer. The CLI (bead_dedupe.rb) does the I/O, the gating and the logging.
# Nothing here files, refuses, closes, edits or blocks a bead.
module BeadDedupe
  SITE = "bead_dedupe"

  # ANY change to the question's instructions or criteria below is a new
  # QUESTION_SET version (the call-site contract's rule): a threshold is keyed
  # by site + question-set id@version + pinned model, so a reworded question
  # must start unthresholded.
  QUESTION_SET = { "id" => "bead_dedupe", "version" => 1 }.freeze

  # \x60 is a backtick, escaped so contract_test.rb's backtick-execution
  # scan does not read the quoted state key as a shell-out.
  QUESTIONS = {
    "same_issue" => {
      "type" => "noul",
      "instructions" => "\x60new_bead\x60 is an issue about to be filed in a work tracker, and " \
                        "\x60candidate\x60 is an open issue already in it. Do they describe the " \
                        "same problem or the same piece of work, so that finishing one would " \
                        "also finish the other?",
      "criteria" => {
        "true" => "Both describe the same underlying problem or change, even when they are " \
                  "worded differently or one gives more detail than the other.",
        "false" => "They describe different problems or different pieces of work, even when " \
                   "they touch the same area, file or words. One being a part, a follow-up, " \
                   "or a prerequisite of the other is not the same issue."
      }
    }.freeze
  }.freeze

  # The per-candidate actions. None of them files, refuses, closes, edits or
  # blocks anything, and none removes a keyword candidate from the list the
  # filer sees: Jev may add a flag, never take one away.
  ACTIONS = %w[dry_run shadow_logged flagged no_change fallback not_judged].freeze

  DEFAULT_MAX_CANDIDATES = 3
  MAX_CANDIDATES_LIMIT = 10
  # Each side's text is cut to this many characters before it is sent: the
  # judgment needs the gist, and the cut bounds the cost of one call.
  MAX_TEXT_CHARS = 1500
  # A candidate with no title word in common still qualifies when the two
  # beads share at least this many words across title and description.
  MIN_BODY_OVERLAP = 5
  MIN_TOKEN_LENGTH = 3
  STOPWORDS = %w[
    the and for with from into onto that this these those when then than what which who
    are was were been being has have had not but its our out one all any can could
    should would will may might must does did doing done also only just more most some
    such each every per via own same other there their them they you your his her
    about after before over under while where why how new use used uses using
  ].freeze

  class << self
    # Lower-cased word tokens: stopwords and short words dropped, a plural
    # "s" folded (notes -> note), duplicates removed. Plain code, so the
    # counting it feeds never reaches Jev.
    def tokens(text)
      return [] unless text.is_a?(String)

      words = text.downcase.scan(/[a-z0-9]+/)
      out = []
      words.each do |w|
        next if w.length < MIN_TOKEN_LENGTH || STOPWORDS.include?(w)

        w = w[0..-2] if w.length > 4 && w.end_with?("s") && !w.end_with?("ss")
        out << w
      end
      out.uniq
    end

    # The candidates worth a Jev call, best first, at most `max`. Each is
    # {"id", "title", "description", "title_overlap", "body_overlap"}. A
    # candidate qualifies on one shared title word, or on MIN_BODY_OVERLAP
    # shared words across title and description. Entries without a string id
    # and title are dropped.
    def rank(new_title:, new_description:, candidates:, max:)
      new_title_tokens = tokens(new_title)
      new_all = (new_title_tokens + tokens(new_description)).uniq
      scored = []
      Array(candidates).each do |cand|
        next unless usable?(cand)

        title_tokens = tokens(cand["title"])
        all = (title_tokens + tokens(cand["description"])).uniq
        title_overlap = (new_title_tokens & title_tokens).size
        body_overlap = (new_all & all).size
        next unless title_overlap >= 1 || body_overlap >= MIN_BODY_OVERLAP

        scored << { "id" => cand["id"], "title" => cand["title"],
                    "description" => cand["description"].is_a?(String) ? cand["description"] : "",
                    "title_overlap" => title_overlap, "body_overlap" => body_overlap }
      end
      scored.sort_by { |c| [-c["title_overlap"], -c["body_overlap"], c["id"]] }.first(max)
    end

    # The Typesafe.judge input for one pair. Only the two beads' titles and
    # descriptions are sent: no id, status, priority, labels, assignee or
    # dates (identity and self-stated labels stay out of Jev). The source
    # label is always set: the privacy refusal depends on it.
    def input_for(new_title:, new_description:, candidate:, source:)
      state = {
        "new_bead" => side(new_title, new_description),
        "candidate" => side(candidate["title"], candidate["description"])
      }
      { "state" => state, "questions" => QUESTIONS, "question_set" => QUESTION_SET,
        "source" => source }
    end

    # Reads one pair's Typesafe::Result. Returns {"jev_yes", "action",
    # "reason", "flagged"}. Only on mode with a threshold met flags; a
    # non-ok outcome or a malformed answer is a fallback and never read as
    # a "no".
    def interpret(result, mode:, threshold:)
      out = { "jev_yes" => nil, "action" => "fallback", "reason" => nil, "flagged" => false }
      unless result.outcome == "ok"
        out["reason"] = result.outcome
        return out
      end

      yes = noul_answer(result.answers)
      if yes.nil?
        out["reason"] = "answer_malformed"
        return out
      end

      out["jev_yes"] = yes
      if mode != "on"
        # Shadow never acts: the filer's own read is the decision.
        out["action"] = "shadow_logged"
        out["reason"] = nil
      elsif threshold.nil?
        out["action"] = "no_change"
        out["reason"] = "no_threshold"
      elsif yes < threshold
        out["action"] = "no_change"
        out["reason"] = "below_threshold"
      else
        out["action"] = "flagged"
        out["flagged"] = true
      end
      out
    end

    private

    def usable?(cand)
      cand.is_a?(Hash) && cand["id"].is_a?(String) && !cand["id"].strip.empty? &&
        cand["title"].is_a?(String) && !cand["title"].strip.empty?
    end

    def side(title, description)
      out = { "title" => clip(title) }
      text = description.is_a?(String) ? description.strip : ""
      out["description"] = clip(text) unless text.empty?
      out
    end

    def clip(text)
      text = text.to_s
      text.length > MAX_TEXT_CHARS ? text[0, MAX_TEXT_CHARS] : text
    end

    # The yes probability, or nil when the answer is missing or out of range.
    def noul_answer(answers)
      return nil unless answers.is_a?(Hash)

      answer = answers["same_issue"]
      return nil unless answer.is_a?(Hash)

      value = answer["noul"]
      return nil unless value.is_a?(Numeric) && value >= 0 && value <= 1

      value.to_f
    end
  end
end

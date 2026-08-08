# frozen_string_literal: true

# Summary turns a bead description into the one-line blurb the candidate
# table shows next to the title (st-sdv). Deterministic by decision, not by
# accident: see docs/skill-automation.md's "What is explicitly not routed to
# Haiku, and why" and statifier-ex ADR-0015. select_batch.rb is the only caller.
module Summary
  MAX_CHARS = 140

  # Sentence boundary: a terminator followed by whitespace and something
  # that can start a sentence. The uppercase-ish lookahead is what keeps
  # "bd 1.1.2" and ".beads/hooks/" from splitting.
  SENTENCE_END = /(?<=[.!?])\s+(?=[A-Z"'(\[])/.freeze

  # Boundaries that look like sentence ends but are not.
  ABBREVIATION = /\b(?:e\.g|i\.e|etc|vs|cf|approx|fig|no)\.\z/i.freeze

  class << self
    # nil for a blank/missing description - the key is always present in the
    # envelope so the table's column is never missing, and "this bead has no
    # description" is information the picker should see.
    def of(description, max: MAX_CHARS)
      return nil if description.nil?

      paragraph = first_paragraph(description)
      collapsed = collapse_whitespace(paragraph)
      return nil if collapsed.empty?

      sentence = first_sentence(collapsed)
      truncate(sentence, max)
    end

    private

    def first_paragraph(text)
      text.split(/\n\s*\n/, 2).first || ""
    end

    def collapse_whitespace(text)
      text.strip.gsub(/\s+/, " ")
    end

    # Scan candidate boundaries left to right, skipping any that end in an
    # abbreviation, and take the text up to the first real one. No real
    # boundary at all means the whole (collapsed) string is the "sentence".
    def first_sentence(text)
      pos = 0
      text.scan(SENTENCE_END) do
        match = ::Regexp.last_match
        candidate = text[0...match.begin(0)]
        unless candidate =~ ABBREVIATION
          pos = match.begin(0)
          break
        end
      end

      pos.zero? ? text : text[0...pos]
    end

    def truncate(text, max)
      return text if text.length <= max

      limit = max - 3
      cut = text[0..limit]
      last_space = cut.rindex(" ")
      truncated = last_space ? cut[0...last_space] : cut
      "#{truncated}..."
    end
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/summary"

class SummaryTest < Minitest::Test
  # sabotage: SENTENCE_END changed to /(?<=[.!?])/ (drop the whitespace/
  # lookahead requirement) so the first "." in "no." style abbreviations
  # would also split, but more directly: dropped the `text[0...pos]` cut and
  # returned the full collapsed text unconditionally -> red
  def test_multi_sentence_description_returns_only_the_first_sentence
    description = "Fixes the idle classifier on the NBSP prompt pad. Also touches the notes column."
    assert_equal "Fixes the idle classifier on the NBSP prompt pad.", Summary.of(description)
  end

  # sabotage: `limit = max - 3` changed to `limit = max` (stopped reserving
  # room for the ellipsis) -> red, the cut window reaches three chars
  # further right and picks up a later word boundary
  def test_first_sentence_over_the_cap_is_truncated_at_a_word_boundary
    # A space at index 130 and another at index 138 straddle the
    # max-3/max boundary (137/140), so the two candidate cut points land
    # on different spaces - the mutation is observable, not coincidental.
    sentence = "#{'a' * 130} #{'b' * 7} #{'c' * 20}."
    result = Summary.of(sentence)
    assert_equal "#{'a' * 130}...", result
    assert_equal 133, result.length
    assert result.end_with?("...")
  end

  # sabotage: ABBREVIATION regex's `e\.g` alternative changed to `x\.g`
  # -> red, "e.g." boundary no longer recognized as an abbreviation. The
  # word after "e.g." is capitalized so SENTENCE_END's lookahead actually
  # offers this boundary as a candidate in the first place.
  def test_embedded_eg_does_not_end_the_summary_early
    description = "Uses helpers, e.g. Foo and Bar, in the pipeline. Returns the result."
    assert_equal "Uses helpers, e.g. Foo and Bar, in the pipeline.", Summary.of(description)
  end

  # sabotage: first_sentence body replaced with `text.split(".").first`
  # (naive split on any period) -> red, "bd 1.1.2" truncates to "Run bd 1".
  # A whitespace-gated regex is what SENTENCE_END guards against this - a
  # naive period split has no way to tell "1.1.2" apart from a real end.
  def test_version_number_and_dotted_path_do_not_split
    description = "Run bd 1.1.2 against the repo, checking .beads/hooks/ for the install. It should succeed."
    assert_equal "Run bd 1.1.2 against the repo, checking .beads/hooks/ for the install.", Summary.of(description)
  end

  # sabotage: `text.split(/\n\s*\n/, 2).first` changed to `text` (skip the
  # paragraph split entirely) -> red, second paragraph leaks into the
  # result. Paragraph two starts lowercase and paragraph one has no
  # terminal punctuation, so first_sentence's own boundary detection
  # cannot mask this bug the way it would if paragraph two started
  # capitalized.
  def test_multi_paragraph_description_never_reaches_second_paragraph
    description = "First paragraph sentence without terminal punctuation\n\n" \
                   "second paragraph starts lowercase and continues on."
    assert_equal "First paragraph sentence without terminal punctuation", Summary.of(description)
  end

  # sabotage: `gsub(/\s+/, " ")` changed to `gsub(/\s+/, "")` (drop spaces
  # entirely instead of collapsing) -> red, words run together
  def test_embedded_newlines_and_whitespace_runs_collapse_to_single_spaces
    description = "Line one\n  with   extra\tspaces and\n a wrap."
    assert_equal "Line one with extra spaces and a wrap.", Summary.of(description)
  end

  # sabotage: `return nil if description.nil?` changed to
  # `return nil if description == :never` (stopped handling nil) -> red,
  # NoMethodError on nil.split
  def test_nil_and_empty_string_both_return_nil
    assert_nil Summary.of(nil)
    assert_nil Summary.of("")
    assert_nil Summary.of("   ")
  end
end

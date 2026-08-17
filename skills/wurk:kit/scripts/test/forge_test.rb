# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/forge"
require_relative "../worktree_survey"
require_relative "../worktree_cleanup"

# Forge (the neutral vocabulary, not the guard - the guard is exercised
# behaviorally in pr_state_test.rb, permalinks_test.rb,
# worktree_survey_test.rb, and worktree_cleanup_test.rb).
class ForgeTest < Minitest::Test
  def test_request_merged_is_lowercase
    refute_equal Forge::REQUEST_MERGED.upcase, Forge::REQUEST_MERGED
    assert_equal "merged", Forge::REQUEST_MERGED
  end

  # The producer and the consumer both reference the same constant rather
  # than each spelling their own literal, so a casing edit to one moves the
  # other with it instead of the two drifting apart silently.
  def test_survey_and_cleanup_reference_the_same_constant
    survey_source = File.read(File.join(__dir__, "../worktree_survey.rb"))
    cleanup_source = File.read(File.join(__dir__, "../worktree_cleanup.rb"))

    assert_includes survey_source, "Forge::REQUEST_MERGED"
    assert_includes cleanup_source, "Forge::REQUEST_MERGED"
  end
end

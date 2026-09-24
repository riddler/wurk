# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/forge"
require_relative "../worktree_survey"
require_relative "../worktree_cleanup"
require_relative "support/home_guard"

# Forge (the neutral vocabulary, not the guard - the guard is exercised
# behaviorally in request_state_test.rb, permalinks_test.rb,
# worktree_survey_test.rb, and worktree_cleanup_test.rb).
class ForgeTest < Minitest::Test
  def test_request_merged_is_lowercase
    refute_equal Forge::REQUEST_MERGED.upcase, Forge::REQUEST_MERGED
    assert_equal "merged", Forge::REQUEST_MERGED
  end

  # The rule that replaced the per-capability list wu-mya.7 carried
  # (PERMALINK_IMPLEMENTED, deleted in wu-4wl.1): a kind on IMPLEMENTED is
  # claimed to work for every capability, so it must have both a default host
  # and a blob shape. Growing IMPLEMENTED without them is exactly the
  # half-working state guard! exists to prevent, and blob_url would raise at
  # the moment a document was being rewritten rather than at the guard.
  #
  # sabotage: add a kind to IMPLEMENTED with no BLOB_SHAPES entry -> red.
  def test_every_implemented_forge_has_a_host_and_a_permalink_shape
    missing = Forge::IMPLEMENTED.reject do |kind|
      Forge::DEFAULT_HOSTS.key?(kind) && Forge::BLOB_SHAPES.key?(kind)
    end

    assert_empty missing,
                 "IMPLEMENTED claims every capability for #{missing.join(', ')}, but " \
                 "DEFAULT_HOSTS or BLOB_SHAPES has no entry - either add the permalink " \
                 "adapter or reintroduce a per-capability list (see IMPLEMENTED's comment)"
  end

  # The identity model: one "/"-joined path, at any depth, and never a partial
  # path built from a half-read payload.
  def test_project_path_joins_segments_and_drops_blanks
    assert_equal "owner/repo", Forge.project_path(%w[owner repo])
    assert_equal "group/subgroup/project", Forge.project_path(%w[group subgroup project])
    assert_equal "owner/repo", Forge.project_path(["owner", nil, " ", "repo"])
    assert_equal "", Forge.project_path([nil, ""])
    assert_equal "", Forge.project_path(nil)
  end

  def test_resolve_host_defaults_per_kind_and_prefers_a_declared_host
    assert_equal "github.com", Forge.resolve_host("github")
    assert_equal "gitlab.com", Forge.resolve_host("gitlab")
    assert_equal "gitlab.example.com", Forge.resolve_host("gitlab", "gitlab.example.com")
    assert_equal "gitlab.com", Forge.resolve_host("gitlab", "   ")
    assert_nil Forge.resolve_host("bitbucket")
  end

  # Draft follows the base, not the branch (wu-o921). A request based on an
  # unmerged parent is a draft because it cannot merge yet; the same stacked
  # branch with its base overridden to the default branch is mergeable and
  # opens ready for review.
  #
  # sabotage: key the predicate off "base was given" instead of "base differs
  # from the default branch" -> the second assertion goes red.
  def test_request_draft_only_when_the_base_is_not_the_default_branch
    assert Forge.request_draft?(base: "wu-1-parent", default_branch: "main")
    refute Forge.request_draft?(base: "main", default_branch: "main")
  end

  # No base named means the request is based on the default branch, and a
  # stray-whitespace spelling of the default branch is still the default
  # branch, not a parent.
  def test_request_draft_treats_no_base_as_the_default_branch
    refute Forge.request_draft?(base: nil, default_branch: "main")
    refute Forge.request_draft?(base: "  ", default_branch: "main")
    refute Forge.request_draft?(base: " main ", default_branch: "main")
    assert Forge.request_draft?(base: "trunk", default_branch: "main")
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

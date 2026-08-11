# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/conflict_paths"
require_relative "support/manifest_helper"

class ConflictPathsTest < Minitest::Test
  include ManifestHelper

  # sabotage: return true for a non-empty entries list regardless of paths ->
  # red. Empty is the default every consumer starts at (ADR-0010); it must
  # never satisfy "every path matches".
  def test_empty_allowlist_is_false_for_any_input
    with_manifest("valid") do
      refute ConflictPaths.auto_resolvable?(["docs/plan.md"])
      refute ConflictPaths.auto_resolvable?([])
    end
  end

  # sabotage: drop the `!list.empty?` guard -> red. No paths is not "every
  # path matched" - it is nothing to resolve.
  def test_empty_path_list_is_false_even_with_a_populated_allowlist
    with_manifest("rebase") do
      refute ConflictPaths.auto_resolvable?([])
    end
  end

  # sabotage: change `all?` to `any?` -> red
  def test_all_paths_allowlisted_is_true
    with_manifest("rebase") do
      assert ConflictPaths.auto_resolvable?(["docs/plan.md", "docs/notes/inbox.md"])
    end
  end

  # sabotage: change `all?` to `any?` -> red. A conflict spanning an
  # allowlisted doc and an out-of-scope file is not an allowlisted conflict.
  def test_any_path_outside_the_allowlist_is_false
    with_manifest("rebase") do
      refute ConflictPaths.auto_resolvable?(["docs/plan.md", "lib/acme.ex"])
    end
  end

  # sabotage: swap GatePaths.match_one? for a bare `==` -> red
  def test_directory_prefix_entry_matches_a_nested_path
    with_manifest("rebase") do
      assert ConflictPaths.auto_resolvable?(["docs/notes/a/b/inbox.md"])
    end
  end

  # sabotage: drop the trailing-"/" distinction in GatePaths.match_one?,
  # treating every entry as a prefix -> red. An exact entry must not match a
  # sibling that merely shares its prefix.
  def test_exact_entry_does_not_match_a_sibling_with_the_same_prefix
    with_manifest("rebase") do
      refute ConflictPaths.auto_resolvable?(["docs/plan.md.bak"])
    end
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require_relative "../rebase_resolve"

# additive_merge? as a pure function against synthetic strings - no Sh, no
# manifest, no CLI. See rebase_resolve.rb's own comment on the function for
# the four checks it runs.
class RebaseResolveInvariantTest < Minitest::Test
  def test_identical_inputs_are_additive
    text = "alpha\nbeta\ngamma\n"
    assert RebaseResolve.additive_merge?(text, text, text, text)
  end

  def test_one_sided_addition_is_additive
    base = "alpha\nbeta\n"
    upstream = "alpha\nbeta\ngamma\n"
    branch = base
    merged = "alpha\nbeta\ngamma\n"

    assert RebaseResolve.additive_merge?(base, upstream, branch, merged)
  end

  def test_two_sided_disjoint_addition_is_additive
    base = "alpha\nbeta\n"
    upstream = "alpha\nbeta\ngamma\n"
    branch = "alpha\nbeta\ndelta\n"
    merged = "alpha\nbeta\ngamma\ndelta\n"

    assert RebaseResolve.additive_merge?(base, upstream, branch, merged)
  end

  def test_dropped_upstream_line_is_not_additive
    base = "alpha\nbeta\n"
    upstream = "alpha\nbeta\ngamma\n"
    branch = base
    merged = "alpha\nbeta\n" # gamma silently dropped

    refute RebaseResolve.additive_merge?(base, upstream, branch, merged)
    assert_equal "dropped a line unique to upstream",
                 RebaseResolve.additive_merge_failure(base, upstream, branch, merged)
  end

  def test_dropped_branch_line_is_not_additive
    base = "alpha\nbeta\n"
    upstream = base
    branch = "alpha\nbeta\ndelta\n"
    merged = "alpha\nbeta\n" # delta silently dropped

    refute RebaseResolve.additive_merge?(base, upstream, branch, merged)
    assert_equal "dropped a line unique to branch",
                 RebaseResolve.additive_merge_failure(base, upstream, branch, merged)
  end

  def test_invented_line_is_not_additive
    base = "alpha\nbeta\n"
    upstream = "alpha\nbeta\ngamma\n"
    branch = base
    merged = "alpha\nbeta\ngamma\nnever seen anywhere\n"

    refute RebaseResolve.additive_merge?(base, upstream, branch, merged)
    assert_equal "invented a line absent from base, upstream, and branch",
                 RebaseResolve.additive_merge_failure(base, upstream, branch, merged)
  end

  # A re-wrapped paragraph invents lines that exist in none of the three
  # inputs - this is the reflow limitation ADR-0010 states as deliberate.
  def test_reflowed_paragraph_is_not_additive
    base = "one line of a paragraph that keeps going and going\n"
    upstream = base
    branch = base
    merged = "one line of a paragraph\nthat keeps going and going\n"

    refute RebaseResolve.additive_merge?(base, upstream, branch, merged)
    assert_equal "invented a line absent from base, upstream, and branch",
                 RebaseResolve.additive_merge_failure(base, upstream, branch, merged)
  end

  def test_retained_conflict_marker_is_not_additive
    base = "alpha\n"
    upstream = "alpha\nup\n"
    branch = "alpha\nbr\n"
    merged = "alpha\n<<<<<<< HEAD\nup\n=======\nbr\n>>>>>>> branch\n"

    refute RebaseResolve.additive_merge?(base, upstream, branch, merged)
    assert_equal "retained a conflict marker",
                 RebaseResolve.additive_merge_failure(base, upstream, branch, merged)
  end

  # Comparison is whitespace-normalized, so a pure reindentation is additive.
  def test_whitespace_only_reindentation_is_additive
    base = "alpha\n  beta\n"
    upstream = base
    branch = base
    merged = "alpha\n    beta\n" # beta re-indented, same trimmed content

    assert RebaseResolve.additive_merge?(base, upstream, branch, merged)
  end
end

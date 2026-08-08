# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/refs"
require_relative "support/manifest_helper"

# Driven from the `valid` fixture manifest (prefix "zz", trailer key
# "Refs"), not this repo's own - see support/manifest_helper.rb. Asserting
# on "st-" would pass here for the wrong reason and prove nothing about the
# prefix actually coming from the manifest.
class RefsTest < Minitest::Test
  include ManifestHelper

  # The real body of 146c69f, reachable in this repo's own history
  # (`git show 146c69f --format=%B -s`) - captured here verbatim, not
  # paraphrased. It carries no trailer line at all, so it must yield [].
  FIXTURE_146C69F = <<~MSG.freeze
    Updates beads interaction log

    Records the status changes from closing st2-00p.1 and st2-gnr
    after PR #2 and PR #3 merged. The Dolt DB is the source of truth
    and is already pushed; this file is a passive export catching up.
  MSG

  def test_146c69f_fixture_yields_no_beads
    with_manifest("valid") { assert_equal [], Refs.beads_from_messages([FIXTURE_146C69F]) }
  end

  # sabotage: drop the \A anchor from the trailer match -> red
  def test_anchor_ignores_bead_ids_named_in_prose
    body = <<~MSG
      Fixes the exit-set ordering bug.

      Related to zz-abc and discussed in zz-def, but this commit does not
      close either of them.
    MSG

    with_manifest("valid") { assert_equal [], Refs.beads_from_messages([body]) }
  end

  def test_extracts_from_trailer_line
    body = <<~MSG
      Adds retry backoff to the send queue.

      Refs: zz-abc
    MSG

    with_manifest("valid") { assert_equal ["zz-abc"], Refs.beads_from_messages([body]) }
  end

  def test_multiple_ids_on_one_trailer_line_uniq_and_sorted
    body = "Body text\n\nRefs: zz-def zz-abc zz-abc\n"

    with_manifest("valid") { assert_equal %w[zz-abc zz-def], Refs.beads_from_messages([body]) }
  end

  def test_dotted_bead_id
    body = "Body\n\nRefs: zz-00p.3\n"

    with_manifest("valid") { assert_equal ["zz-00p.3"], Refs.beads_from_messages([body]) }
  end

  def test_multiple_messages_uniq_and_sort_across_all
    a = "x\n\nRefs: zz-b\n"
    b = "y\n\nRefs: zz-a\n"

    with_manifest("valid") { assert_equal %w[zz-a zz-b], Refs.beads_from_messages([a, b]) }
  end

  def test_indented_trailer_line_is_not_matched
    body = "Body\n\n  Refs: zz-abc\n"

    with_manifest("valid") { assert_equal [], Refs.beads_from_messages([body]) }
  end

  def test_nil_and_empty_messages_are_safe
    with_manifest("valid") do
      assert_equal [], Refs.beads_from_messages([nil, "", "no refs here\n"])
      assert_equal [], Refs.beads_from_messages(nil)
    end
  end

  def test_trailer_line_single_id
    with_manifest("valid") { assert_equal "Refs: zz-abc", Refs.trailer_line(["zz-abc"]) }
  end

  def test_trailer_line_multiple_ids
    with_manifest("valid") { assert_equal "Refs: zz-abc zz-def", Refs.trailer_line(%w[zz-abc zz-def]) }
  end

  # The manifest-derivation tests: change the prefix and the key, and the
  # extraction must follow. Without these, every assertion above would still
  # pass against a hardcoded /st-.../ and a hardcoded "Refs".
  #
  # sabotage: hardcode BEAD_ID back to /st-[a-z0-9]+/ -> red
  def test_bead_prefix_comes_from_the_manifest
    other = manifest_with("valid", "beads" => { "prefix" => "px" })

    with_manifest(other) do
      assert_equal ["px-abc"], Refs.beads_from_messages(["x\n\nRefs: px-abc zz-nope\n"])
    end
  end

  # sabotage: hardcode the anchor back to /\ARefs:/ -> red
  def test_trailer_key_comes_from_the_manifest
    other = manifest_with("valid", "commits" => { "trailer" => { "key" => "Closes" } })

    with_manifest(other) do
      assert_equal ["zz-abc"], Refs.beads_from_messages(["x\n\nCloses: zz-abc\n"])
      assert_equal [], Refs.beads_from_messages(["x\n\nRefs: zz-abc\n"])
      assert_equal "Closes: zz-abc", Refs.trailer_line(["zz-abc"])
    end
  end
end

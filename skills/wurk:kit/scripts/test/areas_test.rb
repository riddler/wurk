# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/areas"
require_relative "support/manifest_helper"

# Driven from the `areas` fixture manifest (area:alpha / area:beta /
# area:build), not this repo's own vocabulary - see
# support/manifest_helper.rb. Asserting on "area:interpreter" would pass
# here for the wrong reason and prove nothing about the vocabulary coming
# from the manifest.
class AreasTest < Minitest::Test
  include ManifestHelper

  # sabotage: restore the hardcoded VALID list -> red
  def test_vocabulary_comes_from_the_manifest
    with_manifest("areas") do
      assert_equal %w[area:alpha area:beta area:build], Areas.valid
    end
  end

  def test_areas_of_keeps_only_recognized_area_labels_in_order
    with_manifest("areas") do
      labels = ["area:alpha", "priority:1", "area:beta", "unrelated"]
      assert_equal ["area:alpha", "area:beta"], Areas.areas_of(labels)
    end
  end

  def test_areas_of_never_infers_from_anything_but_labels
    # No file-path argument exists anywhere on this API - the only input is
    # the label list already on the bead (docs/workflow.md:147-191).
    with_manifest("areas") do
      assert_equal [], Areas.areas_of([])
      assert_equal [], Areas.areas_of(nil)
    end
  end

  def test_always_batchable_bead_carries_no_area_label
    with_manifest("areas") do
      assert Areas.upstream?(["upstream"])
      refute Areas.upstream?(["area:alpha"])
    end
  end

  def test_lands_alone_label_batches_with_nothing
    with_manifest("areas") do
      assert Areas.lands_alone?(["area:build"])
      refute Areas.lands_alone?(["area:alpha"])
    end
  end

  # sabotage: hardcode LANDS_ALONE back to "area:build" -> red
  def test_lands_alone_and_batchable_labels_come_from_the_manifest
    other = manifest_with("areas", "beads" => { "areas" => {
                            "labels" => %w[area:alpha area:toolchain],
                            "lands_alone" => ["area:toolchain"],
                            "always_batchable" => ["vendor"]
                          } })

    with_manifest(other) do
      assert Areas.lands_alone?(["area:toolchain"])
      refute Areas.lands_alone?(["area:build"])
      assert Areas.upstream?(["vendor"])
      refute Areas.upstream?(["upstream"])
    end
  end

  # A project with no areas block batches on nothing and lands nothing
  # alone, rather than falling back to some other repo's vocabulary.
  def test_absent_areas_block_recognizes_no_labels
    with_manifest("valid") do
      assert_equal [], Areas.valid
      assert_equal [], Areas.areas_of(["area:alpha"])
      refute Areas.lands_alone?(["area:build"])
      refute Areas.upstream?(["upstream"])
    end
  end

  def test_disjoint_is_plain_set_intersection
    assert Areas.disjoint?(["area:alpha"], ["area:beta"])
    refute Areas.disjoint?(["area:alpha", "area:beta"], ["area:beta"])
    assert Areas.disjoint?([], ["area:alpha"])
  end
end

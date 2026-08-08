# frozen_string_literal: true

require_relative "manifest"

# Areas is the batching policy over a project's `area:` label vocabulary -
# the label set, the lands-alone rule, and the always-batchable escape
# hatch. All three are manifest data (`beads.areas.*`), documented for this
# repo in docs/workflow.md:147-191.
#
# It holds no inference from file paths: an area label is a prediction
# written before the work exists, so deriving one from a diff would invert
# the design (statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 6).
# select_batch.rb is the only caller.
module Areas
  class << self
    # The closed vocabulary. A label outside this list is not an area this
    # module recognizes - callers treat an unrecognized `area:*` label the
    # same as no area label at all (see docs/workflow.md's table).
    def valid(manifest = Manifest.current)
      manifest.area_labels
    end

    # Labels whose bead batches with nothing else and lands on main alone.
    # For this repo that is `area:build`, which moves mix.lock and the credo
    # config every other worktree's warmed build depends on
    # (docs/workflow.md).
    def lands_alone_labels(manifest = Manifest.current)
      manifest.area_lands_alone
    end

    # Labels marking work that changes no files in this repo
    # (docs/workflow.md). Always batchable - such a bead collides with
    # nothing here by definition.
    def always_batchable_labels(manifest = Manifest.current)
      manifest.area_always_batchable
    end

    # The subset of `labels` that are recognized area: labels, in the order
    # they appear. No path inference, ever - this is a filter over labels
    # already on the bead.
    def areas_of(labels, manifest: Manifest.current)
      vocabulary = valid(manifest)
      Array(labels).select { |l| vocabulary.include?(l) }
    end

    def upstream?(labels, manifest: Manifest.current)
      !(Array(labels) & always_batchable_labels(manifest)).empty?
    end

    def lands_alone?(labels, manifest: Manifest.current)
      !(Array(labels) & lands_alone_labels(manifest)).empty?
    end

    # Two beads are batchable iff their area sets are disjoint - the whole
    # rule (docs/workflow.md). Plain set intersection; there is no bespoke
    # compatibility table because the area globs themselves are already
    # disjoint by construction.
    def disjoint?(areas_a, areas_b)
      (Array(areas_a) & Array(areas_b)).empty?
    end
  end
end

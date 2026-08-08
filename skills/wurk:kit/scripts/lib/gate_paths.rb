# frozen_string_literal: true

require_relative "manifest"

# Two related predicates that are deliberately *not* the same question. Both
# read their path lists from the manifest (`gate.build_paths` and
# `gate.also_gated_paths`); neither knows what language the project is
# written in.
#
# `touches_build?` - does this change touch the project's build? A change
# touching none of `gate.build_paths` has no build to break: skills, docs,
# ADRs, and beads exports cannot break a compile. repo_state.rb reports this
# under `touches_build`.
#
# `gate_applicable?` - does the gate have anything to measure? This is the
# carve-out predicate stated in /commit's Step 0 and /merge-request's gate
# step, and it is strictly wider, because the gate covers more than the
# build. Here the `Script tests` stage (.quality.exs, ledger entry st-hzf)
# runs the Ruby suite under `.claude/scripts/`, so a branch touching only
# those files does have a gate to run - hence `gate.also_gated_paths`.
#
# The two were one predicate until st-hzf added that stage. Conflating them
# is what let a branch of ~8k lines of new Ruby and no Elixir report "no gate
# applicable" and skip the only check that covered it. Keep them separate:
# one answers a question about the build, the other about the gate, and the
# gate is free to grow stages that have nothing to do with the build.
#
# gate.rb reuses `gate_applicable?` so the skills' carve-outs cannot drift
# apart the way the trailer extraction (see lib/refs.rb) once did.
#
# Was `lib/touches_elixir.rb`, whose name and `any?` entry point both
# asserted the project was Elixir. Nothing outside this repo required that;
# the manifest carries it now.
module GatePaths
  class << self
    def touches_build?(paths, manifest: Manifest.current)
      match?(paths, manifest.gate_build_paths)
    end

    def gate_applicable?(paths, manifest: Manifest.current)
      match?(paths, manifest.gate_build_paths + manifest.gate_also_gated_paths)
    end

    # The one matching rule, documented in wurk docs/manifest.md: an entry
    # ending in "/" is a directory prefix, anything else is an exact path.
    # No globbing - a glob dialect is a second thing to get right in every
    # consumer repo, and every value these lists have ever held is one of
    # these two shapes.
    def match_one?(path, entry)
      entry.end_with?("/") ? path.to_s.start_with?(entry) : path.to_s == entry
    end

    private

    def match?(paths, entries)
      Array(paths).any? { |path| entries.any? { |entry| match_one?(path, entry) } }
    end
  end
end

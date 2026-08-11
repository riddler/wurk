# frozen_string_literal: true

require_relative "manifest"
require_relative "gate_paths"

# ADR-0010's eligibility predicate: is a rebase conflict a candidate for
# auto-resolution at all, on path grounds alone? This says nothing about
# whether the merge itself is safe - that is the deterministic net in
# rebase_resolve.rb - only whether the conflict is even in bounds.
#
# Reuses GatePaths.match_one? so the matching rule (a trailing "/" is a
# directory prefix, anything else is an exact path) has exactly one
# definition site in the kit.
module ConflictPaths
  class << self
    # True only when there is at least one path and EVERY path is
    # allowlisted. All, not any: a conflict spanning an allowlisted doc and a
    # source file is not an allowlisted conflict, and the union is where a
    # careless widening would hide.
    def auto_resolvable?(paths, manifest: Manifest.current)
      entries = manifest.rebase_auto_resolve_paths
      return false if entries.empty?

      list = Array(paths)
      !list.empty? && list.all? { |p| entries.any? { |e| GatePaths.match_one?(p, e) } }
    end
  end
end

# frozen_string_literal: true

require_relative "manifest"

# Refs is the single definition site for extracting bead ids from the commit
# trailer line the project uses (`Refs:` here; the key is manifest data, see
# `commits.trailer.key`). Before this extraction the same pattern was written
# twice, independently: `/wurk:mr` SKILL.md (over
# `git log origin/main..HEAD --pretty=%B`) and `/wurk:cleanup` SKILL.md
# (over `gh pr view <n> --json commits --jq '.commits[].messageBody'`). A
# drift between the two would mean a PR body's `Closes` lines and the beads
# `/wurk:cleanup` actually closes disagree - see
# statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 2.
#
# The anchor (`^Refs:`) is load-bearing, not tidiness: a commit body
# routinely names other beads in prose (citing a design note, crediting a
# discovery), and an unanchored match would close every one of them. See the
# 146c69f fixture in test/refs_test.rb for a real example.
#
# The bead id shape and the trailer key both come from the manifest, so this
# module carries no project constants of its own. Callers pass a manifest
# explicitly in tests; in a live run it is the located one.
module Refs
  class << self
    # A bead id: the project's prefix followed by lowercase alphanumerics,
    # optionally dotted (e.g. "st-00p.3"). Built by Manifest from
    # `beads.prefix` - the single definition site.
    def bead_id(manifest = Manifest.current)
      manifest.bead_id_pattern
    end

    def trailer_key(manifest = Manifest.current)
      manifest.trailer_key
    end

    # Extracts bead ids from the trailer line(s) of one or more messages.
    # Each message is split into lines; only lines matching /^<key>:/ are
    # scanned for bead ids. A bead id named elsewhere in the message
    # (ordinary prose) is deliberately ignored. Returns a sorted,
    # deduplicated array of bead id strings.
    def beads_from_messages(texts, manifest: Manifest.current)
      anchor = /\A#{Regexp.escape(trailer_key(manifest))}:/
      pattern = bead_id(manifest)

      ids = []
      Array(texts).each do |text|
        next if text.nil?

        text.to_s.each_line do |line|
          next unless line =~ anchor

          ids.concat(line.scan(pattern))
        end
      end
      ids.uniq.sort
    end

    # Builds a "Refs: id1 id2 ..." trailer line for message construction.
    def trailer_line(ids, manifest: Manifest.current)
      "#{trailer_key(manifest)}: #{Array(ids).join(' ')}"
    end
  end
end

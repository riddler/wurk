# frozen_string_literal: true

# Beads holds the pure, testable logic behind bead.rb: unwrapping bd show's
# one-element array, splitting its single notes blob into entries and
# parsing the /implement-plan --loop note grammar out of them, unioning
# bd ready results for the --label-any workaround (beads#5358), and ranking
# /commit's bead-resolution candidates. bead.rb is the thin CLI that shells
# out via Sh and wires this module's results into the envelope. See
# statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 3.
module Beads
  # The fields bd show --json is known to carry (docs/research/...: Key
  # discoveries). bead.rb emits every one of these under `data`, degrading a
  # missing field to null with a warning rather than crashing - see the
  # Phase 3 manual verification item.
  SHOW_FIELDS = %w[
    id title description acceptance_criteria notes status priority
    issue_type assignee labels dependent_count dependency_count
  ].freeze

  # The /implement-plan --loop note grammar, appended verbatim by that
  # skill's looped execution mode - see .claude/skills/implement-plan/
  # SKILL.md's "## Looped Execution Mode" and st-hzf's own notes for real
  # examples ("loop: Phase 1 complete, commit a2aa5a9").
  LOOP_COMPLETE_RE = /\Aloop: Phase (\d+) complete, commit (\S+)\z/.freeze
  LOOP_STOPPED_RE = /\Aloop stopped at Phase (\d+): (.+)\z/m.freeze

  # A line starting a fresh note entry within the blob. Every other line is
  # a continuation of the entry above it - this is what lets a free-text
  # note (e.g. the initial multi-line "Motivation: ...\nResearch doc: ..."
  # note bd create wrote) round-trip as one entry, and what lets a
  # "loop stopped at Phase N: <reason>" note carry a reason that itself
  # spans multiple physical lines.
  NEW_ENTRY_RE = /\A(?:loop: |loop stopped at )/.freeze

  class << self
    # bd show <id> --json returns a one-element array (not an object) -
    # unwrap it. Returns nil if parsed is not an array or is empty, so the
    # caller can distinguish "no such issue" from a real hash.
    def unwrap_show(parsed)
      return nil unless parsed.is_a?(Array)

      parsed.first
    end

    # Splits bd show's single `notes` string blob into an ordered list of
    # entries, parsing the --loop grammar out of any entry that matches it.
    # Each entry is {"text" => <raw text, possibly multi-line>,
    # "loop" => nil | {"status" => "complete"|"stopped", "phase" => N,
    # "commit" => sha, "reason" => text}}.
    def parse_notes(blob)
      return [] if blob.to_s.strip.empty?

      entries = []
      blob.to_s.each_line do |raw|
        line = raw.chomp
        if entries.empty? || line =~ NEW_ENTRY_RE
          entries << +line
        else
          entries.last << "\n" << line
        end
      end

      entries.map { |text| build_note(text) }
    end

    # Unions several bd ready --json result arrays by issue id, first
    # occurrence wins, sorted by id for a deterministic result. This is the
    # beads#5358 workaround: --label-any silently returns the unfiltered
    # ready set instead of an OR-union, so bead.rb runs bd ready once per
    # label (using the unaffected AND-only --label flag) and unions the
    # results itself here. Keep this comment (and the workaround) until
    # #5358 is confirmed closed - do not drop it on a re-verification pass
    # without checking upstream first.
    #
    # Re-verified 2026-08-08 against bd 1.1.2 (the version it was written
    # for): still broken. `bd ready --json --label-any area:skills` returned
    # all 14 ready beads while `bd ready --json -l area:skills` returned 0,
    # which is the silent-ignore symptom exactly. The workaround stays, and
    # so does select_batch.rb's `unverified_filter` guard.
    def union_by_id(result_arrays)
      seen = {}
      Array(result_arrays).each do |arr|
        Array(arr).each do |issue|
          id = issue["id"]
          seen[id] ||= issue
        end
      end
      seen.values.sort_by { |issue| issue["id"].to_s }
    end

    # Ranks /commit's bead-resolution candidates (strategies 2-4 of its
    # five-strategy ladder; strategy 1 - an explicit id - is resolved by
    # the caller before this ever runs, and strategy 5 - asking the user -
    # is not scriptable at all). `candidates` is an ordered array (highest
    # priority first) of {id:, strategy:, confidence:, status:} where
    # status is bd show's status string, or nil if the id could not be
    # found at all. Returns {resolved: {id:, strategy:, confidence:} | nil,
    # candidates: [...] } where `candidates` holds every candidate other
    # than the resolved one, each annotated with a `warning` when closed or
    # not found - a closed bead must never surface silently
    # (/commit L174-179).
    def rank_candidates(candidates)
      resolved_index = candidates.find_index { |c| eligible?(c) }
      resolved = resolved_index ? candidates[resolved_index] : nil

      remaining = candidates.each_with_index.reject { |_c, i| i == resolved_index }.map(&:first)

      {
        resolved: resolved && { id: resolved[:id], strategy: resolved[:strategy], confidence: resolved[:confidence] },
        candidates: remaining.map { |c| annotate(c) }
      }
    end

    private

    def build_note(text)
      if (m = text.match(LOOP_COMPLETE_RE))
        { "text" => text, "loop" => { "status" => "complete", "phase" => m[1].to_i, "commit" => m[2] } }
      elsif (m = text.match(LOOP_STOPPED_RE))
        { "text" => text, "loop" => { "status" => "stopped", "phase" => m[1].to_i, "reason" => m[2] } }
      else
        { "text" => text, "loop" => nil }
      end
    end

    def eligible?(candidate)
      !candidate[:id].to_s.strip.empty? && !candidate[:status].nil? && candidate[:status] != "closed"
    end

    def annotate(candidate)
      out = { id: candidate[:id], strategy: candidate[:strategy], confidence: candidate[:confidence], status: candidate[:status] }
      out[:warning] =
        if candidate[:status] == "closed"
          candidate[:strategy] == "branch_prefix" ? "stale branch name (statifier-ex ADR-0010)" : "bead #{candidate[:id]} is closed"
        elsif candidate[:status].nil?
          "bead #{candidate[:id]} not found"
        end
      out
    end
  end
end

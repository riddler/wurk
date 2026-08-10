#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "stringio"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/refs"
require_relative "lib/areas"
require_relative "lib/summary"
require_relative "bead"
require_relative "worktree_survey"

# SelectBatch is the mechanics behind /wurk:next at any n, including 1:
# candidate listing, the verdict table, and the greedy priority-ordered walk.
# See statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 6 and
# .claude/skills/next-issues/SKILL.md's Steps 1-3 (the verdict table lives at
# SKILL.md:170-185).
#
# This script never claims a bead and never creates a worktree - selection is
# the only thing it does. `recommended` is a recommendation, not an outcome:
# the envelope always carries `mode`, and only sets `requires_user_choice` in
# manual mode, so a calling model cannot read `recommended` as the decision.
# The picker itself stays in the skill. The `upstream` verdict is how it
# keeps /wurk:next from claiming or standing up a worktree for a bead whose
# work happens in a sibling repo (ADR-0009).
module SelectBatch
  MAX_N = 4

  class << self
    def run(argv, io: $stdout)
      options, error = parse_args(argv)
      env = Envelope.new(script: "select_batch")

      if error
        env.block!(code: error[:code], message: error[:message])
        return env.emit(io)
      end

      env.data["mode"] = options[:auto] ? "auto" : "manual"
      env.data["n"] = options[:n]

      if options[:n] > MAX_N
        env.block!(
          code: "n_too_large",
          message: "n=#{options[:n]} exceeds the ceiling of #{MAX_N}; beyond four the merge queue is the " \
                    "constraint, not the picking - re-run with n=#{MAX_N} if that is really intended"
        )
        return env.emit(io)
      end

      if !options[:explicit_ids].empty? && !options[:passthrough].empty?
        env.block!(
          code: "ambiguous_input",
          message: "mixing explicit bead ids with bd ready filter flags is ambiguous - use one input form per invocation"
        )
        return env.emit(io)
      end

      issues, error = candidates_for(options, env)
      return env.emit(io) if error

      held_areas = held_areas_map(env)

      candidates = issues.map { |issue| annotate(issue, held_areas) }
      walked = walk(candidates, options[:n])

      env.data["candidates"] = candidates.map { |c| public_candidate(c) }
      env.data["recommended"] = walked[:recommended]
      env.data["skipped"] = walked[:skipped]
      env.data["ceiling_hit"] = walked[:ceiling_hit]
      env.data["alternatives"] = alternatives_for(candidates, options[:auto])
      env.data["requires_user_choice"] = true unless options[:auto]

      env.emit(io)
    end

    private

    # --- argument parsing -------------------------------------------------
    #
    # Deliberately not Cli/OptionParser for the default form: a strict
    # parser would reject any bd ready flag this script has not itself
    # declared, which defeats "pass filters straight through" (same reason
    # bead.rb's `ready` subcommand hand-rolls this - see bead.rb).

    def parse_args(argv)
      options = { n: nil, auto: false, dry_run: false, explicit_ids: [], passthrough: [] }
      i = 0
      while i < argv.length
        arg = argv[i]
        case arg
        when "--n"
          options[:n] = argv[i + 1].to_i
          i += 2
        when /\A--n=(\d+)\z/
          options[:n] = ::Regexp.last_match(1).to_i
          i += 1
        when "--auto"
          options[:auto] = true
          i += 1
        when "--dry-run"
          options[:dry_run] = true
          i += 1
        when "--json"
          i += 1
        when "--help"
          puts usage
          exit 0
        when /\A#{Refs.bead_id}\z/
          options[:explicit_ids] << arg
          i += 1
        else
          options[:passthrough] << arg
          i += 1
        end
      end

      options[:n] ||= options[:explicit_ids].empty? ? 3 : options[:explicit_ids].length

      if options[:explicit_ids].length > MAX_N
        return [options, { code: "n_too_large",
                            message: "#{options[:explicit_ids].length} explicit ids exceeds the ceiling of #{MAX_N}" }]
      end

      [options, nil]
    end

    def usage
      "usage: select_batch.rb [--n N] [--auto] [<bead-id> ...] [bd-ready-flags...]"
    end

    # --- candidate listing --------------------------------------------------

    def candidates_for(options, env)
      if !options[:explicit_ids].empty?
        return explicit_candidates(options[:explicit_ids], env)
      end

      filtered_by_label = options[:passthrough].any? do |a|
        a == "-l" || a == "--label" || a.start_with?("--label=") || a == "--label-any" || a.start_with?("--label-any=")
      end

      issues = bead_ready(options[:passthrough], env)
      return [nil, true] unless env.blocked.empty?

      if filtered_by_label
        unfiltered = bead_ready([], env)
        return [nil, true] unless env.blocked.empty?

        if issues.length == unfiltered.length && !unfiltered.empty?
          env.block!(
            code: "unverified_filter",
            message: "filtered and unfiltered bd ready counts are both #{issues.length}; a label filter that " \
                      "changed nothing is exactly the symptom of beads#5358 (a bd flag being silently ignored) - " \
                      "refusing to build a candidate table from a set that was never actually filtered"
          )
          return [nil, true]
        end
      end

      [issues, nil]
    end

    def explicit_candidates(ids, env)
      issues = []
      ids.each do |id|
        io = StringIO.new
        Bead.run(["show", id], io: io)
        parsed = JSON.parse(io.string)
        env.commands.concat(parsed["commands"] || [])

        if parsed["ok"]
          issues << parsed["data"]
        else
          message = (parsed["blocked"] || []).map { |b| b["message"] }.join("; ")
          env.warn(code: "unknown_id", message: "#{id}: #{message.empty? ? 'not found' : message}")
        end
      end
      [issues, nil]
    end

    def bead_ready(passthrough, env)
      io = StringIO.new
      Bead.run(["ready"] + passthrough, io: io)
      parsed = JSON.parse(io.string)
      env.commands.concat(parsed["commands"] || [])

      unless parsed["ok"]
        message = (parsed["blocked"] || []).map { |b| b["message"] }.join("; ")
        env.block!(code: "bd_ready_failed", message: message.empty? ? "bd ready failed" : message)
        return []
      end

      parsed["data"]["issues"] || []
    end

    # --- live worktree survey -----------------------------------------------

    def held_areas_map(env)
      io = StringIO.new
      WorktreeSurvey.run([], io: io)
      parsed = JSON.parse(io.string)
      env.commands.concat(parsed["commands"] || [])

      unless parsed["ok"]
        message = (parsed["blocked"] || []).map { |b| b["message"] }.join("; ")
        env.warn(code: "survey_degraded", message: "worktree_survey failed: #{message}; proceeding as if no live worktree holds anything")
        return {}
      end

      map = {}
      (parsed.dig("data", "worktrees") || []).each do |wt|
        Array(wt["holds_areas"]).each do |area|
          map[area] ||= { "worktree" => wt["path"], "bead" => wt["bead"] }
        end
      end
      map
    end

    # --- verdicts (order-independent - .claude/skills/next-issues/SKILL.md:170-185) ---

    def annotate(issue, held_areas)
      labels = issue["labels"] || []
      areas = Areas.areas_of(labels)
      upstream = Areas.upstream?(labels)

      verdict, reason, collides_with =
        if issue["issue_type"] == "epic"
          ["epic", "epic - work its children", nil]
        elsif upstream
          # An always_batchable label means the bead changes no files here
          # (ADR-0009): it collides with nothing AND has nothing for a
          # workspace to do. Informational only - never recommended, because
          # /wurk:next's claim and workspace standup both act on
          # `recommended`, and this is the only place that waste can be
          # prevented.
          ["upstream", "upstream - the work happens in a sibling repo; run /wurk:work #{issue['id']} to handle it", nil]
        elsif areas.empty?
          ["unlabeled", "unlabeled - blast radius undecided", nil]
        elsif Areas.lands_alone?(labels)
          ["lands-alone", nil, nil]
        else
          colliding = areas.each_with_object({}) { |a, h| h[a] = held_areas[a] if held_areas[a] }
          if colliding.empty?
            ["free", nil, nil]
          else
            names = colliding.map { |a, h| "#{a} (#{h['bead'] || h['worktree']})" }.join(", ")
            ["collides-with-live-worktree", "collides with live worktree: #{names}", colliding]
          end
        end

      {
        id: issue["id"],
        title: issue["title"],
        summary: Summary.of(issue["description"]),
        priority: issue["priority"],
        issue_type: issue["issue_type"],
        areas: areas,
        verdict: verdict,
        reason: reason,
        collides_with: collides_with
      }
    end

    def public_candidate(c)
      {
        "id" => c[:id],
        "title" => c[:title],
        "summary" => c[:summary],
        "priority" => c[:priority],
        "issue_type" => c[:issue_type],
        "areas" => c[:areas],
        "verdict" => c[:verdict],
        "reason" => c[:reason]
      }
    end

    # --- the greedy walk (.claude/skills/next-issues/SKILL.md Step 3) -------
    #
    # Highest priority first (bd ready's own order): skip epic / unlabeled /
    # live-worktree-collision, area:build takes the batch alone, otherwise
    # take and union in areas, skip on collides-in-batch. Stops at n beads
    # or the end of the list - n is a ceiling, not a target.

    def walk(candidates, n)
      recommended = []
      skipped = []
      batch_areas = []
      idx = 0
      alone = false

      while idx < candidates.length && recommended.length < n
        c = candidates[idx]
        idx += 1

        case c[:verdict]
        when "epic", "unlabeled", "upstream", "collides-with-live-worktree"
          skipped << { "id" => c[:id], "reason" => c[:reason] }
        when "lands-alone"
          if recommended.empty?
            recommended << c[:id]
            alone = true
            break
          else
            skipped << { "id" => c[:id], "reason" => "area:build lands alone; batch already holds other beads" }
          end
        else # "free"
          overlap = batch_areas & c[:areas]
          if overlap.empty?
            recommended << c[:id]
            batch_areas |= c[:areas]
          else
            holder = recommended.last
            skipped << { "id" => c[:id], "reason" => "collides in-batch: #{overlap.join(', ')} (already taken by #{holder})" }
          end
        end
      end

      ceiling_hit = !alone && recommended.length >= n && idx < candidates.length

      # Anything never reached by the walk is still a candidate the report
      # has to account for - "n is a ceiling" has to be visible as a fact
      # about specific beads, not just a count, and "area:build lands
      # alone" excludes the rest of the list for a different reason than
      # the ceiling does.
      unreached_reason =
        if alone
          "area:build lands alone; no other bead can join"
        else
          "not reached - ceiling n=#{n} already met"
        end
      candidates[idx..-1].to_a.each do |c|
        next if recommended.include?(c[:id])

        # An unreached epic/unlabeled/live-collision candidate keeps its own
        # verdict-specific reason - it was excluded for that reason
        # regardless of the batch, not because the walk never got to it.
        reason =
          if %w[epic unlabeled upstream collides-with-live-worktree].include?(c[:verdict])
            c[:reason]
          else
            unreached_reason
          end
        skipped << { "id" => c[:id], "reason" => reason }
      end

      { recommended: recommended, skipped: skipped, ceiling_hit: ceiling_hit }
    end

    # --- alternatives --------------------------------------------------------
    #
    # --auto drops the override option entirely: an unattended agent cannot
    # knowingly accept a risk on someone's behalf (SKILL.md's Agent-auto mode).

    def alternatives_for(candidates, auto)
      return [] if auto

      candidates.select { |c| c[:verdict] == "collides-with-live-worktree" }.map do |c|
        {
          "type" => "override",
          "id" => c[:id],
          "note" => "take #{c[:id]} despite #{c[:reason]}"
        }
      end
    end
  end
end

exit SelectBatch.run(ARGV) if __FILE__ == $PROGRAM_NAME

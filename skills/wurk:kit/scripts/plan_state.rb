#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/refs"

# PlanState parses the /wurk:plan grammar: "## Phase N:" sectioning,
# "#### Automated Verification:" vs "#### Manual Verification:" subsections,
# "- [ ]"/"- [x]" checkboxes, and the "## Deferred Manual Verification"
# section /wurk:implement --loop appends to. See
# statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 8.
#
# This module holds the pure, testable parsing/mutation logic over an array
# of lines (no Sh, no file I/O); plan_state.rb (below) is the thin CLI that
# reads/writes the file and wires results into the envelope.
module PlanState
  # Any heading of level 2-4 ("## " through "#### "). \# escapes the "#" so
  # Ruby does not read it as the start of a #{...} interpolation.
  ANY_HEADING_RE = /\A\#{2,4} /.freeze
  H2_RE = /\A## /.freeze

  PHASE_HEADING_RE = /\A## Phase (\d+): (.+?)\s*\z/.freeze
  AUTOMATED_HEADING_RE = /\A#### Automated Verification:/.freeze
  MANUAL_HEADING_RE = /\A#### Manual Verification:/.freeze
  CHECKBOX_RE = /\A- \[( |x)\] (.+)\z/.freeze
  DEFERRED_HEADING_RE = /\A## Deferred Manual Verification\s*\z/.freeze

  # /wurk:plan's mandatory nine sections, in the order the template
  # specifies them (create-plan/SKILL.md's "Template Structure" list).
  MANDATORY_SECTIONS = [
    ["title", /\A# .+/],
    ["Overview", /\A## Overview\b/],
    ["Current State Analysis", /\A## Current State Analysis\b/],
    ["Desired End State", /\A## Desired End State\b/],
    ["What We're NOT Doing", /\A## What We're NOT Doing\b/],
    ["Implementation Approach", /\A## Implementation Approach\b/],
    ["Phase", PHASE_HEADING_RE],
    ["Testing Strategy", /\A## Testing Strategy\b/],
    ["References", /\A## References\b/]
  ].freeze

  class << self
    # Full read-only parse: sections_missing, phases, next_phase (first
    # incomplete phase's n, or nil if every phase is complete),
    # deferred_manual_section, and bead_id (best-effort, from an "Overview"
    # line like "Beads issue: `st-hzf`").
    def parse(text)
      lines = to_lines(text)
      phases = parse_phases(lines)
      incomplete = phases.find { |p| !p[:complete] }

      {
        bead_id: extract_bead_id(text),
        sections_missing: missing_sections(lines),
        phases: phases.map { |p| public_phase(p) },
        next_phase: incomplete && incomplete[:n],
        deferred_manual_section: find_deferred_section(lines)
      }
    end

    def to_lines(text)
      text.to_s.each_line.map(&:chomp)
    end

    # Built per call rather than as a constant: the bead id shape comes from
    # the manifest (lib/refs.rb), which is not loaded at require time.
    def beads_issue_re
      /Beads [Ii]ssue:\s*`?(#{Refs.bead_id})`?/
    end

    def extract_bead_id(text)
      m = text.to_s.match(beads_issue_re)
      m && m[1]
    end

    def missing_sections(lines)
      MANDATORY_SECTIONS.reject { |_name, re| lines.any? { |l| l =~ re } }.map(&:first)
    end

    # Returns phases with internal :automated_items/:manual_items (each
    # {checked:, text:, line: <0-indexed absolute line>}) still attached -
    # used by the mutating subcommands. public_phase strips them for
    # read-only output.
    def parse_phases(lines)
      headings = []
      lines.each_with_index do |line, idx|
        m = line.match(PHASE_HEADING_RE)
        headings << { idx: idx, n: m[1].to_i, name: m[2] } if m
      end

      headings.each_with_index.map do |h, i|
        start_idx = h[:idx]
        end_idx = lines.length - 1
        ((start_idx + 1)...lines.length).each do |j|
          if lines[j] =~ H2_RE
            end_idx = j - 1
            break
          end
        end

        automated_items = extract_checkbox_section(lines, start_idx, end_idx, AUTOMATED_HEADING_RE)
        manual_items = extract_checkbox_section(lines, start_idx, end_idx, MANUAL_HEADING_RE)
        automated_checked = automated_items.count { |it| it[:checked] }

        {
          n: h[:n],
          name: h[:name],
          line_start: start_idx + 1,
          line_end: end_idx + 1,
          automated: { total: automated_items.length, checked: automated_checked },
          manual: {
            total: manual_items.length,
            checked: manual_items.count { |it| it[:checked] },
            items: manual_items.map { |it| it[:text] }
          },
          complete: automated_items.length == automated_checked,
          automated_items: automated_items,
          manual_items: manual_items
        }
      end
    end

    def public_phase(phase)
      phase.reject { |k, _| %i[automated_items manual_items].include?(k) }
    end

    def extract_checkbox_section(lines, range_start, range_end, heading_re)
      heading_idx = nil
      (range_start..range_end).each do |i|
        if lines[i] =~ heading_re
          heading_idx = i
          break
        end
      end
      return [] unless heading_idx

      items = []
      ((heading_idx + 1)..range_end).each do |i|
        line = lines[i]
        break if line =~ ANY_HEADING_RE

        if (m = line.match(CHECKBOX_RE))
          items << { checked: m[1] == "x", text: m[2].strip, line: i }
        elsif !items.empty? && !line.strip.empty? && line.start_with?(" ")
          items.last[:text] = "#{items.last[:text]} #{line.strip}"
        end
      end
      items
    end

    def find_deferred_section(lines)
      idx = lines.find_index { |l| l =~ DEFERRED_HEADING_RE }
      idx ? { present: true, line: idx + 1 } : { present: false, line: nil }
    end

    # The literal Manual Verification lines (checkbox + continuation lines)
    # for one already-parsed phase, with surrounding blank lines trimmed -
    # what `defer` appends verbatim.
    def manual_block_lines(lines, phase)
      start_idx = phase[:line_start] - 1
      end_idx = phase[:line_end] - 1
      heading_idx = nil
      (start_idx..end_idx).each do |i|
        if lines[i] =~ MANUAL_HEADING_RE
          heading_idx = i
          break
        end
      end
      return [] unless heading_idx

      block_end = end_idx
      ((heading_idx + 1)..end_idx).each do |i|
        if lines[i] =~ ANY_HEADING_RE
          block_end = i - 1
          break
        end
      end

      raw = lines[(heading_idx + 1)..block_end] || []
      raw = raw.dup
      raw.shift while raw.first && raw.first.strip.empty?
      raw.pop while raw.last && raw.last.strip.empty?
      raw
    end
  end
end

# The thin CLI: `validate` (the default when no known subcommand is given)
# reads and reports; `check`/`uncheck`/`defer` mutate the file on disk
# (or, under --dry-run, only report what they would have written).
module PlanStateCli
  SUBCOMMANDS = %w[check uncheck defer validate].freeze

  class << self
    def run(argv, io: $stdout)
      argv = argv.dup
      if argv.empty?
        warn usage
        exit 2
      end

      sub = SUBCOMMANDS.include?(argv.first) ? argv.shift : "validate"

      case sub
      when "validate" then run_validate(argv, io)
      when "check" then run_mutate(argv, io, action: :check)
      when "uncheck" then run_mutate(argv, io, action: :uncheck)
      when "defer" then run_defer(argv, io)
      end
    end

    private

    def usage
      "usage: plan_state.rb [check|uncheck|defer|validate] <path> [phase] [options]"
    end

    # --- validate -----------------------------------------------------

    def run_validate(argv, io)
      parser, = Cli.build("plan_state.rb [validate] <path>")
      args = Cli.parse!(parser, argv)
      path = args.first
      usage_error!("plan_state.rb [validate] <path>", parser) if path.to_s.strip.empty?

      env = Envelope.new(script: "plan_state")
      return missing_file!(env, io, path) unless File.exist?(path)

      result = PlanState.parse(File.read(path))
      env.data[:path] = path
      env.data[:bead_id] = result[:bead_id]
      env.data[:sections_missing] = result[:sections_missing]
      env.data[:phases] = result[:phases]
      env.data[:next_phase] = result[:next_phase]
      env.data[:deferred_manual_section] = result[:deferred_manual_section]
      env.emit(io)
    end

    # --- check / uncheck ------------------------------------------------
    #
    # With no --line: bulk-toggles every Automated Verification box in the
    # phase (the common /wurk:implement --loop case: "this phase's gate is
    # green, check its automated criteria"). Manual boxes are never touched
    # in this mode - they are simply not in the target set.
    #
    # With --line N: targets exactly one checkbox by its absolute 1-indexed
    # line number. If that line is a Manual Verification box, this refuses
    # (blocked) rather than toggling it - /wurk:implement is explicit that
    # Manual boxes are never checked by the loop.

    def run_mutate(argv, io, action:)
      options = { dry_run: false }
      parser, options = Cli.build("plan_state.rb #{action} <path> <phase> [--line N]", options) do |opts|
        opts.on("--line N", Integer, "target one checkbox by absolute file line number") do |v|
          options[:line] = v
        end
      end
      args = Cli.parse!(parser, argv)
      path, phase_arg = args[0], args[1]
      usage_error!("plan_state.rb #{action} <path> <phase>", parser) if path.to_s.strip.empty? || phase_arg.to_s.strip.empty?

      phase_n = safe_int(phase_arg)
      usage_error!("plan_state.rb #{action} <path> <phase>", parser) if phase_n.nil?

      env = Envelope.new(script: "plan_state_#{action}")
      return missing_file!(env, io, path) unless File.exist?(path)

      lines = PlanState.to_lines(File.read(path))
      phase = PlanState.parse_phases(lines).find { |p| p[:n] == phase_n }
      unless phase
        env.block!(code: "phase_not_found", message: "no Phase #{phase_n} found in #{path}")
        return env.emit(io)
      end

      targets = resolve_targets(env, phase, options[:line])
      return env.emit(io) unless env.blocked.empty?

      new_state = action == :check
      new_lines = lines.dup
      changed_lines = []
      targets.each do |item|
        next if item[:checked] == new_state

        new_lines[item[:line]] = new_lines[item[:line]].sub(/\A- \[( |x)\]/, new_state ? "- [x]" : "- [ ]")
        changed_lines << item[:line] + 1
      end

      env.data[:path] = path
      env.data[:phase] = phase_n
      env.data[:changed_lines] = changed_lines
      env.commands << "write #{path} (#{changed_lines.length} checkbox line(s) #{action}ed)"

      File.write(path, new_lines.map { |l| "#{l}\n" }.join) unless options[:dry_run] || changed_lines.empty?

      env.emit(io)
    end

    def resolve_targets(env, phase, line)
      return phase[:automated_items] unless line

      idx = line - 1
      item = (phase[:automated_items] + phase[:manual_items]).find { |it| it[:line] == idx }
      unless item
        env.block!(code: "not_a_checkbox", message: "line #{line} is not a checkbox item in Phase #{phase[:n]}")
        return []
      end
      if phase[:manual_items].include?(item)
        env.block!(
          code: "manual_verification_refused",
          message: "line #{line} is a Manual Verification box; check/uncheck only ever operate on Automated boxes"
        )
        return []
      end
      [item]
    end

    # --- defer ------------------------------------------------------------
    #
    # Appends this phase's Manual Verification items verbatim under a new
    # "### Phase N" subheading of "## Deferred Manual Verification",
    # creating that section (with its standard intro paragraph) on first
    # use. Refuses (blocked) if "### Phase N" is already present, rather
    # than risking a duplicate.

    def run_defer(argv, io)
      options = { dry_run: false }
      parser, options = Cli.build("plan_state.rb defer <path> <phase>", options)
      args = Cli.parse!(parser, argv)
      path, phase_arg = args[0], args[1]
      usage_error!("plan_state.rb defer <path> <phase>", parser) if path.to_s.strip.empty? || phase_arg.to_s.strip.empty?

      phase_n = safe_int(phase_arg)
      usage_error!("plan_state.rb defer <path> <phase>", parser) if phase_n.nil?

      env = Envelope.new(script: "plan_state_defer")
      return missing_file!(env, io, path) unless File.exist?(path)

      lines = PlanState.to_lines(File.read(path))
      phase = PlanState.parse_phases(lines).find { |p| p[:n] == phase_n }
      unless phase
        env.block!(code: "phase_not_found", message: "no Phase #{phase_n} found in #{path}")
        return env.emit(io)
      end

      if phase[:manual_items].empty?
        env.data[:path] = path
        env.data[:phase] = phase_n
        env.data[:deferred] = false
        env.warn(code: "no_manual_items", message: "Phase #{phase_n} has no Manual Verification items to defer")
        return env.emit(io)
      end

      manual_lines = PlanState.manual_block_lines(lines, phase)

      subheading_re = /\A### Phase #{phase_n}\s*\z/
      deferred = PlanState.find_deferred_section(lines)
      new_lines = lines.dup

      if deferred[:present]
        section_start = deferred[:line] - 1
        if new_lines[section_start..-1].any? { |l| l =~ subheading_re }
          env.block!(code: "phase_already_deferred", message: "### Phase #{phase_n} already exists under Deferred Manual Verification")
          return env.emit(io)
        end

        section_end = new_lines.length - 1
        ((section_start + 1)...new_lines.length).each do |j|
          if new_lines[j] =~ PlanState::H2_RE
            section_end = j - 1
            break
          end
        end
        insertion = ["", "### Phase #{phase_n}", ""] + manual_lines
        new_lines.insert(section_end + 1, *insertion)
      else
        insertion = [
          "",
          "## Deferred Manual Verification",
          "",
          "Manual verification items are deferred during looped (--loop) execution and",
          "surfaced here once, rather than blocking after each phase. Confirm these",
          "before considering the plan fully landed.",
          "",
          "### Phase #{phase_n}",
          ""
        ] + manual_lines
        new_lines.concat(insertion)
      end

      env.data[:path] = path
      env.data[:phase] = phase_n
      env.data[:deferred] = true
      env.data[:items_deferred] = manual_lines.count { |l| l =~ PlanState::CHECKBOX_RE }
      env.commands << "write #{path} (append Phase #{phase_n} manual items to Deferred Manual Verification)"

      File.write(path, new_lines.map { |l| "#{l}\n" }.join) unless options[:dry_run]

      env.emit(io)
    end

    # --- shared -----------------------------------------------------------

    def missing_file!(env, io, path)
      env.block!(code: "file_not_found", message: "no such file: #{path}")
      env.emit(io)
    end

    def safe_int(text)
      Integer(text)
    rescue ArgumentError, TypeError
      nil
    end

    def usage_error!(usage_line, parser)
      warn "usage: #{usage_line}\n\n#{parser}"
      exit 2
    end
  end
end

exit PlanStateCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

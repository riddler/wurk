#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "stringio"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/manifest"
require_relative "bead"
require_relative "plan_state"

# WorkState is /wurk:work Step 2's resumability seam: for a given bead, which of
# the research / plan / implement stages already have work landed, so a
# re-run of /wurk:work <id> resumes instead of restarting. It reports; it does
# not choose a bucket - sizing stays /wurk:work's own judgment call ("sizing
# happens here, with the codebase in reach" - work/SKILL.md Step 2). See
# statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 12.
module WorkState
  class << self
    # Matches doc_meta.rb's "YYMMDD-[issue-id-]kebab-description.md" grammar:
    # a doc "names" a bead when the id sits right after the date stamp,
    # either followed by a hyphen (there is a description after it) or by
    # ".md" (the id is the whole rest of the filename - unusual but valid).
    def doc_id_pattern(id)
      /\A\d{6}-#{Regexp.escape(id)}(-|\.md\z)/
    end

    # Every doc under dir naming this bead id, sorted (oldest date stamp
    # first since the filename leads with YYMMDD). More than one match is
    # unusual but not this script's call to arbitrate - the caller surfaces
    # a warning and picks the first.
    def find_docs(dir, id)
      return [] unless Dir.exist?(dir)

      pattern = doc_id_pattern(id)
      Dir.children(dir).select { |f| f =~ pattern }.sort.map { |f| File.join(dir, f) }
    end
  end
end

# The thin CLI: composes Bead.run(["show", id]) for the loop notes (the
# same wrapper /wurk:commit and /wurk:implement use, so the note grammar is
# parsed exactly once - lib/beads.rb), a doc-directory scan for research
# and plan docs naming this bead, and plan_state.rb's own parser over
# whichever plan doc it finds, for the phase/checkbox state
# /wurk:implement --loop already tracks in the file itself.
module WorkStateCli
  class << self
    def run(argv, io: $stdout)
      parser, = Cli.build("work_state.rb <id>")
      args = Cli.parse!(parser, argv)
      id = args.first

      env = Envelope.new(script: "work_state")
      return usage_block!(env, io) if id.to_s.strip.empty?

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest

      show = fetch_bead(id, env)
      return env.emit(io) unless env.blocked.empty?

      # Bead.run(["show", ...]) has already split the notes blob into
      # entries and parsed the --loop grammar out of them (lib/beads.rb) -
      # do not re-parse, just filter to the entries that carry loop state.
      loop_notes = Array(show["notes"]).select { |n| n["loop"] }

      # The artifact roots come from the manifest, the same values the
      # skills hand to their research subagents - one source, so a repo
      # keeping plans under thoughts/shared/ is a manifest edit rather than
      # a fork of this script.
      research_docs = WorkState.find_docs(manifest.research_dir, id)
      plan_docs = WorkState.find_docs(manifest.plans_dir, id)

      env.warn(code: "multiple_research_docs", message: "more than one research doc names #{id}: #{research_docs.join(', ')}") if research_docs.length > 1
      env.warn(code: "multiple_plan_docs", message: "more than one plan doc names #{id}: #{plan_docs.join(', ')}") if plan_docs.length > 1

      env.data[:id] = id
      env.data[:bead] = { id: show["id"], title: show["title"], status: show["status"] }
      env.data[:research_docs] = research_docs
      env.data[:plan_docs] = plan_docs
      env.data[:loop_notes] = loop_notes
      env.data[:last_loop_note] = loop_notes.last
      env.data[:plan] = plan_docs.first && plan_summary(plan_docs.first)

      env.emit(io)
    end

    private

    def usage_block!(env, io)
      env.block!(code: "missing_id", message: "work_state.rb requires a beads issue id")
      env.emit(io)
    end

    # Runs through Bead.run (in-process, via a StringIO) rather than
    # shelling out to bead.rb as a subprocess - the same composition
    # select_batch.rb already uses for "bd ready"/"bd show". Its `commands`
    # (the real `bd show ... --json` call) are folded into this script's own
    # envelope so the audit trail still shows exactly what ran.
    def fetch_bead(id, env)
      io = StringIO.new
      Bead.run(["show", id], io: io)
      parsed = JSON.parse(io.string)
      env.commands.concat(parsed["commands"] || [])

      unless parsed["ok"]
        message = (parsed["blocked"] || []).map { |b| b["message"] }.join("; ")
        env.block!(code: "bead_not_found", message: message.empty? ? "bd show #{id} failed" : message)
        return nil
      end

      parsed["data"]
    end

    def plan_summary(path)
      parsed = PlanState.parse(File.read(path))
      {
        path: path,
        next_phase: parsed[:next_phase],
        phases: parsed[:phases],
        sections_missing: parsed[:sections_missing],
        deferred_manual_section: parsed[:deferred_manual_section]
      }
    end
  end
end

exit WorkStateCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/manifest"
require_relative "plan_state"
require_relative "work_state"

# Backlog composes two readers into one answer to "what is left to work on
# this bead": plan_state.rb's Deferred Manual Verification reader (Phase 1)
# and a new, lenient Open Questions reader, over every plan/research
# document a bead owns. It is read-only - see /wurk:verify (the skill this
# feeds) for the walk that actually resolves an item.
module Backlog
  # Lenient by decision, not by accident: this matches every Open Questions
  # heading the corpus has today (title and sentence case, level 2 and 3, an
  # optional parenthetical suffix) without any document being rewritten.
  OPEN_QUESTIONS_RE = /\A(\#{2,3}) Open [Qq]uestions\b/.freeze

  # A marker this reader saw - never a claim the question is answered. A
  # script can see that a note exists; whether the question is settled is
  # the reader's call (ADR-0008). Order matters: the first pattern to match
  # an item's folded text wins.
  SETTLED_MARKERS = {
    "settled" => /\*\*settled\b/i,
    "resolved" => /\A\s*[-*]?\s*(\*\*)?resolved\b/i,
    "strikethrough" => /~~/
  }.freeze

  # Any heading, any level - used only to find where an Open Questions
  # block ends (the next heading of the same level or higher).
  ANY_HEADING_RE = /\A(\#+)\s/.freeze

  NUMBERED_ITEM_RE = /\A\d+\.\s+(.+)\z/.freeze
  BULLET_ITEM_RE = /\A[-*]\s+(.+)\z/.freeze

  class << self
    # Every "## Open Questions" / "### Open questions" block in the
    # document (ordinarily one), each as {heading:, level:, line:, items:}.
    # :line is 1-indexed; item :line is also 1-indexed, matching the shape
    # plan_state.rb's public output already uses.
    def open_questions(lines)
      sections = []
      lines.each_with_index do |line, idx|
        m = line.match(OPEN_QUESTIONS_RE)
        next unless m

        level = m[1].length
        end_idx = block_end(lines, idx, level)
        items = extract_items(lines, idx, end_idx)

        sections << {
          heading: line,
          level: level,
          line: idx + 1,
          items: items.map { |it| { line: it[:line] + 1, text: it[:text], settled_marker: settled_marker(it[:text]) } }
        }
      end
      sections
    end

    private

    def block_end(lines, heading_idx, level)
      end_idx = lines.length - 1
      ((heading_idx + 1)...lines.length).each do |j|
        hm = lines[j].match(ANY_HEADING_RE)
        next unless hm && hm[1].length <= level

        end_idx = j - 1
        break
      end
      end_idx
    end

    # Numbered/bulleted top-level entries, indented continuations folded
    # into the item above them. A block with neither is reported as one
    # item holding the whole (trimmed) paragraph - what the "None
    # blocking." documents need.
    def extract_items(lines, heading_idx, end_idx)
      return [] if end_idx < heading_idx + 1

      range = (heading_idx + 1)..end_idx
      items = []
      range.each do |i|
        line = lines[i]
        if (m = line.match(NUMBERED_ITEM_RE))
          items << { line: i, text: m[1].strip }
        elsif (m = line.match(BULLET_ITEM_RE))
          items << { line: i, text: m[1].strip }
        elsif !items.empty? && !line.strip.empty? && line.start_with?(" ")
          items.last[:text] = "#{items.last[:text]} #{line.strip}"
        end
      end
      return items unless items.empty?

      prose_idx = range.find { |i| !lines[i].strip.empty? }
      return [] unless prose_idx

      text = range.map { |i| lines[i] }.reject { |l| l.strip.empty? }.map(&:strip).join(" ")
      [{ line: prose_idx, text: text }]
    end

    def settled_marker(text)
      SETTLED_MARKERS.each { |name, re| return name if text =~ re }
      nil
    end
  end
end

# The thin CLI: read-only, composing WorkState.find_docs (a bead id) and/or
# an explicit --doc list into the document set, then plan_state.rb's pure
# PlanState module and Backlog.open_questions over each one.
module BacklogCli
  USAGE = "backlog.rb <bead-id> [--doc PATH ...]"

  class << self
    def run(argv, io: $stdout)
      options = { docs: [] }
      parser, options = Cli.build(USAGE, options) do |opts|
        opts.on("--doc PATH", "an exact document path to include (repeatable)") do |v|
          options[:docs] << v
        end
      end
      args = Cli.parse!(parser, argv)
      bead_id = args.first

      usage_error!(parser) if bead_id.to_s.strip.empty? && options[:docs].empty?

      env = Envelope.new(script: "backlog")
      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest

      docs = collect_docs(env, manifest, bead_id, options[:docs])
      return env.emit(io) unless env.blocked.empty?

      docs = dedup(docs)

      env.data[:id] = bead_id unless bead_id.to_s.strip.empty?

      if docs.empty?
        env.data[:documents] = []
        env.data[:totals] = { documents: 0, deferred_unchecked: 0, open_question_items_unmarked: 0 }
        subject = bead_id.to_s.strip.empty? ? "the given --doc paths" : bead_id
        env.warn(code: "no_documents", message: "no plan or research documents found for #{subject}")
        return env.emit(io)
      end

      results = docs.map { |d| document_entry(d) }
      env.data[:documents] = results
      env.data[:totals] = totals(results)
      env.emit(io)
    end

    private

    def collect_docs(env, manifest, bead_id, doc_paths)
      docs = []

      unless bead_id.to_s.strip.empty?
        plan_docs = WorkState.find_docs(manifest.plans_dir, bead_id)
        research_docs = WorkState.find_docs(manifest.research_dir, bead_id)

        if plan_docs.length > 1
          env.warn(code: "multiple_plan_docs", message: "more than one plan doc names #{bead_id}: #{plan_docs.join(', ')}")
        end
        if research_docs.length > 1
          env.warn(code: "multiple_research_docs", message: "more than one research doc names #{bead_id}: #{research_docs.join(', ')}")
        end

        plan_docs.each { |p| docs << { path: p, kind: "plan" } }
        research_docs.each { |p| docs << { path: p, kind: "research" } }
      end

      doc_paths.each do |path|
        unless File.exist?(path)
          env.block!(code: "file_not_found", message: "no such file: #{path}")
          next
        end
        docs << { path: path, kind: doc_kind(manifest, path) }
      end

      docs
    end

    def doc_kind(manifest, path)
      expanded = File.expand_path(path)
      return "plan" if same_dir?(expanded, manifest.plans_dir)
      return "research" if same_dir?(expanded, manifest.research_dir)

      "other"
    end

    def same_dir?(expanded_path, dir)
      return false if dir.to_s.strip.empty?

      File.dirname(expanded_path) == File.expand_path(dir)
    end

    def dedup(docs)
      seen = {}
      docs.select do |d|
        key = File.expand_path(d[:path])
        next false if seen[key]

        seen[key] = true
        true
      end
    end

    def document_entry(doc)
      lines = PlanState.to_lines(File.read(doc[:path]))
      section = PlanState.find_deferred_section(lines)
      items = PlanState.deferred_items(lines).map { |it| public_deferred_item(it) }

      {
        path: doc[:path],
        kind: doc[:kind],
        deferred: {
          present: section[:present],
          line: section[:line],
          total: section[:total],
          checked: section[:checked],
          items: items
        },
        open_questions: Backlog.open_questions(lines)
      }
    end

    def public_deferred_item(item)
      { phase: item[:phase], checked: item[:checked], text: item[:text], line: item[:line] + 1 }
    end

    def totals(results)
      deferred_unchecked = results.sum { |r| r[:deferred][:total] - r[:deferred][:checked] }
      unmarked = results.sum do |r|
        r[:open_questions].sum { |section| section[:items].count { |it| it[:settled_marker].nil? } }
      end

      { documents: results.length, deferred_unchecked: deferred_unchecked, open_question_items_unmarked: unmarked }
    end

    def usage_error!(parser)
      warn "usage: #{USAGE}\n\n#{parser}"
      exit 2
    end
  end
end

exit BacklogCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

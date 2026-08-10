#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/manifest"
require_relative "lib/refs"
require_relative "lib/beads"

# Bead is the bd wrapper: `bd show` is parsed as prose in at least four
# skills today, so this is the single biggest parsing win in the extraction
# (statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 3). Subcommands:
# show, ready, claim, note, link, label, create, sync, resolve.
#
# There is deliberately no `close` subcommand. `bd close` fires only on a
# verified merge into origin/main, and /cleanup-worktrees is the only closer
# (CLAUDE.md's authority table) - a generic "finish the bead" helper here
# would be the most tempting and most wrong extraction available, so it is
# not offered even as dead code.
#
# `bd edit` is never invoked anywhere in this file - it blocks on $EDITOR.
# Notes always go through `bd note`'s --notes/append semantics instead.
module Bead
  class << self
    def run(argv, io: $stdout)
      argv = argv.dup
      sub = argv.shift

      case sub
      when "show" then run_show(argv, io)
      when "ready" then run_ready(argv, io)
      when "claim" then run_claim(argv, io)
      when "note" then run_note(argv, io)
      when "link" then run_link(argv, io)
      when "label" then run_label(argv, io)
      when "create" then run_create(argv, io)
      when "sync" then run_sync(argv, io)
      when "resolve" then run_resolve(argv, io)
      else
        warn usage
        exit 2
      end
    end

    private

    def usage
      "usage: bead.rb <show|ready|claim|note|link|label|create|sync|resolve> [options]"
    end

    # --- show ---------------------------------------------------------

    def run_show(argv, io)
      parser, = Cli.build("bead.rb show [options] <id>")
      args = Cli.parse!(parser, argv)
      id = args.first
      usage_error!("bead.rb show <id>", parser) if id.to_s.strip.empty?

      env = Envelope.new(script: "bead_show")
      result = Sh.run(["bd", "show", id, "--json"], envelope: env)
      unless result.success?
        env.block!(code: "bd_show_failed", message: err_or(result, "bd show #{id} failed"))
        return env.emit(io)
      end

      parsed = parse_json(result.out)
      if parsed.nil?
        env.block!(code: "unparseable_json", message: "bd show returned unparseable JSON")
        return env.emit(io)
      end

      issue = Beads.unwrap_show(parsed)
      if issue.nil?
        env.block!(code: "not_found", message: "bd show #{id} returned no issue")
        return env.emit(io)
      end

      Beads::SHOW_FIELDS.each do |field|
        if issue.key?(field)
          env.data[field] = issue[field]
        else
          env.data[field] = nil
          env.warn(code: "missing_field", message: "bd show response is missing field #{field.inspect}; degraded to null")
        end
      end
      env.data["notes"] = Beads.parse_notes(env.data["notes"])

      env.emit(io)
    end

    # --- ready ----------------------------------------------------------
    #
    # Passes filters through to `bd ready --json` verbatim (including
    # --claim, which exposes the atomic claim-on-ready path with no special
    # handling needed here), except for --label-any: see
    # Beads.union_by_id for the beads#5358 workaround this implements.
    #
    # This subcommand does not go through Cli/OptionParser like the others,
    # deliberately - a strict parser would reject any bd ready flag this
    # wrapper has not itself declared, which defeats "passes through".

    def run_ready(argv, io)
      if argv.include?("--help")
        puts "usage: bead.rb ready [bd-ready-flags...] [--label-any a,b,c]"
        exit 0
      end

      label_any, passthrough = extract_label_any(argv)

      env = Envelope.new(script: "bead_ready")
      issues =
        if label_any.empty?
          bd_ready(passthrough, env)
        else
          per_label = label_any.map { |label| bd_ready(passthrough + ["--label", label], env) }
          Beads.union_by_id(per_label)
        end

      return env.emit(io) unless env.blocked.empty?

      env.data["issues"] = issues
      env.data["count"] = issues.length
      env.emit(io)
    end

    def extract_label_any(argv)
      label_any = []
      passthrough = []
      i = 0
      while i < argv.length
        arg = argv[i]
        if arg == "--label-any"
          label_any.concat(argv[i + 1].to_s.split(","))
          i += 2
        elsif arg.start_with?("--label-any=")
          label_any.concat(arg.split("=", 2)[1].to_s.split(","))
          i += 1
        else
          passthrough << arg
          i += 1
        end
      end
      [label_any.map(&:strip).reject(&:empty?).uniq, passthrough]
    end

    def bd_ready(extra_args, env)
      return [] unless env.blocked.empty?

      result = Sh.run(["bd", "ready", "--json"] + extra_args, envelope: env)
      unless result.success?
        env.block!(code: "bd_ready_failed", message: err_or(result, "bd ready failed"))
        return []
      end

      parsed = parse_json(result.out)
      if parsed.nil?
        env.block!(code: "unparseable_json", message: "bd ready returned unparseable JSON")
        return []
      end
      parsed
    end

    # --- claim ------------------------------------------------------------

    def run_claim(argv, io)
      parser, options = Cli.build("bead.rb claim [options] <id>")
      args = Cli.parse!(parser, argv)
      id = args.first
      usage_error!("bead.rb claim <id>", parser) if id.to_s.strip.empty?

      env = Envelope.new(script: "bead_claim")
      cmd = ["bd", "update", id, "--claim", "--json"]

      if options[:dry_run]
        env.commands << Sh.render(cmd)
        env.data["id"] = id
        env.data["claimed"] = nil
        return env.emit(io)
      end

      result = Sh.run(cmd, envelope: env)
      unless result.success?
        env.block!(code: "bd_claim_failed", message: err_or(result, "bd update --claim failed"))
        return env.emit(io)
      end

      env.data["id"] = id
      env.data["claimed"] = true
      env.emit(io)
    end

    # --- note ---------------------------------------------------------------
    #
    # Shorthand for `bd note <id> <text>`, which itself is append semantics
    # over `bd update --append-notes` - never `bd edit`.

    def run_note(argv, io)
      parser, options = Cli.build("bead.rb note [options] <id> <text...>")
      args = Cli.parse!(parser, argv)
      id = args.shift
      text = args.join(" ")
      usage_error!("bead.rb note <id> <text...>", parser) if id.to_s.strip.empty? || text.strip.empty?

      env = Envelope.new(script: "bead_note")
      cmd = ["bd", "note", id, text]

      if options[:dry_run]
        env.commands << Sh.render(cmd)
        env.data["id"] = id
        env.data["noted"] = nil
        return env.emit(io)
      end

      result = Sh.run(cmd, envelope: env)
      unless result.success?
        env.block!(code: "bd_note_failed", message: err_or(result, "bd note failed"))
        return env.emit(io)
      end

      env.data["id"] = id
      env.data["noted"] = true
      env.emit(io)
    end

    # --- link ------------------------------------------------------------

    def run_link(argv, io)
      options = { dry_run: false, type: "blocks" }
      parser, options = Cli.build("bead.rb link [options] <id1> <id2>", options) do |opts|
        opts.on("--type TYPE", "dependency type (blocks|tracks|related|parent-child|discovered-from)") do |v|
          options[:type] = v
        end
      end
      args = Cli.parse!(parser, argv)
      id1, id2 = args[0], args[1]
      usage_error!("bead.rb link <id1> <id2> [--type TYPE]", parser) if id1.to_s.strip.empty? || id2.to_s.strip.empty?

      env = Envelope.new(script: "bead_link")
      cmd = ["bd", "link", id1, id2, "--type", options[:type]]

      if options[:dry_run]
        env.commands << Sh.render(cmd)
        env.data["id1"] = id1
        env.data["id2"] = id2
        env.data["type"] = options[:type]
        env.data["linked"] = nil
        return env.emit(io)
      end

      result = Sh.run(cmd, envelope: env)
      unless result.success?
        env.block!(code: "bd_link_failed", message: err_or(result, "bd link failed"))
        return env.emit(io)
      end

      env.data["id1"] = id1
      env.data["id2"] = id2
      env.data["type"] = options[:type]
      env.data["linked"] = true
      env.emit(io)
    end

    # --- label --------------------------------------------------------------

    def run_label(argv, io)
      parser, options = Cli.build("bead.rb label [options] <add|remove> <id> <label>")
      args = Cli.parse!(parser, argv)
      action, id, label = args[0], args[1], args[2]
      unless %w[add remove].include?(action) && !id.to_s.strip.empty? && !label.to_s.strip.empty?
        usage_error!("bead.rb label <add|remove> <id> <label>", parser)
      end

      env = Envelope.new(script: "bead_label")
      cmd = ["bd", "label", action, id, label]

      if options[:dry_run]
        env.commands << Sh.render(cmd)
        env.data["id"] = id
        env.data["action"] = action
        env.data["label"] = label
        env.data["applied"] = nil
        return env.emit(io)
      end

      result = Sh.run(cmd, envelope: env)
      unless result.success?
        env.block!(code: "bd_label_failed", message: err_or(result, "bd label #{action} failed"))
        return env.emit(io)
      end

      env.data["id"] = id
      env.data["action"] = action
      env.data["label"] = label
      env.data["applied"] = true
      env.emit(io)
    end

    # --- create ------------------------------------------------------------

    def run_create(argv, io)
      options = { dry_run: false }
      parser, options = Cli.build("bead.rb create [options] <title>", options) do |opts|
        opts.on("--type TYPE") { |v| options[:type] = v }
        opts.on("--priority PRIORITY") { |v| options[:priority] = v }
        opts.on("--labels LABELS", "comma-separated") { |v| options[:labels] = v }
        opts.on("--description DESC") { |v| options[:description] = v }
        opts.on("--parent ID") { |v| options[:parent] = v }
        opts.on("--notes NOTES") { |v| options[:notes] = v }
      end
      args = Cli.parse!(parser, argv)
      title = args.join(" ")
      usage_error!("bead.rb create <title> [options]", parser) if title.strip.empty?

      env = Envelope.new(script: "bead_create")
      cmd = ["bd", "create", title, "--json"]
      cmd += ["--type", options[:type]] if options[:type]
      cmd += ["--priority", options[:priority]] if options[:priority]
      cmd += ["--labels", options[:labels]] if options[:labels]
      cmd += ["--description", options[:description]] if options[:description]
      cmd += ["--parent", options[:parent]] if options[:parent]
      cmd += ["--notes", options[:notes]] if options[:notes]

      if options[:dry_run]
        env.commands << Sh.render(cmd)
        env.data["title"] = title
        env.data["id"] = nil
        env.data["created"] = nil
        return env.emit(io)
      end

      result = Sh.run(cmd, envelope: env)
      unless result.success?
        env.block!(code: "bd_create_failed", message: err_or(result, "bd create failed"))
        return env.emit(io)
      end

      parsed = parse_json(result.out)
      issue = parsed.is_a?(Array) ? parsed.first : parsed
      env.data["title"] = title
      env.data["id"] = issue && issue["id"]
      env.data["created"] = true
      env.emit(io)
    end

    # --- sync -----------------------------------------------------------
    #
    # Best-effort, never gating: a dolt sync failure is a warning, not a
    # block. bd's local database keeps working regardless of whether the
    # dolt remote is reachable.

    def run_sync(argv, io)
      parser, options = Cli.build("bead.rb sync [options] <pull|push>")
      args = Cli.parse!(parser, argv)
      direction = args.first
      usage_error!("bead.rb sync <pull|push>", parser) unless %w[pull push].include?(direction)

      env = Envelope.new(script: "bead_sync")
      cmd = ["bd", "dolt", direction]

      if options[:dry_run]
        env.commands << Sh.render(cmd)
        env.data["direction"] = direction
        env.data["succeeded"] = nil
        return env.emit(io)
      end

      result = Sh.run(cmd, envelope: env)
      env.data["direction"] = direction
      env.data["succeeded"] = result.success?
      env.warn(code: "dolt_#{direction}_failed", message: err_or(result, "bd dolt #{direction} failed")) unless result.success?
      env.emit(io)
    end

    # --- resolve --------------------------------------------------------
    #
    # Encodes /commit's five-strategy bead ladder as data. Strategy 1 (an
    # explicit id, e.g. $ARGUMENTS) is resolved by the caller before this
    # ever runs. Strategy 2 (the bead this session was seeded with) is not
    # visible to a script at all, so it is an input - --seeded-bead - and
    # ranks first when given. Strategies 3 (a plan doc in the diff) and 4
    # (the branch prefix) are derived here from git state, in that priority
    # order. Strategy 5 (ask the user) is not scriptable - if nothing is
    # eligible, `resolved` is null and the caller falls back to asking.

    def run_resolve(argv, io)
      options = { dry_run: false }
      parser, options = Cli.build("bead.rb resolve [options]", options) do |opts|
        opts.on("--seeded-bead ID", "the bead this session was seeded with (ladder strategy 2)") do |v|
          options[:seeded_bead] = v
        end
      end
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "bead_resolve")

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest

      candidates = []

      candidates << { id: options[:seeded_bead], strategy: "seeded_prompt", confidence: "strong" } if options[:seeded_bead]

      plan_bead = resolve_plan_doc_bead(env, manifest)
      candidates << { id: plan_bead, strategy: "plan_doc", confidence: "strong" } if plan_bead

      branch_bead = resolve_branch_bead(env)
      candidates << { id: branch_bead, strategy: "branch_prefix", confidence: "weak" } if branch_bead

      annotated = candidates.map { |c| c.merge(status: bd_status(c[:id], env)) }
      ranked = Beads.rank_candidates(annotated)

      env.data["resolved"] = ranked[:resolved]
      env.data["candidates"] = ranked[:candidates]
      ranked[:candidates].each do |c|
        env.warn(code: "bead_unavailable", message: c[:warning]) if c[:warning]
      end

      env.emit(io)
    end

    def resolve_plan_doc_bead(env, manifest)
      diff_res = Sh.run(["git", "diff", "#{manifest.default_branch}...HEAD", "--name-only"], envelope: env)
      return nil unless diff_res.success?

      files = diff_res.out.to_s.each_line.map(&:strip).reject(&:empty?)
      files.each do |f|
        m = File.basename(f).match(/\A\d{6}-(#{Refs.bead_id})-/)
        return m[1] if m
      end
      nil
    end

    def resolve_branch_bead(env)
      branch_res = Sh.run(%w[git branch --show-current], envelope: env)
      return nil unless branch_res.success?

      m = branch_res.out.to_s.strip.match(/\A(#{Refs.bead_id})-/)
      m && m[1]
    end

    def bd_status(id, env)
      return nil if id.to_s.strip.empty?

      result = Sh.run(["bd", "show", id, "--json"], envelope: env)
      return nil unless result.success?

      parsed = parse_json(result.out)
      issue = parsed && Beads.unwrap_show(parsed)
      issue && issue["status"]
    end

    # --- shared helpers -------------------------------------------------

    def parse_json(text)
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    def err_or(result, fallback)
      msg = result.err.to_s.strip
      msg.empty? ? fallback : msg
    end

    def usage_error!(usage_line, parser)
      warn "usage: #{usage_line}\n\n#{parser}"
      exit 2
    end
  end
end

exit Bead.run(ARGV) if __FILE__ == $PROGRAM_NAME

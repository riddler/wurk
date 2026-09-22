#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/manifest"
require_relative "lib/refs"
require_relative "lib/beads"
require_relative "lib/base_ref"
require_relative "lib/outbound_scan"
require_relative "lib/tracker_scan"

# Bead is the bd wrapper: `bd show` is parsed as prose in at least four
# skills today, so this is the single biggest parsing win in the extraction
# (statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 3). Subcommands:
# show, ready, claim, note, link, label, create, sync, resolve.
#
# There is deliberately no `close` subcommand. `bd close` fires only on a
# verified merge into origin/main, and /wurk:cleanup is the only closer
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
    #
    # Hardened (wu-4in) after the notes field was clobbered four times in
    # the wild by raw `bd update --notes`, which REPLACES the whole field:
    # the prior notes are captured before the append and re-read after, so
    # a lost prior text surfaces as `prior_notes_lost` instead of silence.
    # The text also gets an ISO date header when it does not already carry
    # one, since an undated note is unreadable a week later.
    #
    # Recovery for a clobbered field: the beads database's dolt history
    # still holds the prior value until compaction - read it back with a
    # dolt `AS OF` query (or the dolt_history_issues system table) against
    # `.beads/`'s embedded dolt db, then re-append it, before any dolt
    # push publishes the loss.

    def run_note(argv, io)
      parser, options = Cli.build("bead.rb note [options] <id> <text...>")
      args = Cli.parse!(parser, argv)
      id = args.shift
      text = args.join(" ")
      usage_error!("bead.rb note <id> <text...>", parser) if id.to_s.strip.empty? || text.strip.empty?

      text = date_stamped(text)
      env = Envelope.new(script: "bead_note")
      cmd = ["bd", "note", id, text]

      # The pre-read is a plain read, so it runs under --dry-run too - same
      # stance as worktree_create.rb's guards: an accurate report beats a
      # guess.
      prior = read_notes(id, env)

      if options[:dry_run]
        env.commands << Sh.render(cmd)
        env.data["id"] = id
        env.data["noted"] = nil
        env.data["prior_preserved"] = nil
        return env.emit(io)
      end

      result = Sh.run(cmd, envelope: env)
      unless result.success?
        env.block!(code: "bd_note_failed", message: err_or(result, "bd note failed"))
        return env.emit(io)
      end

      env.data["id"] = id
      env.data["noted"] = true
      verify_append(env, id, prior, text)
      env.emit(io)
    end

    # A text already leading with an ISO date (bare or bracketed) keeps it;
    # anything else gets today's stamped on the front.
    def date_stamped(text)
      return text if text =~ /\A\[?\d{4}-\d{2}-\d{2}/

      "#{Time.now.strftime('%Y-%m-%d')}: #{text}"
    end

    # Reads the current notes blob. :unreadable when bd show fails or
    # returns something unparseable - the append still proceeds; the
    # verification reports what it could not check rather than blocking
    # the note itself.
    def read_notes(id, env)
      res = Sh.run(["bd", "show", id, "--json"], envelope: env)
      return :unreadable unless res.success?

      parsed = parse_json(res.out)
      issue = parsed.is_a?(Array) ? Beads.unwrap_show(parsed) : nil
      return :unreadable unless issue

      issue["notes"].to_s
    end

    # Post-append verification: the new text must be visible, and the prior
    # text must have survived. Either failure blocks (exit 1) so a caller
    # never reports a note it cannot prove landed intact - the write
    # already happened, the block is the alarm, and the recovery recipe is
    # in the comment above run_note.
    def verify_append(env, id, prior, text)
      after = read_notes(id, env)

      if after == :unreadable
        env.data["prior_preserved"] = nil
        env.warn(code: "append_unverified", message: "could not read #{id}'s notes after the append; verify by hand")
        return
      end

      unless after.include?(text)
        env.data["prior_preserved"] = prior.is_a?(String) ? (prior.strip.empty? || after.include?(prior)) : nil
        env.block!(code: "note_not_visible", message: "the appended text is not visible in #{id}'s notes")
        return
      end

      if prior == :unreadable
        env.data["prior_preserved"] = nil
        env.warn(code: "append_unverified", message: "could not read #{id}'s notes before the append; prior text unverifiable")
      elsif prior.strip.empty? || after.include?(prior)
        env.data["prior_preserved"] = true
      else
        env.data["prior_preserved"] = false
        env.block!(
          code: "prior_notes_lost",
          message: "#{id}'s prior notes text is no longer present after the append; " \
                   "recover it from dolt history (AS OF / dolt_history_issues) and re-append " \
                   "before any dolt push"
        )
      end
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
    # `sync pull` is best-effort, never gating: a dolt sync failure is a
    # warning, not a block. bd's local database keeps working regardless of
    # whether the dolt remote is reachable.
    #
    # `sync scan` and `sync push` are the two halves of the gated tracker
    # push (wu-b4i, extending ADR-0014's tracker path). They are SEPARATE
    # VERBS THAT REFUSE TO CHAIN: scan never pushes, push never scans, and
    # there is no verb that does both. The scan reads the full tracker
    # export (`bd list --all --json` - wu-caq: titles-of-open-issues
    # scanning is the known-weak form), scans every string field in
    # process, attributes hits per issue id, and on a clean result writes
    # a marker (lib/tracker_scan.rb) carrying the export's fingerprint. The
    # push refuses unless that marker exists, is younger than
    # TrackerScan::MARKER_TTL_SECONDS, and fingerprints the export the
    # push is about to publish. The point of the split is that the scan's
    # report - in particular the informational hits under a `titles`
    # refusal set - is looked at before anything is published, and a
    # chained scan-and-push is exactly how that look gets skipped.
    #
    # Which hits refuse is the manifest's `beads.scan_refusal` (`all`, the
    # default, `titles`, or `none`); the pattern set and control term stay
    # in the machine config (ADR-0014) and are never inlined here. A
    # refusing hit is a BLOCK (`outbound_scan_hit`, from
    # OutboundScan.apply_to_envelope); a hit outside the refusal set is a
    # warning attributed per issue id. Under `none` the set is empty, so
    # the scan comes back clean enough to mark and the push proceeds - but
    # both verbs then warn `outbound_scan_refusals_waived` and set
    # `data.waived`, because a scan that matched and was waived must be
    # readable as a different thing from a scan that found nothing (see
    # warn_unrefused_hits).
    # Reading the tracker is a precondition for both verbs - a failed or
    # unparseable export is a BLOCK (`tracker_export_unavailable`),
    # deliberately asymmetric with the best-effort `dolt_push_failed`
    # warning for the push itself, which stays a warning unchanged.
    #
    # Both verbs honor `beads.sync`: under `local` (declared or defaulted)
    # neither reads nor pushes anything, and the envelope says so in
    # `data.skipped` rather than in a warning, because a local tracker
    # staying local is the correct outcome, not a degraded one
    # (docs/manifest.md, `beads.sync`).
    #
    # A push that exits 0 saying nothing is UNCONFIRMED, not successful
    # (wu-hvz): `bd dolt push` has printed nothing on a first attempt
    # while the retry showed "Push complete". So a silent push is re-run
    # once, and `data.confirmed` reports whether any attempt produced
    # confirming output - a caller about to depend on the push reads
    # `confirmed`, not just `succeeded`.

    TRACKER_EXPORT_SIZE_WARNING_BYTES = 5 * 1024 * 1024 # 5 MB, ADR-0014's measurement point

    SYNC_VERBS = %w[pull scan push].freeze

    def run_sync(argv, io)
      parser, options = Cli.build("bead.rb sync [options] <pull|scan|push>")
      args = Cli.parse!(parser, argv)
      verb = args.first
      usage_error!("bead.rb sync <pull|scan|push>", parser) unless SYNC_VERBS.include?(verb)

      env = Envelope.new(script: "bead_sync")
      env.data["direction"] = verb

      case verb
      when "pull" then run_sync_pull(env, io, options)
      when "scan" then run_sync_scan(env, io, options)
      when "push" then run_sync_push(env, io, options)
      end
    end

    def run_sync_pull(env, io, options)
      cmd = %w[bd dolt pull]

      if options[:dry_run]
        env.commands << Sh.render(cmd)
        env.data["succeeded"] = nil
        return env.emit(io)
      end

      result = Sh.run(cmd, envelope: env)
      env.data["succeeded"] = result.success?
      env.warn(code: "dolt_pull_failed", message: err_or(result, "bd dolt pull failed")) unless result.success?
      env.emit(io)
    end

    # The scan verb. Read-only except for the marker it writes on a clean
    # result, which is what --dry-run withholds: the export is read and
    # scanned either way, so a dry run reports the real verdict.
    def run_sync_scan(env, io, options)
      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest

      refusal = manifest.beads_scan_refusal
      env.data["refusal"] = refusal
      env.data["marker_written"] = false
      return emit_tracker_local(env, io, manifest) unless manifest.beads_push_allowed?

      config = UserConfig.require!(env)
      return env.emit(io) unless config

      marker_path = resolve_marker_path(env)
      return env.emit(io) unless marker_path

      export = read_tracker_export(env)
      return env.emit(io) unless export

      issues, raw = export
      env.data["issues"] = issues.length
      env.data["fingerprint"] = TrackerScan.fingerprint(raw)
      env.warn(code: "tracker_export_empty", message: "bd list --all --json returned no issues; the scan ran over nothing") if issues.empty?

      result = OutboundScan.run(TrackerScan.payload(issues), config: config)
      refusing, informational = TrackerScan.partition_hits(result.hits, refusal)

      # The gate is the refusing subset: apply_to_envelope blocks on it,
      # warns when disarmed, and is the one place a Result is disclosed.
      gate = OutboundScan::Result.new(
        armed: result.armed?, probe_ok: result.probe_ok, hits: refusing,
        scanned_locations: result.scanned_locations, errors: result.errors
      )
      OutboundScan.apply_to_envelope(gate, env, path_label: "tracker")
      env.data["refusing_hits"] = TrackerScan.attribute(refusing)
      env.data["informational_hits"] = TrackerScan.attribute(informational)
      env.data["waived"] = TrackerScan.waiving?(refusal) && !informational.empty?

      unless informational.empty?
        warn_unrefused_hits(env, refusal, informational.sum(&:count), env.data["informational_hits"].length)
      end

      env.data["marker_path"] = marker_path
      clean = env.blocked.empty?
      env.data["clean"] = clean
      return env.emit(io) unless clean

      marker = TrackerScan.build_marker(
        fingerprint: env.data["fingerprint"], refusal: refusal, armed: result.armed?,
        issues: issues.length, informational: env.data["informational_hits"]
      )
      env.data["scanned_at"] = marker["scanned_at"]
      env.data["marker_ttl_seconds"] = TrackerScan::MARKER_TTL_SECONDS

      if options[:dry_run]
        env.commands << "write #{marker_path}"
        env.data["marker_written"] = nil
        return env.emit(io)
      end

      TrackerScan.write_marker(marker_path, marker)
      env.data["marker_written"] = true
      env.emit(io)
    end

    # The push verb. Never scans: it re-reads the export only to prove the
    # marker is about THIS content, then shells `bd dolt push`. Every
    # pre-push read (manifest, marker, export) runs under --dry-run too, so
    # the dry run reports the verdict the real run would reach.
    def run_sync_push(env, io, options)
      env.data["pushed"] = false
      env.data["succeeded"] = nil
      env.data["confirmed"] = nil

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest

      refusal = manifest.beads_scan_refusal
      env.data["refusal"] = refusal
      return emit_tracker_local(env, io, manifest) unless manifest.beads_push_allowed?

      marker_path = resolve_marker_path(env)
      return env.emit(io) unless marker_path

      export = read_tracker_export(env)
      return env.emit(io) unless export

      _issues, raw = export
      marker = TrackerScan.read_marker(marker_path)
      check = TrackerScan.check_marker(marker, fingerprint: TrackerScan.fingerprint(raw), refusal: refusal)
      env.data["marker_path"] = marker_path
      env.data["marker_state"] = check[:state]
      env.data["marker_age_seconds"] = check[:age_seconds]

      unless check[:state] == "fresh"
        env.block!(code: "scan_marker_#{check[:state]}", message: marker_refusal_message(check[:state]))
        return env.emit(io)
      end

      env.data["informational_hits"] = marker["informational"]
      # A push under `none` with hits behind it must not read as a push
      # under a clean scan: `data.clean` on the scan and a silent push are
      # what "nothing matched" looks like, so the waiver gets its own
      # warning here too, re-emitted from the marker the way the disarmed
      # warning already is. Under `all` and `titles` the push stays silent
      # about informational hits, as it always has - there the refusal set
      # did the ruling, and the hits outside it were read at scan time.
      waived_hits = Array(marker["informational"])
      env.data["waived"] = TrackerScan.waiving?(refusal) && !waived_hits.empty?
      if env.data["waived"]
        warn_unrefused_hits(env, refusal, waived_hits.sum { |entry| entry["count"].to_i }, waived_hits.length)
      end

      if marker["armed"] == false
        env.warn(
          code: "outbound_scan_disarmed",
          message: "no outbound scan is configured on this machine; this push was not scanned"
        )
      end

      cmd = %w[bd dolt push]
      if options[:dry_run]
        env.commands << Sh.render(cmd)
        return env.emit(io)
      end

      result = Sh.run(cmd, envelope: env)
      if result.success? && blank_output?(result)
        retry_result = Sh.run(cmd, envelope: env)
        result = retry_result if retry_result.success?
      end

      env.data["pushed"] = true
      env.data["succeeded"] = result.success?
      confirmed = result.success? && !blank_output?(result)
      env.data["confirmed"] = confirmed
      if result.success? && !confirmed
        env.warn(
          code: "dolt_push_unconfirmed",
          message: "bd dolt push exited 0 with no output twice; treat the push as unconfirmed and verify the remote before depending on it"
        )
      end
      env.warn(code: "dolt_push_failed", message: err_or(result, "bd dolt push failed")) unless result.success?
      env.emit(io)
    end

    # The one place a "found, but did not refuse" result is phrased, for
    # both verbs. Two states that must never be confused for one another,
    # nor for a third one the kit already reports:
    #
    #   outbound_scan_informational   - a hit fell OUTSIDE the refusal set
    #                                   (`titles`), which still refuses on
    #                                   what it covers.
    #   outbound_scan_refusals_waived - the refusal set is EMPTY (`none`):
    #                                   a scan ran, it matched, and the
    #                                   repo has declared the matches
    #                                   acceptable. Not a clean scan.
    #   outbound_scan_disarmed        - no scan is configured on this
    #                                   machine, so nothing was measured at
    #                                   all (emitted elsewhere; a waiver is
    #                                   not a disarm and never borrows its
    #                                   code).
    #
    # Both forms carry COUNTS and nothing else; the issue ids and field
    # names stay in data.informational_hits and no matched literal is ever
    # quoted - the operator rules on a record, and the record is the unit
    # they can scrub.
    def warn_unrefused_hits(env, refusal, hits, issues)
      if TrackerScan.waiving?(refusal)
        env.warn(
          code: "outbound_scan_refusals_waived",
          message: "#{hits} outbound scan hit(s) in #{issues} issue(s) were WAIVED: beads.scan_refusal is " \
                   "\"none\", so this repo declares its scan hits acceptable and none of them refuses the push. " \
                   "This is not a clean scan - see data.informational_hits for the issue ids and field names"
        )
      else
        env.warn(
          code: "outbound_scan_informational",
          message: "#{hits} outbound scan hit(s) in #{issues} issue(s) " \
                   "outside the #{refusal} refusal set; they do not refuse the push - " \
                   "see data.informational_hits for the issue ids and field names"
        )
      end
    end

    def marker_refusal_message(state)
      reason =
        case state
        when "missing" then "no scan marker exists"
        when "unreadable" then "the scan marker is not one this kit wrote"
        when "expired" then "the scan marker is older than #{TrackerScan::MARKER_TTL_SECONDS} seconds"
        when "stale" then "the tracker export or the refusal set changed since the scan"
        end
      "#{reason}; run `bead.rb sync scan`, read its result, then push - the two verbs never chain"
    end

    # Under `local` neither verb touches the tracker or the network. Not a
    # warning: docs/manifest.md says a skipped push under `local` is the
    # correct outcome and must not read as degraded.
    def emit_tracker_local(env, io, manifest)
      env.data["skipped"] = "tracker_local_only"
      env.data["beads_sync"] = manifest.beads_sync
      env.data["beads_sync_declared"] = manifest.beads_sync_declared?
      env.emit(io)
    end

    # The marker lives under the git common dir - one per beads database,
    # shared by every worktree - see TrackerScan::MARKER_RELATIVE_PATH.
    def resolve_marker_path(env)
      result = Sh.run(%w[git rev-parse --path-format=absolute --git-common-dir], envelope: env)
      common = result.success? ? result.out.to_s.strip : ""
      if common.empty?
        env.block!(code: "git_rev_parse_failed", message: err_or(result, "git rev-parse --git-common-dir gave no directory"))
        return nil
      end
      TrackerScan.marker_path(common)
    end

    # [issues, raw] for the full tracker export, or nil after blocking when
    # it could not be read. Empty output is unusable output: `bd list --all
    # --json` printing nothing is not an empty tracker, it is no export.
    def read_tracker_export(env)
      result = Sh.run(%w[bd list --all --json], envelope: env)
      parsed = result.success? ? parse_json(result.out) : nil

      unless result.success? && parsed.is_a?(Array)
        env.block!(
          code: "tracker_export_unavailable",
          message: err_or(result, "bd list --all --json returned no usable JSON")
        )
        return nil
      end

      bytesize = result.out.to_s.bytesize
      if bytesize > TRACKER_EXPORT_SIZE_WARNING_BYTES
        env.warn(
          code: "outbound_scan_large_tracker",
          message: "the tracker export is #{bytesize} bytes, above the 5 MB measurement point; " \
                   "it was still read in full"
        )
      end

      [parsed, result.out.to_s]
    end

    def blank_output?(result)
      result.out.to_s.strip.empty? && result.err.to_s.strip.empty?
    end

    # --- resolve --------------------------------------------------------
    #
    # Encodes /wurk:commit's five-strategy bead ladder as data. Strategy 1 (an
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

    # `files` is the sorted union of the committed diff and the working
    # tree (BaseRef.changed_files), so a branch touching two plan documents
    # resolves to the lexicographically first one rather than git's diff
    # order. That's fine: the multi-plan-document case is already
    # ambiguous, and Beads.rank_candidates - not this order - is what
    # disambiguates candidates.
    def resolve_plan_doc_bead(env, manifest)
      files = BaseRef.changed_files(env, manifest: manifest)[:files]
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

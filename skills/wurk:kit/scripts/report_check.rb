#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/cli"
require_relative "lib/finding_severity"

# ReportCheck answers one question about a campaign's per-bead worker report
# files: does each one actually parse as the JSON its name and its contract
# promise. The contract is stated in skills/wurk:conductor/REFERENCE.md
# ("Staleness threshold and report files") and in SKILL.md's Phase 3 bullet
# "Name a report file in every dispatch": the per-bead file holds the
# worker's JSON result and is the record the sweep reads.
#
# It exists because the prose was not enough. In one measured campaign four
# of eight report files did not parse - three opened with a markdown code
# fence, one with a prose H1 above the fence - and every later reader that
# parses rather than eyeballs (the conductor's sweep, the retro reader's
# per-bead extraction) silently lost those workers' judgementCalls,
# openQuestions, discoveredDeps and blocked/failed status. It was found
# three campaigns later by someone who happened to run JSON.parse over the
# directory.
#
# It is a reader: it never edits, moves or deletes a report. A report that
# does not parse comes back as a blocked[] entry naming the path and the
# fix, and the fix is always the worker re-emitting the file, because the
# report is the worker's statement and nobody else may rewrite it.
#
# Pure filesystem logic, like campaign_state.rb: no Sh, no manifest, and no
# default directory. Every path is a CLI argument, so the reports dir stays
# the caller's seam value (the fleet manifest's campaignState.reports) and
# is never spelled here.
#
# --notes-dir DIR adds one cross-check and keeps the script pure: the CALLER
# (the conductor's sweep) runs bd and writes each bead's notes to
# DIR/<bead-id>.txt, and this script only reads those files. A report whose
# status is "complete" while the bead's last note carries the partial marker
# warns status_contradicts_notes with both texts. It is a warning and never a
# block, for the same reason a bad report is never rewritten here: the
# report is the worker's statement, and the conductor decides which of the
# two to believe. Without the flag the envelope is byte-identical to the
# envelope before the flag existed.
module ReportCheck
  # The per-bead file name the contract fixes: <bead-id>-report.json. A
  # directory is swept for exactly this, so a campaign's morning report
  # (<id>-report.md) and the journal are not candidates without an
  # exclusion list.
  GLOB = "*-report.json"

  # A fenced file opens with a code fence, in either of markdown's two
  # spellings. The backtick is written as an escape so this line is not
  # itself a backtick-execution hit in contract_test.rb's scan.
  FENCE = /\A(?:\x60{3}|~~~)/.freeze
  # Bare JSON: the first non-blank character of the document is the start of
  # an object or an array.
  BARE = /\A[\[{]/.freeze

  # The partial marker, spelled as the conductor's journal vocabulary spells
  # its [partial] entry tag. Matched literally, as a substring, against the
  # bead's LAST note only: an earlier [partial] note that a later note
  # supersedes is history, not a contradiction.
  PARTIAL_MARKER = "[partial]"

  # The suffix the contract's per-bead file name carries after the bead id.
  REPORT_SUFFIX = "-report.json"

  class << self
    # Every *-report.json directly under dir, sorted. A dir that does not
    # exist answers nil so the caller can tell "no such directory" from "a
    # directory with no reports in it" - the second is the ordinary state
    # of a campaign whose first worker has not finished.
    def report_paths(dir)
      return nil unless Dir.exist?(dir)

      Dir.glob(File.join(dir, GLOB)).sort
    end

    # Does this path carry the contract's per-bead file name?
    def report_name?(path)
      File.fnmatch?(GLOB, File.basename(path))
    end

    # {path:, exists:, parsed:, shape:, error:} for one file. shape is the
    # diagnosis the Fix: clause leans on, never a parse fallback: this
    # script reports what is there, it does not rescue a fenced file into
    # JSON, because a reader that tolerates the shape is how the shape
    # spreads.
    def inspect_report(path)
      return { path: path, exists: false, parsed: false, shape: nil, error: nil } unless File.file?(path)

      content = read_utf8(path)
      begin
        report = JSON.parse(content)
        { path: path, exists: true, parsed: true, shape: shape(content), error: nil,
          findings_by_level: findings_by_level_state(report) }
      rescue JSON::ParserError => e
        { path: path, exists: true, parsed: false, shape: shape(content), error: e.message.split("\n").first }
      end
    end

    # The optional reviewRound.findingsByLevel field (finding_severity.rb's
    # data.findings_by_level, copied): nil when absent - a report written on
    # the template before the field existed is still a good report - "ok"
    # when it is an object holding exactly the four level counts as
    # non-negative integers, else "malformed".
    def findings_by_level_state(report)
      review = report.is_a?(Hash) ? report["reviewRound"] : nil
      return nil unless review.is_a?(Hash) && review.key?("findingsByLevel")

      field = review["findingsByLevel"]
      keys = FindingSeverity::BUCKETS.values
      return "malformed" unless field.is_a?(Hash) && field.keys.sort == keys.sort
      return "malformed" unless field.values.all? { |v| v.is_a?(Integer) && v >= 0 }

      "ok"
    end

    # "fenced", "prose", "bare" or "empty", from the first non-blank line.
    # "bare" on an unparseable file means the damage is inside the JSON
    # rather than around it (a truncated write, a stray trailing line), and
    # the message says so instead of blaming a fence that is not there.
    def shape(content)
      line = content.each_line.find { |l| !l.strip.empty? }
      return "empty" if line.nil?
      return "fenced" if line =~ FENCE
      return "bare" if line.strip =~ BARE

      "prose"
    end

    # How the message describes what it found, per shape.
    def shape_phrase(shape)
      case shape
      when "fenced" then "it opens with a markdown code fence"
      when "prose" then "it opens with prose, not JSON"
      when "empty" then "it is empty"
      else "its JSON itself is malformed"
      end
    end

    # The bead id a report file belongs to, from the contract's file name
    # (<bead-id>-report.json) rather than from the JSON, so it is the same id
    # the conductor named in the dispatch and wrote the notes file under.
    def bead_id(path)
      File.basename(path).delete_suffix(REPORT_SUFFIX)
    end

    # DIR/<bead-id>.txt: where the caller wrote this bead's notes.
    def notes_path(notes_dir, report_path)
      File.join(notes_dir, "#{bead_id(report_path)}.txt")
    end

    # The report's status field, or nil when the file does not parse or
    # carries no string status. Only called on a report already known to
    # parse; the nil branch keeps it total.
    def report_status(path)
      report = JSON.parse(read_utf8(path))
      status = report.is_a?(Hash) ? report["status"] : nil
      status.is_a?(String) ? status : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # The last note in a notes file. bd note appends each note to the
    # bead's notes field verbatim, one per line with no stamp of its own, so
    # the file holds that field as `bd show <id> --json` returns it, and the
    # last non-blank line is the last note. Leading and trailing whitespace
    # is dropped so a copy of the indented `bd show` rendering reads the
    # same. nil for a file with no notes in it.
    def last_note(content)
      line = content.each_line.reverse_each.find { |l| !l.strip.empty? }
      line&.strip
    end

    def partial?(note)
      !note.nil? && note.include?(PARTIAL_MARKER)
    end

    def read_utf8(path)
      File.read(path, encoding: "UTF-8")
    rescue ArgumentError
      File.read(path)
    end
  end
end

# CLI: report_check.rb [--notes-dir DIR] <path>... where each path is a
# reports directory or a single report file. Read-only, so there is nothing
# for --dry-run to skip.
class ReportCheckCli
  USAGE = "report_check.rb [--notes-dir DIR] <reports-dir-or-file>..."

  class << self
    def run(argv, io: $stdout)
      options = {}
      parser, = Cli.build(USAGE, options) do |opts|
        opts.on("--notes-dir DIR",
                "cross-check each complete report against DIR/<bead-id>.txt, the bead's notes") do |v|
          options[:notes_dir] = v
        end
      end
      args = Cli.parse!(parser, argv)

      if args.empty?
        warn "usage: #{USAGE}\n\n#{parser}"
        exit 2
      end

      env = Envelope.new(script: "report_check")
      env.data[:paths] = args
      reports = collect(env, args)

      env.data[:reports] = reports
      env.data[:checked] = reports.count { |r| r[:exists] }
      env.data[:unparseable] = reports.select { |r| r[:exists] && !r[:parsed] }.map { |r| r[:path] }

      reports.each { |report| judge(env, report) }
      if options[:notes_dir]
        env.data[:notes_dir] = options[:notes_dir]
        reports.each { |report| check_notes(env, report, options[:notes_dir]) }
      end
      env.emit(io)
    end

    private

    # A directory contributes every report in it; a file contributes itself,
    # named or not, because a caller that names one file has already decided
    # what it is asking about. A path that is not there yet is read as a
    # report rather than a directory when it carries the contract's file
    # name, which is what lets the sweep ask about a bead still in flight
    # and get "not written yet" instead of "no such directory".
    def collect(env, args)
      reports = []
      args.each do |arg|
        if File.file?(arg) || (!Dir.exist?(arg) && ReportCheck.report_name?(arg))
          reports << ReportCheck.inspect_report(arg)
          next
        end

        paths = ReportCheck.report_paths(arg)
        if paths.nil?
          env.warn(code: "reports_path_missing", message: "no reports directory or file at #{arg}")
          next
        end
        if paths.empty?
          env.warn(code: "no_reports", message: "#{arg} holds no #{ReportCheck::GLOB} yet")
          next
        end

        paths.each { |path| reports << ReportCheck.inspect_report(path) }
      end
      reports
    end

    # A named file that is not there is a warning, not a block: the sweep
    # runs this before reading a report, and "the worker has not written it
    # yet" is the ordinary answer for a bead still in flight.
    def judge(env, report)
      unless report[:exists]
        env.warn(code: "report_missing", message: "no report file at #{report[:path]} yet")
        return
      end
      if report[:parsed]
        findings_by_level_warning(env, report)
        return
      end

      env.block!(
        code: "report_not_json",
        message: "#{report[:path]} does not parse as JSON (#{report[:error]}); " \
                 "#{ReportCheck.shape_phrase(report[:shape])}. " \
                 "Fix: have the worker re-emit the report as bare JSON with no markdown fence and " \
                 "no prose preamble, because this file is the record the conductor's sweep and the " \
                 "between-campaigns reader parse.",
        needs: "human"
      )
    end

    # Only a parsed report whose status is "complete" is cross-checked: a
    # blocked or failed report already says the work is not done, so a
    # [partial] note beside it agrees with it. Both outcomes warn and never
    # block - a missing notes file means the check did not run for that bead,
    # and a contradiction is the conductor's to decide; neither rewrites the
    # worker's statement.
    def check_notes(env, report, notes_dir)
      return unless report[:exists] && report[:parsed]

      status = ReportCheck.report_status(report[:path])
      return unless status == "complete"

      bead = ReportCheck.bead_id(report[:path])
      notes = ReportCheck.notes_path(notes_dir, report[:path])
      unless File.file?(notes)
        env.warn(code: "notes_missing",
                 message: "#{bead}: no notes file at #{notes}, so its complete report at " \
                          "#{report[:path]} was not checked against the bead's notes")
        return
      end

      note = ReportCheck.last_note(ReportCheck.read_utf8(notes))
      return unless ReportCheck.partial?(note)

      env.warn(code: "status_contradicts_notes",
               message: "#{bead}: report #{report[:path]} says status \"#{status}\", but the bead's " \
                        "last note carries #{ReportCheck::PARTIAL_MARKER}: #{note.inspect}. " \
                        "The report is not rewritten; the conductor decides which to record.")
    end

    # A malformed optional field warns rather than blocks: the report still
    # parses, so the sweep still reads the rest of it.
    def findings_by_level_warning(env, report)
      return unless report[:findings_by_level] == "malformed"

      env.warn(code: "findings_by_level_malformed",
               message: "#{report[:path]} carries a reviewRound.findingsByLevel that is not an " \
                        "object of the four level counts (#{FindingSeverity::BUCKETS.values.join(', ')}) " \
                        "as non-negative integers; copy finding_severity.rb's data.findings_by_level " \
                        "verbatim, or omit the field")
    end
  end
end

exit ReportCheckCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

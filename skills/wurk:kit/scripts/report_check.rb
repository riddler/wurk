#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/cli"

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
        JSON.parse(content)
        { path: path, exists: true, parsed: true, shape: shape(content), error: nil }
      rescue JSON::ParserError => e
        { path: path, exists: true, parsed: false, shape: shape(content), error: e.message.split("\n").first }
      end
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

    def read_utf8(path)
      File.read(path, encoding: "UTF-8")
    rescue ArgumentError
      File.read(path)
    end
  end
end

# CLI: report_check.rb <path>... where each path is a reports directory or a
# single report file. Read-only, so there is nothing for --dry-run to skip.
class ReportCheckCli
  USAGE = "report_check.rb [options] <reports-dir-or-file>..."

  class << self
    def run(argv, io: $stdout)
      parser, = Cli.build(USAGE)
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
      return if report[:parsed]

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
  end
end

exit ReportCheckCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

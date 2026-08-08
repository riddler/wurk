#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/gate_paths"
require_relative "lib/manifest"

# Gate wraps `mix gate.verify` and `mix quality --format json --report -`,
# serving /commit, /merge-request, /implement-plan, and /work. See
# statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 7 - this is the
# most constrained script in the set: it must make the gate easier to read
# without making it easier to weaken.
#
# Three rules that are load-bearing, not incidental:
#
# 1. `data.skipped_stages` always stays in the payload, for every skip,
#    whatever the reason. CLAUDE.md: "a skipped stage is not a passing one" -
#    a summary that drops it launders exactly what that rule protects.
#
#    Whether a skip *blocks* is a second question, and CLAUDE.md answers it
#    in the same breath: "the reason says whether the gap is in this run or
#    in what the project checks at all." Those are different failures.
#
#    - A gap **in this run** blocks. Dialyzer skipping because the PLT is
#      missing, Tests skipping because compilation half-failed: the gate was
#      asked to measure something and could not, so `ok` is false.
#    - A gap in **what the project checks at all** is reported, not blocked.
#      `:doctor not installed`, `:gettext not installed`, `adr_judge
#      disabled in .quality.exs` are standing project properties, true on
#      every run including the ones that were green when the policy was
#      written. Blocking on them makes `ok` false on *every* full gate run
#      forever, which does not enforce the rule - it deletes the signal, and
#      the first thing anyone does with a check that is always red is stop
#      reading it.
#
#    `PROJECT_LEVEL_SKIP_RE` draws that line, and it is deliberately narrow:
#    anything it does not match blocks. Adding a pattern to it is the same
#    class of decision as editing the gate config, so it belongs in review.
#    This is still stricter than `mix gate.verify`'s `data.attested`, which
#    mirrors only statifier-ex ADR-0011's narrowing test.
# 2. This script accepts exactly one profile argument, `--profile loop`, and
#    forwarding it always sets `attested: false`. Every other `--profile`
#    value, and `--skip`/`--quick` in any form, are simply not options this
#    parser defines - OptionParser rejects them as usage errors (exit 2)
#    before any envelope is built. There is no flag this script owns that
#    narrows what `mix quality` runs beyond that one case.
# 3. `data.sabotage.missing` and `data.gate_guard` are reports. Neither ever
#    flips `ok`, and there is no code path anywhere in this file that writes
#    docs/quality-gate-changes.md - see test/contract_test.rb.
module Gate
  # Skip reasons that describe the project's standing configuration rather
  # than a failure of this run. Matched against a stage's `summary` from the
  # `mix quality` JSON report. See rule 1 in the module doc for why this is
  # narrow and why widening it is a review decision, not a convenience.
  #
  #   ":doctor not installed"        - optional dep the project never added
  #   ":gettext not installed"       - same
  #   "disabled in .quality.exs"     - e.g. adr_judge, off outside --profile merge
  PROJECT_LEVEL_SKIP_RE = /
    \bnot\s+installed\b
    |
    \bdisabled\s+in\s+\.quality\.exs\b
  /x.freeze

  SABOTAGE_DIFF_ARGS = %w[
    git diff main...HEAD -U0 -- test/ :!test/scion_tests :!test/scxml_tests
  ].freeze

  # Matches both accepted note forms - a real mutation
  # (`# sabotage: <what> -> red`) and a stated exemption
  # (`# sabotage: n/a - <why>`) - because both start with the same prefix.
  # Presence is all this checks: docs/testing.md and /commit's Step 0 own the
  # judgment call about whether the mutation was actually run.
  SABOTAGE_NOTE_RE = /#\s*sabotage:/.freeze
  TEST_LINE_RE = /\btest\s+"/.freeze

  # Any comment line, used to walk the contiguous comment block above a test
  # line - a `# sabotage:` note may wrap across several `#`-prefixed lines,
  # and every line in that block has to keep matching this for the walk to
  # continue (a blank line or code line stops it, same as a missing note).
  COMMENT_LINE_RE = /\A\s*#/.freeze

  # Defense in depth: the pathspec on SABOTAGE_DIFF_ARGS already keeps these
  # out of the diff at the git level. Filtering them again here means the
  # scan is still correct even if this method is ever handed diff text from
  # somewhere else.
  EXEMPT_TEST_DIR_PREFIXES = ["test/scion_tests/", "test/scxml_tests/"].freeze

  class << self
    def parse_status_porcelain(out)
      out.to_s.each_line.map do |line|
        line = line.chomp
        next nil if line.empty?

        path = line[3..-1].to_s
        path.include?(" -> ") ? path.split(" -> ").last : path
      end.compact
    end

    # The carve-out predicate (see lib/gate_paths.rb) so /commit's Step 0
    # and this script cannot drift apart the way the trailer extraction once
    # did. Note this is `gate_applicable?`, not `touches_build?`: it is wider
    # than repo_state.rb's `touches_build` because a gate stage may measure
    # paths that touch no build at all.
    def gate_applicable?(env, manifest)
      diff_res = Sh.run(%w[git diff --name-only main...HEAD], envelope: env)
      diff_files =
        if diff_res.success?
          diff_res.out.to_s.each_line.map(&:strip).reject(&:empty?)
        else
          env.warn(code: "no_main_ref", message: "could not diff against local main ref")
          []
        end

      status_res = Sh.run(%w[git status --porcelain], envelope: env)
      dirty_files = parse_status_porcelain(status_res.out)

      GatePaths.gate_applicable?((diff_files + dirty_files).uniq, manifest: manifest)
    end

    # Parses a -U0 unified diff for added `test "..."` lines with no
    # `# sabotage:` note anywhere in the contiguous comment block directly
    # above them within the same hunk. Report-only - see the module doc.
    def scan_sabotage(diff_text)
      missing = []
      current_file = nil
      added_lines = []

      diff_text.to_s.each_line do |raw|
        line = raw.chomp

        if line.start_with?("+++ ")
          current_file = line.sub(%r{\A\+\+\+ (b/)?}, "")
          added_lines = []
          next
        end

        if line.start_with?("@@")
          added_lines = []
          next
        end

        next unless line.start_with?("+")

        content = line[1..-1].to_s
        exempt = EXEMPT_TEST_DIR_PREFIXES.any? { |prefix| current_file.to_s.start_with?(prefix) }

        if !exempt && content =~ TEST_LINE_RE && !sabotage_note_above?(added_lines)
          missing << { file: current_file, text: content.strip }
        end

        added_lines << content
      end

      missing
    end

    # Walks upward from the end of `added_lines` (the added lines seen so
    # far in the current hunk, in file order) over the contiguous run of
    # comment lines immediately preceding the test line, looking for a
    # `# sabotage:` note anywhere in that block. Stops at the first
    # non-comment line - a blank line or code line breaks contiguity, so a
    # note separated from the test by one is treated the same as no note at
    # all.
    def sabotage_note_above?(added_lines)
      idx = added_lines.length - 1
      while idx >= 0 && added_lines[idx] =~ COMMENT_LINE_RE
        return true if added_lines[idx] =~ SABOTAGE_NOTE_RE

        idx -= 1
      end
      false
    end

    def sabotage_missing(env)
      diff_res = Sh.run(SABOTAGE_DIFF_ARGS, envelope: env)
      return [] unless diff_res.success?

      scan_sabotage(diff_res.out)
    end

    def skipped_from(stages)
      Array(stages)
        .select { |s| s["status"] == "skipped" }
        .map do |s|
          summary = s["summary"]
          { name: s["name"], summary: summary, project_level: project_level_skip?(summary) }
        end
    end

    # True when the skip describes what this project checks at all, rather
    # than something this run could not do. See rule 1 in the module doc -
    # narrow on purpose; an unrecognized skip reason blocks.
    def project_level_skip?(summary)
      !(summary.to_s =~ PROJECT_LEVEL_SKIP_RE).nil?
    end

    # `data.gate_guard` is a report, never repaired: the ledger existence
    # check below is read-only (File.exist?), and the guarded-path findings
    # (if any) come straight from the "Gate guard" stage `mix quality`
    # itself already ran - this method adds no write path of its own. See
    # test/contract_test.rb, which asserts that mechanically.
    # Names the paths the project actually gates on, from the manifest, so
    # the reason a commit skipped the gate is checkable against the same
    # lists the predicate used - not against a sentence that drifted.
    def carve_out_reason(manifest)
      paths = (manifest.gate_build_paths + manifest.gate_also_gated_paths).join(", ")
      "no changes under #{paths} - nothing for the gate to measure"
    end

    def gate_guard_from(stages, ledger_path)
      stage = Array(stages).find { |s| s["name"] == "Gate guard" }

      {
        ledger_path: ledger_path,
        ledger_exists: !ledger_path.nil? && File.exist?(ledger_path),
        stage: stage && { status: stage["status"], summary: stage["summary"], findings: stage["findings"] }
      }
    end

    # Tier 1 (docs/gate-contract.md): `gate.report` / `gate.report_loop`
    # emit the machine-readable report. Where the manifest has no reporting
    # command for the mode being run, this degrades to tier 0 - the plain
    # gate command's exit code and nothing else. `report` comes back nil
    # there, and every judgment needing stage detail simply does not fire
    # rather than being faked from an empty stage list.
    #
    # The two reporting commands are separate manifest entries rather than a
    # base command this script appends a profile flag to. Composing argv
    # here would mean this script knowing one gate tool's flag surface,
    # which is exactly the coupling docs/gate-contract.md exists to avoid.
    def run_quality(env, manifest, loop_mode)
      reporting = loop_mode ? manifest.gate_report_loop : manifest.gate_report
      argv = reporting || (loop_mode ? manifest.gate_loop : manifest.gate_full)

      res = Sh.run(argv, envelope: env, timeout: 600)
      return [res, nil] unless reporting

      report = begin
        JSON.parse(res.out)
      rescue JSON::ParserError
        nil
      end
      [res, report]
    end

    def build_parser(options)
      Cli.build("gate.rb [--profile loop]", options) do |opts|
        opts.separator ""
        opts.separator "Wraps mix gate.verify and mix quality --format json --report -."
        opts.separator "The only --profile value accepted is 'loop' (inner-loop iteration; sets"
        opts.separator "data.attested to false so the caller cannot mistake it for a full green)."
        opts.separator "No --skip, no --quick, and no other --profile value is defined by this"
        opts.separator "parser, so OptionParser rejects them as a usage error (exit 2) - there is"
        opts.separator "no way to narrow what mix quality runs beyond the one --profile loop case."
        opts.separator ""
        opts.separator "data.sabotage.missing is a report, not a gate: it never blocks and never"
        opts.separator "flips ok. A present '# sabotage:' note is not evidence the mutation was"
        opts.separator "actually run against broken code - see docs/testing.md."
        opts.on("--profile PROFILE", "only 'loop' is accepted") do |v|
          raise OptionParser::InvalidArgument, "profile must be 'loop' (got #{v.inspect})" if v != "loop"

          options[:profile] = v
        end
      end
    end

    def run(argv, io: $stdout)
      options = {}
      parser, options = build_parser(options)
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "gate")
      loop_mode = options[:profile] == "loop"

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest

      ledger_path = manifest.gate_guard_ledger
      applicable = gate_applicable?(env, manifest)

      missing = sabotage_missing(env)
      env.data[:sabotage] = { missing: missing }
      missing.each do |m|
        env.warn(
          code: "sabotage_note_missing",
          message: "#{m[:file]}: #{m[:text]} has no `# sabotage:` note directly above it " \
                    "(a present note is not evidence the mutation was run)"
        )
      end

      env.data[:applicable] = applicable
      env.data[:carve_out_reason] = applicable ? nil : carve_out_reason(manifest)

      # The carve-out ("skip mix quality and review the diff instead") is a
      # pre-commit decision about the full gate - see /commit's Step 0. It
      # does not apply to --profile loop: that flag is a deliberate ask for
      # inner-loop feedback, not a request to decide whether a commit needs
      # the gate, so it always runs and always reports attested: false.
      if !applicable && !loop_mode
        env.data[:ran] = nil
        env.data[:attested] = nil
        env.data[:attestation_message] = nil
        env.data[:status] = nil
        env.data[:scope] = nil
        env.data[:profile] = nil
        env.data[:stages] = []
        env.data[:skipped_stages] = []
        env.data[:gate_guard] = gate_guard_from([], ledger_path)
        return env.emit(io)
      end

      res, report = run_quality(env, manifest, loop_mode)
      tier = report.nil? ? 0 : 1
      report ||= {}
      stages = report["stages"] || []
      skipped = skipped_from(stages)

      env.data[:ran] = loop_mode ? "loop" : "all"
      env.data[:tier] = tier
      env.data[:status] = report["status"]
      env.data[:scope] = report["scope"]
      env.data[:profile] = report["profile"]
      env.data[:stages] = stages
      env.data[:skipped_stages] = skipped
      env.data[:gate_guard] = gate_guard_from(stages, ledger_path)

      if loop_mode
        env.data[:attested] = false
        env.data[:attestation_message] = nil
      elsif manifest.gate_attest
        verify_res = Sh.run(manifest.gate_attest, envelope: env, timeout: 600)
        env.data[:attested] = verify_res.success?
        env.data[:attestation_message] =
          (verify_res.success? || verify_res.err.to_s.strip.empty? ? verify_res.out : verify_res.err).to_s.strip
      else
        # Tier 0/1 without attestation (docs/gate-contract.md): "prove it was
        # a full gate" degrades to "this run of gate.full exited zero". Say
        # so rather than reporting an attestation that never happened.
        env.data[:attested] = false
        env.data[:attestation_message] =
          "this project has no gate.attest command; attestation degrades to the exit code of the run above"
      end

      # Tier 1 judges on the report's status; tier 0 has only the exit code,
      # which is the whole of the contract's floor. Neither substitutes for
      # the other: a tier-0 green is "the gate command passed", never "a full
      # attested gate is green".
      if tier.zero?
        env.fail! unless res.success?
      elsif report["status"] && report["status"] != "ok"
        env.fail!
      end

      skipped.each do |s|
        if s[:project_level]
          # Reported, never blocking: this is a gap in what the project
          # checks at all, not in what this run measured. It is identical on
          # a green run and a red one, so gating on it would only ever mean
          # "the gate is permanently red".
          env.warn(
            code: "stage_skipped_project_level",
            message: "#{s[:name]} was skipped (#{s[:summary]}) - a standing project gap, not a failure " \
                     "of this run; still not a passing stage, so say so when reporting"
          )
        else
          env.block!(
            code: "stage_skipped",
            message: "#{s[:name]} was skipped (#{s[:summary]}) - the gate could not measure it on this " \
                     "run, and a skipped stage is not a passing one"
          )
        end
      end

      env.emit(io)
    end
  end
end

exit Gate.run(ARGV) if __FILE__ == $PROGRAM_NAME

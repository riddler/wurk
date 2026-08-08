#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/gate_paths"
require_relative "lib/manifest"

# Gate runs the consumer's own gate commands (gate.full, gate.loop,
# gate.report, gate.report_loop, gate.attest) and reports which tier of
# wurk docs/gate-contract.md the project reached. See statifier-ex
# docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 7 - this is the
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
#      A check that is not installed, or a stage disabled in the project's
#      own gate config, is a standing project property, true on every run
#      including the ones that were green when the policy was written.
#      Blocking on them makes `ok` false on *every* full gate run forever,
#      which does not enforce the rule - it deletes the signal, and the
#      first thing anyone does with a check that is always red is stop
#      reading it.
#
#    `gate.project_level_skips` (a manifest field, see docs/manifest.md)
#    draws that line, and a project declaring none gets the strict reading:
#    anything not matched blocks. Widening the list is the same class of
#    decision as editing the gate config, so it belongs in review - in the
#    consumer's own manifest, not in this script.
# 2. This script accepts exactly one profile argument, `--profile loop`, and
#    forwarding it always sets `attested: false`. Every other `--profile`
#    value, and `--skip`/`--quick` in any form, are simply not options this
#    parser defines - OptionParser rejects them as usage errors (exit 2)
#    before any envelope is built. There is no flag this script owns that
#    narrows what the gate command runs beyond that one case.
# 3. `data.sabotage.missing` and `data.gate_guard` are reports. Neither ever
#    flips `ok`, and there is no code path anywhere in this file that writes
#    docs/quality-gate-changes.md - see test/contract_test.rb. The sabotage
#    scan itself only runs when the manifest declares `gate.sabotage`; a
#    project that does not is reported as `enabled: false`, not silently
#    skipped.
module Gate
  # Matches both accepted note forms - a real mutation
  # (`# sabotage: <what> -> red`) and a stated exemption
  # (`# sabotage: n/a - <why>`) - because both start with the same prefix.
  # Presence is all this checks: docs/testing.md and /commit's Step 0 own the
  # judgment call about whether the mutation was actually run. This is
  # wurk's own comment-shape grammar, not consumer data - it stays a
  # constant.
  SABOTAGE_NOTE_RE = /#\s*sabotage:/.freeze

  # Any comment line, used to walk the contiguous comment block above a test
  # line - a `# sabotage:` note may wrap across several `#`-prefixed lines,
  # and every line in that block has to keep matching this for the walk to
  # continue (a blank line or code line stops it, same as a missing note).
  COMMENT_LINE_RE = /\A\s*#/.freeze

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

    # Parses a -U0 unified diff for added test-declaration lines (matching
    # `test_re`, manifest data) with no `# sabotage:` note anywhere in the
    # contiguous comment block directly above them within the same hunk.
    # Report-only - see the module doc.
    def scan_sabotage(diff_text, test_re:, exempt_prefixes: [])
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
        exempt = exempt_prefixes.any? { |prefix| current_file.to_s.start_with?(prefix) }

        if !exempt && content =~ test_re && !sabotage_note_above?(added_lines)
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

    # One definition site for the corpus exemptions: the pathspec keeps them
    # out of the diff at the git level, and scan_sabotage filters them again
    # in case it is ever handed diff text from elsewhere. Both read the same
    # manifest list.
    def sabotage_diff_args(manifest)
      %w[git diff main...HEAD -U0 --] +
        manifest.sabotage_test_roots +
        manifest.sabotage_exempt_prefixes.map { |prefix| ":!#{prefix}" }
    end

    # The scan is a manifest capability (gate.sabotage, see docs/manifest.md):
    # a project that never declares it gets no `git diff` shelled out for it
    # at all, and an empty [] rather than a false "nothing found".
    def sabotage_missing(env, manifest)
      return [] unless manifest.sabotage?

      diff_res = Sh.run(sabotage_diff_args(manifest), envelope: env)
      return [] unless diff_res.success?

      scan_sabotage(diff_res.out,
                    test_re: manifest.sabotage_test_pattern,
                    exempt_prefixes: manifest.sabotage_exempt_prefixes)
    end

    def skipped_from(stages, project_level_re)
      Array(stages)
        .select { |s| s["status"] == "skipped" }
        .map do |s|
          summary = s["summary"]
          { name: s["name"], summary: summary,
            project_level: project_level_skip?(summary, project_level_re) }
        end
    end

    # True when the skip describes what this project checks at all, rather
    # than something this run could not do. The patterns are manifest data
    # (gate.project_level_skips): a project that declares none gets the
    # strict reading, where every skipped stage blocks. See rule 1 in the
    # module doc.
    def project_level_skip?(summary, project_level_re)
      return false if project_level_re.nil?

      !(summary.to_s =~ project_level_re).nil?
    end

    # `data.gate_guard` is a report, never repaired: the ledger existence
    # check below is read-only (File.exist?), and the guarded-path findings
    # (if any) come straight from the "Gate guard" stage the gate command
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
        opts.separator "Runs the gate commands the manifest names (gate.full, gate.loop,"
        opts.separator "gate.report, gate.report_loop, gate.attest) and reports which tier of"
        opts.separator "wurk docs/gate-contract.md the project reached. It knows no gate tool's"
        opts.separator "flag surface."
        opts.separator "The only --profile value accepted is 'loop' (inner-loop iteration; sets"
        opts.separator "data.attested to false so the caller cannot mistake it for a full green)."
        opts.separator "No --skip, no --quick, and no other --profile value is defined by this"
        opts.separator "parser, so OptionParser rejects them as a usage error (exit 2) - there is"
        opts.separator "no way to narrow what the gate command runs beyond the one --profile loop case."
        opts.separator ""
        opts.separator "data.sabotage.missing is a report, not a gate: it never blocks and never"
        opts.separator "flips ok. A present '# sabotage:' note is not evidence the mutation was"
        opts.separator "actually run against broken code - see docs/testing.md. The scan only runs"
        opts.separator "when the manifest declares gate.sabotage; otherwise data.sabotage.enabled"
        opts.separator "is false and no diff is shelled out for it."
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

      missing = sabotage_missing(env, manifest)
      env.data[:sabotage] = {
        enabled: manifest.sabotage?,
        reason: manifest.sabotage? ? nil : "no gate.sabotage section in the manifest; the scan is off",
        missing: missing
      }
      missing.each do |m|
        env.warn(
          code: "sabotage_note_missing",
          message: "#{m[:file]}: #{m[:text]} has no `# sabotage:` note directly above it " \
                    "(a present note is not evidence the mutation was run)"
        )
      end

      env.data[:applicable] = applicable
      env.data[:carve_out_reason] = applicable ? nil : carve_out_reason(manifest)

      # The carve-out ("skip the gate command and review the diff instead") is a
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
      skipped = skipped_from(stages, manifest.project_level_skip_re)

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

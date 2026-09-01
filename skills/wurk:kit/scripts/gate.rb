#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/gate_paths"
require_relative "lib/manifest"
require_relative "lib/base_ref"

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
#    Whether a skip *blocks*, and whether it is worth naming when reporting,
#    are the next two questions, and each skip gets a three-way
#    `classification`:
#
#    - `run_level` - a gap **in this run**. Dialyzer skipping because the PLT
#      is missing, Tests skipping because compilation half-failed: the gate
#      was asked to measure something and could not, so `ok` is false.
#    - `project_level` - a gap in **what the project checks at all**. A check
#      that is not installed, or a stage disabled in the project's own gate
#      config, is a standing project property, true on every run including
#      the ones that were green when the policy was written. Blocking on
#      them makes `ok` false on *every* full gate run forever, which does not
#      enforce the rule - it deletes the signal, and the first thing anyone
#      does with a check that is always red is stop reading it. It does not
#      block, but it is still named in what you report.
#    - `not_applicable` - a gap the project has declared **permanently
#      inapplicable**, not a gap it means to close. It does not block, and
#      unlike `project_level` it is not required in reports either: naming a
#      stage that will never apply, forever, is the noise that trains
#      readers to stop reading the skip lines at all. It stays in
#      `data.skipped_stages` regardless - rule 1 does not bend for it.
#
#    `gate.project_level_skips` and `gate.not_applicable_skips` (manifest
#    fields, see docs/manifest.md) draw those lines, checked in that
#    precedence order (`not_applicable` first, since it is the narrower,
#    explicitly enumerated declaration), and a project declaring neither
#    gets the strict reading: anything not matched blocks. Widening either
#    list is the same class of decision as editing the gate config, so it
#    belongs in review - in the consumer's own manifest, not in this script.
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
#    skipped. `data.sabotage.unverifiable` is a report on the same terms as
#    `missing`: it names declarations this scan could not check at all, and
#    it never flips `ok` either.
module Gate
  # Matches both accepted note forms - a real mutation
  # (`# sabotage: <what> -> red`) and a stated exemption
  # (`# sabotage: n/a - <why>`) - because both start with the same prefix.
  # Case-insensitive: consumer repos write the prefix as `# sabotage:` or
  # `# Sabotage:` (house style differs per repo, and the operator ruled
  # 2026-08-27 to fix the scanner, not the convention). Presence is all
  # this checks: docs/testing.md and /wurk:commit's Step 0 own the
  # judgment call about whether the mutation was actually run. This is
  # wurk's own comment-shape grammar, not consumer data - it stays a
  # constant.
  SABOTAGE_NOTE_RE = /#\s*sabotage:/i.freeze

  # Any comment line, used to walk the contiguous comment block above a test
  # line - a `# sabotage:` note may wrap across several `#`-prefixed lines,
  # and every line in that block has to keep matching this for the walk to
  # continue (a blank line or code line stops it, same as a missing note).
  COMMENT_LINE_RE = /\A\s*#/.freeze

  class << self
    # The carve-out predicate (see lib/gate_paths.rb) so /wurk:commit's Step 0
    # and this script cannot drift apart the way the trailer extraction once
    # did. Note this is `gate_applicable?`, not `touches_build?`: it is wider
    # than repo_state.rb's `touches_build` because a gate stage may measure
    # paths that touch no build at all.
    #
    # `changed` is resolved once per run (see run) and threaded in: the
    # ladder shells out, warns on fallback, and gate.rb asks this question
    # twice per invocation.
    def gate_applicable?(manifest, changed)
      GatePaths.gate_applicable?(changed[:files], manifest: manifest)
    end

    # The working-tree lookup below's default: reads the file from disk,
    # returning nil (rather than raising) for anything that does not
    # currently exist or cannot be read - a file deleted since the diff was
    # taken, a permissions problem, etc. Callers treat nil the same as "can't
    # verify" rather than "no note"; see scan_sabotage.
    #
    # Was a constant lambda reading `path` against Dir.pwd. Diff paths are
    # repo-root-relative, so the reader has to know the root; injected readers
    # (tests) still receive the relative path unchanged, which is what keeps
    # this a seam rather than a signature change.
    def default_sabotage_file_reader(root)
      lambda do |path|
        File.read(File.join(root, path))
      rescue SystemCallError
        nil
      end
    end

    # Parses a -U0 unified diff for CANDIDATE test-declaration lines - added
    # lines matching `test_re` (manifest data) - and, for each candidate,
    # answers "does it have a `# sabotage:` note" against the WORKING-TREE
    # FILE, not the diff. The diff is only good for finding which lines
    # changed; a note's presence is a property of the file, not of the diff.
    # Two things go wrong if the note check stays diff-only: an edit that
    # touches the note and the test declaration but leaves an untouched line
    # between them splits the two across separate `-U0` hunks, and a note
    # that was not edited at all never appears in a `-U0` diff regardless of
    # hunks. Reading the file sidesteps both - it does not care which hunk
    # anything landed in, or whether the note changed at all.
    #
    # `file_reader` is an injectable seam (defaults to real disk reads) so
    # tests can hand in file contents without touching disk. Report-only -
    # see the module doc.
    def scan_sabotage(diff_text, test_re:, exempt_prefixes: [], file_reader:)
      missing = []
      unverifiable = []
      current_file = nil
      file_lines_by_path = {}

      diff_text.to_s.each_line do |raw|
        line = raw.chomp

        if line.start_with?("+++ ")
          current_file = line.sub(%r{\A\+\+\+ (b/)?}, "")
          next
        end

        next if line.start_with?("@@") || !line.start_with?("+")

        content = line[1..-1].to_s
        exempt = exempt_prefixes.any? { |prefix| current_file.to_s.start_with?(prefix) }
        next if exempt || content !~ test_re

        file_lines_by_path[current_file] = sabotage_file_lines(current_file, file_reader) unless
          file_lines_by_path.key?(current_file)
        file_lines = file_lines_by_path[current_file]

        if file_lines.nil?
          unverifiable << { reason: "file_unreadable", file: current_file, text: content.strip, detail: nil }
          next
        end

        case sabotage_note_status(file_lines, content)
        when :unnoted then missing << { file: current_file, text: content.strip }
        when :not_found
          unverifiable << { reason: "declaration_not_found", file: current_file, text: content.strip, detail: nil }
        end
      end

      { missing: missing, unverifiable: unverifiable }
    end

    # Reads `path` through `file_reader` and splits it into chomped lines,
    # or nil if the file does not exist / cannot be read. One read per file
    # per scan, regardless of how many candidate lines it contains.
    def sabotage_file_lines(path, file_reader)
      content = file_reader.call(path)
      return nil if content.nil?

      content.each_line.map(&:chomp)
    end

    # Does any line in `file_lines` equal to `content` (the candidate test
    # declaration) have a `# sabotage:` note directly above it? A
    # declaration can appear more than once verbatim (parameterized-looking
    # names, duplicated fixtures); checking every occurrence and accepting
    # if any one of them is noted is the charitable reading - it is the same
    # bar `-U0`'s old within-hunk check applied, just against the file
    # instead of the diff.
    #
    # Answers the note question three ways so the caller can tell a real
    # missing note from a declaration this scan could not locate at all.
    # :noted / :unnoted / :not_found. wu-lac's call stands - :not_found is
    # not a missing note - a declaration this scan cannot find in the file
    # at all (renamed again since the diff was taken, for example) is
    # treated as "can't verify", not "missing", the same call as the
    # missing-file case in scan_sabotage, and for the same reason: a
    # report-only scan should not manufacture a note-missing warning out of
    # its own inability to locate the line - but it is no longer silent.
    def sabotage_note_status(file_lines, content)
      indices = file_lines.each_index.select { |i| file_lines[i] == content }
      return :not_found if indices.empty?

      indices.any? { |i| sabotage_comment_block_above?(file_lines, i) } ? :noted : :unnoted
    end

    # Walks upward from the line directly above `idx` over the contiguous
    # run of comment lines, looking for a `# sabotage:` note anywhere in
    # that block. Stops at the first non-comment line - a blank line or code
    # line breaks contiguity, so a note separated from the declaration by
    # one is treated the same as no note at all.
    def sabotage_comment_block_above?(file_lines, idx)
      i = idx - 1
      while i >= 0 && file_lines[i] =~ COMMENT_LINE_RE
        return true if file_lines[i] =~ SABOTAGE_NOTE_RE

        i -= 1
      end
      false
    end

    # Two-dot against the merge-base sha, not `<base>...HEAD`: the two-dot
    # form includes uncommitted tracked edits, and an unproved test
    # declaration is likeliest to be exactly that. Same shape as judge.rb.
    # The pathspec keeps the corpus exemptions out at the git level.
    def sabotage_diff_args(manifest, base_sha)
      ["git", "diff", base_sha, "-U0", "--"] +
        manifest.sabotage_test_roots +
        manifest.sabotage_exempt_prefixes.map { |prefix| ":!#{prefix}" }
    end

    # An untracked path is invisible to any diff, two-dot included - it has
    # no committed side to diff against at all. Rather than silently skip it,
    # every untracked path under a sabotage test root (and outside the exempt
    # prefixes) is reported through the same `unverifiable` channel as a
    # declaration the diff-based scan could not check, report-only like every
    # other entry there.
    def sabotage_untracked_unverifiable(env, manifest)
      roots = manifest.sabotage_test_roots
      exempt = manifest.sabotage_exempt_prefixes
      BaseRef.untracked_files(env).select do |path|
        roots.any? { |root| path.start_with?(root) } && exempt.none? { |prefix| path.start_with?(prefix) }
      end.map { |path| { reason: "untracked", file: path, text: nil, detail: nil } }
    end

    # The scan is a manifest capability (gate.sabotage, see docs/manifest.md):
    # a project that never declares it gets no `git diff` shelled out for it
    # at all, and an empty [] rather than a false "nothing found".
    #
    # `base` is the ref `run` already resolved once via `BaseRef.changed_files`
    # (see run) - this method calls only `BaseRef.merge_base` itself, never the
    # ladder again, so one `gate.rb` invocation emits at most one
    # `stale_base_ref` warning. A `nil` base (no default-branch ref resolved)
    # or a `nil` merge base degrades to the existing `{scanned: false, ...}`
    # shape, with an `unverifiable` entry of `reason: "no_base_ref"` - the same
    # precedent as `diff_failed` below: the whole run, not one declaration,
    # went unchecked.
    #
    # A failed diff means this scan checked nothing at all - a different
    # claim from "checked everything and found nothing", and the one case
    # where the blind spot covers the whole run rather than one declaration.
    def sabotage_scan(env, manifest, base)
      return { scanned: false, missing: [], unverifiable: [] } unless manifest.sabotage?

      merge_base = BaseRef.merge_base(env, base)
      if merge_base.nil?
        return { scanned: false, missing: [],
                 unverifiable: [{ reason: "no_base_ref", file: nil, text: nil, detail: nil }] }
      end

      # Pathspecs (gate.sabotage.test_roots / exempt_prefixes) are cwd-relative
      # to git, unlike the diff output they produce - see docs/manifest.md's
      # "what is root-relative, and against what". chdir here, never
      # gate.cwd: this is a git command the kit itself runs, which gate.cwd
      # is explicitly never applied to.
      diff_res = Sh.run(sabotage_diff_args(manifest, merge_base), chdir: manifest.checkout_root, envelope: env)
      unless diff_res.success?
        return { scanned: false, missing: [],
                 unverifiable: [{ reason: "diff_failed", file: nil, text: nil,
                                  detail: diff_res.err.to_s.strip }] }
      end

      result = scan_sabotage(diff_res.out,
                              test_re: manifest.sabotage_test_pattern,
                              exempt_prefixes: manifest.sabotage_exempt_prefixes,
                              file_reader: default_sabotage_file_reader(manifest.checkout_root)).merge(scanned: true)
      result[:unverifiable] += sabotage_untracked_unverifiable(env, manifest)
      result
    end

    def skipped_from(stages, project_level_re, not_applicable_re)
      Array(stages)
        .select { |s| s["status"] == "skipped" }
        .map do |s|
          summary = s["summary"]
          { name: s["name"], summary: summary,
            classification: classify_skip(summary, project_level_re, not_applicable_re) }
        end
    end

    # Three-way, in precedence order. "not_applicable" is checked first: it is
    # the narrower, explicitly enumerated declaration, and a project whose
    # project-level pattern is broad ("not installed") must be able to carve
    # one stage out of it without rewriting the broad pattern. Both regexes
    # are manifest data (gate.not_applicable_skips, gate.project_level_skips),
    # and a nil regex never matches - which is what makes "declare neither
    # list and every skipped stage blocks" the default rather than a special
    # case. See rule 1 in the module doc.
    def classify_skip(summary, project_level_re, not_applicable_re)
      return "not_applicable" if matches?(summary, not_applicable_re)
      return "project_level" if matches?(summary, project_level_re)

      "run_level"
    end

    def matches?(summary, re)
      return false if re.nil?

      !(summary.to_s =~ re).nil?
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

    def gate_guard_from(stages, ledger_path, root)
      stage = Array(stages).find { |s| s["name"] == "Gate guard" }

      {
        ledger_path: ledger_path,
        # Resolved against the manifest's checkout root, not Dir.pwd: manifest
        # resolution walks up from the working directory, so gate.rb is
        # legitimately invoked from a subdirectory, where a bare relative
        # File.exist? silently reports a present ledger as absent.
        ledger_exists: !ledger_path.nil? && File.exist?(File.join(root, ledger_path)),
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

      res = Sh.run(argv, chdir: manifest.gate_chdir, envelope: env, timeout: manifest.gate_timeout_seconds)
      return [res, nil] unless reporting

      report = begin
        JSON.parse(res.out)
      rescue JSON::ParserError
        nil
      end
      [res, report]
    end

    # The last lines of the gate command's captured output, where a gate that
    # prints a trailing VERDICT/summary line puts its verdict. Combines stdout
    # and stderr because a gate command may write its failure to either.
    GATE_OUTPUT_TAIL_LINES = 40

    def gate_output_tail(res)
      [res.out, res.err]
        .map(&:to_s)
        .reject(&:empty?)
        .join("\n")
        .lines
        .last(GATE_OUTPUT_TAIL_LINES)
        .join
        .strip
    end

    # A structured summary of a tier-0 gate command that exited non-zero (or
    # timed out). Tier 0 has no per-stage report, so without this the failure
    # is illegible: the envelope is {ok:false, stages:[]} and nothing else,
    # and an empty stages array reads as "nothing needed checking" exactly as
    # easily as "the gate ran and failed". This is the only place that
    # ambiguity gets resolved, so it carries the exit status, the timeout
    # flag, and the output tail rather than leaving all three in res, which
    # the envelope never surfaces.
    def gate_failure_output(res)
      {
        exit_status: res.status && res.status.exitstatus,
        timed_out: res.timed_out?,
        output_tail: gate_output_tail(res)
      }
    end

    # The human-readable companion to data.gate_output. States in one sentence
    # the thing the empty stages array otherwise leaves ambiguous: the gate
    # ran and failed, and stages is empty because this project reports at
    # tier 0 (no machine-readable per-stage report), NOT because nothing was
    # checked. The timeout case is named separately - a killed gate that never
    # printed its verdict is the shape most often misread as a pass.
    def tier0_failure_message(res)
      if res.timed_out?
        "the tier-0 gate command timed out and was killed before it finished; data.stages is " \
          "empty because no per-stage report was produced, not because nothing needed checking - " \
          "see data.gate_output for the captured output tail"
      else
        code = res.status && res.status.exitstatus
        "the tier-0 gate command exited #{code.nil? ? 'non-zero' : code} and this project has no " \
          "machine-readable report command; data.stages is empty because none was reported, not " \
          "because nothing needed checking - see data.gate_output for the exit status and output tail"
      end
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
      changed = BaseRef.changed_files(env, manifest: manifest)
      applicable = gate_applicable?(manifest, changed)

      scan = sabotage_scan(env, manifest, changed[:base])
      env.data[:sabotage] = {
        enabled: manifest.sabotage?,
        reason: manifest.sabotage? ? nil : "no gate.sabotage section in the manifest; the scan is off",
        scanned: scan[:scanned],
        missing: scan[:missing],
        unverifiable: scan[:unverifiable]
      }
      scan[:missing].each do |m|
        env.warn(
          code: "sabotage_note_missing",
          message: "#{m[:file]}: #{m[:text]} has no `# sabotage:` note directly above it " \
                    "(a present note is not evidence the mutation was run)"
        )
      end
      if scan[:unverifiable].any? { |u| u[:reason] == "diff_failed" }
        env.warn(
          code: "sabotage_scan_failed",
          message: "the sabotage scan's git diff failed, so nothing was checked - " \
                   "an empty missing list here is not a clean result"
        )
      end
      if scan[:unverifiable].any? { |u| u[:reason] == "no_base_ref" }
        env.warn(
          code: "sabotage_scan_failed",
          message: "the sabotage scan had no base ref to diff against, so nothing was checked - " \
                   "an empty missing list here is not a clean result"
        )
      end
      scan[:unverifiable].each do |u|
        next if u[:reason] == "diff_failed" || u[:reason] == "no_base_ref"

        env.warn(
          code: "sabotage_unverifiable",
          message: "#{u[:file]}: #{u[:text]} could not be checked for a `# sabotage:` note " \
                   "(#{u[:reason]}) - this is not a clean result for that declaration"
        )
      end

      env.data[:applicable] = applicable
      env.data[:carve_out_reason] = applicable ? nil : carve_out_reason(manifest)

      # The carve-out ("skip the gate command and review the diff instead") is a
      # pre-commit decision about the full gate - see /wurk:commit's Step 0. It
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
        env.data[:gate_guard] = gate_guard_from([], ledger_path, manifest.checkout_root)
        env.data[:gate_cwd] = nil
        return env.emit(io)
      end

      res, report = run_quality(env, manifest, loop_mode)

      # The gate command itself never got a chance to run: a typo'd gate.cwd
      # or a gate command missing from PATH (Sh::Result#start_failed?, see
      # lib/sh.rb). This is a misconfiguration for a human to fix, not a
      # failing test run, so it reads as blocked - with the concrete cause
      # (command and directory) named in the message - rather than as an
      # ordinary tier-0 failure that would say nothing about why. No stage
      # detail exists to report, so this returns early the same way the
      # carve-out path does.
      if res.start_failed?
        env.data[:ran] = loop_mode ? "loop" : "all"
        env.data[:tier] = 0
        env.data[:status] = nil
        env.data[:scope] = nil
        env.data[:profile] = nil
        env.data[:stages] = []
        env.data[:skipped_stages] = []
        env.data[:gate_guard] = gate_guard_from([], ledger_path, manifest.checkout_root)
        env.data[:gate_cwd] = manifest.gate_chdir
        env.data[:attested] = false
        env.data[:attestation_message] = nil
        # res.err is already the self-describing sentence Sh emits (see
        # lib/sh.rb's start_failure_message) - naming the command and, when
        # set, the chdir - so it becomes the message as-is rather than
        # getting a second "could not start" wrapped around it.
        env.block!(
          code: "gate_command_could_not_start",
          message: res.err,
          needs: "human"
        )
        return env.emit(io)
      end

      tier = report.nil? ? 0 : 1
      report ||= {}
      stages = report["stages"] || []
      skipped = skipped_from(stages, manifest.project_level_skip_re, manifest.not_applicable_skip_re)

      env.data[:ran] = loop_mode ? "loop" : "all"
      env.data[:tier] = tier
      env.data[:status] = report["status"]
      env.data[:scope] = report["scope"]
      env.data[:profile] = report["profile"]
      env.data[:stages] = stages
      env.data[:skipped_stages] = skipped
      env.data[:gate_guard] = gate_guard_from(stages, ledger_path, manifest.checkout_root)
      # Resolved absolute directory the gate command ran in, or nil when the
      # project gates from its checkout root. The `commands` trail already
      # shows it via Sh.render; this makes it machine-readable for the
      # skills.
      env.data[:gate_cwd] = manifest.gate_chdir
      # Populated only on a tier-0 failure (below); nil otherwise so the key is
      # always present. Tier 1 already carries its failure in data.stages.
      env.data[:gate_output] = nil

      if loop_mode
        env.data[:attested] = false
        env.data[:attestation_message] = nil
      elsif manifest.gate_attest
        verify_res = Sh.run(manifest.gate_attest, chdir: manifest.gate_chdir, envelope: env,
                            timeout: manifest.gate_timeout_seconds)
        if verify_res.start_failed?
          # Same misconfiguration class as the quality-run case above, just
          # discovered one step later (gate.full itself started fine; the
          # attest command is the one that could not).
          env.data[:attested] = false
          env.data[:attestation_message] = verify_res.err
          # Same reasoning as the quality-run branch above: verify_res.err is
          # already self-describing, so it is the message as-is.
          env.block!(
            code: "gate_attest_could_not_start",
            message: verify_res.err,
            needs: "human"
          )
        else
          env.data[:attested] = verify_res.success?
          env.data[:attestation_message] =
            (verify_res.success? || verify_res.err.to_s.strip.empty? ? verify_res.out : verify_res.err).to_s.strip
        end
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
        unless res.success?
          # Without this, a tier-0 failure is {ok:false, stages:[]} with no
          # message and the command's own output surfaced nowhere - an empty
          # stages array that reads as "nothing needed checking" as readily as
          # "the gate failed". data.gate_output + this warning make which one
          # it is legible; the timeout case is called out by name.
          env.data[:gate_output] = gate_failure_output(res)
          env.warn(code: "gate_tier0_failure", message: tier0_failure_message(res))
          env.fail!
        end
      elsif report["status"] && report["status"] != "ok"
        env.fail!
      end

      skipped.each do |s|
        case s[:classification]
        when "not_applicable"
          # Declared permanently inapplicable in the consumer's own manifest.
          # Still in data.skipped_stages - rule 1 does not bend - but naming
          # it in every report forever is noise that trains readers to skim
          # the skip lines, so this warning says so instead of asking for it.
          env.warn(
            code: "stage_skipped_not_applicable",
            message: "#{s[:name]} was skipped (#{s[:summary]}) - declared permanently inapplicable to " \
                     "this project (gate.not_applicable_skips); not a passing stage, and not required " \
                     "in reports"
          )
        when "project_level"
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

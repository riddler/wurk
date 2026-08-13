# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../gate"
require_relative "../lib/gate_paths"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"

class GateTest < Minitest::Test
  include ManifestHelper

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
    @orig_pwd = Dir.pwd
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
    Dir.chdir(@orig_pwd)
  end

  def run_gate(argv = [])
    io = StringIO.new
    code = Gate.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  # Runs the block inside a fresh tmp dir carrying a fixture manifest, so
  # the ledger-existence check (a relative path) resolves predictably
  # regardless of where the ledger happens to exist in this real checkout,
  # and the gate commands under test are `make report`/`make attest` rather
  # than this repo's own - see support/manifest_helper.rb.
  def in_tmp_cwd(ledger_present: false, fixture: "gate_tier1")
    in_tmp_repo(fixture) do |dir|
      if ledger_present
        FileUtils.mkdir_p(File.join(dir, "docs"))
        File.write(File.join(dir, "docs", "quality-gate-changes.md"), "# ledger\n")
      end
      yield
    end
  end

  def expect_no_elixir_diff
    @fake.expect(%w[git diff --name-only main...HEAD], out: "docs/plans/x.md\n")
    @fake.expect(%w[git status --porcelain], out: "")
  end

  def expect_elixir_diff
    @fake.expect(%w[git diff --name-only main...HEAD], out: "lib/acme/foo.ex\n")
    @fake.expect(%w[git status --porcelain], out: "")
  end

  def expect_scripts_only_diff
    @fake.expect(%w[git diff --name-only main...HEAD], out: ".claude/scripts/gate.rb\n")
    @fake.expect(%w[git status --porcelain], out: "")
  end

  def expect_skills_only_diff
    @fake.expect(%w[git diff --name-only main...HEAD], out: ".claude/skills/commit/SKILL.md\n")
    @fake.expect(%w[git status --porcelain], out: "")
  end

  def expect_no_sabotage_diff(out: "")
    @fake.expect(
      %w[git diff main...HEAD -U0 -- test/ :!test/scion_tests/ :!test/scxml_tests/],
      out: out
    )
  end

  GREEN_REPORT = {
    "status" => "ok",
    "scope" => "all",
    "stages" => [
      { "name" => "Format", "status" => "ok", "summary" => "clean" },
      { "name" => "Compile", "status" => "ok", "summary" => "no warnings" }
    ]
  }.freeze

  def test_carve_out_applies_and_skips_the_gate_entirely
    in_tmp_cwd do
      expect_no_elixir_diff
      expect_no_sabotage_diff

      code, env = run_gate

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal false, env["data"]["applicable"]
      refute_nil env["data"]["carve_out_reason"]
      assert_nil env["data"]["ran"]
      assert_nil env["data"]["attested"]
      assert_equal [], env["data"]["skipped_stages"]
      # No `make report` or `make attest` call was ever registered above,
      # so if the script tried to shell out to either, FakeSh would raise
      # FakeSh::UnexpectedCommand and this test would fail loudly.
    end
  end

  def test_full_run_green_report_attests_and_is_ok
    in_tmp_cwd do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[make report], out: JSON.generate(GREEN_REPORT))
      @fake.expect(%w[make attest], out: "Full gate green: scope all, no profile, 2 stages considered.\n")

      code, env = run_gate

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal true, env["data"]["applicable"]
      assert_equal "all", env["data"]["ran"]
      assert_equal true, env["data"]["attested"]
      assert_equal [], env["data"]["skipped_stages"]
      assert_equal [], env["blocked"]
    end
  end

  # sabotage: read a hardcoded "main...HEAD" in gate_applicable? instead of
  # manifest.default_branch -> red (FakeSh::UnexpectedCommand: no stub is
  # registered for "main...HEAD" here, only for "trunk...HEAD")
  def test_gate_applicable_diff_uses_the_manifests_default_branch
    other = manifest_with("gate_tier1", "repo" => { "default_branch" => "trunk" })

    Manifest.reset!
    with_manifest(other) do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          @fake.expect(%w[git diff --name-only trunk...HEAD], out: "lib/acme/foo.ex\n")
          @fake.expect(%w[git status --porcelain], out: "")
          @fake.expect(
            %w[git diff trunk...HEAD -U0 -- test/ :!test/scion_tests/ :!test/scxml_tests/],
            out: ""
          )
          @fake.expect(%w[make report], out: JSON.generate(GREEN_REPORT))
          @fake.expect(%w[make attest], out: "Full gate green: scope all, no profile, 2 stages considered.\n")

          code, env = run_gate

          assert_equal 0, code
          assert_equal true, env["ok"]
          assert_equal true, env["data"]["applicable"]
        end
      end
    end
  end

  # sabotage: read a hardcoded "main...HEAD" in sabotage_diff_args instead of
  # manifest.default_branch -> red (FakeSh::UnexpectedCommand: no stub is
  # registered for the "main...HEAD" pathspec)
  def test_sabotage_pathspec_uses_the_manifests_default_branch
    other = manifest_with("gate_tier1", "repo" => { "default_branch" => "trunk" })

    Manifest.reset!
    with_manifest(other) do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          @fake.expect(%w[git diff --name-only trunk...HEAD], out: "docs/plans/x.md\n")
          @fake.expect(%w[git status --porcelain], out: "")
          @fake.expect(
            %w[git diff trunk...HEAD -U0 -- test/ :!test/scion_tests/ :!test/scxml_tests/],
            out: "diff --git a/test/foo_test.exs b/test/foo_test.exs\n" \
                 "--- a/test/foo_test.exs\n+++ b/test/foo_test.exs\n@@ -0,0 +1,1 @@\n" \
                 "+  test \"missing its note\" do\n"
          )
          # scan_sabotage checks the working-tree file, not the diff - see
          # gate.rb - so the fixture needs one on disk with no note above
          # the candidate line.
          FileUtils.mkdir_p("test")
          File.write("test/foo_test.exs", "  test \"missing its note\" do\n")

          _code, env = run_gate

          assert_equal true, env["data"]["sabotage"]["enabled"]
          assert_equal 1, env["data"]["sabotage"]["missing"].length
          assert_equal "sabotage_note_missing", env["warnings"].first["code"]
        end
      end
    end
  end

  # sabotage: keep emitting the pre-rename warning code once the base branch
  # became configurable -> red
  def test_no_base_ref_warning_when_the_diff_fails
    in_tmp_cwd do
      @fake.expect(%w[git diff --name-only main...HEAD], exitstatus: 1, err: "fatal: bad revision\n")
      @fake.expect(%w[git status --porcelain], out: "")
      expect_no_sabotage_diff

      code, env = run_gate

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal false, env["data"]["applicable"]
      assert env["warnings"].any? { |w| w["code"] == "no_base_ref" }
    end
  end

  # A skip the gate hit *on this run* blocks: it was asked to measure
  # something and could not. See gate.rb rule 1.
  # sabotage: make classify_skip return "project_level" unconditionally -> red
  def test_run_level_skipped_stage_forces_ok_false_even_though_status_is_ok
    report = {
      "status" => "ok",
      "scope" => "all",
      "stages" => [
        { "name" => "Format", "status" => "ok", "summary" => "clean" },
        { "name" => "Dialyzer", "status" => "skipped", "summary" => "PLT missing, run mix dialyzer --plt" }
      ]
    }

    in_tmp_cwd do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[make report], out: JSON.generate(report))
      @fake.expect(%w[make attest], out: "Full gate green...\n")

      code, env = run_gate

      assert_equal 1, code
      assert_equal false, env["ok"]
      assert_equal 1, env["data"]["skipped_stages"].length
      assert_equal "Dialyzer", env["data"]["skipped_stages"].first["name"]
      assert_equal "run_level", env["data"]["skipped_stages"].first["classification"]
      assert_equal 1, env["blocked"].length
      assert_equal "stage_skipped", env["blocked"].first["code"]
      # Skipped stages are a report, not evidence the run failed - so this
      # must still show up in data, not silently vanish.
      assert_equal report["stages"], env["data"]["stages"]
    end
  end

  # A stage the project never installed is a standing gap, identical on every
  # run. Blocking on it would make ok false on every full gate run forever,
  # which deletes the signal rather than enforcing it. It is still reported,
  # in data and as a warning - CLAUDE.md's "a skipped stage is not a passing
  # one" governs what you *say*, and this keeps it sayable.
  # sabotage: env.warn -> env.block! in the project_level branch -> red
  def test_project_level_skips_are_reported_but_never_block
    report = {
      "status" => "ok",
      "scope" => "all",
      "stages" => [
        { "name" => "Format", "status" => "ok", "summary" => "clean" },
        { "name" => "Doctor", "status" => "skipped", "summary" => ":doctor not installed" },
        { "name" => "ADR judge", "status" => "skipped", "summary" => "disabled in .quality.exs" }
      ]
    }

    in_tmp_cwd do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[make report], out: JSON.generate(report))
      @fake.expect(%w[make attest], out: "Full gate green...\n")

      code, env = run_gate

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal [], env["blocked"]
      # Reported, not laundered: both still surface, and each carries a
      # warning a caller has to actively ignore.
      assert_equal 2, env["data"]["skipped_stages"].length
      assert(env["data"]["skipped_stages"].all? { |s| s["classification"] == "project_level" })
      codes = env["warnings"].map { |w| w["code"] }
      assert_equal 2, codes.count("stage_skipped_project_level")
    end
  end

  # A stage the project has declared permanently inapplicable (rather than a
  # gap it means to close) does not block, and does not carry the "still not
  # a passing stage, so say so when reporting" nag - it carries its own
  # warning saying the opposite: not required in reports.
  # sabotage: env.warn -> env.block! in the not_applicable branch -> red
  def test_not_applicable_skip_is_reported_but_never_required
    report = {
      "status" => "ok",
      "scope" => "all",
      "stages" => [
        { "name" => "Format", "status" => "ok", "summary" => "clean" },
        { "name" => "Gettext", "status" => "skipped", "summary" => ":gettext not installed" }
      ]
    }

    in_tmp_cwd do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[make report], out: JSON.generate(report))
      @fake.expect(%w[make attest], out: "Full gate green...\n")

      code, env = run_gate

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal [], env["blocked"]
      assert_equal 1, env["data"]["skipped_stages"].length
      assert_equal "not_applicable", env["data"]["skipped_stages"].first["classification"]
      codes = env["warnings"].map { |w| w["code"] }
      assert_includes codes, "stage_skipped_not_applicable"
      refute_includes codes, "stage_skipped_project_level"
    end
  end

  # The fixture deliberately overlaps: gate_tier1's project_level_skips has
  # an unanchored "not installed" that would also match the gettext summary,
  # but not_applicable_skips names it explicitly, and the narrower,
  # explicitly enumerated list wins.
  # sabotage: swap the two `return` lines in classify_skip -> red
  def test_not_applicable_takes_precedence_over_an_overlapping_project_level_pattern
    report = {
      "status" => "ok",
      "scope" => "all",
      "stages" => [
        { "name" => "Doctor", "status" => "skipped", "summary" => ":doctor not installed" },
        { "name" => "Gettext", "status" => "skipped", "summary" => ":gettext not installed" }
      ]
    }

    in_tmp_cwd do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[make report], out: JSON.generate(report))
      @fake.expect(%w[make attest], out: "Full gate green...\n")

      code, env = run_gate

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal [], env["blocked"]
      by_name = env["data"]["skipped_stages"].each_with_object({}) { |s, h| h[s["name"]] = s["classification"] }
      assert_equal "project_level", by_name["Doctor"]
      assert_equal "not_applicable", by_name["Gettext"]
    end
  end

  # With both lists absent, the strict default applies: even a
  # gettext-shaped summary blocks, not just a doctor-shaped one.
  # sabotage: make Gate.matches? return true when handed a nil regex -> red
  def test_absent_both_skip_lists_blocks_even_a_not_applicable_shaped_reason
    report = {
      "status" => "ok",
      "scope" => "all",
      "stages" => [
        { "name" => "Gettext", "status" => "skipped", "summary" => ":gettext not installed" }
      ]
    }

    other = manifest_with("gate_tier1", "gate" => { "not_applicable_skips" => nil, "project_level_skips" => nil })

    Manifest.reset!
    with_manifest(other) do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          expect_elixir_diff
          expect_no_sabotage_diff
          @fake.expect(%w[make report], out: JSON.generate(report))
          @fake.expect(%w[make attest], out: "Full gate green...\n")

          code, env = run_gate

          assert_equal 1, code
          assert_equal false, env["ok"]
          assert_equal ["stage_skipped"], env["blocked"].map { |b| b["code"] }
          assert_equal "run_level", env["data"]["skipped_stages"].first["classification"]
        end
      end
    end
  end

  # Direct unit test of the three-way classifier, independent of a full gate
  # run - including the never-match nil/"" summary cases.
  # sabotage: drop the not_applicable_re nil guard in matches? -> red
  # (NoMethodError on nil =~ re, or a nil summary crashing the match)
  def test_classify_skip_is_a_direct_three_way_unit
    re = fixture_manifest("gate_tier1")

    assert_equal "not_applicable", Gate.classify_skip(":gettext not installed", re.project_level_skip_re, re.not_applicable_skip_re)
    assert_equal "project_level", Gate.classify_skip(":doctor not installed", re.project_level_skip_re, re.not_applicable_skip_re)
    assert_equal "run_level", Gate.classify_skip("some new reason nobody anticipated", re.project_level_skip_re, re.not_applicable_skip_re)
    assert_equal "run_level", Gate.classify_skip(nil, re.project_level_skip_re, re.not_applicable_skip_re)
    assert_equal "run_level", Gate.classify_skip("", re.project_level_skip_re, re.not_applicable_skip_re)
  end

  # The mix of both: the project-level skips must not mask the run-level one.
  # sabotage: `skipped.each` -> `skipped.first` in gate.rb -> red
  def test_a_run_level_skip_still_blocks_alongside_project_level_ones
    report = {
      "status" => "ok",
      "scope" => "all",
      "stages" => [
        { "name" => "Doctor", "status" => "skipped", "summary" => ":doctor not installed" },
        { "name" => "Tests", "status" => "skipped", "summary" => "compilation failed" }
      ]
    }

    in_tmp_cwd do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[make report], out: JSON.generate(report))
      @fake.expect(%w[make attest], out: "Full gate green...\n")

      code, env = run_gate

      assert_equal 1, code
      assert_equal false, env["ok"]
      assert_equal 1, env["blocked"].length
      assert_match(/Tests was skipped/, env["blocked"].first["message"])
    end
  end

  # sabotage: widen gate_tier1's project_level_skips with `|.` -> red
  def test_unrecognized_skip_reason_blocks_by_default
    manifest = fixture_manifest("gate_tier1")
    project_level_re = manifest.project_level_skip_re
    not_applicable_re = manifest.not_applicable_skip_re

    assert_equal "run_level", Gate.classify_skip("some new reason nobody anticipated", project_level_re, not_applicable_re)
    assert_equal "run_level", Gate.classify_skip(nil, project_level_re, not_applicable_re)
    assert_equal "run_level", Gate.classify_skip("", project_level_re, not_applicable_re)
    assert_equal "project_level", Gate.classify_skip(":doctor not installed", project_level_re, not_applicable_re)
    assert_equal "project_level", Gate.classify_skip("disabled in .quality.exs", project_level_re, not_applicable_re)
  end

  # With gate.project_level_skips absent, the strict default applies: even a
  # summary that looks project-level (":doctor not installed") blocks.
  # sabotage: make project_level_skip_re return a match-anything regex when
  # the field is nil -> red
  def test_absent_project_level_skips_blocks_even_a_familiar_looking_reason
    report = {
      "status" => "ok",
      "scope" => "all",
      "stages" => [
        { "name" => "Doctor", "status" => "skipped", "summary" => ":doctor not installed" }
      ]
    }

    other = manifest_with("gate_tier1", "gate" => { "project_level_skips" => nil })

    Manifest.reset!
    with_manifest(other) do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          expect_elixir_diff
          expect_no_sabotage_diff
          @fake.expect(%w[make report], out: JSON.generate(report))
          @fake.expect(%w[make attest], out: "Full gate green...\n")

          code, env = run_gate

          assert_equal 1, code
          assert_equal false, env["ok"]
          assert_equal ["stage_skipped"], env["blocked"].map { |b| b["code"] }
          assert_equal "run_level", env["data"]["skipped_stages"].first["classification"]
        end
      end
    end
  end

  # The mirror of the above: with the field declared (gate_tier1's fixture
  # value), the same summary is project-level and does not block. Proves the
  # field is actually read, not that the strictness is unconditional.
  # sabotage: make classify_skip ignore project_level_re entirely -> red
  def test_declared_project_level_skips_makes_the_same_reason_non_blocking
    report = {
      "status" => "ok",
      "scope" => "all",
      "stages" => [
        { "name" => "Doctor", "status" => "skipped", "summary" => ":doctor not installed" }
      ]
    }

    in_tmp_cwd do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[make report], out: JSON.generate(report))
      @fake.expect(%w[make attest], out: "Full gate green...\n")

      code, env = run_gate

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal [], env["blocked"]
      assert_equal "project_level", env["data"]["skipped_stages"].first["classification"]
    end
  end

  def test_red_gate_fails_without_being_blocked
    report = {
      "status" => "error",
      "scope" => "all",
      "stages" => [
        { "name" => "Credo", "status" => "error", "summary" => "5 issues" }
      ]
    }

    in_tmp_cwd do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[make report], out: JSON.generate(report))
      @fake.expect(%w[make attest], exitstatus: 1, err: "** (Mix) Not a full gate: the gate is red (Credo).\n")

      code, env = run_gate

      assert_equal 1, code
      assert_equal false, env["ok"]
      assert_equal false, env["data"]["attested"]
      assert_equal "error", env["data"]["status"]
    end
  end

  def test_profile_loop_sets_attested_false_and_forwards_the_loop_profile_only
    report = {
      "status" => "ok",
      "profile" => "loop",
      "scope" => "changed",
      "stages" => [{ "name" => "Format", "status" => "ok", "summary" => "clean" }]
    }

    in_tmp_cwd do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[make report-loop], out: JSON.generate(report))
      # No `make attest` expectation registered: a loop run must never
      # call it, since attested is already forced to false.

      code, env = run_gate(["--profile", "loop"])

      assert_equal 0, code
      assert_equal "loop", env["data"]["ran"]
      assert_equal false, env["data"]["attested"]
    end
  end

  def test_profile_loop_runs_even_when_the_carve_out_would_otherwise_apply
    report = {
      "status" => "ok",
      "profile" => "loop",
      "scope" => "changed",
      "stages" => [{ "name" => "Format", "status" => "ok", "summary" => "clean" }]
    }

    in_tmp_cwd do
      expect_no_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[make report-loop], out: JSON.generate(report))

      code, env = run_gate(["--profile", "loop"])

      assert_equal 0, code
      assert_equal false, env["data"]["applicable"]
      assert_equal "loop", env["data"]["ran"]
      assert_equal false, env["data"]["attested"]
    end
  end

  # --- gate contract tiers (wurk docs/gate-contract.md) -------------------
  #
  # Tier 0 is the floor every consumer repo meets: gate.full/gate.loop and an
  # exit code, nothing else. Everything the tier-1 tests above assert about
  # stage detail simply does not fire here - and must not be faked from an
  # empty stage list, which would report "no skipped stages" for a run that
  # measured nothing of the sort.

  # sabotage: judge tier 0 on report["status"] (always nil) instead of the
  # exit code -> red
  def test_tier_0_green_comes_from_the_exit_code_of_gate_full
    in_tmp_cwd(fixture: "gate_tier0") do
      expect_elixir_diff
      @fake.expect(%w[make check], out: "everything is fine\n")

      code, env = run_gate

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal 0, env["data"]["tier"]
      assert_equal [], env["data"]["stages"]
      assert_equal [], env["data"]["skipped_stages"]
    end
  end

  # sabotage: drop the `env.fail! unless res.success?` tier-0 branch -> red
  def test_tier_0_red_exit_code_makes_the_envelope_not_ok
    in_tmp_cwd(fixture: "gate_tier0") do
      expect_elixir_diff
      @fake.expect(%w[make check], out: "boom\n", exitstatus: 1)

      code, env = run_gate

      assert_equal 1, code
      assert_equal false, env["ok"]
      assert_equal 0, env["data"]["tier"]
    end
  end

  # No gate.attest command means "prove it was a full gate" degrades to the
  # exit code of the run - and says so, rather than reporting an attestation
  # that never happened (docs/gate-contract.md, degradation summary).
  #
  # sabotage: report attested: true when gate.attest is absent -> red
  def test_absent_attest_command_reports_attested_false_and_explains_why
    in_tmp_cwd(fixture: "gate_tier0") do
      expect_elixir_diff
      @fake.expect(%w[make check], out: "fine\n")

      _code, env = run_gate

      assert_equal false, env["data"]["attested"]
      assert_match(/no gate\.attest command/, env["data"]["attestation_message"])
    end
  end

  def test_tier_0_loop_run_uses_gate_loop
    in_tmp_cwd(fixture: "gate_tier0") do
      expect_elixir_diff
      @fake.expect(%w[make quick], out: "fine\n")

      code, env = run_gate(["--profile", "loop"])

      assert_equal 0, code
      assert_equal "loop", env["data"]["ran"]
      assert_equal 0, env["data"]["tier"]
      assert_equal false, env["data"]["attested"]
    end
  end

  # The carve-out reason names the project's own path lists, so the sentence
  # a skipped commit is justified by is checkable against the same data the
  # predicate used.
  #
  # sabotage: hardcode the lib/, test/, config/ sentence back -> red
  def test_carve_out_reason_names_the_manifests_own_paths
    in_tmp_cwd do
      expect_no_elixir_diff
      expect_no_sabotage_diff

      _code, env = run_gate

      reason = env["data"]["carve_out_reason"]
      assert_match(/mix\.exs/, reason)
      assert_match(%r{\.claude/scripts/}, reason)
    end
  end

  # sabotage: hardcode "docs/quality-gate-changes.md" back into gate.rb -> red
  def test_ledger_path_comes_from_the_manifest
    other = manifest_with("gate_tier1", "gate" => { "guard_ledger" => "docs/gate-ledger.md" })

    Manifest.reset!
    with_manifest(other) do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          expect_no_elixir_diff
          expect_no_sabotage_diff

          _code, env = run_gate

          assert_equal "docs/gate-ledger.md", env["data"]["gate_guard"]["ledger_path"]
        end
      end
    end
  end

  def test_profile_other_than_loop_is_a_usage_error_not_an_envelope
    err = capture_io_stderr { assert_raises(SystemExit) { Gate.run(["--profile", "merge"]) } }
    assert_match(/profile must be 'loop'/, err)
  end

  def test_skip_flag_is_a_usage_error_not_an_envelope
    err = capture_io_stderr { assert_raises(SystemExit) { Gate.run(["--skip", "dialyzer"]) } }
    assert_match(/invalid option/, err)
  end

  def test_quick_flag_is_a_usage_error_not_an_envelope
    err = capture_io_stderr { assert_raises(SystemExit) { Gate.run(["--quick"]) } }
    assert_match(/invalid option/, err)
  end

  def capture_io_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  # sabotage: GatePaths.gate_applicable? delegating to PATTERNS instead of
  # GATE_PATTERNS -> red (the branch carves out and the gate never runs)
  def test_scripts_only_change_is_gate_applicable_and_runs_the_gate
    in_tmp_cwd do
      expect_scripts_only_diff
      expect_no_sabotage_diff
      @fake.expect(%w[make report], out: JSON.generate(GREEN_REPORT))
      @fake.expect(%w[make attest], out: "Full gate green: scope all, no profile, 2 stages considered.\n")

      code, env = run_gate

      assert_equal 0, code
      assert_equal true, env["data"]["applicable"]
      assert_nil env["data"]["carve_out_reason"]
      assert_equal "all", env["data"]["ran"]
    end
  end

  # sabotage: drop %r{\A\.claude/skills/} from GATED_NON_ELIXIR_PATTERNS ->
  # red (the branch carves out and the gate never runs, even though the ADR
  # judge's statifier-ex ADR-0015 scope reads exactly this file)
  def test_skills_only_change_is_gate_applicable_and_runs_the_gate
    in_tmp_cwd do
      expect_skills_only_diff
      expect_no_sabotage_diff
      @fake.expect(%w[make report], out: JSON.generate(GREEN_REPORT))
      @fake.expect(%w[make attest], out: "Full gate green: scope all, no profile, 2 stages considered.\n")

      code, env = run_gate

      assert_equal 0, code
      assert_equal true, env["data"]["applicable"]
      assert_nil env["data"]["carve_out_reason"]
      assert_equal "all", env["data"]["ran"]
    end
  end

  # --- Carve-out predicate: matches /wurk:commit's Step 0 (L97-98) exactly ---

  # `any?` answers a question about the Elixir build and must NOT widen when
  # the gate grows a stage measuring something else - that is what
  # gate_applicable? is for. See lib/touches_elixir.rb.
  # sabotage: add %r{\A\.claude/scripts/} to PATTERNS -> red
  def test_touches_elixir_predicate_matches_commit_skill_wording
    with_manifest("gate_tier1") do
    matching = %w[
      lib/acme/interpreter.ex
      test/acme/interpreter_test.exs
      config/config.exs
      mix.exs
      mix.lock
    ]
    non_matching = %w[
      docs/plans/260806-zz-hzf-x.md
      changelog.d/zz-hzf.md
      .claude/scripts/gate.rb
      docs/adr/0011.md
      README.md
    ]

    matching.each { |path| assert GatePaths.touches_build?([path]), "expected #{path} to touch elixir" }
    non_matching.each { |path| refute GatePaths.touches_build?([path]), "expected #{path} not to touch elixir" }
    end
  end

  # sabotage: drop GATED_NON_ELIXIR_PATTERNS from GATE_PATTERNS -> red
  def test_gate_applicable_is_strictly_wider_than_touches_elixir
    with_manifest("gate_tier1") do
    # Everything that touches the build still applies.
    %w[lib/acme/interpreter.ex mix.exs].each do |path|
      assert GatePaths.gate_applicable?([path]), "expected #{path} to be gate-applicable"
    end

    # The Script tests stage measures these, so they no longer carve out -
    # even though they touch no Elixir at all.
    %w[.claude/scripts/gate.rb .claude/scripts/lib/refs.rb .claude/scripts/test/run.rb].each do |path|
      refute GatePaths.touches_build?([path]), "expected #{path} not to touch elixir"
      assert GatePaths.gate_applicable?([path]), "expected #{path} to be gate-applicable"
    end

    # sabotage: drop %r{\A\.claude/skills/} from GATED_NON_ELIXIR_PATTERNS ->
    # red (a SKILL.md would carve out instead of being gate-applicable, even
    # though the ADR judge's statifier-ex ADR-0015 scope reads exactly these files)
    #
    # The widening is on the whole `.claude/skills/` prefix, not narrowed to
    # SKILL.md the way the statifier-ex ADR-0015 registry scope is (adr_judge.ex's
    # `in_scope?/2` is the one that matches the suffix too) - a whole-prefix
    # regex here is strictly wider, which is the direction this carve-out is
    # allowed to move. So a non-SKILL.md file under `.claude/skills/` is
    # gate-applicable too, even though no stage judges it specifically.
    %w[
      .claude/skills/commit/SKILL.md
      .claude/skills/merge-request/SKILL.md
      .claude/skills/commit/reference.md
    ].each do |path|
      refute GatePaths.touches_build?([path]), "expected #{path} not to touch elixir"
      assert GatePaths.gate_applicable?([path]), "expected #{path} to be gate-applicable"
    end

    # A plain doc change outside `.claude/` still carves out - no stage
    # measures it.
    %w[docs/adr/0011.md README.md].each do |path|
      refute GatePaths.gate_applicable?([path]), "expected #{path} to carve out"
    end
    end
  end

  # --- Sabotage scan ---

  EXUNIT_TEST_RE = /\btest\s+"/.freeze

  # Builds a `file_reader:` seam for scan_sabotage from an in-memory map of
  # path => full file content, so these tests answer "is there a note in the
  # working-tree file" against fixture text instead of real files on disk.
  def sabotage_files(files)
    ->(path) { files[path] }
  end

  def test_sabotage_scan_flags_a_missing_note
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.exs b/test/acme/foo_test.exs
      --- a/test/acme/foo_test.exs
      +++ b/test/acme/foo_test.exs
      @@ -10,0 +11,2 @@
      +  test "does the thing" do
      +  end
    DIFF
    file = <<~EX
      defmodule Acme.FooTest do
        test "does the thing" do
        end
      end
    EX

    result = Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE,
                                        file_reader: sabotage_files("test/acme/foo_test.exs" => file))

    assert_equal 1, result[:missing].length
    assert_equal "test/acme/foo_test.exs", result[:missing].first[:file]
  end

  def test_sabotage_scan_accepts_a_real_mutation_note
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.exs b/test/acme/foo_test.exs
      --- a/test/acme/foo_test.exs
      +++ b/test/acme/foo_test.exs
      @@ -10,0 +11,3 @@
      +  # sabotage: enter_states/2 skips the initial child -> red
      +  test "does the thing" do
      +  end
    DIFF
    file = <<~EX
      defmodule Acme.FooTest do
        # sabotage: enter_states/2 skips the initial child -> red
        test "does the thing" do
        end
      end
    EX

    result = Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE,
                                        file_reader: sabotage_files("test/acme/foo_test.exs" => file))

    assert_empty result[:missing]
  end

  def test_sabotage_scan_accepts_an_n_a_exemption_note
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.exs b/test/acme/foo_test.exs
      --- a/test/acme/foo_test.exs
      +++ b/test/acme/foo_test.exs
      @@ -10,0 +11,3 @@
      +  # sabotage: n/a - generated corpus fixture
      +  test "does the thing" do
      +  end
    DIFF
    file = <<~EX
      defmodule Acme.FooTest do
        # sabotage: n/a - generated corpus fixture
        test "does the thing" do
        end
      end
    EX

    result = Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE,
                                        file_reader: sabotage_files("test/acme/foo_test.exs" => file))

    assert_empty result[:missing]
  end

  # sabotage: change `i -= 1` to `i -= 2` in sabotage_comment_block_above? ->
  # red
  def test_sabotage_scan_accepts_a_two_line_wrapped_note
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.exs b/test/acme/foo_test.exs
      --- a/test/acme/foo_test.exs
      +++ b/test/acme/foo_test.exs
      @@ -10,0 +11,4 @@
      +  # sabotage: enter_states/2 skips the initial child
      +  # -> red
      +  test "does the thing" do
      +  end
    DIFF
    file = <<~EX
      defmodule Acme.FooTest do
        # sabotage: enter_states/2 skips the initial child
        # -> red
        test "does the thing" do
        end
      end
    EX

    result = Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE,
                                        file_reader: sabotage_files("test/acme/foo_test.exs" => file))

    assert_empty result[:missing]
  end

  # sabotage: change COMMENT_LINE_RE from /\A\s*#/ to /\A\s*##/ -> red
  def test_sabotage_scan_accepts_a_three_line_wrapped_note
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.exs b/test/acme/foo_test.exs
      --- a/test/acme/foo_test.exs
      +++ b/test/acme/foo_test.exs
      @@ -10,0 +11,5 @@
      +  # sabotage: enter_states/2 skips the initial
      +  # child when the parent is compound and the
      +  # default transition is absent -> red
      +  test "does the thing" do
      +  end
    DIFF
    file = <<~EX
      defmodule Acme.FooTest do
        # sabotage: enter_states/2 skips the initial
        # child when the parent is compound and the
        # default transition is absent -> red
        test "does the thing" do
        end
      end
    EX

    result = Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE,
                                        file_reader: sabotage_files("test/acme/foo_test.exs" => file))

    assert_empty result[:missing]
  end

  # sabotage: change COMMENT_LINE_RE from /\A\s*#/ to /\A\s*#?/ so the blank
  # line matches too and the walk keeps going past it -> red
  def test_sabotage_scan_flags_a_blank_line_between_note_and_test
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.exs b/test/acme/foo_test.exs
      --- a/test/acme/foo_test.exs
      +++ b/test/acme/foo_test.exs
      @@ -10,0 +11,4 @@
      +  # sabotage: enter_states/2 skips the initial child -> red
      +
      +  test "does the thing" do
      +  end
    DIFF
    file = <<~EX
      defmodule Acme.FooTest do
        # sabotage: enter_states/2 skips the initial child -> red

        test "does the thing" do
        end
      end
    EX

    result = Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE,
                                        file_reader: sabotage_files("test/acme/foo_test.exs" => file))

    assert_equal 1, result[:missing].length
    assert_equal "test/acme/foo_test.exs", result[:missing].first[:file]
  end

  # sabotage: change the early-return condition in
  # sabotage_comment_block_above? from `file_lines[i] =~ SABOTAGE_NOTE_RE` to
  # `file_lines[i] =~ COMMENT_LINE_RE` (any comment counts as a note) -> red
  def test_sabotage_scan_flags_a_comment_block_with_no_sabotage_note
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.exs b/test/acme/foo_test.exs
      --- a/test/acme/foo_test.exs
      +++ b/test/acme/foo_test.exs
      @@ -10,0 +11,4 @@
      +  # this test covers the happy path
      +  # nothing more to say here
      +  test "does the thing" do
      +  end
    DIFF
    file = <<~EX
      defmodule Acme.FooTest do
        # this test covers the happy path
        # nothing more to say here
        test "does the thing" do
        end
      end
    EX

    result = Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE,
                                        file_reader: sabotage_files("test/acme/foo_test.exs" => file))

    assert_equal 1, result[:missing].length
    assert_equal "test/acme/foo_test.exs", result[:missing].first[:file]
  end

  # Regression for wu-lac, failure shape 1: the note and the test
  # declaration are both edited, but an untouched line between them (the
  # blank line here) puts them in separate `-U0` hunks. The old
  # diff-only check discarded the note's hunk before ever reading the test
  # line; the fix reads the working-tree file instead, where both lines sit
  # three lines apart regardless of which hunk either fell in. Modeled on
  # the real diff quoted in the bead.
  # sabotage: drop the file_reader lookup and fall back to answering from
  # the diff's added lines only -> red (the note's hunk is discarded before
  # the test line is read, and this reports a false sabotage_note_missing)
  def test_sabotage_scan_accepts_a_note_split_across_hunks_by_an_unchanged_line
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.exs b/test/acme/foo_test.exs
      --- a/test/acme/foo_test.exs
      +++ b/test/acme/foo_test.exs
      @@ -277,2 +281,2 @@
      -  # sabotage: a fourth field is added to the payload -> red
      +  # sabotage: a fifth field is added to the payload -> red
      @@ -280 +284 @@
      -  test "AC7: old description" do
      +  test "AC7: new description" do
    DIFF
    file = <<~EX
      defmodule Acme.FooTest do
        # sabotage: a fifth field is added to the payload -> red
        #
        test "AC7: new description" do
        end
      end
    EX

    result = Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE,
                                        file_reader: sabotage_files("test/acme/foo_test.exs" => file))

    assert_empty result[:missing]
  end

  # Regression for wu-lac, failure shape 2: the note is not edited at all,
  # only the test declaration above it is - so the note never appears in a
  # `-U0` diff in the first place, in any hunk. Only the file has it.
  # sabotage: drop the file_reader lookup and fall back to answering from
  # the diff's added lines only -> red (an unchanged note never appears in a
  # -U0 diff, so this reports a false sabotage_note_missing)
  def test_sabotage_scan_accepts_a_note_left_entirely_unchanged
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.exs b/test/acme/foo_test.exs
      --- a/test/acme/foo_test.exs
      +++ b/test/acme/foo_test.exs
      @@ -11 +11 @@
      -  test "old description" do
      +  test "new description" do
    DIFF
    file = <<~EX
      defmodule Acme.FooTest do
        # sabotage: enter_states/2 skips the initial child -> red
        test "new description" do
        end
      end
    EX

    result = Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE,
                                        file_reader: sabotage_files("test/acme/foo_test.exs" => file))

    assert_empty result[:missing]
  end

  # A genuinely note-less test still reports missing when it is EDITED, not
  # just when it is newly added - the fix must not turn "checks the file"
  # into "never flags an edited test".
  def test_sabotage_scan_flags_an_edited_test_with_no_note_at_all
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.exs b/test/acme/foo_test.exs
      --- a/test/acme/foo_test.exs
      +++ b/test/acme/foo_test.exs
      @@ -11 +11 @@
      -  test "old description" do
      +  test "new description" do
    DIFF
    file = <<~EX
      defmodule Acme.FooTest do
        test "new description" do
        end
      end
    EX

    result = Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE,
                                        file_reader: sabotage_files("test/acme/foo_test.exs" => file))

    assert_equal 1, result[:missing].length
    assert_equal "test/acme/foo_test.exs", result[:missing].first[:file]
  end

  # Degenerate case: the file was deleted (or is otherwise unreadable) since
  # the diff was taken. There is nothing to verify a note against, so this
  # is treated as "can't verify", not "missing" - and it must not crash the
  # gate. It is no longer silent either: it surfaces as an unverifiable
  # entry with reason file_unreadable.
  # sabotage: treat a nil file_reader result as "file has no note" instead
  # of "can't verify" -> red (a deleted file would flag every candidate line
  # still sitting in the stale diff)
  def test_sabotage_scan_skips_a_file_missing_from_the_working_tree
    diff = <<~DIFF
      diff --git a/test/acme/gone_test.exs b/test/acme/gone_test.exs
      --- a/test/acme/gone_test.exs
      +++ b/test/acme/gone_test.exs
      @@ -10,0 +11,2 @@
      +  test "does the thing" do
      +  end
    DIFF

    result = Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE,
                                        file_reader: sabotage_files({}))

    assert_empty result[:missing]
    assert_equal 1, result[:unverifiable].length
    assert_equal "file_unreadable", result[:unverifiable].first[:reason]
    assert_equal "test/acme/gone_test.exs", result[:unverifiable].first[:file]
  end

  # A declaration this scan cannot locate in the working-tree file at all
  # (renamed again since the diff was taken, for example) is not a missing
  # note - wu-lac's call - but it is no longer silent: it surfaces as an
  # unverifiable entry with reason declaration_not_found.
  # sabotage: fold :not_found into :noted in sabotage_note_status -> red
  # (this candidate line, absent from the file body, would report neither
  # missing nor unverifiable)
  def test_sabotage_scan_reports_an_unlocatable_declaration
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.exs b/test/acme/foo_test.exs
      --- a/test/acme/foo_test.exs
      +++ b/test/acme/foo_test.exs
      @@ -10,0 +11,2 @@
      +  test "does the renamed thing" do
      +  end
    DIFF
    file = <<~EX
      defmodule Acme.FooTest do
        test "does the thing, renamed since the diff" do
        end
      end
    EX

    result = Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE,
                                        file_reader: sabotage_files("test/acme/foo_test.exs" => file))

    assert_empty result[:missing]
    assert_equal 1, result[:unverifiable].length
    assert_equal "declaration_not_found", result[:unverifiable].first[:reason]
    assert_equal "test/acme/foo_test.exs", result[:unverifiable].first[:file]
  end

  # Degenerate case: the candidate line's exact text appears more than once
  # in the file. scan_sabotage cannot tell which occurrence the diff meant,
  # so it accepts if any occurrence is noted - the charitable reading, and
  # the same bar the old within-hunk check applied.
  def test_sabotage_scan_accepts_if_any_duplicate_occurrence_is_noted
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.exs b/test/acme/foo_test.exs
      --- a/test/acme/foo_test.exs
      +++ b/test/acme/foo_test.exs
      @@ -10,0 +11,2 @@
      +  test "does the thing" do
      +  end
    DIFF
    file = <<~EX
      defmodule Acme.FooTest do
        test "does the thing" do
        end
      end

      defmodule Acme.FooTest.Nested do
        # sabotage: enter_states/2 skips the initial child -> red
        test "does the thing" do
        end
      end
    EX

    result = Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE,
                                        file_reader: sabotage_files("test/acme/foo_test.exs" => file))

    assert_empty result[:missing]
  end

  # sabotage: drop exempt_prefixes filtering from scan_sabotage -> red (both
  # corpus dirs would flag, proving the prefixes are honored from data)
  def test_sabotage_scan_ignores_scion_and_scxml_test_dirs
    diff = <<~DIFF
      diff --git a/test/scion_tests/foo_test.exs b/test/scion_tests/foo_test.exs
      --- a/test/scion_tests/foo_test.exs
      +++ b/test/scion_tests/foo_test.exs
      @@ -0,0 +1,2 @@
      +  test "generated corpus case" do
      +  end
      diff --git a/test/scxml_tests/bar_test.exs b/test/scxml_tests/bar_test.exs
      --- a/test/scxml_tests/bar_test.exs
      +++ b/test/scxml_tests/bar_test.exs
      @@ -0,0 +1,2 @@
      +  test "another generated corpus case" do
      +  end
    DIFF

    assert_empty Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE, exempt_prefixes: %w[test/scion_tests/ test/scxml_tests/])[:missing]
  end

  # sabotage: hardcode /\btest\s+"/ back into scan_sabotage instead of
  # threading test_re -> red (a Python/Ruby-shaped "def test_" line would be
  # missed and this test's flagged declaration would go empty)
  def test_sabotage_scan_pattern_is_data_driven
    python_test_re = /\bdef test_/.freeze
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.py b/test/acme/foo_test.py
      --- a/test/acme/foo_test.py
      +++ b/test/acme/foo_test.py
      @@ -0,0 +1,2 @@
      +  def test_does_the_thing():
      +      pass
    DIFF
    file = "  def test_does_the_thing():\n      pass\n"
    reader = sabotage_files("test/acme/foo_test.py" => file)

    result = Gate.scan_sabotage(diff, test_re: python_test_re, file_reader: reader)
    assert_equal 1, result[:missing].length

    # The ExUnit pattern does not match this Python-shaped declaration at all.
    assert_empty Gate.scan_sabotage(diff, test_re: EXUNIT_TEST_RE, file_reader: reader)[:missing]
  end

  def test_sabotage_scan_runs_over_the_committed_diff_pathspec
    in_tmp_cwd do
      expect_no_elixir_diff
      @fake.expect(
        %w[git diff main...HEAD -U0 -- test/ :!test/scion_tests/ :!test/scxml_tests/],
        out: "diff --git a/test/foo_test.exs b/test/foo_test.exs\n" \
             "--- a/test/foo_test.exs\n+++ b/test/foo_test.exs\n@@ -0,0 +1,1 @@\n" \
             "+  test \"missing its note\" do\n"
      )
      # scan_sabotage's default file_reader reads the real working-tree
      # file, so the fixture needs one on disk with no note above the
      # candidate line - this is what proves the e2e wiring, not just the
      # unit-level file_reader seam, reaches the working tree.
      FileUtils.mkdir_p("test")
      File.write("test/foo_test.exs", "  test \"missing its note\" do\nend\n")

      _code, env = run_gate

      assert_equal true, env["data"]["sabotage"]["enabled"]
      assert_equal 1, env["data"]["sabotage"]["missing"].length
      assert_equal 1, env["warnings"].length
      assert_equal "sabotage_note_missing", env["warnings"].first["code"]
      # A warning never blocks and never flips ok, even though applicable
      # is false here (the carve-out and the sabotage scan are independent).
      assert_equal true, env["ok"]
    end
  end

  # End-to-end: an unlocatable declaration reaches the envelope's
  # `unverifiable` channel and its own warning code, without ever touching
  # `ok`.
  # sabotage: drop the `unverifiable: scan[:unverifiable]` key from
  # env.data[:sabotage] in gate.rb's run -> red (the envelope key would be
  # missing entirely)
  def test_sabotage_scan_reports_unverifiable_through_the_envelope
    in_tmp_cwd do
      expect_no_elixir_diff
      @fake.expect(
        %w[git diff main...HEAD -U0 -- test/ :!test/scion_tests/ :!test/scxml_tests/],
        out: "diff --git a/test/foo_test.exs b/test/foo_test.exs\n" \
             "--- a/test/foo_test.exs\n+++ b/test/foo_test.exs\n@@ -0,0 +1,1 @@\n" \
             "+  test \"renamed since the diff\" do\n"
      )
      # No file on disk carries this exact candidate text, so the working
      # tree cannot locate it - the unverifiable path, not the missing path.
      FileUtils.mkdir_p("test")
      File.write("test/foo_test.exs", "  test \"already renamed\" do\nend\n")

      _code, env = run_gate

      assert_equal true, env["data"]["sabotage"]["enabled"]
      assert_equal [], env["data"]["sabotage"]["missing"]
      assert_equal 1, env["data"]["sabotage"]["unverifiable"].length
      assert_equal "declaration_not_found", env["data"]["sabotage"]["unverifiable"].first["reason"]
      assert_equal "sabotage_unverifiable", env["warnings"].first["code"]
      assert_equal true, env["ok"]
    end
  end

  # sabotage: keep the sabotage git-diff call even when the manifest has no
  # gate.sabotage section -> red (FakeSh would raise UnexpectedCommand)
  def test_sabotage_scan_is_off_when_the_manifest_declares_no_section
    in_tmp_cwd(fixture: "gate_tier0") do
      expect_elixir_diff
      @fake.expect(%w[make check], out: "fine\n")

      _code, env = run_gate

      assert_equal false, env["data"]["sabotage"]["enabled"]
      refute_nil env["data"]["sabotage"]["reason"]
      assert_equal [], env["data"]["sabotage"]["missing"]
      assert_equal [], env["warnings"]
      assert_equal true, env["ok"]
      # No `git diff main...HEAD -U0 -- ...` call was ever registered above,
      # so if the script tried to shell out for the sabotage scan, FakeSh
      # would raise FakeSh::UnexpectedCommand and this test would fail loudly.
    end
  end

  # --- Gate guard: reported, never repaired ---

  def test_gate_guard_reports_ledger_state_with_no_write_attempted
    report = {
      "status" => "error",
      "scope" => "all",
      "stages" => [
        {
          "name" => "Gate guard",
          "status" => "error",
          "summary" => "1 unjustified gate change",
          "findings" => [
            { "file" => ".quality.exs", "line" => nil, "message" => "changed with no ledger entry" }
          ]
        }
      ]
    }

    in_tmp_cwd(ledger_present: true) do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[make report], out: JSON.generate(report))
      @fake.expect(%w[make attest], exitstatus: 1, err: "not a full gate\n")

      _code, env = run_gate

      gate_guard = env["data"]["gate_guard"]
      assert_equal true, gate_guard["ledger_exists"]
      assert_equal "docs/quality-gate-changes.md", gate_guard["ledger_path"]
      assert_equal "error", gate_guard["stage"]["status"]
      assert_equal 1, gate_guard["stage"]["findings"].length
    end
  end

  def test_gate_guard_ledger_missing_is_reported_not_created
    in_tmp_cwd(ledger_present: false) do
      expect_no_elixir_diff
      expect_no_sabotage_diff

      _code, env = run_gate

      assert_equal false, env["data"]["gate_guard"]["ledger_exists"]
      refute File.exist?("docs/quality-gate-changes.md")
    end
  end
end

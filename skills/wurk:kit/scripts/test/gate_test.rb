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
      %w[git diff main...HEAD -U0 -- test/ :!test/scion_tests :!test/scxml_tests],
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

  # A skip the gate hit *on this run* blocks: it was asked to measure
  # something and could not. See gate.rb rule 1.
  # sabotage: make PROJECT_LEVEL_SKIP_RE match /./ -> red
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
      assert_equal false, env["data"]["skipped_stages"].first["project_level"]
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
        { "name" => "Gettext", "status" => "skipped", "summary" => ":gettext not installed" },
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
      # Reported, not laundered: all three still surface, and each carries a
      # warning a caller has to actively ignore.
      assert_equal 3, env["data"]["skipped_stages"].length
      assert(env["data"]["skipped_stages"].all? { |s| s["project_level"] })
      codes = env["warnings"].map { |w| w["code"] }
      assert_equal 3, codes.count("stage_skipped_project_level")
    end
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
    re = fixture_manifest("gate_tier1").project_level_skip_re

    refute Gate.project_level_skip?("some new reason nobody anticipated", re)
    refute Gate.project_level_skip?(nil, re)
    refute Gate.project_level_skip?("", re)
    assert Gate.project_level_skip?(":doctor not installed", re)
    assert Gate.project_level_skip?("disabled in .quality.exs", re)
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
          assert_equal false, env["data"]["skipped_stages"].first["project_level"]
        end
      end
    end
  end

  # The mirror of the above: with the field declared (gate_tier1's fixture
  # value), the same summary is project-level and does not block. Proves the
  # field is actually read, not that the strictness is unconditional.
  # sabotage: make project_level_skip? ignore project_level_re entirely -> red
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
      assert_equal true, env["data"]["skipped_stages"].first["project_level"]
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
      expect_no_sabotage_diff
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
      expect_no_sabotage_diff
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
      expect_no_sabotage_diff
      @fake.expect(%w[make check], out: "fine\n")

      _code, env = run_gate

      assert_equal false, env["data"]["attested"]
      assert_match(/no gate\.attest command/, env["data"]["attestation_message"])
    end
  end

  def test_tier_0_loop_run_uses_gate_loop
    in_tmp_cwd(fixture: "gate_tier0") do
      expect_elixir_diff
      expect_no_sabotage_diff
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

  # --- Carve-out predicate: matches /commit's Step 0 (L97-98) exactly ---

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

  def test_sabotage_scan_flags_a_missing_note
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.exs b/test/acme/foo_test.exs
      --- a/test/acme/foo_test.exs
      +++ b/test/acme/foo_test.exs
      @@ -10,0 +11,2 @@
      +  test "does the thing" do
      +  end
    DIFF

    missing = Gate.scan_sabotage(diff)

    assert_equal 1, missing.length
    assert_equal "test/acme/foo_test.exs", missing.first[:file]
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

    assert_empty Gate.scan_sabotage(diff)
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

    assert_empty Gate.scan_sabotage(diff)
  end

  # sabotage: change `idx -= 1` to `idx -= 2` in sabotage_note_above? -> red
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

    assert_empty Gate.scan_sabotage(diff)
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

    assert_empty Gate.scan_sabotage(diff)
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

    missing = Gate.scan_sabotage(diff)

    assert_equal 1, missing.length
    assert_equal "test/acme/foo_test.exs", missing.first[:file]
  end

  # sabotage: change the early-return condition in sabotage_note_above? from
  # `added_lines[idx] =~ SABOTAGE_NOTE_RE` to `added_lines[idx] =~
  # COMMENT_LINE_RE` (any comment counts as a note) -> red
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

    missing = Gate.scan_sabotage(diff)

    assert_equal 1, missing.length
    assert_equal "test/acme/foo_test.exs", missing.first[:file]
  end

  # sabotage: drop `added_lines = []` from the `@@` hunk-boundary branch in
  # scan_sabotage -> red
  def test_sabotage_scan_flags_a_note_separated_by_a_hunk_boundary
    diff = <<~DIFF
      diff --git a/test/acme/foo_test.exs b/test/acme/foo_test.exs
      --- a/test/acme/foo_test.exs
      +++ b/test/acme/foo_test.exs
      @@ -5,0 +6,1 @@
      +  # sabotage: enter_states/2 skips the initial child -> red
      @@ -10,0 +12,2 @@
      +  test "does the thing" do
      +  end
    DIFF

    missing = Gate.scan_sabotage(diff)

    assert_equal 1, missing.length
    assert_equal "test/acme/foo_test.exs", missing.first[:file]
  end

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

    assert_empty Gate.scan_sabotage(diff)
  end

  def test_sabotage_scan_runs_over_the_committed_diff_pathspec
    in_tmp_cwd do
      expect_no_elixir_diff
      @fake.expect(
        %w[git diff main...HEAD -U0 -- test/ :!test/scion_tests :!test/scxml_tests],
        out: "diff --git a/test/foo_test.exs b/test/foo_test.exs\n" \
             "--- a/test/foo_test.exs\n+++ b/test/foo_test.exs\n@@ -0,0 +1,1 @@\n" \
             "+  test \"missing its note\" do\n"
      )

      _code, env = run_gate

      assert_equal 1, env["data"]["sabotage"]["missing"].length
      assert_equal 1, env["warnings"].length
      assert_equal "sabotage_note_missing", env["warnings"].first["code"]
      # A warning never blocks and never flips ok, even though applicable
      # is false here (the carve-out and the sabotage scan are independent).
      assert_equal true, env["ok"]
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

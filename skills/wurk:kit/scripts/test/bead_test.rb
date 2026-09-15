# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../lib/beads"
require_relative "../bead"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"
require_relative "support/user_config_helper"

# Beads (lib/beads.rb): the pure logic - notes-blob splitting, the --loop
# grammar, --label-any union, and candidate ranking. No Sh involved.
class BeadsLibTest < Minitest::Test
  # --- unwrap_show ------------------------------------------------------

  def test_unwrap_show_takes_first_element_of_one_element_array
    assert_equal({ "id" => "zz-abc" }, Beads.unwrap_show([{ "id" => "zz-abc" }]))
  end

  def test_unwrap_show_nil_for_empty_array
    assert_nil Beads.unwrap_show([])
  end

  def test_unwrap_show_nil_for_non_array
    assert_nil Beads.unwrap_show({ "id" => "zz-abc" })
  end

  # --- parse_notes / the --loop grammar ----------------------------------

  def test_parse_notes_empty_blob_is_empty_list
    assert_equal [], Beads.parse_notes(nil)
    assert_equal [], Beads.parse_notes("")
    assert_equal [], Beads.parse_notes("   \n")
  end

  def test_parse_notes_the_real_st_hzf_notes_blob
    blob = "Motivation: mechanics are slow.\n" \
           "Research doc: docs/research/x.md\n" \
           "Plan doc: docs/plans/x.md (12 phases)\n" \
           "loop: Phase 1 complete, commit a2aa5a9\n" \
           "loop: Phase 2 complete, commit 10b6589"

    entries = Beads.parse_notes(blob)

    assert_equal 3, entries.length
    assert_equal "Motivation: mechanics are slow.\nResearch doc: docs/research/x.md\n" \
                 "Plan doc: docs/plans/x.md (12 phases)", entries[0]["text"]
    assert_nil entries[0]["loop"]

    assert_equal({ "status" => "complete", "phase" => 1, "commit" => "a2aa5a9" }, entries[1]["loop"])
    assert_equal({ "status" => "complete", "phase" => 2, "commit" => "10b6589" }, entries[2]["loop"])
  end

  def test_parse_notes_loop_complete_grammar
    entries = Beads.parse_notes("loop: Phase 3 complete, commit deadbee")

    assert_equal 1, entries.length
    assert_equal({ "status" => "complete", "phase" => 3, "commit" => "deadbee" }, entries[0]["loop"])
  end

  def test_parse_notes_loop_stopped_grammar
    entries = Beads.parse_notes("loop stopped at Phase 4: dialyzer red on unrelated file")

    assert_equal 1, entries.length
    assert_equal(
      { "status" => "stopped", "phase" => 4, "reason" => "dialyzer red on unrelated file" },
      entries[0]["loop"]
    )
  end

  def test_parse_notes_loop_stopped_with_multi_line_reason
    blob = "loop stopped at Phase 4: dialyzer red on unrelated file\n" \
           "see lib/foo.ex:12, looks pre-existing\n" \
           "leaving it for a human to triage"

    entries = Beads.parse_notes(blob)

    assert_equal 1, entries.length
    assert_equal "stopped", entries[0]["loop"]["status"]
    assert_equal 4, entries[0]["loop"]["phase"]
    assert_equal "dialyzer red on unrelated file\nsee lib/foo.ex:12, looks pre-existing\n" \
                 "leaving it for a human to triage", entries[0]["loop"]["reason"]
  end

  def test_parse_notes_a_loop_line_always_starts_a_new_entry_even_after_free_text
    blob = "some free text note\nmore of it\nloop: Phase 1 complete, commit abc1234"

    entries = Beads.parse_notes(blob)

    assert_equal 2, entries.length
    assert_equal "some free text note\nmore of it", entries[0]["text"]
    assert_equal({ "status" => "complete", "phase" => 1, "commit" => "abc1234" }, entries[1]["loop"])
  end

  def test_parse_notes_round_trips_both_loop_shapes_back_to_back
    blob = "loop: Phase 1 complete, commit abc1234\nloop stopped at Phase 2: red gate"

    entries = Beads.parse_notes(blob)

    assert_equal 2, entries.length
    assert_equal "complete", entries[0]["loop"]["status"]
    assert_equal "stopped", entries[1]["loop"]["status"]
    assert_equal "red gate", entries[1]["loop"]["reason"]
  end

  # --- union_by_id (--label-any workaround) -------------------------------

  def test_union_by_id_dedupes_across_arrays_and_sorts
    a = [{ "id" => "zz-b", "title" => "B" }, { "id" => "zz-a", "title" => "A" }]
    b = [{ "id" => "zz-a", "title" => "A (dup)" }, { "id" => "zz-c", "title" => "C" }]

    result = Beads.union_by_id([a, b])

    assert_equal %w[zz-a zz-b zz-c], result.map { |i| i["id"] }
    # first occurrence wins
    assert_equal "A", result.find { |i| i["id"] == "zz-a" }["title"]
  end

  def test_union_by_id_empty_input_is_empty
    assert_equal [], Beads.union_by_id([])
    assert_equal [], Beads.union_by_id(nil)
  end

  # --- rank_candidates (bead.rb resolve) ----------------------------------

  def test_rank_candidates_picks_first_eligible_in_priority_order
    candidates = [
      { id: "zz-seed", strategy: "seeded_prompt", confidence: "strong", status: "open" },
      { id: "zz-plan", strategy: "plan_doc", confidence: "strong", status: "open" }
    ]

    ranked = Beads.rank_candidates(candidates)

    assert_equal({ id: "zz-seed", strategy: "seeded_prompt", confidence: "strong" }, ranked[:resolved])
    assert_equal 1, ranked[:candidates].length
    assert_equal "zz-plan", ranked[:candidates].first[:id]
    assert_nil ranked[:candidates].first[:warning]
  end

  def test_rank_candidates_without_seeded_bead_prefers_plan_doc_over_branch_prefix
    candidates = [
      { id: "zz-plan", strategy: "plan_doc", confidence: "strong", status: "open" },
      { id: "zz-branch", strategy: "branch_prefix", confidence: "weak", status: "open" }
    ]

    ranked = Beads.rank_candidates(candidates)

    assert_equal "plan_doc", ranked[:resolved][:strategy]
    assert_equal "zz-branch", ranked[:candidates].first[:id]
  end

  def test_rank_candidates_closed_bead_is_never_resolved_and_carries_a_warning
    candidates = [
      { id: "zz-xyz", strategy: "branch_prefix", confidence: "weak", status: "closed" }
    ]

    ranked = Beads.rank_candidates(candidates)

    assert_nil ranked[:resolved]
    assert_equal 1, ranked[:candidates].length
    assert_equal "stale branch name - the branch predates the bead id", ranked[:candidates].first[:warning]
  end

  def test_rank_candidates_skips_closed_candidate_and_resolves_the_next_eligible_one
    candidates = [
      { id: "zz-plan", strategy: "plan_doc", confidence: "strong", status: "closed" },
      { id: "zz-branch", strategy: "branch_prefix", confidence: "weak", status: "open" }
    ]

    ranked = Beads.rank_candidates(candidates)

    assert_equal "zz-branch", ranked[:resolved][:id]
    assert_equal 1, ranked[:candidates].length
    assert_equal "zz-plan", ranked[:candidates].first[:id]
    refute_nil ranked[:candidates].first[:warning]
  end

  def test_rank_candidates_not_found_candidate_carries_a_warning_not_a_crash
    candidates = [{ id: "zz-ghost", strategy: "branch_prefix", confidence: "weak", status: nil }]

    ranked = Beads.rank_candidates(candidates)

    assert_nil ranked[:resolved]
    assert_equal "bead zz-ghost not found", ranked[:candidates].first[:warning]
  end

  def test_rank_candidates_empty_input_resolves_nothing
    ranked = Beads.rank_candidates([])

    assert_nil ranked[:resolved]
    assert_equal [], ranked[:candidates]
  end
end

# Bead (bead.rb): the CLI subcommands, driven end to end through FakeSh.
class BeadCliTest < Minitest::Test
  include ManifestHelper
  include UserConfigHelper

  # Bead id resolution (the plan-doc filename scan and the branch-prefix
  # scan) is built from the manifest's `beads.prefix`, so the fixture's "zz"
  # drives every id below.
  FIXTURE = "valid"

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
    # Every sync push test below runs through the outbound-scan gate now
    # (Phase 5), which reads UserConfig.current. Default every test to the
    # disarmed instance so none of them depends on this machine's real
    # ~/.claude/wurk.local.json; a test that needs the scan armed installs
    # its own fixture with with_user_config, which restores this default
    # afterward.
    UserConfig.current = UserConfig.new(path: "(fixture)", raw: {}, exists: false)
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
    UserConfig.reset!
  end

  # Runs under the `valid` fixture unless the test has already installed a
  # manifest with with_manifest (the sync tests do, to run a verb under
  # `local` or under a `titles` refusal set) - that one is kept.
  def run_bead(argv)
    io = StringIO.new
    code = nil
    installed = Manifest.instance_variable_get(:@current)
    with_manifest(installed || FIXTURE) { code = Bead.run(argv, io: io) }
    [code, JSON.parse(io.string)]
  end

  # Stubs the base-ref ladder's remote-first rung as a hit, so BaseRef.resolve
  # picks `ref` (default "origin/main") without falling back or warning.
  def expect_base_ref(ref: "origin/main")
    @fake.expect(["git", "rev-parse", "--verify", "--quiet", ref], exitstatus: 0)
  end

  # --- show --------------------------------------------------------------

  def test_show_unwraps_array_and_splits_notes_into_a_list
    @fake.expect(
      %w[bd show zz-hzf --json],
      out: JSON.generate([{
        "id" => "zz-hzf", "title" => "T", "description" => "D",
        "acceptance_criteria" => "AC", "notes" => "loop: Phase 1 complete, commit abc1234",
        "status" => "in_progress", "priority" => 2, "issue_type" => "chore",
        "assignee" => "JohnnyT", "labels" => ["area:skills"],
        "dependent_count" => 0, "dependency_count" => 0
      }])
    )

    code, env = run_bead(%w[show zz-hzf])

    assert_equal 0, code
    assert env["ok"]
    assert_kind_of Array, env["data"]["notes"]
    assert_equal 1, env["data"]["notes"].length
    assert_equal "complete", env["data"]["notes"].first["loop"]["status"]
    assert_equal [], env["warnings"]
  end

  def test_show_missing_field_degrades_to_null_with_a_warning_not_a_crash
    @fake.expect(
      %w[bd show zz-hzf --json],
      out: JSON.generate([{ "id" => "zz-hzf", "notes" => "" }])
    )

    code, env = run_bead(%w[show zz-hzf])

    assert_equal 0, code
    assert_nil env["data"]["title"]
    assert env["warnings"].any? { |w| w["code"] == "missing_field" }
  end

  def test_show_not_found_blocks
    @fake.expect(%w[bd show zz-zzz --json], out: "[]\n")

    code, env = run_bead(%w[show zz-zzz])

    assert_equal 1, code
    refute env["ok"]
    assert_equal "not_found", env["blocked"].first["code"]
  end

  # --- ready / --label-any -----------------------------------------------

  def test_ready_passes_filters_through_verbatim
    @fake.expect(%w[bd ready --json --priority 1], out: "[]\n")

    code, env = run_bead(%w[ready --priority 1])

    assert_equal 0, code
    assert_equal [], env["data"]["issues"]
  end

  def test_ready_label_any_unions_per_label_results_beads_5358_workaround
    @fake.expect(
      %w[bd ready --json --label area:skills],
      out: JSON.generate([{ "id" => "zz-qww" }])
    )
    @fake.expect(
      %w[bd ready --json --label area:build],
      out: JSON.generate([{ "id" => "zz-yea" }, { "id" => "zz-qww" }])
    )

    code, env = run_bead(%w[ready --label-any area:skills,area:build])

    assert_equal 0, code
    assert_equal %w[zz-qww zz-yea], env["data"]["issues"].map { |i| i["id"] }.sort
    assert_equal 2, env["data"]["count"]
  end

  def test_ready_claim_flag_passes_through_as_the_atomic_claim_path
    @fake.expect(%w[bd ready --json --claim], out: "[]\n")

    code, env = run_bead(%w[ready --claim])

    assert_equal 0, code
    assert env["ok"]
  end

  def test_ready_bd_failure_blocks
    @fake.expect(%w[bd ready --json], exitstatus: 1, err: "boom\n")

    code, env = run_bead(%w[ready])

    assert_equal 1, code
    assert_equal "bd_ready_failed", env["blocked"].first["code"]
  end

  # --- claim ---------------------------------------------------------------

  def test_claim_runs_bd_update_claim
    @fake.expect(%w[bd update zz-abc --claim --json], out: JSON.generate([{ "id" => "zz-abc" }]))

    code, env = run_bead(%w[claim zz-abc])

    assert_equal 0, code
    assert_equal true, env["data"]["claimed"]
  end

  def test_claim_dry_run_does_not_shell_out
    code, env = run_bead(%w[claim zz-abc --dry-run])

    assert_equal 0, code
    assert_nil env["data"]["claimed"]
    assert_equal 1, env["commands"].length
  end

  # --- note -----------------------------------------------------------------

  def test_note_uses_bd_note_append_semantics_never_bd_edit
    today = Time.now.strftime("%Y-%m-%d")
    expect_show_notes("zz-abc", "old note")
    @fake.expect(["bd", "note", "zz-abc", "#{today}: hello world"], out: "ok\n")
    expect_show_notes("zz-abc", "old note\n#{today}: hello world")

    code, env = run_bead(["note", "zz-abc", "hello", "world"])

    assert_equal 0, code
    assert_equal true, env["data"]["noted"]
    assert_equal true, env["data"]["prior_preserved"]
  end

  def test_note_keeps_a_text_that_already_leads_with_a_date
    expect_show_notes("zz-abc", "")
    @fake.expect(["bd", "note", "zz-abc", "2026-08-22: dated already"], out: "ok\n")
    expect_show_notes("zz-abc", "2026-08-22: dated already")

    code, env = run_bead(["note", "zz-abc", "2026-08-22:", "dated", "already"])

    assert_equal 0, code
    assert_equal true, env["data"]["prior_preserved"]
  end

  def test_note_blocks_when_the_prior_text_did_not_survive
    expect_show_notes("zz-abc", "precious precondition note")
    @fake.expect(["bd", "note", "zz-abc"], out: "ok\n")
    expect_show_notes("zz-abc", "#{Time.now.strftime('%Y-%m-%d')}: hello")

    code, env = run_bead(%w[note zz-abc hello])

    assert_equal 1, code
    assert_equal false, env["data"]["prior_preserved"]
    assert env["blocked"].any? { |b| b["code"] == "prior_notes_lost" }
  end

  def test_note_blocks_when_the_new_text_is_not_visible_after_the_append
    expect_show_notes("zz-abc", "old note")
    @fake.expect(["bd", "note", "zz-abc"], out: "ok\n")
    expect_show_notes("zz-abc", "old note")

    code, env = run_bead(%w[note zz-abc hello])

    assert_equal 1, code
    assert env["blocked"].any? { |b| b["code"] == "note_not_visible" }
  end

  def test_note_warns_instead_of_blocking_when_the_pre_read_fails
    @fake.expect(["bd", "show", "zz-abc", "--json"], exitstatus: 1, err: "boom\n")
    @fake.expect(["bd", "note", "zz-abc"], out: "ok\n")
    expect_show_notes("zz-abc", "#{Time.now.strftime('%Y-%m-%d')}: hello")

    code, env = run_bead(%w[note zz-abc hello])

    assert_equal 0, code
    assert_equal true, env["data"]["noted"]
    assert_nil env["data"]["prior_preserved"]
    assert env["warnings"].any? { |w| w["code"] == "append_unverified" }
  end

  def test_note_dry_run_still_pre_reads_but_writes_nothing
    expect_show_notes("zz-abc", "old note")

    code, env = run_bead(%w[note zz-abc hello --dry-run])

    assert_equal 0, code
    assert_nil env["data"]["noted"]
    assert_nil env["data"]["prior_preserved"]
    assert_equal 2, env["commands"].length
    assert_includes env["commands"].last, "bd note"
  end

  def expect_show_notes(id, notes)
    @fake.expect(["bd", "show", id, "--json"],
                 out: JSON.generate([{ "id" => id, "notes" => notes }]))
  end

  # --- link ------------------------------------------------------------------

  def test_link_defaults_to_blocks_type
    @fake.expect(%w[bd link zz-a zz-b --type blocks], out: "ok\n")

    code, env = run_bead(%w[link zz-a zz-b])

    assert_equal 0, code
    assert_equal "blocks", env["data"]["type"]
  end

  def test_link_accepts_explicit_type
    @fake.expect(%w[bd link zz-a zz-b --type related], out: "ok\n")

    code, env = run_bead(%w[link zz-a zz-b --type related])

    assert_equal 0, code
    assert_equal "related", env["data"]["type"]
  end

  # --- label -----------------------------------------------------------------

  def test_label_add
    @fake.expect(%w[bd label add zz-abc area:skills], out: "ok\n")

    code, env = run_bead(%w[label add zz-abc area:skills])

    assert_equal 0, code
    assert_equal true, env["data"]["applied"]
  end

  # --- create ------------------------------------------------------------------

  def test_create_forwards_flags_and_returns_the_new_id
    @fake.expect(
      ["bd", "create", "New thing", "--json", "--type", "chore", "--priority", "2"],
      out: JSON.generate([{ "id" => "zz-new" }])
    )

    code, env = run_bead(["create", "New thing", "--type", "chore", "--priority", "2"])

    assert_equal 0, code
    assert_equal "zz-new", env["data"]["id"]
  end

  # --- sync ------------------------------------------------------------------

  def test_sync_pull_success
    @fake.expect(%w[bd dolt pull], out: "ok\n")

    code, env = run_bead(%w[sync pull])

    assert_equal 0, code
    assert env["ok"]
    assert_equal true, env["data"]["succeeded"]
  end

  def test_sync_pull_reports_no_confirmed_field
    @fake.expect(%w[bd dolt pull], out: "")

    code, env = run_bead(%w[sync pull])

    assert_equal 0, code
    refute env["data"].key?("confirmed")
  end

  def test_sync_rejects_an_unknown_verb_with_usage
    err = capture_stderr do
      exc = assert_raises(SystemExit) { Bead.run(%w[sync fetch], io: StringIO.new) }
      assert_equal 2, exc.status
    end

    assert_includes err, "pull|scan|push"
  end

  # --- sync scan / sync push: the gated tracker push (wu-b4i, ADR-0014) --------
  #
  # Every test below runs inside a scratch git common dir (a tmpdir the fake
  # `git rev-parse --git-common-dir` answers with) so the marker never lands
  # in this checkout's .git. `bd list --all --json` and `bd dolt push` are
  # faked; nothing here reads a real tracker or touches a network.

  CLEAN_EXPORT = [{ "id" => "zz-abc", "title" => "nothing guarded here", "description" => "plain" }].freeze

  def with_common_dir
    Dir.mktmpdir do |dir|
      @common_dir = dir
      yield dir
    end
  ensure
    @common_dir = nil
  end

  def expect_common_dir
    @fake.expect(%w[git rev-parse --path-format=absolute --git-common-dir], out: "#{@common_dir}\n")
  end

  def expect_tracker_export(issues = CLEAN_EXPORT)
    @fake.expect(%w[bd list --all --json], out: JSON.generate(issues))
  end

  def marker_path
    TrackerScan.marker_path(@common_dir)
  end

  def armed_config(patterns_path, control_term)
    { "outbound_scan" => { "patterns_file" => patterns_path, "control_term" => control_term } }
  end

  def write_patterns(dir, content)
    path = File.join(dir, "patterns.txt")
    File.write(path, content)
    path
  end

  # A scan followed by a push, each with its own export read: the sequence
  # every caller runs, packaged so the push tests do not restate the scan.
  def scan_clean!(issues = CLEAN_EXPORT, argv: %w[sync scan])
    expect_common_dir
    expect_tracker_export(issues)
    code, env = run_bead(argv)
    assert_equal 0, code, "scan expected clean: #{env['blocked'].inspect}"
    env
  end

  def dolt_push_called?
    @fake.calls.any? { |c| c.argv == %w[bd dolt push] }
  end

  # --- the scan verb ---

  def test_sync_scan_clean_export_writes_a_marker_with_the_fingerprint
    with_common_dir do
      env = scan_clean!

      assert_equal true, env["data"]["marker_written"]
      assert_equal true, env["data"]["clean"]
      assert_equal "all", env["data"]["refusal"]
      assert_equal 1, env["data"]["issues"]
      assert File.file?(marker_path)

      marker = JSON.parse(File.read(marker_path))
      assert_equal TrackerScan::MARKER_VERSION, marker["version"]
      assert_equal TrackerScan.fingerprint(JSON.generate(CLEAN_EXPORT)), marker["fingerprint"]
      assert_equal env["data"]["fingerprint"], marker["fingerprint"]
      assert_equal "all", marker["refusal"]
      assert_equal false, marker["armed"]
      assert_equal [], marker["informational"]
      refute dolt_push_called?
    end
  end

  def test_sync_scan_disarmed_warns_but_still_marks_clean
    with_common_dir do
      env = scan_clean!

      # No outbound_scan section is configured (see setup): the scan ran
      # over nothing and says so, and the push verb re-warns from the marker.
      assert_equal ["outbound_scan_disarmed"], env["warnings"].map { |w| w["code"] }
      assert_equal false, env["data"]["outbound_scan"]["armed"]
    end
  end

  def test_sync_scan_never_shells_dolt_push
    with_common_dir do
      scan_clean!
      refute dolt_push_called?
      assert_equal %w[git bd], @fake.calls.map { |c| c.argv.first }
    end
  end

  def test_sync_scan_dry_run_scans_for_real_and_withholds_only_the_marker
    with_common_dir do
      env = scan_clean!(argv: %w[sync scan --dry-run])

      assert_nil env["data"]["marker_written"]
      assert_equal true, env["data"]["clean"]
      assert_equal env["data"]["fingerprint"], TrackerScan.fingerprint(JSON.generate(CLEAN_EXPORT))
      assert_includes env["commands"].join("\n"), marker_path
      refute File.exist?(marker_path)
    end
  end

  def test_sync_scan_under_local_reads_nothing_and_reports_skipped
    with_manifest(manifest_with("valid", "beads" => { "sync" => "local" })) do
      code, env = run_bead(%w[sync scan])

      assert_equal 0, code
      assert env["ok"]
      assert_equal "tracker_local_only", env["data"]["skipped"]
      assert_equal "local", env["data"]["beads_sync"]
      assert_equal true, env["data"]["beads_sync_declared"]
      assert_equal false, env["data"]["marker_written"]
      assert_equal [], env["warnings"]
    end

    assert_empty @fake.calls
  end

  def test_sync_scan_armed_and_clean_writes_an_armed_marker
    with_common_dir do
      Dir.mktmpdir do |dir|
        path = write_patterns(dir, "zqiblorf-control-1\nzqiblorf-secret")

        with_user_config(armed_config(path, "zqiblorf-control-1")) do
          env = scan_clean!

          assert_equal true, env["data"]["outbound_scan"]["armed"]
          assert_equal true, env["data"]["outbound_scan"]["probe_ok"]
          assert_empty env["data"]["outbound_scan"]["hits"]
          assert_equal [], env["warnings"]
          assert_equal true, JSON.parse(File.read(marker_path))["armed"]
        end
      end
    end
  end

  def test_sync_scan_a_title_hit_blocks_and_writes_no_marker_under_all
    with_common_dir do
      Dir.mktmpdir do |dir|
        token = "zqiblorf-secret-fixture-1"
        path = write_patterns(dir, "zqiblorf-control-1\n#{token}")
        expect_common_dir
        expect_tracker_export([{ "id" => "zz-abc", "title" => "leading #{token} trailing" }])

        with_user_config(armed_config(path, "zqiblorf-control-1")) do
          code, env = run_bead(%w[sync scan])

          assert_equal 1, code
          refute env["ok"]
          assert_equal ["outbound_scan_hit"], env["blocked"].map { |b| b["code"] }
          assert_equal false, env["data"]["clean"]
          assert_equal false, env["data"]["marker_written"]
          assert_equal [{ "id" => "zz-abc", "count" => 1, "fields" => ["title"] }], env["data"]["refusing_hits"]
          assert_equal [], env["data"]["informational_hits"]
        end

        refute File.exist?(marker_path)
      end
    end
  end

  def test_sync_scan_a_description_hit_blocks_under_all
    with_common_dir do
      Dir.mktmpdir do |dir|
        token = "zqiblorf-secret-fixture-1"
        path = write_patterns(dir, "zqiblorf-control-1\n#{token}")
        expect_common_dir
        expect_tracker_export([{ "id" => "zz-abc", "title" => "clean", "description" => "leading #{token} trailing" }])

        with_user_config(armed_config(path, "zqiblorf-control-1")) do
          code, env = run_bead(%w[sync scan])

          assert_equal 1, code
          assert_equal ["outbound_scan_hit"], env["blocked"].map { |b| b["code"] }
          assert_equal [{ "id" => "zz-abc", "count" => 1, "fields" => ["description"] }], env["data"]["refusing_hits"]
        end
      end
    end
  end

  def test_sync_scan_under_titles_reports_description_hits_per_bead_and_stays_clean
    with_common_dir do
      Dir.mktmpdir do |dir|
        token = "zqiblorf-secret-fixture-1"
        path = write_patterns(dir, "zqiblorf-control-1\n#{token}")
        issues = [
          { "id" => "zz-abc", "title" => "clean", "description" => "#{token} and #{token}", "notes" => "#{token}" },
          { "id" => "zz-aaa", "title" => "also clean", "notes" => "one #{token}" },
          { "id" => "zz-zzz", "title" => "untouched" }
        ]
        expect_common_dir
        expect_tracker_export(issues)

        with_manifest(manifest_with("valid", "beads" => { "scan_refusal" => "titles" })) do
          with_user_config(armed_config(path, "zqiblorf-control-1")) do
            code, env = run_bead(%w[sync scan])

            assert_equal 0, code, env["blocked"].inspect
            assert env["ok"]
            assert_equal "titles", env["data"]["refusal"]
            assert_equal true, env["data"]["clean"]
            assert_equal [], env["data"]["refusing_hits"]
            # Attributed per issue id, sorted, with field NAMES only.
            assert_equal(
              [
                { "id" => "zz-aaa", "count" => 1, "fields" => ["notes"] },
                { "id" => "zz-abc", "count" => 3, "fields" => %w[description notes] }
              ],
              env["data"]["informational_hits"]
            )
            assert_equal ["outbound_scan_informational"], env["warnings"].map { |w| w["code"] }
            assert_includes env["warnings"].first["message"], "4 outbound scan hit(s) in 2 issue(s)"
            assert_equal true, env["data"]["marker_written"]

            marker = JSON.parse(File.read(marker_path))
            assert_equal "titles", marker["refusal"]
            assert_equal env["data"]["informational_hits"], marker["informational"]

            serialized = env.to_json + File.read(marker_path)
            refute_includes serialized, token
            refute_includes serialized, "zqiblorf-control-1"
          end
        end
      end
    end
  end

  def test_sync_scan_under_titles_a_title_hit_still_refuses
    with_common_dir do
      Dir.mktmpdir do |dir|
        token = "zqiblorf-secret-fixture-1"
        path = write_patterns(dir, "zqiblorf-control-1\n#{token}")
        expect_common_dir
        expect_tracker_export([{ "id" => "zz-abc", "title" => "#{token} in the title", "description" => token }])

        with_manifest(manifest_with("valid", "beads" => { "scan_refusal" => "titles" })) do
          with_user_config(armed_config(path, "zqiblorf-control-1")) do
            code, env = run_bead(%w[sync scan])

            assert_equal 1, code
            assert_equal ["outbound_scan_hit"], env["blocked"].map { |b| b["code"] }
            assert_equal [{ "id" => "zz-abc", "count" => 1, "fields" => ["title"] }], env["data"]["refusing_hits"]
            assert_equal [{ "id" => "zz-abc", "count" => 1, "fields" => ["description"] }], env["data"]["informational_hits"]
            assert_equal false, env["data"]["marker_written"]
          end
        end

        refute File.exist?(marker_path)
      end
    end
  end

  def test_sync_scan_a_broken_probe_refuses_and_writes_no_marker
    with_common_dir do
      Dir.mktmpdir do |dir|
        path = write_patterns(dir, "zqiblorf-secret-only")
        expect_common_dir
        expect_tracker_export

        with_user_config(armed_config(path, "zqiblorf-control-that-no-pattern-matches")) do
          code, env = run_bead(%w[sync scan])

          assert_equal 1, code
          assert_equal ["scan_pipeline_broken"], env["blocked"].map { |b| b["code"] }
          assert_equal false, env["data"]["marker_written"]
        end

        refute File.exist?(marker_path)
      end
    end
  end

  def test_sync_scan_failing_tracker_export_blocks
    with_common_dir do
      expect_common_dir
      @fake.expect(%w[bd list --all --json], exitstatus: 1, err: "bd: no such database\n")

      code, env = run_bead(%w[sync scan])

      assert_equal 1, code
      assert_equal ["tracker_export_unavailable"], env["blocked"].map { |b| b["code"] }
      refute File.exist?(marker_path)
    end
  end

  def test_sync_scan_empty_output_is_no_export
    with_common_dir do
      expect_common_dir
      @fake.expect(%w[bd list --all --json], out: "")

      code, env = run_bead(%w[sync scan])

      assert_equal 1, code
      assert_equal ["tracker_export_unavailable"], env["blocked"].map { |b| b["code"] }
    end
  end

  def test_sync_scan_an_empty_tracker_warns_and_marks
    with_common_dir do
      env = scan_clean!([])

      assert_includes env["warnings"].map { |w| w["code"] }, "tracker_export_empty"
      assert_equal 0, env["data"]["issues"]
      assert_equal true, env["data"]["marker_written"]
    end
  end

  def test_sync_scan_a_stale_marker_is_replaced_by_a_clean_scan
    with_common_dir do
      FileUtils.mkdir_p(File.dirname(marker_path))
      File.write(marker_path, "not a marker")

      scan_clean!

      assert_equal TrackerScan::MARKER_VERSION, JSON.parse(File.read(marker_path))["version"]
    end
  end

  # --- the push verb ---

  def test_sync_push_with_a_fresh_marker_pushes_and_confirms
    with_common_dir do
      scan_clean!
      expect_common_dir
      expect_tracker_export
      @fake.expect(%w[bd dolt push], out: "Push complete.\n")

      code, env = run_bead(%w[sync push])

      assert_equal 0, code
      assert env["ok"]
      assert_equal "fresh", env["data"]["marker_state"]
      assert_equal true, env["data"]["pushed"]
      assert_equal true, env["data"]["succeeded"]
      assert_equal true, env["data"]["confirmed"]
      assert_equal [], env["data"]["informational_hits"]
      # The disarmed warning travels from the marker: the push itself
      # never scanned, and says so the same way the scan did.
      assert_equal ["outbound_scan_disarmed"], env["warnings"].map { |w| w["code"] }
    end
  end

  def test_sync_push_without_a_marker_refuses_and_never_shells_dolt_push
    with_common_dir do
      expect_common_dir
      expect_tracker_export
      # deliberately no "bd dolt push" expectation: if bead.rb shells it
      # anyway, FakeSh raises UnexpectedCommand and this fails loudly.

      code, env = run_bead(%w[sync push])

      assert_equal 1, code
      refute env["ok"]
      assert_equal ["scan_marker_missing"], env["blocked"].map { |b| b["code"] }
      assert_includes env["blocked"].first["message"], "bead.rb sync scan"
      assert_equal "missing", env["data"]["marker_state"]
      assert_equal false, env["data"]["pushed"]
      assert_nil env["data"]["succeeded"]
      refute dolt_push_called?
    end
  end

  def test_sync_push_never_scans
    with_common_dir do
      Dir.mktmpdir do |dir|
        token = "zqiblorf-secret-fixture-1"
        path = write_patterns(dir, "zqiblorf-control-1\n#{token}")
        expect_common_dir
        expect_tracker_export([{ "id" => "zz-abc", "title" => token }])

        with_user_config(armed_config(path, "zqiblorf-control-1")) do
          code, env = run_bead(%w[sync push])

          # A push with no marker refuses for the MISSING MARKER, not for
          # the hit it would have found had it scanned - it did not scan.
          assert_equal 1, code
          assert_equal ["scan_marker_missing"], env["blocked"].map { |b| b["code"] }
          refute env["data"].key?("outbound_scan")
        end
      end
    end
  end

  def test_sync_push_refuses_when_the_tracker_changed_since_the_scan
    with_common_dir do
      scan_clean!
      expect_common_dir
      expect_tracker_export(CLEAN_EXPORT + [{ "id" => "zz-new", "title" => "filed after the scan" }])

      code, env = run_bead(%w[sync push])

      assert_equal 1, code
      assert_equal ["scan_marker_stale"], env["blocked"].map { |b| b["code"] }
      assert_equal "stale", env["data"]["marker_state"]
      refute dolt_push_called?
    end
  end

  def test_sync_push_refuses_when_the_refusal_set_changed_since_the_scan
    with_common_dir do
      scan_clean!
      expect_common_dir
      expect_tracker_export

      with_manifest(manifest_with("valid", "beads" => { "scan_refusal" => "titles" })) do
        code, env = run_bead(%w[sync push])

        assert_equal 1, code
        assert_equal ["scan_marker_stale"], env["blocked"].map { |b| b["code"] }
      end

      refute dolt_push_called?
    end
  end

  def test_sync_push_refuses_an_expired_marker
    with_common_dir do
      scan_clean!
      marker = JSON.parse(File.read(marker_path))
      marker["scanned_at"] = (Time.now.utc - TrackerScan::MARKER_TTL_SECONDS - 1).iso8601
      File.write(marker_path, JSON.generate(marker))
      expect_common_dir
      expect_tracker_export

      code, env = run_bead(%w[sync push])

      assert_equal 1, code
      assert_equal ["scan_marker_expired"], env["blocked"].map { |b| b["code"] }
      assert_operator env["data"]["marker_age_seconds"], :>, TrackerScan::MARKER_TTL_SECONDS
      refute dolt_push_called?
    end
  end

  def test_sync_push_refuses_a_marker_it_did_not_write
    with_common_dir do
      FileUtils.mkdir_p(File.dirname(marker_path))
      File.write(marker_path, JSON.generate("version" => 99, "scanned_at" => Time.now.utc.iso8601))
      expect_common_dir
      expect_tracker_export

      code, env = run_bead(%w[sync push])

      assert_equal 1, code
      assert_equal ["scan_marker_unreadable"], env["blocked"].map { |b| b["code"] }
      refute dolt_push_called?
    end
  end

  def test_sync_push_carries_the_scan_informational_hits_into_its_own_result
    with_common_dir do
      Dir.mktmpdir do |dir|
        token = "zqiblorf-secret-fixture-1"
        path = write_patterns(dir, "zqiblorf-control-1\n#{token}")
        issues = [{ "id" => "zz-abc", "title" => "clean", "description" => token }]

        with_manifest(manifest_with("valid", "beads" => { "scan_refusal" => "titles" })) do
          with_user_config(armed_config(path, "zqiblorf-control-1")) do
            scan_clean!(issues)
          end

          expect_common_dir
          expect_tracker_export(issues)
          @fake.expect(%w[bd dolt push], out: "Push complete.\n")
          code, env = run_bead(%w[sync push])

          assert_equal 0, code
          assert_equal true, env["data"]["confirmed"]
          assert_equal [{ "id" => "zz-abc", "count" => 1, "fields" => ["description"] }], env["data"]["informational_hits"]
          assert_equal [], env["warnings"]
          refute_includes env.to_json, token
        end
      end
    end
  end

  def test_sync_push_failure_is_a_warning_never_a_block
    with_common_dir do
      scan_clean!
      expect_common_dir
      expect_tracker_export
      @fake.expect(%w[bd dolt push], exitstatus: 1, err: "no remote\n")

      code, env = run_bead(%w[sync push])

      assert_equal 0, code
      assert env["ok"]
      assert_equal [], env["blocked"]
      assert_equal true, env["data"]["pushed"]
      assert_equal false, env["data"]["succeeded"]
      assert_equal false, env["data"]["confirmed"]
      assert env["warnings"].any? { |w| w["code"] == "dolt_push_failed" }
    end
  end

  def test_sync_push_silent_success_reruns_and_confirms_on_retry
    with_common_dir do
      scan_clean!
      expect_common_dir
      expect_tracker_export
      @fake.expect(%w[bd dolt push], out: "")
      @fake.expect(%w[bd dolt push], out: "Push complete.\n")

      code, env = run_bead(%w[sync push])

      assert_equal 0, code
      assert_equal true, env["data"]["succeeded"]
      assert_equal true, env["data"]["confirmed"]
    end
  end

  def test_sync_push_silent_twice_warns_unconfirmed
    with_common_dir do
      scan_clean!
      expect_common_dir
      expect_tracker_export
      @fake.expect(%w[bd dolt push], out: "")
      @fake.expect(%w[bd dolt push], out: "")

      code, env = run_bead(%w[sync push])

      assert_equal 0, code
      assert_equal true, env["data"]["succeeded"]
      assert_equal false, env["data"]["confirmed"]
      assert env["warnings"].any? { |w| w["code"] == "dolt_push_unconfirmed" }
    end
  end

  def test_sync_push_failing_tracker_export_blocks_and_never_shells_dolt_push
    with_common_dir do
      scan_clean!
      expect_common_dir
      @fake.expect(%w[bd list --all --json], exitstatus: 1, err: "bd: no such database\n")

      code, env = run_bead(%w[sync push])

      assert_equal 1, code
      assert_equal ["tracker_export_unavailable"], env["blocked"].map { |b| b["code"] }
      assert_equal false, env["data"]["pushed"]
      refute dolt_push_called?
    end
  end

  def test_sync_push_unparseable_tracker_export_blocks
    with_common_dir do
      expect_common_dir
      @fake.expect(%w[bd list --all --json], out: "not json at all")

      code, env = run_bead(%w[sync push])

      assert_equal 1, code
      assert_equal ["tracker_export_unavailable"], env["blocked"].map { |b| b["code"] }
      refute dolt_push_called?
    end
  end

  def test_sync_push_under_local_pushes_nothing_and_reports_skipped
    with_manifest(manifest_with("valid", "beads" => { "sync" => "local" })) do
      code, env = run_bead(%w[sync push])

      assert_equal 0, code
      assert env["ok"]
      assert_equal "tracker_local_only", env["data"]["skipped"]
      assert_equal false, env["data"]["pushed"]
      assert_equal [], env["warnings"]
    end

    assert_empty @fake.calls
  end

  def test_sync_push_under_a_defaulted_local_says_so
    with_manifest(manifest_with("valid", "beads" => { "sync" => nil })) do
      code, env = run_bead(%w[sync push])

      assert_equal 0, code
      assert_equal "tracker_local_only", env["data"]["skipped"]
      assert_equal false, env["data"]["beads_sync_declared"]
    end

    assert_empty @fake.calls
  end

  def test_sync_push_dry_run_reads_the_marker_and_shells_no_push
    with_common_dir do
      scan_clean!
      expect_common_dir
      expect_tracker_export

      code, env = run_bead(%w[sync push --dry-run])

      assert_equal 0, code
      assert_equal "fresh", env["data"]["marker_state"]
      assert_nil env["data"]["succeeded"]
      assert_nil env["data"]["confirmed"]
      assert_equal false, env["data"]["pushed"]
      assert_includes env["commands"].join("\n"), "bd dolt push"
      refute dolt_push_called?
    end
  end

  def test_sync_push_dry_run_still_refuses_without_a_marker
    with_common_dir do
      expect_common_dir
      expect_tracker_export

      code, env = run_bead(%w[sync push --dry-run])

      assert_equal 1, code
      assert_equal ["scan_marker_missing"], env["blocked"].map { |b| b["code"] }
      refute_includes env["commands"].join("\n"), "bd dolt push"
    end
  end

  def test_sync_push_a_fresh_marker_serves_more_than_one_push_of_the_same_export
    with_common_dir do
      scan_clean!
      2.times do
        expect_common_dir
        expect_tracker_export
        @fake.expect(%w[bd dolt push], out: "Push complete.\n")
        code, = run_bead(%w[sync push])
        assert_equal 0, code
      end
      assert File.file?(marker_path)
    end
  end

  # --- resolve ----------------------------------------------------------------

  def test_resolve_without_seeded_bead_prefers_plan_doc_over_branch_prefix
    expect_base_ref
    @fake.expect(%w[git diff --name-only origin/main...HEAD], out: "docs/plans/260806-zz-hzf-skill-mechanics-scripts.md\n")
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git branch --show-current], out: "zz-oth-some-other-branch\n")
    @fake.expect(%w[bd show zz-hzf --json], out: JSON.generate([{ "id" => "zz-hzf", "status" => "in_progress" }]))
    @fake.expect(%w[bd show zz-oth --json], out: JSON.generate([{ "id" => "zz-oth", "status" => "open" }]))

    code, env = run_bead(%w[resolve])

    assert_equal 0, code
    assert_equal "zz-hzf", env["data"]["resolved"]["id"]
    assert_equal "plan_doc", env["data"]["resolved"]["strategy"]
    assert(env["data"]["candidates"].any? { |c| c["id"] == "zz-oth" && c["strategy"] == "branch_prefix" })
  end

  def test_resolve_ranks_seeded_bead_first_when_given
    expect_base_ref
    @fake.expect(%w[git diff --name-only origin/main...HEAD], out: "docs/plans/260806-zz-hzf-skill-mechanics-scripts.md\n")
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git branch --show-current], out: "zz-oth-some-other-branch\n")
    @fake.expect(%w[bd show zz-seed --json], out: JSON.generate([{ "id" => "zz-seed", "status" => "open" }]))
    @fake.expect(%w[bd show zz-hzf --json], out: JSON.generate([{ "id" => "zz-hzf", "status" => "in_progress" }]))
    @fake.expect(%w[bd show zz-oth --json], out: JSON.generate([{ "id" => "zz-oth", "status" => "open" }]))

    code, env = run_bead(%w[resolve --seeded-bead zz-seed])

    assert_equal 0, code
    assert_equal "zz-seed", env["data"]["resolved"]["id"]
    assert_equal "seeded_prompt", env["data"]["resolved"]["strategy"]
    assert(env["data"]["candidates"].any? { |c| c["id"] == "zz-hzf" && c["strategy"] == "plan_doc" })
    assert(env["data"]["candidates"].any? { |c| c["id"] == "zz-oth" && c["strategy"] == "branch_prefix" })
  end

  def test_resolve_surfaces_closed_bead_as_a_warning_never_silently
    expect_base_ref
    @fake.expect(%w[git diff --name-only origin/main...HEAD], out: "\n")
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git branch --show-current], out: "zz-xyz-something\n")
    @fake.expect(%w[bd show zz-xyz --json], out: JSON.generate([{ "id" => "zz-xyz", "status" => "closed" }]))

    code, env = run_bead(%w[resolve])

    assert_equal 0, code
    assert_nil env["data"]["resolved"]
    assert_equal 1, env["data"]["candidates"].length
    assert_equal "stale branch name - the branch predates the bead id", env["data"]["candidates"].first["warning"]
    assert env["warnings"].any? { |w| w["code"] == "bead_unavailable" }
  end

  # sabotage: read a hardcoded "origin/main...HEAD" in resolve_plan_doc_bead
  # instead of BaseRef's manifest-derived base -> red (FakeSh::
  # UnexpectedCommand: no stub for "origin/main...HEAD" here, only
  # "origin/trunk...HEAD")
  def test_resolve_with_trunk_override_diffs_against_trunk
    other = manifest_with("valid", "repo" => { "default_branch" => "trunk" })

    expect_base_ref(ref: "origin/trunk")
    @fake.expect(%w[git diff --name-only origin/trunk...HEAD], out: "docs/plans/260806-zz-hzf-skill-mechanics-scripts.md\n")
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git branch --show-current], out: "zz-oth-some-other-branch\n")
    @fake.expect(%w[bd show zz-hzf --json], out: JSON.generate([{ "id" => "zz-hzf", "status" => "in_progress" }]))
    @fake.expect(%w[bd show zz-oth --json], out: JSON.generate([{ "id" => "zz-oth", "status" => "open" }]))

    io = StringIO.new
    code = nil
    with_manifest(other) { code = Bead.run(%w[resolve], io: io) }
    env = JSON.parse(io.string)

    assert_equal 0, code
    assert_equal "zz-hzf", env["data"]["resolved"]["id"]
    assert_equal "plan_doc", env["data"]["resolved"]["strategy"]
  end

  # sabotage: make resolve_plan_doc_bead scan only the committed diff
  # (drop BaseRef.changed_files' working-tree union) -> red
  # (FakeSh::UnexpectedCommand: no stub for "git status --porcelain"
  # returning the untracked plan path here, or resolved bead comes back nil)
  def test_resolve_finds_plan_doc_in_untracked_file_with_no_committed_diff
    expect_base_ref
    @fake.expect(%w[git diff --name-only origin/main...HEAD], out: "")
    @fake.expect(%w[git status --porcelain], out: "?? docs/plans/260814-zz-abc-untitled.md\n")
    @fake.expect(%w[git branch --show-current], out: "zz-oth-some-other-branch\n")
    @fake.expect(%w[bd show zz-abc --json], out: JSON.generate([{ "id" => "zz-abc", "status" => "in_progress" }]))
    @fake.expect(%w[bd show zz-oth --json], out: JSON.generate([{ "id" => "zz-oth", "status" => "open" }]))

    code, env = run_bead(%w[resolve])

    assert_equal 0, code
    assert_equal "zz-abc", env["data"]["resolved"]["id"]
    assert_equal "plan_doc", env["data"]["resolved"]["strategy"]
    assert_equal "strong", env["data"]["resolved"]["confidence"]
  end

  # --- no close subcommand ------------------------------------------------

  def test_close_is_not_a_reachable_subcommand
    io = StringIO.new
    err = capture_stderr do
      exc = assert_raises(SystemExit) { Bead.run(%w[close zz-abc], io: io) }
      assert_equal 2, exc.status
    end

    assert_empty io.string
    assert_match(/usage/, err)
  end

  private

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../lib/beads"
require_relative "../bead"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"

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

  # Bead id resolution (the plan-doc filename scan and the branch-prefix
  # scan) is built from the manifest's `beads.prefix`, so the fixture's "zz"
  # drives every id below.
  FIXTURE = "valid"

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
  end

  def run_bead(argv)
    io = StringIO.new
    code = nil
    with_manifest(FIXTURE) { code = Bead.run(argv, io: io) }
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
    @fake.expect(["bd", "note", "zz-abc", "hello world"], out: "ok\n")

    code, env = run_bead(["note", "zz-abc", "hello", "world"])

    assert_equal 0, code
    assert_equal true, env["data"]["noted"]
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

  def test_sync_push_failure_is_a_warning_never_a_block
    @fake.expect(%w[bd dolt push], exitstatus: 1, err: "no remote\n")

    code, env = run_bead(%w[sync push])

    assert_equal 0, code
    assert env["ok"]
    assert_equal [], env["blocked"]
    assert_equal false, env["data"]["succeeded"]
    assert env["warnings"].any? { |w| w["code"] == "dolt_push_failed" }
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

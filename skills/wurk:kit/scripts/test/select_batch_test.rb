# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../select_batch"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"

class SelectBatchTest < Minitest::Test
  include ManifestHelper

  # Selection reads two manifezz-derived things: the bead id shape (via
  # Refs) and the area vocabulary with its batching policy (via Areas). The
  # `areas_wide` fixture supplies both under names this repo does not use,
  # so a test naming "area:alpha" or "zz-" would have proved nothing.
  FIXTURE = "areas_wide"

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
  end

  def run_select(argv = [])
    io = StringIO.new
    code = nil
    with_manifest(FIXTURE) { code = SelectBatch.run(argv, io: io) }
    [code, JSON.parse(io.string)]
  end

  # No other worktrees: survey is one call and nothing else.
  def expect_empty_survey
    @fake.expect(
      %w[git worktree list --porcelain],
      out: "worktree /repos/myrepo\nHEAD aaaa\nbranch refs/heads/main\n"
    )
  end

  # One other worktree, for a branch/bead/areas/merged combination the
  # caller supplies.
  def expect_survey_with_worktree(branch:, bead_id:, labels:, merged:)
    porcelain = <<~TXT
      worktree /repos/myrepo
      HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      branch refs/heads/main

      worktree /repos/zz-worktrees/#{branch}
      HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      branch refs/heads/#{branch}
    TXT

    @fake.expect(%w[git worktree list --porcelain], out: porcelain)
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: merged ? 0 : 1)
    @fake.expect(["bd", "show", bead_id, "--json"], out: JSON.generate([{ "id" => bead_id, "labels" => labels }]))

    merged_json = merged ? %({"number":9,"mergedAt":"2026-08-05T00:00:00Z","headRefOid":"deadbeef"}\n) : "null\n"
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", branch,
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: merged_json
    )
  end

  def expect_ready(issues, filters: [])
    @fake.expect(["bd", "ready", "--json"] + filters, out: JSON.generate(issues))
  end

  # Auto mode claims at take (ADR-0012), so every auto test whose walk takes
  # a bead must authorize that bead's claim. Registering it per id rather
  # than as a blanket prefix keeps FakeSh's "unauthorized command" raise as
  # the check that the script claims exactly what it took and nothing else.
  def expect_claim(*ids, exitstatus: 0, err: "")
    ids.each do |id|
      @fake.expect(["bd", "update", id, "--claim"],
                   out: JSON.generate([{ "id" => id }]), err: err, exitstatus: exitstatus)
    end
  end

  def issue(id, priority:, labels:, issue_type: "chore", description: "Description for #{id}.")
    { "id" => id, "title" => "title for #{id}", "priority" => priority, "issue_type" => issue_type, "labels" => labels,
      "description" => description }
  end

  # --- verdict table cases -------------------------------------------------

  def test_area_build_takes_the_batch_alone
    expect_ready([
                   issue("zz-bld", priority: 1, labels: ["area:build"]),
                   issue("zz-int", priority: 2, labels: ["area:alpha"])
                 ])
    expect_empty_survey
    expect_claim("zz-bld")

    _code, env = run_select(["--auto"])

    assert_equal ["zz-bld"], env["data"]["recommended"]
    skipped = env["data"]["skipped"].find { |s| s["id"] == "zz-int" }
    assert_match(/area:build lands alone/, skipped["reason"])
  end

  def test_unlabeled_skipped_with_reason_string
    expect_ready([issue("zz-nol", priority: 1, labels: [])])
    expect_empty_survey

    _code, env = run_select(["--auto"])

    assert_equal [], env["data"]["recommended"]
    skipped = env["data"]["skipped"].find { |s| s["id"] == "zz-nol" }
    assert_equal "unlabeled - blast radius undecided", skipped["reason"]
    candidate = env["data"]["candidates"].find { |c| c["id"] == "zz-nol" }
    assert_equal "unlabeled", candidate["verdict"]
  end

  def test_upstream_bead_is_informational_and_never_recommended
    expect_ready([
                   issue("zz-up1", priority: 1, labels: ["upstream"]),
                   issue("zz-up2", priority: 2, labels: ["upstream"])
                 ])
    expect_empty_survey

    _code, env = run_select(["--auto"])

    assert_equal [], env["data"]["recommended"]
    env["data"]["candidates"].each { |c| assert_equal "upstream", c["verdict"] }
    up1 = env["data"]["skipped"].find { |s| s["id"] == "zz-up1" }
    up2 = env["data"]["skipped"].find { |s| s["id"] == "zz-up2" }
    assert_match(%r{/wurk:work zz-up1}, up1["reason"])
    assert_match(%r{/wurk:work zz-up2}, up2["reason"])
  end

  def test_upstream_wins_over_area_labels
    expect_ready([issue("zz-mix", priority: 1, labels: %w[upstream area:alpha])])
    expect_empty_survey

    _code, env = run_select(["--auto"])

    assert_equal [], env["data"]["recommended"]
    candidate = env["data"]["candidates"].find { |c| c["id"] == "zz-mix" }
    assert_equal "upstream", candidate["verdict"]
  end

  def test_upstream_beats_unlabeled_but_not_epic
    expect_ready([issue("zz-epi", priority: 1, labels: ["upstream"], issue_type: "epic")])
    expect_empty_survey

    _code, env = run_select(["--auto"])

    candidate = env["data"]["candidates"].find { |c| c["id"] == "zz-epi" }
    assert_equal "epic", candidate["verdict"]
  end

  def test_unreached_upstream_keeps_its_own_reason
    expect_ready([
                   issue("zz-fst", priority: 1, labels: ["area:alpha"]),
                   issue("zz-up", priority: 2, labels: ["upstream"])
                 ])
    expect_empty_survey
    expect_claim("zz-fst")

    _code, env = run_select(["--n", "1", "--auto"])

    assert_equal ["zz-fst"], env["data"]["recommended"]
    skipped = env["data"]["skipped"].find { |s| s["id"] == "zz-up" }
    assert_match(%r{/wurk:work zz-up}, skipped["reason"])
    refute_match(/ceiling/, skipped["reason"])
  end

  def test_upstream_label_is_manifest_driven
    manifest = manifest_with("areas_wide", "beads" => { "areas" => { "always_batchable" => [] } })
    expect_ready([issue("zz-up", priority: 1, labels: ["upstream"])])
    expect_empty_survey

    io = StringIO.new
    with_manifest(manifest) { SelectBatch.run(["--auto"], io: io) }
    env = JSON.parse(io.string)

    candidate = env["data"]["candidates"].find { |c| c["id"] == "zz-up" }
    assert_equal "unlabeled", candidate["verdict"]
  end

  def test_stale_worktree_areas_do_not_block
    expect_ready([issue("zz-new", priority: 1, labels: ["area:alpha"])])
    expect_survey_with_worktree(branch: "zz-old-thing", bead_id: "zz-old", labels: ["area:alpha"], merged: true)
    expect_claim("zz-new")

    _code, env = run_select(["--auto"])

    assert_equal ["zz-new"], env["data"]["recommended"]
    candidate = env["data"]["candidates"].find { |c| c["id"] == "zz-new" }
    assert_equal "free", candidate["verdict"]
  end

  # Regression fixture for the failure mode observed live 2026-08-05: a
  # merged-but-not-removed worktree for zz-o9a caused zz-d9g to be reported
  # as colliding with work that had already landed on main minutes earlier
  # (.claude/skills/next-issues/SKILL.md:150-157, worktree_survey.rb's
  # holds_areas comment).
  def test_2026_08_05_phantom_collision_regression
    expect_ready([issue("zz-d9g", priority: 1, labels: ["area:gamma"])])
    expect_survey_with_worktree(branch: "zz-o9a-corpus-thing", bead_id: "zz-o9a", labels: ["area:gamma"], merged: true)
    expect_claim("zz-d9g")

    _code, env = run_select(["--auto"])

    assert_equal ["zz-d9g"], env["data"]["recommended"]
    candidate = env["data"]["candidates"].find { |c| c["id"] == "zz-d9g" }
    refute_equal "collides-with-live-worktree", candidate["verdict"]
    assert_equal "free", candidate["verdict"]
  end

  def test_collides_with_live_non_stale_worktree_is_named_and_skipped_in_auto_mode
    expect_ready([issue("zz-new", priority: 1, labels: ["area:epsilon"])])
    expect_survey_with_worktree(branch: "zz-hzf-skill-mechanics-scripts", bead_id: "zz-hzf", labels: ["area:epsilon"], merged: false)

    _code, env = run_select(["--auto"])

    assert_equal [], env["data"]["recommended"]
    candidate = env["data"]["candidates"].find { |c| c["id"] == "zz-new" }
    assert_equal "collides-with-live-worktree", candidate["verdict"]
    assert_match(/area:epsilon/, candidate["reason"])
    skipped = env["data"]["skipped"].find { |s| s["id"] == "zz-new" }
    refute_nil skipped
  end

  def test_dependency_edge_not_batched_across_epic_row_absorbs_it
    expect_ready([
                   issue("zz-epic", priority: 1, labels: ["area:gamma"], issue_type: "epic"),
                   issue("zz-child", priority: 2, labels: ["area:gamma"])
                 ])
    expect_empty_survey
    expect_claim("zz-child")

    _code, env = run_select(["--auto"])

    assert_equal ["zz-child"], env["data"]["recommended"]
    skipped = env["data"]["skipped"].find { |s| s["id"] == "zz-epic" }
    assert_equal "epic - work its children", skipped["reason"]
  end

  # --- ceiling ---------------------------------------------------------------

  def test_n_greater_than_4_blocks_never_clamps
    _code, env = run_select(["--n", "5", "--auto"])

    assert_equal false, env["ok"]
    assert_equal "n_too_large", env["blocked"].first["code"]
    refute_equal [4], env["data"]["recommended"] # never silently substitutes 4 and proceeds
    assert_nil env["data"]["recommended"]
  end

  def test_ceiling_hit_false_when_the_pool_ran_out
    expect_ready([
                   issue("zz-a", priority: 1, labels: ["area:alpha"]),
                   issue("zz-b", priority: 2, labels: ["area:beta"])
                 ])
    expect_empty_survey
    expect_claim("zz-a", "zz-b")

    _code, env = run_select(["--n", "3", "--auto"])

    assert_equal %w[zz-a zz-b], env["data"]["recommended"]
    assert_equal false, env["data"]["ceiling_hit"]
  end

  def test_ceiling_hit_true_when_batch_full_before_pool_exhausted
    expect_ready([
                   issue("zz-a", priority: 1, labels: ["area:alpha"]),
                   issue("zz-b", priority: 2, labels: ["area:beta"]),
                   issue("zz-c", priority: 3, labels: ["area:delta"])
                 ])
    expect_empty_survey
    expect_claim("zz-a", "zz-b")

    _code, env = run_select(["--n", "2", "--auto"])

    assert_equal %w[zz-a zz-b], env["data"]["recommended"]
    assert_equal true, env["data"]["ceiling_hit"]
    skipped = env["data"]["skipped"].find { |s| s["id"] == "zz-c" }
    assert_match(/ceiling/, skipped["reason"])
  end

  # --- mode: manual vs auto ---------------------------------------------------

  def test_manual_mode_sets_requires_user_choice_and_offers_override
    expect_ready([issue("zz-new", priority: 1, labels: ["area:epsilon"])])
    expect_survey_with_worktree(branch: "zz-hzf-skill-mechanics-scripts", bead_id: "zz-hzf", labels: ["area:epsilon"], merged: false)

    _code, env = run_select([])

    assert_equal "manual", env["data"]["mode"]
    assert_equal true, env["data"]["requires_user_choice"]
    override = env["data"]["alternatives"].find { |a| a["type"] == "override" && a["id"] == "zz-new" }
    refute_nil override
  end

  def test_auto_mode_has_no_requires_user_choice_and_no_override_alternative
    expect_ready([issue("zz-new", priority: 1, labels: ["area:epsilon"])])
    expect_survey_with_worktree(branch: "zz-hzf-skill-mechanics-scripts", bead_id: "zz-hzf", labels: ["area:epsilon"], merged: false)

    _code, env = run_select(["--auto"])

    assert_equal "auto", env["data"]["mode"]
    refute env["data"].key?("requires_user_choice")
    assert_equal [], env["data"]["alternatives"]
  end

  # --- filter-sanity check -----------------------------------------------------

  def test_label_filter_that_changed_nothing_blocks_rather_than_silently_proceeding
    same_set = [issue("zz-a", priority: 1, labels: ["area:alpha"])]
    expect_ready(same_set, filters: ["-l", "area:epsilon"])
    expect_ready(same_set)

    _code, env = run_select(["-l", "area:epsilon"])

    assert_equal false, env["ok"]
    assert_equal "unverified_filter", env["blocked"].first["code"]
  end

  def test_label_filter_that_actually_filtered_proceeds_normally
    expect_ready([issue("zz-a", priority: 1, labels: ["area:epsilon"])], filters: ["-l", "area:epsilon"])
    expect_ready([
                   issue("zz-a", priority: 1, labels: ["area:epsilon"]),
                   issue("zz-b", priority: 2, labels: ["area:alpha"])
                 ])
    expect_empty_survey
    expect_claim("zz-a")

    _code, env = run_select(["-l", "area:epsilon", "--auto"])

    assert_equal true, env["ok"]
    assert_equal ["zz-a"], env["data"]["recommended"]
  end

  # --- ambiguous input ---------------------------------------------------------

  def test_mixing_explicit_ids_and_filters_is_refused
    _code, env = run_select(["zz-abc", "-l", "area:epsilon"])

    assert_equal false, env["ok"]
    assert_equal "ambiguous_input", env["blocked"].first["code"]
  end

  # --- summary field (zz-sdv) ---------------------------------------------

  # sabotage: dropped `summary: Summary.of(issue["description"])` from
  # annotate/2's returned hash -> red, candidate carries no "summary" key
  def test_every_candidate_carries_a_summary_derived_from_the_description_in_default_mode
    expect_ready([
                   issue("zz-a", priority: 1, labels: ["area:alpha"],
                                 description: "Fixes the interpreter's idle path. More detail follows."),
                   issue("zz-b", priority: 2, labels: ["area:beta"],
                                 description: "Extends the parser's guard clause. More detail follows.")
                 ])
    expect_empty_survey
    expect_claim("zz-a", "zz-b")

    _code, env = run_select(["--auto"])

    env["data"]["candidates"].each { |c| assert c.key?("summary") }
    a = env["data"]["candidates"].find { |c| c["id"] == "zz-a" }
    b = env["data"]["candidates"].find { |c| c["id"] == "zz-b" }
    assert_equal "Fixes the interpreter's idle path.", a["summary"]
    assert_equal "Extends the parser's guard clause.", b["summary"]
  end

  # Explicit-selection mode reads the description from `bd show` (a
  # different code path than `bd ready`, in explicit_candidates/2) - this
  # is the only test exercising that path for the summary field.
  # sabotage: `"summary" => c[:summary]` dropped from public_candidate/1
  # -> red, candidate carries no "summary" key even though annotate/2 set it
  def test_summary_present_in_explicit_selection_mode_too
    @fake.expect(
      %w[bd show zz-trm --json],
      out: JSON.generate([{
        "id" => "zz-trm", "title" => "title for zz-trm",
        "description" => "Extends the ADR guard to cover statifier-ex ADR-0015 in Ruby. More detail follows.",
        "labels" => ["area:epsilon"], "priority" => 2, "issue_type" => "chore"
      }])
    )
    expect_empty_survey
    expect_claim("zz-trm")

    _code, env = run_select(["zz-trm", "--auto"])

    candidate = env["data"]["candidates"].find { |c| c["id"] == "zz-trm" }
    assert_equal "Extends the ADR guard to cover statifier-ex ADR-0015 in Ruby.", candidate["summary"]
  end

  # sabotage: `Summary.of` body changed to always `return description`
  # (skip the blank check) -> red, expects nil but gets ""
  def test_candidate_with_empty_description_carries_summary_key_with_nil_value
    expect_ready([issue("zz-nod", priority: 1, labels: ["area:alpha"], description: "")])
    expect_empty_survey
    expect_claim("zz-nod")

    _code, env = run_select(["--auto"])

    candidate = env["data"]["candidates"].find { |c| c["id"] == "zz-nod" }
    assert candidate.key?("summary")
    assert_nil candidate["summary"]
  end

  # The zz-trm/zz-tgv motivating case from zz-sdv's own description: two
  # ready beads sharing an identical title, distinguishable only by
  # description.
  # sabotage: `issue["description"]` changed to `issue["title"]` in
  # annotate/2 -> red, both summaries collapse to the shared title's summary
  def test_identical_titles_with_different_descriptions_produce_different_summaries
    shared_title = "Extends the ADR guard"
    expect_ready([
                   { "id" => "zz-trm", "title" => shared_title, "priority" => 1, "issue_type" => "chore",
                     "labels" => ["area:alpha"],
                     "description" => "Extends the ADR guard to cover statifier-ex ADR-0015 in Ruby." },
                   { "id" => "zz-tgv", "title" => shared_title, "priority" => 2, "issue_type" => "chore",
                     "labels" => ["area:beta"],
                     "description" => "plan_state_test.rb's real-plan fixture assumes an always-incomplete phase." }
                 ])
    expect_empty_survey
    expect_claim("zz-trm", "zz-tgv")

    _code, env = run_select(["--auto"])

    trm = env["data"]["candidates"].find { |c| c["id"] == "zz-trm" }
    tgv = env["data"]["candidates"].find { |c| c["id"] == "zz-tgv" }
    assert_equal trm["title"], tgv["title"]
    refute_equal trm["summary"], tgv["summary"]
  end

  # --- claim at take (ADR-0012, wu-z6n phase 2) ---------------------------

  # sabotage: drop the claim_take call from the "free" branch -> red, no
  # bd update call is recorded for either recommended bead
  def test_auto_claims_exactly_the_beads_the_walk_took
    expect_ready([
                   issue("zz-a", priority: 1, labels: ["area:alpha"]),
                   issue("zz-b", priority: 2, labels: ["area:beta"]),
                   issue("zz-c", priority: 3, labels: ["area:alpha"])
                 ])
    expect_empty_survey
    expect_claim("zz-a", "zz-b")

    _code, env = run_select(["--auto"])

    assert_equal %w[zz-a zz-b], env["data"]["recommended"]
    claimed_ids = @fake.calls.select { |c| c.argv[0, 2] == %w[bd update] }.map { |c| c.argv[2] }
    assert_equal %w[zz-a zz-b], claimed_ids
  end

  # sabotage: treat a failed claim as a take (ignore claim_take's return)
  # -> red, the contended bead appears in recommended
  def test_contended_claim_skips_and_the_walk_continues
    expect_ready([
                   issue("zz-a", priority: 1, labels: ["area:alpha"]),
                   issue("zz-b", priority: 2, labels: ["area:beta"])
                 ])
    expect_empty_survey
    expect_claim("zz-a", exitstatus: 1, err: "already claimed by another session")
    expect_claim("zz-b")

    code, env = run_select(["--auto"])

    assert_equal ["zz-b"], env["data"]["recommended"]
    skipped = env["data"]["skipped"].find { |s| s["id"] == "zz-a" }
    assert_match(/claim failed/, skipped["reason"])
    assert_match(/already claimed by another session/, skipped["reason"])
    assert env["warnings"].any? { |w| w["code"] == "claim_contended" && w["message"].include?("zz-a") }
    assert_equal true, env["ok"]
    assert_equal 0, code
  end

  # sabotage: union zz-a's areas into batch_areas before the claim ->
  # red, zz-b (sharing an area with zz-a) is skipped as an in-batch
  # collision instead of being taken
  def test_contended_bead_does_not_consume_the_batch_area_budget
    expect_ready([
                   issue("zz-a", priority: 1, labels: ["area:alpha"]),
                   issue("zz-b", priority: 2, labels: ["area:alpha"])
                 ])
    expect_empty_survey
    expect_claim("zz-a", exitstatus: 1, err: "already claimed by another session")
    expect_claim("zz-b")

    _code, env = run_select(["--auto"])

    assert_equal ["zz-b"], env["data"]["recommended"]
    skipped = env["data"]["skipped"].find { |s| s["id"] == "zz-a" }
    assert_match(/claim failed/, skipped["reason"])
  end

  # sabotage: on a contended lands-alone candidate, still set alone = true
  # and break -> red, the following free bead is never taken
  def test_contended_lands_alone_candidate_voids_alone_and_the_walk_resumes
    expect_ready([
                   issue("zz-bld", priority: 1, labels: ["area:build"]),
                   issue("zz-int", priority: 2, labels: ["area:alpha"])
                 ])
    expect_empty_survey
    expect_claim("zz-bld", exitstatus: 1, err: "already claimed by another session")
    expect_claim("zz-int")

    _code, env = run_select(["--auto"])

    assert_equal ["zz-int"], env["data"]["recommended"]
    skipped = env["data"]["skipped"].find { |s| s["id"] == "zz-bld" }
    assert_match(/claim failed/, skipped["reason"])
    refute_match(/lands alone/, skipped["reason"])
  end

  # sabotage: drop the `--dry-run` passthrough in claim_take -> red,
  # FakeSh raises on an unauthorized bd update
  def test_dry_run_auto_claims_nothing_and_renders_the_claim_commands
    expect_ready([issue("zz-a", priority: 1, labels: ["area:alpha"])])
    expect_empty_survey

    _code, env = run_select(["--auto", "--dry-run"])

    assert_equal ["zz-a"], env["data"]["recommended"]
    refute @fake.calls.any? { |c| c.argv[0, 2] == %w[bd update] }
    assert env["commands"].any? { |c| c.include?("bd update zz-a --claim --json") }
  end

  # sabotage: call claim_take unconditionally (drop the `claim` guard) ->
  # red, FakeSh raises on an unauthorized bd update in manual mode
  def test_manual_mode_executes_no_claim
    expect_ready([issue("zz-a", priority: 1, labels: ["area:alpha"])])
    expect_empty_survey

    _code, env = run_select([])

    assert_equal "manual", env["data"]["mode"]
    refute @fake.calls.any? { |c| c.argv[0, 2] == %w[bd update] }
    assert_equal ["zz-a"], env["data"]["recommended"]
  end
end

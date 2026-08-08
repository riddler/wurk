# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../work_state"
require_relative "support/fake_sh"
require_relative "support/manifest_helper"

# WorkState.find_docs / doc_id_pattern (pure functions).
class WorkStateLibTest < Minitest::Test
  def test_finds_a_doc_naming_the_bead_with_a_description_after_it
    in_tmp_dir do |dir|
      write(dir, "260806-zz-hzf-skill-mechanics-scripts.md")

      assert_equal ["#{dir}/260806-zz-hzf-skill-mechanics-scripts.md"], WorkState.find_docs(dir, "zz-hzf")
    end
  end

  def test_finds_a_doc_with_a_dotted_issue_id
    in_tmp_dir do |dir|
      write(dir, "260806-zz-00p.3-regression-ratchet.md")

      assert_equal ["#{dir}/260806-zz-00p.3-regression-ratchet.md"], WorkState.find_docs(dir, "zz-00p.3")
    end
  end

  def test_does_not_match_a_bead_id_that_is_only_a_prefix_of_another
    in_tmp_dir do |dir|
      write(dir, "260806-zz-hzfoo-unrelated.md")

      assert_empty WorkState.find_docs(dir, "zz-hzf")
    end
  end

  def test_returns_empty_when_the_directory_does_not_exist
    assert_empty WorkState.find_docs("/no/such/dir/at/all", "zz-hzf")
  end

  def test_sorts_multiple_matches_by_filename_oldest_date_first
    in_tmp_dir do |dir|
      write(dir, "260810-zz-hzf-later.md")
      write(dir, "260801-zz-hzf-earlier.md")

      assert_equal(
        ["#{dir}/260801-zz-hzf-earlier.md", "#{dir}/260810-zz-hzf-later.md"],
        WorkState.find_docs(dir, "zz-hzf")
      )
    end
  end

  private

  def in_tmp_dir
    Dir.mktmpdir { |dir| yield dir }
  end

  def write(dir, filename)
    File.write(File.join(dir, filename), "content\n")
  end
end

# WorkStateCli (composes Bead.run and plan_state.rb's parser).
class WorkStateCliTest < Minitest::Test
  include ManifestHelper

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
    @orig_pwd = Dir.pwd
  end

  def teardown
    Sh.runner = nil
    Dir.chdir(@orig_pwd)
  end

  def run_work_state(argv)
    io = StringIO.new
    code = WorkStateCli.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  def expect_bd_show(id, notes:, status: "in_progress")
    payload = [{
      "id" => id, "title" => "A bead", "description" => "d", "acceptance_criteria" => "a",
      "notes" => notes, "status" => status, "priority" => "P2", "issue_type" => "chore",
      "assignee" => "someone", "labels" => [], "dependent_count" => 0, "dependency_count" => 0
    }]
    @fake.expect(["bd", "show", id, "--json"], out: JSON.generate(payload))
  end

  def test_missing_id_is_a_usage_block_not_a_crash
    code, result = run_work_state([])

    assert_equal 1, code
    assert_equal ["missing_id"], result["blocked"].map { |b| b["code"] }
  end

  # Needs in_tmp_repo like its neighbours: the script requires a manifest
  # before it ever shells out to bd, so a bare cwd sends the walk-up all the
  # way to `git rev-parse`, which FakeSh refuses.
  def test_bead_not_found_blocks_with_the_bd_failure_reason
    in_tmp_repo do
      @fake.expect(["bd", "show", "zz-nope", "--json"], out: "", err: "not found", exitstatus: 1)

      code, result = run_work_state(["zz-nope"])

      assert_equal 1, code
      assert_equal ["bead_not_found"], result["blocked"].map { |b| b["code"] }
    end
  end

  def test_reports_bead_and_loop_notes_with_no_docs_present
    in_tmp_repo do
      expect_bd_show("zz-abc", notes: "loop: Phase 1 complete, commit deadbee\nloop: Phase 2 complete, commit c0ffee1")

      code, result = run_work_state(["zz-abc"])

      assert_equal 0, code
      assert_equal "zz-abc", result["data"]["bead"]["id"]
      assert_equal "in_progress", result["data"]["bead"]["status"]
      assert_empty result["data"]["research_docs"]
      assert_empty result["data"]["plan_docs"]
      assert_nil result["data"]["plan"]
      assert_equal 2, result["data"]["loop_notes"].length
      assert_equal({ "status" => "complete", "phase" => 2, "commit" => "c0ffee1" }, result["data"]["last_loop_note"]["loop"])
    end
  end

  def test_non_loop_notes_are_excluded_from_loop_notes
    in_tmp_repo do
      expect_bd_show("zz-abc", notes: "Motivation: some free text with no loop grammar at all")

      _code, result = run_work_state(["zz-abc"])

      assert_empty result["data"]["loop_notes"]
      assert_nil result["data"]["last_loop_note"]
    end
  end

  def test_finds_research_and_plan_docs_and_parses_the_plan
    in_tmp_repo do
      FileUtils.mkdir_p("docs/research")
      FileUtils.mkdir_p("docs/plans")
      File.write("docs/research/260801-zz-abc-some-topic.md", "# Research\n")
      File.write("docs/plans/260802-zz-abc-a-plan.md", sample_plan)

      expect_bd_show("zz-abc", notes: "")

      _code, result = run_work_state(["zz-abc"])

      assert_equal ["docs/research/260801-zz-abc-some-topic.md"], result["data"]["research_docs"]
      assert_equal ["docs/plans/260802-zz-abc-a-plan.md"], result["data"]["plan_docs"]
      refute_nil result["data"]["plan"]
      assert_equal "docs/plans/260802-zz-abc-a-plan.md", result["data"]["plan"]["path"]
      assert_equal 1, result["data"]["plan"]["next_phase"]
    end
  end

  def test_warns_on_multiple_plan_docs_but_still_reports_the_first
    in_tmp_repo do
      FileUtils.mkdir_p("docs/plans")
      File.write("docs/plans/260801-zz-abc-first.md", sample_plan)
      File.write("docs/plans/260805-zz-abc-second.md", sample_plan)

      expect_bd_show("zz-abc", notes: "")

      _code, result = run_work_state(["zz-abc"])

      assert_equal 2, result["data"]["plan_docs"].length
      assert_equal "docs/plans/260801-zz-abc-first.md", result["data"]["plan"]["path"]
      assert_includes result["warnings"].map { |w| w["code"] }, "multiple_plan_docs"
    end
  end

  # The artifact roots are manifest data, not constants - a repo laying its
  # documents out under thoughts/shared/ gets found without a code change.
  # This is the same pair of values the skills pass to their research
  # subagents, so a drift here would mean the script and the agents look in
  # different places for the same document.
  #
  # sabotage: hardcode "docs/research"/"docs/plans" back into WorkState -> red
  def test_artifact_roots_come_from_the_manifest
    in_tmp_repo("thoughts_layout") do
      FileUtils.mkdir_p("thoughts/shared/plans")
      FileUtils.mkdir_p("thoughts/shared/research")
      File.write("thoughts/shared/plans/260801-zz-abc-a-plan.md", sample_plan)
      File.write("thoughts/shared/research/260801-zz-abc-a-question.md", "# Research\n")

      expect_bd_show("zz-abc", notes: "")

      _code, result = run_work_state(["zz-abc"])

      assert_equal ["thoughts/shared/plans/260801-zz-abc-a-plan.md"], result["data"]["plan_docs"]
      assert_equal ["thoughts/shared/research/260801-zz-abc-a-question.md"], result["data"]["research_docs"]
    end
  end

  # This script never itself pushes, opens a PR, closes a bead, or chooses
  # a bucket - it only reports. Confirm the recorded commands are exactly
  # the one bd show call, nothing more.
  def test_commands_carries_only_the_bd_show_call
    in_tmp_repo do
      expect_bd_show("zz-abc", notes: "")

      _code, result = run_work_state(["zz-abc"])

      assert_equal ["bd show zz-abc --json"], result["commands"]
    end
  end

  private

  def sample_plan
    <<~PLAN
      # A Plan

      ## Phase 1: First

      ### Success Criteria:

      #### Automated Verification:
      - [ ] something automated

      #### Manual Verification:
      - [ ] something manual
    PLAN
  end
end

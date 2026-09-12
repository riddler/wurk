# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../worktree_cleanup"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"

class WorktreeCleanupTest < Minitest::Test
  include ManifestHelper

  # Bead prefix and trailer key are manifest values (zz / Refs), so the
  # fixture drives both the branch decomposition and the trailer scan.
  FIXTURE = "worktree"

  MAIN = "/repos/myrepo"
  WT1 = "/repos/zz-worktrees/zz-abc-merged-thing"
  WT2 = "/repos/zz-worktrees/zz-def-open-pr"

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
  end

  def run_cleanup(argv = [], fixture: FIXTURE)
    io = StringIO.new
    code = nil
    with_manifest(fixture) { code = WorktreeCleanup.run(argv, io: io) }
    [code, JSON.parse(io.string)]
  end

  # Both kinds the manifest schema accepts now have a request-state adapter,
  # so the implemented list is narrowed to make the unsupported-forge path
  # reachable at all: this script must refuse in its own voice for the forge
  # after these, which is a property no fixture can express on its own.
  #
  # sabotage: drop the Forge.guard! call from worktree_cleanup.rb -> the
  # sweep proceeds to a forge CLI and FakeSh raises UnexpectedCommand -> red.
  # This is the script that deletes branches, so it must refuse in its own
  # voice.
  def test_an_unimplemented_forge_blocks_before_any_branch_is_touched
    code, env = Forge.with_implemented(%w[github]) do
      run_cleanup([], fixture: "forge_gitlab")
    end

    assert_equal 1, code
    assert_equal "unsupported_forge", env["blocked"].first["code"]
    assert_equal "human", env["blocked"].first["needs"]
    assert_empty @fake.calls
  end

  def porcelain
    <<~TXT
      worktree #{MAIN}
      HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      branch refs/heads/main

      worktree #{WT1}
      HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      branch refs/heads/zz-abc-merged-thing

      worktree #{WT2}
      HEAD cccccccccccccccccccccccccccccccccccccccc
      branch refs/heads/zz-def-open-pr
    TXT
  end

  def expect_survey(wt1_pr: :merged, wt2_pr: :none)
    @fake.expect(%w[git worktree list --porcelain], out: porcelain)

    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[bd show zz-abc --json], out: '[{"id":"zz-abc","labels":[]}]')
    if wt1_pr == :merged
      @fake.expect(
        ["gh", "pr", "list", "--state", "merged", "--head", "zz-abc-merged-thing",
         "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
        out: %({"number":42,"mergedAt":"2026-08-06T00:00:00Z","headRefOid":"deadbeef"}\n)
      )
    end

    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 1)
    @fake.expect(%w[bd show zz-def --json], out: '[{"id":"zz-def","labels":[]}]')
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "zz-def-open-pr",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: "null\n"
    )
  end

  def test_merged_clean_worktree_is_removed_beads_gathered_no_close_called
    expect_survey
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git rev-parse HEAD], out: "deadbeef\n")
    @fake.expect(
      ["gh", "pr", "view", "42", "--json", "commits", "--jq", ".commits[].messageBody"],
      out: "Fixes a thing.\n\nRefs: zz-abc\n"
    )
    @fake.expect(["git", "worktree", "remove", WT1], out: "")
    @fake.expect(%w[git worktree prune], out: "")
    @fake.expect(["git", "branch", "-D", "zz-abc-merged-thing"], out: "")
    @fake.expect(%w[git fetch --prune], out: "")

    code, env = run_cleanup

    assert_equal 0, code
    assert_equal true, env["ok"]
    results = env["data"]["results"]
    wt1 = results.find { |r| r["path"] == WT1 }
    assert_equal "merged in request #42, removed", wt1["result"]

    wt2 = results.find { |r| r["path"] == WT2 }
    assert_equal "not merged (no request, open, or closed unmerged), kept", wt2["result"]

    assert_equal ["zz-abc"], env["data"]["beads_to_close"]
  end

  def test_dirty_worktree_is_never_force_removed
    expect_survey
    @fake.expect(%w[git status --porcelain], out: " M lib/foo.ex\n")
    @fake.expect(%w[git fetch --prune], out: "")
    # No "git worktree remove" expectation - a dirty worktree must not be
    # touched, forced or otherwise.

    code, env = run_cleanup

    assert_equal 0, code
    wt1 = env["data"]["results"].find { |r| r["path"] == WT1 }
    assert_equal "dirty, skipped", wt1["result"]
    assert_equal [], env["data"]["beads_to_close"]
  end

  def test_a_commit_the_merged_request_never_saw_is_still_refused
    expect_survey
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git rev-parse HEAD], out: "0123456\n")
    @fake.expect(%w[git cherry origin/main HEAD], out: "+ 0123456789012345678901234567890123456789\n")
    @fake.expect(%w[git fetch --prune], out: "")
    # No removal, prune, or branch-delete expectations - a genuine extra
    # commit is still refused, probe or no probe.

    code, env = run_cleanup

    assert_equal 0, code
    wt1 = env["data"]["results"].find { |r| r["path"] == WT1 }
    assert_match(/commits after merge/, wt1["result"])
    assert_equal [], env["data"]["beads_to_close"]
  end

  def test_a_mixed_cherry_output_refuses_on_the_single_unmatched_commit
    expect_survey
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git rev-parse HEAD], out: "0123456\n")
    @fake.expect(
      %w[git cherry origin/main HEAD],
      out: "- aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n+ bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n"
    )
    @fake.expect(%w[git fetch --prune], out: "")

    code, env = run_cleanup

    assert_equal 0, code
    wt1 = env["data"]["results"].find { |r| r["path"] == WT1 }
    assert_match(/commits after merge/, wt1["result"])
  end

  def test_an_unverifiable_probe_refuses_and_says_so
    expect_survey
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git rev-parse HEAD], out: "0123456\n")
    @fake.expect(%w[git cherry origin/main HEAD], exitstatus: 1, err: "fatal: no such ref\n")
    @fake.expect(%w[git fetch --prune], out: "")

    code, env = run_cleanup

    assert_equal 0, code
    wt1 = env["data"]["results"].find { |r| r["path"] == WT1 }
    assert_match(/unverified, skipped/, wt1["result"])
    assert_equal "patch_equivalence_unknown", env["warnings"].first["code"]
  end

  def test_a_rewritten_tip_whose_patches_all_landed_is_removed_and_its_beads_gathered
    expect_survey
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git rev-parse HEAD], out: "f1703cd\n")
    @fake.expect(%w[git cherry origin/main HEAD], out: "- f1703cd0000000000000000000000000000000\n")
    @fake.expect(
      ["gh", "pr", "view", "42", "--json", "commits", "--jq", ".commits[].messageBody"],
      out: "Fixes a thing.\n\nRefs: zz-abc\n"
    )
    @fake.expect(["git", "worktree", "remove", WT1], out: "")
    @fake.expect(%w[git worktree prune], out: "")
    @fake.expect(["git", "branch", "-D", "zz-abc-merged-thing"], out: "")
    @fake.expect(%w[git fetch --prune], out: "")

    code, env = run_cleanup

    assert_equal 0, code
    wt1 = env["data"]["results"].find { |r| r["path"] == WT1 }
    assert_equal "merged in request #42 (local tip rewritten, patches already on origin/main), removed", wt1["result"]
    assert_equal ["zz-abc"], env["data"]["beads_to_close"]
  end

  def test_the_probe_is_not_run_when_the_shas_match
    expect_survey
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git rev-parse HEAD], out: "deadbeef\n")
    @fake.expect(
      ["gh", "pr", "view", "42", "--json", "commits", "--jq", ".commits[].messageBody"],
      out: "Fixes a thing.\n\nRefs: zz-abc\n"
    )
    @fake.expect(["git", "worktree", "remove", WT1], out: "")
    @fake.expect(%w[git worktree prune], out: "")
    @fake.expect(["git", "branch", "-D", "zz-abc-merged-thing"], out: "")
    @fake.expect(%w[git fetch --prune], out: "")

    run_cleanup

    refute @fake.calls.any? { |c| c.argv.first(2) == %w[git cherry] }
  end

  def test_forge_unavailable_stops_the_whole_sweep
    @fake.expect(%w[git worktree list --porcelain], out: porcelain)
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[bd show zz-abc --json], out: '[{"id":"zz-abc","labels":[]}]')
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "zz-abc-merged-thing",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      exitstatus: 1, err: "gh: authentication required\n"
    )
    # Survey still visits wt2 (its own forge_available degrade is
    # per-worktree), but never queries gh again once it went unavailable.
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 1)
    @fake.expect(%w[bd show zz-def --json], out: '[{"id":"zz-def","labels":[]}]')

    code, env = run_cleanup

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "forge_unavailable", env["blocked"].first["code"]
  end

  def test_dry_run_never_removes_or_deletes_the_branch
    @fake.expect(%w[git fetch --prune], out: "")
    expect_survey
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git rev-parse HEAD], out: "deadbeef\n")
    @fake.expect(
      ["gh", "pr", "view", "42", "--json", "commits", "--jq", ".commits[].messageBody"],
      out: "Refs: zz-abc\n"
    )
    # No "git worktree remove" or "git branch -D" expectations - dry-run
    # must not execute either, even though the fetch above is real.

    code, env = run_cleanup(["--dry-run"])

    assert_equal 0, code
    assert env["commands"].any? { |c| c.include?("git worktree remove") }
    assert env["commands"].any? { |c| c.include?("git branch -D") }
    refute env["commands"].any? { |c| c.include?("--force") }
    assert @fake.calls.any? { |c| c.argv == %w[git fetch --prune] }
    refute @fake.calls.any? { |c| c.argv.include?("remove") && c.argv.include?("worktree") }
    refute @fake.calls.any? { |c| c.argv == ["git", "branch", "-D", "zz-abc-merged-thing"] }
  end

  def test_the_sweep_fetches_before_it_judges_any_worktree
    @fake.expect(%w[git fetch --prune], out: "")
    expect_survey
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git rev-parse HEAD], out: "deadbeef\n")
    @fake.expect(
      ["gh", "pr", "view", "42", "--json", "commits", "--jq", ".commits[].messageBody"],
      out: "Fixes a thing.\n\nRefs: zz-abc\n"
    )
    @fake.expect(["git", "worktree", "remove", WT1], out: "")
    @fake.expect(%w[git worktree prune], out: "")
    @fake.expect(["git", "branch", "-D", "zz-abc-merged-thing"], out: "")

    run_cleanup

    fetch_index = @fake.calls.find_index { |c| c.argv == %w[git fetch --prune] }
    first_rev_parse_index = @fake.calls.find_index { |c| c.argv == %w[git rev-parse HEAD] }

    refute_nil fetch_index
    refute_nil first_rev_parse_index
    assert_operator fetch_index, :<, first_rev_parse_index
  end

  def test_a_failed_survey_fetches_nothing
    @fake.expect(%w[git worktree list --porcelain], out: porcelain)
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[bd show zz-abc --json], out: '[{"id":"zz-abc","labels":[]}]')
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "zz-abc-merged-thing",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      exitstatus: 1, err: "gh: authentication required\n"
    )
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 1)
    @fake.expect(%w[bd show zz-def --json], out: '[{"id":"zz-def","labels":[]}]')

    code, env = run_cleanup

    assert_equal 1, code
    assert_equal "forge_unavailable", env["blocked"].first["code"]
    refute @fake.calls.any? { |c| c.argv == %w[git fetch --prune] }
  end

  def test_no_bd_close_call_anywhere_in_source
    code_lines = File.readlines(File.expand_path("../worktree_cleanup.rb", __dir__))
                      .map { |l| l.sub(/#.*/, "") }
    refute code_lines.any? { |l| l =~ /bd["'\s,]+close\b/ }, "found a bd close call outside comments"
  end

  def test_no_force_flag_anywhere_in_source
    source = File.read(File.expand_path("../worktree_cleanup.rb", __dir__))
    # "force" appears exactly once, in the comment forbidding it.
    hits = source.each_line.select { |l| l.include?("force") }
    assert_equal 1, hits.length
    assert_match(/\A\s*#/, hits.first)
  end

  def test_patch_equivalence_with_empty_output_is_equivalent
    @fake.expect(%w[git cherry origin/main HEAD], out: "")
    state, detail = WorktreeCleanup.patch_equivalence("/repos/wt", "origin/main", Envelope.new(script: "test"))
    assert_equal :equivalent, state
    assert_nil detail
  end

  def test_patch_equivalence_with_all_dash_lines_is_equivalent
    @fake.expect(
      %w[git cherry origin/main HEAD],
      out: "- aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n- bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n"
    )
    state, = WorktreeCleanup.patch_equivalence("/repos/wt", "origin/main", Envelope.new(script: "test"))
    assert_equal :equivalent, state
  end

  def test_patch_equivalence_with_any_plus_line_is_diverged
    @fake.expect(
      %w[git cherry origin/main HEAD],
      out: "- aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n+ bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n"
    )
    state, detail = WorktreeCleanup.patch_equivalence("/repos/wt", "origin/main", Envelope.new(script: "test"))
    assert_equal :diverged, state
    assert_match(/1 commit/, detail)
  end

  def test_patch_equivalence_with_a_nonzero_exit_is_unknown
    @fake.expect(%w[git cherry origin/main HEAD], exitstatus: 1, err: "fatal: bad revision\n")
    state, detail = WorktreeCleanup.patch_equivalence("/repos/wt", "origin/main", Envelope.new(script: "test"))
    assert_equal :unknown, state
    assert_match(/fatal: bad revision/, detail)
  end
end

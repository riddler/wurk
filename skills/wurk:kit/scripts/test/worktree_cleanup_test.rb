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

  # sabotage: drop the Forge.guard! call from worktree_cleanup.rb -> the
  # sweep proceeds to gh and FakeSh raises UnexpectedCommand -> red. This is
  # the script that deletes branches, so it must refuse in its own voice.
  def test_a_gitlab_repo_blocks_before_any_branch_is_touched
    code, env = run_cleanup([], fixture: "forge_gitlab")

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
    assert_equal "merged in PR #42, removed", wt1["result"]

    wt2 = results.find { |r| r["path"] == WT2 }
    assert_equal "not merged (no PR, open, or closed unmerged), kept", wt2["result"]

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

  def test_commits_after_merge_are_skipped_not_deleted
    expect_survey
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git rev-parse HEAD], out: "0123456\n")
    @fake.expect(%w[git fetch --prune], out: "")
    # No removal expectations - the local tip diverged from what merged.

    code, env = run_cleanup

    assert_equal 0, code
    wt1 = env["data"]["results"].find { |r| r["path"] == WT1 }
    assert_match(/commits after merge/, wt1["result"])
  end

  def test_gh_unavailable_stops_the_whole_sweep
    @fake.expect(%w[git worktree list --porcelain], out: porcelain)
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[bd show zz-abc --json], out: '[{"id":"zz-abc","labels":[]}]')
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "zz-abc-merged-thing",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      exitstatus: 1, err: "gh: authentication required\n"
    )
    # Survey still visits wt2 (its own gh_available degrade is per-worktree),
    # but never queries gh again once it went unavailable.
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 1)
    @fake.expect(%w[bd show zz-def --json], out: '[{"id":"zz-def","labels":[]}]')

    code, env = run_cleanup

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "gh_unavailable", env["blocked"].first["code"]
  end

  def test_dry_run_never_removes_or_deletes_the_branch
    expect_survey
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git rev-parse HEAD], out: "deadbeef\n")
    @fake.expect(
      ["gh", "pr", "view", "42", "--json", "commits", "--jq", ".commits[].messageBody"],
      out: "Refs: zz-abc\n"
    )
    # No "git worktree remove", "git worktree prune", "git branch -D" or
    # "git fetch --prune" expectations - dry-run must not execute any of
    # them.

    code, env = run_cleanup(["--dry-run"])

    assert_equal 0, code
    assert env["commands"].any? { |c| c.include?("git worktree remove") }
    assert env["commands"].any? { |c| c.include?("git branch -D") }
    assert env["commands"].any? { |c| c.include?("git fetch --prune") }
    refute env["commands"].any? { |c| c.include?("--force") }
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
end

# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../worktree_survey"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"

class WorktreeSurveyTest < Minitest::Test
  include ManifestHelper

  # Bead decomposition is the manifest's `beads.prefix` now, so the fixture
  # drives it: a branch named zz-abc-... only decomposes if Refs really read
  # the manifest. Asserting "zz-abc" here would have gone green either way.
  FIXTURE = "worktree"

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
  end

  def run_survey(argv = [], fixture: FIXTURE)
    io = StringIO.new
    code = nil
    with_manifest(fixture) { code = WorktreeSurvey.run(argv, io: io) }
    [code, JSON.parse(io.string)]
  end

  # sabotage: drop the Forge.guard! call from worktree_survey.rb -> the
  # survey shells out to gh against a GitLab repo -> red
  def test_a_gitlab_repo_blocks_rather_than_shelling_out_to_gh
    code, env = run_survey([], fixture: "forge_gitlab")

    assert_equal 1, code
    assert_equal "unsupported_forge", env["blocked"].first["code"]
    assert_equal "human", env["blocked"].first["needs"]
    assert_empty @fake.calls
  end

  def test_survey_drops_main_decomposes_dotted_id_and_marks_stale_holds_no_areas
    porcelain = <<~TXT
      worktree /repos/myrepo
      HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      branch refs/heads/main

      worktree /repos/zz-worktrees/zz-abc-exit-sets
      HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      branch refs/heads/zz-abc-exit-sets

      worktree /repos/zz-worktrees/zz-00p.3-fix-thing
      HEAD cccccccccccccccccccccccccccccccccccccccc
      branch refs/heads/zz-00p.3-fix-thing
    TXT

    @fake.expect(%w[git worktree list --porcelain], out: porcelain)

    # zz-abc-exit-sets: clean, ahead of origin/main, merged (stale).
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[bd show zz-abc --json], out: '[{"id":"zz-abc","labels":["area:interpreter"]}]')
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "zz-abc-exit-sets",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: %({"number":9,"mergedAt":"2026-08-01T00:00:00Z","headRefOid":"deadbeef"}\n)
    )

    # zz-00p.3-fix-thing: dirty, not merged, dotted bead id.
    @fake.expect(%w[git status --porcelain], out: " M lib/foo.ex\n")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 1)
    @fake.expect(%w[bd show zz-00p.3 --json], out: '[{"id":"zz-00p.3","labels":["area:parser"]}]')
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "zz-00p.3-fix-thing",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: "null\n"
    )

    code, env = run_survey

    assert_equal 0, code
    data = env["data"]
    assert_equal "/repos/myrepo", data["main_checkout"]
    assert_equal 2, data["worktrees"].length

    wt1 = data["worktrees"].find { |w| w["bead"] == "zz-abc" }
    assert_equal true, wt1["stale"]
    assert_equal ["area:interpreter"], wt1["areas"]
    assert_equal [], wt1["holds_areas"]
    assert_equal Forge::REQUEST_MERGED, wt1["request"]["state"]

    wt2 = data["worktrees"].find { |w| w["bead"] == "zz-00p.3" }
    assert_equal false, wt2["stale"]
    assert_equal ["area:parser"], wt2["areas"]
    assert_equal ["area:parser"], wt2["holds_areas"]
    assert_equal true, wt2["dirty"]
    assert_nil wt2["request"]

    assert_equal true, data["forge_available"]
    assert_equal [], data["degraded"]
  end

  def test_forge_unavailable_degrades_once_not_per_worktree
    porcelain = <<~TXT
      worktree /repos/myrepo
      HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      branch refs/heads/main

      worktree /repos/zz-worktrees/zz-abc-exit-sets
      HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      branch refs/heads/zz-abc-exit-sets

      worktree /repos/zz-worktrees/zz-def-other
      HEAD cccccccccccccccccccccccccccccccccccccccc
      branch refs/heads/zz-def-other
    TXT

    @fake.expect(%w[git worktree list --porcelain], out: porcelain)

    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[bd show zz-abc --json], out: '[{"id":"zz-abc","labels":["area:interpreter"]}]')
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "zz-abc-exit-sets",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      exitstatus: 1, err: "gh: authentication required\n"
    )

    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[bd show zz-def --json], out: '[{"id":"zz-def","labels":["area:parser"]}]')
    # No second "gh pr list" expectation is registered - if the script
    # queried gh again after it went unavailable, FakeSh would raise
    # UnexpectedCommand and fail this test.

    code, env = run_survey

    assert_equal 0, code
    data = env["data"]
    assert_equal false, data["forge_available"]
    assert_equal 1, env["warnings"].length
    assert_equal "forge_unavailable", env["warnings"].first["code"]
    assert_equal(
      %w[
        /repos/zz-worktrees/zz-abc-exit-sets
        /repos/zz-worktrees/zz-def-other
      ],
      data["degraded"]
    )

    wt2 = data["worktrees"].find { |w| w["bead"] == "zz-def" }
    assert_equal false, wt2["stale"]
    assert_equal ["area:parser"], wt2["holds_areas"]
  end

  # sabotage: read a hardcoded "origin/main" instead of
  # manifest.remote_default_branch -> FakeSh raises UnexpectedCommand (no
  # stub for "origin/main" here, only "origin/trunk") -> red. The reported
  # field stays ancestor_of_origin_main even though the value now comes from
  # the manifest's remote default branch.
  def test_trunk_override_checks_ancestry_against_the_manifests_remote_default_branch
    other = manifest_with(FIXTURE, "repo" => { "default_branch" => "trunk" })

    porcelain = <<~TXT
      worktree /repos/myrepo
      HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      branch refs/heads/main

      worktree /repos/zz-worktrees/zz-abc-exit-sets
      HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      branch refs/heads/zz-abc-exit-sets
    TXT

    @fake.expect(%w[git worktree list --porcelain], out: porcelain)
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/trunk HEAD], exitstatus: 0)
    @fake.expect(%w[bd show zz-abc --json], out: '[{"id":"zz-abc","labels":[]}]')
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "zz-abc-exit-sets",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: "null\n"
    )

    code, env = run_survey([], fixture: other)

    assert_equal 0, code
    wt = env["data"]["worktrees"].first
    assert_equal true, wt["ancestor_of_origin_main"]
  end

  def test_git_worktree_list_failure_blocks
    @fake.expect(%w[git worktree list --porcelain], exitstatus: 1, err: "fatal: not a git repository\n")

    code, env = run_survey

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "git_worktree_list_failed", env["blocked"].first["code"]
  end
end

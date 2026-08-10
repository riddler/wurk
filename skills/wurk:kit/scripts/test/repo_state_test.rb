# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../repo_state"
require_relative "support/fake_sh"
require_relative "support/manifest_helper"

# Driven from the `repo_layout` fixture manifest (prefix "zz", plans under
# docs/plans, fragments under changelog.d) rather than this repo's own - see
# support/manifest_helper.rb.
class RepoStateTest < Minitest::Test
  include ManifestHelper

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
    Manifest.current = fixture_manifest("repo_layout")
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
  end

  def run_repo_state(argv = [])
    io = StringIO.new
    code = RepoState.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  def expect_locate(git_dir: "/repo/worktrees/zz-abc-x/.git",
                     common_dir: "/repo/.git",
                     toplevel: "/repo/worktrees/zz-abc-x")
    @fake.expect(%w[git rev-parse --git-dir], out: "#{git_dir}\n")
    @fake.expect(%w[git rev-parse --git-common-dir], out: "#{common_dir}\n")
    @fake.expect(%w[git rev-parse --show-toplevel], out: "#{toplevel}\n")
  end

  def test_worktree_checkout_is_detected_and_branch_bead_is_weak
    expect_locate
    @fake.expect(%w[git branch --show-current], out: "zz-abc-exit-sets\n")
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(
      ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
      out: "origin/zz-abc-exit-sets\n"
    )
    @fake.expect(["git", "rev-list", "--count", "origin/zz-abc-exit-sets..HEAD"], out: "1\n")
    @fake.expect(["git", "rev-list", "--count", "HEAD..origin/zz-abc-exit-sets"], out: "0\n")
    @fake.expect(%w[git log], out: "")
    @fake.expect(%w[git diff --name-only main...HEAD], out: "")

    code, env = run_repo_state

    assert_equal 0, code
    assert_equal "worktree", env["data"]["checkout"]
    assert_equal false, env["data"]["is_main"]
    assert_equal "zz-abc-exit-sets", env["data"]["branch"]
    assert_equal(
      { "id" => "zz-abc", "strategy" => "branch_prefix", "confidence" => "weak" },
      env["data"]["branch_bead"]
    )
    assert_equal 1, env["data"]["commits_ahead"]
    assert_equal 0, env["data"]["commits_behind"]
  end

  def test_main_checkout_is_detected_when_git_dir_and_common_dir_match
    expect_locate(git_dir: "/repo/.git", common_dir: "/repo/.git", toplevel: "/repo")
    @fake.expect(%w[git branch --show-current], out: "main\n")
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(
      ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
      out: "origin/main\n"
    )
    @fake.expect(["git", "rev-list", "--count"], out: "0\n")
    @fake.expect(["git", "rev-list", "--count"], out: "0\n")
    @fake.expect(%w[git log], out: "")
    @fake.expect(%w[git diff --name-only main...HEAD], out: "")

    code, env = run_repo_state

    assert_equal 0, code
    assert_equal "main", env["data"]["checkout"]
    assert_equal true, env["data"]["is_main"]
    assert_nil env["data"]["branch_bead"]
  end

  def test_dirty_and_touches_build_true_via_status
    expect_locate
    @fake.expect(%w[git branch --show-current], out: "zz-abc-exit-sets\n")
    @fake.expect(%w[git status --porcelain], out: " M lib/statifier/foo.ex\n")
    @fake.expect(
      ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
      exitstatus: 1, err: "fatal: no upstream configured\n"
    )
    @fake.expect(%w[git diff --name-only main...HEAD], out: "")

    code, env = run_repo_state

    assert_equal 0, code
    assert_equal true, env["data"]["dirty"]
    assert_equal ["lib/statifier/foo.ex"], env["data"]["dirty_files"]
    assert_equal true, env["data"]["touches_build"]
    assert_nil env["data"]["upstream"]
    assert_equal [], env["data"]["unpushed"]
    assert_equal 1, env["warnings"].length
    assert_equal "no_upstream", env["warnings"].first["code"]
  end

  def test_unpushed_commits_carry_their_refs_ids
    expect_locate
    @fake.expect(%w[git branch --show-current], out: "zz-abc-exit-sets\n")
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(
      ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
      out: "origin/zz-abc-exit-sets\n"
    )
    @fake.expect(["git", "rev-list", "--count", "origin/zz-abc-exit-sets..HEAD"], out: "2\n")
    @fake.expect(["git", "rev-list", "--count", "HEAD..origin/zz-abc-exit-sets"], out: "0\n")

    record = "abc1234full\x1fAdds retry backoff\x1fAdds retry backoff\n\nRefs: zz-abc\n\x1e"
    @fake.expect(%w[git log], out: record)
    @fake.expect(%w[git diff --name-only main...HEAD], out: "")

    code, env = run_repo_state

    assert_equal 0, code
    unpushed = env["data"]["unpushed"]
    assert_equal 1, unpushed.length
    assert_equal "abc1234", unpushed.first["sha"]
    assert_equal "Adds retry backoff", unpushed.first["subject"]
    assert_equal ["zz-abc"], unpushed.first["refs"]
    assert_equal ["zz-abc"], env["data"]["refs_beads"]
  end

  def test_dotted_bead_id_and_plan_and_changelog_paths
    expect_locate
    @fake.expect(%w[git branch --show-current], out: "zz-00p.3-fix-thing\n")
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(
      ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
      exitstatus: 1
    )
    @fake.expect(
      %w[git diff --name-only main...HEAD],
      out: "docs/plans/260806-zz-00p-x.md\nchangelog.d/zz-00p.md\ndocs/adr/0011.md\n"
    )

    code, env = run_repo_state

    assert_equal 0, code
    assert_equal(
      { "id" => "zz-00p.3", "strategy" => "branch_prefix", "confidence" => "weak" },
      env["data"]["branch_bead"]
    )
    assert_equal ["docs/plans/260806-zz-00p-x.md"], env["data"]["plan_docs"]
    assert_equal ["changelog.d/zz-00p.md"], env["data"]["changelog_fragments"]
    assert_equal false, env["data"]["touches_build"]
  end

  # The two document roots are manifest data. A repo laying its plans out
  # under thoughts/shared/ and its changelog under a different directory
  # gets them classified without a code change.
  #
  # sabotage: hardcode the docs/plans and changelog.d regexes back -> red
  def test_plan_and_changelog_roots_come_from_the_manifest
    Manifest.current = manifest_with(
      "repo_layout",
      "artifacts" => { "plans" => "thoughts/shared/plans" },
      "changelog" => { "dir" => "notes/unreleased" }
    )

    expect_locate
    @fake.expect(%w[git branch --show-current], out: "zz-abc-x\n")
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], exitstatus: 1)
    @fake.expect(
      %w[git diff --name-only main...HEAD],
      out: "thoughts/shared/plans/260806-zz-abc.md\nnotes/unreleased/zz-abc.md\ndocs/plans/260806-zz-abc.md\n"
    )

    _code, env = run_repo_state

    assert_equal ["thoughts/shared/plans/260806-zz-abc.md"], env["data"]["plan_docs"]
    assert_equal ["notes/unreleased/zz-abc.md"], env["data"]["changelog_fragments"]
  end

  # A project with `changelog.mode: none` has no fragment directory at all.
  # Reporting [] is the honest answer; guessing a conventional path would
  # invent a workflow the project does not have.
  def test_absent_changelog_dir_reports_no_fragments
    Manifest.current = manifest_with("repo_layout", "changelog" => { "mode" => "none", "dir" => nil })

    expect_locate
    @fake.expect(%w[git branch --show-current], out: "zz-abc-x\n")
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], exitstatus: 1)
    @fake.expect(%w[git diff --name-only main...HEAD], out: "changelog.d/zz-abc.md\n")

    _code, env = run_repo_state

    assert_equal [], env["data"]["changelog_fragments"]
  end

  # sabotage: drop env.data[:default_branch] = manifest.default_branch -> red
  def test_default_branch_is_reported_on_the_default_manifest
    expect_locate
    @fake.expect(%w[git branch --show-current], out: "zz-abc-x\n")
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], exitstatus: 1)
    @fake.expect(%w[git diff --name-only main...HEAD], out: "")

    _code, env = run_repo_state

    assert_equal "main", env["data"]["default_branch"]
  end

  # sabotage: read a hardcoded "main...HEAD" instead of manifest.default_branch
  # -> red (FakeSh::UnexpectedCommand: no stub for "main...HEAD" here, only
  # "trunk...HEAD")
  def test_trunk_override_diffs_against_trunk_and_reports_it
    Manifest.current = manifest_with("repo_layout", "repo" => { "default_branch" => "trunk" })

    expect_locate
    @fake.expect(%w[git branch --show-current], out: "zz-abc-x\n")
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], exitstatus: 1)
    @fake.expect(%w[git diff --name-only trunk...HEAD], out: "docs/plans/260806-zz-abc.md\n")

    _code, env = run_repo_state

    assert_equal "trunk", env["data"]["default_branch"]
    assert_equal ["docs/plans/260806-zz-abc.md"], env["data"]["plan_docs"]
  end

  def test_not_a_git_repo_blocks_with_needs_human
    @fake.expect(%w[git rev-parse --git-dir], exitstatus: 128, err: "fatal: not a git repository\n")
    @fake.expect(%w[git rev-parse --git-common-dir], exitstatus: 128)
    @fake.expect(%w[git rev-parse --show-toplevel], exitstatus: 128)

    code, env = run_repo_state

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "not_a_git_repo", env["blocked"].first["code"]
    assert_equal "human", env["blocked"].first["needs"]
  end
end

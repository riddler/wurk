# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../worktree_refresh"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"

class WorktreeRefreshTest < Minitest::Test
  include ManifestHelper

  # Bead prefix, gate command and repair lockfile all come from the
  # `worktree` fixture (zz / `make quick` / lock.json), so nothing here goes
  # green merely because the suite happens to run inside statifier.
  FIXTURE = "worktree"

  MAIN = "/repos/myrepo"
  WT1 = "/repos/zz-worktrees/zz-abc-current-thing"
  WT2 = "/repos/zz-worktrees/zz-def-needs-rebase"

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
  end

  def run_refresh(argv = [], fixture: FIXTURE)
    io = StringIO.new
    code = nil
    with_manifest(fixture) { code = WorktreeRefresh.run(argv, io: io) }
    [code, JSON.parse(io.string)]
  end

  # sabotage: drop the Forge.guard! call from worktree_refresh.rb -> the
  # survey it drives shells out to gh against a GitLab repo -> red. Without
  # its own guard this sweep would relay worktree_survey's "unsupported_forge"
  # block as a nested "survey_failed" instead of naming the cause itself.
  def test_a_gitlab_repo_blocks_in_its_own_voice_rather_than_relaying_survey_failed
    code, env = run_refresh([], fixture: "forge_gitlab")

    assert_equal 1, code
    assert_equal "unsupported_forge", env["blocked"].first["code"]
    assert_empty @fake.calls
  end

  def porcelain
    <<~TXT
      worktree #{MAIN}
      HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      branch refs/heads/main

      worktree #{WT1}
      HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      branch refs/heads/zz-abc-current-thing

      worktree #{WT2}
      HEAD cccccccccccccccccccccccccccccccccccccccc
      branch refs/heads/zz-def-needs-rebase
    TXT
  end

  # Registers the survey's own call sequence for the two-worktree fixture
  # above: enumerate, then per worktree status/merge-base/bd show/gh pr list.
  def expect_survey
    @fake.expect(%w[git worktree list --porcelain], out: porcelain)

    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[bd show zz-abc --json], out: '[{"id":"zz-abc","labels":[]}]')
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "zz-abc-current-thing",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: "null\n"
    )

    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 1)
    @fake.expect(%w[bd show zz-def --json], out: '[{"id":"zz-def","labels":[]}]')
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "zz-def-needs-rebase",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: "null\n"
    )
  end

  def test_current_worktree_is_skipped_without_touching_the_build
    expect_survey
    @fake.expect(%w[git fetch origin], out: "")
    @fake.expect(%w[git rev-parse origin/main], out: "deadbeef\n")

    # wt1: current.
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    # wt2: needs rebase, lock.json unchanged, loop green.
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 1)
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git rev-parse HEAD], out: "aaaaaaa\n")
    @fake.expect(%w[git rebase origin/main], out: "")
    @fake.expect(%w[git rev-parse origin/main], out: "deadbeef\n")
    @fake.expect(["git", "diff", "--quiet", "aaaaaaa", "HEAD", "--", "lock.json"], exitstatus: 0)
    @fake.expect(%w[make quick], out: "green\n")

    code, env = run_refresh

    assert_equal 0, code
    results = env["data"]["results"]
    assert_equal 2, results.length

    wt1 = results.find { |r| r["path"] == WT1 }
    assert_equal "current, skipped", wt1["result"]

    wt2 = results.find { |r| r["path"] == WT2 }
    assert_equal "rebased onto deadbeef, lock unchanged, loop green", wt2["result"]
  end

  # wu-ik8: a gate command that never got a chance to run (missing
  # executable, or a gate.cwd typo) must not read as an ordinary "red" -
  # that reads as this worktree's tests failing, when it is really a
  # misconfiguration for a human to fix. The result string names the cause
  # instead, and the sweep still fails overall.
  #
  # sabotage: check `quality_res.success?` alone instead of
  # `quality_res.start_failed?` first in confirm_green -> red (this would
  # report the bare "red" instead of naming the cause)
  def test_gate_command_that_cannot_start_names_the_cause_instead_of_red
    expect_survey
    @fake.expect(%w[git fetch origin], out: "")
    @fake.expect(%w[git rev-parse origin/main], out: "deadbeef\n")

    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 1)
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git rev-parse HEAD], out: "aaaaaaa\n")
    @fake.expect(%w[git rebase origin/main], out: "")
    @fake.expect(%w[git rev-parse origin/main], out: "deadbeef\n")
    @fake.expect(["git", "diff", "--quiet", "aaaaaaa", "HEAD", "--", "lock.json"], exitstatus: 0)
    err = "could not start command - No such file or directory - make (command: \"make\")"
    @fake.expect(%w[make quick], start_failed: true, err: err)

    code, env = run_refresh

    assert_equal 1, code
    assert_equal false, env["ok"]
    wt2 = env["data"]["results"].find { |r| r["path"] == WT2 }
    assert_equal "red, gate could not start: #{err}", wt2["result"]
  end

  def test_dirty_worktree_is_refused_never_stashed
    expect_survey
    @fake.expect(%w[git fetch origin], out: "")
    @fake.expect(%w[git rev-parse origin/main], out: "deadbeef\n")

    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 1)
    @fake.expect(%w[git status --porcelain], out: " M lib/foo.ex\n")
    # No rebase/gate expectations - a dirty worktree must not be touched.

    code, env = run_refresh

    assert_equal 0, code
    wt2 = env["data"]["results"].find { |r| r["path"] == WT2 }
    assert_equal "dirty, skipped", wt2["result"]
  end

  def test_conflict_is_reported_blocked_with_files_named
    expect_survey
    @fake.expect(%w[git fetch origin], out: "")
    @fake.expect(%w[git rev-parse origin/main], out: "deadbeef\n")

    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 1)
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git rev-parse HEAD], out: "aaaaaaa\n")
    @fake.expect(%w[git rebase origin/main], exitstatus: 1, err: "CONFLICT\n")
    @fake.expect(%w[git diff --name-only --diff-filter=U], out: "docs/workflow.md\n")
    @fake.expect(%w[git rebase --abort], out: "")

    code, env = run_refresh

    # A conflict blocks the overall envelope (needs: human) even though the
    # rest of the sweep completed - see rebase_onto.rb's "always blocked"
    # contract, which worktree_refresh.rb reuses directly.
    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "rebase_conflict", env["blocked"].first["code"]
    wt2 = env["data"]["results"].find { |r| r["path"] == WT2 }
    assert_equal "conflict in docs/workflow.md, aborted, unchanged", wt2["result"]
  end

  def test_offline_fetch_is_a_hard_stop
    expect_survey
    @fake.expect(%w[git fetch origin], exitstatus: 1, err: "fatal: unable to access\n")

    code, env = run_refresh

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "offline", env["blocked"].first["code"]
  end

  def test_no_live_worktrees_is_a_normal_outcome_not_an_error
    @fake.expect(%w[git worktree list --porcelain], out: "worktree #{MAIN}\nHEAD aaaa\nbranch refs/heads/main\n")

    code, env = run_refresh

    assert_equal 0, code
    assert_equal [], env["data"]["results"]
  end

  def test_dry_run_never_executes_rebase_or_the_gate
    expect_survey
    @fake.expect(%w[git fetch origin], out: "")
    @fake.expect(%w[git rev-parse origin/main], out: "deadbeef\n")

    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 1)
    @fake.expect(%w[git status --porcelain], out: "")
    # No git rebase / gate expectations - dry-run must not execute them.

    code, env = run_refresh(["--dry-run"])

    assert_equal 0, code
    assert_equal true, env["ok"]
    wt2 = env["data"]["results"].find { |r| r["path"] == WT2 }
    assert_equal "dry run", wt2["result"]
    assert env["commands"].any? { |c| c.include?("git rebase origin/main") }
    # sabotage: hardcode `mix quality --profile loop` back into the dry-run
    # render -> red. The gate command is manifest data on both the executed
    # and the rendered path.
    assert env["commands"].any? { |c| c.include?("make quick") }
    refute env["commands"].any? { |c| c.include?("--force") }
  end

  # --- gate.cwd: the gate command runs under gate.cwd inside the refreshed worktree ---

  # sabotage: pass `chdir: path` instead of `chdir: gate_chdir(manifest, path)`
  # to confirm_green's Sh.run call -> red
  def test_gate_cwd_present_chdirs_confirm_greens_quality_run
    manifest = manifest_with(FIXTURE, "gate" => { "cwd" => "backend" })

    expect_survey
    @fake.expect(%w[git fetch origin], out: "")
    @fake.expect(%w[git rev-parse origin/main], out: "deadbeef\n")

    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 1)
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git rev-parse HEAD], out: "aaaaaaa\n")
    @fake.expect(%w[git rebase origin/main], out: "")
    @fake.expect(%w[git rev-parse origin/main], out: "deadbeef\n")
    @fake.expect(["git", "diff", "--quiet", "aaaaaaa", "HEAD", "--", "lock.json"], exitstatus: 0)
    @fake.expect(%w[make quick], out: "green\n")

    io = StringIO.new
    code = nil
    with_manifest(manifest) { code = WorktreeRefresh.run([], io: io) }
    env = JSON.parse(io.string)

    assert_equal 0, code
    wt2 = env["data"]["results"].find { |r| r["path"] == WT2 }
    assert_equal "rebased onto deadbeef, lock unchanged, loop green", wt2["result"]

    gate_call = @fake.calls.find { |c| c.argv == %w[make quick] }
    assert_equal File.join(WT2, "backend"), gate_call.chdir
  end

  # sabotage: render the dry-run preview with `chdir: path` instead of
  # `chdir: gate_chdir(manifest, path)` -> red
  def test_gate_cwd_present_renders_the_dry_run_preview_with_the_subdirectory
    manifest = manifest_with(FIXTURE, "gate" => { "cwd" => "backend" })

    expect_survey
    @fake.expect(%w[git fetch origin], out: "")
    @fake.expect(%w[git rev-parse origin/main], out: "deadbeef\n")

    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 1)
    @fake.expect(%w[git status --porcelain], out: "")
    # No git rebase / gate expectations - dry-run must not execute them.

    io = StringIO.new
    code = nil
    with_manifest(manifest) { code = WorktreeRefresh.run(["--dry-run"], io: io) }
    env = JSON.parse(io.string)

    assert_equal 0, code
    gate_preview = env["commands"].find { |c| c.include?("make quick") }
    assert_match(/\A\(cd #{Regexp.escape(File.join(WT2, "backend"))} && make quick\)/, gate_preview)
  end

  def test_never_force_in_source
    source = File.read(File.expand_path("../worktree_refresh.rb", __dir__))
    refute_match(/--force\b/, source)
  end

  # sabotage: read a hardcoded "origin/main" instead of
  # manifest.remote_default_branch -> FakeSh raises UnexpectedCommand (no
  # stub for "origin/main" here, only "origin/trunk") -> red. data.origin_main
  # keeps its historical field name even though the value now comes from the
  # manifest's remote default branch.
  def test_trunk_override_rev_parses_and_checks_ancestry_against_the_manifests_remote_default_branch
    other = manifest_with(FIXTURE, "repo" => { "default_branch" => "trunk" })

    porcelain = <<~TXT
      worktree #{MAIN}
      HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      branch refs/heads/main

      worktree #{WT1}
      HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      branch refs/heads/zz-abc-current-thing
    TXT

    @fake.expect(%w[git worktree list --porcelain], out: porcelain)
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/trunk HEAD], exitstatus: 0)
    @fake.expect(%w[bd show zz-abc --json], out: '[{"id":"zz-abc","labels":[]}]')
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "zz-abc-current-thing",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: "null\n"
    )

    @fake.expect(%w[git fetch origin], out: "")
    @fake.expect(%w[git rev-parse origin/trunk], out: "deadbeef\n")
    @fake.expect(%w[git merge-base --is-ancestor origin/trunk HEAD], exitstatus: 0)

    io = StringIO.new
    code = nil
    with_manifest(other) { code = WorktreeRefresh.run([], io: io) }
    env = JSON.parse(io.string)

    assert_equal 0, code
    assert_equal "deadbeef", env["data"]["origin_main"]
    wt1 = env["data"]["results"].find { |r| r["path"] == WT1 }
    assert_equal "current, skipped", wt1["result"]
  end
end

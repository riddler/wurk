# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../pr_state"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"

class PrStateTest < Minitest::Test
  include ManifestHelper

  FIXTURE = "worktree"

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
  end

  def run_pr_state(argv, fixture: FIXTURE)
    io = StringIO.new
    code = nil
    with_manifest(fixture) { code = PrState.run(argv, io: io) }
    [code, JSON.parse(io.string)]
  end

  # Item 8 of wurk's coupling inventory: `gitlab` is a legal manifest value
  # and an illegal state for this script, and half-working is the failure
  # mode to avoid - a `gh` call against a GitLab repo fails with an
  # authentication message that sends the reader nowhere useful.
  #
  # sabotage: drop the Forge.guard! call from pr_state.rb -> gh is called
  # and FakeSh raises UnexpectedCommand -> red
  def test_a_gitlab_repo_blocks_clearly_rather_than_calling_gh
    code, env = run_pr_state(["zz-abc-x"], fixture: "forge_gitlab")

    assert_equal 1, code
    assert_equal "unsupported_forge", env["blocked"].first["code"]
    assert_match(/gitlab/, env["blocked"].first["message"])
    assert_empty @fake.calls
  end

  def test_merged_branch_reports_merged_true_with_pr_fields
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "zz-abc-x",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: %({"number":41,"mergedAt":"2026-08-01T00:00:00Z","headRefOid":"deadbeef"}\n)
    )

    code, env = run_pr_state(["zz-abc-x"])

    assert_equal 0, code
    assert_equal true, env["ok"]
    assert_equal true, env["data"]["merged"]
    assert_equal 41, env["data"]["number"]
    assert_equal "deadbeef", env["data"]["head_oid"]
    assert_equal "2026-08-01T00:00:00Z", env["data"]["merged_at"]
  end

  def test_unmerged_branch_reports_merged_false
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "zz-abc-x",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: "null\n"
    )

    code, env = run_pr_state(["zz-abc-x"])

    assert_equal 0, code
    assert_equal false, env["data"]["merged"]
    refute env["data"].key?("number")
  end

  def test_gh_failure_blocks_needs_human_never_falls_back_to_ancestry
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "zz-abc-x",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      exitstatus: 1, err: "gh: authentication required\n"
    )

    code, env = run_pr_state(["zz-abc-x"])

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "forge_unavailable", env["blocked"].first["code"]
    assert_equal "human", env["blocked"].first["needs"]
    # No merge-base/ancestry call was ever attempted: FakeSh would have
    # raised UnexpectedCommand had the script tried one as a fallback.
  end

  def test_beads_subcommand_extracts_via_refs_anchor
    @fake.expect(
      ["gh", "pr", "view", "41", "--json", "commits", "--jq", ".commits[].messageBody"],
      out: "Adds thing.\n\nRefs: zz-abc\n" \
           "Fixes other thing, related to zz-zzz but no trailer here.\n"
    )

    code, env = run_pr_state(%w[beads 41])

    assert_equal 0, code
    assert_equal ["zz-abc"], env["data"]["beads"]
  end

  def test_beads_subcommand_gh_failure_blocks_needs_human
    @fake.expect(
      ["gh", "pr", "view", "41", "--json", "commits", "--jq", ".commits[].messageBody"],
      exitstatus: 1, err: "gh: not found\n"
    )

    code, env = run_pr_state(%w[beads 41])

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "forge_unavailable", env["blocked"].first["code"]
    assert_equal "human", env["blocked"].first["needs"]
  end
end

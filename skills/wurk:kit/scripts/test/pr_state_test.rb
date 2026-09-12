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

  # Item 8 of wurk's coupling inventory: a forge kind this script has no
  # adapter for must stop here, because half-working is the failure mode to
  # avoid - a `gh` call against a repo on another forge fails with an
  # authentication message that sends the reader nowhere useful. Both kinds
  # the manifest schema accepts now have an adapter, so the list is narrowed
  # to make that path reachable; the forge after these arrives into this test,
  # not into a regression.
  #
  # sabotage: drop the Forge.guard! call from pr_state.rb -> gh is called
  # and FakeSh raises UnexpectedCommand -> red
  def test_an_unimplemented_forge_blocks_clearly_rather_than_calling_a_forge_cli
    code, env = Forge.with_implemented(%w[github]) do
      run_pr_state(["zz-abc-x"], fixture: "forge_gitlab")
    end

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

  # --- the gitlab adapter -------------------------------------------------
  #
  # Every shape below is the one the research verified live against
  # gitlab.com (docs/research/260817-wu-mya.2-gitlab-merged-request-
  # detection.md): the raw REST field names, the array-on-empty, the error
  # object with a non-zero exit, the fork whose source branch shares a name,
  # and the several merged requests on one long-lived branch.

  GITLAB_FIXTURE = "forge_gitlab"

  LIST_ARGV = ["glab", "mr", "list", "--merged", "--source-branch", "zz-abc-x", "--output", "json"].freeze

  COMMITS_ARGV = ["glab", "api", "--paginate", "projects/:id/merge_requests/41/commits"].freeze

  # The subset of the 48-key payload this adapter reads, plus the two
  # project ids the fork filter compares.
  def request_json(iid:, merged_at:, sha:, state: Forge::REQUEST_MERGED, source_project: 7, target_project: 7)
    {
      "iid" => iid, "state" => state, "merged_at" => merged_at, "sha" => sha,
      "source_branch" => "zz-abc-x", "source_project_id" => source_project,
      "target_project_id" => target_project
    }
  end

  def run_gitlab(argv)
    run_pr_state(argv, fixture: GITLAB_FIXTURE)
  end

  def test_gitlab_merged_request_reports_merged_true_from_the_rest_field_names
    @fake.expect(LIST_ARGV, out: JSON.generate([
      request_json(iid: 3720, merged_at: "2026-08-17T14:16:10.149Z", sha: "4f971f47")
    ]))

    code, env = run_gitlab(["zz-abc-x"])

    assert_equal 0, code
    assert_equal true, env["data"]["merged"]
    assert_equal 3720, env["data"]["number"]
    assert_equal "2026-08-17T14:16:10.149Z", env["data"]["merged_at"]
    assert_equal "4f971f47", env["data"]["head_oid"]
  end

  # The empty result is an empty array, not the null the GitHub adapter gets
  # from its server-side filter.
  def test_gitlab_no_request_reports_merged_false
    @fake.expect(LIST_ARGV, out: "[]\n")

    code, env = run_gitlab(["zz-abc-x"])

    assert_equal 0, code
    assert_equal false, env["data"]["merged"]
    refute env["data"].key?("number")
  end

  # A request that is not merged is not a merged request even if it reaches
  # the adapter: the state comparison is the signal, never the presence of a
  # row, and never a merge commit (empty string under fast-forward merges).
  def test_gitlab_unmerged_request_reports_merged_false
    @fake.expect(LIST_ARGV, out: JSON.generate([
      request_json(iid: 3721, merged_at: nil, sha: "abc", state: "opened")
    ]))

    code, env = run_gitlab(["zz-abc-x"])

    assert_equal 0, code
    assert_equal false, env["data"]["merged"]
  end

  # The source-branch filter matches the branch NAME in any project, so a
  # fork request named like the local branch is a false positive. It is
  # discarded on the project-id mismatch, and the local branch is reported
  # unmerged rather than swept up by a stranger request.
  #
  # sabotage: drop the same_project? filter -> merged true, iid 3708 -> red
  def test_gitlab_fork_sourced_request_is_discarded_on_project_id_mismatch
    @fake.expect(LIST_ARGV, out: JSON.generate([
      request_json(iid: 3708, merged_at: "2026-08-17T00:00:00.000Z", sha: "fork",
                   source_project: 85_318_062, target_project: 34_675_721)
    ]))

    code, env = run_gitlab(["zz-abc-x"])

    assert_equal 0, code
    assert_equal false, env["data"]["merged"]
  end

  # A missing project id is not evidence of a fork, and reporting a merged
  # request as unmerged is the one error this script must never make.
  def test_gitlab_request_without_project_ids_is_kept
    @fake.expect(LIST_ARGV, out: JSON.generate([
      request_json(iid: 9, merged_at: "2026-08-17T00:00:00.000Z", sha: "abc",
                   source_project: nil, target_project: nil)
    ]))

    _code, env = run_gitlab(["zz-abc-x"])

    assert_equal true, env["data"]["merged"]
  end

  # Machine output is written on failure too - an error object where the
  # success shape is an array - with a non-zero exit. Success is read off
  # the exit status, so this is "unknown", never "not merged", and never a
  # fall back to git ancestry (FakeSh would raise on the merge-base call).
  def test_gitlab_error_object_with_nonzero_exit_reports_unavailable
    @fake.expect(LIST_ARGV, exitstatus: 1,
                 out: %({"error":{"message":"404 Not Found"}}\n),
                 err: "404 Not Found\n")

    code, env = run_gitlab(["zz-abc-x"])

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "forge_unavailable", env["blocked"].first["code"]
    assert_equal "human", env["blocked"].first["needs"]
  end

  # An error object on a ZERO exit would be the same wrong shape without the
  # exit status to catch it. The adapter checks the shape as well, because
  # the alternative is a NoMethodError deep in the selection pass.
  def test_gitlab_unexpected_output_shape_reports_unavailable
    @fake.expect(LIST_ARGV, out: %({"error":{"message":"418"}}\n))

    code, env = run_gitlab(["zz-abc-x"])

    assert_equal 1, code
    assert_equal "forge_unavailable", env["blocked"].first["code"]
  end

  # The recorded decision: greatest merged_at wins, not the first element.
  # The list arrives newest-CREATED first, so the fixture puts the request
  # that was opened last but merged first at the head - the shape a shared
  # renovate-style branch produces, and the one .[0] gets wrong.
  #
  # sabotage: select .first instead of max_by(merged_at) -> iid 40 -> red
  def test_gitlab_several_merged_requests_resolve_to_the_latest_merged_at
    @fake.expect(LIST_ARGV, out: JSON.generate([
      request_json(iid: 40, merged_at: "2026-08-10T09:00:00.000Z", sha: "older"),
      request_json(iid: 39, merged_at: "2026-08-17T09:00:00.000Z", sha: "newest"),
      request_json(iid: 38, merged_at: "2026-08-01T09:00:00.000Z", sha: "oldest"),
      request_json(iid: 37, merged_at: "2026-08-18T09:00:00.000Z", sha: "fork",
                   source_project: 85_318_062, target_project: 34_675_721)
    ]))

    code, env = run_gitlab(["zz-abc-x"])

    assert_equal 0, code
    assert_equal 39, env["data"]["number"]
    assert_equal "newest", env["data"]["head_oid"]
  end

  # The commits request carries the pagination flag and no server-side
  # filter, so the messages are mapped in Ruby. Paginated pages arrive
  # concatenated into one array, which is what this fixture is: more rows
  # than one default page would hold.
  #
  # sabotage: drop --paginate from the argv -> FakeSh raises
  # UnexpectedCommand -> red
  def test_gitlab_beads_subcommand_reads_paginated_commits_via_refs_anchor
    commits = (1..25).map do |n|
      { "id" => format("%040d", n), "title" => "Step #{n}",
        "message" => "Step #{n}.\n\nRefs: zz-abc\n", "trailers" => {} }
    end
    commits << { "id" => "f" * 40, "title" => "Last",
                 "message" => "Last step.\n\nRefs: zz-xyz\n", "trailers" => {} }
    @fake.expect(COMMITS_ARGV, out: JSON.generate(commits))

    code, env = run_gitlab(%w[beads 41])

    assert_equal 0, code
    assert_equal %w[zz-abc zz-xyz], env["data"]["beads"]
  end

  def test_gitlab_beads_subcommand_failure_blocks_needs_human
    @fake.expect(COMMITS_ARGV, exitstatus: 1, err: "404 Not Found\n")

    code, env = run_gitlab(%w[beads 41])

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "forge_unavailable", env["blocked"].first["code"]
    assert_equal "human", env["blocked"].first["needs"]
  end
end

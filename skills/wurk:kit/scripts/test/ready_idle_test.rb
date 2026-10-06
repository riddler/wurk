# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../ready_idle"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"

class ReadyIdleTest < Minitest::Test
  include ManifestHelper

  FIXTURE = "worktree"            # forge.kind github, no ready_idle_hours
  GITLAB_FIXTURE = "forge_gitlab"

  NOW = Time.iso8601("2026-10-06T12:00:00Z")
  FIVE_HOURS_AGO = "2026-10-06T07:00:00Z"
  THIRTY_MINUTES_AGO = "2026-10-06T11:30:00Z"

  FETCH = %w[git fetch origin].freeze
  GITHUB_LIST = %w[gh pr list].freeze
  REV_LIST = %w[git rev-list --count].freeze
  GITLAB_LIST = ["glab", "api", "--paginate", "projects/:id/merge_requests?state=opened"].freeze

  GREEN_ROLLUP = [
    { "__typename" => "CheckRun", "status" => "COMPLETED", "conclusion" => "SUCCESS" },
    { "__typename" => "StatusContext", "state" => "SUCCESS" }
  ].freeze

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
  end

  def run_ready_idle(argv, fixture: FIXTURE)
    io = StringIO.new
    code = nil
    with_manifest(fixture) { code = ReadyIdle.run(argv, io: io, now: NOW) }
    [code, JSON.parse(io.string)]
  end

  # One GitHub request as `gh pr list --json` prints it, green and idle by
  # default; a test overrides the one field it is about.
  def github_request(number: 7, overrides: {})
    {
      "number" => number, "title" => "Adds the thing", "headRefName" => "zz-abc-thing",
      "headRefOid" => "abc123", "isDraft" => false, "mergeable" => "MERGEABLE",
      "reviewDecision" => "", "statusCheckRollup" => GREEN_ROLLUP, "updatedAt" => FIVE_HOURS_AGO
    }.merge(overrides)
  end

  def expect_github_list(*requests)
    @fake.expect(GITHUB_LIST, out: JSON.generate(requests))
  end

  def skipped_reason(env, number)
    entry = env["data"]["skipped"].find { |s| s["number"] == number }
    entry && entry["reason"]
  end

  # --- the row -------------------------------------------------------------

  # sabotage: drop the `rows` from data.ready (always []) -> red
  def test_green_unblocked_idle_request_is_one_row_with_hours_idle_and_behind
    @fake.expect(FETCH)
    expect_github_list(github_request)
    @fake.expect(REV_LIST, out: "4\n")

    code, env = run_ready_idle([])

    assert_equal 0, code
    assert_equal true, env["data"]["scan_complete"]
    assert_equal 1, env["data"]["ready"].length
    row = env["data"]["ready"].first
    assert_equal 7, row["number"]
    assert_equal "Adds the thing", row["title"]
    assert_equal "zz-abc-thing", row["branch"]
    assert_equal "abc123", row["head"]
    assert_equal 5.0, row["hours_idle"]
    assert_equal 4, row["behind"]
    assert_equal "success", row["pipeline"]
    assert_equal false, row["drift_lower_bound"]
    assert_equal true, env["data"]["fetched"]
    assert_equal "github", env["data"]["forge"]
    assert_equal "main", env["data"]["default_branch"]
    assert_empty env["data"]["skipped"]
    assert_equal ["git", "rev-list", "--count", "abc123..origin/main"], @fake.calls.last.argv
    @fake.verify!
  end

  def test_rows_are_sorted_most_idle_first
    @fake.expect(FETCH)
    expect_github_list(github_request(number: 1),
                       github_request(number: 2, overrides: { "updatedAt" => "2026-10-05T12:00:00Z" }))
    @fake.expect(REV_LIST, out: "0\n")
    @fake.expect(REV_LIST, out: "0\n")

    _code, env = run_ready_idle([])

    assert_equal [2, 1], env["data"]["ready"].map { |row| row["number"] }
    assert_equal 24.0, env["data"]["ready"].first["hours_idle"]
  end

  # --- disqualifiers -------------------------------------------------------

  # The rev-list answer is registered so that a sabotaged run reaches the
  # assertions rather than stopping on FakeSh's unexpected-command error.
  #
  # sabotage: ignore request.draft in cheap_disqualifier -> one row, no
  # "draft" skip -> red on the ready assertion
  def test_draft_request_yields_no_row
    @fake.expect(FETCH)
    expect_github_list(github_request(overrides: { "isDraft" => true }))
    @fake.expect(REV_LIST, out: "0\n")

    code, env = run_ready_idle([])

    assert_equal 0, code
    assert_equal [], env["data"]["ready"]
    assert_equal "draft", skipped_reason(env, 7)
  end

  # sabotage: compare mergeable against "MERGEABLE" for conflict -> red
  def test_conflicted_request_yields_no_row
    @fake.expect(FETCH)
    expect_github_list(github_request(overrides: { "mergeable" => "CONFLICTING" }))

    _code, env = run_ready_idle([])

    assert_equal [], env["data"]["ready"]
    assert_equal "conflict", skipped_reason(env, 7)
  end

  def test_unknown_mergeability_yields_no_row
    @fake.expect(FETCH)
    expect_github_list(github_request(overrides: { "mergeable" => "UNKNOWN" }))

    _code, env = run_ready_idle([])

    assert_equal [], env["data"]["ready"]
    assert_equal "mergeability_unknown", skipped_reason(env, 7)
  end

  # sabotage: drop the PIPELINE_FAILED return in pipeline_from_rollup -> the
  # failing check is outranked by nothing and reads green -> red
  def test_red_request_yields_no_row
    @fake.expect(FETCH)
    expect_github_list(github_request(overrides: { "statusCheckRollup" => [
      { "__typename" => "CheckRun", "status" => "COMPLETED", "conclusion" => "SUCCESS" },
      { "__typename" => "CheckRun", "status" => "COMPLETED", "conclusion" => "FAILURE" }
    ] }))

    _code, env = run_ready_idle([])

    assert_equal [], env["data"]["ready"]
    assert_equal "pipeline_failed", skipped_reason(env, 7)
  end

  def test_running_checks_yield_no_row
    @fake.expect(FETCH)
    expect_github_list(github_request(overrides: { "statusCheckRollup" => [
      { "__typename" => "CheckRun", "status" => "IN_PROGRESS", "conclusion" => nil },
      { "__typename" => "StatusContext", "state" => "SUCCESS" }
    ] }))

    _code, env = run_ready_idle([])

    assert_equal "pipeline_running", skipped_reason(env, 7)
  end

  # sabotage: map an empty rollup to PIPELINE_SUCCESS -> a row -> red
  def test_request_with_no_checks_is_not_green
    @fake.expect(FETCH)
    expect_github_list(github_request(overrides: { "statusCheckRollup" => [] }))

    _code, env = run_ready_idle([])

    assert_equal [], env["data"]["ready"]
    assert_equal "no_pipeline", skipped_reason(env, 7)
  end

  # sabotage: drop the not_idle check -> a row -> red
  def test_not_yet_idle_request_yields_no_row
    @fake.expect(FETCH)
    expect_github_list(github_request(overrides: { "updatedAt" => THIRTY_MINUTES_AGO }))

    _code, env = run_ready_idle([])

    assert_equal [], env["data"]["ready"]
    assert_equal "not_idle", skipped_reason(env, 7)
  end

  # sabotage: drop the review_blocked check -> a row -> red
  def test_changes_requested_yields_no_row
    @fake.expect(FETCH)
    expect_github_list(github_request(overrides: { "reviewDecision" => "CHANGES_REQUESTED" }))

    _code, env = run_ready_idle([])

    assert_equal [], env["data"]["ready"]
    assert_equal "review_blocked", skipped_reason(env, 7)
  end

  # --- a scan that could not finish ----------------------------------------

  # The never-empty rule: a failed forge read is not "nothing is waiting".
  #
  # sabotage: set data.ready = [] in the scan_incomplete rescue -> the key is
  # present -> red
  def test_failed_forge_read_blocks_with_ready_absent_never_empty
    @fake.expect(FETCH)
    @fake.expect(GITHUB_LIST, exitstatus: 1, err: "gh: authentication required\n")

    code, env = run_ready_idle([])

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal false, env["data"]["scan_complete"]
    refute env["data"].key?("ready"), "data.ready must be absent on an incomplete scan, never []"
    refute env["data"].key?("skipped")
    blocked = env["blocked"].first
    assert_equal "scan_incomplete", blocked["code"]
    assert_match(/authentication required/, blocked["message"])
    assert_match(/not read this as zero/, blocked["message"])
  end

  def test_unparseable_forge_output_blocks_with_ready_absent
    @fake.expect(FETCH)
    @fake.expect(GITHUB_LIST, out: "not json")

    code, env = run_ready_idle([])

    assert_equal 1, code
    refute env["data"].key?("ready")
    assert_equal "scan_incomplete", env["blocked"].first["code"]
  end

  # sabotage: drop the GITHUB_LIST_LIMIT check -> a complete scan -> red
  def test_a_list_at_the_limit_is_treated_as_possibly_truncated
    @fake.expect(FETCH)
    requests = (1..ReadyIdle::GITHUB_LIST_LIMIT).map { |n| github_request(number: n, overrides: { "isDraft" => true }) }
    expect_github_list(*requests)

    code, env = run_ready_idle([])

    assert_equal 1, code
    refute env["data"].key?("ready")
    assert_match(/truncated/, env["blocked"].first["message"])
  end

  # --- drift --------------------------------------------------------------

  # sabotage: return true from fetch_origin on failure -> drift_lower_bound
  # false and no warning -> red
  def test_fetch_that_cannot_reach_origin_marks_drift_lower_bound_and_warns
    @fake.expect(FETCH, exitstatus: 128, err: "fatal: unable to access origin\n")
    expect_github_list(github_request)
    @fake.expect(REV_LIST, out: "2\n")

    code, env = run_ready_idle([])

    assert_equal 0, code
    assert_equal false, env["data"]["fetched"]
    assert_equal true, env["data"]["ready"].first["drift_lower_bound"]
    assert_equal 2, env["data"]["ready"].first["behind"]
    warning = env["warnings"].find { |w| w["code"] == "fetch_failed" }
    refute_nil warning
    assert_match(/lower bound/, warning["message"])
  end

  def test_no_fetch_skips_the_fetch_and_marks_drift_lower_bound
    expect_github_list(github_request)
    @fake.expect(REV_LIST, out: "0\n")

    _code, env = run_ready_idle(["--no-fetch"])

    refute(@fake.calls.any? { |c| c.argv[0, 2] == %w[git fetch] })
    assert_equal true, env["data"]["ready"].first["drift_lower_bound"]
    assert(env["warnings"].any? { |w| w["code"] == "fetch_skipped" })
  end

  # A dry run records the fetch and does not run it; the reads still run.
  def test_dry_run_records_the_fetch_without_running_it
    expect_github_list(github_request)
    @fake.expect(REV_LIST, out: "0\n")

    code, env = run_ready_idle(["--dry-run"])

    assert_equal 0, code
    refute(@fake.calls.any? { |c| c.argv[0, 2] == %w[git fetch] })
    assert_includes env["commands"], "git fetch origin"
    assert_equal true, env["data"]["ready"].first["drift_lower_bound"]
    assert(env["warnings"].any? { |w| w["code"] == "fetch_skipped" })
  end

  def test_head_missing_locally_reports_null_behind_and_warns
    @fake.expect(FETCH)
    expect_github_list(github_request)
    @fake.expect(REV_LIST, exitstatus: 128, err: "fatal: bad revision\n")

    code, env = run_ready_idle([])

    assert_equal 0, code
    row = env["data"]["ready"].first
    assert_nil row["behind"]
    assert_equal true, row["drift_lower_bound"]
    assert(env["warnings"].any? { |w| w["code"] == "drift_unknown" && w["message"].include?("7") })
  end

  # --- the threshold ------------------------------------------------------

  def test_default_threshold_is_two_hours
    @fake.expect(FETCH)
    expect_github_list

    _code, env = run_ready_idle([])

    assert_equal 2.0, env["data"]["idle_hours"]
    assert_equal "default", env["data"]["idle_hours_source"]
  end

  # sabotage: ignore manifest.ready_idle_hours in resolve_threshold -> the
  # 2.0 default lists the five-hour request -> red
  def test_manifest_key_sets_the_threshold
    @fake.expect(FETCH)
    expect_github_list(github_request)
    manifest = manifest_with(FIXTURE, "forge" => { "ready_idle_hours" => 6 })

    _code, env = run_ready_idle([], fixture: manifest)

    assert_equal 6.0, env["data"]["idle_hours"]
    assert_equal "manifest", env["data"]["idle_hours_source"]
    assert_equal [], env["data"]["ready"]
    assert_equal "not_idle", skipped_reason(env, 7)
  end

  # sabotage: let the manifest win over the flag -> six hours, no row -> red
  def test_flag_overrides_the_manifest_key
    @fake.expect(FETCH)
    expect_github_list(github_request)
    @fake.expect(REV_LIST, out: "0\n")
    manifest = manifest_with(FIXTURE, "forge" => { "ready_idle_hours" => 6 })

    _code, env = run_ready_idle(["--idle-hours", "4.5"], fixture: manifest)

    assert_equal 4.5, env["data"]["idle_hours"]
    assert_equal "flag", env["data"]["idle_hours_source"]
    assert_equal [7], env["data"]["ready"].map { |row| row["number"] }
  end

  def test_bad_idle_hours_is_a_usage_error
    ["abc", "0", "-2"].each do |value|
      io = StringIO.new
      exc = nil
      capture_io do
        exc = assert_raises(SystemExit) do
          with_manifest(FIXTURE) { ReadyIdle.run(["--idle-hours", value], io: io, now: NOW) }
        end
      end
      assert_equal 2, exc.status, "--idle-hours #{value} should exit 2"
      assert_empty io.string, "a usage error prints no envelope"
      assert_empty @fake.calls
    end
  end

  # --- --repo -------------------------------------------------------------

  def test_repo_is_the_working_directory_of_every_shell_out
    Dir.mktmpdir do |dir|
      @fake.expect(FETCH)
      expect_github_list(github_request)
      @fake.expect(REV_LIST, out: "0\n")

      code, _env = run_ready_idle(["--repo", dir])

      assert_equal 0, code
      assert_equal [dir], @fake.calls.map(&:chdir).uniq
    end
  end

  # --- forge guard --------------------------------------------------------

  # sabotage: drop the Forge.guard! call -> gh is called and FakeSh raises
  # UnexpectedCommand -> red
  def test_unsupported_forge_blocks_without_calling_a_forge_cli
    code, env = Forge.with_implemented(%w[github]) do
      run_ready_idle([], fixture: GITLAB_FIXTURE)
    end

    assert_equal 1, code
    assert_equal "unsupported_forge", env["blocked"].first["code"]
    assert_equal false, env["data"]["scan_complete"]
    refute env["data"].key?("ready")
    assert_empty @fake.calls
  end

  # --- the gitlab adapter -------------------------------------------------

  def gitlab_request(iid: 12, overrides: {})
    {
      "iid" => iid, "title" => "Adds the other thing", "source_branch" => "zz-def-other",
      "sha" => "def456", "draft" => false, "work_in_progress" => false, "has_conflicts" => false,
      "detailed_merge_status" => "mergeable", "updated_at" => "2026-10-06T07:00:00.000Z"
    }.merge(overrides)
  end

  def expect_gitlab_detail(iid, head_pipeline:, exitstatus: 0)
    @fake.expect(["glab", "api", "projects/:id/merge_requests/#{iid}"],
                 out: JSON.generate("iid" => iid, "head_pipeline" => head_pipeline), exitstatus: exitstatus)
  end

  # sabotage: read the pipeline as success without the per-request call ->
  # FakeSh's unconsumed expectation fails verify! -> red
  def test_gitlab_green_idle_request_is_one_row
    @fake.expect(FETCH)
    @fake.expect(GITLAB_LIST, out: JSON.generate([gitlab_request]))
    expect_gitlab_detail(12, head_pipeline: { "status" => "success" })
    @fake.expect(REV_LIST, out: "3\n")

    code, env = run_ready_idle([], fixture: GITLAB_FIXTURE)

    assert_equal 0, code
    assert_equal "gitlab", env["data"]["forge"]
    row = env["data"]["ready"].first
    assert_equal 12, row["number"]
    assert_equal "zz-def-other", row["branch"]
    assert_equal "def456", row["head"]
    assert_equal 5.0, row["hours_idle"]
    assert_equal 3, row["behind"]
    @fake.verify!
  end

  # The pipeline is read only for requests the list payload did not already
  # rule out: a draft costs no per-request call (FakeSh would raise on one).
  def test_gitlab_disqualifiers_skip_the_pipeline_read
    @fake.expect(FETCH)
    @fake.expect(GITLAB_LIST, out: JSON.generate([
      gitlab_request(iid: 1, overrides: { "draft" => true }),
      gitlab_request(iid: 2, overrides: { "has_conflicts" => true }),
      gitlab_request(iid: 3, overrides: { "detailed_merge_status" => "requested_changes" })
    ]))

    _code, env = run_ready_idle([], fixture: GITLAB_FIXTURE)

    assert_equal %w[draft conflict review_blocked], [1, 2, 3].map { |n| skipped_reason(env, n) }
  end

  def test_gitlab_missing_and_failed_pipelines_yield_no_row
    @fake.expect(FETCH)
    @fake.expect(GITLAB_LIST, out: JSON.generate([gitlab_request(iid: 1), gitlab_request(iid: 2)]))
    expect_gitlab_detail(1, head_pipeline: nil)
    expect_gitlab_detail(2, head_pipeline: { "status" => "failed" })

    _code, env = run_ready_idle([], fixture: GITLAB_FIXTURE)

    assert_equal [], env["data"]["ready"]
    assert_equal "no_pipeline", skipped_reason(env, 1)
    assert_equal "pipeline_failed", skipped_reason(env, 2)
  end

  # sabotage: treat a failed per-request read as "none" -> a complete scan
  # with an empty list -> red
  def test_gitlab_per_request_read_failure_makes_the_scan_incomplete
    @fake.expect(FETCH)
    @fake.expect(GITLAB_LIST, out: JSON.generate([gitlab_request]))
    expect_gitlab_detail(12, head_pipeline: nil, exitstatus: 1)

    code, env = run_ready_idle([], fixture: GITLAB_FIXTURE)

    assert_equal 1, code
    assert_equal false, env["data"]["scan_complete"]
    refute env["data"].key?("ready")
    assert_match(%r{merge_requests/12}, env["blocked"].first["message"])
  end

  # An error object on a zero exit is still not a list.
  def test_gitlab_error_object_blocks_with_ready_absent
    @fake.expect(FETCH)
    @fake.expect(GITLAB_LIST, out: %({"message":"401 Unauthorized"}))

    code, env = run_ready_idle([], fixture: GITLAB_FIXTURE)

    assert_equal 1, code
    refute env["data"].key?("ready")
    assert_equal "scan_incomplete", env["blocked"].first["code"]
  end
end

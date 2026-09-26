# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require "time"
require "open3"
require "rbconfig"
require_relative "../campaign_state"
require_relative "../lib/lock"
require_relative "support/home_guard"
require_relative "support/dead_pid"
require_relative "support/user_config_helper"

# Every fixture here is built in a tmpdir by the test itself. The kit's own
# campaign directory is live state for whatever campaign is running while
# this suite runs, and a test that pointed at it could disarm a campaign in
# flight - so no test ever reads or writes outside its own mktmpdir.
module CampaignFixtures
  FIXED_NOW = Time.new(2026, 9, 14, 20, 0, 0, "-06:00")

  def write_plan(dir, id, status: nil, body: nil, heading: "# Campaign #{id}")
    lines = [heading, ""]
    lines << "Status: #{status}" << "" if status
    lines << (body || default_body)
    path = File.join(dir, "#{id}.md")
    File.write(path, "#{lines.join("\n")}\n")
    path
  end

  def default_body
    <<~MD
      Single-repo campaign. This file carries the policy.

      ## Mode

      MR mode. Each bead ends in /wurk:mr with an open PR.

      ## Consent (verbatim, from the invocation)

          MR mode. Scope: epic zz-1 and zz-2.

      ## Scope

      In scope (2): zz-1 zz-2
      Explicitly out: every other open bead.

      ## Gate

      `make test` - SHORT GATE.
    MD
  end

  # Same shape as write_plan, with an optional Machine: line placed
  # directly under the Status line - the binding this phase's tests exist
  # to cover. write_plan itself is left untouched (additions only, per this
  # repo's rule for this file) rather than growing a new keyword.
  def write_plan_with_machine(dir, id, status:, machine:, body: nil, heading: "# Campaign #{id}")
    lines = [heading, "", "Status: #{status}", "Machine: #{machine}", "", (body || default_body)]
    path = File.join(dir, "#{id}.md")
    File.write(path, "#{lines.join("\n")}\n")
    path
  end

  # Same shape, but takes the whole Machine: line verbatim so a test can
  # write a malformed one (operator prose, a name with trailing prose)
  # that write_plan_with_machine's `machine:` keyword cannot produce.
  def write_plan_with_raw_machine_line(dir, id, status:, machine_line:, body: nil, heading: "# Campaign #{id}")
    lines = [heading, "", "Status: #{status}", machine_line, "", (body || default_body)]
    path = File.join(dir, "#{id}.md")
    File.write(path, "#{lines.join("\n")}\n")
    path
  end

  def write_consent(dir, id, status: "ADOPTED 2026-09-14 18:41 -0600")
    path = File.join(dir, "#{id}-consent.md")
    File.write(path, "# Campaign #{id} consent\n\nStatus: #{status}.\n\nPlan: `#{id}.md`.\n")
    path
  end

  def write_report(dir, id)
    File.write(File.join(dir, "#{id}-report.md"), "# Morning report - campaign #{id}\n\nAll done.\n")
  end

  def hold_mutex(dir, id, pid: Process.pid)
    Lock.try_acquire(File.join(dir, "locks", "campaign-#{id}"), "campaign" => id, "bead" => "zz-1", "pid" => pid.to_s)
  end
end

# CampaignState's pure functions: plan discovery, Status parsing, section
# extraction, and the Status-line rewrite. No CLI, no envelope.
class CampaignStateLibTest < Minitest::Test
  include CampaignFixtures

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # --- discovery ------------------------------------------------------------

  def test_a_plan_is_a_markdown_file_whose_h1_names_its_own_basename
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha")
    write_report(@dir, "260914-alpha")
    FileUtils.mkdir_p(File.join(@dir, "journal"))
    File.write(File.join(@dir, "journal", "260914-alpha.md"), "# Campaign 260914-alpha\n")
    File.write(File.join(@dir, "notes.md"), "# Some other document\n")

    plans = CampaignState.plan_paths(@dir)

    assert_equal [File.join(@dir, "260914-alpha.md")], plans
  end

  def test_a_file_whose_h1_names_a_different_id_is_not_a_plan
    File.write(File.join(@dir, "260914-copy.md"), "# Campaign 260914-alpha\n\nStatus: ARMED\n")

    assert_empty CampaignState.plan_paths(@dir)
  end

  def test_plan_paths_is_empty_for_a_missing_directory
    assert_empty CampaignState.plan_paths(File.join(@dir, "nope"))
  end

  def test_a_plan_may_be_headed_with_a_colon_after_campaign
    write_plan(@dir, "gitlab", status: "ARMED 2026-09-14 18:41 -0600", heading: "# Campaign: gitlab")

    plans = CampaignState.plan_paths(@dir)

    assert_equal [File.join(@dir, "gitlab.md")], plans
  end

  def test_a_consent_file_never_counts_as_a_plan_even_with_a_colon_heading
    write_plan(@dir, "gitlab", status: "ARMED 2026-09-14 18:41 -0600", heading: "# Campaign: gitlab")
    File.write(File.join(@dir, "gitlab-consent.md"), "# Campaign gitlab consent\n\nStatus: ADOPTED 2026-09-14.\n")

    plans = CampaignState.plan_paths(@dir)

    assert_equal [File.join(@dir, "gitlab.md")], plans
  end

  # --- unparsed_campaign_files -----------------------------------------------

  def test_unparsed_campaign_files_names_a_file_whose_h1_does_not_match_either_plan_form
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    File.write(File.join(@dir, "notes.md"), "# Some other document\n\nStatus: ARMED\n")

    unparsed = CampaignState.unparsed_campaign_files(@dir)

    assert_equal [File.join(@dir, "notes.md")], unparsed.map { |f| f[:path] }
    assert_match(/does not match/, unparsed.first[:reason])
    assert_equal "ARMED", unparsed.first[:status]
  end

  def test_unparsed_campaign_files_names_a_file_whose_h1_id_does_not_match_its_basename
    File.write(File.join(@dir, "260914-copy.md"), "# Campaign 260914-alpha\n\nStatus: ARMED\n")

    unparsed = CampaignState.unparsed_campaign_files(@dir)

    assert_equal [File.join(@dir, "260914-copy.md")], unparsed.map { |f| f[:path] }
    assert_match(/names "260914-alpha", not "260914-copy"/, unparsed.first[:reason])
  end

  def test_unparsed_campaign_files_excludes_a_recognized_plans_consent_and_report_companions
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha")
    write_report(@dir, "260914-alpha")

    assert_empty CampaignState.unparsed_campaign_files(@dir)
  end

  def test_unparsed_campaign_files_includes_a_queued_file
    File.write(File.join(@dir, "notes.md"), "# Some other document\n\nStatus: QUEUED 2026-09-14 after x\n")

    unparsed = CampaignState.unparsed_campaign_files(@dir)

    assert_equal [File.join(@dir, "notes.md")], unparsed.map { |f| f[:path] }
    assert_equal "QUEUED", unparsed.first[:status]
  end

  def test_unparsed_campaign_files_stays_silent_for_wrapped_drafted_or_no_status
    File.write(File.join(@dir, "wrapped.md"), "# Some other document\n\nStatus: WRAPPED 2026-09-14\n")
    File.write(File.join(@dir, "drafted.md"), "# Some other document\n\nStatus: DRAFTED 2026-09-14\n")
    File.write(File.join(@dir, "no-status.md"), "# Some other document\n\nJust prose.\n")

    assert_empty CampaignState.unparsed_campaign_files(@dir)
  end

  def test_unparsed_campaign_files_stays_silent_for_a_bad_h1_legacy_wrapped_plan
    File.write(File.join(@dir, "RF050-foo.md"), "# Campaign RF050 - description\n\nStatus: WRAPPED 2026-09-01\n")

    assert_empty CampaignState.unparsed_campaign_files(@dir)
  end

  # --- status parsing -------------------------------------------------------

  def test_parses_the_status_word_and_stamp_from_the_status_line
    content = "# Campaign x\n\nStatus: ARMED 2026-09-14 18:41 -0600 (consent adopted). More prose.\n"

    parsed = CampaignState.parse_status(content)

    assert_equal "ARMED", parsed[:status]
    assert_equal "2026-09-14 18:41 -0600", parsed[:stamp]
    assert_equal 3, parsed[:line]
  end

  def test_status_is_nil_when_no_status_line_exists
    parsed = CampaignState.parse_status("# Campaign x\n\nJust prose.\n")

    assert_nil parsed[:status]
    assert_nil parsed[:stamp]
    assert_nil parsed[:line]
  end

  def test_a_status_word_outside_the_known_vocabulary_is_reported_verbatim
    parsed = CampaignState.parse_status("# Campaign x\n\nStatus: PAUSED for now\n")

    assert_equal "PAUSED", parsed[:status]
    refute CampaignState.known_status?(parsed[:status])
  end

  def test_status_line_is_only_recognized_at_the_start_of_a_line
    content = "# Campaign x\n\nThe row reads Status: ARMED in the registry.\n\nStatus: DRAFTED\n"

    assert_equal "DRAFTED", CampaignState.parse_status(content)[:status]
  end

  # --- sections ---------------------------------------------------------------

  def test_extracts_a_named_h2_section_body_up_to_the_next_h2
    content = "# Campaign x\n\n## Mode\n\nMR mode.\n\n## Scope\n\nIn scope: zz-1\nOut: zz-9\n\n## Gate\n\nmake test\n"

    assert_equal "In scope: zz-1\nOut: zz-9", CampaignState.section(content, "Scope")
    assert_equal "MR mode.", CampaignState.section(content, "Mode")
  end

  def test_section_matches_the_heading_prefix_so_a_qualified_heading_still_hits
    content = "# Campaign x\n\n## Consent (verbatim, from the invocation)\n\n    MR mode.\n"

    assert_equal "    MR mode.", CampaignState.section(content, "Consent")
  end

  def test_section_is_nil_when_the_heading_is_absent
    assert_nil CampaignState.section("# Campaign x\n\nprose\n", "Scope")
  end

  # --- rewrite ------------------------------------------------------------------

  def test_rewrite_replaces_only_the_status_word_and_stamp_and_keeps_trailing_prose
    content = "# Campaign x\n\nStatus: DRAFTED 2026-09-13 (waiting on consent). Arming flips\nthis line.\n"

    rewritten = CampaignState.rewrite_status(content, "ARMED", now: FIXED_NOW)

    assert_equal "# Campaign x\n\nStatus: ARMED 2026-09-14 20:00 -0600 (waiting on consent). Arming flips\nthis line.\n", rewritten
  end

  def test_rewrite_inserts_a_status_line_after_the_h1_when_none_exists
    content = "# Campaign x\n\nSingle-repo campaign.\n\n## Scope\n"

    rewritten = CampaignState.rewrite_status(content, "ARMED", now: FIXED_NOW)

    assert_equal "# Campaign x\n\nStatus: ARMED 2026-09-14 20:00 -0600\n\nSingle-repo campaign.\n\n## Scope\n", rewritten
  end

  def test_rewrite_inserts_at_the_top_when_there_is_no_h1
    rewritten = CampaignState.rewrite_status("prose only\n", "DRAFTED", now: FIXED_NOW)

    assert_equal "Status: DRAFTED 2026-09-14 20:00 -0600\n\nprose only\n", rewritten
  end
end

# CampaignStateCli: list / show / arm / disarm through the envelope.
class CampaignStateCliTest < Minitest::Test
  include CampaignFixtures

  def setup
    @dir = Dir.mktmpdir
    @previous_clock = CampaignState.clock
    CampaignState.clock = -> { FIXED_NOW }
  end

  def teardown
    CampaignState.clock = @previous_clock
    FileUtils.remove_entry(@dir)
  end

  def run_cli(argv)
    io = StringIO.new
    code = CampaignStateCli.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  def plan_path(id)
    File.join(@dir, "#{id}.md")
  end

  # --- list ---------------------------------------------------------------------

  def test_list_reports_an_armed_campaign_with_adopted_consent_as_runnable
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600 (consent adopted)")
    write_consent(@dir, "260914-alpha")

    code, env = run_cli(["list", "--dir", @dir])

    assert_equal 0, code
    assert env["ok"]
    assert_equal "campaign_state", env["script"]
    assert_equal [@dir], env["data"]["dirs"]
    assert_equal ["260914-alpha"], env["data"]["runnable"]
    campaign = env["data"]["campaigns"].fetch(0)
    assert_equal "260914-alpha", campaign["id"]
    assert_equal plan_path("260914-alpha"), campaign["path"]
    assert_equal "ARMED", campaign["status"]
    assert_equal "2026-09-14 18:41 -0600", campaign["status_stamp"]
    assert campaign["armed"]
    refute campaign["running"]
    assert campaign["runnable"]
    assert_equal "In scope (2): zz-1 zz-2\nExplicitly out: every other open bead.", campaign["scope"]
    assert_equal "MR mode. Each bead ends in /wurk:mr with an open PR.", campaign["mode"]
    assert campaign["consent"]["exists"]
    assert_equal "ADOPTED", campaign["consent"]["status"]
    assert_equal File.join(@dir, "260914-alpha-consent.md"), campaign["consent"]["path"]
    refute campaign["mutex"]["held"]
    assert_equal File.join(@dir, "locks", "campaign-260914-alpha"), campaign["mutex"]["dir"]
  end

  def test_list_reports_an_unarmed_campaign_as_not_runnable
    write_plan(@dir, "260914-beta", status: "DRAFTED 2026-09-14")
    write_consent(@dir, "260914-beta")

    _code, env = run_cli(["list", "--dir", @dir])

    campaign = env["data"]["campaigns"].fetch(0)
    assert_equal "DRAFTED", campaign["status"]
    refute campaign["armed"]
    refute campaign["runnable"]
    assert_empty env["data"]["runnable"]
  end

  def test_list_treats_a_plan_with_no_status_line_as_drafted
    write_plan(@dir, "260910-legacy")

    _code, env = run_cli(["list", "--dir", @dir])

    campaign = env["data"]["campaigns"].fetch(0)
    assert_nil campaign["status"]
    refute campaign["armed"]
    refute campaign["runnable"]
  end

  def test_list_reports_a_running_campaign_via_the_held_mutex_and_excludes_it_from_runnable
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha")
    hold_mutex(@dir, "260914-alpha")

    _code, env = run_cli(["list", "--dir", @dir])

    campaign = env["data"]["campaigns"].fetch(0)
    assert campaign["armed"]
    assert campaign["running"]
    refute campaign["runnable"]
    assert campaign["mutex"]["held"]
    assert_equal "260914-alpha", campaign["mutex"]["owner"]["campaign"]
    assert_equal Process.pid.to_s, campaign["mutex"]["owner"]["pid"]
    assert_equal true, campaign["mutex"]["holder_alive"]
    refute campaign["mutex"]["stale"]
    assert_empty env["data"]["runnable"]
  end

  def test_list_does_not_count_a_provably_stale_mutex_as_running
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha")
    hold_mutex(@dir, "260914-alpha", pid: dead_pid)

    _code, env = run_cli(["list", "--dir", @dir])

    campaign = env["data"]["campaigns"].fetch(0)
    assert campaign["mutex"]["held"]
    assert campaign["mutex"]["stale"]
    assert_equal "dead_holder_pid", campaign["mutex"]["staleness_reason"]
    refute campaign["running"]
    assert campaign["runnable"]
    assert_equal ["260914-alpha"], env["data"]["runnable"]
    assert_equal ["stale_mutex"], env["warnings"].map { |w| w["code"] }
  end

  def test_list_reports_a_missing_consent_file_and_keeps_the_campaign_out_of_runnable
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")

    _code, env = run_cli(["list", "--dir", @dir])

    campaign = env["data"]["campaigns"].fetch(0)
    assert campaign["armed"]
    refute campaign["consent"]["exists"]
    assert_nil campaign["consent"]["status"]
    assert_equal File.join(@dir, "260914-alpha-consent.md"), campaign["consent"]["path"]
    refute campaign["runnable"]
    assert_equal ["consent_missing"], env["warnings"].map { |w| w["code"] }
  end

  def test_list_keeps_a_campaign_whose_consent_is_only_drafted_out_of_runnable
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha", status: "DRAFTED 2026-09-14")

    _code, env = run_cli(["list", "--dir", @dir])

    campaign = env["data"]["campaigns"].fetch(0)
    assert_equal "DRAFTED", campaign["consent"]["status"]
    refute campaign["runnable"]
  end

  def test_list_recognizes_a_plan_headed_with_a_colon
    write_plan(@dir, "gitlab", status: "ARMED 2026-09-14 18:41 -0600", heading: "# Campaign: gitlab")
    write_consent(@dir, "gitlab")

    _code, env = run_cli(["list", "--dir", @dir])

    assert_equal ["gitlab"], env["data"]["campaigns"].map { |c| c["id"] }
    assert_equal ["gitlab"], env["data"]["runnable"]
    assert_empty env["warnings"]
  end

  def test_list_warns_about_an_unrecognized_file_whose_status_is_armed
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha")
    File.write(File.join(@dir, "notes.md"), "# Some other document\n\nStatus: ARMED 2026-09-14\n")

    _code, env = run_cli(["list", "--dir", @dir])

    assert_equal ["260914-alpha"], env["data"]["campaigns"].map { |c| c["id"] }
    warning = env["warnings"].find { |w| w["code"] == "unparsed_campaign_file" }
    refute_nil warning
    assert_includes warning["message"], File.join(@dir, "notes.md")
    assert_includes warning["message"], "ARMED"
  end

  def test_list_warns_about_an_unrecognized_file_whose_status_is_queued
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha")
    File.write(File.join(@dir, "notes.md"), "# Some other document\n\nStatus: QUEUED 2026-09-14 after 260914-alpha\n")

    _code, env = run_cli(["list", "--dir", @dir])

    warning = env["warnings"].find { |w| w["code"] == "unparsed_campaign_file" }
    refute_nil warning
    assert_includes warning["message"], "QUEUED"
  end

  def test_list_stays_silent_on_an_unrecognized_wrapped_file
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha")
    File.write(File.join(@dir, "notes.md"), "# Some other document\n\nStatus: WRAPPED 2026-09-01\n")

    _code, env = run_cli(["list", "--dir", @dir])

    refute_includes env["warnings"].map { |w| w["code"] }, "unparsed_campaign_file"
  end

  def test_list_stays_silent_on_an_unrecognized_drafted_file
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha")
    File.write(File.join(@dir, "notes.md"), "# Some other document\n\nStatus: DRAFTED 2026-09-01\n")

    _code, env = run_cli(["list", "--dir", @dir])

    refute_includes env["warnings"].map { |w| w["code"] }, "unparsed_campaign_file"
  end

  def test_list_stays_silent_on_an_unrecognized_file_with_no_status_line
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha")
    File.write(File.join(@dir, "notes.md"), "# Some other document\n\nJust prose.\n")

    _code, env = run_cli(["list", "--dir", @dir])

    refute_includes env["warnings"].map { |w| w["code"] }, "unparsed_campaign_file"
  end

  def test_list_stays_silent_on_a_bad_h1_legacy_wrapped_plan
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha")
    File.write(File.join(@dir, "RF050-foo.md"), "# Campaign RF050 - description\n\nStatus: WRAPPED 2026-09-01\n")

    _code, env = run_cli(["list", "--dir", @dir])

    refute_includes env["warnings"].map { |w| w["code"] }, "unparsed_campaign_file"
  end

  def test_list_does_not_warn_about_a_recognized_plans_consent_and_report_files
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha")
    write_report(@dir, "260914-alpha")

    _code, env = run_cli(["list", "--dir", @dir])

    refute_includes env["warnings"].map { |w| w["code"] }, "unparsed_campaign_file"
  end

  def test_list_warns_on_an_unknown_status_word_and_never_treats_it_as_armed
    write_plan(@dir, "260914-alpha", status: "PAUSED 2026-09-14")
    write_consent(@dir, "260914-alpha")

    _code, env = run_cli(["list", "--dir", @dir])

    campaign = env["data"]["campaigns"].fetch(0)
    assert_equal "PAUSED", campaign["status"]
    refute campaign["armed"]
    assert_equal ["unknown_status"], env["warnings"].map { |w| w["code"] }
  end

  def test_list_warns_status_missing_for_a_parsed_plan_with_no_status_line_and_treats_it_as_not_armed
    write_plan(@dir, "260914-alpha", body: "Some prose with no Status line at all.")

    _code, env = run_cli(["list", "--dir", @dir])

    campaign = env["data"]["campaigns"].fetch(0)
    assert_nil campaign["status"]
    refute campaign["armed"]
    assert_equal ["status_missing"], env["warnings"].map { |w| w["code"] }
  end

  def test_list_scans_several_dirs_and_sorts_by_id
    other = File.join(@dir, "fleet-repo", "campaigns")
    FileUtils.mkdir_p(other)
    write_plan(other, "260901-old")
    write_plan(@dir, "260914-new")

    code, env = run_cli(["list", "--dir", @dir, "--dir", other])

    assert_equal 0, code
    assert_equal [@dir, other], env["data"]["dirs"]
    assert_equal %w[260901-old 260914-new], env["data"]["campaigns"].map { |c| c["id"] }
  end

  def test_list_of_a_missing_dir_is_ok_and_empty_with_a_warning
    code, env = run_cli(["list", "--dir", File.join(@dir, "absent")])

    assert_equal 0, code
    assert env["ok"]
    assert_empty env["data"]["campaigns"]
    assert_equal ["campaigns_dir_missing"], env["warnings"].map { |w| w["code"] }
  end

  def test_list_defaults_to_the_repo_campaigns_dir_under_the_current_directory
    FileUtils.mkdir_p(File.join(@dir, ".claude", "campaigns"))
    write_plan(File.join(@dir, ".claude", "campaigns"), "260914-here")

    _code, env = Dir.chdir(@dir) { run_cli(["list"]) }

    assert_equal [File.join(File.realpath(@dir), ".claude", "campaigns")], env["data"]["dirs"]
    assert_equal ["260914-here"], env["data"]["campaigns"].map { |c| c["id"] }
  end

  def test_list_honors_an_explicit_locks_dir
    locks = File.join(@dir, "elsewhere", "locks")
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14")
    write_consent(@dir, "260914-alpha")
    Lock.try_acquire(File.join(locks, "campaign-260914-alpha"), "campaign" => "260914-alpha", "pid" => Process.pid.to_s)

    _code, env = run_cli(["list", "--dir", @dir, "--locks-dir", locks])

    campaign = env["data"]["campaigns"].fetch(0)
    assert_equal File.join(locks, "campaign-260914-alpha"), campaign["mutex"]["dir"]
    assert campaign["running"]
  end

  def test_list_never_writes_anything
    path = write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14")
    before = File.read(path)

    run_cli(["list", "--dir", @dir])

    assert_equal before, File.read(path)
    assert_equal [path], Dir.glob(File.join(@dir, "**", "*")).select { |f| File.file?(f) }
  end

  # --- show ---------------------------------------------------------------------

  def test_show_returns_one_campaign_under_data_campaign
    write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha")

    code, env = run_cli(["show", "260914-alpha", "--dir", @dir])

    assert_equal 0, code
    assert_equal "260914-alpha", env["data"]["campaign"]["id"]
    assert env["data"]["campaign"]["runnable"]
    assert_empty env["commands"]
  end

  def test_show_blocks_on_an_unknown_id
    code, env = run_cli(["show", "260914-nope", "--dir", @dir])

    assert_equal 1, code
    assert_equal ["campaign_not_found"], env["blocked"].map { |b| b["code"] }
  end

  def test_show_requires_an_id
    _code, status = capture_exit { run_cli(["show", "--dir", @dir]) }

    assert_equal 2, status
  end

  # --- arm ----------------------------------------------------------------------

  def test_arm_rewrites_the_status_line_to_armed_with_a_stamp
    path = write_plan(@dir, "260914-alpha", status: "DRAFTED 2026-09-13 (plan written)")
    write_consent(@dir, "260914-alpha")

    code, env = run_cli(["arm", "260914-alpha", "--dir", @dir])

    assert_equal 0, code
    assert env["ok"]
    assert env["data"]["changed"]
    assert_equal "DRAFTED", env["data"]["before"]
    assert_equal "ARMED", env["data"]["after"]
    assert_equal "ARMED", env["data"]["campaign"]["status"]
    assert env["data"]["campaign"]["runnable"]
    assert_equal ["rewrite Status line in #{path}: DRAFTED -> ARMED 2026-09-14 20:00 -0600"], env["commands"]
    assert_includes File.read(path), "Status: ARMED 2026-09-14 20:00 -0600 (plan written)\n"
  end

  def test_arm_inserts_a_status_line_when_the_plan_has_none
    path = write_plan(@dir, "260914-alpha")
    write_consent(@dir, "260914-alpha")

    code, env = run_cli(["arm", "260914-alpha", "--dir", @dir])

    assert_equal 0, code
    assert_nil env["data"]["before"]
    assert_equal "# Campaign 260914-alpha\n\nStatus: ARMED 2026-09-14 20:00 -0600\n\nSingle-repo campaign.", File.read(path)[0, 84]
  end

  def test_arm_dry_run_reports_the_rewrite_without_touching_the_file
    path = write_plan(@dir, "260914-alpha", status: "DRAFTED 2026-09-13")
    write_consent(@dir, "260914-alpha")
    before = File.read(path)

    code, env = run_cli(["arm", "260914-alpha", "--dir", @dir, "--dry-run"])

    assert_equal 0, code
    assert env["data"]["dry_run"]
    assert env["data"]["changed"]
    assert_equal "ARMED", env["data"]["after"]
    assert_equal 1, env["commands"].length
    assert_equal before, File.read(path)
    assert_equal "DRAFTED", env["data"]["campaign"]["status"]
  end

  def test_arm_refuses_when_the_consent_file_is_missing
    path = write_plan(@dir, "260914-alpha", status: "DRAFTED 2026-09-13")
    before = File.read(path)

    code, env = run_cli(["arm", "260914-alpha", "--dir", @dir])

    assert_equal 1, code
    assert_equal ["consent_not_adopted"], env["blocked"].map { |b| b["code"] }
    assert_equal "human", env["blocked"][0]["needs"]
    assert_equal before, File.read(path)
    refute File.exist?(File.join(@dir, "260914-alpha-consent.md")), "arm must never write a consent file"
  end

  def test_arm_refuses_when_the_consent_is_only_drafted
    write_plan(@dir, "260914-alpha", status: "DRAFTED 2026-09-13")
    write_consent(@dir, "260914-alpha", status: "DRAFTED 2026-09-13")

    code, env = run_cli(["arm", "260914-alpha", "--dir", @dir])

    assert_equal 1, code
    assert_equal ["consent_not_adopted"], env["blocked"].map { |b| b["code"] }
  end

  def test_arm_refuses_a_wrapped_campaign
    write_plan(@dir, "260914-alpha", status: "WRAPPED 2026-09-14")
    write_consent(@dir, "260914-alpha")

    code, env = run_cli(["arm", "260914-alpha", "--dir", @dir])

    assert_equal 1, code
    assert_equal ["campaign_wrapped"], env["blocked"].map { |b| b["code"] }
  end

  def test_arm_of_an_already_armed_campaign_is_ok_and_changes_nothing
    path = write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha")
    before = File.read(path)

    code, env = run_cli(["arm", "260914-alpha", "--dir", @dir])

    assert_equal 0, code
    refute env["data"]["changed"]
    assert_empty env["commands"]
    assert_equal ["already_armed"], env["warnings"].map { |w| w["code"] }
    assert_equal before, File.read(path)
  end

  def test_arm_blocks_on_an_unknown_id
    code, env = run_cli(["arm", "260914-nope", "--dir", @dir])

    assert_equal 1, code
    assert_equal ["campaign_not_found"], env["blocked"].map { |b| b["code"] }
  end

  # --- disarm -------------------------------------------------------------------

  def test_disarm_rewrites_the_status_line_to_drafted
    path = write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600 (consent adopted)")
    write_consent(@dir, "260914-alpha")

    code, env = run_cli(["disarm", "260914-alpha", "--dir", @dir])

    assert_equal 0, code
    assert env["data"]["changed"]
    assert_equal "ARMED", env["data"]["before"]
    assert_equal "DRAFTED", env["data"]["after"]
    refute env["data"]["campaign"]["armed"]
    assert_includes File.read(path), "Status: DRAFTED 2026-09-14 20:00 -0600 (consent adopted)\n"
    assert File.exist?(File.join(@dir, "260914-alpha-consent.md")), "disarm never touches the consent file"
  end

  def test_disarm_refuses_while_the_campaign_is_running
    path = write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "260914-alpha")
    hold_mutex(@dir, "260914-alpha")
    before = File.read(path)

    code, env = run_cli(["disarm", "260914-alpha", "--dir", @dir])

    assert_equal 1, code
    assert_equal ["campaign_running"], env["blocked"].map { |b| b["code"] }
    assert_equal before, File.read(path)
  end

  def test_disarm_of_an_unarmed_campaign_is_ok_and_changes_nothing
    path = write_plan(@dir, "260914-alpha", status: "DRAFTED 2026-09-13")
    before = File.read(path)

    code, env = run_cli(["disarm", "260914-alpha", "--dir", @dir])

    assert_equal 0, code
    refute env["data"]["changed"]
    assert_equal ["not_armed"], env["warnings"].map { |w| w["code"] }
    assert_equal before, File.read(path)
  end

  def test_disarm_dry_run_touches_nothing
    path = write_plan(@dir, "260914-alpha", status: "ARMED 2026-09-14")
    before = File.read(path)

    code, env = run_cli(["disarm", "260914-alpha", "--dir", @dir, "--dry-run"])

    assert_equal 0, code
    assert env["data"]["changed"]
    assert_equal 1, env["commands"].length
    assert_equal before, File.read(path)
  end

  # --- usage ----------------------------------------------------------------------

  def test_unknown_subcommand_is_a_usage_error
    _code, status = capture_exit { run_cli(["frobnicate"]) }

    assert_equal 2, status
  end

  private

  # A pid that is certainly dead: spawned, exited, reaped. Never fork - see
  # support/dead_pid.rb (wu-tms).
  def dead_pid
    DeadPid.obtain
  end

  def capture_exit
    yield
    [nil, 0]
  rescue SystemExit => e
    [nil, e.status]
  end
end

# The QUEUED status: sequencing one campaign behind another so a scheduler
# keying off `armed` never sees two ARMED plans and never needs a human at
# the handoff.
class CampaignStateQueueTest < Minitest::Test
  include CampaignFixtures

  def setup
    @dir = Dir.mktmpdir
    @previous_clock = CampaignState.clock
    CampaignState.clock = -> { FIXED_NOW }
  end

  def teardown
    CampaignState.clock = @previous_clock
    FileUtils.remove_entry(@dir)
  end

  def run_cli(argv)
    io = StringIO.new
    code = CampaignStateCli.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  def locks_dir
    File.join(@dir, "locks")
  end

  def queue_fixture(predecessor_status:)
    write_plan(@dir, "042", status: "#{predecessor_status} 2026-09-14 18:41 -0600")
    write_consent(@dir, "042")
    write_plan(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600 after 042")
    write_consent(@dir, "043")
  end

  def test_parse_status_captures_the_after_id
    parsed = CampaignState.parse_status("Status: QUEUED 2026-09-14 19:00 -0600 after 042 prose tail\n")
    assert_equal "QUEUED", parsed[:status]
    assert_equal "042", parsed[:after]

    assert_nil CampaignState.parse_status("Status: ARMED 2026-09-14 19:00 -0600\n")[:after]
  end

  def test_queued_holds_while_the_predecessor_is_armed
    queue_fixture(predecessor_status: "ARMED")
    _, env = run_cli(["list", "--dir", @dir])
    q = env["data"]["campaigns"].find { |c| c["id"] == "043" }
    refute q["armed"], "queued campaign must not report armed while the predecessor is not WRAPPED"
    refute q["runnable"]
    assert_equal "042", q["queued_after"]
    refute q["queue"]["satisfied"]
    assert_equal ["042"], env["data"]["runnable"]
  end

  def test_queued_promotes_when_the_predecessor_wraps
    queue_fixture(predecessor_status: "WRAPPED")
    _, env = run_cli(["list", "--dir", @dir])
    q = env["data"]["campaigns"].find { |c| c["id"] == "043" }
    assert q["armed"], "queued campaign reports armed once the predecessor is WRAPPED"
    assert q["queue"]["satisfied"]
    assert_equal "QUEUED", q["status"], "virtual promotion never rewrites the file"
    assert_equal ["043"], env["data"]["runnable"]
  end

  # An aborted predecessor stopped on something still in the environment;
  # promoting the successor sends it into the same wall (measured: two
  # campaigns aborted on one stray file, minutes apart).
  #
  # sabotage: satisfy the queue on any terminal word (WRAPPED or ABORTED)
  # -> red here, green in test_queued_promotes_when_the_predecessor_wraps.
  def test_queued_holds_when_the_predecessor_aborted
    queue_fixture(predecessor_status: "ABORTED")
    _, env = run_cli(["list", "--dir", @dir])
    q = env["data"]["campaigns"].find { |c| c["id"] == "043" }
    refute q["armed"], "an ABORTED predecessor must hold the queue"
    refute q["queue"]["satisfied"]
    assert_equal "ABORTED", q["queue"]["predecessor_status"]
    assert env["warnings"].any? { |w| w["code"] == "queue_predecessor_aborted" }, env["warnings"].inspect
    assert_equal [], env["data"]["runnable"], "neither the aborted plan nor its successor is runnable"
  end

  def test_aborted_is_a_known_status_that_is_not_armed
    write_plan(@dir, "042", status: "ABORTED 2026-09-16 22:10 -0600 (kit preflight refused)")
    write_consent(@dir, "042")
    _, env = run_cli(["list", "--dir", @dir])
    c = env["data"]["campaigns"].first
    assert_equal "ABORTED", c["status"]
    refute c["armed"]
    refute c["runnable"]
    refute env["warnings"].any? { |w| w["code"] == "unknown_status" }, env["warnings"].inspect
  end

  # Unlike WRAPPED, ABORTED is re-armable by the script: that is the
  # operator's path back once the fault is cleared.
  #
  # sabotage: refuse ABORTED alongside WRAPPED in run_arm -> red.
  def test_arm_re_arms_an_aborted_campaign_with_a_warning
    path = write_plan(@dir, "042", status: "ABORTED 2026-09-16 22:10 -0600 (kit preflight refused)")
    write_consent(@dir, "042")

    code, env = run_cli(["arm", "042", "--dir", @dir])

    assert_equal 0, code
    assert_equal "ABORTED", env["data"]["before"]
    assert_equal "ARMED", env["data"]["after"]
    assert env["warnings"].any? { |w| w["code"] == "re_armed_after_abort" }, env["warnings"].inspect
    assert_match(/^Status: ARMED 2026-09-14 20:00 -0600 \(kit preflight refused\)/, File.read(path))
  end

  def test_queued_holds_while_the_wrapped_predecessors_mutex_is_still_held
    queue_fixture(predecessor_status: "WRAPPED")
    hold_mutex(@dir, "042")
    _, env = run_cli(["list", "--dir", @dir])
    q = env["data"]["campaigns"].find { |c| c["id"] == "043" }
    refute q["armed"], "WRAPPED is flipped while the mutex is still held; the successor must not start in that window"
    refute q["queue"]["satisfied"]
  end

  def test_queued_after_a_missing_predecessor_warns_and_holds
    write_plan(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600 after 042")
    write_consent(@dir, "043")
    _, env = run_cli(["list", "--dir", @dir])
    q = env["data"]["campaigns"].find { |c| c["id"] == "043" }
    refute q["armed"], "a typo'd predecessor must hold the queue, not release it"
    assert env["warnings"].any? { |w| w["code"] == "queue_predecessor_missing" }, env["warnings"].inspect
  end

  def test_queued_without_after_warns_and_holds
    write_plan(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600")
    write_consent(@dir, "043")
    _, env = run_cli(["list", "--dir", @dir])
    refute env["data"]["campaigns"].first["armed"]
    assert env["warnings"].any? { |w| w["code"] == "queued_without_after" }, env["warnings"].inspect
  end

  def test_arm_after_writes_the_queued_line_and_plain_arm_promotes
    write_plan(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "042")
    write_plan(@dir, "043", status: "DRAFTED 2026-09-14 18:00 -0600")
    write_consent(@dir, "043")

    _, env = run_cli(["arm", "043", "--dir", @dir, "--after", "042"])
    assert env["ok"], env.inspect
    assert_equal "QUEUED", env["data"]["after"]
    line = File.read(File.join(@dir, "043.md"))[/^Status:.*$/]
    assert_match(/\AStatus: QUEUED 2026-09-14 20:00 -0600 after 042/, line)

    # Plain arm on the QUEUED plan is the manual promotion path.
    _, env = run_cli(["arm", "043", "--dir", @dir])
    assert env["ok"], env.inspect
    line = File.read(File.join(@dir, "043.md"))[/^Status:.*$/]
    assert_match(/\AStatus: ARMED 2026-09-14 20:00 -0600/, line)
  end

  def test_arm_after_refuses_self
    write_plan(@dir, "043", status: "DRAFTED 2026-09-14 18:00 -0600")
    write_consent(@dir, "043")
    _, env = run_cli(["arm", "043", "--dir", @dir, "--after", "043"])
    refute env["ok"]
    assert env["blocked"].any? { |b| b["code"] == "queued_after_self" }, env.inspect
  end

  # --- arm on a queued plan drops the old after tail (wu-7bpp) ---------------

  # sabotage: pass drop_after: false on run_arm's plain path -> red on the
  # Status line (the old `after 042` survives behind ARMED).
  def test_plain_arm_on_a_queued_plan_drops_the_after_tail_and_keeps_the_prose
    write_plan(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "042")
    path = write_plan(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600 after 042 (queued by the operator)")
    write_consent(@dir, "043")

    code, env = run_cli(["arm", "043", "--dir", @dir])

    assert_equal 0, code
    assert env["ok"], env.inspect
    assert env["data"]["changed"]
    assert_equal "QUEUED", env["data"]["before"]
    assert_equal "ARMED", env["data"]["after"]
    assert_equal ["rewrite Status line in #{path}: QUEUED -> ARMED 2026-09-14 20:00 -0600 (drops after 042)"], env["commands"]
    assert_includes File.read(path), "Status: ARMED 2026-09-14 20:00 -0600 (queued by the operator)\n"
    assert_nil env["data"]["campaign"]["queued_after"]
  end

  # sabotage: pass drop_after: false on run_arm's --after path -> red (the
  # line reads `after 044 after 042`).
  def test_arm_after_on_a_queued_plan_replaces_the_after_tail
    write_plan(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600")
    write_plan(@dir, "044", status: "ARMED 2026-09-14 18:50 -0600")
    path = write_plan(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600 after 042 (queued by the operator)")
    write_consent(@dir, "043")

    code, env = run_cli(["arm", "043", "--dir", @dir, "--after", "044"])

    assert_equal 0, code
    assert env["ok"], env.inspect
    assert_equal ["rewrite Status line in #{path}: QUEUED -> QUEUED 2026-09-14 20:00 -0600 after 044 (drops after 042)"], env["commands"]
    assert_includes File.read(path), "Status: QUEUED 2026-09-14 20:00 -0600 after 044 (queued by the operator)\n"
    assert_equal "044", env["data"]["campaign"]["queued_after"]
  end

  def test_arm_dry_run_on_a_queued_plan_writes_nothing
    path = write_plan(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600 after 042")
    write_consent(@dir, "043")
    before = File.read(path)

    _, plain = run_cli(["arm", "043", "--dir", @dir, "--dry-run"])
    _, requeue = run_cli(["arm", "043", "--dir", @dir, "--after", "044", "--dry-run"])

    assert plain["data"]["changed"]
    assert_match(/QUEUED -> ARMED 2026-09-14 20:00 -0600 \(drops after 042\)\z/, plain["commands"].first)
    assert_match(/QUEUED -> QUEUED 2026-09-14 20:00 -0600 after 044 \(drops after 042\)\z/, requeue["commands"].first)
    assert_equal before, File.read(path)
  end

  # A satisfied queue reports armed (virtual promotion) while the file
  # still says QUEUED; arm keys the tail drop off the Status word, not
  # off armed, so it drops the tail on that path too.
  # sabotage: pass drop_after: queued && !campaign[:armed] on the plain
  # path -> red here.
  def test_arm_on_a_virtually_promoted_queued_plan_drops_the_after_tail
    write_plan(@dir, "042", status: "WRAPPED 2026-09-14 19:30 -0600")
    path = write_plan(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600 after 042")
    write_consent(@dir, "043")

    code, env = run_cli(["arm", "043", "--dir", @dir])

    assert_equal 0, code
    assert env["ok"], env.inspect
    assert_equal "QUEUED", env["data"]["before"]
    assert_includes File.read(path), "Status: ARMED 2026-09-14 20:00 -0600\n"
  end

  # Only a QUEUED line's `after <id>` is a tail. On DRAFTED the text past
  # the stamp is prose and stays verbatim; an ARMED re-arm writes nothing.
  # sabotage: pass drop_after: true unconditionally in run_arm -> red here.
  def test_arm_on_drafted_keeps_after_looking_prose_and_armed_re_arm_is_unchanged
    drafted = write_plan(@dir, "043", status: "DRAFTED 2026-09-13 after review (plan written)")
    write_consent(@dir, "043")
    armed = write_plan(@dir, "045", status: "ARMED 2026-09-14 19:00 -0600 after 042")
    write_consent(@dir, "045")
    armed_before = File.read(armed)

    _, env = run_cli(["arm", "043", "--dir", @dir])
    assert env["ok"], env.inspect
    assert_includes File.read(drafted), "Status: ARMED 2026-09-14 20:00 -0600 after review (plan written)\n"

    _, env = run_cli(["arm", "043", "--dir", @dir, "--after", "042"])
    assert_includes File.read(drafted), "Status: QUEUED 2026-09-14 20:00 -0600 after 042 after review (plan written)\n"

    _, env = run_cli(["arm", "045", "--dir", @dir])
    assert_equal ["already_armed"], env["warnings"].map { |w| w["code"] }
    refute env["data"]["changed"]
    assert_equal armed_before, File.read(armed)
  end

  # --- disarm on a queued plan (wu-vmia) ------------------------------------

  # sabotage: keep run_disarm's guard at `campaign[:armed]` alone -> red
  # here (not_armed, changed false). sabotage: pass drop_after: false for
  # QUEUED -> red on the Status line assertion (the after tail survives).
  def test_disarm_takes_a_queued_plan_back_to_drafted_and_drops_the_after_tail
    write_plan(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "042")
    path = write_plan(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600 after 042 (queued by the operator)")
    write_consent(@dir, "043")

    code, env = run_cli(["disarm", "043", "--dir", @dir])

    assert_equal 0, code
    assert env["ok"], env.inspect
    assert env["data"]["changed"]
    assert_equal "QUEUED", env["data"]["before"]
    assert_equal "DRAFTED", env["data"]["after"]
    assert_empty env["warnings"].map { |w| w["code"] } & ["not_armed"]
    assert_includes File.read(path), "Status: DRAFTED 2026-09-14 20:00 -0600 (queued by the operator)\n"
    refute env["data"]["campaign"]["queued"]
    assert_nil env["data"]["campaign"]["queued_after"]
  end

  # A satisfied queue reports armed (virtual promotion) while the file
  # still says QUEUED; disarm must drop the after tail on that path too.
  def test_disarm_of_a_virtually_promoted_queued_plan_drops_the_after_tail
    write_plan(@dir, "042", status: "WRAPPED 2026-09-14 19:30 -0600")
    path = write_plan(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600 after 042")
    write_consent(@dir, "043")

    code, env = run_cli(["disarm", "043", "--dir", @dir])

    assert_equal 0, code
    assert_equal "QUEUED", env["data"]["before"]
    assert_includes File.read(path), "Status: DRAFTED 2026-09-14 20:00 -0600\n"
  end

  # QUEUED is disarmable now, so the running refusal is all that keeps a
  # live queued campaign's file intact. sabotage: drop run_disarm's
  # campaign_running block -> red.
  def test_disarm_refuses_a_queued_plan_while_it_is_running
    path = write_plan(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600 after 042")
    write_consent(@dir, "043")
    hold_mutex(@dir, "043")
    before = File.read(path)

    code, env = run_cli(["disarm", "043", "--dir", @dir])

    assert_equal 1, code
    assert_equal ["campaign_running"], env["blocked"].map { |b| b["code"] }
    refute env["data"]["changed"]
    assert_equal before, File.read(path)
  end

  def test_disarm_dry_run_on_a_queued_plan_writes_nothing
    path = write_plan(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600 after 042")
    before = File.read(path)

    code, env = run_cli(["disarm", "043", "--dir", @dir, "--dry-run"])

    assert_equal 0, code
    assert env["data"]["changed"]
    assert_equal "QUEUED", env["data"]["before"]
    assert_equal "DRAFTED", env["data"]["after"]
    assert_equal 1, env["commands"].length
    assert_match(/QUEUED -> DRAFTED 2026-09-14 20:00 -0600 \(drops after 042\)\z/, env["commands"].first)
    assert_equal before, File.read(path)
  end

  # The ARMED path is untouched: drop_after applies only to QUEUED, so a
  # plan's hand-written `after <id>` (plain arm no longer leaves one,
  # wu-7bpp) stays put.
  # sabotage: pass drop_after: true unconditionally -> red.
  def test_disarm_of_an_armed_plan_keeps_the_rest_of_the_line_verbatim
    path = write_plan(@dir, "043", status: "ARMED 2026-09-14 19:00 -0600 after 042")
    write_consent(@dir, "043")

    code, env = run_cli(["disarm", "043", "--dir", @dir])

    assert_equal 0, code
    assert_equal "ARMED", env["data"]["before"]
    assert_includes File.read(path), "Status: DRAFTED 2026-09-14 20:00 -0600 after 042\n"
  end

  def test_disarm_of_a_terminal_plan_still_warns_not_armed
    path = write_plan(@dir, "043", status: "WRAPPED 2026-09-14 19:00 -0600")
    before = File.read(path)

    code, env = run_cli(["disarm", "043", "--dir", @dir])

    assert_equal 0, code
    refute env["data"]["changed"]
    warning = env["warnings"].find { |w| w["code"] == "not_armed" }
    assert warning, env["warnings"].inspect
    assert_match(/neither ARMED nor QUEUED/, warning["message"])
    assert_equal before, File.read(path)
  end
end

# wu-9vp: under launchd there is no LANG/LC_ALL/LC_CTYPE, so Ruby's default
# external encoding is US-ASCII. A bare File.read used to tag every campaign
# file's content with that default, and the first regex match against a
# non-ASCII byte raised ArgumentError and took down the whole `list` run
# instead of skipping one campaign. This spawns the real script as a
# subprocess (in-process specs can't exercise Encoding.default_external -
# it's fixed at Ruby startup from the launching env) with those three
# variables explicitly unset, the same shape as the acceptance criterion's
# `env -u LANG -u LC_ALL -u LC_CTYPE`.
#
# sabotage: revert campaign_state.rb's read_utf8 to a bare File.read -> red
# here (ArgumentError: invalid byte sequence in US-ASCII, exit 1), while the
# in-process CampaignStateCliTest suite above stays green because this
# process's own default external encoding is whatever locale launched it.
class CampaignStateLocaleTest < Minitest::Test
  include CampaignFixtures

  SCRIPT = File.expand_path("../campaign_state.rb", __dir__)

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_list_survives_a_non_ascii_plan_file_with_no_locale_in_the_environment
    write_plan(@dir, "260914-cafe", body: "Non-ASCII plan body: café, naïve, — an em dash.\n\n## Mode\n\nMR mode.\n")
    write_consent(@dir, "260914-cafe")

    env = ENV.to_h.merge("LANG" => nil, "LC_ALL" => nil, "LC_CTYPE" => nil)
    out, err, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, "list", "--dir", @dir)

    assert status.success?, "expected exit 0, got #{status.exitstatus}; stderr: #{err}"
    parsed = JSON.parse(out)
    assert parsed["ok"], parsed.inspect
    assert_equal ["260914-cafe"], parsed["data"]["campaigns"].map { |c| c["id"] }
  end
end

# wu-dtrb: the plan-to-machine binding. A `Machine: <name>` line opts a plan
# into per-machine gating - list/show/arm all read the same record, so this
# suite drives everything through the CLI (list, show) the way the existing
# CampaignStateQueueTest does, plus a couple of direct CampaignState.parse_machine
# checks for the parser itself.
class CampaignStateMachineBindingTest < Minitest::Test
  include CampaignFixtures
  include UserConfigHelper

  def setup
    @dir = Dir.mktmpdir
    @previous_clock = CampaignState.clock
    CampaignState.clock = -> { FIXED_NOW }
  end

  def teardown
    CampaignState.clock = @previous_clock
    FileUtils.remove_entry(@dir)
  end

  def run_cli(argv)
    io = StringIO.new
    code = CampaignStateCli.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  # --- parse_machine ----------------------------------------------------

  def test_parse_machine_reads_the_first_column_one_line
    content = "# Campaign 042\n\nMachine: mbp\n\nStatus: ARMED 2026-09-14 18:41 -0600\n"
    assert_equal "mbp", CampaignState.parse_machine(content)[:machine]
  end

  def test_parse_machine_returns_blank_for_a_blank_line
    content = "# Campaign 042\n\nMachine:\n\nStatus: ARMED 2026-09-14 18:41 -0600\n"
    assert_equal "", CampaignState.parse_machine(content)[:machine]
  end

  def test_parse_machine_returns_nil_when_absent
    content = "# Campaign 042\n\nStatus: ARMED 2026-09-14 18:41 -0600\n"
    parsed = CampaignState.parse_machine(content)
    assert_nil parsed[:machine]
    assert_nil parsed[:line]
  end

  def test_parse_machine_ignores_an_indented_line_in_prose
    content = "# Campaign 042\n\nA note to the reader:\n  Machine: mbp (not a real binding)\n\nStatus: ARMED 2026-09-14 18:41 -0600\n"
    assert_nil CampaignState.parse_machine(content)[:machine]
  end

  # --- malformed Machine: line ---------------------------------------------
  #
  # Measured on the riddler fleet, 2026-09-19: RF063.md line 22 was
  # column-1 operator prose that happens to begin with "Machine:". The
  # branch this phase fixes captured the whole remainder as the bound
  # name; the only accepted shape is a bare token (MACHINE_LINE), so
  # anything else is malformed, never a bind.

  def test_parse_machine_rejects_the_rf063_operator_prose_line
    content = "# Campaign RF063\n\nStatus: ARMED 2026-09-14 18:41 -0600\n" \
              "Machine: **personal-air**, QUEUED after RF056 (the operator, 2026-09-19 12:5x MDT). RF063\n\n" \
              "Body.\n"
    parsed = CampaignState.parse_machine(content)
    assert_nil parsed[:machine]
    assert parsed[:malformed]
    assert_equal "Machine: **personal-air**, QUEUED after RF056 (the operator, 2026-09-19 12:5x MDT). RF063", parsed[:raw]
  end

  def test_parse_machine_rejects_a_valid_name_followed_by_trailing_prose
    content = "# Campaign 042\n\nStatus: ARMED 2026-09-14 18:41 -0600\nMachine: mbp, QUEUED after 041 (the operator)\n\nBody.\n"
    parsed = CampaignState.parse_machine(content)
    assert_nil parsed[:machine]
    assert parsed[:malformed]
  end

  def test_parse_machine_accepts_a_bare_token_with_trailing_whitespace
    content = "# Campaign 042\n\nStatus: ARMED 2026-09-14 18:41 -0600\nMachine: mbp   \n\nBody.\n"
    parsed = CampaignState.parse_machine(content)
    assert_equal "mbp", parsed[:machine]
    refute parsed[:malformed]
  end

  def test_the_rf063_line_is_listed_but_not_armed
    write_plan_with_raw_machine_line(
      @dir, "RF063", status: "ARMED 2026-09-14 18:41 -0600",
      machine_line: "Machine: **personal-air**, QUEUED after RF056 (the operator, 2026-09-19 12:5x MDT). RF063"
    )
    write_consent(@dir, "RF063")

    with_user_config("machine" => { "name" => "personal-air" }) do
      _, env = run_cli(["list", "--dir", @dir])
      c = env["data"]["campaigns"].first
      assert_equal "ARMED", c["status"]
      assert_nil c["machine"]
      assert_equal "unverified", c["machine_match"]
      refute c["armed"]
      refute c["runnable"]
      assert_equal [], env["data"]["runnable"]
      assert env["warnings"].any? { |w| w["code"] == "machine_binding_malformed" && w["message"].include?("RF063") }, env["warnings"].inspect
    end
  end

  def test_a_valid_name_with_trailing_prose_is_malformed_not_armed
    write_plan_with_raw_machine_line(
      @dir, "042", status: "ARMED 2026-09-14 18:41 -0600",
      machine_line: "Machine: mbp, QUEUED after 041 (the operator)"
    )
    write_consent(@dir, "042")

    with_user_config("machine" => { "name" => "mbp" }) do
      _, env = run_cli(["list", "--dir", @dir])
      c = env["data"]["campaigns"].first
      assert_nil c["machine"]
      assert_equal "unverified", c["machine_match"]
      refute c["armed"]
      refute c["runnable"]
      assert env["warnings"].any? { |w| w["code"] == "machine_binding_malformed" }, env["warnings"].inspect
    end
  end

  def test_a_bare_token_with_trailing_whitespace_still_binds
    write_plan_with_raw_machine_line(
      @dir, "042", status: "ARMED 2026-09-14 18:41 -0600",
      machine_line: "Machine: mbp   "
    )
    write_consent(@dir, "042")

    with_user_config("machine" => { "name" => "mbp" }) do
      _, env = run_cli(["list", "--dir", @dir])
      c = env["data"]["campaigns"].first
      assert_equal "mbp", c["machine"]
      assert_equal "this_machine", c["machine_match"]
      assert c["armed"]
      assert c["runnable"]
      assert_equal ["042"], env["data"]["runnable"]
      assert_equal [], env["warnings"], env["warnings"].inspect
    end
  end

  def test_arm_refuses_a_malformed_machine_line
    path = write_plan_with_raw_machine_line(
      @dir, "042", status: "ARMED 2026-09-14 18:41 -0600",
      machine_line: "Machine: mbp, QUEUED after 041 (the operator)"
    )
    write_consent(@dir, "042")
    before = File.read(path)

    with_user_config("machine" => { "name" => "mbp" }) do
      code, env = run_cli(["arm", "042", "--dir", @dir])
      assert_equal 1, code
      assert_equal ["machine_binding_malformed"], env["blocked"].map { |b| b["code"] }
      assert_equal before, File.read(path)
    end
  end

  def test_queued_behind_a_predecessor_with_a_malformed_machine_line_holds
    write_plan_with_raw_machine_line(
      @dir, "042", status: "WRAPPED 2026-09-14 18:41 -0600",
      machine_line: "Machine: **personal-air**, QUEUED after 041 (the operator)"
    )
    write_consent(@dir, "042")
    write_plan(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600 after 042")
    write_consent(@dir, "043")

    with_user_config("machine" => { "name" => "personal-air" }) do
      _, env = run_cli(["list", "--dir", @dir])
      q = env["data"]["campaigns"].find { |c| c["id"] == "043" }
      refute q["armed"]
      refute q["queue"]["satisfied"]
      assert_nil q["queue"]["predecessor_machine"]
      assert_equal "unverified", q["queue"]["predecessor_machine_match"]
      assert env["warnings"].any? { |w| w["code"] == "queue_predecessor_remote" }, env["warnings"].inspect
      assert_equal [], env["data"]["runnable"]
    end
  end

  # --- bound-to-me / bound-to-other --------------------------------------

  def test_bound_to_this_machine_is_armed_and_runnable
    write_plan_with_machine(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600", machine: "mbp")
    write_consent(@dir, "042")

    with_user_config("machine" => { "name" => "mbp" }) do
      _, env = run_cli(["list", "--dir", @dir])
      c = env["data"]["campaigns"].first
      assert_equal "mbp", c["machine"]
      assert_equal "this_machine", c["machine_match"]
      assert c["armed"]
      assert c["runnable"]
      assert_equal ["042"], env["data"]["runnable"]
      assert_equal [], env["warnings"], env["warnings"].inspect
    end
  end

  # sabotage: drop the machine gate from armed -> red here, green in
  # test_bound_to_this_machine_is_armed_and_runnable.
  def test_bound_to_another_machine_is_listed_but_not_armed
    write_plan_with_machine(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600", machine: "mbp")
    write_consent(@dir, "042")

    with_user_config("machine" => { "name" => "air" }) do
      _, env = run_cli(["list", "--dir", @dir])
      c = env["data"]["campaigns"].first
      assert_equal "ARMED", c["status"]
      assert_equal "mbp", c["machine"]
      assert_equal "other_machine", c["machine_match"]
      refute c["armed"]
      refute c["runnable"]
      assert_equal [], env["data"]["runnable"]
      assert_equal [], env["warnings"], env["warnings"].inspect
    end
  end

  # "the measured riddler shape": two ARMED plans, one bound here, one
  # bound elsewhere -> exactly one record with armed: true.
  def test_two_armed_plans_one_bound_here_one_elsewhere_only_one_is_armed
    write_plan_with_machine(@dir, "056", status: "ARMED 2026-09-14 18:00 -0600", machine: "air")
    write_consent(@dir, "056")
    write_plan_with_machine(@dir, "059", status: "ARMED 2026-09-14 18:41 -0600", machine: "mbp")
    write_consent(@dir, "059")

    with_user_config("machine" => { "name" => "mbp" }) do
      _, env = run_cli(["list", "--dir", @dir])
      armed = env["data"]["campaigns"].select { |c| c["armed"] }
      assert_equal ["059"], armed.map { |c| c["id"] }
      assert_equal ["059"], env["data"]["runnable"]
    end
  end

  # --- unbound -------------------------------------------------------------

  def test_unbound_plan_behaves_as_today_under_a_named_machine
    write_plan(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "042")

    with_user_config("machine" => { "name" => "mbp" }) do
      _, env = run_cli(["list", "--dir", @dir])
      c = env["data"]["campaigns"].first
      assert_nil c["machine"]
      assert_equal "unbound", c["machine_match"]
      assert c["armed"]
      assert c["runnable"]
    end
  end

  def test_unbound_plan_behaves_as_today_under_no_config
    write_plan(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "042")

    with_user_config(nil) do
      _, env = run_cli(["list", "--dir", @dir])
      c = env["data"]["campaigns"].first
      assert_nil c["machine"]
      assert_equal "unbound", c["machine_match"]
      assert c["armed"]
      assert c["runnable"]
    end
  end

  # sabotage: resolve the machine eagerly in run_list -> red here, since the
  # invalid config installed below would then warn on this unbound plan too.
  def test_unbound_plan_never_reads_machine_config
    write_plan(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "042")

    with_user_config("machine" => { "name" => "" }) do
      code, env = run_cli(["list", "--dir", @dir])
      assert_equal 0, code
      assert env["ok"], env.inspect
      assert_equal [], env["warnings"], env["warnings"].inspect
      assert_equal ["042"], env["data"]["runnable"]
    end
  end

  # --- unnamed machine / invalid config -------------------------------------

  def test_unnamed_machine_bound_plan_is_unverified
    write_plan_with_machine(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600", machine: "mbp")
    write_consent(@dir, "042")

    with_user_config(nil) do
      _, env = run_cli(["list", "--dir", @dir])
      c = env["data"]["campaigns"].first
      assert_equal "unverified", c["machine_match"]
      refute c["armed"]
      assert env["warnings"].any? { |w| w["code"] == "machine_name_unset" && w["message"].include?("machine.name") }, env["warnings"].inspect
    end
  end

  def test_invalid_config_bound_plan_is_unverified_and_list_stays_ok
    write_plan_with_machine(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600", machine: "mbp")
    write_consent(@dir, "042")

    with_user_config("machine" => { "name" => "" }) do
      code, env = run_cli(["list", "--dir", @dir])
      assert_equal 0, code
      assert env["ok"], env.inspect
      c = env["data"]["campaigns"].first
      assert_equal "unverified", c["machine_match"]
      assert env["warnings"].any? { |w| w["code"] == "user_config_invalid" }, env["warnings"].inspect
    end
  end

  def test_blank_machine_line_is_unverified
    write_plan_with_machine(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600", machine: "")
    write_consent(@dir, "042")

    with_user_config("machine" => { "name" => "mbp" }) do
      _, env = run_cli(["list", "--dir", @dir])
      c = env["data"]["campaigns"].first
      assert_equal "", c["machine"]
      assert_equal "unverified", c["machine_match"]
      refute c["armed"]
      assert env["warnings"].any? { |w| w["code"] == "machine_binding_blank" }, env["warnings"].inspect
    end
  end

  # --- show ------------------------------------------------------------------

  def test_show_exposes_machine_and_machine_match
    write_plan_with_machine(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600", machine: "mbp")
    write_consent(@dir, "042")

    with_user_config("machine" => { "name" => "mbp" }) do
      _, env = run_cli(["show", "042", "--dir", @dir])
      assert_equal "mbp", env["data"]["campaign"]["machine"]
      assert_equal "this_machine", env["data"]["campaign"]["machine_match"]
    end
  end

  # --- queue -------------------------------------------------------------------

  def remote_queue_fixture
    write_plan_with_machine(@dir, "042", status: "WRAPPED 2026-09-14 18:41 -0600", machine: "mbp")
    write_consent(@dir, "042")
    write_plan(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600 after 042")
    write_consent(@dir, "043")
  end

  # sabotage: drop the predecessor-machine term from satisfied -> red here,
  # green in test_queued_behind_a_predecessor_bound_here_is_satisfied.
  def test_queued_behind_a_remote_predecessor_holds
    remote_queue_fixture

    with_user_config("machine" => { "name" => "air" }) do
      _, env = run_cli(["list", "--dir", @dir])
      q = env["data"]["campaigns"].find { |c| c["id"] == "043" }
      refute q["armed"]
      refute q["queue"]["satisfied"]
      assert_equal "mbp", q["queue"]["predecessor_machine"]
      assert_equal "other_machine", q["queue"]["predecessor_machine_match"]
      assert env["warnings"].any? { |w| w["code"] == "queue_predecessor_remote" }, env["warnings"].inspect
      assert_equal [], env["data"]["runnable"]
    end
  end

  def test_queued_behind_a_predecessor_bound_here_is_satisfied
    remote_queue_fixture

    with_user_config("machine" => { "name" => "mbp" }) do
      _, env = run_cli(["list", "--dir", @dir])
      q = env["data"]["campaigns"].find { |c| c["id"] == "043" }
      assert q["armed"]
      assert q["queue"]["satisfied"]
      assert_equal ["043"], env["data"]["runnable"]
    end
  end

  def test_queued_behind_a_predecessor_on_an_unnamed_machine_holds
    remote_queue_fixture

    with_user_config(nil) do
      _, env = run_cli(["list", "--dir", @dir])
      q = env["data"]["campaigns"].find { |c| c["id"] == "043" }
      refute q["armed"]
      refute q["queue"]["satisfied"]
      assert_equal "unverified", q["queue"]["predecessor_machine_match"]
      assert env["warnings"].any? { |w| w["code"] == "queue_predecessor_remote" }, env["warnings"].inspect
    end
  end
end

# arm --host: the one writer of the Machine line, and the refusals that
# keep arm/disarm from touching a plan bound elsewhere.
class CampaignStateArmHostTest < Minitest::Test
  include CampaignFixtures
  include UserConfigHelper

  def setup
    @dir = Dir.mktmpdir
    @previous_clock = CampaignState.clock
    CampaignState.clock = -> { FIXED_NOW }
  end

  def teardown
    CampaignState.clock = @previous_clock
    FileUtils.remove_entry(@dir)
  end

  def run_cli(argv)
    io = StringIO.new
    code = CampaignStateCli.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  # --- rewrite_machine (pure) ---------------------------------------------

  def test_rewrite_machine_inserts_after_the_status_line
    content = "# Campaign 042\n\nStatus: DRAFTED 2026-09-13\n\nBody.\n"
    rewritten = CampaignState.rewrite_machine(content, "mbp")
    assert_equal "# Campaign 042\n\nStatus: DRAFTED 2026-09-13\nMachine: mbp\n\nBody.\n", rewritten
  end

  def test_rewrite_machine_replaces_an_existing_line
    content = "# Campaign 042\n\nStatus: ARMED 2026-09-14\nMachine: air\n\nBody.\n"
    rewritten = CampaignState.rewrite_machine(content, "mbp")
    assert_equal "# Campaign 042\n\nStatus: ARMED 2026-09-14\nMachine: mbp\n\nBody.\n", rewritten
  end

  def test_rewrite_machine_inserts_after_the_h1_with_no_status_line
    content = "# Campaign 042\n\nBody.\n"
    rewritten = CampaignState.rewrite_machine(content, "mbp")
    assert_equal "# Campaign 042\n\nMachine: mbp\n\nBody.\n", rewritten
  end

  # --- arm --host writes the binding ----------------------------------------

  def test_arm_host_writes_status_and_machine_lines
    path = write_plan(@dir, "042", status: "DRAFTED 2026-09-13")
    write_consent(@dir, "042")

    with_user_config("machine" => { "name" => "mbp" }) do
      code, env = run_cli(["arm", "042", "--dir", @dir, "--host", "mbp"])

      assert_equal 0, code
      assert env["ok"], env.inspect
      assert_equal "mbp", env["data"]["machine_after"]
      assert env["data"]["campaign"]["runnable"]
      assert_equal "this_machine", env["data"]["campaign"]["machine_match"]
      content = File.read(path)
      assert_match(/\AStatus: ARMED 2026-09-14 20:00 -0600\nMachine: mbp\n/, content[content.index("Status:")..])
    end
  end

  def test_arm_host_refuses_a_name_that_is_not_this_machine
    path = write_plan(@dir, "042", status: "DRAFTED 2026-09-13")
    write_consent(@dir, "042")
    before = File.read(path)

    with_user_config("machine" => { "name" => "mbp" }) do
      code, env = run_cli(["arm", "042", "--dir", @dir, "--host", "air"])

      assert_equal 1, code
      assert_equal ["host_not_this_machine"], env["blocked"].map { |b| b["code"] }
      assert_equal before, File.read(path)
    end
  end

  def test_arm_host_refuses_when_the_machine_has_no_name
    path = write_plan(@dir, "042", status: "DRAFTED 2026-09-13")
    write_consent(@dir, "042")
    before = File.read(path)

    with_user_config(nil) do
      code, env = run_cli(["arm", "042", "--dir", @dir, "--host", "mbp"])

      assert_equal 1, code
      assert_equal ["machine_name_unset"], env["blocked"].map { |b| b["code"] }
      assert env["blocked"][0]["message"].include?("machine.name"), env["blocked"][0]["message"]
      assert_equal before, File.read(path)
    end
  end

  def test_arm_host_refuses_on_an_invalid_config
    path = write_plan(@dir, "042", status: "DRAFTED 2026-09-13")
    write_consent(@dir, "042")
    before = File.read(path)

    with_user_config("machine" => { "name" => "" }) do
      code, env = run_cli(["arm", "042", "--dir", @dir, "--host", "mbp"])

      assert_equal 1, code
      assert_equal ["user_config_invalid"], env["blocked"].map { |b| b["code"] }
      assert_equal before, File.read(path)
    end
  end

  def test_arm_host_on_an_already_armed_unbound_plan_only_writes_the_machine_line
    path = write_plan(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "042")
    status_line_before = File.read(path)[/^Status:.*$/]

    with_user_config("machine" => { "name" => "mbp" }) do
      code, env = run_cli(["arm", "042", "--dir", @dir, "--host", "mbp"])

      assert_equal 0, code
      assert env["data"]["changed"]
      assert_equal ["already_armed"], env["warnings"].map { |w| w["code"] }
      assert_equal status_line_before, File.read(path)[/^Status:.*$/]
      assert_includes File.read(path), "Machine: mbp\n"
    end
  end

  def test_arm_host_composes_with_after
    write_plan(@dir, "041", status: "ARMED 2026-09-14 18:41 -0600")
    write_consent(@dir, "041")
    path = write_plan(@dir, "042", status: "DRAFTED 2026-09-13")
    write_consent(@dir, "042")

    with_user_config("machine" => { "name" => "mbp" }) do
      code, env = run_cli(["arm", "042", "--dir", @dir, "--after", "041", "--host", "mbp"])

      assert_equal 0, code
      assert env["ok"], env.inspect
      content = File.read(path)
      assert_match(/Status: QUEUED 2026-09-14 20:00 -0600 after 041\nMachine: mbp\n/, content)
    end
  end

  def test_arm_host_on_a_queued_plan_drops_the_after_tail
    path = write_plan(@dir, "042", status: "QUEUED 2026-09-14 19:00 -0600 after 041")
    write_consent(@dir, "042")

    with_user_config("machine" => { "name" => "mbp" }) do
      code, env = run_cli(["arm", "042", "--dir", @dir, "--host", "mbp"])

      assert_equal 0, code
      assert env["ok"], env.inspect
      assert_equal 2, env["commands"].length
      assert_match(/\AStatus: ARMED 2026-09-14 20:00 -0600\nMachine: mbp\n/, File.read(path)[File.read(path).index("Status:")..])
    end
  end

  def test_arm_host_dry_run_touches_nothing
    path = write_plan(@dir, "042", status: "DRAFTED 2026-09-13")
    write_consent(@dir, "042")
    before = File.read(path)

    with_user_config("machine" => { "name" => "mbp" }) do
      code, env = run_cli(["arm", "042", "--dir", @dir, "--host", "mbp", "--dry-run"])

      assert_equal 0, code
      assert_equal 2, env["commands"].length
      assert_equal before, File.read(path)
    end
  end

  # --- arm/disarm refuse a foreign or unverifiable binding -------------------

  def test_arm_without_host_refuses_a_plan_bound_to_another_machine
    path = write_plan_with_machine(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600", machine: "mbp")
    write_consent(@dir, "042")
    before = File.read(path)

    with_user_config("machine" => { "name" => "air" }) do
      code, env = run_cli(["arm", "042", "--dir", @dir])

      assert_equal 1, code
      assert_equal ["bound_to_other_machine"], env["blocked"].map { |b| b["code"] }
      assert_equal before, File.read(path)
    end
  end

  def test_arm_without_host_refuses_a_plan_it_cannot_verify
    path = write_plan_with_machine(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600", machine: "mbp")
    write_consent(@dir, "042")
    before = File.read(path)

    with_user_config(nil) do
      code, env = run_cli(["arm", "042", "--dir", @dir])

      assert_equal 1, code
      assert_equal ["machine_name_unset"], env["blocked"].map { |b| b["code"] }
      assert_equal before, File.read(path)
    end
  end

  def test_disarm_refuses_a_plan_bound_to_another_machine
    path = write_plan_with_machine(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600", machine: "mbp")
    write_consent(@dir, "042")
    before = File.read(path)

    with_user_config("machine" => { "name" => "air" }) do
      code, env = run_cli(["disarm", "042", "--dir", @dir])

      assert_equal 1, code
      assert_equal ["bound_to_other_machine"], env["blocked"].map { |b| b["code"] }
      assert_equal before, File.read(path)
    end
  end

  def test_disarm_on_the_bound_machine_disarms_and_keeps_the_binding
    path = write_plan_with_machine(@dir, "042", status: "ARMED 2026-09-14 18:41 -0600", machine: "mbp")
    write_consent(@dir, "042")

    with_user_config("machine" => { "name" => "mbp" }) do
      code, env = run_cli(["disarm", "042", "--dir", @dir])

      assert_equal 0, code
      assert env["ok"], env.inspect
      assert_equal "DRAFTED", env["data"]["campaign"]["status"]
      assert_includes File.read(path), "Machine: mbp\n"
    end
  end

  # wu-vmia: disarm now rewrites QUEUED, and the foreign-machine refusal
  # must still stop it. sabotage: drop run_disarm's refuse_foreign_machine
  # line -> red (the plan is QUEUED, so the guard no longer catches it).
  def test_disarm_refuses_a_queued_plan_bound_to_another_machine
    path = write_plan_with_machine(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600 after 042", machine: "mbp")
    write_consent(@dir, "043")
    before = File.read(path)

    with_user_config("machine" => { "name" => "air" }) do
      code, env = run_cli(["disarm", "043", "--dir", @dir])

      assert_equal 1, code
      assert_equal ["bound_to_other_machine"], env["blocked"].map { |b| b["code"] }
      refute env["data"]["changed"]
      assert_equal before, File.read(path)
    end
  end

  def test_disarm_of_a_queued_plan_on_the_bound_machine_keeps_the_binding
    path = write_plan_with_machine(@dir, "043", status: "QUEUED 2026-09-14 19:00 -0600 after 042", machine: "mbp")
    write_consent(@dir, "043")

    with_user_config("machine" => { "name" => "mbp" }) do
      code, env = run_cli(["disarm", "043", "--dir", @dir])

      assert_equal 0, code
      assert_equal "QUEUED", env["data"]["before"]
      assert_includes File.read(path), "Status: DRAFTED 2026-09-14 20:00 -0600\nMachine: mbp\n"
    end
  end

  # --- usage -------------------------------------------------------------------

  def test_host_on_list_is_a_usage_error
    _code, status = capture_exit { run_cli(["list", "--dir", @dir, "--host", "mbp"]) }

    assert_equal 2, status
  end

  private

  def capture_exit
    yield
    [nil, 0]
  rescue SystemExit => e
    [nil, e.status]
  end
end

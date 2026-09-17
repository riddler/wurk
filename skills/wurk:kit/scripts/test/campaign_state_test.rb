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

  def test_list_warns_on_an_unknown_status_word_and_never_treats_it_as_armed
    write_plan(@dir, "260914-alpha", status: "PAUSED 2026-09-14")
    write_consent(@dir, "260914-alpha")

    _code, env = run_cli(["list", "--dir", @dir])

    campaign = env["data"]["campaigns"].fetch(0)
    assert_equal "PAUSED", campaign["status"]
    refute campaign["armed"]
    assert_equal ["unknown_status"], env["warnings"].map { |w| w["code"] }
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

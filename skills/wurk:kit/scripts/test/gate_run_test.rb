# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require "time"
require_relative "../gate_run"
require_relative "../lib/lock"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"

# GateRun: `start` (detached launch, optional lock acquisition), `supervise`
# (the detached child - never exercised via a real spawn here, since FakeSh
# never actually runs the recorded argv; its run dirs are built by hand to
# drive `poll`/`status`/`supervise` directly), `poll` (the bounded foreground
# wait), and `status` (read-only). See docs/plans/
# 260902-wu-4x9-long-gate-runner-and-lock-helper.md Phase 4.
class GateRunTest < Minitest::Test
  include ManifestHelper

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
    @orig_pwd = Dir.pwd
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
    Dir.chdir(@orig_pwd)
  end

  def run_gr(argv = [])
    io = StringIO.new
    code = GateRun.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  def capture_io_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  # --- start ------------------------------------------------------------

  def test_start_resolves_reporting_argv_and_records_it_for_the_supervisor
    in_tmp_repo("gate_tier1") do |dir|
      run_dir = File.join(dir, "run")
      code, env = run_gr(%W[start --run-dir #{run_dir}])

      assert_equal 0, code
      assert_equal run_dir, env["data"]["run_dir"]

      meta = JSON.parse(File.read(File.join(run_dir, "meta.json")))
      # gate_tier1 declares gate.report - the reporting variant - so that is
      # what gets recorded, never gate.full/gate.loop, and never a literal
      # gate tool name written by this script itself.
      assert_equal %w[make report], meta["argv"]

      assert_equal 1, @fake.detached_calls.size
      detached = @fake.detached_calls.first
      assert_includes detached.argv, "supervise"
      assert_includes detached.argv, "--run-dir"
      assert_includes detached.argv, run_dir
    end
  end

  def test_start_falls_back_to_gate_full_when_no_reporting_command_exists
    in_tmp_repo("valid") do |dir|
      run_dir = File.join(dir, "run")
      run_gr(%W[start --run-dir #{run_dir}])

      meta = JSON.parse(File.read(File.join(run_dir, "meta.json")))
      assert_equal %w[make check], meta["argv"]
    end
  end

  def test_start_deadline_uses_long_timeout_seconds_not_timeout_seconds
    in_tmp_repo("gate_tier1") do |dir|
      run_dir = File.join(dir, "run")
      run_gr(%W[start --run-dir #{run_dir}])

      meta = JSON.parse(File.read(File.join(run_dir, "meta.json")))
      started_at = Time.parse(meta["started_at"])
      deadline_at = Time.parse(meta["deadline_at"])

      # gate_tier1 fixture: gate.long_timeout_seconds = 3600, distinct from
      # gate.timeout_seconds' default of 600.
      assert_in_delta 3600, deadline_at - started_at, 1
    end
  end

  def test_start_dry_run_creates_no_run_dir_and_spawns_nothing
    in_tmp_repo("gate_tier1") do |dir|
      run_dir = File.join(dir, "run")
      code, env = run_gr(%W[start --dry-run --run-dir #{run_dir}])

      assert_equal 0, code
      refute Dir.exist?(run_dir)
      assert_empty @fake.calls
      assert_empty @fake.detached_calls
      assert_nil env["data"]["pid"]
      assert_equal [], env["data"]["locks"]
    end
  end

  def test_start_with_lock_flags_acquires_and_records_the_supervisor_pid
    in_tmp_repo("gate_tier1") do |dir|
      run_dir = File.join(dir, "run")
      lock_dir = File.join(dir, "locks", "gate-x")

      code, env = run_gr(%W[start --run-dir #{run_dir} --gate-lock #{lock_dir} --campaign c1 --bead zz-1])

      assert_equal 0, code
      assert Dir.exist?(lock_dir)

      owner = Lock.read_owner(lock_dir)
      assert_equal env["data"]["pid"].to_s, owner["pid"]
      # The pid recorded is the supervisor's (spawn_detached's return value),
      # never this process's own pid - the whole point of the rewrite.
      refute_equal Process.pid.to_s, owner["pid"]
      assert_equal "c1", owner["campaign"]
      assert_equal "zz-1", owner["bead"]

      assert_equal [{ "kind" => "gate", "dir" => lock_dir }], env["data"]["locks"]
    end
  end

  def test_start_usage_error_on_slots_dir_without_slots_count
    in_tmp_repo("gate_tier1") do |dir|
      err = capture_io_stderr do
        assert_raises(SystemExit) { GateRun.run(%W[start --run-dir #{dir}/run --slots-dir #{dir}/slots]) }
      end
      assert_match(/usage/, err)
    end
  end

  # --- poll ---------------------------------------------------------------

  def build_run_dir(dir, pid: Process.pid, deadline_at: Time.now.utc + 3600, log_path: nil)
    log = log_path || File.join(dir, "gate.log")
    File.write(log, "line one\nline two\n") unless File.exist?(log)
    meta = {
      "run_id" => "20260101T000000Z-1",
      "argv" => %w[make report],
      "chdir" => nil,
      "profile" => nil,
      "started_at" => Time.now.utc.iso8601,
      "deadline_at" => deadline_at.iso8601,
      "long_timeout_seconds" => 3600,
      "locks" => [],
      "lock_owner" => nil,
      "log_path" => log,
      "sentinel_path" => File.join(dir, "result.json"),
      "pid" => pid
    }
    File.write(File.join(dir, "meta.json"), JSON.generate(meta))
    dir
  end

  def write_result(dir, ok:, data: {})
    result = { "ok" => ok, "script" => "gate_run_supervise", "data" => data, "warnings" => [], "blocked" => [],
               "commands" => [] }
    File.write(File.join(dir, "result.json"), JSON.generate(result))
  end

  def test_poll_running_with_live_pid_exits_zero_and_includes_poll_command
    Dir.mktmpdir do |dir|
      build_run_dir(dir, pid: Process.pid)

      code, env = run_gr(%W[poll --run-dir #{dir} --wait-seconds 0])

      assert_equal 0, code
      assert_equal "running", env["data"]["state"]
      assert_match(/gate_run\.rb poll --run-dir #{Regexp.escape(dir)}/, env["data"]["poll_command"])
    end
  end

  def test_poll_finished_green_exits_zero
    Dir.mktmpdir do |dir|
      build_run_dir(dir)
      write_result(dir, ok: true, data: { "exit_status" => 0, "timed_out" => false, "duration_seconds" => 1.2,
                                           "log_path" => File.join(dir, "gate.log"), "output_tail" => "all green" })

      code, env = run_gr(%W[poll --run-dir #{dir} --wait-seconds 0])

      assert_equal 0, code
      assert_equal "finished", env["data"]["state"]
      assert_equal 0, env["data"]["exit_status"]
    end
  end

  def test_poll_finished_red_exits_one_with_supervisor_data
    Dir.mktmpdir do |dir|
      build_run_dir(dir)
      write_result(dir, ok: false, data: { "exit_status" => 1, "timed_out" => false, "duration_seconds" => 3.0,
                                            "log_path" => File.join(dir, "gate.log"), "output_tail" => "boom" })

      code, env = run_gr(%W[poll --run-dir #{dir} --wait-seconds 0])

      assert_equal 1, code
      assert_equal "finished", env["data"]["state"]
      assert_equal 1, env["data"]["exit_status"]
      assert_equal "boom", env["data"]["output_tail"]
    end
  end

  def test_poll_past_deadline_with_no_sentinel_is_abandoned
    Dir.mktmpdir do |dir|
      build_run_dir(dir, pid: Process.pid, deadline_at: Time.now.utc - 10)

      code, env = run_gr(%W[poll --run-dir #{dir} --wait-seconds 0])

      assert_equal 1, code
      assert_equal "abandoned", env["data"]["state"]
      assert_equal "deadline_exceeded", env["data"]["reason"]
    end
  end

  def test_poll_with_dead_supervisor_pid_and_no_sentinel_is_abandoned
    Dir.mktmpdir do |dir|
      dead_pid = fork { exit(0) }
      Process.wait(dead_pid)

      build_run_dir(dir, pid: dead_pid, deadline_at: Time.now.utc + 3600)

      code, env = run_gr(%W[poll --run-dir #{dir} --wait-seconds 0])

      assert_equal 1, code
      assert_equal "abandoned", env["data"]["state"]
      assert_equal "supervisor_pid_dead", env["data"]["reason"]
    end
  end

  def test_poll_never_observes_a_partial_sentinel
    Dir.mktmpdir do |dir|
      build_run_dir(dir, pid: Process.pid)
      File.write(File.join(dir, "result.json.part"), JSON.generate({ "ok" => true }))

      code, env = run_gr(%W[poll --run-dir #{dir} --wait-seconds 0])

      assert_equal 0, code
      assert_equal "running", env["data"]["state"]
    end
  end

  # --- status ---------------------------------------------------------------

  def test_status_always_exits_zero_even_when_abandoned
    Dir.mktmpdir do |dir|
      build_run_dir(dir, pid: Process.pid, deadline_at: Time.now.utc - 10)

      code, env = run_gr(%W[status --run-dir #{dir}])

      assert_equal 0, code
      assert_equal "abandoned", env["data"]["state"]
    end
  end

  def test_status_always_exits_zero_even_when_red
    Dir.mktmpdir do |dir|
      build_run_dir(dir)
      write_result(dir, ok: false, data: { "exit_status" => 1 })

      code, env = run_gr(%W[status --run-dir #{dir}])

      assert_equal 0, code
      assert_equal "finished", env["data"]["state"]
    end
  end

  # --- supervise --------------------------------------------------------------

  def test_supervise_writes_sentinel_by_rename_and_releases_locks_first
    Dir.mktmpdir do |dir|
      lock_dir = File.join(dir, "gate-x")
      owner = { "campaign" => "c1", "bead" => "zz-1", "pid" => Process.pid.to_s }
      Lock.try_acquire(lock_dir, owner)

      build_run_dir(dir, pid: Process.pid)
      meta = JSON.parse(File.read(File.join(dir, "meta.json")))
      meta["locks"] = [{ "kind" => "gate", "dir" => lock_dir }]
      meta["lock_owner"] = owner
      File.write(File.join(dir, "meta.json"), JSON.generate(meta))

      @fake.expect(%w[make report], out: "all good", exitstatus: 0)

      code, env = run_gr(%W[supervise --run-dir #{dir}])

      assert_equal 0, code
      assert env["ok"]
      assert File.exist?(File.join(dir, "result.json"))
      refute File.exist?(File.join(dir, "result.json.part"))
      refute Dir.exist?(lock_dir), "the gate lock should have been released"
      assert_equal 0, env["data"]["exit_status"]
    end
  end

  def test_supervise_still_writes_a_sentinel_when_release_raises
    Dir.mktmpdir do |dir|
      lock_dir = File.join(dir, "gate-x")
      owner = { "campaign" => "c1", "bead" => "zz-1", "pid" => Process.pid.to_s }
      Lock.try_acquire(lock_dir, owner)

      build_run_dir(dir, pid: Process.pid)
      meta = JSON.parse(File.read(File.join(dir, "meta.json")))
      meta["locks"] = [{ "kind" => "gate", "dir" => lock_dir }]
      meta["lock_owner"] = owner
      File.write(File.join(dir, "meta.json"), JSON.generate(meta))

      @fake.expect(%w[make report], out: "all good", exitstatus: 0)

      original_release = Lock.method(:release)
      begin
        Lock.define_singleton_method(:release) { |*_args, **_kwargs| raise "boom" }

        code, env = run_gr(%W[supervise --run-dir #{dir}])

        assert_equal 0, code
        assert File.exist?(File.join(dir, "result.json")), "a sentinel must still be written when release raises"
        assert(env["warnings"].any? { |w| w["code"] == "gate_run_lock_release_failed" })
      ensure
        Lock.define_singleton_method(:release, original_release)
      end
    end
  end

  # --- usage errors -----------------------------------------------------------

  def test_unknown_subcommand_is_a_usage_error_not_an_envelope
    err = capture_io_stderr { assert_raises(SystemExit) { GateRun.run(["bogus"]) } }
    assert_match(/usage/, err)
  end

  def test_poll_without_run_dir_is_a_usage_error_not_an_envelope
    err = capture_io_stderr { assert_raises(SystemExit) { GateRun.run(["poll"]) } }
    assert_match(/usage/, err)
  end
end

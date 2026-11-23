# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../worker_cap"
require_relative "support/user_config_helper"
require_relative "support/dead_pid"

# worker_cap.rb check: the one question every dispatcher asks - may I start
# another worker now. The load reader, clock and capture root are fixtures,
# so no test reads the real machine or the operator's captures.
class WorkerCapCliTest < Minitest::Test
  include UserConfigHelper

  NOW = Time.at(1_800_000_000)
  CALM = { one: 1.0, five: 1.0, ncpu: 8, memory: "normal" }.freeze

  def setup
    @dir = Dir.mktmpdir("worker-cap-cli-")
    @saved_env = ENV.to_h.slice("XDG_STATE_HOME", "CLAUDE_LIMITS_ROOT")
    ENV["XDG_STATE_HOME"] = File.join(@dir, "state")
    ENV["CLAUDE_LIMITS_ROOT"] = File.join(@dir, "limits")
    @reading = CALM
    WorkerCapCli.load_reader = -> { @reading }
    WorkerCapCli.clock = -> { NOW }
  end

  def teardown
    WorkerCapCli.load_reader = nil
    WorkerCapCli.clock = nil
    WorkerCapCli.refresher = nil
    %w[XDG_STATE_HOME CLAUDE_LIMITS_ROOT].each { |k| ENV[k] = @saved_env[k] }
    FileUtils.remove_entry(@dir)
  end

  def state_path
    File.join(@dir, "state", "wurk", "worker-cap.json")
  end

  def machine(workers: { "ceiling" => 4 }, gate_slots: nil)
    section = { "workers" => workers }
    section["gate_slots"] = gate_slots if gate_slots
    { "machine" => section }
  end

  def run_cli(argv, config: machine)
    with_user_config(config) do
      io = StringIO.new
      code = WorkerCapCli.run(argv, io: io)
      [code, JSON.parse(io.string)]
    end
  end

  # [exit status, stdout, stderr] for a call that ends in exit.
  def run_usage(argv, config: machine)
    with_user_config(config) do
      io = StringIO.new
      err = StringIO.new
      original = $stderr
      $stderr = err
      begin
        WorkerCapCli.run(argv, io: io)
        flunk "expected a usage exit"
      rescue SystemExit => e
        [e.status, io.string, err.string]
      ensure
        $stderr = original
      end
    end
  end

  def write_capture(week:, fable: 0)
    dir = File.join(@dir, "limits", ".state")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "current.json"), JSON.generate(
      "account" => { "email" => "a@example.com" },
      "captured_at" => NOW.to_i - 60,
      "windows" => {
        "seven_day" => { "used_percentage" => week, "resets_at" => NOW.to_i + 86_400 },
        "seven_day_fable" => { "used_percentage" => fable, "resets_at" => NOW.to_i + 86_400 }
      }
    ))
  end

  # 4.1#1 / AC1.
  def test_a_well_formed_caller_gets_the_envelope
    write_capture(week: 20)
    code, env = run_cli(%w[check --caller fleet-a --running 1])
    assert_equal 0, code
    assert env["ok"]
    assert_equal "worker_cap", env["script"]
    data = env["data"]
    assert_equal 4, data["cap"]
    assert_equal 4, data["ceiling"]
    assert_equal "calm", data["zone"]
    assert_equal 3, data["headroom"]
    assert_equal true, data["dispatch"]
    assert_equal({ "caller" => 1, "machine" => 1 }, data["running"])
    assert_equal({ "one" => 1.0, "five" => 1.0, "ncpu" => 8, "per_core" => 0.13 }, data["load"])
    assert_equal "normal", data["memory"]
    assert_nil data["gate_slots"]
    assert_equal NOW.utc.iso8601, data["read_at"]
    refute data["account"]["paused"]
    assert_equal 20, data["account"]["week_used"]
    assert File.file?(state_path)
  end

  def test_the_default_ceiling_follows_the_core_count
    @reading = CALM.merge(ncpu: 12)
    _code, env = run_cli(%w[check --caller x --running 0 --no-refresh], config: nil)
    assert_equal 3, env["data"]["ceiling"]
    assert_equal 3, env["data"]["cap"]
  end

  # 4.1#2. sabotage: validate the caller after reading the config -> red.
  def test_a_malformed_caller_id_is_refused_before_any_read
    WorkerCapCli.load_reader = -> { flunk "the load must not be read" }
    status, out, err = run_usage(["check", "--caller", "../x", "--running", "1"])
    assert_equal 2, status
    assert_empty out
    assert_match(/--caller/, err)
    refute File.exist?(state_path)
  end

  def test_a_missing_caller_or_subcommand_is_a_usage_error
    assert_equal 2, run_usage(%w[check --running 1]).first
    assert_equal 2, run_usage(%w[check --caller a]).first
    assert_equal 2, run_usage(%w[status --caller a --running 1]).first
  end

  # 4.1#3 / AC5. sabotage: let the flag replace the ceiling -> red.
  def test_a_ceiling_flag_above_the_machine_ceiling_does_not_raise_the_cap
    _code, env = run_cli(%w[check --caller a --running 0 --ceiling 5 --no-refresh],
                         config: machine(workers: { "ceiling" => 2 }))
    assert_equal 2, env["data"]["cap"]
    assert_equal 2, env["data"]["ceiling"]
    assert_includes env["warnings"].map { |w| w["code"] }, "ceiling_overridden"
  end

  # 4.1#4. sabotage: store the flag-lowered cap as the level -> red.
  def test_a_ceiling_flag_below_lowers_this_answer_only
    _code, first = run_cli(%w[check --caller a --running 0 --ceiling 1 --no-refresh])
    _code, second = run_cli(%w[check --caller a --running 0 --no-refresh])
    assert_equal 1, first["data"]["cap"]
    assert_equal 4, second["data"]["cap"]
    assert_equal 4, JSON.parse(File.read(state_path))["level_state"]["level"]
  end

  # sabotage: let the flag replace the cap rather than bound it -> red.
  def test_a_ceiling_flag_never_lifts_a_lower_reading
    @reading = CALM.merge(one: 9.0, five: 9.0)
    _code, env = run_cli(%w[check --caller a --running 0 --ceiling 2 --no-refresh])
    assert_equal 0, env["data"]["cap"]
    assert_equal false, env["data"]["dispatch"]
  end

  # sabotage: drop the SystemCallError rescue -> red (a backtrace, no envelope).
  def test_an_unwritable_state_dir_blocks_with_an_envelope
    blocker = File.join(@dir, "not-a-dir")
    File.write(blocker, "")
    ENV["XDG_STATE_HOME"] = blocker
    code, env = run_cli(%w[check --caller a --running 0 --no-refresh])
    assert_equal 1, code
    assert_equal ["state_unwritable"], env["blocked"].map { |b| b["code"] }
  end

  # 4.1#5.
  def test_a_negative_or_non_integer_running_count
    assert_equal 2, run_usage(%w[check --caller a --running -1]).first
    assert_equal 2, run_usage(%w[check --caller a --running two]).first
    assert_equal 2, run_usage(%w[check --caller a --running 1.5]).first
    assert_equal 2, run_usage(%w[check --caller a --running 1 --ceiling 0]).first
    refute File.exist?(state_path)
  end

  # 4.1#6. sabotage: emit a reading on an invalid config -> red.
  def test_thresholds_out_of_order
    code, env = run_cli(%w[check --caller a --running 0],
                        config: machine(workers: { "load_step_up" => 0.9, "load_step_down" => 0.5 }))
    assert_equal 1, code
    assert_includes env["blocked"].map { |b| b["code"] }, "bad_machine_config"
    refute File.exist?(state_path)
  end

  # 4.1#7. sabotage: ignore free slots in headroom -> red.
  def test_free_slots_bound_the_headroom
    slots = File.join(@dir, "slots")
    Lock.try_acquire(File.join(slots, "slot-1"), "campaign" => "c", "bead" => "b", "pid" => Process.pid)
    _code, env = run_cli(["check", "--caller", "a", "--running", "0", "--slots-dir", slots, "--no-refresh"],
                         config: machine(gate_slots: 2))
    assert_equal({ "count" => 2, "free" => 1 }, env["data"]["gate_slots"])
    assert_equal 1, env["data"]["headroom"]
    assert Dir.exist?(File.join(slots, "slot-1")), "counting must not touch a held slot"
  end

  # 4.1#8.
  def test_a_slots_dir_with_no_machine_slot_count
    status, _out, err = run_usage(["check", "--caller", "a", "--running", "0", "--slots-dir", @dir])
    assert_equal 2, status
    assert_match(/gate_slots/, err)
  end

  # 4.1#9 / AC3. sabotage: zero the cap on a pause -> red.
  def test_an_account_pause_turns_dispatch_off_and_leaves_the_cap_alone
    write_capture(week: 100)
    code, env = run_cli(%w[check --caller a --running 0 --no-refresh])
    assert_equal 0, code
    assert_equal 4, env["data"]["cap"]
    assert_equal 4, env["data"]["headroom"]
    assert_equal true, env["data"]["account"]["paused"]
    assert_equal "week_spent", env["data"]["account"]["reason"]
    assert_equal false, env["data"]["dispatch"]
  end

  def test_a_fable_week_pauses_only_with_model_fable
    write_capture(week: 30, fable: 100)
    _code, plain = run_cli(%w[check --caller a --running 0 --no-refresh])
    _code, fable = run_cli(%w[check --caller a --running 0 --no-refresh --model fable])
    assert plain["data"]["dispatch"]
    refute fable["data"]["dispatch"]
  end

  # 4.1#10. sabotage: exit 1 on cap 0 -> red.
  def test_cap_zero_is_a_reading_not_a_failure
    @reading = CALM.merge(one: 9.0, five: 9.0)
    code, env = run_cli(%w[check --caller a --running 0 --no-refresh])
    assert_equal 0, code
    assert env["ok"]
    assert_equal 0, env["data"]["cap"]
    assert_equal false, env["data"]["dispatch"]
    assert_equal "pause", env["data"]["zone"]
  end

  def test_running_counts_sum_across_callers
    run_cli(%w[check --caller fleet-a --running 2 --no-refresh])
    _code, env = run_cli(%w[check --caller lane --running 1 --no-refresh])
    assert_equal({ "caller" => 1, "machine" => 3 }, env["data"]["running"])
    assert_equal 1, env["data"]["headroom"]
  end

  def test_unknown_memory_and_missing_capture_warn
    @reading = CALM.merge(memory: "unknown")
    _code, env = run_cli(%w[check --caller a --running 0 --no-refresh])
    codes = env["warnings"].map { |w| w["code"] }
    assert_includes codes, "memory_unknown"
    assert_includes codes, "account_reading_unknown"
    assert env["data"]["dispatch"], "an unknown account reading is not a pause"
  end

  def test_dry_run_writes_no_state_and_runs_no_refresh
    WorkerCapCli.refresher = -> { flunk "dry run must not refresh" }
    code, env = run_cli(%w[check --caller a --running 0 --dry-run])
    assert_equal 0, code
    assert_equal 4, env["data"]["cap"]
    refute File.exist?(state_path)
  end

  def test_no_refresh_skips_the_refresher
    dir = File.join(@dir, "limits", ".state")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "current.json"), JSON.generate(
      "captured_at" => NOW.to_i - 5000,
      "windows" => { "seven_day" => { "used_percentage" => 10, "resets_at" => NOW.to_i + 60 } }
    ))
    calls = 0
    WorkerCapCli.refresher = -> { calls += 1 }
    run_cli(%w[check --caller a --running 0 --no-refresh])
    assert_equal 0, calls
    run_cli(%w[check --caller a --running 0])
    assert_equal 1, calls
  end
end

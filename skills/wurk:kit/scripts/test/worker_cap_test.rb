# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../lib/worker_cap"
require_relative "support/user_config_helper"

# WorkerCap.decide, .headroom, .default_ceiling, and WorkerCap::Store - the
# pure rule and its state file behind worker_cap.rb check. Fixtures are an
# 8-core machine with the default marks, so per-core 0.50 / 0.75 / 1.00 are
# load 4.0 (step up), 6.0 (step down) and 8.0 (pause).
class WorkerCapDecideTest < Minitest::Test
  NOW = Time.at(1_800_000_000)

  CONFIG = {
    "ceiling" => 4,
    "load_step_up" => 0.50,
    "load_step_down" => 0.75,
    "load_pause" => 1.00,
    "raise_after_seconds" => 180
  }.freeze

  def reading(one: 1.0, five: 1.0, ncpu: 8, memory: "normal")
    { one: one, five: five, ncpu: ncpu, memory: memory }
  end

  def ago(seconds)
    NOW.to_i - seconds
  end

  def decide(reading_args = {}, state: nil, config: {})
    WorkerCap.decide(reading: reading(**reading_args), state: state,
                     config: CONFIG.merge(config), now: NOW)
  end

  # 1.1#1. sabotage: start a missing state at level 1 -> red.
  def test_first_reading_on_a_calm_machine_starts_at_the_ceiling
    result = decide
    assert_equal "calm", result[:zone]
    assert_equal 4, result[:level]
    assert_equal 4, result[:cap]
  end

  # 1.1#2. sabotage: drop the load_step_down comparison -> red.
  def test_load_at_the_step_down_mark_drops_one_step
    result = decide({ one: 6.0, five: 6.0 }, state: { "level" => 4, "last_lowered" => ago(61) })
    assert_equal "high", result[:zone]
    assert_equal 3, result[:level]
    assert_equal 3, result[:cap]
    assert_includes result[:reasons], "load_high"
    assert_equal NOW.to_i, result[:state]["last_lowered"]
  end

  # 1.1#3. sabotage: ignore last_lowered -> red.
  def test_a_second_high_reading_inside_60_seconds_does_not_drop_again
    result = decide({ one: 7.0, five: 7.0 }, state: { "level" => 3, "last_lowered" => ago(20) })
    assert_equal 3, result[:level]
    assert_equal 3, result[:cap]
  end

  # 1.1#4.
  def test_level_never_drops_under_one
    result = decide({ one: 6.5, five: 6.5 }, state: { "level" => 1, "last_lowered" => ago(300) })
    assert_equal "high", result[:zone]
    assert_equal 1, result[:level]
    assert_equal 1, result[:cap]
  end

  # 1.1#5. sabotage: let the pause zone answer cap = level -> red.
  def test_load_at_the_pause_mark_is_cap_zero
    result = decide({ one: 8.0, five: 8.0 }, state: { "level" => 3, "last_lowered" => ago(61) })
    assert_equal "pause", result[:zone]
    assert_equal 0, result[:cap]
    assert_equal 2, result[:level]
    assert_includes result[:reasons], "load_pause"
  end

  # 1.1#6. sabotage: ignore memory warn -> red.
  def test_memory_warn_steps_down_with_a_calm_load
    result = decide({ memory: "warn" }, state: { "level" => 4 })
    assert_equal "high", result[:zone]
    assert_equal 3, result[:level]
    assert_includes result[:reasons], "memory_warn"
  end

  # 1.1#7. sabotage: ignore memory critical -> red.
  def test_memory_critical_is_cap_zero
    result = decide({ memory: "critical" }, state: { "level" => 4 })
    assert_equal "pause", result[:zone]
    assert_equal 0, result[:cap]
    assert_includes result[:reasons], "memory_critical"
  end

  # 1.1#8. sabotage: keep calm_since in the steady zone -> red.
  def test_the_dead_band_holds_the_level_and_clears_the_calm_clock
    result = decide({ one: 5.0, five: 5.0 }, state: { "level" => 2, "calm_since" => ago(170) })
    assert_equal "steady", result[:zone]
    assert_equal 2, result[:level]
    assert_nil result[:state]["calm_since"]
  end

  # 1.1#9. sabotage: raise without waiting raise_after_seconds -> red.
  def test_calm_for_less_than_raise_after_holds
    result = decide({ one: 2.0, five: 2.0 }, state: { "level" => 2, "calm_since" => ago(100) })
    assert_equal "calm", result[:zone]
    assert_equal 2, result[:level]
  end

  # 1.1#10. sabotage: raise straight to the ceiling -> red.
  def test_calm_for_raise_after_steps_up_one_not_to_the_ceiling
    result = decide({ one: 2.0, five: 2.0 },
                    state: { "level" => 2, "calm_since" => ago(181), "last_change" => ago(181) })
    assert_equal 3, result[:level]
    assert_equal 3, result[:cap]
    assert_equal NOW.to_i, result[:state]["calm_since"]
  end

  # The level must also not have moved for raise_after_seconds.
  def test_a_recent_change_holds_the_raise
    result = decide({ one: 2.0, five: 2.0 },
                    state: { "level" => 2, "calm_since" => ago(181), "last_change" => ago(30) })
    assert_equal 2, result[:level]
  end

  # 1.1#11. sabotage: read only the 1 minute load for calm -> red.
  def test_a_calm_one_minute_load_with_a_busy_five_minute_load_is_not_calm
    result = decide({ one: 2.0, five: 5.0 }, state: { "level" => 2, "calm_since" => ago(600) })
    assert_equal "steady", result[:zone]
    assert_equal 2, result[:level]
  end

  # 1.1#12.
  def test_level_never_passes_the_ceiling
    result = decide({}, state: { "level" => 4, "calm_since" => ago(600), "last_change" => ago(600) })
    assert_equal 4, result[:level]
  end

  # 1.1#13. sabotage: skip the clamp to the ceiling -> red.
  def test_a_ceiling_lowered_in_config_pulls_the_level_down
    result = decide({ one: 5.0, five: 5.0 }, state: { "level" => 4 }, config: { "ceiling" => 2 })
    assert_equal 2, result[:level]
    assert_equal 2, result[:cap]
  end

  # 1.1#14. sabotage: treat an unreadable load as calm -> red.
  def test_an_unreadable_load_is_cap_zero_with_the_level_kept
    result = decide({ one: nil, five: nil }, state: { "level" => 3 })
    assert_equal "unknown", result[:zone]
    assert_equal 0, result[:cap]
    assert_equal 3, result[:level]
    assert_includes result[:reasons], "load_unknown"
  end

  def test_an_unknown_core_count_is_an_unreadable_load
    result = decide({ ncpu: nil }, state: { "level" => 3 })
    assert_equal "unknown", result[:zone]
    assert_equal 0, result[:cap]
  end

  # 1.1#15.
  def test_unknown_memory_reads_as_normal
    result = decide({ memory: "unknown" }, state: { "level" => 2 })
    assert_equal "calm", result[:zone]
    assert(result[:reasons].none? { |r| r.start_with?("memory") })
  end

  # 1.1#16 (I6): no usage number enters the decision.
  def test_the_decision_takes_no_usage_input
    plain = decide({}, state: { "level" => 3 })
    with_usage = WorkerCap.decide(reading: reading.merge(week_used: 100, fable_used: 100),
                                  state: { "level" => 3 }, config: CONFIG, now: NOW)
    assert_equal plain, with_usage
    params = WorkerCap.method(:decide).parameters.map(&:last)
    assert_equal %i[reading state config now], params
  end

  # 1.2
  def test_headroom_room_under_the_cap
    assert_equal 3, WorkerCap.headroom(cap: 4, machine_running: 1, free_slots: nil)
  end

  def test_headroom_free_slots_bound_the_room
    assert_equal 1, WorkerCap.headroom(cap: 4, machine_running: 1, free_slots: 1)
  end

  def test_headroom_no_free_slot_is_no_room
    assert_equal 0, WorkerCap.headroom(cap: 4, machine_running: 0, free_slots: 0)
  end

  # sabotage: drop the floor at 0 -> red.
  def test_headroom_running_above_the_cap_floors_at_zero
    assert_equal 0, WorkerCap.headroom(cap: 2, machine_running: 5)
  end

  # 1.3
  def test_default_ceiling
    assert_equal 4, WorkerCap.default_ceiling(18)
    assert_equal 2, WorkerCap.default_ceiling(8)
    assert_equal 1, WorkerCap.default_ceiling(2)
    assert_equal 1, WorkerCap.default_ceiling(nil)
    assert_equal 4, WorkerCap.default_ceiling(64)
  end

  def test_caller_id_rule
    assert WorkerCap.valid_caller?("fleet-a")
    assert WorkerCap.valid_caller?("lane:build.2")
    refute WorkerCap.valid_caller?("../x")
    refute WorkerCap.valid_caller?("Fleet")
    refute WorkerCap.valid_caller?("")
    refute WorkerCap.valid_caller?("a" * 65)
  end
end

class WorkerCapStoreTest < Minitest::Test
  NOW = Time.at(1_800_000_000)

  def setup
    @dir = Dir.mktmpdir("worker-cap-store-")
    @path = File.join(@dir, "wurk", "worker-cap.json")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def update(now = NOW, &block)
    WorkerCap::Store.update(@path, now: now, &block)
  end

  # 1.4#1. sabotage: replace the whole callers map on report -> red.
  def test_a_callers_report_replaces_only_its_own_entry
    update { |s| s.report("fleet-a", 2) }
    update { |s| s.report("lane", 1) }
    running = update do |s|
      s.report("fleet-a", 0)
      s.machine_running
    end
    assert_equal 1, running
    lane = JSON.parse(File.read(@path))["callers"]["lane"]
    assert_equal 1, lane["running"]
  end

  # 1.4#2. sabotage: drop the 900 s cutoff -> red.
  def test_a_report_older_than_900_seconds_is_dropped
    update(NOW - 901) { |s| s.report("fleet-a", 3) }
    update(NOW - 10) { |s| s.report("lane", 1) }
    assert_equal 1, update { |s| s.machine_running }
  end

  # 1.4#3. sabotage: write in place, or skip the chmod -> red.
  def test_the_file_is_written_0600_and_replaced_by_rename
    update { |s| s.report("a", 1) }
    assert_equal 0o600, File.stat(@path).mode & 0o777
    before = File.read(@path)
    assert_raises(RuntimeError) do
      update do |s|
        s.report("a", 5)
        raise "interrupted"
      end
    end
    assert_equal before, File.read(@path), "an interrupted update must leave the old file whole"
    leftovers = Dir.children(File.dirname(@path)).reject { |n| n.start_with?("worker-cap.json") }
    assert_empty leftovers
    assert_empty Dir.children(File.dirname(@path)).grep(/tmp/)
  end

  # 1.4#4. sabotage: remove the flock -> red (one report is lost).
  def test_two_updates_at_once_both_land
    lib = File.expand_path("../lib/worker_cap", __dir__)
    script = <<~RUBY
      require #{lib.inspect}
      WorkerCap::Store.update(ARGV[0], now: Time.now) do |s|
        s.report(ARGV[1], 1)
        sleep 0.4
      end
    RUBY
    pids = %w[a b].map do |name|
      Process.spawn(RbConfig.ruby, "-e", script, @path, name, out: File::NULL, err: File::NULL)
    end
    pids.each { |pid| Process.wait(pid) }
    assert_equal 2, WorkerCap::Store.update(@path, now: Time.now, &:machine_running)
  end

  # 1.4#5. sabotage: let a parse error raise -> red.
  def test_a_corrupt_state_file_reads_as_no_state_with_a_warning
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "{")
    store = nil
    update { |s| store = s }
    assert_includes store.warnings, "state_reset"
    assert_nil store.level_state
  end

  def test_decide_through_the_store_keeps_the_level_between_readings
    config = { "ceiling" => 4, "load_step_up" => 0.5, "load_step_down" => 0.75,
               "load_pause" => 1.0, "raise_after_seconds" => 180 }
    high = { one: 6.0, five: 6.0, ncpu: 8, memory: "normal" }
    first = update { |s| s.decide(reading: high, config: config) }
    second = update(NOW + 61) { |s| s.decide(reading: high, config: config) }
    assert_equal 3, first[:level]
    assert_equal 2, second[:level]
  end

  def test_state_path_prefers_xdg_state_home
    assert_equal "/x/state/wurk/worker-cap.json",
                 WorkerCap.state_path(env: { "XDG_STATE_HOME" => "/x/state" }, home: "/h")
    assert_equal "/h/.local/state/wurk/worker-cap.json", WorkerCap.state_path(env: {}, home: "/h")
  end
end

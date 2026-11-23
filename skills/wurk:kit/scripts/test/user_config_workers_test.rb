# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/user_config"
require_relative "support/user_config_helper"

# machine.workers in the machine config: the worker-cap ceiling and load
# marks worker_cap.rb reads. All optional; absent keys take the defaults.
class UserConfigWorkersTest < Minitest::Test
  def config(workers = nil, machine: {})
    section = machine.dup
    section["workers"] = workers unless workers.nil?
    UserConfig.new(path: "(fixture)", raw: { "machine" => section })
  end

  # 6.1#1. sabotage: change a default mark -> red.
  def test_absent_section_gives_the_defaults
    workers = config.machine_workers(ncpu: 18)
    assert_equal 4, workers["ceiling"]
    assert_equal "default", workers["ceiling_source"]
    assert_equal 0.5, workers["load_step_up"]
    assert_equal 0.75, workers["load_step_down"]
    assert_equal 1.0, workers["load_pause"]
    assert_equal 180, workers["raise_after_seconds"]
  end

  def test_no_file_at_all_gives_the_defaults
    workers = UserConfig.new(path: "(fixture)", raw: {}, exists: false).machine_workers(ncpu: 8)
    assert_equal 2, workers["ceiling"]
  end

  # 6.1#2. sabotage: ignore a set value -> red.
  def test_set_values_win
    cfg = config("ceiling" => 2, "load_pause" => 0.67, "load_step_down" => 0.5, "load_step_up" => 0.35,
                 "raise_after_seconds" => 0)
    assert cfg.valid?, cfg.errors.inspect
    workers = cfg.machine_workers(ncpu: 18)
    assert_equal 2, workers["ceiling"]
    assert_equal "machine_config", workers["ceiling_source"]
    assert_equal 0.35, workers["load_step_up"]
    assert_equal 0.5, workers["load_step_down"]
    assert_equal 0.67, workers["load_pause"]
    assert_equal 0, workers["raise_after_seconds"]
  end

  # 6.1#3. sabotage: accept a zero ceiling -> red.
  def test_a_zero_or_negative_ceiling
    [0, -1, 1.5, "2"].each do |bad|
      cfg = config("ceiling" => bad)
      refute cfg.valid?, "ceiling #{bad.inspect} must block"
      assert(cfg.errors.any? { |e| e.include?("machine.workers.ceiling") }, cfg.errors.inspect)
    end
  end

  def test_bad_marks_and_raise_after
    refute config("load_step_up" => 0).valid?
    refute config("load_pause" => "1").valid?
    refute config("raise_after_seconds" => -1).valid?
    refute config("raise_after_seconds" => 1.5).valid?
    refute UserConfig.new(path: "(fixture)", raw: { "machine" => { "workers" => [] } }).valid?
  end

  # 6.1#4. sabotage: drop the order check -> red.
  def test_out_of_order_thresholds
    cfg = config("load_step_down" => 1.2, "load_pause" => 1.0)
    refute cfg.valid?
    assert(cfg.errors.any? { |e| e.include?("load_step_up < load_step_down < load_pause") }, cfg.errors.inspect)
  end

  def test_the_order_check_fills_absent_marks_with_defaults
    refute config("load_step_up" => 0.9).valid?, "0.9 is above the default step-down of 0.75"
    assert config("load_step_up" => 0.6).valid?
  end

  # 6.1#5. sabotage: leave workers out of KNOWN -> red.
  def test_machine_workers_keys_are_known
    cfg = config({ "ceiling" => 2, "load_step_up" => 0.4, "load_step_down" => 0.6, "load_pause" => 0.9,
                   "raise_after_seconds" => 60 }, machine: { "name" => "box", "gate_slots" => 2 })
    assert cfg.valid?, cfg.errors.inspect
    assert_empty cfg.warnings
    assert_equal 1, config("nope" => 1).warnings.length
  end

  # 6.1#6.
  def test_machine_gate_slots_reads_as_before
    assert_equal 4, config(nil, machine: { "gate_slots" => 4 }).machine_gate_slots
  end
end

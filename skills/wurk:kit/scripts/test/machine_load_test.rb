# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/machine_load"
require_relative "support/fake_sh"

# MachineLoad.read: the 1 and 5 minute load, the core count and the memory
# pressure level, from sysctl on macOS and /proc/loadavg on Linux. Every
# shell-out goes through a FakeSh, so no test reads the real machine.
class MachineLoadTest < Minitest::Test
  LOADAVG = %w[sysctl -n vm.loadavg].freeze
  NCPU = %w[sysctl -n hw.ncpu].freeze
  PRESSURE = %w[sysctl -n kern.memorystatus_vm_pressure_level].freeze

  def mac(loadavg: "{ 2.80 1.96 1.99 }\n", ncpu: "18\n", pressure: "1\n", loadavg_exit: 0, pressure_exit: 0)
    fake = FakeSh.new
    fake.expect(LOADAVG, out: loadavg, exitstatus: loadavg_exit)
    fake.expect(NCPU, out: ncpu)
    fake.expect(PRESSURE, out: pressure, exitstatus: pressure_exit)
    MachineLoad.read(runner: fake, os: "darwin23")
  end

  # 2.1#1. sabotage: read the 15 minute field as five -> red.
  def test_macos_output_parses
    result = mac
    assert_equal 2.8, result[:one]
    assert_equal 1.96, result[:five]
    assert_equal 18, result[:ncpu]
    assert_equal "normal", result[:memory]
  end

  # 2.1#2. sabotage: map 4 to warn -> red.
  def test_pressure_two_and_four
    assert_equal "warn", mac(pressure: "2\n")[:memory]
    assert_equal "critical", mac(pressure: "4\n")[:memory]
  end

  # 2.1#3. A failed command's output is not trusted, whatever it printed.
  # sabotage: parse the output of a failed sysctl -> red.
  def test_sysctl_fails
    result = mac(loadavg: "{ 9.00 9.00 9.00 }\n", loadavg_exit: 1)
    assert_nil result[:one]
    assert_nil result[:five]
  end

  # 2.1#4.
  def test_no_pressure_key
    result = mac(pressure: "", pressure_exit: 1)
    assert_equal "unknown", result[:memory]
    assert_equal 2.8, result[:one]
  end

  def test_an_unexpected_pressure_value_is_unknown
    assert_equal "unknown", mac(pressure: "9\n")[:memory]
  end

  # 2.1#5. sabotage: read the third field as five -> red.
  def test_linux_form
    Dir.mktmpdir do |dir|
      path = File.join(dir, "loadavg")
      File.write(path, "0.52 0.40 0.31 1/123 456\n")
      result = MachineLoad.read(runner: FakeSh.new, os: "linux-gnu", loadavg_path: path, nprocessors: -> { 4 })
      assert_equal 0.52, result[:one]
      assert_equal 0.4, result[:five]
      assert_equal 4, result[:ncpu]
      assert_equal "unknown", result[:memory]
    end
  end

  def test_linux_unreadable_loadavg
    result = MachineLoad.read(runner: FakeSh.new, os: "linux-gnu", loadavg_path: "/nonexistent/loadavg",
                              nprocessors: -> { 4 })
    assert_nil result[:one]
  end
end

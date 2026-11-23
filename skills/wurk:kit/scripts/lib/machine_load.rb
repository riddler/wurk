# frozen_string_literal: true

require "etc"
require "rbconfig"
require_relative "sh"

# MachineLoad reads the three facts worker_cap.rb decides from: the 1 and 5
# minute load averages, the core count, and the memory pressure level.
#
# macOS: `sysctl -n vm.loadavg` ("{ 2.80 1.96 1.99 }"), `sysctl -n hw.ncpu`,
# and `sysctl -n kern.memorystatus_vm_pressure_level` (1 normal, 2 warn,
# 4 critical). Linux: /proc/loadavg and the processor count; memory reads
# "unknown" there, which the cap treats as normal and the CLI reports as a
# warning.
#
# Never raises. A load or core count it cannot read is nil, and the cap
# answers zone unknown, cap 0; it never guesses a calm machine.
module MachineLoad
  PRESSURE_LEVELS = { 1 => "normal", 2 => "warn", 4 => "critical" }.freeze
  TIMEOUT_SECONDS = 5

  class << self
    # runner: anything with Sh's #run(argv, timeout:) (Sh itself, or a FakeSh).
    # os, loadavg_path and nprocessors are seams for the Linux branch.
    def read(runner: Sh, os: RbConfig::CONFIG["host_os"], loadavg_path: "/proc/loadavg",
             nprocessors: -> { Etc.nprocessors })
      if os.to_s.include?("darwin")
        read_darwin(runner)
      else
        read_linux(loadavg_path, nprocessors)
      end
    end

    private

    def read_darwin(runner)
      one, five = parse_loadavg(sysctl(runner, "vm.loadavg"))
      ncpu = integer(sysctl(runner, "hw.ncpu"))
      level = integer(sysctl(runner, "kern.memorystatus_vm_pressure_level"))
      { one: one, five: five, ncpu: ncpu, memory: PRESSURE_LEVELS.fetch(level, "unknown") }
    end

    def read_linux(loadavg_path, nprocessors)
      text = File.file?(loadavg_path) ? File.read(loadavg_path) : nil
      one, five = parse_loadavg(text)
      ncpu = begin
        nprocessors.call
      rescue StandardError
        nil
      end
      { one: one, five: five, ncpu: ncpu.is_a?(Integer) && ncpu.positive? ? ncpu : nil, memory: "unknown" }
    rescue SystemCallError
      { one: nil, five: nil, ncpu: nil, memory: "unknown" }
    end

    def sysctl(runner, key)
      result = runner.run(["sysctl", "-n", key], timeout: TIMEOUT_SECONDS)
      result.success? ? result.out : nil
    rescue StandardError
      nil
    end

    # The first two numbers in the text, braces or not.
    def parse_loadavg(text)
      return [nil, nil] if text.nil?

      fields = text.delete("{}").split
      one = float(fields[0])
      five = float(fields[1])
      one && five ? [one, five] : [nil, nil]
    end

    def float(text)
      Float(text.to_s.strip)
    rescue ArgumentError, TypeError
      nil
    end

    def integer(text)
      return nil if text.nil?

      Integer(text.strip, 10)
    rescue ArgumentError, TypeError
      nil
    end
  end
end

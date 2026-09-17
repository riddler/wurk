#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"

# PortabilityLane runs a test file inside a Linux container whose /bin/sh is
# bash 4.4 or newer, so a shell regression that only shows up there is
# catchable on a macOS developer machine, where /bin/sh is bash 3.2.
#
# Why this lane exists (wu-5yo): the hooks under hooks/ are #!/bin/sh
# scripts and the hook tests invoke them through their shebang. On macOS
# /bin/sh is bash 3.2.57, which predates the bash 4.4 "command
# substitution: ignored null byte in input" warning entirely, so a
# warning-only regression under a modern bash is invisible to the default
# gate - and the default gate is the only gate this repo has. It was found
# by an outside contributor on Linux, not here.
#
# The lane is deliberately NOT part of the default gate:
#
# - The default gate must stay stdlib-only system Ruby and must pass on a
#   machine with no container runtime and no network. A missing runtime is
#   a reported skip, never a red gate.
# - The default gate's duration is load-bearing (every caller treats it as
#   a short, foreground run). A container pull on that path would change
#   that number.
#
# So this script is its own entry point, and the default suite carries only
# an opt-in test that reports the lane as skipped and names why. See
# docs/gate-contract.md.
#
# Every infrastructure failure - no runtime binary, no running daemon, an
# image that cannot be pulled - reports `data.status: "skipped"` with a
# named reason and exits 0. Only the test run itself failing, or a
# container whose /bin/sh turns out not to be a modern bash, is not ok.
module PortabilityLane
  # The image is the kit's own choice, not consumer data: it needs a Ruby
  # (to run the test file as written) and a /bin/sh that can be pointed at
  # a bash 4.4+ (Debian ships bash 5.2 at /bin/bash while /bin/sh is dash,
  # which the in-container script relinks). Override with --image.
  DEFAULT_IMAGE = "ruby:3.3-slim-bookworm"

  # The default subject: the hook tests, the suite whose blind spot this
  # lane exists to cover. Relative to the repo root, which is what gets
  # mounted. Override with --test.
  DEFAULT_TEST = "skills/wurk:kit/scripts/test/hooks_test.rb"

  DEFAULT_RUNTIME = "docker"

  # Seconds for the pull and the test run. Generous: a cold image pull is
  # minutes on a slow link, and a lane that times out mid-pull reports a
  # useless result.
  DEFAULT_TIMEOUT = 600

  # Short budget for the two probes that only ask a local daemon a
  # question.
  PROBE_TIMEOUT = 60

  # The floor the lane exists to exercise. bash 4.4 is where the NUL-byte
  # command-substitution warning arrived; anything older reproduces the
  # macOS blind spot and would make the lane green for the wrong reason.
  MIN_BASH = [4, 4].freeze

  MOUNT_POINT = "/repo"
  SH_MARKER = "wurk-lane-sh:"

  # Runs in the container, before the test: repoint /bin/sh at bash so the
  # #!/bin/sh scripts under test run under a modern bash, announce which
  # shell that turned out to be (the lane verifies it rather than trusting
  # the image tag), then exec the test file. $1 is the test path, passed as
  # an argument rather than interpolated.
  CONTAINER_SCRIPT = <<~SH
    set -e
    ln -sf /bin/bash /bin/sh
    printf '%s ' '#{SH_MARKER}'
    /bin/sh --version | head -1
    exec ruby "$1"
  SH

  class << self
    # The wurk repo root: this script lives at
    # <root>/skills/wurk:kit/scripts/, so the root is three levels up.
    def repo_root
      File.expand_path(File.join(__dir__, "..", "..", ".."))
    end

    # True when `name` resolves to an executable file on PATH. A pure
    # filesystem lookup on purpose: the default suite's opt-in test calls
    # this to decide its skip reason, and it must cost nothing and start
    # no process.
    def runtime_on_path?(name = DEFAULT_RUNTIME)
      return File.executable?(name) if name.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        next false if dir.empty?

        File.executable?(File.join(dir, name)) && !File.directory?(File.join(dir, name))
      end
    end

    # Parses the bash version out of the marker line the container script
    # prints. Returns [major, minor] or nil when no marker was found (an
    # image whose /bin/bash is missing, or a run that died before the
    # printf).
    def parse_sh_version(output)
      line = output.to_s.each_line.find { |l| l.include?(SH_MARKER) }
      return nil unless line

      match = line.match(/version (\d+)\.(\d+)/)
      return nil unless match

      [match[1].to_i, match[2].to_i]
    end

    # True when [major, minor] is at or above the bash floor the lane
    # needs. nil (no marker, unparsable version) is never good enough.
    def modern_bash?(version)
      return false unless version

      (version <=> MIN_BASH) >= 0
    end

    def run_argv(options)
      [options[:runtime], "run", "--rm",
       "-v", "#{options[:root]}:#{MOUNT_POINT}:ro",
       "-w", MOUNT_POINT,
       options[:image],
       "sh", "-c", CONTAINER_SCRIPT, "wurk-portability-lane", options[:test]]
    end

    def parse(argv)
      options = { image: DEFAULT_IMAGE, test: DEFAULT_TEST, runtime: DEFAULT_RUNTIME,
                  timeout: DEFAULT_TIMEOUT, root: repo_root }
      parser, options = Cli.build("portability_lane.rb [options]", options) do |opts|
        opts.on("--image IMAGE", "container image to run in (default #{DEFAULT_IMAGE})") do |v|
          options[:image] = v
        end
        opts.on("--test PATH", "test file to run, relative to the repo root") { |v| options[:test] = v }
        opts.on("--runtime CMD", "container runtime (default #{DEFAULT_RUNTIME})") { |v| options[:runtime] = v }
        opts.on("--timeout SECONDS", Integer, "budget for the pull and the run") { |v| options[:timeout] = v }
      end
      Cli.parse!(parser, argv)
      options
    end

    # Reports a named skip: a warning, `status: "skipped"`, and an ok
    # envelope. This is the "missing runtime is a reported skip, never a
    # red gate" rule, in one place.
    def skip!(env, code:, message:)
      env.warn(code: code, message: message)
      env.data[:status] = "skipped"
      env.data[:skip_reason] = message
      env.data[:skip_code] = code
    end

    def run(argv, io: $stdout)
      options = parse(argv)
      env = Envelope.new(script: "portability_lane")
      env.data[:runtime] = options[:runtime]
      env.data[:image] = options[:image]
      env.data[:test] = options[:test]
      env.data[:root] = options[:root]
      env.data[:min_bash] = MIN_BASH.join(".")

      unless File.exist?(File.join(options[:root], options[:test]))
        env.block!(code: "test_file_missing",
                   message: "no such test file under #{options[:root]}: #{options[:test]}")
        return env.emit(io)
      end

      if options[:dry_run]
        env.data[:status] = "dry_run"
        env.commands << Sh.render(run_argv(options))
        return env.emit(io)
      end

      return env.emit(io) unless runtime_ready?(env, options)
      return env.emit(io) unless image_ready?(env, options)

      execute(env, options)
      env.emit(io)
    end

    private

    # Both runtime probes are skips, not failures, and they are different
    # skips: no binary at all is a machine that never had a container
    # runtime, while a binary whose daemon does not answer is one where it
    # is installed but not running. A caller reading the envelope should
    # be able to tell those apart without reading prose.
    def runtime_ready?(env, options)
      probe = Sh.run([options[:runtime], "version", "--format", "{{.Server.Version}}"],
                     timeout: PROBE_TIMEOUT, envelope: env)
      if probe.start_failed?
        skip!(env, code: "runtime_missing",
                   message: "no container runtime on PATH (#{options[:runtime]}); " \
                            "the portability lane needs one and the default gate does not")
        return false
      end

      unless probe.success?
        skip!(env, code: "runtime_unavailable",
                   message: "#{options[:runtime]} is installed but not answering " \
                            "(daemon not running?): #{probe.err.to_s.strip}")
        return false
      end

      env.data[:runtime_version] = probe.out.to_s.strip
      true
    end

    # An image already in the local store needs no network at all, which is
    # what makes the lane runnable offline once it has run once. A pull
    # that fails is the no-network case and is a skip: the lane could not
    # be exercised, which is not the same claim as the lane having found a
    # regression.
    def image_ready?(env, options)
      inspect = Sh.run([options[:runtime], "image", "inspect", options[:image]],
                       timeout: PROBE_TIMEOUT, envelope: env)
      if inspect.success?
        env.data[:image_pulled] = false
        return true
      end

      pull = Sh.run([options[:runtime], "pull", options[:image]], timeout: options[:timeout], envelope: env)
      unless pull.success?
        detail = pull.timed_out? ? "timed out after #{options[:timeout]}s" : pull.err.to_s.strip
        skip!(env, code: "image_unavailable",
                   message: "#{options[:image]} is not in the local image store and could not " \
                            "be pulled (no network?): #{detail}")
        return false
      end

      env.data[:image_pulled] = true
      true
    end

    def execute(env, options)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Sh.run(run_argv(options), timeout: options[:timeout], envelope: env)
      env.data[:duration_seconds] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)

      # Never truncated: this output IS the evidence the lane produces, and
      # the gate contract's never-truncate rule holds at every tier.
      output = [result.out.to_s, result.err.to_s].join
      env.data[:output] = output

      version = parse_sh_version(output)
      env.data[:sh_version] = version ? version.join(".") : nil

      if result.timed_out?
        env.data[:status] = "timeout"
        env.warn(code: "lane_timed_out", message: "the lane exceeded #{options[:timeout]}s and was killed")
        env.fail!
        return
      end

      # Checked before the exit status: a green run under an ancient
      # /bin/sh is the exact blind spot this lane exists to close, so it
      # must never read as a pass.
      unless modern_bash?(version)
        env.block!(code: "sh_not_modern_bash",
                   message: "the container's /bin/sh did not report bash >= #{MIN_BASH.join('.')} " \
                            "(got #{env.data[:sh_version].inspect}); #{options[:image]} cannot " \
                            "exercise the regression class this lane covers")
        env.data[:status] = "failed"
        return
      end

      if result.success?
        env.data[:status] = "passed"
      else
        env.data[:status] = "failed"
        env.fail!
      end
    end
  end
end

exit PortabilityLane.run(ARGV) if __FILE__ == $PROGRAM_NAME

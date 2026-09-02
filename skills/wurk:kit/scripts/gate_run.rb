#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require "rbconfig"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/manifest"
require_relative "lib/lock"

# GateRun is the sanctioned long-gate runner: `start` launches the manifest's
# gate detached (optionally under one or more locks), `supervise` is the
# detached child that actually runs it, `poll` is the bounded foreground wait
# an agent repeats, and `status` is the same computation with no waiting.
#
# See docs/plans/260902-wu-4x9-long-gate-runner-and-lock-helper.md,
# "Implementation Approach", for the load-bearing design decisions this file
# implements:
#
# - A supervisor, not a bare background command: `start` spawns *itself*
#   (`gate_run.rb supervise --run-dir DIR`) detached, rather than the
#   consumer's gate command directly. The gate command still runs through
#   Sh (the one sanctioned shell-out primitive), and the supervisor - being
#   the gate's real parent - is the only thing that can ever capture and
#   persist its exit status; a later poller is not the gate's parent and
#   cannot waitpid it.
# - The sentinel is a rename: the supervisor writes `result.json.part` and
#   File.renames it to `result.json`, so a poller only ever observes either
#   a complete envelope or nothing.
# - `poll` is foreground and bounded (default 60s) and always exits 0 while
#   the run is still going - a still-running gate is not an error. The
#   run's own red/green only reaches the exit code once the sentinel exists.
# - Two timeouts stay separate: `gate.timeout_seconds` bounds a foreground,
#   blocked caller (`gate.rb`); `gate.long_timeout_seconds` bounds this
#   detached runner, which exists precisely to outlive that bound.
# - Liveness without `ps`: `Process.kill(0, pid)` - ESRCH is provably dead,
#   EPERM is alive-but-not-ours, no exception is alive. A poller uses this
#   (plus the recorded deadline) to report `abandoned` rather than waiting
#   forever on a supervisor that was itself killed.
#
# Like gate.rb, this script names no gate tool and no gate flag: every argv
# comes from the manifest (gate.report/gate.report_loop, falling back to
# gate.full/gate.loop), and gate.cwd via manifest.gate_chdir.
module GateRun
  SUBCOMMANDS = %w[start supervise poll status].freeze

  DEFAULT_POLL_WAIT_SECONDS = 60
  DEFAULT_TAIL_LINES = 40
  DEFAULT_LOCK_WAIT_SECONDS = 600
  DEFAULT_LOCK_POLL_SECONDS = 10
  DEFAULT_STALE_AFTER_SECONDS = 1800

  META_FILE = "meta.json"
  RESULT_FILE = "result.json"
  RESULT_PART_FILE = "result.json.part"
  LOG_FILE = "gate.log"
  SUPERVISE_LOG_FILE = "supervise.log"

  # The absolute path to this file, used both to spawn the detached
  # supervisor (`ruby <this file> supervise ...`) and to render the literal
  # `poll_command` an agent is handed - so the "next step" is a command to
  # run verbatim, never something to remember or reconstruct.
  SELF_PATH = File.expand_path(__FILE__)

  # The last lines of the gate command's captured output - same convention
  # and line count as gate.rb's GATE_OUTPUT_TAIL_LINES, so a tier-0-style
  # tail reads the same regardless of which script produced it.
  GATE_OUTPUT_TAIL_LINES = 40

  START_USAGE = "gate_run.rb start [--profile loop] [--run-dir DIR] " \
                "[--gate-lock DIR --campaign ID --bead ID] [--slots-dir DIR --slots N] " \
                "[--wait-seconds N] [--dry-run]"
  SUPERVISE_USAGE = "gate_run.rb supervise --run-dir DIR"
  POLL_USAGE = "gate_run.rb poll --run-dir DIR [--wait-seconds N] [--tail-lines N]"
  STATUS_USAGE = "gate_run.rb status --run-dir DIR [--tail-lines N]"

  class << self
    def run(argv, io: $stdout)
      argv = argv.dup
      unless SUBCOMMANDS.include?(argv.first)
        warn usage
        exit 2
      end

      case argv.shift
      when "start" then run_start(argv, io)
      when "supervise" then run_supervise(argv, io)
      when "poll" then run_poll(argv, io)
      when "status" then run_status(argv, io)
      end
    end

    private

    def usage
      "usage: gate_run.rb <start|supervise|poll|status> [options]"
    end

    def usage_error!(usage_line, parser)
      warn "usage: #{usage_line}\n\n#{parser}"
      exit 2
    end

    def blank?(value)
      value.to_s.strip.empty?
    end

    # --- start --------------------------------------------------------------

    def run_start(argv, io)
      options = { dry_run: false, wait_seconds: DEFAULT_LOCK_WAIT_SECONDS }
      parser, options = Cli.build(START_USAGE, options) { |opts| add_start_flags(opts, options) }
      Cli.parse!(parser, argv)

      lock_specs = start_lock_specs(options)
      usage_error!(START_USAGE, parser) if lock_specs.nil?
      if lock_specs.any? && (blank?(options[:campaign]) || blank?(options[:bead]))
        usage_error!(START_USAGE, parser)
      end

      env = Envelope.new(script: "gate_run_start")
      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest

      loop_mode = options[:profile] == "loop"
      reporting = loop_mode ? manifest.gate_report_loop : manifest.gate_report
      gate_argv = reporting || (loop_mode ? manifest.gate_loop : manifest.gate_full)
      chdir = manifest.gate_chdir

      run_id = "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{Process.pid}"
      run_dir = options[:run_dir] || File.join(manifest.checkout_root, ".claude", "wurk-runs", "gate", run_id)
      log_path = File.join(run_dir, LOG_FILE)
      sentinel_path = File.join(run_dir, RESULT_FILE)
      started_at = Time.now.utc
      deadline_at = started_at + manifest.gate_long_timeout_seconds
      poll_command = poll_command_for(run_dir)

      return emit_start_dry_run(env, io, run_id: run_id, run_dir: run_dir, log_path: log_path,
                                          sentinel_path: sentinel_path, deadline_at: deadline_at,
                                          gate_argv: gate_argv, chdir: chdir, lock_specs: lock_specs,
                                          poll_command: poll_command) if options[:dry_run]

      lock_owner = nil
      locks_acquired = []
      if lock_specs.any?
        lock_owner = {
          "campaign" => options[:campaign],
          "bead" => options[:bead],
          "pid" => Process.pid.to_s,
          "acquired_at" => started_at.iso8601
        }
        result = Lock.acquire_all(lock_specs, owner: lock_owner, wait_seconds: options[:wait_seconds],
                                               poll_seconds: DEFAULT_LOCK_POLL_SECONDS)
        unless result[:acquired]
          probe = Lock.probe(result[:contended_dir], stale_after_seconds: DEFAULT_STALE_AFTER_SECONDS)
          env.data[:contended] = { kind: result[:contended_kind], dir: result[:contended_dir], probe: probe }
          env.block!(
            code: "lock_contended",
            message: "timed out after #{result[:waited_seconds].round(1)}s waiting for the " \
                      "#{result[:contended_kind]} lock at #{result[:contended_dir]}"
          )
          return env.emit(io)
        end
        locks_acquired = result[:locks]
      end

      FileUtils.mkdir_p(run_dir)

      supervisor_pid = Sh.spawn_detached(
        [RbConfig.ruby, SELF_PATH, "supervise", "--run-dir", run_dir],
        out_path: File.join(run_dir, SUPERVISE_LOG_FILE)
      )

      # The lock was acquired under this process's own pid - the supervisor
      # did not exist yet - so the owner file is corrected now that the real,
      # long-lived pid is known. See Lock.rewrite_owner_pid: this is a
      # rename over the owner file, never a truncating in-place write.
      locks_acquired.each { |l| Lock.rewrite_owner_pid(l[:dir], supervisor_pid) }
      lock_owner["pid"] = supervisor_pid.to_s if lock_owner

      meta = {
        "run_id" => run_id,
        "argv" => gate_argv,
        "chdir" => chdir,
        "profile" => options[:profile],
        "started_at" => started_at.iso8601,
        "deadline_at" => deadline_at.iso8601,
        "long_timeout_seconds" => manifest.gate_long_timeout_seconds,
        "locks" => locks_acquired.map { |l| { "kind" => l[:kind], "dir" => l[:dir] } },
        "lock_owner" => lock_owner,
        "log_path" => log_path,
        "sentinel_path" => sentinel_path,
        "pid" => supervisor_pid
      }
      write_json(File.join(run_dir, META_FILE), meta)

      env.commands << Sh.render([RbConfig.ruby, SELF_PATH, "supervise", "--run-dir", run_dir])
      env.data[:run_id] = run_id
      env.data[:run_dir] = run_dir
      env.data[:log_path] = log_path
      env.data[:sentinel_path] = sentinel_path
      env.data[:pid] = supervisor_pid
      env.data[:deadline_at] = deadline_at.iso8601
      env.data[:locks] = meta["locks"]
      env.data[:poll_command] = poll_command
      env.emit(io)
    end

    def add_start_flags(opts, options)
      opts.on("--profile PROFILE", "only 'loop' is accepted") do |v|
        raise OptionParser::InvalidArgument, "profile must be 'loop' (got #{v.inspect})" if v != "loop"

        options[:profile] = v
      end
      opts.on("--run-dir DIR", "override the default run directory") { |v| options[:run_dir] = v }
      opts.on("--gate-lock DIR", "repo gate lock dir to acquire before spawning") { |v| options[:gate_lock] = v }
      opts.on("--slots-dir DIR", "machine gate slots parent dir") { |v| options[:slots_dir] = v }
      opts.on("--slots N", Integer, "number of machine gate slots") { |v| options[:slots] = v }
      opts.on("--campaign ID", "campaign id, recorded in the owner file") { |v| options[:campaign] = v }
      opts.on("--bead ID", "bead id, recorded in the owner file") { |v| options[:bead] = v }
      opts.on("--wait-seconds N", Integer, "bounded lock-acquire wait (default 600)") { |v| options[:wait_seconds] = v }
    end

    # Builds the ordered lock specs from whichever lock flags were given.
    # Returns [] when no lock was named at all (a legitimate, lock-free
    # start), or nil (a usage error) when exactly one of --slots-dir/--slots
    # was given without the other.
    def start_lock_specs(options)
      specs = []
      specs << { kind: "gate", dir: options[:gate_lock] } if options[:gate_lock]

      slots_named = options[:slots_dir] || options[:slots]
      if slots_named
        return nil if blank?(options[:slots_dir]) || options[:slots].to_i <= 0

        specs << { kind: "slot", slots_dir: options[:slots_dir], count: options[:slots] }
      end

      specs
    end

    def emit_start_dry_run(env, io, run_id:, run_dir:, log_path:, sentinel_path:, deadline_at:, gate_argv:, chdir:,
                            lock_specs:, poll_command:)
      lock_specs.each do |spec|
        target = spec[:kind] == "slot" ? "#{spec[:slots_dir]}/slot-1..#{spec[:count]}" : spec[:dir]
        env.commands << "mkdir #{target} (lock: #{spec[:kind]})"
      end
      env.commands << "mkdir -p #{run_dir}"
      env.commands << Sh.render([RbConfig.ruby, SELF_PATH, "supervise", "--run-dir", run_dir], chdir: nil)
      env.data[:run_id] = run_id
      env.data[:run_dir] = run_dir
      env.data[:log_path] = log_path
      env.data[:sentinel_path] = sentinel_path
      env.data[:pid] = nil
      env.data[:deadline_at] = deadline_at.iso8601
      env.data[:locks] = []
      env.data[:poll_command] = poll_command
      env.data[:argv] = gate_argv
      env.data[:chdir] = chdir
      env.emit(io)
    end

    # --- supervise ------------------------------------------------------------

    def run_supervise(argv, io)
      options = { dry_run: false }
      parser, options = Cli.build(SUPERVISE_USAGE, options) do |opts|
        opts.on("--run-dir DIR", "the run directory start created") { |v| options[:run_dir] = v }
      end
      Cli.parse!(parser, argv)
      usage_error!(SUPERVISE_USAGE, parser) if blank?(options[:run_dir])

      run_dir = options[:run_dir]
      env = Envelope.new(script: "gate_run_supervise")
      meta_path = File.join(run_dir, META_FILE)

      unless File.exist?(meta_path)
        env.block!(code: "gate_run_meta_missing", message: "no #{META_FILE} found in #{run_dir}")
        return env.emit(io)
      end

      meta = load_json(meta_path)
      log_path = meta["log_path"] || File.join(run_dir, LOG_FILE)

      start_time = Time.now
      res = Sh.run_streaming(meta["argv"], chdir: meta["chdir"], timeout: meta["long_timeout_seconds"],
                                            log_path: log_path)
      duration_seconds = (Time.now - start_time).round(3)

      release_locks(meta, env)

      env.data[:exit_status] = res.status && res.status.exitstatus
      env.data[:timed_out] = res.timed_out?
      env.data[:duration_seconds] = duration_seconds
      env.data[:log_path] = log_path
      env.data[:output_tail] = gate_output_tail(res)
      env.fail! unless res.success?

      write_sentinel(run_dir, env)
      env.emit(io)
    end

    # Releases every lock named in meta.json, in the reverse of the order
    # they were acquired, before the sentinel is written - a poller that
    # observes the sentinel can then be sure the lock is free. Wrapped so
    # that a crash while releasing one lock never stops the others from
    # being attempted, and never prevents the sentinel from being written -
    # a run that finished but could not release is reported via a warning,
    # never left silently hung.
    def release_locks(meta, env)
      locks = Array(meta["locks"])
      owner = meta["lock_owner"] || {}

      locks.reverse_each do |lock|
        begin
          result = Lock.release(lock["dir"], owner, force: false)
          unless result[:released]
            env.warn(
              code: "gate_run_lock_release_failed",
              message: "could not release #{lock['kind']} lock at #{lock['dir']} (#{result[:reason]})"
            )
          end
        rescue StandardError => e
          env.warn(
            code: "gate_run_lock_release_failed",
            message: "releasing #{lock['kind']} lock at #{lock['dir']} raised #{e.class}: #{e.message}"
          )
        end
      end
    end

    def write_sentinel(run_dir, env)
      part_path = File.join(run_dir, RESULT_PART_FILE)
      result_path = File.join(run_dir, RESULT_FILE)
      File.write(part_path, env.to_json)
      File.rename(part_path, result_path)
    end

    def gate_output_tail(res)
      [res.out, res.err]
        .map(&:to_s)
        .reject(&:empty?)
        .join("\n")
        .lines
        .last(GATE_OUTPUT_TAIL_LINES)
        .join
        .strip
    end

    # --- poll -----------------------------------------------------------------

    def run_poll(argv, io)
      options = { dry_run: false, wait_seconds: DEFAULT_POLL_WAIT_SECONDS, tail_lines: DEFAULT_TAIL_LINES }
      parser, options = Cli.build(POLL_USAGE, options) { |opts| add_wait_flags(opts, options) }
      Cli.parse!(parser, argv)
      usage_error!(POLL_USAGE, parser) if blank?(options[:run_dir])

      env = Envelope.new(script: "gate_run_poll")
      state = compute_state(options[:run_dir], wait_seconds: options[:wait_seconds], tail_lines: options[:tail_lines])
      env.data.merge!(state)

      case state[:state]
      when "finished"
        env.fail! unless state[:ok]
      when "abandoned"
        env.block!(
          code: "gate_run_abandoned",
          message: "the gate_run supervisor is no longer alive (or the run's deadline has passed) and " \
                    "left no result.json - the run is abandoned, not still running"
        )
      when "not_found"
        env.block!(code: "gate_run_not_found", message: "no #{META_FILE} found in #{options[:run_dir]}")
      end

      env.emit(io)
    end

    def add_wait_flags(opts, options)
      opts.on("--run-dir DIR", "the run directory start created") { |v| options[:run_dir] = v }
      opts.on("--wait-seconds N", Integer, "bounded foreground wait (default 60)") { |v| options[:wait_seconds] = v }
      opts.on("--tail-lines N", Integer, "log tail length (default 40)") { |v| options[:tail_lines] = v }
    end

    # --- status -----------------------------------------------------------------

    def run_status(argv, io)
      options = { dry_run: false, tail_lines: DEFAULT_TAIL_LINES }
      parser, options = Cli.build(STATUS_USAGE, options) do |opts|
        opts.on("--run-dir DIR", "the run directory start created") { |v| options[:run_dir] = v }
        opts.on("--tail-lines N", Integer, "log tail length (default 40)") { |v| options[:tail_lines] = v }
      end
      Cli.parse!(parser, argv)
      usage_error!(STATUS_USAGE, parser) if blank?(options[:run_dir])

      env = Envelope.new(script: "gate_run_status")
      # Read-only, always exit 0 (never block!/fail!) - status reports
      # whatever state it finds without waiting for it to change.
      state = compute_state(options[:run_dir], wait_seconds: 0, tail_lines: options[:tail_lines])
      env.data.merge!(state)
      env.emit(io)
    end

    # --- shared state computation (poll and status) ----------------------------

    # Computes the current state of a run dir: "finished" (result.json
    # exists - the sentinel is a rename, so this is never a half-written
    # file), "abandoned" (past the deadline or the supervisor pid is dead,
    # with no sentinel - a poller must never wait forever on a dead
    # supervisor), "running" (neither, within wait_seconds), or "not_found"
    # (no meta.json at all). Blocks for at most wait_seconds, re-checking
    # result.json and liveness between short sleeps.
    def compute_state(run_dir, wait_seconds:, tail_lines:)
      meta_path = File.join(run_dir, META_FILE)
      return { state: "not_found" } unless File.exist?(meta_path)

      meta = load_json(meta_path)
      result_path = File.join(run_dir, RESULT_FILE)
      start = Time.now
      deadline = start + wait_seconds

      loop do
        return finished_state(result_path) if File.exist?(result_path)

        reason = abandoned_reason(meta)
        return abandoned_state(meta, reason, tail_lines) if reason

        now = Time.now
        break if now >= deadline

        sleep([1, deadline - now].min)
      end

      running_state(run_dir, meta, start, tail_lines)
    end

    def finished_state(result_path)
      result = load_json(result_path)
      data = result["data"] || {}
      symbolized = data.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      symbolized.merge(state: "finished", ok: result["ok"])
    end

    # nil when still plausibly alive; otherwise the reason the run counts as
    # abandoned. A dead supervisor pid is checked before the deadline so a
    # `kill -9`'d supervisor is reported immediately rather than only once
    # its deadline (which could be an hour away) finally passes.
    def abandoned_reason(meta)
      pid = meta["pid"]
      return "supervisor_pid_dead" if pid && !pid_alive?(pid)

      deadline_at = meta["deadline_at"] && Time.parse(meta["deadline_at"])
      return "deadline_exceeded" if deadline_at && Time.now > deadline_at

      nil
    end

    def abandoned_state(meta, reason, tail_lines)
      {
        state: "abandoned",
        reason: reason,
        deadline_at: meta["deadline_at"],
        pid: meta["pid"],
        log_tail: tail_of(meta["log_path"], tail_lines)
      }
    end

    def running_state(run_dir, meta, start, tail_lines)
      {
        state: "running",
        elapsed_seconds: (Time.now - start).round(3),
        deadline_at: meta["deadline_at"],
        log_tail: tail_of(meta["log_path"], tail_lines),
        poll_command: poll_command_for(run_dir)
      }
    end

    # true (alive), false (provably dead) - same Process.kill(0, pid)
    # liveness probe lib/lock.rb uses, so a run's supervisor and a lock's
    # holder are judged by the same rule. Unlike Lock.holder_alive?, a
    # missing pid here is not a legitimate case (every run dir start creates
    # has one), so EPERM (alive, just not ours) still counts as alive and
    # anything else defaults to "assume alive" rather than "abandoned".
    def pid_alive?(pid)
      Process.kill(0, Integer(pid))
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def tail_of(log_path, tail_lines)
      return "" unless log_path && File.file?(log_path)

      File.readlines(log_path).last(tail_lines).join.strip
    rescue SystemCallError
      ""
    end

    def poll_command_for(run_dir)
      "ruby #{SELF_PATH} poll --run-dir #{run_dir} --wait-seconds #{DEFAULT_POLL_WAIT_SECONDS}"
    end

    def write_json(path, hash)
      File.write(path, JSON.generate(hash))
    end

    def load_json(path)
      JSON.parse(File.read(path))
    end
  end
end

exit GateRun.run(ARGV) if __FILE__ == $PROGRAM_NAME

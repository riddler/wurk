#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require_relative "lib/envelope"
require_relative "lib/cli"
require_relative "lib/sh"
require_relative "lib/lock"
require_relative "lib/user_config"
require_relative "lib/worker_cap"
require_relative "lib/machine_load"
require_relative "lib/account_pause"

# WorkerCapCli answers the one question every dispatcher asks before it
# starts a worker: may I start another one now, and how many?
#
#   worker_cap.rb check --caller ID --running N [--ceiling N]
#                       [--slots-dir DIR] [--model FAMILY] [--no-refresh]
#
# The cap comes from the machine's load and memory pressure alone
# (lib/worker_cap.rb); the account pause comes from the current account's
# newest limit capture (lib/account_pause.rb) and only ever turns `dispatch`
# off - it never moves the cap. `headroom` is the cap less every live
# caller's reported running count, bounded by the free gate slots when
# --slots-dir names the machine slot pool.
#
# Every reading exits 0, cap 0 and a pause included: `dispatch` is the
# answer. A malformed --caller or --running is a usage error (exit 2, no
# envelope, nothing read or written); an invalid machine config blocks
# bad_machine_config (exit 1). --ceiling may lower the cap for this answer,
# never raise it, and never changes the stored level (the rule of
# Lock.resolve_slot_count). --dry-run reads everything and writes nothing:
# no state update, no capture refresh.
module WorkerCapCli
  USAGE = "worker_cap.rb check --caller ID --running N [--ceiling N] [--slots-dir DIR] " \
          "[--model FAMILY] [--no-refresh]"
  SLOTS_HINT = "--slots-dir needs machine.gate_slots in the machine config (~/.claude/wurk.local.json); " \
               "there is no default slot count"
  REFRESH_STAMP = File.join("wurk", "account-refresh.stamp")

  class << self
    # Test seams, reset to nil in teardown: load_reader returns a
    # MachineLoad-shaped reading, clock returns a Time, refresher is the
    # capture-refresh callable.
    attr_accessor :load_reader, :clock, :refresher

    def run(argv, io: $stdout)
      argv = argv.dup
      if Cli.unsplit_argv?(argv)
        env = Envelope.new(script: "worker_cap")
        env.block!(code: "argv_unsplit", message: Cli.unsplit_message(argv))
        env.emit(io)
        exit 2
      end
      unless argv.first == "check"
        warn "usage: #{USAGE}"
        exit 2
      end
      argv.shift

      options = parse(argv)
      check(options, io)
    end

    private

    def parse(argv)
      options = { refresh: true }
      parser, options = Cli.build(USAGE, options) do |opts|
        opts.on("--caller ID", "this dispatcher's id (a-z 0-9 _ . : -, at most 64)") { |v| options[:caller] = v }
        opts.on("--running N", "workers this caller runs now") { |v| options[:running] = v }
        opts.on("--ceiling N", "lower the cap for this answer (never raises it)") { |v| options[:ceiling] = v }
        opts.on("--slots-dir DIR", "the machine gate-slot pool to count") { |v| options[:slots_dir] = v }
        opts.on("--model FAMILY", "the worker's model family (fable adds the Fable week)") { |v| options[:model] = v }
        opts.on("--no-refresh", "never run the capture tool") { options[:refresh] = false }
      end
      Cli.parse!(parser, argv)

      usage_error!(parser, "--caller must match #{WorkerCap::CALLER_ID.source}") unless WorkerCap.valid_caller?(options[:caller])
      options[:running] = count_arg(options[:running], parser, "--running must be a non-negative integer", min: 0)
      unless options[:ceiling].nil?
        options[:ceiling] = count_arg(options[:ceiling], parser, "--ceiling must be a positive integer", min: 1)
      end
      usage_error!(parser, "--slots-dir must not be blank") if options[:slots_dir] && options[:slots_dir].strip.empty?
      usage_error!(parser, "unexpected arguments: #{argv.join(' ')}") unless argv.empty?
      options
    end

    def count_arg(value, parser, message, min:)
      usage_error!(parser, message) unless value.is_a?(String) && value.match?(/\A\d+\z/)
      number = Integer(value, 10)
      usage_error!(parser, message) if number < min
      number
    end

    def usage_error!(parser, message)
      warn "#{message}\n\n#{parser}"
      exit 2
    end

    def check(options, io)
      env = Envelope.new(script: "worker_cap")
      config = UserConfig.current
      unless config.valid?
        config.errors.each { |e| env.block!(code: "bad_machine_config", message: e) }
        return env.emit(io)
      end
      config.warnings.each { |w| env.warn(code: "user_config_unknown_key", message: w) }

      slot_count = config.machine_gate_slots
      if options[:slots_dir] && slot_count.nil?
        warn "#{SLOTS_HINT}\n\nusage: #{USAGE}"
        exit 2
      end

      now = (clock || -> { Time.now }).call
      reading = (load_reader || -> { MachineLoad.read }).call
      workers = config.machine_workers(ncpu: reading[:ncpu])
      env.warn(code: "memory_unknown", message: "memory pressure could not be read; treated as normal") if reading[:memory] == "unknown"

      decision, machine_running = update_store(options, reading, workers, now, env)
      cap = lower_cap(decision[:cap], workers["ceiling"], options[:ceiling], env)

      free = options[:slots_dir] ? Lock.free_slots(dir: options[:slots_dir], count: slot_count, now: now) : nil
      headroom = WorkerCap.headroom(cap: cap, machine_running: machine_running, free_slots: free)

      account = AccountPause.check(limits_root: AccountPause.limits_root, model: options[:model], now: now,
                                   refresh: refresh_for(options, now, env))
      account.delete(:warnings).each { |w| env.warn(**w) }

      fill(env, decision: decision, cap: cap, workers: workers, reading: reading, slots: slot_count, free: free,
                options: options, machine_running: machine_running, headroom: headroom, account: account, now: now)
      env.emit(io)
    end

    # The read-modify-write of the shared state: the level, and this
    # caller's running count. Under --dry-run the store is read and nothing
    # is written.
    def update_store(options, reading, workers, now, env)
      path = WorkerCap.state_path
      WorkerCap::Store.update(path, now: now, write: !options[:dry_run]) do |store|
        store.warnings.each do |code|
          env.warn(code: code, message: "the worker-cap state file was unreadable and has been started fresh")
        end
        decision = store.decide(reading: reading, config: workers)
        store.report(options[:caller], options[:running])
        [decision, store.machine_running]
      end
    end

    def lower_cap(cap, ceiling, flag, env)
      return cap if flag.nil?

      if flag > ceiling
        env.warn(code: "ceiling_overridden",
                 message: "--ceiling #{flag} is above this machine's ceiling of #{ceiling} and was not used; " \
                          "a flag may lower the cap, never raise it")
        return cap
      end
      [cap, flag].min
    end

    def refresh_for(options, now, env)
      return nil unless options[:refresh]

      if options[:dry_run]
        env.commands << Sh.render(AccountPause::Refresher::COMMAND) + " (if the capture is stale; not run under --dry-run)"
        return nil
      end
      return refresher if refresher

      stamp = File.join(File.dirname(File.dirname(WorkerCap.state_path)), REFRESH_STAMP)
      AccountPause::Refresher.new(stamp_path: stamp, now: now)
    end

    def fill(env, decision:, cap:, workers:, reading:, slots:, free:, options:, machine_running:, headroom:, account:, now:)
      per_core = reading[:one] && reading[:ncpu] ? (reading[:one].to_f / reading[:ncpu]).round(2) : nil
      env.data[:cap] = cap
      env.data[:level] = decision[:level]
      env.data[:ceiling] = workers["ceiling"]
      env.data[:ceiling_source] = workers["ceiling_source"]
      env.data[:zone] = decision[:zone]
      env.data[:reasons] = decision[:reasons]
      env.data[:load] = { one: reading[:one], five: reading[:five], ncpu: reading[:ncpu], per_core: per_core }
      env.data[:memory] = reading[:memory]
      env.data[:gate_slots] = free.nil? ? nil : { count: slots, free: free }
      env.data[:running] = { caller: options[:running], machine: machine_running }
      env.data[:headroom] = headroom
      env.data[:account] = account
      env.data[:dispatch] = headroom.positive? && !account[:paused]
      env.data[:read_at] = now.utc.iso8601
    end
  end
end

exit WorkerCapCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "socket"
require "fileutils"
require_relative "lib/envelope"
require_relative "lib/cli"
require_relative "lib/lock"

# LockCli is the thin wiring between Lock's pure filesystem logic and the
# kit's envelope contract: acquire (bounded wait, fixed order, all-or-
# nothing), release (refuses a foreign owner), status (read-only probe),
# and clear (refuses anything not provably stale). No manifest, no Sh - a
# lock directory is a plain CLI argument (see the plan's "What We're NOT
# Doing": the fleet manifest that would otherwise name these paths is out
# of scope here).
module LockCli
  SUBCOMMANDS = %w[acquire release status clear].freeze
  DEFAULT_STALE_AFTER_SECONDS = 1800

  ACQUIRE_USAGE = "lock.rb acquire [--campaign-mutex DIR] [--gate-lock DIR] [--tracker-lock DIR] " \
                  "[--registry-lock DIR] [--slots-dir DIR --slots N] --campaign ID --bead ID " \
                  "[--pid N] [--purpose S] [--wait-seconds N] [--poll-seconds N]"
  RELEASE_USAGE = "lock.rb release --dir DIR --campaign ID --bead ID [--pid N]"
  STATUS_USAGE = "lock.rb status --dir DIR [--stale-after-seconds N]"
  CLEAR_USAGE = "lock.rb clear --dir DIR"

  class << self
    def run(argv, io: $stdout)
      argv = argv.dup
      unless SUBCOMMANDS.include?(argv.first)
        warn usage
        exit 2
      end

      case argv.shift
      when "acquire" then run_acquire(argv, io)
      when "release" then run_release(argv, io)
      when "status" then run_status(argv, io)
      when "clear" then run_clear(argv, io)
      end
    end

    private

    def usage
      "usage: lock.rb <acquire|release|status|clear> [options]"
    end

    # --- acquire ----------------------------------------------------------

    def run_acquire(argv, io)
      options = { dry_run: false, wait_seconds: 600, poll_seconds: 10 }
      parser, options = Cli.build(ACQUIRE_USAGE, options) { |opts| add_acquire_flags(opts, options) }
      Cli.parse!(parser, argv)

      usage_error!(ACQUIRE_USAGE, parser) if blank?(options[:campaign]) || blank?(options[:bead])

      specs = acquire_specs(options)
      usage_error!(ACQUIRE_USAGE, parser) if specs.nil?

      env = Envelope.new(script: "lock_acquire")
      owner = build_owner(options)
      order = specs.sort_by { |s| Lock::ORDER.fetch(s[:kind]) }.map { |s| s[:kind] }

      return emit_acquire_dry_run(env, io, specs, order, owner) if options[:dry_run]

begin
  result = Lock.acquire_all(specs, owner: owner, wait_seconds: options[:wait_seconds], poll_seconds: options[:poll_seconds])
rescue SystemCallError => e
  # A lock path the filesystem will not let us create (read-only mount,
  # no permission, missing parent) is not contention and never becomes
  # true by waiting - it is a caller error about WHERE the lock lives.
  # It still owes the envelope contract an envelope rather than a
  # backtrace, so it is reported as blocked, not raised.
  env.data[:acquired] = []
  env.block!(code: "lock_path_unusable",
             message: "cannot create a lock directory under the requested path: #{e.message}")
  return env.emit(io)
end

      env.data[:order] = result[:order]
      env.data[:waited_seconds] = result[:waited_seconds]

      if result[:acquired]
        env.data[:acquired] = result[:locks]
        result[:locks].each { |l| env.commands << "mkdir #{l[:dir]} (owner campaign=#{owner['campaign']} bead=#{owner['bead']})" }
        return env.emit(io)
      end

      env.data[:acquired] = []
      probe = Lock.probe(result[:contended_dir], stale_after_seconds: DEFAULT_STALE_AFTER_SECONDS)
      env.data[:contended] = { kind: result[:contended_kind], dir: result[:contended_dir], probe: probe }
      env.block!(
        code: "lock_contended",
        message: "timed out after #{result[:waited_seconds].round(1)}s waiting for the " \
                  "#{result[:contended_kind]} lock at #{result[:contended_dir]}"
      )
      env.emit(io)
    end

    def add_acquire_flags(opts, options)
      opts.on("--campaign-mutex DIR", "campaign mutex lock dir") { |v| options[:campaign_mutex] = v }
      opts.on("--gate-lock DIR", "repo gate lock dir") { |v| options[:gate_lock] = v }
      opts.on("--tracker-lock DIR", "tracker lock dir") { |v| options[:tracker_lock] = v }
      opts.on("--registry-lock DIR", "registry lock dir") { |v| options[:registry_lock] = v }
      opts.on("--slots-dir DIR", "machine gate slots parent dir") { |v| options[:slots_dir] = v }
      opts.on("--slots N", Integer, "number of machine gate slots") { |v| options[:slots] = v }
      opts.on("--campaign ID", "campaign id, recorded in the owner file") { |v| options[:campaign] = v }
      opts.on("--bead ID", "bead id, recorded in the owner file") { |v| options[:bead] = v }
      opts.on("--pid N", Integer, "holder pid, recorded in the owner file") { |v| options[:pid] = v }
      opts.on("--purpose S", "free-text purpose, recorded in the owner file") { |v| options[:purpose] = v }
      opts.on("--wait-seconds N", Integer, "bounded wait before lock_contended (default 600)") { |v| options[:wait_seconds] = v }
      opts.on("--poll-seconds N", Integer, "poll interval while waiting (default 10)") { |v| options[:poll_seconds] = v }
    end

    # Builds the ordered lock specs from whichever lock flags were given.
    # Returns nil (a usage error) when no lock was named at all, or when
    # exactly one of --slots-dir/--slots was given without the other.
    def acquire_specs(options)
      specs = []
      specs << { kind: "campaign", dir: options[:campaign_mutex] } if options[:campaign_mutex]
      specs << { kind: "gate", dir: options[:gate_lock] } if options[:gate_lock]
      specs << { kind: "tracker", dir: options[:tracker_lock] } if options[:tracker_lock]
      specs << { kind: "registry", dir: options[:registry_lock] } if options[:registry_lock]

      slots_named = options[:slots_dir] || options[:slots]
      if slots_named
        return nil if blank?(options[:slots_dir]) || options[:slots].to_i <= 0

        specs << { kind: "slot", slots_dir: options[:slots_dir], count: options[:slots] }
      end

      specs.empty? ? nil : specs
    end

    def build_owner(options)
      owner = { "campaign" => options[:campaign], "bead" => options[:bead], "acquired_at" => Time.now.utc.iso8601 }
      owner["pid"] = options[:pid].to_s if options[:pid]
      owner["purpose"] = options[:purpose] if options[:purpose]
      begin
        owner["host"] = Socket.gethostname
      rescue SocketError, SystemCallError
        # host is best-effort metadata; its absence never blocks an acquire
      end
      owner
    end

    def emit_acquire_dry_run(env, io, specs, order, owner)
      order.each do |kind|
        spec = specs.find { |s| s[:kind] == kind }
        target = spec[:kind] == "slot" ? "#{spec[:slots_dir]}/slot-1..#{spec[:count]}" : spec[:dir]
        env.commands << "mkdir #{target} (owner campaign=#{owner['campaign']} bead=#{owner['bead']})"
      end
      env.data[:acquired] = []
      env.data[:order] = order
      env.data[:waited_seconds] = 0
      env.emit(io)
    end

    # --- release ------------------------------------------------------------
    #
    # Deliberately has no --force flag: a foreign or ownerless lock is
    # always refused back to a human (skills/wurk:conductor/REFERENCE.md:83-87).

    def run_release(argv, io)
      options = { dry_run: false }
      parser, options = Cli.build(RELEASE_USAGE, options) do |opts|
        opts.on("--dir DIR", "lock directory to release") { |v| options[:dir] = v }
        opts.on("--campaign ID", "campaign id to match against the owner file") { |v| options[:campaign] = v }
        opts.on("--bead ID", "bead id to match against the owner file") { |v| options[:bead] = v }
        opts.on("--pid N", Integer, "pid to match against the owner file") { |v| options[:pid] = v }
      end
      Cli.parse!(parser, argv)
      usage_error!(RELEASE_USAGE, parser) if blank?(options[:dir]) || blank?(options[:campaign]) || blank?(options[:bead])

      env = Envelope.new(script: "lock_release")
      owner = { "campaign" => options[:campaign], "bead" => options[:bead] }
      owner["pid"] = options[:pid].to_s if options[:pid]

      env.data[:dir] = options[:dir]

      unless Dir.exist?(options[:dir])
        env.block!(code: "lock_not_held", message: "no lock directory at #{options[:dir]}")
        return env.emit(io)
      end

      current = Lock.read_owner(options[:dir])
      unless Lock.owner_matches?(current, owner)
        env.data[:current_owner] = current
        env.block!(
          code: "lock_not_owned",
          message: "lock at #{options[:dir]} is owned by #{current.inspect}, not campaign=#{options[:campaign]} bead=#{options[:bead]}"
        )
        return env.emit(io)
      end

      env.commands << "release lock #{options[:dir]} (owner campaign=#{options[:campaign]} bead=#{options[:bead]})"

      result = options[:dry_run] ? { released: true } : Lock.release(options[:dir], owner)
      env.data[:released] = result[:released]
      env.fail! unless result[:released]
      env.emit(io)
    end

    # --- status -------------------------------------------------------------
    #
    # Read-only, always exit 0 - the machine-detectable staleness answer.

    def run_status(argv, io)
      options = { dry_run: false, stale_after_seconds: DEFAULT_STALE_AFTER_SECONDS }
      parser, options = Cli.build(STATUS_USAGE, options) do |opts|
        opts.on("--dir DIR", "lock directory to probe") { |v| options[:dir] = v }
        opts.on("--stale-after-seconds N", Integer, "ownerless-lock cutoff (default 1800)") { |v| options[:stale_after_seconds] = v }
      end
      Cli.parse!(parser, argv)
      usage_error!(STATUS_USAGE, parser) if blank?(options[:dir])

      env = Envelope.new(script: "lock_status")
      probe = Lock.probe(options[:dir], stale_after_seconds: options[:stale_after_seconds])
      env.data[:dir] = options[:dir]
      probe.each { |k, v| env.data[k] = v }
      env.emit(io)
    end

    # --- clear ----------------------------------------------------------------
    #
    # Removes a lock dir only when probe reports stale: true with reason
    # dead_holder_pid - the one case a script may decide on its own. Anything
    # else is refused to a human with the probe attached as evidence.

    def run_clear(argv, io)
      options = { dry_run: false }
      parser, options = Cli.build(CLEAR_USAGE, options) do |opts|
        opts.on("--dir DIR", "lock directory to clear") { |v| options[:dir] = v }
      end
      Cli.parse!(parser, argv)
      usage_error!(CLEAR_USAGE, parser) if blank?(options[:dir])

      env = Envelope.new(script: "lock_clear")
      probe = Lock.probe(options[:dir], stale_after_seconds: DEFAULT_STALE_AFTER_SECONDS)
      env.data[:dir] = options[:dir]
      env.data[:probe] = probe

      unless probe[:held]
        env.block!(code: "lock_not_held", message: "no lock directory at #{options[:dir]}")
        return env.emit(io)
      end

      unless probe[:stale] && probe[:staleness_reason] == "dead_holder_pid"
        env.block!(
          code: "lock_not_provably_stale",
          message: "lock at #{options[:dir]} is not provably stale " \
                    "(staleness_reason: #{probe[:staleness_reason].inspect}) - a human must clear it"
        )
        return env.emit(io)
      end

      env.commands << "rm -rf #{options[:dir]} (dead holder pid #{probe[:owner] && probe[:owner]['pid']})"
      FileUtils.rm_rf(options[:dir]) unless options[:dry_run]
      env.data[:cleared] = true
      env.emit(io)
    end

    # --- shared ---------------------------------------------------------------

    def blank?(value)
      value.to_s.strip.empty?
    end

    def usage_error!(usage_line, parser)
      warn "usage: #{usage_line}\n\n#{parser}"
      exit 2
    end
  end
end

exit LockCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

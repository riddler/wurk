#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "socket"
require "fileutils"
require "rbconfig"
require_relative "lib/envelope"
require_relative "lib/cli"
require_relative "lib/lock"
require_relative "lib/sh"
require_relative "lib/user_config"

# LockCli is the thin wiring between Lock's pure filesystem logic and the
# kit's envelope contract: acquire (bounded wait, fixed order, all-or-
# nothing), release (refuses a foreign owner), status (read-only probe),
# clear (refuses anything not provably stale), and keep (the detached
# keeper `acquire --hold-seconds` spawns). No manifest; its one shell-out
# is the keeper spawn, through `Sh.spawn_detached` (see the plan's "What
# We're NOT Doing": the fleet manifest that would otherwise name these
# paths is out of scope here). The one thing read from outside the argv is
# the machine config's `machine.gate_slots`, which caps the slot pool for
# this box: a `--slots N` may lower that cap, never raise it
# (Lock.resolve_slot_count).
module LockCli
  SUBCOMMANDS = %w[acquire release status clear keep].freeze
  DEFAULT_STALE_AFTER_SECONDS = 1800
  KEEPER_POLL_SECONDS = 2

  # How long spawn_keeper_and_emit polls a freshly spawned keeper for
  # immediate death before trusting its pid as the lock's owner: a bound
  # of tries * interval seconds, about 1s at the defaults.
  KEEPER_DEATH_CHECK_TRIES = 20
  KEEPER_DEATH_CHECK_INTERVAL = 0.05

  # The absolute path to this file, used to spawn the detached keeper
  # (`ruby <this file> keep ...`), the same move gate_run.rb makes to spawn
  # its own detached supervisor (gate_run.rb:67).
  SELF_PATH = File.expand_path(__FILE__)

  ACQUIRE_USAGE = "lock.rb acquire [--campaign-mutex DIR] [--gate-lock DIR] [--tracker-lock DIR] " \
                  "[--registry-lock DIR] [--slots-dir DIR [--slots N]] --campaign ID --bead ID " \
                  "[--pid N] [--hold-seconds N] [--purpose S] [--wait-seconds N] [--poll-seconds N]"
  SLOTS_HINT = "--slots-dir needs a slot count: --slots N, or machine.gate_slots in the machine config " \
               "(~/.claude/wurk.local.json), which takes precedence when both are set"
  HOLD_PID_HINT = "a keeper-held lock's pid is the keeper's; pass one or the other"
  RELEASE_USAGE = "lock.rb release --dir DIR --campaign ID --bead ID [--pid N]"
  STATUS_USAGE = "lock.rb status --dir DIR [--stale-after-seconds N]"
  CLEAR_USAGE = "lock.rb clear --dir DIR"
  KEEP_USAGE = "lock.rb keep --dir DIR [--dir DIR ...] --acquirer-pid N --hold-until ISO [--poll-seconds N]"

  class << self
    # Test-only seam: a test that wants to exercise the immediate-death
    # detection without a real dying process can install a fake here
    # (e.g. ->(pid) { false }) and must reset it to nil in teardown. Left
    # nil, #probe_keeper_alive uses the real Process.kill(0, pid) poll.
    attr_accessor :keeper_probe

    def run(argv, io: $stdout)
      argv = argv.dup
      if Cli.unsplit_argv?(argv)
        env = Envelope.new(script: "lock")
        env.block!(code: "argv_unsplit", message: Cli.unsplit_message(argv))
        env.emit(io)
        exit 2
      end
      unless SUBCOMMANDS.include?(argv.first)
        warn usage
        exit 2
      end

      case argv.shift
      when "acquire" then run_acquire(argv, io)
      when "release" then run_release(argv, io)
      when "status" then run_status(argv, io)
      when "clear" then run_clear(argv, io)
      when "keep" then run_keep(argv, io)
      end
    end

    private

    def usage
      "usage: lock.rb <acquire|release|status|clear|keep> [options]"
    end

    # --- acquire ----------------------------------------------------------

    def run_acquire(argv, io)
      options = { dry_run: false, wait_seconds: 600, poll_seconds: 10 }
      parser, options = Cli.build(ACQUIRE_USAGE, options) { |opts| add_acquire_flags(opts, options) }
      Cli.parse!(parser, argv)

      usage_error!(ACQUIRE_USAGE, parser) if blank?(options[:campaign]) || blank?(options[:bead])
      usage_error!(ACQUIRE_USAGE, parser) if options[:hold_seconds] && options[:hold_seconds] <= 0
      usage_error!(ACQUIRE_USAGE, parser, hint: HOLD_PID_HINT) if options[:hold_seconds] && options[:pid]

      env = Envelope.new(script: "lock_acquire")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      slots = Lock.resolve_slot_count(machine: config.machine_gate_slots, flag: options[:slots])
      specs = acquire_specs(options, slots[:count])
      usage_error!(ACQUIRE_USAGE, parser, hint: slots_hint(options)) if specs.nil?
      report_slot_source(env, slots, options)

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
        return spawn_keeper_and_emit(env, io, result[:locks], owner) if options[:hold_seconds]

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
      opts.on("--hold-seconds N", Integer, "spawn a detached keeper that holds this lock for N seconds") { |v| options[:hold_seconds] = v }
      opts.on("--purpose S", "free-text purpose, recorded in the owner file") { |v| options[:purpose] = v }
      opts.on("--wait-seconds N", Integer, "bounded wait before lock_contended (default 600)") { |v| options[:wait_seconds] = v }
      opts.on("--poll-seconds N", Integer, "poll interval while waiting (default 10)") { |v| options[:poll_seconds] = v }
    end

    # Spawns the detached keeper for every lock this acquire call just took,
    # rewrites each owner file's pid to the keeper's, and reports
    # data.keeper_pid/data.hold_until. A SystemCallError from the spawn
    # (missing ruby, unusable argv) releases every lock just taken - a hold
    # with no keeper would record this CLI's own pid, which is dead the
    # moment it exits - and blocks keeper_spawn_failed.
    #
    # Sh.spawn_detached's returned pid is only ever a live keeper as far as
    # this method has checked: it is the pid Process.spawn handed back, not
    # proof the keeper is still running a moment later. A keeper that dies
    # immediately after starting (a usage exit 2 out of its own Cli.parse!,
    # an unparseable --hold-until, any startup exception) would otherwise
    # get recorded as the owner and reported acquired, and probe would then
    # read a genuinely dead lock as alive for as long as nothing kills that
    # pid a second time. So the rewrite is followed by a brief bounded poll
    # (probe_keeper_alive) before the lock is trusted; on a dead keeper this
    # rolls back exactly like the spawn-failure path and blocks with its own
    # distinct code, keeper_died_immediately, so the two causes (could not
    # spawn at all vs. spawned and died at once) stay tellable apart.
    def spawn_keeper_and_emit(env, io, locks, owner)
      keeper_argv = build_keeper_argv(locks.map { |l| l[:dir] }, owner["hold_until"])

      begin
        keeper_pid = Sh.spawn_detached(keeper_argv, out_path: File::NULL)
      rescue SystemCallError => e
        locks.reverse_each { |l| Lock.release(l[:dir], owner, force: true) }
        env.data[:acquired] = []
        env.block!(code: "keeper_spawn_failed",
                   message: "could not spawn the lock keeper: #{e.message}")
        return env.emit(io)
      end

      locks.each { |l| Lock.rewrite_owner_pid(l[:dir], keeper_pid) }

      if premature_keeper_death?(keeper_pid, owner["hold_until"])
        locks.reverse_each { |l| Lock.release(l[:dir], owner, force: true) }
        env.data[:acquired] = []
        env.block!(code: "keeper_died_immediately",
                   message: "the lock keeper (pid #{keeper_pid}) exited immediately after starting; " \
                             "the lock was released rather than left recorded under a dead pid")
        return env.emit(io)
      end

      env.data[:acquired] = locks.map { |l| l.merge(owner: l[:owner].merge("pid" => keeper_pid.to_s)) }
      env.data[:keeper_pid] = keeper_pid
      env.data[:hold_until] = owner["hold_until"]
      env.commands << Sh.render(keeper_argv)
      env.emit(io)
    end

    # dirs is a plain list of lock directory strings (the concrete slot dir,
    # not the pool) - shared by spawn_keeper_and_emit and the dry-run
    # preview so the two never drift on what the keeper command looks like.
    #
    # LOCK_RB_TEST_KEEPER_HOLD_UNTIL_OVERRIDE is a test-only seam: when set,
    # it replaces the --hold-until value the real keeper is spawned with, so
    # a real-process test can make the spawned keeper's own Cli.parse!
    # reject it and exit immediately, exercising probe_keeper_alive against
    # a genuinely dying process rather than a mock. It is never set outside
    # a test; the dry-run preview also reflects it (nothing is ever spawned
    # under --dry-run, so there is nothing for the override to make die).
    def build_keeper_argv(dirs, hold_until)
      [RbConfig.ruby, SELF_PATH, "keep",
       *dirs.flat_map { |d| ["--dir", d] },
       "--acquirer-pid", Process.pid.to_s,
       "--hold-until", ENV["LOCK_RB_TEST_KEEPER_HOLD_UNTIL_OVERRIDE"] || hold_until,
       "--poll-seconds", KEEPER_POLL_SECONDS.to_s]
    end

    # Polls Process.kill(0, pid) briefly (about KEEPER_DEATH_CHECK_TRIES *
    # KEEPER_DEATH_CHECK_INTERVAL seconds) for a keeper that has already
    # died. Sh.spawn_detached detaches via Process.detach - a background
    # thread in THIS process that waits on the child - not a double fork,
    # so a keeper that exited the instant it started is a zombie
    # until that thread gets scheduled and reaps it; until then kill(0,pid)
    # still succeeds (the process table entry exists), so a single
    # immediate check would wrongly read a dead keeper as alive. Polling
    # gives the detach thread room to run (Kernel#sleep between tries yields
    # the scheduler) so a genuinely dead keeper turns into a real ESRCH
    # inside the bound; a keeper still unreaped after the bound is treated
    # as alive, since a slow reap is not evidence of death. Delegates to
    # keeper_probe when a test has installed one.
    def probe_keeper_alive(pid)
      return keeper_probe.call(pid) if keeper_probe

      KEEPER_DEATH_CHECK_TRIES.times do |i|
        begin
          Process.kill(0, pid)
        rescue Errno::ESRCH
          return false
        rescue Errno::EPERM
          return true
        end
        sleep(KEEPER_DEATH_CHECK_INTERVAL) unless i == KEEPER_DEATH_CHECK_TRIES - 1
      end
      true
    end

    # A dead keeper is only a bug when its own lease had not yet run out -
    # probe_keeper_alive's poll window (about 1s) can outlast a --hold-
    # seconds short enough that the keeper legitimately expired while we
    # were still watching (the plan's own expiry test uses --hold-seconds
    # 1). That case is not a crash: it is the ordinary "expired" exit
    # Lock.keep already documents, and the dead pid it leaves behind is
    # exactly what probe/clear expect - rolling it back here would be
    # wrong. So a dead keeper is reported premature (a real
    # keeper_died_immediately) only while hold_until is still in the
    # future; at or past it, this method defers to the ordinary expired-
    # lease path and returns false (not premature).
    def premature_keeper_death?(pid, hold_until_iso)
      return false if probe_keeper_alive(pid)

      Time.iso8601(hold_until_iso) > Time.now
    end

    # Builds the ordered lock specs from whichever lock flags were given.
    # `slot_count` is the already-resolved pool size (machine config over
    # --slots). Returns nil (a usage error) when no lock was named at all,
    # when --slots was given without --slots-dir, or when --slots-dir was
    # given and neither --slots nor the machine config supplied a count.
    def acquire_specs(options, slot_count)
      specs = []
      specs << { kind: "campaign", dir: options[:campaign_mutex] } if options[:campaign_mutex]
      specs << { kind: "gate", dir: options[:gate_lock] } if options[:gate_lock]
      specs << { kind: "tracker", dir: options[:tracker_lock] } if options[:tracker_lock]
      specs << { kind: "registry", dir: options[:registry_lock] } if options[:registry_lock]

      slots_named = options[:slots_dir] || options[:slots]
      if slots_named
        return nil if blank?(options[:slots_dir]) || slot_count.to_i <= 0

        specs << { kind: "slot", slots_dir: options[:slots_dir], count: slot_count }
      end

      specs.empty? ? nil : specs
    end

    # The usage hint for the slot flags, only when the slot flags are what
    # went wrong; a plain "no lock named" usage error gets none.
    def slots_hint(options)
      options[:slots_dir] || options[:slots] ? SLOTS_HINT : nil
    end

    # Records where the slot count came from, and warns when the machine
    # config LOWERED the --slots value the caller passed - the caller
    # (usually a conductor relaying a fleet manifest) should see that its
    # number was not the one used. A flag below the cap is used as given and
    # draws no warning.
    def report_slot_source(env, slots, options)
      return if slots[:count].nil? || blank?(options[:slots_dir])

      env.data[:slots] = slots[:count]
      env.data[:slots_source] = slots[:source]
      return unless slots[:overridden]

      env.warn(code: "slots_overridden",
               message: "--slots #{options[:slots]} lowered to #{slots[:count]}: machine.gate_slots " \
                        "caps this box at #{slots[:count]} and a flag may not raise it")
    end

    def build_owner(options)
      owner = { "campaign" => options[:campaign], "bead" => options[:bead], "acquired_at" => Time.now.utc.iso8601 }
      owner["pid"] = options[:pid].to_s if options[:pid]
      if options[:hold_seconds]
        # Seeded with THIS process's pid, not the keeper's - the keeper does
        # not exist yet. Without this seed the owner file would carry no pid
        # at all during the window between acquire and the owner rewrite,
        # and the keeper's first poll would read its own lock as not ours
        # (Lock.keep treats a pid-less owner as not ours). gate_run.rb start
        # seeds its own supervisor's lock owner the same way.
        owner["pid"] = Process.pid.to_s
        owner["hold_until"] = (Time.now + options[:hold_seconds]).utc.iso8601
      end
      owner["purpose"] = options[:purpose] if options[:purpose]
      begin
        owner["host"] = Socket.gethostname
      rescue SocketError, SystemCallError
        # host is best-effort metadata; its absence never blocks an acquire
      end
      owner
    end

    def emit_acquire_dry_run(env, io, specs, order, owner)
      targets = []
      order.each do |kind|
        spec = specs.find { |s| s[:kind] == kind }
        target = spec[:kind] == "slot" ? "#{spec[:slots_dir]}/slot-1..#{spec[:count]}" : spec[:dir]
        targets << target
        env.commands << "mkdir #{target} (owner campaign=#{owner['campaign']} bead=#{owner['bead']})"
      end
      env.data[:acquired] = []
      env.data[:order] = order
      env.data[:waited_seconds] = 0

      if owner["hold_until"]
        env.commands << Sh.render(build_keeper_argv(targets, owner["hold_until"]))
        env.data[:hold_until] = owner["hold_until"]
      end

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

    # --- keep -----------------------------------------------------------------
    #
    # The detached keeper `acquire --hold-seconds` spawns. Internal - not
    # meant to be run by hand, the same way gate_run.rb's `supervise` is not.
    # Its stdout/stderr are redirected to /dev/null by the spawn, so the
    # envelope it emits is never read by anyone in practice; it still emits
    # one, because the contract holds regardless of who is watching.

    def run_keep(argv, io)
      options = { dry_run: false, poll_seconds: KEEPER_POLL_SECONDS, dirs: [] }
      parser, options = Cli.build(KEEP_USAGE, options) do |opts|
        opts.on("--dir DIR", "lock directory to watch (repeatable)") { |v| options[:dirs] << v }
        opts.on("--acquirer-pid N", Integer, "the acquiring CLI's pid, counted as ours until rewritten") { |v| options[:acquirer_pid] = v }
        opts.on("--hold-until ISO", "the lease deadline (ISO-8601)") { |v| options[:hold_until] = v }
        opts.on("--poll-seconds N", Integer, "poll interval while watching (default #{KEEPER_POLL_SECONDS})") { |v| options[:poll_seconds] = v }
      end
      Cli.parse!(parser, argv)
      usage_error!(KEEP_USAGE, parser) if options[:dirs].empty? || options[:acquirer_pid].nil? || blank?(options[:hold_until])

      hold_until = begin
        Time.iso8601(options[:hold_until])
      rescue ArgumentError
        usage_error!(KEEP_USAGE, parser, hint: "--hold-until must be ISO-8601 (got #{options[:hold_until].inspect})")
      end

      env = Envelope.new(script: "lock_keep")
      env.data[:dirs] = options[:dirs]

      if options[:dry_run]
        env.data[:watching] = options[:dirs]
        return env.emit(io)
      end

      result = Lock.keep(options[:dirs], own_pid: Process.pid, acquirer_pid: options[:acquirer_pid],
                                          hold_until: hold_until, poll_seconds: options[:poll_seconds])
      env.data[:reason] = result[:reason]
      env.data[:watching] = result[:watching]
      env.emit(io)
    end

    # --- shared ---------------------------------------------------------------

    def blank?(value)
      value.to_s.strip.empty?
    end

    def usage_error!(usage_line, parser, hint: nil)
      warn "usage: #{usage_line}\n#{hint ? "\n#{hint}\n" : ''}\n#{parser}"
      exit 2
    end
  end
end

exit LockCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

# frozen_string_literal: true

require "fileutils"
require "time"

# Lock is the mkdir-mutex the conductor spec describes in prose
# (skills/wurk:conductor/REFERENCE.md:29-90) turned into a machine-checkable
# mechanism. Pure filesystem + Process.kill logic only - no Sh, no envelope,
# no manifest - so it is directly unit-testable with Dir.mktmpdir and needs
# no fixture wiring. lock.rb (the CLI, one directory up) wires this into the
# kit's envelope contract.
#
# A lock is a directory. Acquiring one is `Dir.mkdir`, which is atomic on
# every filesystem the kit runs on: two processes racing to create the same
# directory, exactly one succeeds and the other gets Errno::EEXIST. Releasing
# one is removing the owner file then the directory. Nothing here uses
# flock, a pid file library, or any gem - stdlib only, per ADR-0006.
module Lock
  OWNER_FILE = "owner"

  # The fixed acquisition order from skills/wurk:conductor/REFERENCE.md:74-78:
  # the repo gate lock (or a campaign mutex, if the campaign caps its own
  # concurrency below the machine cap) is taken before a machine slot, and
  # locks release in the reverse of the order they were taken. Lower rank is
  # taken first and released last. Registry and tracker locks are
  # independent of the gate/slot chain but are given a consistent place in
  # the same total order so a caller never has to think about interleaving:
  # it hands this module every lock it wants in any order, and the order is
  # normalized here, making an out-of-order request a non-event rather than
  # a deadlock.
  ORDER = { "campaign" => 1, "registry" => 1, "gate" => 2, "tracker" => 2, "slot" => 3 }.freeze

  # Keys the owner file may carry, in the order they are written. Not every
  # key is present on every lock (a human-held lock may carry no pid); an
  # absent key is simply not written, never written empty.
  OWNER_KEYS = %w[campaign bead pid host purpose acquired_at].freeze

  DEFAULT_CLOCK = -> { Time.now }
  DEFAULT_SLEEPER = ->(seconds) { Kernel.sleep(seconds) }

  class << self
    # Attempts to create dir as a new, empty directory and, on success,
    # writes the owner file into it. Returns true/false; never raises for
    # the ordinary contention case (Errno::EEXIST).
    #
    # The owner file is written in a second step, after Dir.mkdir succeeds -
    # so a reader may briefly observe a lock directory with no owner file
    # yet. read_owner and probe both treat "directory exists, owner file
    # missing or unreadable" as owner: nil rather than raising, and a caller
    # that needs to distinguish "briefly ownerless" from "genuinely
    # ownerless" should retry before concluding the latter.
    def try_acquire(dir, owner)
      FileUtils.mkdir_p(File.dirname(dir))
      Dir.mkdir(dir)
      write_owner(dir, owner)
      true
    rescue Errno::EEXIST
      false
    end

    def write_owner(dir, owner)
      File.write(File.join(dir, OWNER_FILE), owner_content(owner))
    end

    # Atomically corrects the pid= field of an already-published owner file,
    # leaving every other field untouched. gate_run.rb's `start` needs this:
    # the lock is acquired under the CLI process's own pid because the real
    # supervisor pid does not exist until after Sh.spawn_detached returns, so
    # the owner file is patched once the supervisor is running. Unlike
    # write_owner's first write (nothing has discovered the lock dir yet),
    # this owner file may already have readers polling it (lock.rb status, a
    # contending acquire), so the correction goes to a sibling temp file and
    # is File.renamed into place - a reader sees the old contents or the new
    # ones, never a half-written file.
    def rewrite_owner_pid(dir, pid)
      current = read_owner(dir) || {}
      current["pid"] = pid.to_s
      owner_path = File.join(dir, OWNER_FILE)
      tmp_path = File.join(dir, "#{OWNER_FILE}.tmp-#{Process.pid}")
      File.write(tmp_path, owner_content(current))
      File.rename(tmp_path, owner_path)
    end

    # key=value lines -> hash (string keys, string values). Absent or
    # unparseable owner file yields nil - never raises. A line with no "="
    # is skipped rather than blocking the whole parse.
    def read_owner(dir)
      path = File.join(dir, OWNER_FILE)
      return nil unless File.file?(path)

      content = File.read(path)
      result = {}
      content.each_line do |line|
        line = line.chomp
        next if line.empty?

        key, value = line.split("=", 2)
        result[key] = value if key && value
      end
      result.empty? ? nil : result
    rescue SystemCallError
      nil
    end

    # Bounded-wait acquire of a single lock directory. Polls at most every
    # poll_seconds (never sleeping past the deadline) via the injected
    # sleeper, so a test can assert the wait loop ran without sleeping for
    # real. Returns {acquired:, dir:, owner:, waited_seconds:}.
    def acquire(dir, owner, wait_seconds:, poll_seconds:, clock: DEFAULT_CLOCK, sleeper: DEFAULT_SLEEPER)
      start = clock.call
      deadline = start + wait_seconds

      loop do
        return { acquired: true, dir: dir, owner: owner, waited_seconds: clock.call - start } if try_acquire(dir, owner)

        now = clock.call
        return { acquired: false, dir: dir, owner: owner, waited_seconds: now - start } if now >= deadline

        sleeper.call([poll_seconds, deadline - now].min)
      end
    end

    # Acquires the first free slot-1..slot-N under slots_dir. Same shape and
    # bounded-wait behavior as acquire, but each poll cycle sweeps every
    # slot instead of retrying one fixed directory.
    def acquire_slot(slots_dir, count, owner, wait_seconds:, poll_seconds:, clock: DEFAULT_CLOCK, sleeper: DEFAULT_SLEEPER)
      start = clock.call
      deadline = start + wait_seconds

      loop do
        (1..count).each do |i|
          dir = File.join(slots_dir, "slot-#{i}")
          return { acquired: true, dir: dir, owner: owner, waited_seconds: clock.call - start } if try_acquire(dir, owner)
        end

        now = clock.call
        return { acquired: false, dir: nil, owner: owner, waited_seconds: now - start } if now >= deadline

        sleeper.call([poll_seconds, deadline - now].min)
      end
    end

    # Acquires every spec, sorted by ORDER, releasing what was already taken
    # (in reverse) the moment one cannot be had inside the shared wait
    # budget. Each element of specs is either {kind:, dir:} for an ordinary
    # named lock, or {kind: "slot", slots_dir:, count:} for the machine
    # slot pool.
    #
    # Returns, on success: {acquired: true, locks: [{kind:, dir:, owner:}],
    # order: [kind, ...], waited_seconds:}.
    # On contention: {acquired: false, locks: [...already released...],
    # order: [...], contended_kind:, contended_dir:, waited_seconds:} - the
    # caller (lock.rb) probes contended_dir itself so the envelope carries
    # the staleness evidence.
    def acquire_all(specs, owner:, wait_seconds:, poll_seconds:, clock: DEFAULT_CLOCK, sleeper: DEFAULT_SLEEPER)
      sorted = specs.sort_by { |spec| ORDER.fetch(spec[:kind]) }
      start = clock.call
      acquired = []

      sorted.each do |spec|
        result = acquire_one(spec, owner, wait_seconds: wait_seconds, poll_seconds: poll_seconds, clock: clock, sleeper: sleeper)

        if result[:acquired]
          acquired << { kind: spec[:kind], dir: result[:dir], owner: owner }
          next
        end

        acquired.reverse_each { |lock| release(lock[:dir], owner, force: true) }
        return {
          acquired: false,
          locks: [],
          order: sorted.map { |s| s[:kind] },
          contended_kind: spec[:kind],
          contended_dir: result[:dir] || spec[:dir] || spec[:slots_dir],
          waited_seconds: clock.call - start
        }
      end

      { acquired: true, locks: acquired, order: sorted.map { |s| s[:kind] }, waited_seconds: clock.call - start }
    end

    # Filesystem/pid-liveness probe. `stale` is true only in the two cases
    # the plan draws a line between: a provably dead holder pid
    # (staleness_reason "dead_holder_pid"), or an ownerless lock older than
    # stale_after_seconds (staleness_reason "ownerless_and_older_than_cutoff").
    # A lock with no pid recorded but a live-seeming holder (holder_alive
    # nil, age within cutoff) is reported as not stale - degrade honestly,
    # never guess.
    def probe(dir, now: DEFAULT_CLOCK.call, stale_after_seconds: 1800)
      unless Dir.exist?(dir)
        return { held: false, owner: nil, age_seconds: nil, holder_alive: nil, stale: false, staleness_reason: nil }
      end

      owner = read_owner(dir)
      age_seconds = (now - mtime(dir)).round
      holder_alive = holder_alive?(owner)

      stale, reason =
        if holder_alive == false
          [true, "dead_holder_pid"]
        elsif holder_alive.nil? && age_seconds > stale_after_seconds
          [true, "ownerless_and_older_than_cutoff"]
        else
          [false, nil]
        end

      { held: true, owner: owner, age_seconds: age_seconds, holder_alive: holder_alive, stale: stale, staleness_reason: reason }
    end

    # Refuses to remove a lock it does not own unless force: true. Owner
    # identity is compared field by field over whichever of
    # campaign/bead/pid the caller supplies in `owner` - a field the caller
    # omits is not checked, but every field it does supply must match the
    # lock's recorded owner, and an ownerless lock never matches (force is
    # the only way to remove one).
    def release(dir, owner, force: false)
      return { released: false, reason: "not_held" } unless Dir.exist?(dir)

      current = read_owner(dir)
      return { released: false, reason: "not_owned", current_owner: current } unless force || owner_matches?(current, owner)

      owner_path = File.join(dir, OWNER_FILE)
      File.delete(owner_path) if File.file?(owner_path)
      Dir.rmdir(dir)
      { released: true, dir: dir, owner: current }
    rescue Errno::ENOTEMPTY, SystemCallError => e
      { released: false, reason: "rmdir_failed", message: e.message }
    end

    # Removes a lock outright, with no ownership check, but only when probe
    # proves it stale via a dead holder pid - the one case a script may
    # decide on its own (REFERENCE.md:83-87: "only a conductor clears, after
    # an owner re-read and a liveness probe" - the proof lives here, the
    # ambiguous case is left to lock.rb's CLI to refuse to a human).
    def clear(dir, stale_after_seconds:, now: DEFAULT_CLOCK.call)
      result = probe(dir, now: now, stale_after_seconds: stale_after_seconds)
      return { cleared: false, reason: "not_held", probe: result } unless result[:held]
      return { cleared: false, reason: "not_provably_stale", probe: result } unless result[:stale] && result[:staleness_reason] == "dead_holder_pid"

      FileUtils.rm_rf(dir)
      { cleared: true, probe: result }
    end

    # Field-by-field owner identity comparison, exposed publicly so a CLI
    # can decide "would this release be refused?" under --dry-run without
    # duplicating release's mutation. See #release for the matching rule.
    def owner_matches?(current, requested)
      return false if current.nil?

      %w[campaign bead pid].all? do |key|
        wanted = requested[key] || requested[key.to_sym]
        wanted.nil? || current[key] == wanted.to_s
      end
    end

    private

    def owner_content(owner)
      lines = OWNER_KEYS.filter_map do |key|
        value = owner[key] || owner[key.to_sym]
        next if value.nil?

        "#{key}=#{value}"
      end
      "#{lines.join("\n")}\n"
    end

    def acquire_one(spec, owner, wait_seconds:, poll_seconds:, clock:, sleeper:)
      if spec[:kind] == "slot"
        acquire_slot(spec[:slots_dir], spec[:count], owner, wait_seconds: wait_seconds, poll_seconds: poll_seconds, clock: clock, sleeper: sleeper)
      else
        acquire(spec[:dir], owner, wait_seconds: wait_seconds, poll_seconds: poll_seconds, clock: clock, sleeper: sleeper)
      end
    end

    def mtime(dir)
      owner_path = File.join(dir, OWNER_FILE)
      File.file?(owner_path) ? File.mtime(owner_path) : File.mtime(dir)
    end

    # true (alive), false (provably dead), or nil (unknown: no pid recorded,
    # or the owner file itself could not be read). Process.kill(0, pid) is
    # the deterministic liveness check the plan specifies: Errno::ESRCH
    # proves dead, Errno::EPERM proves alive-but-not-ours, no exception
    # means alive.
    def holder_alive?(owner)
      return nil if owner.nil? || owner["pid"].nil?

      pid = Integer(owner["pid"], exception: false)
      return nil if pid.nil?

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
  end
end

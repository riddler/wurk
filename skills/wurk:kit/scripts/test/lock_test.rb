# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../lib/lock"
require_relative "../lock"

# A no-op sleeper that just counts calls, so a bounded-wait test never
# sleeps for real. Paired with FakeClock below, this is the seam the plan's
# Automated Verification requires: the contention test can assert the
# sleeper was actually invoked while the test's own wall clock stays well
# under a second.
class RecordingSleeper
  attr_reader :calls

  def initialize
    @calls = []
  end

  def call(seconds)
    @calls << seconds
  end
end

# A controllable clock: starts at a fixed Time and advances by exactly the
# amount the (fake) sleeper "slept", so acquire's deadline math runs to
# completion without any real time passing.
class FakeClock
  def initialize(start = Time.now)
    @now = start
  end

  def call
    @now
  end

  def advance(seconds)
    @now += seconds
  end
end

# Ties a FakeClock and RecordingSleeper together so every recorded sleep
# also advances the clock - the shape acquire's `loop` needs to ever reach
# its deadline without a real sleep.
class FakeWaiter
  attr_reader :clock, :sleeper

  def initialize(start = Time.now)
    @clock = FakeClock.new(start)
    @sleeper = RecordingSleeper.new
  end

  def clock_proc
    @clock
  end

  def sleeper_proc
    waiter = self
    ->(seconds) {
      waiter.sleeper.call(seconds)
      waiter.clock.advance(seconds)
    }
  end
end

# Lock (the pure filesystem/pid module). Dir.mktmpdir, never FakeSh - this
# module shells out to nothing.
class LockLibTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def lock_dir(name = "gate-x")
    File.join(@dir, name)
  end

  def owner(extra = {})
    { "campaign" => "c1", "bead" => "zz-1", "pid" => Process.pid.to_s }.merge(extra)
  end

  # --- try_acquire / read_owner --------------------------------------------

  def test_try_acquire_creates_dir_and_owner_file
    dir = lock_dir
    assert Lock.try_acquire(dir, owner)

    assert Dir.exist?(dir)
    assert File.file?(File.join(dir, Lock::OWNER_FILE))
  end

  def test_try_acquire_returns_false_when_already_held
    dir = lock_dir
    assert Lock.try_acquire(dir, owner)
    refute Lock.try_acquire(dir, owner("bead" => "zz-2"))
  end

  def test_read_owner_parses_key_value_lines
    dir = lock_dir
    Lock.try_acquire(dir, owner("purpose" => "gate run"))

    parsed = Lock.read_owner(dir)
    assert_equal "c1", parsed["campaign"]
    assert_equal "zz-1", parsed["bead"]
    assert_equal "gate run", parsed["purpose"]
  end

  def test_read_owner_returns_nil_for_missing_file
    dir = lock_dir
    Dir.mkdir(dir)

    assert_nil Lock.read_owner(dir)
  end

  def test_read_owner_returns_nil_for_unparseable_content_and_never_raises
    dir = lock_dir
    Dir.mkdir(dir)
    File.write(File.join(dir, Lock::OWNER_FILE), "not a key value file at all\n\n")

    assert_nil Lock.read_owner(dir)
  end

  # --- acquire: bounded wait, seam-only sleeping ---------------------------

  def test_acquire_succeeds_immediately_when_free
    dir = lock_dir
    result = Lock.acquire(dir, owner, wait_seconds: 5, poll_seconds: 1)

    assert result[:acquired]
    assert Dir.exist?(dir)
  end

  # The Automated Verification requirement: the injected sleeper recorded at
  # least one call, and the test's own wall clock stayed under 0.5s -
  # together these prove the wait loop went through the seam and never
  # reached Kernel.sleep.
  def test_second_acquire_on_a_held_lock_waits_then_blocks_with_lock_contended
    dir = lock_dir
    Lock.try_acquire(dir, owner)

    waiter = FakeWaiter.new
    wall_clock_start = Time.now

    result = Lock.acquire(
      dir, owner("bead" => "zz-2"),
      wait_seconds: 30, poll_seconds: 10,
      clock: waiter.clock_proc, sleeper: waiter.sleeper_proc
    )

    wall_elapsed = Time.now - wall_clock_start

    refute result[:acquired]
    assert_operator waiter.sleeper.calls.length, :>=, 1
    assert_operator wall_elapsed, :<, 0.5
  end

  def test_acquire_polls_at_the_poll_interval_never_past_the_deadline
    dir = lock_dir
    Lock.try_acquire(dir, owner)

    waiter = FakeWaiter.new
    Lock.acquire(dir, owner, wait_seconds: 25, poll_seconds: 10, clock: waiter.clock_proc, sleeper: waiter.sleeper_proc)

    # Three polls of 10s would overshoot a 25s budget; the last one is
    # clamped to the 5s remaining.
    assert_equal [10, 10, 5], waiter.sleeper.calls
  end

  # --- acquisition order is normalized regardless of flag order -----------

  def test_acquire_all_normalizes_order_regardless_of_input_order
    specs = [
      { kind: "slot", slots_dir: File.join(@dir, "slots"), count: 2 },
      { kind: "gate", dir: lock_dir("gate-x") },
      { kind: "campaign", dir: lock_dir("campaign-x") }
    ]

    result = Lock.acquire_all(specs, owner: owner, wait_seconds: 5, poll_seconds: 1)

    assert result[:acquired]
    assert_equal %w[campaign gate slot], result[:order]
    assert_equal %w[campaign gate slot], result[:locks].map { |l| l[:kind].to_s }
  end

  # --- a failure on the third lock releases the first two in reverse ------

  def test_partial_failure_releases_already_acquired_locks_in_reverse_order
    contended = lock_dir("tracker-x")
    Lock.try_acquire(contended, owner("bead" => "someone-else"))

    specs = [
      { kind: "campaign", dir: lock_dir("campaign-x") },
      { kind: "gate", dir: lock_dir("gate-x") },
      { kind: "tracker", dir: contended }
    ]

    result = Lock.acquire_all(specs, owner: owner, wait_seconds: 0, poll_seconds: 1)

    refute result[:acquired]
    assert_equal "tracker", result[:contended_kind]
    refute Dir.exist?(lock_dir("campaign-x")), "campaign lock should have been released on partial failure"
    refute Dir.exist?(lock_dir("gate-x")), "gate lock should have been released on partial failure"
    assert Dir.exist?(contended), "the contended lock (never ours) must survive untouched"
  end

  # --- slot acquisition ------------------------------------------------------

  def test_acquire_slot_takes_the_first_free_slot
    slots_dir = File.join(@dir, "slots")
    result = Lock.acquire_slot(slots_dir, 3, owner, wait_seconds: 5, poll_seconds: 1)

    assert result[:acquired]
    assert_equal File.join(slots_dir, "slot-1"), result[:dir]
  end

  def test_acquire_slot_skips_taken_slots
    slots_dir = File.join(@dir, "slots")
    Lock.try_acquire(File.join(slots_dir, "slot-1"), owner)

    result = Lock.acquire_slot(slots_dir, 2, owner, wait_seconds: 5, poll_seconds: 1)

    assert result[:acquired]
    assert_equal File.join(slots_dir, "slot-2"), result[:dir]
  end

  def test_acquire_slot_blocks_when_all_taken
    slots_dir = File.join(@dir, "slots")
    Lock.try_acquire(File.join(slots_dir, "slot-1"), owner)
    Lock.try_acquire(File.join(slots_dir, "slot-2"), owner)

    waiter = FakeWaiter.new
    result = Lock.acquire_slot(slots_dir, 2, owner, wait_seconds: 5, poll_seconds: 1, clock: waiter.clock_proc, sleeper: waiter.sleeper_proc)

    refute result[:acquired]
    assert_operator waiter.sleeper.calls.length, :>=, 1
  end

  # --- probe: pid liveness ----------------------------------------------------

  def test_probe_on_a_lock_owned_by_a_reaped_forked_pid_reports_dead_and_stale
    dead_pid = fork { exit(0) }
    Process.wait(dead_pid)

    dir = lock_dir
    Lock.try_acquire(dir, owner("pid" => dead_pid.to_s))

    result = Lock.probe(dir, stale_after_seconds: 1800)

    assert_equal false, result[:holder_alive]
    assert result[:stale]
    assert_equal "dead_holder_pid", result[:staleness_reason]
  end

  def test_probe_on_a_lock_owned_by_process_pid_reports_alive_and_not_stale_regardless_of_age
    dir = lock_dir
    Lock.try_acquire(dir, owner("pid" => Process.pid.to_s))

    far_future = Time.now + (100 * 24 * 60 * 60)
    result = Lock.probe(dir, now: far_future, stale_after_seconds: 60)

    assert_equal true, result[:holder_alive]
    refute result[:stale]
    assert_nil result[:staleness_reason]
  end

  def test_probe_on_an_ownerless_dir_reports_holder_alive_nil
    dir = lock_dir
    Dir.mkdir(dir)

    result = Lock.probe(dir, stale_after_seconds: 1800)

    assert_nil result[:holder_alive]
    assert_nil result[:owner]
  end

  def test_probe_on_an_ownerless_dir_older_than_cutoff_is_stale_for_a_distinct_reason
    dir = lock_dir
    Dir.mkdir(dir)

    far_future = Time.now + 3600
    result = Lock.probe(dir, now: far_future, stale_after_seconds: 60)

    assert result[:stale]
    assert_equal "ownerless_and_older_than_cutoff", result[:staleness_reason]
  end

  def test_probe_on_a_missing_dir_reports_not_held
    result = Lock.probe(lock_dir("does-not-exist"), stale_after_seconds: 60)

    refute result[:held]
    refute result[:stale]
  end

  # --- release ----------------------------------------------------------------

  def test_release_refuses_a_foreign_owner
    dir = lock_dir
    Lock.try_acquire(dir, owner)

    result = Lock.release(dir, owner("campaign" => "someone-else"))

    refute result[:released]
    assert_equal "not_owned", result[:reason]
    assert Dir.exist?(dir)
  end

  def test_release_succeeds_for_the_matching_owner
    dir = lock_dir
    Lock.try_acquire(dir, owner)

    result = Lock.release(dir, owner)

    assert result[:released]
    refute Dir.exist?(dir)
  end

  def test_release_refuses_an_ownerless_lock_without_force
    dir = lock_dir
    Dir.mkdir(dir)

    result = Lock.release(dir, owner)

    refute result[:released]
    assert Dir.exist?(dir)
  end

  def test_release_of_a_lock_that_does_not_exist_reports_not_held
    result = Lock.release(lock_dir("nope"), owner)

    refute result[:released]
    assert_equal "not_held", result[:reason]
  end

  # --- clear --------------------------------------------------------------

  def test_clear_refuses_a_live_holder
    dir = lock_dir
    Lock.try_acquire(dir, owner("pid" => Process.pid.to_s))

    result = Lock.clear(dir, stale_after_seconds: 60)

    refute result[:cleared]
    assert Dir.exist?(dir)
  end

  def test_clear_succeeds_on_a_dead_holder
    dead_pid = fork { exit(0) }
    Process.wait(dead_pid)

    dir = lock_dir
    Lock.try_acquire(dir, owner("pid" => dead_pid.to_s))

    result = Lock.clear(dir, stale_after_seconds: 60)

    assert result[:cleared]
    refute Dir.exist?(dir)
  end

  def test_clear_refuses_an_ownerless_lock_even_when_older_than_cutoff
    dir = lock_dir
    Dir.mkdir(dir)
    File.utime(Time.now - 7200, Time.now - 7200, dir)

    result = Lock.clear(dir, stale_after_seconds: 60)

    refute result[:cleared]
    assert_equal "not_provably_stale", result[:reason]
    assert Dir.exist?(dir)
  end
end

# LockCli - the envelope-wrapped subcommands, driven through the CLI
# dispatcher exactly the way plan_state_test.rb drives PlanStateCli.
class LockCliTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_cli(argv)
    io = StringIO.new
    code = LockCli.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  def lock_dir(name = "gate-x")
    File.join(@dir, name)
  end

  # --- acquire --------------------------------------------------------------

  def test_acquire_creates_dir_and_owner_file_and_reports_acquired
    code, env = run_cli(%W[acquire --gate-lock #{lock_dir} --campaign c1 --bead zz-1 --wait-seconds 5])

    assert_equal 0, code
    assert env["ok"]
    assert Dir.exist?(lock_dir)
    assert_equal 1, env["data"]["acquired"].length
    assert_equal "gate", env["data"]["acquired"].first["kind"]
  end

  def test_acquire_dry_run_creates_no_directory_and_records_intended_commands
    code, env = run_cli(%W[acquire --gate-lock #{lock_dir} --campaign c1 --bead zz-1 --dry-run])

    assert_equal 0, code
    refute Dir.exist?(lock_dir)
    assert_equal [], env["data"]["acquired"]
    refute_empty env["commands"]
    assert_match(/#{Regexp.escape(lock_dir)}/, env["commands"].first)
  end

  def test_acquire_with_no_lock_flags_is_a_usage_error
    io = StringIO.new
    _, status = capture_exit { LockCli.run(%w[acquire --campaign c1 --bead zz-1], io: io) }

    assert_equal 2, status
  end

  def test_acquire_blocked_with_lock_contended_reports_the_probe
    Lock.try_acquire(lock_dir, { "campaign" => "other", "bead" => "zz-9" })

    code, env = run_cli(%W[acquire --gate-lock #{lock_dir} --campaign c1 --bead zz-1 --wait-seconds 0 --poll-seconds 1])

    assert_equal 1, code
    refute env["ok"]
    assert_equal "lock_contended", env["blocked"].first["code"]
    assert_equal lock_dir, env["data"]["contended"]["dir"]
    assert_equal "other", env["data"]["contended"]["probe"]["owner"]["campaign"]
  end

  # --- release ----------------------------------------------------------------

  def test_release_succeeds_for_the_owner_that_holds_it
    run_cli(%W[acquire --gate-lock #{lock_dir} --campaign c1 --bead zz-1])

    code, env = run_cli(%W[release --dir #{lock_dir} --campaign c1 --bead zz-1])

    assert_equal 0, code
    assert env["data"]["released"]
    refute Dir.exist?(lock_dir)
  end

  def test_release_refuses_a_lock_owned_by_someone_else
    run_cli(%W[acquire --gate-lock #{lock_dir} --campaign c1 --bead zz-1])

    code, env = run_cli(%W[release --dir #{lock_dir} --campaign c2 --bead zz-9])

    assert_equal 1, code
    assert_equal "lock_not_owned", env["blocked"].first["code"]
    assert Dir.exist?(lock_dir)
  end

  # --- status -------------------------------------------------------------

  def test_status_is_read_only_and_always_exits_0
    code, env = run_cli(%W[status --dir #{lock_dir("does-not-exist")}])

    assert_equal 0, code
    refute env["data"]["held"]
  end

  # --- clear --------------------------------------------------------------

  def test_clear_refuses_a_live_holder_via_cli
    run_cli(%W[acquire --gate-lock #{lock_dir} --campaign c1 --bead zz-1 --pid #{Process.pid}])

    code, env = run_cli(%W[clear --dir #{lock_dir}])

    assert_equal 1, code
    assert_equal "lock_not_provably_stale", env["blocked"].first["code"]
    assert Dir.exist?(lock_dir)
  end

  def test_clear_succeeds_on_a_dead_holder_via_cli
    dead_pid = fork { exit(0) }
    Process.wait(dead_pid)
    run_cli(%W[acquire --gate-lock #{lock_dir} --campaign c1 --bead zz-1 --pid #{dead_pid}])

    code, env = run_cli(%W[clear --dir #{lock_dir}])

    assert_equal 0, code
    assert env["data"]["cleared"]
    refute Dir.exist?(lock_dir)
  end

  def test_clear_dry_run_removes_nothing
    dead_pid = fork { exit(0) }
    Process.wait(dead_pid)
    run_cli(%W[acquire --gate-lock #{lock_dir} --campaign c1 --bead zz-1 --pid #{dead_pid}])

    code, env = run_cli(%W[clear --dir #{lock_dir} --dry-run])

    assert_equal 0, code
    assert env["data"]["cleared"]
    assert Dir.exist?(lock_dir)
  end

  private

  # OptionParser's --help / usage_error paths call Kernel#exit; capture that
  # instead of letting it tear down the test process.
  def capture_exit
    yield
    [nil, 0]
  rescue SystemExit => e
    [nil, e.status]
  end
end

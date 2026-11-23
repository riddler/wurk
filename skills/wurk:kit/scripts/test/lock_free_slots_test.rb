# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "digest"
require_relative "../lib/lock"
require_relative "support/dead_pid"

# Lock.free_slots: how many slot-N directories no live owner holds at the
# moment of the reading. A count for a worker-cap answer, never a promise a
# slot is free - a slot acquire still decides for itself.
class LockFreeSlotsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("free-slots-")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def hold(slot, pid)
    Lock.try_acquire(File.join(@dir, "slot-#{slot}"), "campaign" => "c", "bead" => "b", "pid" => pid)
  end

  def snapshot
    Dir.glob(File.join(@dir, "**", "*"), File::FNM_DOTMATCH).sort.map do |path|
      stat = File.stat(path)
      [path, stat.mtime.to_f, File.file?(path) ? Digest::SHA256.file(path).hexdigest : :dir]
    end
  end

  # 5.1#1.
  def test_no_slot_dirs
    assert_equal 3, Lock.free_slots(dir: @dir, count: 3, now: Time.now)
  end

  def test_a_missing_slots_dir_is_all_free
    assert_equal 2, Lock.free_slots(dir: File.join(@dir, "nope"), count: 2, now: Time.now)
  end

  # 5.1#2. sabotage: count every slot free -> red.
  def test_a_live_owner_holds_one
    hold(1, Process.pid)
    assert_equal 2, Lock.free_slots(dir: @dir, count: 3, now: Time.now)
  end

  # 5.1#3. sabotage: count any existing slot dir as held -> red.
  def test_a_dead_pid_slot_counts_as_free
    hold(2, DeadPid.obtain)
    assert_equal 3, Lock.free_slots(dir: @dir, count: 3, now: Time.now)
  end

  # A slot past the count is not part of this machine's pool.
  def test_a_slot_past_the_count_is_not_counted
    hold(3, Process.pid)
    assert_equal 2, Lock.free_slots(dir: @dir, count: 2, now: Time.now)
  end

  # A nil count would be an endless range; it is refused instead.
  def test_a_missing_count_is_refused
    assert_raises(ArgumentError) { Lock.free_slots(dir: @dir, count: nil, now: Time.now) }
  end

  # 5.1#4. sabotage: clear the dead slot while counting -> red.
  def test_counting_takes_no_slot_and_clears_none
    hold(1, Process.pid)
    hold(2, DeadPid.obtain)
    before = snapshot
    Lock.free_slots(dir: @dir, count: 3, now: Time.now)
    assert_equal before, snapshot
  end
end

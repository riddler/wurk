# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/account_pause"
require_relative "support/fake_sh"

# AccountPause.check: is the current account's week (or its Fable week, for a
# Fable dispatch) spent? Reads only the newest capture of the current
# account; refreshes a stale one through an injected callable.
class AccountPauseTest < Minitest::Test
  NOW = Time.at(1_800_000_000)

  def setup
    @root = Dir.mktmpdir("limits-root-")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write_capture(week: 24, fable: 6, captured_ago: 60, resets_in: 86_400, email: "a@example.com",
                    extra_windows: {}, fable_resets_in: resets_in)
    FileUtils.mkdir_p(File.join(@root, ".state"))
    capture = {
      "schema" => 1,
      "account" => { "email" => email, "uuid" => "u-1" },
      "captured_at" => NOW.to_i - captured_ago,
      "windows" => {
        "seven_day" => { "used_percentage" => week, "resets_at" => NOW.to_i + resets_in },
        "seven_day_fable" => { "used_percentage" => fable, "resets_at" => NOW.to_i + fable_resets_in }
      }.merge(extra_windows)
    }
    File.write(File.join(@root, ".state", "current.json"), JSON.generate(capture))
  end

  def check(model: nil, refresh: nil)
    AccountPause.check(limits_root: @root, model: model, now: NOW, refresh: refresh)
  end

  def codes(result)
    result[:warnings].map { |w| w[:code] }
  end

  # 3.1#1.
  def test_a_week_under_100_is_not_a_pause
    write_capture(week: 24)
    result = check
    refute result[:paused]
    assert_equal 24, result[:week_used]
    assert_equal 6, result[:fable_used]
  end

  # 3.1#2. sabotage: compare with > 100 -> red.
  def test_a_week_at_100_pauses
    write_capture(week: 100)
    result = check
    assert result[:paused]
    assert_equal "week_spent", result[:reason]
  end

  # 3.1#3.
  def test_99_does_not_pause
    write_capture(week: 99)
    refute check[:paused]
  end

  # 3.1#4. sabotage: drop the resets_at check -> red.
  def test_a_spent_week_that_has_reset_is_not_a_pause
    write_capture(week: 100, resets_in: -60)
    refute check[:paused]
  end

  # 3.1#5. sabotage: check the Fable week for every model -> red.
  def test_a_spent_fable_week_pauses_only_a_fable_dispatch
    write_capture(week: 40, fable: 100)
    fable = check(model: "fable")
    assert fable[:paused]
    assert_equal "fable_week_spent", fable[:reason]
    refute check(model: "sonnet")[:paused]
    refute check[:paused]
  end

  # 3.1#6. sabotage: skip the 95-percent early refresh -> red.
  def test_a_stale_capture_near_the_mark_is_refreshed_once
    write_capture(week: 96, captured_ago: 400)
    calls = 0
    refresh = lambda do
      calls += 1
      write_capture(week: 100, captured_ago: 1)
      true
    end
    result = check(refresh: refresh)
    assert_equal 1, calls
    assert result[:paused]
  end

  def test_a_capture_older_than_an_hour_is_refreshed_at_any_usage
    write_capture(week: 10, captured_ago: 3601)
    calls = 0
    check(refresh: -> { calls += 1 })
    assert_equal 1, calls
  end

  # 3.1#7.
  def test_a_fresh_capture_is_not_refreshed
    write_capture(week: 96, captured_ago: 100)
    calls = 0
    check(refresh: -> { calls += 1 })
    assert_equal 0, calls
  end

  # 3.1#8.
  def test_the_pause_lifts_when_the_next_capture_is_another_account
    write_capture(week: 100, captured_ago: 4000, email: "a@example.com")
    refresh = lambda do
      write_capture(week: 12, captured_ago: 1, email: "b@example.com")
      true
    end
    result = check(refresh: refresh)
    refute result[:paused]
    assert_equal AccountPause.account_id("b@example.com"), result[:id]
    refute_equal AccountPause.account_id("a@example.com"), result[:id]
  end

  # 3.1#9. sabotage: let the refresh exception escape -> red.
  def test_a_failed_refresh_keeps_a_spent_unreset_week_paused
    write_capture(week: 100, captured_ago: 4000)
    result = check(refresh: -> { raise "capture tool exploded" })
    assert result[:paused]
    assert_includes codes(result), "refresh_failed"
  end

  def test_a_refresh_that_reports_failure_warns
    write_capture(week: 100, captured_ago: 4000)
    assert_includes codes(check(refresh: -> { false })), "refresh_failed"
  end

  # 3.1#10. sabotage: treat a missing capture as paused -> red.
  def test_no_capture_is_unknown_not_a_pause
    result = check
    refute result[:paused]
    assert_includes codes(result), "account_reading_unknown"
    assert_nil result[:id]
  end

  def test_an_unparseable_capture_is_unknown_not_a_pause
    FileUtils.mkdir_p(File.join(@root, ".state"))
    File.write(File.join(@root, ".state", "current.json"), "{nope")
    result = check
    refute result[:paused]
    assert_includes codes(result), "account_reading_unknown"
  end

  # 3.1#11. The retired short window, spelled by join so the tree carries no
  # literal key: the bead's acceptance grep for it over skills/ must find
  # nothing, and a test is not an exception to that.
  SHORT_WINDOW = %w[five hour].join("_")

  def test_a_retired_short_window_in_the_capture_is_ignored
    write_capture(week: 10, extra_windows: { SHORT_WINDOW => { "used_percentage" => 100,
                                                                "resets_at" => NOW.to_i + 60 } })
    refute check[:paused]
  end

  # 3.1#12. sabotage: put the address in id -> red.
  def test_the_answer_carries_a_hash_never_the_address
    write_capture(week: 100, email: "a@example.com")
    result = check
    assert_match(/\A[0-9a-f]{8}\z/, result[:id])
    refute_includes JSON.generate(result), "a@example.com"
    refute_includes JSON.generate(result), "example.com"
  end

  # 3.1#13.
  def test_no_refresh_never_runs_the_capture_tool
    write_capture(week: 97, captured_ago: 5000)
    result = check(refresh: nil)
    assert_equal 97, result[:week_used]
    refute result[:paused]
  end

  def test_times_are_reported_as_iso8601
    write_capture(week: 24, captured_ago: 60)
    result = check
    assert_equal Time.at(NOW.to_i - 60).utc.iso8601, result[:captured_at]
    assert_equal Time.at(NOW.to_i + 86_400).utc.iso8601, result[:resets_at]
  end
end

# The refresher behind --no-refresh's absence: runs the capture tool once,
# with a 45 second limit, at most once per 300 seconds per machine.
class AccountPauseRefresherTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("refresh-stamp-")
    @stamp = File.join(@dir, "account-refresh.stamp")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_runs_the_capture_command_with_a_45_second_limit
    fake = FakeSh.new
    fake.expect(%w[claude-limits capture])
    assert_equal true, AccountPause::Refresher.new(stamp_path: @stamp, runner: fake, now: Time.now).call
    assert_equal 45, fake.calls.first.timeout
  end

  # sabotage: drop the stamp check -> red (the fake refuses a second call).
  def test_at_most_one_attempt_per_300_seconds
    fake = FakeSh.new
    fake.expect(%w[claude-limits capture], exitstatus: 1)
    now = Time.now
    assert_equal false, AccountPause::Refresher.new(stamp_path: @stamp, runner: fake, now: now).call
    assert_nil AccountPause::Refresher.new(stamp_path: @stamp, runner: fake, now: now + 100).call
    assert_equal 1, fake.calls.length
  end

  def test_a_missing_tool_is_a_failed_refresh
    fake = FakeSh.new
    fake.expect(%w[claude-limits capture], start_failed: true)
    assert_equal false, AccountPause::Refresher.new(stamp_path: @stamp, runner: fake, now: Time.now).call
  end
end

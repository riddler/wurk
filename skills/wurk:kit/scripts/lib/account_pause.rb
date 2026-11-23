# frozen_string_literal: true

require "json"
require "time"
require "digest"
require "fileutils"
require_relative "sh"

# AccountPause answers one yes-or-no for worker_cap.rb: is the current
# account's week spent, so that no new worker should start? It is a pause on
# dispatch, never an input to the cap (see lib/worker_cap.rb).
#
# The reading is the newest limit capture made on this machine, written by
# the operator's capture tool at <limits root>/.state/current.json
# (CLAUDE_LIMITS_ROOT, else ~/.local/claude-limits). Only that capture - the
# account logged in now - is read; no other account's headroom ever enters.
#
# Paused when windows.seven_day.used_percentage is at or above 100 and its
# resets_at is still ahead; for a Fable dispatch, also when
# windows.seven_day_fable is. Any other window in the capture is ignored. A
# missing or unreadable capture is not a pause: it is a warning,
# account_reading_unknown. The pause lifts by itself: the next capture is of
# whichever account is logged in, and a week that has reset is not spent.
#
# A stale capture (older than STALE_SECONDS, or older than NEAR_STALE_SECONDS
# at NEAR_PERCENT or more) is refreshed once through the `refresh` callable
# and read again. refresh: nil never refreshes.
#
# The account appears in the answer only as `id`, the first 8 hex digits of
# a SHA-256 of its address; the address itself never leaves this module.
module AccountPause
  STALE_SECONDS = 3600
  NEAR_STALE_SECONDS = 300
  NEAR_PERCENT = 95
  SPENT_PERCENT = 100
  CAPTURE_PATH = File.join(".state", "current.json")
  DEFAULT_ROOT = File.join(".local", "claude-limits")

  class << self
    def limits_root(env: ENV, home: ENV["HOME"] || Dir.home)
      configured = env["CLAUDE_LIMITS_ROOT"]
      configured.nil? || configured.strip.empty? ? File.join(home, DEFAULT_ROOT) : File.expand_path(configured)
    end

    def account_id(address)
      return nil unless address.is_a?(String) && !address.strip.empty?

      Digest::SHA256.hexdigest(address.strip.downcase)[0, 8]
    end

    def fable?(model)
      model.to_s.downcase.include?("fable")
    end

    # -> {paused:, reason:, id:, week_used:, fable_used:, captured_at:,
    #     resets_at:, warnings: [{code:, message:}]}
    def check(limits_root:, model:, now:, refresh:)
      warnings = []
      path = File.join(limits_root, CAPTURE_PATH)
      capture = read_capture(path)

      if capture && refresh && stale?(capture, model, now)
        outcome = begin
          refresh.call
        rescue StandardError
          false
        end
        if outcome == false
          warnings << { code: "refresh_failed",
                        message: "the limit capture is stale and refreshing it failed; answering from the stale capture" }
        end
        capture = read_capture(path) || capture
      end

      return unknown(warnings) unless capture

      answer(capture, model, now, warnings)
    end

    private

    def answer(capture, model, now, warnings)
      week = window(capture, "seven_day")
      fable = window(capture, "seven_day_fable")
      reason, spent_window =
        if spent?(week, now)
          ["week_spent", week]
        elsif fable?(model) && spent?(fable, now)
          ["fable_week_spent", fable]
        end
      account = capture["account"].is_a?(Hash) ? capture["account"] : {}
      [week, fable].compact.each do |win|
        next unless win["used_percentage"] >= SPENT_PERCENT && epoch(win["resets_at"]).nil?

        warnings << { code: "resets_at_unknown",
                      message: "a window reads 100 percent with no readable resets_at; not treated as a pause" }
      end
      {
        paused: !reason.nil?,
        reason: reason,
        id: account_id(account["email"]),
        week_used: week && week["used_percentage"],
        fable_used: fable && fable["used_percentage"],
        captured_at: iso(capture["captured_at"]),
        resets_at: iso((spent_window || week || {})["resets_at"]),
        warnings: warnings
      }
    end

    def unknown(warnings)
      warnings << { code: "account_reading_unknown",
                    message: "no readable limit capture for the current account; not treated as a pause" }
      { paused: false, reason: nil, id: nil, week_used: nil, fable_used: nil,
        captured_at: nil, resets_at: nil, warnings: warnings }
    end

    def read_capture(path)
      return nil unless File.file?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) && parsed["windows"].is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def window(capture, key)
      value = capture["windows"][key]
      value.is_a?(Hash) && value["used_percentage"].is_a?(Numeric) ? value : nil
    end

    def spent?(win, now)
      return false unless win && win["used_percentage"] >= SPENT_PERCENT

      resets = epoch(win["resets_at"])
      !resets.nil? && resets > now.to_i
    end

    def stale?(capture, model, now)
      captured = epoch(capture["captured_at"])
      return true if captured.nil?

      age = now.to_i - captured
      return true if age > STALE_SECONDS
      return false unless age > NEAR_STALE_SECONDS

      used = [window(capture, "seven_day")]
      used << window(capture, "seven_day_fable") if fable?(model)
      used.compact.any? { |w| w["used_percentage"] >= NEAR_PERCENT }
    end

    # Epoch seconds from an integer or an ISO-8601 string, else nil.
    def epoch(value)
      case value
      when Integer then value
      when Float then value.to_i
      when String then Time.iso8601(value).to_i
      end
    rescue ArgumentError
      nil
    end

    def iso(value)
      t = epoch(value)
      t && Time.at(t).utc.iso8601
    end
  end

  # The refresh callable worker_cap.rb hands to check: runs the capture tool
  # once (CAPTURE_TIMEOUT_SECONDS), at most once per MIN_INTERVAL_SECONDS on
  # this machine. The time of the last attempt is kept in a stamp file under
  # an flock, so two dispatchers asking at once start one capture between
  # them. Returns true (ran and succeeded), false (ran and failed, or could
  # not start), or nil (skipped: an attempt is too recent or in progress).
  class Refresher
    COMMAND = %w[claude-limits capture].freeze
    CAPTURE_TIMEOUT_SECONDS = 45
    MIN_INTERVAL_SECONDS = 300

    def initialize(stamp_path:, now:, runner: Sh)
      @stamp_path = stamp_path
      @now = now
      @runner = runner
    end

    def call
      FileUtils.mkdir_p(File.dirname(@stamp_path), mode: 0o700)
      File.open(@stamp_path, File::RDWR | File::CREAT, 0o600) do |stamp|
        return nil unless stamp.flock(File::LOCK_EX | File::LOCK_NB)

        last = stamp.read.to_s.strip
        return nil if last.match?(/\A\d+\z/) && @now.to_i - last.to_i < MIN_INTERVAL_SECONDS

        stamp.rewind
        stamp.truncate(0)
        stamp.write(@now.to_i.to_s)
        stamp.flush
        @runner.run(COMMAND, timeout: CAPTURE_TIMEOUT_SECONDS).success?
      end
    rescue SystemCallError
      false
    end
  end
end

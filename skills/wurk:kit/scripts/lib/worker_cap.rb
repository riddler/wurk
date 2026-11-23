# frozen_string_literal: true

require "json"
require "fileutils"

# WorkerCap is the rule behind worker_cap.rb check: how many workers this
# machine should run at once right now, from its load and memory pressure
# and nothing else. No token count, price, burn rate or usage percentage
# enters `decide` - it has no parameter that could carry one. A spent week
# reaches a dispatcher only as the account pause (lib/account_pause.rb), a
# separate field beside the cap.
#
# The cap moves through a stored `level`, 1..ceiling. Hysteresis is
# asymmetric on purpose: a high reading steps the level down by one at once
# (at most one step per STEP_DOWN_SECONDS), a calm spell steps it up by one
# only after raise_after_seconds of calm with no level change, and between
# the step-up and step-down marks is a dead band where nothing moves. The
# pause zone (load at the pause mark, or critical memory) answers cap 0 and
# still steps the level down, so the machine comes back from a pause
# cautiously. An unreadable load answers cap 0 and keeps the level.
#
# Pure except for Store, which holds the level and every caller's running
# count in one state file under an flock.
module WorkerCap
  STEP_DOWN_SECONDS = 60
  CALLER_TTL_SECONDS = 900
  MAX_DEFAULT_CEILING = 4
  CALLER_ID = /\A[a-z0-9][a-z0-9_.:-]{0,63}\z/.freeze
  STATE_FILE = File.join("wurk", "worker-cap.json")

  class << self
    def valid_caller?(id)
      id.is_a?(String) && id.match?(CALLER_ID)
    end

    # The ceiling a machine gets when its config sets none: a quarter of its
    # cores, at least 1 and at most MAX_DEFAULT_CEILING. An unknown core
    # count is 1.
    def default_ceiling(ncpu)
      return 1 unless ncpu.is_a?(Integer) && ncpu.positive?

      (ncpu / 4).clamp(1, MAX_DEFAULT_CEILING)
    end

    # <XDG_STATE_HOME or ~/.local/state>/wurk/worker-cap.json, the same
    # state-dir convention lib/user_config.rb's typesafe_state_dir uses.
    def state_path(env: ENV, home: ENV["HOME"] || Dir.home)
      xdg = env["XDG_STATE_HOME"]
      base = xdg.nil? || xdg.strip.empty? ? File.join(home, ".local", "state") : xdg
      File.join(base, STATE_FILE)
    end

    # One reading -> {zone:, level:, cap:, reasons:, state:}.
    #
    # reading: {one:, five:, ncpu:, memory:} - extra keys are ignored.
    # state:   nil (first reading) or {"level", "last_lowered",
    #          "last_change", "calm_since"}, times as integer epoch seconds.
    # config:  the machine.workers values (UserConfig#machine_workers).
    # now:     a Time.
    #
    # The returned :state is what the next reading should be given.
    def decide(reading:, state:, config:, now:)
      ceiling = config["ceiling"]
      t = now.to_i
      prior = state.is_a?(Hash) ? state : {}
      level = prior["level"].is_a?(Integer) ? prior["level"] : ceiling
      next_state = {
        "level" => level,
        "last_lowered" => prior["last_lowered"],
        "last_change" => prior["last_change"],
        "calm_since" => prior["calm_since"]
      }
      reasons = []

      clamped = level.clamp(1, ceiling)
      if clamped != level
        reasons << "ceiling_lowered" if clamped < level
        next_state["level"] = clamped
        next_state["last_change"] = t
      end

      one, five, ncpu = reading.values_at(:one, :five, :ncpu)
      unless one.is_a?(Numeric) && five.is_a?(Numeric) && ncpu.is_a?(Integer) && ncpu.positive?
        next_state["calm_since"] = nil
        return result("unknown", 0, next_state, reasons << "load_unknown")
      end

      per_one = one.to_f / ncpu
      per_five = five.to_f / ncpu
      memory = reading[:memory]

      if memory == "critical" || per_one >= config["load_pause"]
        reasons << "memory_critical" if memory == "critical"
        reasons << "load_pause" if per_one >= config["load_pause"]
        step_down(next_state, t, reasons)
        next_state["calm_since"] = nil
        return result("pause", 0, next_state, reasons)
      end

      if memory == "warn" || per_one >= config["load_step_down"]
        reasons << "memory_warn" if memory == "warn"
        reasons << "load_high" if per_one >= config["load_step_down"]
        step_down(next_state, t, reasons)
        next_state["calm_since"] = nil
        return result("high", next_state["level"], next_state, reasons)
      end

      unless per_one < config["load_step_up"] && per_five < config["load_step_up"]
        next_state["calm_since"] = nil
        return result("steady", next_state["level"], next_state, reasons)
      end

      calm_since = next_state["calm_since"]
      next_state["calm_since"] = t if calm_since.nil? || calm_since > t
      raise_after = config["raise_after_seconds"]
      calm_long_enough = t - next_state["calm_since"] >= raise_after
      unmoved_long_enough = next_state["last_change"].nil? || t - next_state["last_change"] >= raise_after
      if calm_long_enough && unmoved_long_enough && next_state["level"] < ceiling
        next_state["level"] += 1
        next_state["last_change"] = t
        next_state["calm_since"] = t
        reasons << "stepped_up"
      end
      result("calm", next_state["level"], next_state, reasons)
    end

    # How many more workers may start now: the cap less what the machine
    # already runs, at most the free gate slots when a slot pool was read,
    # never below 0.
    def headroom(cap:, machine_running:, free_slots: nil)
      room = cap - machine_running
      room = [room, free_slots].min unless free_slots.nil?
      [room, 0].max
    end

    private

    def step_down(state, t, reasons)
      return if state["level"] <= 1
      # A stamp in the future (the clock stepped back) counts as long ago, so
      # a clock change can never hold the cap up under load.
      last = state["last_lowered"]
      return if last && last <= t && t - last < STEP_DOWN_SECONDS

      state["level"] -= 1
      state["last_lowered"] = t
      state["last_change"] = t
      reasons << "stepped_down"
    end

    def result(zone, cap, state, reasons)
      { zone: zone, level: state["level"], cap: cap, reasons: reasons, state: state }
    end
  end

  # The machine-wide state file: the level between readings and each
  # caller's last reported running count. Every read-modify-write happens
  # under an exclusive flock on a sibling `.lock` file (the data file itself
  # is replaced by rename, so it cannot carry the lock), and the new content
  # goes to a temp file that is renamed into place, mode 0600 - a reader
  # sees the old file or the new one, never half of either.
  #
  # A caller's report replaces only that caller's entry; a report older than
  # CALLER_TTL_SECONDS no longer counts, so a dispatcher that died stops
  # holding room after fifteen minutes.
  class Store
    attr_reader :warnings, :now

    # Opens the store at path under the lock, yields it, and writes it back
    # if the block returns normally. Returns the block's value. An exception
    # in the block leaves the file as it was. write: false (a dry run) reads
    # without the lock and creates nothing on disk.
    def self.update(path, now:, write: true)
      return yield(new(path, now)) unless write

      dir = File.dirname(path)
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        store = new(path, now)
        value = yield store
        store.save
        value
      end
    end

    def initialize(path, now)
      @path = path
      @now = now
      @warnings = []
      @data = load
    end

    def level_state
      @data["level_state"]
    end

    # Runs WorkerCap.decide against the stored level and keeps its state.
    def decide(reading:, config:)
      outcome = WorkerCap.decide(reading: reading, state: level_state, config: config, now: now)
      @data["level_state"] = outcome[:state]
      outcome
    end

    def report(caller_id, running)
      @data["callers"][caller_id] = { "running" => running, "at" => now.to_i }
    end

    def machine_running
      live_callers.values.sum { |entry| entry["running"] }
    end

    def save
      @data["callers"] = live_callers
      tmp = "#{@path}.tmp-#{Process.pid}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(JSON.generate(@data)) }
      File.chmod(0o600, tmp)
      File.rename(tmp, @path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    private

    def live_callers
      cutoff = now.to_i - CALLER_TTL_SECONDS
      @data["callers"].select do |_id, entry|
        entry.is_a?(Hash) && entry["running"].is_a?(Integer) && entry["at"].is_a?(Integer) && entry["at"] >= cutoff
      end
    end

    def load
      return empty unless File.file?(@path)

      parsed = JSON.parse(File.read(@path))
      raise JSON::ParserError, "not an object" unless parsed.is_a?(Hash)

      parsed["callers"] = {} unless parsed["callers"].is_a?(Hash)
      parsed["level_state"] = nil unless parsed["level_state"].is_a?(Hash)
      parsed
    rescue JSON::ParserError, SystemCallError
      @warnings << "state_reset"
      empty
    end

    def empty
      { "version" => 1, "level_state" => nil, "callers" => {} }
    end
  end
end

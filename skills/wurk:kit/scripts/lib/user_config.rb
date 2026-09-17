# frozen_string_literal: true

require "json"
require_relative "envelope"
require_relative "cli"

# UserConfig is the kit's second config reader, alongside Manifest. It
# locates, parses, and validates the machine-level `~/.claude/wurk.local.json`
# and hands typed values to any script that needs a setting the project's
# manifest has no business carrying.
#
# This file describes the machine and the person sitting at it, not the
# project - permission mode is the first example (see wu-jhb); the machine's
# own name, its gate-slot cap, and the list of workloads it runs (wu-yi7.5)
# are the same kind of fact. That is why
# resolution is HOME-anchored only, with no walk-up and no git fallback: a
# stray `.claude/wurk.local.json` committed inside some checkout (by accident,
# or by a template) must never be picked up as if it were machine config, the
# way a project manifest legitimately is found by walking up from wherever a
# script happens to run. `.local.json` mirrors Claude Code's own
# `settings.json` / `settings.local.json` convention: `settings.json` is
# shared and checked in, `settings.local.json` is this machine only and never
# committed. This file is the second half of that pair for wurk.
#
# Validation follows the same asymmetry as Manifest (see docs/manifest.md):
# an unknown key warns, because a machine may be running an older or newer
# kit than the file was written for; an enum field with an unrecognized value
# blocks, because it selects a structural behavior (here, a flag on a shelled
# command line) and guessing is worse than stopping.
class UserConfig
  SCHEMA_VERSION = 1
  FILENAME = File.join(".claude", "wurk.local.json")

  # Every enum in the schema. An unrecognized value blocks.
  ENUMS = {
    "tmux.permission_mode" => %w[auto default acceptEdits plan skip-permissions]
  }.freeze

  # The known key surface, for the unknown-key warning. Same shape as
  # Manifest::KNOWN: nested sections list their own keys; a section absent
  # from this map is not validated further.
  # A key ending in "[]" describes the object elements of an array under
  # that key; collect_unknown_keys walks into each element with it.
  # `metrics.prices` is deliberately absent from this map: its keys are model
  # ids, which are data and not schema, so the walk stops at `metrics` and a
  # new model never warns as an unknown key.
  KNOWN = {
    nil => %w[wurk tmux outbound_scan machine workloads metrics],
    "tmux" => %w[permission_mode],
    "outbound_scan" => %w[patterns_file control_term],
    "machine" => %w[name gate_slots],
    "workloads[]" => %w[root fleet_manifest enabled primary],
    "metrics" => %w[prices error_events]
  }.freeze

  # The components a per-model price entry may quote, each in US dollars per
  # million tokens. A component outside this list warns rather than blocks:
  # a newer kit may bill something this one does not know how to count, and
  # the price of a bucket nobody reads is harmless.
  PRICE_COMPONENTS = %w[input output cache_write cache_read].freeze

  # Per-entry defaults for workloads[]. `root` has none: an entry without
  # one is an error, because the root is what identifies the workload.
  WORKLOAD_DEFAULTS = { "fleet_manifest" => nil, "enabled" => true, "primary" => false }.freeze

  DEFAULTS = {
    "tmux.permission_mode" => "auto"
  }.freeze

  attr_reader :path, :raw, :errors, :warnings

  class << self
    # The memoized config for this process. Scripts call `require!` rather
    # than this, so a missing (normal) or invalid (abnormal) file becomes an
    # envelope entry instead of an exception mid-run.
    def current(home: ENV["HOME"] || Dir.home)
      @current ||= load(home: home)
    end

    # Test seam: drop the memoized instance so a fixture config can be loaded
    # in its place.
    def reset!
      @current = nil
    end

    attr_writer :current

    # Never raises: an absent file is a normal, valid instance whose values
    # are all defaults, unlike Manifest.load which raises NotFound when the
    # project manifest cannot be located at all.
    def load(home: ENV["HOME"] || Dir.home)
      path = File.join(home, FILENAME)
      return new(path: path, raw: {}, exists: false) unless File.file?(path)

      new(path: path, raw: parse(path), exists: true)
    end

    # Loads the config, or records the reason on `env` and returns nil. The
    # one entry point scripts should use.
    def require!(env, home: ENV["HOME"] || Dir.home)
      config = current(home: home)
      unless config.valid?
        config.errors.each { |e| env.block!(code: "user_config_invalid", message: e) }
        return nil
      end
      config.warnings.each { |w| env.warn(code: "user_config_unknown_key", message: w) }
      config
    rescue JSON::ParserError => e
      env.block!(code: "user_config_unavailable", message: e.message)
      nil
    end

    def parse(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      # Never interpolate the parser's own message: JSON::ParserError quotes
      # the offending source text, and this file is where the outbound scan's
      # control_term and patterns_file path live (ADR-0014). A malformed
      # value would otherwise travel from here into a block! message, out of
      # the pre-push hook on stdout, and into a terminal or a CI log - which
      # is exactly the leak the scan exists to prevent. Position only.
      raise JSON::ParserError, "#{path} is not valid JSON#{parse_position(e)}"
    end

    private

    # The "at line N column M" tail of a parser message, when it has one.
    # Digits and fixed words only, so nothing from the file can ride along.
    def parse_position(error)
      match = error.message.to_s.match(/\bat line \d+ column \d+/)
      match ? " (#{match[0]})" : ""
    end
  end

  def initialize(path:, raw:, exists: true)
    @path = path
    @exists = exists
    @errors = []
    @warnings = []
    if raw.is_a?(Hash)
      @raw = raw
    else
      @raw = {}
      @errors << "#{path}: top-level value must be a JSON object, got #{raw.class}" unless raw == {}
    end
    validate!
  end

  def valid?
    errors.empty?
  end

  # Whether the file existed on disk at load time. A parsed-but-empty file
  # ("{}") still exists; a never-written path does not.
  def exists?
    @exists
  end

  # The flag the seeded session's command line carries for permission
  # handling. Defaults to "auto". Validated against ENUMS, so an unrecognized
  # value blocks rather than reaching the shell command line - see
  # tmux_window.rb's claude_command for how "skip-permissions" maps to
  # --dangerously-skip-permissions instead of a --permission-mode value.
  def tmux_permission_mode
    fetch("tmux.permission_mode")
  end

  # The path to the operator's outbound-scan pattern file, or nil if the
  # section (or this key within it) is absent. No default: absent means
  # disarmed, and a default here would invent a policy the machine never
  # opted into.
  def outbound_scan_patterns_file
    fetch("outbound_scan.patterns_file")
  end

  # The positive-control token the scan pipeline must be able to hit before
  # a zero-hit payload result is trusted. No default, same reasoning as
  # outbound_scan_patterns_file.
  def outbound_scan_control_term
    fetch("outbound_scan.control_term")
  end

  # Whether the machine declares an outbound scan at all. False means the
  # gate is disarmed and pushes are allowed with an advisory; it never
  # means "scanned clean".
  def outbound_scan_declared?
    raw.key?("outbound_scan")
  end

  # A human-readable name for this machine, or nil when the file does not
  # give one. No default and no fallback to the hostname: a caller that
  # wants a hostname asks the OS, and a caller that wants the operator's
  # name for the box gets exactly that or nothing.
  def machine_name
    fetch("machine.name")
  end

  # The machine-wide cap on concurrent full gates and warms - the count of
  # `slot-N` directories a slot acquire may take - or nil when the file does
  # not set one. No default: absent means "whatever the caller was told",
  # which today is the fleet manifest's value handed to lock.rb and
  # gate_run.rb as `--slots N`. When set it wins over that flag, because
  # the machine knows its own capacity and the fleet manifest is shared by
  # every machine that runs the fleet (see Lock.resolve_slot_count).
  def machine_gate_slots
    fetch("machine.gate_slots")
  end

  # The workloads this machine runs, as an array of normalized hashes with
  # every key present: `root` (expanded to an absolute path, so "~" works),
  # `fleet_manifest` (a path or nil), `enabled` (default true), `primary`
  # (default false). Empty when the section is absent. Only meaningful on a
  # valid config; on an invalid one, entries that failed validation are
  # skipped rather than half-normalized.
  def workloads
    entries = raw["workloads"]
    return [] unless entries.is_a?(Array)

    entries.map do |entry|
      next unless entry.is_a?(Hash) && entry["root"].is_a?(String) && !entry["root"].strip.empty?

      { "root" => File.expand_path(entry["root"]) }.merge(WORKLOAD_DEFAULTS).merge(entry.slice(*WORKLOAD_DEFAULTS.keys))
    end.compact
  end

  # The workloads with enabled: true - "what does this machine run right
  # now", as opposed to everything it knows how to run.
  def enabled_workloads
    workloads.select { |w| w["enabled"] == true }
  end

  # The one workload marked primary: true, or nil when none is. Validation
  # guarantees at most one.
  def primary_workload
    workloads.find { |w| w["primary"] == true }
  end

  # The per-model price table, as `{ "<model id>" => { "input" => 3.0, ... } }`
  # in US dollars per million tokens, or `{}` when the machine names none.
  # The kit ships no prices and has no defaults here on purpose: prices move,
  # they differ per account, and a number checked into a repo is a number
  # that is silently wrong later. A caller with an empty table reports cost
  # as null - it never guesses. See session_metrics.rb.
  def metrics_prices
    section = raw["metrics"]
    return {} unless section.is_a?(Hash)

    prices = section["prices"]
    prices.is_a?(Hash) ? prices : {}
  end

  # Whether the machine quotes any price at all.
  def metrics_prices?
    !metrics_prices.empty?
  end

  # The path to this machine's telemetry sink - a JSONL file an opt-in hook
  # appends error events to - or nil when none is configured. A path that
  # does not exist yet is normal and every reader of it is absent-safe: the
  # config may name a sink before anything writes one.
  def metrics_error_events_path
    fetch("metrics.error_events")
  end

  # Dotted lookup with defaults applied. Returns nil for an absent optional
  # key that has no default.
  def fetch(dotted)
    parts = dotted.split(".")
    value = parts.inject(raw) { |node, key| node.is_a?(Hash) ? node[key] : nil }
    value.nil? ? DEFAULTS[dotted] : value
  end

  private

  # raw is always a Hash by the time this runs - initialize normalizes a
  # non-object top level to {} and records the error itself - so these
  # passes only ever see a legitimate (possibly empty) config body.
  def validate!
    validate_version
    validate_enums
    validate_outbound_scan
    validate_machine
    validate_workloads
    validate_metrics
    collect_unknown_keys(raw, nil)
  end

  def validate_version
    version = raw["wurk"]
    return if version.nil? # absent is fine - the minimum useful file is one line
    return if version == SCHEMA_VERSION

    errors << "#{path}: wurk is #{version.inspect}, but this kit implements schema version #{SCHEMA_VERSION}"
  end

  def validate_enums
    ENUMS.each do |dotted, allowed|
      value = fetch(dotted)
      next if value.nil?
      next if allowed.include?(value)

      errors << "#{path}: #{dotted} is #{value.inspect}; expected one of #{allowed.join(', ')}"
    end
  end

  # Shape validation only - no filesystem access. Whether the pattern file
  # exists, is readable, and is non-empty is a scan-time concern (see
  # lib/outbound_scan.rb), not a load-time one: UserConfig is a parser and
  # must stay cheap enough for every script to require unconditionally.
  #
  # A section with exactly one of the two keys is deliberately NOT an error
  # here. A machine may carry a half-written section that only matters when
  # something actually scans; making it a load-time error would block
  # tmux_window.rb open and every other unrelated script on a config problem
  # that has nothing to do with them. The scan engine blocks on it instead.
  def validate_outbound_scan
    return unless raw.key?("outbound_scan")

    section = raw["outbound_scan"]
    unless section.is_a?(Hash)
      errors << "#{path}: outbound_scan must be a JSON object, got #{section.class}"
      return
    end

    if section.empty?
      errors << "#{path}: outbound_scan is present but configures neither patterns_file nor control_term"
      return
    end

    %w[patterns_file control_term].each do |key|
      next unless section.key?(key)

      value = section[key]
      if !value.is_a?(String)
        errors << "#{path}: outbound_scan.#{key} must be a string, got #{value.class}"
      elsif value.strip.empty?
        errors << "#{path}: outbound_scan.#{key} must not be blank"
      end
    end
  end

  # Shape validation of the machine section. `name` is a non-blank string;
  # `gate_slots` is a positive integer, because it becomes the count of
  # slot directories a lock acquire may take, and a cap of zero or a
  # fraction is a config that can never grant a slot.
  def validate_machine
    return unless raw.key?("machine")

    section = raw["machine"]
    unless section.is_a?(Hash)
      errors << "#{path}: machine must be a JSON object, got #{section.class}"
      return
    end

    if section.key?("name")
      name = section["name"]
      if !name.is_a?(String)
        errors << "#{path}: machine.name must be a string, got #{name.class}"
      elsif name.strip.empty?
        errors << "#{path}: machine.name must not be blank"
      end
    end

    return unless section.key?("gate_slots")

    slots = section["gate_slots"]
    return if slots.is_a?(Integer) && slots.positive?

    errors << "#{path}: machine.gate_slots must be a positive integer, got #{slots.inspect}"
  end

  # Shape validation of workloads[]: an array of objects, each with a
  # non-blank string `root`, an optional non-blank string `fleet_manifest`,
  # optional boolean `enabled` and `primary`, no two entries sharing a root,
  # and at most one entry marked primary. Paths are validated as strings
  # only - whether a root or a fleet manifest exists on disk is the
  # caller's concern, same reasoning as validate_outbound_scan.
  def validate_workloads
    return unless raw.key?("workloads")

    entries = raw["workloads"]
    unless entries.is_a?(Array)
      errors << "#{path}: workloads must be a JSON array, got #{entries.class}"
      return
    end

    roots = []
    primaries = 0
    entries.each_with_index do |entry, index|
      label = "workloads[#{index}]"
      unless entry.is_a?(Hash)
        errors << "#{path}: #{label} must be a JSON object, got #{entry.class}"
        next
      end

      root = entry["root"]
      if !root.is_a?(String) || root.strip.empty?
        errors << "#{path}: #{label}.root must be a non-blank string, got #{root.inspect}"
      elsif roots.include?(File.expand_path(root))
        errors << "#{path}: #{label}.root duplicates an earlier workload's root"
      else
        roots << File.expand_path(root)
      end

      if entry.key?("fleet_manifest")
        fm = entry["fleet_manifest"]
        if !fm.is_a?(String) || fm.strip.empty?
          errors << "#{path}: #{label}.fleet_manifest must be a non-blank string, got #{fm.inspect}"
        end
      end

      %w[enabled primary].each do |key|
        next unless entry.key?(key)
        next if [true, false].include?(entry[key])

        errors << "#{path}: #{label}.#{key} must be true or false, got #{entry[key].inspect}"
      end

      primaries += 1 if entry["primary"] == true
    end

    errors << "#{path}: workloads marks #{primaries} entries primary; at most one may be" if primaries > 1
  end

  # Shape validation of the metrics section. `prices` maps a model id to an
  # object of price components, each a non-negative number in dollars per
  # million tokens; `error_events` is a non-blank path string.
  #
  # A malformed price BLOCKS rather than warns, unlike an unknown component
  # name. The two are different failures: a component this kit cannot spend
  # is inert, but a price that is a string, or negative, would travel into a
  # dollar figure that a human reads and believes. A cost metric is only
  # worth emitting if a wrong one cannot be emitted quietly.
  def validate_metrics
    return unless raw.key?("metrics")

    section = raw["metrics"]
    unless section.is_a?(Hash)
      errors << "#{path}: metrics must be a JSON object, got #{section.class}"
      return
    end

    validate_prices(section["prices"]) if section.key?("prices")

    return unless section.key?("error_events")

    sink = section["error_events"]
    if !sink.is_a?(String)
      errors << "#{path}: metrics.error_events must be a string, got #{sink.class}"
    elsif sink.strip.empty?
      errors << "#{path}: metrics.error_events must not be blank"
    end
  end

  def validate_prices(prices)
    unless prices.is_a?(Hash)
      errors << "#{path}: metrics.prices must be a JSON object, got #{prices.class}"
      return
    end

    prices.each do |model, entry|
      label = "metrics.prices.#{model}"
      unless entry.is_a?(Hash)
        errors << "#{path}: #{label} must be a JSON object, got #{entry.class}"
        next
      end

      if entry.empty?
        errors << "#{path}: #{label} is present but quotes no price component"
        next
      end

      entry.each do |component, value|
        unless PRICE_COMPONENTS.include?(component)
          warnings << "#{path}: unknown key #{label}.#{component} (ignored)"
          next
        end
        next if value.is_a?(Numeric) && !value.negative?

        errors << "#{path}: #{label}.#{component} must be a non-negative number, got #{value.inspect}"
      end
    end
  end

  # Forward compatibility: a key this kit does not know about is a warning,
  # never an error - same reasoning as Manifest#collect_unknown_keys. An
  # array under a key with a "<key>[]" entry in KNOWN is walked element by
  # element, each object element reported under its index
  # ("workloads[0].nope") but looked up under the shared "workloads[]" key.
  def collect_unknown_keys(node, prefix, known_key = prefix)
    if node.is_a?(Array)
      element_key = "#{known_key}[]"
      return unless KNOWN[element_key]

      node.each_with_index { |element, index| collect_unknown_keys(element, "#{prefix}[#{index}]", element_key) }
      return
    end

    known = KNOWN[known_key]
    return unless node.is_a?(Hash) && known

    node.each_key do |key|
      dotted = prefix ? "#{prefix}.#{key}" : key
      if known.include?(key)
        collect_unknown_keys(node[key], dotted, known_key ? "#{known_key}.#{key}" : key)
      else
        warnings << "#{path}: unknown key #{dotted} (ignored)"
      end
    end
  end
end

# The standalone lint: `ruby lib/user_config.rb check [--file PATH]`. Emits
# the same envelope as every other script. Read-only, so no --dry-run.
# Exits 1 on an invalid config, 0 otherwise (unknown-key warnings do not fail
# it - that is the whole point of warning on them).
module UserConfigCli
  class << self
    def run(argv, io: $stdout)
      argv = argv.dup
      argv.shift if argv.first == "check"

      options = {}
      parser, options = Cli.build("user_config.rb check [--file PATH]", options) do |opts|
        opts.on("--file PATH", "check this config instead of the located one") { |v| options[:file] = v }
      end
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "user_config")

      config = build(options[:file])

      env.data[:path] = config.path
      env.data[:exists] = config.exists?
      env.data[:valid] = config.valid?
      env.data[:errors] = config.errors
      env.data[:tmux_permission_mode] = config.tmux_permission_mode
      env.data[:outbound_scan_declared] = config.outbound_scan_declared?
      env.data[:machine_name] = config.machine_name
      env.data[:machine_gate_slots] = config.machine_gate_slots
      env.data[:workloads] = config.workloads
      # Model ids, not the prices themselves: what this machine can price is
      # the useful answer, and the numbers are the operator's business.
      env.data[:metrics_priced_models] = config.metrics_prices.keys.sort
      env.data[:metrics_error_events_declared] = !config.metrics_error_events_path.nil?

      config.warnings.each { |w| env.warn(code: "unknown_key", message: w) }
      config.errors.each { |e| env.block!(code: "invalid", message: e) }

      env.emit(io)
    rescue JSON::ParserError => e
      env ||= Envelope.new(script: "user_config")
      env.block!(code: "unparseable", message: e.message)
      env.emit(io)
    end

    private

    def build(file)
      return UserConfig.load if file.nil?

      exists = File.file?(file)
      raw = exists ? UserConfig.parse(file) : {}
      UserConfig.new(path: file, raw: raw, exists: exists)
    end
  end
end

exit UserConfigCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

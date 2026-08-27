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
# project - permission mode is the first example (see wu-jhb). That is why
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
  KNOWN = {
    nil => %w[wurk tmux outbound_scan],
    "tmux" => %w[permission_mode],
    "outbound_scan" => %w[patterns_file control_term]
  }.freeze

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
      raise JSON::ParserError, "#{path} is not valid JSON: #{e.message}"
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

  # Forward compatibility: a key this kit does not know about is a warning,
  # never an error - same reasoning as Manifest#collect_unknown_keys.
  def collect_unknown_keys(node, prefix)
    known = KNOWN[prefix]
    return unless node.is_a?(Hash) && known

    node.each_key do |key|
      dotted = prefix ? "#{prefix}.#{key}" : key
      if known.include?(key)
        collect_unknown_keys(node[key], dotted)
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

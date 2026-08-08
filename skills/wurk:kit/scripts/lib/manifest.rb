# frozen_string_literal: true

require "json"
require_relative "sh"
require_relative "envelope"
require_relative "cli"

# Manifest is the single place that locates, parses, and validates the
# consumer repo's `.claude/wurk.json` and hands typed values to every other
# script. Before it, each script carried this repo's constants inline -
# `st-`, `statifier-ex-worktrees`, `mix quality`, an absolute home-directory
# path - which is what made the set uncopyable to a sibling repo. See
# ~/repos/github/wurk/docs/manifest.md for the schema and
# ~/repos/github/wurk/docs/plan.md phase 1 for why.
#
# Resolution, in order:
#
#   1. Walk up from `start` (the working directory by default) looking for
#      `.claude/wurk.json`. First hit wins. This finds the manifest from any
#      subdirectory of any checkout, and - the point - a worktree finds its
#      OWN manifest, so a branch that edits the schema is testable on that
#      branch instead of silently reading main's copy.
#   2. Failing that, ask git for the main checkout
#      (`git rev-parse --git-common-dir`, whose parent is the main working
#      tree) and look there. This is the bare-`.git`-elsewhere case; step 1
#      already covers ordinary worktrees.
#
# Validation is deliberately asymmetric (see docs/manifest.md): an unknown
# key warns, because a consumer repo may be running against a newer schema
# than the kit it has installed; a missing required key blocks, naming the
# field; an enum field with an unrecognized value blocks rather than falling
# back to a default, because every enum in this schema selects a structural
# behavior and guessing one is worse than stopping.
class Manifest
  class NotFound < StandardError; end

  SCHEMA_VERSION = 1
  FILENAME = File.join(".claude", "wurk.json")

  # Required keys, in dotted form - the message names the field exactly as
  # docs/manifest.md spells it.
  REQUIRED = %w[
    wurk
    beads.prefix
    forge.kind
    gate.full
    gate.loop
    parallelism.model
    artifacts.plans
    artifacts.research
    changelog.mode
  ].freeze

  # Every enum in the schema. An unrecognized value blocks.
  ENUMS = {
    "beads.topology" => %w[beads beads-with-forge-projection],
    "forge.kind" => %w[github gitlab],
    "parallelism.model" => %w[worktree-per-issue branch-in-place],
    "commits.style" => %w[s-form conventional],
    "changelog.mode" => %w[fragments keep-a-changelog none]
  }.freeze

  # The known key surface, for the unknown-key warning. Nested sections list
  # their own keys; a section absent from this map is not validated further.
  KNOWN = {
    nil => %w[wurk beads forge gate parallelism tmux models artifacts commits changelog release],
    "beads" => %w[prefix topology areas],
    "beads.areas" => %w[labels lands_alone always_batchable],
    "forge" => %w[kind labels],
    "gate" => %w[full loop report report_loop attest guard_ledger build_paths also_gated_paths moving_files
                 project_level_skips],
    "parallelism" => %w[model worktrees_dir trust warm_clone warm_globs warm repair_when repair post_branch],
    "tmux" => %w[session model],
    "models" => %w[direction],
    "artifacts" => %w[plans research filename repository],
    "commits" => %w[style package_map subject_under body_line_max total_lines_max trailer],
    "commits.trailer" => %w[key],
    "changelog" => %w[mode dir]
  }.freeze

  DEFAULTS = {
    "beads.topology" => "beads",
    "commits.style" => "s-form",
    "commits.subject_under" => 50,
    "commits.body_line_max" => 72,
    "commits.total_lines_max" => 40,
    "commits.trailer.key" => "Refs",
    "models.direction" => "opus",
    "artifacts.filename" => "YYMMDD-[id-]kebab"
  }.freeze

  attr_reader :path, :raw, :errors, :warnings

  class << self
    # The memoized manifest for this process. Scripts call `require!` rather
    # than this, so a missing or invalid manifest becomes an envelope block
    # instead of an exception in the middle of a run.
    def current(start: Dir.pwd)
      @current ||= load(start: start)
    end

    # Test seam: drop the memoized instance so a fixture manifest can be
    # loaded in its place.
    def reset!
      @current = nil
    end

    attr_writer :current

    def load(start: Dir.pwd)
      path = locate(start: start)
      raise NotFound, "no #{FILENAME} found from #{start} upward, nor in the main checkout" unless path

      new(path: path, raw: parse(path))
    end

    # Loads the manifest, or records the reason on `env` and returns nil.
    # The one entry point scripts should use.
    def require!(env, start: Dir.pwd)
      manifest = current(start: start)
      unless manifest.valid?
        manifest.errors.each { |e| env.block!(code: "manifest_invalid", message: e) }
        return nil
      end
      manifest.warnings.each { |w| env.warn(code: "manifest_unknown_key", message: w) }
      manifest
    rescue NotFound, JSON::ParserError => e
      env.block!(code: "manifest_unavailable", message: e.message)
      nil
    end

    def locate(start: Dir.pwd)
      found = walk_up(File.expand_path(start))
      return found if found

      main = main_checkout
      return nil unless main

      candidate = File.join(main, FILENAME)
      File.file?(candidate) ? candidate : nil
    end

    # The main working tree, whatever checkout we are standing in:
    # --git-common-dir is the main repo's .git for every worktree, so its
    # parent is the main checkout. Never an absolute path baked into a
    # constant - that was the machine-bound half of the old tmux_window.rb,
    # which is the other caller (a tmux session's working directory has to
    # be the main checkout, and it cannot be `/Users/<someone>/...`).
    # Returns nil when git cannot answer.
    def main_checkout
      res = Sh.run(%w[git rev-parse --git-common-dir])
      return nil unless res.success?

      common = res.out.to_s.strip
      return nil if common.empty?

      File.dirname(File.expand_path(common))
    end

    private

    def walk_up(dir)
      loop do
        candidate = File.join(dir, FILENAME)
        return candidate if File.file?(candidate)

        parent = File.dirname(dir)
        return nil if parent == dir

        dir = parent
      end
    end

    def parse(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise JSON::ParserError, "#{path} is not valid JSON: #{e.message}"
    end
  end

  def initialize(path:, raw:)
    @path = path
    @raw = raw
    @errors = []
    @warnings = []
    validate!
  end

  def valid?
    errors.empty?
  end

  # --- typed accessors ----------------------------------------------------

  def bead_prefix
    fetch("beads.prefix")
  end

  def topology
    fetch("beads.topology")
  end

  def area_labels
    Array(fetch("beads.areas.labels"))
  end

  def area_lands_alone
    Array(fetch("beads.areas.lands_alone"))
  end

  def area_always_batchable
    Array(fetch("beads.areas.always_batchable"))
  end

  def forge_kind
    fetch("forge.kind")
  end

  def forge_labels
    fetch("forge.labels") || {}
  end

  def gate_full
    argv(fetch("gate.full"))
  end

  def gate_loop
    argv(fetch("gate.loop"))
  end

  def gate_report
    value = fetch("gate.report")
    value && argv(value)
  end

  # The tier-1 reporting command for a loop run. Separate from `gate.report`
  # because composing it (base command + profile flag) would mean the kit
  # knowing one gate tool's flag surface.
  def gate_report_loop
    value = fetch("gate.report_loop")
    value && argv(value)
  end

  def gate_attest
    value = fetch("gate.attest")
    value && argv(value)
  end

  def gate_guard_ledger
    fetch("gate.guard_ledger")
  end

  def gate_build_paths
    Array(fetch("gate.build_paths"))
  end

  def gate_also_gated_paths
    Array(fetch("gate.also_gated_paths"))
  end

  def gate_moving_files
    Array(fetch("gate.moving_files"))
  end

  # Compiles gate.project_level_skips into one Regexp, or nil when the
  # project declares none. nil is the strict direction: every skipped stage
  # blocks. Widening this list is a review decision made in the consumer's
  # own manifest, not a default this kit guesses at.
  def project_level_skip_re
    sources = Array(fetch("gate.project_level_skips"))
    return nil if sources.empty?

    Regexp.union(sources.map { |s| Regexp.new(s) })
  end

  def parallelism_model
    fetch("parallelism.model")
  end

  def worktrees_dir
    fetch("parallelism.worktrees_dir")
  end

  def trust_argv
    value = fetch("parallelism.trust")
    value && argv(value)
  end

  def warm_clone
    Array(fetch("parallelism.warm_clone"))
  end

  def warm_globs
    Array(fetch("parallelism.warm_globs"))
  end

  def warm
    Array(fetch("parallelism.warm")).map { |c| argv(c) }
  end

  def repair_when
    fetch("parallelism.repair_when")
  end

  def repair
    Array(fetch("parallelism.repair")).map { |c| argv(c) }
  end

  def post_branch
    Array(fetch("parallelism.post_branch")).map { |c| argv(c) }
  end

  def tmux?
    !fetch("tmux").nil?
  end

  def tmux_session
    fetch("tmux.session")
  end

  def tmux_model
    fetch("tmux.model")
  end

  # The one stage model that genuinely differs between projects: the
  # direction/ADR tier wurk:work dispatches. Every other stage model is
  # workflow policy stated in the skill itself. Read by wurk:work from the
  # manifest directly; the accessor exists so a script that needs it later
  # goes through the same typed path as everything else.
  def direction_model
    fetch("models.direction")
  end

  def plans_dir
    fetch("artifacts.plans")
  end

  def research_dir
    fetch("artifacts.research")
  end

  def artifact_dirs
    [plans_dir, research_dir].compact
  end

  def repository_override
    fetch("artifacts.repository")
  end

  def commit_style
    fetch("commits.style")
  end

  def subject_under
    fetch("commits.subject_under")
  end

  def body_line_max
    fetch("commits.body_line_max")
  end

  def total_lines_max
    fetch("commits.total_lines_max")
  end

  def trailer_key
    fetch("commits.trailer.key")
  end

  def package_map
    fetch("commits.package_map") || {}
  end

  def changelog_mode
    fetch("changelog.mode")
  end

  def changelog_dir
    fetch("changelog.dir")
  end

  def release
    fetch("release")
  end

  # The bead id shape, built from the prefix: "st-" followed by lowercase
  # alphanumerics, optionally dotted (e.g. "st-00p.3"). Every script that
  # needs this shape asks here rather than re-deriving it - see lib/refs.rb
  # for what a second definition site once cost.
  def bead_id_pattern
    /#{Regexp.escape(bead_prefix)}-[a-z0-9]+(?:\.[0-9]+)?/
  end

  # Dotted lookup with defaults applied. Returns nil for an absent optional
  # key that has no default.
  def fetch(dotted)
    parts = dotted.split(".")
    value = parts.inject(raw) { |node, key| node.is_a?(Hash) ? node[key] : nil }
    value.nil? ? DEFAULTS[dotted] : value
  end

  private

  # Commands are argv arrays in the manifest, never shell strings - the same
  # rule Sh enforces at the other end. A string here is a schema error, not
  # something to split on whitespace.
  def argv(value)
    return value if argv?(value)

    raise ArgumentError, "expected an argv array of strings, got #{value.inspect} in #{path}"
  end

  # Command fields carry argv arrays. Checked here as well as at the
  # accessor so `check` reports a shell-string command as a validation
  # error rather than exploding mid-run in whichever script reads it first.
  COMMAND_FIELDS = %w[gate.full gate.loop gate.report gate.report_loop gate.attest parallelism.trust].freeze
  COMMAND_LIST_FIELDS = %w[parallelism.warm parallelism.repair parallelism.post_branch].freeze

  # Fields that hold a list of regex source strings rather than argv. Each
  # entry must compile; the field itself may be absent.
  REGEX_LIST_FIELDS = %w[gate.project_level_skips].freeze

  def validate!
    validate_version
    validate_required
    validate_enums
    validate_commands
    validate_regex_lists
    collect_unknown_keys(raw, nil)
  end

  def validate_regex_lists
    REGEX_LIST_FIELDS.each do |dotted|
      value = fetch(dotted)
      next if value.nil?

      unless value.is_a?(Array) && value.all? { |v| v.is_a?(String) }
        errors << "#{path}: #{dotted} must be a list of regex source strings, got #{value.inspect}"
        next
      end

      value.each do |source|
        Regexp.new(source)
      rescue RegexpError => e
        errors << "#{path}: #{dotted} entry #{source.inspect} is not a valid regular expression (#{e.message})"
      end
    end
  end

  def validate_commands
    COMMAND_FIELDS.each do |dotted|
      value = fetch(dotted)
      next if value.nil? || argv?(value)

      errors << "#{path}: #{dotted} must be an argv array of strings, got #{value.inspect}"
    end

    COMMAND_LIST_FIELDS.each do |dotted|
      value = fetch(dotted)
      next if value.nil?

      unless value.is_a?(Array) && value.all? { |c| argv?(c) }
        errors << "#{path}: #{dotted} must be a list of argv arrays, got #{value.inspect}"
      end
    end
  end

  def argv?(value)
    value.is_a?(Array) && !value.empty? && value.all? { |v| v.is_a?(String) }
  end

  def validate_version
    version = raw["wurk"]
    return if version.nil? # validate_required reports it

    return if version == SCHEMA_VERSION

    errors << "#{path}: wurk is #{version.inspect}, but this kit implements schema version #{SCHEMA_VERSION}"
  end

  def validate_required
    REQUIRED.each do |dotted|
      value = fetch(dotted)
      next unless value.nil? || (value.respond_to?(:empty?) && value.empty?)

      errors << "#{path}: missing required key #{dotted} (see wurk docs/manifest.md)"
    end
  end

  def validate_enums
    ENUMS.each do |dotted, allowed|
      value = fetch(dotted)
      next if value.nil?
      next if allowed.include?(value)

      errors << "#{path}: #{dotted} is #{value.inspect}; expected one of #{allowed.join(', ')}"
    end
  end

  # Forward compatibility: a key this kit does not know about is a warning,
  # never an error - the consumer repo may be pinned to a newer schema than
  # the installed kit.
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

# The standalone lint: `ruby .claude/scripts/lib/manifest.rb check
# [--file PATH]`. Emits the same envelope as every other script, so a
# consumer repo can wire it into its own gate without knowing anything about
# this file. Exits 1 on an invalid manifest, 0 on a valid one (unknown-key
# warnings do not fail it - that is the whole point of warning on them).
module ManifestCli
  class << self
    def run(argv, io: $stdout)
      argv = argv.dup
      argv.shift if argv.first == "check"

      options = {}
      parser, options = Cli.build("manifest.rb check [--file PATH]", options) do |opts|
        opts.on("--file PATH", "check this manifest instead of the located one") { |v| options[:file] = v }
      end
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "manifest")

      manifest = build(options[:file])
      unless manifest
        env.block!(
          code: "manifest_unavailable",
          message: options[:file] ? "no such file: #{options[:file]}" : "no #{Manifest::FILENAME} found from #{Dir.pwd} upward, nor in the main checkout"
        )
        return env.emit(io)
      end

      env.data[:path] = manifest.path
      env.data[:wurk] = manifest.fetch("wurk")
      env.data[:valid] = manifest.valid?
      env.data[:errors] = manifest.errors

      manifest.warnings.each { |w| env.warn(code: "unknown_key", message: w) }
      manifest.errors.each { |e| env.block!(code: "invalid", message: e) }

      env.emit(io)
    rescue JSON::ParserError => e
      env ||= Envelope.new(script: "manifest")
      env.block!(code: "unparseable", message: e.message)
      env.emit(io)
    end

    private

    def build(file)
      return Manifest.load if file.nil?
      return nil unless File.file?(file)

      Manifest.new(path: file, raw: JSON.parse(File.read(file)))
    rescue Manifest::NotFound
      nil
    end
  end
end

exit ManifestCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

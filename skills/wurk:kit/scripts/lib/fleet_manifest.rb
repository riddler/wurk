# frozen_string_literal: true

require "json"
require_relative "envelope"
require_relative "cli"
require_relative "manifest"

# FleetManifest locates, parses, and validates a project's
# `.claude/wurk-fleet.json` - the file that holds what no single repo's
# `.claude/wurk.json` can know: the roster of repos a campaign may span,
# the package edges between them, which repo owns which contract area, and
# where the campaign state (journal, reports, locks, registry) lives. See
# docs/fleet-manifest.md for the schema; that document and this file change
# in the same commit, and this file is the authority.
#
# A sibling of lib/manifest.rb rather than a section inside it, for the
# same reason lib/user_config.rb is: it is a different file with a different
# reader. No kit script reads the fleet manifest - its readers are the
# /wurk:conductor skill and the wurk-fleet-scout agent, which read it as
# prose-driven agents - so the kit's job here is the lint and the resolved
# values, not typed accessors for a script pipeline. Keeping it out of
# Manifest also keeps the per-repo schema's required set, defaults and
# validation order untouched by a file that most consumers never ship.
#
# Validation follows Manifest's asymmetry (docs/manifest.md "Validation"):
# an unknown key warns, because the consumer may be pinned to a newer
# schema than the installed kit; a malformed value blocks, naming the
# field. Two refinements are specific to this file:
#
#   - A key starting with "_" is an annotation, anywhere in the tree, and
#     is skipped silently rather than warned about. Fleet manifests carry
#     dated provenance notes beside the values they explain (`_note`), and
#     a lint that warned on every one of them would be ignored wholesale.
#   - Two blocks, `policy` and `stacking`, are free-form: the conductor
#     relays them verbatim into every dispatch and interprets nothing in
#     them except the keys named in KNOWN. An unknown key there is not
#     silently ignored - it reaches every worker - so it is not warned on.
class FleetManifest
  class NotFound < StandardError; end

  FILENAME = File.join(".claude", "wurk-fleet.json")

  # The campaign-state defaults the conductor already applies when the
  # project has no fleet manifest (skills/wurk:conductor/SKILL.md, "Name a
  # report file in every dispatch" and "Journal and morning report";
  # REFERENCE.md, "Campaign files and campaign_state.rb"). Stated once here
  # so the resolved values in `check` and the prose cannot drift.
  DEFAULT_CAMPAIGNS_DIR = File.join(".claude", "campaigns")
  DEFAULT_STALENESS_MINUTES = 50

  # The known key surface, for the unknown-key warning. Same shape as
  # UserConfig::KNOWN: a key ending in "[]" describes the object elements
  # of an array under that key. A section absent from this map is not
  # walked further - which is how `policy` and `stacking` stay free-form
  # (their known keys are validated by name below, never enumerated here).
  KNOWN = {
    nil => %w[fleet description repos dependsOn ownership policy depOverride campaignState multiCampaign
              stacking landingCheck],
    "repos[]" => %w[dir package beadsPrefix note],
    "depOverride" => %w[ledger localStage pushedStage],
    "campaignState" => %w[dir journalDir reports armCommand],
    "multiCampaign" => %w[protocol registry locksDir machineGateSlots]
  }.freeze

  # Sections whose value must be a JSON object when present.
  OBJECT_SECTIONS = %w[dependsOn ownership policy depOverride campaignState multiCampaign stacking].freeze

  # Optional string-valued keys, in dotted form, that block on a non-string
  # or an empty string. Paths are checkout-relative, like every path in
  # docs/manifest.md, and an absolute one blocks: the fleet manifest is
  # shared by every machine that runs the fleet, and an absolute path is
  # right on at most one of them. campaignState.armCommand is a command
  # line run from the workload root (a consumer arm script that writes
  # more than the plan Status line, e.g. a fleet registry row), so it is a
  # string and not a path: the kit never runs it, only reports it.
  STRING_FIELDS = %w[fleet description depOverride.localStage depOverride.pushedStage campaignState.armCommand
                     multiCampaign.protocol stacking.sameRepo stacking.crossRepo].freeze
  PATH_FIELDS = %w[depOverride.ledger campaignState.dir campaignState.journalDir campaignState.reports
                   multiCampaign.registry multiCampaign.locksDir multiCampaign.protocol].freeze
  POSITIVE_INTEGER_FIELDS = %w[policy.stalenessMinutes multiCampaign.machineGateSlots].freeze

  attr_reader :path, :raw, :errors, :warnings

  class << self
    def current(start: Dir.pwd)
      @current ||= load(start: start)
    end

    def reset!
      @current = nil
    end

    attr_writer :current

    def load(start: Dir.pwd)
      path = locate(start: start)
      raise NotFound, "no #{FILENAME} found from #{start} upward" unless path

      new(path: path, raw: parse(path))
    end

    # Loads the fleet manifest, or records the reason on `env` and returns
    # nil. Absent is a block here and not a default: a caller that asks for
    # the fleet manifest is a fleet campaign, and a fleet campaign with no
    # roster has nothing to run over. A single-repo campaign never asks.
    def require!(env, start: Dir.pwd)
      manifest = current(start: start)
      unless manifest.valid?
        manifest.errors.each { |e| env.block!(code: "fleet_manifest_invalid", message: e) }
        return nil
      end
      manifest.warnings.each { |w| env.warn(code: "fleet_manifest_unknown_key", message: w) }
      manifest
    rescue NotFound, JSON::ParserError => e
      env.block!(code: "fleet_manifest_unavailable", message: e.message)
      nil
    end

    # Walk up from `start` looking for .claude/wurk-fleet.json. First hit
    # wins, same as Manifest.locate's first step. There is no git fallback:
    # the fleet root is the directory holding the file, by definition
    # (agents/wurk-fleet-scout.md), so a checkout's main working tree is
    # not a better guess than "not here".
    def locate(start: Dir.pwd)
      dir = File.expand_path(start)
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

  # --- resolved values -----------------------------------------------------

  # The directory holding the manifest's `.claude/`: `repos[].dir` and every
  # path field resolve against it.
  def fleet_root
    File.expand_path(File.join(File.dirname(path), ".."))
  end

  # Roster entries as plain hashes with the four known keys, in declaration
  # order. Malformed entries are dropped here - they have already blocked in
  # validate_repos - so a caller reading after a failed load sees only
  # well-formed rows.
  def repos
    entries = raw["repos"]
    return [] unless entries.is_a?(Array)

    entries.select { |e| e.is_a?(Hash) && nonblank?(e["dir"]) }.map do |entry|
      {
        "dir" => entry["dir"],
        "package" => nonblank?(entry["package"]) ? entry["package"] : nil,
        "beadsPrefix" => nonblank?(entry["beadsPrefix"]) ? entry["beadsPrefix"] : nil,
        "note" => entry["note"].is_a?(String) ? entry["note"] : nil
      }
    end
  end

  def repo_dirs
    repos.map { |r| r["dir"] }
  end

  def packages
    repos.map { |r| r["package"] }.compact
  end

  # Package -> [packages it depends on], annotation keys dropped, restricted
  # to well-formed rows.
  def depends_on
    section = raw["dependsOn"]
    return {} unless section.is_a?(Hash)

    section.each_with_object({}) do |(package, deps), out|
      next if annotation?(package)
      next unless deps.is_a?(Array) && deps.all? { |d| d.is_a?(String) }

      out[package] = deps
    end
  end

  # Contract area -> owning repo dir, annotation keys dropped.
  def ownership
    section = raw["ownership"]
    return {} unless section.is_a?(Hash)

    section.reject { |area, _| annotation?(area) }
  end

  # Every package in dependency order, dependencies first: the default
  # campaign order the conductor's ready-graph starts from. Packages that
  # appear only as roster entries (no edge in or out) come after the ones
  # the edges order, in roster order. nil when dependsOn has a cycle, which
  # validate_depends_on has already reported.
  def topological_order
    edges = depends_on
    nodes = (packages + edges.keys + edges.values.flatten).uniq
    order = []
    state = {}
    cyclic = false

    visit = lambda do |node|
      case state[node]
      when :done then next
      when :active
        cyclic = true
        next
      end
      state[node] = :active
      (edges[node] || []).each { |dep| visit.call(dep) }
      state[node] = :done
      order << node
    end

    nodes.each { |node| visit.call(node) }
    cyclic ? nil : order
  end

  # The fleet-wide default for the campaign file's `staleness_minutes`;
  # the campaign file wins when both are set (conductor REFERENCE.md,
  # "Staleness threshold and report files"). A malformed value has already
  # blocked, so this only ever returns the declared integer or the default.
  def staleness_minutes
    positive_integer(fetch("policy.stalenessMinutes")) || DEFAULT_STALENESS_MINUTES
  end

  # The fleet's slot count, or nil. A FALLBACK only: `lock.rb acquire`
  # takes the machine config's `machine.gate_slots` over this number
  # whenever the machine sets one (docs/machine-config.md, "machine.gate_slots
  # wins over the fleet's number"), because a shared file can be right for
  # at most one of the machines that run the fleet.
  def machine_gate_slots
    positive_integer(fetch("multiCampaign.machineGateSlots"))
  end

  def campaigns_dir
    fetch("campaignState.dir") || DEFAULT_CAMPAIGNS_DIR
  end

  def journal_dir
    fetch("campaignState.journalDir") || File.join(campaigns_dir, "journal")
  end

  # The reports dir with the conductor's `<campaign-id>` placeholder left
  # in: the manifest names a parent, the campaign id is only known at
  # dispatch.
  def reports_dir
    fetch("campaignState.reports") || File.join(campaigns_dir, "reports", "<campaign-id>")
  end

  # The workload's own arm/disarm command line, or nil: a consumer whose
  # arming writes more than the plan Status line (a fleet registry row,
  # say) names the script that writes both, and a peer arm runs it from
  # the workload root instead of campaign_state.rb arm. The kit only
  # reports it here; nothing in the kit runs it.
  def arm_command
    fetch("campaignState.armCommand")
  end

  def locks_dir
    fetch("multiCampaign.locksDir") || File.join(campaigns_dir, "locks")
  end

  def registry
    fetch("multiCampaign.registry")
  end

  def ledger
    fetch("depOverride.ledger")
  end

  def landing_check
    value = fetch("landingCheck")
    argv?(value) ? value : nil
  end

  # Dotted lookup over the raw tree; nil for an absent key. No DEFAULTS
  # table: the handful of defaults above are derived from one another
  # (journal under campaigns dir), which a flat table cannot express.
  def fetch(dotted)
    dotted.split(".").inject(raw) { |node, key| node.is_a?(Hash) ? node[key] : nil }
  end

  private

  def annotation?(key)
    key.is_a?(String) && key.start_with?("_")
  end

  def positive_integer(value)
    value.is_a?(Integer) && value.positive? ? value : nil
  end

  def nonblank?(value)
    value.is_a?(String) && !value.strip.empty?
  end

  def argv?(value)
    value.is_a?(Array) && !value.empty? && value.all? { |v| v.is_a?(String) }
  end

  def validate!
    unless raw.is_a?(Hash)
      errors << "#{path}: the fleet manifest must be a JSON object, got #{raw.class}"
      return
    end

    validate_object_sections
    validate_repos
    validate_depends_on
    validate_ownership
    validate_strings
    validate_paths
    validate_positive_integers
    validate_dep_override
    validate_landing_check
    collect_unknown_keys(raw, nil)
  end

  def validate_object_sections
    OBJECT_SECTIONS.each do |key|
      value = raw[key]
      next if value.nil? || value.is_a?(Hash)

      errors << "#{path}: #{key} must be an object (see wurk docs/fleet-manifest.md)"
    end
  end

  # `repos` is the one required key: it is what makes the file a fleet. A
  # roster of one is valid and expected (a single-repo project that wants
  # the campaign-state keys); an empty roster is not a fleet.
  def validate_repos
    entries = raw["repos"]
    unless entries.is_a?(Array) && !entries.empty?
      errors << "#{path}: repos must be a non-empty array of {dir, package, beadsPrefix} objects " \
                "(see wurk docs/fleet-manifest.md)"
      return
    end

    entries.each_with_index { |entry, index| validate_repo_entry(entry, index) }
    validate_repos_distinct(entries, "dir")
    validate_repos_distinct(entries, "package")
    validate_repos_distinct(entries, "beadsPrefix")
  end

  def validate_repo_entry(entry, index)
    unless entry.is_a?(Hash)
      errors << "#{path}: repos[#{index}] must be an object, got #{entry.inspect}"
      return
    end

    dir = entry["dir"]
    if !nonblank?(dir)
      errors << "#{path}: repos[#{index}].dir must be a non-empty relative path, got #{dir.inspect}"
    elsif dir.start_with?("/")
      errors << "#{path}: repos[#{index}].dir must be relative to the fleet root, got #{dir.inspect}"
    elsif dir.split("/").include?("..")
      errors << "#{path}: repos[#{index}].dir must stay under the fleet root (no '..' segments), " \
                "got #{dir.inspect}"
    end

    %w[package beadsPrefix note].each do |key|
      value = entry[key]
      next if value.nil? || nonblank?(value)

      errors << "#{path}: repos[#{index}].#{key} must be a non-empty string when present, got #{value.inspect}"
    end
  end

  # Two roster rows with one dir are one repo listed twice; two with one
  # package would make every dependsOn edge ambiguous; two with one bead
  # prefix would leave a bead id attributable to either repo.
  def validate_repos_distinct(entries, key)
    values = entries.select { |e| e.is_a?(Hash) }.map { |e| e[key] }.select { |v| nonblank?(v) }
    repeated = values.group_by { |v| v }.select { |_, uses| uses.length > 1 }.keys
    return if repeated.empty?

    errors << "#{path}: repos[].#{key} #{repeated.map(&:inspect).join(', ')} listed more than once"
  end

  # Every key and every value names a roster package. The conductor and the
  # scout join these edges into the ready-graph; an edge to a package no
  # roster row declares is a repo the campaign cannot find, and a cycle is
  # a graph with no first repo.
  def validate_depends_on
    section = raw["dependsOn"]
    return unless section.is_a?(Hash)

    known = packages
    section.each do |package, deps|
      next if annotation?(package)

      unless known.include?(package)
        errors << "#{path}: dependsOn.#{package} is not a repos[].package"
      end

      unless deps.is_a?(Array) && deps.all? { |d| d.is_a?(String) }
        errors << "#{path}: dependsOn.#{package} must be an array of package names, got #{deps.inspect}"
        next
      end

      deps.each do |dep|
        if dep == package
          errors << "#{path}: dependsOn.#{package} depends on itself"
        elsif !known.include?(dep)
          errors << "#{path}: dependsOn.#{package} names #{dep.inspect}, which is not a repos[].package"
        end
      end
    end

    return unless errors.empty? && topological_order.nil?

    errors << "#{path}: dependsOn has a cycle; a campaign over it has no first repo"
  end

  # Every value names a roster dir: a discovered dependency is filed in the
  # owning repo, and an owner that is not in the roster is nowhere to file.
  def validate_ownership
    section = raw["ownership"]
    return unless section.is_a?(Hash)

    dirs = repo_dirs
    section.each do |area, owner|
      next if annotation?(area)

      unless nonblank?(owner)
        errors << "#{path}: ownership.#{area} must be a repos[].dir string, got #{owner.inspect}"
        next
      end

      next if dirs.include?(owner)

      errors << "#{path}: ownership.#{area} names #{owner.inspect}, which is not a repos[].dir"
    end
  end

  def validate_strings
    STRING_FIELDS.each do |dotted|
      value = fetch(dotted)
      next if value.nil? || nonblank?(value)

      errors << "#{path}: #{dotted} must be a non-empty string, got #{value.inspect}"
    end
  end

  def validate_paths
    PATH_FIELDS.each do |dotted|
      value = fetch(dotted)
      next if value.nil?

      unless nonblank?(value)
        errors << "#{path}: #{dotted} must be a non-empty fleet-root-relative path, got #{value.inspect}"
        next
      end

      next unless value.start_with?("/")

      errors << "#{path}: #{dotted} must be relative to the fleet root (the manifest is shared by every " \
                "machine that runs the fleet), got #{value.inspect}"
    end
  end

  def validate_positive_integers
    POSITIVE_INTEGER_FIELDS.each do |dotted|
      value = fetch(dotted)
      next if value.nil?
      next if value.is_a?(Integer) && value.positive?

      errors << "#{path}: #{dotted} must be a positive integer, got #{value.inspect}"
    end
  end

  # Present-or-absent, never half-present, the rule the manifest's optional
  # sections follow: a depOverride block is where the linkage ledger lives,
  # and the stage vocabulary is meaningless without one.
  def validate_dep_override
    section = raw["depOverride"]
    return unless section.is_a?(Hash)
    return unless section["ledger"].nil?

    errors << "#{path}: depOverride.ledger is required when the depOverride section is present " \
              "(omit the section entirely to run without a cross-repo linkage recipe)"
  end

  # An argv array, never a shell string - the rule every command field in
  # docs/manifest.md follows, for the reason lib/sh.rb enforces at the
  # other end.
  def validate_landing_check
    value = raw["landingCheck"]
    return if value.nil? || argv?(value)

    errors << "#{path}: landingCheck must be an argv array of strings, got #{value.inspect}"
  end

  # Forward compatibility, as in Manifest#collect_unknown_keys, plus the
  # annotation rule: a "_"-prefixed key is skipped at every level. A
  # section with no KNOWN entry (policy, stacking, and every leaf) is not
  # walked.
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
      next if annotation?(key)

      dotted = prefix ? "#{prefix}.#{key}" : key
      if known.include?(key)
        collect_unknown_keys(node[key], dotted, known_key ? "#{known_key}.#{key}" : key)
      else
        warnings << "#{path}: unknown key #{dotted} (ignored)"
      end
    end
  end
end

# The standalone lint: `ruby lib/fleet_manifest.rb check [--file PATH]`.
# Emits the usual envelope. Read-only, so no --dry-run. Exits 1 on an
# invalid manifest, 0 otherwise (unknown-key warnings do not fail it).
#
# Two checks live here and not in FleetManifest#validate!, on the split
# lib/manifest.rb draws between validate! (pure shape over the parsed JSON,
# runs on every load) and the lint (reads the filesystem, answers questions
# about the environment): whether each roster dir is present under the
# fleet root, and whether each roster row's beadsPrefix agrees with the
# `beads.prefix` that repo's own .claude/wurk.json declares.
module FleetManifestCli
  class << self
    def run(argv, io: $stdout)
      argv = argv.dup
      argv.shift if argv.first == "check"

      options = {}
      parser, options = Cli.build("fleet_manifest.rb check [--file PATH]", options) do |opts|
        opts.on("--file PATH", "check this fleet manifest instead of the located one") { |v| options[:file] = v }
      end
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "fleet_manifest")

      manifest = build(options[:file])
      unless manifest
        env.block!(
          code: "fleet_manifest_unavailable",
          message: options[:file] ? "no such file: #{options[:file]}" : "no #{FleetManifest::FILENAME} found from #{Dir.pwd} upward"
        )
        return env.emit(io)
      end

      env.data[:path] = manifest.path
      env.data[:fleet_root] = manifest.fleet_root
      env.data[:valid] = manifest.valid?
      env.data[:errors] = manifest.errors
      env.data[:repos] = manifest.repos
      env.data[:depends_on] = manifest.depends_on
      env.data[:topological_order] = manifest.topological_order
      env.data[:ownership] = manifest.ownership
      env.data[:staleness_minutes] = manifest.staleness_minutes
      env.data[:machine_gate_slots] = manifest.machine_gate_slots
      env.data[:campaigns_dir] = manifest.campaigns_dir
      env.data[:journal_dir] = manifest.journal_dir
      env.data[:reports_dir] = manifest.reports_dir
      env.data[:arm_command] = manifest.arm_command
      env.data[:locks_dir] = manifest.locks_dir
      env.data[:registry] = manifest.registry
      env.data[:ledger] = manifest.ledger
      env.data[:landing_check] = manifest.landing_check

      warn_missing_repo_dirs(env, manifest)
      block_beads_prefix_mismatches(env, manifest)

      manifest.warnings.each { |w| env.warn(code: "unknown_key", message: w) }
      manifest.errors.each { |e| env.block!(code: "invalid", message: e) }

      env.emit(io)
    rescue JSON::ParserError => e
      env ||= Envelope.new(script: "fleet_manifest")
      env.block!(code: "unparseable", message: e.message)
      env.emit(io)
    end

    private

    # A warning, not a block: a fleet manifest is shared by every machine
    # that runs the fleet, and a repo not cloned on this one is a fact
    # about the box. The scout reports the same absence when it sweeps.
    def warn_missing_repo_dirs(env, manifest)
      missing = manifest.repo_dirs.reject { |dir| File.directory?(File.join(manifest.fleet_root, dir)) }
      return if missing.empty?

      env.warn(
        code: "fleet_repo_dir_missing",
        message: "#{manifest.path}: repos[].dir #{missing.map(&:inspect).join(', ')} not found under " \
                 "#{manifest.fleet_root} - not cloned on this machine, or a stale roster entry"
      )
    end

    # A block: a roster prefix that disagrees with the repo's own manifest
    # has no legitimate reading, and the alternative is a conductor
    # attributing a bead id to the wrong repo mid-campaign. Only present
    # repos with a readable manifest are compared; a repo whose wurk.json
    # is missing or invalid is that repo's own lint's business.
    def block_beads_prefix_mismatches(env, manifest)
      manifest.repos.each do |repo|
        next unless repo["beadsPrefix"]

        declared = repo_beads_prefix(File.join(manifest.fleet_root, repo["dir"]))
        next if declared.nil? || declared == repo["beadsPrefix"]

        env.block!(
          code: "fleet_beads_prefix_mismatch",
          message: "#{manifest.path}: repos[].beadsPrefix for #{repo['dir'].inspect} is " \
                   "#{repo['beadsPrefix'].inspect}, but that repo's #{Manifest::FILENAME} declares " \
                   "beads.prefix #{declared.inspect}"
        )
      end
    end

    def repo_beads_prefix(root)
      file = File.join(root, Manifest::FILENAME)
      return nil unless File.file?(file)

      raw = JSON.parse(File.read(file))
      beads = raw.is_a?(Hash) ? raw["beads"] : nil
      prefix = beads.is_a?(Hash) ? beads["prefix"] : nil
      prefix.is_a?(String) && !prefix.empty? ? prefix : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def build(file)
      return FleetManifest.load if file.nil?
      return nil unless File.file?(file)

      FleetManifest.new(path: file, raw: FleetManifest.parse(file))
    rescue FleetManifest::NotFound
      nil
    end
  end
end

exit FleetManifestCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

# frozen_string_literal: true

require "json"
require_relative "sh"
require_relative "envelope"
require_relative "cli"
require_relative "gate_paths"

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
    "beads.sync" => %w[local git dolthub],
    "forge.kind" => %w[github gitlab],
    "parallelism.model" => %w[worktree-per-issue branch-in-place],
    "commits.style" => %w[s-form conventional],
    "changelog.mode" => %w[fragments keep-a-changelog none],
    "tmux.layout" => %w[window-per-issue session-per-issue]
  }.freeze

  # Keys this schema used to carry. A consumer pinned to an older kit may
  # still set one; the answer is a warning that names the replacement, not a
  # block - removing a key can never be a reason to refuse to run.
  RETIRED = {
    "tmux.permission_mode" =>
      "moved to the machine-level config (see docs/machine-config.md); " \
      "the manifest value is ignored"
  }.freeze

  # The known key surface, for the unknown-key warning. Nested sections list
  # their own keys; a section absent from this map is not validated further.
  KNOWN = {
    nil => %w[wurk repo beads forge gate parallelism tmux models artifacts commits changelog release judge rebase
             mr],
    "repo" => %w[default_branch],
    "beads" => %w[prefix topology sync areas],
    "beads.areas" => %w[labels lands_alone always_batchable],
    "forge" => %w[kind labels],
    "gate" => %w[cwd full loop report report_loop attest guard_ledger build_paths also_gated_paths moving_files
                 project_level_skips not_applicable_skips sabotage timeout_seconds long_timeout_seconds],
    "gate.sabotage" => %w[test_roots test_pattern exempt_prefixes],
    "parallelism" => %w[model worktrees_dir trust warm_clone warm_globs warm repair_when repair post_branch
                        timeout_seconds],
    "tmux" => %w[session model layout editor],
    "models" => %w[direction],
    "artifacts" => %w[plans research filename repository],
    "commits" => %w[style package_map subject_under body_line_max total_lines_max trailer],
    "commits.trailer" => %w[key],
    "changelog" => %w[mode dir],
    "judge" => %w[model registry],
    "rebase" => %w[auto_resolve_paths],
    "mr" => %w[review_agents]
  }.freeze

  DEFAULTS = {
    "repo.default_branch" => "main",
    "beads.topology" => "beads",
    # Deliberately NOT the most common value. See validate_beads_sync and
    # docs/manifest.md: an absent key must never be able to cause a push.
    "beads.sync" => "local",
    "commits.style" => "s-form",
    "commits.subject_under" => 50,
    "commits.body_line_max" => 72,
    "commits.total_lines_max" => 40,
    "commits.trailer.key" => "Refs",
    "models.direction" => "opus",
    "artifacts.filename" => "YYMMDD-[id-]kebab",
    "judge.model" => "sonnet",
    "gate.timeout_seconds" => 600,
    "gate.long_timeout_seconds" => 3600,
    "parallelism.timeout_seconds" => 600,
    "tmux.layout" => "window-per-issue"
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

  # The root of the checkout this manifest was located in: `path` is always
  # <root>/.claude/wurk.json, so the root is two levels up. Every kit use of a
  # repo-root-relative manifest path resolves against this rather than
  # Dir.pwd, because manifest resolution walks up from the working directory
  # (see `locate`) and gate.rb is legitimately invoked from a subdirectory.
  def checkout_root
    File.expand_path(File.join(File.dirname(path), ".."))
  end

  # The branch every "what did this branch change" comparison is made
  # against. Defaults to "main" - git's own convention, stated once here
  # rather than spelled into each script's argv.
  def default_branch
    fetch("repo.default_branch")
  end

  # The same branch on the shared remote. The remote name is not configurable
  # (see the plan's What We're NOT Doing); only the branch is.
  def remote_default_branch
    "origin/#{default_branch}"
  end

  def bead_prefix
    fetch("beads.prefix")
  end

  def topology
    fetch("beads.topology")
  end

  # How this repo's beads database syncs, and therefore whether any skill is
  # ever allowed to run `bd dolt push` here:
  #
  #   local   - the beads never leave the machine. Pushing is FORBIDDEN.
  #   git     - the dolt remote is a git+ssh URL on the code forge; the
  #             tracker is pushed after the code push.
  #   dolthub - the remote is a DoltHub database; same ordering, different
  #             remote and auth.
  #
  # Absent means `local`, which is the unsafe-by-omission direction turned
  # around on purpose: see validate_beads_sync.
  def beads_sync
    fetch("beads.sync")
  end

  # The single predicate every tracker-pushing step asks. Written as an
  # allow-list rather than `!= "local"` so that a mode this kit does not yet
  # know about (a consumer pinned to a newer schema, whose value survives
  # the enum check only in that consumer's newer kit) cannot fall through
  # into a push here.
  def beads_push_allowed?
    %w[git dolthub].include?(beads_sync)
  end

  # True when the consumer actually wrote the key down, false when the
  # `local` default is only being inferred. The distinction is what the
  # unset warning reports, and what a skill needs to say "not pushed,
  # tracker is local" versus "not pushed, and nobody has declared a mode".
  def beads_sync_declared?
    !dig_raw("beads.sync").nil?
  end

  # Every dolt remote configured for this checkout's beads database, as
  # "<source>: <name> -> <url>" strings, newest-footgun-first. Two sources,
  # because the incident behind beads.sync had a remote in the second one
  # after a guard script had removed it from the first:
  #
  #   1. .beads/config.yaml - the `sync.remote` key bd itself reads.
  #   2. .beads/embeddeddolt/*/.dolt/repo_state.json - dolt's own state,
  #      which keeps a remote that was added once even after the yaml no
  #      longer mentions it.
  #
  # Pure file reads, no shell-out and no `bd`: this runs inside the lint,
  # which must work in a checkout where bd is not installed. An unreadable
  # or unparseable file contributes nothing rather than raising - the
  # caller's job is a warning, not a verdict.
  def beads_dolt_remotes(root: checkout_root)
    beads = File.join(root, ".beads")
    return [] unless File.directory?(beads)

    remotes_from_config(File.join(beads, "config.yaml")) +
      remotes_from_dolt_state(beads)
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

  # Seconds Sh.run allows the gate command and the attest command before
  # killing them. Defaults to 600 - the value both gate.rb call sites used to
  # hard-code. A consumer whose gate runs inside docker-compose (image build,
  # deps fetch, full test battery) can plausibly need longer than that cold.
  def gate_timeout_seconds
    fetch("gate.timeout_seconds")
  end

  # Seconds the detached long-gate runner (gate_run.rb) allows the gate
  # command before killing it. Defaults to 3600. Deliberately a separate
  # field from gate.timeout_seconds rather than a multiple of it:
  # gate.timeout_seconds bounds a FOREGROUND gate run whose caller (a
  # subagent's Bash tool) is blocked waiting on it, so it has to stay under
  # the harness's own hard cap; this one bounds the DETACHED long-gate run,
  # which exists precisely to outlive that cap and run unattended, so it
  # needs its own, much longer, bound.
  def gate_long_timeout_seconds
    fetch("gate.long_timeout_seconds")
  end

  # The repo-root-relative directory the five consumer gate commands run in,
  # or nil when the project gates from its repo root (the common case).
  # See docs/manifest.md: gate.cwd scopes EXECUTION of gate commands; it never
  # rescopes MATCHING of manifest paths.
  def gate_cwd
    fetch("gate.cwd")
  end

  # The `chdir:` to hand Sh.run for a gate command, given the root of the
  # checkout being gated. nil when the project declares no gate.cwd, so the
  # caller's own default applies unchanged - gate.rb passes no chdir at all,
  # and the worktree scripts keep passing the worktree path.
  def gate_chdir(root: checkout_root)
    gate_cwd && File.join(root, gate_cwd)
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
    skip_re("gate.project_level_skips")
  end

  # The sibling list, for stages the project has declared permanently
  # inapplicable rather than a gap it means to close. Same shape, same
  # nil-means-strict default; gate.rb checks this one first (see
  # docs/manifest.md).
  def not_applicable_skip_re
    skip_re("gate.not_applicable_skips")
  end

  # Whether the sabotage scan is configured at all. A section absent means
  # the scan is off, not that it found nothing - see gate.rb and
  # docs/manifest.md for the distinction the envelope has to preserve.
  def sabotage?
    !fetch("gate.sabotage").nil?
  end

  def sabotage_test_roots
    Array(fetch("gate.sabotage.test_roots"))
  end

  def sabotage_test_pattern
    source = fetch("gate.sabotage.test_pattern")
    source && Regexp.new(source)
  end

  def sabotage_exempt_prefixes
    Array(fetch("gate.sabotage.exempt_prefixes"))
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

  # Seconds Sh.run allows the mise-trust hook and each parallelism.warm
  # command before killing them. Defaults to 600, same as gate.timeout_seconds
  # and for the same reason: a consumer whose warm step builds container
  # images or fetches deps can plausibly need longer than the 60s Sh.run
  # default. Separate from gate.timeout_seconds because it is a different
  # phase with a different owner - the post-warm verify runs gate.loop itself
  # and uses gate.timeout_seconds instead (see worktree_create.rb).
  def parallelism_timeout_seconds
    fetch("parallelism.timeout_seconds")
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

  def tmux_layout
    fetch("tmux.layout")
  end

  # Optional argv, same shape as trust_argv: absent stays nil, present is
  # held to the argv rule rather than split on whitespace.
  def tmux_editor_argv
    value = fetch("tmux.editor")
    value && argv(value)
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

  # Whether a judged-prose registry is configured at all. Absent means the
  # judge has nothing to judge, not that it judged and found nothing.
  def judge?
    !fetch("judge").nil?
  end

  def judge_model
    fetch("judge.model")
  end

  # Registry entries as plain hashes, in declaration order. Each carries
  # key, label, scope_prefix, optional scope_suffix, text (the path of the
  # judged document) and focus (what the propose pass is asked to look for).
  def judge_registry
    Array(fetch("judge.registry"))
  end

  # The read-only review agents a consumer ships in .claude/agents/ and
  # wants spawned against the worktree between the gate and the push (the
  # pre-request review round in /wurk:mr). Names only - the kit never learns
  # what any of them do.
  #
  # Absent means the consumer ships no such agents, and the step is skipped
  # in silence rather than warned about: a repo that never declared a review
  # round is not missing one. Distinct from `judge` (ADR-0008), which is a
  # merge-time propose/refute pass over registered DOCUMENTS; this is a
  # review of the diff by the consumer's own agents.
  #
  # The filter is a safety valve, not a schema: a malformed value already
  # blocks in validate_mr, and this keeps a non-string from reaching
  # File.join in the lint before that block is read.
  def mr_review_agents
    value = fetch("mr.review_agents")
    return [] unless value.is_a?(Array)

    value.select { |name| name.is_a?(String) }
  end

  def mr_review_agents?
    !mr_review_agents.empty?
  end

  # Where a declared name has to resolve. A name is a bare agent name and
  # never a path, which is what validate_mr enforces - the file is always
  # <checkout>/.claude/agents/<name>.md.
  def mr_review_agent_path(name, root: checkout_root)
    File.join(root, ".claude", "agents", "#{name}.md")
  end

  # Declared names with no file behind them. Reads the filesystem, so the
  # lint calls it and validate! does not - the same split as
  # beads_dolt_remotes.
  def mr_review_agents_missing(root: checkout_root)
    mr_review_agents.reject { |name| File.file?(mr_review_agent_path(name, root: root)) }
  end

  # The only paths a rebase conflict may be auto-resolved in. Empty - the
  # default - means the feature is off, which is where every consumer starts.
  # Same matching rule as the gate path lists (see lib/gate_paths.rb): a
  # trailing "/" is a directory prefix, anything else is an exact path.
  def rebase_auto_resolve_paths
    Array(fetch("rebase.auto_resolve_paths"))
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
    value = dig_raw(dotted)
    value.nil? ? DEFAULTS[dotted] : value
  end

  # `fetch` without the default applied: what the consumer literally wrote,
  # so a caller can tell "declared, and equal to the default" from "absent".
  def dig_raw(dotted)
    dotted.split(".").inject(raw) { |node, key| node.is_a?(Hash) ? node[key] : nil }
  end

  private

  # `sync.remote: "..."` is bd's own flat key; the nested `sync:` / `remote:`
  # form is accepted too. Comments are stripped first - the shipped
  # config.yaml documents the key in a comment block, and matching that
  # would make the warning fire in every repo.
  def remotes_from_config(file)
    return [] unless File.file?(file)

    File.readlines(file).filter_map do |line|
      body = line.sub(/#.*\z/, "").rstrip
      next unless (m = body.match(/^\s*(?:sync\.)?remote:\s*(.+)\z/))

      url = m[1].strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
      next if url.empty?

      "config.yaml: sync.remote -> #{url}"
    end
  rescue SystemCallError
    []
  end

  # dolt's repo_state.json is the copy that outlives a config edit, which is
  # exactly why it is checked separately.
  def remotes_from_dolt_state(beads_dir)
    Dir.glob(File.join(beads_dir, "embeddeddolt", "*", ".dolt", "repo_state.json")).sort.flat_map do |state|
      parsed = JSON.parse(File.read(state))
      next [] unless parsed.is_a?(Hash)

      db = File.basename(File.dirname(File.dirname(state)))
      (parsed["remotes"] || {}).map do |name, spec|
        url = spec.is_a?(Hash) ? spec["url"] : spec
        "embeddeddolt/#{db}: #{name} -> #{url}"
      end
    rescue JSON::ParserError, SystemCallError
      []
    end
  end

  # Shared by project_level_skip_re and not_applicable_skip_re: compiles a
  # regex-list field into one Regexp, or nil when the project declares none.
  # One helper so the two accessors cannot drift apart.
  def skip_re(dotted)
    sources = Array(fetch(dotted))
    return nil if sources.empty?

    Regexp.union(sources.map { |s| Regexp.new(s) })
  end

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
  COMMAND_FIELDS = %w[gate.full gate.loop gate.report gate.report_loop gate.attest parallelism.trust
                      tmux.editor].freeze
  COMMAND_LIST_FIELDS = %w[parallelism.warm parallelism.repair parallelism.post_branch].freeze

  # Fields that hold a list of regex source strings rather than argv. Each
  # entry must compile; the field itself may be absent.
  REGEX_LIST_FIELDS = %w[gate.project_level_skips gate.not_applicable_skips].freeze

  def validate!
    validate_version
    validate_required
    validate_enums
    validate_commands
    validate_regex_lists
    validate_default_branch
    validate_beads_sync
    validate_sabotage
    validate_judge
    validate_rebase
    validate_mr
    validate_gate_timeout_seconds
    validate_gate_long_timeout_seconds
    validate_parallelism_timeout_seconds
    validate_gate_cwd
    validate_tmux
    validate_retired
    collect_unknown_keys(raw, nil)
  end

  # Git ref-name shape, deliberately narrower than git-check-ref-format(1):
  # the value is spliced into an argv git already interprets positionally, so
  # a leading "-" would become an option rather than a ref. Slashes are
  # allowed (release/next is a legitimate default branch); whitespace, "..",
  # "~", "^", ":" and a leading "-" are not.
  DEFAULT_BRANCH_RE = %r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}

  # validate_default_branch needs no nil guard: fetch applies the default, so
  # the value is only ever absent-and-defaulted or explicitly wrong.
  def validate_default_branch
    value = fetch("repo.default_branch")
    return if value.is_a?(String) && value.match?(DEFAULT_BRANCH_RE) && !value.include?("..")

    errors << "#{path}: repo.default_branch must be a git branch name " \
              "(letters, digits, '.', '_', '/', '-'; no leading '-'), got #{value.inspect}"
  end

  # An unset beads.sync warns rather than blocking, and defaults to `local`.
  #
  # Both halves are deliberate, and the default runs against the usual rule
  # for picking one. Most defaults in this schema are the most common value
  # (`repo.default_branch` = main, `beads.topology` = beads); this one is the
  # value that does the least, because the two directions are not
  # symmetrical. Guessing `git` for a repo whose beads are local publishes an
  # issue database that was never meant to leave the machine, and nothing
  # un-publishes it; guessing `local` for a repo that does push costs one
  # skipped push and a warning saying so. That is the same reasoning the rest
  # of this class's asymmetry rests on (see the class comment and
  # docs/manifest.md "Validation"): an unrecognized value blocks because
  # guessing a structural behavior is worse than stopping, and here the
  # absent value is guessed only in the direction that is recoverable.
  #
  # The warning exists so the guess is never silent - a consumer that does
  # push is told to declare the key rather than quietly losing its tracker
  # pushes. It is a warning and not a block because a missing key with a safe
  # default is not a reason to refuse to run.
  def validate_beads_sync
    return if beads_sync_declared?

    warnings << "#{path}: beads.sync is unset - defaulting to local, which means no skill will run " \
                "bd dolt push in this repo. Declare beads.sync (local, git, or dolthub) to say so " \
                "on purpose; see wurk docs/manifest.md"
  end

  # Present-or-absent, never half-present: a section that declares roots but
  # no pattern (or vice versa) is a schema error, not a partly-on scan.
  def validate_sabotage
    section = fetch("gate.sabotage")
    return if section.nil?

    unless section.is_a?(Hash)
      errors << "#{path}: gate.sabotage must be an object (see wurk docs/manifest.md)"
      return
    end

    roots = section["test_roots"]
    unless roots.is_a?(Array) && !roots.empty? &&
           roots.all? { |r| r.is_a?(String) && !r.empty? && !r.start_with?(":") }
      errors << "#{path}: gate.sabotage.test_roots must be a non-empty list of git pathspecs " \
                "(directory prefixes, exact file paths, or globs; no leading ':')"
    end

    pattern = section["test_pattern"]
    if !pattern.is_a?(String) || pattern.empty?
      errors << "#{path}: gate.sabotage.test_pattern must be a regex source string"
    else
      begin
        Regexp.new(pattern)
      rescue RegexpError => e
        errors << "#{path}: gate.sabotage.test_pattern is not a valid regular expression (#{e.message})"
      end
    end

    exempt = section["exempt_prefixes"]
    unless exempt.nil? || (exempt.is_a?(Array) && exempt.all? { |p| p.is_a?(String) })
      errors << "#{path}: gate.sabotage.exempt_prefixes must be a list of path prefixes"
    end
  end

  # validate_gate_timeout_seconds needs no nil guard, same reason as
  # validate_default_branch: fetch applies the 600 default, so the value is
  # only ever absent-and-defaulted or explicitly wrong.
  def validate_gate_timeout_seconds
    value = fetch("gate.timeout_seconds")
    return if value.is_a?(Integer) && value.positive?

    errors << "#{path}: gate.timeout_seconds must be a positive integer, got #{value.inspect}"
  end

  # validate_gate_long_timeout_seconds needs no nil guard, same reason as
  # validate_gate_timeout_seconds: fetch applies the 3600 default, so the
  # value is only ever absent-and-defaulted or explicitly wrong. Also warns
  # (never blocks) when the long timeout is shorter than the short one -
  # legal, since nothing enforces an ordering between the two fields, but
  # almost certainly a mistake given what each one bounds.
  def validate_gate_long_timeout_seconds
    value = fetch("gate.long_timeout_seconds")
    unless value.is_a?(Integer) && value.positive?
      errors << "#{path}: gate.long_timeout_seconds must be a positive integer, got #{value.inspect}"
      return
    end

    short = fetch("gate.timeout_seconds")
    return unless short.is_a?(Integer) && value < short

    warnings << "#{path}: gate.long_timeout_seconds (#{value}) is less than gate.timeout_seconds " \
                "(#{short}) - gate.timeout_seconds bounds a foreground gate run whose caller is " \
                "blocked waiting on it, gate.long_timeout_seconds bounds the detached long-gate run " \
                "that exists to outlive it, so this is legal but almost certainly a mistake"
  end

  # validate_parallelism_timeout_seconds needs no nil guard, same reason as
  # validate_gate_timeout_seconds: fetch applies the 600 default, so the
  # value is only ever absent-and-defaulted or explicitly wrong.
  def validate_parallelism_timeout_seconds
    value = fetch("parallelism.timeout_seconds")
    return if value.is_a?(Integer) && value.positive?

    errors << "#{path}: parallelism.timeout_seconds must be a positive integer, got #{value.inspect}"
  end

  # Shape only, never the filesystem - see docs/manifest.md and this plan's
  # What We're NOT Doing. A `gate.cwd` that names a directory which does not
  # exist fails loudly the first time the gate command tries to start; a
  # validation-time probe would make `manifest.rb check` depend on the
  # process cwd, which is the sensitivity gate.cwd exists to remove.
  def validate_gate_cwd
    value = fetch("gate.cwd")
    return if value.nil?

    unless value.is_a?(String) && !value.empty?
      errors << "#{path}: gate.cwd must be a non-empty relative directory path, got #{value.inspect}"
      return
    end

    if value.start_with?("/")
      errors << "#{path}: gate.cwd must be relative to the repo root, got #{value.inspect}"
      return
    end

    if value == "." || value.split("/").include?("..")
      errors << "#{path}: gate.cwd must name a subdirectory of the repo root " \
                "(no '.', no '..' segments); omit the field to gate from the root, got #{value.inspect}"
    end
  end

  # tmux.session is required under window-per-issue because ensure-session
  # and open address the session by name; under session-per-issue the
  # per-issue session name comes from the workspace name, so session may be
  # absent.
  def validate_tmux
    return unless tmux?
    return unless fetch("tmux.layout") == "window-per-issue"

    session = fetch("tmux.session")
    return if session.is_a?(String) && !session.empty?

    errors << "#{path}: tmux.session is required under tmux.layout " \
              "window-per-issue, got #{session.inspect}"
  end

  # A retired key still present in the raw manifest warns with a message
  # naming its replacement, rather than falling through to the generic
  # "unknown key (ignored)" collect_unknown_keys would otherwise emit for
  # it - see RETIRED and collect_unknown_keys' `elsif !RETIRED.key?(dotted)`
  # guard below.
  def validate_retired
    RETIRED.each do |dotted, note|
      parts = dotted.split(".")
      value = parts.inject(raw) { |node, key| node.is_a?(Hash) ? node[key] : nil }
      next if value.nil?

      warnings << "#{path}: #{dotted} is retired - #{note}"
    end
  end

  JUDGE_ENTRY_STRING_FIELDS = %w[key label scope_prefix text focus].freeze

  # Present-or-absent, never half-present, same rule as gate.sabotage: a
  # judge section with an empty (or missing) registry is a schema error, not
  # a silently disabled judge.
  def validate_judge
    section = fetch("judge")
    return if section.nil?

    unless section.is_a?(Hash)
      errors << "#{path}: judge must be an object (see wurk docs/manifest.md)"
      return
    end

    registry = section["registry"]
    unless registry.is_a?(Array) && !registry.empty?
      errors << "#{path}: judge.registry must be a non-empty array of objects"
      return
    end

    registry.each { |entry| validate_judge_entry(entry) }

    model = section["model"]
    unless model.nil? || (model.is_a?(String) && !model.empty?)
      errors << "#{path}: judge.model must be a non-empty string"
    end
  end

  def validate_judge_entry(entry)
    unless entry.is_a?(Hash)
      errors << "#{path}: judge.registry entries must be objects"
      return
    end

    JUDGE_ENTRY_STRING_FIELDS.each do |field|
      value = entry[field]
      next if value.is_a?(String) && !value.empty?

      errors << "#{path}: judge.registry entry missing #{field}"
    end

    suffix = entry["scope_suffix"]
    return if suffix.nil? || suffix.is_a?(String)

    errors << "#{path}: judge.registry entry scope_suffix must be a string"
  end

  # gate.build_paths and gate.also_gated_paths are coverage lists: they
  # declare where the gate looks, and a collision with them means the full
  # gate verifies the merged result on top of the deterministic net and the
  # refute. They are not disjointness surfaces. gate.moving_files, together
  # with gate.guard_ledger and parallelism.repair_when, are hazard surfaces
  # where a machine merge changes what verification means, so they stay.
  # Kept as a separate named list rather than folded into the scalars so a
  # collision error can name exactly which entry it hit. See ADR-0010's
  # 2026-08-17 amendment.
  REBASE_COLLISION_LIST_FIELDS = %w[gate.moving_files].freeze
  REBASE_COLLISION_SCALAR_FIELDS = %w[gate.guard_ledger parallelism.repair_when].freeze

  # An allowlist entry that resolves to the whole repo is not an allowlist.
  REBASE_WHOLE_REPO_ENTRIES = ["/", "."].freeze

  # Present-or-absent, never half-present, same rule as gate.sabotage and
  # judge: a rebase section with a malformed auto_resolve_paths is a schema
  # error, not a silently-empty allowlist. See ADR-0010 for why every entry
  # is validated disjoint from the gate-guarded, lockfile, and manifest
  # surfaces rather than merely documented as such.
  def validate_rebase
    section = fetch("rebase")
    return if section.nil?

    unless section.is_a?(Hash)
      errors << "#{path}: rebase must be an object (see wurk docs/manifest.md)"
      return
    end

    entries = section["auto_resolve_paths"]
    return if entries.nil?

    unless entries.is_a?(Array)
      errors << "#{path}: rebase.auto_resolve_paths must be a list of non-empty strings, got #{entries.inspect}"
      return
    end

    entries.each { |entry| validate_rebase_entry(entry) }
  end

  def validate_rebase_entry(entry)
    unless entry.is_a?(String) && !entry.empty?
      errors << "#{path}: rebase.auto_resolve_paths entries must be non-empty strings, got #{entry.inspect}"
      return
    end

    if REBASE_WHOLE_REPO_ENTRIES.include?(entry)
      errors << "#{path}: rebase.auto_resolve_paths entry #{entry.inspect} matches the whole repo, " \
                "which is not an allowlist"
      return
    end

    manifest_dir = File.dirname(Manifest::FILENAME)
    if entry == manifest_dir || entry.start_with?("#{manifest_dir}/")
      errors << "#{path}: rebase.auto_resolve_paths entry #{entry.inspect} is inside #{manifest_dir}/, " \
                "which holds the manifest and every extension file"
      return
    end

    collision = rebase_collision(entry)
    return unless collision

    errors << "#{path}: rebase.auto_resolve_paths entry #{entry.inspect} collides with #{collision}"
  end

  # "Matches or is matched by" both directions, against the manifest's own
  # gate-guarded, lockfile, and repair-trigger surfaces. Returns a string
  # naming the colliding field and value, or nil.
  def rebase_collision(entry)
    REBASE_COLLISION_LIST_FIELDS.each do |dotted|
      Array(fetch(dotted)).each do |guarded|
        next unless GatePaths.match_one?(entry, guarded) || GatePaths.match_one?(guarded, entry)

        return "#{dotted} entry #{guarded.inspect}"
      end
    end

    REBASE_COLLISION_SCALAR_FIELDS.each do |dotted|
      guarded = fetch(dotted)
      next if guarded.nil?
      next unless GatePaths.match_one?(entry, guarded) || GatePaths.match_one?(guarded, entry)

      return "#{dotted} (#{guarded.inspect})"
    end

    nil
  end

  # A bare agent name, not a path: the name is joined to
  # .claude/agents/<name>.md, so a separator or a ".." segment would let a
  # declared "name" address a file outside the consumer's own agent
  # directory.
  MR_REVIEW_AGENT_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  # Present-or-absent, never half-present, the same rule gate.sabotage,
  # judge and rebase follow: an `mr` section whose review_agents is missing
  # or empty is a schema error, not a silently disabled review round. Off is
  # spelled by omitting the section, and that omission is the only thing
  # /wurk:mr skips on - silently, because a repo with no review agents is
  # not a repo with a gap.
  #
  # Shape only. Whether a declared name has a file behind it is a fact about
  # the filesystem, and validate! runs on every script's manifest load and
  # touches no disk (see validate_gate_cwd, and warn_local_mode_with_dolt_remote
  # for the same split), so that check lives in `manifest.rb check`.
  def validate_mr
    section = fetch("mr")
    return if section.nil?

    unless section.is_a?(Hash)
      errors << "#{path}: mr must be an object (see wurk docs/manifest.md)"
      return
    end

    agents = section["review_agents"]
    unless agents.is_a?(Array) && !agents.empty?
      errors << "#{path}: mr.review_agents must be a non-empty array of agent names " \
                "(omit the mr section entirely to run no pre-request review round)"
      return
    end

    agents.each { |name| validate_mr_review_agent(name) }
    validate_mr_review_agents_distinct(agents)
  end

  def validate_mr_review_agent(name)
    return if name.is_a?(String) && name.match?(MR_REVIEW_AGENT_RE)

    errors << "#{path}: mr.review_agents entry #{name.inspect} must be a bare agent name " \
              "(letters, digits, '.', '_', '-'; no leading '-' and no path separator) - it " \
              "resolves to .claude/agents/<name>.md"
  end

  # A repeated name would spawn the same agent twice in one round, which is
  # a second run and not a second opinion - and the round is deliberately
  # single (see the /wurk:mr step), so the duplicate buys nothing and costs
  # a full agent.
  def validate_mr_review_agents_distinct(agents)
    repeated = agents.select { |name| name.is_a?(String) }.tally.select { |_, count| count > 1 }.keys
    return if repeated.empty?

    errors << "#{path}: mr.review_agents lists #{repeated.join(', ')} more than once; a second " \
              "instance of the same agent is another run, not another opinion"
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
      elsif !RETIRED.key?(dotted)
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
      # The tracker-push gate, read by /wurk:mr and /wurk:cleanup. Both
      # fields, because "local because declared" and "local because nobody
      # said" are different sentences in those skills' reports.
      env.data[:beads_sync] = manifest.beads_sync
      env.data[:beads_sync_declared] = manifest.beads_sync_declared?

      # The pre-request review round, read by /wurk:mr: the names to spawn,
      # and empty when the consumer declares none.
      env.data[:mr_review_agents] = manifest.mr_review_agents

      warn_local_mode_with_dolt_remote(env, manifest)
      block_unresolved_review_agents(env, manifest)

      manifest.warnings.each { |w| env.warn(code: "unknown_key", message: w) }
      manifest.errors.each { |e| env.block!(code: "invalid", message: e) }

      env.emit(io)
    rescue JSON::ParserError => e
      env ||= Envelope.new(script: "manifest")
      env.block!(code: "unparseable", message: e.message)
      env.emit(io)
    end

    private

    # The footgun that produced beads.sync, checked directly: a repo whose
    # mode resolves to `local` but whose beads database still has a dolt
    # remote configured is one `bd dolt push` away from publishing a tracker
    # that was never meant to leave the machine - and in the incident behind
    # this key the remote was not in config.yaml at all, it was inside the
    # embedded dolt db, where a guard script deleting it from the yaml never
    # reached it.
    #
    # This lives in the lint and not in Manifest#validate! on purpose:
    # validate! is pure shape over the parsed JSON and touches no
    # filesystem (see validate_gate_cwd), and it runs on every script's
    # manifest load. This check reads two files outside the manifest and
    # answers a question about the environment, which is what a lint is for.
    #
    # A warning, never a block: the remote may be there for a legitimate
    # read-only reason (a periodic backup remote, a clone's leftovers), and
    # the actual guarantee is upstream of it - under `local` no skill issues
    # the push at all. This tells a human to go remove the loaded gun.
    def warn_local_mode_with_dolt_remote(env, manifest)
      return if manifest.beads_push_allowed?

      remotes = manifest.beads_dolt_remotes
      return if remotes.empty?

      env.warn(
        code: "beads_sync_local_with_dolt_remote",
        message: "#{manifest.path}: beads.sync resolves to local " \
                 "(#{manifest.beads_sync_declared? ? 'declared' : 'unset, defaulted'}) but this " \
                 "checkout's .beads has a dolt remote configured: #{remotes.join('; ')}. " \
                 "No wurk skill will push it, but any hand-run bd dolt push would. Remove the " \
                 "remote, or declare the mode that matches it."
      )
    end

    # Every declared review agent has to exist as a file, and this is the
    # only place that can say so: Manifest#validate! is pure shape over the
    # parsed JSON and never reads the disk (see validate_mr).
    #
    # A block rather than a warning, which is the other half of the split
    # from warn_local_mode_with_dolt_remote above. A stray dolt remote has a
    # legitimate reading and the real guarantee sits upstream of it; a name
    # with no agent behind it has no legitimate reading at all, and the
    # alternative to rejecting it here is discovering it in /wurk:mr after
    # the gate has already run, with the review round half-done.
    def block_unresolved_review_agents(env, manifest)
      missing = manifest.mr_review_agents_missing
      return if missing.empty?

      env.block!(
        code: "mr_review_agent_missing",
        message: "#{manifest.path}: mr.review_agents names #{missing.join(', ')}, which " \
                 "#{missing.one? ? 'does' : 'do'} not resolve to a file under .claude/agents/ " \
                 "in #{manifest.checkout_root}. Ship the agent, or drop the name."
      )
    end

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

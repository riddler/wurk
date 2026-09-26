# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../lib/fleet_manifest"
require_relative "support/home_guard"

# The fixture convention, as for test/fixtures/manifests/: every test loads
# a fleet manifest from test/fixtures/fleet_manifests/ by name, never a
# real one, and every fixture uses placeholder repo names (alpha, beta,
# gamma) so nothing here can be confused with a consumer fleet.
module FleetFixtures
  DIR = File.expand_path(File.join(__dir__, "fixtures", "fleet_manifests"))

  module_function

  def path(name)
    File.join(DIR, "#{name}.json")
  end

  def load(name)
    FleetManifest.new(path: path(name), raw: JSON.parse(File.read(path(name))))
  end

  def load_with(name, overrides)
    raw = deep_merge(JSON.parse(File.read(path(name))), overrides)
    FleetManifest.new(path: path(name), raw: raw)
  end

  def deep_merge(base, overrides)
    base.merge(overrides) do |_key, old, new|
      old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
    end
  end
end

class FleetManifestValidationTest < Minitest::Test
  def test_valid_fixture_has_no_errors_or_warnings
    m = FleetFixtures.load("valid")
    assert m.valid?, "expected the valid fixture to validate: #{m.errors.inspect}"
    assert_empty m.warnings
  end

  # sabotage: drop the non-empty check in validate_repos -> red
  def test_repos_is_required_and_non_empty
    m = FleetFixtures.load_with("valid", "repos" => [])
    refute m.valid?
    assert_match(/repos must be a non-empty array/, m.errors.join("\n"))
    assert_match(%r{docs/fleet-manifest\.md}, m.errors.join("\n"))

    m = FleetManifest.new(path: "x.json", raw: { "fleet" => "nameless" })
    refute m.valid?
    assert_match(/repos must be a non-empty array/, m.errors.join("\n"))
  end

  # A fleet of one, with the roster dir being the fleet root itself, is the
  # single-repo project that wants the campaign-state keys.
  def test_minimal_fixture_is_a_fleet_of_one
    m = FleetFixtures.load("minimal")
    assert m.valid?, m.errors.inspect
    assert_empty m.warnings
    assert_equal ["."], m.repo_dirs
    assert_equal [], m.packages
    assert_equal [], m.topological_order
  end

  # sabotage: skip the "_"-prefix check in collect_unknown_keys -> red
  def test_annotation_keys_never_warn
    m = FleetFixtures.load("valid")
    assert_empty m.warnings
    assert_includes m.raw.keys, "_note"
    assert_includes m.raw["dependsOn"].keys, "_note"
    assert_includes m.raw["multiCampaign"].keys, "_machineGateSlots_note"
  end

  # sabotage: make an unknown key an error, or drop the warning -> red
  def test_unknown_keys_warn_at_every_level_and_never_block
    m = FleetFixtures.load("unknown_key")
    assert m.valid?, m.errors.inspect
    joined = m.warnings.join("\n")
    assert_match(/unknown key repos\[0\]\.group \(ignored\)/, joined)
    assert_match(/unknown key campaignState\.journalFile \(ignored\)/, joined)
    assert_match(/unknown key firewallScan \(ignored\)/, joined)
    assert_equal 3, m.warnings.length
  end

  # sabotage: add "policy" or "stacking" to KNOWN with a closed key list ->
  # red. Both blocks are relayed verbatim into dispatches, so a key the kit
  # does not know is not ignored and must not be reported as such.
  def test_policy_and_stacking_are_free_form
    m = FleetFixtures.load("valid")
    assert_equal "relayed verbatim to every worker; never interpreted by the kit", m.raw["policy"]["customRule"]
    assert_equal "operator, 2026-01-01", m.raw["stacking"]["decision"]
    assert_empty m.warnings
  end

  # sabotage: drop OBJECT_SECTIONS or the is_a?(Hash) check -> red
  def test_sections_must_be_objects
    %w[dependsOn ownership policy depOverride campaignState multiCampaign stacking].each do |key|
      m = FleetFixtures.load_with("valid", key => "nope")
      refute m.valid?, "#{key} as a string should block"
      assert_match(/#{key} must be an object/, m.errors.join("\n"))
    end
  end

  # sabotage: drop the dir shape checks in validate_repo_entry -> red
  def test_repo_dir_must_be_a_relative_path_under_the_fleet_root
    m = FleetFixtures.load_with("valid", "repos" => [{ "dir" => "" }])
    assert_match(/repos\[0\]\.dir must be a non-empty relative path/, m.errors.join("\n"))

    m = FleetFixtures.load_with("valid", "repos" => [{ "dir" => "/abs/alpha" }])
    assert_match(/repos\[0\]\.dir must be relative to the fleet root/, m.errors.join("\n"))

    m = FleetFixtures.load_with("valid", "repos" => [{ "dir" => "../alpha" }])
    assert_match(/repos\[0\]\.dir must stay under the fleet root/, m.errors.join("\n"))

    m = FleetFixtures.load_with("valid", "repos" => ["alpha"])
    assert_match(/repos\[0\] must be an object/, m.errors.join("\n"))
  end

  # sabotage: drop the string check on package/beadsPrefix/note -> red
  def test_repo_optional_strings_must_be_non_empty_when_present
    m = FleetFixtures.load_with("valid", "repos" => [{ "dir" => "alpha", "package" => "", "beadsPrefix" => 7 }])
    joined = m.errors.join("\n")
    assert_match(/repos\[0\]\.package must be a non-empty string when present/, joined)
    assert_match(/repos\[0\]\.beadsPrefix must be a non-empty string when present/, joined)
  end

  # sabotage: drop any one of the three validate_repos_distinct calls -> red
  def test_repo_dirs_packages_and_prefixes_are_distinct
    dup = [{ "dir" => "alpha", "package" => "alpha", "beadsPrefix" => "aa" },
           { "dir" => "alpha", "package" => "alpha", "beadsPrefix" => "aa" }]
    m = FleetFixtures.load_with("valid", "repos" => dup, "dependsOn" => {}, "ownership" => {})
    joined = m.errors.join("\n")
    assert_match(/repos\[\]\.dir "alpha" listed more than once/, joined)
    assert_match(/repos\[\]\.package "alpha" listed more than once/, joined)
    assert_match(/repos\[\]\.beadsPrefix "aa" listed more than once/, joined)
  end

  # sabotage: drop the roster membership check on keys or values -> red
  def test_depends_on_names_only_roster_packages
    m = FleetFixtures.load_with("valid", "dependsOn" => { "alpha" => ["delta"], "epsilon" => [] })
    joined = m.errors.join("\n")
    assert_match(/dependsOn\.alpha names "delta", which is not a repos\[\]\.package/, joined)
    assert_match(/dependsOn\.epsilon is not a repos\[\]\.package/, joined)

    m = FleetFixtures.load_with("valid", "dependsOn" => { "alpha" => "beta" })
    assert_match(/dependsOn\.alpha must be an array of package names/, m.errors.join("\n"))

    m = FleetFixtures.load_with("valid", "dependsOn" => { "alpha" => ["alpha"] })
    assert_match(/dependsOn\.alpha depends on itself/, m.errors.join("\n"))
  end

  # sabotage: drop the cycle check, or make topological_order return a
  # partial order on a cycle instead of nil -> red
  def test_depends_on_cycle_blocks
    m = FleetFixtures.load("bad_edges")
    refute m.valid?
    assert_match(/dependsOn has a cycle/, m.errors.join("\n"))
    assert_nil m.topological_order
  end

  # sabotage: reverse the visit order, or emit roster-only packages before
  # the ordered ones -> red
  def test_topological_order_puts_dependencies_first
    m = FleetFixtures.load("valid")
    order = m.topological_order
    assert_equal %w[alpha beta gamma], order

    m = FleetFixtures.load_with("valid", "dependsOn" => { "gamma" => ["alpha"] })
    order = m.topological_order
    assert order.index("alpha") < order.index("gamma")
    assert_includes order, "beta"
  end

  # sabotage: drop the roster membership check in validate_ownership -> red
  def test_ownership_values_name_roster_dirs
    m = FleetFixtures.load_with("valid", "ownership" => { "parser" => "delta", "runtime" => 3 })
    joined = m.errors.join("\n")
    assert_match(/ownership\.parser names "delta", which is not a repos\[\]\.dir/, joined)
    assert_match(/ownership\.runtime must be a repos\[\]\.dir string/, joined)
  end

  # sabotage: drop policy.stalenessMinutes or multiCampaign.machineGateSlots
  # from POSITIVE_INTEGER_FIELDS -> red
  def test_integer_fields_must_be_positive_integers
    [["policy", "stalenessMinutes"], ["multiCampaign", "machineGateSlots"]].each do |section, key|
      [0, -1, 1.5, "2", true].each do |bad|
        m = FleetFixtures.load_with("valid", section => { key => bad })
        refute m.valid?, "#{section}.#{key} = #{bad.inspect} should block"
        assert_match(/#{section}\.#{key} must be a positive integer/, m.errors.join("\n"))
      end
    end
  end

  # sabotage: drop the leading-slash check in validate_paths -> red
  def test_path_fields_must_be_relative_and_non_empty
    m = FleetFixtures.load_with("valid", "depOverride" => { "ledger" => "/abs/ledger.json" })
    assert_match(/depOverride\.ledger must be relative to the fleet root/, m.errors.join("\n"))

    m = FleetFixtures.load_with("valid", "multiCampaign" => { "locksDir" => "" })
    assert_match(/multiCampaign\.locksDir must be a non-empty fleet-root-relative path/, m.errors.join("\n"))

    m = FleetFixtures.load_with("valid", "campaignState" => { "reports" => 4 })
    assert_match(/campaignState\.reports must be a non-empty fleet-root-relative path/, m.errors.join("\n"))
  end

  # sabotage: drop a field from STRING_FIELDS -> red
  def test_string_fields_must_be_non_empty_strings
    m = FleetFixtures.load_with("valid", "fleet" => "", "stacking" => { "sameRepo" => 1 })
    joined = m.errors.join("\n")
    assert_match(/fleet must be a non-empty string/, joined)
    assert_match(/stacking\.sameRepo must be a non-empty string/, joined)
  end

# wu-05f9: a consumer whose arming writes more than the plan Status line
# names its own arm script here (riddler-84). sabotage: drop armCommand
# from KNOWN["campaignState"] or from STRING_FIELDS -> red
def test_campaign_state_arm_command_is_a_known_non_blank_string
  m = FleetFixtures.load_with("valid", "campaignState" => { "armCommand" => "ruby .claude/fleet/bin/campaign-arm.rb" })
  assert_empty m.errors
  assert_empty m.warnings
  assert_equal "ruby .claude/fleet/bin/campaign-arm.rb", m.arm_command

  assert_nil FleetFixtures.load("valid").arm_command

  m = FleetFixtures.load_with("valid", "campaignState" => { "armCommand" => 7 })
  assert_match(/campaignState\.armCommand must be a non-empty string/, m.errors.join("\n"))
  m = FleetFixtures.load_with("valid", "campaignState" => { "armCommand" => " " })
  assert_match(/campaignState\.armCommand must be a non-empty string/, m.errors.join("\n"))
end

  # sabotage: drop validate_dep_override -> red
  def test_dep_override_requires_a_ledger
    m = FleetFixtures.load_with("valid", "depOverride" => { "localStage" => "x", "pushedStage" => "y" })
    assert m.valid?, m.errors.inspect # deep_merge keeps the fixture's ledger

    m = FleetManifest.new(path: "x.json", raw: { "repos" => [{ "dir" => "." }], "depOverride" => { "localStage" => "x" } })
    refute m.valid?
    assert_match(/depOverride\.ledger is required when the depOverride section is present/, m.errors.join("\n"))
  end

  # sabotage: accept a shell string for landingCheck -> red
  def test_landing_check_is_an_argv_array
    m = FleetFixtures.load_with("valid", "landingCheck" => "make deps-sort")
    assert_match(/landingCheck must be an argv array of strings/, m.errors.join("\n"))
    assert_nil m.landing_check

    m = FleetFixtures.load("valid")
    assert_equal %w[make deps-sort], m.landing_check
  end

  # sabotage: return errors for a non-object root instead of blocking -> red
  def test_non_object_root_blocks
    m = FleetManifest.new(path: "x.json", raw: [1, 2])
    refute m.valid?
    assert_match(/must be a JSON object/, m.errors.join("\n"))
  end
end

class FleetManifestResolvedValuesTest < Minitest::Test
  # sabotage: change any of the three defaults, or derive journal from a
  # fixed path instead of the campaigns dir -> red
  def test_defaults_when_no_campaign_state_is_declared
    m = FleetFixtures.load("minimal")
    assert_equal 50, m.staleness_minutes
    assert_nil m.machine_gate_slots
    assert_equal ".claude/campaigns", m.campaigns_dir
    assert_equal ".claude/campaigns/journal", m.journal_dir
    assert_equal ".claude/campaigns/reports/<campaign-id>", m.reports_dir
    assert_equal ".claude/campaigns/locks", m.locks_dir
    assert_nil m.registry
    assert_nil m.ledger
    assert_nil m.landing_check
  end

  # sabotage: derive journal_dir from the default instead of campaigns_dir
  # when only dir is declared -> red
  def test_journal_and_locks_follow_a_declared_campaigns_dir
    m = FleetFixtures.load_with("minimal", "campaignState" => { "dir" => "state/campaigns" })
    assert_equal "state/campaigns/journal", m.journal_dir
    assert_equal "state/campaigns/reports/<campaign-id>", m.reports_dir
    assert_equal "state/campaigns/locks", m.locks_dir
  end

  def test_declared_values_win
    m = FleetFixtures.load("valid")
    assert_equal 40, m.staleness_minutes
    assert_equal 2, m.machine_gate_slots
    assert_equal ".claude/fleet/campaigns", m.campaigns_dir
    assert_equal ".claude/fleet/journal", m.journal_dir
    assert_equal ".claude/fleet/reports", m.reports_dir
    assert_equal ".claude/fleet/locks", m.locks_dir
    assert_equal ".claude/fleet/campaigns/ACTIVE.md", m.registry
    assert_equal ".claude/fleet/linkage-ledger.json", m.ledger
  end

  # sabotage: return the raw hash including the "_note" key -> red
  def test_depends_on_and_ownership_drop_annotations
    m = FleetFixtures.load("valid")
    assert_equal({ "alpha" => [], "beta" => ["alpha"], "gamma" => %w[beta alpha] }, m.depends_on)
    assert_equal({ "parser" => "alpha", "runtime" => "beta", "example-host" => "gamma-app" }, m.ownership)
  end

  def test_repos_carries_the_four_known_keys
    m = FleetFixtures.load("valid")
    assert_equal 3, m.repos.length
    assert_equal({ "dir" => "beta", "package" => "beta", "beadsPrefix" => "bb", "note" => nil }, m.repos[1])
    assert_equal %w[alpha beta gamma-app], m.repo_dirs
    assert_equal %w[alpha beta gamma], m.packages
  end

  # sabotage: make fleet_root the manifest's own directory -> red
  def test_fleet_root_is_two_levels_above_the_manifest
    m = FleetManifest.new(path: "/fleet/.claude/wurk-fleet.json", raw: { "repos" => [{ "dir" => "a" }] })
    assert_equal "/fleet", m.fleet_root
  end
end

class FleetManifestResolutionTest < Minitest::Test
  def teardown
    FleetManifest.reset!
  end

  # sabotage: stop the walk at the start dir -> red
  def test_locate_walks_up_from_a_subdirectory
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".claude"))
      FileUtils.cp(FleetFixtures.path("valid"), File.join(dir, ".claude", "wurk-fleet.json"))
      nested = File.join(dir, "alpha", "lib")
      FileUtils.mkdir_p(nested)
      assert_equal File.join(dir, ".claude", "wurk-fleet.json"), FleetManifest.locate(start: nested)
    end
  end

  # sabotage: fall back to some other directory instead of nil -> red
  def test_locate_returns_nil_when_nothing_is_found
    Dir.mktmpdir do |dir|
      assert_nil FleetManifest.locate(start: dir)
    end
  end

  # sabotage: swallow NotFound in require! without blocking -> red
  def test_require_blocks_when_absent
    Dir.mktmpdir do |dir|
      env = Envelope.new(script: "t")
      assert_nil FleetManifest.require!(env, start: dir)
      assert_equal ["fleet_manifest_unavailable"], env.blocked.map { |b| b[:code] }
    end
  end

  # sabotage: return the manifest from require! even when invalid -> red
  def test_require_blocks_on_an_invalid_manifest_and_warns_on_unknown_keys
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".claude"))
      FileUtils.cp(FleetFixtures.path("bad_edges"), File.join(dir, ".claude", "wurk-fleet.json"))
      env = Envelope.new(script: "t")
      assert_nil FleetManifest.require!(env, start: dir)
      assert_includes env.blocked.map { |b| b[:code] }, "fleet_manifest_invalid"
    end

    FleetManifest.reset!
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".claude"))
      FileUtils.cp(FleetFixtures.path("unknown_key"), File.join(dir, ".claude", "wurk-fleet.json"))
      env = Envelope.new(script: "t")
      refute_nil FleetManifest.require!(env, start: dir)
      assert_empty env.blocked
      assert_equal %w[fleet_manifest_unknown_key] * 3, env.warnings.map { |w| w[:code] }
    end
  end
end

class FleetManifestCliTest < Minitest::Test
  def run_check(*args)
    io = StringIO.new
    code = FleetManifestCli.run(["check", *args], io: io)
    [code, JSON.parse(io.string)]
  end

  # sabotage: drop any data key -> red
  def test_check_reports_resolved_values_for_a_valid_manifest
    code, out = run_check("--file", FleetFixtures.path("valid"))
    assert_equal 0, code
    assert out["ok"]
    data = out["data"]
    assert data["valid"]
    assert_equal FleetFixtures.path("valid"), data["path"]
    assert_equal File.expand_path(File.join(FleetFixtures::DIR, "..")), data["fleet_root"]
    assert_equal %w[alpha beta gamma], data["topological_order"]
    assert_equal 40, data["staleness_minutes"]
    assert_equal 2, data["machine_gate_slots"]
    assert_equal ".claude/fleet/journal", data["journal_dir"]
    assert_equal ".claude/fleet/reports", data["reports_dir"]
    assert_nil data["arm_command"]
    assert_equal ".claude/fleet/locks", data["locks_dir"]
    assert_equal ".claude/fleet/campaigns/ACTIVE.md", data["registry"]
    assert_equal ".claude/fleet/linkage-ledger.json", data["ledger"]
    assert_equal %w[make deps-sort], data["landing_check"]
    assert_equal 3, data["repos"].length
    assert_equal({ "parser" => "alpha", "runtime" => "beta", "example-host" => "gamma-app" }, data["ownership"])
  end

  # The valid fixture's roster dirs do not exist beside the fixture file,
  # so the lint's filesystem check fires. sabotage: make it a block -> red
  def test_check_warns_on_roster_dirs_missing_under_the_fleet_root
    code, out = run_check("--file", FleetFixtures.path("valid"))
    assert_equal 0, code
    warning = out["warnings"].find { |w| w["code"] == "fleet_repo_dir_missing" }
    refute_nil warning
    assert_match(/"alpha", "beta", "gamma-app" not found under/, warning["message"])
  end

  # sabotage: fail the exit code on an unknown-key warning -> red
  def test_check_exits_zero_on_unknown_keys
    code, out = run_check("--file", FleetFixtures.path("unknown_key"))
    assert_equal 0, code
    assert out["ok"]
    assert_equal 3, out["warnings"].count { |w| w["code"] == "unknown_key" }
  end

  # sabotage: exit 0 on an invalid manifest -> red
  def test_check_exits_one_on_an_invalid_manifest
    code, out = run_check("--file", FleetFixtures.path("bad_edges"))
    assert_equal 1, code
    refute out["ok"]
    refute out["data"]["valid"]
    assert_nil out["data"]["topological_order"]
    assert_match(/dependsOn has a cycle/, out["blocked"].map { |b| b["message"] }.join("\n"))
  end

  def test_check_blocks_unparseable_and_missing_files
    code, out = run_check("--file", FleetFixtures.path("malformed"))
    assert_equal 1, code
    assert_equal ["unparseable"], out["blocked"].map { |b| b["code"] }

    code, out = run_check("--file", File.join(FleetFixtures::DIR, "nope.json"))
    assert_equal 1, code
    assert_equal ["fleet_manifest_unavailable"], out["blocked"].map { |b| b["code"] }
  end

  # sabotage: compare against the roster prefix instead of the repo's own
  # manifest, or drop the block -> red. The fleet root here is a tmpdir
  # with one repo cloned whose wurk.json disagrees with the roster.
  def test_check_blocks_a_roster_prefix_that_disagrees_with_the_repo_manifest
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".claude"))
      FileUtils.mkdir_p(File.join(dir, "alpha", ".claude"))
      FileUtils.mkdir_p(File.join(dir, "beta", ".claude"))
      File.write(File.join(dir, ".claude", "wurk-fleet.json"), JSON.generate(
        "repos" => [{ "dir" => "alpha", "beadsPrefix" => "aa" }, { "dir" => "beta", "beadsPrefix" => "bb" }]
      ))
      File.write(File.join(dir, "alpha", ".claude", "wurk.json"), JSON.generate("beads" => { "prefix" => "zz" }))
      File.write(File.join(dir, "beta", ".claude", "wurk.json"), JSON.generate("beads" => { "prefix" => "bb" }))

      code, out = run_check("--file", File.join(dir, ".claude", "wurk-fleet.json"))
      assert_equal 1, code
      blocked = out["blocked"].select { |b| b["code"] == "fleet_beads_prefix_mismatch" }
      assert_equal 1, blocked.length
      assert_match(/"alpha" is "aa", but that repo's .claude\/wurk\.json declares beads\.prefix "zz"/,
                   blocked.first["message"])
      assert_empty out["warnings"].select { |w| w["code"] == "fleet_repo_dir_missing" }
    end
  end

  # A repo with no wurk.json (or an unparseable one) is that repo's own
  # lint's business. sabotage: block on a missing repo manifest -> red
  def test_check_ignores_repos_without_a_readable_manifest
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".claude"))
      FileUtils.mkdir_p(File.join(dir, "alpha", ".claude"))
      FileUtils.mkdir_p(File.join(dir, "beta"))
      File.write(File.join(dir, ".claude", "wurk-fleet.json"), JSON.generate(
        "repos" => [{ "dir" => "alpha", "beadsPrefix" => "aa" }, { "dir" => "beta", "beadsPrefix" => "bb" }]
      ))
      File.write(File.join(dir, "alpha", ".claude", "wurk.json"), "{ not json")

      code, out = run_check("--file", File.join(dir, ".claude", "wurk-fleet.json"))
      assert_equal 0, code, out.inspect
      assert_empty out["blocked"]
    end
  end

  # sabotage: stop locating from the working directory -> red
  def test_check_locates_the_manifest_by_walking_up
    FleetManifest.reset!
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".claude"))
      FileUtils.cp(FleetFixtures.path("minimal"), File.join(dir, ".claude", "wurk-fleet.json"))
      nested = File.join(dir, "deep", "er")
      FileUtils.mkdir_p(nested)
      Dir.chdir(nested) do
        code, out = run_check
        assert_equal 0, code, out.inspect
        assert_equal File.join(File.realpath(dir), ".claude", "wurk-fleet.json"), out["data"]["path"]
      end
    end
  ensure
    FleetManifest.reset!
  end
end

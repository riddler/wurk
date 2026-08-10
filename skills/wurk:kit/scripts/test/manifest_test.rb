# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../lib/manifest"
require_relative "support/fake_sh"

# The fixture-manifest convention (see .claude/scripts/README.md): every test
# that needs a manifest loads one from test/fixtures/manifests/ by name,
# never the repo's real .claude/wurk.json. A test asserting against the real
# manifest would go red the day this repo legitimately changes a value, which
# is the opposite of what these tests are for.
module ManifestFixtures
  DIR = File.expand_path(File.join(__dir__, "fixtures", "manifests"))

  module_function

  def path(name)
    File.join(DIR, "#{name}.json")
  end

  def load(name)
    Manifest.new(path: path(name), raw: JSON.parse(File.read(path(name))))
  end

  # A one-off manifest from the named fixture with `overrides` deep-merged
  # in, for a test that needs one field different and nothing else.
  def load_with(name, overrides)
    raw = deep_merge(JSON.parse(File.read(path(name))), overrides)
    Manifest.new(path: path(name), raw: raw)
  end

  def deep_merge(base, overrides)
    base.merge(overrides) do |_key, old, new|
      old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
    end
  end
end

class ManifestValidationTest < Minitest::Test
  def test_valid_fixture_has_no_errors_or_warnings
    m = ManifestFixtures.load("valid")
    assert m.valid?, "expected the valid fixture to validate: #{m.errors.inspect}"
    assert_empty m.warnings
  end

  # sabotage: drop the REQUIRED entry for beads.prefix -> red
  def test_missing_required_key_blocks_and_names_the_field
    m = ManifestFixtures.load("missing_required")
    refute m.valid?
    assert_match(/missing required key beads\.prefix/, m.errors.join("\n"))
    assert_match(/docs\/manifest\.md/, m.errors.join("\n"))
  end

  # sabotage: make validate_enums fall back to a default instead of erroring -> red
  def test_unknown_enum_value_blocks_rather_than_defaulting
    m = ManifestFixtures.load("bad_enum")
    refute m.valid?
    assert_match(/forge\.kind is "bitbucket"; expected one of github, gitlab/, m.errors.join("\n"))
  end

  # sabotage: move unknown keys from warnings to errors -> red
  def test_unknown_keys_warn_and_do_not_invalidate
    m = ManifestFixtures.load("unknown_key")
    assert m.valid?, "an unknown key must not invalidate the manifest: #{m.errors.inspect}"
    joined = m.warnings.join("\n")
    assert_match(/unknown key beads\.froth/, joined)
    assert_match(/unknown key unheard_of/, joined)
  end

  # sabotage: accept any schema version -> red
  def test_wrong_schema_version_blocks
    m = ManifestFixtures.load("wrong_version")
    refute m.valid?
    assert_match(/wurk is 2, but this kit implements schema version 1/, m.errors.join("\n"))
  end

  # sabotage: let argv() split a shell string on whitespace -> red
  def test_shell_string_command_blocks
    m = ManifestFixtures.load("shell_string_command")
    refute m.valid?
    assert_match(/gate\.full must be an argv array of strings/, m.errors.join("\n"))
  end

  # sabotage: drop the is_a?(Array) check in validate_regex_lists -> red
  def test_non_array_project_level_skips_blocks_naming_the_field
    m = ManifestFixtures.load_with("valid", "gate" => { "project_level_skips" => "not installed" })
    refute m.valid?
    assert_match(/gate\.project_level_skips must be a list of regex source strings/, m.errors.join("\n"))
  end

  # sabotage: stop rescuing RegexpError in validate_regex_lists -> red
  def test_uncompilable_project_level_skip_blocks_naming_the_entry
    m = ManifestFixtures.load_with("valid", "gate" => { "project_level_skips" => ["not installed", "["] })
    refute m.valid?
    assert_match(/gate\.project_level_skips entry "\[" is not a valid regular expression/, m.errors.join("\n"))
  end

  # sabotage: drop gate.not_applicable_skips from REGEX_LIST_FIELDS -> red
  def test_non_array_not_applicable_skips_blocks_naming_the_field
    m = ManifestFixtures.load_with("valid", "gate" => { "not_applicable_skips" => "no .po files" })
    refute m.valid?
    assert_match(/gate\.not_applicable_skips must be a list of regex source strings/, m.errors.join("\n"))
  end

  # sabotage: drop gate.not_applicable_skips from REGEX_LIST_FIELDS -> red
  def test_uncompilable_not_applicable_skip_blocks_naming_the_entry
    m = ManifestFixtures.load_with("valid", "gate" => { "not_applicable_skips" => ["no .po files", "["] })
    refute m.valid?
    assert_match(/gate\.not_applicable_skips entry "\[" is not a valid regular expression/, m.errors.join("\n"))
  end

  # sabotage: drop the roots check in validate_sabotage -> red
  def test_sabotage_missing_test_roots_blocks
    m = ManifestFixtures.load_with(
      "valid",
      "gate" => { "sabotage" => { "test_pattern" => "\\btest\\s+\"" } }
    )
    refute m.valid?
    assert_match(/gate\.sabotage\.test_roots must be a non-empty list of path prefixes/, m.errors.join("\n"))
  end

  # sabotage: drop the pattern check in validate_sabotage -> red
  def test_sabotage_missing_test_pattern_blocks
    m = ManifestFixtures.load_with(
      "valid",
      "gate" => { "sabotage" => { "test_roots" => ["test/"] } }
    )
    refute m.valid?
    assert_match(/gate\.sabotage\.test_pattern must be a regex source string/, m.errors.join("\n"))
  end

  # sabotage: stop rescuing RegexpError for test_pattern in validate_sabotage
  # -> red
  def test_sabotage_uncompilable_test_pattern_blocks
    m = ManifestFixtures.load_with(
      "valid",
      "gate" => { "sabotage" => { "test_roots" => ["test/"], "test_pattern" => "[" } }
    )
    refute m.valid?
    assert_match(/gate\.sabotage\.test_pattern is not a valid regular expression/, m.errors.join("\n"))
  end

  # sabotage: drop the is_a?(Array) check on exempt_prefixes -> red
  def test_sabotage_non_array_exempt_prefixes_blocks
    m = ManifestFixtures.load_with(
      "valid",
      "gate" => {
        "sabotage" => { "test_roots" => ["test/"], "test_pattern" => "\\btest\\s+\"", "exempt_prefixes" => "test/scion_tests/" }
      }
    )
    refute m.valid?
    assert_match(/gate\.sabotage\.exempt_prefixes must be a list of path prefixes/, m.errors.join("\n"))
  end

  def test_sabotage_fully_declared_section_validates
    m = ManifestFixtures.load_with(
      "valid",
      "gate" => {
        "sabotage" => {
          "test_roots" => ["test/"],
          "test_pattern" => "\\btest\\s+\"",
          "exempt_prefixes" => ["test/scion_tests/"]
        }
      }
    )
    assert m.valid?, "expected a fully-declared gate.sabotage section to validate: #{m.errors.inspect}"
  end

  def test_judge_fixture_validates
    m = ManifestFixtures.load("judge")
    assert m.valid?, "expected the judge fixture to validate: #{m.errors.inspect}"
  end

  # sabotage: drop the section-must-be-an-object check in validate_judge -> red
  def test_judge_non_object_section_blocks
    m = ManifestFixtures.load_with("valid", "judge" => "on")
    refute m.valid?
    assert_match(/judge must be an object/, m.errors.join("\n"))
  end

  # sabotage: drop the empty-registry check in validate_judge -> red
  def test_judge_empty_registry_blocks
    m = ManifestFixtures.load_with("valid", "judge" => { "registry" => [] })
    refute m.valid?
    assert_match(/judge\.registry must be a non-empty array of objects/, m.errors.join("\n"))
  end

  # sabotage: drop the missing-registry check in validate_judge -> red
  def test_judge_missing_registry_blocks
    m = ManifestFixtures.load_with("valid", "judge" => { "model" => "sonnet" })
    refute m.valid?
    assert_match(/judge\.registry must be a non-empty array of objects/, m.errors.join("\n"))
  end

  # sabotage: drop any per-field check in validate_judge_entry -> red
  def test_judge_entry_missing_required_field_blocks_naming_it
    %w[key label scope_prefix text focus].each do |field|
      entry = {
        "key" => "rule-one",
        "label" => "RULE-ONE",
        "scope_prefix" => "docs/rules/",
        "text" => "docs/rules/rule-one.md",
        "focus" => "a fake focus string"
      }
      entry.delete(field)

      m = ManifestFixtures.load_with("valid", "judge" => { "registry" => [entry] })
      refute m.valid?, "expected a registry entry missing #{field} to block"
      assert_match(/judge\.registry entry missing #{field}/, m.errors.join("\n"))
    end
  end

  # sabotage: drop the scope_suffix type check in validate_judge_entry -> red
  def test_judge_entry_non_string_scope_suffix_blocks
    entry = {
      "key" => "rule-one",
      "label" => "RULE-ONE",
      "scope_prefix" => "docs/rules/",
      "scope_suffix" => 1,
      "text" => "docs/rules/rule-one.md",
      "focus" => "a fake focus string"
    }
    m = ManifestFixtures.load_with("valid", "judge" => { "registry" => [entry] })
    refute m.valid?
    assert_match(/judge\.registry entry scope_suffix must be a string/, m.errors.join("\n"))
  end

  # sabotage: drop the judge.model type check in validate_judge -> red
  def test_judge_empty_model_blocks
    entry = {
      "key" => "rule-one",
      "label" => "RULE-ONE",
      "scope_prefix" => "docs/rules/",
      "text" => "docs/rules/rule-one.md",
      "focus" => "a fake focus string"
    }
    m = ManifestFixtures.load_with("valid", "judge" => { "model" => "", "registry" => [entry] })
    refute m.valid?
    assert_match(/judge\.model must be a non-empty string/, m.errors.join("\n"))
  end

  # sabotage: drop the DEFAULT_BRANCH_RE type check, accept a non-string -> red
  def test_default_branch_non_string_blocks
    m = ManifestFixtures.load_with("valid", "repo" => { "default_branch" => 3 })
    refute m.valid?
    assert_match(/repo\.default_branch must be a git branch name/, m.errors.join("\n"))
  end

  # sabotage: let DEFAULT_BRANCH_RE match the empty string -> red
  def test_default_branch_empty_string_blocks
    m = ManifestFixtures.load_with("valid", "repo" => { "default_branch" => "" })
    refute m.valid?
    assert_match(/repo\.default_branch must be a git branch name/, m.errors.join("\n"))
  end

  # sabotage: drop the leading-character class from DEFAULT_BRANCH_RE, letting
  # a leading "-" through -> red
  def test_default_branch_leading_dash_blocks
    m = ManifestFixtures.load_with("valid", "repo" => { "default_branch" => "--upload-pack=x" })
    refute m.valid?
    assert_match(/repo\.default_branch must be a git branch name/, m.errors.join("\n"))
  end

  # sabotage: drop the explicit ".." check in validate_default_branch -> red
  def test_default_branch_double_dot_blocks
    m = ManifestFixtures.load_with("valid", "repo" => { "default_branch" => "main..evil" })
    refute m.valid?
    assert_match(/repo\.default_branch must be a git branch name/, m.errors.join("\n"))
  end

  # sabotage: let DEFAULT_BRANCH_RE accept whitespace -> red
  def test_default_branch_whitespace_blocks
    m = ManifestFixtures.load_with("valid", "repo" => { "default_branch" => "ma in" })
    refute m.valid?
    assert_match(/repo\.default_branch must be a git branch name/, m.errors.join("\n"))
  end

  # sabotage: forget to add "repo" to KNOWN["repo"] (or KNOWN[nil]) -> red,
  # since an unrecognized-section key would then be silently unvalidated
  # rather than warned on
  def test_unknown_key_under_repo_warns
    m = ManifestFixtures.load_with("valid", "repo" => { "default_branch" => "main", "bogus" => 1 })
    assert m.valid?, "an unknown key must not invalidate the manifest: #{m.errors.inspect}"
    assert_match(/unknown key repo\.bogus/, m.warnings.join("\n"))
  end
end

class ManifestAccessorTest < Minitest::Test
  def setup
    @m = ManifestFixtures.load("valid")
  end

  # sabotage: build the pattern from a literal "st" -> red
  def test_bead_id_pattern_is_built_from_the_prefix
    assert_match @m.bead_id_pattern, "zz-abc"
    assert_match @m.bead_id_pattern, "zz-00p.3"
    refute_match(/\A#{@m.bead_id_pattern}\z/, "st-abc")
  end

  def test_argv_accessors_return_arrays
    assert_equal %w[make check], @m.gate_full
    assert_equal %w[make quick], @m.gate_loop
  end

  # sabotage: return [] instead of nil for an absent optional command -> red
  def test_absent_optional_commands_are_nil_not_empty
    assert_nil @m.gate_report
    assert_nil @m.gate_attest
    assert_nil @m.trust_argv
  end

  # sabotage: drop a DEFAULTS entry -> red
  def test_documented_defaults_fill_in_for_absent_optional_keys
    assert_equal "beads", @m.topology
    assert_equal "s-form", @m.commit_style
    assert_equal 50, @m.subject_under
    assert_equal 72, @m.body_line_max
    assert_equal 40, @m.total_lines_max
    assert_equal "opus", @m.direction_model
  end

  def test_absent_tmux_section_reports_no_tmux_integration
    refute @m.tmux?
    assert_nil @m.tmux_session
  end

  # sabotage: return a match-anything regex instead of nil when the key is
  # absent -> red
  def test_project_level_skip_re_is_nil_when_absent
    assert_nil @m.project_level_skip_re
  end

  # sabotage: return a match-anything regex instead of nil when the key is
  # absent -> red
  def test_not_applicable_skip_re_is_nil_when_absent
    assert_nil @m.not_applicable_skip_re
  end

  # sabotage: drop gate.not_applicable_skips from REGEX_LIST_FIELDS -> red
  def test_not_applicable_skip_re_matches_a_declared_source_when_present
    m = ManifestFixtures.load_with("valid", "gate" => { "not_applicable_skips" => ["no \\.po files"] })
    assert_instance_of Regexp, m.not_applicable_skip_re
    assert_match m.not_applicable_skip_re, "no .po files found"
  end

  # sabotage: make sabotage? return true when the section is absent -> red
  def test_sabotage_defaults_to_off_with_empty_prefixes
    refute @m.sabotage?
    assert_equal [], @m.sabotage_test_roots
    assert_nil @m.sabotage_test_pattern
    assert_equal [], @m.sabotage_exempt_prefixes
  end

  # sabotage: make judge? return true when the section is absent -> red
  def test_judge_absent_leaves_judge_false_and_registry_empty
    refute @m.judge?
    assert_equal [], @m.judge_registry
  end

  # sabotage: drop the judge.model DEFAULTS entry -> red
  def test_judge_model_defaults_to_sonnet_when_unset
    assert_equal "sonnet", @m.judge_model
  end

  # sabotage: drop the "repo.default_branch" => "main" DEFAULTS entry -> red
  def test_default_branch_defaults_to_main_when_section_absent
    assert_equal "main", @m.default_branch
  end

  # sabotage: make fetch skip the DEFAULTS fallback for an explicit null -> red
  def test_default_branch_defaults_to_main_when_explicitly_null
    m = ManifestFixtures.load_with("valid", "repo" => { "default_branch" => nil })
    assert_equal "main", m.default_branch
  end

  # sabotage: read "repo.branch" or some other key instead of
  # "repo.default_branch" -> red
  def test_default_branch_reads_the_declared_value
    m = ManifestFixtures.load_with("valid", "repo" => { "default_branch" => "trunk" })
    assert_equal "trunk", m.default_branch
  end

  # sabotage: hardcode "origin/main" instead of interpolating default_branch -> red
  def test_remote_default_branch_composes_origin_and_the_default_branch
    m = ManifestFixtures.load_with("valid", "repo" => { "default_branch" => "trunk" })
    assert_equal "origin/trunk", m.remote_default_branch
  end

  def test_judge_fixture_exposes_typed_registry_values
    m = ManifestFixtures.load("judge")
    assert m.judge?
    assert_equal "faketool-model", m.judge_model

    registry = m.judge_registry
    assert_equal 1, registry.length

    entry = registry.first
    assert_equal "rule-one", entry["key"]
    assert_equal "RULE-ONE", entry["label"]
    assert_equal "docs/rules/", entry["scope_prefix"]
    assert_equal "RULE.md", entry["scope_suffix"]
    assert_equal "docs/rules/rule-one.md", entry["text"]
    refute_empty entry["focus"]
  end
end

class ManifestResolutionTest < Minitest::Test
  def teardown
    Manifest.reset!
    Sh.runner = nil
  end

  # The rule recorded in wurk docs/manifest.md: walk up from the working
  # directory first, so a worktree finds its OWN manifest. A branch editing
  # the schema must be testable on that branch.
  #
  # sabotage: make locate ask git before walking up -> red
  def test_walks_up_from_the_start_directory
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".claude"))
      FileUtils.cp(ManifestFixtures.path("valid"), File.join(dir, ".claude", "wurk.json"))
      nested = File.join(dir, "a", "b", "c")
      FileUtils.mkdir_p(nested)

      assert_equal File.join(dir, ".claude", "wurk.json"), Manifest.locate(start: nested)
    end
  end

  # sabotage: hardcode a main-checkout path instead of asking git -> red
  def test_falls_back_to_the_main_checkout_via_git_common_dir
    Dir.mktmpdir do |dir|
      main = File.join(dir, "main")
      FileUtils.mkdir_p(File.join(main, ".claude"))
      FileUtils.cp(ManifestFixtures.path("valid"), File.join(main, ".claude", "wurk.json"))

      elsewhere = File.join(dir, "elsewhere")
      FileUtils.mkdir_p(elsewhere)

      fake = FakeSh.new
      fake.expect(%w[git rev-parse --git-common-dir], out: "#{main}/.git\n")
      Sh.runner = fake

      assert_equal File.join(main, ".claude", "wurk.json"), Manifest.locate(start: elsewhere)
    end
  end

  def test_locate_returns_nil_when_git_cannot_help_either
    Dir.mktmpdir do |dir|
      fake = FakeSh.new
      fake.expect(%w[git rev-parse --git-common-dir], out: "", err: "not a git repository", exitstatus: 128)
      Sh.runner = fake

      assert_nil Manifest.locate(start: dir)
    end
  end
end

class ManifestRequireTest < Minitest::Test
  def teardown
    Manifest.reset!
  end

  # sabotage: let require! return the manifest anyway when invalid -> red
  def test_require_blocks_the_envelope_on_an_invalid_manifest
    Manifest.current = ManifestFixtures.load("bad_enum")
    env = Envelope.new(script: "probe")

    assert_nil Manifest.require!(env)
    refute env.ok?
    assert_equal ["manifest_invalid"], env.blocked.map { |b| b[:code] }.uniq
  end

  def test_require_forwards_unknown_key_warnings_and_returns_the_manifest
    Manifest.current = ManifestFixtures.load("unknown_key")
    env = Envelope.new(script: "probe")

    refute_nil Manifest.require!(env)
    assert env.ok?
    assert_equal ["manifest_unknown_key"], env.warnings.map { |w| w[:code] }.uniq
  end
end

class ManifestCliTest < Minitest::Test
  def teardown
    Manifest.reset!
  end

  def run_cli(argv)
    io = StringIO.new
    code = ManifestCli.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  def test_check_passes_against_a_valid_manifest
    code, env = run_cli(["check", "--file", ManifestFixtures.path("valid")])
    assert_equal 0, code
    assert_equal true, env["ok"]
    assert_equal true, env["data"]["valid"]
  end

  # sabotage: emit ok:true regardless of errors -> red
  def test_check_fails_usefully_against_a_broken_fixture
    code, env = run_cli(["check", "--file", ManifestFixtures.path("missing_required")])
    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_match(/missing required key beads\.prefix/, env["blocked"].map { |b| b["message"] }.join("\n"))
  end

  def test_check_reports_unparseable_json_without_crashing
    code, env = run_cli(["check", "--file", ManifestFixtures.path("malformed")])
    assert_equal 1, code
    assert_equal ["unparseable"], env["blocked"].map { |b| b["code"] }
  end

  def test_check_reports_a_missing_file
    code, env = run_cli(["check", "--file", "/nonexistent/wurk.json"])
    assert_equal 1, code
    assert_equal ["manifest_unavailable"], env["blocked"].map { |b| b["code"] }
  end

  # In the donor repo this checked that repo's own .claude/wurk.json - the
  # one place the suite was allowed to read a real manifest. Wurk is not a
  # consumer and ships no wurk.json, so the check that survives the move is
  # the equivalent one over the fixtures: every fixture that is not
  # deliberately broken must still satisfy the schema. Same job (a schema
  # change that invalidates shipped data fails the suite), no consumer repo
  # involved. Consumers get this coverage by running `manifest.rb check` in
  # their own gate - see wurk:kit REFERENCE.md.
  DELIBERATELY_INVALID = %w[bad_enum missing_required malformed wrong_version shell_string_command].freeze

  def test_every_valid_fixture_manifest_satisfies_the_schema
    names = Dir.glob(File.join(ManifestFixtures::DIR, "*.json"))
                .map { |p| File.basename(p, ".json") }
                .reject { |n| DELIBERATELY_INVALID.include?(n) }
    refute_empty names, "no valid fixture manifests found - this check would be vacuous"

    names.each do |name|
      code, env = run_cli(["check", "--file", ManifestFixtures.path(name)])
      assert_equal 0, code, "fixture #{name} is invalid: #{env['blocked'].inspect}"
      next if name == "unknown_key" # that one exists to prove warnings fire

      assert_empty env["warnings"], "fixture #{name} has unknown keys: #{env['warnings'].inspect}"
    end
  end
end

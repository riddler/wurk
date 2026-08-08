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

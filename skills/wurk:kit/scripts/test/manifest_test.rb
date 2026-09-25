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
    assert_match(/gate\.sabotage\.test_roots must be a non-empty list of git pathspecs/, m.errors.join("\n"))
  end

  # sabotage: drop the empty-string check on test_roots entries -> red
  def test_sabotage_empty_string_test_root_blocks
    m = ManifestFixtures.load_with(
      "valid",
      "gate" => { "sabotage" => { "test_roots" => [""], "test_pattern" => "\\btest\\s+\"" } }
    )
    refute m.valid?
    assert_match(/gate\.sabotage\.test_roots must be a non-empty list of git pathspecs/, m.errors.join("\n"))
  end

  # sabotage: drop the leading-":" check on test_roots entries -> red
  def test_sabotage_leading_colon_test_root_blocks
    m = ManifestFixtures.load_with(
      "valid",
      "gate" => { "sabotage" => { "test_roots" => [":!test/fixtures/"], "test_pattern" => "\\btest\\s+\"" } }
    )
    refute m.valid?
    assert_match(/gate\.sabotage\.test_roots must be a non-empty list of git pathspecs/, m.errors.join("\n"))
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

  def test_rebase_fixture_validates
    m = ManifestFixtures.load("rebase")
    assert m.valid?, "expected the rebase fixture to validate: #{m.errors.inspect}"
  end

  # sabotage: drop the section-must-be-an-object check in validate_rebase -> red
  def test_rebase_non_object_section_blocks
    m = ManifestFixtures.load_with("valid", "rebase" => "on")
    refute m.valid?
    assert_match(/rebase must be an object/, m.errors.join("\n"))
  end

  # sabotage: drop the is_a?(Array) check on auto_resolve_paths -> red
  def test_rebase_non_list_auto_resolve_paths_blocks
    m = ManifestFixtures.load_with("valid", "rebase" => { "auto_resolve_paths" => "docs/plan.md" })
    refute m.valid?
    assert_match(/rebase\.auto_resolve_paths must be a list of non-empty strings/, m.errors.join("\n"))
  end

  # sabotage: drop the entry non-empty-string check in validate_rebase_entry -> red
  def test_rebase_empty_string_entry_blocks
    m = ManifestFixtures.load_with("valid", "rebase" => { "auto_resolve_paths" => [""] })
    refute m.valid?
    assert_match(/auto_resolve_paths entries must be non-empty strings/, m.errors.join("\n"))
  end

  # sabotage: drop REBASE_WHOLE_REPO_ENTRIES from validate_rebase_entry -> red
  def test_rebase_whole_repo_entry_blocks
    m = ManifestFixtures.load_with("valid", "rebase" => { "auto_resolve_paths" => ["/"] })
    refute m.valid?
    assert_match(/auto_resolve_paths entry "\/" matches the whole repo/, m.errors.join("\n"))

    m = ManifestFixtures.load_with("valid", "rebase" => { "auto_resolve_paths" => ["."] })
    refute m.valid?
    assert_match(/auto_resolve_paths entry "\." matches the whole repo/, m.errors.join("\n"))
  end

  # sabotage: put gate.build_paths back into REBASE_COLLISION_LIST_FIELDS ->
  # red. Coverage lists are not disjointness surfaces (ADR-0010's
  # 2026-08-17 amendment): a collision with build_paths means the full
  # gate verifies the merged result, so it is accepted.
  def test_rebase_entry_colliding_with_build_paths_is_accepted
    m = ManifestFixtures.load_with("rebase", "rebase" => { "auto_resolve_paths" => ["mix.exs"] })
    assert m.valid?, "expected a build_paths collision to be accepted: #{m.errors.inspect}"
  end

  # sabotage: put gate.also_gated_paths back into REBASE_COLLISION_LIST_FIELDS
  # -> red. Same reasoning as build_paths above - also_gated_paths is a
  # coverage list, not a hazard surface.
  def test_rebase_entry_colliding_with_also_gated_paths_is_accepted
    m = ManifestFixtures.load_with("rebase", "rebase" => { "auto_resolve_paths" => ["vendor/generated/"] })
    assert m.valid?, "expected an also_gated_paths collision to be accepted: #{m.errors.inspect}"
  end

  # sabotage: drop gate.moving_files from REBASE_COLLISION_LIST_FIELDS -> red
  def test_rebase_entry_colliding_with_moving_files_blocks_naming_the_list
    m = ManifestFixtures.load_with("rebase", "rebase" => { "auto_resolve_paths" => [".quality.exs"] })
    refute m.valid?
    assert_match(
      /auto_resolve_paths entry "\.quality\.exs" collides with gate\.moving_files entry "\.quality\.exs"/,
      m.errors.join("\n")
    )
  end

  # sabotage: drop gate.guard_ledger from REBASE_COLLISION_SCALAR_FIELDS -> red
  def test_rebase_entry_colliding_with_guard_ledger_blocks_naming_the_field
    m = ManifestFixtures.load_with("rebase", "rebase" => { "auto_resolve_paths" => ["docs/quality-gate-changes.md"] })
    refute m.valid?
    assert_match(
      /auto_resolve_paths entry "docs\/quality-gate-changes\.md" collides with gate\.guard_ledger \("docs\/quality-gate-changes\.md"\)/,
      m.errors.join("\n")
    )
  end

  # sabotage: drop parallelism.repair_when from REBASE_COLLISION_SCALAR_FIELDS -> red
  def test_rebase_entry_colliding_with_repair_when_blocks_naming_the_field
    m = ManifestFixtures.load_with(
      "rebase",
      "parallelism" => { "repair_when" => "package.lock" },
      "rebase" => { "auto_resolve_paths" => ["package.lock"] }
    )
    refute m.valid?
    assert_match(
      /auto_resolve_paths entry "package\.lock" collides with parallelism\.repair_when \("package\.lock"\)/,
      m.errors.join("\n")
    )
  end

  # sabotage: check only GatePaths.match_one?(entry, guarded) and drop the
  # reverse direction in rebase_collision -> red. An allowlist entry that is
  # a directory prefix of a guarded exact path is as wrong as the reverse.
  def test_rebase_entry_that_is_a_prefix_of_a_guarded_path_blocks
    m = ManifestFixtures.load_with("rebase", "rebase" => { "auto_resolve_paths" => ["docs/"] })
    refute m.valid?
    assert_match(/auto_resolve_paths entry "docs\/" collides with gate\.guard_ledger/, m.errors.join("\n"))
  end

  # sabotage: check only GatePaths.match_one?(guarded, entry) and drop the
  # forward direction in rebase_collision -> red. Uses gate.moving_files
  # (a hazard surface, not a coverage list) since build_paths and
  # also_gated_paths no longer collide.
  def test_rebase_entry_that_is_prefixed_by_a_guarded_path_blocks
    m = ManifestFixtures.load_with("rebase", "rebase" => { "auto_resolve_paths" => ["genfiles/extra.rb"] })
    refute m.valid?
    assert_match(/auto_resolve_paths entry "genfiles\/extra\.rb" collides with gate\.moving_files entry "genfiles\/"/, m.errors.join("\n"))
  end

  # sabotage: check only GatePaths.match_one?(entry, guarded) and drop the
  # reverse direction, specifically inside the REBASE_COLLISION_LIST_FIELDS
  # loop -> red. A directory-prefix allowlist entry that is broader than a
  # list-field guarded path (rather than a guard_ledger/repair_when scalar)
  # must also be caught; the scalar-field case above does not exercise this
  # branch. Uses gate.moving_files for the same reason as the test above.
  def test_rebase_directory_prefix_entry_broader_than_a_list_field_guarded_path_blocks
    m = ManifestFixtures.load_with("rebase", "rebase" => { "auto_resolve_paths" => ["special/"] })
    refute m.valid?
    assert_match(/auto_resolve_paths entry "special\/" collides with gate\.moving_files entry "special\/check\.rb"/, m.errors.join("\n"))
  end

  # sabotage: check only GatePaths.match_one?(guarded, entry) and drop the
  # forward direction, specifically inside the REBASE_COLLISION_SCALAR_FIELDS
  # loop -> red. Both scalar fields hold a single file path in practice, and
  # for an exact path the two directions catch the same entries - so the
  # forward branch is only reachable when a consumer sets a scalar to a
  # directory prefix, which nothing validates against.
  def test_rebase_entry_under_a_directory_prefix_scalar_blocks
    m = ManifestFixtures.load_with(
      "rebase",
      "parallelism" => { "repair_when" => "deps/" },
      "rebase" => { "auto_resolve_paths" => ["deps/vendored.md"] }
    )
    refute m.valid?
    assert_match(
      /auto_resolve_paths entry "deps\/vendored\.md" collides with parallelism\.repair_when \("deps\/"\)/,
      m.errors.join("\n")
    )
  end

  # sabotage: drop the manifest-directory check in validate_rebase_entry -> red
  def test_rebase_entry_naming_the_manifest_file_blocks
    m = ManifestFixtures.load_with("valid", "rebase" => { "auto_resolve_paths" => [".claude/wurk.json"] })
    refute m.valid?
    assert_match(/auto_resolve_paths entry "\.claude\/wurk\.json" is inside \.claude\//, m.errors.join("\n"))
  end

  # sabotage: drop the exact-directory branch of the manifest-directory check -> red
  def test_rebase_entry_naming_the_manifest_directory_itself_blocks
    m = ManifestFixtures.load_with("valid", "rebase" => { "auto_resolve_paths" => [".claude/"] })
    refute m.valid?
    assert_match(/auto_resolve_paths entry "\.claude\/" is inside \.claude\//, m.errors.join("\n"))
  end

  # sabotage: drop the start_with?("#{manifest_dir}/") branch, only checking
  # equality with the bare directory -> red
  def test_rebase_entry_naming_an_extension_file_blocks
    m = ManifestFixtures.load_with("valid", "rebase" => { "auto_resolve_paths" => [".claude/wurk/mr.md"] })
    refute m.valid?
    assert_match(/auto_resolve_paths entry "\.claude\/wurk\/mr\.md" is inside \.claude\//, m.errors.join("\n"))
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

  def test_gate_timeout_seconds_explicit_valid_value_validates
    m = ManifestFixtures.load_with("valid", "gate" => { "timeout_seconds" => 1200 })
    assert m.valid?, "expected an explicit positive integer timeout to validate: #{m.errors.inspect}"
  end

  # sabotage: drop the .positive? check, letting 0 through -> red
  def test_gate_timeout_seconds_zero_blocks
    m = ManifestFixtures.load_with("valid", "gate" => { "timeout_seconds" => 0 })
    refute m.valid?
    assert_match(/gate\.timeout_seconds must be a positive integer, got 0/, m.errors.join("\n"))
  end

  # sabotage: drop the .positive? check entirely -> red
  def test_gate_timeout_seconds_negative_blocks
    m = ManifestFixtures.load_with("valid", "gate" => { "timeout_seconds" => -5 })
    refute m.valid?
    assert_match(/gate\.timeout_seconds must be a positive integer, got -5/, m.errors.join("\n"))
  end

  # sabotage: use is_a?(Numeric) instead of is_a?(Integer), letting a float
  # through -> red
  def test_gate_timeout_seconds_float_blocks
    m = ManifestFixtures.load_with("valid", "gate" => { "timeout_seconds" => 600.5 })
    refute m.valid?
    assert_match(/gate\.timeout_seconds must be a positive integer, got 600\.5/, m.errors.join("\n"))
  end

  # sabotage: drop the is_a?(Integer) check, letting a string through -> red
  def test_gate_timeout_seconds_non_numeric_blocks
    m = ManifestFixtures.load_with("valid", "gate" => { "timeout_seconds" => "600" })
    refute m.valid?
    assert_match(/gate\.timeout_seconds must be a positive integer, got "600"/, m.errors.join("\n"))
  end

  def test_gate_long_timeout_seconds_explicit_valid_value_validates
    m = ManifestFixtures.load_with("valid", "gate" => { "long_timeout_seconds" => 7200 })
    assert m.valid?, "expected an explicit positive integer long timeout to validate: #{m.errors.inspect}"
    assert_empty m.warnings
  end

  # sabotage: forget to add "long_timeout_seconds" to KNOWN["gate"] -> red,
  # since the field would then warn as unknown instead of validating
  def test_gate_long_timeout_seconds_is_not_an_unknown_key
    m = ManifestFixtures.load_with("valid", "gate" => { "long_timeout_seconds" => 7200 })
    refute_match(/unknown key gate\.long_timeout_seconds/, m.warnings.join("\n"))
  end

  # sabotage: drop the .positive? check, letting 0 through -> red
  def test_gate_long_timeout_seconds_zero_blocks
    m = ManifestFixtures.load_with("valid", "gate" => { "long_timeout_seconds" => 0 })
    refute m.valid?
    assert_match(/gate\.long_timeout_seconds must be a positive integer, got 0/, m.errors.join("\n"))
  end

  # sabotage: drop the .positive? check entirely -> red
  def test_gate_long_timeout_seconds_negative_blocks
    m = ManifestFixtures.load_with("valid", "gate" => { "long_timeout_seconds" => -5 })
    refute m.valid?
    assert_match(/gate\.long_timeout_seconds must be a positive integer, got -5/, m.errors.join("\n"))
  end

  # sabotage: use is_a?(Numeric) instead of is_a?(Integer), letting a float
  # through -> red
  def test_gate_long_timeout_seconds_float_blocks
    m = ManifestFixtures.load_with("valid", "gate" => { "long_timeout_seconds" => 3600.5 })
    refute m.valid?
    assert_match(/gate\.long_timeout_seconds must be a positive integer, got 3600\.5/, m.errors.join("\n"))
  end

  # sabotage: drop the is_a?(Integer) check, letting a string through -> red
  def test_gate_long_timeout_seconds_non_numeric_blocks
    m = ManifestFixtures.load_with("valid", "gate" => { "long_timeout_seconds" => "3600" })
    refute m.valid?
    assert_match(/gate\.long_timeout_seconds must be a positive integer, got "3600"/, m.errors.join("\n"))
  end

  # sabotage: drop the long-vs-short comparison in
  # validate_gate_long_timeout_seconds -> red
  def test_gate_long_timeout_seconds_below_short_timeout_warns_but_validates
    m = ManifestFixtures.load_with(
      "valid", "gate" => { "timeout_seconds" => 600, "long_timeout_seconds" => 300 }
    )
    assert m.valid?, "a long timeout below the short one is legal, just suspicious: #{m.errors.inspect}"
    assert_match(/gate\.long_timeout_seconds \(300\) is less than gate\.timeout_seconds \(600\)/,
                 m.warnings.join("\n"))
  end

  # --- parallelism.preflight (wu-yi7.3) --------------------------------------

  # sabotage: drop "parallelism.preflight" from DEFAULTS -> red. Absent must
  # mean ON: the preflight guards against a stale base, and a consumer that
  # never heard of the key gets the guard, not the incident.
  def test_parallelism_preflight_defaults_to_true
    m = ManifestFixtures.load("valid")
    assert_nil m.dig_raw("parallelism.preflight")
    assert_equal true, m.preflight?
  end

  # sabotage: read the key with `fetch(...)` truthiness instead of `== true`
  # -> still green here, but the "false" string test below is what then
  # closes the hole; together they pin the accessor to a real boolean.
  def test_parallelism_preflight_false_turns_it_off_and_validates
    m = ManifestFixtures.load_with("valid", "parallelism" => { "preflight" => false })
    assert m.valid?, "an explicit false is the opt-out: #{m.errors.inspect}"
    assert_equal false, m.preflight?
  end

  def test_parallelism_preflight_explicit_true_validates
    m = ManifestFixtures.load_with("valid", "parallelism" => { "preflight" => true })
    assert m.valid?
    assert_equal true, m.preflight?
  end

  # sabotage: forget to add "preflight" to KNOWN["parallelism"] -> red
  def test_parallelism_preflight_is_not_an_unknown_key
    m = ManifestFixtures.load_with("valid", "parallelism" => { "preflight" => false })
    refute_match(/unknown key parallelism\.preflight/, m.warnings.join("\n"))
  end

  # sabotage: drop validate_parallelism_preflight -> red. A string "false"
  # is truthy in Ruby: without the check a consumer who wrote it to opt out
  # would get the preflight anyway and read its refusal as a kit bug.
  def test_parallelism_preflight_string_false_blocks
    m = ManifestFixtures.load_with("valid", "parallelism" => { "preflight" => "false" })
    refute m.valid?
    assert_match(/parallelism\.preflight must be true or false, got "false"/, m.errors.join("\n"))
  end

  def test_parallelism_preflight_integer_blocks
    m = ManifestFixtures.load_with("valid", "parallelism" => { "preflight" => 1 })
    refute m.valid?
    assert_match(/parallelism\.preflight must be true or false, got 1/, m.errors.join("\n"))
  end

  def test_parallelism_timeout_seconds_explicit_valid_value_validates
    m = ManifestFixtures.load_with("valid", "parallelism" => { "timeout_seconds" => 1200 })
    assert m.valid?, "expected an explicit positive integer timeout to validate: #{m.errors.inspect}"
  end

  # sabotage: drop the .positive? check, letting 0 through -> red
  def test_parallelism_timeout_seconds_zero_blocks
    m = ManifestFixtures.load_with("valid", "parallelism" => { "timeout_seconds" => 0 })
    refute m.valid?
    assert_match(/parallelism\.timeout_seconds must be a positive integer, got 0/, m.errors.join("\n"))
  end

  # sabotage: drop the .positive? check entirely -> red
  def test_parallelism_timeout_seconds_negative_blocks
    m = ManifestFixtures.load_with("valid", "parallelism" => { "timeout_seconds" => -5 })
    refute m.valid?
    assert_match(/parallelism\.timeout_seconds must be a positive integer, got -5/, m.errors.join("\n"))
  end

  # sabotage: use is_a?(Numeric) instead of is_a?(Integer), letting a float
  # through -> red
  def test_parallelism_timeout_seconds_float_blocks
    m = ManifestFixtures.load_with("valid", "parallelism" => { "timeout_seconds" => 600.5 })
    refute m.valid?
    assert_match(/parallelism\.timeout_seconds must be a positive integer, got 600\.5/, m.errors.join("\n"))
  end

  # sabotage: drop the is_a?(Integer) check, letting a string through -> red
  def test_parallelism_timeout_seconds_non_numeric_blocks
    m = ManifestFixtures.load_with("valid", "parallelism" => { "timeout_seconds" => "600" })
    refute m.valid?
    assert_match(/parallelism\.timeout_seconds must be a positive integer, got "600"/, m.errors.join("\n"))
  end

  # --- forge.host (wu-4wl.1) ---------------------------------------------
  #
  # The field is additive: an existing consumer manifest with no forge.host
  # keeps validating, and resolves to the forge kind's own host in
  # lib/forge.rb. That back-compatibility is the first test here, not an
  # afterthought - three consumer manifests predate the field.

  def test_forge_host_absent_validates
    m = ManifestFixtures.load("valid")
    assert m.valid?, "expected an absent forge.host to validate: #{m.errors.inspect}"
    assert_nil m.forge_host
  end

  def test_forge_host_hostname_validates
    m = ManifestFixtures.load_with("valid", "forge" => { "host" => "gitlab.example.com" })
    assert m.valid?, "expected a bare hostname to validate: #{m.errors.inspect}"
    assert_equal "gitlab.example.com", m.forge_host
  end

  def test_forge_host_with_a_port_validates
    m = ManifestFixtures.load_with("valid", "forge" => { "host" => "git.example.com:8443" })
    assert m.valid?, "expected a host:port to validate: #{m.errors.inspect}"
  end

  def test_forge_host_single_label_validates
    m = ManifestFixtures.load_with("valid", "forge" => { "host" => "gitlab" })
    assert m.valid?, "expected an intranet single-label host to validate: #{m.errors.inspect}"
  end

  # Shape only, never the network - the same line validate_gate_cwd draws.
  def test_forge_host_validation_does_not_resolve_the_name
    m = ManifestFixtures.load_with("valid", "forge" => { "host" => "definitely-not-a-real-host.invalid" })
    assert m.valid?, "expected validation to accept an unresolvable host: #{m.errors.inspect}"
  end

  # sabotage: drop FORGE_HOST_RE and accept any non-empty string -> red. A
  # scheme survives into "https://https://host/...", which 404s in a document
  # nobody re-reads.
  def test_forge_host_with_a_scheme_blocks
    m = ManifestFixtures.load_with("valid", "forge" => { "host" => "https://gitlab.example.com" })
    refute m.valid?
    assert_match(/forge\.host must be a bare hostname/, m.errors.join("\n"))
  end

  def test_forge_host_with_a_path_blocks
    m = ManifestFixtures.load_with("valid", "forge" => { "host" => "gitlab.example.com/gitlab" })
    refute m.valid?
    assert_match(/forge\.host must be a bare hostname/, m.errors.join("\n"))
  end

  def test_forge_host_with_a_trailing_slash_blocks
    m = ManifestFixtures.load_with("valid", "forge" => { "host" => "gitlab.example.com/" })
    refute m.valid?
    assert_match(/forge\.host must be a bare hostname/, m.errors.join("\n"))
  end

  # sabotage: drop the is_a?(String) check -> red
  def test_forge_host_non_string_blocks
    m = ManifestFixtures.load_with("valid", "forge" => { "host" => 443 })
    refute m.valid?
    assert_match(/forge\.host must be a non-empty hostname string, got 443/, m.errors.join("\n"))
  end

  def test_forge_host_empty_string_blocks
    m = ManifestFixtures.load_with("valid", "forge" => { "host" => "  " })
    refute m.valid?
    assert_match(/forge\.host must be a non-empty hostname string/, m.errors.join("\n"))
  end

  # sabotage: leave "host" out of KNOWN["forge"] -> the field a consumer
  # declares on purpose warns as unknown -> red
  def test_forge_host_is_a_known_key_and_warns_about_nothing
    m = ManifestFixtures.load_with("valid", "forge" => { "host" => "gitlab.example.com" })
    m.valid?
    assert_empty m.warnings
  end

  def test_gate_cwd_absent_validates
    m = ManifestFixtures.load("valid")
    assert m.valid?, "expected an absent gate.cwd to validate: #{m.errors.inspect}"
  end

  def test_gate_cwd_relative_subdirectory_validates
    m = ManifestFixtures.load_with("valid", "gate" => { "cwd" => "backend" })
    assert m.valid?, "expected a relative subdirectory to validate: #{m.errors.inspect}"
  end

  def test_gate_cwd_nested_relative_subdirectory_validates
    m = ManifestFixtures.load_with("valid", "gate" => { "cwd" => "apps/backend" })
    assert m.valid?, "expected a nested relative subdirectory to validate: #{m.errors.inspect}"
  end

  # sabotage: drop the trailing-slash tolerance (there isn't one to drop -
  # File.join handles it) by normalizing the value -> this pins that no
  # normalization happens and a trailing slash still validates
  def test_gate_cwd_trailing_slash_validates
    m = ManifestFixtures.load_with("valid", "gate" => { "cwd" => "backend/" })
    assert m.valid?, "expected a trailing slash to validate: #{m.errors.inspect}"
  end

  # Validation is deliberately filesystem-free: a gate.cwd naming a directory
  # that does not exist must still validate. See lib/manifest.rb's
  # validate_gate_cwd comment and docs/manifest.md.
  def test_gate_cwd_validation_does_not_touch_the_filesystem
    m = ManifestFixtures.load_with("valid", "gate" => { "cwd" => "definitely/does/not/exist/anywhere" })
    assert m.valid?, "expected validation to accept a nonexistent directory: #{m.errors.inspect}"
  end

  # sabotage: drop the is_a?(String) check, letting a non-string through -> red
  def test_gate_cwd_non_string_blocks
    m = ManifestFixtures.load_with("valid", "gate" => { "cwd" => 5 })
    refute m.valid?
    assert_match(/gate\.cwd must be a non-empty relative directory path, got 5/, m.errors.join("\n"))
  end

  # sabotage: drop the !value.empty? check, letting "" through -> red
  def test_gate_cwd_empty_string_blocks
    m = ManifestFixtures.load_with("valid", "gate" => { "cwd" => "" })
    refute m.valid?
    assert_match(/gate\.cwd must be a non-empty relative directory path, got ""/, m.errors.join("\n"))
  end

  # sabotage: drop the start_with?("/") check -> red
  def test_gate_cwd_absolute_path_blocks
    m = ManifestFixtures.load_with("valid", "gate" => { "cwd" => "/abs/path" })
    refute m.valid?
    assert_match(%r{gate\.cwd must be relative to the repo root, got "/abs/path"}, m.errors.join("\n"))
  end

  # sabotage: drop the value == "." check -> red
  def test_gate_cwd_dot_blocks
    m = ManifestFixtures.load_with("valid", "gate" => { "cwd" => "." })
    refute m.valid?
    assert_match(/gate\.cwd must name a subdirectory of the repo root/, m.errors.join("\n"))
  end

  # sabotage: drop the ".." segment check -> red
  def test_gate_cwd_dot_dot_prefix_blocks
    m = ManifestFixtures.load_with("valid", "gate" => { "cwd" => "../up" })
    refute m.valid?
    assert_match(/gate\.cwd must name a subdirectory of the repo root/, m.errors.join("\n"))
  end

  # sabotage: check the value string for ".." with a substring match instead
  # of splitting on "/" -> would incorrectly reject "a..b" while still
  # missing this test's "a/../b" if the split were dropped entirely -> red
  def test_gate_cwd_dot_dot_segment_blocks
    m = ManifestFixtures.load_with("valid", "gate" => { "cwd" => "a/../b" })
    refute m.valid?
    assert_match(/gate\.cwd must name a subdirectory of the repo root/, m.errors.join("\n"))
  end

  # sabotage: forget to add "cwd" to KNOWN["gate"] -> red, since gate.cwd
  # would then warn as an unknown key instead of validating as a known one
  def test_gate_subdir_fixture_produces_no_unknown_key_warning
    m = ManifestFixtures.load("gate_subdir")
    assert m.valid?, "expected the gate_subdir fixture to validate: #{m.errors.inspect}"
    assert_empty m.warnings, "gate.cwd must be a known key: #{m.warnings.inspect}"
  end

  # sabotage: drop the DEFAULTS["tmux.layout"] entry -> red
  def test_tmux_layout_defaults_to_window_per_issue
    m = ManifestFixtures.load("tmux")
    assert_equal "window-per-issue", m.tmux_layout
  end

  # sabotage: drop "tmux.layout" from ENUMS -> red
  def test_unrecognized_tmux_layout_blocks_rather_than_defaulting
    m = ManifestFixtures.load_with("tmux", "tmux" => { "layout" => "per-window-issue" })
    refute m.valid?
    assert_match(/tmux\.layout is "per-window-issue"; expected one of window-per-issue, session-per-issue/,
                 m.errors.join("\n"))
  end

  # wu-jhb: tmux.permission_mode moved to the machine-level config
  # (lib/user_config.rb). A manifest that still sets it stays valid and gets
  # exactly one warning naming the key and the doc it moved to.
  # sabotage: drop RETIRED["tmux.permission_mode"] -> red (falls through to
  # the generic "unknown key" warning instead of naming the replacement)
  def test_retired_tmux_permission_mode_is_still_valid_and_warns_once_naming_the_replacement
    m = ManifestFixtures.load_with("tmux", "tmux" => { "permission_mode" => "acceptEdits" })
    assert m.valid?, "a retired key must never block: #{m.errors.inspect}"
    assert_equal 1, m.warnings.length, "expected exactly one warning: #{m.warnings.inspect}"
    assert_match(/tmux\.permission_mode is retired/, m.warnings.first)
    assert_match(/docs\/machine-config\.md/, m.warnings.first)
  end

  # sabotage: leave #tmux_permission_mode defined on Manifest -> red
  def test_manifest_no_longer_responds_to_tmux_permission_mode
    refute_respond_to Manifest.new(path: "(n/a)", raw: {}), :tmux_permission_mode
  end

  # A genuinely unknown tmux key (not the retired one) must still get the
  # generic unknown-key warning - proves the retired path did not swallow
  # the general case.
  # sabotage: collect_unknown_keys' `elsif !RETIRED.key?(dotted)` changed to
  # unconditionally skip warning -> red
  def test_unrelated_unknown_tmux_key_still_gets_the_generic_warning
    m = ManifestFixtures.load_with("tmux", "tmux" => { "bogus_key" => "x" })
    assert m.valid?
    assert_equal 1, m.warnings.length, "expected exactly one warning: #{m.warnings.inspect}"
    assert_match(/unknown key tmux\.bogus_key \(ignored\)/, m.warnings.first)
  end

  # sabotage: split tmux.editor on whitespace instead of enforcing argv -> red
  def test_shell_string_tmux_editor_blocks
    m = ManifestFixtures.load_with("tmux_session_per_issue", "tmux" => { "editor" => "nvim" })
    refute m.valid?
    assert_match(/tmux\.editor must be an argv array of strings/, m.errors.join("\n"))
  end

  # sabotage: drop the layout guard in validate_tmux, requiring session under
  # every layout -> red, since tmux_session_per_issue has no tmux.session
  def test_tmux_session_absent_is_valid_under_session_per_issue
    m = ManifestFixtures.load("tmux_session_per_issue")
    assert m.valid?, "expected the tmux_session_per_issue fixture to validate: #{m.errors.inspect}"
    assert_empty m.warnings
  end

  # sabotage: return early regardless of layout in validate_tmux -> red,
  # since window-per-issue with no session must still block
  def test_tmux_session_required_under_window_per_issue
    m = ManifestFixtures.load_with("tmux_session_per_issue", "tmux" => { "layout" => "window-per-issue" })
    refute m.valid?
    assert_match(/tmux\.session is required under tmux\.layout window-per-issue/, m.errors.join("\n"))
  end

  # wu-a6r: a tmux section with no tmux.model key must block, not degrade to
  # a bare `--model` that swallows the seeded prompt. The key is genuinely
  # absent here (not merely blank), matching the shape reported in
  # ciq-errata-management's manifest.
  # sabotage: drop validate_tmux_model's call from validate_tmux -> red
  def test_tmux_model_missing_key_blocks_under_window_per_issue
    raw = JSON.parse(File.read(ManifestFixtures.path("tmux")))
    raw["tmux"].delete("model")
    m = Manifest.new(path: ManifestFixtures.path("tmux"), raw: raw)
    refute m.valid?
    assert_match(/tmux\.model is required whenever a tmux section is present \(both layouts\)/, m.errors.join("\n"))
  end

  # sabotage: gate validate_tmux_model behind the window-per-issue layout
  # check the way validate_tmux gates tmux.session -> red, since
  # tmux_session_per_issue's own layout is session-per-issue
  def test_tmux_model_missing_key_blocks_under_session_per_issue
    raw = JSON.parse(File.read(ManifestFixtures.path("tmux_session_per_issue")))
    raw["tmux"].delete("model")
    m = Manifest.new(path: ManifestFixtures.path("tmux_session_per_issue"), raw: raw)
    refute m.valid?
    assert_match(/tmux\.model is required whenever a tmux section is present \(both layouts\)/, m.errors.join("\n"))
  end

  # sabotage: treat an empty string the same as a present model -> red
  def test_tmux_model_empty_string_blocks
    m = ManifestFixtures.load_with("tmux", "tmux" => { "model" => "" })
    refute m.valid?
    assert_match(/tmux\.model is required whenever a tmux section is present \(both layouts\)/, m.errors.join("\n"))
  end

  # sabotage: require tmux.model unconditionally, even with no tmux section
  # at all -> red, since "valid" carries no tmux key
  def test_tmux_model_present_stays_valid_under_window_per_issue
    m = ManifestFixtures.load("tmux")
    assert m.valid?, "expected the tmux fixture (model present) to validate: #{m.errors.inspect}"
  end

  def test_tmux_model_present_stays_valid_under_session_per_issue
    m = ManifestFixtures.load("tmux_session_per_issue")
    assert m.valid?, "expected the tmux_session_per_issue fixture (model present) to validate: #{m.errors.inspect}"
  end

  # The important regression guard: omitting tmux entirely means no tmux
  # integration and must never become an error on its own.
  # sabotage: call validate_tmux_model unconditionally instead of behind
  # `return unless tmux?` -> red, since "valid" has no tmux section
  def test_no_tmux_section_at_all_remains_valid
    m = ManifestFixtures.load("valid")
    assert m.valid?, "expected a manifest with no tmux section to validate: #{m.errors.inspect}"
    refute m.tmux?
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
    assert_equal 600, @m.gate_timeout_seconds
    assert_equal 3600, @m.gate_long_timeout_seconds
    assert_equal 600, @m.parallelism_timeout_seconds
  end

  # sabotage: read the wrong dotted key, or drop the DEFAULTS entry, in
  # gate_timeout_seconds -> red
  def test_gate_timeout_seconds_reads_an_explicit_value
    m = ManifestFixtures.load_with("valid", "gate" => { "timeout_seconds" => 1800 })
    assert_equal 1800, m.gate_timeout_seconds
  end

  # sabotage: read the wrong dotted key, or drop the DEFAULTS entry, in
  # gate_long_timeout_seconds -> red
  def test_gate_long_timeout_seconds_reads_an_explicit_value
    m = ManifestFixtures.load_with("valid", "gate" => { "long_timeout_seconds" => 7200 })
    assert_equal 7200, m.gate_long_timeout_seconds
  end

  # sabotage: read the wrong dotted key, or drop the DEFAULTS entry, in
  # parallelism_timeout_seconds -> red
  def test_parallelism_timeout_seconds_reads_an_explicit_value
    m = ManifestFixtures.load_with("valid", "parallelism" => { "timeout_seconds" => 1800 })
    assert_equal 1800, m.parallelism_timeout_seconds
  end

  def test_absent_tmux_section_reports_no_tmux_integration
    refute @m.tmux?
    assert_nil @m.tmux_session
  end

  # sabotage: drop the DEFAULTS["tmux.layout"] entry -> red, since tmux_layout
  # would then return nil against a manifest with no tmux section at all
  def test_tmux_layout_defaults_to_window_per_issue_even_without_a_tmux_section
    assert_equal "window-per-issue", @m.tmux_layout
    refute @m.tmux?
  end

  # sabotage: return [] instead of nil for an absent tmux.editor -> red
  def test_tmux_editor_argv_is_nil_when_absent
    m = ManifestFixtures.load("tmux")
    assert_nil m.tmux_editor_argv
  end

  # sabotage: read the wrong dotted key, or drop the argv() call, in
  # tmux_editor_argv -> red
  def test_tmux_editor_argv_reads_the_declared_argv
    m = ManifestFixtures.load("tmux_session_per_issue")
    assert_equal ["nvim"], m.tmux_editor_argv
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

  # sabotage: return nil (or a non-empty default) instead of [] for an
  # absent rebase section -> red
  def test_rebase_auto_resolve_paths_defaults_to_empty_when_absent
    assert_equal [], @m.rebase_auto_resolve_paths
  end

  # sabotage: read the wrong dotted key, or drop the Array() wrap, in
  # rebase_auto_resolve_paths -> red
  def test_rebase_auto_resolve_paths_round_trips_a_well_formed_list
    m = ManifestFixtures.load("rebase")
    assert_equal ["docs/plan.md", "docs/notes/"], m.rebase_auto_resolve_paths
  end

  # sabotage: read the wrong dotted key in gate_cwd -> red
  def test_gate_cwd_is_nil_when_absent
    assert_nil @m.gate_cwd
  end

  def test_gate_cwd_reads_the_declared_value
    m = ManifestFixtures.load("gate_subdir")
    assert_equal "backend", m.gate_cwd
  end

  # checkout_root is two directories up from path (path is always
  # <root>/.claude/wurk.json).
  # sabotage: go up only one directory instead of two -> red
  def test_checkout_root_is_two_directories_above_path
    m = ManifestFixtures.load("valid")
    expected = File.expand_path(File.join(ManifestFixtures::DIR, ".."))
    assert_equal expected, m.checkout_root
  end

  # sabotage: return the checkout root instead of nil when gate.cwd is
  # absent -> red. This is the property that keeps the rendered `commands`
  # audit trail byte-identical for every consumer that does not use the
  # field.
  def test_gate_chdir_is_nil_when_gate_cwd_is_absent
    assert_nil @m.gate_chdir(root: @m.checkout_root)
    assert_nil @m.gate_chdir(root: "/some/worktree")
  end

  # sabotage: give `root:` a default of checkout_root again -> red
  # (ArgumentError is no longer raised, and the assertion that it is fails)
  def test_gate_chdir_requires_an_explicit_root
    assert_raises(ArgumentError) { @m.gate_chdir }
  end

  # sabotage: ignore the explicit root: keyword and always use checkout_root
  # -> red. This is the shape worktree_create.rb / worktree_refresh.rb rely
  # on: gate_chdir(root: <worktree path>).
  def test_gate_chdir_joins_gate_cwd_onto_an_explicit_root
    m = ManifestFixtures.load("gate_subdir")
    assert_equal "/some/worktree/backend", m.gate_chdir(root: "/some/worktree")
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

  def test_check_reports_null_external_tracker_when_absent
    code, env = run_cli(["check", "--file", ManifestFixtures.path("valid")])
    assert_equal 0, code
    assert_nil env["data"]["external_tracker"]
  end

  def test_check_reports_the_resolved_external_tracker_including_lifecycle
    Dir.mktmpdir do |dir|
      raw = JSON.parse(File.read(ManifestFixtures.path("valid")))
      raw["external_tracker"] = {
        "id_pattern" => "[A-Z]+-[0-9]+",
        "subject_prefix" => true,
        "statuses" => { "claimed" => "Todo", "closed" => "Done" },
        "assignee" => { "agent" => "bot-account-1", "owner" => "human-account-1" }
      }
      manifest = File.join(dir, "wurk.json")
      File.write(manifest, JSON.generate(raw))

      code, env = run_cli(["check", "--file", manifest])
      assert_equal 0, code
      section = env["data"]["external_tracker"]
      refute_nil section
      assert_equal "[A-Z]+-[0-9]+", section["id_pattern"]
      assert_equal true, section["subject_prefix"]
      assert_equal({ "claimed" => "Todo", "closed" => "Done" }, section["statuses"])
      assert_equal({ "agent" => "bot-account-1", "owner" => "human-account-1" }, section["assignee"])
      assert_equal %w[claimed closed], section["lifecycle"].map { |e| e["event"] }
      assert_equal "bot-account-1", section["lifecycle"].first["assignee"]
      assert_equal "human-account-1", section["lifecycle"].last["assignee"]
    end
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

# beads.sync - the tracker-push gate. The safety property under test
# throughout: an absent key can never resolve to a mode that pushes.
class ManifestBeadsSyncTest < Minitest::Test
  def without_sync
    raw = JSON.parse(File.read(ManifestFixtures.path("valid")))
    raw["beads"].delete("sync")
    Manifest.new(path: ManifestFixtures.path("valid"), raw: raw)
  end

  def with_sync(value)
    ManifestFixtures.load_with("valid", { "beads" => { "sync" => value } })
  end

  # sabotage: change the beads.sync default to "git" -> red. This is the one
  # the bead calls P1: an unset key must not be able to cause a push.
  def test_absent_beads_sync_defaults_to_local_and_forbids_pushing
    m = without_sync
    assert_equal "local", m.beads_sync
    refute m.beads_push_allowed?
    refute m.beads_sync_declared?
  end

  # sabotage: turn the unset warning into an error -> red (a missing key with
  # a safe default is not a reason to refuse to run).
  def test_absent_beads_sync_warns_without_blocking
    m = without_sync
    assert m.valid?, "an unset beads.sync must not invalidate the manifest: #{m.errors.inspect}"
    assert_match(/beads\.sync is unset/, m.warnings.join("\n"))
    assert_match(/defaulting to local/, m.warnings.join("\n"))
  end

  # sabotage: drop the unset warning -> red.
  def test_declared_local_is_silent_but_still_forbids_pushing
    m = with_sync("local")
    assert m.valid?
    assert_empty m.warnings
    assert_equal "local", m.beads_sync
    refute m.beads_push_allowed?
    assert m.beads_sync_declared?
  end

  def test_git_and_dolthub_allow_pushing
    assert with_sync("git").beads_push_allowed?
    assert with_sync("dolthub").beads_push_allowed?
    assert_equal "dolthub", with_sync("dolthub").beads_sync
  end

  # sabotage: make beads_push_allowed? read `!= "local"` -> red. An
  # unrecognized mode must not fall through into a push.
  def test_an_unrecognized_mode_blocks_and_does_not_allow_pushing
    m = with_sync("gitlab")
    refute m.valid?
    assert_match(/beads\.sync is "gitlab"; expected one of local, git, dolthub/, m.errors.join("\n"))
    refute m.beads_push_allowed?
  end
end

# beads.scan_refusal - which tracker fields a scan hit refuses the push on
# (wu-b4i). The safety property: an absent key resolves to the WIDER set.
class ManifestBeadsScanRefusalTest < Minitest::Test
  def with_refusal(value)
    ManifestFixtures.load_with("valid", { "beads" => { "scan_refusal" => value } })
  end

  # sabotage: change the default to "titles" -> red. With no ruling on
  # record, every field refuses.
  def test_absent_scan_refusal_defaults_to_all_silently
    m = ManifestFixtures.load("valid")
    assert m.valid?
    assert_empty m.warnings
    assert_equal "all", m.beads_scan_refusal
  end

  def test_titles_is_accepted_and_is_not_an_unknown_key
    m = with_refusal("titles")
    assert m.valid?, m.errors.inspect
    assert_empty m.warnings
    assert_equal "titles", m.beads_scan_refusal
  end

  # sabotage: drop "none" from the enum -> red. A repo whose scan hits are
  # its own subject matter says so here; without the value its operator's
  # only remaining moves are renaming records, deleting a pattern that also
  # guards the public repos, or pushing around the kit entirely.
  def test_none_is_accepted_and_is_not_an_unknown_key
    m = with_refusal("none")
    assert m.valid?, m.errors.inspect
    assert_empty m.warnings
    assert_equal "none", m.beads_scan_refusal
  end

  # sabotage: drop the enum entry -> red. A value the kit does not know
  # must not reach the scan as "refuse on nothing" - only the literal
  # "none" may mean that, and the refusal names all three legal values so
  # a typo'd ruling is a correctable one.
  def test_an_unrecognized_refusal_set_blocks
    m = with_refusal("descriptions")
    refute m.valid?
    assert_match(/beads\.scan_refusal is "descriptions"; expected one of all, titles, none/, m.errors.join("\n"))
  end

  # sabotage: accept any falsy-looking spelling -> red. "off", "false" and
  # an empty string are not the ruling; none of them may disarm the set.
  def test_a_near_miss_spelling_of_none_blocks
    ["off", "false", "None", ""].each do |value|
      m = with_refusal(value)
      refute m.valid?, "#{value.inspect} must not be accepted as a refusal set"
      assert_match(/expected one of all, titles, none/, m.errors.join("\n"))
    end
  end
end

# The lint's environmental check: mode local, dolt remote present anyway.
class ManifestBeadsSyncLintTest < Minitest::Test
  DOLT_REMOTE_STATE = {
    "remotes" => {
      "origin" => { "name" => "origin", "url" => "git+ssh://git@example.invalid/./acme/thing.git" }
    }
  }.freeze

  # A throwaway checkout: <root>/.claude/wurk.json, so checkout_root - and
  # therefore the .beads lookup - lands where the fixture writes .beads.
  def in_checkout(sync:, config: nil, dolt_state: nil)
    Dir.mktmpdir do |root|
      raw = JSON.parse(File.read(ManifestFixtures.path("valid")))
      sync.nil? ? raw["beads"].delete("sync") : raw["beads"]["sync"] = sync
      FileUtils.mkdir_p(File.join(root, ".claude"))
      manifest = File.join(root, ".claude", "wurk.json")
      File.write(manifest, JSON.pretty_generate(raw))

      if config
        FileUtils.mkdir_p(File.join(root, ".beads"))
        File.write(File.join(root, ".beads", "config.yaml"), config)
      end
      if dolt_state
        dir = File.join(root, ".beads", "embeddeddolt", "zz", ".dolt")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "repo_state.json"), JSON.generate(dolt_state))
      end

      io = StringIO.new
      code = ManifestCli.run(["check", "--file", manifest], io: io)
      yield code, JSON.parse(io.string)
    end
  end

  def codes(env)
    env["warnings"].map { |w| w["code"] }
  end

  # sabotage: delete warn_local_mode_with_dolt_remote's call site -> red.
  def test_local_mode_with_a_configured_remote_warns
    in_checkout(sync: "local", config: %(sync.remote: "git@example.invalid:acme/thing.git"\n)) do |code, env|
      assert_equal 0, code, "the warning must not fail the lint"
      assert_equal true, env["ok"]
      assert_includes codes(env), "beads_sync_local_with_dolt_remote"
      assert_match(/sync\.remote -> git@example\.invalid:acme\/thing\.git/, env["warnings"].map { |w| w["message"] }.join)
    end
  end

  # The incident's actual shape: nothing in config.yaml, a remote still live
  # inside the embedded dolt db.
  # sabotage: check config.yaml only -> red.
  def test_a_remote_only_inside_the_embedded_dolt_db_warns
    in_checkout(sync: "local", config: "# no remote here\n", dolt_state: DOLT_REMOTE_STATE) do |_code, env|
      assert_includes codes(env), "beads_sync_local_with_dolt_remote"
      assert_match(%r{embeddeddolt/zz: origin ->}, env["warnings"].map { |w| w["message"] }.join)
    end
  end

  # sabotage: match commented lines too -> red, and every repo shipping bd's
  # documented config.yaml would warn.
  def test_a_commented_out_remote_does_not_warn
    config = <<~YAML
      # Cross-machine sync uses Dolt remotes.
      # sync.remote: "git@example.invalid:acme/thing.git"
    YAML
    in_checkout(sync: "local", config: config) do |_code, env|
      refute_includes codes(env), "beads_sync_local_with_dolt_remote"
    end
  end

  def test_an_unset_mode_with_a_remote_warns_about_both
    in_checkout(sync: nil, dolt_state: DOLT_REMOTE_STATE) do |_code, env|
      assert_includes codes(env), "beads_sync_local_with_dolt_remote"
      assert_match(/unset, defaulted/, env["warnings"].map { |w| w["message"] }.join)
      assert_match(/beads\.sync is unset/, env["warnings"].map { |w| w["message"] }.join)
    end
  end

  # sabotage: warn regardless of mode -> red. A repo that declares git is
  # supposed to have a remote.
  def test_a_pushing_mode_with_a_remote_does_not_warn
    in_checkout(sync: "git", dolt_state: DOLT_REMOTE_STATE) do |_code, env|
      refute_includes codes(env), "beads_sync_local_with_dolt_remote"
    end
  end

  def test_local_mode_with_no_beads_directory_does_not_warn
    in_checkout(sync: "local") do |_code, env|
      refute_includes codes(env), "beads_sync_local_with_dolt_remote"
    end
  end

  # The skills read the mode off this envelope rather than parsing the
  # manifest themselves.
  # sabotage: drop either data field -> red.
  def test_the_lint_reports_the_mode_for_the_skills_to_gate_on
    in_checkout(sync: "dolthub") do |_code, env|
      assert_equal "dolthub", env["data"]["beads_sync"]
      assert_equal true, env["data"]["beads_sync_declared"]
    end
    in_checkout(sync: nil) do |_code, env|
      assert_equal "local", env["data"]["beads_sync"]
      assert_equal false, env["data"]["beads_sync_declared"]
    end
  end

  # sabotage: drop data.beads_scan_refusal -> red.
  def test_the_lint_reports_the_scan_refusal_set
    in_checkout(sync: "dolthub") do |_code, env|
      assert_equal "all", env["data"]["beads_scan_refusal"]
    end
  end
end

# mr.review_agents - the consumer-declared pre-request review round. Two
# properties under test: absent is silent (a repo with no review agents is
# not a repo with a gap), and every check that reads the disk stays out of
# validate!.
class ManifestMrReviewAgentsTest < Minitest::Test
  def with_mr(value)
    ManifestFixtures.load_with("valid", { "mr" => { "review_agents" => value } })
  end

  # sabotage: warn on the absent section -> red. Silence is the contract.
  def test_an_absent_section_is_silent_and_declares_no_agents
    m = ManifestFixtures.load("valid")
    assert m.valid?
    assert_empty m.warnings
    assert_empty m.mr_review_agents
    refute m.mr_review_agents?
  end

  def test_a_declared_list_is_read_in_order
    m = with_mr(%w[alpha-reviewer beta.reviewer])
    assert m.valid?, m.errors.inspect
    assert_empty m.warnings
    assert_equal %w[alpha-reviewer beta.reviewer], m.mr_review_agents
    assert m.mr_review_agents?
  end

  # sabotage: accept a bare string and wrap it -> red. The field is a list.
  def test_a_non_array_blocks
    m = with_mr("alpha-reviewer")
    refute m.valid?
    assert_match(/mr\.review_agents must be a non-empty array/, m.errors.join("\n"))
    assert_empty m.mr_review_agents
  end

  # Present-or-absent, never half-present: "off" is spelled by omitting the
  # section, not by declaring an empty list.
  def test_an_empty_array_blocks
    m = with_mr([])
    refute m.valid?
    assert_match(/non-empty array of agent names/, m.errors.join("\n"))
    assert_match(/omit the mr section entirely/, m.errors.join("\n"))
  end

  def test_a_missing_review_agents_key_blocks
    m = ManifestFixtures.load_with("valid", { "mr" => {} })
    refute m.valid?
    assert_match(/mr\.review_agents must be a non-empty array/, m.errors.join("\n"))
  end

  def test_a_non_object_mr_section_blocks
    m = ManifestFixtures.load_with("valid", { "mr" => ["alpha-reviewer"] })
    refute m.valid?
    assert_match(/mr must be an object/, m.errors.join("\n"))
  end

  # sabotage: drop MR_REVIEW_AGENT_RE and accept any string -> red. The name
  # is joined to .claude/agents/<name>.md, so a path escapes that directory.
  def test_a_name_that_is_a_path_blocks
    ["../../etc/passwd", "sub/alpha", "-alpha", "", "alpha/"].each do |name|
      m = with_mr([name])
      refute m.valid?, "expected #{name.inspect} to be rejected as an agent name"
      assert_match(/must be a bare agent name/, m.errors.join("\n"))
    end
  end

  def test_a_non_string_entry_blocks
    m = with_mr([{ "name" => "alpha-reviewer" }])
    refute m.valid?
    assert_match(/must be a bare agent name/, m.errors.join("\n"))
  end

  def test_a_repeated_name_blocks
    m = with_mr(%w[alpha-reviewer alpha-reviewer])
    refute m.valid?
    assert_match(/lists alpha-reviewer more than once/, m.errors.join("\n"))
  end

  def test_an_unknown_key_under_mr_warns_without_blocking
    m = ManifestFixtures.load_with("valid", { "mr" => { "review_agents" => %w[alpha], "rounds" => 3 } })
    assert m.valid?, m.errors.inspect
    assert_match(/unknown key mr\.rounds/, m.warnings.join("\n"))
  end

  # The split this section is built on, asserted directly: validate! runs on
  # every script's manifest load, so it must not go looking for the agent
  # files. Resolving them is the lint's job (see the CLI test below).
  # sabotage: move the resolve check into validate! -> red.
  def test_validate_does_not_resolve_the_agent_files
    m = with_mr(%w[nothing-ships-this-agent])
    assert m.valid?, "validate! must not touch the filesystem: #{m.errors.inspect}"
    assert_empty m.warnings
  end
end

# external_tracker (ADR-0018 section 2 and wu-yi7.4's statuses/assignee
# addition). Two properties under test throughout: present-or-absent, never
# half-present, and the kit never learns the tracker's status vocabulary -
# it only carries the consumer's strings through to the lifecycle array.
class ManifestExternalTrackerTest < Minitest::Test
  def with_external_tracker(overrides)
    ManifestFixtures.load_with("valid", { "external_tracker" => overrides })
  end

  # sabotage: warn on the absent section -> red. Silence is the contract.
  def test_an_absent_section_is_silent
    m = ManifestFixtures.load("valid")
    assert m.valid?
    assert_empty m.warnings
    refute m.external_tracker?
    assert_nil m.external_tracker
    assert_empty m.external_tracker_lifecycle
  end

  def test_minimal_present_section_is_valid_with_defaults
    m = with_external_tracker({ "id_pattern" => "[A-Z]+-[0-9]+" })
    assert m.valid?, m.errors.inspect
    assert_empty m.warnings
    assert m.external_tracker?
    refute m.external_tracker_subject_prefix?
    assert_empty m.external_tracker_statuses
    assert_empty m.external_tracker_lifecycle
  end

  def test_missing_id_pattern_blocks
    m = ManifestFixtures.load_with("valid", { "external_tracker" => { "subject_prefix" => true } })
    refute m.valid?
    assert_match(/external_tracker\.id_pattern must be a non-empty regex source string/, m.errors.join("\n"))
    assert_match(/omit the external_tracker section entirely/, m.errors.join("\n"))
  end

  def test_empty_id_pattern_blocks
    m = with_external_tracker({ "id_pattern" => "" })
    refute m.valid?
    assert_match(/external_tracker\.id_pattern must be a non-empty regex source string/, m.errors.join("\n"))
  end

  def test_non_string_id_pattern_blocks
    m = with_external_tracker({ "id_pattern" => 3 })
    refute m.valid?
    assert_match(/external_tracker\.id_pattern must be a non-empty regex source string/, m.errors.join("\n"))
  end

  def test_uncompilable_id_pattern_blocks_naming_the_regexp_error
    m = with_external_tracker({ "id_pattern" => "[" })
    refute m.valid?
    assert_match(/external_tracker\.id_pattern/, m.errors.join("\n"))
  end

  def test_id_pattern_is_anchored_over_the_whole_value
    m = with_external_tracker({ "id_pattern" => "[A-Z]+-[0-9]+" })
    assert m.valid?, m.errors.inspect
    assert m.external_tracker_id_pattern.match?("ABC-12")
    refute m.external_tracker_id_pattern.match?("xABC-12y")
  end

  def test_subject_prefix_string_true_blocks
    m = with_external_tracker({ "id_pattern" => "X-[0-9]+", "subject_prefix" => "true" })
    refute m.valid?
    assert_match(/external_tracker\.subject_prefix must be true or false/, m.errors.join("\n"))
  end

  def test_subject_prefix_true_is_read
    m = with_external_tracker({ "id_pattern" => "X-[0-9]+", "subject_prefix" => true })
    assert m.valid?, m.errors.inspect
    assert m.external_tracker_subject_prefix?
  end

  def test_partial_statuses_map_is_valid_and_lifecycle_carries_declared_events_in_order
    m = with_external_tracker(
      "id_pattern" => "X-[0-9]+",
      # JSON order deliberately reversed from EXTERNAL_TRACKER_EVENTS order.
      "statuses" => { "closed" => "Done", "claimed" => "Todo" }
    )
    assert m.valid?, m.errors.inspect
    assert_equal %w[claimed closed], m.external_tracker_lifecycle.map { |e| e["event"] }
    assert_equal "Todo", m.external_tracker_lifecycle.first["status"]
    assert_equal "agent", m.external_tracker_lifecycle.first["holder"]
    assert_equal "owner", m.external_tracker_lifecycle.last["holder"]
  end

  def test_empty_statuses_blocks
    m = with_external_tracker({ "id_pattern" => "X-[0-9]+", "statuses" => {} })
    refute m.valid?
    assert_match(/external_tracker\.statuses must be a non-empty object/, m.errors.join("\n"))
  end

  def test_statuses_non_string_value_blocks_naming_the_event
    m = with_external_tracker({ "id_pattern" => "X-[0-9]+", "statuses" => { "claimed" => 3 } })
    refute m.valid?
    assert_match(/external_tracker\.statuses\.claimed must be a non-empty string/, m.errors.join("\n"))
  end

  def test_unknown_status_event_warns_without_blocking
    m = with_external_tracker(
      "id_pattern" => "X-[0-9]+",
      "statuses" => { "claimed" => "Todo", "abandoned" => "Wontfix" }
    )
    assert m.valid?, m.errors.inspect
    assert_match(/unknown key external_tracker\.statuses\.abandoned/, m.warnings.join("\n"))
  end

  def test_assignee_with_both_ids_yields_lifecycle_assignee_by_holder
    m = with_external_tracker(
      "id_pattern" => "X-[0-9]+",
      "statuses" => { "claimed" => "Todo", "request_opened" => "In Review",
                      "needs_attention" => "Needs Attention", "closed" => "Done" },
      "assignee" => { "agent" => "bot-account-1", "owner" => "human-account-1" }
    )
    assert m.valid?, m.errors.inspect
    by_event = m.external_tracker_lifecycle.to_h { |e| [e["event"], e["assignee"]] }
    assert_equal "bot-account-1", by_event["claimed"]
    assert_equal "bot-account-1", by_event["request_opened"]
    assert_equal "human-account-1", by_event["needs_attention"]
    assert_equal "human-account-1", by_event["closed"]
  end

  def test_assignee_missing_owner_blocks
    m = with_external_tracker(
      "id_pattern" => "X-[0-9]+",
      "statuses" => { "claimed" => "Todo" },
      "assignee" => { "agent" => "bot-account-1" }
    )
    refute m.valid?
    assert_match(/external_tracker\.assignee must be an object with non-empty string ids under agent and owner/, m.errors.join("\n"))
  end

  def test_assignee_non_hash_blocks
    m = with_external_tracker(
      "id_pattern" => "X-[0-9]+",
      "statuses" => { "claimed" => "Todo" },
      "assignee" => "bot-account-1"
    )
    refute m.valid?
    assert_match(/external_tracker\.assignee must be an object with non-empty string ids under agent and owner/, m.errors.join("\n"))
  end

  def test_assignee_without_statuses_blocks
    m = with_external_tracker(
      "id_pattern" => "X-[0-9]+",
      "assignee" => { "agent" => "bot-account-1", "owner" => "human-account-1" }
    )
    refute m.valid?
    assert_match(/external_tracker\.assignee is declared but external_tracker\.statuses is not/, m.errors.join("\n"))
  end

  def test_non_object_section_blocks
    m = ManifestFixtures.load_with("valid", { "external_tracker" => ["X-[0-9]+"] })
    refute m.valid?
    assert_match(/external_tracker must be an object/, m.errors.join("\n"))
  end

  def test_unknown_key_under_external_tracker_warns_without_blocking
    m = with_external_tracker({ "id_pattern" => "X-[0-9]+", "priority" => "high" })
    assert m.valid?, m.errors.inspect
    assert_match(/unknown key external_tracker\.priority/, m.warnings.join("\n"))
  end
end

# The lint's environmental check: a declared name with no agent file behind
# it.
class ManifestMrReviewAgentsLintTest < Minitest::Test
  # A throwaway checkout: <root>/.claude/wurk.json, so checkout_root - and
  # therefore the .claude/agents lookup - lands where the fixture writes it.
  # `ships` are the consumer's own agents under <root>/.claude/agents/;
  # `installed` are the roster under a throwaway HOME's .claude/agents/, the
  # directory install.rb links wurk's shipped agents into. HOME is always
  # pointed at the throwaway so the real machine's roster can never make a
  # test pass by accident.
  def in_checkout(agents:, ships: [], installed: [])
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |home|
        raw = JSON.parse(File.read(ManifestFixtures.path("valid")))
        raw["mr"] = { "review_agents" => agents } unless agents.nil?
        FileUtils.mkdir_p(File.join(root, ".claude"))
        manifest = File.join(root, ".claude", "wurk.json")
        File.write(manifest, JSON.pretty_generate(raw))

        write_agents(File.join(root, ".claude", "agents"), ships)
        write_agents(File.join(home, ".claude", "agents"), installed)

        saved_home = ENV["HOME"]
        ENV["HOME"] = home
        begin
          io = StringIO.new
          code = ManifestCli.run(["check", "--file", manifest], io: io)
          yield code, JSON.parse(io.string)
        ensure
          ENV["HOME"] = saved_home
        end
      end
    end
  end

  # artifacts.adr: absent is off, declared-and-present is the path,
  # declared-and-missing blocks in the lint only.
  def in_checkout_with_adr(adr:, mkdir: true)
    Dir.mktmpdir do |root|
      raw = JSON.parse(File.read(ManifestFixtures.path("valid")))
      raw["artifacts"]["adr"] = adr unless adr.nil?
      FileUtils.mkdir_p(File.join(root, ".claude"))
      manifest = File.join(root, ".claude", "wurk.json")
      File.write(manifest, JSON.pretty_generate(raw))
      FileUtils.mkdir_p(File.join(root, adr)) if adr.is_a?(String) && mkdir && !adr.empty?

      io = StringIO.new
      code = ManifestCli.run(["check", "--file", manifest], io: io)
      yield code, JSON.parse(io.string)
    end
  end

  # sabotage: default adr_dir to "docs/adr" when absent -> red (absent
  # must report nil, so a skill can tell "said" from "guessed").
  def test_an_absent_adr_key_reports_nil_and_does_not_block
    in_checkout_with_adr(adr: nil) do |code, env|
      assert_equal 0, code
      assert_nil env["data"]["artifacts_adr"]
      refute_includes blocked_codes(env), "artifacts_adr_missing"
    end
  end

  # sabotage: drop env.data[:artifacts_adr] from the check -> red.
  def test_a_declared_adr_dir_that_exists_is_reported
    in_checkout_with_adr(adr: "docs/decisions") do |code, env|
      assert_equal 0, code
      assert_equal "docs/decisions", env["data"]["artifacts_adr"]
    end
  end

  # sabotage: delete block_missing_adr_dir's call site -> red.
  def test_a_declared_adr_dir_that_is_missing_blocks
    in_checkout_with_adr(adr: "docs/decisions", mkdir: false) do |code, env|
      assert_equal 1, code
      assert_includes blocked_codes(env), "artifacts_adr_missing"
      assert_match(%r{docs/decisions}, env["blocked"].map { |b| b["message"] }.join)
    end
  end

  # sabotage: accept an absolute path in validate_artifacts_adr -> red.
  def test_an_absolute_or_empty_adr_value_blocks_on_shape
    ["", "/abs/adr", 3].each do |bad|
      in_checkout_with_adr(adr: bad, mkdir: false) do |code, env|
        assert_equal 1, code, "expected #{bad.inspect} to block"
        assert_match(/artifacts\.adr must be a non-empty/, env["blocked"].map { |b| b["message"] }.join)
      end
    end
  end

  def write_agents(dir, names)
    return if names.empty?

    FileUtils.mkdir_p(dir)
    names.each { |name| File.write(File.join(dir, "#{name}.md"), "---\nname: #{name}\n---\n") }
  end

  # sabotage: drop the home root from mr_review_agent_roots -> red (the
  # installed name is then unresolved and the check blocks).
  def test_an_installed_agent_resolves_without_a_consumer_file
    in_checkout(agents: %w[wurk-diff-critic], installed: %w[wurk-diff-critic]) do |code, env|
      assert_equal 0, code
      assert_equal true, env["ok"]
      refute_includes blocked_codes(env), "mr_review_agent_missing"
      assert_equal %w[wurk-diff-critic], env["data"]["mr_review_agents"]
    end
  end

  # sabotage: resolve against the home root before the consumer root ->
  # still green here, so this test pins precedence a different way: the
  # consumer file is the only one that exists and must be enough.
  def test_a_consumer_file_resolves_when_nothing_is_installed
    in_checkout(agents: %w[wurk-diff-critic], ships: %w[wurk-diff-critic]) do |code, env|
      assert_equal 0, code
      refute_includes blocked_codes(env), "mr_review_agent_missing"
    end
  end

  # sabotage: make mr_review_agent_path return the first candidate path
  # without File.file? -> red (nothing exists, yet nothing is reported).
  def test_a_name_in_neither_root_blocks_and_names_both_roots
    in_checkout(agents: %w[wurk-diff-critic], ships: [], installed: %w[wurk-test-critic]) do |code, env|
      assert_equal 1, code
      assert_includes blocked_codes(env), "mr_review_agent_missing"
      message = env["blocked"].map { |b| b["message"] }.join
      assert_match(%r{\.claude/agents.*\.claude/agents}m, message)
      assert_match(/install\.rb/, message)
    end
  end

  # sabotage: read ENV["HOME"] at require time instead of call time -> red
  # (the throwaway HOME set by in_checkout is never seen).
  def test_home_is_read_when_the_check_runs
    manifest = Manifest.new(path: "/x/.claude/wurk.json", raw: JSON.parse(File.read(ManifestFixtures.path("valid"))))
    roots = manifest.mr_review_agent_roots(root: "/x", home: "/h")
    assert_equal ["/x/.claude/agents", "/h/.claude/agents"], roots
  end

  def blocked_codes(env)
    env["blocked"].map { |b| b["code"] }
  end

  def test_a_declared_agent_that_ships_passes
    in_checkout(agents: %w[alpha-reviewer beta-reviewer], ships: %w[alpha-reviewer beta-reviewer]) do |code, env|
      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal %w[alpha-reviewer beta-reviewer], env["data"]["mr_review_agents"]
    end
  end

  # sabotage: delete block_unresolved_review_agents' call site -> red.
  def test_a_declared_agent_with_no_file_blocks
    in_checkout(agents: %w[alpha-reviewer beta-reviewer], ships: %w[alpha-reviewer]) do |code, env|
      assert_equal 1, code
      assert_equal false, env["ok"]
      assert_includes blocked_codes(env), "mr_review_agent_missing"
      message = env["blocked"].map { |b| b["message"] }.join
      assert_match(/names beta-reviewer/, message)
      refute_match(/alpha-reviewer,/, message)
    end
  end

  # sabotage: warn instead of block -> red. There is no legitimate reading
  # of a name with no agent behind it.
  def test_an_absent_section_needs_no_agents_directory
    in_checkout(agents: nil) do |code, env|
      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_empty env["data"]["mr_review_agents"]
      refute_includes blocked_codes(env), "mr_review_agent_missing"
    end
  end

  # A malformed value blocks on shape and must not also crash the resolve
  # check on its way through.
  def test_a_malformed_value_blocks_on_shape_without_crashing
    in_checkout(agents: { "first" => "alpha-reviewer" }) do |code, env|
      assert_equal 1, code
      assert_match(/mr\.review_agents must be a non-empty array/, env["blocked"].map { |b| b["message"] }.join)
      refute_includes blocked_codes(env), "mr_review_agent_missing"
    end
  end
end

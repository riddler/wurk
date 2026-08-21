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

  # sabotage: drop the DEFAULTS["tmux.permission_mode"] entry -> red
  def test_tmux_permission_mode_defaults_to_auto
    m = ManifestFixtures.load("tmux")
    assert_equal "auto", m.tmux_permission_mode
  end

  # sabotage: drop "tmux.permission_mode" from ENUMS -> red
  def test_unrecognized_tmux_permission_mode_blocks_rather_than_defaulting
    m = ManifestFixtures.load_with("tmux", "tmux" => { "permission_mode" => "yolo" })
    refute m.valid?
    assert_match(
      /tmux\.permission_mode is "yolo"; expected one of auto, default, acceptEdits, plan, skip-permissions/,
      m.errors.join("\n")
    )
  end

  # sabotage: drop "permission_mode" from KNOWN["tmux"] -> red, since a valid
  # value would then warn as an unknown key instead of validating as known
  def test_tmux_permission_mode_produces_no_unknown_key_warning
    m = ManifestFixtures.load_with("tmux", "tmux" => { "permission_mode" => "skip-permissions" })
    assert m.valid?, "expected skip-permissions to validate: #{m.errors.inspect}"
    assert_empty m.warnings, "tmux.permission_mode must be a known key: #{m.warnings.inspect}"
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
    assert_equal 600, @m.parallelism_timeout_seconds
  end

  # sabotage: read the wrong dotted key, or drop the DEFAULTS entry, in
  # gate_timeout_seconds -> red
  def test_gate_timeout_seconds_reads_an_explicit_value
    m = ManifestFixtures.load_with("valid", "gate" => { "timeout_seconds" => 1800 })
    assert_equal 1800, m.gate_timeout_seconds
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
    assert_nil @m.gate_chdir
    assert_nil @m.gate_chdir(root: "/some/worktree")
  end

  # sabotage: join against Dir.pwd instead of the default root argument -> red
  def test_gate_chdir_joins_gate_cwd_onto_the_default_checkout_root
    m = ManifestFixtures.load("gate_subdir")
    assert_equal File.join(m.checkout_root, "backend"), m.gate_chdir
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

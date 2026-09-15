# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../lib/user_config"
require_relative "support/user_config_helper"

class UserConfigResolutionTest < Minitest::Test
  include UserConfigHelper

  def teardown
    UserConfig.reset!
  end

  # sabotage: raise instead of returning a valid instance when the file is
  # absent -> red
  def test_absent_file_is_valid_with_defaults_and_no_warnings
    in_tmp_home(nil) do
      config = UserConfig.load
      assert config.valid?
      refute config.exists?
      assert_equal "auto", config.tmux_permission_mode
      assert_empty config.warnings
    end
  end

  # sabotage: drop the "".freeze empty-hash default and make an empty file
  # (parsed "{}") count as absent -> red
  def test_empty_object_file_is_valid_all_defaults
    in_tmp_home({}) do
      config = UserConfig.load
      assert config.valid?
      assert config.exists?
      assert_equal "auto", config.tmux_permission_mode
    end
  end

  # sabotage: drop the HOME-anchored resolution and fall back to walking up
  # from Dir.pwd -> red, since the repo-local file would then be picked up
  def test_repo_local_file_is_not_read_when_home_is_elsewhere
    Dir.mktmpdir do |repo_dir|
      FileUtils.mkdir_p(File.join(repo_dir, ".claude"))
      File.write(
        File.join(repo_dir, ".claude", "wurk.local.json"),
        JSON.generate("tmux" => { "permission_mode" => "plan" })
      )

      in_tmp_home(nil) do
        Dir.chdir(repo_dir) do
          config = UserConfig.load
          refute config.exists?
          assert_equal "auto", config.tmux_permission_mode
        end
      end
    end
  end

  ENUMS = %w[auto default acceptEdits plan skip-permissions].freeze

  # sabotage: drop "skip-permissions" (or any entry) from ENUMS -> red
  def test_each_enum_value_round_trips_through_a_real_file
    ENUMS.each do |mode|
      in_tmp_home("tmux" => { "permission_mode" => mode }) do
        config = UserConfig.load
        assert config.valid?, "#{mode}: #{config.errors.inspect}"
        assert_equal mode, config.tmux_permission_mode
      end
    end
  end

  # sabotage: let validate_enums fall back to a default instead of erroring
  # -> red
  def test_unrecognized_value_blocks_and_names_file_key_value_and_allowed_set
    in_tmp_home("tmux" => { "permission_mode" => "yolo" }) do
      config = UserConfig.load
      refute config.valid?
      assert_match(
        /tmux\.permission_mode is "yolo"; expected one of auto, default, acceptEdits, plan, skip-permissions/,
        config.errors.join("\n")
      )
      assert_includes config.errors.join("\n"), config.path
    end
  end

  # sabotage: stop rescuing JSON::ParserError and re-raise raw -> red (this
  # test expects a clean invalid instance, not an exception)
  def test_unparseable_json_blocks_and_names_the_path
    Dir.mktmpdir do |dir|
      write_raw_user_config(dir, "{ not json")
      in_tmp_home(nil) do
        ENV["HOME"] = dir
        error = assert_raises(JSON::ParserError) { UserConfig.load }
        assert_includes error.message, File.join(dir, ".claude", "wurk.local.json")
      end
    end
  end

  # sabotage: interpolate the rescued JSON::ParserError's own message -> red.
  # That message quotes the offending source, and this file is where the
  # outbound scan's control_term lives; the quoted text travels from here
  # into a block! message and out of the pre-push hook on stdout. Position
  # only. Every token below is invented nonsense, which is the point.
  def test_unparseable_json_never_quotes_the_files_own_content
    Dir.mktmpdir do |dir|
      token = "zqorbex-control-term-7714"
      write_raw_user_config(dir, %({"outbound_scan": {"control_term": #{token}}}))
      in_tmp_home(nil) do
        ENV["HOME"] = dir

        error = assert_raises(JSON::ParserError) { UserConfig.load }
        refute_includes error.message, token

        env = Envelope.new(script: "probe")
        assert_nil UserConfig.require!(env)
        refute_includes env.to_json, token
      end
    end
  end

  # sabotage: skip the empty-string special case and let JSON.parse("") raise
  # uncaught with a message that doesn't name the path -> red
  def test_empty_file_is_unparseable
    Dir.mktmpdir do |dir|
      write_raw_user_config(dir, "")
      ENV["HOME"] = dir
      assert_raises(JSON::ParserError) { UserConfig.load }
    ensure
      ENV.delete("HOME")
    end
  end

  # sabotage: accept an array top level as if it were a hash -> red
  def test_non_object_top_level_blocks
    Dir.mktmpdir do |dir|
      write_raw_user_config(dir, "[]")
      ENV["HOME"] = dir
      config = UserConfig.load
      refute config.valid?
      assert_includes config.errors.join("\n"), config.path
    ensure
      ENV.delete("HOME")
    end
  end

  # sabotage: accept any schema version -> red
  def test_wrong_schema_version_blocks
    in_tmp_home("wurk" => 2) do
      config = UserConfig.load
      refute config.valid?
    end
  end

  def test_matching_schema_version_is_valid
    in_tmp_home("wurk" => 1, "tmux" => { "permission_mode" => "plan" }) do
      config = UserConfig.load
      assert config.valid?, config.errors.inspect
    end
  end

  def test_absent_schema_version_is_valid
    in_tmp_home("tmux" => { "permission_mode" => "plan" }) do
      config = UserConfig.load
      assert config.valid?, config.errors.inspect
    end
  end

  # sabotage: move unknown keys from warnings to errors -> red
  def test_unknown_key_warns_exactly_once_and_stays_valid
    in_tmp_home("nope" => 1) do
      config = UserConfig.load
      assert config.valid?
      assert_equal 1, config.warnings.size
      assert_match(/unknown key nope/, config.warnings.first)
    end
  end
end

class UserConfigOutboundScanTest < Minitest::Test
  include UserConfigHelper

  def teardown
    UserConfig.reset!
  end

  # sabotage: make outbound_scan_declared? default to true -> red
  def test_absent_section_is_valid_and_not_declared
    in_tmp_home(nil) do
      config = UserConfig.load
      assert config.valid?
      refute config.outbound_scan_declared?
      assert_nil config.outbound_scan_patterns_file
      assert_nil config.outbound_scan_control_term
      assert_empty config.warnings
    end
  end

  # sabotage: swap the two accessor fetches -> red
  def test_full_section_reads_both_values_back
    in_tmp_home(
      "outbound_scan" => {
        "patterns_file" => "(fixture patterns path)",
        "control_term" => "fixture-control-token"
      }
    ) do
      config = UserConfig.load
      assert config.valid?, config.errors.inspect
      assert config.outbound_scan_declared?
      assert_equal "(fixture patterns path)", config.outbound_scan_patterns_file
      assert_equal "fixture-control-token", config.outbound_scan_control_term
    end
  end

  # sabotage: drop "outbound_scan" from KNOWN's nil-prefix list, or drop the
  # "outbound_scan" => %w[patterns_file control_term] entry -> red (the
  # unknown-key walk would then warn on the whole section, or on the known
  # keys within it)
  def test_unknown_key_under_section_warns_and_does_not_block
    in_tmp_home(
      "outbound_scan" => {
        "patterns_file" => "(fixture patterns path)",
        "control_term" => "fixture-control-token",
        "extra_future_key" => "x"
      }
    ) do
      config = UserConfig.load
      assert config.valid?, config.errors.inspect
      assert_equal 1, config.warnings.size
      assert_match(/unknown key outbound_scan\.extra_future_key/, config.warnings.first)
    end
  end

  # sabotage: accept a non-string patterns_file silently -> red
  def test_non_string_patterns_file_blocks
    in_tmp_home("outbound_scan" => { "patterns_file" => 5 }) do
      config = UserConfig.load
      refute config.valid?
      assert_match(/outbound_scan\.patterns_file must be a string/, config.errors.join("\n"))
    end
  end

  # sabotage: accept a non-string control_term silently -> red
  def test_non_string_control_term_blocks
    in_tmp_home(
      "outbound_scan" => { "patterns_file" => "(fixture patterns path)", "control_term" => false }
    ) do
      config = UserConfig.load
      refute config.valid?
      assert_match(/outbound_scan\.control_term must be a string/, config.errors.join("\n"))
    end
  end

  # sabotage: skip the blank-after-strip check -> red
  def test_blank_patterns_file_blocks
    in_tmp_home("outbound_scan" => { "patterns_file" => "   " }) do
      config = UserConfig.load
      refute config.valid?
      assert_match(/outbound_scan\.patterns_file must not be blank/, config.errors.join("\n"))
    end
  end

  # sabotage: accept a non-object outbound_scan section (e.g. an array or
  # string) as if it were a hash -> red
  def test_non_object_section_blocks
    in_tmp_home("outbound_scan" => "not-an-object") do
      config = UserConfig.load
      refute config.valid?
      assert_match(/outbound_scan must be a JSON object/, config.errors.join("\n"))
    end
  end

  # sabotage: skip the empty-hash special case -> red
  def test_empty_object_section_blocks
    in_tmp_home("outbound_scan" => {}) do
      config = UserConfig.load
      refute config.valid?
      assert_match(/configures neither patterns_file nor control_term/, config.errors.join("\n"))
    end
  end

  # sabotage: turn the one-key case into a load-time error -> red. Per the
  # plan, incompleteness with exactly one key present is a Phase 2
  # scan-time concern, not a UserConfig validation error.
  def test_section_with_only_patterns_file_is_valid_at_load_time
    in_tmp_home("outbound_scan" => { "patterns_file" => "(fixture patterns path)" }) do
      config = UserConfig.load
      assert config.valid?, config.errors.inspect
      assert config.outbound_scan_declared?
      assert_equal "(fixture patterns path)", config.outbound_scan_patterns_file
      assert_nil config.outbound_scan_control_term
    end
  end

  # sabotage: same as above, the other key
  def test_section_with_only_control_term_is_valid_at_load_time
    in_tmp_home("outbound_scan" => { "control_term" => "fixture-control-token" }) do
      config = UserConfig.load
      assert config.valid?, config.errors.inspect
      assert config.outbound_scan_declared?
      assert_nil config.outbound_scan_patterns_file
      assert_equal "fixture-control-token", config.outbound_scan_control_term
    end
  end
end

class UserConfigMachineTest < Minitest::Test
  include UserConfigHelper

  def teardown
    UserConfig.reset!
  end

  # sabotage: give machine_name or machine_gate_slots a default (the
  # hostname, 1) -> red. Absent means "not said", and lock.rb's precedence
  # rule depends on nil meaning exactly that.
  def test_absent_section_reads_nil_for_both_and_stays_valid
    in_tmp_home(nil) do
      config = UserConfig.load
      assert config.valid?
      assert_nil config.machine_name
      assert_nil config.machine_gate_slots
      assert_empty config.warnings
    end
  end

  # sabotage: swap the two accessor fetches -> red
  def test_full_section_reads_both_values_back
    in_tmp_home("machine" => { "name" => "fixture-box", "gate_slots" => 3 }) do
      config = UserConfig.load
      assert config.valid?, config.errors.inspect
      assert_equal "fixture-box", config.machine_name
      assert_equal 3, config.machine_gate_slots
    end
  end

  # sabotage: drop "machine" from KNOWN's nil-prefix list, or the
  # "machine" => %w[name gate_slots] entry -> red
  def test_unknown_key_under_section_warns_and_does_not_block
    in_tmp_home("machine" => { "name" => "fixture-box", "colour" => "beige" }) do
      config = UserConfig.load
      assert config.valid?, config.errors.inspect
      assert_equal 1, config.warnings.size
      assert_match(/unknown key machine\.colour/, config.warnings.first)
    end
  end

  # sabotage: accept a non-object machine section -> red
  def test_non_object_section_blocks
    in_tmp_home("machine" => "fixture-box") do
      config = UserConfig.load
      refute config.valid?
      assert_match(/machine must be a JSON object/, config.errors.join("\n"))
    end
  end

  # sabotage: skip the blank-after-strip check on name -> red
  def test_blank_or_non_string_name_blocks
    in_tmp_home("machine" => { "name" => "  " }) do
      refute UserConfig.load.valid?
    end
    in_tmp_home("machine" => { "name" => 7 }) do
      config = UserConfig.load
      refute config.valid?
      assert_match(/machine\.name must be a string/, config.errors.join("\n"))
    end
  end

  # sabotage: accept 0, a negative, a float, a string, or true as gate_slots
  # -> red. The value becomes the count of slot directories an acquire may
  # take; anything but a positive integer is a pool that can never grant.
  def test_gate_slots_must_be_a_positive_integer
    [0, -1, 2.5, "2", true].each do |bad|
      in_tmp_home("machine" => { "gate_slots" => bad }) do
        config = UserConfig.load
        refute config.valid?, "gate_slots=#{bad.inspect} should block"
        assert_match(/machine\.gate_slots must be a positive integer/, config.errors.join("\n"))
      end
    end
  end

  # sabotage: drop machine_gate_slots from the lint envelope -> red
  def test_check_reports_machine_fields
    Dir.mktmpdir do |dir|
      path = File.join(dir, "wurk.local.json")
      File.write(path, JSON.generate("machine" => { "name" => "fixture-box", "gate_slots" => 2 }))
      io = StringIO.new
      code = UserConfigCli.run(["check", "--file", path], io: io)
      env = JSON.parse(io.string)
      assert_equal 0, code
      assert_equal "fixture-box", env["data"]["machine_name"]
      assert_equal 2, env["data"]["machine_gate_slots"]
      assert_equal [], env["data"]["workloads"]
    end
  end
end

class UserConfigWorkloadsTest < Minitest::Test
  include UserConfigHelper

  def teardown
    UserConfig.reset!
  end

  def two_workloads
    [
      { "root" => "/fixture/primary", "fleet_manifest" => "/fixture/primary/.claude/wurk-fleet.json", "primary" => true },
      { "root" => "/fixture/secondary", "enabled" => false }
    ]
  end

  # sabotage: return nil instead of [] for an absent section -> red
  def test_absent_section_reads_as_empty_and_stays_valid
    in_tmp_home(nil) do
      config = UserConfig.load
      assert config.valid?
      assert_equal [], config.workloads
      assert_equal [], config.enabled_workloads
      assert_nil config.primary_workload
    end
  end

  # sabotage: drop a default from WORKLOAD_DEFAULTS, or stop expanding root
  # -> red. Every entry comes back with every key present so a caller never
  # has to know the defaults.
  def test_entries_are_normalized_with_every_key_present
    in_tmp_home("workloads" => two_workloads) do
      config = UserConfig.load
      assert config.valid?, config.errors.inspect
      assert_equal [
        { "root" => "/fixture/primary", "fleet_manifest" => "/fixture/primary/.claude/wurk-fleet.json",
          "enabled" => true, "primary" => true },
        { "root" => "/fixture/secondary", "fleet_manifest" => nil, "enabled" => false, "primary" => false }
      ], config.workloads
    end
  end

  # sabotage: expand root relative to Dir.pwd instead of HOME -> red
  def test_tilde_root_expands_against_home
    in_tmp_home("workloads" => [{ "root" => "~/fixture-root" }]) do |home|
      config = UserConfig.load
      assert_equal File.join(home, "fixture-root"), config.workloads.first["root"]
    end
  end

  # sabotage: swap the enabled/primary filters -> red
  def test_enabled_and_primary_selectors
    in_tmp_home("workloads" => two_workloads) do
      config = UserConfig.load
      assert_equal ["/fixture/primary"], config.enabled_workloads.map { |w| w["root"] }
      assert_equal "/fixture/primary", config.primary_workload["root"]
    end
  end

  # sabotage: accept an object (or string) where the array should be -> red
  def test_non_array_section_blocks
    in_tmp_home("workloads" => { "root" => "/fixture" }) do
      config = UserConfig.load
      refute config.valid?
      assert_match(/workloads must be a JSON array/, config.errors.join("\n"))
    end
  end

  # sabotage: let an entry without a root through -> red. Root is the
  # identity of a workload; there is nothing to default it to.
  def test_entry_without_root_blocks_and_names_its_index
    in_tmp_home("workloads" => [{ "root" => "/fixture/a" }, { "enabled" => true }]) do
      config = UserConfig.load
      refute config.valid?
      assert_match(/workloads\[1\]\.root must be a non-blank string/, config.errors.join("\n"))
    end
  end

  # sabotage: accept a non-object entry -> red
  def test_non_object_entry_blocks
    in_tmp_home("workloads" => ["/fixture/a"]) do
      config = UserConfig.load
      refute config.valid?
      assert_match(/workloads\[0\] must be a JSON object/, config.errors.join("\n"))
    end
  end

  # sabotage: compare raw strings instead of expanded paths -> red on the
  # trailing-slash variant
  def test_duplicate_root_blocks_after_expansion
    in_tmp_home("workloads" => [{ "root" => "/fixture/a" }, { "root" => "/fixture/a/" }]) do
      config = UserConfig.load
      refute config.valid?
      assert_match(/workloads\[1\]\.root duplicates/, config.errors.join("\n"))
    end
  end

  # sabotage: drop the primaries counter -> red. Two primaries is a question
  # ("which one?") the config must not leave to the reader.
  def test_two_primaries_block
    in_tmp_home("workloads" => [{ "root" => "/fixture/a", "primary" => true }, { "root" => "/fixture/b", "primary" => true }]) do
      config = UserConfig.load
      refute config.valid?
      assert_match(/marks 2 entries primary; at most one/, config.errors.join("\n"))
    end
  end

  # sabotage: accept "true" (a string) or 1 as a boolean -> red
  def test_enabled_and_primary_must_be_booleans
    in_tmp_home("workloads" => [{ "root" => "/fixture/a", "enabled" => "true" }]) do
      config = UserConfig.load
      refute config.valid?
      assert_match(/workloads\[0\]\.enabled must be true or false/, config.errors.join("\n"))
    end
  end

  # sabotage: accept a blank fleet_manifest -> red
  def test_blank_fleet_manifest_blocks
    in_tmp_home("workloads" => [{ "root" => "/fixture/a", "fleet_manifest" => "" }]) do
      config = UserConfig.load
      refute config.valid?
      assert_match(/workloads\[0\]\.fleet_manifest must be a non-blank string/, config.errors.join("\n"))
    end
  end

  # sabotage: drop the Array branch of collect_unknown_keys, or the
  # "workloads[]" KNOWN entry -> red (no warning at all, or a warning on
  # every known key)
  def test_unknown_key_inside_an_entry_warns_under_its_index
    in_tmp_home("workloads" => [{ "root" => "/fixture/a" }, { "root" => "/fixture/b", "nickname" => "b" }]) do
      config = UserConfig.load
      assert config.valid?, config.errors.inspect
      assert_equal 1, config.warnings.size
      assert_match(/unknown key workloads\[1\]\.nickname/, config.warnings.first)
    end
  end
end

class UserConfigRequireTest < Minitest::Test
  include UserConfigHelper

  def teardown
    UserConfig.reset!
  end

  # sabotage: let require! return the config anyway when invalid -> red
  def test_require_blocks_the_envelope_on_an_invalid_config
    with_user_config("tmux" => { "permission_mode" => "yolo" }) do
      env = Envelope.new(script: "probe")
      assert_nil UserConfig.require!(env)
      refute env.ok?
      assert_equal ["user_config_invalid"], env.blocked.map { |b| b[:code] }.uniq
    end
  end

  def test_require_returns_an_instance_with_no_envelope_entries_when_absent
    with_user_config(nil) do
      env = Envelope.new(script: "probe")
      config = UserConfig.require!(env)
      refute_nil config
      assert env.ok?
      assert_empty env.warnings
      assert_empty env.blocked
    end
  end

  def test_require_forwards_unknown_key_warnings_and_returns_the_config
    with_user_config("nope" => 1) do
      env = Envelope.new(script: "probe")
      config = UserConfig.require!(env)
      refute_nil config
      assert env.ok?
      assert_equal ["user_config_unknown_key"], env.warnings.map { |w| w[:code] }.uniq
    end
  end

  # sabotage: stop rescuing JSON::ParserError in require! -> red (an
  # exception escaping mid-run instead of a blocked envelope)
  def test_require_blocks_the_envelope_on_unparseable_json
    Dir.mktmpdir do |dir|
      UserConfigHelper.write_raw_user_config(dir, "{ not json")
      previous_home = ENV["HOME"]
      ENV["HOME"] = dir
      env = Envelope.new(script: "probe")
      assert_nil UserConfig.require!(env)
      refute env.ok?
      assert_equal ["user_config_unavailable"], env.blocked.map { |b| b[:code] }.uniq
    ensure
      ENV["HOME"] = previous_home
    end
  end
end

class UserConfigCliTest < Minitest::Test
  def teardown
    UserConfig.reset!
  end

  def run_cli(argv)
    io = StringIO.new
    code = UserConfigCli.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  def with_config_file(hash)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "wurk.local.json")
      File.write(path, JSON.generate(hash))
      yield path
    end
  end

  def test_check_passes_against_a_valid_config
    with_config_file("tmux" => { "permission_mode" => "acceptEdits" }) do |path|
      code, env = run_cli(["check", "--file", path])
      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal true, env["data"]["valid"]
      assert_equal "acceptEdits", env["data"]["tmux_permission_mode"]
    end
  end

  # sabotage: emit ok:true regardless of errors -> red
  def test_check_fails_usefully_against_an_invalid_config
    with_config_file("tmux" => { "permission_mode" => "yolo" }) do |path|
      code, env = run_cli(["check", "--file", path])
      assert_equal 1, code
      assert_equal false, env["ok"]
      refute_empty env["blocked"]
      assert_match(/tmux\.permission_mode is "yolo"/, env["blocked"].map { |b| b["message"] }.join("\n"))
    end
  end

  def test_check_reports_a_missing_file_as_absent_not_an_error
    code, env = run_cli(["check", "--file", "/nonexistent/wurk.local.json"])
    assert_equal 0, code
    assert_equal true, env["ok"]
    assert_equal false, env["data"]["exists"]
    assert_equal "auto", env["data"]["tmux_permission_mode"]
    assert_equal false, env["data"]["outbound_scan_declared"]
  end

  # sabotage: leave outbound_scan_declared off the emitted envelope, or add
  # outbound_scan_patterns_file to it -> red
  def test_check_reports_outbound_scan_declared_but_not_the_patterns_path
    with_config_file(
      "outbound_scan" => {
        "patterns_file" => "(fixture patterns path)",
        "control_term" => "fixture-control-token"
      }
    ) do |path|
      code, env = run_cli(["check", "--file", path])
      assert_equal 0, code
      assert_equal true, env["data"]["outbound_scan_declared"]
      refute env["data"].key?("outbound_scan_patterns_file")
    end
  end

  def test_check_reports_unparseable_json_without_crashing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "wurk.local.json")
      File.write(path, "{ not json")
      code, env = run_cli(["check", "--file", path])
      assert_equal 1, code
      assert_equal ["unparseable"], env["blocked"].map { |b| b["code"] }
    end
  end
end

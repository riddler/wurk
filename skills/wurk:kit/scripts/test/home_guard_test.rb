# frozen_string_literal: true

require "minitest/autorun"
require_relative "support/home_guard"
require_relative "../lib/user_config"

# The suite-wide HOME guard (support/home_guard.rb) and the rule that keeps
# it in force: every test file loads it, directly or through a support
# helper, and no test deletes HOME out from under it. See wu-yi7.11.
class HomeGuardTest < Minitest::Test
  TEST_DIR = File.expand_path(__dir__)
  SUPPORTS_WITH_GUARD = %w[home_guard manifest_helper user_config_helper fake_sh dead_pid].freeze

  # sabotage: drop the ENV["HOME"] assignment from HomeGuard.install! -> red
  def test_home_points_at_the_guard_dir_and_never_at_the_original
    assert HomeGuard.installed?
    assert_equal HomeGuard.dir, ENV["HOME"]
    assert Dir.exist?(HomeGuard.dir)
    refute_equal HomeGuard.original_home, ENV["HOME"] if HomeGuard.original_home
  end

  # sabotage: seed the guard dir with a .claude/wurk.local.json, or make
  # install! reuse a fixed path instead of a fresh mktmpdir -> red. The
  # property that matters: a load nobody prepared for finds no file.
  def test_a_bare_load_under_the_guard_finds_no_config
    refute File.exist?(File.join(ENV["HOME"], ".claude", "wurk.local.json"))
    UserConfig.reset!
    config = UserConfig.load
    refute config.exists?
    assert config.valid?
    assert_equal HomeGuard.dir, File.dirname(File.dirname(config.path))
  ensure
    UserConfig.reset!
  end

  # sabotage: make install! run a second mktmpdir on a repeat call -> red
  # (every support helper requires the guard; the second require must be a
  # no-op or HOME moves mid-process and in_tmp_home's restore lands on a
  # stale dir)
  def test_install_is_idempotent
    assert_equal HomeGuard.dir, HomeGuard.install!
    assert_equal HomeGuard.dir, ENV["HOME"]
  end

  # sabotage: remove the support/home_guard require from any one of the four
  # bare test files, or from a support helper that a test file relies on ->
  # red, naming the file. A test file that loads none of the guarded supports
  # can run by hand (`ruby lock_test.rb`) against the operator's real HOME,
  # which is exactly the leak the guard exists to close.
  def test_every_test_file_loads_the_guard
    unguarded = Dir.glob(File.join(TEST_DIR, "*_test.rb")).sort.reject do |file|
      content = File.read(file)
      SUPPORTS_WITH_GUARD.any? { |name| content.include?(%(require_relative "support/#{name}")) }
    end
    assert_empty unguarded.map { |f| File.basename(f) },
                 "test files that load no guard-carrying support helper (see support/home_guard.rb)"
  end

  # sabotage: put an ENV-delete of the HOME key back into any test -> red.
  # Deleting the key (rather than restoring the previous value) drops the
  # guard: UserConfig falls through to Dir.home, which is the real home
  # directory regardless of what the guard set. The pattern is built from
  # pieces so this file does not match itself.
  def test_no_test_deletes_home
    pattern = Regexp.new(["ENV", "\.delete\(\s*", "[\"']HOME[\"']", "\s*\)"].join)
    offenders = Dir.glob(File.join(TEST_DIR, "**", "*.rb")).sort.select do |file|
      File.read(file).match?(pattern)
    end
    assert_empty offenders.map { |f| f.sub("#{TEST_DIR}/", "") },
                 "deleting the HOME key drops the suite-wide HOME guard; restore the previous value instead"
  end

  # sabotage: let every guarded support helper stop requiring home_guard ->
  # red. The file-level rule above only holds if the helpers it accepts as
  # proxies really do install the guard.
  def test_every_accepted_support_helper_requires_the_guard
    (SUPPORTS_WITH_GUARD - %w[home_guard]).each do |name|
      content = File.read(File.join(TEST_DIR, "support", "#{name}.rb"))
      assert_includes content, %(require_relative "home_guard"), "support/#{name}.rb must require home_guard"
    end
  end
end

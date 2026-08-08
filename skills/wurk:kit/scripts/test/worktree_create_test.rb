# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../worktree_create"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"

class WorktreeCreateTest < Minitest::Test
  include ManifestHelper

  # Every value this script used to hardcode now comes from the `worktree`
  # fixture: a "../zz-worktrees" sibling dir, a `faketool trust {path}`
  # trust step, vendor/build as the cloned caches, and `make quick` as the
  # gate. Asserting on `mise trust` or `mix quality` here would have gone
  # green whether or not the script read the manifest at all.
  FIXTURE = "worktree"

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
  end

  def run_create(argv)
    io = StringIO.new
    code = WorktreeCreate.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  def expect_location(root)
    @fake.expect(%w[git rev-parse --git-dir], out: "#{root}/.git\n")
    @fake.expect(%w[git rev-parse --git-common-dir], out: "#{root}/.git\n")
    @fake.expect(%w[git rev-parse --show-toplevel], out: "#{root}\n")
  end

  # A scratch main checkout plus the sibling worktrees dir the fixture's
  # "../zz-worktrees" resolves to.
  def with_scratch_repo
    with_manifest(FIXTURE) do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "myrepo")
        FileUtils.mkdir_p(root)
        yield root, File.join(tmp, "zz-worktrees")
      end
    end
  end

  # sabotage: drop the parallelism_model guard in worktree_create.rb -> red
  def test_blocks_under_a_parallelism_model_that_has_no_worktrees
    manifest = manifest_with(FIXTURE, "parallelism" => { "model" => "branch-in-place" })

    with_manifest(manifest) do
      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 1, code
      assert_equal "wrong_parallelism_model", env["blocked"].first["code"]
      assert_match(/branch-in-place/, env["blocked"].first["message"])
    end
  end

  # sabotage: drop the worktrees_dir guard -> red (the worktree would be
  # created inside the checkout it was branched from)
  def test_blocks_when_worktrees_dir_is_not_configured
    raw = JSON.parse(File.read(fixture_path(FIXTURE)))
    raw["parallelism"].delete("worktrees_dir")

    with_manifest(Manifest.new(path: fixture_path(FIXTURE), raw: raw)) do
      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 1, code
      assert_equal "missing_worktrees_dir", env["blocked"].first["code"]
    end
  end

  def test_blocks_when_not_run_from_the_main_checkout
    with_manifest(FIXTURE) do
      @fake.expect(%w[git rev-parse --git-dir], out: "/wt/.git/worktrees/x\n")
      @fake.expect(%w[git rev-parse --git-common-dir], out: "/wt/.git\n")
      @fake.expect(%w[git rev-parse --show-toplevel], out: "/wt\n")

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 1, code
      assert_equal false, env["ok"]
      assert_equal "not_main_checkout", env["blocked"].first["code"]
    end
  end

  def test_blocks_when_branch_already_exists
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "  zz-abc-new-thing\n")

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 1, code
      assert_equal "branch_exists", env["blocked"].first["code"]
      assert_equal "human", env["blocked"].first["needs"]
    end
  end

  # sabotage: resolve worktrees_root against Dir.pwd instead of the repo
  # root -> the existing directory is not found and this goes red
  def test_blocks_when_worktree_directory_already_exists
    with_scratch_repo do |root, worktrees_root|
      FileUtils.mkdir_p(File.join(worktrees_root, "zz-abc-new-thing"))

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 1, code
      assert_equal "worktree_dir_exists", env["blocked"].first["code"]
    end
  end

  def test_offline_fetch_falls_back_to_local_main_and_warns
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], exitstatus: 1, err: "fatal: unable to access\n")

      code, env = run_create(["zz-abc-new-thing", "--dry-run"])

      assert_equal 0, code
      assert_equal "main", env["data"]["base_ref"]
      assert_equal "fetch_failed", env["warnings"].first["code"]
    end
  end

  def test_dry_run_never_executes_the_mutating_steps
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")

      # No expectations registered for mkdir, git worktree add, the trust
      # step, cp, the warm commands, or the gate - if the script called
      # Sh.run for any of them, FakeSh would raise UnexpectedCommand and
      # fail this test.
      code, env = run_create(["zz-abc-new-thing", "--dry-run"])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal true, env["data"]["dry_run"]
      assert_equal "origin/main", env["data"]["base_ref"]
      assert env["commands"].any? { |c| c.include?("git worktree add") }
      assert env["commands"].any? { |c| c.include?("faketool trust") }
      assert env["commands"].any? { |c| c.include?("make quick") }
      refute env["commands"].any? { |c| c.include?("--force") }
    end
  end

  # sabotage: substitute {path} nowhere (pass manifest.trust_argv straight
  # through) -> the rendered command still carries the literal token -> red
  def test_dry_run_substitutes_the_worktree_path_into_the_trust_command
    with_scratch_repo do |root, worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")

      _code, env = run_create(["zz-abc-new-thing", "--dry-run"])

      trust = env["commands"].find { |c| c.include?("faketool trust") }

      assert_includes trust, File.join(worktrees_root, "zz-abc-new-thing")
      refute_includes trust, "{path}"
    end
  end

  def test_dry_run_command_sequence_matches_new_worktree_prose_order
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")

      _code, env = run_create(["zz-abc-new-thing", "--dry-run"])

      mutating = env["commands"].select do |c|
        c =~ /mkdir -p|git worktree add|faketool trust|cp -Rfc|fallback|faketool fetch|make quick/
      end

      assert_equal 7, mutating.length
      assert_match(/\Amkdir -p/, mutating[0])
      assert_match(/git worktree add/, mutating[1])
      assert_match(/faketool trust/, mutating[2])
      assert_match(/cp -Rfc/, mutating[3])
      assert_match(/fallback/, mutating[4])
      assert_match(/faketool fetch/, mutating[5])
      assert_match(/make quick/, mutating[6])
    end
  end

  def test_happy_path_creates_warms_and_verifies
    with_scratch_repo do |root, worktrees_root|
      FileUtils.mkdir_p(File.join(root, "build", "cache"))
      FileUtils.touch(File.join(root, "build", "cache", "faketool-1.2.cache"))
      path = File.join(worktrees_root, "zz-abc-new-thing")

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      @fake.expect(["mkdir", "-p", worktrees_root], out: "")
      @fake.expect(["git", "worktree", "add", path, "-b", "zz-abc-new-thing", "--no-track", "origin/main"], out: "")
      @fake.expect(["faketool", "trust", path], out: "")
      @fake.expect(["cp", "-Rfc", "vendor", "build", "#{path}/"], out: "")
      @fake.expect(%w[faketool fetch], out: "")
      @fake.expect(%w[make quick], out: "loop green\n")

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal true, env["data"]["caches_cloned"]
      assert_equal true, env["data"]["warm_caches_present"]
      assert_equal true, env["data"]["quality_green"]
      refute env["commands"].any? { |c| c.include?("--force") }
    end
  end

  # sabotage: report warm_caches_present unconditionally true -> red. The
  # glob is manifest data now, so "the cache is missing" has to be answered
  # against the configured glob rather than a hardcoded PLT name.
  def test_a_missing_warm_cache_warns_without_blocking
    with_scratch_repo do |root, worktrees_root|
      path = File.join(worktrees_root, "zz-abc-new-thing")

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      @fake.expect(["mkdir", "-p", worktrees_root], out: "")
      @fake.expect(["git", "worktree", "add", path, "-b", "zz-abc-new-thing", "--no-track", "origin/main"], out: "")
      @fake.expect(["faketool", "trust", path], out: "")
      @fake.expect(["cp", "-Rfc", "vendor", "build", "#{path}/"], out: "")
      @fake.expect(%w[faketool fetch], out: "")
      @fake.expect(%w[make quick], out: "loop green\n")

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 0, code
      assert_equal false, env["data"]["warm_caches_present"]
      assert_equal "warm_cache_missing", env["warnings"].first["code"]
    end
  end

  # sabotage: give warm_caches_present a `false` default when no globs are
  # configured -> red. A repo that configures none has nothing missing, and
  # nil says "not asked" rather than "asked and found nothing".
  def test_a_repo_with_no_warm_configuration_skips_the_warm_steps
    manifest = manifest_with(FIXTURE, "parallelism" => {
                               "model" => "worktree-per-issue",
                               "worktrees_dir" => "../zz-worktrees",
                               "trust" => nil,
                               "warm_clone" => [],
                               "warm_globs" => [],
                               "warm" => []
                             })

    with_manifest(manifest) do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "myrepo")
        FileUtils.mkdir_p(root)
        worktrees_root = File.join(tmp, "zz-worktrees")
        path = File.join(worktrees_root, "zz-abc-new-thing")

        expect_location(root)
        @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
        @fake.expect(%w[git fetch origin], out: "")
        @fake.expect(["mkdir", "-p", worktrees_root], out: "")
        @fake.expect(["git", "worktree", "add", path, "-b", "zz-abc-new-thing", "--no-track", "origin/main"], out: "")
        @fake.expect(%w[make quick], out: "loop green\n")

        code, env = run_create(["zz-abc-new-thing"])

        assert_equal 0, code
        assert_nil env["data"]["caches_cloned"]
        assert_nil env["data"]["warm_caches_present"]
        assert_empty env["warnings"]
      end
    end
  end

  def test_never_force_in_source
    source = File.read(File.expand_path("../worktree_create.rb", __dir__))
    refute_match(/--force\b/, source)
  end
end

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

  # The dry-run report is the contract for what a real run will do, so a
  # nested entry has to show its own mkdir -p and single-source cp rather
  # than folding into the flat multi-source cp above it.
  def test_dry_run_command_sequence_for_a_nested_warm_clone_entry
    manifest = manifest_with(FIXTURE, "parallelism" => { "warm_clone" => %w[vendor priv/plts] })

    with_manifest(manifest) do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "myrepo")
        FileUtils.mkdir_p(root)
        worktrees_root = File.join(tmp, "zz-worktrees")
        path = File.join(worktrees_root, "zz-abc-new-thing")

        expect_location(root)
        @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
        @fake.expect(%w[git fetch origin], out: "")

        _code, env = run_create(["zz-abc-new-thing", "--dry-run"])

        mutating = env["commands"].select do |c|
          c =~ /mkdir -p|git worktree add|faketool trust|cp -Rfc|fallback|faketool fetch|make quick/
        end

        assert_equal 10, mutating.length
        assert_match(/\Amkdir -p #{Regexp.escape(worktrees_root)}/, mutating[0])
        assert_match(/git worktree add/, mutating[1])
        assert_match(/faketool trust/, mutating[2])
        assert_match(/cp -Rfc vendor #{Regexp.escape("#{path}/")}/, mutating[3])
        assert_match(/\A\(fallback/, mutating[4])
        assert_match(/\Amkdir -p #{Regexp.escape(File.join(path, "priv"))}/, mutating[5])
        assert_match(/cp -Rfc priv\/plts #{Regexp.escape(File.join(path, "priv", "plts"))}/, mutating[6])
        assert_match(/\A\(fallback/, mutating[7])
        assert_match(/faketool fetch/, mutating[8])
        assert_match(/make quick/, mutating[9])
      end
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

  # wu-ik8: a gate command that never got a chance to run (missing
  # executable, or a gate.cwd typo caught here rather than at manifest load)
  # must not read as an ordinary failing quality run - it is a
  # misconfiguration for a human to fix, so it blocks with the same code
  # gate.rb uses for the identical condition.
  #
  # sabotage: check `quality_res.success?` alone instead of
  # `quality_res.start_failed?` first -> red (this would set
  # quality_green: false and fail! instead of blocking with the cause named)
  def test_gate_command_that_cannot_start_blocks_instead_of_reading_as_red
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
      err = "could not start command - No such file or directory - make (command: \"make\")"
      @fake.expect(%w[make quick], start_failed: true, err: err)

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 1, code
      assert_equal false, env["ok"]
      assert_equal false, env["data"]["quality_green"]
      assert_equal 1, env["blocked"].length
      assert_equal "gate_command_could_not_start", env["blocked"].first["code"]
      assert_equal "human", env["blocked"].first["needs"]
      assert_equal err, env["blocked"].first["message"]
    end
  end

  # sabotage: pass no timeout: (or the wrong manifest field) to the trust and
  # warm Sh.run calls -> red (FakeSh records Sh.run's 60s default instead of
  # the configured parallelism.timeout_seconds)
  def test_trust_and_warm_use_the_parallelism_timeout
    manifest = manifest_with(FIXTURE, "parallelism" => { "timeout_seconds" => 900 })

    with_manifest(manifest) do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "myrepo")
        FileUtils.mkdir_p(File.join(root, "build", "cache"))
        FileUtils.touch(File.join(root, "build", "cache", "faketool-1.2.cache"))
        worktrees_root = File.join(tmp, "zz-worktrees")
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

        code, _env = run_create(["zz-abc-new-thing"])

        assert_equal 0, code
        trust_call = @fake.calls.find { |c| c.argv == ["faketool", "trust", path] }
        warm_call = @fake.calls.find { |c| c.argv == %w[faketool fetch] }
        assert_equal 900, trust_call.timeout
        assert_equal 900, warm_call.timeout
      end
    end
  end

  # sabotage: pass no timeout: (or gate.timeout_seconds instead of
  # parallelism.timeout_seconds) to the verify Sh.run call -> red
  def test_verify_uses_the_gate_timeout_not_the_parallelism_timeout
    manifest = manifest_with(FIXTURE, "gate" => { "timeout_seconds" => 1800 },
                                       "parallelism" => { "timeout_seconds" => 900 })

    with_manifest(manifest) do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "myrepo")
        FileUtils.mkdir_p(File.join(root, "build", "cache"))
        FileUtils.touch(File.join(root, "build", "cache", "faketool-1.2.cache"))
        worktrees_root = File.join(tmp, "zz-worktrees")
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

        code, _env = run_create(["zz-abc-new-thing"])

        assert_equal 0, code
        gate_call = @fake.calls.find { |c| c.argv == %w[make quick] }
        assert_equal 1800, gate_call.timeout
      end
    end
  end

  # sabotage: batch a nested entry into the flat multi-source cp instead of
  # giving it its own mkdir -p + single-source cp -> cp flattens it to its
  # basename ("plts" instead of "priv/plts") and this goes red. This is the
  # wu-z6w regression case: predicator-ex's warm_clone includes priv/plts.
  def test_a_nested_warm_clone_entry_lands_at_its_relative_path
    manifest = manifest_with(FIXTURE, "parallelism" => { "warm_clone" => %w[vendor priv/plts] })

    with_manifest(manifest) do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "myrepo")
        FileUtils.mkdir_p(File.join(root, "build", "cache"))
        FileUtils.touch(File.join(root, "build", "cache", "faketool-1.2.cache"))
        worktrees_root = File.join(tmp, "zz-worktrees")
        path = File.join(worktrees_root, "zz-abc-new-thing")

        expect_location(root)
        @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
        @fake.expect(%w[git fetch origin], out: "")
        @fake.expect(["mkdir", "-p", worktrees_root], out: "")
        @fake.expect(["git", "worktree", "add", path, "-b", "zz-abc-new-thing", "--no-track", "origin/main"], out: "")
        @fake.expect(["faketool", "trust", path], out: "")
        @fake.expect(["cp", "-Rfc", "vendor", "#{path}/"], out: "")
        @fake.expect(["mkdir", "-p", File.join(path, "priv")], out: "")
        @fake.expect(["cp", "-Rfc", "priv/plts", File.join(path, "priv", "plts")], out: "")
        @fake.expect(%w[faketool fetch], out: "")
        @fake.expect(%w[make quick], out: "loop green\n")

        code, env = run_create(["zz-abc-new-thing"])

        assert_equal 0, code
        assert_equal true, env["ok"]
        assert_equal true, env["data"]["caches_cloned"]
        assert_empty env["warnings"]
      end
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

  # sabotage: read a hardcoded "origin/main"/"main" instead of
  # manifest.remote_default_branch/manifest.default_branch -> red
  # (FakeSh::UnexpectedCommand: no stub is registered for "origin/main" here,
  # only for "origin/trunk")
  def test_trunk_override_uses_the_manifests_remote_default_branch
    other = manifest_with(FIXTURE, "repo" => { "default_branch" => "trunk" })

    with_manifest(other) do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "myrepo")
        FileUtils.mkdir_p(root)
        worktrees_root = File.join(tmp, "zz-worktrees")
        path = File.join(worktrees_root, "zz-abc-new-thing")

        expect_location(root)
        @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
        @fake.expect(%w[git fetch origin], out: "")
        @fake.expect(["mkdir", "-p", worktrees_root], out: "")
        @fake.expect(["git", "worktree", "add", path, "-b", "zz-abc-new-thing", "--no-track", "origin/trunk"], out: "")
        @fake.expect(["faketool", "trust", path], out: "")
        @fake.expect(["cp", "-Rfc", "vendor", "build", "#{path}/"], out: "")
        @fake.expect(%w[faketool fetch], out: "")
        @fake.expect(%w[make quick], out: "loop green\n")

        code, env = run_create(["zz-abc-new-thing"])

        assert_equal 0, code
        assert_equal "origin/trunk", env["data"]["base_ref"]
      end
    end
  end

  # sabotage: same as above, but for the offline fallback rung -> red
  # (FakeSh::UnexpectedCommand: no stub for "origin/trunk", and the fallback
  # would report "main" instead of "trunk")
  def test_trunk_override_falls_back_to_local_trunk_when_offline
    other = manifest_with(FIXTURE, "repo" => { "default_branch" => "trunk" })

    with_manifest(other) do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "myrepo")
        FileUtils.mkdir_p(root)

        expect_location(root)
        @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
        @fake.expect(%w[git fetch origin], exitstatus: 1, err: "fatal: unable to access\n")

        code, env = run_create(["zz-abc-new-thing", "--dry-run"])

        assert_equal 0, code
        assert_equal "trunk", env["data"]["base_ref"]
        assert_equal "fetch_failed", env["warnings"].first["code"]
      end
    end
  end

  # --- gate.cwd: the gate command runs under gate.cwd inside the new worktree ---

  # sabotage: pass `chdir: path` instead of `chdir: gate_chdir(manifest, path)`
  # to the real Sh.run call in create_and_warm -> red (FakeSh records the
  # bare worktree path instead of worktree/backend)
  def test_gate_cwd_present_chdirs_the_real_quality_run_into_the_subdirectory
    manifest = manifest_with(FIXTURE, "gate" => { "cwd" => "backend" })

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
        @fake.expect(["faketool", "trust", path], out: "")
        @fake.expect(["cp", "-Rfc", "vendor", "build", "#{path}/"], out: "")
        @fake.expect(%w[faketool fetch], out: "")
        @fake.expect(%w[make quick], out: "loop green\n")

        code, env = run_create(["zz-abc-new-thing"])

        assert_equal 0, code
        assert_equal true, env["data"]["quality_green"]
        gate_call = @fake.calls.find { |c| c.argv == %w[make quick] }
        assert_equal File.join(path, "backend"), gate_call.chdir
      end
    end
  end

  # sabotage: render the dry-run preview with `chdir: path` instead of
  # `chdir: gate_chdir(manifest, path)` -> red (the rendered command shows
  # the bare worktree path instead of worktree/backend)
  def test_gate_cwd_present_renders_the_dry_run_preview_with_the_subdirectory
    manifest = manifest_with(FIXTURE, "gate" => { "cwd" => "backend" })

    with_manifest(manifest) do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "myrepo")
        FileUtils.mkdir_p(root)
        worktrees_root = File.join(tmp, "zz-worktrees")
        path = File.join(worktrees_root, "zz-abc-new-thing")

        expect_location(root)
        @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
        @fake.expect(%w[git fetch origin], out: "")

        _code, env = run_create(["zz-abc-new-thing", "--dry-run"])

        gate_preview = env["commands"].find { |c| c.include?("make quick") }
        assert_match(/\A\(cd #{Regexp.escape(File.join(path, "backend"))} && make quick\)/, gate_preview)
      end
    end
  end

  # Without gate.cwd, both the real run's chdir and the dry-run preview stay
  # the bare worktree path, exactly as before this field existed.
  def test_gate_cwd_absent_chdir_and_preview_are_the_bare_worktree_path
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

      code, _env = run_create(["zz-abc-new-thing"])

      assert_equal 0, code
      gate_call = @fake.calls.find { |c| c.argv == %w[make quick] }
      assert_equal path, gate_call.chdir
    end
  end

  def test_never_force_in_source
    source = File.read(File.expand_path("../worktree_create.rb", __dir__))
    refute_match(/--force\b/, source)
  end
end

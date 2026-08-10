# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../rebase_onto"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"

class RebaseOntoTest < Minitest::Test
  include ManifestHelper

  # The `worktree` fixture's repair recipe is `faketool fetch` triggered by
  # `lock.json`, and its warm cache is `build/cache/faketool-*.cache`.
  # Asserting on mix.lock and a dialyzer PLT here would pass whether or not
  # the script consulted the manifest at all.
  FIXTURE = "worktree"

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
  end

  def run_rebase(argv)
    io = StringIO.new
    code = RebaseOnto.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  # The whole point of the extraction: the diff --diff-filter=U capture must
  # precede the rebase --abort in the recorded call sequence, because the
  # abort clears the conflict state a report assembled afterward would
  # otherwise have nothing left to name.
  def test_conflict_captures_files_before_aborting_in_that_order
    path = "/wt/zz-abc-x"
    with_manifest(FIXTURE) do
      @fake.expect(%w[git rev-parse HEAD], out: "aaaaaaa\n")
      @fake.expect(%w[git rebase origin/main], exitstatus: 1, err: "CONFLICT\n")
      @fake.expect(%w[git diff --name-only --diff-filter=U], out: "lib/foo.ex\nlib/bar.ex\n")
      @fake.expect(%w[git rebase --abort], out: "")

      code, env = run_rebase([path])

      assert_equal 1, code
      assert_equal false, env["ok"]
      assert_equal "rebase_conflict", env["blocked"].first["code"]
      assert_equal "human", env["blocked"].first["needs"]
      assert_equal %w[lib/foo.ex lib/bar.ex], env["data"]["files"]

      capture_index = @fake.calls.find_index { |c| c.argv == %w[git diff --name-only --diff-filter=U] }
      abort_index = @fake.calls.find_index { |c| c.argv == %w[git rebase --abort] }
      refute_nil capture_index
      refute_nil abort_index
      assert capture_index < abort_index, "expected the diff capture to precede the rebase --abort"
    end
  end

  def test_conflict_has_no_resolve_path_the_script_never_calls_checkout_or_merge_tool
    source = File.read(File.expand_path("../rebase_onto.rb", __dir__))
    refute_match(/checkout\s+--(ours|theirs)/, source)
    refute_match(/git\s+add\b/, source)
    refute_match(/rebase\s+--continue/, source)
  end

  # sabotage: drop the `if manifest.repair_when` guard and always diff
  # against a hardcoded "mix.lock" -> FakeSh raises UnexpectedCommand -> red
  def test_an_unchanged_lockfile_takes_the_fast_path_and_runs_no_repair
    path = "/wt/zz-abc-x"
    with_manifest(FIXTURE) do
      @fake.expect(%w[git rev-parse HEAD], out: "aaaaaaa\n")
      @fake.expect(%w[git rebase origin/main], out: "")
      @fake.expect(%w[git rev-parse origin/main], out: "bbbbbbb\n")
      @fake.expect(["git", "diff", "--quiet", "aaaaaaa", "HEAD", "--", "lock.json"], exitstatus: 0)

      # No "faketool fetch" expectation registered - if the script ran the
      # repair on the unchanged fast path, FakeSh would raise
      # UnexpectedCommand.
      code, env = run_rebase([path])

      assert_equal 0, code
      assert_equal "rebased", env["data"]["status"]
      assert_equal false, env["data"]["lock_changed"]
      assert_nil env["data"]["repaired"]
    end
  end

  # sabotage: treat an absent repair_when as "always changed" -> the repair
  # commands run and FakeSh raises on the unexpected `faketool fetch` -> red
  def test_a_repo_that_configures_no_repair_never_takes_the_repair_path
    manifest = manifest_with(FIXTURE, "parallelism" => {
                               "model" => "worktree-per-issue",
                               "repair_when" => nil,
                               "repair" => []
                             })

    with_manifest(manifest) do
      @fake.expect(%w[git rev-parse HEAD], out: "aaaaaaa\n")
      @fake.expect(%w[git rebase origin/main], out: "")
      @fake.expect(%w[git rev-parse origin/main], out: "bbbbbbb\n")

      code, env = run_rebase(["/wt/zz-abc-x"])

      assert_equal 0, code
      assert_equal false, env["data"]["lock_changed"]
      assert_nil env["data"]["repaired"]
    end
  end

  # sabotage: copy each match to File.basename(src) under the worktree root
  # instead of preserving its repo-relative path -> the expected cp argv no
  # longer matches -> red. The glob is manifest data now, so a cache nested
  # under build/cache/ has to land back under build/cache/.
  def test_a_moved_lockfile_runs_the_repair_and_copies_warm_caches_targeted
    with_manifest(FIXTURE) do
      Dir.mktmpdir do |tmp|
        main = File.join(tmp, "myrepo")
        path = File.join(tmp, "zz-worktrees", "zz-abc-x")
        FileUtils.mkdir_p(File.join(main, "build", "cache"))
        FileUtils.mkdir_p(File.join(path, "build", "cache"))
        cache = File.join(main, "build", "cache", "faketool-1.2.cache")
        FileUtils.touch(cache)

        @fake.expect(%w[git rev-parse HEAD], out: "aaaaaaa\n")
        @fake.expect(%w[git rebase origin/main], out: "")
        @fake.expect(%w[git rev-parse origin/main], out: "bbbbbbb\n")
        @fake.expect(["git", "diff", "--quiet", "aaaaaaa", "HEAD", "--", "lock.json"], exitstatus: 1)
        @fake.expect(%w[faketool fetch], out: "")
        @fake.expect(%w[git worktree list --porcelain], out: "worktree #{main}\nHEAD cccc\nbranch refs/heads/main\n")
        @fake.expect(["cp", "-f", cache, File.join(path, "build", "cache", "faketool-1.2.cache")], out: "")

        code, env = run_rebase([path])

        assert_equal 0, code
        assert_equal true, env["data"]["lock_changed"]
        assert_equal true, env["data"]["repaired"]
      end
    end
  end

  # sabotage: block instead of warn when the warm cache is absent -> red.
  # A missing cache costs a rebuild, never a rebase.
  def test_a_missing_warm_cache_warns_and_the_rebase_still_succeeds
    with_manifest(FIXTURE) do
      Dir.mktmpdir do |tmp|
        main = File.join(tmp, "myrepo")
        path = File.join(tmp, "zz-worktrees", "zz-abc-x")
        FileUtils.mkdir_p(main)
        FileUtils.mkdir_p(path)

        @fake.expect(%w[git rev-parse HEAD], out: "aaaaaaa\n")
        @fake.expect(%w[git rebase origin/main], out: "")
        @fake.expect(%w[git rev-parse origin/main], out: "bbbbbbb\n")
        @fake.expect(["git", "diff", "--quiet", "aaaaaaa", "HEAD", "--", "lock.json"], exitstatus: 1)
        @fake.expect(%w[faketool fetch], out: "")
        @fake.expect(%w[git worktree list --porcelain], out: "worktree #{main}\nHEAD cccc\nbranch refs/heads/main\n")

        code, env = run_rebase([path])

        assert_equal 0, code
        assert_equal true, env["ok"]
        assert_equal "warm_cache_missing", env["warnings"].first["code"]
      end
    end
  end

  # The recursive-copy flags are what a wholesale re-clone of the warm_clone
  # directories would need; this script only ever copies individual files.
  def test_never_reclones_the_warm_clone_directories_wholesale
    source = File.read(File.expand_path("../rebase_onto.rb", __dir__))
    refute_match(/"cp", "-R/, source)
  end

  def test_dry_run_executes_nothing
    with_manifest(FIXTURE) do
      # No FakeSh expectations at all - any Sh.run call would raise.
      code, env = run_rebase(["/wt/zz-abc-x", "--dry-run"])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal "dry_run", env["data"]["status"]
      assert env["commands"].any? { |c| c.include?("git rebase origin/main") }
      assert env["commands"].any? { |c| c.include?("(if lock.json moved) ") && c.include?("faketool fetch") }
      refute env["commands"].any? { |c| c.include?("--force") }
    end
  end

  def test_never_force_in_source
    source = File.read(File.expand_path("../rebase_onto.rb", __dir__))
    refute_match(/--force\b/, source)
  end

  # sabotage: read a hardcoded "origin/main" instead of
  # manifest.remote_default_branch -> FakeSh raises UnexpectedCommand (no
  # stub for "origin/main" here, only "origin/trunk") -> red
  def test_trunk_override_rebases_against_the_manifests_remote_default_branch
    manifest = manifest_with(FIXTURE, "repo" => { "default_branch" => "trunk" })

    with_manifest(manifest) do
      @fake.expect(%w[git rev-parse HEAD], out: "aaaaaaa\n")
      @fake.expect(%w[git rebase origin/trunk], out: "")
      @fake.expect(%w[git rev-parse origin/trunk], out: "bbbbbbb\n")
      @fake.expect(["git", "diff", "--quiet", "aaaaaaa", "HEAD", "--", "lock.json"], exitstatus: 0)

      code, env = run_rebase(["/wt/zz-abc-x"])

      assert_equal 0, code
      assert_equal "rebased", env["data"]["status"]
      assert_equal "bbbbbbb", env["data"]["target"]
    end
  end

  # sabotage: same, but for the dry-run rendering -> the dry-run commands[]
  # would still name "origin/main" -> red
  def test_trunk_override_dry_run_renders_the_manifests_remote_default_branch
    manifest = manifest_with(FIXTURE, "repo" => { "default_branch" => "trunk" })

    with_manifest(manifest) do
      code, env = run_rebase(["/wt/zz-abc-x", "--dry-run"])

      assert_equal 0, code
      assert env["commands"].any? { |c| c.include?("git rebase origin/trunk") }
    end
  end
end

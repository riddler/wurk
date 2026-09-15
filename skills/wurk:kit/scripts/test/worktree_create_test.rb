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

  LOCAL_SHA = "a" * 40
  REMOTE_SHA = "b" * 40

  # The preflight's two reads, answered with the local and remote default at
  # the same sha - the clean case, in which the preflight changes nothing.
  # Tests for the other cases register the reads themselves.
  def expect_preflight_in_sync(default: "main")
    expect_preflight_shas(default: default, local: REMOTE_SHA, remote: REMOTE_SHA)
  end

  def expect_preflight_shas(default: "main", local:, remote:)
    @fake.expect(["git", "rev-parse", "--verify", "--quiet", "refs/heads/#{default}"],
                 out: local ? "#{local}\n" : "", exitstatus: local ? 0 : 1)
    @fake.expect(["git", "rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{default}"],
                 out: remote ? "#{remote}\n" : "", exitstatus: remote ? 0 : 1)
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

  # A worktree git has registered for `name`, in the porcelain shape
  # `git worktree list --porcelain` emits: the main checkout first, then the
  # branch's own entry.
  def worktree_list(root, entries)
    out = "worktree #{root}\nHEAD 1111111\nbranch refs/heads/main\n\n"
    entries.each do |wt_path, branch|
      out += "worktree #{wt_path}\nHEAD 2222222\nbranch refs/heads/#{branch}\n\n"
    end
    out
  end

  # The branch exists but nothing is checked out for it - today's block,
  # unchanged. Adoption needs a worktree to adopt.
  def test_blocks_when_branch_already_exists
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "  zz-abc-new-thing\n")
      @fake.expect(%w[git worktree list --porcelain], out: worktree_list(root, []))

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 1, code
      assert_equal "branch_exists", env["blocked"].first["code"]
      assert_equal "human", env["blocked"].first["needs"]
      assert_match(/no worktree/, env["blocked"].first["message"])
    end
  end

  # --- adoption (wu-mya.3) ---------------------------------------------------
  #
  # Every one of these blocks stays a block: adoption is only for the case
  # where the workspace the caller asked for is already standing, clean, at
  # exactly the expected path.

  # sabotage: drop the clean-tree check -> red. Uncommitted work in the
  # existing tree is precisely what a human has to judge.
  def test_blocks_when_the_existing_worktree_is_dirty
    with_scratch_repo do |root, worktrees_root|
      path = File.join(worktrees_root, "zz-abc-new-thing")
      FileUtils.mkdir_p(path)

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "  zz-abc-new-thing\n")
      @fake.expect(%w[git worktree list --porcelain], out: worktree_list(root, [[path, "zz-abc-new-thing"]]))
      @fake.expect(%w[git status --porcelain], out: " M lib/thing.rb\n")

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 1, code
      assert_equal "branch_exists", env["blocked"].first["code"]
      assert_equal "human", env["blocked"].first["needs"]
      assert_match(/uncommitted changes/, env["blocked"].first["message"])
    end
  end

  # sabotage: compare only that SOME worktree carries the branch, not that it
  # is the expected path -> red. Adopting here would leave two directories
  # for one branch, one of which nothing else in the workflow knows about.
  def test_blocks_when_the_branch_is_checked_out_at_another_path
    with_scratch_repo do |root, worktrees_root|
      elsewhere = File.join(worktrees_root, "somewhere-else")
      FileUtils.mkdir_p(elsewhere)

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "  zz-abc-new-thing\n")
      @fake.expect(%w[git worktree list --porcelain], out: worktree_list(root, [[elsewhere, "zz-abc-new-thing"]]))

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 1, code
      assert_equal "branch_exists", env["blocked"].first["code"]
      assert_includes env["blocked"].first["message"], elsewhere
    end
  end

  # A directory at the expected path that is not a worktree of this branch is
  # a stray sibling, not something to adopt.
  def test_blocks_when_the_directory_is_not_a_worktree_of_the_branch
    with_scratch_repo do |root, worktrees_root|
      path = File.join(worktrees_root, "zz-abc-new-thing")
      FileUtils.mkdir_p(path)

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "  zz-abc-new-thing\n")
      @fake.expect(%w[git worktree list --porcelain], out: worktree_list(root, [[path, "zz-other-branch"]]))

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 1, code
      assert_equal "branch_exists", env["blocked"].first["code"]
      assert_match(/no worktree/, env["blocked"].first["message"])
    end
  end

  # The registered worktree's directory is gone (a prunable entry): nothing
  # standing to adopt, so this stays blocked too.
  def test_blocks_when_the_registered_worktree_directory_is_missing
    with_scratch_repo do |root, worktrees_root|
      path = File.join(worktrees_root, "zz-abc-new-thing")

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "  zz-abc-new-thing\n")
      @fake.expect(%w[git worktree list --porcelain], out: worktree_list(root, [[path, "zz-abc-new-thing"]]))

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 1, code
      assert_equal "branch_exists", env["blocked"].first["code"]
      assert_match(/is not a directory/, env["blocked"].first["message"])
    end
  end

  # sabotage: run the create steps on the adopt path anyway -> red
  # (FakeSh::UnexpectedCommand: no mkdir, no git worktree add, and no git
  # fetch is registered - there is no branch to cut).
  def test_adopts_a_clean_matching_worktree_and_still_warms_and_verifies
    with_scratch_repo do |root, worktrees_root|
      FileUtils.mkdir_p(File.join(root, "build", "cache"))
      FileUtils.touch(File.join(root, "build", "cache", "faketool-1.2.cache"))
      path = File.join(worktrees_root, "zz-abc-new-thing")
      FileUtils.mkdir_p(path)

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "  zz-abc-new-thing\n")
      @fake.expect(%w[git worktree list --porcelain], out: worktree_list(root, [[path, "zz-abc-new-thing"]]))
      @fake.expect(%w[git status --porcelain], out: "")
      @fake.expect(["faketool", "trust", path], out: "")
      @fake.expect(["cp", "-Rfc", "vendor", "build", "#{path}/"], out: "")
      @fake.expect(%w[faketool fetch], out: "")
      @fake.expect(%w[make quick], out: "loop green\n")

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal "adopted", env["data"]["action"]
      assert_equal path, env["data"]["path"]
      assert_nil env["data"]["base_ref"]
      assert_equal true, env["data"]["caches_cloned"]
      assert_equal true, env["data"]["quality_green"]
      assert_empty env["blocked"]
      refute env["commands"].any? { |c| c.include?("git worktree add") }
    end
  end

  # A created workspace says so too, so a caller routes on one key rather
  # than on the absence of another.
  def test_a_created_workspace_reports_action_created
    with_scratch_repo do |root, worktrees_root|
      path = File.join(worktrees_root, "zz-abc-new-thing")

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      expect_preflight_in_sync

      _code, env = run_create(["zz-abc-new-thing", "--dry-run"])

      assert_equal "created", env["data"]["action"]
      assert env["commands"].any? { |c| c.include?("git worktree add #{path}") }
    end
  end

  # sabotage: render the create steps on the adopt dry-run anyway -> red.
  # --dry-run is the contract for what a real run will do; an adopt preview
  # that shows a `git worktree add` promises a mutation that will not happen.
  def test_adopt_dry_run_omits_the_create_steps_and_keeps_the_warm_steps
    with_scratch_repo do |root, worktrees_root|
      path = File.join(worktrees_root, "zz-abc-new-thing")
      FileUtils.mkdir_p(path)

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "  zz-abc-new-thing\n")
      @fake.expect(%w[git worktree list --porcelain], out: worktree_list(root, [[path, "zz-abc-new-thing"]]))
      @fake.expect(%w[git status --porcelain], out: "")

      code, env = run_create(["zz-abc-new-thing", "--dry-run"])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal "adopted", env["data"]["action"]
      assert_equal true, env["data"]["dry_run"]
      refute env["commands"].any? { |c| c.include?("git worktree add") }
      refute env["commands"].any? { |c| c =~ /\Amkdir -p/ }
      assert env["commands"].any? { |c| c.include?("faketool trust") }
      assert env["commands"].any? { |c| c.include?("cp -Rfc") }
      assert env["commands"].any? { |c| c.include?("faketool fetch") }
      assert env["commands"].any? { |c| c.include?("make quick") }
    end
  end

  # --base names what to cut a new branch from, and adoption cuts nothing.
  # Saying so beats honoring a flag that cannot apply and beats silence.
  def test_adopt_warns_that_an_explicit_base_cannot_apply
    with_scratch_repo do |root, worktrees_root|
      path = File.join(worktrees_root, "zz-abc-new-thing")
      FileUtils.mkdir_p(path)

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "  zz-abc-new-thing\n")
      @fake.expect(%w[git worktree list --porcelain], out: worktree_list(root, [[path, "zz-abc-new-thing"]]))
      @fake.expect(%w[git status --porcelain], out: "")

      code, env = run_create(["zz-abc-new-thing", "--base", "zz-abc.1-parent", "--dry-run"])

      assert_equal 0, code
      assert_equal "adopted", env["data"]["action"]
      assert_equal "base_ignored_on_adopt", env["warnings"].first["code"]
      assert_includes env["warnings"].first["message"], "zz-abc.1-parent"
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
      expect_preflight_in_sync

      code, env = run_create(["zz-abc-new-thing", "--dry-run"])

      assert_equal 0, code
      assert_equal "main", env["data"]["base_ref"]
      assert_equal "fetch_failed", env["warnings"].first["code"]
    end
  end

  def test_base_flag_cuts_from_the_given_ref
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc.2-child"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      expect_preflight_in_sync
      @fake.expect(["git", "rev-parse", "--verify", "--quiet", "zz-abc.1-parent^{commit}"], out: "deadbeef\n")

      code, env = run_create(["zz-abc.2-child", "--base", "zz-abc.1-parent", "--dry-run"])

      assert_equal 0, code
      assert_equal "zz-abc.1-parent", env["data"]["base_ref"]
      add = env["commands"].find { |c| c.include?("git worktree add") }
      assert_includes add, "zz-abc.1-parent"
    end
  end

  def test_base_flag_blocks_before_any_mutation_when_the_ref_does_not_resolve
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc.2-child"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      expect_preflight_in_sync
      @fake.expect(["git", "rev-parse", "--verify", "--quiet", "zz-abc.1-typo^{commit}"], exitstatus: 1)

      # No expectations for mkdir or git worktree add: reaching them would
      # raise UnexpectedCommand. This is a real run, not --dry-run.
      code, env = run_create(["zz-abc.2-child", "--base", "zz-abc.1-typo"])

      assert_equal 1, code
      assert_equal "base_ref_not_found", env["blocked"].first["code"]
      assert_equal "human", env["blocked"].first["needs"]
    end
  end

  def test_base_flag_offline_fetch_keeps_the_explicit_base
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc.2-child"], out: "")
      @fake.expect(%w[git fetch origin], exitstatus: 1, err: "fatal: unable to access\n")
      expect_preflight_in_sync
      @fake.expect(["git", "rev-parse", "--verify", "--quiet", "zz-abc.1-parent^{commit}"], out: "deadbeef\n")

      code, env = run_create(["zz-abc.2-child", "--base", "zz-abc.1-parent", "--dry-run"])

      assert_equal 0, code
      assert_equal "zz-abc.1-parent", env["data"]["base_ref"]
      assert_equal "fetch_failed", env["warnings"].first["code"]
    end
  end

  def test_dry_run_never_executes_the_mutating_steps
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      expect_preflight_in_sync

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
      expect_preflight_in_sync

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
      expect_preflight_in_sync

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
        expect_preflight_in_sync

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
      expect_preflight_in_sync
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
      expect_preflight_in_sync
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
        expect_preflight_in_sync
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
        expect_preflight_in_sync
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
        expect_preflight_in_sync
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
      expect_preflight_in_sync
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
        expect_preflight_in_sync
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
        expect_preflight_in_sync(default: "trunk")
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
        expect_preflight_in_sync(default: "trunk")

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
        expect_preflight_in_sync
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
        expect_preflight_in_sync

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
      expect_preflight_in_sync
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

  # --- parallelism.preflight: the base preflight (wu-yi7.3) -----------------
  #
  # A worktree cut while the local default branch is stale has forked behind
  # the remote and rebuilt already-merged work. The preflight asserts local
  # default == origin/default by sha after the fetch, fast-forwards a
  # zero-commit stale local default, and refuses a diverged one. Every
  # refusal is `blocked` preflight_refused with `data.preflight.reason`
  # naming the condition, and none of them reach `git worktree add`.

  # The clean case: the shas match, the preflight records in_sync, and the
  # cut proceeds exactly as before the preflight existed.
  def test_preflight_in_sync_records_the_shas_and_proceeds
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      expect_preflight_in_sync

      code, env = run_create(["zz-abc-new-thing", "--dry-run"])

      assert_equal 0, code
      assert_equal "in_sync", env["data"]["preflight"]["status"]
      assert_equal REMOTE_SHA, env["data"]["preflight"]["local_sha"]
      assert_equal REMOTE_SHA, env["data"]["preflight"]["remote_sha"]
      assert_equal true, env["data"]["preflight"]["remote_fresh"]
      assert env["commands"].any? { |c| c.include?("git worktree add") }
      refute env["commands"].any? { |c| c.include?("--ff-only") }
    end
  end

  # The stale-main case: local main is strictly behind (its sha is an
  # ancestor of the remote's) and checked out in the main checkout, so the
  # preflight fast-forwards it with `git merge --ff-only` and the cut goes on.
  #
  # sabotage: skip the merge-base check and fast-forward unconditionally ->
  # this stays green but test_preflight_refuses_a_diverged_local_default
  # goes red (FakeSh::UnexpectedCommand on the merge). The two tests are a
  # pair.
  def test_preflight_fast_forwards_a_zero_commit_stale_local_default
    with_scratch_repo do |root, worktrees_root|
      path = File.join(worktrees_root, "zz-abc-new-thing")

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      expect_preflight_shas(local: LOCAL_SHA, remote: REMOTE_SHA)
      @fake.expect(["git", "merge-base", "--is-ancestor", LOCAL_SHA, REMOTE_SHA], out: "")
      @fake.expect(%w[git worktree list --porcelain], out: worktree_list(root, []))
      @fake.expect(["git", "merge", "--ff-only", REMOTE_SHA], out: "Fast-forward\n")
      @fake.expect(["mkdir", "-p", worktrees_root], out: "")
      @fake.expect(["git", "worktree", "add", path, "-b", "zz-abc-new-thing", "--no-track", "origin/main"], out: "")
      @fake.expect(["faketool", "trust", path], out: "")
      @fake.expect(["cp", "-Rfc", "vendor", "build", "#{path}/"], out: "")
      @fake.expect(%w[faketool fetch], out: "")
      @fake.expect(%w[make quick], out: "loop green\n")

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal "fast_forwarded", env["data"]["preflight"]["status"]
      merge_call = @fake.calls.find { |c| c.argv[0, 3] == %w[git merge --ff-only] }
      assert_equal root, merge_call.chdir
    end
  end

  # The same stale-main case when nothing has the default branch checked
  # out: the ref moves by update-ref with the old-value guard, since there
  # is no working tree to merge into.
  def test_preflight_moves_an_unchecked_out_stale_default_with_update_ref
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      expect_preflight_shas(local: LOCAL_SHA, remote: REMOTE_SHA)
      @fake.expect(["git", "merge-base", "--is-ancestor", LOCAL_SHA, REMOTE_SHA], out: "")
      detached = "worktree #{root}\nHEAD 1111111\ndetached\n\n"
      @fake.expect(%w[git worktree list --porcelain], out: detached)

      # --dry-run records the repair rather than running it (no update-ref
      # is registered); the real-run half of this branch is the same code
      # path the merge test above exercises.
      code, env = run_create(["zz-abc-new-thing", "--dry-run"])

      assert_equal 0, code
      assert_equal "stale", env["data"]["preflight"]["status"]
      assert_includes env["data"]["preflight"]["repair"], "git update-ref refs/heads/main #{REMOTE_SHA} #{LOCAL_SHA}"
      refute @fake.calls.any? { |c| c.argv[0, 2] == %w[git update-ref] }
    end
  end

  # sabotage: record the fast-forward in `commands` AND run it on --dry-run
  # -> red (the merge is not registered, so FakeSh raises). --dry-run is the
  # contract for what a real run will do, and the repair is a mutation of
  # the local default branch.
  def test_preflight_dry_run_records_the_fast_forward_without_running_it
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      expect_preflight_shas(local: LOCAL_SHA, remote: REMOTE_SHA)
      @fake.expect(["git", "merge-base", "--is-ancestor", LOCAL_SHA, REMOTE_SHA], out: "")
      @fake.expect(%w[git worktree list --porcelain], out: worktree_list(root, []))

      code, env = run_create(["zz-abc-new-thing", "--dry-run"])

      assert_equal 0, code
      assert_equal "stale", env["data"]["preflight"]["status"]
      assert env["commands"].any? { |c| c.include?("git merge --ff-only #{REMOTE_SHA}") }
      assert env["commands"].any? { |c| c.include?("git worktree add") }
    end
  end

  # The diverged-branch case: local main has commits the remote lacks, so
  # merge-base --is-ancestor says no. That is a merge-forward for a human;
  # the preflight refuses before anything is cut, and the refusal is
  # machine-readable twice over.
  #
  # sabotage: reset local main to the remote instead of refusing -> red
  # (no reset/update-ref is registered, and blocked would be empty)
  def test_preflight_refuses_a_diverged_local_default
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      expect_preflight_shas(local: LOCAL_SHA, remote: REMOTE_SHA)
      @fake.expect(["git", "merge-base", "--is-ancestor", LOCAL_SHA, REMOTE_SHA], exitstatus: 1)

      # No expectations for mkdir or git worktree add: reaching them would
      # raise UnexpectedCommand. This is a real run, not --dry-run.
      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 1, code
      assert_equal false, env["ok"]
      assert_equal 1, env["blocked"].length
      assert_equal "preflight_refused", env["blocked"].first["code"]
      assert_equal "human", env["blocked"].first["needs"]
      assert_match(/merge it forward/, env["blocked"].first["message"])
      assert_equal "refused", env["data"]["preflight"]["status"]
      assert_equal "local_default_diverged", env["data"]["preflight"]["reason"]
      assert_equal LOCAL_SHA, env["data"]["preflight"]["local_sha"]
      assert_equal REMOTE_SHA, env["data"]["preflight"]["remote_sha"]
      refute env["commands"].any? { |c| c.include?("git worktree add") }
    end
  end

  # A stale default checked out in some OTHER worktree is that worktree's
  # tree to move, not this script's: refuse and name where it is.
  def test_preflight_refuses_when_the_stale_default_is_checked_out_elsewhere
    with_scratch_repo do |root, worktrees_root|
      elsewhere = File.join(worktrees_root, "main-lives-here")

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      expect_preflight_shas(local: LOCAL_SHA, remote: REMOTE_SHA)
      @fake.expect(["git", "merge-base", "--is-ancestor", LOCAL_SHA, REMOTE_SHA], out: "")
      listing = "worktree #{root}\nHEAD 1111111\ndetached\n\nworktree #{elsewhere}\nHEAD 2222222\nbranch refs/heads/main\n\n"
      @fake.expect(%w[git worktree list --porcelain], out: listing)

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 1, code
      assert_equal "preflight_refused", env["blocked"].first["code"]
      assert_equal "default_checked_out_elsewhere", env["data"]["preflight"]["reason"]
      assert_includes env["blocked"].first["message"], elsewhere
    end
  end

  # A fast-forward that fails (a dirty file in its way) leaves local main
  # where it was and refuses rather than cutting from a base the preflight
  # could not bring up to date.
  def test_preflight_refuses_when_the_fast_forward_fails
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      expect_preflight_shas(local: LOCAL_SHA, remote: REMOTE_SHA)
      @fake.expect(["git", "merge-base", "--is-ancestor", LOCAL_SHA, REMOTE_SHA], out: "")
      @fake.expect(%w[git worktree list --porcelain], out: worktree_list(root, []))
      @fake.expect(["git", "merge", "--ff-only", REMOTE_SHA], exitstatus: 1,
                                                              err: "error: Your local changes would be overwritten\n")

      code, env = run_create(["zz-abc-new-thing"])

      assert_equal 1, code
      assert_equal "preflight_refused", env["blocked"].first["code"]
      assert_equal "fast_forward_failed", env["data"]["preflight"]["reason"]
      assert_match(/local changes would be overwritten/, env["blocked"].first["message"])
    end
  end

  # Offline, the comparison is against the last-fetched remote ref and says
  # so: a warning beside the existing fetch_failed one, never a refusal on
  # its own.
  def test_preflight_offline_compares_against_the_last_fetched_remote_and_warns
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], exitstatus: 1, err: "fatal: unable to access\n")
      expect_preflight_in_sync

      code, env = run_create(["zz-abc-new-thing", "--dry-run"])

      assert_equal 0, code
      assert_equal "main", env["data"]["base_ref"]
      assert_equal "in_sync", env["data"]["preflight"]["status"]
      assert_equal false, env["data"]["preflight"]["remote_fresh"]
      assert_equal %w[fetch_failed preflight_stale_remote], env["warnings"].map { |w| w["code"] }
    end
  end

  # A remote ref that does not resolve (a repo that has never fetched) is
  # nothing to compare against, not a stale base: skip with a warning.
  def test_preflight_skips_with_a_warning_when_the_remote_ref_is_missing
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      expect_preflight_shas(local: LOCAL_SHA, remote: nil)

      code, env = run_create(["zz-abc-new-thing", "--dry-run"])

      assert_equal 0, code
      assert_equal "skipped", env["data"]["preflight"]["status"]
      assert_equal "ref_missing", env["data"]["preflight"]["reason"]
      assert_equal "preflight_skipped", env["warnings"].first["code"]
      assert_includes env["warnings"].first["message"], "origin/main"
    end
  end

  # sabotage: read `parallelism.preflight` with a truthiness test instead of
  # `== true` -> this test still passes, but a written "false" string is a
  # manifest validation error (manifest_test), so the two together close it.
  # Here: an explicit false turns the preflight off and says so, and no
  # rev-parse is registered - reaching one would raise UnexpectedCommand.
  def test_preflight_false_in_the_manifest_disables_it
    manifest = manifest_with(FIXTURE, "parallelism" => { "preflight" => false })

    with_manifest(manifest) do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "myrepo")
        FileUtils.mkdir_p(root)

        expect_location(root)
        @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
        @fake.expect(%w[git fetch origin], out: "")

        code, env = run_create(["zz-abc-new-thing", "--dry-run"])

        assert_equal 0, code
        assert_equal "disabled", env["data"]["preflight"]["status"]
        assert env["commands"].any? { |c| c.include?("git worktree add") }
      end
    end
  end

  # sabotage: hardcode "main" in the preflight's ref names instead of
  # manifest.default_branch -> red (FakeSh::UnexpectedCommand: only the
  # trunk refs are registered)
  def test_preflight_compares_the_manifests_default_branch
    other = manifest_with(FIXTURE, "repo" => { "default_branch" => "trunk" })

    with_manifest(other) do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "myrepo")
        FileUtils.mkdir_p(root)

        expect_location(root)
        @fake.expect(["git", "branch", "--list", "zz-abc-new-thing"], out: "")
        @fake.expect(%w[git fetch origin], out: "")
        expect_preflight_shas(default: "trunk", local: LOCAL_SHA, remote: REMOTE_SHA)
        @fake.expect(["git", "merge-base", "--is-ancestor", LOCAL_SHA, REMOTE_SHA], exitstatus: 1)

        code, env = run_create(["zz-abc-new-thing"])

        assert_equal 1, code
        assert_equal "local_default_diverged", env["data"]["preflight"]["reason"]
        assert_includes env["blocked"].first["message"], "origin/trunk"
      end
    end
  end

  # The preflight runs on a --base cut too: it is about the local default
  # branch's hygiene, not about which ref the branch is cut from.
  def test_preflight_runs_on_a_base_cut
    with_scratch_repo do |root, _worktrees_root|
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "zz-abc.2-child"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      @fake.expect(["git", "rev-parse", "--verify", "--quiet", "zz-abc.1-parent^{commit}"], out: "deadbeef\n")
      expect_preflight_shas(local: LOCAL_SHA, remote: REMOTE_SHA)
      @fake.expect(["git", "merge-base", "--is-ancestor", LOCAL_SHA, REMOTE_SHA], exitstatus: 1)

      code, env = run_create(["zz-abc.2-child", "--base", "zz-abc.1-parent"])

      assert_equal 1, code
      assert_equal "preflight_refused", env["blocked"].first["code"]
    end
  end

  def test_never_force_in_source
    source = File.read(File.expand_path("../worktree_create.rb", __dir__))
    refute_match(/--force\b/, source)
  end
end

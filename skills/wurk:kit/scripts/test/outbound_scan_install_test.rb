# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../outbound_scan"
require_relative "support/fake_sh"

# Phase 4 coverage for outbound_scan.rb install: the pre-push shim writer and
# its --uninstall / --allow-shared-hooks-path modes. Every hooks directory
# here is a Dir.mktmpdir this test creates and controls - never a real
# checkout's hooks directory, and never the machine-global one core.hooksPath
# names on this machine. git rev-parse is always faked via FakeSh; nothing in
# this file shells a real git process.
class OutboundScanInstallTest < Minitest::Test
  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
  end

  def run_cli(argv)
    io = StringIO.new
    code = OutboundScanCli.run(argv, io: io, stdin: StringIO.new(""))
    [code, JSON.parse(io.string)]
  end

  # Sets up the two git rev-parse calls run_install issues, as a "repo"
  # scope: the effective hooks directory is inside the common git dir, the
  # ordinary per-checkout case.
  def expect_repo_scope(repo_dir)
    common_dir = File.join(repo_dir, ".git")
    hooks_dir = File.join(common_dir, "hooks")
    FileUtils.mkdir_p(hooks_dir)
    @fake.expect(["git", "rev-parse", "--path-format=absolute", "--git-path", "hooks"], out: "#{hooks_dir}\n")
    @fake.expect(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], out: "#{common_dir}\n")
    hooks_dir
  end

  # A "shared" scope: the effective hooks directory sits outside the common
  # git dir entirely - what core.hooksPath produces on the machine this bead
  # came from.
  def expect_shared_scope(base_dir)
    common_dir = File.join(base_dir, "repo", ".git")
    hooks_dir = File.join(base_dir, "machine-wide-hooks")
    FileUtils.mkdir_p(hooks_dir)
    @fake.expect(["git", "rev-parse", "--path-format=absolute", "--git-path", "hooks"], out: "#{hooks_dir}\n")
    @fake.expect(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], out: "#{common_dir}\n")
    hooks_dir
  end

  # --- fresh install ----------------------------------------------------

  def test_fresh_install_creates_executable_pre_push_with_markers
    Dir.mktmpdir do |dir|
      hooks_dir = expect_repo_scope(dir)
      code, body = run_cli(["install"])
      assert_equal 0, code
      assert_equal "create", body["data"]["action"]

      pre_push = File.join(hooks_dir, "pre-push")
      assert File.exist?(pre_push)
      assert File.executable?(pre_push)
      content = File.read(pre_push)
      assert_includes content, HookInstaller::BEGIN_MARKER
      assert_includes content, HookInstaller::END_MARKER
      assert content.start_with?("#!/bin/sh\n"), "expected a #!/bin/sh shebang at the top"
    end
  end

  # sabotage: report "create" (or write again) on a second install -> red
  def test_reinstall_is_a_no_op
    Dir.mktmpdir do |dir|
      hooks_dir = expect_repo_scope(dir)
      run_cli(["install"])
      pre_push = File.join(hooks_dir, "pre-push")
      before = File.read(pre_push)
      before_mtime = File.mtime(pre_push)

      expect_repo_scope(dir)
      code, body = run_cli(["install"])
      assert_equal 0, code
      assert_equal "unchanged", body["data"]["action"]
      assert_equal before, File.read(pre_push)
      assert_equal before_mtime, File.mtime(pre_push)
    end
  end

  # --- composing with an existing file -----------------------------------

  def test_install_over_a_foreign_hook_preserves_every_byte_and_inserts_after_shebang
    Dir.mktmpdir do |dir|
      hooks_dir = expect_repo_scope(dir)
      pre_push = File.join(hooks_dir, "pre-push")
      foreign = "#!/bin/sh\necho 'a foreign pre-push hook'\nexit 0\n"
      File.write(pre_push, foreign)
      File.chmod(0o755, pre_push)

      code, body = run_cli(["install"])
      assert_equal 0, code
      assert_equal "insert", body["data"]["action"]

      content = File.read(pre_push)
      assert content.start_with?("#!/bin/sh\n#{HookInstaller::BEGIN_MARKER}\n"),
             "expected the wurk block immediately after the shebang"
      assert_includes content, "echo 'a foreign pre-push hook'"
      assert_includes content, "exit 0"
      # Every original byte below the shebang survives, in order.
      assert content.end_with?("echo 'a foreign pre-push hook'\nexit 0\n")
    end
  end

  def test_install_over_a_file_with_a_beads_section_preserves_it
    Dir.mktmpdir do |dir|
      hooks_dir = expect_repo_scope(dir)
      pre_push = File.join(hooks_dir, "pre-push")
      beads = "#!/bin/sh\n# --- BEGIN BEADS INTEGRATION v1 ---\necho beads\n# --- END BEADS INTEGRATION v1 ---\n"
      File.write(pre_push, beads)
      File.chmod(0o755, pre_push)

      code, body = run_cli(["install"])
      assert_equal 0, code
      assert_equal "insert", body["data"]["action"]

      content = File.read(pre_push)
      assert_includes content, "# --- BEGIN BEADS INTEGRATION v1 ---"
      assert_includes content, "echo beads"
      assert_includes content, "# --- END BEADS INTEGRATION v1 ---"
      # Ours goes first, right after the shebang.
      assert content.index(HookInstaller::BEGIN_MARKER) < content.index("BEADS INTEGRATION")
    end
  end

  # --- dry run ------------------------------------------------------------

  def test_dry_run_writes_nothing_and_reports_the_same_action
    Dir.mktmpdir do |dir|
      hooks_dir = expect_repo_scope(dir)
      pre_push = File.join(hooks_dir, "pre-push")

      code, body = run_cli(["install", "--dry-run"])
      assert_equal 0, code
      assert_equal "create", body["data"]["action"]
      refute File.exist?(pre_push), "dry-run must not write the file"
    end
  end

  def test_dry_run_over_an_existing_foreign_hook_reports_insert_and_writes_nothing
    Dir.mktmpdir do |dir|
      hooks_dir = expect_repo_scope(dir)
      pre_push = File.join(hooks_dir, "pre-push")
      foreign = "#!/bin/sh\necho original\n"
      File.write(pre_push, foreign)
      File.chmod(0o755, pre_push)

      code, body = run_cli(["install", "--dry-run"])
      assert_equal 0, code
      assert_equal "insert", body["data"]["action"]
      assert_equal foreign, File.read(pre_push)
    end
  end

  # --- uninstall ------------------------------------------------------------

  def test_uninstall_removes_only_our_block
    Dir.mktmpdir do |dir|
      hooks_dir = expect_repo_scope(dir)
      pre_push = File.join(hooks_dir, "pre-push")
      foreign = "#!/bin/sh\necho 'a foreign pre-push hook'\nexit 0\n"
      File.write(pre_push, foreign)
      File.chmod(0o755, pre_push)

      run_cli(["install"])
      assert_includes File.read(pre_push), HookInstaller::BEGIN_MARKER

      expect_repo_scope(dir)
      code, body = run_cli(["install", "--uninstall"])
      assert_equal 0, code
      assert_equal "remove", body["data"]["action"]

      content = File.read(pre_push)
      refute_includes content, HookInstaller::BEGIN_MARKER
      refute_includes content, HookInstaller::END_MARKER
      assert_equal foreign, content
      assert File.exist?(pre_push), "uninstall must never delete a file it did not create"
    end
  end

  def test_uninstall_on_a_file_with_no_wurk_block_is_a_no_op
    Dir.mktmpdir do |dir|
      hooks_dir = expect_repo_scope(dir)
      pre_push = File.join(hooks_dir, "pre-push")
      foreign = "#!/bin/sh\necho original\n"
      File.write(pre_push, foreign)

      code, body = run_cli(["install", "--uninstall"])
      assert_equal 0, code
      assert_equal "unchanged", body["data"]["action"]
      assert_equal foreign, File.read(pre_push)
    end
  end

  # If only a shebang remains after removing our block, the file is left in
  # place - never deleted, since this repo does not delete files it did not
  # create.
  def test_uninstall_leaves_a_shebang_only_file_in_place
    Dir.mktmpdir do |dir|
      hooks_dir = expect_repo_scope(dir)
      run_cli(["install"])
      pre_push = File.join(hooks_dir, "pre-push")

      expect_repo_scope(dir)
      run_cli(["install", "--uninstall"])

      assert File.exist?(pre_push)
      assert_equal "#!/bin/sh\n", File.read(pre_push)
    end
  end

  # --- refusals ---------------------------------------------------------

  def test_refuses_a_non_posix_shell_shebang
    Dir.mktmpdir do |dir|
      hooks_dir = expect_repo_scope(dir)
      pre_push = File.join(hooks_dir, "pre-push")
      File.write(pre_push, "#!/usr/bin/env ruby\nputs 'no'\n")

      code, body = run_cli(["install"])
      assert_equal 1, code
      assert_equal ["pre_push_non_shell_shebang"], body["blocked"].map { |b| b["code"] }
      assert_equal "refuse", body["data"]["action"]
      assert_equal "#!/usr/bin/env ruby\nputs 'no'\n", File.read(pre_push)
    end
  end

  def test_refuses_a_begin_marker_with_no_matching_end
    Dir.mktmpdir do |dir|
      hooks_dir = expect_repo_scope(dir)
      pre_push = File.join(hooks_dir, "pre-push")
      broken = "#!/bin/sh\n#{HookInstaller::BEGIN_MARKER}\necho stuck\n"
      File.write(pre_push, broken)

      code, body = run_cli(["install"])
      assert_equal 1, code
      assert_equal ["pre_push_unmatched_begin_marker"], body["blocked"].map { |b| b["code"] }
      assert_equal broken, File.read(pre_push)
    end
  end

  # --- shared hooks path scope --------------------------------------------

  def test_refuses_shared_scope_without_the_flag
    Dir.mktmpdir do |dir|
      hooks_dir = expect_shared_scope(dir)
      code, body = run_cli(["install"])
      assert_equal 1, code
      assert_equal ["shared_hooks_path"], body["blocked"].map { |b| b["code"] }
      assert_equal "shared", body["data"]["hooks_dir_scope"]
      refute File.exist?(File.join(hooks_dir, "pre-push"))
    end
  end

  def test_succeeds_on_shared_scope_with_the_flag
    Dir.mktmpdir do |dir|
      hooks_dir = expect_shared_scope(dir)
      code, body = run_cli(["install", "--allow-shared-hooks-path"])
      assert_equal 0, code
      assert_equal "shared", body["data"]["hooks_dir_scope"]
      assert File.exist?(File.join(hooks_dir, "pre-push"))
    end
  end

  def test_repo_scope_reported_for_the_ordinary_case
    Dir.mktmpdir do |dir|
      expect_repo_scope(dir)
      _code, body = run_cli(["install", "--dry-run"])
      assert_equal "repo", body["data"]["hooks_dir_scope"]
    end
  end

  # --- participant-above detection (detect and warn, never repair) -------

  def test_warns_when_a_beads_block_sits_above_ours_on_reinstall
    Dir.mktmpdir do |dir|
      hooks_dir = expect_repo_scope(dir)
      pre_push = File.join(hooks_dir, "pre-push")
      # Hand-construct the reordered state directly: a beads block above an
      # already-installed wurk block.
      content = "#!/bin/sh\n# --- BEGIN BEADS INTEGRATION v1 ---\necho beads\n" \
                "# --- END BEADS INTEGRATION v1 ---\n" + HookInstaller::SHIM_BLOCK
      File.write(pre_push, content)
      File.chmod(0o755, pre_push)

      code, body = run_cli(["install"])
      assert_equal 0, code
      assert_equal ["hook_participant_above_scan"], body["warnings"].map { |w| w["code"] }
      assert_equal "unchanged", body["data"]["action"]
    end
  end

  # --- the shim block's own shape ------------------------------------------

  def test_shim_block_has_no_backtick_and_never_spells_the_banned_push_phrase_outside_a_comment
    refute_includes HookInstaller::SHIM_BLOCK, "`"

    banned = /\bgit\s+push\b/
    HookInstaller::SHIM_BLOCK.each_line do |line|
      code = line.sub(/#.*/, "")
      refute_match banned, code, "the shim block spells the banned push phrase outside a comment: #{line.inspect}"
    end
  end

  # Syntax check only - this never executes the hook logic, it only parses
  # it, so it has no side effects and touches no real hooks directory.
  def test_shim_block_parses_cleanly_under_sh_dash_n
    Dir.mktmpdir do |dir|
      script = File.join(dir, "shim.sh")
      File.write(script, "#!/bin/sh\n" + HookInstaller::SHIM_BLOCK)

      out = IO.popen(["/bin/sh", "-n", script], err: [:child, :out], &:read)
      assert $?.success?, "sh -n reported a syntax error: #{out}"
    end
  end
end

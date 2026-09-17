# frozen_string_literal: true

require "minitest/autorun"
require_relative "support/home_guard"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"

# install.rb's --with hooks: opt-in hook links, the printed settings.json
# snippet, and the promise that the default install is unchanged. Every
# home here is a Dir.mktmpdir passed as --home; ENV["HOME"] is never read
# or touched, and the real ~/.claude is never the target. The repo root is
# this checkout, read-only: install.rb only globs it and links to it.
class InstallTest < Minitest::Test
  REPO_ROOT = File.expand_path("../../../..", __dir__)
  INSTALL_RB = File.join(REPO_ROOT, "install.rb")

  # $PROGRAM_NAME is this test, never install.rb, so the trailing `exit
  # Install.main(ARGV)` guard stays quiet under load.
  load INSTALL_RB unless defined?(Install::Installer)

  def hook_basenames
    Dir.glob(File.join(REPO_ROOT, "hooks", "*.sh")).map { |p| File.basename(p) }.sort
  end

  def installer(home, with: [])
    Install::Installer.new(repo_root: REPO_ROOT, home: home, with: with)
  end

  def run_main(argv)
    io = StringIO.new
    code = Install.main(argv, io: io)
    [code, io.string]
  end

  # The snippet is the JSON object after the summary; everything before
  # the first `{` at column 0 is the action lines and the explanation.
  def snippet_from(output)
    JSON.parse(output[output.index(/^\{/)..-1])
  end

  def test_repo_ships_three_hooks
    assert_equal %w[harness-event.sh main-session-policy.sh safe-wait-guard.sh], hook_basenames
  end

  # sabotage: link hooks unconditionally in install_actions -> red
  def test_default_install_plans_no_hooks
    Dir.mktmpdir do |home|
      actions = installer(home).install_actions
      hooks_dir = File.join(home, ".claude", "hooks")
      refute actions.any? { |a| a.path.start_with?(hooks_dir) },
             "default install must not touch #{hooks_dir}"
      refute actions.any? { |a| a.target.to_s.include?("/hooks/") }
    end
  end

  def test_with_hooks_adds_the_dir_and_one_link_per_hook
    Dir.mktmpdir do |home|
      default = installer(home).install_actions
      with = installer(home, with: %w[hooks]).install_actions
      hooks_dir = File.join(home, ".claude", "hooks")

      extra = with - default
      assert_equal [:mkdir], extra.select { |a| a.kind == :mkdir }.map(&:kind)
      assert_equal hooks_dir, extra.find { |a| a.kind == :mkdir }.path

      links = extra.select { |a| a.kind == :link }
      assert_equal hook_basenames.map { |b| File.join(hooks_dir, "wurk-#{b}") }, links.map(&:path)
      assert_equal hook_basenames.map { |b| File.join(REPO_ROOT, "hooks", b) }, links.map(&:target)
      assert_equal default, with - extra, "the hooks-less part of the plan must be the default plan"
    end
  end

  def test_main_with_hooks_creates_links_and_prints_a_parseable_snippet
    Dir.mktmpdir do |home|
      code, out = run_main(["--home", home, "--with", "hooks"])
      assert_equal 0, code

      snippet = snippet_from(out)
      commands = snippet.fetch("hooks").values.flatten.flat_map { |e| e.fetch("hooks") }.map { |h| h.fetch("command") }
      assert_equal hook_basenames.map { |b| File.join(home, ".claude", "hooks", "wurk-#{b}") }, commands.sort
      commands.each do |path|
        assert File.symlink?(path), "#{path} should be a symlink"
        assert File.exist?(path), "#{path} should resolve"
        assert File.executable?(path), "#{path} should be executable"
        refute path.start_with?("~"), "snippet paths must be absolute"
      end

      assert_equal "startup", snippet["hooks"]["SessionStart"].first["matcher"]
      assert_equal "Bash", snippet["hooks"]["PreToolUse"].first["matcher"]
      assert_equal "", snippet["hooks"]["PostToolUse"].first["matcher"],
                   "an empty matcher is every tool, which is what a per-call recorder needs"
      assert_includes snippet["hooks"]["SessionStart"].first["hooks"].first["command"], "wurk-main-session-policy.sh"
      assert_includes snippet["hooks"]["PreToolUse"].first["hooks"].first["command"], "wurk-safe-wait-guard.sh"
      assert_includes snippet["hooks"]["PostToolUse"].first["hooks"].first["command"], "wurk-harness-event.sh"
      assert_includes out, "settings.json"
      assert_includes out, "never edits settings.json"
    end
  end

  # sabotage: skip print_hook_wiring on dry runs -> red
  def test_with_hooks_dry_run_creates_nothing_but_still_prints_the_snippet
    Dir.mktmpdir do |home|
      code, out = run_main(["--home", home, "--with", "hooks", "--dry-run"])
      assert_equal 0, code
      refute File.exist?(File.join(home, ".claude")), "dry run must create nothing"
      snippet = snippet_from(out)
      assert_equal %w[PostToolUse PreToolUse SessionStart], snippet["hooks"].keys.sort
    end
  end

  def test_default_install_output_mentions_neither_hooks_nor_settings
    Dir.mktmpdir do |home|
      code, out = run_main(["--home", home])
      assert_equal 0, code
      refute_match(/hooks/, out)
      refute_match(/settings\.json/, out)
      refute File.exist?(File.join(home, ".claude", "hooks"))
    end
  end

  def test_unknown_with_name_is_a_usage_error
    Dir.mktmpdir do |home|
      code = nil
      _, err = capture_io { code, = run_main(["--home", home, "--with", "bogus"]) }
      assert_equal 2, code
      assert_includes err, "bogus"
      refute File.exist?(File.join(home, ".claude")), "a usage error must change nothing"
    end
  end

  def test_uninstall_removes_hook_links_and_leaves_foreign_links_alone
    Dir.mktmpdir do |home|
      code, = run_main(["--home", home, "--with", "hooks"])
      assert_equal 0, code

      hooks_dir = File.join(home, ".claude", "hooks")
      foreign_target = File.join(home, "elsewhere.sh")
      File.write(foreign_target, "#!/bin/sh\n")
      foreign = File.join(hooks_dir, "someone-elses.sh")
      File.symlink(foreign_target, foreign)
      real_file = File.join(hooks_dir, "hand-written.sh")
      File.write(real_file, "#!/bin/sh\n")

      code, out = run_main(["--home", home, "--uninstall"])
      assert_equal 0, code
      hook_basenames.each do |b|
        refute File.symlink?(File.join(hooks_dir, "wurk-#{b}")), "wurk-#{b} should be unlinked"
        assert_includes out, "wurk-#{b}"
      end
      assert File.symlink?(foreign), "a symlink pointing outside the repo is not ours to remove"
      assert File.file?(real_file), "a real file is never touched"
      refute_includes out, "someone-elses"
    end
  end

  def test_hook_settings_names_every_shipped_hook
    Dir.mktmpdir do |home|
      settings = installer(home, with: %w[hooks]).hook_settings
      placed = settings["hooks"].values.flatten.flat_map { |e| e["hooks"] }.map { |h| File.basename(h["command"]) }
      assert_equal hook_basenames.map { |b| "wurk-#{b}" }, placed.sort,
                   "every hooks/*.sh needs an Installer::HOOK_EVENTS entry or the snippet cannot wire it"
    end
  end
end

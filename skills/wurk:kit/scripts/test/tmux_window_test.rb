# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../tmux_window"
require_relative "support/manifest_helper"
require_relative "support/user_config_helper"
require_relative "support/fake_sh"

# TmuxWindow::classify against captured fixtures, verbatim from
# cleanup-worktrees/SKILL.md's idle-classifier section: dim placeholder,
# half-typed draft, dialog, empty box, spinner frame, and a spinner frame
# whose verb is one not listed anywhere - proving the verb is never matched.
# Fixtures are raw bytes (real ESC 0x1b, not "\e" as literal backslash-e
# text) under test/fixtures/pane/, the same shape `tmux capture-pane -e -p`
# emits.
class TmuxWindowClassifyTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/pane", __dir__)

  def fixture(name)
    File.read(File.join(FIXTURES, name), mode: "rb")
  end

  def test_dim_placeholder_is_idle
    assert_equal "idle", TmuxWindow.classify(fixture("dim_placeholder.txt"))
  end

  def test_half_typed_draft_is_busy
    assert_equal "busy", TmuxWindow.classify(fixture("half_typed_draft.txt"))
  end

  def test_dialog_awaiting_an_answer_is_busy
    assert_equal "busy", TmuxWindow.classify(fixture("dialog.txt"))
  end

  def test_empty_box_is_idle
    assert_equal "idle", TmuxWindow.classify(fixture("empty_box.txt"))
  end

  # empty_box.txt was hand-authored with an ASCII space; the real thing pads
  # the box with U+00A0, which String#strip does not remove - every idle
  # window read as busy until classify stopped using strip.
  # sabotage: only_styling? back to .strip.empty? -> red
  def test_empty_box_padded_with_a_non_breaking_space_is_idle
    assert_equal "idle", TmuxWindow.classify(fixture("empty_box_nbsp.txt"))
  end

  def test_the_nbsp_fixture_really_carries_the_u00a0_byte_pair
    line = fixture("empty_box_nbsp.txt").lines.find { |l| l.include?("\xE2\x9D\xAF".b) }
    assert_includes line, "\xC2\xA0".b, "fixture lost the NBSP pad that makes this case distinct from empty_box.txt"
  end

  def test_spinner_frame_is_busy
    assert_equal "busy", TmuxWindow.classify(fixture("spinner_frame.txt"))
  end

  # The verb ("Bamboozling…") appears nowhere in TmuxWindow - only the timer
  # chunk ("(12s · ") drives the match. If this ever started matching on the
  # verb text, this fixture (whose verb is invented and matches no known
  # spinner word) would flip to idle.
  def test_spinner_with_an_unlisted_verb_is_still_busy
    assert_equal "busy", TmuxWindow.classify(fixture("spinner_unlisted_verb.txt"))
  end

  def test_fixtures_carry_real_escape_bytes_not_the_literal_backslash_e_text
    dim = fixture("dim_placeholder.txt")
    refute_includes dim, "\\e[2m", "fixture should hold a real ESC byte, not the literal two-character sequence \\e"
    assert_includes dim, "\e[2m", "fixture is missing the real ESC (0x1b) byte tmux capture-pane -e actually emits"
  end

  def test_classify_takes_only_the_last_marker_line
    # dim_placeholder.txt's first ❯ line is real, visible, non-dim text
    # ("discard the model change") - if classify read that line instead of
    # the last one, this would come back busy.
    text = fixture("dim_placeholder.txt")
    assert_equal "idle", TmuxWindow.classify(text)
  end

  # Input chips (st-byl): a pasted-text placeholder, a pasted-image
  # placeholder, and an @-file mention, captured 2026-08-07 from a real
  # st-byl-capture:1 session via tmux load-buffer/paste-buffer, C-v against a
  # clipboard PNG, and a literal send-keys of "@README.md". None of the three
  # came back dim-wrapped, so no idle-rule change was needed - these tests
  # exist to keep that verified rather than merely asserted in a bead.
  # sabotage: last.sub(/\A.*?❯ ?/, "") changed to strip the whole line instead
  # of just the prefix, so after_marker is always "" -> red (every chip test
  # here goes idle)
  def test_pasted_text_chip_is_busy
    assert_equal "busy", TmuxWindow.classify(fixture("chip_pasted_text.txt"))
  end

  # sabotage: wholly_dim_wrapped? changed to `true` unconditionally -> red
  def test_pasted_image_chip_is_busy
    assert_equal "busy", TmuxWindow.classify(fixture("chip_image.txt"))
  end

  # sabotage: only_styling? changed to always return `true` -> red
  def test_at_file_mention_chip_is_busy
    assert_equal "busy", TmuxWindow.classify(fixture("chip_file_mention.txt"))
  end
end

class TmuxWindowTest < Minitest::Test
  include ManifestHelper
  include UserConfigHelper

  # Session name and model are manifest data (`zz-session` / `fakemodel`),
  # and the main checkout is asked of git at runtime. Asserting on
  # "statifier-ex" or "opus" here would have gone green whether or not
  # either value was ever read.
  FIXTURE = "tmux"
  MAIN = "/repos/myrepo"

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
    TmuxWindow.sleep_fn = ->(_seconds) {} # never really sleep in tests
  end

  def teardown
    Sh.runner = nil
    TmuxWindow.sleep_fn = nil
    Manifest.reset!
  end

  def run_tmux(argv, fixture: FIXTURE, user_config: nil)
    io = StringIO.new
    code = nil
    with_manifest(fixture) do
      with_user_config(user_config) { code = TmuxWindow.run(argv, io: io) }
    end
    [code, JSON.parse(io.string)]
  end

  # wu-esa: every `open` call probes for caffeinate before composing the
  # seeded command line. Tests that aren't about the probe itself register
  # this - "no caffeinate on PATH" - so their command-line assertions stay
  # exactly what they were before the probe existed.
  def expect_no_caffeinate
    @fake.expect(%w[which caffeinate], exitstatus: 1)
  end

  def expect_caffeinate_on_ac
    @fake.expect(%w[which caffeinate], exitstatus: 0)
    @fake.expect(["pmset", "-g", "batt"], out: "Now drawing from 'AC Power'\n -InternalBattery-0\t100%; charged;\n")
  end

  # percent defaults above the wu-ds2 40% floor - callers that need the
  # below-floor or unparseable cases pass their own pmset second line.
  def expect_caffeinate_on_battery(percent: 62)
    @fake.expect(%w[which caffeinate], exitstatus: 0)
    @fake.expect(["pmset", "-g", "batt"],
                 out: "Now drawing from 'Battery Power'\n" \
                      " -InternalBattery-0 (id=1234)\t#{percent}%; discharging; 3:21 remaining present: true\n")
  end

  # The main checkout is derived, not configured: every path that names a
  # session working directory asks git for it first.
  def expect_main_checkout
    @fake.expect(%w[git rev-parse --git-common-dir], out: "#{MAIN}/.git\n")
  end

  # sabotage: default a missing tmux section to some session name instead of
  # blocking -> red. A guessed name creates a second, parallel session
  # nothing else in the kit can find.
  def test_a_project_without_a_tmux_section_blocks_rather_than_guessing
    code, env = run_tmux(["ensure-session"], fixture: "worktree")

    assert_equal 1, code
    assert_equal "tmux_not_configured", env["blocked"].first["code"]
    assert_empty @fake.calls
  end

  # sabotage: restore a MAIN_REPO constant and use it instead of
  # Manifest.main_checkout -> the git call never happens, the expectation
  # goes unused and the new-session argv no longer matches -> red
  def test_ensure_session_derives_the_main_checkout_from_git_not_a_constant
    expect_main_checkout
    @fake.expect(["tmux", "has-session", "-t", "=zz-session"], exitstatus: 1)
    @fake.expect(["tmux", "new-session", "-d", "-s", "zz-session", "-c", MAIN], exitstatus: 0)

    code, env = run_tmux(["ensure-session"])

    assert_equal 0, code
    assert_equal MAIN, env["data"]["main_repo"]
    refute_match(%r{/Users/}, File.read(File.expand_path("../tmux_window.rb", __dir__)))
  end

  # sabotage: block instead of reporting when git cannot answer -> this is
  # already the behavior; invert it (fall back to Dir.pwd) and the block
  # disappears -> red
  def test_ensure_session_blocks_when_git_cannot_name_the_main_checkout
    @fake.expect(%w[git rev-parse --git-common-dir], exitstatus: 1, err: "not a git repository\n")

    code, env = run_tmux(["ensure-session"])

    assert_equal 1, code
    assert_equal "main_checkout_unknown", env["blocked"].first["code"]
  end

  # --- ensure-session ------------------------------------------------------

  def test_ensure_session_reuses_an_existing_session
    expect_main_checkout
    @fake.expect(["tmux", "has-session", "-t", "=zz-session"], exitstatus: 0)

    code, env = run_tmux(["ensure-session"])

    assert_equal 0, code
    assert_equal false, env["data"]["created"]
  end

  def test_ensure_session_creates_when_missing
    expect_main_checkout
    @fake.expect(["tmux", "has-session", "-t", "=zz-session"], exitstatus: 1)
    @fake.expect(["tmux", "new-session", "-d", "-s", "zz-session", "-c", MAIN], exitstatus: 0)

    code, env = run_tmux(["ensure-session"])

    assert_equal 0, code
    assert_equal true, env["data"]["created"]
  end

  def test_ensure_session_dry_run_issues_no_commands
    expect_main_checkout

    code, env = run_tmux(["ensure-session", "--dry-run"])

    assert_equal 0, code
    assert env["commands"].any? { |c| c.include?("has-session") }
    assert env["commands"].any? { |c| c.include?("new-session") }
  end

  # --- open ------------------------------------------------------------------

  def test_open_creates_a_window_and_seeds_it
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "other-window\n")
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "zz-abc-thing",
       "-c", "/repos/zz-worktrees/zz-abc-thing"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

    code, env = run_tmux([
                            "open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing",
                            "zz-abc", "/wurk:work zz-abc --auto"
                          ])

    assert_equal 0, code
    assert_equal "@42", env["data"]["window_id"]
    assert_equal "fakemodel", env["data"]["model"]
    assert_equal false, env["data"]["skipped"]

    send_call = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }
    assert_equal "@42", send_call.argv[3]
    keys = send_call.argv[4]
    assert_includes keys, "claude --permission-mode auto --model fakemodel"
    assert_includes keys, "/wurk:work zz-abc --auto"
    assert_includes keys, "/wurk:commit --auto"
    assert_includes keys, "unrelated to zz-abc"
    assert_equal "Enter", send_call.argv[5]
  end

  # The finishing clause names an installed skill, and the name it named went
  # stale through the phase 2 rename without a single test noticing (wu-bls):
  # the old assertion asserted the old string. A seeded session is the one
  # caller nobody is watching, so the name is pinned here in its installed
  # form, and the bare pre-rename spelling is asserted absent.
  def test_seeded_finishing_clause_names_the_installed_skill
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "zz-abc-thing",
       "-c", "/repos/zz-worktrees/zz-abc-thing"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

    run_tmux(["open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing", "zz-abc", "/wurk:work zz-abc --auto"])

    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]

    assert_includes keys, "finish with /wurk:commit --auto"
    refute_match(%r{(?<!wurk:)/commit --auto}, keys)
  end

  # The trailer key is manifest data (fixative writes `Closes #NN`, not
  # `Refs`), and it was a literal in the template until wu-bls. The tmux
  # fixture declares no commits section, so it takes the default "Refs" -
  # asserting that would pass whether or not the manifest was ever read.
  # Overriding to "Closes" is what proves the read.
  def test_seeded_finishing_clause_takes_the_trailer_key_from_the_manifest
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "zz-abc-thing",
       "-c", "/repos/zz-worktrees/zz-abc-thing"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

    fixture = manifest_with("tmux", "commits" => { "trailer" => { "key" => "Closes" } })
    run_tmux(["open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing", "zz-abc", "/wurk:work zz-abc --auto"],
             fixture: fixture)

    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]

    assert_includes keys, "it writes the Closes trailer"
    refute_includes keys, "Refs trailer"
  end

  # wu-hu2: --no-finish suppresses the appended finishing clause entirely -
  # the seeded command is the seed alone, with no /wurk:commit instruction
  # tacked on. This is the shape a release seed (which makes its own commit)
  # or a workspace with no bead id needs.
  def test_open_no_finish_suppresses_the_finishing_clause
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "release-v1.2.3",
       "-c", "/repos/zz-worktrees/release-v1.2.3"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

    code, env = run_tmux([
                            "open", "--no-finish", "release-v1.2.3",
                            "/repos/zz-worktrees/release-v1.2.3",
                            "release-v1.2.3", "/wurk:release 1.2.3"
                          ])

    assert_equal 0, code
    assert_equal true, env["data"]["no_finish"]

    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    assert_includes keys, "claude --permission-mode auto --model fakemodel"
    assert_includes keys, "/wurk:release 1.2.3"
    refute_includes keys, "/wurk:commit --auto"
    refute_includes keys, "finish with"
  end

  # Default (no --no-finish) stays byte-for-byte the existing behavior:
  # data.no_finish reports false and the clause is present, unchanged.
  def test_open_default_still_appends_the_finishing_clause
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "zz-abc-thing",
       "-c", "/repos/zz-worktrees/zz-abc-thing"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

    code, env = run_tmux([
                            "open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing",
                            "zz-abc", "/wurk:work zz-abc --auto"
                          ])

    assert_equal 0, code
    assert_equal false, env["data"]["no_finish"]

    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    assert_includes keys, "/wurk:commit --auto"
    assert_includes keys, "finish with /wurk:commit --auto"
    assert_includes keys, "unrelated to zz-abc"
  end

  # dry-run must render the suppressed command line too, not just the live path.
  def test_open_dry_run_with_no_finish_renders_no_finishing_clause
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    expect_no_caffeinate

    code, env = run_tmux([
                            "open", "--no-finish", "--dry-run", "release-v1.2.3",
                            "/repos/zz-worktrees/release-v1.2.3",
                            "release-v1.2.3", "/wurk:release 1.2.3"
                          ])

    assert_equal 0, code
    send_line = env["commands"].find { |c| c.include?("send-keys") }
    refute_nil send_line
    assert_includes send_line, "/wurk:release 1.2.3"
    refute_includes send_line, "/wurk:commit --auto"
    assert_equal true, env["data"]["no_finish"]
  end

  def test_open_skips_when_window_name_already_exists
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "zz-abc-thing\n")
    # No new-window or send-keys expectation - a name hit must not create a
    # second window.

    code, env = run_tmux(["open", "zz-abc-thing", "/some/path", "zz-abc", "/wurk:work zz-abc --auto"])

    assert_equal 0, code
    assert_equal true, env["data"]["skipped"]
  end

  def test_open_never_sends_keys_when_the_captured_window_id_is_empty
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    expect_no_caffeinate
    @fake.expect(["tmux", "new-window"], out: "") # empty id despite success
    # No send-keys expectation registered at all - FakeSh raises if the code
    # tries. An empty -t "" resolves to the *current* window in real tmux,
    # which cost a live window on 2026-08-02.

    code, env = run_tmux(["open", "zz-abc-thing", "/some/path", "zz-abc", "/wurk:work zz-abc --auto"])

    assert_equal 1, code
    assert_equal "window_id_empty", env["blocked"].first["code"]
  end

  def test_open_dry_run_renders_a_pasteable_command_line
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    expect_no_caffeinate

    code, env = run_tmux([
                            "open", "--dry-run", "zz-abc-thing",
                            "/repos/zz-worktrees/zz-abc-thing",
                            "zz-abc", "/wurk:work zz-abc --auto"
                          ])

    assert_equal 0, code
    send_line = env["commands"].find { |c| c.include?("send-keys") }
    refute_nil send_line
    assert_includes send_line, "claude --permission-mode auto --model fakemodel"
    # Sh.render single-quotes the seeded-command argument, exactly what a
    # human would type at a fish prompt.
    assert_match(/'.*claude --permission-mode auto --model fakemodel.*'/, send_line)
  end

  # --- caffeinate probe (wu-esa) ------------------------------------------

  # Sh.run's real runner shells out via Open3.popen3(*argv), which raises
  # Errno::ENOENT - not a failed Result - when the binary itself is missing.
  # That is the literal shape a platform with no `which` on PATH hits, and
  # FakeSh's #expect can only script a Result, never a raise, so this wraps
  # it to inject the one exception a stubbed Result can't represent.
  class RaisingOnWhichSh
    def initialize(inner)
      @inner = inner
    end

    def run(argv, chdir: nil, timeout: 60)
      raise Errno::ENOENT, "which" if argv[0, 2] == %w[which caffeinate]

      @inner.run(argv, chdir: chdir, timeout: timeout)
    end
  end

  # sabotage: the `rescue StandardError` in caffeinate_available? removed ->
  # red (Errno::ENOENT propagates out of claude_command and the whole `open`
  # call raises instead of degrading to an unwrapped launch)
  def test_open_command_is_unwrapped_when_the_which_probe_raises_enoent
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "zz-abc-thing",
       "-c", "/repos/zz-worktrees/zz-abc-thing"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")
    Sh.runner = RaisingOnWhichSh.new(@fake)

    code, env = run_tmux(["open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing", "zz-abc",
                           "/wurk:work zz-abc --auto"])

    assert_equal 0, code
    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    refute_match(/caffeinate/, keys)
    assert_match(/\Aclaude --permission-mode auto/, keys)
    assert (env["warnings"] || []).empty?
  end

  # sabotage: caffeinate_prefix's `&&` changed to `||` -> red (wraps even
  # when the platform has no caffeinate, as long as it's on AC power)
  def test_open_wraps_the_command_in_caffeinate_when_available_and_on_ac_power
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    expect_caffeinate_on_ac
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "zz-abc-thing",
       "-c", "/repos/zz-worktrees/zz-abc-thing"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

    run_tmux(["open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing", "zz-abc", "/wurk:work zz-abc --auto"])

    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    assert_match(/\Acaffeinate -i claude --permission-mode auto/, keys)
  end

  # Pins the exact unwrapped string a platform with no `caffeinate` produces,
  # so a future change to the probe cannot silently start prepending
  # anything even when the binary genuinely isn't there.
  def test_open_command_is_byte_identical_to_unwrapped_when_caffeinate_is_absent
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "zz-abc-thing",
       "-c", "/repos/zz-worktrees/zz-abc-thing"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

    code, env = run_tmux(["open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing", "zz-abc",
                           "/wurk:work zz-abc --auto"])

    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    assert_equal "claude --permission-mode auto --model fakemodel " \
                 "'/wurk:work zz-abc --auto. When the work is complete, finish with /wurk:commit --auto " \
                 "- it writes the Refs trailer and refuses if the tree carries changes unrelated to zz-abc. " \
                 "Do not run git commit directly.'", keys
    assert_empty env["warnings"] || []
  end

  # wu-jhb: permission_mode now comes from the machine-level config
  # (~/.claude/wurk.local.json via lib/user_config.rb), not the manifest.
  # No machine config present -> the pre-wu-jhb default command line,
  # unchanged - test_open_command_is_byte_identical_to_unwrapped_when_caffeinate_is_absent
  # above already exercises this with no user_config: passed, since run_tmux
  # defaults it to absent; this test just names that regression guard
  # explicitly.
  def test_open_with_no_machine_config_uses_the_default_permission_mode
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "zz-abc-thing",
       "-c", "/repos/zz-worktrees/zz-abc-thing"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

    code, env = run_tmux(["open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing", "zz-abc",
                           "/wurk:work zz-abc --auto"])

    assert_equal 0, code
    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    assert_includes keys, "claude --permission-mode auto --model fakemodel"
  end

  # One test per supported machine-config value, asserting the exact
  # send-keys payload each produces.
  %w[auto default acceptEdits plan].each do |mode|
    define_method("test_open_uses_permission_mode_#{mode}_from_machine_config") do
      @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
      expect_no_caffeinate
      @fake.expect(
        ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "zz-abc-thing",
         "-c", "/repos/zz-worktrees/zz-abc-thing"],
        out: "@42\n"
      )
      @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

      code, env = run_tmux(["open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing", "zz-abc",
                             "/wurk:work zz-abc --auto"],
                            user_config: { "tmux" => { "permission_mode" => mode } })

      assert_equal 0, code
      keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
      assert_includes keys, "--permission-mode #{mode}"
    end
  end

  # wu-b7f (now machine config, wu-jhb): "skip-permissions" swaps the entire
  # flag for --dangerously-skip-permissions, with no --permission-mode
  # alongside it.
  def test_open_command_uses_dangerously_skip_permissions_when_machine_config_selects_it
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "zz-abc-thing",
       "-c", "/repos/zz-worktrees/zz-abc-thing"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

    code, env = run_tmux(["open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing", "zz-abc",
                           "/wurk:work zz-abc --auto"],
                          user_config: { "tmux" => { "permission_mode" => "skip-permissions" } })

    assert_equal 0, code
    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    assert_equal "claude --dangerously-skip-permissions --model fakemodel " \
                 "'/wurk:work zz-abc --auto. When the work is complete, finish with /wurk:commit --auto " \
                 "- it writes the Refs trailer and refuses if the tree carries changes unrelated to zz-abc. " \
                 "Do not run git commit directly.'", keys
    refute_match(/--permission-mode/, keys)
    assert_empty env["warnings"] || []
  end

  # An invalid machine-config value blocks before any tmux command is
  # issued, including the caffeinate probe - a bad config costs nothing.
  def test_open_blocks_on_an_invalid_machine_config_permission_mode_and_shells_out_nothing
    code, env = run_tmux(["open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing", "zz-abc",
                           "/wurk:work zz-abc --auto"],
                          user_config: { "tmux" => { "permission_mode" => "yolo" } })

    assert_equal 1, code
    blocked = env["blocked"].first
    assert_match(/tmux\.permission_mode/, blocked["message"])
    assert_empty @fake.calls
  end

  # A manifest that still sets the retired tmux.permission_mode key must not
  # change the composed command line - the machine config (or its default)
  # governs regardless.
  def test_open_ignores_a_manifest_that_still_sets_the_retired_permission_mode_key
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "zz-abc-thing",
       "-c", "/repos/zz-worktrees/zz-abc-thing"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

    fixture = manifest_with("tmux", "tmux" => { "permission_mode" => "skip-permissions" })
    code, env = run_tmux(["open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing", "zz-abc",
                           "/wurk:work zz-abc --auto"],
                          fixture: fixture,
                          user_config: { "tmux" => { "permission_mode" => "plan" } })

    assert_equal 0, code
    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    assert_includes keys, "--permission-mode plan"
    refute_match(/skip-permissions/, keys)
  end

  # wu-ds2: above the 40% floor, battery is treated the same as AC - the
  # 2026-08-13 incident (four seeded sessions idle-slept unwrapped on
  # battery at 71%) is exactly the case this closes.
  # sabotage: `> BATTERY_FLOOR_PERCENT` changed to `>=` -> still green here
  # (62% clears either comparison); this test only rules out the floor being
  # ignored outright. It's the exactly-40% test below that flips on `>=`.
  def test_open_wraps_the_command_in_caffeinate_when_on_battery_above_the_floor
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    expect_caffeinate_on_battery(percent: 62)
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "zz-abc-thing",
       "-c", "/repos/zz-worktrees/zz-abc-thing"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

    code, env = run_tmux(["open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing", "zz-abc",
                           "/wurk:work zz-abc --auto"])

    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    assert_match(/\Acaffeinate -i claude --permission-mode auto/, keys)
    assert_equal 0, code
    assert (env["warnings"] || []).empty?
  end

  # The probe doubles as the opt-out (wu-esa's settled design), and the
  # 40% floor (wu-ds2) keeps it that way at and below the floor: the launch
  # degrades exactly like a platform with no caffeinate at all - unwrapped,
  # byte-identical, and not an error or a warning. 40% itself is the pinned
  # boundary - the bead requires strictly greater than 40, not >=.
  # sabotage: `> BATTERY_FLOOR_PERCENT` changed to `>=` -> red (at exactly
  # 40%, `>=` wraps the command while `>` does not; this is the one case
  # that tells the two comparisons apart)
  def test_open_command_is_unwrapped_when_on_battery_at_the_floor
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    expect_caffeinate_on_battery(percent: 40)
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "zz-abc-thing",
       "-c", "/repos/zz-worktrees/zz-abc-thing"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

    code, env = run_tmux(["open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing", "zz-abc",
                           "/wurk:work zz-abc --auto"])

    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    refute_match(/caffeinate/, keys)
    assert_match(/\Aclaude --permission-mode auto/, keys)
    assert_equal 0, code
    assert (env["warnings"] || []).empty?
  end

  # sabotage: the `percent.nil?` guard in power_ok? removed -> red
  # (percent.to_i on nil raises NoMethodError instead of degrading, or
  # `nil.to_i` silently reads as 0 and the launch stays unwrapped for the
  # wrong reason - either way this pins the unwrapped, byte-identical
  # outcome for pmset output with no parseable percentage on the second
  # line, e.g. Full Battery Charging).
  def test_open_command_is_unwrapped_when_the_battery_percentage_is_unparseable
    @fake.expect(["tmux", "list-windows", "-t", "=zz-session", "-F", '#{window_name}'], out: "")
    @fake.expect(%w[which caffeinate], exitstatus: 0)
    @fake.expect(["pmset", "-g", "batt"], out: "Now drawing from 'Battery Power'\n -InternalBattery-0\tno info\n")
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=zz-session:", "-n", "zz-abc-thing",
       "-c", "/repos/zz-worktrees/zz-abc-thing"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

    code, env = run_tmux(["open", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing", "zz-abc",
                           "/wurk:work zz-abc --auto"])

    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    refute_match(/caffeinate/, keys)
    assert_match(/\Aclaude --permission-mode auto/, keys)
    assert_equal 0, code
    assert (env["warnings"] || []).empty?
  end

  # --- find --------------------------------------------------------------

  def test_find_matches_on_name_and_path_together
    @fake.expect(
      ["tmux", "list-panes", "-a", "-F", '#{window_id} #{window_name} #{pane_current_path}'],
      out: "@1 other-name /some/other/path\n@2 zz-abc-thing /repos/zz-worktrees/zz-abc-thing\n"
    )

    code, env = run_tmux(["find", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing"])

    assert_equal 0, code
    assert_equal true, env["data"]["found"]
    assert_equal "@2", env["data"]["window_id"]
  end

  # Under window-per-issue, session is always nil and session_scoped false -
  # find has no session to report, and none of its matching logic changes.
  def test_find_reports_session_and_session_scoped_under_window_per_issue
    @fake.expect(
      ["tmux", "list-panes", "-a", "-F", '#{window_id} #{window_name} #{pane_current_path}'],
      out: "@2 zz-abc-thing /repos/zz-worktrees/zz-abc-thing\n"
    )

    code, env = run_tmux(["find", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing"])

    assert_equal 0, code
    assert_nil env["data"]["session"]
    assert_equal false, env["data"]["session_scoped"]
  end

  # A project with no tmux section at all (the "worktree" fixture) must
  # behave exactly as today - byte-identical list-panes format, no block on
  # the missing section, and no session-scoping. find's no-block posture is
  # what keeps /wurk:cleanup safe on projects that never opted into tmux.
  def test_find_with_no_tmux_section_behaves_as_today_and_does_not_block
    @fake.expect(
      ["tmux", "list-panes", "-a", "-F", '#{window_id} #{window_name} #{pane_current_path}'],
      out: "@2 zz-abc-thing /repos/zz-worktrees/zz-abc-thing\n"
    )

    code, env = run_tmux(["find", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing"], fixture: "worktree")

    assert_equal 0, code
    assert_empty env["blocked"]
    assert_equal true, env["data"]["found"]
    assert_equal "@2", env["data"]["window_id"]
    assert_equal false, env["data"]["session_scoped"]
  end

  def test_find_no_match_is_not_an_error
    @fake.expect(
      ["tmux", "list-panes", "-a", "-F", '#{window_id} #{window_name} #{pane_current_path}'],
      out: "@1 other-name /some/other/path\n"
    )

    code, env = run_tmux(["find", "zz-abc-thing", "/nowhere"])

    assert_equal 0, code
    assert_equal false, env["data"]["found"]
    assert_nil env["data"]["window_id"]
  end

  def test_find_two_matching_windows_blocks
    out = "@1 zz-abc-thing /repos/zz-worktrees/zz-abc-thing\n" \
          "@2 zz-abc-thing /repos/zz-worktrees/zz-abc-thing\n"
    @fake.expect(["tmux", "list-panes", "-a", "-F", '#{window_id} #{window_name} #{pane_current_path}'], out: out)

    code, env = run_tmux(["find", "zz-abc-thing", "/repos/zz-worktrees/zz-abc-thing"])

    assert_equal 1, code
    assert_equal "ambiguous_window_match", env["blocked"].first["code"]
  end

  # --- classify (subcommand) ------------------------------------------------

  def test_classify_cmd_requires_both_samples_idle
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "claude\n")
    @fake.expect(["tmux", "capture-pane", "-e", "-p", "-t", "@2"], out: "\xe2\x9d\xaf \e[39m\n")
    @fake.expect(["tmux", "capture-pane", "-e", "-p", "-t", "@2"], out: "\xe2\x9d\xaf \e[39m\n")

    code, env = run_tmux(["classify", "@2"])

    assert_equal 0, code
    assert_equal "idle", env["data"]["status"]
    assert_equal %w[idle idle], env["data"]["samples"]
  end

  def test_classify_cmd_one_busy_sample_is_enough_to_call_it_busy
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "claude\n")
    @fake.expect(["tmux", "capture-pane", "-e", "-p", "-t", "@2"], out: "\xe2\x9d\xaf half a draft\n")
    @fake.expect(["tmux", "capture-pane", "-e", "-p", "-t", "@2"], out: "\xe2\x9d\xaf \e[39m\n")

    code, env = run_tmux(["classify", "@2"])

    assert_equal 0, code
    assert_equal "busy", env["data"]["status"]
  end

  def test_classify_cmd_never_captures_with_an_empty_window_id
    code, env = run_tmux(["classify", ""])

    assert_equal 1, code
    assert_equal "empty_window_id", env["blocked"].first["code"]
    assert_empty @fake.calls
  end

  # st-zgf: a pane at a bare shell prompt (claude already exited - by /exit,
  # by crash, or the session never having been started) must report
  # "exited", not fall through to the byte-level idle/busy classifier. The
  # byte classifier would read an empty shell prompt as "idle", which then
  # sent /wurk:cleanup into a full quiesce (typing /exit into a plain
  # shell) on a window that was ready to close from the start.
  # sabotage: classify_cmd's `if bare_shell_panes?(panes_res)` branch
  # deleted, falling straight through to capture_and_classify -> red
  # (FakeSh::UnexpectedCommand: no capture-pane expectation is registered)
  def test_classify_cmd_reports_exited_when_pane_is_a_bare_shell
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "fish\n")
    # No capture-pane expectation - a bare-shell pane must never reach the
    # byte-level classifier at all.

    code, env = run_tmux(["classify", "@2"])

    assert_equal 0, code
    assert_equal "exited", env["data"]["status"]
    assert_equal "@2", env["data"]["window_id"]
  end

  def test_classify_cmd_bare_shell_check_covers_every_pane_in_the_window
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "fish\nzsh\n")

    code, env = run_tmux(["classify", "@2"])

    assert_equal 0, code
    assert_equal "exited", env["data"]["status"]
  end

  def test_classify_cmd_falls_through_to_byte_classifier_when_list_panes_fails
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], exitstatus: 1)
    @fake.expect(["tmux", "capture-pane", "-e", "-p", "-t", "@2"], out: "\xe2\x9d\xaf \e[39m\n")
    @fake.expect(["tmux", "capture-pane", "-e", "-p", "-t", "@2"], out: "\xe2\x9d\xaf \e[39m\n")

    code, env = run_tmux(["classify", "@2"])

    assert_equal 0, code
    assert_equal "idle", env["data"]["status"]
  end

  # --- quiesce -------------------------------------------------------------

  def test_quiesce_sends_ctrl_u_then_exit_then_polls_to_a_bare_shell
    @fake.expect(["tmux", "send-keys", "-t", "@2", "C-u"], out: "")
    @fake.expect(["tmux", "send-keys", "-t", "@2", "/exit", "Enter"], out: "")
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "2.1.220\n")
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "fish\n")

    code, env = run_tmux(["quiesce", "@2"])

    assert_equal 0, code
    assert_equal "exited", env["data"]["status"]
  end

  def test_quiesce_timeout_is_blocked_not_escalated
    @fake.expect(["tmux", "send-keys", "-t", "@2", "C-u"], out: "")
    @fake.expect(["tmux", "send-keys", "-t", "@2", "/exit", "Enter"], out: "")
    15.times { @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "2.1.220\n") }
    # No further expectations - a timeout must not try anything else, kill
    # included.

    code, env = run_tmux(["quiesce", "@2"])

    assert_equal 1, code
    assert_equal "quiesce_timeout", env["blocked"].first["code"]
  end

  def test_quiesce_never_issues_a_command_with_an_empty_window_id
    code, env = run_tmux(["quiesce", ""])

    assert_equal 1, code
    assert_equal "empty_window_id", env["blocked"].first["code"]
    assert_empty @fake.calls
  end

  def test_quiesce_dry_run_issues_no_commands
    code, env = run_tmux(["quiesce", "--dry-run", "@2"])

    assert_equal 0, code
    assert env["commands"].any? { |c| c.include?("/exit") }
    assert_empty @fake.calls
  end

  # --- close -----------------------------------------------------------------

  def test_close_kills_the_window_when_every_pane_is_a_bare_shell
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "fish\n")
    @fake.expect(["tmux", "kill-window", "-t", "@2"], out: "")

    code, env = run_tmux(["close", "@2"])

    assert_equal 0, code
    assert_equal true, env["data"]["closed"]
  end

  def test_close_keeps_the_window_when_a_pane_is_busy
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "2.1.220\n")
    # No kill-window expectation - a live pane must never be closed.

    code, env = run_tmux(["close", "@2"])

    assert_equal 0, code
    assert_equal false, env["data"]["closed"]
    assert_match(/other panes busy/, env["data"]["reason"])
  end

  def test_close_never_issues_a_command_with_an_empty_window_id
    code, env = run_tmux(["close", ""])

    assert_equal 1, code
    assert_equal "empty_window_id", env["blocked"].first["code"]
    assert_empty @fake.calls
  end

  # Without --session, close stays byte-identical to today: no has-session,
  # no list-panes -s, no kill-session, nothing session-shaped in the calls
  # or the data.
  def test_close_without_session_issues_no_session_command_at_all
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "fish\n")
    @fake.expect(["tmux", "kill-window", "-t", "@2"], out: "")

    code, env = run_tmux(["close", "@2"])

    assert_equal 0, code
    assert_equal true, env["data"]["closed"]
    refute env["data"].key?("session_closed")
    refute(@fake.calls.any? { |c| c.argv.include?("has-session") || c.argv.include?("kill-session") })
  end

  # --- source-level guarantees ------------------------------------------

  # The three banned kill operations are allowed to appear in the one
  # header comment in tmux_window.rb that forbids them (see the plan's own
  # grep check in statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase
  # 5), but never in a line that isn't a comment. The needles are assembled
  # at runtime, not spelled out contiguously here, so this test file itself
  # doesn't add a second grep hit next to the one that comment permits.
  def test_banned_kill_operations_appear_only_in_the_forbidding_comment
    needles = ["kill" + "-pane", "kill" + " -9", "SIG" + "KILL"]
    banned = Regexp.union(needles.map { |n| Regexp.new(Regexp.escape(n)) })

    source = File.read(File.expand_path("../tmux_window.rb", __dir__))
    hits = source.each_line.select { |l| l =~ banned }

    refute_empty hits, "expected the forbidding comment to be present"
    hits.each do |line|
      assert_match(/\A\s*#/, line, "found a banned kill operation outside a comment: #{line.inspect}")
    end
  end

  def test_kill_window_only_targets_a_window_confirmed_all_bare_shells
    # tmux's window-level close (distinct from the banned pane/signal kills
    # above) is legitimate in close_window, but only ever issued after
    # list-panes confirms every pane is a bare shell.
    @fake.expect(["tmux", "list-panes", "-t", "@2", '-F', '#{pane_current_command}'], out: "fish\nzsh\n")
    @fake.expect(["tmux", "kill-window", "-t", "@2"], out: "")

    code, env = run_tmux(["close", "@2"])

    assert_equal 0, code
    assert_equal true, env["data"]["closed"]
  end
end

# session-per-issue: each workspace gets its own tmux session instead of a
# window inside one shared, manifest-named session. Same FakeSh + sleep_fn
# setup as TmuxWindowTest, driven off the tmux_session_per_issue fixture
# instead (layout: session-per-issue, model: fakemodel, editor: ["nvim"],
# no `session` key at all - see manifest fixture and Decision 4).
class TmuxWindowSessionPerIssueTest < Minitest::Test
  include ManifestHelper
  include UserConfigHelper

  FIXTURE = "tmux_session_per_issue"
  NAME = "wu-aqy-thing"
  PATH = "/repos/zz-worktrees/wu-aqy-thing"
  ID = "wu-aqy"
  SEED = "/wurk:work wu-aqy --auto"

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
    TmuxWindow.sleep_fn = ->(_seconds) {}
  end

  def teardown
    Sh.runner = nil
    TmuxWindow.sleep_fn = nil
    Manifest.reset!
  end

  def run_tmux(argv, fixture: FIXTURE, user_config: nil)
    io = StringIO.new
    code = nil
    with_manifest(fixture) do
      with_user_config(user_config) { code = TmuxWindow.run(argv, io: io) }
    end
    [code, JSON.parse(io.string)]
  end

  def expect_no_caffeinate
    @fake.expect(%w[which caffeinate], exitstatus: 1)
  end

  def open_argv(extra = [])
    ["open", *extra, NAME, PATH, ID, SEED]
  end

  # --- ensure-session --------------------------------------------------

  def test_ensure_session_is_a_reporting_no_op_and_issues_no_tmux_command
    code, env = run_tmux(["ensure-session"])

    assert_equal 0, code
    assert_equal "session-per-issue", env["data"]["layout"]
    assert_equal false, env["data"]["created"]
    assert_equal true, env["data"]["skipped"]
    assert_match(/each workspace gets its own session/, env["data"]["reason"])
    assert_empty @fake.calls
  end

  # The fixture omits tmux.session entirely (Decision 4); session_name_unused
  # must reflect "no session configured", i.e. false here.
  def test_ensure_session_reports_session_name_unused_false_when_no_session_is_configured
    _code, env = run_tmux(["ensure-session"])

    assert_equal false, env["data"]["session_name_unused"]
  end

  # A session-per-issue project that does set tmux.session anyway gets that
  # fact reported, not silently ignored (Decision 4).
  def test_ensure_session_reports_session_name_unused_true_when_a_stray_session_is_configured
    fixture = manifest_with(FIXTURE, "tmux" => { "session" => "stray-session" })

    _code, env = run_tmux(["ensure-session"], fixture: fixture)

    assert_equal true, env["data"]["session_name_unused"]
    assert_empty @fake.calls
  end

  # --- open: full sequence, order, and argv -----------------------------

  def test_open_creates_the_session_as_the_editor_window_then_the_claude_window_in_order
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 1)
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-session", "-d", "-P", "-F", '#{window_id}', "-s", NAME, "-c", PATH,
       "-n", "nvim", "--", "/bin/sh", "-c", "exec nvim"],
      out: "@1\n"
    )
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=#{NAME}:", "-n", "claude", "-c", PATH],
      out: "@2\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@2"], out: "")

    code, env = run_tmux(open_argv)

    assert_equal 0, code
    assert_equal "session-per-issue", env["data"]["layout"]
    assert_equal NAME, env["data"]["session"]
    assert_equal "@1", env["data"]["editor_window_id"]
    assert_equal "@2", env["data"]["window_id"]
    assert_equal false, env["data"]["skipped"]

    # Order: has-session, new-session (editor), new-window (claude),
    # send-keys - and no third new-window. The caffeinate probe's own
    # `which` call is filtered out; it is not part of this sequence.
    kinds = @fake.calls.map { |c| c.argv[0, 2] }.reject { |k| k == %w[which caffeinate] }
    assert_equal(
      [%w[tmux has-session], %w[tmux new-session], %w[tmux new-window], %w[tmux send-keys]],
      kinds
    )
    new_window_calls = @fake.calls.select { |c| c.argv[0, 2] == %w[tmux new-window] }
    assert_equal 1, new_window_calls.length
  end

  def test_open_editor_window_is_named_from_the_editor_argv_basename
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 1)
    expect_no_caffeinate
    fixture = manifest_with(FIXTURE, "tmux" => { "editor" => ["/usr/local/bin/nvim", "-c", "Explore"] })
    @fake.expect(
      ["tmux", "new-session", "-d", "-P", "-F", '#{window_id}', "-s", NAME, "-c", PATH,
       "-n", "nvim", "--", "/bin/sh", "-c", "exec /usr/local/bin/nvim -c Explore"],
      out: "@1\n"
    )
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=#{NAME}:", "-n", "claude", "-c", PATH],
      out: "@2\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@2"], out: "")

    code, _env = run_tmux(open_argv, fixture: fixture)

    assert_equal 0, code
  end

  # tmux hands a one-element shell-command to the shell, which leaves the
  # editor as a non-foreground child and makes pane_current_command report
  # the shell - close --session then reads a live editor as a bare shell and
  # tears the session down (seen against real tmux 3.6b on 2026-08-21). The
  # sh -c exec wrapper keeps the editor as the pane's own process, and an
  # argv needing quoting must survive the join intact.
  def test_open_wraps_the_editor_argv_in_sh_c_exec_so_the_editor_owns_the_pane
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 1)
    expect_no_caffeinate
    fixture = manifest_with(FIXTURE, "tmux" => { "editor" => ["nvim", "-c", "e a b.txt"] })
    @fake.expect(
      ["tmux", "new-session", "-d", "-P", "-F", '#{window_id}', "-s", NAME, "-c", PATH,
       "-n", "nvim", "--", "/bin/sh", "-c", "exec nvim -c e\\ a\\ b.txt"],
      out: "@1\n"
    )
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=#{NAME}:", "-n", "claude", "-c", PATH],
      out: "@2\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@2"], out: "")

    code, _env = run_tmux(open_argv, fixture: fixture)

    assert_equal 0, code
  end

  # --- open: no editor configured ---------------------------------------

  def test_open_with_no_editor_issues_a_single_new_session_and_no_new_window
    fixture = manifest_with(FIXTURE, "tmux" => { "editor" => nil })
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 1)
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-session", "-d", "-P", "-F", '#{window_id}', "-s", NAME, "-c", PATH, "-n", "claude"],
      out: "@1\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@1"], out: "")

    code, env = run_tmux(open_argv, fixture: fixture)

    assert_equal 0, code
    assert_equal "@1", env["data"]["window_id"]
    assert_nil env["data"]["editor_window_id"]
    refute(@fake.calls.any? { |c| c.argv[0, 2] == %w[tmux new-window] })
  end

  # --- editor argv never joined into send-keys ---------------------------

  def test_editor_argv_is_the_window_command_never_joined_into_send_keys
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 1)
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-session", "-d", "-P", "-F", '#{window_id}', "-s", NAME, "-c", PATH,
       "-n", "nvim", "--", "/bin/sh", "-c", "exec nvim"],
      out: "@1\n"
    )
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=#{NAME}:", "-n", "claude", "-c", PATH],
      out: "@2\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@2"], out: "")

    run_tmux(open_argv)

    send_call = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }
    refute_includes send_call.argv[4], "nvim"
  end

  # --- existing session skip ---------------------------------------------

  def test_open_skips_when_the_session_already_exists
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 0)
    # No new-session, new-window, or send-keys expectation - a hit must not
    # create anything.

    code, env = run_tmux(open_argv)

    assert_equal 0, code
    assert_equal true, env["data"]["skipped"]
    assert_match(/#{Regexp.escape(NAME)} already exists/, env["data"]["reason"])
  end

  # --- empty captured window id -------------------------------------------

  def test_open_never_sends_keys_when_the_claude_window_id_is_empty_with_an_editor
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 1)
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-session", "-d", "-P", "-F", '#{window_id}', "-s", NAME, "-c", PATH,
       "-n", "nvim", "--", "/bin/sh", "-c", "exec nvim"],
      out: "@1\n"
    )
    @fake.expect(["tmux", "new-window"], out: "") # empty id despite success
    # No send-keys expectation - FakeSh raises if the code tries.

    code, env = run_tmux(open_argv)

    assert_equal 1, code
    assert_equal "window_id_empty", env["blocked"].first["code"]
  end

  def test_open_never_sends_keys_when_the_session_window_id_is_empty_with_no_editor
    fixture = manifest_with(FIXTURE, "tmux" => { "editor" => nil })
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 1)
    expect_no_caffeinate
    @fake.expect(["tmux", "new-session"], out: "") # empty id despite success
    # No send-keys expectation - FakeSh raises if the code tries.

    code, env = run_tmux(open_argv, fixture: fixture)

    assert_equal 1, code
    assert_equal "window_id_empty", env["blocked"].first["code"]
  end

  # --- byte-identical claude command --------------------------------------

  def test_seeded_claude_command_is_byte_identical_to_window_per_issue
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 1)
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-session", "-d", "-P", "-F", '#{window_id}', "-s", NAME, "-c", PATH,
       "-n", "nvim", "--", "/bin/sh", "-c", "exec nvim"],
      out: "@1\n"
    )
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=#{NAME}:", "-n", "claude", "-c", PATH],
      out: "@2\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@2"], out: "")

    run_tmux(open_argv)

    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    assert_includes keys, "claude --permission-mode auto --model fakemodel"
    assert_includes keys, SEED
    assert_includes keys, "/wurk:commit --auto"
    assert_includes keys, "unrelated to #{ID}"
  end

  # --- machine-level permission mode (wu-jhb) -----------------------------

  # No machine config present -> the pre-wu-jhb default, unchanged. Named
  # explicitly as the regression guard for absent-safety on this path, same
  # as the window-per-issue side.
  def test_open_with_no_machine_config_uses_the_default_permission_mode
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 1)
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-session", "-d", "-P", "-F", '#{window_id}', "-s", NAME, "-c", PATH,
       "-n", "nvim", "--", "/bin/sh", "-c", "exec nvim"],
      out: "@1\n"
    )
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=#{NAME}:", "-n", "claude", "-c", PATH],
      out: "@2\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@2"], out: "")

    code, env = run_tmux(open_argv)

    assert_equal 0, code
    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    assert_includes keys, "claude --permission-mode auto --model fakemodel"
  end

  %w[auto default acceptEdits plan].each do |mode|
    define_method("test_open_uses_permission_mode_#{mode}_from_machine_config") do
      @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 1)
      expect_no_caffeinate
      @fake.expect(
        ["tmux", "new-session", "-d", "-P", "-F", '#{window_id}', "-s", NAME, "-c", PATH,
         "-n", "nvim", "--", "/bin/sh", "-c", "exec nvim"],
        out: "@1\n"
      )
      @fake.expect(
        ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=#{NAME}:", "-n", "claude", "-c", PATH],
        out: "@2\n"
      )
      @fake.expect(["tmux", "send-keys", "-t", "@2"], out: "")

      code, env = run_tmux(open_argv, user_config: { "tmux" => { "permission_mode" => mode } })

      assert_equal 0, code
      keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
      assert_includes keys, "--permission-mode #{mode}"
    end
  end

  def test_open_command_uses_dangerously_skip_permissions_when_machine_config_selects_it
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 1)
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-session", "-d", "-P", "-F", '#{window_id}', "-s", NAME, "-c", PATH,
       "-n", "nvim", "--", "/bin/sh", "-c", "exec nvim"],
      out: "@1\n"
    )
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=#{NAME}:", "-n", "claude", "-c", PATH],
      out: "@2\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@2"], out: "")

    code, env = run_tmux(open_argv, user_config: { "tmux" => { "permission_mode" => "skip-permissions" } })

    assert_equal 0, code
    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    assert_includes keys, "claude --dangerously-skip-permissions --model fakemodel"
    refute_match(/--permission-mode/, keys)
  end

  # An invalid machine-config value blocks before any tmux command is
  # issued (not even has-session), so a bad config costs nothing.
  def test_open_blocks_on_an_invalid_machine_config_permission_mode_and_shells_out_nothing
    code, env = run_tmux(open_argv, user_config: { "tmux" => { "permission_mode" => "yolo" } })

    assert_equal 1, code
    blocked = env["blocked"].first
    assert_match(/tmux\.permission_mode/, blocked["message"])
    assert_empty @fake.calls
  end

  # A manifest that still sets the retired tmux.permission_mode key does not
  # change the composed command line - the machine config, or its default,
  # governs regardless.
  def test_open_ignores_a_manifest_that_still_sets_the_retired_permission_mode_key
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 1)
    expect_no_caffeinate
    @fake.expect(
      ["tmux", "new-session", "-d", "-P", "-F", '#{window_id}', "-s", NAME, "-c", PATH,
       "-n", "nvim", "--", "/bin/sh", "-c", "exec nvim"],
      out: "@1\n"
    )
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=#{NAME}:", "-n", "claude", "-c", PATH],
      out: "@2\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@2"], out: "")

    fixture = manifest_with(FIXTURE, "tmux" => { "permission_mode" => "skip-permissions" })
    code, env = run_tmux(open_argv, fixture: fixture, user_config: { "tmux" => { "permission_mode" => "plan" } })

    assert_equal 0, code
    keys = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }.argv[4]
    assert_includes keys, "--permission-mode plan"
    refute_match(/skip-permissions/, keys)
  end

  # --- dry run --------------------------------------------------------------

  def test_open_dry_run_renders_the_full_sequence_and_issues_no_mutating_commands
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 1)
    expect_no_caffeinate

    code, env = run_tmux(open_argv(["--dry-run"]))

    assert_equal 0, code
    session_line = env["commands"].find { |c| c.include?("new-session") }
    window_line = env["commands"].find { |c| c.include?("new-window") }
    send_line = env["commands"].find { |c| c.include?("send-keys") }

    refute_nil session_line
    refute_nil window_line
    refute_nil send_line
    assert_includes send_line, "$win"
    refute(@fake.calls.any? { |c| %w[new-session new-window send-keys].include?(c.argv[1]) })
  end

  def test_ensure_session_dry_run_is_still_a_no_op
    code, env = run_tmux(["ensure-session", "--dry-run"])

    assert_equal 0, code
    assert_equal true, env["data"]["skipped"]
    assert_empty @fake.calls
    assert_empty env["commands"]
  end

  # --- find: layout-aware, claude window only -----------------------------

  # The editor window shares the claude window's pane path (same worktree),
  # so name+path alone can't discriminate under this layout - the session
  # name plus CLAUDE_WINDOW_NAME must. find must return the claude window,
  # never the editor's, even though both windows list the same path.
  def test_find_returns_the_claude_window_not_the_editor_window_sharing_a_pane_path
    out = "@1 #{NAME} nvim #{PATH}\n@2 #{NAME} claude #{PATH}\n"
    @fake.expect(
      ["tmux", "list-panes", "-a", "-F", '#{window_id} #{session_name} #{window_name} #{pane_current_path}'],
      out: out
    )

    code, env = run_tmux(["find", NAME, PATH])

    assert_equal 0, code
    assert_equal true, env["data"]["found"]
    assert_equal "@2", env["data"]["window_id"]
  end

  def test_find_still_blocks_ambiguous_window_match_on_two_matching_claude_windows
    out = "@2 #{NAME} claude #{PATH}\n@3 #{NAME} claude #{PATH}\n"
    @fake.expect(
      ["tmux", "list-panes", "-a", "-F", '#{window_id} #{session_name} #{window_name} #{pane_current_path}'],
      out: out
    )

    code, env = run_tmux(["find", NAME, PATH])

    assert_equal 1, code
    assert_equal "ambiguous_window_match", env["blocked"].first["code"]
  end

  def test_find_reports_session_and_session_scoped_under_session_per_issue
    out = "@2 #{NAME} claude #{PATH}\n"
    @fake.expect(
      ["tmux", "list-panes", "-a", "-F", '#{window_id} #{session_name} #{window_name} #{pane_current_path}'],
      out: out
    )

    code, env = run_tmux(["find", NAME, PATH])

    assert_equal 0, code
    assert_equal true, env["data"]["session_scoped"]
    assert_equal NAME, env["data"]["session"]
  end

  # --- close --session: teardown inherits the all-bare-shell precondition -

  def test_close_session_kills_the_session_when_every_remaining_pane_is_a_bare_shell
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "fish\n")
    @fake.expect(["tmux", "kill-window", "-t", "@2"], out: "")
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 0)
    @fake.expect(["tmux", "list-panes", "-s", "-t", "=#{NAME}", "-F", '#{pane_current_command}'], out: "fish\n")
    @fake.expect(["tmux", "kill-session", "-t", "=#{NAME}"], out: "")

    code, env = run_tmux(["close", "--session", NAME, "@2"])

    assert_equal 0, code
    assert_equal true, env["data"]["closed"]
    assert_equal true, env["data"]["session_closed"]
  end

  def test_close_session_keeps_the_session_when_a_remaining_pane_is_an_editor
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "fish\n")
    @fake.expect(["tmux", "kill-window", "-t", "@2"], out: "")
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 0)
    @fake.expect(["tmux", "list-panes", "-s", "-t", "=#{NAME}", "-F", '#{pane_current_command}'], out: "nvim\n")
    # No kill-session expectation - a live editor pane must keep the session.

    code, env = run_tmux(["close", "--session", NAME, "@2"])

    assert_equal 0, code
    assert_equal true, env["data"]["closed"]
    assert_equal false, env["data"]["session_closed"]
    assert_match(/session kept, other windows busy/, env["data"]["reason"])
  end

  # The last window going with the window kill is not a failure to detect -
  # has-session simply comes back false, and no kill-session is issued
  # against a session that is already gone.
  def test_close_session_reports_session_ended_with_its_last_window_and_issues_no_kill_session
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "fish\n")
    @fake.expect(["tmux", "kill-window", "-t", "@2"], out: "")
    @fake.expect(["tmux", "has-session", "-t", "=#{NAME}"], exitstatus: 1)
    # No list-panes -s or kill-session expectation.

    code, env = run_tmux(["close", "--session", NAME, "@2"])

    assert_equal 0, code
    assert_equal true, env["data"]["session_closed"]
    assert_match(/session ended with its last window/, env["data"]["reason"])
  end

  # close --session must never issue any session command when the window
  # kill itself did not happen - a busy window keeps everything untouched.
  def test_close_session_never_issues_a_session_command_when_the_window_kill_did_not_happen
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "2.1.220\n")
    # No kill-window, has-session, list-panes -s, or kill-session expectation.

    code, env = run_tmux(["close", "--session", NAME, "@2"])

    assert_equal 0, code
    assert_equal false, env["data"]["closed"]
    refute env["data"].key?("session_closed")
  end

  def test_close_session_dry_run_renders_list_panes_and_conditional_kill_session_executing_nothing
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "fish\n")

    code, env = run_tmux(["close", "--session", NAME, "--dry-run", "@2"])

    assert_equal 0, code
    assert_equal false, env["data"]["closed"]
    assert_equal false, env["data"]["session_closed"]
    kill_window_line = env["commands"].find { |c| c.include?("kill-window") }
    list_panes_s_line = env["commands"].find { |c| c.include?("list-panes") && c.include?("-s") }
    kill_session_line = env["commands"].find { |c| c.include?("kill-session") }
    refute_nil kill_window_line
    refute_nil list_panes_s_line
    refute_nil kill_session_line
    refute(@fake.calls.any? { |c| %w[kill-window has-session kill-session].include?(c.argv[1]) })
  end
end

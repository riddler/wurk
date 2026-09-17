# frozen_string_literal: true

require "minitest/autorun"
require_relative "support/home_guard"
require "json"
require "tmpdir"

# The two opt-in hooks under hooks/: each is run as a real process with a
# fixture on stdin, the way Claude Code runs it, and judged by stdout and
# exit status alone. Nothing here reads or writes a settings file. The
# hook scripts carry their own --self-test; this file checks the same
# contract from Ruby so the kit gate covers it, and adds the sabotage-
# shaped assertions a shell self-test would not bother with.
class HooksTest < Minitest::Test
  HOOKS_DIR = File.expand_path("../../../../hooks", __dir__)
  POLICY = File.join(HOOKS_DIR, "main-session-policy.sh")
  GUARD = File.join(HOOKS_DIR, "safe-wait-guard.sh")

  # A hook's environment never inherits the two variables the policy hook
  # reads, so a test asserting "prints the policy" is not fooled by the
  # process this suite runs in being a subagent.
  CLEAN_ENV = { "CLAUDE_AGENT_ID" => nil, "WURK_MAIN_SESSION_POLICY" => nil }.freeze

  def run_hook(path, stdin:, env: {}, args: [])
    out = IO.popen([CLEAN_ENV.merge(env), path, *args], "r+", err: [:child, :out]) do |io|
      io.write(stdin) if stdin
      io.close_write
      io.read
    end
    [out, $?]
  end

  def bash_input(command)
    JSON.generate("session_id" => "s1", "hook_event_name" => "PreToolUse",
                  "tool_name" => "Bash", "tool_input" => { "command" => command })
  end

  def deny_reason(out)
    body = JSON.parse(out)
    spec = body.fetch("hookSpecificOutput")
    assert_equal "PreToolUse", spec["hookEventName"]
    assert_equal "deny", spec["permissionDecision"]
    reason = spec.fetch("permissionDecisionReason")
    assert_includes reason, "Fix:", "a denial must name the fix"
    reason
  end

  TOP_LEVEL = '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup","cwd":"/tmp/x"}'
  IN_SUBAGENT = '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup","agent_id":"a1","agent_type":"worker"}'
  SUBAGENT_START = '{"session_id":"s1","hook_event_name":"SubagentStart","agent_type":"worker"}'

  # --- both hooks ------------------------------------------------------------

  def test_hooks_are_executable_and_parse_under_sh_dash_n
    [POLICY, GUARD].each do |hook|
      assert File.executable?(hook), "#{hook} must be chmod +x"
      out = IO.popen(["/bin/sh", "-n", hook], err: [:child, :out], &:read)
      assert $?.success?, "sh -n reported a syntax error in #{hook}: #{out}"
    end
  end

  def test_both_self_tests_pass
    [POLICY, GUARD].each do |hook|
      out, status = run_hook(hook, stdin: "", args: ["--self-test"])
      assert status.success?, "#{File.basename(hook)} --self-test failed:\n#{out}"
      refute_match(/^FAIL/, out)
      assert_match(/^PASS/, out)
    end
  end

  # --- main-session-policy ---------------------------------------------------

  def test_policy_prints_for_a_top_level_session
    out, status = run_hook(POLICY, stdin: TOP_LEVEL)
    assert status.success?
    assert_includes out, "coordinates"
    assert_includes out, "does not code"
    assert_includes out, "subagent"
  end

  # sabotage: drop the agent_id grep from suppressed() -> red
  def test_policy_is_silent_inside_a_subagent
    out, status = run_hook(POLICY, stdin: IN_SUBAGENT)
    assert status.success?
    assert_equal "", out
  end

  # sabotage: drop the CLAUDE_AGENT_ID check -> red
  def test_policy_is_silent_when_claude_agent_id_is_set
    out, status = run_hook(POLICY, stdin: TOP_LEVEL, env: { "CLAUDE_AGENT_ID" => "agent-1" })
    assert status.success?
    assert_equal "", out
  end

  def test_policy_is_silent_on_subagent_start
    out, status = run_hook(POLICY, stdin: SUBAGENT_START)
    assert status.success?
    assert_equal "", out
  end

  def test_policy_honors_the_operator_escape_hatch
    %w[off 0].each do |value|
      out, status = run_hook(POLICY, stdin: TOP_LEVEL, env: { "WURK_MAIN_SESSION_POLICY" => value })
      assert status.success?
      assert_equal "", out, "WURK_MAIN_SESSION_POLICY=#{value} should suppress"
    end
  end

  # Fail-open: with nothing to say it is a subagent, it is the top level.
  def test_policy_treats_empty_stdin_as_top_level
    out, status = run_hook(POLICY, stdin: "")
    assert status.success?
    assert_includes out, "coordinates"
  end

  def test_policy_never_fails_on_garbage_stdin
    out, status = run_hook(POLICY, stdin: "\x00 not json {{{ \"agent_id\": \"a1\"")
    assert status.success?
    assert_equal "", out, "a stray agent_id key still counts as a subagent signal"

    out, status = run_hook(POLICY, stdin: "not json at all")
    assert status.success?
    assert_includes out, "coordinates"
  end

  # The bead's hard rule: the injected text is generic. It names no ticket
  # prefix, no user path, no dotfile, and uses plain ASCII punctuation.
  def test_policy_text_is_generic_and_ascii
    out, = run_hook(POLICY, stdin: TOP_LEVEL)
    assert_match(/\A[[:ascii:]]*\z/, out, "policy text must be plain ASCII")
    ["wu-", "/Users/", ".claude"].each do |forbidden|
      refute_includes out, forbidden, "policy text must not mention #{forbidden.inspect}"
    end
    assert out.length < 10_000, "hook output is capped at 10,000 characters"
  end

  # --- safe-wait-guard -------------------------------------------------------

  ALLOWED = [
    "until grep -qE 'GREEN|RED' log; do sleep 15; done",
    "while read -r line; do echo \"$line\"; done < file",
    "while IFS= read -r line; do echo \"$line\"; done < file",
    "for i in 1 2 3; do echo $i; done",
    "ruby skills/wurk:kit/scripts/test/run.rb",
    "git log --oneline | while read l; do echo $l; done",
    "echo \"meanwhile\" && echo done",
    "for f in a b; do touch $f; done && ls",
    "trap 'kill $!' EXIT; (while true; do sleep 1; done) &",
    "while pgrep -f gate.rb | grep -vx $$ >/dev/null; do sleep 5; done",
    "i=0; until test -f x; do\n  sleep 2\n  i=$((i+1))\n  test $i -lt 20 || break\ndone",
    "cd /repo && ruby run.rb 2>&1 | tail -5"
  ].freeze

  DENIED = {
    "while true; do date; done" => "sleep",
    "while ! test -f done.txt; do :; done" => "sleep",
    "until grep -q GREEN log; do :; done" => "sleep",
    "(while true; do sleep 1; done) &" => "trap",
    "while pgrep -f gate.rb >/dev/null; do sleep 5; done" => "$$"
  }.freeze

  def test_guard_allows_bounded_and_non_waiting_commands
    ALLOWED.each do |command|
      out, status = run_hook(GUARD, stdin: bash_input(command))
      assert status.success?, "guard must exit 0 for #{command.inspect}"
      assert_equal "", out, "guard must stay silent for #{command.inspect}"
    end
  end

  # sabotage: make any one rule's reason omit its fix word -> red; make R1
  # ignore the sleep check -> the bounded-until fixture above goes red.
  def test_guard_denies_each_bad_wait_shape_and_names_the_fix
    DENIED.each do |command, fix_word|
      out, status = run_hook(GUARD, stdin: bash_input(command))
      assert status.success?, "guard exits 0 even when denying (#{command.inspect})"
      reason = deny_reason(out)
      assert_includes reason, fix_word, "reason for #{command.inspect} must mention #{fix_word.inspect}"
    end
  end

  def test_guard_emits_exactly_one_decision
    out, = run_hook(GUARD, stdin: bash_input("while pgrep -f x; do :; done &"))
    assert_equal 1, out.lines.count
    assert_includes deny_reason(out), "sleep", "the first rule hit (R1) wins"
  end

  def test_guard_ignores_other_tools
    input = JSON.generate("tool_name" => "Read", "tool_input" => { "file_path" => "while true; do :; done" })
    out, status = run_hook(GUARD, stdin: input)
    assert status.success?
    assert_equal "", out
  end

  def test_guard_fails_open_on_garbage_and_missing_input
    ["not json {{{", "", "{\"tool_name\":\"Bash\"}", "{\"tool_name\":\"Bash\",\"tool_input\":{}}"].each do |stdin|
      out, status = run_hook(GUARD, stdin: stdin)
      assert status.success?, "guard must exit 0 on #{stdin.inspect}"
      assert_equal "", out, "guard must stay silent on #{stdin.inspect}"
    end
  end

  def test_guard_reasons_are_ascii_and_short
    DENIED.each_key do |command|
      out, = run_hook(GUARD, stdin: bash_input(command))
      assert_match(/\A[[:ascii:]]*\z/, out)
      assert out.length < 10_000
    end
  end

  # --- the deny-message contract, over every hook ----------------------------

  # A refusal names what to change, so the next attempt can pass. In a hook
  # that means every deny reason carries a greppable "Fix:" clause. The two
  # tests below hold that over hooks/*.sh as a whole rather than over one
  # named hook, the way test_guard_denies_each_bad_wait_shape_and_names_the_fix
  # does, so a hook added later cannot ship a bare deny and stay green.
  #
  # The only way out is this list, and every entry states why the hook has no
  # deny path at all. A hook that is neither listed here nor emitting a deny
  # fails: a new hook is a guard by default.
  HOOKS_WITHOUT_A_DENY_PATH = {
    "main-session-policy.sh" =>
      "SessionStart hook: it either injects context or stays silent, and it " \
      "fails open. It has no deny path, no failure message, and nothing it " \
      "could name a fix for - every exit is 0 with no decision."
  }.freeze

  # The PreToolUse deny decision, however the hook spells the JSON.
  DENY_EMITTER = /permissionDecision"?\s*:\s*"?deny/

  # The convention a deny reason is written under: a shell variable whose name
  # carries REASON, assigned a single- or double-quoted string (a double-quoted
  # one may span lines). A hook that builds its reason some other way finds no
  # reasons here and fails - that is the deny-by-default end of the contract, a
  # prompt to follow the convention or to justify an exemption, not a green
  # pass.
  REASON_ASSIGNMENT =
    /^[ \t]*([A-Za-z_][A-Za-z0-9_]*REASON[A-Za-z0-9_]*)=(?:"((?:[^"\\]|\\.)*)"|'([^']*)'|([^\n]*))/

  def hook_scripts
    scripts = Dir[File.join(HOOKS_DIR, "*.sh")].sort
    refute_empty scripts, "no hooks found under #{HOOKS_DIR}"
    scripts
  end

  def deny_reasons(body)
    body.scan(REASON_ASSIGNMENT).map { |name, dquoted, squoted, bare| [name, dquoted || squoted || bare] }
  end

  # sabotage: drop the main-session-policy.sh entry -> red (it denies nothing
  # and would then be required to); add a hook that denies with a bare reason
  # -> red in the test below.
  def test_every_hook_either_denies_or_is_exempt_with_a_reason
    names = hook_scripts.map { |path| File.basename(path) }
    stale = HOOKS_WITHOUT_A_DENY_PATH.keys - names
    assert_empty stale, "HOOKS_WITHOUT_A_DENY_PATH names hooks that no longer exist: #{stale.join(', ')}"

    hook_scripts.each do |path|
      name = File.basename(path)
      denies = File.read(path).match?(DENY_EMITTER)
      exemption = HOOKS_WITHOUT_A_DENY_PATH[name]
      if exemption
        refute denies, "#{name} is listed as having no deny path but emits one - drop it from the exempt list"
        assert_operator exemption.length, :>=, 40,
                        "the HOOKS_WITHOUT_A_DENY_PATH entry for #{name} must say WHY it has no deny path"
      else
        assert denies,
               "#{name} emits no deny decision and is not in HOOKS_WITHOUT_A_DENY_PATH - " \
               "add the deny, or list it there with the reason it has none"
      end
    end
  end

  # sabotage: drop "Fix:" from any one of safe-wait-guard.sh's R1_REASON,
  # R2_REASON, R3_REASON -> red, naming that variable.
  def test_every_hook_deny_reason_names_the_fix
    hook_scripts.each do |path|
      name = File.basename(path)
      body = File.read(path)
      # A hook with no deny decision is the other test's business, exempt or
      # not; saying "denies, but ..." about it would name the wrong defect.
      next unless body.match?(DENY_EMITTER)

      reasons = deny_reasons(body)
      refute_empty reasons,
                   "#{name} denies, but no *_REASON= assignment carries its reason text - " \
                   "the contract test cannot read a reason built any other way"
      reasons.each do |variable, text|
        assert_includes text, "Fix:",
                        "#{name}: #{variable} is a deny reason, so it must name the fix (a 'Fix: ...' clause)"
      end
    end
  end
end

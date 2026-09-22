# frozen_string_literal: true

require "minitest/autorun"
require_relative "support/home_guard"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../session_metrics"

# The opt-in hooks under hooks/: each is run as a real process with a
# fixture on stdin, the way Claude Code runs it, and judged by stdout, the
# file it wrote, and exit status alone. Nothing here reads or writes a
# settings file. The
# hook scripts carry their own --self-test; this file checks the same
# contract from Ruby so the kit gate covers it, and adds the sabotage-
# shaped assertions a shell self-test would not bother with.
class HooksTest < Minitest::Test
  HOOKS_DIR = File.expand_path("../../../../hooks", __dir__)
  POLICY = File.join(HOOKS_DIR, "main-session-policy.sh")
  GUARD = File.join(HOOKS_DIR, "safe-wait-guard.sh")
  HARNESS = File.join(HOOKS_DIR, "harness-event.sh")

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
    hook_scripts.each do |hook|
      assert File.executable?(hook), "#{hook} must be chmod +x"
      out = IO.popen(["/bin/sh", "-n", hook], err: [:child, :out], &:read)
      assert $?.success?, "sh -n reported a syntax error in #{hook}: #{out}"
    end
  end

  def test_every_hook_self_test_passes
    hook_scripts.each do |hook|
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
    "cd /repo && ruby run.rb 2>&1 | tail -5",
    "until test -f x\ndo\n  sleep 2\ndone"
  ].freeze

  # wu-jarf. A Bash call carries data as well as shell - a heredoc body, a
  # -m message - and the guard must not read that data as shell. R1 used to
  # fold the command's newlines away before matching, so any "while" and any
  # later "do" in a document matched the loop header. A conductor writing a
  # campaign journal was refused for prose and worked around the guard a
  # dozen times that night rather than reporting it.
  PROSE = [
    "cat >> journal.md <<'EOF'\nWorkers hold their notes while they are being written.\n\n" \
    "The conductor should not assume the sweep is finished, nor\ndo anything about it yet.\nEOF",
    "cat <<-EOF > f\n\twait a while for it\n\tand then do the rest\n\tEOF",
    "echo 'we waited a while' && echo 'and do it again'",
    "cat <<EOF > f\nWe waited a while for the gate.\n\nNothing to do now.\n\nThe work is done.\nEOF",
    "git commit -m 'Stops polling while the gate runs\n\nWe do not need a second reader.'"
  ].freeze

  DENIED = {
    "while true; do date; done" => "sleep",
    "while ! test -f done.txt; do :; done" => "sleep",
    "until grep -q GREEN log; do :; done" => "sleep",
    "(while true; do sleep 1; done) &" => "trap",
    "while pgrep -f gate.rb >/dev/null; do sleep 5; done" => "$$",
    # The long form, whose header spans the one newline shell allows there.
    # This is what the folding wu-jarf removed was there to catch, so it is
    # the half of that fix that can silently rot; keep it beside the prose
    # cases rather than trusting the shell self-test alone.
    "while true\ndo\n  date\ndone" => "sleep",
    "until test -f x\ndo\n  :\ndone" => "sleep",
    "bash <<'EOF'\nwhile true\ndo\n  date\ndone\nEOF" => "sleep",
    "(\n  while true; do sleep 1; done\n) &" => "trap",
    "while pgrep -f gate.rb >/dev/null\ndo\n  sleep 5\ndone" => "$$"
  }.freeze

  def test_guard_allows_bounded_and_non_waiting_commands
    ALLOWED.each do |command|
      out, status = run_hook(GUARD, stdin: bash_input(command))
      assert status.success?, "guard must exit 0 for #{command.inspect}"
      assert_equal "", out, "guard must stay silent for #{command.inspect}"
    end
  end

  # sabotage: fold the command's newlines in extract_command the way it used
  # to (\n -> space) -> every one of these goes red, because a folded
  # document is one line in which "while" and a later "do" match the loop
  # header. Drop only the has_done requirement -> the one-line prose case
  # goes red. wu-jarf.
  def test_guard_allows_prose_that_merely_contains_the_loop_keywords
    PROSE.each do |command|
      out, status = run_hook(GUARD, stdin: bash_input(command))
      assert status.success?, "guard must exit 0 for #{command.inspect}"
      assert_equal "", out,
                   "prose is not shell: guard must stay silent for #{command.inspect}"
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

  # --- harness-event ---------------------------------------------------------

  def post_tool_input(tool, response)
    JSON.generate("session_id" => "s1", "hook_event_name" => "PostToolUse",
                  "tool_name" => tool, "tool_input" => { "command" => "ls" },
                  "tool_response" => response)
  end

  # Runs the hook with a sink of its own and returns [stdout, status, lines].
  def record(stdin, sink, env: {})
    out, status = run_hook(HARNESS, stdin: stdin, env: { "WURK_HARNESS_EVENTS" => sink }.merge(env))
    lines = File.exist?(sink) ? File.readlines(sink).reject { |l| l.strip.empty? } : []
    [out, status, lines]
  end

  def with_sink
    Dir.mktmpdir { |dir| yield File.join(dir, "error-events.jsonl") }
  end

  # sabotage: drop the "ok" key from the success line -> red. The bead's three
  # fields are ts, tool and ok; a line without ok cannot answer "what share of
  # calls failed", which is the only reason to record successes at all.
  def test_harness_records_a_successful_call
    with_sink do |sink|
      out, status, lines = record(post_tool_input("Bash", "stdout" => "a"), sink)
      assert status.success?
      assert_equal "", out, "a PostToolUse hook's stdout can reach the model; this one says nothing"
      assert_equal 1, lines.length
      event = JSON.parse(lines.first)
      assert_equal "Bash", event["tool"]
      assert_equal true, event["ok"]
      assert_equal "info", event["level"]
      assert_equal false, event["is_error"]
      assert_equal event["timestamp"], event["ts"], "ts and timestamp are the same instant"
      assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, event["timestamp"])
    end
  end

  # sabotage: match the error flags over the whole input rather than the
  # tool_response part -> the decoy test below goes red.
  def test_harness_records_both_error_shapes
    [{ "is_error" => true }, { "success" => false }].each do |response|
      with_sink do |sink|
        _out, status, lines = record(post_tool_input("Read", response), sink)
        assert status.success?
        event = JSON.parse(lines.first)
        assert_equal false, event["ok"], "#{response.inspect} is a failed call"
        assert_equal "error", event["level"]
        assert_equal true, event["is_error"]
      end
    end
  end

  def test_harness_does_not_score_error_text_in_the_tool_input_as_an_error
    with_sink do |sink|
      input = JSON.generate("hook_event_name" => "PostToolUse", "tool_name" => "Bash",
                            "tool_input" => { "command" => "grep '\"is_error\": true' log" },
                            "tool_response" => { "stdout" => "ok" })
      _out, _status, lines = record(input, sink)
      assert_equal "info", JSON.parse(lines.first)["level"]
    end
  end

  def test_harness_appends_one_line_per_call
    with_sink do |sink|
      record(post_tool_input("Bash", "stdout" => "a"), sink)
      record(post_tool_input("Read", "is_error" => true), sink)
      _out, _status, lines = record(post_tool_input("Edit", "stdout" => "b"), sink)
      assert_equal 3, lines.length
      assert_equal %w[Bash Read Edit], lines.map { |l| JSON.parse(l)["tool"] }
    end
  end

  # It is a machine-wide recorder: a subagent's tool calls are exactly the ones
  # a later transcript parse is worst at seeing, so unlike the policy hook this
  # one must NOT suppress itself inside a subagent.
  def test_harness_records_inside_a_subagent_too
    with_sink do |sink|
      input = JSON.generate("hook_event_name" => "PostToolUse", "tool_name" => "Bash",
                            "agent_id" => "a1", "agent_type" => "worker",
                            "tool_response" => { "is_error" => true })
      _out, _status, lines = record(input, sink, env: { "CLAUDE_AGENT_ID" => "a1" })
      assert_equal 1, lines.length
    end
  end

  def test_harness_honors_the_operator_escape_hatch
    %w[off 0].each do |value|
      with_sink do |sink|
        _out, status, lines = record(post_tool_input("Bash", "stdout" => "a"), "#{sink}-unused",
                                     env: { "WURK_HARNESS_EVENTS" => value })
        assert status.success?
        assert_empty lines
        refute File.exist?(sink), "WURK_HARNESS_EVENTS=#{value} must write nothing"
      end
    end
  end

  def test_harness_creates_a_missing_sink_directory
    Dir.mktmpdir do |dir|
      sink = File.join(dir, "deep", "er", "error-events.jsonl")
      _out, status, lines = record(post_tool_input("Bash", "stdout" => "a"), sink)
      assert status.success?
      assert_equal 1, lines.length
    end
  end

  def test_harness_fails_open_on_garbage_and_missing_input
    ["not json {{{", "", "{}"].each do |stdin|
      with_sink do |sink|
        out, status, = record(stdin, sink)
        assert status.success?, "the hook must exit 0 on #{stdin.inspect}"
        assert_equal "", out
      end
    end
  end

  def test_harness_records_an_unnamed_tool_rather_than_dropping_the_call
    with_sink do |sink|
      input = JSON.generate("hook_event_name" => "PostToolUse", "tool_response" => { "is_error" => true })
      _out, _status, lines = record(input, sink)
      assert_equal "unknown", JSON.parse(lines.first)["tool"]
      assert_equal "error", JSON.parse(lines.first)["level"]
    end
  end

  def test_harness_is_silent_when_the_sink_cannot_be_written
    Dir.mktmpdir do |dir|
      sink = File.join(dir, "error-events.jsonl")
      File.write(sink, "")
      File.chmod(0o400, sink)
      out, status, = record(post_tool_input("Bash", "stdout" => "a"), sink)
      assert status.success?, "an unwritable sink is not worth failing a tool call over"
      assert_equal "", out
    ensure
      File.chmod(0o600, sink) if sink && File.exist?(sink)
    end
  end

  # The sink resolution order, which no other test reaches: the env override
  # wins, then metrics.error_events out of the machine config, then a default
  # under the user's state dir. Each case runs the hook with a HOME of its
  # own, so nothing here can touch the real machine's config or sink.
  #
  # sabotage: drop the config_sink branch from sink_path -> the middle case
  # goes red (the event lands in the default path instead).
  def test_harness_reads_the_sink_from_the_machine_config
    Dir.mktmpdir do |home|
      configured = File.join(home, "configured.jsonl")
      FileUtils.mkdir_p(File.join(home, ".claude"))
      File.write(File.join(home, ".claude", "wurk.local.json"),
                 JSON.pretty_generate("metrics" => { "error_events" => configured }))
      _out, status = run_hook(HARNESS, stdin: post_tool_input("Bash", "is_error" => true),
                                       env: { "HOME" => home, "WURK_HARNESS_EVENTS" => nil })
      assert status.success?
      assert File.exist?(configured), "the hook must honor metrics.error_events"
      assert_equal "error", JSON.parse(File.readlines(configured).first)["level"]
    end
  end

  # sabotage: default the sink to a path inside the repo or the kit -> red.
  # The sink is machine state; a checkout must never accumulate it.
  def test_harness_defaults_to_the_users_state_dir
    Dir.mktmpdir do |home|
      _out, status = run_hook(HARNESS, stdin: post_tool_input("Bash", "stdout" => "a"),
                                       env: { "HOME" => home, "WURK_HARNESS_EVENTS" => nil,
                                              "XDG_STATE_HOME" => nil })
      assert status.success?
      default = File.join(home, ".local", "state", "wurk", "error-events.jsonl")
      assert File.exist?(default), "expected the default sink at #{default}"
    end
  end

  def test_harness_prefers_the_env_override_to_the_machine_config
    Dir.mktmpdir do |home|
      configured = File.join(home, "configured.jsonl")
      override = File.join(home, "override.jsonl")
      FileUtils.mkdir_p(File.join(home, ".claude"))
      File.write(File.join(home, ".claude", "wurk.local.json"),
                 JSON.generate("metrics" => { "error_events" => configured }))
      run_hook(HARNESS, stdin: post_tool_input("Bash", "stdout" => "a"),
                        env: { "HOME" => home, "WURK_HARNESS_EVENTS" => override })
      assert File.exist?(override)
      refute File.exist?(configured), "the env override must win outright"
    end
  end

  # The end-to-end agreement the two halves were written against: the hook is
  # the writer of the sink session_metrics.rb reads, so what it appends must
  # count as an error event there without either side being adjusted.
  #
  # sabotage: rename the hook's "timestamp" key to "ts" alone -> the since
  # filter below goes red; drop "level"/"is_error" -> the count goes to 0.
  def test_session_metrics_counts_what_the_hook_writes
    with_sink do |sink|
      record(post_tool_input("Bash", "stdout" => "a"), sink)
      record(post_tool_input("Read", "is_error" => true), sink)
      record(post_tool_input("Edit", "success" => false), sink)

      events = SessionMetrics.error_events(sink)
      assert events["exists"]
      assert_equal 2, events["count"], "the two failed calls, not the successful one"
      assert_equal 0, events["malformed_lines"], "every line the hook writes must parse"

      signals = SessionMetrics.signals([], events)
      signal = signals.find { |s| s["kind"] == "error_events" }
      refute_nil signal, "a written error event must surface as a signal"
      assert_equal 2, signal["count"]
      assert_equal sink, signal["path"]

      future = Time.now.utc + 3600
      assert_equal 0, SessionMetrics.error_events(sink, since: future)["count"],
                   "the hook's timestamp must be the key the since filter reads"
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
    "harness-event.sh" =>
      "PostToolUse hook: it runs after the tool has already run, so it has " \
      "nothing left to deny. It only appends a telemetry line and exits 0; " \
      "every failure path drops the line silently rather than reporting one.",
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

#!/bin/sh
# hooks/harness-event.sh - PostToolUse hook that appends one JSON line per
# tool call to this machine's telemetry sink, so a reader can count what a
# later transcript parse misses.
#
# session_metrics.rb parses transcripts after the fact, per project, per
# session file. This hook records tool calls as they happen, in every
# session on the machine regardless of cwd, into one absolute path - so the
# events aggregate across sessions instead of scattering with the cwd.
#
# It never suppresses itself. The SessionStart policy hook beside it goes
# quiet inside a subagent because its output is context a subagent should
# not get; this one writes a file nobody reads at runtime, and a subagent's
# tool calls are exactly the ones a transcript parse is worst at seeing.
#
# Installed by `ruby install.rb --with hooks` (opt-in; the default install
# never touches hooks) as ~/.claude/hooks/wurk-harness-event.sh and wired by
# hand into settings.json under PostToolUse with matcher "" (every tool) -
# the installer prints the snippet and never edits settings itself.
#
# jq is NOT required. The two fields this hook needs - the tool name, and
# whether the call errored - are pulled with the same grep/sed stdin parsing
# main-session-policy.sh and safe-wait-guard.sh already use, so the hook has
# no dependency a machine might be missing and no "jq is absent, do nothing"
# path to get wrong. The cost is that the parse is best-effort pattern
# matching rather than a JSON reader; every mis-parse degrades to a line
# with tool "unknown" or to no line at all, never to a failure.
#
# Harness contract (Claude Code hooks reference, checked 2026-09-17):
#
#   - PostToolUse receives JSON on stdin: the common fields plus
#     `tool_name`, `tool_input`, and `tool_response` (the result the tool
#     returned). It runs after the tool has already run, so nothing this
#     hook does can block or alter the call.
#   - Hooks in settings files also run inside subagents. This one is meant
#     to; see above.
#   - stdout from a PostToolUse hook can be shown to the model, so this
#     hook prints NOTHING on the success path: its output is the sink file.
#
# The error signal: a tool result carries `is_error: true`, and some tools
# report `success: false` instead. Both are looked for in the `tool_response`
# part of the input only, not the whole document - a Bash command or a Write
# payload can contain either string as ordinary text, and matching over the
# whole input would score those as errors.
#
# Sink path, in order:
#
#   1. $WURK_HARNESS_EVENTS - an explicit absolute path (the override an
#      operator or a test sets).
#   2. `metrics.error_events` in ~/.claude/wurk.local.json, the machine
#      config seam (docs/machine-config.md). A hook cannot afford to load
#      Ruby per tool call, so the key is read with the same sh-level
#      parsing as everything else here: best-effort, and a config this
#      parse cannot read falls through to the default rather than failing.
#   3. ${XDG_STATE_HOME:-$HOME/.local/state}/wurk/error-events.jsonl
#
# Never a repo path and never a path under the kit: the sink is machine
# state, it outlives any checkout, and a checkout must not accumulate it.
#
# Line shape - one JSON object, one line, appended:
#
#   {"timestamp":"...","ts":"...","tool":"Bash","ok":false,
#    "level":"error","is_error":true}
#
# `timestamp` and `level`/`is_error` are the keys session_metrics.rb reads
# (its error_events counts a line when is_error is true or level is
# "error", and filters on timestamp); `ts`, `tool` and `ok` are this hook's
# own fields, carried alongside for a reader that wants the whole stream
# rather than the error count. `ts` and `timestamp` are the same instant.
#
# Every call is recorded, not only the failures, so `ok` means something and
# a rate can be computed. That grows the file; an operator who does not want
# it turns the hook off with WURK_HARNESS_EVENTS=off (or 0), or points the
# sink somewhere rotated.
#
# Fail-open: this hook never exits non-zero and never prints a diagnostic.
# An unreadable input, an unwritable sink, a missing directory - each ends
# in a silent exit 0, because a telemetry line is worth less than a tool
# call.
#
# Portability: POSIX sh, coreutils, grep and sed (grep -E / sed -E, which
# BSD and GNU both accept). No other dependencies.
#
#   hooks/harness-event.sh --self-test   # hermetic PASS/FAIL cases

set +e

DEFAULT_SINK_REL="wurk/error-events.jsonl"

# NULs are stripped here: bash's command substitution warns on a stray NUL
# byte (dash drops it silently), so stripping at the source keeps both
# shells silent.
read_input() {
  if [ -t 0 ]; then
    printf ''
  else
    cat 2>/dev/null | tr -d '\000' || true
  fi
}

# The FIRST "tool_name" string in the document, restricted to the characters
# a tool name is made of. grep -o reports matches left to right, so head -1
# takes the real field even when a tool_input payload quotes the key later.
extract_tool() {
  printf '%s' "$1" | tr -d '\n\r' \
    | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[A-Za-z0-9_.:-]+"' 2>/dev/null \
    | head -1 \
    | sed -E 's/.*"([A-Za-z0-9_.:-]+)"$/\1/'
}

# Everything from the "tool_response" key onward, which is where an error
# flag counts. Prints nothing when the key is absent.
tool_response_part() {
  printf '%s' "$1" | tr -d '\n\r' \
    | sed -E -n 's/.*("tool_response"[[:space:]]*:.*)/\1/p'
}

# 0 when the response says the call errored.
response_errored() {
  part=$(tool_response_part "$1")
  [ -n "$part" ] || return 1
  printf '%s' "$part" | grep -qE '"is_error"[[:space:]]*:[[:space:]]*true' 2>/dev/null && return 0
  printf '%s' "$part" | grep -qE '"success"[[:space:]]*:[[:space:]]*false' 2>/dev/null && return 0
  return 1
}

# metrics.error_events out of the machine config, best effort.
config_sink() {
  config="${HOME:-}/.claude/wurk.local.json"
  [ -f "$config" ] || return 0
  tr -d '\n\r' <"$config" 2>/dev/null \
    | grep -oE '"error_events"[[:space:]]*:[[:space:]]*"[^"]+"' 2>/dev/null \
    | head -1 \
    | sed -E 's/.*"([^"]+)"$/\1/'
}

sink_path() {
  if [ -n "${WURK_HARNESS_EVENTS:-}" ]; then
    printf '%s' "$WURK_HARNESS_EVENTS"
    return 0
  fi
  from_config=$(config_sink)
  if [ -n "$from_config" ]; then
    printf '%s' "$from_config"
    return 0
  fi
  state="${XDG_STATE_HOME:-${HOME:-}/.local/state}"
  printf '%s/%s' "$state" "$DEFAULT_SINK_REL"
}

# Escapes the characters that cannot sit raw inside a JSON string. The tool
# name is already restricted to a safe charset; this guards the path where
# it came back empty and something else was substituted.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

event_line() {
  tool=$(json_escape "$1")
  errored="$2"
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || stamp=""
  if [ "$errored" = "yes" ]; then
    printf '{"timestamp":"%s","ts":"%s","tool":"%s","ok":false,"level":"error","is_error":true}\n' \
      "$stamp" "$stamp" "$tool"
  else
    printf '{"timestamp":"%s","ts":"%s","tool":"%s","ok":true,"level":"info","is_error":false}\n' \
      "$stamp" "$stamp" "$tool"
  fi
}

append_event() {
  sink="$1"
  line="$2"
  [ -n "$sink" ] || return 0
  dir=$(dirname "$sink" 2>/dev/null) || return 0
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  # The group's stderr is redirected before the append is attempted, so an
  # unwritable sink costs nothing: the shell's own "Permission denied" for a
  # failed redirection is printed by the shell, not by printf, and 2>/dev/null
  # on printf alone would not catch it. A PostToolUse hook's stderr can reach
  # the session, and a telemetry failure has nothing to say to it.
  { printf '%s\n' "$line" >>"$sink"; } 2>/dev/null || return 0
  return 0
}

suppressed() {
  case "${WURK_HARNESS_EVENTS:-}" in
    off|OFF|0) return 0 ;;
  esac
  return 1
}

run_hook() {
  suppressed && exit 0
  input=$(read_input) || input=""
  [ -n "$input" ] || exit 0

  tool=$(extract_tool "$input")
  [ -n "$tool" ] || tool="unknown"

  if response_errored "$input"; then
    errored="yes"
  else
    errored="no"
  fi

  append_event "$(sink_path)" "$(event_line "$tool" "$errored")"
  exit 0
}

# --- self-test ------------------------------------------------------------
# Each case re-execs this script with a fixture on stdin and a sink of its
# own under a temp dir, then reads the line that landed. Hermetic: no
# harness, no settings file, no machine config, nothing written outside the
# temp dir.

self_test() {
  failures=0
  self="$0"

  tmp=$(mktemp -d 2>/dev/null) || { echo "self-test: mktemp failed"; exit 1; }
  trap 'rm -rf "$tmp"' EXIT

  pass() { echo "PASS $1"; }
  fail() { echo "FAIL $1 ($2)"; failures=$((failures + 1)); }

  check() {
    name="$1"; pattern="$2"; body="$3"
    if printf '%s' "$body" | grep -qF -- "$pattern"; then
      pass "$name"
    else
      fail "$name" "expected ${pattern}, got: ${body:-nothing}"
    fi
  }

  # Runs the hook with a fresh sink and prints what landed in it.
  run() {
    sink="$tmp/sink-$2.jsonl"
    rm -f "$sink"
    printf '%s' "$1" | WURK_HARNESS_EVENTS="$sink" "$self"
    cat "$sink" 2>/dev/null
  }

  ok_input='{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"a","is_error":false}}'
  err_input='{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/x"},"tool_response":{"is_error":true,"stderr":"nope"}}'
  fail_input='{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{},"tool_response":{"success":false}}'
  decoy='{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo is_error: true and success: false"},"tool_response":{"stdout":"done"}}'
  renamed='{"hook_event_name":"PostToolUse","tool_name":"Grep","tool_input":{"note":"tool_name is quoted here too"},"tool_response":{}}'
  nameless='{"hook_event_name":"PostToolUse","tool_input":{},"tool_response":{}}'

  out=$(run "$ok_input" ok)
  check "a successful call records ok true" '"ok":true' "$out"
  check "a successful call records the tool" '"tool":"Bash"' "$out"
  check "a successful call is info level" '"level":"info"' "$out"
  check "a line carries a timestamp" '"timestamp":"20' "$out"
  check "a line carries ts alongside timestamp" '"ts":"20' "$out"

  out=$(run "$err_input" err)
  check "is_error true records an error event" '"is_error":true' "$out"
  check "an error event is error level" '"level":"error"' "$out"
  check "an error event records ok false" '"ok":false' "$out"
  check "an error event records the tool" '"tool":"Read"' "$out"

  out=$(run "$fail_input" fail)
  check "success false records an error event" '"level":"error"' "$out"

  out=$(run "$decoy" decoy)
  check "an error string in the command is not an error" '"level":"info"' "$out"

  out=$(run "$renamed" renamed)
  check "the first tool_name wins" '"tool":"Grep"' "$out"

  out=$(run "$nameless" nameless)
  check "a missing tool name records unknown" '"tool":"unknown"' "$out"

  # One call, one line.
  sink="$tmp/sink-append.jsonl"
  rm -f "$sink"
  printf '%s' "$ok_input" | WURK_HARNESS_EVENTS="$sink" "$self"
  printf '%s' "$err_input" | WURK_HARNESS_EVENTS="$sink" "$self"
  lines=$(wc -l <"$sink" | tr -d ' ')
  if [ "$lines" = "2" ]; then pass "two calls append two lines"; else fail "two calls append two lines" "got $lines"; fi

  # Fail-open, and silent.
  sink="$tmp/sink-quiet.jsonl"
  rm -f "$sink"
  out=$(printf '%s' "$ok_input" | WURK_HARNESS_EVENTS="$sink" "$self")
  if [ -z "$out" ]; then pass "the hook prints nothing"; else fail "the hook prints nothing" "got: $out"; fi

  out=$(printf 'not json {{{' | WURK_HARNESS_EVENTS="$tmp/sink-garbage.jsonl" "$self"; echo "rc=$?")
  check "garbage stdin exits 0" 'rc=0' "$out"

  out=$(WURK_HARNESS_EVENTS="$tmp/sink-empty.jsonl" "$self" </dev/null; echo "rc=$?")
  check "empty stdin exits 0" 'rc=0' "$out"
  if [ -f "$tmp/sink-empty.jsonl" ]; then
    fail "empty stdin writes nothing" "sink was created"
  else
    pass "empty stdin writes nothing"
  fi

  # The off switch.
  sink="$tmp/sink-off.jsonl"
  rm -f "$sink"
  printf '%s' "$ok_input" | WURK_HARNESS_EVENTS=off "$self"
  if [ -f "$sink" ]; then fail "WURK_HARNESS_EVENTS=off writes nothing" "sink exists"; else pass "WURK_HARNESS_EVENTS=off writes nothing"; fi

  # A missing parent directory is created, not a failure.
  sink="$tmp/deep/er/still/sink.jsonl"
  printf '%s' "$ok_input" | WURK_HARNESS_EVENTS="$sink" "$self"
  if [ -s "$sink" ]; then pass "a missing sink directory is created"; else fail "a missing sink directory is created" "no line landed"; fi

  # An unwritable sink is silent, not fatal.
  mkdir -p "$tmp/ro" && printf '' >"$tmp/ro/sink.jsonl" && chmod 400 "$tmp/ro/sink.jsonl"
  out=$(printf '%s' "$ok_input" | WURK_HARNESS_EVENTS="$tmp/ro/sink.jsonl" "$self" 2>&1)
  rc=$?
  if [ "$rc" = "0" ] && [ -z "$out" ]; then
    pass "an unwritable sink exits 0 quietly"
  else
    fail "an unwritable sink exits 0 quietly" "rc=$rc out=${out:-nothing}"
  fi
  chmod 600 "$tmp/ro/sink.jsonl" 2>/dev/null

  if [ "$failures" -eq 0 ]; then
    echo "self-test: all cases passed"
    exit 0
  fi
  echo "self-test: $failures failure(s)"
  exit 1
}

case "${1:-}" in
  --self-test) self_test ;;
  *) run_hook ;;
esac
exit 0

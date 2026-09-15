#!/bin/sh
# hooks/main-session-policy.sh - SessionStart hook: tells the top-level
# session that it coordinates and delegates, and says nothing at all when
# it fires inside a subagent.
#
# Installed by `ruby install.rb --with hooks` (opt-in; the default install
# never touches hooks) as ~/.claude/hooks/wurk-main-session-policy.sh and
# wired by hand into settings.json under SessionStart with matcher
# "startup" - the installer prints the snippet and never edits settings
# itself. Another harness ships an equivalent; this one is the generic
# form, so the text below names no persona, product, project, ticket
# prefix, or path. A consumer that wants specifics adds its own hook.
#
# Harness contract (Claude Code hooks reference, checked 2026-09-14):
#
#   - SessionStart receives JSON on stdin with the common fields plus
#     `source` ("startup" | "resume" | "clear" | "compact" | "fork").
#     Plain stdout on exit 0 is added to the model's context.
#   - The common field `agent_id` is "present only when the hook fires
#     inside a subagent call"; that is the documented way to tell a
#     subagent call from a main-thread call. `agent_type` is not enough:
#     it is also present when a top-level session starts with
#     `claude --agent <name>`.
#   - Hooks in settings files also run inside subagents, so this script
#     must suppress itself rather than rely on the wiring.
#   - The CLAUDE_AGENT_ID environment variable is NOT documented; it is
#     honored here as belt and braces only. The documented signal is the
#     `agent_id` input field.
#   - Output is capped at 10,000 characters; the text stays short.
#
# Fail-open: this hook never exits non-zero and never blocks a session.
# Any unexpected condition ends in a silent exit 0. An operator can turn
# it off without unwiring it: WURK_MAIN_SESSION_POLICY=off (or 0).
#
# Portability: POSIX sh, coreutils, grep and sed. No other dependencies.
#
#   hooks/main-session-policy.sh --self-test   # hermetic PASS/FAIL cases

set +e

policy_text() {
  cat <<'EOF'
Main-session policy (from a SessionStart hook):

This is the top-level session. It coordinates; it does not code. Ticketed
work is delegated to a subagent or to a seeded workspace session that owns
one ticket in its own branch. This session reads, decides, dispatches,
reviews, and reports. Direct edits from here are limited to the
coordination artifacts themselves (journal, notes, campaign files).

Subagents never see this text; the hook suppresses itself when it fires
inside a subagent.
EOF
}

# Reads stdin only when it is not a terminal, so a hand-run never hangs.
read_input() {
  if [ -t 0 ]; then
    printf ''
  else
    cat 2>/dev/null || true
  fi
}

# Exit 0 silently, printing nothing, when any of these hold:
#   - CLAUDE_AGENT_ID is set and non-empty (undocumented; belt and braces)
#   - the input carries an "agent_id" key (the documented subagent signal)
#   - the event is SubagentStart (someone wired it there by mistake)
#   - WURK_MAIN_SESSION_POLICY is "off" or "0" (operator escape hatch)
suppressed() {
  input="$1"
  case "${WURK_MAIN_SESSION_POLICY:-}" in
    off|OFF|0) return 0 ;;
  esac
  [ -n "${CLAUDE_AGENT_ID:-}" ] && return 0
  printf '%s' "$input" | grep -q '"agent_id"[[:space:]]*:' 2>/dev/null && return 0
  printf '%s' "$input" | grep -q '"hook_event_name"[[:space:]]*:[[:space:]]*"SubagentStart"' 2>/dev/null && return 0
  return 1
}

run_hook() {
  input=$(read_input) || input=""
  if suppressed "$input"; then
    exit 0
  fi
  policy_text
  exit 0
}

# --- self-test ------------------------------------------------------------
# Each case re-execs this script with a fixture on stdin and a controlled
# environment, then checks whether the policy text came out. Hermetic: no
# harness, no settings file, nothing outside this process tree.

self_test() {
  failures=0
  self="$0"

  check() {
    name="$1"; expect="$2"; got="$3"
    if [ "$expect" = "text" ] && printf '%s' "$got" | grep -q 'coordinates'; then
      echo "PASS $name"
    elif [ "$expect" = "silent" ] && [ -z "$got" ]; then
      echo "PASS $name"
    else
      echo "FAIL $name (expected $expect)"
      failures=$((failures + 1))
    fi
  }

  top='{"session_id":"s1","hook_event_name":"SessionStart","source":"startup","cwd":"/x"}'
  sub='{"session_id":"s1","hook_event_name":"SessionStart","source":"startup","agent_id":"a1","agent_type":"worker"}'
  sas='{"session_id":"s1","hook_event_name":"SubagentStart","agent_type":"worker"}'

  out=$(printf '%s' "$top" | CLAUDE_AGENT_ID= WURK_MAIN_SESSION_POLICY= "$self")
  check "top-level session prints the policy" text "$out"

  out=$(printf '%s' "$sub" | CLAUDE_AGENT_ID= WURK_MAIN_SESSION_POLICY= "$self")
  check "agent_id in input suppresses" silent "$out"

  out=$(printf '%s' "$top" | CLAUDE_AGENT_ID=a1 WURK_MAIN_SESSION_POLICY= "$self")
  check "CLAUDE_AGENT_ID env suppresses" silent "$out"

  out=$(printf '%s' "$sas" | CLAUDE_AGENT_ID= WURK_MAIN_SESSION_POLICY= "$self")
  check "SubagentStart event suppresses" silent "$out"

  out=$(printf '%s' "$top" | CLAUDE_AGENT_ID= WURK_MAIN_SESSION_POLICY=off "$self")
  check "WURK_MAIN_SESSION_POLICY=off suppresses" silent "$out"

  out=$(CLAUDE_AGENT_ID= WURK_MAIN_SESSION_POLICY= "$self" </dev/null)
  check "empty stdin is treated as top-level (fail-open)" text "$out"

  out=$(printf 'not json at all {{{' | CLAUDE_AGENT_ID= WURK_MAIN_SESSION_POLICY= "$self")
  check "garbage stdin is treated as top-level (fail-open)" text "$out"

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

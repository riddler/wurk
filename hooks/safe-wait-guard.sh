#!/bin/sh
# hooks/safe-wait-guard.sh - PreToolUse hook (matcher: Bash) that denies
# the three wait shapes that burn a machine or outlive their tool call,
# and says in the denial how to fix each one.
#
# It encodes, as a machine check, the wait rules the conductor skill's
# gate-wait rules and the repo worker's waiting rules already state in
# prose:
#
#   - a foreground wait must be bounded and must sleep between polls; a
#     loop that polls without sleeping is a spin loop that burns a core
#     for as long as it waits;
#   - a loop started with `&` outlives the tool call - nothing stops it
#     when the call returns - unless a trap ties it to the shell;
#   - `pgrep -f PATTERN` inside a loop matches the loop's own shell, whose
#     command line contains PATTERN, so the loop never sees the process
#     exit unless it excludes its own pid ($$).
#
# Installed by `ruby install.rb --with hooks` (opt-in; the default install
# never touches hooks) as ~/.claude/hooks/wurk-safe-wait-guard.sh and wired
# by hand into settings.json under PreToolUse with matcher "Bash" - the
# installer prints the snippet and never edits settings itself. Another
# harness ships an equivalent.
#
# Harness contract (Claude Code hooks reference, checked 2026-09-14):
#
#   - PreToolUse receives JSON on stdin: the common fields plus
#     `tool_name` and `tool_input`; for Bash, `tool_input.command` (and
#     an optional `description`).
#   - To deny: exit 0 with this JSON on stdout -
#       {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#        "permissionDecision":"deny","permissionDecisionReason":"..."}}
#     (the top-level `decision: "block"` form is not the PreToolUse form).
#   - Hooks in settings files also run inside subagents. This guard is
#     meant to; a worker's spin loop is exactly what it exists to catch.
#   - Output is capped at 10,000 characters; the reasons stay short.
#
# Fail-open: this hook never exits non-zero. If the input cannot be read
# or the command cannot be extracted, it prints nothing and exits 0, and
# the tool call proceeds. The check is best-effort pattern matching over
# the command text, not a shell parser; the reason text names the fix so
# a false positive costs one rewrite, never a stuck session.
#
# Portability: POSIX sh, coreutils, grep and sed (grep -E / sed -E, which
# BSD and GNU both accept). No other dependencies.
#
#   hooks/safe-wait-guard.sh --self-test   # hermetic PASS/FAIL cases

set +e

# A word boundary that both BSD and GNU grep -E understand: \b is GNU-only.
W='(^|[^[:alnum:]_])'
E='([^[:alnum:]_]|$)'

# No double quotes or newlines in a reason: it goes into JSON verbatim.
R1_REASON="spin loop: a while/until loop with no sleep burns CPU while it waits. Fix: add 'sleep N' inside the loop and bound it (a counter or a deadline), or wait on the process/log in the foreground instead."
R2_REASON="backgrounded loop: a loop started with & outlives this tool call and nothing stops it. Fix: run it in the foreground with a bound, or add trap 'kill \$!' EXIT so it dies with the shell."
R3_REASON="pgrep -f inside a loop matches this shell's own command line, so it never sees the process exit. Fix: exclude yourself (pgrep -f PATTERN | grep -vx \$\$) or poll a pid file / 'kill -0 PID' instead."

# NULs are stripped here: bash's command substitution warns on a stray
# NUL byte (dash drops it silently), so stripping at the source keeps
# both shells silent.
read_input() {
  if [ -t 0 ]; then
    printf ''
  else
    cat 2>/dev/null | tr -d '\000' || true
  fi
}

# Pulls tool_input.command out of the input JSON as one line of shell.
# Best effort: newlines are dropped first (a JSON document has none inside
# a string, so this only joins pretty-printed input), then the string
# after `"command":` is taken up to its closing unescaped quote, then the
# escapes that matter for matching are undone: \n and \t become spaces,
# \" becomes ", \\ becomes \. Prints nothing when there is no command.
extract_command() {
  printf '%s' "$1" | tr -d '\n\r' \
    | sed -E -n 's/.*(^|[^\\])"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\2/p' \
    | sed -E -e 's/\\n/ /g' -e 's/\\t/ /g' -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}

has() { printf '%s' "$1" | grep -qE "$2" 2>/dev/null; }

# Every `while ... do` / `until ... do` header in the command, one per
# line, minus the line-reader and getopts forms that never spin.
spin_loop_headers() {
  printf '%s' "$1" \
    | grep -oE "${W}(while|until)[^;]*(;|[[:space:]])[[:space:]]*do${E}" 2>/dev/null \
    | grep -vE "${W}while[[:space:]]+(IFS=[^[:space:]]*[[:space:]]+)?read${E}" \
    | grep -vE "${W}while[[:space:]]+getopts${E}"
}

has_loop() { has "$1" "${W}(while|until)[^;]*(;|[[:space:]])[[:space:]]*do${E}"; }

deny() {
  reason=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
}

check_command() {
  cmd="$1"
  [ -n "$cmd" ] || return 0

  # R1: a while/until loop that is not a line reader, and no sleep anywhere.
  if [ -n "$(spin_loop_headers "$cmd")" ] && ! has "$cmd" "${W}sleep${E}"; then
    deny "$R1_REASON"
    return 0
  fi

  # R2: a loop's done is followed by & (not &&), and nothing traps.
  if has "$cmd" "${W}done[[:space:]]*[)}]?[[:space:]]*&([^&]|$)" && ! has "$cmd" "${W}trap${E}"; then
    deny "$R2_REASON"
    return 0
  fi

  # R3: pgrep -f inside a loop with no $$ to exclude the loop's own shell.
  if has_loop "$cmd" && has "$cmd" "${W}pgrep[[:space:]]+(-[[:alnum:]]+[[:space:]]+)*-[[:alnum:]]*f${E}" && ! has "$cmd" '\$\$'; then
    deny "$R3_REASON"
    return 0
  fi
  return 0
}

run_hook() {
  input=$(read_input) || input=""
  [ -n "$input" ] || exit 0
  has "$input" '"tool_name"[[:space:]]*:[[:space:]]*"Bash"' || exit 0
  cmd=$(extract_command "$input") || exit 0
  check_command "$cmd"
  exit 0
}

# --- self-test ------------------------------------------------------------
# Re-execs this script with each fixture on stdin. `allow` expects no
# output; `deny` expects a deny decision whose reason names the fix.

self_test() {
  failures=0
  self="$0"

  fixture() { printf '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

  expect() {
    kind="$1"; name="$2"; out="$3"; must="${4:-}"
    case "$kind" in
      allow)
        if [ -z "$out" ]; then echo "PASS allow: $name"; else echo "FAIL allow: $name (got: $out)"; failures=$((failures + 1)); fi ;;
      deny)
        if printf '%s' "$out" | grep -q '"permissionDecision":"deny"' \
          && printf '%s' "$out" | grep -q 'Fix:' \
          && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
          echo "PASS deny: $name"
        else
          echo "FAIL deny: $name (got: ${out:-nothing})"; failures=$((failures + 1))
        fi ;;
    esac
  }

  run() { printf '%s' "$1" | "$self"; }

  # allowed
  expect allow "bounded until with sleep" "$(run "$(fixture "until grep -qE 'GREEN|RED' log; do sleep 15; done")")"
  expect allow "while read line reader" "$(run "$(fixture 'while read -r line; do echo \"$line\"; done < file')")"
  expect allow "while IFS= read line reader" "$(run "$(fixture 'while IFS= read -r line; do echo \"$line\"; done < file')")"
  expect allow "for loop" "$(run "$(fixture 'for i in 1 2 3; do echo $i; done')")"
  expect allow "plain command" "$(run "$(fixture 'ruby skills/wurk:kit/scripts/test/run.rb')")"
  expect allow "piped while read" "$(run "$(fixture 'git log --oneline | while read l; do echo $l; done')")"
  expect allow "while inside a word" "$(run "$(fixture 'echo \"meanwhile\" && echo done')")"
  expect allow "done && is not backgrounding" "$(run "$(fixture 'for f in a b; do touch $f; done && ls')")"
  expect allow "backgrounded loop with trap" "$(run "$(fixture "trap 'kill \$!' EXIT; (while true; do sleep 1; done) &")")"
  expect allow "pgrep loop excluding self" "$(run "$(fixture 'while pgrep -f gate.rb | grep -vx $$ >/dev/null; do sleep 5; done')")"
  expect allow "escaped newlines in command" "$(run "$(fixture 'until test -f x; do\n  sleep 2\ndone')")"
  expect allow "non-Bash tool" "$(run '{"tool_name":"Read","tool_input":{"file_path":"while true; do :; done"}}')"
  expect allow "no tool_input" "$(run '{"tool_name":"Bash"}')"
  expect allow "garbage stdin" "$(run 'not json {{{')"
  expect allow "empty stdin" "$("$self" </dev/null)"

  # denied
  expect deny "while true no sleep (R1)" "$(run "$(fixture 'while true; do date; done')")" "sleep"
  expect deny "while ! test no sleep (R1)" "$(run "$(fixture 'while ! test -f done.txt; do :; done')")" "sleep"
  expect deny "until no sleep (R1)" "$(run "$(fixture 'until grep -q GREEN log; do :; done')")" "sleep"
  expect deny "backgrounded loop no trap (R2)" "$(run "$(fixture '(while true; do sleep 1; done) &')")" "trap"
  expect deny "pgrep -f in loop no \$\$ (R3)" "$(run "$(fixture 'while pgrep -f gate.rb >/dev/null; do sleep 5; done')")" '$$'

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

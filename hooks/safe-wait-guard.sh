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
# Scope: the guard reads SHELL, and a Bash call carries data too - a
# heredoc body, a long -m message. It must not read that data as shell.
# The loop rules therefore match a header inside one line (plus the one
# newline the long `while ... / do` form spans) and require the `done`
# that ends a real loop, rather than looking for the two keywords anywhere
# in the command. See extract_command and loop_scan_text below.
#
# Fail-open: this hook never exits non-zero. If the input cannot be read
# or the command cannot be extracted, it prints nothing and exits 0, and
# the tool call proceeds. The check is best-effort pattern matching over
# the command text, not a shell parser; the reason text names the fix so
# a false positive costs one rewrite, never a stuck session.
#
# Portability: POSIX sh, coreutils, grep, sed and awk (grep -E / sed -E,
# which BSD and GNU both accept). No other dependencies.
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

# Pulls tool_input.command out of the input JSON as shell text.
# Best effort: the JSON's own newlines are dropped first (a JSON document
# has none inside a string, so this only joins pretty-printed input), then
# the string after `"command":` is taken up to its closing unescaped
# quote, then the escapes that matter for matching are undone: \n becomes
# a real newline, \t a space, \" a ", \\ a \. Prints nothing when there is
# no command.
#
# \n becoming a NEWLINE rather than a space is load-bearing. It used to
# become a space, which folded a whole multi-line command onto one line
# before any pattern ran - and a folded heredoc is prose, not shell. A
# journal entry carrying "while" in one paragraph and "do" in a later one
# then matched the R1 loop header and was refused as a spin loop with no
# loop anywhere in it (wu-jarf). Keeping the line structure is what lets
# the loop-keyword scan below stay inside a line.
extract_command() {
  printf '%s' "$1" | tr -d '\n\r' \
    | sed -E -n 's/.*(^|[^\\])"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\2/p' \
    | sed -E -e 's/\\n/\
/g' -e 's/\\t/ /g' -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}

has() { printf '%s' "$1" | grep -qE "$2" 2>/dev/null; }

# The header a while/until loop is written with, matched WITHIN one line.
LOOP_HEADER="${W}(while|until)[^;]*(;|[[:space:]])[[:space:]]*do${E}"

# The text the loop-KEYWORD scan runs over.
#
# grep is line-oriented, so scanning the command as it stands already
# keeps a match inside one line. The one thing that legitimately crosses a
# line is a loop header written in the long form -
#
#     while true
#     do
#       ...
#     done
#
# - so a line whose first word is `do` is joined onto the line above it,
# and nothing else is. That is the single newline a real header spans, and
# it is exactly what the old whole-command folding was there to catch.
#
# A blank line is never joined across: paragraphs are separated by one,
# which is precisely the prose shape that used to trip R1.
loop_scan_text() {
  printf '%s\n' "$1" | awk '
    {
      line = $0
      if (prev != "" && line ~ /^[ \t]*do([^A-Za-z0-9_]|$)/) {
        sub(/^[ \t]*/, "", line)
        prev = prev " " line
      } else {
        if (prev != "") print prev
        prev = line
      }
    }
    END { if (prev != "") print prev }
  ' 2>/dev/null
}

# Every `while ... do` / `until ... do` header in the command, one per
# line, minus the line-reader and getopts forms that never spin.
spin_loop_headers() {
  loop_scan_text "$1" \
    | grep -oE "$LOOP_HEADER" 2>/dev/null \
    | grep -vE "${W}while[[:space:]]+(IFS=[^[:space:]]*[[:space:]]+)?read${E}" \
    | grep -vE "${W}while[[:space:]]+getopts${E}"
}

has_loop() { has "$(loop_scan_text "$1")" "$LOOP_HEADER"; }

# A loop the shell will actually run is terminated by `done`. Requiring it
# costs a real loop nothing - the command has to be syntactically complete
# to run at all - and it rules out the remaining prose shape the per-line
# scan cannot: one sentence carrying both "while" and "do".
has_done() { has "$1" "${W}done${E}"; }

deny() {
  reason=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
}

# Two views of the command are used below, and which one a check gets is
# the whole of this fix:
#
#   $cmd   - line structure intact. Only the loop-KEYWORD scan reads it,
#            through loop_scan_text, so a header must sit inside one line.
#   $flat  - the same command on one line, for every check that asks
#            whether something appears ANYWHERE in the command: the sleep
#            that bounds a loop, the trap that ties a background job to
#            the shell, the $$ that excludes a pgrep from itself, and R2's
#            `done ... &`, whose two halves may sit on separate lines.
check_command() {
  cmd="$1"
  [ -n "$cmd" ] || return 0
  flat=$(printf '%s' "$cmd" | tr '\n' ' ')

  # R1: a while/until loop that is not a line reader, and no sleep anywhere.
  if has_done "$flat" && [ -n "$(spin_loop_headers "$cmd")" ] && ! has "$flat" "${W}sleep${E}"; then
    deny "$R1_REASON"
    return 0
  fi

  # R2: a loop's done is followed by & (not &&), and nothing traps.
  if has "$flat" "${W}done[[:space:]]*[)}]?[[:space:]]*&([^&]|$)" && ! has "$flat" "${W}trap${E}"; then
    deny "$R2_REASON"
    return 0
  fi

  # R3: pgrep -f inside a loop with no $$ to exclude the loop's own shell.
  if has_done "$flat" && has_loop "$cmd" && has "$flat" "${W}pgrep[[:space:]]+(-[[:alnum:]]+[[:space:]]+)*-[[:alnum:]]*f${E}" && ! has "$flat" '\$\$'; then
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
  # wu-jarf: prose is not shell. A heredoc body carrying the two header
  # words on different lines used to fold into one line and match R1.
  expect allow "heredoc prose, while and do on different lines" "$(run "$(fixture 'cat <<EOF > journal.md\nWorkers hold their notes while they are being written.\n\nThe conductor should not assume the sweep is finished, nor\ndo anything about it yet.\nEOF')")"
  expect allow "heredoc prose paragraphs apart" "$(run "$(fixture 'cat <<-EOF > f\n\twait a while for it\n\tand then do the rest\n\tEOF')")"
  expect allow "one prose line with while and do but no done" "$(run "$(fixture "echo 'we waited a while' && echo 'and do it again'")")"
  expect allow "commit message mentioning a while loop" "$(run "$(fixture "git commit -m 'Stops polling while the gate runs\n\nWe do not need a second reader.'")")"
  expect allow "non-Bash tool" "$(run '{"tool_name":"Read","tool_input":{"file_path":"while true; do :; done"}}')"
  expect allow "no tool_input" "$(run '{"tool_name":"Bash"}')"
  expect allow "garbage stdin" "$(run 'not json {{{')"
  expect allow "empty stdin" "$("$self" </dev/null)"

  # denied
  expect deny "while true no sleep (R1)" "$(run "$(fixture 'while true; do date; done')")" "sleep"
  expect deny "while ! test no sleep (R1)" "$(run "$(fixture 'while ! test -f done.txt; do :; done')")" "sleep"
  expect deny "until no sleep (R1)" "$(run "$(fixture 'until grep -q GREEN log; do :; done')")" "sleep"
  # The case the old whole-command folding existed to catch: a real loop
  # whose header is split across the one newline shell allows there.
  expect deny "multi-line while spin loop (R1)" "$(run "$(fixture 'while true\ndo\n  date\ndone')")" "sleep"
  expect deny "multi-line until spin loop (R1)" "$(run "$(fixture 'until test -f x\ndo\n  :\ndone')")" "sleep"
  expect deny "spin loop inside a heredoc body (R1)" "$(run "$(fixture 'bash <<EOF\nwhile true\ndo\n  date\ndone\nEOF')")" "sleep"
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

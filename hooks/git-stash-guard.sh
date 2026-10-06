#!/bin/sh
# hooks/git-stash-guard.sh - PreToolUse hook (matcher: Bash) that denies
# writes to the git stash list from places where the list is not yours,
# and says in the denial how to fix each one.
#
# Every linked worktree of a repository shares ONE stash list with the main
# checkout and with every other linked worktree. Under worktree-per-issue
# that list is not a private scratch area: the kit itself puts entries on
# it (worktree_create.rb --stash-dirty stashes the main checkout's dirty
# edits and reports the restore command), and a person working in the main
# checkout puts their own there. An agent in a linked worktree that runs
# `git stash pop`, `drop` or `clear` acts on whichever entry is on top,
# which is usually somebody else's work.
#
# The two rules:
#
#   - from a linked worktree (git rev-parse --git-dir differs from
#     --git-common-dir), deny `git stash` with any verb but `list` and
#     `show` - a bare `git stash` and `git stash -u` are pushes;
#   - from anywhere, deny `git -C <dir> stash pop|drop|clear`: reaching
#     into another checkout to remove a stash entry is never the caller's
#     to decide.
#
# The main checkout's own `git stash push/pop` is allowed: that is the
# ordinary single-checkout workflow, and the list there is the owner's.
#
# Installed by `ruby install.rb --with hooks` (opt-in; the default install
# never touches hooks) as ~/.claude/hooks/wurk-git-stash-guard.sh and wired
# by hand into settings.json under PreToolUse with matcher "Bash" - the
# installer prints the snippet and never edits settings itself.
#
# Harness contract: the same as hooks/safe-wait-guard.sh. PreToolUse
# receives JSON on stdin with `cwd`, `tool_name` and `tool_input.command`;
# a deny is exit 0 with a hookSpecificOutput permissionDecision "deny".
# The session's cwd comes from the input's `cwd` field, falling back to
# the hook's own working directory when the field is absent.
#
# Scope: compound commands are split on &&, ||, ;, | and & and each piece
# is read on its own, so `git add -A && git stash` is caught. This is
# simple splitting over the command text, not a shell parser: a quoted
# argument containing one of those separators can split wrongly, and a
# `cd` earlier in the same command is not followed. Only a piece whose
# first word is `git` and whose subcommand is `stash` is judged, so
# `git add stash/notes.md` and `cat stash.txt` are untouched.
#
# Fail-open: this hook never exits non-zero. If the input cannot be read,
# the command cannot be extracted, or git cannot say what the cwd is, it
# prints nothing and exits 0, and the tool call proceeds.
#
# Portability: POSIX sh, coreutils, grep, sed, awk and git. No other
# dependencies.
#
#   hooks/git-stash-guard.sh --self-test   # hermetic PASS/FAIL cases

set +e

# No double quotes or newlines in a reason: it goes into JSON verbatim.
LINKED_REASON="git stash from a linked worktree: every worktree of this repo shares one stash list, so this write can pop, drop or bury an entry that belongs to another checkout or session. Fix: commit a wip commit on your branch instead (git add -A && git commit -m wip); git stash list and git stash show are still allowed."
CROSS_REASON="git -C <dir> stash pop/drop/clear removes an entry from a stash list another checkout or session may own. Fix: look with git stash list and git stash show -p, leave removing the entry to whoever made it, and commit a wip commit on your branch instead of stashing."

# NULs are stripped here, as in safe-wait-guard.sh.
read_input() {
  if [ -t 0 ]; then
    printf ''
  else
    cat 2>/dev/null | tr -d '\000' || true
  fi
}

# Pulls a top-level JSON string field out of the input as text. Best
# effort, the same shape as safe-wait-guard.sh's extract_command: the key
# must not be preceded by a backslash (so a key-like string inside the
# command is not taken for the real one), then the escapes that matter are
# undone - \n becomes a newline, \t a space, \" a ", \\ a \.
extract_field() {
  printf '%s' "$1" | tr -d '\n\r' \
    | sed -E -n 's/.*(^|[^\\])"'"$2"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\2/p' \
    | sed -E -e 's/\\n/\
/g' -e 's/\\t/ /g' -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}

has() { printf '%s' "$1" | grep -qE "$2" 2>/dev/null; }

deny() {
  reason=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
}

# One line per `git ... stash ...` piece of the command: "C <verb>" when
# the piece passed -C, "N <verb>" otherwise. A missing verb, or one that
# is an option (`git stash -u`), is a push. Global options that take a
# separate argument are skipped with it, so `git -c k=v stash pop` still
# finds `stash`.
stash_calls() {
  printf '%s\n' "$1" | awk '
    {
      nseg = split($0, segs, /&&|\|\||;|\||&/)
      for (s = 1; s <= nseg; s++) {
        n = split(segs[s], raw, /[ \t]+/)
        k = 0
        for (j = 1; j <= n; j++) {
          tok = raw[j]
          if (k == 0) sub(/^[({]+/, "", tok)
          if (tok != "") t[++k] = tok
        }
        if (k < 2 || t[1] != "git") continue
        i = 2; hasC = 0
        while (i <= k && t[i] ~ /^-/) {
          if (t[i] == "-C") { hasC = 1; i += 2; continue }
          if (t[i] ~ /^(-c|--git-dir|--work-tree|--namespace)$/) { i += 2; continue }
          i++
        }
        if (i > k || t[i] != "stash") continue
        verb = (i + 1 <= k) ? t[i + 1] : ""
        sub(/[)}]+$/, "", verb)
        if (verb == "" || verb ~ /^-/) verb = "push"
        print (hasC ? "C" : "N") " " verb
      }
    }
  ' 2>/dev/null
}

# True when $1 is inside a linked worktree: its git dir is not the common
# dir. Both are resolved to physical absolute paths from inside $1, so a
# relative answer from rev-parse compares correctly. Any failure (not a
# directory, not a repository, no git) is "not linked", which allows.
is_linked_worktree() {
  dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  pair=$(
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    cd "$dir" 2>/dev/null || exit 1
    gd=$(git rev-parse --git-dir 2>/dev/null) || exit 1
    cd_=$(git rev-parse --git-common-dir 2>/dev/null) || exit 1
    a=$(cd "$gd" 2>/dev/null && pwd -P) || exit 1
    b=$(cd "$cd_" 2>/dev/null && pwd -P) || exit 1
    printf '%s\n%s' "$a" "$b"
  ) || return 1
  a=$(printf '%s' "$pair" | sed -n 1p)
  b=$(printf '%s' "$pair" | sed -n 2p)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]
}

check_command() {
  cmd="$1"; cwd="$2"
  [ -n "$cmd" ] || return 0
  has "$cmd" 'stash' || return 0
  calls=$(stash_calls "$cmd")
  [ -n "$calls" ] || return 0

  linked=""
  printf '%s\n' "$calls" | {
    while read -r kind verb; do
      case "$verb" in
        list|show) continue ;;
      esac
      if [ "$kind" = "C" ]; then
        case "$verb" in
          pop|drop|clear) deny "$CROSS_REASON"; exit 0 ;;
        esac
      fi
      if [ -z "$linked" ]; then
        if is_linked_worktree "$cwd"; then linked=yes; else linked=no; fi
      fi
      if [ "$linked" = "yes" ]; then
        deny "$LINKED_REASON"
        exit 0
      fi
    done
  }
  return 0
}

run_hook() {
  input=$(read_input) || input=""
  [ -n "$input" ] || exit 0
  has "$input" '"tool_name"[[:space:]]*:[[:space:]]*"Bash"' || exit 0
  cmd=$(extract_field "$input" command) || exit 0
  cwd=$(extract_field "$input" cwd) || cwd=""
  [ -n "$cwd" ] || cwd=$(pwd 2>/dev/null)
  check_command "$cmd" "$cwd"
  exit 0
}

# --- self-test ------------------------------------------------------------
# Builds a throwaway repository with one linked worktree under a fresh temp
# dir (git's global and system config ignored), then re-execs this script
# with each fixture on stdin. `allow` expects no output; `deny` expects a
# deny decision whose reason names the fix. Nothing outside the temp dir is
# read or written, and no stash command is ever run.

self_test() {
  failures=0
  self="$0"
  case "$self" in /*) ;; *) self="$(pwd)/$self" ;; esac

  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t gitstashguard) || { echo "FAIL setup: mktemp"; exit 1; }
  trap 'rm -rf "$tmp"' EXIT
  GIT_CONFIG_NOSYSTEM=1; GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  main="$tmp/main"; wt="$tmp/wt"; plain="$tmp/plain"
  mkdir -p "$main" "$plain"
  if ! { git -C "$main" init -q \
      && git -C "$main" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init \
      && git -C "$main" worktree add -q -b wt "$wt"; } >/dev/null 2>&1; then
    echo "FAIL setup: could not build the linked-worktree fixture"
    exit 1
  fi

  fixture() { printf '{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" "$2"; }

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

  run() { printf '%s' "$(fixture "$1" "$2")" | "$self"; }

  # denied from the linked worktree
  for c in 'git stash' 'git stash push -m x' 'git stash pop' 'git stash apply' \
           'git stash drop' 'git stash clear' 'git add -A && git stash' 'git stash -u'; do
    expect deny "linked worktree: $c" "$(run "$wt" "$c")" "wip commit"
  done

  # allowed from the linked worktree
  expect allow "linked worktree: git stash list" "$(run "$wt" 'git stash list')"
  expect allow "linked worktree: git stash show -p" "$(run "$wt" 'git stash show -p')"
  expect allow "linked worktree: git status" "$(run "$wt" 'git status')"
  expect allow "linked worktree: git commit" "$(run "$wt" "git commit -m 'Adds the stash notes'")"
  expect allow "linked worktree: a path containing stash" "$(run "$wt" 'git add docs/stash-notes.md && cat stash/README')"

  # the main checkout owns its list
  for c in 'git stash' 'git stash push -m x' 'git stash pop' 'git stash apply' \
           'git stash drop' 'git stash clear' 'git add -A && git stash'; do
    expect allow "main checkout: $c" "$(run "$main" "$c")"
  done

  # -C pop/drop/clear is denied from anywhere
  expect deny "main checkout: git -C <dir> stash pop" "$(run "$main" "git -C $wt stash pop")" "whoever made it"
  expect deny "not a repo: git -C <dir> stash drop" "$(run "$plain" "git -C $main stash drop")" "whoever made it"
  expect deny "linked worktree: git -C <dir> stash clear" "$(run "$wt" "git -C $main stash clear")" "whoever made it"
  expect allow "not a repo: git -C <dir> stash list" "$(run "$plain" "git -C $main stash list")"

  # fail open
  expect allow "non-Bash tool" "$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"git stash pop"}}' | "$self")"
  expect allow "no tool_input" "$(printf '%s' '{"tool_name":"Bash"}' | "$self")"
  expect allow "garbage stdin" "$(printf '%s' 'not json {{{' | "$self")"
  expect allow "empty stdin" "$("$self" </dev/null)"
  expect allow "cwd that does not exist" "$(run "$tmp/nope" 'git stash pop')"

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

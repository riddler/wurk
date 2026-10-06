#!/bin/sh
# hooks/worktree-escape-guard.sh - PreToolUse hook (matcher: Bash) that
# denies changing what is checked out in a main checkout the consumer has
# declared owned, and says in the denial how to fix it.
#
# Under worktree-per-issue the work happens in linked worktrees, and the
# main checkout is often not idle: a long-running process (a daemon, a
# scheduler, a server reading its own tree) may live there and act on
# whatever is checked out. An agent pointed at that checkout - a reviewer
# given its path and a sha range - can run `git checkout <sha>` there to
# "look at" the commit, which detaches the HEAD under the process that
# owns it. That happened: a reviewer agent checked out a sha in a live main
# checkout and left it detached for about fifteen minutes.
#
# The rule: when the target checkout is a MAIN checkout (git rev-parse
# --git-dir equals --git-common-dir) AND that checkout's .claude/wurk.json
# says parallelism.model "worktree-per-issue" AND
# parallelism.main_checkout_owned true, deny
#
#   - `git checkout` with any argument (a sha, a branch, -b, and also
#     `git checkout -- <file>`, which rewrites the tree);
#   - `git switch`, in any form;
#   - `git reset --hard|--keep|--merge|--soft`, and a `git reset` naming
#     anything before `--` (it may be a commit; HEAD would move). A bare
#     `git reset` and `git reset -- <paths>` only touch the index and
#     are allowed;
#   - `git stash` with any verb but `list` and `show`.
#
# The target is the session's cwd, or the `-C <dir>` the command passes
# (relative to the cwd; several -C compose as git composes them). The same
# commands in a linked worktree are allowed, and so is everything when the
# consumer has not opted in: without parallelism.main_checkout_owned the
# main checkout is an ordinary place to work. Reading is never judged -
# `git show`, `git log` and `git diff` pass in any checkout.
#
# Relation to hooks/git-stash-guard.sh: that hook allows the main
# checkout's own `git stash push/pop`, because by default the main
# checkout is the owner's single-checkout workflow. This hook denies it
# only under the opt-in above, where the consumer has said the main
# checkout belongs to something else. The two do not contradict: without
# the opt-in this hook allows everything that one allows.
#
# Limit: only commands the Bash tool runs reach a PreToolUse hook. A kit
# script that runs git itself (worktree_create.rb --stash-dirty, for one,
# shells out from Ruby) is not seen here and is not covered by it.
#
# Installed by `ruby install.rb --with hooks` (opt-in; the default install
# never touches hooks) as ~/.claude/hooks/wurk-worktree-escape-guard.sh
# and wired by hand into settings.json under PreToolUse with matcher
# "Bash" - the installer prints the snippet and never edits settings
# itself.
#
# Harness contract: the same as hooks/safe-wait-guard.sh. PreToolUse
# receives JSON on stdin with `cwd`, `tool_name` and `tool_input.command`;
# a deny is exit 0 with a hookSpecificOutput permissionDecision "deny".
# The session's cwd comes from the input's `cwd` field, falling back to
# the hook's own working directory when the field is absent.
#
# Scope: compound commands are split on &&, ||, ;, | and & and each piece
# is read on its own, so `git add -A && git checkout main` is caught. This
# is simple splitting over the command text, not a shell parser: a quoted
# argument containing one of those separators can split wrongly, and a
# `cd` earlier in the same command is not followed. Only a piece whose
# first word is `git` is judged. `git restore` is not judged. The manifest
# is read with text matching, not a JSON parser: the parallelism object is
# expected to hold no nested object, which the schema guarantees.
#
# Fail-open: this hook never exits non-zero. If the input cannot be read,
# the command cannot be extracted, git cannot say what the target is, or
# the manifest cannot be read, it prints nothing and exits 0, and the tool
# call proceeds.
#
# Portability: POSIX sh, coreutils, grep, sed, awk and git. No other
# dependencies.
#
#   hooks/worktree-escape-guard.sh --self-test   # hermetic PASS/FAIL cases

set +e

# No double quotes or newlines in a reason: it goes into JSON verbatim.
OWNED_REASON="git checkout, switch, reset or stash in a main checkout this repo marks as owned (parallelism.main_checkout_owned): something else runs on what is checked out there, and this would detach or rewrite its tree. Fix: work in the bead's worktree; read history with git -C <main> show, log or diff, or look at a sha in a temporary worktree (git worktree add)."

# NULs are stripped here, as in safe-wait-guard.sh.
read_input() {
  if [ -t 0 ]; then
    printf ''
  else
    cat 2>/dev/null | tr -d '\000' || true
  fi
}

# Pulls a top-level JSON string field out of the input as text, the same
# best-effort shape as git-stash-guard.sh's extract_field.
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

# One line per piece of the command that would change what is checked out,
# holding that piece's -C target ("." when it passed none; several -C
# compose: an absolute one replaces, a relative one appends). Global
# options that take a separate argument are skipped with it.
tree_changing_targets() {
  printf '%s\n' "$1" | awk '
    function unquote(s) { gsub(/["\047]/, "", s); return s }
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
        i = 2; target = "."
        while (i <= k && t[i] ~ /^-/) {
          if (t[i] == "-C") {
            d = unquote(t[i + 1])
            if (d ~ /^\//) target = d
            else if (d != "") target = (target == "." ? d : target "/" d)
            i += 2; continue
          }
          if (t[i] ~ /^(-c|--git-dir|--work-tree|--namespace)$/) { i += 2; continue }
          i++
        }
        if (i > k) continue
        sub_ = t[i]
        hit = 0
        if (sub_ == "checkout") {
          hit = (i + 1 <= k)
        } else if (sub_ == "switch") {
          hit = 1
        } else if (sub_ == "reset") {
          for (a = i + 1; a <= k; a++) {
            arg = t[a]; sub(/[)}]+$/, "", arg)
            if (arg == "--") break
            if (arg ~ /^--(hard|keep|merge|soft)$/) { hit = 1; break }
            if (arg != "" && arg !~ /^-/) { hit = 1; break }
          }
        } else if (sub_ == "stash") {
          verb = (i + 1 <= k) ? t[i + 1] : ""
          sub(/[)}]+$/, "", verb)
          hit = (verb != "list" && verb != "show")
        }
        if (hit) print target
      }
    }
  ' 2>/dev/null
}

# True when $1 is inside a MAIN checkout: its git dir is the common dir.
# Both are resolved to physical absolute paths from inside $1. Any failure
# (not a directory, not a repository, a bare repository, no git) is "not
# main", which allows. On success the checkout's top level is left in
# $main_top.
is_main_checkout() {
  dir="$1"; main_top=""
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  triple=$(
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    cd "$dir" 2>/dev/null || exit 1
    gd=$(git rev-parse --git-dir 2>/dev/null) || exit 1
    cd_=$(git rev-parse --git-common-dir 2>/dev/null) || exit 1
    top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 1
    a=$(cd "$gd" 2>/dev/null && pwd -P) || exit 1
    b=$(cd "$cd_" 2>/dev/null && pwd -P) || exit 1
    printf '%s\n%s\n%s' "$a" "$b" "$top"
  ) || return 1
  a=$(printf '%s' "$triple" | sed -n 1p)
  b=$(printf '%s' "$triple" | sed -n 2p)
  main_top=$(printf '%s' "$triple" | sed -n 3p)
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$main_top" ] && [ "$a" = "$b" ]
}

# True when the manifest at $1/.claude/wurk.json opts in: parallelism.model
# is worktree-per-issue and parallelism.main_checkout_owned is true. Text
# matching over the file with whitespace removed; an absent or unreadable
# file is "not opted in".
opted_in() {
  manifest="$1/.claude/wurk.json"
  [ -r "$manifest" ] || return 1
  section=$(tr -d ' \t\r\n' < "$manifest" 2>/dev/null \
    | sed -n 's/.*"parallelism":{\([^}]*\)}.*/\1/p')
  [ -n "$section" ] || return 1
  has "$section" '"model":"worktree-per-issue"' || return 1
  has "$section" '"main_checkout_owned":true' || return 1
  return 0
}

check_command() {
  cmd="$1"; cwd="$2"
  [ -n "$cmd" ] || return 0
  has "$cmd" 'git' || return 0
  targets=$(tree_changing_targets "$cmd")
  [ -n "$targets" ] || return 0

  printf '%s\n' "$targets" | {
    while IFS= read -r target; do
      case "$target" in
        .) dir="$cwd" ;;
        /*) dir="$target" ;;
        *) dir="$cwd/$target" ;;
      esac
      if is_main_checkout "$dir" && opted_in "$main_top"; then
        deny "$OWNED_REASON"
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
# Builds throwaway repositories under a fresh temp dir (git's global and
# system config ignored): an opted-in main checkout with one linked
# worktree, a main checkout whose manifest does not set the owned key, and
# one that sets it under branch-in-place. Then re-execs this script with
# each fixture on stdin. `allow` expects no output; `deny` expects a deny
# decision whose reason names the fix. Nothing outside the temp dir is read
# or written, and no guarded command is ever run.

self_test() {
  failures=0
  self="$0"
  case "$self" in /*) ;; *) self="$(pwd)/$self" ;; esac

  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t worktreeescapeguard) || { echo "FAIL setup: mktemp"; exit 1; }
  trap 'rm -rf "$tmp"' EXIT
  GIT_CONFIG_NOSYSTEM=1; GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  main="$tmp/main"; wt="$tmp/wt"; free="$tmp/free"; bip="$tmp/bip"; plain="$tmp/plain"
  mkdir -p "$main" "$free" "$bip" "$plain"
  for r in "$main" "$free" "$bip"; do
    if ! { git -C "$r" init -q \
        && git -C "$r" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init; } >/dev/null 2>&1; then
      echo "FAIL setup: could not build the repository fixture"
      exit 1
    fi
    mkdir -p "$r/.claude"
  done
  if ! git -C "$main" worktree add -q -b wt "$wt" >/dev/null 2>&1; then
    echo "FAIL setup: could not build the linked-worktree fixture"
    exit 1
  fi
  printf '{\n  "wurk": 1,\n  "parallelism": {\n    "model": "worktree-per-issue",\n    "worktrees_dir": "../wt",\n    "main_checkout_owned": true\n  }\n}\n' > "$main/.claude/wurk.json"
  printf '{\n  "wurk": 1,\n  "parallelism": {\n    "model": "worktree-per-issue",\n    "worktrees_dir": "../wt"\n  }\n}\n' > "$free/.claude/wurk.json"
  printf '{\n  "wurk": 1,\n  "parallelism": {\n    "model": "branch-in-place",\n    "main_checkout_owned": true\n  }\n}\n' > "$bip/.claude/wurk.json"
  # the linked worktree carries the same manifest, as a tracked one would
  mkdir -p "$wt/.claude" && cp "$main/.claude/wurk.json" "$wt/.claude/wurk.json"

  fixture() { printf '{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" "$2"; }

  expect() {
    kind="$1"; name="$2"; out="$3"
    case "$kind" in
      allow)
        if [ -z "$out" ]; then echo "PASS allow: $name"; else echo "FAIL allow: $name (got: $out)"; failures=$((failures + 1)); fi ;;
      deny)
        if printf '%s' "$out" | grep -q '"permissionDecision":"deny"' \
          && printf '%s' "$out" | grep -q 'Fix:' \
          && printf '%s' "$out" | grep -qF "bead's worktree"; then
          echo "PASS deny: $name"
        else
          echo "FAIL deny: $name (got: ${out:-nothing})"; failures=$((failures + 1))
        fi ;;
    esac
  }

  run() { printf '%s' "$(fixture "$1" "$2")" | "$self"; }

  changes='git checkout a1b2c3d|git checkout main|git checkout -b x|git checkout -- README.md|git switch x|git switch -c x|git reset --hard|git reset --hard HEAD~1|git reset HEAD~1|git stash|git stash -u|git stash push -m x|git stash pop|git add -A && git checkout main'

  # denied in the opted-in main checkout, and in a subdirectory of it
  old_ifs=$IFS; IFS='|'
  for c in $changes; do
    IFS=$old_ifs
    expect deny "owned main checkout: $c" "$(run "$main" "$c")"
  done
  IFS=$old_ifs
  expect deny "owned main checkout, from a subdir: git checkout x" "$(run "$main/.claude" 'git checkout x')"

  # -C reaching into the owned main checkout is denied from anywhere
  expect deny "linked worktree: git -C <main> checkout x" "$(run "$wt" "git -C $main checkout x")"
  expect deny "not a repo: git -C <main> reset --hard" "$(run "$plain" "git -C $main reset --hard")"
  expect deny "not a repo: relative -C into main" "$(run "$tmp" 'git -C main switch x')"

  # allowed in a linked worktree, and in main checkouts that did not opt in
  IFS='|'
  for c in $changes; do
    IFS=$old_ifs
    expect allow "linked worktree: $c" "$(run "$wt" "$c")"
    expect allow "not opted in: $c" "$(run "$free" "$c")"
    expect allow "branch-in-place: $c" "$(run "$bip" "$c")"
  done
  IFS=$old_ifs
  expect allow "owned main checkout: git -C <wt> checkout x" "$(run "$main" "git -C $wt checkout x")"

  # reading, and index-only commands, are untouched in the owned checkout
  for c in 'git show HEAD' 'git log --oneline' 'git diff main...HEAD' 'git status' \
           'git stash list' 'git stash show -p' 'git reset' 'git reset -- README.md' \
           'git worktree add ../look a1b2c3d' 'cat checkout.txt'; do
    expect allow "owned main checkout: $c" "$(run "$main" "$c")"
  done

  # fail open
  expect allow "non-Bash tool" "$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"git checkout x"}}' | "$self")"
  expect allow "no tool_input" "$(printf '%s' '{"tool_name":"Bash"}' | "$self")"
  expect allow "garbage stdin" "$(printf '%s' 'not json {{{' | "$self")"
  expect allow "empty stdin" "$("$self" </dev/null)"
  expect allow "cwd that does not exist" "$(run "$tmp/nope" 'git checkout x')"

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

#!/bin/sh
# hooks/scratch-rm-guard.sh - PreToolUse hook (matcher: Bash) that denies
# a recursive rm over a directory other sessions keep their scratch work
# in, and says in the denial how to fix it.
#
# Sessions dispatched from one parent share a scratchpad root: each one's
# scratchpad is a directory under a common parent, and that parent usually
# sits in the system temp dir. A cleanup written as `rm -rf <root>/*` from
# one agent deletes every sibling's work along with its own, and nothing
# about the command looks wrong to the agent that runs it.
#
# The rules, applied to every recursive rm (-r, -R, -rf, -fr, -Rf, a
# separate -r beside -f, --recursive; flag order does not matter) and to
# each of its operands after a trailing glob component is stripped (so
# `<dir>/*` and `<dir>/claude-*` are judged as `<dir>`):
#
#   - deny when the target is the system temp root (/tmp, /var/tmp) or
#     $TMPDIR itself - including a glob directly under one of them;
#   - deny when the target is a PARENT of the session's own scratchpad.
#
# Deleting inside one's own scratchpad (`rm -rf <scratchpad>/build`, and
# `<scratchpad>/*`, which strips to the scratchpad itself, not a parent)
# and deleting a project build dir stay allowed. A non-recursive rm is
# never judged.
#
# Where the scratchpad comes from - never a hardcoded host path:
#
#   1. $WURK_SCRATCHPAD_DIR, when the environment the hook runs in sets
#      it: the target is a parent when the scratchpad path starts with it.
#   2. Otherwise, the input's `session_id`: a harness keeps per-session
#      state in a directory named after the session id, and the
#      scratchpad lives under it. The target is a parent when it is that
#      directory, or when a directory named for the session id exists one
#      or two levels below it. The
#      hook only tests for the directory's existence; it reads nothing in
#      it.
#
# Both are compared lexically and, when the target exists, by its physical
# path too (`cd && pwd -P`), so a temp dir reached through a symlink
# (/tmp on some systems is one) is still recognized.
#
# Installed by `ruby install.rb --with hooks` (opt-in; the default install
# never touches hooks) as ~/.claude/hooks/wurk-scratch-rm-guard.sh and
# wired by hand into settings.json under PreToolUse with matcher "Bash" -
# the installer prints the snippet and never edits settings itself.
#
# Harness contract: the same as hooks/safe-wait-guard.sh. PreToolUse
# receives JSON on stdin with `cwd`, `session_id`, `tool_name` and
# `tool_input.command`; a deny is exit 0 with a hookSpecificOutput
# permissionDecision "deny". A relative target is resolved against the
# input's `cwd`, falling back to the hook's own working directory.
#
# Scope: compound commands are split on &&, ||, ;, |, & and newlines and
# each piece is read on its own. This is simple splitting over the command
# text, not a shell parser: a quoted operand containing a space or a
# separator can split wrongly, a `cd` earlier in the command is not
# followed, and of the variables only $TMPDIR, ${TMPDIR}, $HOME, ${HOME}
# and a leading ~ are expanded - an operand naming any other variable is
# not judged. The hook evaluates the command; it never runs it.
#
# Fail-open: this hook never exits non-zero. If the input cannot be read
# or the command cannot be extracted, it prints nothing and exits 0, and
# the tool call proceeds.
#
# Portability: POSIX sh, coreutils, grep, sed and awk. No other
# dependencies.
#
#   hooks/scratch-rm-guard.sh --self-test   # hermetic PASS/FAIL cases

set +e

# No double quotes or newlines in a reason: it goes into JSON verbatim.
TEMP_REASON="recursive rm over the system temp root or TMPDIR itself: other sessions and tools keep live work there, and a glob directly under it reaches all of them. Fix: name the one directory you created (rm -rf <your-dir>), or delete inside your own scratchpad."
PARENT_REASON="recursive rm over a parent of this session's scratchpad: sibling sessions dispatched from the same parent keep their scratchpads beside yours, so this deletes their work too. Fix: delete inside your own scratchpad only (rm -rf <scratchpad>/<dir>), never the directory that holds it."

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

# One line per operand of every RECURSIVE rm in the command, with its
# quote characters removed (so '<dir>'/* reads as <dir>/*). Leading env assignments and the wrappers
# sudo, command, exec, nohup and time are skipped; `rm` may be spelled
# with a path (/bin/rm). Options end at `--`; redirections are dropped.
rm_targets() {
  printf '%s\n' "$1" | awk '
    function unquote(s) {
      gsub(/["\047]/, "", s)
      return s
    }
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
        i = 1
        while (i <= k && (t[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || t[i] ~ /^(sudo|command|exec|nohup|time)$/)) i++
        if (i > k || (t[i] != "rm" && t[i] !~ /\/rm$/)) continue
        rec = 0; nops = 0; opts = 1
        for (j = i + 1; j <= k; j++) {
          tok = t[j]
          sub(/[)}]+$/, "", tok)
          if (tok == "") continue
          if (tok ~ /^[0-9]*[<>]/) continue
          if (opts && tok == "--") { opts = 0; continue }
          if (opts && tok == "--recursive") { rec = 1; continue }
          if (opts && tok ~ /^--/) continue
          if (opts && tok ~ /^-[A-Za-z]+$/) { if (tok ~ /[rR]/) rec = 1; continue }
          ops[++nops] = unquote(tok)
        }
        if (rec) for (j = 1; j <= nops; j++) print ops[j]
      }
    }
  ' 2>/dev/null
}

# Lexical normalization of an absolute path: collapses //, . and .., and
# drops a trailing slash. "/" stays "/".
normalize() {
  printf '%s\n' "$1" | awk '{
    n = split($0, p, "/"); k = 0
    for (i = 1; i <= n; i++) {
      if (p[i] == "" || p[i] == ".") continue
      if (p[i] == "..") { if (k > 0) k--; continue }
      out[++k] = p[i]
    }
    s = ""
    for (i = 1; i <= k; i++) s = s "/" out[i]
    print (s == "" ? "/" : s)
  }' 2>/dev/null
}

# The physical path of an existing directory, or nothing.
physical() {
  [ -n "$1" ] && [ -d "$1" ] || return 0
  (cd "$1" 2>/dev/null && pwd -P) 2>/dev/null
}

# True when $2 is strictly below $1 (both normalized, absolute).
is_parent_of() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  [ "$1" != "$2" ] || return 1
  [ "$1" = "/" ] && return 0
  case "$2" in "$1"/*) return 0 ;; esac
  return 1
}

# The judged form of one operand: variables expanded, made absolute
# against the cwd, a trailing glob component stripped, normalized. Prints
# nothing for an operand the hook cannot evaluate (another variable, a
# command substitution).
resolve_target() {
  t="$1"; cwd="$2"
  case "$t" in
    '~') t="$HOME" ;;
    '~/'*) t="$HOME/${t#\~/}" ;;
  esac
  if [ -n "${TMPDIR:-}" ]; then
    t=$(printf '%s' "$t" | sed -e "s|\\\${TMPDIR}|$TMPDIR|g" -e "s|\\\$TMPDIR|$TMPDIR|g")
  fi
  if [ -n "${HOME:-}" ]; then
    t=$(printf '%s' "$t" | sed -e "s|\\\${HOME}|$HOME|g" -e "s|\\\$HOME|$HOME|g")
  fi
  case "$t" in *'$'*|*'`'*) return 0 ;; esac
  [ -n "$t" ] || return 0
  case "$t" in /*) ;; *) [ -n "$cwd" ] || return 0; t="$cwd/$t" ;; esac
  t=$(printf '%s' "$t" | sed -e 's|/*$||')
  last="${t##*/}"
  case "$last" in *'*'*|*'?'*|*'['*) t="${t%/*}" ;; esac
  [ -n "$t" ] || t="/"
  normalize "$t"
}

# True when $1 (normalized) is a temp root, lexically or physically.
is_temp_root() {
  target="$1"; tphys="$2"
  for root in /tmp /var/tmp "${TMPDIR:-}"; do
    [ -n "$root" ] || continue
    rlex=$(normalize "$root"); rphys=$(physical "$root")
    for cand in "$target" "$tphys"; do
      [ -n "$cand" ] || continue
      [ "$cand" = "$rlex" ] && return 0
      [ -n "$rphys" ] && [ "$cand" = "$rphys" ] && return 0
    done
  done
  return 1
}

# True when $1 (normalized) holds the session's scratchpad below it.
is_scratch_parent() {
  target="$1"; tphys="$2"; sid="$3"
  if [ -n "${WURK_SCRATCHPAD_DIR:-}" ]; then
    case "$WURK_SCRATCHPAD_DIR" in
      /*)
        slex=$(normalize "$WURK_SCRATCHPAD_DIR"); sphys=$(physical "$WURK_SCRATCHPAD_DIR")
        for cand in "$target" "$tphys"; do
          [ -n "$cand" ] || continue
          is_parent_of "$cand" "$slex" && return 0
          [ -n "$sphys" ] && is_parent_of "$cand" "$sphys" && return 0
        done
        ;;
    esac
    return 1
  fi
  case "$sid" in ''|*/*|.|..) return 1 ;; esac
  [ -d "$target" ] || return 1
  [ "${target##*/}" = "$sid" ] && return 0
  [ -d "$target/$sid" ] && return 0
  for d in "$target"/*/"$sid"; do
    [ -d "$d" ] && return 0
  done
  return 1
}

check_command() {
  cmd="$1"; cwd="$2"; sid="$3"
  [ -n "$cmd" ] || return 0
  has "$cmd" 'rm' || return 0
  targets=$(rm_targets "$cmd")
  [ -n "$targets" ] || return 0

  printf '%s\n' "$targets" | {
    while IFS= read -r op; do
      [ -n "$op" ] || continue
      target=$(resolve_target "$op" "$cwd")
      [ -n "$target" ] || continue
      tphys=$(physical "$target")
      if is_temp_root "$target" "$tphys"; then
        deny "$TEMP_REASON"; exit 0
      fi
      if is_scratch_parent "$target" "$tphys" "$sid"; then
        deny "$PARENT_REASON"; exit 0
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
  sid=$(extract_field "$input" session_id) || sid=""
  check_command "$cmd" "$cwd" "$sid"
  exit 0
}

# --- self-test ------------------------------------------------------------
# Builds a throwaway tree under a fresh temp dir - a shared scratch root
# holding this session's directory and a sibling's, a project with a
# build dir, and a stand-in TMPDIR - then re-execs this script with each
# fixture on stdin. `allow` expects no output; `deny` expects a deny
# decision whose reason names the fix. No rm is ever run against any of
# it: the hook only evaluates the command text. The one rm here is the
# trap that removes the temp dir this test created.

self_test() {
  failures=0
  self="$0"
  case "$self" in /*) ;; *) self="$(pwd)/$self" ;; esac

  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t scratchrmguard) || { echo "FAIL setup: mktemp"; exit 1; }
  trap 'rm -rf "$tmp"' EXIT
  tmp=$(cd "$tmp" && pwd -P)
  sid="sess-0001"
  root="$tmp/root"; proj="$tmp/proj"; fake_tmpdir="$tmp/tmpdir"
  scratch="$root/project-slug/$sid/scratchpad"
  mkdir -p "$scratch/sub" "$root/project-slug/sess-0002/scratchpad" "$proj/_build" "$fake_tmpdir" \
    || { echo "FAIL setup: mkdir"; exit 1; }

  fixture() {
    # $2 is placed in a JSON string: escape \ and " the way a harness would.
    c=$(printf '%s' "$2" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    printf '{"session_id":"%s","hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$sid" "$1" "$c"
  }

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

  # Session-id discovery, with WURK_SCRATCHPAD_DIR unset.
  run() { printf '%s' "$(fixture "$1" "$2")" | env -u WURK_SCRATCHPAD_DIR TMPDIR="$fake_tmpdir" "$self"; }
  # The explicit scratchpad from the environment.
  run_env() { printf '%s' "$(fixture "$1" "$2")" | env WURK_SCRATCHPAD_DIR="$scratch" TMPDIR="$fake_tmpdir" "$self"; }

  # parent of the scratchpad, any flag order, by both sources
  for c in "rm -rf $root" "rm -fr $root/project-slug" "rm -R $root" "rm --recursive $root" \
           "rm -r -f $root/project-slug/$sid" "rm -f -r $root"; do
    expect deny "scratch parent (session id): $c" "$(run "$proj" "$c")" "sibling sessions"
    expect deny "scratch parent (env): $c" "$(run_env "$proj" "$c")" "sibling sessions"
  done
  expect deny "glob over the scratch root: rm -rf root/*" "$(run "$proj" "rm -rf $root/*")" "sibling sessions"
  expect deny "glob over the scratch root, quoted, env" "$(run_env "$proj" "rm -rf '$root/project-slug'/*")" "sibling sessions"
  expect deny "relative parent of the scratchpad" "$(run "$scratch" 'rm -rf ../..')" "sibling sessions"

  # the system temp root and TMPDIR
  expect deny "system temp root: rm -rf /tmp" "$(run "$proj" 'rm -rf /tmp')" "temp root"
  expect deny "glob under the temp root: rm -rf /tmp/*" "$(run "$proj" 'rm -rf /tmp/*')" "temp root"
  expect deny "glob under the temp root: rm -fr /var/tmp/claude-*" "$(run "$proj" 'rm -fr /var/tmp/claude-*')" "temp root"
  expect deny 'quoted $TMPDIR' "$(run "$proj" 'rm -rf "$TMPDIR"')" "temp root"
  expect deny 'glob under ${TMPDIR}' "$(run "$proj" 'rm -rf ${TMPDIR}/*')" "temp root"
  expect deny "TMPDIR by its path, after a cd" "$(run "$proj" "cd /x && rm -rf $fake_tmpdir/")" "temp root"

  # allowed: inside one's own scratchpad, a project build dir, non-recursive
  expect allow "inside own scratchpad" "$(run "$proj" "rm -rf $scratch/sub")"
  expect allow "inside own scratchpad, env" "$(run_env "$proj" "rm -rf $scratch/sub")"
  expect allow "glob inside own scratchpad" "$(run_env "$proj" "rm -rf $scratch/*")"
  expect allow "glob inside own scratchpad, session id" "$(run "$proj" "rm -rf $scratch/*")"
  expect allow "project build dir (relative)" "$(run "$proj" 'rm -rf _build')"
  expect allow "project build dir (absolute)" "$(run "$proj" "rm -rf $proj/_build && ls")"
  expect allow "own dir under TMPDIR" "$(run "$proj" 'rm -rf "$TMPDIR/my-build-1"')"
  expect allow "non-recursive rm of a glob under the temp root" "$(run "$proj" 'rm -f /tmp/*')"
  expect allow "non-recursive rm of the scratch root glob" "$(run "$proj" "rm $root/*")"
  expect allow "a path that merely contains rm" "$(run "$proj" "ls $root && git rm -r --cached x")"
  expect allow "unexpanded variable" "$(run "$proj" 'rm -rf "$OTHER_DIR"')"

  # fail open
  expect allow "non-Bash tool" "$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"rm -rf /tmp"}}' | "$self")"
  expect allow "no tool_input" "$(printf '%s' '{"tool_name":"Bash"}' | "$self")"
  expect allow "garbage stdin" "$(printf '%s' 'not json {{{' | "$self")"
  expect allow "empty stdin" "$("$self" </dev/null)"

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

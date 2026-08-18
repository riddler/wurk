---
date: 2026-08-17
planner: Claude
git_commit: cb3ad01bb889c81a2b04de3452654ffa43e8d5f6
branch: wu-aqy-tmux-session-per-issue
repository: wurk
beads_issue: wu-aqy
topic: "tmux session-per-issue layout for wurk:branch"
tags: [plan, kit, skills, tmux, manifest]
status: ready
last_updated: 2026-08-17
last_updated_by: Claude
---

# tmux session-per-issue layout Implementation Plan

## Overview

Add a second tmux topology to the kit: instead of one manifest-named session
accumulating one window per issue, each issue gets its own tmux *session*
named `<bead-id>-<slug>` - the same string that names the branch and the
worktree - containing an optional editor window and a `claude` window running
the seeded session. The layout is selected by a new `tmux.layout` manifest
enum whose default reproduces today's behavior byte for byte, and the editor
comes from a new optional `tmux.editor` argv. Beads issue: `wu-aqy`.

## Current State Analysis

The kit has exactly one tmux topology and does not name it anywhere. All of
its mechanics live in `skills/wurk:kit/scripts/tmux_window.rb`, whose six
subcommands split into two groups:

- **Session-addressing** - `ensure-session` (`tmux_window.rb:282-336`) and
  `open` (`:340-417`). These are the only two that read
  `manifest.tmux_session`, and the only two gated on the manifest having a
  `tmux` section at all (`tmux_not_configured`, `:136-149`).
- **Session-agnostic** - `find` (`:421-461`), `classify` (`:465-511`),
  `quiesce` (`:515-568`), `close` (`:572-618`). These work purely from a tmux
  window id and never consult the manifest.

`open` composes the launched command in exactly one place, `claude_command`
(`:157-160`): `caffeinate_prefix + "claude --permission-mode auto --model
<tmux.model> '<body>'"`, sent with `send-keys` after `new-window -d -P -F
'#{window_id}'`. There is no notion of any other command being launched in a
workspace - no editor, no second window.

The manifest side is thin: `KNOWN["tmux"] = %w[session model]`
(`lib/manifest.rb:77`), three accessors (`:405-415`), no `DEFAULTS` entries,
no `ENUMS` entries, no `validate_tmux`. `docs/manifest.md` gives tmux four
lines inside the schema fence (`:93-96`), one per-repo table row (`:527`) and
one absence-rule mention (`:595`), and no `##` subsection.

The seeding sequence is skill prose: `/wurk:branch` step 2
(`skills/wurk:branch/SKILL.md:100-118`) runs `ensure-session` then
`open [--no-finish] <name> <path> <id> <seed>`. `/wurk:cleanup` steps 2-3
(`skills/wurk:cleanup/SKILL.md:93-145`) run `find` -> `classify` ->
`quiesce` -> `close`.

What is missing: any concept of a layout, of a second window in a workspace,
of an editor command, or of a session as the per-issue unit.

Key constraints discovered:

- `find` matches on window **name and pane path together** (`:438-443`) and
  blocks `ambiguous_window_match` on two hits (`:453-457`). Under the new
  layout the claude window is named `claude` in *every* per-issue session and
  the editor window shares its pane path, so today's matcher would hit the
  ambiguity block on every session-per-issue workspace.
- The script's header rule (`:18-21`): never `kill-pane`, never
  `kill -9`/SIGKILL; a quiesce timeout is `blocked`, never escalated.
  `kill-window` on a window whose every pane is already a bare shell is
  carved out as not that rule, because it targets nothing alive.
- The empty-window-id trap (`:395-405`): an empty `-t ""` resolves to the
  *current* window, which cost a live window on 2026-08-02.
- Manifest commands are argv arrays, never shell strings
  (`lib/manifest.rb:531-537`, `docs/manifest.md:606-645`) - "a shell string
  is a schema error, never something to split on whitespace".

## Desired End State

A project that sets nothing new behaves exactly as it does today. A project
that sets `"tmux": {"layout": "session-per-issue", "model": "opus", "editor":
["nvim"]}` gets, per `/wurk:branch` invocation, a detached tmux session named
`<bead-id>-<slug>` containing a window named `nvim` running `nvim` in the
worktree and a window named `claude` running the seeded claude command; and
`/wurk:cleanup` finds, quiesces, and closes that claude window and then
garbage-collects the session when nothing alive remains in it.

Verification:

- `ruby skills/wurk:kit/scripts/test/run.rb` green at every phase.
- `ruby skills/wurk:kit/scripts/lib/manifest.rb check` reports valid against
  each fixture manifest, including the new session-per-issue one.
- The default-path tests in `tmux_window_test.rb` that assert exact argv
  (`=zz-session`, `new-window ... -n <name>`) are unchanged and still pass -
  the mechanical proof that the default path did not move.
- `ruby skills/wurk:kit/scripts/tmux_window.rb open --dry-run <name> <path>
  <id> <seed>` against a session-per-issue manifest renders exactly three
  commands - a `new-session` naming the editor window and carrying the
  editor argv, a `new-window` for claude, and a `send-keys` - and executes
  nothing. Against the same manifest with `tmux.editor` removed it renders
  exactly two: a `new-session` naming the claude window, and a `send-keys`.

### Key Discoveries:

- `skills/wurk:kit/scripts/tmux_window.rb:132-149` - the session-addressing
  vs session-agnostic split is the seam the layout switch has to respect.
- `skills/wurk:kit/scripts/tmux_window.rb:157-160` - `claude_command` is the
  single convergence point for the launched command line; the editor must not
  fork it.
- `skills/wurk:kit/scripts/lib/manifest.rb:56-62, 77, 84-99` - the enum,
  known-key and defaults registries a `tmux.layout` slots into unchanged.
- `skills/wurk:kit/scripts/lib/manifest.rb:365-368` (`trust_argv`) - the
  exact accessor shape an optional argv field uses: `value && argv(value)`.
- `skills/wurk:kit/scripts/lib/manifest.rb:544` (`COMMAND_FIELDS`) - adding
  `tmux.editor` here gets argv-shape validation with no new validator.
- `skills/wurk:kit/scripts/test/manifest_test.rb:937-950` - the every-fixture
  schema check that catches a `KNOWN`/`ENUMS` edit made in only one place.
- `skills/wurk:kit/scripts/test/contract_test.rb:153-159` - the consumer
  vocabulary list bans consumer repo names, mix/exunit vocabulary and
  statifier corpus dirs. It does **not** ban `nvim`; see Decision 8.
- ADR-0004 (`docs/adr/0004-manifest-and-extension-seams.md`) - structural
  choices belong in the manifest as explicit enums. `tmux.layout` is exactly
  that shape; this plan adds a field rather than forking a skill, which is
  what the ADR requires.
- ADR-0006 (`docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`) -
  the script contract; `contract_test.rb:691-709` re-parses its banned list
  on every run.

## What We're NOT Doing

- **Not making the editor window optional per invocation.** There is no
  `--no-editor` flag. Omitting `tmux.editor` from the manifest is the only
  way to skip the editor window, per the bead.
- **Not adding a `kill-pane`, `kill -9`, or forced `kill-session` path.**
  Session teardown inherits the existing all-bare-shell precondition
  verbatim. A session holding a live editor is kept and reported, exactly as
  a window holding a live pane is today.
- **Not changing `classify` or `quiesce`.** Both are already window-id-only
  and layout-blind; nothing about them needs to know which session a window
  lives in.
- **Not implementing `branch-in-place`.** It remains unimplemented and its
  refusal in `/wurk:branch` stands.
- **Not renaming `tmux_window.rb`.** The file now manages sessions as well as
  windows under one layout, and a rename would touch every skill, script and
  test that references it (CLAUDE.md's rename rule) for no behavior change.
  A header comment records the widened scope instead.
- **Not adding a doc/code sync test for `docs/manifest.md`.** None exists
  today; the discipline is CLAUDE.md's hard rule plus review. Adding one is a
  separate bead, not a rider on this one.
- **Not migrating this repo's own `.claude/wurk.json` to the new layout.**
  The manifest change is opt-in and the repo's own workflow is not part of
  this bead's acceptance. Switching it is a one-line follow-up once the
  feature has been exercised by hand.

## Implementation Approach

Four phases, ordered so that each leaves the tree committable and the gate
green, and so that the default path is proven untouched before anything
consumes the new field.

Phase 1 lands the schema alone: the enum, the argv field, the accessors, the
validation, the fixture, the tests, and `docs/manifest.md` in the same commit
(CLAUDE.md's sync rule). Nothing reads the field yet.

Phase 2 teaches the seeding half (`ensure-session`, `open`) the new layout.
Phase 3 teaches the cleanup half (`find`, `close`). They are separate commits
because they touch disjoint regions of the script with disjoint tests, and
each is independently gate-verifiable; the intermediate state between them is
reachable only by a project that has opted into a layout the docs do not yet
tell it to use, which is why Phase 4 is where the layout becomes documented
as usable.

Phase 4 lands the skill prose for `/wurk:branch` and `/wurk:cleanup` plus the
kit REFERENCE note, gated by the contract test's markdown scans.

### Decisions taken

The research document ended with eight open questions. All eight are resolved
here; no human was available, so each carries its rationale.

1. **What closes a per-issue session** - `close` gains an optional
   `--session <name>` flag. Its existing behavior is untouched: kill the
   window only when every pane in it is a bare shell. When `--session` is
   given and the kill succeeded, `close` then lists the session's remaining
   windows and issues `tmux kill-session -t =<session>` **only if every pane
   of every remaining window is a bare shell**, reusing `bare_shell_panes?`
   unchanged. Otherwise it reports `data.session_closed: false, reason:
   "session kept, other windows busy"`. Rationale: this is the same carve-out
   the header already grants `kill-window` - it targets nothing alive - lifted
   one level. A live editor is not a bare shell, so an editor with unsaved
   buffers always keeps its session. Note that in the common case the
   question does not arise: the editor is launched as `new-window`'s command
   argument, so when the editor exits its window closes, and killing the last
   window ends the session by itself.

2. **What `find` matches under session-per-issue** - `find` becomes
   layout-aware. Under `window-per-issue` (and whenever the manifest has no
   `tmux` section) it is byte-identical to today: `tmux list-panes -a -F
   '#{window_id} #{window_name} #{pane_current_path}'`, matching name and
   path together. Under `session-per-issue` it uses a wider format,
   `'#{window_id} #{session_name} #{window_name} #{pane_current_path}'`, and
   matches `session_name == <name> && window_name == "claude" && pane path ==
   <path>` - which returns the claude window and deliberately never the
   editor window. `find` reads the manifest through `Manifest.require!` and
   treats an absent `tmux` section as `window-per-issue`; it never blocks
   `tmux_not_configured`, because `find`'s no-block posture is what makes
   `/wurk:cleanup` safe on projects with no tmux at all. The
   `ambiguous_window_match` block stays and still fires on two hits, which is
   the correct outcome in the pathological case of a consumer whose editor
   window is itself named `claude`.

3. **Whether the duplicate guard moves to the session name** - yes, under
   `session-per-issue`. `open`'s guard becomes `tmux has-session -t =<name>`;
   a hit returns `data.skipped: true` with reason `"session <name> already
   exists"` and creates nothing. Rationale: the per-issue session name is the
   unique key under this layout exactly as the window name is under the
   other, and the guard keeps the same shape as `worktree_create.rb`'s
   branch/directory guards - a hit is a normal outcome, never a reason to
   create a second one.

4. **Whether `tmux.session` stays meaningful** - it stays the schema's home
   for the shared session and becomes conditionally required.
   `validate_tmux` requires `tmux.session` when the section is present and
   the layout is `window-per-issue` (including by default), and permits its
   absence under `session-per-issue`, where the per-issue session name comes
   from the workspace name. If a `session-per-issue` project *does* set
   `tmux.session`, the value is simply unused by the per-issue path and is
   reported as such in the envelope (`data.session_name_unused: true` from
   `ensure-session`) rather than silently ignored. Rationale: capability
   absence is reported, never guessed (`docs/manifest.md:594-604`), and a
   prefix scheme was rejected because the bead states the session is named
   *what the window would have been*, with no prefix.

5. **How the editor is launched** - as `new-window`'s command argument, not
   `send-keys`: `tmux new-window -d -P -F '#{window_id}' -t =<session>: -n
   <editor-name> -c <path> -- <editor argv...>`. Rationale: (a) the manifest
   hands the kit an argv array and tmux accepts argv directly, so nothing has
   to be joined into a shell string - joining it would be exactly the
   whitespace concatenation the argv schema rule exists to prevent; (b) when
   the editor exits, its window closes on its own, which is both the natural
   signal that the editor is gone and the reason session teardown is usually
   a non-event. The claude command keeps `send-keys` unchanged, because it is
   composed as one shell string with the caffeinate prefix and a quoted seed
   body. The editor window's name is `File.basename(argv.first)` - derived,
   so no editor name ever appears in kit source or generic skill prose. The
   editor's working directory is the worktree, via the same `-c <path>` the
   claude window already uses.

6. **Which end of the contract owns the two-window sequence** - the script.
   `open` stays the single seeding call and grows the layout branch
   internally; `/wurk:branch`'s two-line call sequence is unchanged, and
   `ensure-session` becomes a reporting no-op under `session-per-issue` so no
   conditional is needed in prose. Rationale: the layout is behavior, not a
   value, and the kit owns tmux mechanics. A flag on `open` or two extra
   skill-level calls would both force skill prose to read `tmux.layout` and
   branch on it, which puts a structural switch in markdown where nothing
   tests it.

7. **Whether `docs/manifest.md` gains a `## tmux` subsection** - yes. A
   layout enum plus an optional editor argv is the first tmux material with
   behavior worth prose, and every field with real prose
   (`gate.sabotage:253`, `judge:324`, `rebase.auto_resolve_paths:354`,
   `gate.cwd:403`) has one. The subsection states what each layout produces,
   what omitting `editor` does, and what `session` means under each layout.

8. **How `tmux.editor` avoids the consumer-vocabulary scan** - it already
   does; no scan change is needed. `CONSUMER_VOCABULARY`
   (`contract_test.rb:153-159`) bans statifier corpus dirs, elixir gate
   config filenames, `mix` gate commands, the ExUnit `test "` macro, and the
   three consumer repo names. An editor binary matches none of them. The
   markdown scans glob `skills/wurk:*/SKILL.md` and target
   `skills/wurk:kit/REFERENCE.md`; `docs/manifest.md` is not scanned at all,
   which is why it may already name `statifier-ex` in its examples. The rule
   this plan therefore adopts and states in the code: a concrete editor argv
   may appear in a fixture manifest and in `docs/manifest.md`'s schema
   example; kit source and generic skill markdown name only the field
   `tmux.editor` and never a concrete editor binary, and the kit ships no
   default editor.

---

## Phase 1: Manifest schema for `tmux.layout` and `tmux.editor`

### Overview

Add the enum, the optional argv field, the accessors, the conditional
`session` requirement, the doc, and the fixture. Nothing consumes the new
fields yet; the phase's value is that the schema is settled and validated
before any behavior depends on it.

### Changes Required:

#### 1. Manifest registries and accessors
**File**: `skills/wurk:kit/scripts/lib/manifest.rb`
**Changes**: register the enum, the default, the known keys, the argv command
field, two accessors, and one validator.

```ruby
# ENUMS (:56-62) - add:
"tmux.layout" => %w[window-per-issue session-per-issue],

# KNOWN (:77) - replace:
"tmux" => %w[session model layout editor],

# DEFAULTS (:84-99) - add:
"tmux.layout" => "window-per-issue",

# COMMAND_FIELDS (:544) - append "tmux.editor" so validate_commands
# enforces the argv-array-of-strings rule with no new validator.

# accessors, beside tmux_model (:413-415):
def tmux_layout
  fetch("tmux.layout")
end

# Optional argv, same shape as trust_argv (:365-368): absent stays nil,
# present is held to the argv rule rather than split on whitespace.
def tmux_editor_argv
  value = fetch("tmux.editor")
  value && argv(value)
end

# validate! list (:551-562) - add validate_tmux

# tmux.session is required under window-per-issue because ensure-session and
# open address the session by name; under session-per-issue the per-issue
# session name comes from the workspace name, so session may be absent.
def validate_tmux
  return unless tmux?
  return unless fetch("tmux.layout") == "window-per-issue"

  session = fetch("tmux.session")
  return if session.is_a?(String) && !session.empty?

  errors << "#{path}: tmux.session is required under tmux.layout " \
            "window-per-issue, got #{session.inspect}"
end
```

Note that `DEFAULTS["tmux.layout"]` makes `tmux_layout` resolve to
`"window-per-issue"` even with no `tmux` section at all; every call site
guards on `tmux?` or treats the default as today's behavior, so that is
harmless and keeps the accessor total.

#### 2. Fixture manifest
**File**: `skills/wurk:kit/scripts/test/fixtures/manifests/tmux_session_per_issue.json`
**Changes**: new fixture, a copy of `tmux.json` whose tmux section is:

```json
"tmux": {
  "layout": "session-per-issue",
  "model": "fakemodel",
  "editor": ["nvim"]
}
```

It deliberately omits `session`, which is what exercises Decision 4. It is
not added to `DELIBERATELY_INVALID`, so
`test_every_valid_fixture_manifest_satisfies_the_schema`
(`manifest_test.rb:937-950`) validates it with zero warnings.

#### 3. Manifest tests
**File**: `skills/wurk:kit/scripts/test/manifest_test.rb`
**Changes**: add, each with the `sabotage: ... -> red` comment the file's
archetype uses (`:58-74`):

- absent `tmux.layout` defaults to `window-per-issue` (against `tmux`).
- an unrecognized `tmux.layout` blocks rather than defaulting, modeled on
  `test_unknown_enum_value_blocks_rather_than_defaulting` (`:59-63`).
- `tmux_editor_argv` is nil against `tmux`, `["nvim"]` against
  `tmux_session_per_issue`.
- a shell-string `tmux.editor` (`"nvim"`) is a validation error naming
  `tmux.editor`, via `load_with`.
- `tmux.session` absent under `window-per-issue` is a validation error.
- `tmux.session` absent under `session-per-issue` is valid.
- `tmux_layout` against the `valid` fixture (no tmux section) is
  `"window-per-issue"` and `tmux?` is still false.

#### 4. Manifest documentation
**File**: `docs/manifest.md`
**Changes**: in the schema fence (`:93-96`), extend the tmux block:

```
  "tmux": {                           // (opt) omit = no tmux integration
    "layout": "window-per-issue",     // (opt) or "session-per-issue"; see ## tmux
    "session": "statifier-ex",        // required under window-per-issue
    "model": "opus",                  // model for seeded worktree sessions
    "editor": ["nvim"]                // (opt) session-per-issue only; omit = no editor window
  },
```

Add a `## tmux` subsection after `## gate.cwd` (`:403`) covering: what each
layout produces; that `session` names the shared session under
`window-per-issue` and is unused under `session-per-issue`; that `editor` is
an argv array launched in the worktree as the window's command, with the
window named after the argv's first element's basename; and that omitting
`editor` skips the editor window entirely. Update the per-repo table row
(`:527`) and the absence rule at `:595` to mention that a `tmux` section with
no `layout` is `window-per-issue`. **Also append `tmux.layout` =
`window-per-issue` to the defaults enumeration under `## Required, optional,
and defaults` (`docs/manifest.md:585-592`)** - that list names every
`DEFAULTS` entry by hand, and a new `DEFAULTS` key that does not appear
there is exactly the drift CLAUDE.md's same-commit sync rule exists to
prevent.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] `ruby skills/wurk:kit/scripts/lib/manifest.rb check --file
      skills/wurk:kit/scripts/test/fixtures/manifests/tmux_session_per_issue.json`
      exits 0 with `data.valid: true` and an empty `warnings` array
- [x] `ruby skills/wurk:kit/scripts/lib/manifest.rb check` on this repo's own
      `.claude/wurk.json` still exits 0 with no new warnings
- [x] The new fixture file exists at the path above
- [x] `git diff --stat` for the commit shows `lib/manifest.rb` and
      `docs/manifest.md` both present (CLAUDE.md's same-commit sync rule)
- [x] Every key in `Manifest::DEFAULTS` appears in `docs/manifest.md`'s
      defaults enumeration - check with
      `ruby -r./skills/wurk:kit/scripts/lib/manifest -e 'd=File.read("docs/manifest.md"); miss=Manifest::DEFAULTS.keys.reject { |k| d.include?(k) }; abort(miss.inspect) unless miss.empty?'`

#### Manual Verification:
- [ ] `docs/manifest.md`'s `## tmux` prose matches what `lib/manifest.rb`
      actually validates, field for field
- [ ] The schema-fence comments read consistently with the `(opt)` convention
      the rest of the fence uses
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: Seeding side - `ensure-session` and `open` under session-per-issue

### Overview

Teach the two session-addressing subcommands the layout. Under
`window-per-issue` every rendered argv stays byte-identical, which the
existing tests already assert.

### Changes Required:

#### 1. `ensure-session` becomes a reporting no-op under the new layout
**File**: `skills/wurk:kit/scripts/tmux_window.rb`
**Changes**: after `tmux_manifest(env)` succeeds (`:290`), branch on layout
before touching `tmux_session`.

```ruby
if manifest.tmux_layout == "session-per-issue"
  # Nothing to ensure: each workspace's session is created by `open`, named
  # after the workspace. Reported rather than silently skipped so the caller
  # can say what happened, and so a stray tmux.session under this layout is
  # visible instead of quietly ignored.
  env.data["layout"] = "session-per-issue"
  env.data["created"] = false
  env.data["skipped"] = true
  env.data["reason"] = "session-per-issue: each workspace gets its own session"
  env.data["session_name_unused"] = !blank?(manifest.tmux_session)
  return env.emit(io)
end
env.data["layout"] = "window-per-issue"
# ... existing body unchanged
```

#### 2. `open` grows a session-per-issue branch
**File**: `skills/wurk:kit/scripts/tmux_window.rb`
**Changes**: keep the existing body as the `window-per-issue` path verbatim;
add a sibling path. Shared: the strict arity check, `claude_command`, the
empty-window-id trap, and the `send_keys_failed` warning.

```ruby
CLAUDE_WINDOW_NAME = "claude"

# session-per-issue: the workspace name IS the session name (wu-aqy). The
# duplicate guard is has-session rather than a window-name scan, because the
# session is this layout's unique key - same shape as worktree_create.rb's
# branch/directory guards.
#
# `new-session` always creates a first window, so it is used AS the first
# window rather than leaving an unnamed one behind. With an editor
# configured that first window is the editor; with none it is claude, and
# the session has exactly one window. Never three.
#
# With tmux.editor configured - three commands after the guard:
#   tmux has-session -t =<name>                       -> skip if it exists
#   tmux new-session -d -s <name> -c <path> -n <editor> -- <editor argv...>
#   tmux new-window  -d -P -F '#{window_id}' -t =<name>: -n claude -c <path>
#   tmux send-keys   -t <claude window id> <keys> Enter
#
# With no tmux.editor - two commands after the guard:
#   tmux has-session -t =<name>                       -> skip if it exists
#   tmux new-session -d -P -F '#{window_id}' -s <name> -c <path> -n claude
#   tmux send-keys   -t <claude window id> <keys> Enter
```

Details that must hold:

- `new-session` unavoidably creates a first window, so that window is
  *used*, never left over: with an editor configured the session is created
  as `-n <editor_name>` with the editor argv as its command, so window 1 is
  the editor; with no editor configured the session is created as
  `-n claude` and the claude keys go to it. A session-per-issue workspace
  therefore has exactly two windows with an editor and exactly one without,
  matching the Overview - there is never an orphaned default window.
- The editor window name is `File.basename(editor_argv.first)`. No editor
  name is ever written in this file.
- The claude window id is captured from `new-window -P -F '#{window_id}'`
  in the editor case, and from `new-session -P -F '#{window_id}'` in the
  no-editor case. **Verify the second form against a real tmux before
  relying on it**: `new-session -P` prints the session name by default, and
  while `-F` is documented to override the format, this plan has not
  exercised `-F '#{window_id}'` on `new-session` the way it is exercised
  daily on `new-window`. If it does not yield a window id, fall back to
  `tmux list-windows -t =<name> -F '#{window_id}'` immediately after the
  create - never to an empty id. Either way the captured id goes through
  the same empty-id trap before any `-t` command is issued. This is
  non-negotiable; the trap is why it exists.
- `--dry-run` renders every argv above in order, with `$win` standing in for
  the captured id exactly as the current dry run does, and executes nothing.
- Envelope data: `layout`, `session` (the per-issue session name), `name`,
  `path`, `model`, `no_finish`, `skipped`, `window_id` (the claude window),
  and `editor_window_id` (nil when no editor is configured).

#### 3. Header comment
**File**: `skills/wurk:kit/scripts/tmux_window.rb`
**Changes**: extend the module header (`:9-21`) to record that the script now
manages a session per workspace under one layout, that the kill rules apply
unchanged, and that no default editor exists in this file by design.

#### 4. Tests
**File**: `skills/wurk:kit/scripts/test/tmux_window_test.rb`
**Changes**: add a `TmuxWindowSessionPerIssueTest` class with the same
`FakeSh` + `sleep_fn` setup. Note that `TmuxWindowTest#run_tmux`
(`tmux_window_test.rb:125`) already takes a `fixture:` keyword defaulting to
`FIXTURE = "tmux"`, so the new class differs from the existing one only in
which fixture it passes - no helper needs to change. Cases:

- `ensure-session` under session-per-issue issues **no** tmux command and
  reports `skipped: true` with the layout.
- `open` creates the session (as the editor window) then the claude window,
  in that order, with the exact argv above - and issues no third
  `new-window`.
- the editor window is named from the argv's basename.
- with no `tmux.editor` (via `load_with` dropping the key) `open` issues a
  single `new-session -n claude` and no `new-window` at all.
- the editor argv is passed as the window's command, never joined into a
  send-keys string (assert no `send-keys` carries the editor argv).
- an existing session of that name skips, creating nothing.
- an empty captured window id blocks `window_id_empty` and issues no
  `send-keys`.
- the seeded claude command is byte-identical to the window-per-issue one
  (same `claude_command`, same finishing clause, same `--model fakemodel`).
- dry run renders the full sequence and issues no commands.
- **regression**: the existing `TmuxWindowTest` cases are untouched and still
  assert `=zz-session` and today's exact argv.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] Every pre-existing test in `tmux_window_test.rb` passes with its
      assertions unmodified (verified by `git diff` showing no deletions or
      edits inside `class TmuxWindowTest`)
- [x] `contract_test.rb`'s `test_no_consumer_vocabulary_in_kit_source` and
      `test_banned_kill_operations_appear_only_in_the_forbidding_comment`
      pass
- [x] `grep -n 'nvim\|vim\|emacs\|code ' skills/wurk:kit/scripts/tmux_window.rb`
      returns nothing

#### Manual Verification:
- [ ] Against a scratch session-per-issue manifest, `open --dry-run` renders
      a pasteable three-command sequence in the right order (two with
      `tmux.editor` removed)
- [ ] Running that sequence by hand in tmux produces a detached session named
      for the workspace with the editor window first and `claude` second, both
      rooted in the worktree
- [ ] The seeded claude window is live and in auto permission mode (this is
      the case `docs/plan.md:539-553` records as deliberately never smoke-run
      automatically, because it launches a real session)
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: Cleanup side - `find` disambiguation and session teardown

### Overview

Make `find` return the right window under session-per-issue and give `close`
an opt-in session teardown that inherits the all-bare-shell precondition.
`classify` and `quiesce` are not touched.

### Changes Required:

#### 1. `find` becomes layout-aware without becoming blocking
**File**: `skills/wurk:kit/scripts/tmux_window.rb`
**Changes**: read the manifest through `Manifest.require!` (not
`tmux_manifest`, which blocks), default a missing tmux section to
`window-per-issue`, and select the matcher.

```ruby
# find stays non-blocking on purpose: /wurk:cleanup calls it on every
# candidate, including in projects with no tmux section at all, and a block
# there would stop a sweep that has nothing to do with tmux. The only thing
# it needs from the manifest is the layout.
manifest = Manifest.require!(env)
layout = manifest&.tmux? ? manifest.tmux_layout : "window-per-issue"

if layout == "session-per-issue"
  # The claude window is named `claude` in every per-issue session and the
  # editor window shares its pane path, so name+path no longer discriminates.
  # The session name does: it is the workspace name. Matching the session and
  # the window name together returns the claude window and never the editor's.
  fmt = '#{window_id} #{session_name} #{window_name} #{pane_current_path}'
  # match: sname == name && wname == CLAUDE_WINDOW_NAME && wpath == path
else
  # unchanged
  fmt = '#{window_id} #{window_name} #{pane_current_path}'
  # match: wname == name && wpath == path
end
```

Envelope data gains `session` (the matched session name, nil under
window-per-issue) and `session_scoped` (true only under session-per-issue).
`found`, `window_id` and the `ambiguous_window_match` block keep their exact
current semantics.

#### 2. `close --session`
**File**: `skills/wurk:kit/scripts/tmux_window.rb`
**Changes**: add the flag via `Cli.build`'s block, leaving every existing
code path unchanged. After the `kill-window` succeeds:

```ruby
# Session teardown is the same carve-out kill-window already has, one level
# up: it is only ever issued against a session with nothing alive in it.
# `tmux list-panes -s -t =<session> -F '#{pane_current_command}'` covers
# every pane of every remaining window; bare_shell_panes? is reused, not
# reimplemented, so the definition of "nothing alive" cannot fork. A pane
# running an editor is not a bare shell, which is exactly why an editor with
# unsaved buffers keeps its session.
```

- A session that no longer exists after the window kill (the last window went
  with it) reports `session_closed: true, reason: "session ended with its
  last window"` and issues no kill-session.
- A session with a live pane reports `session_closed: false, reason: "session
  kept, other windows busy"`.
- A `kill-session` failure is a **warning** (`kill_session_failed`), matching
  how `kill_window_failed` is handled - the removal already stands.
- `--dry-run` renders the `list-panes -s` and the conditional `kill-session`
  and executes nothing.
- Without `--session`, `close` is byte-identical to today.

#### 3. Tests
**File**: `skills/wurk:kit/scripts/test/tmux_window_test.rb`
**Changes**: add to the session-per-issue class:

- `find` under session-per-issue returns the claude window and not the editor
  window when both share a pane path.
- `find` under session-per-issue still blocks `ambiguous_window_match` on two
  matching claude windows.
- `find` with no tmux section in the manifest behaves exactly as today and
  does not block.
- `find` returns `session` and `session_scoped` correctly under each layout.
- `close --session` kills the session when every remaining pane is a bare
  shell.
- `close --session` keeps the session when a remaining pane is an editor.
- `close --session` never issues `kill-session` when the window kill itself
  did not happen.
- `close` without `--session` issues no session command at all.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] The pre-existing `find` and `close` tests in `TmuxWindowTest` pass with
      their assertions unmodified
- [x] `test_banned_kill_operations_appear_only_in_the_forbidding_comment`
      passes with `kill-session` present in the file
- [x] `grep -n 'kill-pane\|kill -9\|SIGKILL' skills/wurk:kit/scripts/tmux_window.rb`
      shows only comment lines

#### Manual Verification:
- [ ] With a real two-window per-issue session, `find <name> <path>` returns
      the claude window id, not the editor's
- [ ] `close --session <name> <window_id>` against a session whose editor is
      still running kills the claude window and leaves the session and the
      editor alone
- [ ] The same call against a session with only bare shells left removes the
      session
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 4: Skill prose and kit reference

### Overview

Document the layout where the operators of the workflow read it, and teach
`/wurk:cleanup` to pass `--session` when `find` says the match was session
scoped. `/wurk:branch`'s call sequence does not change; its result-reading
and report do.

### Changes Required:

#### 1. `/wurk:branch`
**File**: `skills/wurk:branch/SKILL.md`
**Changes**: step 2 (`:100-118`) keeps its two commands verbatim; add a
paragraph stating that the topology is the manifest's `tmux.layout` and that
the script handles both - under `session-per-issue` `ensure-session` reports
that it had nothing to do and `open` creates the workspace's own session with
an optional editor window. In "How to read the result" (`:153-165`) add:
`data.layout`, `data.session`, and `data.editor_window_id` feed the report;
`data.skipped: true` now means "a window or a session of this name already
exists" depending on the layout, and is still a normal outcome. In the
report section (`:167-176`) state the session name alongside the window when
the layout is session-per-issue.

#### 2. `/wurk:cleanup`
**File**: `skills/wurk:cleanup/SKILL.md`
**Changes**: step 2 (`:93-123`) gains one sentence: carry `data.session`
forward alongside `data.window_id` when `data.session_scoped` is true. Step 3
(`:125-145`) changes the close invocation to:

```bash
ruby ~/.claude/skills/wurk:kit/scripts/tmux_window.rb close [--session <session>] <window_id>
```

with prose: pass `--session` only when step 2 reported `data.session_scoped:
true`, using the `data.session` it returned. Add `data.session_closed: false`
with `reason: "session kept, other windows busy"` to the list of normal
outcomes, beside the existing window-kept one. The skill reads these from the
envelope; it never reads `tmux.layout` itself.

#### 3. Kit reference
**File**: `skills/wurk:kit/REFERENCE.md`
**Changes**: extend the tmux mention at `:59` so the stated rule covers the
new field surface: no `tmux` section still blocks the session-addressing
subcommands; `tmux.layout` selects the topology and defaults to
`window-per-issue`; `tmux.editor` is an argv array and its absence means no
editor window. Keep it to prose - no shell fence naming a concrete editor,
since `REFERENCE.md`'s command blocks are scanned.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] `contract_test.rb`'s `test_markdown_scans_cover_every_shipped_skill`,
      `test_no_consumer_vocabulary_in_skill_markdown` and
      `test_no_consumer_vocabulary_in_kit_reference_command_blocks` pass
- [x] `grep -rn 'nvim\|emacs' skills/` returns nothing

#### Manual Verification:
- [ ] `/wurk:branch` prose read end to end still describes one unconditional
      two-command sequence, with no manifest branching asked of the model
- [ ] `/wurk:cleanup` prose makes the `--session` condition decidable purely
      from the `find` envelope
- [ ] An operator reading `docs/manifest.md`'s `## tmux` plus these two skills
      can turn on session-per-issue without reading the script
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Testing Strategy

### Unit Tests:

- `skills/wurk:kit/scripts/test/manifest_test.rb` - the enum default, the
  enum rejection, the argv shape, the shell-string rejection, and the
  conditional `tmux.session` requirement. Each carries the `sabotage: ... ->
  red` comment naming the branch a mutant would remove, matching the file's
  archetype at `:58-74`.
- `skills/wurk:kit/scripts/test/tmux_window_test.rb` - a new
  session-per-issue class against the new fixture, covering the full seeding
  sequence, the editor-argv-as-command rule, the no-editor case, the session
  duplicate guard, the empty-window-id trap, the `find` disambiguation, and
  `close --session` in both outcomes. The existing `TmuxWindowTest` class is
  the regression net for the default layout and must not be edited.
- `skills/wurk:kit/scripts/test/manifest_test.rb:937-950` - the every-fixture
  schema check picks up the new fixture automatically and is what catches a
  `KNOWN`/`ENUMS` edit made in only one place.
- Key edge cases: an editor argv whose first element is a path
  (`/usr/local/bin/nvim` -> window named `nvim`); a session-per-issue
  manifest that also sets `tmux.session` (valid, unused, reported); a
  `tmux.editor` of `[]` (rejected by the argv rule, which requires non-empty).

### Manual Testing Steps:

1. Point a scratch manifest at `session-per-issue` with an editor argv and
   run `tmux_window.rb ensure-session` - confirm it issues nothing and
   reports the layout.
2. Run `tmux_window.rb open --dry-run <name> <worktree-path> <id> "<seed>"`
   and read the rendered sequence.
3. Paste that sequence into a shell and confirm the session, the two windows,
   their names, and both working directories.
4. Attach to the session, confirm the editor is live in window 1 and the
   seeded claude session is live in window 2.
5. Exit the editor; confirm its window closes on its own.
6. Run `tmux_window.rb find <name> <worktree-path>` and confirm it returns
   the claude window id with `session_scoped: true`.
7. Quiesce and `close --session <name> <window_id>`; confirm the session is
   gone.
8. Repeat step 7 with the editor still running; confirm the claude window
   dies and the session and editor survive.
9. Switch the scratch manifest back to no `layout` key and confirm
   `ensure-session` and `open --dry-run` render exactly what they render on
   `main`.

## References

- Source document: `docs/research/260817-wu-aqy-tmux-session-per-issue-layout.md`
- Related ADRs: `docs/adr/0004-manifest-and-extension-seams.md`,
  `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`,
  `docs/adr/0009-upstream-beads-without-a-workspace.md`
- Similar implementation: `skills/wurk:kit/scripts/lib/manifest.rb:365-368`
  (optional argv accessor), `skills/wurk:kit/scripts/lib/manifest.rb:643-666`
  (`validate_gate_cwd`, the shape-only optional-field validator),
  `skills/wurk:kit/scripts/worktree_create.rb:23-93` (guard-and-skip shape)
- Prior art for adding a field to a structural section rather than forking:
  `docs/plans/260817-wu-9fb-subdirectory-gate-cwd.md`
- Bead: `wu-aqy`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] `docs/manifest.md`'s `## tmux` prose matches what `lib/manifest.rb`
      actually validates, field for field
- [ ] The schema-fence comments read consistently with the `(opt)` convention
      the rest of the fence uses
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 2

- [ ] Against a scratch session-per-issue manifest, `open --dry-run` renders
      a pasteable three-command sequence in the right order (two with
      `tmux.editor` removed)
- [ ] Running that sequence by hand in tmux produces a detached session named
      for the workspace with the editor window first and `claude` second, both
      rooted in the worktree
- [ ] The seeded claude window is live and in auto permission mode (this is
      the case `docs/plan.md:539-553` records as deliberately never smoke-run
      automatically, because it launches a real session)
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 3

- [ ] With a real two-window per-issue session, `find <name> <path>` returns
      the claude window id, not the editor's
- [ ] `close --session <name> <window_id>` against a session whose editor is
      still running kills the claude window and leaves the session and the
      editor alone
- [ ] The same call against a session with only bare shells left removes the
      session
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 4

- [ ] `/wurk:branch` prose read end to end still describes one unconditional
      two-command sequence, with no manifest branching asked of the model
- [ ] `/wurk:cleanup` prose makes the `--session` condition decidable purely
      from the `find` envelope
- [ ] An operator reading `docs/manifest.md`'s `## tmux` plus these two skills
      can turn on session-per-issue without reading the script
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

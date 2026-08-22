---
date: 2026-08-22
planner: Claude
git_commit: 36edae26b69f71995faf1a8dc79ace8f33453cb4
branch: wu-jhb-machine-level-permission-mode
repository: wurk
beads_issue: wu-jhb
topic: "Machine-level config source for the seeded session's permission mode"
tags: [plan, kit, docs, tmux, manifest, config]
status: ready
last_updated: 2026-08-22
last_updated_by: Claude
---

# Machine-level permission mode config Implementation Plan

## Overview

Move the seeded session's permission mode out of the checked-in project
manifest and into a new machine-level config source the kit reads from the
user's home directory. This introduces wurk's first user-level config seam,
so the plan settles its path, schema, precedence, and absent-safe behavior
deliberately rather than incidentally. Beads issue: wu-jhb

## Current State Analysis

`tmux.permission_mode` landed one commit ago in wu-b7f (36edae2) and lives
entirely inside the manifest seam:

- `skills/wurk:kit/scripts/lib/manifest.rb:63` - the enum
  (`auto default acceptEdits plan skip-permissions`).
- `skills/wurk:kit/scripts/lib/manifest.rb:79` - `permission_mode` in
  `KNOWN["tmux"]`.
- `skills/wurk:kit/scripts/lib/manifest.rb:103` - `DEFAULTS` entry, `"auto"`.
- `skills/wurk:kit/scripts/lib/manifest.rb:432-434` -
  `Manifest#tmux_permission_mode`.
- `skills/wurk:kit/scripts/tmux_window.rb:185-189` - `claude_command` takes
  the value and builds the flag; `skills/wurk:kit/scripts/tmux_window.rb:425`
  and `:519` are the two call sites (window-per-issue `open` and
  session-per-issue `open`).
- `docs/manifest.md:98`, `:493-506`, `:635` and
  `skills/wurk:kit/REFERENCE.md:66-68` document it.
- `skills/wurk:kit/scripts/test/manifest_test.rb:636-658` and
  `skills/wurk:kit/scripts/test/tmux_window_test.rb:514-538` cover it.

What is missing is any user-level config source at all. `Manifest.locate`
(`skills/wurk:kit/scripts/lib/manifest.rb:146-155`) walks up from the working
directory for `.claude/wurk.json` and, failing that, asks git for the main
checkout. Nothing in the kit reads `$HOME`. The one place in the repo that
does is `install.rb:220`, which resolves it as `ENV["HOME"] || Dir.home` and
exposes a `--home DIR` override so the install is testable against a tmpdir.

Constraints discovered:

- ADR-0004 declares exactly two seams, "both in the consumer repo". A
  machine-level source is a third seam outside the consumer repo, so it is an
  ADR-level decision, not a quiet addition.
- ADR-0006 / `skills/wurk:kit/REFERENCE.md` - stdlib-only system Ruby, one
  JSON envelope on stdout, exit 0/1/2, `--dry-run` on every mutating script,
  all shell-outs through `lib/sh.rb`.
- `CLAUDE.md` - `docs/manifest.md` and `lib/manifest.rb` must change in the
  same commit; kit scripts carry no consumer-project constants; plain ASCII
  punctuation; commit titles under 50 chars in simple present tense.
- The manifest's unknown-key rule (`docs/manifest.md:650-655`) warns rather
  than blocks, which is what makes retiring a field non-breaking.
- No consumer sets `tmux.permission_mode` today. This repo's own
  `.claude/wurk.json` does not, and the value appears nowhere outside the
  files listed above.
- `skills/wurk:kit/scripts/test/run.rb` globs `**/*_test.rb`, so a new test
  file is picked up with no registration.

## Desired End State

A machine-level config file at `~/.claude/wurk.local.json`, read by a new
`skills/wurk:kit/scripts/lib/user_config.rb`, is the only source of the
seeded session's permission mode. `tmux.permission_mode` no longer exists in
the manifest schema; a manifest that still sets it gets a warning naming its
replacement, and the value has no effect.

Verify by: with no `~/.claude/wurk.local.json`, `tmux_window.rb open --dry-run`
still composes `claude --permission-mode auto --model <model> '<seed>'`; with
`{"tmux": {"permission_mode": "acceptEdits"}}` in that file it composes
`--permission-mode acceptEdits`; with `"skip-permissions"` it composes
`--dangerously-skip-permissions` and no `--permission-mode`; with `"yolo"` it
blocks with a message naming the field, the value, the allowed set, and the
file path, and issues no tmux command. `ruby skills/wurk:kit/scripts/test/run.rb`
is green throughout.

### Key Discoveries:

- The whole manifest-side surface is five small sites in one file
  (`skills/wurk:kit/scripts/lib/manifest.rb:63,79,103,432-434`), so retiring
  the field is a contained edit.
- `Manifest` already ships the exact shape a second config source wants:
  `current` / `reset!` / `current=` memoization with a test seam
  (`skills/wurk:kit/scripts/lib/manifest.rb:98-113`), `require!(env)` folding
  failures into the envelope (`:134-144`), `valid?` / `errors` / `warnings`,
  and a `check` CLI at the bottom of the file (`:929-984`). Mirroring it
  keeps one vocabulary rather than inventing a second.
- `install.rb:220`'s `ENV["HOME"] || Dir.home` is the existing precedent for
  home resolution and gives tests a seam without a bespoke mechanism.
- `ManifestHelper` (`skills/wurk:kit/scripts/test/support/manifest_helper.rb`)
  is the model for the new test helper: `with_manifest` swaps the memoized
  instance and restores it in an `ensure`.
- ADR-0004 is the decision this amends; ADR-0006 is the contract the new file
  must satisfy. Next free ADR number is 0013.

## What We're NOT Doing

- **Not keeping `tmux.permission_mode` as a project-level default the machine
  config overrides.** The bead's premise is that permission mode is not a
  property of the project, and a checked-in default still forces a choice on
  every engineer who has not written a machine config - the exact complaint.
  Keeping both would also mean a precedence rule to document, test, and get
  wrong, for a field no consumer sets today. It is retired outright.
- **Not bumping `Manifest::SCHEMA_VERSION`.** Removing a key from `KNOWN`
  demotes it to a warning, which is already the schema's forward-compat
  behavior; bumping the version would hard-fail every consumer over a field
  none of them set. ADR-0004's Consequences say manifest schema changes "get
  versioned via the manifest's `wurk` field", and this is a deliberate,
  noticed continuation of existing practice rather than an unremarked
  deviation: `SCHEMA_VERSION` has stayed at 1 across every schema-growing
  change this repo has shipped, because `validate_version` treats the field
  as a hard equality check and any bump is a simultaneous break for all
  consumers. The retirement is handled by the warning path instead, which is
  the mechanism the schema already has for exactly this.
- **Not generalizing the machine config beyond one key.** The file's schema
  is shaped so more machine-level keys can land later, but this bead adds
  exactly `tmux.permission_mode` and nothing else.
- **Not touching `install.rb`.** The bead flags that seeding a default local
  config might pull in area:install. It does not: the file is absent-safe by
  design, so there is nothing to seed, and installing a config file would
  make wurk write into a user's home beyond its own symlinks. The bead needs
  no relabel.
- **Not making the machine config discoverable by walk-up.** It is
  HOME-anchored only, so a stray `.claude/wurk.local.json` inside a repo is
  never read as machine config.
- **Not extending the enum.** The five values wu-b7f settled carry over
  unchanged.

## Implementation Approach

Three phases, ordered so every intermediate commit leaves the gate green.

Phase 1 adds `lib/user_config.rb` and its tests with no consumer. It is
independently gate-verifiable through its own unit tests, and landing it
alone keeps the seam's design reviewable on its own terms.

Phase 2 is deliberately one commit rather than three: it swaps
`tmux_window.rb` onto the new source, retires the manifest field, and moves
every doc. Splitting it would either leave `tmux_window.rb` calling a deleted
accessor (red gate) or break `CLAUDE.md`'s rule that `docs/manifest.md` and
`lib/manifest.rb` change together.

Phase 3 records ADR-0013. Doc-only, and last because an ADR should describe
what shipped.

---

## Phase 1: The machine-level config source

### Overview

Introduce `UserConfig`, the kit's first user-level config reader: locate,
parse, validate, and hand out typed values, with the same envelope
integration and test seams `Manifest` has. Nothing consumes it yet.

### Changes Required:

#### 1. The new library

**File**: `skills/wurk:kit/scripts/lib/user_config.rb` (new)
**Changes**: A `UserConfig` class mirroring `Manifest`'s public shape.

Resolution: `FILENAME = File.join(".claude", "wurk.local.json")`, resolved
against `ENV["HOME"] || Dir.home` and nothing else - no walk-up, no git. A
moduledoc states why: this file describes the machine and the person at it,
so a copy inside a checkout must never be picked up, and `.local.json`
follows the harness's own `settings.json` / `settings.local.json` convention
for "present on this machine, not checked in".

Schema, all keys optional:

```json
{
  "wurk": 1,
  "tmux": { "permission_mode": "acceptEdits" }
}
```

Constants, deliberately parallel to `Manifest`'s:

```ruby
SCHEMA_VERSION = 1
ENUMS = { "tmux.permission_mode" => %w[auto default acceptEdits plan skip-permissions] }.freeze
KNOWN = { nil => %w[wurk tmux], "tmux" => %w[permission_mode] }.freeze
DEFAULTS = { "tmux.permission_mode" => "auto" }.freeze
```

Behavior:

- Absent file: a valid instance whose every value is the `DEFAULTS` entry.
  No warning - absence is the normal case, not a degraded one.
- Unparseable JSON: blocks, message naming the path and the parser error.
  A typo in your own config must not silently revert you to `auto`.
- Top-level value that is not a JSON object: blocks, naming the path.
- `wurk` present and not `SCHEMA_VERSION`: blocks. Absent is fine, so the
  minimum useful file is one line.
- Unrecognized enum value: blocks, naming the dotted key, the value, and the
  allowed set - same message shape as `Manifest#validate_enums`, plus the
  file path.
- Unknown key: warns, same asymmetry and same reasoning as the manifest.

Class methods `current(home:)`, `reset!`, `current=`, `load(home:)`, and
`require!(env, home:)`. In every one of them `home:` **defaults to
`ENV["HOME"] || Dir.home`**, exactly as `Manifest.current` defaults
`start: Dir.pwd` (`skills/wurk:kit/scripts/lib/manifest.rb:102`) - so the
ordinary call is `UserConfig.require!(env)` and the keyword exists only as a
test seam. `require!` records errors on the envelope and returns nil,
mirroring `Manifest.require!`; warnings go on as `user_config_unknown_key`.

Instance methods `path`, `raw`, `errors`, `warnings`, `valid?`, `exists?`,
`fetch(dotted)`, and `tmux_permission_mode`.

#### 2. The standalone lint

**File**: `skills/wurk:kit/scripts/lib/user_config.rb`
**Changes**: A `UserConfigCli` at the bottom of the file, modeled on
`ManifestCli` (`skills/wurk:kit/scripts/lib/manifest.rb:929-984`):

```
ruby skills/wurk:kit/scripts/lib/user_config.rb check [--file PATH]
```

Emits the standard envelope with `data.path`, `data.exists`, `data.valid`,
`data.errors`, and `data.tmux_permission_mode` - the effective value, so the
command answers "what mode will my sessions get" in one shot. Exit 1 on an
invalid config, 0 otherwise. Read-only, so no `--dry-run`.

#### 3. Test support

**File**: `skills/wurk:kit/scripts/test/support/user_config_helper.rb` (new)
**Changes**: A `UserConfigHelper` module mirroring `ManifestHelper`:

- `with_user_config(hash_or_nil)` - installs a `UserConfig` built from the
  hash (or the absent-file instance for `nil`) as `UserConfig.current` for
  the block, restoring the previous value in an `ensure`.
- `in_tmp_home(hash_or_nil)` - a tmpdir with `.claude/wurk.local.json`
  written (or deliberately not written), `ENV["HOME"]` pointed at it for the
  block and restored afterward. This is what exercises real resolution rather
  than the injected seam.
- `write_raw_user_config(dir, string)` - for the unparseable-JSON case.

#### 4. Unit tests

**File**: `skills/wurk:kit/scripts/test/user_config_test.rb` (new)
**Changes**: Cover, each with a sabotage comment in this suite's existing
style:

- absent file -> `valid?`, `exists?` false, `tmux_permission_mode == "auto"`,
  no warnings;
- each of the five enum values round-trips through a real file in a tmp home;
- `"yolo"` -> invalid, message matches
  `/tmux\.permission_mode is "yolo"; expected one of auto, default, acceptEdits, plan, skip-permissions/`
  and includes the file path;
- unparseable JSON -> invalid, message names the path;
- non-object top level (`[]`) -> invalid;
- `{"wurk": 2}` -> invalid; `{"wurk": 1, ...}` -> valid; no `wurk` -> valid;
- unknown key (`{"nope": 1}`) -> valid with exactly one warning;
- a `.claude/wurk.local.json` inside the working directory, with `HOME`
  pointed elsewhere, is NOT read - the HOME-anchored rule;
- `require!` blocks the envelope on an invalid config and returns nil, and
  returns an instance with no envelope entries when the file is absent;
- the `check` CLI: exit 0 and `data.tmux_permission_mode` on a valid config,
  exit 1 with a `blocked` entry on an invalid one.

### Success Criteria:

#### Automated Verification:
- [x] `ruby skills/wurk:kit/scripts/test/run.rb` passes
- [x] `skills/wurk:kit/scripts/lib/user_config.rb` exists and requires only
      stdlib plus `lib/` siblings (`grep -n '^require' ` shows no gems)
- [x] `ruby skills/wurk:kit/scripts/lib/user_config.rb check` on a machine
      with no config file exits 0 and emits one JSON envelope whose
      `data.tmux_permission_mode` is `"auto"`
- [x] The contract test in the suite stays green (no banned calls, no
      consumer vocabulary, no `system`/backticks in the new file)

#### Manual Verification:
- [ ] Reading the new file beside `lib/manifest.rb`, the parallel is obvious
      enough that a future machine-level key has one clear place to go
- [ ] The block message for an invalid value reads clearly at a terminal:
      it names the file, the key, the bad value, and the allowed set
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: Wire it up, retire the manifest field, move the docs

### Overview

Point `tmux_window.rb` at `UserConfig`, remove `tmux.permission_mode` from
the manifest schema with a warning that names its replacement, and move every
doc in the same commit.

### Changes Required:

#### 1. tmux_window.rb

**File**: `skills/wurk:kit/scripts/tmux_window.rb`
**Changes**: `claude_command` keeps its `permission_mode` parameter and its
flag-building logic unchanged; only the source moves. Update its moduledoc
comment (currently `:179-184`) to say the value comes from
`UserConfig#tmux_permission_mode`, still validated against a known set before
it can reach a shell command line.

Add `require_relative "lib/user_config"` beside the existing requires.

Both `open` paths resolve the config where they already resolve the manifest,
so an invalid machine config blocks before any tmux command is issued:

```ruby
user_config = UserConfig.require!(env)
return env.emit(io) unless user_config
```

and then at `:425` and `:519`:

```ruby
keys = claude_command(model, seed, id, manifest.trailer_key,
                      user_config.tmux_permission_mode,
                      no_finish: options[:no_finish])
```

The block must sit ahead of the `tmux new-window` / `tmux new-session`
shell-out, and ahead of the caffeinate probe, so a bad config costs nothing.

#### 2. manifest.rb

**File**: `skills/wurk:kit/scripts/lib/manifest.rb`
**Changes**: Remove the four wu-b7f sites - the `ENUMS` entry (`:63`),
`permission_mode` from `KNOWN["tmux"]` (`:79`), the `DEFAULTS` entry
(`:103`), and `#tmux_permission_mode` (`:432-434`).

Add a retired-key map and a validation pass over it, so a consumer that still
sets the field gets a message that points somewhere instead of the generic
"unknown key (ignored)":

```ruby
# Keys this schema used to carry. A consumer pinned to an older kit may
# still set one; the answer is a warning that names the replacement, not a
# block - removing a key can never be a reason to refuse to run.
RETIRED = {
  "tmux.permission_mode" =>
    "moved to the machine-level config (see docs/machine-config.md); " \
    "the manifest value is ignored"
}.freeze
```

`validate_retired` runs before `collect_unknown_keys` and suppresses the
generic unknown-key warning for a retired key, so exactly one warning is
emitted.

#### 3. Manifest tests

**File**: `skills/wurk:kit/scripts/test/manifest_test.rb`
**Changes**: Delete the three wu-b7f tests (`:636-658`). Add:

- a manifest setting `tmux.permission_mode` is still valid, and warns exactly
  once with a message naming the key and `docs/machine-config.md`;
- `Manifest` no longer responds to `tmux_permission_mode`;
- a genuinely unknown `tmux` key still gets the generic unknown-key warning,
  so the retired path did not swallow the general case.

#### 4. tmux_window tests

**File**: `skills/wurk:kit/scripts/test/tmux_window_test.rb`
**Changes**: Include `UserConfigHelper`; have `run_tmux` accept a
`user_config:` keyword defaulting to absent, wrapping the existing
`with_manifest` block in `with_user_config`. Replace the wu-b7f test
(`:514-538`) with:

- no machine config -> the existing `--permission-mode auto` command line,
  unchanged (this is the regression guard for absent-safety, and the existing
  command-line assertions elsewhere in the file already exercise it);
- one test per supported value, asserting the exact `send-keys` payload:
  `auto`, `default`, `acceptEdits`, `plan` each produce
  `--permission-mode <value>`, and `skip-permissions` produces
  `--dangerously-skip-permissions` with `refute_match(/--permission-mode/)`;
- an invalid value -> exit 1, a `blocked` entry naming
  `tmux.permission_mode`, and `assert_empty @fake.calls` (nothing shelled
  out, including the caffeinate probe);
- the same coverage for the session-per-issue `open` path, so both call sites
  are proven rather than one.

- a manifest that still sets `tmux.permission_mode` does not change the
  composed command line - the machine config, or its default, governs.

#### 5. New doc page

**File**: `docs/machine-config.md` (new)
**Changes**: The sibling page the bead invites, since the machine config is a
different seam from the manifest and not a section of it. Covers: what it is
and why permission mode is not a project property; the path
`~/.claude/wurk.local.json` and why it is HOME-anchored only; the schema with
the minimal one-line example; the full enum with the `skip-permissions`
special case; absent-safe behavior; validation rules (block vs warn), stated
to match `lib/user_config.rb` as authority; the `check` lint invocation; and
an explicit statement that it is never checked into a consumer repo and that
consumer projects have no say in it.

State precedence in one sentence: there is no precedence, because the
manifest no longer carries the field. Name the retirement and point at
`docs/manifest.md`.

#### 6. Manifest doc

**File**: `docs/manifest.md`
**Changes**: Remove the `permission_mode` line from the example (`:98`), the
`tmux.permission_mode` prose block (`:493-506`), and the defaults-list entry
(`:635`). Add a short "Retired keys" note under `## Validation` recording
that `tmux.permission_mode` existed in wu-b7f, moved in wu-jhb, now warns and
is ignored, and pointing at `docs/machine-config.md`.

#### 7. REFERENCE.md

**File**: `skills/wurk:kit/REFERENCE.md`
**Changes**: Drop the `tmux.permission_mode` clause (`:66-68`). Add a short
subsection under "The manifest is an input to the contract" naming the
machine config as the second input, its path, its reader, and its doc page -
scripts consume it exactly like the manifest, through a typed accessor, never
by reading `$HOME` themselves.

#### 8. Architecture doc

**File**: `docs/architecture.md`
**Changes**: Add the machine-level source to the layer diagram and a short
paragraph after the Layer 3 section: three inputs now, one of which lives
outside the consumer repo, and the rule for which is which - anything the
project decides goes in the manifest, anything the machine or the person at
it decides goes in the machine config.

### Success Criteria:

#### Automated Verification:
- [x] `ruby skills/wurk:kit/scripts/test/run.rb` passes
- [x] `grep -rn "tmux_permission_mode" skills/wurk:kit/scripts/lib/manifest.rb`
      returns nothing
- [x] `grep -rn "tmux.permission_mode" docs/manifest.md skills/wurk:kit/REFERENCE.md`
      returns only the retired-key note in `docs/manifest.md`
- [x] `ruby skills/wurk:kit/scripts/lib/manifest.rb check` on this repo exits
      0 with no warnings
- [x] `docs/machine-config.md` exists
- [x] Both `lib/manifest.rb` and `docs/manifest.md` are in the same commit
      (`git show --stat` lists both)

#### Manual Verification:
- [ ] With no `~/.claude/wurk.local.json`, a real
      `ruby skills/wurk:kit/scripts/tmux_window.rb open --dry-run ...` shows
      the unchanged `claude --permission-mode auto --model opus '...'` line
- [ ] Writing `{"tmux": {"permission_mode": "acceptEdits"}}` to
      `~/.claude/wurk.local.json` and re-running the dry run shows
      `--permission-mode acceptEdits`, with no repo change and nothing to
      commit
- [ ] Setting it to `"skip-permissions"` shows
      `--dangerously-skip-permissions` and no `--permission-mode`
- [ ] Setting it to `"yolo"` blocks with a message a human can act on, and
      opens no tmux window
- [ ] Restoring the file to absent restores the default, confirming the
      round trip is a one-line local edit
- [ ] `docs/machine-config.md` reads as a page someone new to wurk could
      follow without reading the code
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: ADR-0013, the machine-level config seam

### Overview

Record the third seam as a settled decision, so the next machine-level knob
cites a number instead of re-arguing the placement.

### Changes Required:

#### 1. The ADR

**File**: `docs/adr/0013-machine-level-config-seam.md` (new)
**Changes**: The repo's four-part ADR format (Status / Context / Decision /
Consequences), matching `docs/adr/0004-manifest-and-extension-seams.md`.

- **Context**: ADR-0004 settled two seams, both in the consumer repo, on the
  premise that everything a script needs is either a project constant or
  project domain prose. wu-b7f found a value that is neither: the seeded
  session's permission mode is a property of the machine and the person at
  it. Putting it in the manifest forces one setting on every engineer working
  the repo and makes changing it a commit.
- **Decision**: A third seam, `~/.claude/wurk.local.json`, read by
  `lib/user_config.rb`. HOME-anchored, absent-safe, validated on the same
  asymmetry as the manifest (unknown warns, enum blocks), documented in
  `docs/machine-config.md`. The placement rule: the manifest carries what the
  project decides, the machine config carries what the machine or the person
  at it decides, and a value that is genuinely both is a manifest field with
  a machine-level override - which nothing needs yet and which this ADR does
  not authorize in advance.
- **Consequences**: consumer repos never carry a permission-mode setting; a
  new machine onboards with zero files, because absent is the default; a
  fourth kind of value now has a home, so schema pressure has somewhere to go
  besides the manifest; and the kit gains a second config reader to keep in
  step with the first.

Status: `accepted (2026-08-22)`.

#### 2. Cross-references

**File**: `docs/machine-config.md`, `docs/architecture.md`
**Changes**: Cite ADR-0013 in both, one line each.

### Success Criteria:

#### Automated Verification:
- [ ] `ruby skills/wurk:kit/scripts/test/run.rb` passes (doc-only change; the
      gate must stay green)
- [ ] `docs/adr/0013-machine-level-config-seam.md` exists and contains the
      `Status:`, `## Context`, `## Decision`, `## Consequences` headings
- [ ] `grep -rn "ADR-0013" docs/` matches the ADR plus
      `docs/machine-config.md` and `docs/architecture.md`

#### Manual Verification:
- [ ] The ADR's placement rule is stated crisply enough to settle the next
      "manifest or machine config?" argument without reopening this one
- [ ] It amends rather than contradicts ADR-0004, and says so
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

- `skills/wurk:kit/scripts/test/user_config_test.rb` - resolution (absent,
  present, HOME-anchored, repo-local file ignored), parsing (valid,
  unparseable, non-object), validation (each enum value, invalid value,
  schema version, unknown key), the `require!` envelope integration, and the
  `check` CLI.
- `skills/wurk:kit/scripts/test/manifest_test.rb` - the retired key warns
  once and names its replacement; the accessor is gone; the generic
  unknown-key path still works.
- `skills/wurk:kit/scripts/test/tmux_window_test.rb` - the composed command
  line for absent config, for each of the five values, and for an invalid
  value (blocked, nothing shelled out), across both `open` paths.

Edge cases that get their own test rather than a comment: an empty file
(`""` is not valid JSON - blocks), `{}` (valid, all defaults), a
`.claude/wurk.local.json` in the working directory with `HOME` elsewhere, and
a manifest that still sets the retired key alongside a machine config that
sets a different value (the machine config wins, because the manifest field
no longer exists).

### Manual Testing Steps:

1. With no `~/.claude/wurk.local.json`, run
   `ruby skills/wurk:kit/scripts/lib/user_config.rb check` and confirm exit 0
   with `data.exists` false and `data.tmux_permission_mode` `"auto"`.
2. Run `tmux_window.rb open --dry-run` for a real worktree and confirm the
   command line is byte-identical to today's.
3. Write `{"tmux": {"permission_mode": "acceptEdits"}}` to
   `~/.claude/wurk.local.json`. Re-run the dry run; confirm the flag changed
   and `git status` in the repo is clean.
4. Change it to `"skip-permissions"`; confirm
   `--dangerously-skip-permissions` and the absence of `--permission-mode`.
5. Change it to `"yolo"`; confirm the block message and that no window opens.
6. Delete the file; confirm the default is back.
7. Add `"permission_mode": "plan"` to this repo's `.claude/wurk.json` `tmux`
   section, run the manifest lint, confirm the single warning naming
   `docs/machine-config.md`, then revert the manifest edit.

## Open Questions

These were decided by judgment during planning rather than confirmed with a
human, and are recorded here so the decision is visible and cheap to revisit.
None of them block implementation.

1. **The filename.** `~/.claude/wurk.local.json` was chosen over
   `~/.claude/wurk.json` (too easily confused with a consumer manifest, and
   `~/.claude` is not a checkout) and `~/.claude/wurk/config.json` (needs a
   directory, and `.claude/wurk/` already means "markdown extensions" in a
   consumer repo). The `.local.json` infix matches Claude Code's own
   `settings.json` / `settings.local.json` convention. Renaming later is a
   one-constant change plus its doc, since nothing external depends on it.
2. **Retire versus keep as a project default.** Settled as retire, for the
   reasons in "What We're NOT Doing". If a consumer later turns out to need a
   project-level floor on permission mode, that is a new bead and a new
   manifest field with a stated override rule, not a revival of this one.
3. **Blocking on unparseable JSON.** Chosen over warning-and-defaulting so a
   typo in your own config is loud. The cost is that a corrupt machine file
   stops `tmux_window.rb open` until it is fixed - acceptable, because the
   fix is a one-line local edit and the message names the file.
4. **Whether the `check` lint earns its keep.** It is ~30 lines mirroring
   `ManifestCli` and it gives the docs a single command that answers "what
   mode will my sessions get". Kept. If it is never used it can be dropped
   without touching the reader.

## References

- Bead: `wu-jhb`
- Preceding commit: `36edae2` (wu-b7f, added `tmux.permission_mode`)
- Related ADRs: `docs/adr/0004-manifest-and-extension-seams.md` (the two
  seams this amends), `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`
  (the contract the new script satisfies), `docs/adr/0002-standalone-repo-installed-by-symlink.md`
  (why `~/.claude` is wurk's install target)
- Schema authority: `skills/wurk:kit/scripts/lib/manifest.rb`,
  `docs/manifest.md`
- Similar implementation: `skills/wurk:kit/scripts/lib/manifest.rb:98-155`
  (memoized load, test seam, resolution), `:929-984` (the `check` CLI),
  `skills/wurk:kit/scripts/test/support/manifest_helper.rb` (the test helper
  to mirror), `install.rb:220` (home resolution precedent)
- Consumer sites: `skills/wurk:kit/scripts/tmux_window.rb:185`, `:425`, `:519`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Reading the new file beside `lib/manifest.rb`, the parallel is obvious
      enough that a future machine-level key has one clear place to go
- [ ] The block message for an invalid value reads clearly at a terminal:
      it names the file, the key, the bad value, and the allowed set
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

- [ ] With no `~/.claude/wurk.local.json`, a real
      `ruby skills/wurk:kit/scripts/tmux_window.rb open --dry-run ...` shows
      the unchanged `claude --permission-mode auto --model opus '...'` line
- [ ] Writing `{"tmux": {"permission_mode": "acceptEdits"}}` to
      `~/.claude/wurk.local.json` and re-running the dry run shows
      `--permission-mode acceptEdits`, with no repo change and nothing to
      commit
- [ ] Setting it to `"skip-permissions"` shows
      `--dangerously-skip-permissions` and no `--permission-mode`
- [ ] Setting it to `"yolo"` blocks with a message a human can act on, and
      opens no tmux window
- [ ] Restoring the file to absent restores the default, confirming the
      round trip is a one-line local edit
- [ ] `docs/machine-config.md` reads as a page someone new to wurk could
      follow without reading the code
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

# Campaign plan-to-machine binding Implementation Plan

## Overview

`campaign_state.rb` reports a plan as ARMED and RUNNABLE on every machine
that can see the file. On a fleet whose campaigns dir is shared through git
while the campaign mutexes live in a per-machine, gitignored locks dir, one
machine cannot tell another machine's in-flight campaign from an unclaimed
one: a scheduler acting on `runnable` would start a second conductor on a
campaign already running elsewhere, and a consumer that refuses on more than
one ARMED plan (`ambiguous_armed`) is permanently blocked. This plan adds an
opt-in plan-to-machine binding - a `Machine: <name>` line in the plan - that
`list` and `show` honor when computing `armed` and `runnable`, a
`machine`/`machine_match` pair on the campaign record so consumers filter on
data, a queue rule for a predecessor bound elsewhere, and an `arm --host`
writer that can only ever write this machine's own name.

Bead: wu-dtrb

## Current State Analysis

- There is no host concept anywhere in `campaign_state.rb`: `arm` takes no
  host flag and no line of a plan records a machine
  (`skills/wurk:kit/scripts/campaign_state.rb:274-312`).
- `armed` is `status == ARMED || (queued && queue.satisfied)` and `runnable`
  is `armed && consent.adopted && !running`
  (`campaign_state.rb:212-225`). `running` is a probe of the local locks dir
  only (`campaign_state.rb:204`, `:265-268`), so a campaign whose mutex is on
  another machine's disk always reads `running: false` here.
- A QUEUED plan is satisfied when its predecessor is WRAPPED and the
  predecessor's mutex is not live-held (`campaign_state.rb:242-256`). The
  mutex half of that check is the guard against starting inside the
  WRAPPED-while-still-holding window; for a predecessor that runs on another
  machine the check reads an empty local locks dir and passes vacuously.
- The script is "pure filesystem logic ... no Sh, no manifest"
  (`campaign_state.rb:24-26`); every path is a CLI argument. It reads no
  per-repo manifest, which matters because a fleet umbrella may carry only
  `wurk-fleet.json` and no `wurk.json`.
- The machine-name vocabulary already exists:
  `UserConfig#machine_name` returns `machine.name` from the HOME-anchored
  `~/.claude/wurk.local.json`, or nil when the file, the `machine` section,
  or the key is absent - by design, with no hostname fallback
  (`skills/wurk:kit/scripts/lib/user_config.rb:190-196`; schema in
  `docs/machine-config.md` "`machine`"; seam settled by ADR-0013).
- Other scripts load machine config through `UserConfig.require!(env)`,
  which blocks the envelope on an invalid file and adds
  `user_config_unknown_key` warnings (`lib/user_config.rb:100-111`; callers
  `lock.rb:66`, `gate_run.rb:122`, `bead.rb:521`).
- The test suite never sees the operator's real config:
  `test/support/home_guard.rb` points HOME at an empty tmpdir, and
  `test/support/user_config_helper.rb` provides `with_user_config(hash)` to
  install a fixture as `UserConfig.current`.
- Several existing campaign tests assert the EXACT warning list
  (`campaign_state_test.rb:297`, `:311`, `:334`, `:356`), so any new warning
  emitted on an unbound plan would change an existing expectation.
- The schema and every record key and warning/block code are documented in
  `skills/wurk:conductor/REFERENCE.md`, "Campaign files and
  `campaign_state.rb`" (lines 130-300 at 5fd85bd); `skills/wurk:kit/REFERENCE.md`
  "`campaign_state.rb`: which campaign may a scheduler start" summarizes it
  and points there.

## Desired End State

- A plan may carry one column-1 line `Machine: <name>`. With none, the plan
  is **unbound** and every field, warning, block and exit code is exactly as
  today - and the machine config is not even read.
- Every campaign record carries `machine` (the binding string, or null) and
  `machine_match`, one of:
  - `"unbound"` - no `Machine:` line;
  - `"this_machine"` - binding equals this machine's `machine.name`;
  - `"other_machine"` - this machine has a name and it differs;
  - `"unverified"` - a binding exists but this machine cannot prove it is
    the named host: `machine.name` unset, `wurk.local.json` invalid, or the
    `Machine:` line blank.
- `armed` (and therefore `runnable` and `data.runnable`) is additionally
  gated on `machine_match` being `"unbound"` or `"this_machine"`. A plan
  bound elsewhere, or unverifiable, is neither armed nor runnable here, but
  still appears in `data.campaigns[]` with its `status` word verbatim and its
  binding shown.
- A QUEUED plan whose predecessor is bound to anything other than this
  machine (other or unverified) never has its queue satisfied here, with a
  `queue_predecessor_remote` warning; `queue` gains `predecessor_machine`
  and `predecessor_machine_match`.
- `arm ID --host NAME` writes/keeps `Machine: NAME` and refuses unless NAME
  equals this machine's `machine.name`; on an unnamed machine it refuses
  with a message naming `wurk.local.json machine.name`. `arm` and `disarm`
  refuse a plan bound elsewhere or unverifiable.
- The kit's `~/.claude/wurk.local.json` `machine.name` is the one authority
  for the comparison. A persona harness that mirrors the key in its own
  config (known to drift) reads `campaign_state.rb`'s answer and does not
  compare on its own. This is stated in the code comment and in the
  conductor REFERENCE.

Verify with the kit suite (`/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb`)
and by the "Manual Testing Steps" below against a scratch campaigns dir.

### Key Discoveries:
- `inspect_plan` is the single place `armed`/`runnable` are computed
  (`campaign_state.rb:198-231`); `inspect_queue` the single place a queue is
  judged (`:242-256`). Both changes land there.
- `parse_status` matches the first column-1 `Status:` line anywhere in the
  file (`campaign_state.rb:95-105`); the `Machine:` line follows the same
  rule, for one schema shape rather than two.
- `rewrite_status` + `write_atomically` (`campaign_state.rb:140-186`) are the
  pattern for the new `rewrite_machine`; the rewrite never touches the
  filesystem itself.
- `UserConfig.current` is memoized and swappable in tests
  (`lib/user_config.rb:76-86`, `test/support/user_config_helper.rb:27-40`).
- ADR-0013 settles that machine facts live in `wurk.local.json`, not the
  manifest; ADR-0006 the script contract (stdlib Ruby, envelope, exit codes).

## What We're NOT Doing

- **No hostname fallback, ever.** An unnamed machine never matches a bound
  plan (bead note, design input 1-2; `machine_name` has no fallback by
  design, `lib/user_config.rb:190-193`).
- **No cross-host arming.** `arm --host` can only write this machine's own
  name. Arming a plan for another machine is done on that machine. Rebinding
  a plan already bound elsewhere, or unbinding one, is a deliberate hand edit
  of the `Machine:` line; no script does it.
- **`disarm` does not remove a binding.** A binding outlives arm/disarm
  cycles; it is part of the plan, not of its arm state.
- **No change to the conductor skill's prose** (`skills/wurk:conductor/SKILL.md`).
  `--armed` counts `armed: true` records and reads `data.runnable`, so it
  picks up the binding with no edit. Only REFERENCE.md changes.
- **No refusal in the interactive `/wurk:conductor campaign <id>` path.**
  A human naming a campaign explicitly is outside the scheduler failure this
  bead fixes; `show` exposes `machine_match` for a Phase 0 check if one is
  wanted later (see Decisions, "Follow-ups").
- **No consumer-side changes.** The persona harness's `Campaigns.pick`
  honoring the binding is carried by a separate bead on that side.
- **No new envelope-level `data.this_machine` field.** Populating it would
  force a config read on every `list`, breaking the "unbound fleet never
  reads machine config" guarantee. The name appears only inside records
  whose binding needed it (in `machine_match`).
- **No manifest or fleet-manifest field.** The binding lives in the plan and
  the identity in machine config (ADR-0013); nothing is read from
  `wurk.json` or `wurk-fleet.json`.
- **No binding-by-dir or binding-by-locks-dir scheme** and no new naming
  vocabulary.

## Implementation Approach

The binding is data in the plan file, read by the same line-grammar the
Status line already uses, and the identity it is compared against is the
one ADR-0013 already put in machine config. Every judgment the bead asks
for fails toward "not armed here": the failure being prevented is two
conductors on one campaign, so a machine that cannot prove a plan is its
own declines it.

Machine config is resolved **lazily**: a small memo in the CLI loads
`UserConfig.current` the first time a record (or a queue predecessor) turns
out to carry a binding, and never otherwise. That is what makes the
unbound guarantee structural rather than hopeful - an unbound fleet on a
machine with an invalid or unknown-keyed `wurk.local.json` gets no new
warning, because the file is never opened. When it is consulted from
`list`/`show`, an invalid config is a `user_config_invalid` **warning** and
resolves to "no name" (so every bound record reads `unverified`): `list`
stays always-exit-0 as its contract says. `arm --host`, `arm`, and `disarm`
on a bound plan use `UserConfig.require!`, which blocks, because they
mutate.

Two phases, each gate-green and committable on its own: the read side
first (binding honored by `list`/`show`/queue - a hand-written `Machine:`
line is fully functional after Phase 1), then the write side (`arm --host`
and the arm/disarm refusals). Docs change in the same commit as the code
they describe.

## Phase 1: Binding honored by list, show and the queue

### Overview
Parse the `Machine:` line, resolve this machine's name lazily, add
`machine`/`machine_match` to the record, gate `armed` on the match, hold a
queue behind a predecessor bound elsewhere, and document it.

### Changes Required:

#### 1. Parsing and record
**File**: `skills/wurk:kit/scripts/campaign_state.rb`
**Changes**:
- `require_relative "lib/user_config"`. Update the header comment: the
  script now reads machine config (never a manifest), lazily and only for a
  bound plan, and the kit's `~/.claude/wurk.local.json` `machine.name` is
  the authority for the comparison - a harness that mirrors the key in its
  own config reads this script's answer rather than comparing itself,
  because the mirror is known to drift.
- `MACHINE_LINE = /\AMachine:[ \t]*(.*?)[ \t]*\z/` and
  `parse_machine(content)` returning `{ machine:, line: }` for the first
  column-1 match (value may be `""`), or `{ machine: nil, line: nil }`.
- `MACHINE_MATCHES = %w[unbound this_machine other_machine unverified]` and
  `machine_match(binding, this_machine)`:

```ruby
def machine_match(binding, this_machine)
  return "unbound" if binding.nil?
  return "unverified" if binding.empty? || this_machine.nil?

  binding == this_machine ? "this_machine" : "other_machine"
end
```

- `inspect_plan(path, locks_dir:, this_machine: -> { nil })`: the new
  keyword is a callable, invoked only when the plan (or, via
  `inspect_queue`, its predecessor) carries a binding. Record gains
  `machine:` and `machine_match:`; `armed` becomes
  `(status ARMED || queue satisfied) && %w[unbound this_machine].include?(machine_match)`.
  The default callable keeps every existing direct caller and test working
  unchanged.
- `inspect_queue(dir, after, locks_dir:, this_machine:)`: parse the
  predecessor's `Machine:` line; `predecessor_machine` and
  `predecessor_machine_match` join the queue hash (including the
  no-`after` early return, as nil / nil); `satisfied` additionally requires
  `predecessor_machine_match` to be `unbound` or `this_machine`.

#### 2. Lazy machine identity in the CLI
**File**: `skills/wurk:kit/scripts/campaign_state.rb` (`CampaignStateCli`)
**Changes**:
- A per-run memo, e.g. `machine_resolver(env)`, returning a lambda that on
  first call loads `UserConfig.current`; if `!config.valid?` it warns
  `user_config_invalid` once (message: the errors, which never quote file
  content - `UserConfig.parse` already strips it) and resolves nil; a
  `JSON::ParserError` is handled the same way; otherwise resolves
  `config.machine_name`. Unknown-key warnings are NOT relayed from
  `list`/`show` (they are noise for a reader, and `user_config.rb check`
  owns them).
- `run_list`/`run_show`/`inspect_and_warn` pass the resolver through to
  `inspect_plan`.
- New warnings in `inspect_and_warn`, each only for a bound record:
  - `machine_name_unset` - record `unverified` because `machine.name` is
    unset; message names `~/.claude/wurk.local.json machine.name` and says
    the plan is treated as not armed. Emitted only when the plan's status is
    ARMED or QUEUED (a DRAFTED bound plan on an unnamed box is not news).
  - `machine_binding_blank` - `Machine:` line present with no name; treated
    as unverified.
  - `queue_predecessor_remote` - queued after a predecessor whose
    `predecessor_machine_match` is `other_machine` or `unverified`; message
    says the predecessor's mutex is not visible from this machine, so the
    queue holds, and that plain `arm <id>` (manual promotion) is the
    operator's path once they know the predecessor has finished.
- No warning is emitted for `other_machine` on its own: it is the normal
  state of a shared fleet dir and the record carries it.
- `USAGE` unchanged in this phase.

#### 3. Tests
**File**: `skills/wurk:kit/scripts/test/campaign_state_test.rb`
**Changes**: additions only. `require_relative "support/user_config_helper"`
and a new `class CampaignStateMachineBindingTest` (same setup/teardown shape
as `CampaignStateQueueTest`, `include UserConfigHelper`). Every existing
test is left byte-for-byte as it is. Tests:
- `parse_machine` reads the first column-1 line, returns `""` for a blank
  one, nil when absent, and ignores an indented `Machine:` in prose.
- **bound-to-me**: `Machine: mbp` + ARMED + ADOPTED under
  `with_user_config("machine" => { "name" => "mbp" })` -> `armed`,
  `runnable`, `machine == "mbp"`, `machine_match == "this_machine"`, id in
  `data.runnable`, no warnings.
- **bound-to-other**: same plan under name `air` -> listed in
  `data.campaigns`, `status == "ARMED"`, `machine == "mbp"`,
  `machine_match == "other_machine"`, `armed` false, `runnable` false,
  `data.runnable` empty, no warnings. Sabotage note: drop the machine gate
  from `armed` -> red here, green in bound-to-me.
- **the measured riddler shape**: two ARMED plans, one bound here, one bound
  elsewhere -> exactly one record with `armed: true` (the `ambiguous_armed`
  consequence).
- **unbound** under a named machine and under no config: identical record
  to today plus `machine: nil`, `machine_match: "unbound"`; runnable.
- **unbound never reads config**: install an INVALID config
  (`with_user_config("machine" => { "name" => "" })`) and list unbound ARMED
  plans -> `ok`, no warnings at all, still runnable. Sabotage note: resolve
  the machine eagerly in `run_list` -> red here.
- **unnamed machine, bound plan**: `with_user_config(nil)` + bound ARMED ->
  `machine_match == "unverified"`, not armed, warning
  `machine_name_unset` naming `machine.name`.
- **invalid config, bound plan**: list is `ok`, exit 0, warning
  `user_config_invalid`, record `unverified`.
- **blank binding**: `Machine:` alone -> `unverified`, warning
  `machine_binding_blank`, not armed.
- **show** exposes `machine` and `machine_match` under `data.campaign`.
- **queued behind a remote predecessor**: predecessor `042` WRAPPED and
  `Machine: mbp`, successor `043` unbound `QUEUED ... after 042`, both
  ADOPTED, under name `air` -> `043` not armed, `queue.satisfied` false,
  `queue.predecessor_machine == "mbp"`,
  `queue.predecessor_machine_match == "other_machine"`, warning
  `queue_predecessor_remote`, `data.runnable` empty. Sabotage note: drop the
  predecessor-machine term from `satisfied` -> red here, green in the next.
- **queued behind a predecessor bound here**: same fixture under name
  `mbp` -> satisfied, `043` in `data.runnable` (today's behavior preserved
  for the local case).
- **queued behind a predecessor on an unnamed machine**: predecessor bound,
  `with_user_config(nil)` -> holds, `queue_predecessor_remote`.

#### 4. Docs
**File**: `skills/wurk:conductor/REFERENCE.md`, "Campaign files and
`campaign_state.rb`"
**Changes**:
- New subsection "The Machine line - binding a plan to one machine" after
  "Queueing": grammar (first column-1 `Machine: <name>`), the four
  `machine_match` values, the armed/runnable rule, the fail-safe rule for an
  unnamed machine or invalid config, the lazy-read guarantee for unbound
  plans, no hostname fallback, and the authority statement (kit
  `wurk.local.json` `machine.name`; a harness mirror reads this script's
  answer). Cite ADR-0013 and `docs/machine-config.md`.
- "Queueing": one paragraph for the remote-predecessor hold.
- "The campaign record" JSON example: add `"machine": null` and
  `"machine_match": "unbound"`; the queue hash keys list gains the two
  predecessor keys.
- Warnings list: add `machine_name_unset`, `machine_binding_blank`,
  `queue_predecessor_remote`, `user_config_invalid`.
- Sections table: an optional `Machine:` line row (reader:
  `campaign_state.rb`).
- "The unattended invocation reads this record": one sentence that a plan
  bound elsewhere is not `armed`, so it counts toward neither refusal 1's
  zero nor its two.
- The plan template: an optional `Machine: <machine.name>` line directly
  under the Status line, commented as optional.

**File**: `skills/wurk:kit/REFERENCE.md`, "`campaign_state.rb`: which
campaign may a scheduler start"
**Changes**: one sentence: the script reads no manifest but does read
machine config, lazily, for a plan carrying a `Machine:` binding.

**File**: `docs/machine-config.md`, "`machine`"
**Changes**: under `machine.name`, name `campaign_state.rb` as a reader and
state that it is the authority for a campaign plan's `Machine:` binding.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb`
- [x] The new `CampaignStateMachineBindingTest` class exists and its
      bound-to-me, bound-to-other, unbound, unbound-never-reads-config,
      unnamed-machine, and queued-behind-a-remote-predecessor tests are
      green: `/usr/bin/ruby skills/wurk:kit/scripts/test/campaign_state_test.rb -n /MachineBinding/`
- [x] No existing test changed expectation - the test file diff deletes no
      line: `git diff main -U0 -- skills/wurk:kit/scripts/test/campaign_state_test.rb | grep -c '^-[^-]'`
      prints `0`
- [x] `grep -n "Machine line" skills/wurk:conductor/REFERENCE.md` finds the
      new subsection, and `grep -n "queue_predecessor_remote\|machine_name_unset\|machine_binding_blank" skills/wurk:conductor/REFERENCE.md`
      finds each code
- [x] `grep -n "machine_match" skills/wurk:conductor/REFERENCE.md` finds the
      record field
- [x] No hostname fallback in code (comment lines excluded):
      `grep -v '^[[:space:]]*#' skills/wurk:kit/scripts/campaign_state.rb | grep -ci 'socket\|hostname'`
      prints `0`

#### Manual Verification:
- [ ] Manual Testing Steps 1-4 below behave as described on a scratch dir
- [ ] REFERENCE prose reads correctly to someone who only knows the old
      schema: an unbound plan is described as unchanged, and the fail-safe
      direction is unambiguous
- [ ] No regressions in related features: `list` against a real, unbound
      campaigns dir on this machine reports exactly what it did before the
      change (compare `data.runnable` and `warnings` from `main` vs branch)

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: arm --host writes the binding; arm and disarm refuse foreign plans

### Overview
The one writer of a binding, which can only write this machine's name, and
the refusals that stop `arm`/`disarm` from flipping a plan this machine does
not own.

### Changes Required:

#### 1. The Machine-line rewrite
**File**: `skills/wurk:kit/scripts/campaign_state.rb` (`CampaignState`)
**Changes**: `rewrite_machine(content, name)` - pure, like
`rewrite_status`. When a `Machine:` line exists, replace its value; else
insert `Machine: <name>` on the line directly after the Status line (the
caller guarantees one exists by composing after `rewrite_status`, or the
plan already had one); with no Status line at all, insert after the H1 the
same way `rewrite_status` does.

#### 2. arm --host and the refusals
**File**: `skills/wurk:kit/scripts/campaign_state.rb` (`CampaignStateCli`)
**Changes**:
- `--host NAME` option ("arm only: bind the plan to this machine; NAME must
  equal ~/.claude/wurk.local.json machine.name"); `USAGE` becomes
  `... arm ID [--after ID] [--host NAME] ...`. Passing `--host` to another
  subcommand is a usage error (exit 2), same as a misplaced flag today.
- In `run_arm`, after `campaign_wrapped` and before the consent check:
  - if the record is `other_machine`: block `bound_to_other_machine`
    (message names the binding and this machine's name; says arming is done
    on that machine and rebinding is a hand edit);
  - if `unverified`: block `machine_name_unset` (unset name; message names
    `wurk.local.json machine.name`) or `machine_binding_blank` (blank line),
    each `needs: human`.
- With `--host NAME`: load config with `UserConfig.require!(env)` (an
  invalid file blocks, as in `lock.rb`); `machine_name` nil -> block
  `machine_name_unset`, message
  `--host needs this machine's name; set machine.name in ~/.claude/wurk.local.json (the OS host name is never used)`;
  NAME != machine_name -> block `host_not_this_machine` naming both. Never
  consult the OS hostname.
- The Status write and the Machine write are independent, each done only if
  it changes the file: an already-ARMED unbound plan with `--host <me>`
  gets only the Machine line (Status and stamp untouched, `already_armed`
  still warned, `changed: true`); a plan already bound to this machine with
  `--host <me>` writes no Machine line. Both composed into one
  `write_atomically`. Each write is its own `commands` entry
  (`write Machine line in <path>: <old or none> -> <name>`). `--dry-run`
  reports and touches nothing. `data.machine_before` / `data.machine_after`
  join `before`/`after`.
- The `already_armed` early return (`campaign_state.rb:405-408`) and the
  `already_queued` one (`:394-397`) must be restructured, not reused as
  is: today they return before any write, which would skip the
  Machine-only write promised above. When `--host` adds or changes the
  binding, the warning is still emitted but the Machine write proceeds
  before returning.
- The `rewrite` helper's post-write re-read (`campaign_state.rb:491`) and
  every other `inspect_plan` call in the CLI must receive the per-run
  machine resolver (the Phase 1 default `-> { nil }` would report a freshly
  bound plan as `unverified`). Simplest shape: `rewrite` re-reads through
  `inspect_and_warn`-equivalent plumbing that already carries the resolver.
- `--host` composes with `--after` (writes `QUEUED ... after ID` and the
  Machine line).
- In `run_disarm`, before the `campaign_running` check: the same
  `bound_to_other_machine` / `machine_name_unset` / `machine_binding_blank`
  refusals - the other machine's mutex is not visible here, so a disarm
  from here cannot know whether a conductor already read ARMED (the same
  reasoning as `campaign_running`). `disarm` never touches the Machine line.
- Why cross-host arming is refused, stated in the `run_arm` comment: the
  binding is the claim "this machine will conduct it"; only the machine
  making the claim can make it, and a typo'd foreign name would silently
  strand the plan.

#### 3. Tests
**File**: `skills/wurk:kit/scripts/test/campaign_state_test.rb`
**Changes**: additions only, in `CampaignStateMachineBindingTest` (or a
sibling `CampaignStateArmHostTest`):
- `rewrite_machine` inserts after the Status line, replaces an existing
  line, and inserts after the H1 with no Status line.
- `arm --host mbp` under name `mbp` on a DRAFTED plan: `Status: ARMED ...`
  then `Machine: mbp` on the next line; record `this_machine`, runnable.
- `arm --host air` under name `mbp`: exit 1, `host_not_this_machine`, file
  unchanged.
- `arm --host mbp` under `with_user_config(nil)`: exit 1,
  `machine_name_unset`, message includes `machine.name`, file unchanged.
- `arm --host mbp` under an invalid config: exit 1, `user_config_invalid`.
- `arm --host mbp` on an already-ARMED unbound plan: Machine line added,
  Status line byte-identical, `already_armed` warned, `changed` true.
- `arm --host mbp --after 042`: QUEUED line plus Machine line.
- `arm --host mbp --dry-run`: two command entries, file unchanged.
- `arm` (no `--host`) on a plan bound to `mbp` under name `air`: exit 1,
  `bound_to_other_machine`, file unchanged; under no config: exit 1
  `machine_name_unset`.
- `disarm` on a plan bound to `mbp` under name `air`: exit 1,
  `bound_to_other_machine`, file unchanged; under name `mbp`: disarms, and
  the Machine line survives.
- `--host` on `list`: exit 2.

#### 4. Docs
**File**: `skills/wurk:conductor/REFERENCE.md`, "Subcommands"
**Changes**: `arm` entry documents `--host NAME`, its refusals
(`host_not_this_machine`, `machine_name_unset`, `user_config_invalid`), the
independent Status/Machine writes, and why cross-host arming is refused;
`arm` and `disarm` entries document `bound_to_other_machine` /
`machine_name_unset` / `machine_binding_blank` on a foreign or unverifiable
plan, and that `disarm` keeps the binding. The "Machine line" subsection
from Phase 1 gains one sentence pointing at `arm --host` as the writer.
Template's `armed:` header row comment unchanged.

**File**: `skills/wurk:kit/REFERENCE.md`, `campaign_state.rb` section
**Changes**: the restated rule gains its companion: `arm --host` writes
only this machine's own name and never falls back to a hostname.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb`
      (including `contract_test.rb`, which covers `--dry-run` and the banned
      operations)
- [ ] The arm/disarm binding tests are green: `/usr/bin/ruby skills/wurk:kit/scripts/test/campaign_state_test.rb -n "/host|bound_to_other|Machine/"`
- [ ] Still no existing test changed expectation:
      `git diff main -U0 -- skills/wurk:kit/scripts/test/campaign_state_test.rb | grep -c '^-[^-]'`
      prints `0`
- [ ] `ruby skills/wurk:kit/scripts/campaign_state.rb list --host x` exits 2
- [ ] `grep -n "host_not_this_machine\|bound_to_other_machine" skills/wurk:conductor/REFERENCE.md`
      finds both codes

#### Manual Verification:
- [ ] Manual Testing Steps 5-7 below behave as described
- [ ] The `arm --host` refusal messages are actionable to an operator who
      has never seen `wurk.local.json` (the key path is in the message)
- [ ] No regressions in related features: plain `arm`/`disarm`/`arm --after`
      on unbound plans behave exactly as before

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
- All in `skills/wurk:kit/scripts/test/campaign_state_test.rb`, additions
  only; machine identity is always installed with
  `UserConfigHelper#with_user_config` (HomeGuard keeps the real config out).
- The acceptance matrix: bound-to-me, bound-to-other, unbound (named and
  unnamed machine, and with an invalid config to prove laziness), unnamed
  machine with a bound plan, blank binding, and queued behind a predecessor
  bound elsewhere / here / on an unnamed machine.
- Writer: `--host` match, mismatch, unnamed, invalid config, dry-run,
  composition with `--after`, bind-an-already-armed-plan; arm/disarm
  refusal on foreign and unverifiable plans.
- Each fail-safe test carries a sabotage note naming the one-line mutation
  that turns it red.

### Manual Testing Steps:
Use a scratch campaigns dir and a scratch HOME
(`HOME=<tmp> ruby skills/wurk:kit/scripts/campaign_state.rb ...`) so the
real machine config and live campaigns are never touched.
1. Scratch HOME with no `wurk.local.json`; one ARMED + ADOPTED unbound plan:
   `list` output matches `main`'s byte-for-byte apart from the two new
   record keys.
2. Add `Machine: mbp` to the plan; no config: plan listed, `armed: false`,
   `machine_match: "unverified"`, `machine_name_unset` warning.
3. Scratch config `{"machine":{"name":"air"}}`: `other_machine`, no warning,
   `runnable` empty. Change to `mbp`: `this_machine`, runnable.
4. Second plan `QUEUED ... after` the first; mark the first WRAPPED; under
   `air`: successor held with `queue_predecessor_remote`; under `mbp`:
   successor runnable.
5. Unbound DRAFTED plan, config `mbp`: `arm ID --host mbp` writes Status and
   Machine lines; `--host air` refuses `host_not_this_machine`.
6. Config removed: `arm ID --host mbp` refuses `machine_name_unset` naming
   `machine.name`.
7. Config `air`, plan bound to `mbp`: `arm` and `disarm` both refuse
   `bound_to_other_machine` and the file is unchanged.

## Decisions

Made without a human, conservatively, per the plan stage's brief. Each is
reversible by editing this plan before implementation.

- **Binding shape: a column-1 `Machine: <name>` line**, first match wins,
  anywhere in the file - the Status line's own rule, so the plan schema
  stays one grammar. The value is the rest of the line, trimmed, compared
  by exact string equality (machine names may contain spaces).
- **Unnamed machine + bound plan = not armed** (`unverified`), never a match
  and never a hostname guess (bead note design input 1-2).
- **Invalid machine config during `list`/`show` = warning, not block**:
  `list` is documented always-exit-0, and every bound record degrades to
  `unverified`, which is the safe direction. Mutations block on it.
- **Blank `Machine:` line = `unverified`**, not unbound: an explicit
  binding with no name is a mistake, and a mistake must hold rather than
  release (the same rule as a typo'd queue predecessor).
- **A predecessor bound elsewhere never satisfies a queue here**, even when
  its file says WRAPPED, because the mutex half of the satisfaction check
  cannot be evaluated across machines. The operator's path is plain `arm`
  (manual promotion), which already exists.
- **Arm/disarm refuse foreign and unverifiable plans.** The bound machine
  arms and disarms its own plan.
- **Cross-host arming is refused**, not documented-as-allowed (bead
  criterion offers either; refusing is the conservative one).
- **Machine config is read lazily**, only when a binding is present, so the
  unbound guarantee holds even on a machine with a broken
  `wurk.local.json`.
- **No `other_machine` warning.** On a shared fleet dir it is the normal
  state and would fire on every tick; the record field is the signal.

### Follow-ups (not blocking this plan)
- Whether the interactive `/wurk:conductor campaign <id>` Phase 0 should
  refuse a plan whose `show` reports `other_machine`. A human-directed
  dispatch is outside this bead's failure; worth its own bead if wanted.
- Existing plans on consumer fleets that happen to carry a column-1
  `Machine:` line of prose would become bound. The failure is in the safe
  direction (not armed, visible in the record), but a consumer adopting
  this kit version may want to grep its campaigns dir once. Mention in the
  commit body.

## References

- Bead: `wu-dtrb` (description, acceptance criteria, and the 2026-09-19
  design-input note)
- Script: `skills/wurk:kit/scripts/campaign_state.rb:198-256`
- Tests: `skills/wurk:kit/scripts/test/campaign_state_test.rb`
- Machine identity: `skills/wurk:kit/scripts/lib/user_config.rb:190-196`,
  `docs/machine-config.md` ("`machine`")
- Test seams: `skills/wurk:kit/scripts/test/support/user_config_helper.rb`,
  `skills/wurk:kit/scripts/test/support/home_guard.rb`
- Schema doc: `skills/wurk:conductor/REFERENCE.md`, "Campaign files and
  `campaign_state.rb`"
- Related ADRs: `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`,
  `docs/adr/0013-machine-level-config-seam.md`
- Similar implementation: `skills/wurk:kit/scripts/lock.rb:66` (the
  `UserConfig.require!` pattern for a machine value)
- Related bead: `wu-0m0` (list reporting a plan a consumer cannot act on)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Manual Testing Steps 1-4 below behave as described on a scratch dir
- [ ] REFERENCE prose reads correctly to someone who only knows the old
      schema: an unbound plan is described as unchanged, and the fail-safe
      direction is unambiguous
- [ ] No regressions in related features: `list` against a real, unbound
      campaigns dir on this machine reports exactly what it did before the
      change (compare `data.runnable` and `warnings` from `main` vs branch)

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

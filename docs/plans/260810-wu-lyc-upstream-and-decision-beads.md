# Upstream and decision beads in wurk:work Implementation Plan

## Overview

ADR-0009 decided how an upstream bead - one that changes no files in the repo
that tracks it, because the work happens in a sibling repository - is handled:
the upstream check is a label read over `beads.areas.always_batchable`
available to both skills, `/wurk:next` refuses to stand up a workspace for
such a bead, and `/wurk:work` owns the early exit and the coordination report.
The same record notes that bd issue type as a signal into `/wurk:work`'s
bucket table is documentation of an existing seam, and that its wording lands
with this bead's implementation. This plan implements exactly the five items
ADR-0009's Consequences section enumerates. It does not re-open any of them.
Beads issue: `wu-lyc`.

## Current State Analysis

The seam exists and is read; its second consequence is simply not drawn.

- **`lib/areas.rb:34-48`** already exposes `always_batchable_labels` (from
  `manifest.area_always_batchable`) and the predicate `upstream?`. Its
  comment for `always_batchable_labels` says "Labels marking work that
  changes no files in this repo (docs/workflow.md). Always batchable - such a
  bead collides with nothing here by definition." Two problems: it states only
  the batching consequence, and `docs/workflow.md` is a statifier-ex path that
  does not exist in this repo (the same stale citation appears at
  `lib/areas.rb:6, 11, 22, 26, 33, 55` and in `test/areas_test.rb:31`).
- **`select_batch.rb:221-241`** (`annotate`) computes `upstream =
  Areas.upstream?(labels)` and uses it for exactly one thing: exempting the
  bead from the `unlabeled` verdict (`elsif areas.empty? && !upstream`). With
  no area labels and no collision it therefore falls through to `free` -
  pickable, claimed by `/wurk:next` step 4, and given a workspace in step 6.
- **`select_batch.rb:276-339`** (`walk`) has two verdict lists that a new
  informational verdict must join: the skip arm at line 288
  (`when "epic", "unlabeled", "collides-with-live-worktree"`) and the
  keep-your-own-reason list at line 330 (`%w[epic unlabeled
  collides-with-live-worktree]`), which is what stops an unreached candidate
  being reported as "not reached - ceiling met" when it was really excluded
  on its own verdict.
- **`test/select_batch_test.rb:108-119`**
  (`test_upstream_beads_collide_with_nothing`) asserts today's behavior
  directly: two `upstream`-labelled beads both land in `data.recommended` and
  both carry verdict `free`. **This test encodes the bug and must be
  rewritten, not added around.** The `areas_wide` fixture
  (`test/fixtures/manifests/areas_wide.json:16-18`) already sets
  `always_batchable: ["upstream"]`, so no fixture change is needed.
- **`skills/wurk:next/SKILL.md:160-166`** holds the verdict table. The
  `unlabeled` row (line 163) ends with the sentence that belongs to the new
  row: "The exception is the labels the manifest lists under
  `beads.areas.always_batchable`, which by definition change no files here."
  Steps 4 and 6 (claim, then stand up a workspace per bead) act on
  `data.recommended`, so an informational verdict is automatically excluded
  from both - but the skill has to say so, because step 2's manual-mode
  picker can otherwise be read as free to offer any candidate row.
- **`skills/wurk:work/SKILL.md:51-78`** is step 0 ("Locate self"): the main
  checkout branch invokes `/wurk:branch <id>-<slug> -- /wurk:work <id> --auto`
  and stops. This is the handoff ADR-0009 requires the upstream exit to sit
  ahead of. The worktree branch continues to step 1, which is where the
  defensive in-workspace exit belongs.
- **`skills/wurk:work/SKILL.md:79-97`** (step 1) already reads the bead and
  already refuses an epic in prose ("An epic is not workable: report it,
  point at its children, and stop"). So `issue_type` is read; it is just not
  carried into step 2's bucket table (`SKILL.md:126-133`).
- **`docs/manifest.md:19-23`** shows `always_batchable` only inside the jsonc
  block, with no prose. The document's convention is a `## <field>` section
  for any field whose meaning is not obvious (`## gate.project_level_skips`,
  `## gate.sabotage`, `## judge`, `## Two path lists, not one`), which is the
  shape the sharpened wording should take.
- **`skills/wurk:issue/SKILL.md:125-130`** is the third place the phrase
  lives, and it too states only half the meaning.
- No consumer currently sets `always_batchable`: this repo's own
  `.claude/wurk.json:16` has `[]`, and predicator-ex's adoption bead px-ttt
  deliberately omits it pending this work. The behavior is therefore
  exercised only by the fixture manifests today, which is why the kit test
  coverage in phase 1 is the real proof.
- **No script test asserts on `wurk:*/SKILL.md` content.** The `SKILL.md`
  mentions under `scripts/test/` are comments, a `gate_test.rb` fixture
  string using consumer-era `.claude/skills/` paths, and a frozen plan
  fixture. So skill prose here is gated only by review plus the merge-time
  prose judge (`.claude/wurk/mr.md`, ADR-0008), never by `run.rb`.

## Desired End State

- `select_batch.rb` emits an `upstream` verdict for any bead carrying a label
  the manifest lists under `beads.areas.always_batchable`; such a bead appears
  in `data.candidates` with a reason pointing at `/wurk:work <id>`, appears in
  `data.skipped` with that same reason, and never appears in
  `data.recommended`.
- `/wurk:next`'s verdict table has an `upstream` row carrying the
  always_batchable sentence, the `unlabeled` row no longer carries it, and the
  skill states that an upstream bead is neither claimed nor given a workspace.
- `/wurk:work` exits early for an upstream bead ahead of the `/wurk:branch`
  handoff, having claimed it, and reports the sibling repo and that the bead
  tracks rather than performs the work; the same exit fires defensively when
  the session is already inside a workspace.
- `/wurk:work`'s bucket table documents bd issue type as a signal: `decision`
  raises the prior for Direction, `epic` refuses; neither overrides the
  description.
- `docs/manifest.md` and `lib/areas.rb` state that "changes no files here"
  implies both batchable and no workspace standup. No schema change, no
  version bump, `lib/manifest.rb` untouched.

Verify by running the gate (`ruby skills/wurk:kit/scripts/test/run.rb`) and by
reading each changed skill against the criteria in each phase below.

### Key Discoveries:

- ADR-0009 is binding and settles every design question this bead raised;
  cite it rather than re-deriving. In particular: the upstream check is a
  label read of the same kind as the `epic` type read
  (`docs/adr/0009-upstream-beads-without-a-workspace.md:29-39`), the split of
  responsibilities is `/wurk:next` refuses standup and `/wurk:work` owns the
  report (`0009:43-68`), and `always_batchable` stays the seam with no schema
  change and no rename (`0009:70-83`).
- `test/select_batch_test.rb:108-119` asserts the old behavior and is the one
  test that must change rather than be added to.
- `select_batch.rb:288` and `:330` are the two places in `walk` that a new
  informational verdict has to be added to; missing the second produces a
  correct-looking `skipped` entry with the wrong reason for any candidate the
  walk never reached.
- Verdict precedence in `annotate` is expressed as an if/elsif chain, so
  placement decides precedence. `epic` must stay first (an upstream epic is
  still an epic; work its children). `upstream` goes second, ahead of
  `lands-alone` and the collision check, so a bead carrying both an
  `always_batchable` label and an area label still reports `upstream` - the
  label combination is contradictory, and the safe reading is the one that
  refuses to build a workspace.
- Skills read manifest values as prose instructions where no script wraps the
  read - `skills/wurk:next/SKILL.md:38` ("Read `beads.topology` from
  `.claude/wurk.json`") is the precedent phase 2 follows for the upstream
  label read in `/wurk:work`. No new kit script is needed or wanted.
- ADR-0009:105-107 - an upstream bead never merges anything here, so
  `/wurk:cleanup` never closes it; it closes manually with `bd close` when
  the sibling work lands. `/wurk:work`'s exit report has to say this, because
  nothing else in the workflow will.
- ADR-0004 / CLAUDE.md: extensions add, they never override; no consumer
  constants in generic skills or kit scripts. Every string this plan adds is
  either generic (`/wurk:work <id>`) or manifest-derived.

## What We're NOT Doing

- **No manifest schema change and no version bump.** ADR-0009:70-83 rejects
  both a second "upstream" label list and a rename of `always_batchable`.
  `lib/manifest.rb` is not touched, so the code-doc sync rule is satisfied by
  a `docs/manifest.md` wording change alone.
- **No structured label-to-repo mapping in the manifest.** The sibling repo
  is named in prose on the bead; ADR-0009:62-64 defers the mapping until a
  second consumer demonstrates the need.
- **No change to `/wurk:cleanup`.** Manual `bd close` on the tracking bead is
  the recorded outcome (ADR-0009:105-107), not a new reaping path.
- **No change to `/wurk:next`'s selection mechanics beyond the new verdict** -
  no new flag, no "include upstream" mode, no change to `alternatives_for`
  (override exists only for `collides-with-live-worktree`, and an upstream
  bead is not a risk a user can knowingly accept - there is nothing here for
  the workspace to do).
- **No change to this repo's own `.claude/wurk.json`.** Wurk has no upstream
  beads; leaving `always_batchable` as `[]` keeps the fixture manifests as
  the only place the behavior is exercised, which is where the tests want it.
- **Not fixing the stale `docs/workflow.md` citations** in `lib/areas.rb`
  beyond the one comment phase 1 rewrites. They are a pre-existing porting
  artifact across six lines and one test comment; sweeping them here would
  bury this bead's change in unrelated diff noise. Worth its own bead.
- **No script-level enforcement of the `/wurk:work` early exit.** It is skill
  prose, like the epic refusal it sits beside; the kit's banned-operations
  contract is about irreversible actions, not about routing.

## Implementation Approach

Two phases, each leaving the tree green and committable on its own.

Phase 1 lands the script change, its documenting prose, and the sharpened
`always_batchable` wording together. Three reasons, all pointing the same way:
`/wurk:next`'s verdict table is a direct mirror of `select_batch.rb`'s verdict
strings, so a commit where the script emits `upstream` and the table has no
row for it is a documented-contract mismatch; CLAUDE.md's rule about updating
every referencing skill, script and test in the same commit is aimed at
exactly that coupling; and **ADR-0009:108-110 says in terms that
`docs/manifest.md`'s wording and `lib/areas.rb`'s comments are sharpened in
the same commit as the skill changes, per the code-doc sync rule.** An earlier
draft of this plan split the sharpening into a third, later phase; that would
have left the merged history showing the doc lagging the code it describes,
which is precisely what the ADR's clause forbids. The four statements of what
`always_batchable` means (`docs/manifest.md`, `lib/areas.rb`,
`wurk:next/SKILL.md`'s new verdict row, `wurk:issue/SKILL.md`) therefore all
move in one commit.

Phase 2 is `/wurk:work` prose only - both the upstream exit and the issue-type
signal, since they are two edits to one file with no ordering between them.
It carries no doc sharpening, so nothing in it is subject to the same-commit
clause.

The gate (`ruby skills/wurk:kit/scripts/test/run.rb`) runs at every phase. It
has real assertions to make only in phase 1; in phase 2 it is a regression
check, which is the honest description and is why phase 2 also carries
grep-shaped automated criteria that can actually fail.

---

## Phase 1: The `upstream` verdict, and what always_batchable means

### Overview

`select_batch.rb` gains an `upstream` verdict - informational, never
recommended, reason pointing at `/wurk:work <id>` - with kit test coverage;
`/wurk:next`'s verdict table grows the matching row; and the three prose
statements of what `always_batchable` means (`docs/manifest.md`,
`lib/areas.rb`, `wurk:issue/SKILL.md`) are sharpened in the same commit, per
ADR-0009:108-110. No schema change, no version bump, `lib/manifest.rb`
untouched.

### Changes Required:

#### 1. The verdict

**File**: `skills/wurk:kit/scripts/select_batch.rb`
**Changes**: In `annotate` (line 221-241), insert the `upstream` arm second,
after `epic` and before the `unlabeled` check. The `unlabeled` guard's
`&& !upstream` becomes redundant once `upstream` short-circuits ahead of it
and is removed, so the exemption lives in exactly one place.

```ruby
      verdict, reason, collides_with =
        if issue["issue_type"] == "epic"
          ["epic", "epic - work its children", nil]
        elsif upstream
          # An always_batchable label means the bead changes no files here
          # (ADR-0009): it collides with nothing AND has nothing for a
          # workspace to do. Informational only - never recommended, because
          # /wurk:next's claim and workspace standup both act on
          # `recommended`, and this is the only place that waste can be
          # prevented.
          ["upstream", "upstream - the work happens in a sibling repo; run /wurk:work #{issue['id']} to handle it", nil]
        elsif areas.empty?
          ["unlabeled", "unlabeled - blast radius undecided", nil]
```

In `walk`, add `"upstream"` to both verdict lists:

```ruby
        when "epic", "unlabeled", "upstream", "collides-with-live-worktree"
```

```ruby
          if %w[epic unlabeled upstream collides-with-live-worktree].include?(c[:verdict])
```

Also extend the module header comment (lines 14-24) with one sentence: the
script never claims and never creates a worktree, and the `upstream` verdict
is how it keeps `/wurk:next` from doing either for a bead whose work is
elsewhere.

#### 2. Kit test coverage

**File**: `skills/wurk:kit/scripts/test/select_batch_test.rb`
**Changes**: Replace `test_upstream_beads_collide_with_nothing`
(lines 108-119) - it asserts the pre-ADR-0009 behavior - and add cases
around it. The `areas_wide` fixture already supplies
`always_batchable: ["upstream"]`; the fixture-independence test uses
`manifest_with`, the pattern at `areas_test.rb:54-65`.

- `test_upstream_bead_is_informational_and_never_recommended` - two
  `upstream`-labelled beads: `data.recommended` is empty, both candidates
  carry verdict `upstream`, and each `skipped` reason matches `/wurk:work
  zz-up1` / `zz-up2` respectively (the reason names the bead's own id).
- `test_upstream_wins_over_area_labels` - a bead labelled
  `["upstream", "area:alpha"]` gets verdict `upstream`, not `free`, and is
  not recommended.
- `test_upstream_beats_unlabeled_but_not_epic` - an `upstream`-labelled bead
  with `issue_type: "epic"` still reports `epic`.
- `test_unreached_upstream_keeps_its_own_reason` - a free bead at priority 1
  and an `upstream` bead at priority 2, run with `--n 1`: the upstream bead's
  `skipped` reason is its own verdict reason, not "not reached - ceiling
  n=1 already met".
- `test_upstream_label_is_manifest_driven` - a manifest whose
  `always_batchable` is `[]` gives an `upstream`-labelled bead with no area
  label the `unlabeled` verdict, proving the verdict comes from the manifest
  and not from the literal string "upstream".

#### 3. The verdict table row

**File**: `skills/wurk:next/SKILL.md`
**Changes**: In the verdict table (lines 160-166), strip the trailing
exception sentence from the `unlabeled` row and add an `upstream` row between
`unlabeled` and `lands-alone`, worded generically (no consumer label names):

```
| `upstream` | carries a label the manifest lists under `beads.areas.always_batchable`, which by definition changes no files here - so there is nothing for a workspace to do. Informational: it is shown in the candidate table and never enters the recommended batch. The reason points at `/wurk:work <id>`, which handles it without a workspace. |
```

Then, immediately under the table, one paragraph: an `upstream` candidate is
**never claimed here and never given a workspace**, in either mode - manual
mode may not offer it as a pick, and the override path does not apply to it,
because the workspace is not a risk to accept but pure waste with no cleanup
path (an upstream bead opens no request, so `/wurk:cleanup` never reaps it).
Cite ADR-0009. Add the same point to the Guidelines list at the end of the
skill, next to "This skill picks and claims; it neither sizes nor
implements."

#### 4. The manifest document

**File**: `docs/manifest.md`
**Changes**: Add a `## beads.areas.always_batchable` section, in the same
shape as `## Two path lists, not one` and `## gate.sabotage`, placed after
`## Two path lists, not one`. Content:

- The field lists labels marking work that **changes no files in this repo** -
  the work happens in a sibling project and the bead here tracks it.
- That single predicate has **two consequences, not one**: such a bead
  collides with nothing (so it is always batchable), *and* it has nothing for
  a workspace to do (so no workspace is stood up for it). `select_batch.rb`
  reports it as the `upstream` verdict - informational, never recommended -
  and `/wurk:work` handles it with an early exit and a coordination report.
- The name is narrower than the meaning. ADR-0009 considered renaming and
  rejected it: a breaking manifest change bought only for a name. If a
  breaking schema change happens for other reasons, the rename rides along.
- A bead carrying one of these labels takes no `area:` label; the two are
  alternatives.

Leave the jsonc block at lines 19-23 as it is. Do not touch
`## Per-repo starting values` - no consumer's value changes here (predicator's
adoption is its own bead in its own repo). `lib/manifest.rb` is not touched,
so the code-doc sync rule is satisfied by this wording change alone.

#### 5. The library comments

**File**: `skills/wurk:kit/scripts/lib/areas.rb`
**Changes**: Rewrite the `always_batchable_labels` comment (lines 32-34) to
state both consequences and cite ADR-0009 instead of the stale
`docs/workflow.md`:

```ruby
    # Labels marking work that changes no files in this repo - the work
    # happens in a sibling project and the bead here tracks it. One
    # predicate, two consequences (ADR-0009): such a bead collides with
    # nothing (always batchable), and it has nothing for a workspace to do
    # (select_batch.rb reports the `upstream` verdict, and /wurk:work exits
    # early rather than standing one up).
```

Add one line to the `upstream?` predicate (line 46) naming what callers do
with a true result, so the second consequence is visible at the call site
too. Leave the module header and the other `docs/workflow.md` citations
alone - see "What We're NOT Doing".

#### 6. The issue skill's half-statement

**File**: `skills/wurk:issue/SKILL.md`
**Changes**: The paragraph at lines 125-130 already says such a bead takes no
area label. Extend its last clause by one sentence: such a bead is picked up
without a workspace, so labelling it is strictly better than leaving it
unlabelled - the labelled bead gets a coordination report, the unlabelled one
is skipped as "blast radius undecided". This is the third and last prose site
of the phrase; leaving it stating half the meaning is the drift CLAUDE.md's
same-commit rule exists to prevent.

### Success Criteria:

#### Automated Verification:

- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] `grep -c 'upstream' skills/wurk:kit/scripts/select_batch.rb` increases
      by at least 3 over its pre-phase value (the `annotate` verdict string,
      the `walk` skip arm, the `walk` keep-your-own-reason `%w[]` list). Note
      the second `walk` list is `%w[]`-quoted, so a `'"upstream"'` grep would
      find only two of the three - match on the bare word.
- [x] No consumer constants **added**:
      `git diff main...HEAD -- skills/wurk:kit/scripts/select_batch.rb skills/wurk:kit/scripts/lib/areas.rb | grep -nE '^\+.*\b(st|px|pd|gl)-[a-z0-9]'`
      is empty. Scoped to added lines deliberately: `select_batch.rb:16` and
      `lib/areas.rb` already carry pre-existing statifier-era citations
      (`st-hzf`) that this bead does not clean up, so a whole-file grep would
      be red before and after for reasons outside this plan. The contract
      test's own consumer-vocabulary scan is the second, independent check on
      the same property and runs as part of the gate.
- [x] `grep -n 'always_batchable' skills/wurk:next/SKILL.md` shows it on the
      `upstream` row and no longer on the `unlabeled` row
- [x] `git diff --name-only main...HEAD` for this phase does **not** include
      `skills/wurk:kit/scripts/lib/manifest.rb` - no schema change
- [x] `grep -n 'Schema version 1' docs/manifest.md` and
      `grep -n '"wurk": 1' docs/manifest.md` both still match - no version
      bump
- [x] `grep -n 'always_batchable' docs/manifest.md` shows both the jsonc line
      and the new `## beads.areas.always_batchable` heading
- [x] `grep -n 'ADR-0009' skills/wurk:kit/scripts/lib/areas.rb` is non-empty

#### Manual Verification:

- [ ] Read the new verdict row against `select_batch.rb`'s emitted reason
      string - the table's wording and the script's wording agree
- [ ] The reason string reads as an instruction a model will follow
      (`run /wurk:work <id>`), not as a bare classification
- [ ] No regressions in the rest of the verdict table: `epic`, `unlabeled`,
      `lands-alone`, `collides-with-live-worktree` are unchanged in meaning
- [ ] All four statements of the phrase (`docs/manifest.md`, `lib/areas.rb`,
      `wurk:next/SKILL.md`'s verdict row, `wurk:issue/SKILL.md`) say the same
      thing, and all four are in this one commit
- [ ] The new `docs/manifest.md` section reads as reference material,
      matching its neighbours' register

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: The wurk:work upstream exit and the issue-type signal

### Overview

`/wurk:work` gains the early exit for an upstream bead ahead of the step 0
handoff to `/wurk:branch`, the defensive in-workspace exit, and bd issue type
documented as a signal into the bucket table.

### Changes Required:

#### 1. The upstream exit

**File**: `skills/wurk:work/SKILL.md`
**Changes**: Add a new section **"Step 0: Upstream beads exit here"** ahead of
the current step 0, renumbering the existing "Step 0: Locate self" to
**Step 0.5** (steps 1-5 keep their numbers). A similar fractional-step
convention already exists in `wurk:next/SKILL.md`, though as a numbered list
item under one `## Steps` heading rather than as its own `## Step N:` heading
- so it is a precedent for the numbering, not for the heading shape.

The section says, in bead mode only:

- Read the bead: `ruby ~/.claude/skills/wurk:kit/scripts/bead.rb show <id>`.
  This read is needed here anyway - step 1 does it - and doing it first is
  what makes the check possible before any workspace exists.
- Read `beads.areas.always_batchable` from `.claude/wurk.json` (the same
  direct-manifest-read pattern as `wurk:next/SKILL.md:38`). If the list is
  absent or empty, no bead is upstream; continue to step 0.5.
- If any of the bead's labels is in that list, **this bead is upstream: the
  work happens in a sibling repository and this bead exists to track and
  coordinate it (ADR-0009).** Then:
  1. Claim it as usual (`bead.rb claim <id>`) - the claim still marks
     coordination in progress - and `bead.rb sync push`, best-effort.
  2. **Do not invoke `/wurk:branch`. Do not create a branch or a workspace.
     Do not size the job.** There is nothing here for a workspace to do, and
     an upstream bead opens no request, so `/wurk:cleanup` would never reap
     one that got created.
  3. Report and stop, with: the bead id and title; **which sibling repository
     the work happens in**, taken from the bead's description - and, when the
     description does not name one, say so explicitly rather than guessing,
     and point at the bead as the thing to fix; that this bead **tracks
     rather than performs** the work; that it stays in progress and is closed
     manually with `bd close` when the sibling work lands, because
     `/wurk:cleanup` never will.
- **Defensive case.** If this session is already inside a workspace for an
  upstream bead (which `/wurk:next` no longer creates, but a hand-run
  `/wurk:branch` still can), give the same report and stop rather than sizing,
  and additionally name the workspace and branch as leftovers to remove by
  hand. The workspace's existence is a mistake to report, not a reason to
  proceed (ADR-0009:65-68). Because this check runs ahead of "Locate self",
  one check covers both the main-checkout and in-workspace cases; the
  defensive text is the extra sentence the in-workspace case adds.
- **Intake mode** has no bead yet at this point. Re-apply the same check at
  the end of step 1 once `/wurk:issue` has created the bead, and take the
  same exit.

Also update the "Direction still goes through the same workspace path"
paragraph (lines 135-139) with one sentence distinguishing the two cases, so
the two rationales do not read as contradictory: a Direction bead commits a
record *here*, so its workspace is used late rather than wasted, whereas an
upstream bead produces no commit here at all (ADR-0009:36-39).

#### 2. bd issue type as a signal

**File**: `skills/wurk:work/SKILL.md`
**Changes**: Add a **`bd type signal`** column to the bucket table
(lines 128-133): `decision` on the Direction row, `-` on Code-heavy,
Plan-only and Just-do-it. Then a paragraph immediately under the table:

- bd's `decision` issue type means the same thing the Direction bucket means -
  ADR-shaped work: architecture decisions, spec interpretation, review - so a
  `decision`-typed bead starts in Direction unless the description plainly
  says otherwise.
- `epic` is a refusal, not a bucket; step 1 already handles it.
- **The type is a signal, never an override.** It raises the prior; it does
  not settle the bucket. A `task`-typed bead whose description is plainly a
  direction question ("should we ...", "decide whether ...", "which of these
  two designs") still lands in Direction, and a `decision`-typed bead whose
  description is really a small chore does not. The description and the code
  in reach are still the evidence; the type is one more piece of it, free and
  usually right.
- Cite ADR-0009:85-92 for "documentation of an existing seam, not a new
  mechanism".

### Success Criteria:

#### Automated Verification:

- [ ] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
      (regression only - no test asserts on skill prose)
- [ ] `grep -n 'always_batchable' skills/wurk:work/SKILL.md` is non-empty
- [ ] `grep -n 'bd close' skills/wurk:work/SKILL.md` is non-empty (the
      manual-close instruction is present)
- [ ] `grep -niE '\b(statifier|predicator|fixative|riddler)\b' skills/wurk:work/SKILL.md` is empty - no consumer named in a generic skill
- [ ] The upstream section precedes the `/wurk:branch` invocation in file
      order: `grep -n 'upstream\|/wurk:branch' skills/wurk:work/SKILL.md`
      shows the first `upstream` hit above the first `/wurk:branch` hit

#### Manual Verification:

- [ ] Walk the skill top to bottom as a model would: an upstream bead in a
      main checkout reaches the exit before any `/wurk:branch` invocation, and
      an upstream bead in a workspace reaches the same exit before sizing
- [ ] The renumbering left no dangling cross-reference - every "step N"
      mention inside `wurk:work/SKILL.md` and in any other skill that names a
      `/wurk:work` step still points at the right one
- [ ] The report contents are stated concretely enough that two different
      sessions would produce the same shape of report
- [ ] The signal-not-override wording cannot be read as "type decides the
      bucket"

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

All in `skills/wurk:kit/scripts/test/select_batch_test.rb`, against the
`areas_wide` fixture manifest (prefix `zz`, `always_batchable: ["upstream"]`)
so nothing asserts on this repo's own vocabulary:

- The `upstream` verdict itself: emitted, informational, never in
  `data.recommended`, reason names `/wurk:work <the bead's own id>`.
- Precedence: `epic` beats `upstream`; `upstream` beats both `unlabeled` and
  an area label's `free`/collision path.
- The unreached-candidate path: an upstream bead the walk never reaches keeps
  its own reason rather than the ceiling reason. This is the edge case that a
  naive one-line change to `walk`'s skip arm silently gets wrong.
- Manifest-driven: with `always_batchable: []`, the literal label "upstream"
  is just an unrecognized label and the bead is `unlabeled`.

`areas_test.rb` needs no new case - `Areas.upstream?` is unchanged, and its
existing manifest-driven tests (`areas_test.rb:38-41, 54-65, 68-76`) already
cover the predicate.

### Manual Testing Steps:

1. In this checkout, temporarily set `.claude/wurk.json`'s
   `beads.areas.always_batchable` to `["upstream"]`, label a scratch bead
   `upstream`, and run
   `ruby skills/wurk:kit/scripts/select_batch.rb --auto`: the bead shows as a
   candidate with verdict `upstream`, appears in `skipped` with the
   `/wurk:work` reason, and is absent from `recommended`. **Revert both the
   manifest edit and the label afterwards** - this repo ships
   `always_batchable: []` and has no upstream beads.
2. With the same temporary setup, run `/wurk:next` and confirm the candidate
   table shows the bead, the picker does not offer it, and nothing is claimed
   for it and no workspace is created.
3. With the same temporary setup, run `/wurk:work <that bead>` from the main
   checkout and confirm it claims the bead, creates no branch and no
   workspace, and reports the sibling repo (or says the bead does not name
   one) plus the manual-close instruction.
4. Re-read `/wurk:work`'s bucket table and confirm a `task`-typed bead whose
   description is a direction question would still be routed to Direction on
   a plain reading.
5. Merge-time: the prose judge (`.claude/wurk/mr.md`, ADR-0008) runs over the
   changed `skills/**/SKILL.md` files at `/wurk:mr`. This is not part of the
   required gate by design, so expect it there and not in `run.rb`.

## Open Questions

None block implementation. One judgment call was made here in the absence of
a human and is recorded so it can be overturned cheaply:

- **Step renumbering in `wurk:work/SKILL.md`.** Phase 2 inserts the upstream
  exit as a new "Step 0" and renumbers "Locate self" to "Step 0.5", which
  keeps steps 1-5 stable and matches the `0.5` convention already used in
  `wurk:next/SKILL.md`. The alternative - folding the check into the existing
  step 0 as its first bullet - avoids renumbering entirely but buries an exit
  path inside a section named "Locate self", which is the kind of burial
  ADR-0009 says caused the gap in the first place (the word "upstream"
  already appeared in this file, in "upstream of the workspace", with no exit
  behind it). If review prefers the fold, it is a small edit confined to
  phase 2 and changes no criterion in this plan.

## References

- Binding decision: `docs/adr/0009-upstream-beads-without-a-workspace.md`
- Related ADRs: `docs/adr/0004-manifest-and-extension-seams.md` (the schema
  test this plan does not trip), `docs/adr/0008-merge-time-judge-over-generic-skill-prose.md`
  (why skill prose is judged at merge, not in the gate)
- Project rules: `CLAUDE.md`, `docs/architecture.md`, `docs/manifest.md`
- Verdict mechanics: `skills/wurk:kit/scripts/select_batch.rb:221-241`,
  `:276-339`
- Existing coverage to rewrite:
  `skills/wurk:kit/scripts/test/select_batch_test.rb:108-119`
- Skills changed: `skills/wurk:next/SKILL.md:160-166`,
  `skills/wurk:work/SKILL.md:51-78`, `:126-139`,
  `skills/wurk:issue/SKILL.md:125-130`
- Bead: `wu-lyc` (supersedes predicator-ex `px-uio`; unblocks predicator-ex
  `px-ttt`'s `always_batchable` adoption)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Read the new verdict row against `select_batch.rb`'s emitted reason
      string - the table's wording and the script's wording agree
- [ ] The reason string reads as an instruction a model will follow
      (`run /wurk:work <id>`), not as a bare classification
- [ ] No regressions in the rest of the verdict table: `epic`, `unlabeled`,
      `lands-alone`, `collides-with-live-worktree` are unchanged in meaning
- [ ] All four statements of the phrase (`docs/manifest.md`, `lib/areas.rb`,
      `wurk:next/SKILL.md`'s verdict row, `wurk:issue/SKILL.md`) say the same
      thing, and all four are in this one commit
- [ ] The new `docs/manifest.md` section reads as reference material,
      matching its neighbours' register

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

# /wurk:verify - working the deferred-verification and open-question backlog

## Overview

`/wurk:work --auto` ends by naming two kinds of loose end - the Deferred
Manual Verification (DMV) items `/wurk:implement --loop` pushed into the plan
document, and the open questions a stage recorded in its artifact - and then
nothing in the workflow works that list. This plan adds `/wurk:verify`, a
skill that enumerates both backlogs mechanically, walks them with a human one
at a time, verifying and fixing as it goes, escalates an item that turns out
to be a decision to the Direction stage, marks each item as it is worked so an
interrupted pass resumes, and finishes with a summary plus an optional
`/wurk:commit` touch-up.

Two kit additions make the enumeration mechanical rather than a matter of what
the session remembers: `plan_state.rb` learns to read and tick the deferred
section it can already write, and a new `backlog.rb` composes that with an
open-questions reader across the documents a bead owns.

Beads issue: `wu-7l5`.

## Current State Analysis

The two halves of the backlog are not symmetric, and the plan is shaped by
that asymmetry (research:
`docs/research/260819-wu-7l5-dmv-and-open-question-backlog-skill.md`).

**DMV is a real, machine-parsed grammar with a writer and no reader.**
`DEFERRED_HEADING_RE` (`skills/wurk:kit/scripts/plan_state.rb:29`) anchors
`## Deferred Manual Verification`; `run_defer` (`plan_state.rb:328-402`)
creates the section with a fixed three-line intro, appends one `### Phase N`
subheading per phase, and copies the phase's Manual Verification block
verbatim. What the kit cannot do is read the items back or tick one:
`find_deferred_section` (`plan_state.rb:154-157`) reports only
`{present:, line:}`, and `resolve_targets` (`plan_state.rb:301-318`) both
bulk-toggles automated boxes only and explicitly refuses a `--line` that
names a Manual box (`manual_verification_refused`). A deferred line is in
neither `phase[:automated_items]` nor `phase[:manual_items]`, so even the
`--line` form blocks with `not_a_checkbox` today.

Two parsing quirks matter. `manual_block_lines` (`plan_state.rb:162-187`)
copies everything between the `#### Manual Verification:` heading and the
next level 2-4 heading, so `**Implementation Note**:` paragraphs and `---`
rules land inside the deferred section alongside the checkboxes (live example:
`docs/plans/260808-wu-gd1-gate-rb-manifest-driven-constants.md` from line 722).
And checkbox items routinely wrap onto indented continuation lines, which
`extract_checkbox_section` (`plan_state.rb:130-152`) folds back into one
`text` inside a phase but which nothing folds inside the deferred section.

The backlog is concrete: all 13 plans under `docs/plans/` carry the section,
7 of them still hold 92 unchecked items, and
`docs/plans/260816-wu-z6n-atomic-claim-inside-auto-walk.md` is half-walked
(4 unchecked, 7 checked) - resume is a real case, not a hypothetical.

**Open questions have no grammar at all.** The heading is optional
everywhere and appears in four distinguishable forms across 15 sections
(`## Open Questions`, `## Open questions`, one `### Open questions` inside
ADR-0010's amendment, and one with a parenthetical suffix at
`docs/plan.md:1266`). Content is prose in some documents and numbered
bold-lead-in lists in most. No document anywhere uses checkboxes for one -
`- [ ]` is reserved for plan success criteria. Resolution is marked three
ways: strikethrough plus bold Settled (`docs/plan.md:1278-1280`), a nested
`**Settled after the loop**` sub-note
(`docs/plans/260810-wu-2cb-default-branch-base-ref-from-manifest.md:821-823`),
and an inline `Resolved:` prefix
(`docs/research/260810-wu-ubm-direction-model-reality-vs-doc.md:60`). Nothing
parses any of it.

The same heading also carries two meanings. In a research document it means
"genuinely unresolved" (`skills/wurk:research/SKILL.md:231-233`). In the three
plans that carry one it means "a non-blocking judgment call, recorded so it
can be overturned cheaply", because `/wurk:plan` forbids unresolved questions
in a final plan (`skills/wurk:plan/SKILL.md:336`, `:399-401`) while
`/wurk:work` simultaneously tells every stage subagent to record open
questions in the artifact it produces (`skills/wurk:work/SKILL.md:266-270`).

**Finding a bead's artifacts is already solved.** `WorkState.doc_id_pattern`
and `find_docs` (`skills/wurk:kit/scripts/work_state.rb:25-38`) match
`doc_meta.rb`'s `YYMMDD-[issue-id-]kebab-description.md` grammar against the
manifest's `artifacts.plans` and `artifacts.research` directories. No
`artifacts.*` field names an ADR directory, so no script can locate ADRs.

**Direction is prose, not a skill.** It is the one stage-table row with
nothing to mirror: no stage skill, a prompt composed directly into the Agent
call (`skills/wurk:work/SKILL.md:241-246`, `:256-260`, `:277-301`), and a
model read from the manifest's `models.direction` (accessor at
`skills/wurk:kit/scripts/lib/manifest.rb:422-424`, default `opus`).

**Adding a skill is mechanically free.** `install.rb:49` globs
`skills/wurk:*`; there is no registry. `contract_test.rb:559-582` scans every
shipped `SKILL.md` for consumer vocabulary and asserts every skill directory
contributes one, so a new skill lands in the judged surface automatically.

## Desired End State

`skills/wurk:verify/SKILL.md` exists and is installed by the same glob as
every other skill. Given a bead id or a document path, it:

1. runs `backlog.rb` to enumerate both backlogs from the documents on disk,
   never from the session's recollection of a `/wurk:work` report;
2. walks the items one at a time, verifying each against the code and fixing
   what is wrong in the working tree;
3. escalates an item that turns out to be a decision rather than a check to
   the Direction stage as `/wurk:work` defines it, on the manifest's
   `models.direction`;
4. ticks each confirmed DMV item through `plan_state.rb confirm` and appends a
   `**Settled (YYYY-MM-DD):**` note under each settled open question, so a
   second invocation resumes where the first stopped;
5. ends with a summary and, when the pass changed anything, one touch-up
   commit through `/wurk:commit` - never a bare `git commit`;
6. honors `.claude/wurk/verify.md`, and contains no consumer constant.

`/wurk:work`'s step 5 report points at it as the way to work the loose ends it
lists, and a contract test fails if that reference (or any other `/wurk:<name>`
reference in any skill) stops resolving to a shipped skill.

**How to verify**: `ruby skills/wurk:kit/scripts/test/run.rb` is green;
`ruby skills/wurk:kit/scripts/backlog.rb wu-7l5` reports this bead's own
documents; and a walk over one of the seven plans that still hold unchecked
items ticks boxes in that file and leaves the rest of the corpus untouched.

### Key Discoveries

- `plan_state.rb:29` and `:328-402` - the deferred grammar, its single writer,
  and the fixed intro paragraph.
- `plan_state.rb:301-318` - the standing rule that `check`/`uncheck` never
  touch a Manual box. This plan adds a second verb rather than relaxing it.
- `plan_state.rb:130-152` - continuation folding, which the deferred reader
  must repeat.
- `work_state.rb:25-38` - the bead-to-artifact lookup `backlog.rb` reuses.
- `skills/wurk:work/SKILL.md:266-270` - the "no human is available" invariant
  that governs whether this skill may run unattended.
- `skills/wurk:implement/SKILL.md:165-170`, `:264` - "Do not remove the
  section from the plan" and "Do not check off manual testing steps until the
  user confirms them". This skill automates the walking, never the deciding.
- `skills/wurk:iterate/SKILL.md:14-16` - "link to it by name rather than
  restating it - two copies drift", the stated cross-skill sharing idiom.
- **ADR-0008** - policy calls, human gates, and verification disciplines stay
  stated in the skill's own prose; a script reports inputs and the model
  decides; prose that turns a discipline into a check on its own artifact is
  the named failure mode. This constrains every marker decision below.
- **ADR-0006** - the banned-operation list is absolute, which is why the
  touch-up commit goes through `/wurk:commit`.
- **ADR-0004** - `.claude/wurk.json` for machine constants,
  `.claude/wurk/<skill>.md` for domain prose; a consumer needing different
  generic behavior means the schema is missing a field.
- `docs/plans/260808-wu-gd1-gate-rb-manifest-driven-constants.md` and
  `docs/plan.md:1078-1081` - two DMV passes already done by hand, both of which
  produced real fixes and one of which produced a new bead. That is the report
  shape this skill reproduces.

## Settled Decisions

The research document closed with six questions. Each is settled here, with
its reasoning, so nothing below is left to the implementer's discretion.

**1. `docs/adr/` is out of scope for enumeration.** `backlog.rb` sweeps only
the directories the manifest names under `artifacts.plans` and
`artifacts.research`. Including ADRs would need either a new manifest field
(a schema change, plus `docs/manifest.md` in the same commit, per ADR-0004 and
`CLAUDE.md:25-27`) or a convention-based guess at the directory - which in a
generic skill would be a consumer constant, exactly what
`docs/architecture.md:29-35` forbids. Beyond the mechanics, an ADR's open
questions are the residue of a decision already accepted; resolving one is
Direction work that produces an amendment, not a verification walk. The escape
hatch costs nothing: `backlog.rb --doc <path>` accepts any markdown path, so a
human who wants an ADR swept can name it, and the manifest field can be added
later by the bead that actually wants ADR sweeps by default.

**2. The open-questions corpus is not normalized; the reader is lenient.**
`backlog.rb` matches `\A(\#{2,3}) Open [Qq]uestions\b`, which covers all 15
headings that exist today, including the level-3 amendment section and the one
with a parenthetical suffix, without touching a single file. Normalizing would
be a corpus-wide edit no bead asks for, over dated artifacts whose value is
that they are snapshots. The writer side needs no change either:
`/wurk:research`'s template already emits one canonical form
(`skills/wurk:research/SKILL.md:231`), so the variants are historical, and
tolerating them costs one character class.

**3. An open question is marked worked with a `**Settled (YYYY-MM-DD):**`
note, written by the model, not by a script.** This adopts the corpus's
existing nested-sub-note idiom
(`docs/plans/260810-wu-2cb-...:821-823`) rather than inventing a fourth, and
it deliberately does not use checkboxes: `- [ ]` is reserved in this repo for
plan success criteria and `CHECKBOX_RE` would then find items that are not
success criteria. The note is written with an editor, not a kit script,
because it carries the decision and its reason - judgment prose, not a
mechanical substitution, which is precisely the line ADR-0008 draws. Two
rules follow and are stated in the skill's prose: the marker records that the
pass reached the item, and is never evidence that the question is well
answered; and `backlog.rb` reports which marker string it saw
(`settled` / `resolved` / `strikethrough` / none) and never reports a question
as resolved.

**4. The Direction stage definition stays in `/wurk:work` and is cited by
name.** `skills/wurk:iterate/SKILL.md:14-16` states this as the repo's idiom,
and ADR-0008 turns the alternative into a hazard: the Direction prompt is
judgment prose, and the only document skills are told to go read is
`skills/wurk:kit/REFERENCE.md`, whose content is entirely script mechanics
(`docs/architecture.md:37-57` puts skills and the kit in different layers for
this reason). Moving a judgment prompt into the script layer's reference
blurs that boundary and is close to the failure mode ADR-0008 names. The
machine-readable half is already shared correctly: the model comes from the
manifest's `models.direction`, which both skills read. So `/wurk:verify`
states in its own prose *when* an item is a decision rather than a check -
that is its policy call and it must be stated here - and tells the session to
read `/wurk:work`'s "### Direction stage prompt" section to compose the
prompt. `/wurk:work` gets one sentence marking that section as the definition
another skill cites, so a future rewrite there sees the coupling. This
settles the bead's conditional ("if it needs to be shared, it should move
somewhere both can read") in the negative: it does not need to move.

**5. The skill is named `/wurk:verify`.** The bead proposed `/wurk:dmv` while
flagging the name as provisional, and the user subsequently steered to
`/wurk:verify`; this plan takes that steer, so the name is settled against the
bead's written text and with the author's later preference. The reason
`/wurk:dmv` loses: it names one of the two backlogs the skill works, and
"DMV" is an internal acronym that a reader meets before they meet the
"Deferred Manual Verification" heading it abbreviates. The one real objection
to `verify` is that "verification" is loaded vocabulary here - the gate, and
`/wurk:plan`'s Automated/Manual Verification split - so `/wurk:verify` could
read as "run the checks". Three things answer it: the backlog this skill
walks is literally called Deferred Manual *Verification*, so the overlap is
mostly a hit rather than a collision; running checks is already unambiguously
`/wurk:commit`'s and `gate.rb`'s job, and no skill in the family is named for
it; and the skill's `description` frontmatter names both backlogs, which is
what a reader picking between skills actually sees. `/wurk:settle` was
considered as a third option covering both halves with no vocabulary overlap,
and rejected as a close call that says nothing about verification at all -
close calls go to the user's suggestion. The bead's acceptance criteria were
read directly from the tracker while planning (`bd show wu-7l5`) and do name
`skills/wurk:dmv/SKILL.md` and `.claude/wurk/dmv.md` literally, so Phase 3
updates the bead text through `/wurk:issue` in the same pass rather than
leaving the tracker pointing at a path that will never exist. Every other
acceptance criterion on the bead is unaffected by the rename and is satisfied
as written.

**6. There is no `--auto` form.** The items in this backlog exist *because*
`/wurk:implement --loop` ran with no human available, and
`skills/wurk:implement/SKILL.md:264` is explicit that manual steps are not
checked off until the user confirms them. An `--auto` pass would tick those
boxes with no human in the loop, converting a human gate into an automated
one - the ADR-0008 failure mode, committed at the level of the whole skill.
What an unattended caller legitimately needs is the enumeration, and that is
already available read-only: `backlog.rb` is a plain script any session or
`/wurk:work` report can run. So the answer to "can it run unattended" is
"the reporting half can, and always could; the confirming half is the point
and stays interactive", and the skill says so in its Guidelines.

## What We're NOT Doing

- **Not sweeping `docs/adr/` by default**, and not adding an `artifacts.*`
  manifest field for a decisions directory. See Settled Decision 1;
  `--doc <path>` covers the occasional case.
- **Not normalizing the existing open-questions headings** across the corpus,
  and not editing any document this pass does not walk.
- **Not giving open questions checkboxes**, and not extending `CHECKBOX_RE`
  to reach them.
- **Not adding an `--auto` mode**, now or as a hidden flag.
- **Not moving the Direction stage prompt** out of `skills/wurk:work/SKILL.md`,
  and not creating a second shared reference document beside
  `skills/wurk:kit/REFERENCE.md`.
- **Not relaxing `check`/`uncheck`'s refusal to touch a Manual Verification
  box inside a phase** (`plan_state.rb:310-316`). The new verb operates only
  inside the deferred section.
- **Not removing the `## Deferred Manual Verification` section** from a plan
  once it is fully walked; `skills/wurk:implement/SKILL.md:165-170` says it
  stays, and the checked boxes are the record.
- **Not working the existing 92-item corpus backlog** as part of this bead.
  This plan ships the tool; the walk is separate work, and doing it here would
  make the phases neither independently committable nor reviewable.
- **Not having any script push, open a request, `bd close`, or `bd edit`**
  (ADR-0006). The touch-up commit is `/wurk:commit`; the bead text update in
  Phase 3 is `/wurk:issue`, driven by a human.
- **Not making `/wurk:verify` a mode of `/wurk:work`.** The bead already
  decided this: it runs after work finishes, on a different cadence, and is
  invoked by hand.

## Implementation Approach

Three phases, bottom-up, each independently committable and each green on the
kit suite by itself:

1. **`plan_state.rb` learns to read and tick the deferred section.** Additive
   only: new parse keys, a new read subcommand, and a new line-scoped mutating
   verb. Existing callers (`work_state.rb:117-126`,
   `skills/wurk:implement/SKILL.md`, `skills/wurk:iterate/SKILL.md:78`) keep
   working unchanged because nothing existing is removed or renamed.
2. **`backlog.rb` composes the two backlogs into one envelope.** It reuses
   `WorkState.find_docs` and `PlanState` rather than reimplementing either,
   and adds the one genuinely new thing: a lenient open-questions reader that
   labels each document by the manifest directory it came from, which is what
   makes the plan-versus-research semantic difference legible to the model.
3. **The skill and its wiring.** `skills/wurk:verify/SKILL.md`, the
   `/wurk:work` step 5 pointer, the docs/plan.md skill list, and a new
   contract test that keeps every `/wurk:<name>` cross-reference in every
   skill resolving to a shipped skill.

Phase 3 depends on both earlier phases; 1 and 2 are ordered because
`backlog.rb` calls the reader Phase 1 adds.

---

## Phase 1: `plan_state.rb` reads and ticks the deferred backlog

### Overview

Give the kit a reader for the section it already writes, and one line-scoped
verb that ticks a single deferred checkbox. Nothing else in `plan_state.rb`
changes behavior.

### Changes Required:

#### 1. The deferred-section parser

**File**: `skills/wurk:kit/scripts/plan_state.rb`
**Changes**: add a subheading regex and a `deferred_items` reader; enrich
`find_deferred_section` with counts. Both are additive.

```ruby
DEFERRED_SUBHEADING_RE = /\A### Phase (\d+)\s*\z/.freeze

# Every checkbox inside "## Deferred Manual Verification", tagged with the
# "### Phase N" subheading it sits under. Continuation lines are folded the
# same way extract_checkbox_section folds them inside a phase; non-checkbox
# prose that `defer` copied in verbatim (an "**Implementation Note**:"
# paragraph, a "---" rule) is skipped, not reported as an item.
def deferred_items(lines)
  # walk from find_deferred_section[:line] - 1 to the next H2_RE (or EOF),
  # tracking the current DEFERRED_SUBHEADING_RE phase number, collecting
  # { phase:, checked:, text:, line: } (line 0-indexed internally, 1-indexed
  # in the envelope, matching changed_lines elsewhere in this file).
end
```

`find_deferred_section` gains `total:` and `checked:` alongside `present:`
and `line:`. Existing assertions read `[:present]` and `[:line]`
(`test/plan_state_test.rb:77-78`, `:87`) and `work_state.rb:124` passes the
hash through, so added keys are safe.

#### 2. The `deferred` read subcommand

**File**: `skills/wurk:kit/scripts/plan_state.rb`
**Changes**: `SUBCOMMANDS` gains `deferred`; `run_deferred` emits
`path`, `deferred_manual_section`, and `items`. Read-only, no file write.
Blocks `file_not_found` for a missing path; warns `no_deferred_section` and
emits an empty item list when the section is absent (absence is normal for a
plan that never ran under `--loop`, so it is a warning, not a block).

#### 3. The `confirm` mutating verb

**File**: `skills/wurk:kit/scripts/plan_state.rb`
**Changes**: `SUBCOMMANDS` gains `confirm`.

```
plan_state.rb confirm <path> --line N [--undo] [--dry-run]
```

Toggles exactly one deferred checkbox to `[x]` (or back to `[ ]` with
`--undo`). It has no bulk form at all: a backlog is walked item by item, and
a verb that could tick a whole section in one call is the shape ADR-0008
warns about. Blocks:

- `not_deferred_item` - the line is outside `## Deferred Manual Verification`,
  or is not a `CHECKBOX_RE` line inside it. This is what keeps `confirm` from
  becoming a back door around `manual_verification_refused`
  (`plan_state.rb:310-316`), which stays exactly as it is.
- `file_not_found`, `no_deferred_section` - as above, the latter as a block
  here since there is nothing to confirm.

Envelope data mirrors `run_mutate`: `path`, `line`, `changed_lines`,
plus `item` (the folded text) so the caller can echo what it ticked. Under
`--dry-run` it populates `changed_lines` and `commands` and writes nothing.

#### 4. Fixture and tests

**File**: `skills/wurk:kit/scripts/test/fixtures/plans/deferred_backlog.md`
**Changes**: new fixture - a plan with a deferred section holding two
`### Phase N` subheadings, a mix of checked and unchecked items, one item
wrapped onto an indented continuation line, one `**Implementation Note**:`
paragraph and one `---` rule copied in verbatim, and at least one phase whose
in-phase Manual Verification block still exists (so the "confirm refuses an
in-phase Manual box" case has a real line to aim at).

**File**: `skills/wurk:kit/scripts/test/plan_state_test.rb`
**Changes**: new cases, following the file's existing split - pure-parse
cases in `PlanStateLibTest`, CLI cases in `PlanStateCliTest` against
`Dir.mktmpdir` copies via `copy_fixture` and the in-process `run_cli`
(`test/plan_state_test.rb:186-196`):

- `deferred_items` folds a continuation line into one item's `text`
- `deferred_items` skips the Implementation Note paragraph and the `---` rule
- each item carries the `### Phase N` number it sits under
- `find_deferred_section` reports correct `total`/`checked`, and still
  reports `present: false` on `missing_section.md`
- `deferred` emits the items read-only and leaves the file byte-identical
- `deferred` warns `no_deferred_section` on a plan without one
- `confirm --line N` ticks exactly that line and no other
- `confirm --line N --undo` reverses it
- `confirm --line N --dry-run` reports `changed_lines` and leaves the file
  byte-identical
- `confirm` blocks `not_deferred_item` for an in-phase Manual Verification
  box, for an Automated box, and for a prose line inside the section
- `check --line N` targeting an in-phase Manual box still blocks
  `manual_verification_refused` (regression guard on the untouched rule)

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] `plan_state.rb --help` and the usage line list `deferred` and `confirm`
- [x] `ruby skills/wurk:kit/scripts/plan_state.rb deferred docs/plans/260816-wu-z6n-atomic-claim-inside-auto-walk.md`
      reports 4 unchecked and 7 checked items, matching the research
      document's count for that file
- [x] `contract_test.rb` still passes with the new subcommands present
      (`--dry-run` on the mutating verb, no banned calls, no backticks)
- [x] The regression case holds: `check --line N` aimed at an in-phase Manual
      Verification box still blocks `manual_verification_refused`, and
      `defer` still appends a phase's block unchanged (both asserted in
      `test/plan_state_test.rb`)

#### Manual Verification:
- [ ] `deferred` over two or three of the seven plans that still hold
      unchecked items reads them the way a human reads them - no split
      continuation lines, no prose masquerading as an item
- [ ] `confirm --dry-run` against a real plan reports the line a human would
      have ticked by hand
- [ ] Run `/wurk:implement --loop` over one phase of a small real plan and
      confirm its `defer` and `check` calls behave exactly as before: the
      phase's manual block lands under a fresh `### Phase N`, the automated
      boxes tick, and the new subcommands are not reached

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: `backlog.rb` enumerates both backlogs for a bead

### Overview

One read-only script that answers "what is left to work on this bead", by
composing the Phase 1 reader with a lenient open-questions reader over the
documents the manifest's `artifacts.*` directories hold.

### Changes Required:

#### 1. The script

**File**: `skills/wurk:kit/scripts/backlog.rb` (new, `chmod +x`, shebang)
**Changes**: built to `skills/wurk:kit/REFERENCE.md:404-427` - `lib/envelope`,
`lib/sh`, `lib/cli`, `lib/manifest`, plus `require_relative` of `plan_state`
and `work_state` for their pure modules.

```
backlog.rb <bead-id> [--doc PATH ...]
backlog.rb --doc PATH [--doc PATH ...]
```

- With a bead id: `WorkState.find_docs` over `manifest.plans_dir` and
  `manifest.research_dir`, mirroring `work_state.rb:69-85`, including its
  `multiple_plan_docs` / `multiple_research_docs` warnings. Unlike
  `work_state.rb`, every match is reported rather than the first, because a
  backlog walk wants all of them.
- With `--doc`: that exact path, `kind` resolved by which manifest directory
  contains it, or `"other"` when neither does. This is the ADR escape hatch
  from Settled Decision 1.
- Both together are allowed and de-duplicated by path.

Per document the envelope reports:

```ruby
{
  path: "...",
  kind: "plan" | "research" | "other",
  deferred: { present:, line:, total:, checked:, items: [...] },  # Phase 1
  open_questions: [
    { heading: "## Open Questions", level: 2, line: 41,
      items: [{ line: 43, text: "...", settled_marker: "settled" | "resolved" | "strikethrough" | nil }] }
  ]
}
```

plus a top-level `totals: { documents:, deferred_unchecked:,
open_question_items_unmarked: }`.

#### 2. The open-questions reader

**File**: `skills/wurk:kit/scripts/backlog.rb`
**Changes**:

```ruby
# Lenient by decision, not by accident: this matches every Open Questions
# heading the corpus has today (title and sentence case, level 2 and 3, an
# optional parenthetical suffix) without any document being rewritten.
OPEN_QUESTIONS_RE = /\A(\#{2,3}) Open [Qq]uestions\b/.freeze

# A marker this reader saw - never a claim the question is answered. A script
# can see that a note exists; whether the question is settled is the reader's
# call (ADR-0008).
SETTLED_MARKERS = {
  "settled" => /\*\*settled\b/i,
  "resolved" => /\A\s*[-*]?\s*(\*\*)?resolved\b/i,
  "strikethrough" => /~~/
}.freeze
```

The block runs from the heading to the next heading of the same level or
higher, or EOF. Items are the block's top-level numbered (`1.`) or bulleted
(`- ` / `* `) entries with their indented continuations folded in; a block
with neither is reported as one item holding the whole paragraph, which is
what the `"None blocking."` documents need. `settled_marker` is computed over
the item's own folded text only.

#### 3. Tests

**File**: `skills/wurk:kit/scripts/test/backlog_test.rb` (new)
**File**: `skills/wurk:kit/scripts/test/fixtures/` - a small research-shaped
fixture with a numbered open-questions list (one entry carrying a `**Settled`
sub-note, one carrying `Resolved:`, one plain), a fixture with sentence-case
`## Open questions` holding a single `None blocking.` paragraph, and a
fixture with a level-3 `### Open questions` nested under a later `##`
section. Reuse the Phase 1 `deferred_backlog.md` plan fixture rather than
duplicating it.

Cases, using `ManifestHelper` to install a fixture manifest whose
`artifacts.*` point at a `Dir.mktmpdir` tree, and the in-process
`run(argv, io: StringIO.new)` pattern from `plan_state_test.rb:192-196`:

- a bead id with one plan and one research doc reports both, each with the
  right `kind`
- a bead id with no matching documents emits `ok: true` with a
  `no_documents` warning and empty totals (an unworked bead is not an error)
- title case, sentence case, and the level-3 heading are all found
- a heading with a parenthetical suffix is found
- the block stops at the next same-level heading, and a level-3 block stops
  at the next `##`
- numbered items split correctly, continuations fold, and a prose-only block
  yields exactly one item
- `settled_marker` reports `settled` / `resolved` / `strikethrough` / `nil`
  per item, and no item is ever reported with a boolean "resolved" field
- `deferred` totals match what `plan_state.rb deferred` reports for the same
  fixture (the composition, not a second parser)
- `--doc` on a path outside both manifest directories reports `kind: "other"`
- `--doc` on a missing path blocks `file_not_found`
- an invalid manifest blocks through `Manifest.require!`, and the script
  writes nothing under any input (it is read-only; assert no file in the
  tmpdir changed)

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [ ] `ruby skills/wurk:kit/scripts/backlog.rb wu-7l5` exits 0 and reports
      this bead's research document with its six open-question items
- [ ] `contract_test.rb`'s shebang/executable-bit, banned-call, no-backticks,
      and no-consumer-vocabulary scans all cover the new script and pass
- [ ] `backlog.rb --help` documents `<bead-id>` and `--doc`

#### Manual Verification:
- [ ] Run over three or four real beads with artifacts: every open-questions
      heading a human can find in those documents appears in the output, and
      nothing that is not one appears
- [ ] The `kind` label makes the plan-versus-research semantic difference
      legible - a plan's questions read as recorded judgment calls, a
      research document's as genuinely open
- [ ] Output is small enough to be useful in a session without flooding it

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: the `/wurk:verify` skill and its wiring

### Overview

The skill itself, the `/wurk:work` pointer that makes it discoverable, the
docs entry, and a contract test that keeps skill-to-skill references honest.

### Changes Required:

#### 1. The skill

**File**: `skills/wurk:verify/SKILL.md` (new)
**Changes**: frontmatter in the family's shape - `name: wurk:verify`,
`model: opus` (the pass makes judgment calls about correctness and dispatches
Direction; it sits with plan/research/work/iterate, not with the sonnet
mechanics skills), `argument-hint: ["a bead id, or a plan/research document
path"]`, and a `description` ending with the fixed clause
"Reads .claude/wurk.json; honors .claude/wurk/verify.md." The description
names both backlogs, since that is what disambiguates the name.

Body, in the family's order:

- title, short intro, the fixed `~/.claude/skills/wurk:kit/REFERENCE.md`
  pointer sentence
- `## Project extension` - read `.claude/wurk/verify.md` before step 1;
  extensions add, never override; typical content: what "verified" means for
  a domain, extra checks a project always wants in this pass
- `## Input` - a bead id (manifest `beads.prefix` shape) or one or more
  document paths. **No `--auto`**, stated with Settled Decision 6's reason
- `## Step 1: Enumerate` - run `backlog.rb`, report the counts per document
  before walking anything. State plainly that the list comes from the
  documents on disk, not from what a `/wurk:work` report said
- `## Step 2: Walk the items` - one at a time, in document order, DMV items
  before open questions within each document. For each: restate the item,
  read the code or documents it asserts about, say what was found, and fix
  what is wrong in the working tree. Not a read-only audit; not a batch of
  blind edits. An item already ticked or already carrying a settled marker is
  skipped, which is what makes a second invocation a resume
- `## Step 3: Escalate a decision` - the policy call stated here: an item is
  a decision rather than a check when confirming it would require choosing
  between defensible alternatives, when the fix would change an interface or
  a stated rule, or when the item contradicts an accepted decision record.
  Then dispatch the Direction stage as `/wurk:work` defines it - read that
  skill's "### Direction stage prompt" section and compose the prompt from
  it, on the model at the manifest's `models.direction` - rather than
  restating the prompt here. The escalation produces a record, not an edit;
  the walk resumes with its answer
- `## Step 4: Mark it worked` - a confirmed DMV item goes through
  `plan_state.rb confirm <path> --line N`; a settled open question gets a
  `**Settled (YYYY-MM-DD):**` note appended under it, saying what was decided
  and why. Both are stated as recording that the human confirmed, never as
  the confirmation itself
- `## Step 5: Summarize and commit` - the summary names every item walked and
  its outcome, every fix made, and everything filed rather than fixed. When
  the pass changed anything, one touch-up commit through `/wurk:commit`.
  Never a bare `git commit`, never `bd close`
- `## Guidelines` - the human confirms, the skill walks; the marker is a
  resume aid and never evidence; work discovered along the way is filed with
  `/wurk:issue` and linked, not chased; no unattended form, and why; the
  deferred section stays in the plan when the walk is done

The whole file must survive `contract_test.rb`'s consumer-vocabulary scan:
no bead prefix, no repo path, no gate command, no consumer ADR number.

#### 2. The `/wurk:work` pointer

**File**: `skills/wurk:work/SKILL.md`
**Changes**: two edits.

- Step 5's report bullet ("any **Deferred Manual Verification** items the loop
  surfaced, and any open questions a stage recorded in its artifact",
  `:343-344`) gains a following sentence naming `/wurk:verify` as the way to
  work them.
- The "### Direction stage prompt" section gains one sentence marking it as
  the definition `/wurk:verify` cites, so a later rewrite there sees the
  coupling (Settled Decision 4).

#### 3. Docs

**File**: `docs/plan.md`
**Changes**: add `/wurk:verify` to the skill list at `:138-153` so the
family roster stays complete. No `README.md` or `docs/architecture.md` change:
both describe the family generically.

#### 4. The cross-reference contract test

**File**: `skills/wurk:kit/scripts/test/contract_test.rb`
**Changes**: a new case beside the existing markdown scans
(`:559-582`): every `/wurk:<name>` reference in any shipped `SKILL.md`
resolves to a `skills/wurk:<name>/` directory that exists. This is what makes
Phase 3's `/wurk:work` pointer gate-verifiable rather than merely written, and
it guards the same drift `CLAUDE.md:52-55` makes a rename responsible for.

```ruby
SKILL_REF_RE = %r{/wurk:([a-z][a-z0-9-]*)}.freeze
```

This pattern was run over the shipped skills at planning time and yields
exactly the fourteen names that have directories today, so it starts green
with no pre-existing reference to fix. Add the meta-check the file's other
scans carry: assert the scan found at least one reference, so a moved glob
cannot make it vacuous.

#### 5. The bead text

**File**: none in this repo.
**Changes**: update wu-7l5's description and acceptance criteria through
`/wurk:issue` so they name `skills/wurk:verify/SKILL.md` and
`.claude/wurk/verify.md` instead of the provisional `dmv` spellings
(Settled Decision 5). This is a tracker edit driven by a human, not a script:
`bd edit` is a banned operation for kit scripts (ADR-0006).

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [ ] `contract_test.rb`'s `test_markdown_scans_cover_every_shipped_skill`
      sees `skills/wurk:verify/SKILL.md`
- [ ] The consumer-vocabulary scan finds nothing in the new SKILL.md
- [ ] The new cross-reference test passes, and fails if
      `skills/wurk:verify/` is renamed without updating `/wurk:work`
      (verify by planting the rename in a scratch copy, as the file's other
      meta-checks do)
- [ ] `ruby install.rb --dry-run` lists the new skill directory

#### Manual Verification:
- [ ] Invoke `/wurk:verify` on a bead that has a half-walked plan: it
      enumerates the remaining items, skips the ones already ticked, and
      walks the rest one at a time
- [ ] An item that is really a decision escalates to Direction on the
      manifest's model and returns a record, rather than being silently
      decided in the walk
- [ ] A settled open question ends with a `**Settled (...)**` note that reads
      naturally beside the corpus's existing ones, and a re-invocation skips it
- [ ] The pass ends with a summary and a single `/wurk:commit` touch-up, with
      nothing pushed and no bead closed
- [ ] Read the new SKILL.md against ADR-0008: every policy call, human gate,
      and verification discipline is stated in its own prose, and no step
      hands one to a script
- [ ] The name reads right in use - typing `/wurk:verify` and reading its
      description does not suggest "run the gate"

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

- `test/plan_state_test.rb` - the deferred reader (folding, prose skipping,
  phase tagging, counts) in `PlanStateLibTest`; `deferred` and `confirm`
  including `--dry-run`, `--undo`, and every block code in
  `PlanStateCliTest`. The regression guard that `check --line` still refuses
  an in-phase Manual box is as important as the new cases: it is the rule the
  new verb is designed not to weaken.
- `test/backlog_test.rb` - document discovery by bead id and by `--doc`, the
  `kind` labelling, every heading variant the corpus contains, block
  boundaries at same-level and higher-level headings, item splitting and
  continuation folding, marker reporting, the `no_documents` warning, and the
  read-only assertion that no fixture file changes.
- `test/contract_test.rb` - the new cross-reference scan, plus its
  non-vacuity meta-check.

Edge cases worth naming: a deferred section that is the last thing in the
file (no following `##`); a `### Phase N` subheading with no items under it;
an open-questions heading as the last line of a file; a document with two
open-questions sections (ADR-0010's shape, reachable through `--doc`); and a
plan with a deferred section but zero checkboxes.

### Manual Testing Steps:

1. `ruby skills/wurk:kit/scripts/plan_state.rb deferred <a plan with unchecked items>`
   and compare against reading the section by eye.
2. `ruby skills/wurk:kit/scripts/plan_state.rb confirm <path> --line N --dry-run`,
   then without `--dry-run`, and confirm exactly one line changed with
   `git diff`.
3. Run `/wurk:implement --loop` over one phase of a small real plan and
   confirm `defer` and `check` still behave as they did before Phase 1
   (fresh `### Phase N` block appended, automated boxes ticked, nothing in
   the deferred section ticked).
4. `ruby skills/wurk:kit/scripts/backlog.rb <a bead with both artifacts>` and
   check every heading a human can find is reported.
5. Invoke `/wurk:verify` on a bead with a real backlog; walk two or three
   items, including one that needs a fix and one that is really a decision.
6. Interrupt the pass, re-invoke, and confirm it resumes rather than
   restarting.
7. Confirm the pass ends with a summary and one `/wurk:commit` touch-up, and
   that nothing was pushed and no bead was closed.

## References

- Source document:
  `docs/research/260819-wu-7l5-dmv-and-open-question-backlog-skill.md`
- Related ADRs: `docs/adr/0004-manifest-and-extension-seams.md`,
  `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`,
  `docs/adr/0008-merge-time-judge-over-generic-skill-prose.md`
- Grammar and writer: `skills/wurk:kit/scripts/plan_state.rb:29`, `:130-152`,
  `:154-157`, `:301-318`, `:328-402`
- Artifact lookup to reuse: `skills/wurk:kit/scripts/work_state.rb:25-38`,
  `:69-85`
- Direction stage definition: `skills/wurk:work/SKILL.md:241-260`, `:277-301`
- Report obligation this skill answers: `skills/wurk:work/SKILL.md:340-346`
- Handoff rules: `skills/wurk:implement/SKILL.md:165-170`, `:264`
- Cross-skill sharing idiom: `skills/wurk:iterate/SKILL.md:14-16`
- New-script recipe and envelope: `skills/wurk:kit/REFERENCE.md:91-176`,
  `:404-427`
- Similar implementation to model the script on:
  `skills/wurk:kit/scripts/work_state.rb:50-126`
- Prior hand-run passes:
  `docs/plans/260808-wu-gd1-gate-rb-manifest-driven-constants.md`,
  `docs/plan.md:1078-1081`
- Bead: wu-7l5

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] `deferred` over two or three of the seven plans that still hold
      unchecked items reads them the way a human reads them - no split
      continuation lines, no prose masquerading as an item
- [ ] `confirm --dry-run` against a real plan reports the line a human would
      have ticked by hand
- [ ] Run `/wurk:implement --loop` over one phase of a small real plan and
      confirm its `defer` and `check` calls behave exactly as before: the
      phase's manual block lands under a fresh `### Phase N`, the automated
      boxes tick, and the new subcommands are not reached

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

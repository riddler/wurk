# Host-Project Orientation for the Codebase Agents Implementation Plan

## Overview

Thread host-project orientation to the three `wurk-codebase-*` agents through
one new agent-family extension file, `.claude/wurk/codebase.md`: the spawning
skills forward it verbatim into codebase-agent prompts, and the agents that
can read fall back to reading it themselves. The direction is settled by
ADR-0011; this plan implements only what its Consequences section names.

Beads Issue: `wu-mkm`

## Current State Analysis

**The agents carry no host-project knowledge.** Phase 2 step 3 of the
migration (`docs/plan.md:988-1000`) stripped the consumer-specific blocks from
the three codebase agents and replaced them with a layered "Orienting"
section. Each ladder today has exactly three rungs:

- `agents/wurk-codebase-locator.md:42-64` - prompt, then repo orientation
  documents, then a directory listing. Tools: `Grep, Glob, LS` (no `Read`).
- `agents/wurk-codebase-analyzer.md:42-61` - prompt, then repo orientation
  documents, then the code itself. Tools: `Read, Grep, Glob, LS`.
- `agents/wurk-codebase-pattern-finder.md:41-61` - prompt, then repo
  orientation documents, then a directory listing. Tools: `Grep, Glob, Read,
  LS`.

**Three skills spawn these agents**, verified by grepping `skills/` for
`wurk-codebase-`:

- `skills/wurk:research/SKILL.md:98-100` (spawn menu), with the existing
  forwarding paragraph for the docs pair at `:113-117`.
- `skills/wurk:plan/SKILL.md:101-103` (spawn menu), with the docs-pair
  forwarding folded into the `wurk-docs-locator` bullet at `:104-106`.
- `skills/wurk:iterate/SKILL.md:91-97` (spawn menu by reference to
  `/wurk:plan` step 1.2, plus its own `artifacts.*` sentence at `:95-96`).

No other skill references a `wurk-codebase-*` agent; `wurk:work` reaches them
only indirectly, by dispatching `/wurk:research` and `/wurk:plan` as
subagents.

**Each of the three skills already has a "Project extension" section** that
names the point in the flow where its own `.claude/wurk/<skill>.md` is read
(`skills/wurk:research/SKILL.md:25-30`, `skills/wurk:plan/SKILL.md:17-23`,
`skills/wurk:iterate/SKILL.md:21-25`). That is the natural place to add the
codebase-file read, per ADR-0011 point 2.

**The seam is documented in three places in this repo**, all of which describe
extensions as strictly per-skill:

- `docs/architecture.md:17-22` (the layer diagram) and `:68-92` (layer 4,
  "Optional per-skill markdown at `.claude/wurk/<skill>.md`").
- `docs/plan.md:131-132` (the four-layer restatement).
- `README.md:13-14` ("optional per-skill extension files").

`docs/manifest.md` and `lib/manifest.rb` do not enumerate extension files at
all - `docs/manifest.md:307-309` mentions them only as a fact about the
`.claude/` directory in the conflict-allowlist rules. Both stay untouched,
which ADR-0011 states as a property of the decision rather than an omission.

**The extraction routing is already past its execution point.** ADR-0011
point 6 says the orientation rows of phase 2 step 2's extraction table
(`docs/plan.md:898-907`) are written to `codebase.md` "when step 7 writes
statifier's extensions" - but step 7 is DONE (`docs/plan.md:1061-1064`), and
`~/repos/github/statifier-ex/.claude/wurk/` already holds `research.md` and
`plan.md` carrying exactly that content (the pipeline vocabulary, the tree
map, the good-search-keys list, the Appendix D pseudocode rule, the common
patterns). The reroute is therefore retroactive: a note on the historical
steps plus a new follow-on step, not an edit to a completed one.

**The gate is unaffected.** `ruby skills/wurk:kit/scripts/test/run.rb` covers
`skills/wurk:kit/scripts/` only; no test in `skills/wurk:kit/scripts/test/`
asserts on agent files or on non-kit `SKILL.md` prose. Every phase here is
prose, so the gate is a regression check that nothing else moved, not a
verification that the change works.

## Desired End State

A consumer repo may drop a `.claude/wurk/codebase.md` into place and have its
content reach every `wurk-codebase-*` agent invocation, by two paths:

1. **Fast path**: `/wurk:research`, `/wurk:plan`, and `/wurk:iterate` read the
   file where they read their own extension and paste it verbatim into each
   codebase-agent prompt under a fixed heading.
2. **Standalone path**: each codebase agent's Orienting ladder has a second
   rung naming the file, used when the prompt supplied no orientation.

A repo with no `codebase.md` - or no `.claude/` at all - behaves exactly as it
does today: the ladder falls through to repo orientation documents and a
listing, nothing warns, nothing fails.

Verification: the four criteria checks below, plus `git grep -n
'codebase\.md'` showing hits in exactly the three agent files, the three skill
files, `docs/architecture.md`, `docs/plan.md`, `README.md`, the ADR, and this
plan.

### Key Discoveries:

- ADR-0011 (`docs/adr/0011-codebase-orientation-extension-file.md`,
  uncommitted in the working tree) settles the direction. Do not re-open it;
  it extends ADR-0004 rather than amending it, so ADR-0004 itself is not
  edited by this plan.
- `agents/wurk-codebase-locator.md:4` - `tools: Grep, Glob, LS`. No `Read`.
  ADR-0011 point 3 handles this explicitly: the locator may Grep the file for
  its headings or skip the rung, because the fast path makes prompt-supplied
  orientation its common case.
- `skills/wurk:research/SKILL.md:113-117` is the pattern to model the
  forwarding paragraph on - it already says "the agents can find these
  themselves, but a skill that forgets costs every invocation an extra
  manifest read", which is the same argument in the same shape.
- `skills/wurk:iterate/SKILL.md:13-16` - `/wurk:plan` is the authority on shared
  rules and iterate links by name rather than restating. The forwarding
  instruction is short enough to state in all three, and ADR-0011 point 2
  names all three explicitly, so it is stated in each rather than referenced.
- `.claude/wurk.json` `judge.registry` scopes the ADR-0008 prose judge to
  `skills/**/SKILL.md`. Phase 3 lands inside that scope; it adds a step and
  deletes nothing, so it is judge-clean by construction, but the judge runs at
  merge time (`/wurk:mr`) and is not a per-phase gate.
- `docs/plan.md` is listed in `rebase.auto_resolve_paths`, so phase 4's edits
  there are expected to be conflict-prone across sibling branches and are
  handled by the bounded auto-resolution of ADR-0010.

## What We're NOT Doing

- **No manifest change.** `docs/manifest.md` and `lib/manifest.rb` are not
  touched. ADR-0011's Decision states this as a property of the choice; a
  `codebase` manifest section was priced and rejected in its Context.
- **No schema, lint, or validation for `codebase.md`.** ADR-0011 point 1:
  no schema, like every other extension file. No kit script reads it, so
  there is nothing for the contract test to cover.
- **No editing of ADR-0004.** ADR-0011 states how ADR-0004's sentence reads
  henceforth; accepted records are not rewritten in place.
- **No change to the docs pair** (`wurk-docs-locator`, `wurk-docs-analyzer`).
  ADR-0011's third open question defers that until a real case exists.
- **No truncation or excerpting policy** for a long `codebase.md`. ADR-0011's
  first open question defers it; forwarding is verbatim, and the
  one-screenful guidance stays advisory prose in the ADR rather than a rule
  in a skill.
- **No migration of statifier-ex's existing extension content.** That is a
  statifier-side edit in another repo. Phase 4 records it as a new step in
  `docs/plan.md` so it is tracked; filing and executing its bead is not this
  plan's work. See "Open Questions".
- **No new automated test.** Every change here is prose in files the kit
  suite does not read. Adding a grep-based prose assertion to the kit suite
  would couple `skills/wurk:kit/` to `agents/` and to sibling skills, which
  is exactly the coupling `docs/plan.md:1050-1055` removed on purpose.

## Implementation Approach

Four phases, ordered so no commit describes a mechanism that does not yet
exist: the record and the standalone path first, then the fast path, then the
documentation of the finished seam, then wurk's own dogfood file. Phases 2 and
3 are independent of each other and could be executed in either order or in
parallel worktrees; the stated order is the one that keeps each intermediate
commit truthful.

Every phase is prose-only. The kit suite is run in each as a regression check
- it must stay green, and it cannot go red from these edits, so it verifies
that nothing unintended moved rather than that the change works. The real
verification for each phase is manual, and the criteria say so explicitly.

Two constants are fixed here so all three skills and all three agents agree,
and are used literally everywhere below:

- The file path, always written as `.claude/wurk/codebase.md`.
- The prompt heading the skills paste above the forwarded content:
  `## Project orientation, from .claude/wurk/codebase.md`.

---

## Phase 1: Record the decision and add the standalone rung

### Overview

Commit the accepted ADR and give each codebase agent the second Orienting
rung it names. After this phase an agent invoked with no orientation in its
prompt finds `codebase.md` on its own; nothing else in the repo mentions the
file yet, which is accurate - the fast path arrives in phase 2.

### Changes Required:

#### 1. The ADR

**File**: `docs/adr/0011-codebase-orientation-extension-file.md`
**Changes**: None - the file is written and accepted, currently untracked in
the working tree. This phase's commit carries it, so the repo states the
decision in the same commit that begins implementing it.

#### 2. Agents with a Read tool

**File**: `agents/wurk-codebase-analyzer.md` (Orienting list at `:47-54`)
**File**: `agents/wurk-codebase-pattern-finder.md` (Orienting list at `:46-51`)
**Changes**: Insert a new item 2 into the numbered ladder and renumber the
existing items 2 and 3 to 3 and 4. Keep each file's existing voice - the
analyzer's list is about reading code accurately, the pattern-finder's about
what makes a useful example - so the inserted rung is worded once and the
surrounding numbering is the only other edit.

```
2. **`.claude/wurk/codebase.md`, when the prompt gave you none.** Some
   projects keep a short orientation file there for exactly this purpose:
   layout, test suites and what distinguishes them, module families,
   terms of art, and the reading rules that are easy to get wrong. Read it
   when it exists. Most projects do not have one - its absence is normal,
   not an error, and not worth reporting.
```

#### 3. The locator, which has no Read tool

**File**: `agents/wurk-codebase-locator.md` (Orienting list at `:47-54`)
**Changes**: Same insertion and renumbering, with the tool constraint stated
in the rung itself rather than left for the agent to discover:

```
2. **`.claude/wurk/codebase.md`, when the prompt gave you none.** Some
   projects keep a short orientation file there: layout, test suites,
   module families, and terms of art. You have no Read tool, so Grep it for
   its headings and the lines around them - or skip it, because when the
   invoking skill did its job this content already reached you in rung 1.
   Its absence is normal, not an error, and not worth reporting.
```

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
      (regression check only - no test reads `agents/`)
- [x] `git grep -n 'claude/wurk/codebase.md' agents/` returns exactly three
      hits, one per codebase agent
- [x] `git status --porcelain docs/adr/` is clean after the commit, i.e. the
      ADR is tracked

#### Manual Verification:
- [ ] Each of the three Orienting ladders is correctly renumbered 1-4 with no
      duplicate or skipped number
- [ ] The locator's rung names its lack of a Read tool and offers both Grep
      and skip; the other two say "Read it when it exists"
- [ ] No consumer-project constant appears in any inserted text: no bead
      prefix, repo path, gate command, label, or consumer ADR number
- [ ] Every inserted line uses plain ASCII punctuation - hyphens, not em
      dashes - matching the surrounding agent prose
- [ ] Each rung states that absence is normal, so an agent in a repo with no
      `.claude/` does not report a missing file as a finding

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: Forward the file from the three spawning skills

### Overview

Give `/wurk:research`, `/wurk:plan`, and `/wurk:iterate` the fast path: read
`.claude/wurk/codebase.md` where each already reads its own extension, and
paste it verbatim into every codebase-agent prompt under the fixed heading.
This is the common case ADR-0011 point 3 relies on for the locator.

### Changes Required:

#### 1. `/wurk:research`

**File**: `skills/wurk:research/SKILL.md`
**Changes**: Two edits. Add to the "Project extension" section (`:25-30`) a
sentence naming the second file read at the same point:

```
Also read `.claude/wurk/codebase.md` if it exists. It is not this skill's
extension - it is addressed to the `wurk-codebase-*` agents, and this skill's
only job with it is to forward it (step 3).
```

Then, in step 3 immediately after the existing `artifacts.*` forwarding
paragraph (`:113-117`), add the forwarding instruction:

```
   **Pass the project's orientation** to every `wurk-codebase-*` agent you
   spawn: paste the content of `.claude/wurk/codebase.md`, verbatim, under
   the heading `## Project orientation, from .claude/wurk/codebase.md`.
   Forward it as it stands - summarizing or excerpting it is a judgment call
   you would be making invisibly, on every invocation. If the file does not
   exist, say nothing about it; the agents orient from the repo, which is
   the normal case.
```

#### 2. `/wurk:plan`

**File**: `skills/wurk:plan/SKILL.md`
**Changes**: The same two edits, sited in this skill's structure. The
"Project extension" section is at `:17-23`; the spawn menu is step 1.2 at
`:95-115`, where the docs-pair roots are already passed in the
`wurk-docs-locator` bullet (`:104-106`). Place the forwarding paragraph after
the agent menu, before the "The research agents are documentarians" line.

#### 3. `/wurk:iterate`

**File**: `skills/wurk:iterate/SKILL.md`
**Changes**: The same two edits. The "Project extension" section is at
`:21-25`; the spawn paragraph is step 2 at `:87-97`, whose existing sentence
"Pass the manifest's `artifacts.*` roots to the docs agents" is the sentence
to extend with the codebase forwarding. Keep this skill's convention of
linking to `/wurk:plan` by name for shared rules, but state the forwarding
instruction in full here too - ADR-0011 point 2 names all three skills, and
an instruction reached only by following a cross-reference is one an
execution agent can miss.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
      (regression check only - no test reads these skills' prose)
- [x] `git grep -c 'claude/wurk/codebase.md' skills/wurk:research/SKILL.md
      skills/wurk:plan/SKILL.md skills/wurk:iterate/SKILL.md` shows at least
      two hits per file (the extension-section read and the forwarding step)
- [x] `git grep -n 'Project orientation, from .claude/wurk/codebase.md'
      skills/` returns exactly three hits, one per skill, with identical
      heading text

#### Manual Verification:
- [ ] In each skill the forwarding instruction sits next to the existing
      `artifacts.*` forwarding, so a reader finds both in one place
- [ ] The instruction says verbatim, and gives the reason (an invisible
      per-invocation judgment call) rather than only the rule
- [ ] Each skill's absent-file behavior is stated as silence, not a warning
- [ ] No consumer-project constant appears in any inserted text
- [ ] Cross-references use installed skill names (`/wurk:research`,
      `/wurk:plan`) where any are added
- [ ] Plain ASCII punctuation throughout the inserted prose
- [ ] Nothing was deleted: the ADR-0008 judge scope covers
      `skills/**/SKILL.md`, and this phase only adds steps

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: Document the second extension key shape

### Overview

Update the three places this repo describes the extension seam as per-skill,
so they describe the seam that now exists: `.claude/wurk/` holds per-skill
files and one agent-family file.

### Changes Required:

#### 1. Architecture, layer diagram

**File**: `docs/architecture.md` (`:17-22`)
**Changes**: Add one line to the consumer-repo block, beside the existing
`wurk/<skill>.md` line:

```
  wurk/codebase.md            orientation forwarded into the codebase agents
```

#### 2. Architecture, layer 4

**File**: `docs/architecture.md` (`:68-92`)
**Changes**: Replace the opening sentence "Optional per-skill markdown at
`.claude/wurk/<skill>.md` (e.g. `wurk/mr.md`, `wurk/plan.md`)" with a two-shape
statement, keeping the existing examples list, the add-not-override paragraph,
and the agents paragraph unchanged:

```
Optional markdown under `.claude/wurk/`, in two key shapes:

- **Per-skill**, `.claude/wurk/<skill>.md` (e.g. `wurk/mr.md`,
  `wurk/plan.md`) - the common case. A generic skill states where in its flow
  it reads its extension and treats the content as additional required steps
  or domain patterns.
- **Per-agent-family**, `.claude/wurk/codebase.md` (ADR-0011) - host-project
  orientation addressed to the `wurk-codebase-*` agents: layout, test suites,
  module families, terms of art, and reading rules. `/wurk:research`,
  `/wurk:plan`, and `/wurk:iterate` forward it verbatim into those agents'
  prompts, and the agents that have a Read tool fall back to reading it
  themselves. Absent, the agents orient from the repo exactly as before.

Examples of what lives here rather than in wurk:
```

#### 3. The four-layer restatement in the migration plan

**File**: `docs/plan.md` (`:131-132`)
**Changes**: Extend the layer-4 bullet to name both shapes and cite ADR-0011
alongside ADR-0004.

#### 4. README

**File**: `README.md` (`:13-14`)
**Changes**: "optional per-skill extension files" becomes "optional markdown
extension files", so the sentence stops asserting the per-skill key shape it
no longer describes fully. The Layout block (`:28-38`) needs no change - it
lists this repo's directories, not a consumer's.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
      (regression check only - this phase is doc-only, and per CLAUDE.md
      doc-only changes have no gate of their own)
- [ ] `git grep -n 'per-skill' docs/architecture.md docs/plan.md README.md`
      shows no remaining claim that extensions are only per-skill
- [ ] `git diff --stat` for this phase touches no file under
      `docs/manifest.md`, `lib/`, or `skills/wurk:kit/`

#### Manual Verification:
- [ ] Layer 4 reads as one seam with two key shapes, not two seams
- [ ] The wording matches ADR-0011's framing: ADR-0004's sentence names the
      common case, and this record extends rather than amends it
- [ ] ADR-0004 itself is unedited
- [ ] `docs/manifest.md` is unedited, and the diff makes that visible as a
      deliberate property rather than an oversight
- [ ] Plain ASCII punctuation, matching each file's existing style
- [ ] Skill cross-references in the new prose use installed names

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 4: Reroute the extraction table and dogfood the seam

### Overview

Two loose ends, both small, both `docs`-shaped, committed together because
each alone is a one-paragraph commit. First, record the extraction reroute in
`docs/plan.md` - retroactively, because step 7 is already DONE and statifier's
extensions are already written. Second, write wurk's own
`.claude/wurk/codebase.md`, which is the only way anything in this repo
exercises either path end to end.

ADR-0011's last Consequences bullet makes the dogfood file explicitly
optional ("nothing requires it"). It is included because without it neither
the fast path nor the standalone path can be exercised anywhere, and ADR-0007
already makes wurk a consumer of itself - `.claude/wurk/mr.md` is the
precedent.

### Changes Required:

#### 1. Reroute note on the extraction table

**File**: `docs/plan.md` (the table at `:898-907`, and the step 3 outcome
note at `:988-1000`)
**Changes**: Do not rewrite the historical table rows - they record what was
extracted, and that happened. Add a note directly beneath the table:

```
   **Reroute (ADR-0011).** The orientation rows above - the pipeline-layer
   vocabulary and tree map in `wurk/research.md`, and the Appendix D
   pseudocode rule and common patterns in `wurk/plan.md` - belong in
   `.claude/wurk/codebase.md`, the agent-family extension the codebase agents
   read and the spawning skills forward. Step 7 wrote the per-skill files
   before that decision existed, so the move is follow-on work; see step 11.
```

Then amend the step 3 outcome note's sentence "already slated for the
consumers' `wurk/research.md` and `wurk/plan.md` extensions (step 2's
extraction table), which the invoking skill reads and passes down" to name
`.claude/wurk/codebase.md` and cite ADR-0011 as the record that fixed the
mechanism the sentence anticipated.

#### 2. New follow-on step

**File**: `docs/plan.md` (phase 2's statifier-side step list - after step 10's
"Steps 9-10 outcome notes" block and before the "Definition of done" line,
currently around `:1113-1115`; re-read the section rather than trusting the
line number, since sibling branches move this file)
**Changes**: Add step 11, following the established shape of the statifier-side
steps (a wurk bead, executed on a statifier branch):

```
11. **TODO.** Statifier side: move the orientation content out of
    `.claude/wurk/research.md` and `.claude/wurk/plan.md` into a new
    `.claude/wurk/codebase.md` (ADR-0011) - the pipeline vocabulary, the tree
    map, the good-search-keys list, the Appendix D pseudocode rule, and the
    common patterns. The per-skill files keep the genuinely skill-facing
    remainder: reference-checkout guidance and areas wanting their own
    sub-agent in `research.md`; corpus/ratchet success criteria, required
    sections, and phase-splitting boundaries in `plan.md`. Needs its own bead;
    not blocking anything here.
```

#### 3. Wurk's own orientation file

**File**: `.claude/wurk/codebase.md` (new)
**Changes**: Write the file for this repo, under a screenful, using the
headings ADR-0011 point 1 suggests. Content, drawn from `CLAUDE.md`,
`docs/architecture.md`, and the kit's REFERENCE.md - facts about this repo,
which is the one place in this project where consumer-specific constants are
correct, because here wurk is the consumer:

- **Layout**: `skills/wurk:<name>/SKILL.md` (the colon is part of the
  directory name), `skills/wurk:kit/` (REFERENCE.md plus
  `scripts/`, `scripts/lib/`, `scripts/test/`), `agents/*.md`, `docs/`,
  `docs/adr/`, `docs/plans/`, `docs/research/`, `install.rb`.
- **Suites**: one, `skills/wurk:kit/scripts/test/run.rb`, minitest on system
  Ruby. `contract_test.rb` is the script-contract enforcer and is the first
  place to look when a script change fails.
- **Module families worth mining**: `scripts/*.rb` all share one envelope
  shape, so any script is a template for a new one; `scripts/lib/*.rb` holds
  the shared helpers; `scripts/test/*_test.rb` mirror the scripts one-to-one.
- **Terms of art**: manifest, extension, envelope, gate tier, bead, kit,
  seam, rung - and the `wurk:` / `wurk-` split (colon for skills, hyphen for
  agents).
- **Reading rules**: scripts are stdlib-only system Ruby with one JSON
  envelope on stdout and exit 0/1/2; every shell-out goes through
  `lib/sh.rb`; generic skill and agent prose carries no consumer constants;
  accepted ADRs under `docs/adr/` are settled - cite the number.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
      (regression check only - nothing reads `.claude/wurk/codebase.md`
      mechanically, by design)
- [ ] `.claude/wurk/codebase.md` exists and is tracked by git
- [ ] `wc -l .claude/wurk/codebase.md` is under 60 lines, honoring
      ADR-0011's one-screenful guidance
- [ ] `git grep -n 'step 11' docs/plan.md` finds the new follow-on step

#### Manual Verification:
- [ ] The reroute note does not rewrite the historical table rows or the DONE
      status of step 7
- [ ] Step 11 names what moves and what stays, so whoever picks it up does
      not have to re-derive the split from ADR-0011
- [ ] `.claude/wurk/codebase.md` describes this repo accurately - layout,
      suite, families, vocabulary, reading rules - and a reader who knows the
      repo finds no false statement in it
- [ ] Spawn a `wurk-codebase-locator` through `/wurk:research` in this repo
      and confirm the forwarded orientation appears in its prompt under the
      fixed heading (the fast path)
- [ ] Spawn a `wurk-codebase-analyzer` directly, with no orientation in the
      prompt, and confirm it reads `.claude/wurk/codebase.md` rather than
      falling straight through to `CLAUDE.md` (the standalone path)
- [ ] Temporarily rename the file aside and confirm both an agent and a skill
      proceed silently, with no warning and no error (the degradation
      property), then restore it

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

None, and this is a decision rather than an omission. Every file this plan
touches is prose that no kit script reads: the agents, three `SKILL.md` files,
three docs, and one new extension file with no schema (ADR-0011 point 1). The
kit suite is the gate for `skills/wurk:kit/scripts/`, and coupling it to
`agents/` or to sibling skills' prose is the coupling
`docs/plan.md:1050-1055` deliberately removed. The suite is still run in every
phase as a regression check - it must stay green, and its greenness says
nothing about whether the change works, which is why every phase's real bar is
under Manual Verification.

### Manual Testing Steps:

1. After phase 1, spawn `wurk-codebase-analyzer` in a scratch repo with no
   `.claude/` directory and confirm it orients from `README.md` without
   reporting a missing `codebase.md`.
2. After phase 2, run `/wurk:research` on a small question in this repo and
   read the codebase-agent prompt it composes: with no `codebase.md` present,
   the prompt should carry no orientation heading at all.
3. After phase 4, repeat step 2 with the file present and confirm the heading
   `## Project orientation, from .claude/wurk/codebase.md` and the file's full
   content appear verbatim in the prompt.
4. After phase 4, invoke `wurk-codebase-locator` directly with a bare "find
   the envelope contract" prompt and confirm it either Greps `codebase.md` or
   proceeds without it - both are conformant per ADR-0011 point 3, and
   neither is an error.
5. Rename `.claude/wurk/codebase.md` aside and repeat steps 3 and 4; nothing
   should warn, fail, or mention the file. Restore it.

## Open Questions

One, recorded rather than guessed at; no maintainer was available while this
plan was written. It blocks no phase.

- **Who files the statifier-side migration bead, and when?** Phase 4 adds
  `docs/plan.md` step 11 so the work is written down, and stops there. Filing
  it is not obviously this repo's job: wurk's `.claude/wurk.json` sets
  `beads.areas.always_batchable` to `[]` and has no `upstream` label, so
  ADR-0009's upstream-bead handling is not wired up here, and the statifier-side
  steps 6-10 were each executed as a wurk bead on a statifier branch
  (`docs/plan.md:1058-1113`) - a pattern that presupposes someone deciding to
  open one. The plan's position: step 11 is the record, and a maintainer opens
  the bead when statifier's next session makes it worth doing. Nothing degrades
  meanwhile - statifier's `research.md` and `plan.md` keep working exactly as
  they do today, because per-skill extensions are unchanged by this plan.

## References

- Source ADR: `docs/adr/0011-codebase-orientation-extension-file.md`
- Related ADRs: `docs/adr/0004-manifest-and-extension-seams.md` (the seam this
  extends), `docs/adr/0007-beads-for-issue-tracking.md` (wurk as its own
  consumer), `docs/adr/0008-merge-time-judge-over-generic-skill-prose.md` (the
  judge scope phase 2 lands in)
- Existing forwarding pattern: `skills/wurk:research/SKILL.md:113-117`
- Orienting ladders: `agents/wurk-codebase-locator.md:42-64`,
  `agents/wurk-codebase-analyzer.md:42-61`,
  `agents/wurk-codebase-pattern-finder.md:41-61`
- Seam documentation: `docs/architecture.md:68-92`, `docs/plan.md:131-132`,
  `README.md:13-14`
- Extraction table and its execution: `docs/plan.md:898-907`,
  `docs/plan.md:1061-1064`, `docs/plan.md:988-1000`
- Bead: `wu-mkm`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Each of the three Orienting ladders is correctly renumbered 1-4 with no
      duplicate or skipped number
- [ ] The locator's rung names its lack of a Read tool and offers both Grep
      and skip; the other two say "Read it when it exists"
- [ ] No consumer-project constant appears in any inserted text: no bead
      prefix, repo path, gate command, label, or consumer ADR number
- [ ] Every inserted line uses plain ASCII punctuation - hyphens, not em
      dashes - matching the surrounding agent prose
- [ ] Each rung states that absence is normal, so an agent in a repo with no
      `.claude/` does not report a missing file as a finding

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 2

- [ ] In each skill the forwarding instruction sits next to the existing
      `artifacts.*` forwarding, so a reader finds both in one place
- [ ] The instruction says verbatim, and gives the reason (an invisible
      per-invocation judgment call) rather than only the rule
- [ ] Each skill's absent-file behavior is stated as silence, not a warning
- [ ] No consumer-project constant appears in any inserted text
- [ ] Cross-references use installed skill names (`/wurk:research`,
      `/wurk:plan`) where any are added
- [ ] Plain ASCII punctuation throughout the inserted prose
- [ ] Nothing was deleted: the ADR-0008 judge scope covers
      `skills/**/SKILL.md`, and this phase only adds steps

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

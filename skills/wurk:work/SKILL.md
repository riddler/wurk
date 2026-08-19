---
name: wurk:work
description: Single entry point for working a bead - creates or reads it, sizes the job with the codebase in reach, then drives research / plan / implement as model-tiered subagents. Never implements directly. Reads .claude/wurk.json; honors .claude/wurk/work.md.
model: opus
argument-hint: ["a bead id, or free text describing the work", "optional: --auto"]
---

# Work

The single entry point for working a bead. Take a bead id (or free text that
becomes one), size the job **with the codebase in reach**, then drive the
research -> plan -> implement sequence as model-tiered subagents.

**This skill orchestrates. It never implements the bead itself.**

`model: opus` in the frontmatter is what makes "the orchestrator is always
Opus" hold even when `/wurk:work` is typed into an already-running Sonnet
session: a skill's `model:` governs the turn it is active for, independent of
the session's own model.

See `~/.claude/skills/wurk:kit/REFERENCE.md` for the envelope contract shared
by every script below.

## Project extension

If `.claude/wurk/work.md` exists, **read it before step 2** and treat its
content as additional required steps, placed where it says. Extensions add;
they never override. Typical content: project-specific sizing rules (a domain
whose changes are always heavier than they look), extra bucket vocabulary,
what intake owes beyond the shared minimum.

## Input

Parse `$ARGUMENTS`:

- **A token matching the project's bead id shape** (the manifest's
  `beads.prefix` plus an id, e.g. `zz-abc`, `zz-00p.3`) -> **bead mode**: that
  is the bead to work.
- **`--auto` present** -> **unattended mode**: no checkpoint pauses, no
  questions. This is what a seeded session (see step 0.5) is given
  automatically. Without it, this skill pauses at each artifact boundary for
  review.
- **Anything else** -> **intake mode**: the free text is the work description,
  and a bead must exist before anything else happens.

```
/wurk:work zz-abc                                 # bead mode, interactive
/wurk:work zz-abc --auto                          # bead mode, unattended
/wurk:work "add retry backoff to the send queue"  # intake mode
```

## Step 0: Upstream beads exit here

**Bead mode only.** This check exists to catch an upstream bead before any
workspace exists, so it must run before the step 0.5 handoff to
`/wurk:branch`:

- Read the bead: `ruby ~/.claude/skills/wurk:kit/scripts/bead.rb show <id>`.
  This read is needed here anyway - step 1 does it - and doing it first is
  what makes the check possible before any workspace exists.
- Read `beads.areas.always_batchable` from `.claude/wurk.json` (the same
  direct-manifest-read pattern as `wurk:next/SKILL.md`'s "Read
  `beads.topology`"). If the list is absent or empty, no bead is upstream;
  continue to step 0.5.
- If any of the bead's labels is in that list, **this bead is upstream: the
  work happens in a sibling repository and this bead exists to track and
  coordinate it (ADR-0009).** Then:
  1. Claim it as usual (`bead.rb claim <id>`) - the claim still marks
     coordination in progress - and `bead.rb sync push`, best-effort.
  2. **Do not invoke `/wurk:branch`. Do not create a branch or a workspace.
     Do not size the job.** There is nothing here for a workspace to do, and
     an upstream bead opens no request, so `/wurk:cleanup` would never reap
     one that got created.
  3. Report and stop, with: the bead id and title; **which sibling
     repository the work happens in**, taken from the bead's description -
     and, when the description does not name one, say so explicitly rather
     than guessing, and point at the bead as the thing to fix; that this
     bead **tracks rather than performs** the work; that it stays in
     progress and is closed manually with `bd close` when the sibling work
     lands, because `/wurk:cleanup` never will.
- **Defensive case.** If this session is already inside a workspace for an
  upstream bead (which `/wurk:next` no longer creates, but a hand-run
  `/wurk:branch` still can), give the same report and stop rather than
  sizing, and additionally name the workspace and branch as leftovers to
  remove by hand. The workspace's existence is a mistake to report, not a
  reason to proceed (ADR-0009). Because this check runs ahead of "Locate
  self", one check covers both the main-checkout and in-workspace cases; the
  defensive text is the extra sentence the in-workspace case adds.
- **Intake mode** has no bead yet at this point. Re-apply the same check at
  the end of step 1 once `/wurk:issue` has created the bead, and take the
  same exit.

## Step 0.5: Locate self

Everything downstream branches on this, because no project in this workflow
commits on its default branch:

```bash
ruby ~/.claude/skills/wurk:kit/scripts/repo_state.rb
```

`data.checkout` is `"main"` or `"worktree"`, decided by comparing the
per-worktree git dir against the shared common dir - which survives the
checkout being moved or cloned somewhere else, unlike comparing a path
against a constant.

- **main checkout** -> do intake (step 1) if needed, claim the bead, compute
  the branch name `<id>-<slug>` (2-4 distinctive kebab-case words from the
  title, not a full transcription), then invoke
  **`/wurk:branch <id>-<slug> -- /wurk:work <id> --auto`** and **stop**. Do
  not work the bead here. The seeded session runs step 0.5 again, finds
  itself in the workspace, and does the work - so the recursion terminates
  at depth one.
- **worktree** -> continue to step 1.

Under `branch-in-place` (manifest `parallelism.model`), `/wurk:branch` puts
the branch in this same checkout rather than a sibling one, so there is no
second session to hand off to: invoke it, then continue to step 1 here rather
than stopping.

## Step 1: Get a claimed bead

**Bead mode.**

```bash
ruby ~/.claude/skills/wurk:kit/scripts/bead.rb show <id>
```

Description, acceptance criteria, dependencies, notes. This is the input to
sizing, so it happens before anything is spawned. If the bead is not already
in progress, claim it:

```bash
ruby ~/.claude/skills/wurk:kit/scripts/bead.rb claim <id>
```

The claim is the lock. An epic is not workable: report it, point at its
children, and stop.

**Intake mode.** Compose with **`/wurk:issue`** rather than duplicating it.
Before it is claimed, the bead **must** carry:

- a description,
- acceptance criteria,
- at least one area label from the vocabulary the manifest names in
  `beads.areas.labels`, where the project defines one - or, for an upstream
  bead, a label from `beads.areas.always_batchable` instead.

The area label is not optional and is not something to backfill later: an
unlabeled bead is exactly what `/wurk:next` skips as "blast radius
undecided", so a bead this skill creates and leaves unlabeled is one the batch
picker will refuse to touch. Intake owes the label at creation. An
`always_batchable` label satisfies the same requirement rather than violating
it: the bead's blast radius must be decided at creation either way, and "no
files change here" is a decided blast radius, not a missing one.

Then claim and publish:

```bash
ruby ~/.claude/skills/wurk:kit/scripts/bead.rb claim <id>
ruby ~/.claude/skills/wurk:kit/scripts/bead.rb sync push
```

The push is best-effort and never gates the claim - sessions in this
checkout's worktrees share the database directly and see the claim regardless.

Now that the bead exists, apply step 0's upstream check to it and take step
0's exit if it fires.

## Step 2: Size the job

Buckets are **entry points into one sequence**, not terminal choices. Picking
"plan-only" does not mean planning is the whole job; it means the sequence
starts at the plan stage and runs through implementation from there.

| Bucket | Enters at | Stages, in order | bd type signal | When |
|---|---|---|---|---|
| **Code-heavy** | research | `/wurk:research` -> `/wurk:plan` -> `/wurk:implement --loop` | - | Touches a multi-module subsystem; blast radius unclear; existing structure must be mapped before planning. |
| **Plan-only** | plan | `/wurk:plan` -> `/wurk:implement --loop` | - | Well understood, but multi-step or cross-cutting enough to deserve a plan under `artifacts.plans`; a research document would be redundant. |
| **Just-do-it** | implement | one implementation subagent, no artifacts | - | Bounded doc / chore / config / small utility, low blast radius. |
| **Direction** | direction | direction stage (step 3) -> resumes into the sequence | `decision` | ADR-shaped work: architecture decisions, spec interpretation, review of plans or of finished phases. |

bd's `decision` issue type means the same thing the Direction bucket means -
ADR-shaped work: architecture decisions, spec interpretation, review - so a
`decision`-typed bead starts in Direction unless the description plainly says
otherwise. `epic` is a refusal, not a bucket; step 1 already handles it.
**The type is a signal, never an override.** It raises the prior; it does not
settle the bucket. A `task`-typed bead whose description is plainly a
direction question ("should we ...", "decide whether ...", "which of these
two designs") still lands in Direction, and a `decision`-typed bead whose
description is really a small chore does not. The description and the code in
reach are still the evidence; the type is one more piece of it, free and
usually right (ADR-0009).

**Direction still goes through the same workspace path, deliberately.** An ADR
is a documentation change and often precedes the code it governs, so a warmed
workspace is setup it does not need - but wasted is not harmful, and the
alternative is a second pickup path that only Direction beads use, forking the
flow this skill exists to keep singular. One path that occasionally warms a
build it does not need is cheaper than two paths to keep in sync. This
rationale does not extend to upstream beads (step 0): a Direction bead commits
a record *here*, so its workspace is used late rather than wasted, whereas an
upstream bead produces no commit here at all (ADR-0009).

**Sizing happens here, with the codebase in reach.** That is the whole reason
it lives in this skill rather than in `/wurk:next`: read the files the bead
names before choosing a bucket. A description-only guess at blast radius is
what this step exists to replace.

When genuinely uncertain between two buckets, **pick the heavier one**
(research > plan > just-do-it). Skipped diligence costs more than an
unnecessary research pass.

**Skip stages already satisfied.** Before spawning anything:

```bash
ruby ~/.claude/skills/wurk:kit/scripts/work_state.rb <id>
```

This composes the bead's already-parsed loop notes (`data.loop_notes`,
`data.last_loop_note` - `/wurk:implement --loop` writes one after each phase,
and another when it refuses), a research-document lookup by bead id
(`data.research_docs`), and a plan lookup plus `plan_state.rb`'s own parse of
whatever plan it finds (`data.plan_docs`, `data.plan.next_phase`,
`data.plan.phases`). Both lookups use the directories the manifest names under
`artifacts.*`.

**It reports; it does not choose a bucket.** Reading `data.plan.next_phase`
still takes the same judgment this step already exercises about what stage
that implies.

Enter the sequence at the first unsatisfied stage. This is the seam that makes
`/wurk:work <id>` re-invocable: after a stopped loop, re-running it resumes
rather than restarting.

**Report the bucket and a one-line rationale** before spawning. Without
`--auto`, let the user override it first.

## Step 3: Stage contract

| Stage | Skill | Agent type | `model` |
|---|---|---|---|
| Research | `/wurk:research <id>` | `general-purpose` | `opus` |
| Plan | `/wurk:plan <id>` | `general-purpose` | `opus` |
| Direction | *(no stage skill - prompt below)* | `general-purpose` | manifest `models.direction` |
| Implement | `/wurk:implement <path> --loop` | `general-purpose` | `sonnet` |

Every spawn obeys these invariants:

- **The `model` column mirrors each skill's `model:` frontmatter; it does not
  override it.** A skill's frontmatter wins for the turn it is active, so the
  Agent-call model governs only the subagent's turns *before* the skill fires
  - the bead read, the file reads. Keeping the two equal is the point: if they
  ever diverge, the frontmatter is what actually runs and this table is wrong.

  **Direction is the one row with nothing to mirror.** No stage skill fits
  what it produces (a decision, not a plan or an implementation), so its
  prompt is composed directly in the Agent call. Its model is the one stage
  model projects genuinely disagree about, so it comes from the manifest's
  `models.direction` (default `opus`) rather than being stated here.
- **`run_in_background: false`.** Each stage feeds the next; there is nothing
  to do while one runs.
- **The prompt must be fully self-contained**: the bead id, the artifact path
  where there is one, and an explicit instruction to read the bead itself. The
  subagent has no memory of this conversation.
- **No human is available.** Say so, and say what to do instead: record open
  questions *in the artifact it produces* and return them in its report; never
  block on a question. `/wurk:plan` and `/wurk:research` are interactive by
  design, and this instruction is what makes them terminate instead of
  stalling on a clarification nobody will answer.
- **Return the artifact path** in the report, so the next stage can be given
  it.
- **Never a nested CLI session.** A seeded session cannot spawn one - auto
  mode's classifier blocks it. In-process Agent subagents are unaffected and
  are the only mechanism this skill uses.

### Direction stage prompt

No skill wraps this stage, so the prompt is composed directly into the Agent
call. This section is the definition `/wurk:verify` cites by name rather
than restating when it escalates an item to Direction; a rewrite here should
keep that coupling in mind. Tell the subagent to:

- read the bead in full and the files it names;
- read the project's existing architecture-decision records, and its
  architecture documents where relevant, to see whether the bead asks for a
  new record, an amendment to one already accepted, or a narrower call that
  does not warrant its own record;
- write the decision as a new record at the next free number, in the same
  shape and status convention every other record in that project carries. A
  call too narrow for its own record goes to the research directory
  (`artifacts.research`) instead, naming the bead;
- return the artifact path and a one-line statement of the decision made (or
  the open question it could not resolve, recorded in the artifact per the
  "no human is available" invariant).

**What happens after the artifact** follows step 2's "buckets are entry points
into one sequence" framing. Some Direction beads are done once the record
lands - the decision was the deliverable, and step 5 reports it as terminal.
Others exist to unblock implementation the same bead asks for; once the
direction question has an answer, re-enter step 2 and size whatever is left
the normal way (commonly plan-only or just-do-it, since the hard call is
already made) rather than treating Direction as a dead end.

`general-purpose` is the right agent type because its tool list is `*`: it has
both the Skill tool (to invoke the stage skill) and the Agent tool (so the
implement stage's own loop can spawn per-phase subagents).

## Step 4: Implement stage

**With a plan**: one Sonnet subagent running `/wurk:implement <path> --loop`.

That loop is **already a per-phase orchestrator**: it dispatches one
`general-purpose` subagent per phase with a self-contained prompt, and it runs
`/wurk:commit --auto` *itself* after each phase as the automated advancement
gate, deliberately independent of the phase subagent's self-report. **Do not
re-implement either half here** - no per-phase subagents, no per-phase commit.

The nesting this produces - this skill (orchestrator) -> implement subagent
(layer 1) -> per-phase subagent (layer 2) - is within the default three-layer
spawn depth, which is also why `wurk-gate-reader` is only ever spawned as a
leaf.

On a **stopped loop**, the subagent returns the refusal reason and the phase.
Report both verbatim; do not retry, and do not clean up the tree - the refusal
is diagnostic information. Re-running `/wurk:work <id>` later resumes via step
2's `work_state.rb` scan.

**Just-do-it** is the same shape without a plan: one Sonnet subagent
implements the bead and is told explicitly **not** to commit; this skill runs
`/wurk:commit --auto` itself afterwards. That mirrors the loop's deliberate
split - the gate runs independent of the subagent's self-report, so a subagent
that believes it is done still has to pass a real gate.

## Step 5: Checkpoints and report

- **Without `--auto`**: after each stage, print the artifact path and a
  one-line summary, then pause for the user before starting the next stage.
- **With `--auto`**: chain straight through, no pauses, no questions; report
  every artifact at the end.

Always report:

- the bucket and its one-line rationale,
- each stage that ran, the model it ran on, and the artifact it produced,
- any **Deferred Manual Verification** items the loop surfaced, and any open
  questions a stage recorded in its artifact - `/wurk:verify` is how that
  backlog gets worked, on its own cadence and by hand,

- for a stopped loop: the refusal reason and the phase it stopped at.

## Guidelines

- **This skill orchestrates, it does not implement.** No edits to source,
  tests, or documentation. The only things this session does itself are bead
  calls, the just-do-it commit gate, and its own report. Everything else is a
  subagent.
- **Sizing happens here, in the workspace**, because this is the session that
  can read the code. That is why it is not in `/wurk:next`, and re-adding a
  bucket decision upstream of the workspace undoes the point of this skill.
- Sync steps are best-effort and never gate a claim. Offline is not a reason
  to abort.
- Work discovered along the way is **filed and linked, not chased now**.
- Compose with `/wurk:issue`, `/wurk:branch`, and the three stage skills
  rather than duplicating their logic. When a stage's behavior needs to
  change, change it there.
- **The bead stays in progress when the work is done.** It closes on merge, via
  `/wurk:cleanup`. Push, request-opening, and closing all still need an
  explicit human ask; finishing the work is not a request to publish it.

# ADR-0009: Upstream beads are handled without a workspace, on the always_batchable seam

Status: accepted (2026-08-10)

## Context

An upstream bead changes no files in the repo that tracks it: the work
happens in a sibling repository, and the bead here exists to track and
coordinate it. predicator-ex has them because its ADR-0003 makes it the
owner of decisions its siblings consume (px-35i.6, px-35i.7);
statifier-ex has the mirror image (st-bfq). The manifest already names
them: `beads.areas.always_batchable`, documented as labels that "by
definition change no files here". statifier-ex sets it to `["upstream"]`.

The seam is read but its consequence is not drawn. `select_batch.rb`
checks the labels (`Areas.upstream?`) only to exempt such a bead from the
`unlabeled` skip, so it comes out `free`: pickable, claimed, and - because
every picked bead gets a workspace - handed a warmed worktree, a branch, a
tmux window, and a seeded `/wurk:work` session that then has nothing to
size. Labelling an upstream bead is therefore strictly worse than leaving
it unlabelled: unlabelled is skipped harmlessly as "blast radius
undecided", labelled gets a workspace for work that happens in another
repo. Worse, that workspace is unreclaimable by the normal path:
`/wurk:cleanup` reaps workspaces via merged requests, and an upstream bead
never opens one. predicator-ex's adoption bead (px-ttt) omits
`always_batchable` deliberately until this is fixed; that deferral is the
concrete cost. Bead wu-lyc, superseding predicator-ex px-uio.

Two prior positions are in tension. `/wurk:next` deliberately does no
sizing - sizing lives in `/wurk:work`, "with the codebase in reach". And
`/wurk:work`'s Direction bucket accepts a workspace it may not need
("wasted is not harmful") to keep the pickup path singular. Neither
settles this case. "Is this bead upstream" is a label read, not a sizing
judgment - `select_batch.rb` performs it already, the same way the `epic`
verdict is a type read. And the Direction rationale does not transfer: a
Direction bead commits a record in this repo, so its workspace is used
late rather than wasted; an upstream bead produces no commit here at all,
so its workspace is not occasionally-idle setup but a dead end with no
cleanup path.

## Decision

**The upstream check is a label read available to both skills, and the
handling splits by role: `/wurk:next` refuses to stand up the workspace,
`/wurk:work` owns the early exit and the coordination report.**

- `select_batch.rb` gains an `upstream` verdict, triggered by any label
  the manifest lists under `beads.areas.always_batchable`. Like `epic`, it
  is informational and never enters the recommended batch: `/wurk:next`
  shows the bead in the candidate table with a reason pointing at
  `/wurk:work <id>`, and never claims it or creates a workspace for it.
  This is not sizing leaking upstream - it is the same kind of
  deterministic read the `epic` verdict already is, and the waste it
  prevents (workspace standup) happens in `/wurk:next`, so nowhere later
  can prevent it.
- `/wurk:work`, invoked on an upstream bead, exits early **before the
  step 0 handoff to `/wurk:branch`**: it reads the bead, sees the label,
  claims the bead as usual (the claim still marks coordination in
  progress), and reports the coordination step - which sibling repo, and
  that this bead tracks rather than performs the work - taken from the
  bead's description. No workspace, no branch, no sizing. The sibling repo
  is named in prose on the bead; a structured label-to-repo mapping in the
  manifest is deliberately not added until a second consumer demonstrates
  the need.
- Defensively, a `/wurk:work` session that finds itself already seeded in
  a workspace for an upstream bead gives the same report and stops rather
  than sizing - the workspace's existence is a mistake to report, not a
  reason to proceed.

**`always_batchable` remains the seam; the manifest schema is not missing
a field.** "Changes no files here" is one predicate with two consequences:
such a bead collides with nothing (batchable) and has nothing for a
workspace to do (no standup). A separate "upstream" label set would be a
second list definitionally identical to the first, kept in sync by hand,
and a bead in one but not the other would be an incoherent state the
schema newly allows. Under ADR-0004's test - a consumer needing different
generic behavior means the schema is missing a field - nothing is missing:
the field exists, and the skills simply failed to draw its second
consequence. Renaming the field to match the widened reading was
considered and rejected: a breaking manifest change bought only for a
name. If a breaking schema change happens for other reasons, the rename
can ride along. The sharpened meaning is documented in `docs/manifest.md`
and the skill prose instead.

**bd issue type as a signal into `/wurk:work`'s bucket table is
documentation of an existing seam, not a decision needing this record.**
`/wurk:work` already reads `issue_type` (epic -> refuse). Documenting
`decision -> Direction` as a prior-raiser - a signal, never an override,
so a task-typed bead whose description is plainly a direction question
still lands in Direction - adds no mechanism and changes no schema. It is
recorded here only to say so; the wording lands in `wurk:work/SKILL.md`
with the rest of this bead's implementation.

## Consequences

- Labelling an upstream bead becomes strictly better than leaving it
  unlabelled, so predicator-ex (px-ttt) can adopt
  `beads.areas.always_batchable ["upstream"]` without the labelled bead
  getting a pointless worktree.
- `/wurk:next`'s verdict table grows an `upstream` row; the exception text
  currently buried in the `unlabeled` row moves there. The kit suite
  covers the new verdict.
- `/wurk:work` gains the early exit ahead of the `/wurk:branch` handoff,
  plus the defensive in-workspace exit.
- An upstream bead never merges anything here, so `/wurk:cleanup` will
  never close it; it closes manually (`bd close`) when the sibling work
  lands, per the authority model.
- No manifest schema change, so no version bump; `docs/manifest.md`'s
  wording and `lib/areas.rb`'s comments are sharpened in the same commit
  as the skill changes, per the code-doc sync rule.

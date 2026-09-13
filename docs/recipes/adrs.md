# Recipe: decision records (ADRs)

A decision record is a short numbered document that says what was decided,
why, and what follows, so that the next session cites the number instead of
re-arguing the decision. Wurk's own `docs/adr/` is the working example and
ADR-0001 there is the rule that created it. This recipe is how a consumer
repo starts the practice and how wurk's skills use it once it exists.

Wurk ships no script that writes a record. What it ships is a manifest key
that says where records live (`artifacts.adr`), a reading of bd's own
`decision` issue type that routes such a bead to the stage that writes
one, a plan critic that checks plans against accepted records, and an
optional merge-time judge that can hold prose to a record's rule. Everything below is a consumer
choice; the seed is the only part that has to come first.

## The seed: record 0001

The Direction stage of `/wurk:work` writes a new record "in the same shape
and status convention every other record in that project carries". An
empty directory gives it nothing to imitate and it will invent a format.
So the first record is the one that states the practice, and it is
written by a person, once, before any bead asks for a decision.
`/wurk:init` writes this file from the template below when a project
opts into records; by hand, copy it and fill in the two placeholders,
the project name and the date.

`docs/adr/0001-record-architecture-decisions.md`:

```markdown
# ADR-0001: Record architecture decisions

Status: accepted (<YYYY-MM-DD>)

## Context

<Project> makes decisions that constrain later work: which library owns a
concern, where a boundary sits, what a format promises. Without a record,
every later session - human or agent - re-derives the reasoning, and
sometimes reaches a different answer.

## Decision

Architecture decisions are recorded as numbered records in `docs/adr/`,
one file per decision, named `NNNN-short-kebab-title.md`, with the
sections Status, Context, Decision, and Consequences. A record starts as
`accepted` with its date; there is no proposed state, because a decision
that is not yet accepted is a discussion, not a record. A decision that
is later adjusted is amended in place: the status line gains
`amended (<date>)` and an amendment section is appended, so the record
stays the one place the decision is read. A decision that is replaced is
a new record; the old one's status line says which record superseded it
and its text is otherwise left as written.

Small choices that do not constrain future work live in the docs, not in
records.

## Consequences

- Sessions cite record numbers instead of re-arguing decisions; a plan or
  change that contradicts an accepted record says so explicitly and asks
  for a new record rather than working around it.
- The `.claude/wurk.json` manifest names this directory as
  `artifacts.adr`, so wurk's docs agents and planning skills read the
  records here.
```

Numbering is four digits, zero-padded, allocated at the next free number
when the record is written; a gap is fine, a duplicate is not. The date on
the status line is the date the decision was accepted, not the date the
file was last touched.

## Telling wurk where they are

```jsonc
"artifacts": {
  "plans": "docs/plans",
  "research": "docs/research",
  "adr": "docs/adr"
}
```

`artifacts.adr` has no default: absent means the project has not said
whether it keeps records, and the docs agents fall back to conventional
candidates and say in their report that the root was a guess. Declared, it
is forwarded to `wurk-docs-locator` and `wurk-docs-analyzer` by
`/wurk:plan` and `/wurk:research`, and `manifest.rb check` blocks if the
directory is not there (`artifacts_adr_missing`), which is why the seed
comes before the key (`docs/manifest.md`, "`artifacts.adr`").

## Asking for a decision: the `decision` bead

A bead whose work is a decision rather than a change is filed with bd's
`decision` type:

```bash
bd create --type=decision --priority=2 \
  --title="Decide where retry policy lives" \
  --description="Why: two call sites implement backoff differently. What to decide: one owner for retry policy, and whether callers configure it or inherit it. Constraints: ADR-0003 (no per-call tuning knobs)."
```

`/wurk:work` reads the type as a signal and starts the bead in its
Direction bucket, which dispatches a subagent on the `models.direction`
tier to read the existing records and the bead, decide whether the answer
is a new record, an amendment, or a call too small for a record (that one
goes to `artifacts.research` instead), and write it at the next free
number. The type is a signal, not an override: a `decision` bead whose
description plainly asks for a change is sized like any other. One other
route reaches the same stage: `/wurk:verify` dispatches it when a
deferred item turns out to be a choice between defensible alternatives.
`/wurk:plan` and `/wurk:iterate` do not dispatch it; they flag a plan
that would contradict an accepted record and stop, and the person files
a `decision` bead if the record should change.

Some decision beads are done when the record lands; others unblock work
the same bead describes, and the skill re-enters sizing once the direction
question has an answer.

## What reads the records

- **`wurk-plan-critic`** checks every drafted plan, including its
  verification sections, for a step that quietly does what an accepted
  record rules out. A plan may propose changing a decision, but it must say
  so. The critic never argues a record; it cites one.
- **`/wurk:research`** and **`/wurk:plan`** cite record numbers in their
  documents and treat accepted records as settled.
- **`/wurk:iterate`** flags rather than silently edits a plan change that
  would contradict a record.

None of that needs a manifest key beyond `artifacts.adr`; the agents are
reading the files.

## Optional enforcement

**Advisory drift check at commit or request time.** The lightest form,
copied from a consumer that runs it: an extension step that greps the
`References` (or any) section of every record for a path the diff touches
and, on a hit, adds one line to the report naming the record and asking
whether the decision still holds. Advisory only; it never edits a record
and never blocks. In `.claude/wurk/commit.md`:

```markdown
## ADR drift (advisory, before presenting)

Grep `docs/adr/*.md` for any path in this commit's diff. If a record
references a changed file, add one line to the report naming the record
and asking whether the decision still holds. Never edit a record from
here and never block the commit on it.
```

The same step in `.claude/wurk/mr.md` puts the line in the request body
instead. A record that wants to be greppable this way carries a
`## References` section listing the files it governs.

**A merge-time judge over a record's rule.** For a record that states a
rule prose can violate (wurk's ADR-0008 is one: a skill step must state
its policy rather than hand it to a script), the `judge` manifest section
registers the record's text, the files it governs, and a description of
the failure mode, and `judge.rb` runs a propose-and-refute pass over the
branch's hunks at request time, invoked from `.claude/wurk/mr.md`
(`docs/manifest.md`, "`judge`"; ADR-0008 for the design). A surviving
finding refuses the request. This is the heavy form and most records do
not need it; a project registers one when a rule has already eroded once.

## What this recipe does not do

Make the Direction stage write a record for a project that has none.
Seed first. And it does not put record numbers into the manifest: a
consumer's own ADR numbers are consumer constants, cited in that
consumer's extension files and CLAUDE.md, never in a generic skill.

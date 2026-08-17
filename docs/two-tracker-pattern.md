# The two-tracker pattern

Some consumers keep a business-facing tracker - Notion, Jira, Linear - as the
source of truth upstream of beads. Business people file and read tickets
there; engineering decomposes each ticket into one or more beads and does the
work through the usual wurk flow. This document describes the pattern worked
out with one such consumer, so the next one does not reinvent it. It is a
consumer pattern, not a kit feature: nothing here changes a skill, a script,
or the manifest schema.

## When a consumer needs this

A consumer needs this pattern when tickets are filed and read by people who
do not work in beads - a product or support team, a customer-facing queue -
and engineering's decomposition of a ticket into engineering work is itself
information worth keeping (which beads came from which ticket, and where
each one stands).

A consumer does **not** need this when beads already is the single source of
truth end to end: engineering files its own work, nobody outside engineering
reads `bd`, and there is no second system whose state has to reflect bead
state. That is the common case among today's consumers (statifier-ex,
predicator-ex) and needs nothing from this document - plain ADR-0007 beads
tracking is the whole answer.

This is also not the same shape as ADR-0009's upstream-bead pattern, even
though both involve a bead pointing outside the repo it lives in. ADR-0009 is
about work that *happens* in a sibling repository - the bead here tracks
work performed elsewhere, changes no files locally, and is marked
`beads.areas.always_batchable` so no workspace is stood up for it. The
two-tracker pattern is about where a ticket is *decided and read*, not where
work happens - the engineering work still happens in this repo, gets a
normal workspace, and is tracked by ordinary beads. The two patterns can
coexist (an upstream bead's sibling repo could itself run a two-tracker
setup) but they answer different questions and neither implies the other.

## Minting: one ticket, one or more beads

When engineering picks up a ticket, it mints one or more beads for the
engineering-sized pieces of work the ticket decomposes into, and each minted
bead records the external ticket id.

`bd create --external-ref` is the intended mechanism for this: `bd create
--help` in this repo's installed `bd` (2026-08-17) confirms the flag exists
(`--external-ref string   External reference (e.g., 'gh-9', 'jira-ABC', Linear
URL)`), which is a fit by name and by the example values shown. This document
verifies only that the flag exists and its stated purpose - not its stored
shape, its behavior under `bd show`/`bd list`, or how it interacts with
`--parent` for a ticket that mints several beads. A consumer adopting this
pattern should confirm those specifics against its own installed `bd` before
depending on them; treat this as the recommended mechanism, not a proven one.

A ticket that decomposes into several beads is ordinary: nothing in the kit
assumes one bead per external id, and `--external-ref` can be passed to each
bead minted from the same ticket.

## The commit convention

Two things travel with every commit on this kind of work, and they are not
in tension: the business ticket id belongs in the subject line, for a reader
who thinks in ticket numbers; the bead id belongs in the trailer, because
that is what `/wurk:commit`, `/wurk:mr`, and `/wurk:cleanup` already parse
and act on (`lib/refs.rb`, keyed on `commits.trailer.key`, default `Refs`).

`/wurk:commit` today composes a subject in the style `commits.style` selects
(s-form or conventional) followed by the bead trailer - it has no notion of
a second, external id. Folding the ticket id into the subject text itself,
ahead of the s-form or conventional wording, is additive and needs no kit
change: `commit_message.rb`'s checks (subject length, trailer present and
last) do not care what precedes the trailer, only that the trailer is there
and is last. A consumer doing this in practice states the convention in its
own `.claude/wurk/commit.md`, since the subject shape is a project-specific
constant the kit does not carry.

Example, with `PROJ-123` standing in for a real ticket id and `wu-lvs` for
the bead:

```
PROJ-123: Adds retry backoff to the sync worker

Retries now back off exponentially instead of hammering the upstream
API on every failure.

Refs: wu-lvs
```

## The sync model

Sync runs one way only: bead state drives ticket state, never the reverse.
Three events, each read off ordinary bead/workflow state that already
exists, drive the same three transitions in the external tracker:

| Event (in beads/wurk) | Ticket transition |
|---|---|
| A bead for the ticket is claimed | Ticket moves to "in progress" |
| A request (PR/MR) is opened referencing the bead | Ticket moves to "in review", with a link to the request |
| Every bead minted from the ticket is closed | Ticket moves to "done" |

Each transition is triggered by a bead-side event that a wurk skill already
observes in the course of its normal job - claiming, opening a request,
closing on merge - not by a poll of the external tracker and not by a
webhook the external tracker fires into this repo.

### Why one-directional and event-based, not field-level bidirectional sync

Bidirectional, field-level sync between two trackers invites failure modes
this pattern deliberately avoids:

- **Loops.** A field write in either system that triggers a write back to
  the other can re-trigger the first, with nothing but ad hoc guards to stop
  it, especially once both systems are edited by different sets of people at
  different times.
- **Conflicting writes.** Two systems both claiming to be authoritative over
  the same field (status, assignee, priority) will disagree eventually - a
  human edits the ticket directly, or a bead's state changes for a reason
  the sync logic didn't anticipate - and there is no principled way to
  decide which write wins without a human arbitrating, which defeats the
  point of automating it.
- **A tracker that must be reachable for local work to proceed.** Local,
  in-process beads tracking is one of the four properties ADR-0007 settles
  on for wurk's own tracker (local, structured, durable, reversible).
  Bidirectional sync that blocks bead writes on a remote tracker's
  availability reintroduces exactly the dependency ADR-0007 avoided, for
  every consumer that adopts the pattern.

One-directional, event-based sync sidesteps all three: beads stays the
system of record for engineering state, the external tracker only ever
receives pushes, never sends them, and there is nothing for the sync logic
to reconcile because it never reads the external tracker's state at all.

## Where the sync lives

This is consumer-specific behavior by every measure this repo already uses
to draw that line: the external tracker's identity, its API or CLI, its
state vocabulary ("in progress", "in review", "done" are that tracker's
words, not beads'), and the ticket id scheme are all consumer constants.
CLAUDE.md's hard rule is explicit that generic skills and kit scripts carry
none of that. So the sync is implemented in consumer extension files
(ADR-0004's second seam), never in a generic skill or a kit script.

Each of the three events maps to the skill already sitting at that point in
the flow, and the extension file it reads (per `docs/architecture.md`'s
layer 4):

| Event | Skill that observes it | Extension file |
|---|---|---|
| Bead claimed | `/wurk:next` - claims the bead before `/wurk:branch` stands up its workspace (the claim is the lock, per `wurk:branch/SKILL.md`) | `.claude/wurk/next.md` |
| Request opened | `/wurk:mr`, step 7 (push and open the request) | `.claude/wurk/mr.md` |
| All beads for the ticket closed | `/wurk:cleanup`, step 4 (closes beads whose requests merged) | `.claude/wurk/cleanup.md` |

All three skills already document this seam and read their extension file
before their first step, treating its content as additional required steps
- the same mechanism `.claude/wurk/codebase.md` and `.claude/wurk/mr.md`
already use in this repo (the prose-judge invocation in `wurk/mr.md` is one
concrete example of an extension adding a required step to a generic skill's
flow). A ticket-sync extension follows the identical shape: additional steps
appended at the point the skill already names, calling out to whatever the
consumer's tracker needs (an API call, a CLI, a script the consumer owns
outside the kit) to make the transition. None of that script or API-calling
code belongs in this repo.

"All beads for the ticket closed" is a many-to-one check the extension logic
has to make itself - the kit's `beads_to_close` union in `/wurk:cleanup`
reports which beads just closed, but has no notion of an external ticket id
grouping several of them, since `--external-ref` (or whatever field a future
manifest scheme names) is not something any kit script reads today. The
extension file's step performs that grouping and check.

## What the kit does not do today

There is no manifest field for the external-id scheme - which field on a
bead holds the ticket id, what format it takes, which tracker it points at.
Today `--external-ref` is a `bd` capability, read by nothing in this kit and
named in no manifest field. If a second consumer adopts this pattern and the
duplication of implicit convention becomes a real cost, the fix is a
manifest field (and `docs/manifest.md` updated in the same commit, per
CLAUDE.md's hard rule and ADR-0004's "a consumer needing different generic
behavior means the schema is missing a field") - not a fork of any skill and
not a bespoke script in this repo. Until then, the whole pattern - minting
convention, commit convention, and sync logic - lives entirely in the one
consumer's manifest values, `.claude/wurk/*.md` extension files, and whatever
external script or integration performs the actual tracker API calls.

## Open questions

- Whether the same external-ref field can name more than one tracker id per
  bead (e.g. a bead that also gets promoted to a forge issue under
  `beads-with-forge-projection`) is unexplored; the one consumer this
  pattern is drawn from does not combine the two.
- The exact trigger for "request opened" when a consumer's tracker wants the
  link recorded on the ticket (the request URL) rather than just a state
  change is left to the consumer's `mr.md` extension; no shared shape for
  "write this URL back to the ticket" is proposed here, since it is a single
  API call specific to the tracker in question.
- If and when a manifest field for the external-id scheme is proposed, this
  document does not attempt to design its shape - that is `docs/manifest.md`
  work at the time a second consumer needs it, not now.

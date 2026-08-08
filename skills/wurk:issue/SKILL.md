---
name: wurk:issue
description: File a bead with type, priority, labels, acceptance criteria and dependency links, or update an existing one. Beads is the tracker; area labels are a collision prediction, not a topic tag. Reads .claude/wurk.json; honors .claude/wurk/issue.md.
model: sonnet
argument-hint: ["issue title or description; or an existing bead id plus the change to make"]
---

# Issue

File work into the bead tracker, or change a bead already there. Beads is the
tracker for every project using this workflow - not the forge's issues, not a
markdown checklist.

See `~/.claude/skills/wurk:kit/REFERENCE.md` for the envelope contract shared
by every script below.

## Tracker topology

Read `beads.topology` from `.claude/wurk.json`.

- **`beads`** (the default) - beads is the only tracker, and everything below
  applies as written. There is nothing to mirror or reconcile.
- **`beads-with-forge-projection`** - beads are promoted to forge issues, and
  a promoted bead has fields whose source of truth is the forge (its state,
  its title, its labels) alongside fields that stay bead-only (fine-grained
  priority, discovered-from links, working notes). **The projection half is not
  implemented yet.** Filing a bead here works exactly as below; **updating a
  promoted bead does not** - report that mirroring and reconciliation are
  unimplemented for this topology and stop, rather than changing one side of a
  pair that is supposed to stay in step.

## Project extension

If `.claude/wurk/issue.md` exists, **read it before gathering details** and
treat its content as additional required steps, placed where it says.
Extensions add; they never override. Typical content: the project's area-label
vocabulary in full, with the paths each covers and the disambiguation notes
that keep them apart; project-specific labels; a priority rubric.

## Mode

- `$ARGUMENTS` naming an **existing bead id plus a change** -> **update mode**
  (last section).
- **Anything else** -> **file mode** (the default), below.

## Gather the details

From `$ARGUMENTS` where given; otherwise ask for:

- **Title** - short, imperative.
- **Description** - context, relevant file paths, the spec or document
  sections involved.
- **Acceptance criteria** - what has to be true for this to be done. Not
  optional filler: it is what a later session checks its own work against, and
  it is where the file paths that decide the area labels usually become
  visible.
- **Type** - task, bug, feature, epic, or chore.
- **Priority** - 0 (urgent) through 3 (low); default 2 when the user has no
  preference.
- **Related work** (optional) - existing bead ids this blocks, depends on, or
  was discovered from.

**Infer type and priority when they are obvious; ask only about what is
genuinely ambiguous.** Do not interrogate the user field by field.

## Create

```bash
ruby ~/.claude/skills/wurk:kit/scripts/bead.rb create "Title here" \
  --type task --priority 2 --description "Longer context..." --labels area:x,tooling
```

`--type`, `--priority`, `--labels` (comma-separated), `--description`,
`--parent`, and `--notes` are all optional - omit whatever was not gathered.
For quick capture of work discovered mid-task, the title alone is enough:

```bash
ruby ~/.claude/skills/wurk:kit/scripts/bead.rb create "Title here"
```

Read `data.id` and `data.created`. The flags pass straight through to `bd`;
check `bd create --help` if they drift. Acceptance criteria go in through
whichever flag the installed `bd` exposes for them - verify rather than
assume, and put them in the description if the flag is absent, never nowhere.

## Link dependencies

```bash
ruby ~/.claude/skills/wurk:kit/scripts/bead.rb link <new-id> <other-id> --type depends-on
ruby ~/.claude/skills/wurk:kit/scripts/bead.rb link <new-id> <other-id> --type discovered-from
```

Use `discovered-from` for work found mid-task, and dependency links so the
ready set reflects the real build order rather than a flat list. Where the
bead belongs to an epic, link it as a child (`--parent` at create time, or
`--type parent-child` here).

## Apply labels

```bash
ruby ~/.claude/skills/wurk:kit/scripts/bead.rb label add <id> <label>
```

**At least one area label on every bead that will change files in this repo.**
The vocabulary is the manifest's `beads.areas.labels`; the paths each one
covers belong in the project's extension file, and that is where to look
before guessing.

Three rules make the difference between a label that works and one that
misleads:

- **Label by the paths in the acceptance criteria, not by subject matter.**
  An area label is not a topic tag. It is the input to `/wurk:next`'s
  collision check - two beads are batchable exactly when their area sets are
  disjoint - so it answers "which files will this touch", and nothing else.
  Two beads about the same subject touching disjoint files are batchable; two
  beads in unrelated subsystems that both edit the same build file are not.
- **The labels the manifest lists under `beads.areas.lands_alone` are
  exclusive.** A bead carrying one batches with nothing and lands on its own.
  Typically the build/config surface, where every other branch is measured
  against the files it changes.
- **A bead may legitimately carry several areas.** One that adds a function
  *and* exposes it publicly touches both, and saying so is correct rather than
  untidy - it is what stops it being batched against work in either.

Beyond areas: add whatever topical labels the user mentions, and the labels
the manifest lists under `beads.areas.always_batchable` where they apply -
those mark work that changes no files in this repo (a fix that belongs in a
sibling project, for example), which is why such a bead takes no area label at
all.

**An unlabeled bead is not neutral: it is unpickable.** `/wurk:next` skips it
as "blast radius undecided". Labeling at creation is cheaper than the round
trip.

## Report

```
Created zz-b57: <title> (task, p2)
Linked: depends-on zz-a42; labeled: area:x, area:y
```

**Do not commit, push, or sync the beads database unless explicitly asked.**

## Update mode

Bare `bd update` already covers trivial one-offs, and this skill does not
wrap it for its own sake. What it adds is the routing: which fields are
bead-native, which have a source of truth elsewhere, and which must never
travel.

1. **Resolve the target** - a bead id, and under a projection topology a forge
   reference resolved to its bead.
2. **Apply the change.** Bead-native fields (status, priority, assignee,
   notes, acceptance criteria, labels) go through `bd update` and the kit's
   label subcommands. Where the project's extension file states a priority
   rubric, follow it rather than inventing a scale.
3. **Never `bd edit`.** Notes are append-only through
   `bead.rb note`; an edit rewrites history other sessions have already read.
4. **Never close a bead here.** Closing is a claim about the default branch,
   and `/wurk:cleanup` makes it against a confirmed merge. A bead that turns
   out to be unwanted is a decision for the user to state, not a status flip to
   perform in passing.
5. **Report** what changed, field by field.

## Guidelines

- **Every bead is filed to be picked up by someone with none of this
  conversation's context.** Description, acceptance criteria, and area labels
  are what make that possible; a title alone is a reminder, not an issue.
  Quick capture is for the moment of discovery, not the finished article.
- Work discovered mid-task is filed and linked with `discovered-from`, not
  chased now.
- Type and priority are inferences worth making; asking about every field
  turns a ten-second capture into an interview.

---
name: wurk:verify
description: Work the deferred-verification and open-question backlog - enumerate every Deferred Manual Verification item a loop pushed into a plan and every open question a stage recorded in its artifact, then either walk them with a human one at a time (default) or, with --unattended, machine-check and fix what an agent can verify while leaving human-only items deferred. Reads .claude/wurk.json; honors .claude/wurk/verify.md.
model: opus
argument-hint: ["a bead id, or a plan/research document path"]
---

# Verify

Work the two backlogs the rest of the workflow only ever names and never
works: the **Deferred Manual Verification** items `/wurk:implement --loop`
pushed into a plan, and the **open questions** a research or plan stage
recorded in its artifact. This skill enumerates both mechanically, walks
them one at a time with a human, fixes what is wrong along the way, and
marks each item as it is confirmed so an interrupted pass resumes rather
than restarts.

See `~/.claude/skills/wurk:kit/REFERENCE.md` for the envelope contract shared
by every script below.

## Project extension

If `.claude/wurk/verify.md` exists, **read it before step 1** and treat its
content as additional required steps, placed where it says. Extensions add;
they never override. Typical content: what "verified" means for a domain,
and extra checks a project always wants run during this pass.

## Input

Parse `$ARGUMENTS`:

- **A token matching the project's bead id shape** (the manifest's
  `beads.prefix` plus an id, e.g. `zz-abc`) -> enumerate every plan and
  research document the manifest's `artifacts.plans` and `artifacts.research`
  directories hold for that bead.
- **One or more document paths** -> enumerate exactly those documents.

There is no `--auto` form, but there is `--unattended` (added 2026-08-26,
operator decision: unattended verify passes after implementation kept
turning up and fixing real findings). The two modes differ in who confirms:

- Default (interactive): walk items one at a time with a human, as below.
- `--unattended`: an agent ATTEMPTS every item that is machine-checkable -
  actually runs the check the item describes, fixes real defects it finds
  (within the bead's scope, gate re-run afterward), and records the outcome
  as `**Machine-checked (unattended, YYYY-MM-DD):**` with the evidence.
  It NEVER uses the human-confirmed marker or `plan_state.rb confirm`:
  those stay reserved for a human walk. Items that genuinely need human
  eyes or judgment (visual checks, product calls, anything the item text
  says only the operator can decide) are left untouched and re-listed in
  the summary as still-deferred. An unattended pass therefore shrinks the
  backlog's defect count, not its human gate: a later interactive pass
  still walks what remains, plus the machine-checked markers if the human
  wants to spot-check them.

## Step 1: Enumerate

```bash
ruby ~/.claude/skills/wurk:kit/scripts/backlog.rb <bead-id> [--doc PATH ...]
```

Read the envelope's shape rather than guessing at it: deferred items are
nested under each document's `deferred` hash as `deferred.items`, and open
questions are grouped by heading, so the items live at
`open_questions[].items` rather than in a flat list. Both totals are
reported separately under `totals`, so a flat read that finds nothing while
the totals are non-zero means the keys were guessed, not that the backlog is
empty.

Report the counts per document - deferred items unchecked, open-question
items with no settled marker - before walking anything. **The list comes
from the documents on disk, not from what a `/wurk:work` report said.** A
report is a snapshot from the moment a stage finished; the documents are the
current truth, and a document can carry items no report ever mentioned (a
human edited it since, or `--doc` names something `/wurk:work` never saw).

## Step 2: Walk the items

One at a time, in document order, deferred items before open questions
within each document. For each item:

1. Restate the item in one line.
2. Read the code or documents it asserts about.
3. Say what was found.
4. Fix what is wrong in the working tree.

This is not a read-only audit, and it is not a batch of blind edits: every
item gets read against the current state of the tree before anything is
touched, and a fix lands only for what is actually wrong.

An item already ticked (a deferred checkbox already `[x]`) or already
carrying a settled marker (Step 4 below) is skipped without discussion -
that is what makes a second invocation of this skill a resume rather than a
restart.

## Step 3: Escalate a decision

Not every item is a check. An item is a **decision** rather than a check
when any of these hold:

- confirming it would require choosing between defensible alternatives;
- the fix would change an interface or a stated rule;
- the item contradicts an accepted decision record.

When one of these fires, dispatch the Direction stage exactly as
`/wurk:work` defines it: read that skill's "### Direction stage prompt"
section and compose the prompt from it, rather than restating the prompt
here, on the model at the manifest's `models.direction`. The escalation
produces a record (a new decision record, an amendment, or a narrower
artifact under `artifacts.research`, per that section) - never a silent
edit made in this walk. Once the record exists, the walk resumes with its
answer: mark the item worked (Step 4) and continue.

## Step 4: Mark it worked

- A confirmed **deferred** item:

  ```bash
  ruby ~/.claude/skills/wurk:kit/scripts/plan_state.rb confirm <path> --line N
  ```

- A settled **open question** gets a `**Settled (YYYY-MM-DD):**` note
  appended under it, written directly with an editor, stating what was
  decided and why.

Both record that **the human confirmed** the item during this walk - neither
is the confirmation itself. The checkbox and the note are resume aids for a
later pass, not evidence to anyone reading the document later that the
underlying claim is actually true.

## Step 5: Summarize and commit

End with a summary naming:

- every item walked, and its outcome;
- every fix made, with the files it touched;
- everything filed rather than fixed - work discovered along the way that
  this pass did not chase (see Guidelines).

When the pass changed anything in the working tree, make one touch-up
commit through `/wurk:commit`. Never a bare `git commit`, and never `bd
close` - this skill only ever confirms items on a document, it does not
close the bead they belong to.

## Guidelines

- **The human confirms, the skill walks.** Every item in this backlog exists
  because a human was not available when it was first raised; this pass is
  where the human comes back into the loop, one item at a time.
- **The marker is a resume aid, never evidence.** A checked box or a
  `**Settled**` note means this pass reached the item and a human confirmed
  it then - not that the underlying claim holds forever. Say so if a later
  reader might mistake one for the other.
- **Work discovered along the way is filed with `/wurk:issue` and linked,
  not chased now.** A fix that turns out to be its own project belongs on
  its own bead, referenced from the note or the summary, not folded into
  this pass.
- **Unattended checks, human confirmations**: `--unattended` (see Input)
  lets an agent run the checks and fix what they catch, because in practice
  those passes surface real defects. What it never does is tick the human
  gate: `plan_state.rb confirm` and `**Settled**` notes record a HUMAN
  walking the item, and an agent writing them would erase the distinction
  the whole backlog exists to keep.
- **The deferred section stays in the plan when the walk is done.** A fully
  walked backlog is a record of what was checked, not clutter to remove;
  `/wurk:implement`'s own handoff rule says the same thing about the section
  it writes.

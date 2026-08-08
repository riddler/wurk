---
name: wurk:next
description: Pick the next ready bead (or up to n whose area labels are pairwise disjoint), claim it, stand up its workspace via /wurk:branch, and seed a session with /wurk:work. Picks and claims; never sizes or implements. Reads .claude/wurk.json; honors .claude/wurk/next.md.
model: sonnet
argument-hint: ["optional: n (default 1, max 4), --auto, one or more bead IDs, and/or bd ready filters (e.g. -l parser, -p 1)"]
---

# Next

Pick unblocked, unclaimed work, claim it so other workspaces skip it, stand up
a workspace per bead, and hand each bead to `/wurk:work` in the session that
can actually read the code.

`n` defaults to **1**. At `n > 1` this is a fan-out: pick several beads that
are safe to work at the same time, claim all of them, and give each its own
branch, workspace and window. Nothing else changes - the same selection
mechanics, the same handoff. The collision check is the mechanism rather than
an opinion: **two beads are batchable exactly when their area label sets are
disjoint.**

In manual mode this skill **presents choices; it does not decide for you.**
Every candidate's constraints go on screen - including collisions with beads
already held by a live workspace - before anything is claimed, and the greedy
pick is offered as the *recommended* option among the legal ones, not as the
outcome. A user who understands a collision's risk can still take it,
deliberately, through the override path; an unattended run never can.

This skill **composes; it does not fork.** Selection is the only thing it
adds. The mechanics - listing candidates, surveying live workspaces,
annotating verdicts, running the greedy walk - live in `select_batch.rb`; this
skill supplies the judgment that script deliberately leaves out: the picker.

See `~/.claude/skills/wurk:kit/REFERENCE.md` for the envelope contract shared
by every script below.

## Tracker topology

Read `beads.topology` from `.claude/wurk.json`.

- **`beads`** (the default) - beads is the only tracker. Issue state syncs
  across machines through the shared database on the git remote; any exported
  file is a passive export, never the sync channel. Everything below applies
  as written.
- **`beads-with-forge-projection`** - the project also mirrors each bead to a
  forge issue at work-start, stamps the bead with the forge reference,
  reconciles beads whose forge issue closed, and reaps stale claims. **None of
  that is implemented yet.** Report that this project's topology needs the
  projection work, and stop. Do not fall through to a plain pickup: a bead
  picked up without its promotion leaves the forge with no issue for work that
  has started, which is the state the topology exists to prevent.

## Project extension

If `.claude/wurk/next.md` exists, **read it before step 1** and treat its
content as additional required steps, placed where it says. Extensions add;
they never override.

## Input

`$ARGUMENTS` is passed straight through to `select_batch.rb`, which parses it
itself:

- **A bare integer** -> `n`, the ceiling on batch size. Default `1`.
  **The script refuses `n > 4`** (`blocked` `n_too_large`): relay its message
  as-is. Beyond four, the merge queue is the constraint rather than the
  picking, and every extra workspace is another branch that has to rebase past
  the ones that land first. Offer to run with 4. This is a refusal, not a
  clamp: someone asking for 8 has a wrong model of where the constraint is,
  and silently giving them 4 hides that.
- **`--auto` present** -> **auto mode**: select and claim without
  confirmation. For unattended sessions.
- **One or more bead ids** (tokens matching the manifest's `beads.prefix` id
  shape) -> **explicit-selection mode**: "consider exactly these", not a
  filter. The script validates each one; an unknown id comes back as a
  `warnings` entry (`unknown_id`) rather than being silently dropped. `n`
  defaults to the count of listed ids here, still capped at 4. **Mixing bead
  ids with ready-filter flags is refused** (`blocked` `ambiguous_input`) - one
  input form per invocation.
- **Otherwise** -> **manual mode** (the default): present the candidates,
  their constraints, and the legal options; let the user pick before anything
  is claimed.

Everything else maps to `bd ready`'s native filter flags (`-p/--priority`,
`-l/--label`/`--label-any`/`--exclude-label`, `-t/--type`/`--exclude-type`,
`--parent`, ...) and is passed straight through. Re-verify against
`bd ready --help` if these drift.

**`--label-any` is broken upstream as of bd 1.1.2**
([beads#5358](https://github.com/gastownhall/beads/issues/5358), re-verified
2026-08-08 and still open): it is silently ignored in embedded-Dolt
workspaces, so passing it through returns the *unfiltered* ready set with no
error. `bead.rb ready`, which `select_batch.rb` calls, already carries the
workaround - it splits `--label-any a,b` into one call per label and unions
the results by id. `-l`/`--label` (AND) is unaffected. **Do not drop this note
on a future pass without checking whether the bug has closed**; if it has, the
workaround and this paragraph go together.

`n` is a **ceiling, not a target.** Returning two when three were asked for is
the right outcome when the third collides. `data.skipped` and
`data.ceiling_hit` make that explicit - relay both. A silently short batch
reads as "there was no more work", which is a different and much more alarming
fact.

## Steps

0. **Refresh beads (best-effort).**

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/bead.rb sync pull
   ```

   `data.succeeded` may be false; that produces a warning, never a block.
   Offline means the local database is the best available view, which is fine.

0.5. **Clean up merged workspaces (best-effort).** Invoke **`/wurk:cleanup`**.
   Picking up new work is the natural moment for it: the previous branch has
   usually landed, and its workspace and local branch are still sitting there.
   At `n > 1` it matters more - about to stand up three or four workspaces is
   exactly the wrong moment to be carrying three or four dead ones.

   Never let it gate the pickup. If the forge is unreachable, `/wurk:cleanup`
   stops on its own and reports; carry on.

   **Run this every invocation, even if it already ran earlier in the
   session.** Step 1's live-workspace survey is only sound for the window
   "since the last sweep", and a branch can land in the minutes between an
   earlier cleanup and this run. "Cleanup already ran this session" is not the
   same claim as "cleanup ran immediately before this survey", and re-running
   is cheap.

1. **Select.**

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/select_batch.rb $ARGUMENTS
   ```

   One call lists candidates, surveys live workspaces for the areas they
   already hold, annotates every candidate with a verdict, and runs the greedy
   priority-ordered walk. **Nothing is claimed by this call** - it only
   reports.

   The live-workspace survey does not simply trust that step 0.5 ran and
   succeeded: for every live workspace it also asks the forge whether that
   branch already merged, and if so treats it as holding no areas regardless
   of *why* it survived cleanup - skipped, forge briefly down, or the session
   inside it busy. Without that check, a merged-but-not-removed workspace
   reports collisions against work that landed minutes ago. If the forge is
   unavailable the survey degrades and the script warns `survey_degraded` -
   relay that as "possibly stale, could not confirm" next to any
   `collides-with-live-worktree` verdict it produced, never as a hard fact.

   Read `data`:

   - **`data.mode`** - `"auto"` or `"manual"`, echoing what was parsed.
   - **`data.candidates`** - one row per candidate: `id`, `title`, `summary`,
     `priority`, `issue_type`, `areas`, `verdict`, `reason`. `summary` is the
     bead's first sentence, truncated - deterministic, produced by the kit,
     not model-written. Verdicts:

     | Verdict | Meaning |
     |---|---|
     | `epic` | work its children instead |
     | `unlabeled` | no area label - blast radius undecided. Nobody has decided this bead's blast radius; skipping it is the label being missing, not a failure of this skill. Name every bead skipped for this so they can be labeled and re-run. The exception is the labels the manifest lists under `beads.areas.always_batchable`, which by definition change no files here. |
     | `lands-alone` | carries a label the manifest lists under `beads.areas.lands_alone` - takes the batch alone |
     | `collides-with-live-worktree` | its areas intersect a live workspace's held areas - names the area(s) and the workspace holding them |
     | `free` | none of the above |

     A parent epic and its child can both be ready - that is what the `epic`
     verdict is for. Do not batch across that dependency edge.
   - **`data.recommended`** - the greedy pick. Label it the **recommended
     batch**: an option to present, not the outcome to report.
   - **`data.skipped`** - id plus reason for everything not recommended,
     including explicit ceiling reasoning ("asked for 4, took 2").
   - **`data.ceiling_hit`** - true when more legal candidates existed than `n`
     allowed. Surface it explicitly.
   - **`data.alternatives`** - override options, manual mode only; always
     empty under `--auto`, because an unattended run cannot knowingly accept a
     risk on someone's behalf. Each names the specific collision it accepts.
   - **`data.requires_user_choice`** - true in manual mode; the signal to run
     the picker rather than proceeding to claim.

   **`data.recommended` empty** (candidates all skipped, or none at all) ->
   nothing ready and unclaimed. **Do not auto-file work.** Report it, show what
   is blocked on what, and stop. In manual mode, offer `/wurk:issue` as the way
   to file something new.

   `blocked` codes to handle:

   - `n_too_large`, `ambiguous_input` - covered under Input; report and stop.
   - `bd_ready_failed` - report and stop.
   - `unverified_filter` - **do not trust a label filter you cannot verify.**
     The script compares filtered and unfiltered counts whenever a label flag
     is present; equal counts over a nonempty set is exactly the symptom of a
     flag being silently ignored (the bug above). Report the mismatch and stop
     rather than building a candidate table from a set that was never filtered.

2. **Present the picker (manual mode).** Show the full candidate table first,
   so every constraint - and every subject - is on screen before any question
   is asked:

   | Column | Source | Required |
   |---|---|---|
   | Bead | `id` | always |
   | Title | `title` | always |
   | What it is | `summary` (`-` when null) | always |
   | Pri / Type | `priority`, `issue_type` | always |
   | Areas | `areas` | always |
   | Verdict | `verdict` + `reason` | always |

   **Title and summary are not optional columns and are not dropped for
   width.** The constraint columns are what a reader can reconstruct from the
   tracker; the subject matter is what they cannot. If the table is too wide,
   wrap the summary - do not drop it. "Why did it only take two" is the
   question this skill will be asked most often, and the answer has to be
   visible before anyone asks.

   Then offer the choice:

   - Where the **AskUserQuestion** tool is available, use it. Options:
     1. **The recommended batch**, marked as such.
     2. **Legal alternatives** when meaningfully different - explicit subsets,
        sequencing splits.
     3. **Override**: take a bead despite a named collision. The option text
        names the specific risk it accepts.

     Every option's text must say what its beads are *about*, not just their
     ids and areas: one clause per bead, `<id>: <short summary>`, trimmed to
     the option's text budget. An override option states both the risk and the
     subject.
   - Where it is not available, present the same options as a plain list and
     ask.

   **Never auto-select in manual mode, even when only one candidate is
   ready** - show it and confirm. Nothing is claimed until the user picks;
   branch-name confirmation (step 3) folds into the same presentation.

   **Auto mode:** skip the picker. Take `data.recommended` as-is - a live
   collision is already a hard skip inside the script's walk, and
   `data.alternatives` is empty, so there is no override to consider. Print the
   picked and skipped lists and proceed without confirming.

3. **Compute a branch name per bead**: `<id>-<slug>`, the slug 2-4
   distinctive kebab-case words from the title, not a full transcription.
   `/wurk:branch` refuses to guess one, so this skill produces the full name.
   In manual mode the names ride along in step 2's presentation.

   Each name is fixed at creation and never renamed afterwards, even if the
   branch grows to carry more beads.

4. **Claim every bead in the chosen batch - all of them, before any workspace
   exists.**

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/bead.rb claim <id>   # once per bead
   ```

   The claim is the lock, and this ordering is deliberate: claimed-with-no-
   workspace is a cheap, recoverable state, while a workspace for an unclaimed
   bead is another session's collision waiting to happen.

   If a claim fails (`blocked` `bd_claim_failed` - someone else got there
   between the select and the claim), **drop that bead from the batch, keep the
   rest, and say so.** Do not silently retry against a different candidate.

   **If the chosen batch includes an override** (manual mode only), record it
   on each affected bead at claim time:

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/bead.rb note <id> "<date>: claimed over <area> collision with <workspace> - deliberate override via /wurk:next"
   ```

   `bead.rb note` is append semantics, never an edit. This is the record that
   lets a later refresh or selection run see that the collision was accepted on
   purpose rather than missed.

   Then publish the claims, once for the batch:

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/bead.rb sync push
   ```

   Best-effort: sessions in this checkout's workspaces share the database
   directly and see the claims regardless.

5. **Read each chosen bead.**

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/bead.rb show <id>
   ```

   This happens before the workspace is stood up: the slug comes from the
   title, and an epic or a malformed bead is worth catching while the only cost
   is a claim to reverse rather than a workspace and a window that exist for
   it. **Sizing the work is not what this read is for** - that happens in the
   workspace, in `/wurk:work`.

6. **Stand up a workspace per bead.** For each bead in the batch, invoke:

   **`/wurk:branch <id>-<slug> -- /wurk:work <id> --auto`**

   **The seed is the same for every bead, by design.** It is uniform precisely
   *because* sizing is not this skill's job: choosing between research, a plan,
   and implementing directly needs the codebase, and this session has only the
   bead's description. The seeded session has the workspace and can read the
   modules the bead names before it decides. Nothing is lost by not deciding
   here; the decision is simply made where the evidence is.

   Workspaces are created **one at a time, in batch order.** Each clones warm
   caches from this checkout and then runs a gate; running several at once
   contends on the same caches for no gain. If one fails, report it, leave its
   bead claimed, and continue with the rest - a failed workspace is not a
   reason to abandon the ones that worked.

7. **Report.** One row per bead:

   | Bead | Branch | Workspace | Window |
   |---|---|---|---|
   | `zz-abc` | `zz-abc-slug` | `../myrepo-worktrees/zz-abc-slug` | `zz-abc-slug` (`@42`) |

   Then, always and separately:

   - **what was skipped and why**, bead by bead - including "asked for 4, took
     2" stated as such,
   - **what was overridden and why**, bead by bead, when the batch took one,
   - any bead left **claimed without a workspace**, with the command to release
     it,
   - the gate result from each `/wurk:branch`,
   - a reminder that each bead is worked **inside its own workspace**, not
     here.

8. **Hand off - do not do any of the work here.** Each seeded session owns its
   bead from this point. This session picked and dispatched; that is the whole
   job.

## Guidelines

- **This skill picks and claims; it neither sizes nor implements.** Doing any
  of `/wurk:work`'s job here as well is how one bead gets worked twice.
- **Manual mode presents, it does not impose.** A run that claims before the
  user has seen the candidate table and chosen among the legal options has
  skipped the part that matters.
- **The candidate table is a menu of work, not a constraint report.** A run
  that shows constraints without subjects has failed the same way.
- **Claim the whole batch before creating any workspace**, not per-bead
  claim-then-workspace - that leaves workspaces for beads whose claim later
  fails.
- Sync and cleanup steps are best-effort and must never gate a claim. Offline
  is not a reason to abort a pickup.
- **Areas are about file collision, not subject matter.** Two beads both
  "about the corpus" touching disjoint files are batchable; two beads in
  different subsystems that both edit the same build file are not.
- **An area label is a prediction, written before the work exists.** A batch
  built on a wrong label produces exactly the rebase conflict the labels exist
  to prevent. When `/wurk:refresh` hits one, that is feedback about this
  skill's input, not just a chore.
- **Live workspaces are part of the collision surface**, not just the batch
  being formed. The only difference from an in-batch collision is who may
  override it: a user, deliberately - never an unattended run.
- Work discovered while picking is filed and linked as discovered-from, not
  chased now.
- Compose with `/wurk:branch`, `/wurk:cleanup`, `/wurk:issue` and
  `/wurk:work` rather than duplicating their logic. Even selection's mechanics
  live in `select_batch.rb`; what lives here is the picker.
- Re-verify exact `bd` flags against `bd ready --help` if they drift.

---
name: wurk:mr
description: Take a finished branch from local commits to an open pull/merge request - rebase onto the default branch, run the full gate, push, open the request, and record it on the bead. Never closes the bead. Reads .claude/wurk.json; honors .claude/wurk/mr.md.
model: sonnet
argument-hint: ["optional: bead ID; omit to detect from the commits' trailers"]
---

# Merge request

Take a finished branch from local commits to an open pull request (GitHub) or
merge request (GitLab). Which one, and which CLI, comes from the manifest's
`forge.kind`; this document says "the request" where the difference does not
matter.

A commit on a per-issue branch is private and undone with `git reset --soft
HEAD~1`; a push and a request are visible to other people and other machines,
enter review queues, and send notifications. The repo's authority table puts
the human gate on the push and the request itself - and **invoking this skill
is that gate firing**: typing `/wurk:mr` is the user asking for the push in
their own words, so this skill does not stop again to ask. That makes the
checks in steps 1-5 load-bearing in a way they would not be if a human still
read a summary before answering: a red gate, an unresolved rebase conflict,
or a missing changelog entry has to catch a problem before step 6, because
nothing catches it after.

**The bead is not closed here.** It stays in progress until the branch merges
into the default branch. A request is a request, not an outcome.

See `~/.claude/skills/wurk:kit/REFERENCE.md` for the envelope contract shared
by every script below.

## Project extension

If `.claude/wurk/mr.md` exists, **read it before step 1** and treat its
content as additional required steps, placed where it says. Extensions add;
they never override. Typical content: an extra merge-time judgment stage, a
project's request-body conventions, labels the project attaches.

## Input

`$ARGUMENTS` = optional bead ID. Omitted, the beads come from the trailers on
the branch's own commits, falling back to the branch prefix (step 2).

## What to run

1. **Establish where you are.**

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/repo_state.rb
   ```

   STOP if `data.on_default_branch` - this skill operates on issue branches
   only. STOP if `data.dirty` - an uncommitted change is either part of this
   work and belongs in a commit, or is unrelated and belongs somewhere else.
   Do not stage it here.

   Confirm there is something to push, using `data.default_branch` from step
   1's `repo_state.rb` output in place of `<data.default_branch>`:

   ```bash
   git log origin/<data.default_branch>..HEAD --oneline
   ```

   Empty means there is nothing to open a request for. Say so and stop.
   (`repo_state.rb`'s own `unpushed`/`commits_ahead` are relative to the
   branch's upstream, not the default branch, so this check stays hand-run.)

2. **Resolve the beads.** From `$ARGUMENTS` if given. Otherwise read
   `data.refs_beads` from step 1 - the same anchored trailer extraction
   (`lib/refs.rb`, keyed on `commits.trailer.key`) that `/wurk:cleanup`
   closes on via `pr_state.rb beads`, so the request body and the eventual
   closes agree.

   `data.refs_beads` is computed over commits not yet on the branch's
   upstream. **If `data.upstream` is `null`** (the branch has never been
   pushed - the first `/wurk:mr` run for it) or `refs_beads` comes back
   empty, fall back to `data.branch_bead.id`. The prefix is a creation-time
   label naming at most one bead, so a branch carrying several would
   otherwise reach the request body naming only the first.

   Validate each with `bd show <id>`. STOP if none resolves. A request that
   cannot be traced to a bead is work nobody can find later, and the `bd
   note` in step 8 has nowhere to go.

3. **Fetch and rebase onto the default branch.** The gate in step 4 only
   means something if it attests to the tree that will actually merge, not to
   branch + stale main. Rebasing has to happen here, before the gate:
   rebasing between the summary in step 6 and the push in step 7 would
   invalidate the very attestation the gate exists to produce.

   ```bash
   git fetch origin
   ruby ~/.claude/skills/wurk:kit/scripts/rebase_onto.rb .
   ```

   `rebase_onto.rb` is the same shared rebase-with-repair block
   `/wurk:refresh` uses: it checks whether the default branch has moved
   before touching anything, rebases, and runs the manifest's
   `parallelism.repair` commands only when `parallelism.repair_when` (the
   lockfile that triggers repair) actually moved. It never re-clones warmed
   directories wholesale.

   Read `data.status`:

   - **`"rebased"`** - `data.target` (the sha rebased onto),
     `data.lock_changed`, and `data.repaired` feed step 6's summary.
   - **`"conflict"`** (`blocked` code `rebase_conflict`, `needs: "human"`) -
     `data.files` names the conflicting files. **The script has already
     captured them and aborted the rebase** - capture-then-abort is baked in,
     since the abort clears the conflict state a report assembled afterward
     would have nothing left to name. That is the default outcome: an
     aborted rebase ends this run, and resolving a rebase conflict unasked is
     not an authority this workflow grants.

     There is one exception, and it is a grant the consumer made in advance,
     not a judgment call made here: when every conflicting file matches the
     consumer's own `rebase.auto_resolve_paths`, the consumer has already
     said in writing, before this conflict existed, which files it grants
     that authority for. Nothing else is eligible, and an empty list - the
     default - means nothing is. When that holds, run:

     ```bash
     ruby ~/.claude/skills/wurk:kit/scripts/rebase_resolve.rb .
     ```

     Read the result: **`status: "rebased"`** with `data.resolved`
     non-empty means a resolution happened, and it **must** be carried into
     step 6's summary and step 7's request body. Any `blocked` response
     means stop and report `data.stop_reason` verbatim - the worktree is
     never left mid-rebase either way. **`status:
     "conflict_not_reproduced"`** means the worktree moved since
     `rebase_onto.rb` captured the conflict; report that and stop.

     The division of labor, per ADR-0010 and ADR-0008: the script owns the
     rebase plumbing, the blob capture, the deterministic screens, the
     line-set invariant, and prompt assembly; a model owns the merge and an
     independent refutation of it. **This prose owns what to do about the
     result** - and what it says to do about anything short of a clean,
     unrefuted, provably additive merge is stop.

     The reporting is load-bearing, not courteous: for the file class most
     likely to qualify, `data.applicable` comes back `false` in step 4 and
     no gate runs, so the summary and the request body are the only place a
     human ever sees that a merge was made on their behalf. A resolution
     that reaches step 7 unnamed is a defect.

     If `rebase_resolve.rb` is interrupted mid-run, `git rebase --abort` in
     the worktree restores the pre-rebase state.

   **On the no-op case** (nothing to replay): the gate in step 4 still runs.
   What the no-op skips is the expensive part, not the gate. The gate attests
   to *this* tree, and the simplest way to know the tree has not drifted
   since `/wurk:commit` last ran it is to ask again rather than track how long
   ago it was green and what touched the tree since. One code path beats two.

4. **Run the full gate.**

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/gate.rb
   ```

   Never truncate `data.stages`. When the output is more than trivially
   small, hand it to the **wurk-gate-reader** agent rather than reading it
   here.

   **Refuse on red** - `ok: false` means either the run failed or a stage the
   gate could not measure came back skipped; report the failing stages with
   their `file:line` findings and stop. Do not push a branch whose gate is red
   in the hope that CI disagrees.

   Entries in `data.skipped_stages` carry a `classification`.
   `"run_level"` entries have already made the gate red and this step
   refuses. `"project_level"` entries do not block - they are standing gaps
   in what the project checks at all, not failures of this run - and are
   still named in the request body and the final report; a stage that never
   ran is never a stage that passed. `"not_applicable"` entries also do not
   block, and are not required in either the request body or the final
   report - the project has declared the stage will never apply.

   A narrowed run does not count: this script accepts no narrowing flags, and
   passing one is a usage error rather than a narrower run. `data.attested`
   mirrors the manifest's `gate.attest` command where the project has one.

   **Carve-out**, matching `/wurk:commit` Step 0: `data.applicable: false`
   means the diff touches nothing under `gate.build_paths` or
   `gate.also_gated_paths`, so there is no gate to run.
   `data.carve_out_reason` explains why. Skip it and say so in the request
   body and the final report, so a skipped gate is never mistaken for a green
   one.

5. **Check the changelog.** Only when `data.touches_build` (from step 1) is
   true and the diff touches the project's public surface. Follow the branch
   of `/wurk:commit` Step 1.6 that the manifest's `changelog.mode` selects,
   and check that the entry it calls for exists.

   If one is needed and absent, **ask the user** what it should say. Do not
   invent it: a changelog entry is a promise to users about observable
   behavior, and guessing produces a release note describing something the
   code may not do.

6. **Record what is about to become public.** Print the summary, then proceed
   straight to step 7 - invoking `/wurk:mr` was the request to publish, so
   there is nothing left to ask:

   ```
   Ready to open a request for <id> - "<bead title>"

   Branch:    <branch> -> <default branch>
   Rebased:   already current, no commits replayed
              (or: onto <sha>, N commits replayed)
   Conflict:  none
              (or: auto-resolved in <files> - <rationale>)
   Commits:   N
   Gate:      full gate green   (or: docs only, no gate applicable)
   Changelog: <path>   (or: not needed - internal tooling)

   <proposed title>
   ```

7. **Push, then open the request.** No kit script touches either - the
   contract bans a `git push` or a request-creating code path anywhere under
   `scripts/` - so these stay hand-run:

   ```bash
   git push -u origin <branch>
   ```

   If the branch had already been pushed before step 3 ran (the common case,
   since a branch usually gets at least one push before its request is
   ready), the rebase rewrote commits the remote already has and the two have
   diverged. Same if `/wurk:refresh` rebased it independently between pushes.
   Either way the push needs `--force-with-lease` - never a bare `--force`,
   which discards commits pushed from elsewhere without telling you:

   ```bash
   git push --force-with-lease
   ```

   A branch rebased in step 3 but never pushed before needs neither flag;
   there is nothing on the remote to diverge from.

   Then create the request with the CLI `forge.kind` selects (`gh pr create`
   for `github`, `glab mr create` for `gitlab`), based against the default
   branch. Under `forge.kind: gitlab` the kit's forge-dependent scripts still
   block with `unsupported_forge` today (see `skills/wurk:kit/REFERENCE.md`),
   so the automated steps around this one - merge detection, permalinks, the
   note this skill records below - do not yet run on that forge.

   The title matches the project's commit style (`commits.style`) and its
   subject length limit. The body carries what a reviewer needs and the
   commits do not:

   - **Why** - the problem, in the bead's terms
   - **What** - the shape of the change, not a file list; the diff has that
   - **Notes** - anything surprising, deliberately deferred, or worth a
     second opinion, plus which gate ran, and - when step 3 auto-resolved a
     conflict - which file it resolved and what the merge did
   - **The close lines** - one per bead the branch's trailers name (plus the
     epic, if they share one). Under the default `beads` topology these name
     the bead ids. Under `beads-with-forge-projection` they name the forge
     issues the beads were promoted to instead, in that forge's syntax.

   No AI attribution in the title or the body, same rule as commit messages.

8. **Sync beads, then record the request.** Also hand-run - `bd close` is on
   the banned-operation list, and this step never closes anything, but `bd
   dolt push` and `bd note` are ordinary bead commands no script wraps:

   ```bash
   bd dolt push
   bd note <id> "Request: <url>"
   ```

   Run the note once per bead step 2 resolved. A bead whose request URL was
   never recorded is one nobody can follow from the issue to the review.

   `bd dolt push` is not optional. Issue state travels over the same remote
   as the code, so a request whose bead was never pushed is invisible to
   every other machine: a reviewer pulling the branch sees work with no issue
   behind it. The git side has just reached the remote, which is exactly the
   trigger the authority table names for this.

   Leave the bead in progress. Do not close it.

9. **Report.**

   ```
   Request opened: <url>
   Branch:  <branch> -> <default branch> (N commits)
   Gate:    full gate green
   Bead:    <id> in progress, URL recorded, beads pushed
   Next:    merging is a human decision; the bead closes on merge, not here
   ```

## Guidelines

- **Never close the bead here.** Closing fires on merge, verified against the
  remote. Closing at request-open time asserts to every other machine that
  the work landed when it has not.
- **The gate is the command invocation, not a prompt in step 6.** Typing
  `/wurk:mr` is the user asking for the push in their own words; the skill
  does not stop to ask again once it starts. That is why steps 1-5 stay
  strict rather than advisory.
- **Merge strategy matters downstream.** Where the project merges by rebase,
  the branch tip never becomes an ancestor of the default branch, so merge
  detection anywhere downstream must use the forge's request state rather
  than git ancestry - which is exactly why `pr_state.rb` exists (see
  `/wurk:cleanup`). Do not restructure a branch's commits on the assumption
  they will be squashed.
- **One bead per branch is the default, not a law.** Several small beads
  touching the same files belong on one branch as separate commits; splitting
  them across parallel branches manufactures exactly the rebase conflicts the
  module boundaries exist to avoid. Group them when they are the same work,
  split them when they are not.

  This is safe because `/wurk:cleanup` closes beads from the trailers in the
  merged request's commits, not from the branch name, so every bead a branch
  carries gets closed. Keep one bead per **commit** so those trailers stay
  unambiguous, and name every bead the request closes in its body.
- After the merge, sibling branches need `/wurk:refresh`, and this branch's
  worktree and beads are handled by `/wurk:cleanup`.

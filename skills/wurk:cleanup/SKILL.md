---
name: wurk:cleanup
description: Land merged work - close the beads whose requests have merged, remove their worktrees and local branches, using the forge's request state rather than git ancestry. Reads .claude/wurk.json; honors .claude/wurk/cleanup.md.
model: sonnet
argument-hint: ["optional: one worktree/branch name; omit to sweep all"]
---

# Cleanup

Remove the worktrees and local branches left behind by merged work, and close
the beads that merged with them. Nothing else in the workflow does either:
`/wurk:mr` deliberately stops at request-open, so the merge - which happens on
the forge, outside any session - leaves state behind that accumulates until
someone sweeps it.

See `~/.claude/skills/wurk:kit/REFERENCE.md` for the envelope contract shared
by every script below.

## Why detection must not use git ancestry

Where a project merges by rebase, the forge replays a branch's commits onto
the default branch as new SHAs, so **the branch tip never becomes an ancestor
of it**. Two consequences, and both are traps:

1. `git branch --merged` never lists a merged feature branch. A cleanup built
   on it silently no-ops forever while looking like it works - the worst kind
   of broken, because nothing ever reports a problem.
2. `git branch -d` refuses for the same reason, so deletion needs `-D`. That
   makes the request-state check **load-bearing for safety, not just
   detection**: `-D` on an unmerged branch discards commits with no recovery
   path short of the reflog. Never force-delete a branch without a confirmed
   merged state from the forge.

So: ask the forge, never git. `pr_state.rb` - reached through
`worktree_survey.rb` and `worktree_cleanup.rb` - is the one place that encodes
this.

This is verified on both supported forges, not just inferred for one. Across a
sample of merged requests on a live remote, the recorded head was not an
ancestor of the target under more than one of the forge's merge settings - so
this cannot be ruled out by picking a setting, and a check that happens to be
safe under one setting is unsafe under others. In one sampled case, the
request's recorded head and the commit that actually landed were different
commits, with the same message but different parents. Ancestry detection
would have missed that merge. A request's own "has a merge commit" field is
not a safe substitute for its merged state either: some merge settings leave
that field an empty string on a request that is genuinely merged.

**Do not substitute a commit-range check either.** `git log @{upstream}..HEAD`
fails precisely when this skill runs, because the forge deletes the remote
branch on merge and the missing upstream ref reads like "unpushed commits",
skipping every merged worktree. `git log <default>..HEAD` reports commits for
every merged branch regardless, since they were replayed under new SHAs. The
merged-commit SHA the forge reports is the only local-vs-merged comparison
that holds.

## Not applicable under `branch-in-place`

Read `parallelism.model` from `.claude/wurk.json` first. Under
`branch-in-place` there are no per-issue worktrees to remove; a landed branch
is dealt with by switching back to the default branch and deleting it in the
one checkout. **Report that this skill does not apply and stop.** The bead
closing described in step 4 still has to happen somewhere - say so, rather
than leaving the impression that nothing is owed.

## Project extension

If `.claude/wurk/cleanup.md` exists, **read it before step 1** and treat its
content as additional required steps, placed where it says. Extensions add;
they never override.

## Input

`$ARGUMENTS` = optional worktree or branch name, to clean just that one.
Omitted, sweep every worktree.

## What to run

1. **Check phase.**

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/worktree_cleanup.rb --dry-run [name]
   ```

   This enumerates worktrees (dropping the main checkout - removing it would
   take the repository with it), asks the forge whether each branch's request
   merged, refuses on a dirty tree, and compares the local `HEAD` against the
   SHA the forge actually merged, to catch commits made after the push.

   Read `data.results[].result` per worktree. `"merged in request #<n>, would
   remove"` marks a candidate; anything else is not touched this run.

2. **Quiesce each candidate's session**, before touching anything on disk -
   see Guidelines for why this order matters:

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/tmux_window.rb find <name> <path>
   ```

   - `data.found: false` - no window. Nothing to quiesce; go to step 3 for
     this candidate.
   - `blocked` `ambiguous_window_match` - more than one window claims this
     worktree. Skip the quiesce **and** the removal, and report it. Two
     windows claiming one worktree is a state a human should look at.
   - Otherwise carry `data.window_id` forward, and carry `data.session`
     forward alongside it when `data.session_scoped` is true:

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/tmux_window.rb classify <window_id>
   ```

   `data.status: "busy"` - skip this worktree's removal entirely, report
   `"session busy, skipped"`, and leave the worktree, branch, and window
   alone. `data.status: "exited"` - the pane is not running a session at all;
   skip the quiesce (there is nobody to ask to exit) and carry `window_id`
   straight to step 3's close. `data.status: "idle"` - continue:

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/tmux_window.rb quiesce <window_id>
   ```

   `blocked` `quiesce_timeout` - skip this worktree's removal and report it.
   **Never escalate past this.** `data.status: "exited"` - the session is
   down; carry `window_id` forward.

3. **Remove, per candidate that passed step 2** (no window, already exited, or
   quiesced):

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/worktree_cleanup.rb <name>
   ```

   Invoked **by name**, so a busy-skipped candidate is never touched. This
   call also handles the worktree removal, the prune, the branch delete, and
   its own remote prune. Read `data.results[0].result` for the report line and
   `data.beads_to_close` for step 4.

   If step 2 left a `window_id`, close its window now that removal succeeded:

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/tmux_window.rb close [--session <session>] <window_id>
   ```

   Pass `--session` only when step 2 reported `data.session_scoped: true`,
   using the `data.session` value it returned. `data.closed: false` with
   `reason: "window kept, other panes busy"` is a normal outcome - report it
   and move on. So is `data.session_closed: false` with `reason: "session
   kept, other windows busy"`, when `--session` was passed. The removal
   already happened and stands regardless.

4. **Close the beads that just landed.** *(A literal instruction in this
   skill, never routed through a script - see Guidelines.)* Union
   `data.beads_to_close` across every `worktree_cleanup.rb` call this sweep
   made. For each id:

   ```bash
   bd show <id>          # confirm it exists and is not already closed
   bd close <id> --reason="Merged to <default branch> via <request>"
   ```

   Already-closed is a no-op, not an error - say so and move on. An id that
   does not resolve is worth reporting rather than swallowing.

5. **Publish the closes**, only if step 4 closed at least one bead:

   ```bash
   bd dolt push
   ```

   Non-fatal if offline; report that the closes are local and will publish on
   the next push.

## How to read the result

- `blocked` `unsupported_forge` - the manifest names a forge these scripts do
  not implement. Report it and stop; there is no partial path here, and this
  is the script that deletes branches.
- `blocked` `forge_unavailable` (check phase or removal) - **STOP the whole
  sweep.** Without request state there is no safe merge signal. Report the
  error; do not fall back to any git-only check.
- `blocked` `no_matching_worktree` - report what is live instead.
- `blocked` `survey_failed` - report its message; do not proceed on a partial
  worktree list.
- `data.results` empty with `ok: true` - no worktrees at all. Say so and stop.
- The result strings are the report vocabulary directly: `"not merged (no
  request, open, or closed unmerged), kept"`, `"dirty, skipped"`, `"commits
  after merge (<sha> != <sha>), skipped"`, `"merged in request #<n>,
  removed"`, `"merged in request #<n>, would remove"` (dry run), `"remove
  failed, skipped"`.
- `data.beads_to_close` is already deduped and sorted per call. Union across
  calls; do not re-derive it from the forge yourself.
- `warnings` `beads_lookup_failed`, `worktree_remove_failed`,
  `branch_delete_failed` each name one worktree's partial outcome - surface
  them per line rather than as a footnote.

## Report

One line per worktree, naming the beads closed and what happened to the
session and window:

| Worktree | Result |
|---|---|
| `zz-qww.1-team-maintainer-optin` | merged in request #6, closed zz-qww.1, session exited, removed, branch deleted, window closed |
| `zz-qww.4-close-on-merge` | merged in request #10, closed zz-qww.4 + zz-qww.6, no window, removed |
| `zz-00p.3-regression-ratchet` | open request #11, kept |
| `zz-vbu-strict-lint` | no request, kept |
| `zz-92f-area-labels` | dirty, skipped |
| `zz-8k2-send-queue` | merged in request #13, **session busy, skipped** |
| `zz-lzn-tmux-windows` | merged in request #12, **no trailer, no bead closed** |

**A busy session is a skip worth naming, not a footnote.** It is the one
outcome where re-running the sweep later finishes the job on its own, and the
user needs to know there is a job left to finish.

**Nothing to clean is a success, and must say so explicitly** - "no merged
worktrees found, 3 live worktrees kept, no beads closed" rather than silence.
A silent sweep is indistinguishable from the ancestry bug this skill exists to
avoid.

## Guidelines

- An **open request** means work in review; a **closed-unmerged** one means
  work someone abandoned but did not delete. Both are theirs to decide about,
  so both are left alone.
- **Never force a worktree removal, never `-D` an unmerged branch.** Both
  destroy work that exists nowhere else. `git worktree remove` already refuses
  on a dirty tree; that refusal is a feature, and no script routes around it.
  Every skip is reported so a human can deal with it.
- **Quiesce comes after the dirty and SHA checks, not before.** A worktree
  about to be skipped should keep its session running; shutting one down and
  then deciding not to clean up is pure loss. The residual race - the session
  dirties the tree between check and removal - costs nothing, because the
  removal refuses on a dirty tree anyway.
- **Match the window on name and path together, and send ambiguity to a
  human.** `/wurk:branch` sets the window name to the worktree directory name
  and opens it at the worktree path, so a real match agrees on both. Name
  alone would close a window a human renamed onto something else; path alone
  would close a stray shell someone happened to `cd` there.
- **Busy means skip**, the same stance as a dirty tree. Do not force a
  decision a running session has not finished making.
- **Never kill a session, only ask it to exit.** An exit request and a
  timeout - never a signal, never a window kill on a live session. A session
  that will not take the request is one that is doing something, and the point
  of this step is to not be the thing that interrupts it. Idleness comes from
  the byte-level classifier in `tmux_window.rb classify`, which samples twice
  and requires idle both times: one capture can land in the gap between a turn
  ending and the next tool call starting.
- **A bead closes at merge and nowhere else.** A closed bead is a claim about
  the default branch, not about a green branch. Closing at commit or
  request-open time makes `bd ready` offer downstream work against code that
  has not landed, and the shared beads database propagates that wrong state to
  every other machine within minutes. The merge is the moment the claim
  becomes true, so it is the moment to close.
- **The trailer anchor is required, not tidiness.** Commit bodies routinely
  name other beads in prose - citing a design note, crediting a discovery,
  explaining a deviation - and an unanchored match closes every one of them.
  `pr_state.rb beads` is the single definition site for this extraction,
  keyed on the manifest's `commits.trailer`, and shared with `/wurk:mr`.
- **A merged request whose commits carry no trailer closes nothing - report
  that, do not pass over it.** It means either work that skipped
  `/wurk:commit`, or trailers forgotten on a grouped branch. Both leave beads
  open that a human expected closed, and silence is indistinguishable from
  success.
- **Do not let a `bd` failure block cleanup**, and never close a bead for a
  branch whose merge the check phase did not confirm.
- **`bd close` stays a literal instruction here, never routed through a
  script.** No kit script may contain a code path that runs it (the
  banned-operation list in the kit REFERENCE.md). This is the one place in the
  whole workspace lifecycle where that call is authorized, and keeping it
  visible is what keeps its trigger - a verified merge - auditable.
- **Request state or nothing.** If the forge cannot answer, stop.
- **tmux is convenience, never a gate.** No tmux, no server, no window, a
  window with no session in it - all normal, none of them errors.
  `/wurk:branch` treats the window as optional on the way up; this skill does
  the same on the way down.
- **Pairs with `/wurk:refresh`: same moment, opposite direction.** Run this
  one first - refreshing a worktree that is about to be deleted is wasted
  work.
- **A branch may carry several beads.** Trailer-driven closing is what makes
  that safe, so grouping related beads onto one branch is a real option rather
  than something the tooling punishes.
- **Safe to re-run:** unmerged worktrees are kept, already-closed beads are a
  no-op, and a clean sweep changes nothing.

---
name: wurk:refresh
description: Rebase live worktrees onto the latest default branch after a sibling branch lands, repair their build caches if the lockfile moved, and confirm each is green again. Reads .claude/wurk.json; honors .claude/wurk/refresh.md.
model: sonnet
argument-hint: ["optional: one worktree/branch name; omit to sweep all"]
---

# Refresh

Bring live worktrees back in line with the default branch after a sibling
branch lands. `/wurk:branch` cuts a branch from the default branch and clones
the project's warm caches from the main checkout; both are point-in-time. Once
another branch merges, every other worktree is behind, and if the landed
change moved the lockfile named by `parallelism.repair_when`, their cloned
build directories are stale as well.

That staleness is the failure mode this skill exists to prevent: **a worktree
that was green when created goes red for reasons that have nothing to do with
the work inside it**, and the agent working there starts debugging its own
change.

Pairs with `/wurk:cleanup` - same moment, opposite direction. That one removes
the worktree of the branch that just landed; this one refreshes the survivors.

See `~/.claude/skills/wurk:kit/REFERENCE.md` for the envelope contract shared
by every script below.

## Not applicable under `branch-in-place`

Read `parallelism.model` from `.claude/wurk.json` before doing anything else.
Under `branch-in-place` there are no sibling worktrees to refresh: the one
checkout is brought current by an ordinary pull and rebase in whatever session
is using it. **Report that this skill does not apply to this project and
stop.** Do not sweep, and do not rebase the checkout you are standing in as a
substitute - a rebase nobody asked for, in the directory someone is working
in, is exactly the surprise this workflow avoids.

## Project extension

If `.claude/wurk/refresh.md` exists, **read it before the sweep** and treat
its content as additional required steps, placed where it says. Extensions
add; they never override. Typical content: extra files whose movement should
trigger a sweep, project-specific repair expectations.

## Input

`$ARGUMENTS` = optional. One worktree or branch name refreshes just that
worktree; no argument sweeps every live worktree. **The main checkout is never
a target** - it is not a feature branch and is not rebased.

## What to run

```bash
ruby ~/.claude/skills/wurk:kit/scripts/worktree_refresh.rb [name]
```

That is the whole sweep: enumerate live worktrees (dropping the main
checkout), fetch the remote once, then per worktree - skip if the default
branch is already an ancestor, refuse if dirty, rebase (capturing conflicting
files before aborting), run the manifest's `parallelism.repair` commands only
if `parallelism.repair_when` actually moved, and confirm green with
`gate.loop`.

Run it for real; do not `--dry-run` a refresh you intend to act on, since the
report needs the actual rebase and gate outcome rather than a preview.

## How to read the result

- `blocked` `no_matching_worktree` - the given name or branch matched nothing
  live. STOP and report what *is* live instead.
- `blocked` `offline` - the fetch failed. **STOP the whole sweep.** Refreshing
  against a stale remote would rebase every worktree onto the commit it is
  already on and report success for nothing. This is a hard stop, not a
  per-worktree skip.
- `blocked` `survey_failed` - the worktree enumeration itself failed; report
  its message rather than proceeding with a partial list.
- `data.results` empty with `ok: true` - no live worktrees. A normal outcome,
  not an error. Say so and stop.
- Otherwise `data.results` is one entry per worktree, each carrying the
  report vocabulary in `result`:
  - `"current, skipped"` - nothing to do; the build was untouched.
  - `"dirty, skipped"` - uncommitted work; the script never stashed,
    committed, or discarded it.
  - `"conflict in <files>, aborted, unchanged"` - captured and aborted; the
    worktree is exactly as it was.
  - `"red"` - rebase and any repair succeeded, but the loop gate came back
    red.
  - `"rebased onto <sha>, lock unchanged, loop green"` (or `"..., lock
    repaired, loop green"`) - the success case.
- `data.origin_main` is what the default branch moved to; it heads the report.

## Report

One line per worktree, using `data.results[].result` verbatim, plus what the
default branch moved to:

| Worktree | Result |
|---|---|
| `zz-00p.3-regression-ratchet` | rebased onto 146c69f, lock unchanged, loop green |
| `zz-00p.4-corpus-layout` | current, skipped |
| `zz-qww.1-team-maintainer` | **conflict** in `docs/workflow.md`, aborted, unchanged |
| `zz-vbu-strict-lint` | dirty, skipped |

End with the ones needing a human: conflicts, dirty worktrees, red gates.
**Silence about a skipped worktree reads as success** - name every one.

## Guidelines

- **Never stash, commit, or discard on the author's behalf.** Uncommitted work
  belongs to whoever is in that worktree, and a surprise stash during an
  unattended sweep is how it gets lost.
- **A rebase conflict is signal for a human, not something to paper over
  mid-sweep.** It means two branches touched the same files, which means the
  area labels were wrong or the batch was picked badly. Aborting leaves the
  worktree exactly as it was; `bd merge-slot` is the coordination primitive
  for resolving it deliberately, one agent at a time. Name the conflicting
  files in the report.

  This sweep never auto-resolves a conflict, whatever
  `rebase.auto_resolve_paths` allows - that mechanism is scoped to
  `/wurk:mr` only (ADR-0010). A sweep has no per-worktree model turn, no
  branch diff, and no bead context, and the worktree it would be merging in
  belongs to a session that is not this one. A conflict here stays what it
  has always been: signal that the area labels were wrong or the batch was
  picked badly.
- **A red gate is a real result, not a failure of the refresh.** The rebase was
  clean but the combination is not, which is exactly what refreshing early is
  for. Leave the worktree as it is - the agent working there needs to see it.
- **Rebase, never merge.** Keeping branches linear against the default branch
  matches how they will land and avoids a merge commit the eventual request
  cannot use.
- **Nothing here is pushed.** Rebasing rewrites commits; a branch already
  pushed now diverges from its remote counterpart, and the eventual push needs
  `--force-with-lease`. That is `/wurk:mr`'s decision, not this skill's.
- **When to run:** after any branch merges, and always after a change that
  moved the lockfile or any file in `gate.moving_files` - those move the gate
  every other worktree is measured against. Whatever closes the loop on a
  merge should invoke this, so "a branch landed" and "everyone else is
  current" are one event.
- Run `/wurk:cleanup` first. Refreshing a worktree that is about to be deleted
  is wasted work.
- A sweep is safe to re-run: current worktrees are skipped, and the fast path
  costs one merge-base check.

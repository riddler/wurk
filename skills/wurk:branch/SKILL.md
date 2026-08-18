---
name: wurk:branch
description: Stand up the workspace for one bead - under worktree-per-issue, a warmed worktree with its own branch and a seeded tmux session; under branch-in-place, a branch in the current checkout. Reads .claude/wurk.json; honors .claude/wurk/branch.md.
model: sonnet
argument-hint: ["branch/worktree name, e.g. zz-00p.3-regression-ratchet; optionally -- <seed command>"]
---

# Branch

Stand up the workspace for one bead: a branch, and whatever else the project's
parallelism model says goes with it.

The manifest's `parallelism.model` picks between two strategies, and they are
genuinely different workflows rather than variations on one:

- **`worktree-per-issue`** - one bead, one branch, one worktree under
  `parallelism.worktrees_dir`, warmed from the main checkout so the first gate
  run there is fast, with a tmux window and a seeded session in it. Several
  beads are worked in parallel, each in its own directory.
- **`branch-in-place`** - one branch in the current checkout, with the
  project's `parallelism.post_branch` commands run after the switch. One bead
  at a time; nothing to warm, nothing to clean up later.

**`branch-in-place` is not implemented yet.** A project whose manifest selects
it gets a clear refusal from this skill, not a worktree it did not ask for.
Say so and stop; do not fall through to the worktree path.

The bead should already be claimed before the workspace exists - the claim is
the lock, the workspace is only where the work happens. `/wurk:next` claims and
names, then invokes this skill once per bead.

See `~/.claude/skills/wurk:kit/REFERENCE.md` for the envelope contract shared
by every script below.

## Project extension

If `.claude/wurk/branch.md` exists, **read it before step 1** and treat its
content as additional required steps, placed where it says. Extensions add;
they never override. Typical content: naming conventions beyond the shared
grammar, a project's warm-cache expectations, what to check after
`post_branch` has run.

## Input

`$ARGUMENTS` = optionally `--no-finish`, then the branch name, optionally
followed by `--` and the command to seed the new session with.

**`--no-finish`** (optional) is passed straight through to `tmux_window.rb
open` in step 2 - see there for when to use it.

**Branch name** is also the worktree directory name under
`worktree-per-issue`: `<bead-id>-<slug>`, e.g. `zz-00p.3-regression-ratchet`.
Keep the slug to 2-4 distinctive kebab-case words from the bead title, not a
full transcription of it. Given only a bead id, **ask for the slug** - it is
what a human reads when scanning a worktree list, and it is fixed at creation.

The name is never changed afterwards, even if the branch grows to carry more
beads. `/wurk:cleanup` matches its tmux window on name and path together, and
both halves come from this skill.

**Seed command** (optional) is what the new session runs:

```
/wurk:branch zz-00p.3-regression-ratchet -- /wurk:work zz-00p.3 --auto
```

The seed names the **orchestrator, not a stage**: `/wurk:work` sizes the job
from inside the workspace, where the codebase is readable, and drives
research / plan / implement itself. With no seed given, fall back to
`/wurk:work <id> --auto`, so a hand-made workspace behaves exactly like a
routed one.

Pass only the bead id, never a paraphrase of the work. The beads database is
shared across worktrees, so the new session reads the bead directly; a
restated description goes stale the moment the bead is edited.

## What to run

1. **Create and warm the workspace.**

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/worktree_create.rb <name>
   ```

   One call covers the guard (an existing branch or directory), cutting the
   branch from the default branch on the remote (falling back to the local
   one if the fetch fails), trusting the new path with the project's toolchain
   manager before any managed command runs there, cloning the warm caches, and
   a final `gate.loop` run to confirm the workspace comes up green.

   Every one of those - where the worktree goes, what trusts it, what gets
   cloned, which gate runs - is read from `.claude/wurk.json`
   (`parallelism.worktrees_dir`, `parallelism.trust`,
   `parallelism.warm_clone`, `parallelism.warm`, `parallelism.warm_globs`,
   `gate.loop`), which is why this prose names fields and not commands.

   Run it for real. **Do not `--dry-run` this one**: the point of the step is
   the workspace existing and warm, and a preview leaves you with neither.

2. **Open the tmux window**, only once step 1 reports `ok: true`:

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/tmux_window.rb ensure-session
   ruby ~/.claude/skills/wurk:kit/scripts/tmux_window.rb open [--no-finish] <name> <path> <id> <seed>
   ```

   `<path>` comes from step 1's `data.path`. `<id>` is the bead id at the
   front of the branch name (`zz-lzn` from `zz-lzn-tmux-window-per-worktree`,
   `zz-00p.3` from `zz-00p.3-regression-ratchet`). `<seed>` is the seed
   command, passed through verbatim including its leading slash. `<id>` is
   still required even when passing `--no-finish` below - the arity check
   stays strict.

   Pass **`--no-finish`** when the seed makes its own commit (a release seed
   that runs its own commit step, for example), or when the workspace name
   carries no bead id at all - in either case the appended finishing clause
   would either find nothing to commit or name something that is not a bead.
   Every other seed keeps the default appended clause.

   The session's model comes from the manifest's `tmux.model`, passed
   explicitly by the script rather than left to whatever default the launched
   session would otherwise inherit.

   The topology is the manifest's `tmux.layout`, and the script handles both
   without any branching in this prose: under `window-per-issue` the two
   commands do what they have always done. Under `session-per-issue`,
   `ensure-session` has nothing to do and reports that; `open` creates the
   workspace's own session, named for the workspace, with an optional editor
   window ahead of the seeded `claude` window.

## How to read the result

`worktree_create.rb`:

- `blocked` `wrong_parallelism_model` - the manifest selects `branch-in-place`.
  Report the refusal described at the top of this document and stop. **Do not
  create a directory yourself to work around it**: a stray sibling worktree
  nothing else in the workflow knows about is worse than no workspace.
- `blocked` `missing_worktrees_dir` - the manifest selects worktree-per-issue
  but says nowhere to put the worktree. Report it; that is a manifest fix, not
  something to guess.
- `blocked` `not_main_checkout` - worktrees are cut from the main checkout.
  Report where the command was run from.
- `blocked` `branch_exists` or `worktree_dir_exists` - STOP and report. Offer a
  different name, or let the user remove the old one. **Never force**: this
  script has no path that deletes a branch or a directory to make room, and
  neither do you.
- `warnings` worth surfacing in the report: `fetch_failed` (the branch was cut
  from the local default branch instead of the remote's - say so, since it may
  be behind), `trust_failed`, `cache_clone_failed`, `warm_failed`, and
  `warm_cache_missing` (a cache named by `parallelism.warm_globs` did not come
  across; name the file, and suggest rebuilding it once in either checkout).
- `data.quality_green` false (`ok: false`) - the warm workspace came up red
  before any work was done in it. Report `data.quality_output` **in full,
  never truncated**; when it is more than trivially small, hand it to the
  **wurk-gate-reader** agent rather than reading it here.
- `data.path`, `data.base_ref`, `data.name`, and `data.warm_caches_present`
  feed the report and step 2.

`tmux_window.rb`:

- **This step is optional and never fatal.** The workspace is the deliverable;
  the window is a place to sit. If tmux is genuinely unreachable, or the
  manifest has no `tmux` section at all (`blocked` `tmux_not_configured`),
  skip the step with a note and go to the report. Never fail workspace
  creation because a window could not be made.
- `data.skipped: true` - a window or a session of this name already exists,
  depending on `data.layout`. Report it; do not make a second one.
- `blocked` `window_id_empty` - report it as the window step failing, not as
  the workspace failing.
- On success, `data.layout`, `data.session`, `data.editor_window_id`,
  `data.window_id`, `data.name`, `data.path`, and `data.model` feed the
  report directly.

## Report

State the workspace path, the branch and what it was cut from, whether the
warm caches came along, the gate result, **the tmux window** (name and id, or
why it was skipped), and **the model the session launched with**, so the user
can jump to it and knows what is running there without switching windows.
When `data.layout` is `session-per-issue`, state the session name alongside
the window.

Remind that subsequent work on this bead happens **inside the workspace**, and
that under worktree-per-issue the worktree is removed at merge by
`/wurk:cleanup`.

## Guidelines

- **The seed names the orchestrator.** Seeding a stage (`/wurk:implement`,
  `/wurk:research`) decides the sizing from outside the workspace, where the
  codebase has not been read yet. `/wurk:work` makes that call from inside,
  which is the whole reason it exists.
- **The finishing clause is appended by the script**, to a given seed and to
  the fallback alike, because the open step is where every caller converges -
  editing one template reaches every seeded session. It names
  `/wurk:commit --auto` rather than bare `/wurk:commit` because a seeded
  session runs unattended: an interactive approval step would stall with
  nobody watching the window to answer it. Pass `--no-finish` (see step 2) to
  suppress it for a seed that does not want it.

  That does not grant commit authority beyond what the project's authority
  table already grants. It routes the same authority through the skill that
  performs the trailer and unrelated-change checks, instead of a bare
  `git commit` that skips them.
- **The session starts in auto permission mode**, so it makes routine calls
  without stopping to confirm each one - the point of fanning workspaces out
  is not to then babysit four sessions. It is auto, not bypass: the permission
  system still applies, and the project's authority table still gates push,
  request-opening, and bead-closing on an explicit human ask.
- **A seeded session cannot spawn a nested Claude session of its own** - auto
  mode's classifier blocks it, regardless of which model is driving. If a bead
  needs a live session to observe (terminal rendering, spinner frames, dialog
  layout), use a **sibling workspace session** instead: a batch run routinely
  has two or three live in the same tmux server, with nothing new to launch
  and nothing to clean up afterward. They are also more representative than a
  bare session started in a scratch directory.
- **Nothing here is pushed.** No upstream is set. The branch is local until
  `/wurk:mr` pushes it.
- The beads database is shared across worktrees, so `bd` behaves identically
  from any of them.

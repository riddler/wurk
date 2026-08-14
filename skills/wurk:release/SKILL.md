---
name: wurk:release
description: Perform the mechanical part of cutting a release - bump the version, promote the changelog, commit - driven by the manifest's release recipe. Never tags, pushes, or publishes. Refuses when the project has no recipe. Reads .claude/wurk.json; honors .claude/wurk/release.md.
model: sonnet
argument-hint: ["X.Y.Z - the version being released; required, never inferred"]
---

# Release

Perform the **mechanical** part of cutting a release: bump the version where
the project keeps it, promote the changelog, commit. Nothing else.

**This skill never tags, never pushes, never opens a request, and never
publishes a package.** Those are separate human decisions, and finishing a
release commit is not a trigger for any of them. Publishing in particular has
no trigger at all, ever, from any session.

See `~/.claude/skills/wurk:kit/REFERENCE.md` for the envelope contract shared
by every script below.

## The recipe

Read `release` from `.claude/wurk.json`.

**`null` or absent -> this project has no release recipe. Say exactly that and
stop.** Do not improvise one from the files you find: a project without a
recipe either does not cut releases from this workflow, or has not decided how
yet, and both cases are answered by asking rather than by guessing which file
holds the version.

Otherwise `release.kind` selects the recipe. **Follow exactly one**, and only
the edits that recipe names:

### `kind: "hex"`

Three edits, and nothing else:

1. **The version file** (`release.version_file`) - the version attribute
   changes from the old value to `X.Y.Z`.
2. **The README install pin**, where `release.readme_pin` is true - the
   dependency snippet's constraint bumps to the new major/minor, dropping the
   patch component in whatever form previous releases used. Check a previous
   release commit rather than inventing the format.
3. **The changelog** (`release.changelog`) - the `## [Unreleased]` heading
   becomes `## [X.Y.Z] - YYYY-MM-DD`, dated today. **Leave every line under it
   untouched**, and do not add a fresh `## [Unreleased]` stub above it.

### Other kinds

A `release.kind` this skill does not implement gets a clear refusal naming the
kind, exactly like a missing recipe. Half-performing a release recipe is worse
than not starting one: a version bumped in one of three places is a state
nobody can tell from a finished release by looking.

## Project extension

If `.claude/wurk/release.md` exists, **read it before step 1** and treat its
content as additional required steps, placed where it says. Extensions add;
they never override. Typical content: the exact form of the project's install
pin, which artifacts a release must not touch, publishing rules stated so
nobody mistakes them for something this skill does.

## Input

`$ARGUMENTS` must contain a semver `X.Y.Z` (trailing free text is ignored). If
it is missing or does not parse, **STOP and ask the user to name the exact
version being released.**

**The version is never inferred** - not from the unreleased changelog
entries, not from the latest tag, not from a bump rule. Cutting a release
requires the user to ask for one *and* name the version; invoking this skill is
only the first half of that unless the version came with it.

## Steps

### Step 0: Preconditions

```bash
ruby ~/.claude/skills/wurk:kit/scripts/repo_state.rb
```

- **STOP if `data.dirty`.** An uncommitted change is either unrelated to the
  release - in which case it does not belong in the release commit - or it is
  work that needs its own commit first. This check is unconditional and runs
  before anything below, including on the default branch: a dirty tree is
  never a reason to stand up a workspace.

Then read the current version from the recipe's version file and confirm the
requested version is **strictly greater** (compare major, then minor, then
patch as integers). **STOP on equal or lesser**: almost always a typo or the
wrong argument.

Read the changelog's unreleased section. **STOP if it is missing, or present
with no entries under it** - there is nothing to release.

These two checks are cheap reads, and they run **before** anything is created:
a version typo or an empty changelog should never leave behind a workspace
that only gets thrown away.

**If `data.on_default_branch`, stand up a workspace for the release and
finish there instead of committing in place.** A release commit is a commit
like any other and belongs on a branch; this skill no longer refuses on the
default branch, it branches off it, the same way `/wurk:next` stands up a
workspace before handing a bead to `/wurk:work` rather than working it in the
main checkout.

Name the workspace `release-vX.Y.Z` from the requested version (e.g.
`release-v1.2.3`) - there is no bead id to build the name from, so the version
is the whole name.

```
/wurk:branch release-vX.Y.Z -- /wurk:release X.Y.Z
```

- **`parallelism.model: worktree-per-issue`** (the common case) - `/wurk:branch`
  creates a sibling worktree and opens a seeded tmux window there; this
  session cannot simply keep going in a directory it never `cd`ed into, so it
  **hands off** rather than continuing here. The seed re-invokes this skill
  with the same version argument, in the new worktree, on the new branch -
  where `data.on_default_branch` is now false, so the seeded run falls straight
  through this paragraph to the dirty/version/changelog checks (cheap and
  idempotent to repeat) and on into Steps 1-4. No `--auto` flag is needed and
  none exists on this skill: nothing past Step 0 pauses for interactive
  confirmation, so the plain seed is already unattended-safe. Once `/wurk:branch`
  reports success, **this session's job is done** - report the workspace path
  and the tmux window per its own reporting contract, and stop; do not also
  try to perform Steps 1-4 here against a path this session is not in.

  `/wurk:branch`'s own `<id>` for the tmux window comes from the bead id at
  the front of the branch name, and a release name has none - pass the whole
  workspace name (`release-vX.Y.Z`) as `<id>` rather than guessing a fake
  bead id out of it. That `<id>` also lands in `tmux_window.rb`'s
  `FINISH_TEMPLATE`, which appends "finish with `/wurk:commit --auto` ...
  refuses if the tree carries changes unrelated to `<id>`" to every seed.
  This skill's own Step 3 already makes the release commit directly, so the
  seeded session reaches that appended clause with a clean tree and nothing
  left to commit - it is not a second commit to make and not a reason to fold
  anything extra in; the seeded session should simply finish once Step 3 and
  Step 4 are done and let the appended instruction find nothing to do.
- **`parallelism.model: branch-in-place`** - `/wurk:branch` itself refuses this
  model as unimplemented. Surface that refusal exactly as `/wurk:branch`
  reports it and **STOP**; do not fall back to committing on the default
  branch anyway, and do not invent a branch-in-place path here that
  `/wurk:branch` does not have.

`worktree_create.rb` (which `/wurk:branch` runs) also blocks with
`not_main_checkout` when it is not run from the main checkout. That case is
not expected to be reachable here: git refuses to check the same branch out
in two worktrees at once, so `data.on_default_branch` can only be true in the
checkout that has the default branch checked out, which is ordinarily the
main checkout. Report the block if it somehow fires - a manually created
worktree pinned to the default branch is the only way it could - but do not
treat it as a normal outcome to design around.

### Step 1: Make the mechanical edits

Exactly the edits the recipe names, and no others. **Reordering,
consolidating, or rewording changelog entries is an editorial pass a human
does separately**, not something this step infers on the way past.

### Step 2: Run the full gate

```bash
ruby ~/.claude/skills/wurk:kit/scripts/gate.rb
```

The version file is a build file, so no carve-out applies here: this step
always runs, and never in a narrowed or loop form. **STOP on red** and report
the failing stages; a version bump breaking the suite is exactly what the gate
exists to catch before it becomes a tagged release. Where the output is more
than trivially small, hand it to the **wurk-gate-reader** agent rather than
reading it here.

### Step 3: Commit

```bash
git status --porcelain
```

Confirm only the recipe's files changed. **STOP if anything else is dirty** -
do not fold unrelated changes into a release commit.

Commit them with the title `Releases vX.Y.Z` and a body naming each mechanical
edit, one bullet each. The subject-length and body-width limits from
`commits.*` apply here as everywhere. **No AI attribution**, same rule as every
other commit.

Where the user named a bead or epic to reference, add the manifest's commit
trailer for it; otherwise omit it. Release commits are not required to close a
bead.

Verify immediately:

```bash
git log -1 --pretty=format:"%B"
```

Check the title and check for attribution; amend rather than leaving a bad
commit in place.

### Step 4: Report

State plainly what happened **and what deliberately did not**:

```
Committed: Releases vX.Y.Z (<sha>)
Files:     <exactly the recipe's files>
Gate:      full gate green

Not done, and not this skill's to do:
- tagging the release
- pushing, or opening a request
- publishing the package
- closing any bead

Next steps are yours to take explicitly.
```

The "not done" list is not boilerplate. It is the part of the report that
keeps a release commit from reading as a released version.

## Guidelines

- **Never tag, push, or publish.** No outcome of this skill is a trigger for
  any of them.
- **On the default branch, this skill branches off it rather than refusing.**
  Under `worktree-per-issue` that means handing off to a seeded session in a
  new worktree named `release-vX.Y.Z`, not finishing the release in this
  session - see Step 0. Under `branch-in-place`, `/wurk:branch` has no
  implementation yet, so this skill reports that refusal and stops rather than
  committing on the default branch.
- **The version is always explicit input.** "Just bump the minor" is still a
  human decision to state out loud, not a default to compute.
- **Content curation is out of scope.** This skill renames a heading and
  stamps a date; it does not rewrite release notes.
- **One recipe, followed exactly.** Extra edits that seem obviously implied -
  a version mentioned in a doc, a badge, a lockfile - are either in the recipe
  or are not part of a release. If one is genuinely missing, say so and let the
  recipe be fixed; do not perform it this once.

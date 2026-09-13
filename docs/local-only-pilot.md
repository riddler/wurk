# The local-only pilot: trying wurk with zero footprint

A repo can run the whole wurk workflow before it decides to adopt it. The
manifest, the extension files and the hooks stay untracked; the beads
database stays on the machine with no sync remote; nothing appears in a
diff, a branch, or a push. This document is the recommended
low-commitment adoption path, the two non-obvious consequences of running
that way, the things a local-only pilot must never do, and the single step
that graduates a successful pilot into a real adoption.

This is a consumer pattern, not a kit feature - like
`docs/two-tracker-pattern.md`, nothing here changes a skill, a script, or
the manifest schema. If a pilot needs generic behavior to differ, that is
a missing manifest field (ADR-0004), not a reason to keep the config
untracked forever.

## The shape

Four pieces, none of them tracked:

```
<consumer repo>/.claude/wurk.json          the manifest (ADR-0004)
<consumer repo>/.claude/wurk/*.md          extensions, if any
<consumer repo>/.claude/settings.json      hooks (bd prime) and deny rules
<consumer repo>/.beads/                    the tracker (ADR-0007), local only
```

All four are listed in `.git/info/exclude` rather than `.gitignore`:
`.gitignore` is itself a tracked file, so adding entries to it is already
a commit in the consumer's history, which is the thing the pilot is
avoiding. `.git/info/exclude` is per-clone and invisible to everyone else.

The manifest declares `"beads": {"sync": "local"}` explicitly. Absent, it
resolves to `local` anyway - that default is chosen against the usual rule
precisely so an unstated mode can never cause a push (see
"`beads.sync`" in `docs/manifest.md`) - but an unset key warns on every
manifest load, and a pilot wants the sentence "local because the repo said
so" rather than "local because nobody said anything".

Under `local`, no skill runs `bd dolt push`. A step that would have pushed
reports `not pushed, tracker is local` and carries on; nothing else about
it changes.

## Consequence 1: untracked config does not exist inside a worktree

Under `parallelism.model: worktree-per-issue`, `/wurk:branch` creates a
worktree by checking out a branch into a fresh directory. A checkout
contains tracked files. The pilot's config is untracked, so **none of it
is in the worktree** - no `.claude/wurk.json`, no `.claude/wurk/*.md`, no
`.claude/settings.json`, and no helper script the manifest points at.

That breaks every manifest command whose argv names a path relative to the
checkout it runs in. The manifest's five gate commands run inside the
checkout being gated, and `parallelism.warm` / `repair` run inside the new
or refreshed worktree (`parallelism.trust` runs *about* it, with `{path}`
substituted). A pilot whose gate is `["./scripts/gate.sh"]` or
`[".claude/scripts/gate.rb"]` therefore fails in the worktree with a
missing file, while working perfectly in the main checkout.

**The rule: in a local-only pilot, every manifest command that names a
script of the consumer's own is an absolute path into the main checkout**,
and that script operates on its caller's current working directory, never
on its own location:

```jsonc
"gate": {
  "full": ["/Users/me/repos/acme/.claude/scripts/gate.sh"],
  "loop": ["/Users/me/repos/acme/.claude/scripts/gate.sh", "--loop"]
},
"parallelism": {
  "warm": [["/Users/me/repos/acme/.claude/scripts/warm.sh"]],
  "trust": ["/Users/me/repos/acme/.claude/scripts/trust.sh", "{path}"]
}
```

The absolute path is what makes the script reachable from a worktree; the
cwd rule is what makes it gate the *worktree* rather than silently
re-gating main. A script that resolves its targets from `$0` or
`__dir__` will do the second thing and report green for code that is not
the code under test - the failure mode this rule exists to prevent.

Two notes on the paths themselves. A machine-bound absolute path is
tolerable here only because the file is untracked and belongs to one
machine; the moment the config is committed, an absolute
`/Users/<someone>/...` in it is wrong for every other engineer, and
graduation (below) is where it becomes a repo-relative path. And this is
config, not kit code: a kit script never bakes in an absolute path (see
`Manifest.main_checkout`, which asks git instead).

## Consequence 2: a worktree reads the MAIN checkout's manifest

`Manifest.locate` resolves in two steps: walk up from the working
directory looking for `.claude/wurk.json`, and failing that, ask git for
the main checkout (`git rev-parse --git-common-dir`, whose parent is the
main working tree) and look there.

With a tracked manifest, step 1 answers, and it answers with the
worktree's *own* copy - which is the point of walking up first: a branch
that edits the manifest is testable on that branch. With an untracked
manifest there is nothing to find in the worktree (consequence 1), the
walk-up passes through to the filesystem root, and step 2 answers with the
main checkout's file.

So manifest resolution keeps working from worktrees during a pilot, but
only via the fallback, and the value it returns is main's. Two things
follow:

- **Fine while piloting solo.** Every worktree sees one manifest, which is
  the one you are editing, and editing it takes effect everywhere at once
  with no commit.
- **Branch-local manifest testing is unavailable.** You cannot put a
  manifest change on a branch and check that only that branch behaves
  differently, because the branch has no manifest of its own to read. Any
  manifest experiment is global to the clone until the config is
  committed. If a pilot reaches the point of wanting to A/B a manifest
  change, that is a signal to graduate rather than a problem to work
  around.

## What a local-only pilot must never do

The tracker is the part of a pilot that can escape the machine, and it can
do so on the first command, before anyone reviews anything. A local-only
consumer never runs:

- `bd bootstrap`
- `bd init` in a checkout whose git origin is visible
- `bd dolt push`
- `bd dolt remote add`

and never sets `sync.remote` in `.beads/config.yaml`.

The form of `bd init` that a pilot can run with an origin visible is the
stealth one, verified on bd 1.2.2: `bd init --prefix <p> --stealth
--skip-agents --skip-hooks --non-interactive` wires no remote, commits
nothing, and writes the `.beads/` exclusion itself. `docs/adoption.md`
step 3 lists the checks that prove it, and they are run every time,
because this is a flag-level exception to the rule below that the
prohibition is on commands rather than arguments: it holds for the bd
version it was checked against, and the checks are what make it safe
rather than the flags. The plain form both wires the remote and commits
nineteen generated files to the current branch.

**The incident.** A session ran `bd bootstrap` inside the pilot consumer.
Bootstrap auto-wired the repo's git origin as the beads sync remote and
pushed `refs/dolt/data` to the consumer's organization remote - publishing
the tracker of a pilot whose entire premise was that it left no trace in
that repo. `bd init` does the same thing when origin is visible. Neither
command asks. Nothing un-publishes the result: a deleted ref is still in
clones and in the forge's logs.

The prohibition is therefore on the commands, not on their arguments.
`beads.sync: local` guarantees that no *wurk skill* issues a tracker push;
it cannot guarantee anything about a hand-run `bd` command, which is
exactly the gap the incident fell through.

**Install a guard, and run it early.** The pilot behind this document runs
one at the top of every gate invocation, which is the one place a
long-running session reliably passes through. It scrubs all three places a
remote can hide, and prints loudly when it finds one, because a silent
guard teaches nobody:

1. `sync.remote` in `.beads/config.yaml` - the key `bd` itself reads.
2. Dolt remotes: `bd dolt remote list`, and
   `.beads/embeddeddolt/*/.dolt/repo_state.json`, which keeps a remote
   that was added once even after the yaml no longer mentions it.
3. Whatever `bd` has cached about the repo's git remote (its
   git-remote-cache), which is what the auto-wiring consults.

The third and second places are why scrubbing the yaml alone is not
enough: in the incident behind `beads.sync` the remote was only in dolt's
own state, where a guard script deleting it from the yaml never reached
it. `manifest.rb check` reports the same combination as the
`beads_sync_local_with_dolt_remote` warning - mode `local` with a dolt
remote still configured - so a pilot gets a second, independent reading of
the same fact on every lint.

**Turn bd's metrics off.** `bd config` carries `metrics.disabled`; a fully
local pilot sets it, so the tracker makes no network call of its own
either. On bd 1.2.2 it is stored machine-wide, in
`~/.config/bd/config.yaml`, so it is set once per machine rather than per
pilot; earlier versions kept it in `.beads/config.yaml`.

One thing a pilot does *not* have to avoid: the outbound-scan hook
(ADR-0014) is installed per repo by the operator from the target checkout,
never by `install.rb`, and it refuses to install into a hooks directory
shared across every repo on the machine rather than widening scope
silently. Installing it during a pilot is consistent with the pilot's
footprint, since git hooks are not tracked content.

## Graduating: commit the config

A pilot that has earned its keep graduates in one step - **commit the
config** - and the two consequences above disappear with it:

1. Remove the config entries from `.git/info/exclude`. `.beads/` goes
   with them only if step 3 chooses a sync mode that tracks it; under a
   stealth `bd init` (see above) it stays excluded while the tracker
   stays local.
2. Rewrite every absolute path in `.claude/wurk.json` as a repo-relative
   one, and commit the scripts they point at. This is the change
   consequence 1's machine-bound paths were always deferring.
3. Decide `beads.sync` for real. Staying `local` is a legitimate answer;
   moving to `git` or `dolthub` means the tracker now has a remote on
   purpose, and the guard above should come out in the same commit as the
   remote goes in, so nobody is left with a scrubber fighting a remote the
   repo wants.
4. Commit `.claude/wurk.json`, `.claude/wurk/*.md` and
   `.claude/settings.json` together. From this commit, a worktree finds
   its own manifest by walk-up, and branch-local manifest testing works.
5. Retire the guard, or keep it and say why. If `beads.sync` stayed
   `local`, keep it - the prohibition above still holds, and now it holds
   for everyone on the team rather than for one engineer's clone.

After step 4, per-machine settings that were tolerable in an untracked
manifest no longer are: anything the *machine* or the person at it decides
belongs in `~/.claude/wurk.local.json` instead (ADR-0013,
`docs/machine-config.md`). Permission mode is the worked example.

# Adopting wurk in a new repo

This is the ordered checklist for a repository that has never used wurk:
no skills to delete, no extension files to port, no beads database yet.
`docs/plan.md`'s phase 3 and phase 4 are the recipes for consumers that
already carried a copy of the workflow; this document is the recipe for
one that starts from nothing. It lands in the local-only pilot shape
(`docs/local-only-pilot.md`) by default, so nothing here appears in the
repo's history until the last step, graduation, which is a deliberate
choice rather than a side effect of setup.

Follow it by hand, or ask a Claude Code session in the repo to follow it.
`/wurk:init` automates the mechanical parts and lands in the same pilot
shape; this document is what the skill is checked against, and the path
to follow when a step needs a person's judgment the skill defers.

Every step names what it produces and what a wrong result looks like. If a
step's check fails, stop there: every later step assumes the earlier ones.

## 0. Prerequisites, once per machine

| Need | Why | Check |
|---|---|---|
| Ruby 2.6 or newer on `PATH` | every kit script is stdlib Ruby (ADR-0006); macOS ships 2.6.10 at `/usr/bin/ruby`, most Linux distributions need a package | `ruby -v` |
| `bd` (beads) | the issue tracker (ADR-0007); every skill starts from a bead | `bd version` |
| `git`, and `gh` or `glab` for the forge | `/wurk:mr` and `/wurk:cleanup` read request state through the forge CLI | `gh auth status` or `glab auth status` |
| Claude Code | the skills are Claude Code skills | `claude --version` |
| `tmux` | optional; only `parallelism.model: worktree-per-issue` with a `tmux` section uses it | `tmux -V` |

A machine without Ruby cannot run any kit script, and every skill's first
step is a kit script. Install Ruby before anything else.

Then clone wurk and link it:

```bash
git clone <wurk remote> ~/repos/github/wurk
cd ~/repos/github/wurk
ruby install.rb            # symlinks skills/wurk:* and agents/*.md into ~/.claude
ls -la ~/.claude/skills | grep wurk:
```

`install.rb` is idempotent and refuses to replace anything it did not
create; if it exits 1, move the named entry aside and re-run. Updating wurk
later is `git pull` in this clone; the symlinks pick it up.

## 1. Survey the repo before writing anything

The manifest is data about the project, and every value below has to be
true before it goes in. Answer these by looking, not by assuming:

- **Default branch.** `git symbolic-ref refs/remotes/origin/HEAD` or the
  forge's settings. Anything other than `main` goes in
  `repo.default_branch`.
- **The gate.** The one command that runs every check the project trusts
  and exits non-zero when any fails. If no such single command exists yet,
  make one (a `Makefile` target, a `tox` env, a `mise` task, a script);
  the gate contract (`docs/gate-contract.md`, tier 0) needs nothing more
  than an argv array and an exit code. Also decide the quick form, the
  subset a developer runs in a loop; when there is no meaningful subset,
  the two are the same command.
- **Where tests live and what a test declaration looks like**, for the
  sabotage scan (`docs/recipes/sabotage-testing.md`).
- **Files that move the gate**: the lint config, the coverage threshold,
  the test runner's own config. These become `gate.moving_files` and the
  matching deny rules.
- **Forge.** GitHub or GitLab, and whether the host is self-hosted.
- **Toolchain warm-up.** What a fresh checkout needs before the gate can
  run (a virtualenv, a dependency install), and which file changing means
  it has to be redone (the lockfile). Only needed under
  `worktree-per-issue`.
- **Docs layout.** Where plans, research documents, and decision records
  will live. `docs/plans`, `docs/research`, and `docs/adr` are the
  conventions the docs agents fall back to.
- **Existing tracker state.** Whether `.beads/` already exists (then this
  is not a new adoption; see `docs/plan.md` phase 3), and whether the
  project has an upstream business tracker such as Jira
  (`docs/two-tracker-pattern.md`).

Language-specific worked values for a Python project are in
`docs/examples/python.md`; the Elixir and Rust+Swift values are in
`docs/manifest.md`'s per-repo table.

## 2. Write the manifest

Create `.claude/wurk.json`. The required keys are `wurk`, `beads.prefix`,
`forge.kind`, `gate.full`, `gate.loop`, `parallelism.model`,
`artifacts.plans`, `artifacts.research`, and `changelog.mode`
(`docs/manifest.md`, "Required, optional, and defaults"). A minimal
manifest that a solo developer on GitHub can start from:

```jsonc
{
  "wurk": 1,
  "beads": {"prefix": "acme", "sync": "local"},
  "forge": {"kind": "github"},
  "gate": {
    "full": ["make", "check"],
    "loop": ["make", "test"],
    "build_paths": ["src/", "tests/", "Makefile", "pyproject.toml"],
    "moving_files": ["Makefile"]
  },
  "parallelism": {"model": "branch-in-place"},
  "artifacts": {"plans": "docs/plans", "research": "docs/research"},
  "changelog": {"mode": "none"},
  "release": null
}
```

Three structural choices are made here and are expensive to reverse
later; make them on purpose:

- **`beads.prefix`.** Bead ids are cited from commit trailers and document
  filenames that are never rewritten (ADR-0007). Choose a short prefix
  that will still make sense in a year.
- **`parallelism.model`.** `branch-in-place` is the lighter start: one
  checkout, one branch at a time, no worktrees, no tmux. Move to
  `worktree-per-issue` when two beads genuinely need to be open at once;
  it adds `worktrees_dir`, the warm and repair commands, and optionally a
  `tmux` section.
- **`beads.sync`.** `local` during the pilot, declared explicitly so the
  loader stops warning. The choice of a real remote is made at
  graduation, not here.

`gate.build_paths` is not in the required list and is still not optional in
practice: it is where the kit looks to decide whether a change needs the
gate at all, and with it absent no change ever matches, so `gate.rb` skips
the gate command for every commit and reports `applicable: false`. Name
every tree and file whose change should run the gate.

Set `changelog.mode` to `none` unless the project already keeps a
changelog; `release` stays `null` unless a release recipe exists for the
project's packaging (`docs/manifest.md`, "Release recipes"; today only
`hex` is implemented).

Then lint it, from the repo root:

```bash
ruby ~/.claude/skills/wurk:kit/scripts/lib/manifest.rb check
```

The envelope's `ok` must be `true` with no `blocked` entries. A warning
about `beads.sync` means the key is missing; declare it. Read any other
warning in full; each says what it found and where.

## 3. Initialize beads without touching the repo or the network

`bd init` has side effects that a pilot cannot accept: with an `origin`
remote visible it wires that remote as the tracker's sync remote (the
incident behind `docs/local-only-pilot.md`), and by default it writes
`AGENTS.md`, `CLAUDE.md`, `.claude/settings.json`, `.codex/`, `.gitignore`
and `.beads/hooks/` and **commits all of them** to the current branch.
Verified on bd 1.2.2 (2026-09-13): the plain form produced a 19-file
commit and a `sync.remote` pointing at origin.

The form that produces none of that, verified the same day with an origin
remote present:

```bash
bd init --prefix <prefix> --stealth --skip-agents --skip-hooks --non-interactive
bd config set metrics.disabled true   # bd 1.2.2 stores this machine-wide, in ~/.config/bd/config.yaml
```

After it, all of the following must hold, and each is worth checking once
because the failure mode is a published tracker:

```bash
git status --short                      # empty: nothing staged, nothing untracked
git log --oneline -1                    # your last commit, not "bd init: ..."
grep -A1 '^sync' .beads/config.yaml     # no output
bd dolt remote list                     # "No remotes configured."
grep -v '^#' .git/info/exclude          # .beads/ and .claude/settings.local.json listed
```

`--stealth` writes the exclusions to `.git/info/exclude` and wires no
remote; `--skip-agents` leaves the project's own `AGENTS.md`, `CLAUDE.md`
and `settings.json` for step 4 to write in the shapes wurk expects;
`--skip-hooks` leaves git hooks alone (the outbound-scan hook, if wanted,
is installed separately in step 6). The prefix must match
`beads.prefix` in the manifest.

Never run `bd bootstrap`, `bd dolt remote add`, or `bd dolt push` in a
pilot. The prohibition is on the commands, not their arguments
(`docs/local-only-pilot.md`, "What a local-only pilot must never do").

## 4. Write the three files wurk expects beside the manifest

**`.claude/settings.json`**, the `bd prime` hook. Without it the session
never learns bead state:

```json
{
  "hooks": {
    "SessionStart": [
      {"matcher": "", "hooks": [{"type": "command", "command": "bd prime --hook-json"}]}
    ]
  },
  "permissions": {
    "deny": ["Edit(Makefile)"]
  }
}
```

The deny list mirrors `gate.moving_files`, one `Edit(path)` per file
(`skills/wurk:kit/REFERENCE.md`, "Recommended consumer settings", for why
`deny` rather than `ask` and why `Edit` alone is the whole rule).

**`AGENTS.md`**, a stub that names the tracker and defers the command
reference to `bd prime`. Copy wurk's own (`AGENTS.md` in this repo) and
change the prefix. Do not let `bd integrate --update` expand it.

**`CLAUDE.md`**, with an authority table: what an agent may do without
being asked (create, claim, and note beads; run the gate) and what needs
the user to ask in their own words (commit, push, open a request, close a
bead). Wurk skills read this table and never widen it
(`docs/architecture.md`, "Authority model"). The conservative profile in
this repo's `AGENTS.md` is a copyable starting point. A CLAUDE.md that
already exists gets the table added, not replaced.

Then keep all of it out of the repo for now:

```bash
printf '.claude/wurk.json\n.claude/wurk/\n.claude/settings.json\n' >> .git/info/exclude
```

(`.beads/` is already there from step 3. `AGENTS.md` and `CLAUDE.md` are
project files that would be committed anyway; excluding them is a choice,
not a rule.)

## 5. Prove the gate runs through the kit

```bash
ruby ~/.claude/skills/wurk:kit/scripts/gate.rb
```

The envelope reports `ok: true` with `data.ran: "all"`, `data.tier: 0`,
and `data.attested: false`. That is the expected shape for a gate that is
only an exit code; it is not a degraded state to fix before continuing
(`docs/gate-contract.md`). Two wrong shapes to recognize: `data.applicable:
false` with `data.ran: null` means no changed file matched
`gate.build_paths` and the gate command never ran (widen the list, or
make a throwaway edit under it to test); a `blocked` entry naming a
command means the argv in the manifest does not run from the repo root.
Fix the manifest, not the script.

## 6. Optional pieces, each its own decision

- **Extensions.** `.claude/wurk/<skill>.md` files add required steps to a
  skill; `.claude/wurk/codebase.md` orients the research agents
  (ADR-0011). A new repo needs none on day one. The recipes under
  `docs/recipes/` each end with the extension file they need, if any.
- **Disciplines.** Sabotage testing (`docs/recipes/sabotage-testing.md`),
  a coverage floor (`docs/recipes/coverage.md`), decision records
  (`docs/recipes/adrs.md`), a pre-request review round
  (`docs/recipes/review-agents.md`). Each is a manifest section plus, at
  most, one extension file or agent.
- **Machine config.** `~/.claude/wurk.local.json` holds what the person at
  the machine decides, such as the permission mode of seeded sessions
  (`docs/machine-config.md`). Nothing project-level goes there.
- **The outbound-scan hook.** `outbound_scan.rb install` from the repo
  root, per ADR-0014. Consistent with a pilot's footprint, since hooks are
  untracked.
- **An upstream tracker.** If tickets are filed and read in Jira, Linear
  or Notion, read `docs/two-tracker-pattern.md` before minting the first
  bead, so the external ref convention is in place from bead one.

## 7. Work one bead end to end

```bash
bd create --title="Adopt wurk: first bead" --type=task --priority=2 \
  --description="Why: prove the pipeline. What: a small real change."
```

Then, in a Claude Code session in the repo: `/wurk:work <id>`. The skill
reads the bead, sizes it, and drives plan and implement; `/wurk:commit`
runs the gate and writes the commit against the bead; `/wurk:mr` opens the
request. Under `beads.sync: local` every step that would push the tracker
reports `not pushed, tracker is local` and continues.

The adoption is proven when the request merges and `/wurk:cleanup` closes
the bead from the forge's request state. Anything that stalls before that
is either a manifest value that was assumed rather than surveyed (go back
to step 1) or a genuine gap in wurk, which is a bead in this repo, not a
local workaround.

## 8. Graduate

The pilot has earned its keep when a few beads have landed. Graduation is
the one step that touches history, and it is
`docs/local-only-pilot.md`'s "Graduating" section: remove the exclusions,
turn any absolute paths in the manifest into repo-relative ones, decide
`beads.sync` for real, and commit `.claude/wurk.json`, `.claude/wurk/`,
and `.claude/settings.json` together. `.beads/` is the one entry the
stealth init wrote rather than you: while `beads.sync` stays `local` it
stays excluded, and a move to a remote mode is where it is decided with
the rest of that section. Re-run step 3's checks once more before the
first `bd dolt push`, since that is the first command that can publish.

## What this document does not cover

Migrating a repo that already has a hand-maintained copy of these skills
(`docs/plan.md`, phases 3 and 4). Running several repos as a fleet
(`/wurk:conductor`, `.claude/wurk-fleet.json`). Writing a release recipe
for a packaging the kit does not know (`docs/manifest.md`, "Release
recipes"; it is schema work, not consumer work).

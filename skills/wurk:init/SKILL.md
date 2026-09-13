---
name: wurk:init
description: Adopt wurk in a repo that has never used it - survey the toolchain, forge, tests, and docs layout, ask the structural choices, draft .claude/wurk.json and the files beside it, initialize beads with zero footprint, seed the disciplines the user opts into (decision records, sabotage notes, a review round, an upstream-tracker convention), and prove the gate runs through the kit. Lands in the local-only pilot shape by default. Never commits, never pushes, never touches an existing manifest or tracker.
model: sonnet
argument-hint: ["optional: --tracked (skip the pilot exclusions; the config is meant to be committed), --with adr,sabotage,coverage,review,tracker,scan (pre-answer the opt-ins)"]
---

# Init

Take a repository from "never heard of wurk" to a linted manifest, a
local beads database, the three files the skills expect beside the
manifest, and one green gate run through the kit - without a commit, a
push, or a byte in the repo's history. This is the mechanical half of
`docs/adoption.md` in the wurk clone; that document is the checklist a
person follows by hand, and this skill is checked against it, not the
other way round.

Two things this skill never does, and refuses rather than works around:

- **It never runs a `bd` command that can reach the network.** No
  `bd bootstrap`, no `bd init` without `--stealth` while an `origin` remote
  is visible, no `bd dolt push`, no `bd dolt remote add`. The incident
  behind that list published a pilot's tracker to the consumer's
  organization on its first command; the prohibition is on the commands,
  not their arguments.
- **It never edits what already exists.** An existing `.claude/wurk.json`
  means this is not a new adoption: stop and point at
  `manifest.rb check`. An existing `.beads/` means the tracker is
  already someone's: stop and say so. An existing `CLAUDE.md` or
  `AGENTS.md` gets a section appended, never replaced.

There is no project extension seam here. Extensions are read from
`.claude/wurk/<skill>.md` in a project that has adopted wurk, and this
skill runs before that project exists.

## Input

`$ARGUMENTS`, both optional:

- `--tracked` - the config is meant to be committed by the person
  afterwards, so step 8 writes no `.git/info/exclude` entries and step 3
  uses repo-relative paths only. Default is the pilot shape.
- `--with <list>` - comma-separated opt-ins from `adr`, `sabotage`,
  `coverage`, `review`, `tracker`, `scan`, pre-answering step 2's
  questions. Absent, each is asked.

## Locating wurk's own documents

The skills are symlinks into the wurk clone, and the documents this skill
cites (the adoption checklist, the worked examples, the recipes) live in
that clone, not under `~/.claude`. Resolve the clone once and use it
throughout:

```bash
LINK="$(readlink ~/.claude/skills/wurk:kit)"
test -n "$LINK" || echo "not a symlink"
WURK="$(cd "$(dirname "$LINK")/.." && pwd)"
ls "$WURK/docs/adoption.md" "$WURK/docs/examples" "$WURK/docs/recipes"
```

`install.rb` links `~/.claude/skills/wurk:kit` to `<clone>/skills/wurk:kit`,
so one `..` above the link target's directory is the clone. A `not a
symlink` line means wurk was copied rather than installed, and the `cd`
would otherwise resolve to a directory that is not wurk without failing;
stop there and say so, since every later step assumes the kit is at
`~/.claude/skills/wurk:kit/scripts/`. The `ls` failing means the same.

## Steps

0. **Refuse early on the two preconditions**, before reading anything else:

   ```bash
   test -e .claude/wurk.json && echo "manifest exists"
   test -e .beads && echo "tracker exists"
   git rev-parse --show-toplevel
   ```

   Either `exists` line ends this run with a one-sentence report. Not
   being at a git checkout's root ends it too; the manifest is located by
   walking up from the working directory, and writing it anywhere but the
   root produces a file the kit finds from some directories and not
   others.

   Then check the machine, and stop on the first miss with the name of
   what is missing and where `docs/adoption.md`'s prerequisites section
   says to get it:

   ```bash
   ruby -v                              # 2.6 or newer; every kit script is stdlib Ruby
   bd version
   gh auth status || glab auth status   # authenticated, not merely installed
   claude --version
   tmux -V                              # only if step 2 chooses worktree-per-issue
   ```

   An installed but unauthenticated forge CLI passes a version check and
   fails `/wurk:mr` later, which is why the auth form is the one run here.
   `tmux` is checked after step 2 rather than here, since a
   `branch-in-place` adoption never needs it.

1. **Survey the repo, read-only.** Every manifest value below has to be
   true, and the way to know is to look. Collect, and print as a table
   before asking anything:

   - **Default branch**: `git symbolic-ref refs/remotes/origin/HEAD`, else
     the branch `HEAD` is on. Anything but `main` becomes
     `repo.default_branch`.
   - **Origin**: `git remote get-url origin`, and from its host whether
     `forge.kind` is `github` or `gitlab` and whether `forge.host` needs
     declaring (a self-hosted instance). No origin means `forge.kind` is
     still required; ask.
   - **Toolchain**, from the files at the root - one lockfile or project
     file usually settles it. Use the toolchain to pick the source of its
     values, in this order: a worked example under `$WURK/docs/examples/`
     for that toolchain; else the matching column of
     `$WURK/docs/manifest.md`'s per-repo table plus the declaration
     patterns in `$WURK/docs/recipes/sabotage-testing.md`; else nothing,
     in which case every toolchain-specific value (the gate argv, the
     declaration regex, the lockfile) is asked in step 2 and the report
     says it was asked. Never invent one.
   - **Gate candidates**: a `Makefile` target, a task-runner file, a CI
     workflow's test step, a `scripts/` entry. The gate is one argv that
     exits non-zero when anything the project trusts fails
     (`$WURK/docs/gate-contract.md`, tier 0). Record the best candidate
     for `gate.full` and, if there is a faster subset, for `gate.loop`; if
     nothing single exists yet, the draft will name the test runner alone
     and the report will say a wrapper is the first thing to add.
   - **Where tests live and what declares one**, for `gate.sabotage`.
   - **Files that move the gate**: the linter, type-checker, coverage and
     test-runner configs, the lockfile. These become `gate.moving_files`
     and the deny list.
   - **Docs layout**: existing `docs/`, `thoughts/`, or similar; existing
     ADR-like directories; the conventional names are `docs/plans`,
     `docs/research`, `docs/adr`.
   - **What is already there**: `CLAUDE.md`, `AGENTS.md`,
     `.claude/settings.json` (any of these may exist without wurk).
   - **An upstream tracker**: ticket-shaped ids in recent commit
     subjects or branch names (`ABC-123`), a tracker URL in the README.
     This only informs the `tracker` question; nothing is configured
     from it.

   A survey value the skill could not determine is asked in step 2, not
   guessed. Say which values came from the survey and which from the
   person.

2. **Ask the structural choices, explicitly.** These are expensive to
   reverse and the person makes them; a default is offered, never
   assumed silently. One question each, in this order:

   - **Bead prefix.** Short, lowercase, will still make sense in a year;
     bead ids are cited from commit trailers and document filenames that
     are never rewritten. Offer the repo name's initials.
   - **Parallelism model.** `worktree-per-issue` (one worktree per bead
     under `worktrees_dir`, with warm and repair commands and optionally a
     `tmux` section) or `branch-in-place` (one checkout, one bead at a
     time, no worktrees, no tmux). Offer `worktree-per-issue`, to a solo
     developer too: `branch-in-place` is in the manifest schema but
     `/wurk:branch` does not implement it yet and refuses with
     `wrong_parallelism_model` (wu-7yd.13 in the wurk clone), so a
     project that picks it cannot work its first bead through
     `/wurk:work` until that lands. Say so if the person picks it anyway.
   - **Changelog mode.** `none` unless the project already keeps one
     (`keep-a-changelog` or `fragments` with a `changelog.dir`).
   - **Tracker sync.** `local` in the pilot; say that the choice of a
     remote is made at graduation. Under `--tracked`, still `local` unless
     the person names a mode.
   - **Opt-ins**, skipped for any named in `--with`: decision records
     (`adr`), sabotage notes (`sabotage`), a coverage floor (`coverage`),
     a pre-request review round (`review`), an upstream tracker
     convention (`tracker`). Each is one sentence and the recipe path under
     `$WURK/docs/recipes/` for the person to read later.

3. **Draft the manifest** at `.claude/wurk.json` from the survey and the
   answers, with the required keys (`wurk`, `beads.prefix`, `forge.kind`,
   `gate.full`, `gate.loop`, `parallelism.model`, `artifacts.plans`,
   `artifacts.research`, `changelog.mode`) plus `beads.sync`,
   `gate.build_paths`, `gate.moving_files`, and `release: null`.

   `gate.build_paths` is not in the required list and is not optional in
   practice: it is where the kit looks to decide whether a change needs
   the gate, and absent it nothing ever matches, so the gate never runs
   and every commit reports `applicable: false`. Name every tree and file
   whose change should run the gate: the source and test roots, the gate
   wrapper, the project file.

   Commands are argv arrays, never shell strings. In the pilot shape a
   command that names a script of the repo's own is a PATH lookup or an
   absolute path into this checkout, never a relative one - a worktree
   under `worktree-per-issue` contains tracked files only, and the pilot's
   config is untracked (`$WURK/docs/local-only-pilot.md`, consequence 1).
   The other half of that rule travels with the path: such a script must
   gate its caller's working directory and never resolve its targets from
   its own location, or a worktree's gate silently re-gates the main
   checkout and reports green for code that is not under test. Say this
   in the report whenever the draft names a script by absolute path.
   Under `--tracked`, paths are repo-relative.

   Write the file, then lint it and fix what it reports until it is
   clean:

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/lib/manifest.rb check
   ```

   `ok: true` with no `blocked` entries is the exit condition; warnings
   never flip `ok`, so read each one and act on the ones a manifest edit
   can clear. A `beads.sync` warning means the key is missing. An
   unknown-key warning for a key this kit version does not know yet is
   reported and left. A `blocked` entry names the key and the rule; fix
   the value, not the rule.

4. **Initialize beads without touching the repo or the network.** Only
   this form, with the prefix from step 2:

   ```bash
   bd init --prefix <prefix> --stealth --skip-agents --skip-hooks --non-interactive
   bd config set metrics.disabled true   # machine-wide (~/.config/bd/config.yaml on bd 1.2.2)
   ```

   The metrics setting is the one machine-wide effect this step has; say
   so in the report. `--stealth` wires no remote and writes the `.beads/` exclusion to
   `.git/info/exclude` itself; `--skip-agents` leaves `AGENTS.md`,
   `CLAUDE.md`, and `settings.json` for step 5 to write in the shapes the
   skills expect; `--skip-hooks` leaves git hooks alone. Then prove all
   five, because the failure mode is a published tracker and a commit in
   the person's history:

   ```bash
   git status --short                      # only "?? .claude/wurk.json", the step 3 draft
   git log --oneline -1                    # the person's last commit, not bd's
   grep -A1 '^sync' .beads/config.yaml     # no output
   bd dolt remote list                     # "No remotes configured."
   grep -v '^#' .git/info/exclude          # .beads/ and .claude/settings.local.json listed
   ```

   The status line is one untracked file, the manifest this skill wrote in
   step 3; step 8 excludes it. Anything else there, or a `bd init:` commit
   at the top of the log, is bd having written to the repo.
   Any other check failing is reported verbatim and ends the run with the
   tracker left as is - never "fixed" by a further `bd` command. The
   person decides what to do with a tracker that wired a remote.

   Under `--tracked`, run the same form. Whether `.beads/` is ever
   committed is decided with `beads.sync` at graduation, not here.

5. **Write the three files beside the manifest.** Each is appended to
   if it exists and created if not; nothing is replaced:

   - **`.claude/settings.json`**: the `bd prime --hook-json` SessionStart
     hook, and a `permissions.deny` list with one `Edit(<path>)` per entry
     of `gate.moving_files`. An existing file gets the hook and the deny
     entries merged in; say which keys were added. `deny`, not `ask`, and
     `Edit` alone - the reasons are in
     `~/.claude/skills/wurk:kit/REFERENCE.md`, "Recommended consumer
     settings".
   - **`AGENTS.md`**: a stub that names the tracker and the prefix and
     defers the command reference to `bd prime`, in the shape of
     `$WURK/AGENTS.md`. An existing file gets the beads section appended.
   - **`CLAUDE.md`**: an authority table. Offer the conservative profile
     (agents create, claim, and note beads and run the gate freely;
     committing, pushing, opening a request, and closing a bead need the
     person to ask in their own words). The skills read this table and
     never widen it. An existing file gets the section appended.

6. **Seed each opt-in.** In order, only the ones chosen in step 2:

   - **`adr`**: create `artifacts.adr` (offer `docs/adr/`), write
     `0001-record-architecture-decisions.md` from the seed in
     `$WURK/docs/recipes/adrs.md` with the project's name and today's date
     filled in, then add `artifacts.adr` to the manifest. Never seed into
     a directory that already has records; if the survey found one, add
     the key pointing at it and write nothing. The seed comes before the
     key because the lint blocks a declared directory that is not there.
   - **`sabotage`**: add `gate.sabotage` with `test_roots` and a
     `test_pattern` for the toolchain's declaration shape (the worked
     example has it), and write `.claude/wurk/commit.md` from the refusal
     condition in `$WURK/docs/recipes/sabotage-testing.md`. Say in the
     report that the scan requires `#`-comment languages.
   - **`coverage`**: nothing to write. The floor is a flag in the gate
     command and the config it reads is already in `gate.moving_files`;
     report the recipe path and, if the gate candidate has no coverage
     stage, say so.
   - **`review`**: add `mr.review_agents` naming the shipped roster,
     `wurk-diff-critic` and `wurk-test-critic`, then re-run the lint. A
     name resolves to the repo's own `.claude/agents/<name>.md` first and
     the installed `~/.claude/agents/<name>.md` second, and the lint is
     the authority on whether it resolved: a `mr_review_agent_missing`
     block means neither root has the file (usually `install.rb` has not
     run on this machine); report that and remove the section rather than
     leaving a manifest the lint refuses.
   - **`tracker`**: write the three extension stubs (`next.md`, `mr.md`,
     `cleanup.md`) from the tracker section of
     `$WURK/docs/two-tracker-pattern.md` under `.claude/wurk/`, with the
     tracker's id pattern from the survey where one was found, and say in
     the report that the script they call is the person's to write. No
     tracker credentials, URLs, or API calls are configured here.
   - **`scan`**: install the outbound-scan pre-push hook from the repo
     root, per ADR-0014 in the wurk clone:

     ```bash
     ruby ~/.claude/skills/wurk:kit/scripts/outbound_scan.rb install
     ```

     Read its envelope: it refuses to install into a hooks directory
     shared across every repo on the machine, and a refusal is reported,
     never worked around. Hooks are untracked, so this fits the pilot.

   Re-run the lint after this step; most opt-ins touched the manifest.
   Anything the person at this machine decides rather than the project -
   the permission mode of seeded sessions, for one - goes in
   `~/.claude/wurk.local.json` (`$WURK/docs/machine-config.md`), which
   this skill never writes; name it in the report's next steps when the
   parallelism model is `worktree-per-issue`.

7. **Orientation, offered not imposed.** If the survey found a `src/`
   layout, more than one package, generated code, or a test-support
   convention, offer to write `.claude/wurk/codebase.md` (ADR-0011 in the
   wurk clone) from the survey: layout, test suites, terms of art. A
   single-package repo with one test directory does not need it; say so
   and skip.

8. **Pilot footprint.** Skipped under `--tracked`. Otherwise append to
   `.git/info/exclude`:

   ```
   .claude/wurk.json
   .claude/wurk/
   .claude/settings.json
   ```

   `.beads/` is already there from step 4. `AGENTS.md` and `CLAUDE.md`
   are project files a person would commit anyway; excluding them is
   their call, so ask rather than add. Anything written under
   `artifacts.adr` in step 6 is also a project file: it is the practice's
   first record, and it is left for the person to commit.

   Then confirm the footprint is what the pilot promises:

   ```bash
   git status --short
   ```

   Under the pilot shape this prints only the files the person chose to
   leave tracked (a new `AGENTS.md`, a seeded record). Anything else here
   is a file this skill wrote and forgot to exclude; fix the exclusion.

9. **Prove both gate commands run through the kit.** Two runs, because
   the kit runs `gate.full` and `gate.loop` on different paths and a
   wrong argv in either is the most common adoption fault:

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/gate.rb
   ruby ~/.claude/skills/wurk:kit/scripts/gate.rb --profile loop
   ```

   The first decides applicability from the files changed against the
   default branch, untracked ones included, so what it reports depends
   on whether anything this skill wrote (`AGENTS.md`, a seeded record)
   falls under `gate.build_paths`. `data.applicable: true` with
   `data.ran: "all"` proves `gate.full` ran; `data.applicable: false`
   with `data.ran: null` proves nothing yet - it means no changed file
   matched, which is the correct answer for a `build_paths` that names
   only source trees. In that case prove `gate.full` the way
   `docs/adoption.md`'s gate step does: make a throwaway change under a
   listed path, run again, and revert it, so the report can say the full
   argv ran rather than that it was never exercised. The second run
   always executes `gate.loop`; `data.ran: "loop"` proves that argv.

   For both, `data.tier: 0` and `data.attested: false` are the expected
   shape for a gate that is an exit code. A repo with no `origin` warns
   `stale_base_ref` or `no_base_ref` on the first run; expected, and
   named in the report. A `blocked` entry naming a command means that
   argv does not run from the repo root; fix the manifest and re-run. A
   red run is the project's own gate failing on its own tree: report it
   as the project's state, not as a setup fault, and never weaken the
   command to get green.

10. **Report.** Every file written, every manifest key whose value came
    from the person rather than the survey, every opt-in seeded or
    skipped and why, the gate result and its tier, and the three things
    that come next:

    ```
    Adopted wurk in <repo> (<pilot | tracked>)

    Manifest:   .claude/wurk.json - <n> keys, lint clean
    Tracker:    .beads/ (prefix <p>, local, no remote, stealth)
    Beside it:  .claude/settings.json <created | merged>, AGENTS.md <..>, CLAUDE.md <..>
    Opt-ins:    adr (seeded docs/adr/0001), review (2 agents), ...
                skipped: coverage - gate has no coverage stage yet
    Gate:       full green (ran: all), loop green, tier 0
    Footprint:  <n> entries in .git/info/exclude; git status shows <..>

    Next:
      1. Read docs/adoption.md's work-one-bead section in the wurk clone:
         bd create --title="..." && /wurk:work <id>
      2. <the first gap the survey found, e.g. "add a single gate wrapper">
      3. Graduate when a few beads have landed: docs/local-only-pilot.md,
         "Graduating"
    ```

## Guidelines

- **Survey before asking, ask before writing.** A value that could be
  read from the repo is read; a value that is a choice is asked; nothing
  is guessed and then reported as if it were read.
- **Zero footprint is the default and is checked, not assumed.** Steps 4
  and 8 each end with a `git status` that must match the promise.
- **The kit's lint is the authority on the manifest.** This skill does not
  restate the schema; it writes a draft and runs `manifest.rb check`
  until the draft is clean. When the lint and this prose disagree, the
  lint is right and this prose needs a fix in the wurk clone.
- **No consumer constants.** Toolchain-specific values (a test runner's
  argv, a declaration regex, a lockfile name) come from the worked example
  the survey selected, never from this file.
- **Never commit, never push, never close.** The adoption is the person's
  to commit when the pilot has earned it, and the kit's own contract
  already bans the rest.

<!-- SNAPSHOT FIXTURE - do not edit by hand, and do not treat as a live plan.

A frozen copy of a real, completed plan document (statifier-ex
docs/plans/260806-st-hzf-skill-mechanics-scripts.md, taken 2026-08-08),
kept because a hand-written synthetic plan cannot exercise the grammar at
full scale: 12 phases, wrapped manual items, a Deferred Manual
Verification section, and every mandatory heading in the order a real
author produced them. The other plan fixtures beside this one are small
and targeted; this one is the breadth case.

Bead ids were rewritten from the donor repos prefix to the fixture prefix
`zz` so nothing here can pass for the wrong reason. Nothing else was
changed. Re-snapshot only if the plan grammar itself changes. -->

# Skill Mechanics Extraction Implementation Plan

## Overview

Extract the deterministic mechanics out of the 13 `SKILL.md` files under
`.claude/skills/` into a shared, tested `.claude/scripts/` written in Ruby, and
rewrite each skill to invoke those scripts instead of narrating the steps -
with behavior unchanged. Record, durably and in the repo, which steps are
scriptable, which need a model but only a Haiku-sized one, and which need the
session model.

Beads issue: `zz-hzf`. Source research:
`docs/research/260806-zz-hzf-skill-mechanics-scripts.md`.

## Current State Analysis

### What exists

- 13 skills under `.claude/skills/`, 3,765 lines of prose, one `SKILL.md` each.
  **There is no script of any kind under `.claude/` today.** The only non-prose
  file is `.claude/settings.json`, which registers one `SessionStart` hook
  (`bd prime --hook-json`).
- Decomposed, the skills contain ~189 discrete steps: **115 scriptable (~61%)**,
  **21 Haiku-sized (~11%)**, **53 session-model (~28%)**. The six
  worktree/bead-lifecycle skills are ~85% scriptable; the four artifact skills
  invert that ratio.
- The recurring mechanics cluster into eight families (research, "Shared script
  families"), six of which serve three or more skills.

### Constraints discovered

- **Ruby 2.6.10 only.** `/usr/bin/ruby` (macOS system Ruby) is the only Ruby on
  this machine. `mise.toml` provisions Erlang, Elixir and a JRE, no Ruby.
  Adding a Ruby line would be an `area:build` change that batches with nothing
  and is out of scope here. Scripts therefore target **2.6 syntax, stdlib
  only**: no gems, no bundler, no `Data.define`, no endless methods, no hash
  value omission, no `filter_map`, no `Array#intersect?`, no rightward
  assignment. `minitest` ships with 2.6 and is available via
  `require "minitest/autorun"`.
- **`.claude/**` is not a gate-guarded path.** ADR-0011's guard watches
  `.quality.exs`, `.credo.exs`, `coveralls.json`, `.sobelow-conf`,
  gate-relevant `mix.exs` lines, added `@tag :skip`, and a shrunk
  `test/passing_tests.json`. None of this plan touches any of them, so **no
  `docs/quality-gate-changes.md` entry is required or permitted** by this work.
- **`mix quality` will not exercise the Ruby scripts** and this plan does not
  add a stage that would - that would edit `.quality.exs` and require a ledger
  entry, which is a human's call. The scripts get their own stdlib harness.
- **The authority asymmetry lives in the boundaries between steps.** CLAUDE.md
  authorizes `git commit` on a worktree branch under a trigger, and withholds
  `git push`, `gh pr create`, `bd close`, `bd dolt push` (for unlanded work) and
  the ADR-0011 ledger. Extraction must therefore be **step-scoped**: no script
  may span such a boundary, and no script may contain a code path that pushes,
  opens a PR, closes a bead, or writes the ledger.
- **The meta-hazard.** This work edits the very skills that drive it.
  `/implement-plan --loop` and `/commit --auto` are running while the plan
  executes; `/work` sits above them.
- **Sequencing risk.** `.claude/skills/**` is `area:skills` and `zz-hzf` holds
  it, so this branch collides with any other `area:skills` bead for its whole
  life. Keep the branch moving.

### Key discoveries

- Two duplications are **correctness** problems, not speed problems:
  - The `^Refs:` bead-id extraction is written twice with the same regex -
    `.claude/skills/merge-request/SKILL.md:49-51` (over
    `git log origin/main..HEAD --pretty=%B`) and
    `.claude/skills/cleanup-worktrees/SKILL.md:261-263` (over
    `gh pr view <n> --json commits --jq '.commits[].messageBody'`). If they
    drift, the PR body's `Closes` lines and the beads actually closed diverge.
    The anchor is load-bearing: fixture `146c69f` on `main` names `zz-00p.1`
    and `zz-gnr` in its body with no `Refs:` line at all.
  - The **capture-then-abort rebase block plus `mix.lock`-conditional build
    repair** is shared verbatim between
    `.claude/skills/refresh-worktree/SKILL.md:75-121` and
    `.claude/skills/merge-request/SKILL.md:63-115`, and `/merge-request`
    explicitly tells the model not to reimplement it (L86-87, L95-100). That
    cross-reference is a prose stand-in for a shared script.
- The `/cleanup-worktrees` idle classifier
  (`.claude/skills/cleanup-worktrees/SKILL.md:150-202`) reads like judgment but
  is a byte-level decision procedure with captured ANSI fixtures. It is prose
  only because there was nowhere else to put it, and it is the passage most
  likely to be executed inconsistently by a model reading 364 lines.
- `bd show <id> --json` returns a one-element array with
  `id, title, description, acceptance_criteria, notes, status, priority,
  issue_type, assignee, labels, dependent_count, dependency_count`. `notes` is
  a single string blob, not a list, so `/work`'s
  `loop: Phase N complete, commit <sha>` resume scan needs the wrapper to split
  it.
- **A skill's `model:` frontmatter beats an Agent-call override**
  (`docs/workflow.md:6-48`). Haiku can therefore only apply to prompts composed
  directly in an Agent call, never to a step dispatched through the Skill tool.
- `/create-issue` is the only skill with no `model:` frontmatter.
- Constraints that must not be optimized away: `mise trust` before the first
  mise-managed command (hang avoidance, `new-worktree/SKILL.md:70-76`); the
  quoted `'=statifier-ex'` tmux target (equals-expansion in fish/zsh); the
  non-empty `$win` check before any `-t` command (an empty target resolves to
  the *current* window - this cost a live window on 2026-08-02); never grepping
  for `claude` in `pane_current_command` (the binary is version-named).

## Desired End State

- `.claude/scripts/` exists, executable, Ruby 2.6/stdlib only, with a
  documented single JSON envelope and a stdlib test suite run by
  `ruby .claude/scripts/test/run.rb` (green, no gems installed).
- All 13 `SKILL.md` files invoke scripts for their mechanics and keep, verbatim
  or near-verbatim, the prose that carries judgment. Every behavior the current
  skills specify is still specified somewhere - in a script, in surviving
  prose, or in the record document.
- `docs/skill-automation.md` exists as the living record: the
  scriptable/Haiku/session classification, the skill-to-script map, the Haiku
  delegation points and why, and the rules any future script must obey.
- The `^Refs:` extraction and the rebase-with-repair block each exist exactly
  once.
- No `.quality.exs` change, no ledger entry, no `mise.toml` change, no new
  Elixir code.

### How to verify

1. `ruby .claude/scripts/test/run.rb` is green on `/usr/bin/ruby` with no gems.
2. `mix quality` is green (unchanged - this branch touches no Elixir).
3. `grep -rn 'st-\[a-z0-9\]' .claude/` returns exactly one definition site.
4. `grep -rln 'rebase --abort' .claude/` returns exactly one script.
5. No script under `.claude/scripts/` contains `git push`, `gh pr create`,
   `bd close`, or writes `docs/quality-gate-changes.md` (asserted by a test).
6. Reading each rewritten `SKILL.md` against its predecessor in `git diff`
   shows every refusal, policy, and "why" paragraph either retained or moved to
   a named location.

## What We're NOT Doing

- **Not adding a Ruby to `mise.toml`.** `area:build` batches with nothing, and
  the gate guard watches build config. System Ruby 2.6 is the target.
- **Not adding a `mix quality` stage for the scripts.** That edits
  `.quality.exs` and needs an ADR-0011 ledger entry, which is a human's call.
- **Not writing any `ship.rb`-style helper.** No script spans commit -> push ->
  PR, and no script has a code path that pushes, opens a PR, closes a bead,
  runs `bd dolt push` for unlanded work, or writes the ledger.
- **Not scripting the sabotage check.** A script can assert a `# sabotage:`
  line exists; it cannot assert the mutation was plausible or that the test
  failed for the right reason. Automating presence without keeping the
  paragraph in front of the model converts a verification discipline into a
  comment-formatting rule. The protocol stays prose in `/implement-plan` and
  `/commit`, and `gate.rb` reports missing notes as `warnings` only, never as a
  pass/fail the model can route on without reading them.
- **Not defining a Haiku agent under `.claude/agents/`.** The bead asks that
  delegation points be identified and recorded, not that a speculative agent be
  built. The record names the mechanism (per-call `model:` on an inline Agent
  prompt) and the constraint (frontmatter wins for Skill-tool dispatch).
- **Not changing any skill's behavior**, argument surface, mode semantics,
  refusal conditions, or model tiers. This is an extraction, not a redesign.
- **Not splitting into child beads.** One bead, phased; `/implement-plan --loop`
  commits per phase.
- **Not touching plugin or global skills** (`present:*`, `slack:*`, and the
  other non-project skills). Only the 13 under this repo's `.claude/skills/`.
- **Not inferring `area:` labels from diffs.** Areas are a prediction written
  before the work exists (`docs/workflow.md:147-191`); a script that "improves"
  them from changed files inverts the design.
- **Not adding a `--skip` or profile passthrough to `gate.rb`.** A convenience
  that weakens the gate defeats the rule it wraps.

## Implementation Approach

**Build bottom-up, rewrite top-down, and touch the in-use skills last.**

Phases 1-8 are purely additive: they create `.claude/scripts/` and its tests
without editing a single `SKILL.md`. Nothing in the workflow changes, so every
phase commits through the *existing* `/commit --auto` and `/implement-plan`.

Phases 9-12 rewrite the skills, ordered by distance from the running loop:

- Phase 9: the three lifecycle skills nothing in the loop invokes.
- Phase 10: the selection/intake skills, also uninvoked by the loop.
- Phase 11: `/merge-request` and the artifact skills - `/create-plan` and
  `/research-codebase` have already run for this bead, and `/iterate-plan` and
  `/merge-request` run only on an explicit human ask.
- Phase 12 (last): `/work`, `/implement-plan`, `/commit` - the three the
  executing loop is standing on.

The rewrite of Phase 12 is behavior-preserving by construction, but the loop
re-reads `/commit` on the very next invocation after that phase's edit lands,
so **Phase 12 is deliberately the smallest rewrite phase** and its manual
verification is a re-read of the diff rather than a live re-run.

**Every script is step-scoped and reports rather than decides.** Scripts emit
one envelope; the model reads `data` and acts on `blocked`. Mutating scripts
support `--dry-run`, which populates `commands` without executing - this is
both the audit path and how the tests exercise them without a real git, gh, or
tmux.

**Shelling out goes through one runner** that uses `Open3.capture3` with an
argv array, so no shell is involved and a developer's `-i` aliases cannot
apply. The explicit non-interactive flags (`cp -Rf`, `rm -rf`, `-o
BatchMode=yes`) are still passed, per CLAUDE.md, and `bd edit` is banned by a
test.

---

## Phase 1: Foundation - the record, the envelope, and the harness

### Overview

Land the durable record of the audit, the script contract, and the test harness
before any script exists, so every later phase has a fixed target.

### Changes Required:

#### 1. The living record

**File**: `docs/skill-automation.md` (new)
**Changes**: The repo-side, maintained record. The research doc is a dated
snapshot and stays as-is; this is what future work reads and updates. Sections:

- **Classification summary** - the 13-row table (skill, lines, `model:`
  frontmatter, counts for scriptable / Haiku-able / session-model), carried
  from the research doc.
- **Skill-to-script map** - one row per skill naming the scripts it calls
  (filled in as Phases 9-12 land; stubbed with the intended mapping in this
  phase).
- **What must never be scripted** - the sabotage protocol, "changes unrelated
  to the claimed issue", the ADR-0011 ledger entry, `bd close` outside a
  confirmed merge, phase sizing, changelog-fragment invention, and the
  `/next-issues` picker's override option. Each with a one-line reason and a
  file:line pointer.
- **Model routing** - placeholder heading, filled by Phase 12.

#### 2. The script contract

**File**: `.claude/scripts/README.md` (new)
**Changes**: The contract for anyone writing or calling a script.

- **Ruby 2.6.10, stdlib only, `#!/usr/bin/env ruby`.** The forbidden-syntax
  list. No gems, no bundler.
- **The envelope.** Every script prints exactly one JSON object on stdout:

  ```json
  {
    "ok": true,
    "script": "worktree_create",
    "data": {},
    "warnings": [{"code": "plt_missing", "message": "..."}],
    "blocked": [{"code": "branch_exists", "message": "...", "needs": "human"}],
    "commands": ["git worktree add ...", "..."]
  }
  ```

  `commands` is mandatory and non-negotiable: CLAUDE.md forbids truncating
  output, and a script that hides what it ran trades one opacity for another.
  Diagnostics go to stderr, never stdout.
- **Exit codes**: `0` when `ok` is true; `1` when `ok` is false (blocked, or a
  wrapped command failed) - the envelope is still printed; `2` for a usage
  error, with a plain-text message and no envelope.
- **`--dry-run`** on every mutating script: populate `commands`, execute
  nothing, `ok: true`.
- **Step-scoping rule**, verbatim from CLAUDE.md's authority table, plus the
  banned-operation list.
- **How to run the tests**: `ruby .claude/scripts/test/run.rb`, optionally
  `ruby .claude/scripts/test/run.rb -n /pattern/`. State plainly that
  `mix quality` does **not** run this suite and why (ADR-0011: adding a stage
  is a human's call), and that a phase touching `.claude/scripts/` must run
  both.

#### 3. The shared library floor

**File**: `.claude/scripts/lib/envelope.rb` (new)
**Changes**: `Envelope` - accumulates `data`, `warnings`, `blocked`,
`commands`; `#block!(code:, message:, needs:)`; `#emit` writes JSON and returns
the exit code. `ok` is `blocked.empty?` and no wrapped failure.

**File**: `.claude/scripts/lib/sh.rb` (new)
**Changes**: `Sh.run(argv, chdir: nil, timeout: 60)` -> `Result(out, err,
status)`. `Open3.capture3` with an argv array (no shell). Records the rendered
command line into the envelope's `commands`. A `Timeout` wrapper that kills the
child, so a hung `gh` or `tmux` poll cannot stall a session. `Sh.runner=` swaps
in a fake for tests.

**File**: `.claude/scripts/lib/cli.rb` (new)
**Changes**: Shared `OptionParser` setup - `--dry-run`, `--json` (default and
only output form, accepted for symmetry), `--help`. Usage errors exit 2.

#### 4. The test harness

**File**: `.claude/scripts/test/run.rb` (new)
**Changes**: Requires `minitest/autorun` and every `test/**/*_test.rb`. No
gems.

**File**: `.claude/scripts/test/support/fake_sh.rb` (new)
**Changes**: A recording/replaying `Sh` double: matches on argv prefix, returns
fixture stdout/stderr/status, and asserts on unexpected commands so a script
that shells out to something the test did not authorize fails loudly.

**File**: `.claude/scripts/test/envelope_test.rb`,
`.claude/scripts/test/sh_test.rb` (new)
**Changes**: Envelope shape, exit-code mapping, `commands` accumulation, the
Timeout path, and argv-not-shell (a fake command name containing a shell
metacharacter must be passed through literally).

**File**: `.claude/scripts/test/contract_test.rb` (new)
**Changes**: The guardrail test that survives every later phase. Over all
`.claude/scripts/**/*.rb`, assert: no `git push`, no `gh pr create`, no
`bd close`, no `bd edit`, no write to `docs/quality-gate-changes.md`, no
`.quality.exs` write, no `system(`/backticks (everything goes through `Sh`),
every top-level script has the `#!/usr/bin/env ruby` shebang and the executable
bit, and every `cp`/`rm`/`mv` argv carries its non-interactive flag.

### Success Criteria:

#### Automated Verification:
- [x] `ruby .claude/scripts/test/run.rb` is green
- [x] `/usr/bin/ruby -c` parses every file under `.claude/scripts/` (no 2.7+
      syntax): `find .claude/scripts -name '*.rb' -exec /usr/bin/ruby -c {} +`
- [x] Full quality gate passes: `mix quality`
- [x] `docs/skill-automation.md` and `.claude/scripts/README.md` exist

#### Manual Verification:
- [ ] The envelope example in `README.md` and the one in the research doc agree
- [ ] `docs/skill-automation.md`'s "what must never be scripted" list covers all
      12 risks in the research doc's Risks section
- [ ] No gem was installed to make the suite run

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Phase 2: Repo, worktree survey, and PR state (with the shared `^Refs:`)

### Overview

The most-shared family, and the home of the first correctness-driven
extraction.

### Changes Required:

#### 1. `^Refs:` - defined once

**File**: `.claude/scripts/lib/refs.rb` (new)
**Changes**: `Refs::BEAD_ID = /st-[a-z0-9]+(\.[0-9]+)?/` and
`Refs.beads_from_messages(texts)` - split each message into lines, keep only
lines matching `/^Refs:/`, scan for `BEAD_ID`, uniq, sort. This is the single
definition site for both `/merge-request` step 2 and `/cleanup-worktrees` step
4.5. Also `Refs.trailer_line(ids)` for message construction.

#### 2. Repo state

**File**: `.claude/scripts/repo_state.rb` (new)
**Changes**: Replaces `/work` step 0, `/merge-request` step 1, and half of
`/commit` step 1. Locate-self via
`git rev-parse --git-dir` vs `--git-common-dir`; branch; `<id>-<slug>`
decomposition; dirty check; upstream, ahead/behind; unpushed commits with their
`Refs:` ids; `touches_elixir` (the carve-out predicate: anything under `lib/`,
`test/`, `config/`, or `mix.exs`/`mix.lock`, stated identically in `/commit`
L97-98 and `/merge-request` L130-131); changed files; plan docs; changelog
fragments. Payload per the research doc's `repo_state.rb` example.

**The `branch_bead` field never ships alone.** ADR-0010 makes the branch name a
creation-time label, not an authority, so it is emitted as
`{"id":..., "strategy":"branch_prefix", "confidence":"weak"}`.

#### 3. Worktree survey

**File**: `.claude/scripts/worktree_survey.rb` (new)
**Changes**: Replaces `/next-issues` step 2, `/refresh-worktree` step 1, and
`/cleanup-worktrees` step 1 - three variations on one survey today.
`git worktree list --porcelain`, drop the main checkout (never a target, and
removing it would take the repository with it), `<id>-<slug>` decomposition,
dirty, `merge-base --is-ancestor origin/main HEAD`, area labels via
`bd show --json`, the PR-state join, `stale`, and **`holds_areas` distinct from
`areas`** - a stale worktree has areas but holds none, which is the fix for the
2026-08-05 phantom collision (`next-issues/SKILL.md:143-157`). `gh_available`
and `degraded` carry the "say so once, not once per worktree" rule.

#### 4. PR state

**File**: `.claude/scripts/pr_state.rb` (new)
**Changes**: The one place that knows merge detection is `gh`-based and git
ancestry is *wrong* under rebase-merge-only.
`gh pr list --state merged --head <branch> --json number,mergedAt,headRefOid
--jq '.[0]'`; `headRefOid` vs local `git rev-parse HEAD`; a `beads` subcommand
that pipes `gh pr view <n> --json commits --jq '.commits[].messageBody'`
through `Refs.beads_from_messages`. On `gh` failure or unauthenticated: emit
`blocked` with `needs: "human"` - never fall back to ancestry. The two
documented wrong alternatives (`@{upstream}`, `origin/main..HEAD`) get a
comment naming why, so nobody reintroduces them.

#### 5. Tests

**File**: `.claude/scripts/test/refs_test.rb`,
`repo_state_test.rb`, `worktree_survey_test.rb`, `pr_state_test.rb` (new)
**Changes**: `refs_test.rb` includes the `146c69f` fixture - a body naming
`zz-00p.1` and `zz-gnr` with no `Refs:` line - and asserts it yields `[]`.
Survey tests drive `FakeSh` with recorded `git worktree list --porcelain`,
`gh pr list`, and `bd show --json` payloads, covering: stale worktree holds no
areas; `gh` unavailable degrades once; main checkout dropped; dotted bead ids
(`zz-00p.3`) decompose correctly.

### Success Criteria:

#### Automated Verification:
- [x] `ruby .claude/scripts/test/run.rb` is green
- [x] `find .claude/scripts -name '*.rb' -exec /usr/bin/ruby -c {} +` is clean
- [x] Exactly one definition of the bead-id regex:
      `grep -rn 'st-\[a-z0-9\]' .claude/scripts/ | wc -l` is 1
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] `ruby .claude/scripts/repo_state.rb` run in this worktree and in the main
      checkout reports `checkout` correctly in both
- [ ] `ruby .claude/scripts/worktree_survey.rb` output matches what
      `git worktree list` plus `gh pr list` say by hand
- [ ] The `146c69f` fixture is the real commit body, not a paraphrase

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Phase 3: The `bd` wrapper

### Overview

`bd show` is parsed as prose in at least four skills; this is the single
biggest parsing win. Serves nine skills.

### Changes Required:

#### 1. The wrapper

**File**: `.claude/scripts/lib/beads.rb`, `.claude/scripts/bead.rb` (new)
**Changes**: Subcommands `show`, `ready`, `claim`, `note`, `link`, `label`,
`create`, `sync`, `resolve`.

- `show <id>` unwraps the one-element array `bd show --json` returns and
  **splits the `notes` blob into a list**, parsing the `--loop` note grammar
  (`loop: Phase N complete, commit <sha>` / `loop stopped at Phase N:
  <reason>`) into structured fields, since `/work`'s resume scan depends on it.
- `ready [filters]` passes through, plus the **`--label-any` workaround**
  (beads#5358 makes the flag silently return the unfiltered set): run
  `bd ready --json` per label and union by id. The workaround carries a comment
  naming the issue number so it is not quietly dropped on a future
  re-verification pass without checking whether #5358 closed.
- `ready --claim` exposes the atomic path; `claim <id>` is
  `bd update <id> --claim`.
- `sync pull` / `sync push` wrap `bd dolt pull`/`push` **best-effort, never
  gating** - a sync failure is a warning, never a block.
- `resolve` encodes `/commit`'s five-strategy bead ladder as data, with
  `strategy`, `confidence`, and `warning` on every candidate. **Strategy 2
  (the bead named in the session's own seeded prompt) is not visible to a
  script**, so it is an input: `--seeded-bead <id>`, and the script ranks it
  first when given. Closed beads surface as a `warning`, never silently
  (`/commit` L174-179).
- **No `close` subcommand exists.** A comment says why: `bd close` fires on
  merge into `origin/main` and `/cleanup-worktrees` is the only closer; a
  generic "finish the bead" helper is the most tempting and most wrong
  extraction available.
- `bd edit` is never invoked (blocks on `$EDITOR`); notes always use
  `--notes`/`bd note` append semantics.

#### 2. Tests

**File**: `.claude/scripts/test/bead_test.rb` (new)
**Changes**: Notes-blob splitting including multi-line reasons; the loop-note
grammar round-trip; `--label-any` union dedupe; `resolve` ranking with and
without `--seeded-bead`; closed-bead warning present; a test asserting no
`close` subcommand is reachable.

### Success Criteria:

#### Automated Verification:
- [x] `ruby .claude/scripts/test/run.rb` is green
- [x] `ruby .claude/scripts/bead.rb show zz-hzf` returns a valid envelope whose
      `data.notes` is an array
- [x] `grep -rn 'bd close\|bd edit' .claude/scripts/*.rb .claude/scripts/lib/`
      returns only comments
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] `bd show --json` on the installed `bd` still carries every field the
      wrapper reads; any missing field degrades to `null` with a warning rather
      than a crash
- [ ] `bead.rb resolve` on this worktree names `zz-hzf` with `strategy:
      "plan_doc"`, not `"branch_prefix"`

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Phase 4: Worktree lifecycle (and the shared rebase block)

### Overview

`/new-worktree` is the single best extraction target in the repo: 262 lines of
prose that a script reduces to one invocation and one JSON result. This phase
also lands the second correctness-driven extraction.

### Changes Required:

#### 1. Creation

**File**: `.claude/scripts/worktree_create.rb` (new)
**Changes**: Guard (`git branch --list`, worktree-dir existence,
`git fetch origin` with the offline fallback to local `main`); create
(`git worktree add ../statifier-ex-worktrees/<name> -b <name> --no-track
origin/main`); **`mise trust <path>`** - keep the comment explaining that
without it the first mise-managed command prompts and hangs a non-interactive
session; warm (`cp -Rfc deps _build <path>/` falling back to `cp -Rf`, plus PLT
presence detection over
`_build/dev/dialyxir_erlang-*_elixir-*_deps-dev.plt`); verify
(`mix deps.get`, `mix quality --profile loop`).

**Never force.** A pre-existing branch or directory is `blocked` with
`needs: "human"`, not resolved.

#### 2. The shared rebase block - defined once

**File**: `.claude/scripts/rebase_onto.rb` (new)
**Changes**: The block `/merge-request` currently defers to `/refresh-worktree`
for by prose cross-reference. Record `before=$(git rev-parse HEAD)`; `git
rebase origin/main`; **on conflict, capture `git diff --name-only
--diff-filter=U` first, then `git rebase --abort`** - the abort clears the
conflict state, so a report assembled afterwards has nothing left to name;
then `mix.lock`-conditional repair (`git diff --quiet $before HEAD -- mix.lock`
as the fast path, else `mix deps.get` and a *targeted* PLT copy - never a
wholesale re-clone of `deps/` and `_build/`, which forces a full recompile).

A conflict is always `blocked` with `needs: "human"` and the conflicting files
named. The script has no resolve path at all - CLAUDE.md is explicit that
resolving unasked is unauthorized.

#### 3. Refresh and cleanup

**File**: `.claude/scripts/worktree_refresh.rb` (new)
**Changes**: The sweep: enumerate via `worktree_survey.rb`, `git fetch origin`
once (**offline is a hard stop** - refreshing against a stale `origin/main`
rebases worktrees onto the commit they are already on and reports success for
nothing), then per worktree skip-if-current / **refuse-if-dirty** (never stash,
commit, or discard on the author's behalf) / `rebase_onto` /
`mix quality --profile loop`. Result vocabulary preserved exactly: `rebased
onto <sha>, lock unchanged, loop green` / `current, skipped` / `conflict in
<file>, aborted, unchanged` / `dirty, skipped` / `red`.

**File**: `.claude/scripts/worktree_cleanup.rb` (new)
**Changes**: Merged detection through `pr_state.rb` only; dirty refusal
(**never `--force` to `git worktree remove`** - its refusal is a feature);
`headRefOid` vs local `HEAD`; removal in order (`git worktree remove`,
`git worktree prune`, `git branch -D`); `git fetch --prune`. `gh` failure stops
the whole sweep.

**The bead closing itself is not in this script.** It emits
`data.beads_to_close` from `pr_state.rb beads`, and the SKILL.md performs the
close - `bd close` is agent-authorized only against a verified merge, and
keeping the call at the skill boundary is what keeps the trigger visible.
Similarly, tmux quiescing is Phase 5's script, invoked by the skill between
this script's check phase and its removal phase, preserving the ordering
rationale at `cleanup-worktrees/SKILL.md:109-113`.

#### 4. Tests

**File**: `.claude/scripts/test/worktree_create_test.rb`,
`rebase_onto_test.rb`, `worktree_refresh_test.rb`,
`worktree_cleanup_test.rb` (new)
**Changes**: All via `FakeSh` and `--dry-run`. Assert the capture-then-abort
**ordering** explicitly (the `diff --diff-filter=U` call precedes the
`rebase --abort` call in the recorded sequence) - that is the whole point of
the extraction. Assert the `mix.lock`-unchanged fast path issues no
`mix deps.get`. Assert `--force` never appears in any argv. Assert
`worktree_cleanup.rb` issues no `bd close`.

### Success Criteria:

#### Automated Verification:
- [x] `ruby .claude/scripts/test/run.rb` is green, including the ordering assertion
- [x] `grep -rln 'rebase --abort' .claude/scripts/` returns exactly
      `rebase_onto.rb`
- [x] `grep -rn 'force' .claude/scripts/worktree_cleanup.rb` returns only the
      comment forbidding it
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] `worktree_create.rb --dry-run <name>` emits the same command sequence the
      current `/new-worktree` prose specifies, in the same order
- [ ] `worktree_refresh.rb --dry-run` over the live worktrees classifies each
      the same way a manual read of `git worktree list` does
- [ ] The PLT glob still matches a real file in this repo's `_build/dev/`

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Phase 5: tmux

### Overview

Serves only two skills but carries the most fragile logic in the set, including
a byte-level classifier whose current home is a paragraph inside a 364-line
file.

### Changes Required:

#### 1. The tmux script

**File**: `.claude/scripts/tmux_window.rb` (new)
**Changes**: Subcommands `ensure-session`, `open`, `find`, `classify`,
`quiesce`, `close`.

- `ensure-session` keeps the **quoted `'=statifier-ex'` exact-match target**
  and the comment explaining that fish and zsh expand a leading `=` as a
  command path, so a bare `-t =statifier-ex:` dies before tmux sees it.
  Because `Sh` uses argv and no shell, the quoting hazard is structurally gone
  - the comment stays anyway, since anyone reading a rendered `commands` line
  will copy it into a shell.
- `open` guards the window name (`tmux list-windows -F '#{window_name}'`,
  exact match), creates with `-d -P -F '#{window_id}'`, and **refuses to issue
  any `-t` command when the captured id is empty** - an empty `-t ""` resolves
  to the *current* window, which cost a live window on 2026-08-02. In Ruby this
  is a guard clause plus a test, not a shell idiom.
- `open` takes the seed command as an argument and appends the `FINISH` clause
  from **one constant in this script**. This is the convergence point every
  caller relies on: editing the clause here reaches every seeded session
  without touching the calling skills. `--model opus` stays an explicit
  constant with the comment explaining that a skill's `model:` frontmatter
  governs the skill's turn, not the CLI session, which is why the flag exists
  and must not be "simplified" away.
- `find` matches on **name and path together** (`tmux list-panes -a -F
  '#{window_id} #{window_name} #{pane_current_path}'`, both fields equal).
  More than one match is `blocked` and ambiguous - two windows claiming one
  worktree is a state a human should look at.
- `classify` is the idle classifier as a **pure function** over captured pane
  text, so it is testable: spinner match on `/\([0-9]+s · /` or
  `esc to interrupt` - **never the verb**, which is randomized per frame; last
  `❯` line from `tmux capture-pane -e -p` (the `-e` is required so the dim
  `\e[2m ... \e[0m` suggested-prompt placeholder can be told apart from real
  typed text); nothing-or-only-SGR -> idle, wholly-dim-wrapped -> placeholder,
  idle, anything else -> busy. Sampling twice ~3s apart and requiring idle both
  times is the script's job. Never grep for `claude` in `pane_current_command`
  - the binary is version-named (`2.1.220`).
- `quiesce` is `send-keys C-u` then `send-keys '/exit' Enter`, poll
  `pane_current_command` for up to 15s. **Never `kill-pane`, never SIGKILL, and
  no code path that does.** A timeout is `blocked`, not escalation.
- `close` requires every pane to be a bare shell (`fish`, `zsh`, `bash`, `sh`).

#### 2. Tests

**File**: `.claude/scripts/test/tmux_window_test.rb` (new)
**Changes**: `classify` against the captured fixtures verbatim from
`cleanup-worktrees/SKILL.md:161-194`, stored as raw bytes in
`test/fixtures/pane/*.txt`: dim placeholder, half-typed draft, dialog
(` ❯ 1. Yes`), empty box (`❯ \e[39m`), spinner frame, and a spinner frame whose
verb is one not listed anywhere (proving the verb is not matched). Plus: empty
`$win` never produces a `-t` command; two matching windows block; `quiesce`
issues no kill of any kind.

### Success Criteria:

#### Automated Verification:
- [x] `ruby .claude/scripts/test/run.rb` is green, including every pane fixture
- [x] `grep -rn 'kill-pane\|kill -9\|SIGKILL' .claude/scripts/` returns only
      the comment forbidding them
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] `tmux_window.rb classify` against a live busy window in this tmux session
      reports busy, and against an idle one reports idle
- [ ] The fixtures are real captures, not hand-typed escape sequences
- [ ] `tmux_window.rb open --dry-run` renders a command line that could be
      pasted into fish unchanged

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Phase 6: Selection

### Overview

Selection is set arithmetic, and `/next-issues` says so: "a batch is a set
intersection rather than an opinion" (L15-18).

### Changes Required:

#### 1. The selector

**File**: `.claude/scripts/lib/areas.rb`, `.claude/scripts/select_batch.rb`
(new)
**Changes**: `areas.rb` holds the **closed vocabulary**
(`area:interpreter`, `area:parser`, `area:datamodel`, `area:corpus`,
`area:test-harness`, `area:skills`, `area:docs`, `area:build`), disjointness,
and `area:build`-lands-alone. It has **no inference from file paths** - areas
are a prediction written before the work exists, and deriving them from a diff
inverts the design (`docs/workflow.md:147-191`).

`select_batch.rb` computes the verdict table (epic / unlabeled / lands-alone /
collides-with-live-worktree / collides-in-batch / free) and the greedy
priority-ordered walk, over `bead.rb ready`, `bead.rb show`, and
`worktree_survey.rb`. It also carries the **filter-sanity check**: compare
filtered vs unfiltered counts and `block` on a mismatch rather than building a
table from a set that was never actually filtered. `n > 4` is a `blocked`
refusal with the reason, never a silent clamp. `--auto` sets `mode` and drops
the override option from `alternatives`.

**The `recommended` array is a recommendation, not an outcome.** The envelope
carries `mode` and, in manual mode, a `requires_user_choice: true` flag, so a
calling model cannot read `recommended` as the decision. The picker itself
stays in the skill.

`/next-issue` is this script with `n=1`.

#### 2. Tests

**File**: `.claude/scripts/test/select_batch_test.rb`,
`areas_test.rb` (new)
**Changes**: Fixture-driven. Cases: `area:build` takes the batch alone;
unlabeled skipped with the reason string; `upstream` beads collide with
nothing; a stale worktree's areas do not block (`holds_areas` empty); the
2026-08-05 phantom-collision scenario reproduced as a regression fixture;
dependency edges not batched across; `n > 4` blocks; ceiling-not-target
(`ceiling_hit` false when the pool ran out); manual mode sets
`requires_user_choice`, auto mode does not and has no override alternative.

### Success Criteria:

#### Automated Verification:
- [x] `ruby .claude/scripts/test/run.rb` is green, including the phantom-collision
      regression fixture
- [x] `ruby .claude/scripts/select_batch.rb --n 3 --auto` runs against the live
      repo and emits a valid envelope
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] The verdict a live run gives each ready bead matches what
      `.claude/skills/next-issues/SKILL.md:170-185`'s table gives by hand
- [ ] `zz-hzf`'s own `area:skills` hold is reported as a live collision for any
      other `area:skills` bead

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Phase 7: The quality-gate wrapper

### Overview

Serves four skills. The most constrained script in the set: it must make the
gate easier to read without making it easier to weaken.

### Changes Required:

#### 1. The wrapper

**File**: `.claude/scripts/gate.rb` (new)
**Changes**: Wraps `mix gate.verify` and `mix quality --format json --report -`.

- **`skipped_stages` stays in the payload.** CLAUDE.md's "read the `○` lines"
  rule says a skipped stage is not a passing one; a summary that drops them
  launders exactly the information the rule protects. `ok` is false whenever a
  stage is skipped for a reason other than the carve-out.
- **No `--skip`, no `--profile`, no `--quick` passthrough.** The only profile
  argument accepted is `--profile loop`, and when given, the envelope sets
  `"ran": "loop"` and `"attested": false` so the caller cannot mistake it for a
  full green.
- **Carve-out predicate** shared with `repo_state.rb` (`touches_elixir`), so
  `/commit` and `/merge-request` cannot drift. When it applies, `applicable` is
  false and `carve_out_reason` is populated - the skills must report it so a
  skipped gate is never mistaken for a green one.
- **Sabotage scan reports, it does not gate.** `data.sabotage.missing` lists
  new `test "..."` lines (from
  `git diff main...HEAD -U0 -- test/ ':!test/scion_tests' ':!test/scxml_tests'`)
  with no `# sabotage:` line directly above - real mutation
  (`# sabotage: <what> -> red`) or stated exemption (`# sabotage: n/a - <why>`).
  It is emitted under `warnings`, and the script's `--help` and the README both
  state that a present note is not evidence the mutation was run. `/commit`'s
  paragraph stays prose.
- **Gate guard is reported, never repaired.** `data.gate_guard` names the
  guarded paths and whether a ledger entry exists. There is no write path to
  `docs/quality-gate-changes.md`, asserted by `contract_test.rb`.

#### 2. Tests

**File**: `.claude/scripts/test/gate_test.rb` (new)
**Changes**: Over recorded `mix quality --format json` payloads: a skipped
stage forces `ok: false`; `--profile loop` sets `attested: false`; the carve-out
predicate matches `/commit` L97-98 exactly on a table of paths; the sabotage
scan finds a missing note, accepts both note forms, and ignores
`test/scion_tests/` and `test/scxml_tests/`; a red gate guard is reported with
no write attempted.

### Success Criteria:

#### Automated Verification:
- [x] `ruby .claude/scripts/test/run.rb` is green
- [x] `ruby .claude/scripts/gate.rb --profile loop` on this worktree emits
      `"attested": false`
- [x] `grep -rn 'quality-gate-changes' .claude/scripts/` returns only comments
      and a read-only existence check
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] `gate.rb` on a full run agrees stage-for-stage with a bare `mix quality`,
      including every `○` line
- [ ] No argument combination reaches `mix quality --skip`

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Phase 8: Document mechanics

### Overview

The scriptable shell around the four artifact skills: metadata, filenames,
frontmatter, the plan grammar, and permalinks.

### Changes Required:

#### 1. Metadata and filenames

**File**: `.claude/scripts/doc_meta.rb` (new)
**Changes**: The metadata triple (`date +%Y-%m-%dT%H:%M:%S%z`,
`git rev-parse HEAD`, `git branch --show-current`); the filename builder
`YYMMDD-[issue-id-]kebab-description.md` for both `docs/plans/` and
`docs/research/` (one rule, two directories - the `st2-` -> `st-` rename in
commit `36c4b9d` rippled through every one of these filenames, which is the
argument for one builder); research-doc frontmatter emission with the full
field list; and the follow-up mutation (bump `last_updated`, add
`last_updated_note`, append a timestamped `## Follow-up Research` heading).

It **emits** frontmatter and filenames; it does not write the document body.
A scaffolding script that emitted section headings would invite filling them,
and nothing in a skeleton stops a model writing recommendations into
`/research-codebase`'s output.

#### 2. The plan grammar

**File**: `.claude/scripts/plan_state.rb` (new)
**Changes**: Parses `## Phase N:` sectioning, `#### Automated Verification:`
vs `#### Manual Verification:`, `- [ ]` vs `- [x]`, and the
`## Deferred Manual Verification` section. Payload per the research doc's
example, plus `sections_missing` against `/create-plan`'s mandatory nine.
Mutating subcommands `check <phase>`, `uncheck <phase>`, `defer <phase>`,
`validate`.

- `check` and `uncheck` operate on **Automated boxes only** and refuse a
  Manual box - `/implement-plan` L61-62 is explicit that Manual boxes are never
  checked by the loop.
- `defer` appends this phase's Manual items **verbatim** to the running
  `## Deferred Manual Verification` section, creating it on first use.
- There is **no `split` or `size` subcommand.** A phase is "the smallest unit
  that is independently gate-verifiable and independently committable"
  (`create-plan` L228-239); a phase-splitting script produces syntactically
  valid phases that break `--loop`.

#### 3. Permalinks

**File**: `.claude/scripts/permalinks.rb` (new)
**Changes**: `gh repo view --json owner,name`, then rewrite `file:line`
references to
`https://github.com/{owner}/{repo}/blob/{commit}/{file}#L{line}` over an
already-written document. Pure text transform, `--dry-run` shows the
substitutions.

#### 4. Tests

**File**: `.claude/scripts/test/doc_meta_test.rb`,
`plan_state_test.rb`, `permalinks_test.rb` (new)
**Changes**: Filename builder with and without an issue id, and with a dotted
id (`zz-00p.3`); frontmatter round-trip; follow-up mutation is additive.
`plan_state.rb` parses **this plan document** as a fixture (a real,
freshly-authored one), plus a fixture with a `## Deferred Manual Verification`
section already present, a phase with zero Manual items, and a plan missing a
mandatory section. `check` on a Manual box is refused. Permalink rewriting
leaves non-`file:line` text alone and is idempotent.

### Success Criteria:

#### Automated Verification:
- [x] `ruby .claude/scripts/test/run.rb` is green
- [x] `ruby .claude/scripts/plan_state.rb docs/plans/260806-zz-hzf-skill-mechanics-scripts.md`
      reports `sections_missing: []` and every phase in this document
- [x] `ruby .claude/scripts/doc_meta.rb filename --dir docs/plans --issue zz-hzf
      --description skill-mechanics-scripts` reproduces this file's name
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] `plan_state.rb` parses the three most recent plans in `docs/plans/`
      without `sections_missing` false positives
- [ ] `permalinks.rb --dry-run` over an existing research doc proposes only
      correct rewrites

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Phase 9: Rewrite the worktree lifecycle skills

### Overview

The first skill-editing phase, and deliberately the three skills that nothing
in the executing loop invokes: `/new-worktree`, `/refresh-worktree`,
`/cleanup-worktrees`. `/cleanup-worktrees` is 364 lines and the largest single
reduction available.

### Changes Required:

Each rewrite follows the same shape: frontmatter unchanged (name, description,
`model:`, `argument-hint` all preserved byte-for-byte), then **When to invoke**,
**What to run**, **How to read the result**, and a **Judgment** section holding
the prose that must survive.

#### 1. `/new-worktree`

**File**: `.claude/skills/new-worktree/SKILL.md`
**Changes**: Steps 1-4 become `worktree_create.rb`; step 5 becomes
`tmux_window.rb open`.

**Prose that must survive** (all judgment, none mechanics):
- L28-29 "If given only a bead id, ask for the slug - it matters and should not
  be guessed."
- L31-32 the ADR-0010 never-rename rule.
- L40-45 why the seed names the *orchestrator*, not a stage, and the
  hand-made-worktree fallback.
- L50-52 "Never force" on the branch guard.
- L103-111 why the window exists at all, and **"This step is optional and never
  fatal"** - a failed window must not fail worktree creation.
- L172-183 why `FINISH` is appended at this convergence point, and that it
  grants no authority beyond CLAUDE.md's table - it only routes commit
  authority through the skill that performs the Refs-trailer and
  unrelated-changes checks.
- L213-215 pass the bead id, never a paraphrase.
- L217-222 `auto` is not `bypassPermissions`.
- L249-262 a seeded session cannot spawn a nested `claude`; use a sibling
  worktree session.

**Prose that moves into a script comment** (and is deleted from the skill):
the `=` quoting explanation, the empty-`$win` trap mechanics, the `mise trust`
hang explanation, the PLT glob. Each keeps a one-line pointer in the skill so a
reader knows the hazard exists and where the reasoning lives.

#### 2. `/refresh-worktree`

**File**: `.claude/skills/refresh-worktree/SKILL.md`
**Changes**: Steps 1-4 become `worktree_refresh.rb`.

**Prose that must survive**: L16-19 the staleness failure mode (the skill's
reason for existing); L28-30 the main checkout is never a target; L47-49 why
offline is a hard stop; L67-70 **never stash, commit, or discard on the
author's behalf**; L85-92 a rebase conflict means the `area:` labels were wrong
or the batch was picked badly - signal for a human, not something to paper over
mid-sweep; L127-130 a red gate is a real result, not a failure of the refresh;
L141-142 silence about a skipped worktree reads as success; L145-152 rebase
never merge, and **nothing here is pushed** - that is `/merge-request`'s
decision to make; L153-157 when to run.

#### 3. `/cleanup-worktrees`

**File**: `.claude/skills/cleanup-worktrees/SKILL.md`
**Changes**: Steps 1-3 become `worktree_survey.rb` + `pr_state.rb`; step 3.5
becomes `tmux_window.rb find|classify|quiesce`; step 4 becomes
`worktree_cleanup.rb` + `tmux_window.rb close`; step 4.5 stays in the skill as
an explicit `bd close` call driven by `pr_state.rb beads`; steps 5-6 stay as
two named commands.

**Prose that must survive**: L15-38 the entire "why detection must not use git
ancestry" section, including "**a cleanup built on it silently no-ops forever
while looking like it works - the worst kind of broken**" and the safety
argument that makes the PR-state check load-bearing for `-D`; L63-70 an open PR
is work in review and a closed-unmerged one is someone's abandoned work, theirs
to decide about; L76-79 never `--force`, the refusal is a feature; L91-101 the
two documented wrong alternatives with their observed evidence (PRs #8 and #9);
L109-113 why quiesce comes *after* the dirty and SHA checks; L121-131 why
name+path both, and why ambiguity goes to a human; L201-206 busy means skip,
same stance as dirty; L221-224 **never kill a session, only ask it to exit**;
L250-256 why a bead closes at merge and nowhere else; L270-280 the `^Refs:`
anchor rationale and the `146c69f` fixture, and that a merged PR with no
trailer **closes nothing and must be reported**; L291-293 close before removing,
but a `bd` failure never blocks cleanup; L328-335 a busy session is a skip worth
naming, and **nothing to clean is a success that must say so explicitly** - a
silent sweep is indistinguishable from the ancestry bug.

**Prose that moves into `tmux_window.rb`**: the idle classifier's byte-level
procedure and its ANSI fixtures (L150-202), the awk window matcher, the
version-named-binary warning. The skill keeps one sentence: that idleness is
determined by a specified classifier, that it samples twice, and that busy
means skip.

### Success Criteria:

#### Automated Verification:
- [x] Every script the three skills name exists and is executable
- [x] `ruby .claude/scripts/test/run.rb` is green
- [x] No stale command text: `grep -n 'tmux capture-pane\|rebase --abort\|git worktree add'
      .claude/skills/{new-worktree,refresh-worktree,cleanup-worktrees}/SKILL.md`
      returns nothing outside an illustrative block
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] Read `git diff` for each skill against the surviving-prose list above -
      every listed paragraph is present
- [ ] `/cleanup-worktrees` still specifies, somewhere reachable, every one of
      the eleven behaviors its Guidelines section lists
- [ ] Running `/refresh-worktree` live produces the same report vocabulary as
      before

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Phase 10: Rewrite the selection and intake skills

### Overview

`/next-issue`, `/next-issues`, `/create-issue`. Also not invoked by the
executing loop.

### Changes Required:

#### 1. `/next-issues`

**File**: `.claude/skills/next-issues/SKILL.md`
**Changes**: Steps 0-3 and 5-6.5 become `bead.rb sync`, `select_batch.rb`, and
`bead.rb claim`; step 7 becomes a loop over `/new-worktree`. **Step 4, the
picker, does not become a script** and is the reason the skill still exists.

**Prose that must survive**: L20-26 **"this skill presents choices, it does not
decide for you"** and the override asymmetry - a user who understands a
collision's risk can take it deliberately; an unattended agent never can;
L34-37 the `n > 4` refusal *with its reason* (beyond four the merge queue is
the constraint); L44-50 an unknown id is reported not dropped, and mixing ids
with filters is refused as ambiguous; L60-71 the `--label-any` upstream note,
including **do not quietly drop it on a re-verification pass without checking
whether beads#5358 closed**; L73-78 `n` is a ceiling, not a target, and a
silently short batch reads as "there was no more work"; L114-121 do not trust a
label filter you cannot verify; L143-157 the 2026-08-05 failure-mode rationale;
L159-165 a degraded survey must read as "possibly stale" not as fact; L189-197
an unlabeled bead is one nobody has decided the blast radius of, and do not
batch across a dependency edge; L205-220 the full picker including the exact
AskUserQuestion option structure and the rule that the table comes first;
L223 nothing is claimed until the user picks; L226-232 auto mode has no
override; L246-253 claim before worktree, with the reasoning; L255-262 an
override must be recorded via `bd update --notes` (append semantics, never
`bd edit`); L281-284 a failed worktree is not a reason to abandon the rest;
L317-323 areas are about file collision and are a prediction; L328-330 `n > 4`
is refused, not clamped.

#### 2. `/next-issue`

**File**: `.claude/skills/next-issue/SKILL.md`
**Changes**: Becomes `select_batch.rb --n 1` plus `bead.rb claim` plus
`/new-worktree`. The skill shrinks the most of the three.

**Prose that must survive**: L21-25 never auto-select in manual mode, even with
one ready item; L56-62 **run cleanup every invocation** - "already ran this
session" is not "ran immediately before this pickup"; L85-87 empty means stop,
do not auto-file; L102-103 the name is fixed at creation (ADR-0010); L105-110
why the bead is read before the worktree is stood up, and that this read is
**not** sizing; L119-124 **the seed is uniform by design, precisely because
sizing is not this skill's job**; L126-128 hand off, do not do the work here;
L136-141 claim before worktree, and a sync failure never aborts pickup;
L148-152 this skill picks and claims; it neither sizes nor implements.

#### 3. `/create-issue`

**File**: `.claude/skills/create-issue/SKILL.md`
**Changes**: `bd create` / `bd q` / `bd link` / `bd update --add-label` become
`bead.rb create|link|label`. Shortest skill, smallest change.

**Prose that must survive**: L9-11 beads is the only tracker (ADR-0007);
L25-26 **infer type and priority when obvious; do not interrogate the user
field by field**; L59-67 the labeling policy - **label by the paths in the
acceptance criteria, not by subject matter**, and `area:build` batches with
nothing; L70-72 `upstream` beads carry no area; L87 do not commit, push, or
sync the beads database unless explicitly asked.

Frontmatter stays as-is - `/create-issue` remains the only skill with no
`model:` line. Changing that is a separate decision (see Open Questions).

### Success Criteria:

#### Automated Verification:
- [x] `ruby .claude/scripts/test/run.rb` is green
- [x] `ruby .claude/scripts/select_batch.rb --n 1 --auto` emits a valid envelope
- [x] Frontmatter blocks unchanged:
      `git diff -U0 .claude/skills/*/SKILL.md | grep '^[-+]model:'` returns
      nothing
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] `/next-issues`'s picker section reads identically to before - the
      AskUserQuestion option structure and the override wording are unchanged
- [ ] A dry read of `/next-issue` still ends in the same
      `/new-worktree <id>-<slug> -- /work <id> --auto` invocation
- [ ] The `--label-any` workaround note survived the rewrite

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Phase 11: Rewrite `/merge-request` and the artifact skills

### Overview

`/merge-request`, `/research-codebase`, `/create-plan`, `/iterate-plan`. None
runs inside the executing loop, but `/merge-request` will run immediately after
this bead finishes, so it is verified by reading rather than by trial.

### Changes Required:

#### 1. `/merge-request`

**File**: `.claude/skills/merge-request/SKILL.md`
**Changes**: Step 1 becomes `repo_state.rb`; step 2 becomes `pr_state.rb`'s
shared `^Refs:` resolution (the prose cross-reference to `/cleanup-worktrees`
becomes a shared call); step 3 becomes `rebase_onto.rb` (the prose
cross-reference to `/refresh-worktree` step 3d/3e becomes a shared call); step
4 becomes `gate.rb`. **Steps 6-9 stay hand-written commands in the skill** -
the human confirmation, `git push -u` / `--force-with-lease`, `gh pr create`,
`bd dolt push`, `bd note`. No script touches them.

**Prose that must survive**: L12-17 why the human gate lives here, verbatim;
L19-20 the bead is **not** closed here - a PR is a request, not an outcome;
L34-37 stop on `main`, stop on dirty, do not stage it here; L59-61 stop if no
bead resolves; L63-67 the gate must attest to the tree that will actually
merge; L83-93 abort and report, do not resolve unasked, and an aborted rebase
ends this run; L107-115 the one-code-path argument for the no-op case;
L122-124 refuse on red, do not push hoping CI disagrees; L131-133 report the
carve-out so a skipped gate is never mistaken for a green one; L140-142 an ADR
finding is refused exactly as a red gate; L156-160 **do not invent a changelog
entry** - it is a promise to users; L179-180 **the one confirmation this skill
does not skip, and there is no `--auto` for it**; L191-192 never a bare
`--force`; L214-215 no AI attribution; L225-229 `bd dolt push` is not optional;
L231 leave the bead `in_progress`; L244-256 rebase-only, never close here,
confirmation is not a formality; L257-266 one bead per branch is a default not
a law, and one bead per *commit* keeps trailers unambiguous.

#### 2. `/research-codebase`

**File**: `.claude/skills/research-codebase/SKILL.md`
**Changes**: The metadata triple, the filename rule, the frontmatter block, the
permalink rewrite and the follow-up mutation become `doc_meta.rb` and
`permalinks.rb`. Everything else stays.

**Prose that must survive**: L12-20 the entire documentarian charter, verbatim
- do not suggest improvements, do not root-cause, do not critique, do not
recommend refactoring, **only describe what exists**; L131 and L285-288 the
same rule restated for sub-agents; L136 accepted ADRs are settled; L152-158
agents already know how to search, and live findings outrank docs; L177-182 the
human gate on writing the document; L274 always run fresh research; L289-293
never write placeholder values.

The script emits frontmatter and a filename **only** - no section skeleton.

#### 3. `/create-plan`

**File**: `.claude/skills/create-plan/SKILL.md`
**Changes**: The filename rule and the mandatory-section list become
`doc_meta.rb filename` and `plan_state.rb validate`. The skill currently states
its template three times (as a list, as a fenced example, and as a Pre-Write
Checklist); collapse to **one** authoritative fenced template plus a
`plan_state.rb validate` call replacing the checklist.

**Prose that must survive**: L10-12 skeptical, thorough, collaborative, and the
Opus tier; L32 never write the plan outside `docs/plans/`; L91 accepted ADRs
are settled and the plan must fit them; L93-95 read files fully yourself before
spawning sub-tasks; L128-129 Appendix D deviations are semantic bugs (ADR-0002);
L155-159 do not simply accept a correction - verify it; **L228-239 the phase
sizing rule in full** - a phase is the smallest independently gate-verifiable
and independently committable unit, and phases that would leave an intermediate
gate red are combined, not split; L247-254 the human gate on writing;
L376-386 do not write the plan in one shot; L408-413 no open questions in a
final plan; L494-498 verify sub-task results.

#### 4. `/iterate-plan`

**File**: `.claude/skills/iterate-plan/SKILL.md`
**Changes**: The structural consistency checks become `plan_state.rb validate`.
The skill is the least mechanical of the four and shrinks least.

**Prose that must survive**: L70 only spawn research if new understanding is
needed; L118 get user confirmation before proceeding; L169-175 be skeptical,
and **flag changes that contradict an accepted ADR rather than silently editing
the plan** - a script applying Edits has no ADR awareness, so this must stay a
session-model gate; L177-181 be surgical, preserve good content; L189-193
confirm before changing; L200-204 no open questions; L132-136 link to
`/create-plan`'s wording by name rather than restating it.

### Success Criteria:

#### Automated Verification:
- [x] `ruby .claude/scripts/test/run.rb` is green
- [x] The `^Refs:` pipeline appears in no SKILL.md:
      `grep -rn "grep -oE 'st-" .claude/skills/` returns nothing
- [x] `rebase --abort` appears in no SKILL.md:
      `grep -rln 'rebase --abort' .claude/skills/` returns nothing
- [x] `plan_state.rb validate` on the three newest plans reports no missing
      sections
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] `/merge-request`'s step 6 confirmation is still an unconditional human
      gate with no automated path around it
- [ ] `/create-plan`'s single template is byte-identical to the one that
      produced this document
- [ ] `/research-codebase`'s documentarian charter is unmodified

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Phase 12: Rewrite the in-use skills, and record the Haiku routing

### Overview

**Last, and deliberately smallest.** `/work`, `/implement-plan` and `/commit`
are the three skills the loop executing this plan is standing on: the loop
re-reads `/commit` on the very next invocation after this phase's edit lands,
and `/implement-plan` governs the loop itself. Every change here is
behavior-preserving by construction, verified by reading the diff rather than
by a live re-run.

### Changes Required:

#### 1. `/commit`

**File**: `.claude/skills/commit/SKILL.md`
**Changes**: Step 0's gate call becomes `gate.rb`; step 1's analysis becomes
`repo_state.rb`; step 1.5's five-strategy ladder becomes
`bead.rb resolve --seeded-bead <id>`; step 2's three hard message limits become
a `commit_message.rb check` validator (subject <50, body lines ≤72, total ≤40,
`Refs:` present and last, no `Co-Authored-By` / `Generated with` / `Claude`).
Step 4's staging and heredoc commit stay written out - `git commit` is the one
authorized mutation and it stays visible in the skill.

**File**: `.claude/scripts/commit_message.rb` (new)
**Changes**: Pure validation, no drafting. Takes a message on stdin, returns
per-rule pass/fail. The attribution check is the same regex as step 4.4 and
runs both pre- and post-commit. No `--fix`.

**Prose that must survive**: L22-25 what `--auto` commits to, and that it is
**not** authorization to push, open a PR, or close a bead; L27-42 all eight
refusal conditions, and in particular **L37 "the working tree carries changes
unrelated to the claimed issue"**, which has no mechanical test at all and must
remain an explicit session-model gate; L44-45 a refusal is a report, not a
fallback to interactive; L67-76 the whole CRITICAL OVERRIDE block including the
*why*; L101-104 the carve-out is not a judgment call, and say so in the report;
**L119-124 the sabotage paragraph in full** - a missing note means the test was
never run against broken code, stop and sabotage it now, and in auto mode
refuse rather than invent a note for a sabotage that was never run; L148-153
why the seeded-prompt bead outranks the branch; L174-179 validate the bead's
*status*, not just its existence; L186-189 an unattended commit with no `Refs:`
line is untraceable work; L202-210 the changelog test - could someone who only
calls the public API tell the difference; L223-225 never edit `CHANGELOG.md`
directly; L266-269 a prompt nobody answers is noise; L303-306 the attribution
verification is not optional in auto mode; **L362-365 the authority boundary,
verbatim**; L398-402 repeated attribution leaks mean the override is losing to
something; L411-424 a red gate guard is not a failure to fix, and in auto mode
do not repair failures unasked.

#### 2. `/implement-plan`

**File**: `.claude/skills/implement-plan/SKILL.md`
**Changes**: The loop's plan-file mechanics become `plan_state.rb` -
resume scan, phase-text extraction, checkbox toggling, verbatim Manual-item
deferral, and the uncheck-on-refusal path. Preconditions become
`repo_state.rb`. `bd note` calls become `bead.rb note` with the loop-note
grammar shared with `/work`.

**Prose that must survive**: L44-46 a dirty tree stops the loop; L75-79 the
phase subagent implements the phase itself and **must not** re-dispatch a level
down; L91-94 **the orchestrator, not the subagent, runs `/commit --auto`**, and
that independence is the point; L95-104 the refusal path - stop immediately, no
retry, uncheck this phase's Automated boxes, and **leave every other file
exactly as the subagent left it, because the refusal is diagnostic
information**; L148 the plan is a guide but judgment matters; L153-158 ADR-0002
and ADR-0003 constraints; L164-165 stop and think when the plan cannot be
followed; **L180-202 the entire sabotage protocol** - a test that passed on its
first run has only been observed, a test that stays green under sabotage is
broken, never weaken the mutation, deleting a body is not a mutation, and it is
slow on purpose; L211-231 the interactive manual-verification pause; L244 use
sub-tasks sparingly; L253-258 leave commit/push/merge decisions to the user and
the bead stays `in_progress`.

**One inconsistency to fix while here**: L248-250 still says "close the issue
(`bd close <id>`) per the active agent profile in CLAUDE.md", which contradicts
L256-257 and CLAUDE.md's table (`bd close` fires only on a verified merge to
`origin/main`). Align L248-250 to the table. This is the one behavior change in
the plan, and it is a correction of an internal contradiction, not a redesign.

#### 3. `/work`

**File**: `.claude/skills/work/SKILL.md`
**Changes**: Step 0's locate-self becomes `repo_state.rb`; step 1's bd calls
become `bead.rb`; step 2's skip-satisfied resume scan becomes a
`work_state.rb` call composing `bead.rb show` (loop notes),
`docs/research/` and `docs/plans/` lookups by bead id, and `plan_state.rb`.

**File**: `.claude/scripts/work_state.rb` (new)
**Changes**: The resumability seam only - which stages are already satisfied.
It reports; it does not choose a bucket.

**Prose that must survive**: L14-19 this skill orchestrates and never
implements, and why `model: opus`; L55-61 the main-checkout branch stops at
depth one; L72 the claim is the lock and an epic is not workable; L84-86 the
area label is owed at creation, not backfilled; L94-96 the push is best-effort
and never gates the claim; L99-101 buckets are entry points into one sequence;
L112-118 the direction-through-worktree rationale; **L120-127 sizing happens
here, with the codebase in reach, and when uncertain pick the heavier bucket**;
L138-141 the resumability seam's purpose; L143-144 report the bucket and a
one-line rationale before spawning; L156-165 the model column mirrors each
skill's frontmatter and does not override it; L173-177 **"no human is
available"** must be told to every subagent, with open questions recorded in
the artifact; L180-183 never a nested `claude` CLI; L227-232 `/work` must not
re-implement `/implement-plan`'s halves; L239-241 a stopped loop is reported
verbatim and not retried or cleaned up; L243-247 the just-do-it gate runs
independent of the subagent's self-report; L265-268 no `Edit`/`Write` to `lib/`,
`test/` or `docs/` content; L280-282 the bead stays `in_progress`.

#### 4. The Haiku record

**File**: `docs/skill-automation.md`
**Changes**: Fill the `## Model routing` section:

- **The mechanism and its limit.** A skill's `model:` frontmatter beats an
  Agent-call override for the turn that skill is active (`docs/workflow.md:6-48`,
  `work/SKILL.md:156-165`). Haiku therefore applies **only** to prompts composed
  directly in an Agent call, never to a step dispatched through the Skill tool.
  This is why `/work`'s Direction stage composes its prompt inline.
- **The 21 delegation points**, grouped into the five kinds, each with the
  skill, the step, the input, the output, and why it is bounded:
  1. **Branch slug generation** - `/next-issue` step 2, `/next-issues` step 5,
     `/work` step 0, `/new-worktree` input handling. One title in, one
     2-4-word kebab slug out. The cheapest and most frequently executed
     judgment in the set.
  2. **Commit and PR body drafting** - `/commit` step 2, `/merge-request` step
     7b. Prose only; the validation stays in `commit_message.rb` and must stay
     scriptable.
  3. **Diff and change summarization** - `/commit` step 1's
     added/fixed/refactored classification; the one-line "why now" per
     candidate in `/next-issue`.
  4. **Bounded classification** - `/create-issue`'s type and priority
     inference; `/iterate-plan`'s "does this need new research" binary;
     `/implement-plan`'s refusal-reason classification; `/create-plan`'s
     unresolved-open-questions scan.
  5. **Kebab description for artifact filenames** - the `description` slug in
     `docs/{plans,research}/YYMMDD-<id>-<description>.md`.
- **What is explicitly not routed to Haiku and why**: phase sizing, the
  `/next-issues` picker, "changes unrelated to the claimed issue", the sabotage
  judgment, ADR-contradiction detection, and `/work`'s bucket choice. Each
  needs either the codebase in reach or an authority a subagent does not hold.
- **Why no Haiku agent is being added.** The bead asks for identification and
  recording. A `.claude/agents/` definition is a separate change with its own
  verification, and adding one speculatively would put an unused agent in the
  roster.

Each affected SKILL.md gets a two-line `## Model routing` pointer naming its own
delegation points and linking to this document - no restatement.

### Success Criteria:

#### Automated Verification:
- [x] `ruby .claude/scripts/test/run.rb` is green
- [x] `ruby .claude/scripts/commit_message.rb --check` rejects a message with a
      52-char subject, an 80-char body line, 41 lines, a missing `Refs:`, and a
      `Co-Authored-By` line
- [x] `docs/skill-automation.md`'s skill-to-script map names every script under
      `.claude/scripts/` and every one of the 13 skills
- [x] No script gained a forbidden operation: `contract_test.rb` still green
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] Read `git diff .claude/skills/commit/SKILL.md` line by line against the
      surviving-prose list - the sabotage paragraph and the authority boundary
      are present verbatim
- [ ] `/implement-plan` L248-250's contradiction is resolved in favor of
      CLAUDE.md's table, and no other behavior moved
- [ ] The next `/commit --auto` after this phase behaves identically to the
      previous one (this phase's own commit is the test)
- [ ] All 21 Haiku delegation points in the record trace back to a real step in
      a real skill

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Testing Strategy

### Unit Tests (Ruby, stdlib minitest)

Run with `ruby .claude/scripts/test/run.rb` on `/usr/bin/ruby` 2.6.10. No gems,
no bundler, no network. `mix quality` does **not** run this suite - adding a
stage would edit `.quality.exs` and require an ADR-0011 ledger entry, which is
a human's call. Any phase touching `.claude/scripts/` runs both commands.

Three test layers:

1. **Pure functions**, tested directly with no I/O: the `^Refs:` extraction, the
   idle classifier, the area disjointness and verdict table, the greedy walk,
   the plan-document parser, the filename builder, the commit-message
   validator, the carve-out predicate.
2. **Shell-touching code**, tested through `FakeSh`: argv sequences and their
   **order** are the assertion (capture-then-abort is an ordering test, not a
   presence test). Unexpected commands fail the test, so a script cannot
   silently grow a shellout.
3. **The contract test**, which runs over every script file on every phase and
   asserts the forbidden-operation list, the shebang, the executable bit, and
   the non-interactive flags. It is the mechanical half of "no `ship.rb`".

Fixtures live under `.claude/scripts/test/fixtures/` and are **real captures**:
the `146c69f` commit body, real `tmux capture-pane -e -p` bytes, real
`bd show --json` and `bd ready --json` payloads, real
`git worktree list --porcelain` and `gh pr list --json` output, a real
`mix quality --format json` report, and this plan document itself.

### Conformance Tests

None. This branch touches no Elixir, no corpus, and no ratchet.
`mix test.regression` and `test/passing_tests.json` are untouched by design -
shrinking the latter is a gate-guarded action.

### Manual Testing Steps

1. After Phase 4: `worktree_create.rb --dry-run zz-zzz-scratch` and diff its
   `commands` against `/new-worktree`'s current prose, step by step.
2. After Phase 5: with a live busy Claude window and a live idle one in the
   `statifier-ex` tmux session, run `tmux_window.rb classify` against each and
   confirm the verdicts.
3. After Phase 6: run `select_batch.rb --n 3` and hand-verify every verdict
   against the table in `next-issues/SKILL.md:170-185`.
4. After Phase 7: run `gate.rb` and a bare `mix quality` back to back and
   confirm every `○` skipped line appears in `skipped_stages`.
5. After each of Phases 9-12: read the `git diff` for each SKILL.md against
   that phase's surviving-prose list. This is the primary verification for the
   rewrite phases - "behavior unchanged" is a reading task, not a runnable one.
6. After Phase 12: the phase's own `/commit --auto` exercises the rewritten
   `/commit`. If it refuses, the refusal is the finding.

## References

- Source research:
  `docs/research/260806-zz-hzf-skill-mechanics-scripts.md`
- Beads issue: `zz-hzf`
- `CLAUDE.md` - the agent authority table, the non-interactive shell flags, the
  ExQuality rules, and ADR-0011's mechanical half
- `docs/workflow.md:6-48` - model roles and the frontmatter-beats-override rule
- `docs/workflow.md:147-191` - the closed `area:` vocabulary and disjointness
- ADR-0007 - beads is the only tracker
- ADR-0009 - ex_quality is the gate
- ADR-0010 - one issue, one branch, one worktree; the branch name is a
  creation-time label; `Refs:` trailers are what close beads
- ADR-0011 - the gate's own config is not agent-editable
- `.claude/skills/cleanup-worktrees/SKILL.md:15-38` - why merge detection must
  ask GitHub, never git ancestry
- `.claude/skills/cleanup-worktrees/SKILL.md:150-202` - the idle classifier
- `.claude/skills/cleanup-worktrees/SKILL.md:258-289` - the `^Refs:` extraction
  and the `146c69f` fixture
- `.claude/skills/merge-request/SKILL.md:45-61,63-115` - the duplicated
  `^Refs:` extraction and the shared rebase block
- `.claude/skills/refresh-worktree/SKILL.md:75-121` - capture-then-abort and
  `mix.lock`-conditional repair
- `.claude/skills/next-issues/SKILL.md:143-165,167-198` - survey hardening and
  the verdict table
- `.claude/skills/new-worktree/SKILL.md:118-190` - the tmux block and its traps
- `.claude/skills/commit/SKILL.md:27-45,95-126,139-189` - the refusal
  conditions, the carve-out and sabotage scan, and the bead ladder
- `.claude/skills/work/SKILL.md:37-62,129-141,146-183` - locate-self, the
  resume scan, and the stage contract
- `.claude/skills/implement-plan/SKILL.md:40-122,178-231` - the loop state
  machine and the sabotage protocol
- Prior plans: `docs/plans/260805-st2-ott-work-orchestrator.md`,
  `docs/plans/260805-st2-7jr-selection-choices.md`,
  `docs/plans/260803-st2-gm6-looped-plan-execution.md`,
  `docs/plans/260804-st2-h6p-gate-weakening-check.md`

## Deferred Manual Verification

Manual verification items are deferred during looped (`--loop`) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The envelope example in `README.md` and the one in the research doc agree
- [ ] `docs/skill-automation.md`'s "what must never be scripted" list covers all
      12 risks in the research doc's Risks section
- [ ] No gem was installed to make the suite run

### Phase 2

- [ ] `ruby .claude/scripts/repo_state.rb` run in this worktree and in the main
      checkout reports `checkout` correctly in both
- [ ] `ruby .claude/scripts/worktree_survey.rb` output matches what
      `git worktree list` plus `gh pr list` say by hand
- [ ] The `146c69f` fixture is the real commit body, not a paraphrase

### Phase 3

- [ ] `bd show --json` on the installed `bd` still carries every field the
      wrapper reads; any missing field degrades to `null` with a warning rather
      than a crash
- [ ] `bead.rb resolve` on this worktree names `zz-hzf` with `strategy:
      "plan_doc"`, not `"branch_prefix"`

### Phase 4

- [ ] `worktree_create.rb --dry-run <name>` emits the same command sequence the
      current `/new-worktree` prose specifies, in the same order
- [ ] `worktree_refresh.rb --dry-run` over the live worktrees classifies each
      the same way a manual read of `git worktree list` does
- [ ] The PLT glob still matches a real file in this repo's `_build/dev/`

### Phase 5

- [ ] `tmux_window.rb classify` against a live busy window in this tmux session
      reports busy, and against an idle one reports idle
- [ ] The fixtures are real captures, not hand-typed escape sequences
- [ ] `tmux_window.rb open --dry-run` renders a command line that could be
      pasted into fish unchanged

### Phase 6

- [ ] The verdict a live run gives each ready bead matches what
      `.claude/skills/next-issues/SKILL.md:170-185`'s table gives by hand
- [ ] `zz-hzf`'s own `area:skills` hold is reported as a live collision for any
      other `area:skills` bead

### Phase 7

- [ ] `gate.rb` on a full run agrees stage-for-stage with a bare `mix quality`,
      including every `○` line
- [ ] No argument combination reaches `mix quality --skip`

### Phase 8

- [ ] `plan_state.rb` parses the three most recent plans in `docs/plans/`
      without `sections_missing` false positives
- [ ] `permalinks.rb --dry-run` over an existing research doc proposes only
      correct rewrites

### Phase 9

- [ ] Read `git diff` for each skill against the surviving-prose list above -
      every listed paragraph is present
- [ ] `/cleanup-worktrees` still specifies, somewhere reachable, every one of
      the eleven behaviors its Guidelines section lists
- [ ] Running `/refresh-worktree` live produces the same report vocabulary as
      before

### Phase 10

- [ ] `/next-issues`'s picker section reads identically to before - the
      AskUserQuestion option structure and the override wording are unchanged
- [ ] A dry read of `/next-issue` still ends in the same
      `/new-worktree <id>-<slug> -- /work <id> --auto` invocation
- [ ] The `--label-any` workaround note survived the rewrite


### Phase 11

- [ ] `/merge-request`'s step 6 confirmation is still an unconditional human
      gate with no automated path around it
- [ ] `/create-plan`'s single template is byte-identical to the one that
      produced this document
- [ ] `/research-codebase`'s documentarian charter is unmodified

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

### Phase 12

- [ ] Read `git diff .claude/skills/commit/SKILL.md` line by line against the
      surviving-prose list - the sabotage paragraph and the authority boundary
      are present verbatim
- [ ] `/implement-plan` L248-250's contradiction is resolved in favor of
      CLAUDE.md's table, and no other behavior moved
- [ ] The next `/commit --auto` after this phase behaves identically to the
      previous one (this phase's own commit is the test)
- [ ] All 21 Haiku delegation points in the record trace back to a real step in
      a real skill

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---
## Open Questions

No human was available during planning, so these are recorded here rather than
asked. None blocks Phase 1; each has a stated default so the loop can proceed.

1. **`bd show --json` field stability.** The shape was verified against the
   installed `bd` this session, but `notes` arriving as one string blob is an
   implementation detail that could change. **Default taken**: `bead.rb`
   tolerates missing or renamed fields by emitting `null` plus a warning rather
   than crashing, and `bead_test.rb` pins the current shape as a fixture so a
   change is visible as a test failure rather than as a silent
   misparse. Confirm during Phase 3.

2. **Should `docs/skill-automation.md` eventually be an ADR?** It records a
   policy (what may never be scripted, how models are routed) that reads like a
   settled decision. **Default taken**: it lands as a living doc under `docs/`;
   promoting it to an ADR is a direction-level call and is out of scope here.

3. **Who re-verifies the tmux fixtures after a Claude Code CLI upgrade?** The
   idle classifier depends on the CLI's spinner format and the dim-SGR
   placeholder rendering, both of which could change under the version-named
   binary. **Default taken**: the fixtures are committed and the test names the
   CLI version they were captured from, so a change surfaces as a test failure -
   but nothing re-captures them automatically, and no bead exists for that
   maintenance.

4. **Behavior when a script is missing or errors.** Once the prose is gone the
   skill cannot fall back to it. **Default taken**: scripts report `blocked`
   and the skill stops and says which script failed - a stop is the correct
   failure mode for every one of these skills. The residual question is whether
   the three highest-risk skills (`/cleanup-worktrees`, `/merge-request`,
   `/commit`) should keep a minimal prose fallback for the case where
   `.claude/scripts/` is absent entirely, e.g. in a fresh clone before the
   scripts land.

5. **Should `/create-issue` gain a `model:` line?** It is the only skill without
   one, so it runs on whatever the session is - which for an intake step
   invoked from `/work` (Opus) is a heavier tier than the work needs, and it is
   also one of the identified Haiku delegation points. **Default taken**: left
   unchanged, since adding frontmatter changes behavior and this bead is an
   extraction. Worth a follow-up bead.

6. **Should `.claude/scripts/` eventually move to a plugin or dotfiles repo?**
   Six of the eight families are project-agnostic in shape but reference this
   repo's absolute paths (`/Users/johnnyt/repos/github/statifier-ex`) and its
   `area:` vocabulary. **Default taken**: stays in-repo, with the absolute
   paths isolated to a single `lib/paths.rb` constant block so a future
   extraction has one place to parameterize.

7. **Does anything need to migrate out of the research doc?** **Default taken**:
   no. The research doc stays as the dated snapshot of the audit;
   `docs/skill-automation.md` carries the parts that must stay current (the
   classification table, the skill-to-script map, the never-script list, the
   model routing). The research doc is referenced from it rather than copied.

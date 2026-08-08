# Plan: generalize the statifier-ex workflow skills into wurk

Status: approved direction, not started. This document is the working plan for
an implementing agent (Opus for research/design steps, Sonnet for mechanical
steps). Read `docs/architecture.md`, `docs/manifest.md`, and
`docs/gate-contract.md` before starting any phase; cite `docs/adr/` numbers
instead of re-arguing settled decisions.

## Goal

One shared skill set, installed from this repo into `~/.claude/skills/` under
the `wurk:` namespace, that drives the bead-tracked research -> plan ->
implement -> commit -> merge workflow in statifier-ex, predicator-ex, and
eventually fixative (Rust + Swift) - with each project contributing only a
small manifest and a handful of extension files. This permanently ends the
copy-and-drift problem between the sibling repos.

## Source material

The three repos were surveyed in depth on 2026-08-08. Summary of what exists:

### statifier-ex (`~/repos/github/statifier-ex/.claude`) - the donor

The most evolved set: 13 skills whose deterministic mechanics were extracted
into a tested Ruby scripts layer (`.claude/scripts/`: ~14 top-level scripts,
8 lib modules, minitest suite with a FakeSh shell fake, and a contract test
that mechanically bans `git push`, `gh pr create`, `bd close`, `bd edit`, and
raw `system`/backticks outside `lib/sh.rb`). Scripts emit a single JSON
envelope (`ok/script/data/warnings/blocked/commands`, exit 0/1/2, `--dry-run`
on every mutating script) defined in `.claude/scripts/README.md`. Skills are
judgment prose in a "What to run / How to read / Judgment / Report" shape.

Skills: cleanup-worktrees, commit, create-issue, create-plan, implement-plan,
iterate-plan, merge-request, new-worktree, next-issue, next-issues,
refresh-worktree, research-codebase, work. Plus six read-only research agents
in `.claude/agents/` (codebase-locator/analyzer/pattern-finder,
thoughts-locator/analyzer, web-search-researcher).

Statifier-only machinery living inside shared skills: `gate.rb` wrapping
`mix gate.verify` attestation, the ADR-0011 gate guard + ledger, the sabotage
mutation-testing protocol, the ADR judge (`mix quality --profile merge`,
implemented in `lib/mix/statifier/adr_judge.ex`, invoked only by
`/merge-request` step 4), `changelog.d/` fragments, and per-skill model
routing sections.

Where the project-specific constants live (the parameterization surface):

| Location | Constant |
|---|---|
| `lib/refs.rb` | bead id shape `st-[a-z0-9]+(\.\d+)?` |
| `lib/areas.rb` | closed `area:` label vocabulary + batching policy |
| `lib/touches_elixir.rb` | gate-applicable paths (lib/, test/, config/, mix.exs, mix.lock, .claude/scripts/, .claude/skills/) |
| `gate.rb` | `mix gate.verify`, `mix quality --format json --report -`, `--profile loop` |
| `rebase_onto.rb` | Elixir-only repair (mix deps.get + PLT copy when mix.lock moved) |
| `worktree_create.rb` | `WORKTREES_DIR_NAME = "statifier-ex-worktrees"`, deps/_build/PLT warm-clone |
| `tmux_window.rb` | `SESSION = "statifier-ex"`, hardcoded `MAIN_REPO` absolute path, `MODEL = "opus"`, the `/commit --auto` finishing-clause template |
| `doc_meta.rb` | `docs/plans` + `docs/research` roots, `YYMMDD-[id-]kebab.md` grammar, research frontmatter schema |
| `plan_state.rb` | the nine-section plan template grammar |
| skill prose | `mix quality` commands, ADR citations, `../statifier` reference-repo notes, corpus/ratchet notes |

### predicator-ex (`~/repos/github/predicator-ex/.claude`)

Same 13 skill names plus a 14th, `release`. It is the pre-extraction form:
identical logic inline as bash + prose, no scripts layer. Its drift is almost
entirely "statifier extracted, predicator did not". But predicator is AHEAD in
several places that must be folded in during generalization (see the
best-of-both checklist below). Constants: `px-` prefix,
`../predicator-ex-worktrees/`, tmux session `predicator-ex`, its own area
vocabulary, hex-release facts (`@version` in mix.exs, README pin, direct
CHANGELOG.md editing), ISA/ADR-0003 concepts threaded through six skills.

### fixative (`~/repos/github/fixative/.claude`)

Shared DNA (beads + dolt sync hooks, issue-tagged branches cut from fresh
origin/main, research/plan/implement flow, same six agents, same commit style,
no-AI-attribution rule) but different structural choices:

- Branch-in-current-worktree (`/new-branch`) instead of per-issue worktrees;
  no refresh/cleanup skills.
- GitLab: `glab`, "MR", `/create-mr`, `Closes #NN`, `agent-filed` label.
- Beads promoted to GitLab issues at work-start (`external_ref` GL-NN stamp,
  reconcile + stale-claim reaping in `/next-issue` and `/update-issue` -
  duplicated verbatim between them, a prime extraction target).
- Gate is `mise run quality` / `quality:quick` (change-aware suite skipping,
  xcframework rebuild), bash scripts in repo `scripts/`.
- `/release-app` is Xcode-specific (MARKETING_VERSION in project.yml,
  xcodegen regen, per-package Keep-a-Changelog).
- Artifacts under `thoughts/shared/{plans,research,issues}` not `docs/`.
- Post-branch environment hook: `mise run xcodegen` + dev icon + Dock cache
  refresh.
- Precedent for the whole wurk mechanism: fixative's `.claude/diataxis.md` is
  a project-local manifest consumed by generic `~/.claude` skills
  (write-doc / audit-doc). Wurk generalizes that pattern.

## Target architecture (summary; details in docs/architecture.md)

Four layers:

1. **Generic skills** - `skills/wurk:*/SKILL.md` in this repo, installed into
   `~/.claude/skills/` (ADR-0002, ADR-0003). Judgment, sequencing, authority
   deference. No project constants.
2. **Kit scripts** - the Ruby layer, ported from statifier with constants
   replaced by manifest lookups (ADR-0006). Lives in `skills/wurk:kit/`
   alongside a REFERENCE.md, mirroring the existing `present:kit` pattern.
3. **Per-project manifest** - `.claude/wurk.json` in each consumer repo
   (ADR-0004; schema in `docs/manifest.md`).
4. **Per-project extensions** - optional `.claude/wurk/<skill>.md` files the
   generic skills read and honor (ADR-0004): statifier's ADR judge merge step
   and sabotage protocol, predicator's ISA Impact sections and release recipe,
   fixative's UniFFI/privacy patterns and promotion module.

Authority stays in each repo's CLAUDE.md (the trigger-gated table); wurk
skills defer to it exactly as the current skills do.

## Skill rename map

| Current (statifier / predicator / fixative) | wurk name |
|---|---|
| work / work / (next-issue does triage inline) | wurk:work |
| research-codebase | wurk:research |
| create-plan | wurk:plan |
| iterate-plan | wurk:iterate |
| implement-plan | wurk:implement |
| create-issue (+ fixative update-issue) | wurk:issue |
| commit | wurk:commit |
| merge-request / merge-request / create-mr | wurk:mr |
| next-issue + next-issues | wurk:next (n defaults to 1) |
| new-worktree / new-worktree / new-branch | wurk:branch |
| refresh-worktree | wurk:refresh |
| cleanup-worktrees | wurk:cleanup |
| release (pred) / release-app (fixative) | wurk:release |
| (new, shared foundation like present:kit) | wurk:kit |

Renames must land atomically across the set: skills invoke each other by name
(`/commit --auto` is the implement-loop's advancement gate; `/work` is the
worktree seed prompt; the finishing-clause template in `tmux_window.rb` names
`/commit --auto`). Grep for `/<old-name>` across skills, scripts, and script
tests when renaming.

## Best-of-both checklist (fold in while porting, not after)

From predicator (ahead of statifier):

- [ ] Atomic claim: `bd ready --claim --json` in auto mode (statifier's
      select-then-claim reintroduced a read-then-claim race).
- [ ] Modern research-agent menu in plan/iterate skills: `Explore` agent,
      explicit `general-purpose` criteria, "documentarians, not critics",
      drop statifier's stale pseudo-Python `Task(...)` example, consistent
      "sub-agents" terminology.
- [ ] `release` skill: mechanics-vs-never-publish split (explicit version arg,
      three edits, full gate, `Releases vX.Y.Z` commit; tag/push/publish have
      no trigger, ever). Becomes a wurk:release recipe driven by the manifest.
- [ ] Preventive `permissions.deny` rules for gate config (predicator's
      ADR-0008 pattern). Ship as a recommended settings block in wurk:kit's
      REFERENCE.md; complements statifier's detective gate guard.
- [ ] implement-plan setup pointing at the warmed-worktree skill instead of
      raw `git worktree add`.
- [ ] `coveralls.json` in the gate-moving-files list for refresh.
- [ ] create-issue's richer area-label guidance shape (the vocabulary itself
      is per-project manifest data).
- [ ] create-plan pre-write checklist items that `plan_state.rb validate`
      does not cover (path rules, no unresolved open questions).

From fixative:

- [ ] The promotion/reconcile module (beads -> forge issue at work-start,
      reconcile closed forge issues, reap stale claims) as an optional
      tracker-topology mode - and extract it once; fixative currently
      duplicates it verbatim across two skills.
- [ ] Post-branch setup hook concept (manifest field), covering fixative's
      xcodegen/icon regen and statifier's cache warming as two values of one
      seam.
- [ ] Conventional-Commit `type(package):` + monorepo package routing as an
      optional commit-convention mode.

## Phases

Each phase is independently verifiable and committable. Do not start a phase
until the previous one's verification is green.

### Phase 1: parameterize in place (statifier-ex)

No behavior change; statifier keeps working exactly as today, but reads its
constants from a manifest.

1. Add `.claude/wurk.json` to statifier-ex holding its current values
   (schema: `docs/manifest.md`).
2. Add a `lib/manifest.rb` loader to `.claude/scripts/lib/` (stdlib JSON,
   validated, helpful error when missing/invalid; search upward from cwd so
   worktrees resolve the main checkout's manifest - decide and document the
   resolution rule).
3. Replace constants site by site, each with its own test update:
   `refs.rb` prefix regex, `areas.rb` vocabulary + policy table,
   `touches_elixir.rb` path lists (rename toward `gate_paths.rb`),
   `gate.rb` command strings, `rebase_onto.rb` repair commands,
   `worktree_create.rb` dir name + warm commands, `tmux_window.rb` session /
   main-repo path / model / finishing clause, `doc_meta.rb` roots +
   frontmatter fields.
4. Verification: full `mix quality` green in statifier-ex (the script suite
   runs as its `Script tests` stage); `git grep` shows no remaining hardcoded
   `st-`, `statifier-ex-worktrees`, or absolute repo paths in
   `.claude/scripts/` outside the manifest.

### Phase 2: lift into this repo as wurk

1. Create `skills/` here: port each SKILL.md under its wurk name, folding in
   the best-of-both checklist and stripping statifier-specific prose into
   `.claude/wurk/<skill>.md` extension files that stay in statifier-ex
   (ADR judge invocation, sabotage protocol, corpus/ratchet notes, Appendix D
   references, `../statifier` reference-repo notes).
2. Move the scripts + tests into `skills/wurk:kit/scripts/` with the test
   suite runnable standalone (`ruby skills/wurk:kit/scripts/test/run.rb`);
   port the contract test unchanged - the banned-operations list is
   project-independent policy.
3. Port the six research agents into `agents/` here and decide the install
   story for them (they are currently duplicated identically in all three
   repos; `~/.claude/agents/` can hold one copy).
4. Write `install.rb` (stdlib-only): symlink each `skills/wurk:*` dir and each
   agent file into `~/.claude/`; idempotent; `--dry-run`; refuses to overwrite
   non-symlink existing entries.
5. In statifier-ex: delete the ported skills/scripts, keep manifest +
   extensions + settings hook, narrow the ADR judge's ADR-0015 scope to what
   remains in-repo, and record the move in a short statifier ADR (the gate
   machinery that measured `.claude/` was built deliberately; its scope change
   should be on the record there, not just here).
6. Verification: wurk test suite green standalone; statifier full
   `mix quality` green with the slimmed `.claude/`; a real bead driven
   end-to-end in statifier through wurk:next -> wurk:work -> wurk:commit ->
   wurk:mr in a worktree.

### Phase 3: predicator-ex adoption

1. Write predicator's `.claude/wurk.json` (px- prefix, its worktree dir, tmux
   session, area vocabulary, gate commands without `gate.verify`, hex release
   recipe, direct-CHANGELOG changelog mode).
2. Write its extension files: ISA Impact sections (plan/iterate/research/
   commit), the ISA sizing rule (work), release recipe details.
3. Delete its 14 skills; add the `bd prime` SessionStart hook its settings
   lack; keep its ADR-0008 deny rules.
4. Verification: predicator `mix quality` green; one bead driven end-to-end
   there; diff review confirming nothing predicator-only was lost (its skills
   are the pre-extraction reference implementation - keep them retrievable in
   git history).

### Phase 4: fixative (later; design now, build when wanted)

1. Gate: enters at tier 0 of the gate contract via `mise run quality` /
   `quality:quick` (docs/gate-contract.md); optionally climbs to tier 1 by
   emitting the wurk gate report JSON from its quality script.
2. Parallelism: implement the `branch-in-place` strategy in wurk:branch
   (guarded: refresh/cleanup report not-applicable under it); post-branch
   hook runs its xcodegen/icon chain.
3. Forge: `glab`/MR adapter behind the manifest's forge field (terminology,
   permalink format, `--label agent-filed`, `in_review` bead status).
4. Tracker topology: the promotion/reconcile/reap module as an optional mode.
5. Release: its Xcode recipe as manifest data for wurk:release.
6. Verification: one GL issue driven end-to-end in fixative.

## Open questions (settle during the phase that hits them)

- Manifest resolution from inside a worktree: search upward, or an env var,
  or duplicated per-worktree? (Phase 1, step 2. Leaning: walk up from
  `git rev-parse --git-common-dir`.)
- Machine-specific values (tmux session exists per machine, absolute main-repo
  path): manifest field vs derived at runtime. Leaning: derive the main-repo
  path from `git-common-dir`, keep session name in the manifest.
- Whether `~/.claude/skills` entries are symlinks into this repo (leaning yes,
  via install.rb) or this repo is cloned directly at `~/.claude/skills/wurk`
  (colon-named dirs cannot nest, so probably not).
- Whether wurk grows its own ADR judge over its ADRs once the kit is stable
  (out of scope for phases 1-4).
- Model-tier names (`opus`, `sonnet`, `fable`) hardcoded in skill routing
  sections: manifest field now, or leave literal until a second opinion forms.

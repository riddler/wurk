# Plan: generalize the statifier-ex workflow skills into wurk

Status: approved direction, not started. This document is the working plan for
an implementing agent (Opus for research/design steps, Sonnet for mechanical
steps). Read `docs/architecture.md`, `docs/manifest.md`, and
`docs/gate-contract.md` before starting any phase; cite `docs/adr/` numbers
instead of re-arguing settled decisions.

How to use this plan: phases run in order; each is independently verifiable
and committable, and each ends with a Definition of done. The "Known coupling
points" section is the crack-prevention inventory - re-read it at the start
of every phase and check off the items that phase owns. When reality
contradicts this plan, stop and surface it; do not improvise around it.

## Goal

One shared skill set, installed from this repo into `~/.claude/skills/` under
the `wurk:` namespace, that drives the bead-tracked research -> plan ->
implement -> commit -> merge workflow in statifier-ex, predicator-ex, and
eventually fixative (Rust + Swift) - with each project contributing only a
small manifest and a handful of extension files. This permanently ends the
copy-and-drift problem between the sibling repos.

## Non-goals

- No behavior redesign. Wurk ports the workflow as it exists (plus the
  best-of-both fold-ins listed below); inventing new workflow features is out
  of scope for all four phases.
- No plugin packaging (ADR-0003 defers it).
- No wurk-side ADR judge (possible later; out of scope).
- No changes to the consumer repos' authority models - each repo's CLAUDE.md
  table stays the ceiling, and wurk defers to it.
- No new gate tooling for fixative beyond tier 0 (tier 1 is optional later
  work; see docs/gate-contract.md).

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
`mix gate.verify` attestation, the ADR-0011 gate guard + ledger
(`docs/quality-gate-changes.md`), the sabotage mutation-testing protocol, the
ADR judge (`mix quality --profile merge`, implemented in
`lib/mix/statifier/adr_judge.ex`, invoked only by `/merge-request` step 4),
`changelog.d/` fragments, and per-skill model routing sections referencing
`docs/skill-automation.md`.

Statifier's gate measures its `.claude/` directory today: the Ruby suite runs
as the `Script tests` stage of `mix quality` (wired in `.quality.exs`), the
ADR judge's ADR-0015 constraint-4 scope reads `.claude/skills/**/SKILL.md`,
and `lib/touches_elixir.rb` widens the commit carve-out to `.claude/scripts/`
and `.claude/skills/` for exactly that reason. Phase 2 unwinds this
deliberately (see the cracks inventory).

### predicator-ex (`~/repos/github/predicator-ex/.claude`)

Same 13 skill names plus a 14th, `release`. It is the pre-extraction form:
identical logic inline as bash + prose, no scripts layer. Its drift is almost
entirely "statifier extracted, predicator did not". But predicator is AHEAD in
several places that must be folded in during generalization (see the
best-of-both checklist). Constants: `px-` prefix,
`../predicator-ex-worktrees/`, tmux session `predicator-ex`, its own area
vocabulary (`area:lexer-parser|evaluator|context|functions|visitors|api|`
`conformance|skills|docs|build`, anchored to `CLAUDE.md#area-labels`),
hex-release facts (`@version` in mix.exs, README install pin, direct
CHANGELOG.md editing), ISA/ADR-0003 concepts threaded through six skills.
Its settings.json has ADR-0008 `permissions.deny` rules protecting gate
config but NO `bd prime` SessionStart hook (statifier has the hook and no
deny rules - reconcile both ways).

### fixative (`~/repos/github/fixative/.claude`)

Shared DNA (beads + dolt sync hooks, issue-tagged branches cut from fresh
origin/main, research/plan/implement flow, same six agents, same commit
style, no-AI-attribution rule) but different structural choices:

- Branch-in-current-worktree (`/new-branch`) instead of per-issue worktrees;
  no refresh/cleanup skills; tmux window renamed, not created.
- GitLab: `glab`, "MR", `/create-mr`, `Closes #NN`, `agent-filed` label,
  bead custom status `in_review` at MR-open time.
- Beads promoted to GitLab issues at work-start (`external_ref` GL-NN stamp,
  reconcile closed GL issues, reap stale claims via
  `scripts/beads-stale-claims.sh`) - the reconcile block is duplicated
  verbatim between `/next-issue` and `/update-issue`; extract once.
- Gate is `mise run quality` / `quality:quick` (change-aware suite skipping,
  xcframework rebuild); `/commit` still carries older raw cargo/xcodebuild
  commands that predate the mise wrapper - collapse onto mise during phase 4.
- `/release-app` is Xcode-specific (MARKETING_VERSION in `apple/project.yml`,
  xcodegen regen, per-package Keep-a-Changelog, CURRENT_PROJECT_VERSION from
  `git rev-list --count HEAD`).
- Conventional Commit `type(package):` subjects with a path->package routing
  map (`apple/**`+`crypto-core/**` -> `app`, future `backend/**` -> `api`).
- Artifacts under `thoughts/shared/{plans,research,issues}` not `docs/`;
  its thoughts-locator/analyzer agents target `thoughts/`, statifier's
  target `docs/` (see cracks item 9).
- Post-branch environment hook: `mise run xcodegen` + dev-icon regen + Dock
  icon cache refresh.
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
   generic skills read and honor (ADR-0004).

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

## Cross-reference update checklist (applies at every rename)

Skills, scripts, and docs reference each other by name. When a name changes,
update ALL of these in the same commit:

- [ ] Other SKILL.md files (`/commit --auto` appears in implement-plan, work,
      new-worktree; `/work` appears in next-issue, next-issues, new-worktree;
      `/new-worktree` appears in next-issue(s), cleanup, refresh, implement;
      `/cleanup-worktrees` and `/refresh-worktree` cross-reference each
      other and merge-request; `/create-plan` <-> `/implement-plan` <->
      `/iterate-plan`; `/research-codebase` <-> `/create-plan`).
- [ ] `tmux_window.rb`: the seeded-session prompt (`/work <id> --auto`) and
      the finishing-clause template naming `/commit --auto`.
- [ ] Script tests that assert on those strings (tmux fixtures, contract
      test wording).
- [ ] Consumer-repo CLAUDE.md files: statifier's authority table names
      `/refresh-worktree` and `/merge-request` in trigger cells and cites
      `/implement-plan --loop` in the loop paragraph; the skill-list
      descriptions in each repo.
- [ ] Consumer-repo docs: statifier `docs/workflow.md` (model roles, area
      labels), `docs/skill-automation.md` (model routing), ADRs that name
      skills (ADR-0010 worktrees, ADR-0015 scripts); predicator equivalents.
- [ ] Bead notes grammar: the loop-note strings (`loop: Phase N complete,
      commit <sha>`) do NOT contain skill names - confirm, don't assume.
- [ ] Agent names: skills that spawn subagents (research, plan, iterate,
      work) reference agents by name (`codebase-locator`, ...); the ported
      skills must use the `wurk-` prefixed names (phase 2 step 3).

## Best-of-both checklist (fold in while porting, not after)

From predicator (ahead of statifier):

- [ ] Atomic claim: `bd ready --claim --json` in auto mode (statifier's
      select-then-claim reintroduced a read-then-claim race; keep the
      `bd_claim_failed` handling as the fallback for the interactive path).
- [ ] Modern research-agent menu in plan/iterate skills: the `Explore`
      agent, explicit `general-purpose` criteria, "documentarians, not
      critics", drop statifier's stale pseudo-Python `Task(...)` example,
      consistent "sub-agents" terminology.
- [ ] `release` skill: mechanics-vs-never-publish split (explicit version
      arg - never inferred; preconditions; exactly the recipe's edits; full
      gate; commit titled `Releases vX.Y.Z`; report listing what was
      deliberately NOT done - tag, push, PR, publish, bd close).
- [ ] Preventive `permissions.deny` rules for gate config (predicator's
      ADR-0008 pattern; deny not ask, so unattended `--auto` sessions fail
      cleanly instead of stalling). Ship as a recommended settings block in
      wurk:kit's REFERENCE.md with the documented limit (does not cover
      Bash `sed -i`/redirects).
- [ ] implement setup pointing at wurk:branch (warmed) instead of raw
      `git worktree add`.
- [ ] `coveralls.json` in the gate-moving-files list (statifier's refresh
      dropped it; predicator kept it). Manifest field, but seed both repos'
      values correctly.
- [ ] create-issue's richer area-label guidance shape (exclusive lands-alone
      areas, disambiguation notes, `--acceptance` flag usage).
- [ ] create-plan pre-write checklist items `plan_state.rb validate` does
      not cover (path rules, no unresolved open questions).

From fixative:

- [ ] The promotion/reconcile/reap module (beads -> forge issue at
      work-start, reconcile closed forge issues, reap stale claims) as an
      optional tracker-topology mode - extracted once.
- [ ] Post-branch setup hook concept (manifest field), covering fixative's
      xcodegen/icon chain and statifier's cache warming as two values of one
      seam.
- [ ] Conventional-Commit `type(package):` + monorepo package routing as an
      optional commit-convention mode.

## Known coupling points (the cracks inventory)

Numbered so phases can reference them. Each item names the phase that owns it.

Settled by phase 1 (see that section for what shipped): **3** (the two path
lists), **7** (loop-note grammar is name-free), **8** (forge kind, via the new
`lib/forge.rb` - GitLab blocks rather than half-works), **11** (beads#5358
re-verified, still broken, workaround stays), **12** (commit limits and the
trailer *scheme*), **13** (doc dirs and the derived repository name), **19**
(work_state artifacts), **22** (machine-boundness - the absolute
`/Users/johnnyt` path is derived from git at runtime now). The rest are still
open and still owned by the phase each names.

1. **The `Script tests` gate stage** (phase 2). Statifier's `.quality.exs`
   runs the Ruby suite as a `mix quality` stage. When the scripts move out,
   that stage must be removed or retargeted - and `.quality.exs` is a
   gate-guarded file under ADR-0011, so the edit REQUIRES a human-authored
   ledger entry in `docs/quality-gate-changes.md`. An agent must not write
   that entry for itself: prepare the diff, present it, and ask.
2. **ADR judge scope** (phase 2). ADR-0015 constraint 4's judged scope is
   `.claude/skills/**/SKILL.md`. After the move, statifier's judged surface
   becomes `.claude/wurk/**` (extensions + manifest). Update the judge
   registry (`lib/mix/statifier/adr_judge.ex`), the ADR text if it names the
   path, and record the scope change in a new statifier ADR. Same
   human-ledger caution as item 1 if gate config moves.
3. **Commit carve-out paths** (phases 1-2). `lib/touches_elixir.rb`
   `gate_applicable?` includes `.claude/scripts/` and `.claude/skills/`
   because the gate measures them. Phase 1 moves the lists into the
   manifest; phase 2 changes statifier's values (drop `.claude/scripts/`
   and `.claude/skills/`, add `.claude/wurk/` if the judge scope keeps it
   gate-relevant). Get the ordering right: values change only when the
   files actually move.
4. **The finishing-clause and seed templates** (phases 1-2).
   `tmux_window.rb` hardcodes `SESSION`, `MAIN_REPO` (absolute path),
   `MODEL = "opus"`, and the template that appends "finish with
   `/commit --auto`" to seeded prompts, and the seed itself is
   `/work <id> --auto`. Phase 1 parameterizes; phase 2 renames the skill
   references inside those templates. Miss this and every new worktree
   session is seeded pointing at deleted skills.
5. **Live worktrees during cutover** (phases 2-3). In-flight worktree
   sessions were seeded with old skill names and call old script paths.
   Before each repo's cutover: land or park all branches, run cleanup, and
   confirm `worktree_survey.rb` reports none live. Do not cut over with
   active worktrees.
6. **`bd prime` hook asymmetry** (phase 3). Statifier's settings.json has
   the SessionStart `bd prime --hook-json` hook; predicator has none (its
   CLAUDE.md assumes injection that never happens). Fixative has SessionStart
   `bd dolt pull` + Stop `bd dolt push` instead. Wurk:kit's REFERENCE.md
   documents the recommended hook block; phase 3 adds it to predicator.
7. **Loop-note grammar coupling** (phase 1). `lib/beads.rb` parses the
   `/implement-plan --loop` note grammar written via `bd note` and read by
   `work_state.rb` - a cross-session state channel. The grammar is
   wurk-defined (generic); confirm the strings carry no project or skill
   names, and keep the parser and the skill prose that writes the notes in
   the same repo (both move to wurk together).
8. **Forge-format leaks** (phases 1, 4). `permalinks.rb` builds GitHub blob
   URLs; `pr_state.rb` shells `gh pr list`; merge-request writes
   `Closes st-xxx` lines. Phase 1 routes these through the manifest's forge
   field with `github` as the only implemented kind; phase 4 adds `gitlab`
   (glab equivalents: `glab mr list`, GL permalink format, `Closes #NN`).
   Until phase 4, a `gitlab` manifest value must error clearly, not
   half-work.
9. **The docs agents' path split** (phase 2). Statifier's
   thoughts-locator/analyzer target `docs/`; fixative's target `thoughts/`.
   In wurk these become wurk-docs-locator/wurk-docs-analyzer (phase 2
   step 3). Agent .md files take no config at load time, but agents can
   read files at runtime. Resolution, layered: (a) the INVOKING skill
   passes the
   project's artifact roots (from the manifest) in the agent prompt -
   deterministic fast path; (b) the agent's own instructions say that when
   no roots were given, read `.claude/wurk.json` and use `artifacts.*`;
   (c) with no manifest either, glob the conventional candidates
   (`docs/research`, `docs/plans`, `thoughts/shared/`) and say which was
   used. (b)+(c) keep the agents useful standalone, outside wurk skills.
   Verify each ported skill actually passes the paths; a skill that
   forgets silently costs every invocation an extra manifest read. The
   other four agents (codebase-locator/analyzer/pattern-finder,
   web-search-researcher) carry no project assumptions and port verbatim.
10. **Model routing references** (phase 2). Statifier skills carry
    `## Model routing` sections citing `docs/skill-automation.md` (a
    statifier doc). Generic skills keep the routing tables (model names are
    workflow policy, near-identical across repos - note the one divergence:
    Direction bucket runs Fable in statifier, Opus in predicator; make the
    Direction model a manifest field under `tmux`/models) but must not cite
    consumer docs. Consumer-specific rationale goes to the extension file.
11. **`beads#5358` workaround** (phase 1). `select_batch.rb`/skills carry a
    `--label-any` union workaround with an `unverified_filter` guard.
    Verify at port time whether the bd bug is fixed; keep the workaround
    with its issue link if not, drop it (and its guard) if fixed.
12. **`commit_message.rb` constants** (phase 1). Subject < 50, body <= 72,
    <= 40 lines, `Refs:` present-and-last, attribution ban list. The
    attribution ban is universal (keep hardcoded); limits and the trailer
    key come from the manifest (`commits.*`; fixative uses `(GL-NN)` tags +
    `Closes #NN` instead of `Refs:` - model the trailer scheme, not just
    the number).
13. **`doc_meta.rb` frontmatter** (phase 1). The research frontmatter emits
    `repository: statifier-ex` and repo-specific fields. Repository name
    derives from the git remote or manifest; the field list becomes
    manifest data with the current schema as default.
14. **Alias shims / muscle memory** (phases 2-3). After deletion, typing
    `/commit` in a consumer repo does nothing (or hits a different global).
    Decide per repo: either accept retraining (leaning: yes, single user)
    or leave one-line shim skills for a transition window. If shims are
    left, they must only say "invoke /wurk:commit", never duplicate logic,
    and get deleted at the next phase boundary.
15. **`bd merge-slot`** (phase 2). Referenced by refresh/cleanup prose as
    the merge-queue coordination primitive. It is a bd feature, not a
    statifier invention - keep it in generic prose.
16. **Sabotage discipline is statifier-only** (phase 2). The sabotage
    protocol (break-the-code/confirm-red/revert/one-line note) and its
    commit-refusal condition live in statifier's testing doc and gate.
    They go to statifier's extension files (`wurk/commit.md`,
    `wurk/implement.md`), NOT into generic skills - predicator and fixative
    never adopted them.
17. **Changelog models differ threefold** (phases 1-4). statifier:
    `changelog.d/` fragments + never edit CHANGELOG.md; predicator: edit
    `## [Unreleased]` directly + explicit warning against importing the
    fragment workflow; fixative: per-package Keep-a-Changelog files. The
    manifest's changelog mode drives wurk:commit's changelog step; make
    sure the fragment-vs-direct instructions never appear together.
18. **First-commit ritual** (phase 2). "First commit of a new repo is
    .gitignore only" is a user-level convention (also in user memory), not
    project data. Keep it out of wurk skills; it does not generalize to a
    manifest field.
19. **`work_state.rb` doc lookups** (phase 1). It scans
    `docs/research`/`docs/plans` by bead id - paths from the manifest
    (`artifacts.*`), same values the skills pass to agents (item 9). One
    source: the manifest.
20. **settings.local.json noise** (phase 3). Predicator's ~190 accumulated
    allow entries are organic accretion, not workflow dependencies. Do not
    port them; note in REFERENCE.md that consumers may want
    `/fewer-permission-prompts` after adoption.
21. **Six agents are triplicated** (phase 2). Identical files in all three
    repos. One copy moves to wurk's `agents/`, installed to
    `~/.claude/agents/`, renamed `wurk-*` (hyphen; colons are illegal in
    agent names) and colored per the phase 2 step 3 table; consumer copies
    are deleted in each repo's adoption phase, at which point the
    unprefixed names stop resolving - the same commit must update any
    remaining prose that names them. Note the double rename on the
    thoughts pair (`thoughts-locator` -> `wurk-docs-locator`): greps for
    old names must cover both `thoughts-` and bare `docs-` forms
    (item 9).
22. **Machine-boundness** (phase 1). `MAIN_REPO` absolute path must derive
    from `git rev-parse --git-common-dir` at runtime (works from any
    checkout on any machine); tmux session name stays manifest data. Wurk
    itself must work on a second machine by clone + install.rb; nothing may
    assume `/Users/johnnyt`.

## Phases

### Phase 1: parameterize in place (statifier-ex)

**Status: LANDED on branch `st-urc` (2026-08-08), not yet merged.** Bead
`st-urc` in statifier-ex carries the full session-by-session record. Three
commits, each on a full attested green (`mix gate.verify`):

    ff49909 Adds the wurk manifest and its loader
    d87acca Reads bead, area, gate and doc paths from the manifest
    effcb32 Reads worktree and forge behavior from the manifest
    6aacda7 Finishes the manifest conversion of the scripts

plus `7a85d28 Settles the manifest schema against the loader` here, which is
where `docs/manifest.md` caught up to what the loader actually implements.

The steps below are kept as written, with outcome notes where reality
diverged; the conversion table is corrected to the field names that shipped.
Read them together with `docs/manifest.md` (the schema is authority) before
starting phase 2.

No behavior change; statifier keeps working exactly as today, but reads its
constants from a manifest. All work happens in statifier-ex on a normal
issue branch (create a bead for it), gated by its own `mix quality`.

Steps:

1. Add `.claude/wurk.json` holding statifier's current values (schema:
   `docs/manifest.md`). Validate it against the schema doc by hand; the
   loader (step 2) becomes the mechanical check.
2. Add `lib/manifest.rb` to `.claude/scripts/lib/`: locate the manifest by
   walking up from the working directory, falling back to
   `git rev-parse --git-common-dir` (**settled the other way round from the
   lean here** - a worktree is a full checkout and carries its own
   `wurk.json`, so walking up finds the manifest on the branch being worked,
   which is what makes a schema change testable on the branch that makes it;
   recorded under "Resolution" in docs/manifest.md), parse with stdlib JSON,
   validate
   (unknown keys warn, missing required keys block naming the field, enum
   fields reject unknown values), expose typed accessors, provide a
   `manifest.rb check` CLI subcommand emitting the standard envelope. Tests
   use fixture manifests under `test/fixtures/manifests/`.
3. Convert scripts one at a time, each with its test updates in the same
   commit. Conversion table (script -> manifest fields consumed):

   Conversion table **as shipped** (the field names differ from the first
   draft in a few places; see "Schema changes made while converting" below):

   | Script | Fields | Notes |
   |---|---|---|
   | `lib/refs.rb` | `beads.prefix`, `commits.trailer.key` | `Refs::BEAD_ID` became `Refs.bead_id`, a method - the manifest is not loaded at require time (item 12) |
   | `lib/areas.rb` | `beads.areas.*` | vocabulary, lands_alone, always_batchable |
   | `lib/touches_elixir.rb` | `gate.build_paths`, `gate.also_gated_paths` | renamed `gate_paths.rb` and `git rm`'d; `any?` -> `touches_build?`, `gate_applicable?` unions both lists (item 3) |
   | `lib/beads.rb` | (none new) | loop-note grammar confirmed name-free (item 7); carries the beads#5358 re-verification note |
   | `lib/summary.rb` | (none) | generic already |
   | `lib/forge.rb` | `forge.kind` | **new file.** One place answering "is this forge implemented?", plus the blob-permalink shape (item 8) |
   | `gate.rb` | `gate.full/loop/report/report_loop/attest/guard_ledger` | tier detection per docs/gate-contract.md; emits `data.tier` |
   | `rebase_onto.rb` | `parallelism.repair_when/repair/warm_globs` | `perform()` takes a manifest; copied caches keep their repo-relative path |
   | `repo_state.rb` | via gate_paths, refs; `artifacts.plans`, `changelog.dir` | |
   | `worktree_create.rb` | `parallelism.model/worktrees_dir/trust/warm_clone/warm_globs/warm`, `gate.loop` | blocks on a `parallelism.model` it does not implement and on an unset `worktrees_dir`; `data.plt_present` -> `data.warm_caches_present` |
   | `worktree_refresh.rb` | `gate.loop`, and `parallelism.*` through `rebase_onto` | `gate.moving_files` **has no consumer** - see the open item below |
   | `worktree_cleanup.rb` | `forge.kind` | guards in its own voice rather than relaying a nested `survey_failed` - it is the script that deletes branches |
   | `worktree_survey.rb` | `forge.kind`, via refs | item 8 |
   | `pr_state.rb` | `forge.kind` | gitlab blocks `unsupported_forge` before any `gh` call, never half-works |
   | `permalinks.rb` | `forge.kind` | URL shape moved to `lib/forge.rb`; a forge with no format raises rather than guessing a URL that 404s inside a document nobody re-reads |
   | `tmux_window.rb` | `tmux.session/model` | main repo derived from `git rev-parse --git-common-dir` at runtime (item 22 - the `/Users/johnnyt` constant is gone); no `tmux` section blocks rather than inventing a session name; templates still name old skills until phase 2 (item 4) |
   | `select_batch.rb` | via areas, refs | beads#5358 re-verified (item 11) - see below |
   | `bead.rb` | via refs | |
   | `commit_message.rb` | `commits.subject_under/body_line_max/total_lines_max/trailer.key` | `subject_under` is exclusive, so the inclusive bound is spelled once; `ATTRIBUTION_PATTERNS` stays **hardcoded** - universal, not project data (item 12) |
   | `doc_meta.rb` | `artifacts.plans/research/repository` | `VALID_DIRS` gone; repository derived from origin's URL when the manifest does not override (item 13) |
   | `plan_state.rb` | via refs | `BEADS_ISSUE_RE` became a method; template grammar is wurk-defined |
   | `work_state.rb` | `artifacts.*` | item 19 |
   | `envelope.rb`/`cli.rb`/`sh.rb` | (none) | untouched |

   **beads#5358 (item 11) re-verified 2026-08-08 on bd 1.1.2: still broken.**
   `bd ready --json --label-any area:skills` returned all 14 ready beads while
   `bd ready --json -l area:skills` returned 0 - the silent-ignore symptom
   exactly. `Beads.union_by_id` and `select_batch.rb`'s `unverified_filter`
   guard both stay, with the issue link. Re-check at the next bd upgrade, not
   before.

4. Update `.claude/scripts/README.md`: the manifest is now a documented
   input to the contract; fixture-manifest testing convention. **Done** - a
   "The manifest is an input to the contract" section (schema, resolution
   order, asymmetric validation, the `Manifest.require!` entry point, and
   the rule that an unconfigured capability is reported rather than guessed)
   and a "Fixture manifests" subsection.
5. Skill prose: replace hardcoded command strings the skills tell the agent
   to run only where they duplicate what scripts now read from the manifest;
   do NOT restructure skills in this phase (that is phase 2's job). **Done,
   minimally** - `new-worktree/SKILL.md` stopped restating
   `worktree_create.rb`'s commands and now names the current envelope codes
   (`trust_failed`, `warm_failed`, `warm_cache_missing`,
   `wrong_parallelism_model`, `missing_worktrees_dir`);
   `refresh-worktree/SKILL.md` names `gate.loop` and
   `parallelism.repair_when` instead of literal commands.

Schema changes made while converting (all already in `docs/manifest.md`,
committed as 7a85d28 - do not re-derive them from this table):

- `gate.paths` split into `gate.build_paths` + `gate.also_gated_paths`. They
  answer different questions, and conflating them once let statifier report
  "no gate applicable" for an 8k-line Ruby branch (item 3).
- `gate.report_loop` added. Composing "report command + loop profile" in the
  kit would mean knowing one gate tool's flag surface, which is what the gate
  contract exists to avoid. Absent, a loop run degrades to tier 0.
- `commits.subject_max` renamed `subject_under` (the bound is exclusive),
  joined by `body_line_max`, `total_lines_max`, and `trailer: {key: "Refs"}` -
  modelling the trailer *scheme*, not a number, because fixative uses
  `Closes #NN` (item 12).
- `parallelism.trust` added: the one command run *about* a worktree rather
  than in it (`mise trust`). Its argv may contain the literal token `{path}`.
  Nothing else templates.
- `parallelism.warm_globs` added: caches worth reporting and repairing (the
  dialyzer PLT, in statifier).
- `artifacts.repository` added, optional, derived from the git remote when
  absent (item 13).

Definition of done:
- Full `mix quality` green in statifier-ex (script suite included), via
  `mix gate.verify`. **Met** - 14 stages, 850 tests, 95.5% coverage, plus
  the 363-test Ruby script suite as the `Script tests` stage.
- `git grep -nE 'st-|statifier-ex-worktrees|/Users/johnnyt' -- .claude/scripts`
  returns only `wurk.json`, fixtures, and deliberate deprecation comments.
  **Met, under the settled reading of the criterion (2026-08-08).** The pattern
  matches itself: `list-panes`, `list-windows` and `Best-effort` all contain
  `st-`. Narrowed to a bead-id shape -
  `git grep -nE '(^|[^a-z])st-[a-z0-9]{3}|statifier-ex-worktrees|/Users/johnnyt'` -
  about 45 lines remain and **every one is a comment**: plan-document path
  citations in script headers, bead-id provenance (`st-hzf`, `st-biu`,
  `st-sdv`, `st-byl`, `st-zgf`) recording why a rule exists, and `st-` used
  as the illustrative example when explaining the prefix mechanism. Plus one
  deliberate negative assertion (`manifest_test.rb` asserts `"st-abc"` does
  *not* match a `zz` pattern) and `plan_state_test.rb`, which parses
  statifier's real plan document as its fixture because a synthetic copy
  cannot go stale against the real grammar. **No executable code carries a
  project constant.**

  **Decision: the criterion scopes to executable code; comments are exempt.**
  Rewriting a citation would break a real file reference or turn a provenance
  note into a lie, and neither is a project constant in the sense the hard
  rule means (nothing reads them at runtime). Re-running the grep after any
  future phase, judge the hits by whether code or a comment carries them.

  That exemption is not a licence to leave the comments untouched at the
  move, because a fifth of them stop being true when the files change repos.
  A re-grep on the `st-urc` worktree (51 hits) sorts them four ways:

  | Kind | Hits | Fate at the phase 2 move |
  |---|---|---|
  | `docs/plans/260806-st-hzf-...md Phase N` header citations | ~20 | **Dangle** - a relative path into a repo the file no longer lives in |
  | Bead-id provenance (`st-biu`, `st-sdv`, `st-zgf`, `st-byl`) | ~12 | Still true, but unresolvable from wurk |
  | `st-abc` / `st-00p.3` as illustrative examples | ~5 | Harmless; they explain the prefix mechanism |
  | Test fixtures (tmux panes, plan fixtures, `plan_state_test`) | ~14 | Data, not constants |

  Only the first row is a defect, and it is a broken cross-repo reference
  rather than a leaked constant. Phase 2 step 1 owns fixing it.
- `manifest.rb check` passes against the real manifest and fails usefully
  against a broken fixture. **Met** - exit 0 on the real one, exit 1 naming
  `missing required key beads.prefix` on the `missing_required` fixture.
- One end-to-end smoke: create a scratch worktree via `/new-worktree` on a
  trivial bead, confirm seed, gate, and cleanup still work, remove it.
  **Deferred, with a substitute run.** It cannot be done from the branch:
  `worktree_create.rb` refuses to run outside the main checkout, and
  `~/repos/github/statifier-ex` is on `main`, which has neither these scripts
  nor a `wurk.json`. **Re-run it for real once this branch lands - that is
  the actual confirmation, and it is the only thing that catches a
  `tmux_window.rb` mistake.** What was run instead (2026-08-08): a scratch
  git repo whose every manifest value differs from statifier's (prefix `zz`,
  gate `["true"]`, `worktrees_dir ../myrepo-worktrees`, trust
  `["true","trust","{path}"]`, `tmux.session wurk-smoke`, `tmux.model
  haiku`). Verified live: manifest check green; `worktree_create.rb` dry-run
  then for real, creating the worktree at the manifest's path with `{path}`
  substituted and `warm_caches_present` true; `tmux_window.rb ensure-session`
  opening a session whose working directory is the *derived* main checkout;
  `open --dry-run` rendering `--model haiku`, not `opus`; `find`/`classify`/
  `close` against a real window; `worktree_survey.rb` decomposing branch
  `zz-smk-scratch-thing` to bead `zz-smk`; and `pr_state`,
  `worktree_survey`, `worktree_cleanup` all blocking `unsupported_forge`
  once `forge.kind` was flipped to `gitlab`. Torn down afterwards.
  `tmux_window.rb open` was not run for real - it launches a live claude
  session; its send-keys argv is asserted byte-for-byte in the tests.

Open item carried into phase 2:

- ~~**`gate.moving_files` has no consumer.**~~ **Settled in phase 2 step 1:
  it gained one.** The nearest thing was statifier's `test/contract_test.rb`
  `GUARDED_WRITE_TARGETS`, ruled out at the time because it was drift-checked
  against ADR-0015's own text. Moving the file made the guess wrong in a more
  useful way: those five filenames became consumer constants sitting in kit
  source, which the hard rule forbids outright. `Contract.guarded_writes` now
  takes its targets as an argument, and the suite supplies the union of every
  fixture manifest's `gate.moving_files` + `gate.guard_ledger`. The field
  stays in the schema. `.sobelow-conf` was added to the `gate_tier1` fixture
  so coverage did not narrow; statifier's own `wurk.json` should gain it too
  at step 8.

Testing convention established here, and expected to carry into the kit:

`test/support/manifest_helper.rb` plus fixtures under
`test/fixtures/manifests/*.json`. **A test never reads the consumer repo's
real `wurk.json`** - asserting a bead id starts with `st-` passes for the
wrong reason (that repo happens to be statifier) and proves nothing about
the value having been read at all. Fixtures use prefix `zz`, `make` gate
commands, and names like `faketool` so nothing in them can be confused with
a real value. Helpers: `with_manifest`, `manifest_with` (one field
different), `fixture_manifest`, and `in_tmp_repo` (a tmpdir carrying
`.claude/wurk.json`, needed by any script that locates its own manifest by
walking up - a bare `mktmpdir` falls through to `git rev-parse`, which
`FakeSh` correctly refuses). Fixtures as of phase 1: `valid`, `areas`,
`areas_wide`, `repo_layout`, `thoughts_layout`, `gate_tier0`, `gate_tier1`,
`worktree`, `forge_gitlab`, `tmux`, `commits`, `bad_enum`,
`missing_required`, `unknown_key`, `wrong_version`, `shell_string_command`,
`malformed`.

### Phase 2: lift into this repo as wurk

Work happens in BOTH repos: wurk gains its content; statifier slims down.
Sequencing constraint: item 5 (no live worktrees at cutover).

**Precondition, outstanding as of 2026-08-08: `st-urc` is still unmerged and
its worktree is still live.** Two things follow, and they gate different
halves of this phase:

- Steps 6-10 (the statifier side) cannot start. Item 5 forbids cutting over
  with an active worktree, and `st-urc` is one.
- Phase 1's real end-to-end `/new-worktree` smoke is still owed. It could not
  run from the branch (`worktree_create.rb` refuses to run outside the main
  checkout, and statifier's main has neither the scripts nor a `wurk.json`).
  Run it from main immediately after `st-urc` merges. It is the only check
  that catches a `tmux_window.rb` mistake, and a mistake there breaks every
  seeded session silently.

Steps 1-5 (the wurk side) are additive and do not depend on the merge; they
may proceed against the `st-urc` worktree as the source of truth. Accept the
small drift risk knowingly: if the merge changes a script, the copy here must
be re-synced.

#### Tracking

From 2026-08-08 the remaining work is tracked as beads in this repo
(prefix `wu-`), one per step, with dependencies wired. `bd ready` is
authority on what is startable; this document stays authority on what each
step means and why. Two rules keep them from drifting apart:

- **A step is done when its bead closes.** Mark the step here in the same
  commit, with the bead id and an outcome note where reality diverged.
- **Statifier- and predicator-side steps get a `wu-` bead for tracking and
  their own bead + branch in that repo for execution** - the consumer repo's
  gate is what the work has to pass, so the branch belongs there.

#### Where a fresh session picks up

**Start in the wurk repo, on `main`.** Steps 1-4 are done; step 5 is next and
is entirely wurk-side.

State as of 2026-08-08:

| | Bead | |
|---|---|---|
| Step 1 | - | Done - `308e36b` (the lift), `ea60279` (SKILL.md + REFERENCE.md) |
| Step 2, first half | - | Done - wurk:commit, wurk:mr, wurk:research, wurk:plan, wurk:iterate, wurk:implement. See "Step 2 outcome notes" below |
| Step 2, second half | - | Done - wurk:branch, wurk:refresh, wurk:cleanup, wurk:work, wurk:next, wurk:issue, wurk:release. See "Step 2 outcome notes (second half)" |
| Step 3 | - | Done - all eight agents in `agents/`. See "Step 3 outcome notes" |
| Step 4 | `wu-k9j` | Done - `install.rb`. See "Step 4 outcome notes" |
| Step 5 | `wu-em8` | **Next.** Wurk repo hygiene |
| Steps 6-7 | `wu-off` | **Blocked** until `st-urc` merges (item 5) |
| Step 8 | `wu-s36` | Blocked; HUMAN-GATED |
| Step 9 | `wu-1oo` | Blocked |
| Step 10 | `wu-cgw` | Blocked |
| Phase 2 done | `wu-902` | The definition-of-done checks, once all of the above land |
| st-urc merge + phase 1 smoke | `wu-b1p` | **Owed.** Needs a human; unblocks steps 6-10 |
| Phase 3 | `wu-4tq` | Blocked on `wu-902` |
| Phase 4 | `wu-4wl` | Blocked on `wu-4tq` |

Not attached to a step, but in the same backlog: `wu-gd1` (statifier
constants still in `gate.rb` - blocks the slim-down, since the extensions
those constants should come from are written there), `wu-z6n` (the
atomic-claim fold-in carried out of step 2), `wu-mkm` (how host-project
orientation reaches the codebase agents, opened by step 3), and `wu-upg`
(wurk dogfooding its own workflow, blocked on `install.rb`).

The second half is the orchestration chain, and it is where the manifest's
structural switches actually bite: `parallelism.model` (wurk:branch, and the
not-applicable guards in refresh/cleanup), `beads.topology` (wurk:issue,
wurk:next), and `release` (wurk:release refuses on `null`). Read the first
half's skills before writing them - they establish the conventions the second
half should match: an installed-path script invocation
(`ruby ~/.claude/skills/wurk:kit/scripts/<script>.rb`), a "## Project
extension" section naming `.claude/wurk/<skill>.md` and where in the flow it
is read, manifest fields named rather than their values, and the kit
REFERENCE.md pointer as the last line of the preamble.

Read `docs/architecture.md`, `docs/manifest.md`, and
`skills/wurk:kit/REFERENCE.md` first. The gate is
`ruby skills/wurk:kit/scripts/test/run.rb` - green at 364 runs.

Source material for step 2 lives in the `st-urc` worktree at
`~/repos/github/statifier-ex-worktrees/st-urc/.claude/skills/`, with
predicator-ex and fixative as the best-of-both donors named per skill below.
Do not delete anything on the statifier side yet; that is step 7.

Two carry-forwards not otherwise recorded in a step:

- `.sobelow-conf` is declared in the `gate_tier1` fixture but missing from
  statifier's real `wurk.json`. Add it at step 8.
- Merging `st-urc` is cheap and unblocks both the smoke and steps 6-10. It
  needs a human (the kit may not push or open a PR), so it is worth doing
  whenever convenient rather than waiting for step 2 to finish.

Steps, wurk side:

1. **DONE (2026-08-08, commits `308e36b` + `ea60279`).** Suite green
   standalone: 364 runs, 1171 assertions, 0 failures, on system Ruby, in
   ~0.55s. Outcome notes after the step text below.

   Create `skills/wurk:kit/`: move the scripts + tests; suite runnable as
   `ruby skills/wurk:kit/scripts/test/run.rb`; port the contract test
   unchanged (banned operations are project-independent policy); write
   REFERENCE.md (envelope contract, manifest consumption, recommended
   settings blocks: `bd prime` hook, ADR-0008-style deny rules with their
   documented limits, `/fewer-permission-prompts` note).

   Two things break on the way across the repo boundary, both inherited from
   phase 1's comment-exemption decision (see that phase's grep bullet):

   - **Header citations dangle.** ~20 files open with
     `docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase N` - a
     relative path that resolves in statifier and nowhere else. Rewrite each
     to name the repo (`statifier-ex docs/plans/260806-st-hzf-...`) or, where
     the citation carries no rationale the comment does not already state,
     drop it. Bead-id provenance comments stay untouched.
   - **`plan_state_test.rb` reads a file that will not exist.** Its
     `REAL_PLAN` constant walks `../../../docs/plans/` to parse statifier's
     live plan document, deliberately, so the grammar cannot go stale against
     a synthetic copy. That path has no meaning in wurk. Decide at move time;
     leaning: snapshot the document into `test/fixtures/plans/` as a frozen
     real-grammar fixture and say in a comment that it is a snapshot, which
     keeps the coverage and loses only the staleness alarm. Do not silently
     delete the two tests.

   **What actually happened.** The snapshot lean was taken
   (`test/fixtures/plans/real_grammar_snapshot.md`, bead ids rewritten to the
   `zz` fixture prefix). The citations were qualified with the repo name
   rather than dropped. Three things the step text did not anticipate:

   - **The contract test's drift check had the same problem, one level up.**
     It re-read statifier's ADR-0015 to prove its coverage matched the prose.
     Re-anchored to wurk's ADR-0006, which gained an explicit
     banned-operation constraint to be read. It found a real gap on its first
     run: `glab mr create` was stated policy with no matching `Contract`
     rule. Fixed.
   - **`GUARDED_WRITE_TARGETS` was five statifier constants in kit source** -
     see the resolved open item under phase 1.
   - **Several tests passed only because the walk-up found statifier's real
     `wurk.json`** (two `GateTest` path predicates, all of
     `PlanStateLibTest`/`PlanStateCliTest`, one `work_state` case). Each now
     drives a fixture explicitly. `ManifestCliTest#test_this_repos_manifest_is_valid`
     had no wurk equivalent at all - wurk ships no manifest - and became
     "every fixture that is not deliberately broken satisfies the schema",
     which does the same job (a schema change invalidating shipped data fails
     the suite) without a consumer repo. Sample paths like
     `lib/statifier/interpreter.ex` in test bodies were neutralized to
     `lib/acme/`.

   REFERENCE.md was not written from scratch: `scripts/README.md` was already
   that document, so it was `git mv`'d to the kit root, retargeted, and given
   the recommended-settings sections. SKILL.md is new and deliberately thin.
2. Port each skill under its wurk name. Per-skill porting notes - for each,
   the split is [generic core] / [to statifier extension `.claude/wurk/*`] /
   [best-of-both fold-in]:
   - **wurk:commit** - generic: gate-run, diff analysis, 5-strategy bead
     ladder, message draft + `commit_message.rb check`, post-commit
     attribution re-verify, `--auto` refusal list; on a non-trivially-red
     gate, delegate the full output to wurk-gate-reader. Extension
     (statifier
     `wurk/commit.md`): sabotage-note refusal (item 16), changelog-fragment
     step details, ratchet notes, ledger citations, 2.0.0-dev no-bump rule.
     Fold-in: changelog step driven by manifest mode (item 17).
   - **wurk:mr** - generic: location check, bead resolution from trailers,
     rebase via kit, gate, human confirmation, hand-run push + PR/MR
     creation, record on bead, never close. Extension (statifier
     `wurk/mr.md`): ADR judge step (`mix quality --profile merge`; skip is
     pushable, finding is a hard refuse). Fold-in: forge terminology from
     manifest.
   - **wurk:plan / wurk:iterate** - generic: research flow, nine-section
     template, `plan_state.rb validate` before presenting, phases sized for
     the implement loop, ADR-deference rule ("flag, never silently
     contradict an accepted ADR"), and a wurk-plan-critic pass before
     presentation (iterate: after substantive edits). Extensions:
     statifier corpus/ratchet success criteria + Appendix D; predicator
     ISA Impact. Fold-ins: modern agent menu, pre-write checklist items
     (now largely absorbed by the critic - keep only what the critic's
     prompt does not cover), drop the stale `Task(...)` example. Skills
     pass `artifacts.*` paths to agents (item 9).
   - **wurk:implement** - generic: phase-by-phase, `--loop` orchestration
     (subagent per phase, `/wurk:commit --auto` as advancement gate,
     deferred-manual-verification section, loop-note grammar via
     `bead.rb note`), resume from unchecked boxes, 3-layer spawn budget,
     wurk-gate-reader on red gates (mind the spawn budget in `--loop`
     mode - the gate-reader is a leaf, never a spawner). Extension:
     sabotage protocol. Fold-in: setup points at wurk:branch.
   - **wurk:research** - generic: documentarian rules, subagent fan-out,
     `doc_meta.rb` frontmatter/filename, `permalinks.rb`, record on bead,
     follow-up mode. Extensions: statifier pipeline vocabulary +
     `../statifier` reference notes; predicator sibling-port guidance.
   - **wurk:work** - generic: locate self via `repo_state.rb`, four sizing
     buckets, `work_state.rb` resume scan, model-tiered dispatch, never
     implements directly, anti-recursion rule. Direction-bucket model from
     manifest (item 10). Extensions: ISA sizing rule (pred), domain bucket
     vocabulary.
   - **wurk:next** - generic: sync, cleanup pass, candidate survey +
     verdict table, disjoint-area batching, claim, stand up via
     wurk:branch, seed with wurk:work. Fold-in: atomic claim in auto mode;
     picker columns rule (title + summary mandatory). n>4 refusal stays.
   - **wurk:branch** - two strategies behind `parallelism.model`:
     `worktree-per-issue` (statifier's create+warm+tmux-window+seed) and
     `branch-in-place` (fixative's switch+rename-window+post_branch hook -
     implemented in phase 4, erroring clearly until then).
   - **wurk:refresh / wurk:cleanup** - generic with manifest paths; both
     report not-applicable under `branch-in-place`. Fold-in:
     coveralls.json in moving files (via manifest seed values).
   - **wurk:issue** - generic: bead creation, dedupe, scope classification,
     dependency links, label guidance shape with manifest vocabulary.
     Topology extras (promotion stamps, forge mirroring) gated on
     `beads.topology` (phase 4 implements).
   - **wurk:release** - recipe-driven from `release` manifest field;
     `null` -> the skill refuses with "this project has no release recipe".
     Port predicator's skill as the hex recipe shape now; fixative's
     xcode-app recipe lands in phase 4.

   **Step 2 outcome notes (first half, 2026-08-08).** Six skills landed:
   wurk:commit, wurk:mr, wurk:research, wurk:plan, wurk:iterate,
   wurk:implement - the authoring chain. The split was chosen so the half
   that depends on the structural manifest switches stays together in the
   second half. Kit suite still green (364 runs). Notes:

   - **The `st-urc` grep pattern was re-run over the six new files and comes
     back empty**, along with `mix `, `Appendix D`, `changelog.d`,
     `ex_quality`, and consumer ADR numbers. The generic skills name manifest
     fields (`gate.build_paths`, `changelog.mode`, `commits.trailer`,
     `artifacts.plans`, `parallelism.repair_when`) instead of values.
   - **The changelog step is three mutually exclusive branches**, keyed on
     `changelog.mode`, with the fragment and direct-edit instructions
     physically separated and each carrying its own "do not do the other one"
     line (item 17). `/wurk:mr` step 5 defers to `/wurk:commit` Step 1.6
     rather than restating the modes.
   - **The sabotage protocol did not survive into generic prose** (item 16).
     What generic wurk:commit says is that `gate.rb`'s `data.sabotage.missing`
     is a report, and that what to do about a missing note is project policy
     stated in `.claude/wurk/commit.md`. wurk:implement says the same in its
     verification section. The kit's scan stays - it is a grep for a comment
     shape, and a project with no discipline just gets an empty list.
   - **Forge wording comes from `forge.kind`** and wurk:mr says "the request"
     wherever PR/MR does not matter, naming the CLI only at the create step
     (item 8). Nothing in it assumes GitHub.
   - **The plan-critic open question is settled**: findings stay
     conversational, and a finding the author *declines* gets written into
     the plan document (in "What We're NOT Doing" or the phase it concerns),
     not onto the bead. Bead notes are the `--loop` state channel that
     `work_state.rb` reads; review chatter there dilutes a channel with one
     job. The plan document is also what the implementer actually reads.
   - **The spawn budget is stated as three layers** in wurk:implement
     (orchestrator, phase subagent, one leaf) with `wurk-gate-reader`
     explicitly a leaf, so handing it a red gate in `--loop` mode does not
     silently become a fourth layer.
   - **First-commit-is-.gitignore did not port** (item 18), as planned.
   - **wurk:iterate does not restate the plan template or the phase sizing
     rule**; it links to `/wurk:plan` by name. Two copies of a template drift,
     which is the failure this whole repo exists to end.

   **Step 2 outcome notes (second half, 2026-08-08).** The remaining seven
   landed: wurk:branch, wurk:refresh, wurk:cleanup, wurk:work, wurk:next,
   wurk:issue, wurk:release. Kit suite green at 364 runs, 1172 assertions. The
   phase-1 grep pattern plus `statifier`/`predicator`/`fixative`/`mix `/`glab`/
   consumer ADR numbers comes back empty over all seven, and no old skill name
   survives anywhere under `skills/`. Notes:

   - **The schema gained `models.direction`** (item 10), the one stage model
     projects genuinely disagree about (statifier Fable, predicator Opus).
     Default `opus`. `lib/manifest.rb`, its defaults test, and
     `docs/manifest.md` moved together, per the hard rule. Every other stage
     model stays stated in wurk:work's table, because they do not vary.
   - **The `null` release recipe is the refusal path, and an unimplemented
     `kind` takes the same one.** `docs/manifest.md` gained a Release recipes
     section naming the `hex` fields the skill reads. The kit does not validate
     below `release` - only the skill consumes it - and the doc says so.
   - **Not-applicable guards are skill-side reads of `parallelism.model`.**
     `worktree_create.rb` blocks `wrong_parallelism_model` itself, but
     `worktree_refresh.rb`/`worktree_cleanup.rb` have no such guard, so
     wurk:refresh and wurk:cleanup read the manifest and stop before sweeping.
     This follows wurk:commit's existing precedent of reading `changelog.mode`
     from the manifest directly rather than through a script.
   - **`beads-with-forge-projection` refuses rather than half-working**, in
     both wurk:next (promotion at work-start) and wurk:issue (mirroring a
     promoted bead's forge-owned fields). Same stance as `forge.kind: gitlab`
     in the kit: a pickup with no promotion leaves the forge with no issue for
     work that has started, which is the state the topology exists to prevent.
   - **wurk:next is next-issue and next-issues collapsed**, with `n` defaulting
     to 1. The picker, the mandatory title/summary columns, the `n > 4`
     refusal, and the live-workspace collision surface all survived intact; the
     only structural change is that a single-bead pickup is the `n=1` case of
     one document rather than a second one.
   - **The atomic-claim fold-in did not land - see the carried item below.**
   - **`bd close` still appears in exactly one skill** (wurk:cleanup, step 4),
     as a literal instruction, with the banned-operation reasoning intact.

   Carried forward out of step 2:

   - **Atomic claim in auto mode is still owed** (the predicator fold-in).
     `bd ready --claim --json` cannot simply be passed through
     `select_batch.rb`: candidates are listed, surveyed for collisions, and
     given verdicts *before* the greedy walk picks any, so claiming at listing
     time would claim beads the walk then skips. Closing the read-then-claim
     window properly is a kit change with a design question in it (claim
     inside the walk, or claim-then-release the losers), not a prose fold-in.
     wurk:next currently keeps the select-then-claim path with the
     `bd_claim_failed` fallback - which is correct behavior, just one race
     window wider than predicator's. Do it as its own bead - **`wu-z6n`**.

   **Material extracted for statifier's extension files** (step 7 writes
   them; the source is still live in `st-urc` until then):

   | Extension file | What goes in it |
   |---|---|
   | `wurk/commit.md` | the sabotage protocol and its commit-refusal condition; the changelog-fragment detail beyond the mode (the "v2 differs from v1" narrowing, the generated-corpus exemption); ratchet notes; the `2.0.0-dev` no-bump rule; ADR-0011 ledger citations |
   | `wurk/mr.md` | the ADR judge step (`mix quality --profile merge`, skip is pushable, a finding is a hard refuse); the rebase-merge-only note if it is not already CLAUDE.md's |
   | `wurk/plan.md`, `wurk/iterate.md` | corpus/ratchet success criteria; the Appendix D pseudocode rule; the `## Corpus/Ratchet Notes` optional section; the SCXML-element / interpreter-feature / refactoring common patterns |
   | `wurk/implement.md` | the sabotage protocol in full (mutation kinds, the exemption note grammar, the corpus exemption); the "diff against Appendix D first" debugging move; errors-as-events and effects-out rules |
   | `wurk/research.md` | the pipeline-layer vocabulary; the `../statifier` v1 reference-checkout guidance |

3. Move the six agents to `agents/`, renamed with a `wurk-` prefix
   (hyphen, not colon: agent names allow only lowercase letters and
   hyphens; `:` is reserved for plugin identifiers and a name containing
   one silently fails to load). The `thoughts-*` pair is additionally
   renamed to `docs-*`: "thoughts" was upstream-lineage naming that only
   fixative's directory layout still matches, while the agents' actual job
   is locating/analyzing project documents (research, plans, ADRs)
   wherever the manifest's `artifacts.*` points. Do not confuse them with
   the end-user documentation skills (write-doc/audit-doc/diataxis) - the
   descriptions should say "project research/plan/ADR documents"
   explicitly. Four agents port otherwise verbatim; wurk-docs-locator and
   wurk-docs-analyzer get the layered path resolution from item 9
   (prompt-supplied roots > manifest read > conventional glob). Keep their
   frontmatter model pins (sonnet) and read-only tool lists unchanged.
   Add a `color` to each - the field accepts only
   `red|blue|green|yellow|purple|orange|pink|cyan`; the assignment below
   approximates the Embark theme palette:

   | Agent | color | Embark hue it stands in for |
   |---|---|---|
   | wurk-codebase-locator | cyan | #91DDFF |
   | wurk-codebase-analyzer | purple | #A37ACC |
   | wurk-codebase-pattern-finder | green | #A1EFD3 |
   | wurk-docs-locator | pink | #F48FB1 |
   | wurk-docs-analyzer | orange | #F2B482 |
   | wurk-web-search-researcher | yellow | #FFE6B3 |
   | wurk-gate-reader (new) | red | #F02E6E (Embark's error red) |
   | wurk-plan-critic (new) | blue | #65B2FF |

   Two NEW agents join the six ported ones. The bar for a wurk agent:
   it absorbs noisy context the orchestrator should not carry, or it
   provides independent judgment that must not share context with the
   author. Deterministic work goes to kit scripts instead - never create
   an agent for something a script does reliably.

   - **wurk-gate-reader** (read-only: Read, Grep, Glob, Bash for the gate
     command only). Ingests COMPLETE failing-gate output - honoring the
     never-truncate rule without spending the working session's context -
     and returns: failing stages, root cause per failure, which failures
     share a cause, and what to look at first. At gate-contract tier 1 it
     reads the report JSON; at tier 0 it works from raw log (where it
     earns its keep most - that is all fixative will have). Invoked by
     wurk:commit, wurk:implement, and wurk:mr whenever a gate run comes
     back red and the output is more than trivially small.
   - **wurk-plan-critic** (read-only: Read, Grep, Glob). Adversarial
     review of a drafted plan BEFORE presentation, spawned by wurk:plan
     (and wurk:iterate after substantive edits) with fresh context -
     deliberate blindness to the authoring conversation is the point.
     Checks what `plan_state.rb validate` cannot: phases genuinely
     independently committable and gate-verifiable, success criteria
     actually verifiable, no contradiction with accepted ADRs, no
     unresolved open questions, extension-file requirements present
     (e.g. corpus/ratchet steps where the project's wurk/plan.md demands
     them). Reports findings; the authoring session judges them. This
     generalizes the ADR judge's adversarial insight upstream from merge
     time to plan time.

   The agent renames join the cross-reference checklist: every ported
   skill that names a subagent (research, plan, iterate, work) must use
   the `wurk-` names, and the consumer repos' old agent files are deleted
   at their adoption phase so the unprefixed names stop resolving.

   **Step 3 outcome notes (2026-08-08).** All eight agents live in
   `agents/`, named and colored exactly per the table above. Every
   `wurk-*` name referenced anywhere under `skills/` resolves to a file,
   and no old agent name survives there. Kit suite still green (364 runs,
   1172 assertions). Three notes:

   - **"Four agents port otherwise verbatim" was wrong.** Only
     wurk-web-search-researcher was close (one `site:` example naming a
     consumer's spec host and package docs). The other three codebase
     agents each carried a substantial project-specific block - a
     "Project Layout" section, a "Project Context" section naming the
     pipeline and its invariants, and pattern categories written in one
     consumer's domain vocabulary. The hard rule forbids all of it in
     generic prose, so each gained an **Orienting** section instead:
     prompt-supplied context first, then the repo's own `CLAUDE.md` /
     `README.md` / architecture docs, then a directory listing. Same
     layered shape as item 9's resolution for the docs pair, and the same
     reasoning - an agent that must guess should say it guessed. The
     project vocabulary these sections used to hardcode is already slated
     for the consumers' `wurk/research.md` and `wurk/plan.md` extensions
     (step 2's extraction table), which the invoking skill reads and
     passes down. Illustrative code in the output-format blocks was
     replaced with `<file>:<line>` placeholders rather than a different
     project's real code.
   - **wurk-gate-reader's Bash tool is fenced in prose**, since the tool
     list cannot express "the gate command only". It names the permitted
     invocations (the kit's `gate.rb`, the manifest's `gate.*` commands,
     read-only git and `cat`) and bans the rest, with an explicit refusal
     to re-run the gate scoped/quick/profiled to get a cleaner signal -
     that would manufacture exactly the false green the gate contract's
     "a scoped green is not a green" rule exists to prevent. It also
     restates that it is a leaf and spawns nothing (the three-layer spawn
     budget), and that a red gate guard is reported, never worked around.
   - **wurk-plan-critic explicitly does not re-check the nine sections** -
     `plan_state.rb validate` has already run by the time it is spawned,
     and a critic that spends its review re-reporting a validator's output
     trains the author to skim it. Its seven checks are the ones a
     validator cannot make. It records nothing anywhere, per the settled
     open question: findings are conversational, and the bead stays the
     loop's state channel.
4. **`wu-k9j`.** Write `install.rb` (stdlib-only): symlink each `skills/wurk:*` dir and
   each `agents/*.md` into `~/.claude/`; idempotent; `--dry-run`; refuses
   to overwrite non-symlink entries; `--uninstall` removes only symlinks
   that point into this repo.
   **Step 4 outcome notes (2026-08-08).** `install.rb` at the repo root, 2.6-
   compatible stdlib Ruby, no shell-out at all (symlinks are `File.symlink`;
   `lib/sh.rb` is a kit concern and the installer is not a kit script). Notes:

   - **Plain-text output, not the JSON envelope.** The envelope contract
     governs scripts a skill runs and a model reads. This one is run by a
     human at a shell once per machine, so it prints lines and exits 0/1/2
     (2 for usage, matching the kit's convention). The header says so, since
     the divergence is the first thing a reader will question.
   - **The plan is computed before anything is touched**, which is what makes
     `--dry-run` exact rather than a narrated guess: the same action list is
     printed either way and only `apply` executes.
   - **Four destination states, one refusal.** Already-our-symlink is a
     no-op; a symlink pointing elsewhere *inside this repo* is silently
     re-pointed (a renamed skill); a symlink pointing outside the repo and
     any non-symlink entry are refused by name and left alone, exit 1. The
     symlink test runs before `File.exist?` - a broken link is invisible to
     `exist?` and would otherwise look absent and then fail `EEXIST`.
   - **`--uninstall` works from what is installed, not from what the repo
     ships**, so a link left behind by a since-renamed skill is removed too.
     It only unlinks symlinks resolving inside this repo; foreign entries in
     the same directories survive untouched.
   - **`--home DIR`** exists so the scratch-HOME proof is a flag rather than
     an `env` incantation. Nothing reads a username: repo root from
     `__dir__`, destination from `$HOME` (item 22).
   - **Verified live against a scratch HOME**: dry-run, install (2 mkdir, 22
     link), idempotent re-run (22 ok), then seeded conflicts - a real
     directory, a symlink to `/etc/hosts`, a stale in-repo link, a link for
     a skill the repo no longer ships, and an unrelated foreign entry. The
     run relinked the stale one, refused the other two by name, exited 1, and
     changed nothing else; uninstall then removed exactly 21 links and left
     the three foreign/non-symlink entries. Exit codes checked for usage
     error and unexpected argument. A dry-run against the real `$HOME` is
     clean (22 links, no conflicts) - the actual install on this machine is
     `wu-902`'s check.
   - **No test file.** The kit suite is this repo's gate and it must stay
     self-contained: a test under `skills/wurk:kit/` reaching up to
     `../../../install.rb` is the exact coupling step 1 removed from
     `plan_state_test.rb`, and a second root-level suite would fork the gate
     command. Left as a knowing gap - the verification above is manual.
5. **`wu-em8`.** Wurk repo hygiene: update README status, CLAUDE.md gate command, and
   docs/manifest.md (loader is now authority).

Steps, statifier side (a bead + branch there):

6. **`wu-off`.** Confirm no live worktrees (item 5).
7. **`wu-off`.** Delete ported skills, scripts, and agent files; keep `wurk.json`,
   `.claude/wurk/*.md` extensions (write them in this step from the
   material extracted in step 2), and settings.json.
8. **`wu-s36`.** Gate rewiring - HUMAN-GATED (items 1-3): remove/retarget the
   `Script tests` stage in `.quality.exs`; narrow the ADR judge scope to
   `.claude/wurk/**`; adjust `gate.paths` in wurk.json. Present the
   `.quality.exs` diff and the ledger entry draft to the user; the ledger
   entry in `docs/quality-gate-changes.md` is the human's to write.
9. **`wu-1oo`.** Write the statifier ADR recording the move (skills/scripts now live in
   wurk; gate scope narrowed; extension surface is what remains judged).
10. **`wu-cgw`.** Update statifier CLAUDE.md (skill names in the authority table and
    loop paragraph), docs/workflow.md, docs/skill-automation.md, and any
    ADR text naming old paths (cross-reference checklist).

Definition of done (**`wu-902`**):
- Wurk suite green standalone on system Ruby.
- `install.rb` run on this machine; `ls -la ~/.claude/skills` shows the
  wurk symlinks; `/wurk:commit` etc. resolve in a statifier session.
- Statifier full gate green post-slimming (with the human ledger entry in
  place).
- One real bead driven end-to-end in statifier: wurk:next -> worktree ->
  wurk:work -> wurk:commit -> wurk:mr (stop before push unless asked).
- `git grep` in statifier shows no references to the deleted skill names
  outside history/ADR prose that intentionally records them.

### Phase 3: predicator-ex adoption (`wu-4tq`)

1. Write predicator's `.claude/wurk.json`: `px-` prefix, its worktree dir
   and tmux session, its area vocabulary, gate commands (no report? verify:
   predicator has ex_quality JSON - tier 1 yes, `gate.verify` attest no),
   changelog mode `keep-a-changelog` direct, hex release recipe
   (`version_file: mix.exs`, README pin format, CHANGELOG promotion rule),
   Direction model = opus (item 10).
2. Write its extension files: `wurk/plan.md` + `wurk/iterate.md` +
   `wurk/research.md` (ISA Impact sections, sibling Ruby/JS port guidance),
   `wurk/work.md` (ISA sizing rule), `wurk/commit.md` (ISA-bump analysis,
   direct-CHANGELOG warning), `wurk/release.md` (hex recipe detail,
   `mix hex.publish` has no trigger ever).
3. Delete its 14 skills and 6 agents; keep ADR-0008 deny rules; add the
   `bd prime` SessionStart hook (item 6). Do not port settings.local.json
   noise (item 20).
4. Update predicator CLAUDE.md and docs for names/paths (cross-reference
   checklist); a short predicator ADR for the adoption if its ADR practice
   expects one.

Definition of done:
- Predicator full `mix quality` green.
- One bead end-to-end there (as in phase 2).
- A diff review confirming nothing predicator-only was lost: its skills
  were the pre-extraction reference implementation; anything in them that
  is neither in wurk nor in an extension file is either deliberately
  dropped (say so, in the phase's report) or a bug.

### Phase 4: fixative (`wu-4wl`; design now, build when wanted)

1. Verify fixative's actual bead prefix and id shape from its `.beads/`
   config before writing the manifest (survey did not capture it).
2. Gate: tier 0 via `mise run quality` / `quality:quick`; collapse
   `/commit`'s legacy raw cargo/xcodebuild commands onto the mise wrapper;
   optional tier 1 later (quality.sh emits the report JSON).
3. Parallelism: implement `branch-in-place` in wurk:branch (guards in
   refresh/cleanup report not-applicable); `post_branch` runs the
   xcodegen/dev-icon/Dock chain.
4. Forge: implement `gitlab` in `pr_state.rb` (glab mr list), `permalinks.rb`
   (GL URL format), wurk:mr (MR wording, `--label agent-filed`, `in_review`
   bead status, `Closes #NN`), wurk:commit (`(GL-NN)` subject tags,
   conventional `type(package):` mode with the package map).
5. Tracker topology: implement `beads-with-forge-projection` - promotion at
   work-start (`glab issue create` + `external_ref` stamp), reconcile closed
   GL issues, stale-claim reaping; extracted once into wurk:next/wurk:issue
   (replacing the verbatim duplication in fixative's next-issue and
   update-issue).
6. Release: xcode-app recipe for wurk:release (MARKETING_VERSION edit,
   xcodegen regen, per-package changelog promotion, no-Closes-line rule).
7. Extensions: `wurk/plan.md` + `wurk/implement.md` (UniFFI pipeline,
   SwiftUI privacy modifiers by threat class, never-truncate xcbeautify
   note), keep `.claude/diataxis.md` as-is (different skill family).
8. Delete its 10 skills and 6 agents; reconcile hooks (it has dolt
   pull/push hooks; keep, and add `bd prime` if wanted).

Definition of done:
- One GL-tracked item driven end-to-end in fixative (through MR-open,
  stopping before merge unless asked).
- The reconcile logic exists exactly once.
- No wurk generic skill gained a fixative-specific line (extensions and
  manifest absorbed it all) - grep for "xcodegen", "UniFFI", "glab" in
  `skills/` generic prose.

## Per-project agents are part of the extension story

The manifest/extension split (ADR-0004) applies to agents too: a consumer
repo's `.claude/agents/` remains the home for domain agents that would
never generalize - e.g. a statifier sabotage auditor (verify every new
test carries its mutation note), a predicator ISA-drift checker, a
fixative privacy-modifier auditor. Wurk skills must tolerate their
presence (they are additive) but never depend on any of them. The same
bar applies as for wurk's own agents: noisy-context absorption or
independent judgment; scripts for anything deterministic. None of these
example agents is scheduled work - they are the documented pattern for
where such a thing goes when a project wants it.

## Backlog (after phase 4; not scheduled)

Deliberately not beads yet. A backlog item becomes a bead when someone
intends to do it; filing five speculative beads just makes `bd ready`
noisier without making any of them likelier to happen.

- **wurk-conflict-scout** (agent): when refresh/mr abort on a rebase
  conflict, a read-only agent examines the captured conflict and reports
  scope and likely difficulty ("both sides touched the exit-set logic;
  theirs is a rename, yours is behavioral; ~10-minute manual merge") so
  the human gate is an informed one. Authority unchanged: it never
  resolves anything.
- **wurk:init** (skill): onboarding for future projects - survey a repo
  (toolchain, forge, test commands, doc layout, tracker state), draft its
  `.claude/wurk.json` and extension stubs, then walk the user through the
  structural choices (parallelism model, changelog mode, topology). This
  is the "future projects" half of the original goal; nothing else in the
  plan owns it.
- Tier-1 gate report emitter for fixative (docs/gate-contract.md).
- A one-line human summary on stderr from kit scripts (presentational;
  stdout contract unchanged).
- A wurk-side ADR judge over this repo's ADRs (explicitly out of scope
  for phases 1-4).

## Risks and rollback

- Every consumer keeps its full pre-adoption skill set in git history;
  rollback in a consumer = revert the adoption commit(s) + `install.rb
  --uninstall`. Wurk symlinks and project skills can also coexist briefly
  (different names), which is what makes the transition safe.
- The highest-risk step is phase 2's statifier gate rewiring (items 1-3):
  it is the one place where a mistake silently weakens a gate. It is
  human-gated by design; do not batch it with mechanical deletions in one
  commit.
- The seeded-session templates (item 4) are the easiest silent breakage:
  test by actually opening a worktree window after each phase-2/3 cutover.
- Second-machine risk (item 22): after phase 2, do one clone + install.rb
  on a second machine (or a scratch HOME) to prove nothing assumes this
  machine's paths.

## Open questions (settle during the phase that hits them)

- Manifest resolution rule (phase 1 step 2): leaning walk-up from
  `git rev-parse --git-common-dir`; record the decision in docs/manifest.md.
- Whether statifier keeps `.claude/wurk/` inside its judged/gated surface
  (phase 2 step 8) - leaning yes for extensions, since they steer agent
  behavior exactly like skills did.
- Alias shims per repo (item 14): leaning none; retrain.
- Whether predicator wants an adoption ADR (phase 3 step 4).
- Fixative bead prefix and whether its `update-issue` survives as a
  fixative-only extension of wurk:issue or disappears into topology mode
  (phase 4 steps 1, 5).
- ~~Whether wurk-plan-critic findings should be recorded on the bead~~
  **Settled in phase 2 step 2: conversational, with declined findings written
  into the plan document.** See the step 2 outcome notes.

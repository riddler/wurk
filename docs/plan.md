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

No behavior change; statifier keeps working exactly as today, but reads its
constants from a manifest. All work happens in statifier-ex on a normal
issue branch (create a bead for it), gated by its own `mix quality`.

Steps:

1. Add `.claude/wurk.json` holding statifier's current values (schema:
   `docs/manifest.md`). Validate it against the schema doc by hand; the
   loader (step 2) becomes the mechanical check.
2. Add `lib/manifest.rb` to `.claude/scripts/lib/`: locate the manifest by
   walking up from `git rev-parse --git-common-dir` (decision: record the
   final rule in docs/manifest.md), parse with stdlib JSON, validate
   (unknown keys warn, missing required keys block naming the field, enum
   fields reject unknown values), expose typed accessors, provide a
   `manifest.rb check` CLI subcommand emitting the standard envelope. Tests
   use fixture manifests under `test/fixtures/manifests/`.
3. Convert scripts one at a time, each with its test updates in the same
   commit. Conversion table (script -> manifest fields consumed):

   | Script | Fields | Notes |
   |---|---|---|
   | `lib/refs.rb` | `beads.prefix` | regex built from prefix; trailer key from `commits` (item 12) |
   | `lib/areas.rb` | `beads.areas.*` | vocabulary, lands_alone, always_batchable |
   | `lib/touches_elixir.rb` | `gate.paths` | rename to `gate_paths.rb`; keep a deprecation note; item 3 |
   | `lib/beads.rb` | (none new) | confirm loop-note grammar is name-free (item 7) |
   | `lib/summary.rb` | (none) | generic |
   | `gate.rb` | `gate.full/loop/report/attest` | tier detection per docs/gate-contract.md; absent report/attest -> degraded, not error |
   | `rebase_onto.rb` | `parallelism.repair_when/repair` | Elixir repair becomes data |
   | `repo_state.rb` | via gate_paths, refs | |
   | `worktree_create.rb` | `parallelism.worktrees_dir/warm_clone/warm`, `gate.loop` | |
   | `worktree_refresh.rb` | `gate.moving_files`, `gate.loop` | add `coveralls.json` to statifier's value (best-of-both) |
   | `worktree_cleanup.rb` | via refs, worktrees_dir | |
   | `worktree_survey.rb` | `forge.kind` (gh only) | item 8 |
   | `pr_state.rb` | `forge.kind` | gitlab value errors clearly until phase 4 |
   | `permalinks.rb` | `forge.kind` | URL format per forge |
   | `tmux_window.rb` | `tmux.session/model` | derive main repo path from git-common-dir (item 22); templates still name old skills until phase 2 (item 4) |
   | `select_batch.rb` | via areas, refs | re-verify beads#5358 (item 11) |
   | `bead.rb` | via refs | |
   | `commit_message.rb` | `commits.*` | item 12 |
   | `doc_meta.rb` | `artifacts.*` | item 13 |
   | `plan_state.rb` | (none) | template grammar is wurk-defined |
   | `work_state.rb` | `artifacts.*` | item 19 |
   | `envelope.rb`/`cli.rb`/`sh.rb` | (none) | untouched |

4. Update `.claude/scripts/README.md`: the manifest is now a documented
   input to the contract; fixture-manifest testing convention.
5. Skill prose: replace hardcoded command strings the skills tell the agent
   to run only where they duplicate what scripts now read from the manifest;
   do NOT restructure skills in this phase (that is phase 2's job).

Definition of done:
- Full `mix quality` green in statifier-ex (script suite included), via
  `mix gate.verify`.
- `git grep -nE 'st-|statifier-ex-worktrees|/Users/johnnyt' -- .claude/scripts`
  returns only `wurk.json`, fixtures, and deliberate deprecation comments.
- `manifest.rb check` passes against the real manifest and fails usefully
  against a broken fixture.
- One end-to-end smoke: create a scratch worktree via `/new-worktree` on a
  trivial bead, confirm seed, gate, and cleanup still work, remove it.

### Phase 2: lift into this repo as wurk

Work happens in BOTH repos: wurk gains its content; statifier slims down.
Sequencing constraint: item 5 (no live worktrees at cutover).

Steps, wurk side:

1. Create `skills/wurk:kit/`: move the scripts + tests; suite runnable as
   `ruby skills/wurk:kit/scripts/test/run.rb`; port the contract test
   unchanged (banned operations are project-independent policy); write
   REFERENCE.md (envelope contract, manifest consumption, recommended
   settings blocks: `bd prime` hook, ADR-0008-style deny rules with their
   documented limits, `/fewer-permission-prompts` note).
2. Port each skill under its wurk name. Per-skill porting notes - for each,
   the split is [generic core] / [to statifier extension `.claude/wurk/*`] /
   [best-of-both fold-in]:
   - **wurk:commit** - generic: gate-run, diff analysis, 5-strategy bead
     ladder, message draft + `commit_message.rb check`, post-commit
     attribution re-verify, `--auto` refusal list. Extension (statifier
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
     contradict an accepted ADR"). Extensions: statifier corpus/ratchet
     success criteria + Appendix D; predicator ISA Impact. Fold-ins: modern
     agent menu, pre-write checklist items, drop the stale `Task(...)`
     example. Skills pass `artifacts.*` paths to agents (item 9).
   - **wurk:implement** - generic: phase-by-phase, `--loop` orchestration
     (subagent per phase, `/wurk:commit --auto` as advancement gate,
     deferred-manual-verification section, loop-note grammar via
     `bead.rb note`), resume from unchecked boxes, 3-layer spawn budget.
     Extension: sabotage protocol. Fold-in: setup points at wurk:branch.
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

   The agent renames join the cross-reference checklist: every ported
   skill that names a subagent (research, plan, iterate, work) must use
   the `wurk-` names, and the consumer repos' old agent files are deleted
   at their adoption phase so the unprefixed names stop resolving.
4. Write `install.rb` (stdlib-only): symlink each `skills/wurk:*` dir and
   each `agents/*.md` into `~/.claude/`; idempotent; `--dry-run`; refuses
   to overwrite non-symlink entries; `--uninstall` removes only symlinks
   that point into this repo.
5. Wurk repo hygiene: update README status, CLAUDE.md gate command, and
   docs/manifest.md (loader is now authority).

Steps, statifier side (a bead + branch there):

6. Confirm no live worktrees (item 5).
7. Delete ported skills, scripts, and agent files; keep `wurk.json`,
   `.claude/wurk/*.md` extensions (write them in this step from the
   material extracted in step 2), and settings.json.
8. Gate rewiring - HUMAN-GATED (items 1-3): remove/retarget the
   `Script tests` stage in `.quality.exs`; narrow the ADR judge scope to
   `.claude/wurk/**`; adjust `gate.paths` in wurk.json. Present the
   `.quality.exs` diff and the ledger entry draft to the user; the ledger
   entry in `docs/quality-gate-changes.md` is the human's to write.
9. Write the statifier ADR recording the move (skills/scripts now live in
   wurk; gate scope narrowed; extension surface is what remains judged).
10. Update statifier CLAUDE.md (skill names in the authority table and
    loop paragraph), docs/workflow.md, docs/skill-automation.md, and any
    ADR text naming old paths (cross-reference checklist).

Definition of done:
- Wurk suite green standalone on system Ruby.
- `install.rb` run on this machine; `ls -la ~/.claude/skills` shows the
  wurk symlinks; `/wurk:commit` etc. resolve in a statifier session.
- Statifier full gate green post-slimming (with the human ledger entry in
  place).
- One real bead driven end-to-end in statifier: wurk:next -> worktree ->
  wurk:work -> wurk:commit -> wurk:mr (stop before push unless asked).
- `git grep` in statifier shows no references to the deleted skill names
  outside history/ADR prose that intentionally records them.

### Phase 3: predicator-ex adoption

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

### Phase 4: fixative (later; design now, build when wanted)

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
- Whether the kit later emits a one-line human summary on stderr alongside
  the JSON envelope (purely presentational; stdout contract unchanged; both
  streams reach the agent). Not scheduled; revisit after phase 3 usage.

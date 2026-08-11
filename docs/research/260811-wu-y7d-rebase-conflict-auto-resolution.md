---
date: 2026-08-11T05:41:03-0600
researcher: Claude
git_commit: 717999bba09bf4efc5c2f399f56862bc5a06159d
branch: wu-y7d-rebase-auto-resolve
repository: wurk
beads_issue: wu-y7d
topic: "Where a bounded auto-resolution path for simple rebase conflicts could live in /wurk:mr and /wurk:refresh, given the kit script contract"
tags: [research, codebase, kit, rebase, mr, refresh]
status: complete
last_updated: 2026-08-11
last_updated_by: Claude
---

# Research: rebase conflict handling in /wurk:mr and /wurk:refresh

**Date**: 2026-08-11T05:41:03-0600
**Git Commit**: 717999bba09bf4efc5c2f399f56862bc5a06159d
**Branch**: wu-y7d-rebase-auto-resolve
**Bead**: wu-y7d

## Research Question

Bead wu-y7d asks for a bounded auto-resolution path for trivially-mergeable
rebase conflicts in `/wurk:mr` and `/wurk:refresh`, and names four design
questions to ground in the code before any design is written:

1. Where does the judgment live, given that `rebase_onto.rb` is a kit script
   under the deterministic contract? What exactly does the script do today,
   what does the abort guarantee, and what would a "leave it conflicted" mode
   make the caller responsible for?
2. What counts as auto-resolvable, and what must always stop? How does the
   repo identify gate-guarded paths today?
3. What is the safety net? Where does the gate run relative to the rebase in
   each skill, and how are the step 6 summary and the request body assembled?
4. Does this belong in both skills or only `/wurk:mr`? How does
   `/wurk:refresh` invoke the rebase, and how much context does it have?

This document records what exists today. It proposes nothing.

## Summary

- **One rebase implementation, two callers.** `RebaseOnto.perform`
  ([`skills/wurk:kit/scripts/rebase_onto.rb:36-83`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L36-L83)) is the only rebase code
  path in the kit. `/wurk:mr` shells out to it as a script
  ([`skills/wurk:mr/SKILL.md:93`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L93)); `/wurk:refresh` reaches it as an in-process
  library call from [`skills/wurk:kit/scripts/worktree_refresh.rb:112`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L112), sharing one `Envelope`.
- **Conflict handling is hardcoded, not manifest data.** On a failed rebase
  the script captures `git diff --name-only --diff-filter=U`, then aborts,
  then `block!`s with `code: "rebase_conflict", needs: "human"`
  ([`skills/wurk:kit/scripts/rebase_onto.rb:49-53`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L49-L53)). There is no flag, no mode, and no manifest field
  anywhere in the schema concerning conflicts, rebase strategy, or
  auto-resolution.
- **The abort's guarantee is the file list, not the tree.** The capture
  precedes the abort because the abort clears the conflict state; a report
  assembled afterward would otherwise have nothing to name
  ([`skills/wurk:kit/scripts/rebase_onto.rb:45-48`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L45-L48)). Its second effect - restoring the worktree to
  exactly its pre-rebase state - is what `/wurk:refresh` reports verbatim as
  `"conflict in <files>, aborted, unchanged"` ([`skills/wurk:kit/scripts/worktree_refresh.rb:116`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L116)).
- **The "no resolve path" is test-enforced at the source level.**
  [`skills/wurk:kit/scripts/test/rebase_onto_test.rb:65-70`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/rebase_onto_test.rb#L65-L70) reads the script's own source and asserts it
  contains no `checkout --ours|--theirs`, no `git add`, and no `rebase
  --continue`. This is a source-text scan, so it constrains the script file
  itself regardless of which mode a flag would select.
- **Judgment is not banned from scripts by the contract test - only the five
  irreversible operations are.** [`skills/wurk:kit/scripts/test/contract_test.rb:30-39`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/contract_test.rb#L30-L39) bans `git push`,
  `gh pr create`, `glab mr create`, `bd close`, `bd edit`, plus writes to
  manifest-declared guarded paths, `system`/backticks, and consumer
  vocabulary. "No model judgment in scripts" is prose policy
  ([`skills/wurk:kit/REFERENCE.md:182-185`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/REFERENCE.md#L182-L185)), and `judge.rb` is the standing
  counter-example of a kit script that calls a model - under a specific
  division of labor set by ADR-0008.
- **The gate is a safety net for code and nothing else.** `gate.rb` runs the
  manifest's `gate.full` only when the changed path set intersects
  `gate.build_paths + gate.also_gated_paths`
  ([`skills/wurk:kit/scripts/lib/gate_paths.rb:40-42`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/gate_paths.rb#L40-L42), [`skills/wurk:kit/scripts/gate.rb:97-112`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/gate.rb#L97-L112)). For this repo those lists
  are `["skills/wurk:kit/scripts/"]` and `[]` (`.claude/wurk.json`), so a
  docs-only resolution reaches `applicable: false` and no gate runs at all.
- **The step 6 summary and the request body are hand-assembled skill prose.**
  No script produces either ([`skills/wurk:mr/SKILL.md:168-183`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L168-L183) and
  `210-224`). Nothing mechanically forces a resolution to appear in them.
- **`/wurk:refresh` has strictly less context than `/wurk:mr`.**
  `worktree_refresh.rb` discards everything the survey knew about a worktree
  except `path` and `branch` ([`skills/wurk:kit/scripts/worktree_refresh.rb:65-66`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L65-L66)), and the sweep is
  a single script invocation with no per-worktree model turn.
- **A prior, narrower idea is already recorded.** [`docs/plan.md:1208-1213`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/plan.md#L1208-L1213)
  lists a `wurk-conflict-scout` agent in the unscheduled backlog: a read-only
  agent that examines a captured conflict and reports scope and difficulty so
  the human gate is an informed one, with "Authority unchanged: it never
  resolves anything."

## Detailed Findings

### 1. What `rebase_onto.rb` does today

`RebaseOnto.perform(path, env, manifest, dry_run:)`
([`skills/wurk:kit/scripts/rebase_onto.rb:36-83`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L36-L83)) is the whole rebase-with-repair
block:

1. `git rev-parse HEAD` records the pre-rebase sha ([`skills/wurk:kit/scripts/rebase_onto.rb:39-40`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L39-L40)).
2. `git rebase <manifest.remote_default_branch>` ([`skills/wurk:kit/scripts/rebase_onto.rb:42`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L42)).
   `remote_default_branch` is `"origin/#{default_branch}"`
   ([`skills/wurk:kit/scripts/lib/manifest.rb:207-211`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/manifest.rb#L207-L211)); the remote name is hardcoded, the branch is
   manifest data.
3. **On failure** ([`skills/wurk:kit/scripts/rebase_onto.rb:44-54`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L44-L54)): capture `git diff --name-only
   --diff-filter=U`, split into a file list, run `git rebase --abort`, then
   `env.block!(code: "rebase_conflict", message: "conflict in <files>",
   needs: "human")`, and return `{status: "conflict", files: files}`.
4. On success: `git rev-parse` the target, and only if
   `manifest.repair_when` is set, `git diff --quiet <before> HEAD --
   <repair_when>` to decide `lock_changed` ([`skills/wurk:kit/scripts/rebase_onto.rb:56-70`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L56-L70)); a moved
   lockfile runs `manifest.repair` and copies warm caches
   ([`skills/wurk:kit/scripts/rebase_onto.rb:72-80`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L72-L80)).

Returned statuses are exactly three: `"rebased"`, `"conflict"`, `"dry_run"`
([`skills/wurk:kit/scripts/rebase_onto.rb:28-31`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L28-L31)).

**The module header states the policy as settled**, [`skills/wurk:kit/scripts/rebase_onto.rb:15-18`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L15-L18):

> A conflict is always blocked with needs: "human", the conflicting files
> named. There is no resolve path - CLAUDE.md's authority table is explicit
> that resolving a rebase conflict unasked is unauthorized, so this script
> does not offer one even as dead code.

The authority table itself lives in the consumer repo's CLAUDE.md, which wurk
defers to and never widens ([`docs/architecture.md:21`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/architecture.md#L21), [`docs/architecture.md:97`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/architecture.md#L97)).

#### What the abort actually guarantees

Two distinct guarantees, only one of which is called out in the comment:

- **The file list survives.** [`skills/wurk:kit/scripts/rebase_onto.rb:45-48`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L45-L48) explains the ordering:
  the abort clears the conflict state, so a report assembled afterward has
  nothing left to name if the order is reversed. [`skills/wurk:kit/scripts/test/rebase_onto_test.rb:41-63`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/rebase_onto_test.rb#L41-L63)
  asserts the recorded call order (capture index < abort index) rather than
  just the resulting data, so the ordering is pinned, not incidental.
- **The worktree is returned to its pre-rebase state.** Nothing in the script
  says this in so many words, but it is what `/wurk:refresh`'s report
  vocabulary asserts to the user: `"conflict in <files>, aborted, unchanged"`
  ([`skills/wurk:kit/scripts/worktree_refresh.rb:116`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L116), echoed in [`skills/wurk:refresh/SKILL.md:84-85`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:refresh/SKILL.md#L84-L85)),
  and what [`skills/wurk:refresh/SKILL.md:113-118`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:refresh/SKILL.md#L113-L118) means by "Aborting leaves
  the worktree exactly as it was."

A mode that leaves the conflict in place therefore surrenders both. The
caller would own (a) aborting on every exit path including error paths, and
(b) the invariant that no worktree is ever left mid-rebase for a later
session or a later sweep iteration to trip over. In `/wurk:refresh`'s case
the sweep continues to the next worktree after a conflict
([`skills/wurk:kit/scripts/worktree_refresh.rb:65-66`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L65-L66) maps over all worktrees; a conflict is a plain
return value from `refresh_one`, not a short-circuit), so "the caller" there
is a script mid-loop rather than a model turn.

#### What is test-enforced about the absence of a resolve path

[`skills/wurk:kit/scripts/test/rebase_onto_test.rb:65-70`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/rebase_onto_test.rb#L65-L70) reads `rebase_onto.rb`'s own source text:

```ruby
refute_match(/checkout\s+--(ours|theirs)/, source)
refute_match(/git\s+add\b/, source)
refute_match(/rebase\s+--continue/, source)
```

[`skills/wurk:kit/scripts/test/rebase_onto_test.rb:175-178`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/rebase_onto_test.rb#L175-L178) additionally refutes `"cp", "-R` and
[`skills/wurk:kit/scripts/test/rebase_onto_test.rb:194-197`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/rebase_onto_test.rb#L194-L197) refutes `--force`. These are file-level source
scans: any resolve mechanics added to this file fail these tests regardless
of whether a flag guards them. They are this script's own tests, not part of
`contract_test.rb`.

#### Where the script contract actually draws its line

[`skills/wurk:kit/scripts/test/contract_test.rb:30-39`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/contract_test.rb#L30-L39) is the complete fixed ban list:

```ruby
BANNED_CALLS = {
  "git push"      => /\bgit\s+push\b/,
  "gh pr create"  => /\bgh\s+pr\s+create\b/,
  "glab mr create"=> /\bglab\s+mr\s+create\b/,
  "bd close"      => /\bbd\s+close\b/,
  "bd edit"       => /\bbd\s+edit\b/
}.freeze
```

plus manifest-declared guarded writes ([`skills/wurk:kit/scripts/test/contract_test.rb:103-113`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/contract_test.rb#L103-L113)),
`system`/backticks ([`skills/wurk:kit/scripts/test/contract_test.rb:116-122`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/contract_test.rb#L116-L122)), non-interactive flags on
`cp`/`rm`/`mv` ([`skills/wurk:kit/scripts/test/contract_test.rb:126-136`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/contract_test.rb#L126-L136)), consumer vocabulary
([`skills/wurk:kit/scripts/test/contract_test.rb:153-169`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/contract_test.rb#L153-L169)), hardcoded default-branch refs
([`skills/wurk:kit/scripts/test/contract_test.rb:181-195`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/contract_test.rb#L181-L195)), and shebang/executable bit
([`skills/wurk:kit/scripts/test/contract_test.rb:360-368`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/contract_test.rb#L360-L368)). A drift check re-reads ADR-0006's banned-op
paragraph on every run ([`skills/wurk:kit/scripts/test/contract_test.rb:442-460`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/contract_test.rb#L442-L460)), so widening the ban list
means editing both the ADR and the rules.

None of those rules mentions model judgment. The rule against it is prose,
[`skills/wurk:kit/REFERENCE.md:182-185`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/REFERENCE.md#L182-L185):

> The banned list is the mechanical floor, not the whole story: judgment
> calls (phase sizing, `bd close` triggers, a project's own testing protocol)
> stay in skill prose and extension files even where scripting them is
> technically possible.

#### The one kit script that does call a model

`judge.rb` (`skills/wurk:kit/scripts/judge.rb`) is the shipped precedent for
model judgment reached from inside `scripts/`, and its header states the
division of labor explicitly ([`skills/wurk:kit/scripts/judge.rb:10-20`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/judge.rb#L10-L20)): "the script owns diff
plumbing and prompt assembly, the model owns the verdict, and the skill prose
consuming its output owns what to do about a finding." Mechanically it:

- reads its registry from the manifest (`judge.judge_registry`,
  [`skills/wurk:kit/scripts/lib/manifest.rb:442-444`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/manifest.rb#L442-L444)) so the script itself names no scope, no judged
  text, and no violation rule ([`skills/wurk:kit/REFERENCE.md:302-312`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/REFERENCE.md#L302-L312));
- shells the `claude` CLI through `Sh.run` with `--tools "" --strict-mcp-config`
  and a 300s timeout ([`skills/wurk:kit/scripts/judge.rb:145-148`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/judge.rb#L145-L148));
- makes one propose call and one independent refute call per candidate
  ([`skills/wurk:kit/scripts/judge.rb:278-295`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/judge.rb#L278-L295));
- parses fail-closed at every step - unparseable propose is "no candidates",
  unparseable or ambiguous refute is "not a violation"
  ([`skills/wurk:kit/scripts/judge.rb:190-212`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/judge.rb#L190-L212));
- reports a survivor as `block!(code: "judge_finding", needs: "human")`
  ([`skills/wurk:kit/scripts/judge.rb:294`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/judge.rb#L294));
- reports a skip with a named reason rather than a silent pass:
  `no_registry`, `no_cli`, `no_base_ref`, `no_scoped_changes`
  ([`skills/wurk:kit/scripts/judge.rb:220-245`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/judge.rb#L220-L245), [`skills/wurk:kit/scripts/judge.rb:297-301`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/judge.rb#L297-L301));
- is wired in through the consumer's extension file, not the generic skill
  (`.claude/wurk/mr.md:1-27`);
- is never exercised with a real model call in the suite - `FakeSh` is the
  backstop ([`skills/wurk:kit/REFERENCE.md:342-348`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/REFERENCE.md#L342-L348)).

ADR-0008 states the shape as a decision: the judge runs at the merge seam,
deliberately outside the required deterministic gate, which must stay
offline, zero-network, zero-spend
([`docs/adr/0008-merge-time-judge-over-generic-skill-prose.md:64-69`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/adr/0008-merge-time-judge-over-generic-skill-prose.md#L64-L69),
[`docs/architecture.md:119-120`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/architecture.md#L119-L120)).

#### The judge's own scope covers this bead's likely edits

`.claude/wurk.json`'s single registry entry scopes to `skills/` +
`SKILL.md` and focuses on:

> a step that used to state a policy call, a human gate, or a verification
> discipline now handing it to a script, or deleted during a rewrite rather
> than restated - including prose that turns a discipline into a check on its
> own artifact

[`skills/wurk:mr/SKILL.md:104-115`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L104-L115) is exactly such a stated human gate. Any
branch editing it runs through `judge.rb` at merge time via
`.claude/wurk/mr.md`, and a surviving finding refuses the request
(`.claude/wurk/mr.md:13-19`).

### 2. What the repo can identify mechanically about a path

`lib/gate_paths.rb` holds two deliberately different predicates:

- `touches_build?(paths)` - `match?(paths, manifest.gate_build_paths)`
  ([`skills/wurk:kit/scripts/lib/gate_paths.rb:36-38`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/gate_paths.rb#L36-L38)). Reported by `repo_state.rb:128,146` as
  `data.touches_build`.
- `gate_applicable?(paths)` - `match?(paths, manifest.gate_build_paths +
  manifest.gate_also_gated_paths)` ([`skills/wurk:kit/scripts/lib/gate_paths.rb:40-42`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/gate_paths.rb#L40-L42)). Used by `gate.rb`
  and by `/wurk:commit` Step 0 / `/wurk:mr` step 4's carve-out.

The matching rule is one line and has no globbing ([`skills/wurk:kit/scripts/lib/gate_paths.rb:44-51`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/gate_paths.rb#L44-L51)):

```ruby
entry.end_with?("/") ? path.to_s.start_with?(entry) : path.to_s == entry
```

An entry ending in `/` is a directory prefix; anything else is an exact path
match. The comment states the rationale: a glob dialect is a second thing to
get right in every consumer repo, and every value these lists have ever held
is one of these two shapes.

For this repo (`.claude/wurk.json`):

```json
"build_paths": ["skills/wurk:kit/scripts/"],
"also_gated_paths": [],
"moving_files": []
```

So `docs/plan.md` - the file in the motivating incident - matches neither
list. A conflict confined to it is, by this repo's own manifest, a path the
gate does not measure.

**`gate.moving_files` has no production consumer.** `manifest.gate_moving_files`
is defined ([`skills/wurk:kit/scripts/lib/manifest.rb:279-281`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/manifest.rb#L279-L281)) but is read only by test
infrastructure: [`skills/wurk:kit/scripts/test/support/manifest_helper.rb:73-85`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/support/manifest_helper.rb#L73-L85) unions it with
`gate.guard_ledger` across all fixture manifests to feed
`contract_test.rb`'s guarded-writes scan. [`docs/plan.md:430`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/plan.md#L430) notes this
outright: "`gate.moving_files` **has no consumer**". `/wurk:refresh`'s prose
also names it as a trigger for running a sweep
([`skills/wurk:refresh/SKILL.md:127-131`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:refresh/SKILL.md#L127-L131)), which is a human instruction, not a
code path.

`gate.guard_ledger` is read by [`skills/wurk:kit/scripts/gate.rb:310`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/gate.rb#L310) for the gate-guard stage, and
`gate.rb` never writes it ([`skills/wurk:kit/REFERENCE.md:298-300`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/REFERENCE.md#L298-L300)).

**There is no lockfile predicate beyond `parallelism.repair_when`**
([`skills/wurk:kit/scripts/lib/manifest.rb:344-346`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/manifest.rb#L344-L346)), a single path string used only to decide whether
a rebase moved the lockfile. This repo sets no `parallelism.repair_when` at
all - the `parallelism` block in `.claude/wurk.json` carries only `model`,
`worktrees_dir`, and `post_branch` - so `lock_changed` is always false here.

**There is no manifest field for conflict policy.** Grepping
`lib/manifest.rb` and `docs/manifest.md` for `conflict`, `rebase`, and
`auto_resolve` returns nothing. `KNOWN` ([`skills/wurk:kit/scripts/lib/manifest.rb:65-82`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/manifest.rb#L65-L82)) is the full
recognized key surface; unknown keys warn but never block
([`skills/wurk:kit/scripts/lib/manifest.rb:670-685`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/manifest.rb#L670-L685), [`docs/manifest.md:395-403`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/manifest.md#L395-L403)). [`docs/manifest.md:3-6`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/manifest.md#L3-L6)
states `lib/manifest.rb` is the authority and the doc follows in the same
commit.

### 3. The safety net: where the gate runs, and what assembles the report

#### In `/wurk:mr`

Order is fixed and the reason is stated ([`skills/wurk:mr/SKILL.md:85-92`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L85-L92)):
rebase happens in step 3, before the gate in step 4, because "the gate ...
only means something if it attests to the tree that will actually merge"; and
rebasing between the summary (step 6) and the push (step 7) would invalidate
the attestation.

Step 4 ([`skills/wurk:mr/SKILL.md:123-157`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L123-L157)) runs `gate.rb` and refuses on red.
Two ways the gate does not attest to a resolution:

- **The carve-out.** `gate.rb:311,327-328` sets `data.applicable` from
  `gate_applicable?` over `git diff --name-only <default_branch>...HEAD` plus
  `git status --porcelain` ([`skills/wurk:kit/scripts/gate.rb:97-112`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/gate.rb#L97-L112)), and
  `data.carve_out_reason` names the union of both path lists
  ([`skills/wurk:kit/scripts/gate.rb:232-235`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/gate.rb#L232-L235)). When not applicable and not `--profile loop`,
  [`skills/wurk:kit/scripts/gate.rb:335-346`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/gate.rb#L335-L346) short-circuits: no gate command runs, `stages` is `[]`.
  [`skills/wurk:mr/SKILL.md:146-157`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L146-L157) instructs the skill to skip it and say so
  "so a skipped gate is never mistaken for a green one."
- **Skip classification.** `data.skipped_stages` entries carry a
  `classification`; `run_level` has already made the gate red, `project_level`
  does not block but must be named in the request body and final report,
  `not_applicable` neither blocks nor needs naming
  ([`skills/wurk:mr/SKILL.md:139-145`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L139-L145)).

A docs-only branch in this repo hits the carve-out. So for the file class the
bead names as most likely to qualify as "simple", there is no gate at all
behind the resolution.

The project extension adds `judge.rb` after step 4 and before step 6
(`.claude/wurk/mr.md:1-8`) - the only additional automated check on this
branch's skill prose.

#### In `/wurk:refresh`

The gate is per-worktree and it is the **loop** gate, not the full one:
`confirm_green` runs `manifest.gate_loop` in the worktree after a successful
rebase ([`skills/wurk:kit/scripts/worktree_refresh.rb:125-131`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L125-L131)), producing `"red"` or `"rebased onto
<sha>, lock unchanged|repaired, loop green"`. A worktree that conflicted never
reaches `confirm_green` at all ([`skills/wurk:kit/scripts/worktree_refresh.rb:114-122`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L114-L122)). Note also
that `gate.rb`'s carve-out is deliberately bypassed under `--profile loop`
([`skills/wurk:kit/scripts/gate.rb:330-334`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/gate.rb#L330-L334)), but `worktree_refresh.rb` runs `manifest.gate_loop`
directly as a command rather than going through `gate.rb`.

#### How the step 6 summary and the request body are assembled

Both are model-written prose, from a literal template in the skill. No script
emits either.

- **Step 6 summary** - the fenced block at [`skills/wurk:mr/SKILL.md:172-183`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L172-L183),
  with a `Rebased:` line already reading either "already current, no commits
  replayed" or "onto <sha>, N commits replayed", fed by `data.target`,
  `data.lock_changed`, `data.repaired` from step 3
  ([`skills/wurk:mr/SKILL.md:106-108`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L106-L108)).
- **Request body** - the four bullets at [`skills/wurk:mr/SKILL.md:212-223`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L212-L223):
  Why / What / Notes ("anything surprising, deliberately deferred, or worth a
  second opinion, plus which gate ran") / the close lines.
- **Final report** - the block at [`skills/wurk:mr/SKILL.md:248-254`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L248-L254).

`lib/summary.rb` is unrelated: it truncates a bead description to one line for
`select_batch.rb`'s candidate table ([`skills/wurk:kit/scripts/lib/summary.rb:1-8`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/summary.rb#L1-L8)).

`/wurk:refresh`'s report is likewise prose: a table using
`data.results[].result` verbatim ([`skills/wurk:refresh/SKILL.md:92-104`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:refresh/SKILL.md#L92-L104)), with
the standing rule "Silence about a skipped worktree reads as success - name
every one."

### 4. How `/wurk:refresh` invokes the rebase, and what context it has

`/wurk:refresh` is one script invocation for the entire sweep
([`skills/wurk:refresh/SKILL.md:53-66`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:refresh/SKILL.md#L53-L66)):

```bash
ruby ~/.claude/skills/wurk:kit/scripts/worktree_refresh.rb [name]
```

Inside `worktree_refresh.rb`:

- `enumerate` runs `WorktreeSurvey.run` in-process and reads
  `data.worktrees` ([`skills/wurk:kit/scripts/worktree_refresh.rb:74-92`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L74-L92)). Survey entries carry
  `path, branch, bead, areas, dirty, ancestor_of_origin_main, pr, stale,
  holds_areas` ([`skills/wurk:kit/scripts/worktree_survey.rb:170-180`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_survey.rb#L170-L180)).
- One `git fetch origin` for the whole sweep; failure blocks everything as
  `offline` ([`skills/wurk:kit/scripts/worktree_refresh.rb:46-57`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L46-L57)).
- The per-worktree loop takes **only `path` and `branch`** from each survey
  entry ([`skills/wurk:kit/scripts/worktree_refresh.rb:65-66`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L65-L66)); currency and dirtiness are recomputed
  post-fetch inside `refresh_one` ([`skills/wurk:kit/scripts/worktree_refresh.rb:94-107`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L94-L107)). The bead,
  areas, and PR state the survey knew are discarded.
- `RebaseOnto.perform` is called as a library method sharing the same
  `Envelope` ([`skills/wurk:kit/scripts/worktree_refresh.rb:112`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L112)), so every conflicting worktree
  appends its own `rebase_conflict` block to one `@blocked` array
  ([`skills/wurk:kit/scripts/lib/envelope.rb:41-44`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/envelope.rb#L41-L44)), and a single conflict makes the whole sweep
  `ok: false` ([`skills/wurk:kit/scripts/lib/envelope.rb:53-55`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/envelope.rb#L53-L55)). The blocked entries distinguish
  worktrees only by the filenames embedded in their messages.
- `env.fail!` fires if any worktree came back `"red"`
  ([`skills/wurk:kit/scripts/worktree_refresh.rb:68`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L68)).

So the model's involvement in `/wurk:refresh` is: invoke one script, read one
envelope, render one table. There is no per-worktree model turn, no branch
diff in hand, and no bead context - the skill's own guidelines say the agent
working in that worktree is the one who needs to see the result
([`skills/wurk:refresh/SKILL.md:119-121`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:refresh/SKILL.md#L119-L121)), and that a conflict means the area
labels were wrong or the batch was picked badly, with `bd merge-slot` as the
coordination primitive ([`skills/wurk:refresh/SKILL.md:113-118`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:refresh/SKILL.md#L113-L118)).

`/wurk:mr`, by contrast, runs in the worktree it is publishing, with the
branch's commits, the bead, and the diff all in reach, and it is a session a
human just invoked by name ([`skills/wurk:mr/SKILL.md:16-24`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L16-L24)).

### 5. The motivating incident, as recorded in git

The bead cites wu-902 on 2026-08-09. The main-side commit is `60130c7`
"Marks wurk's self-adoption as unblocked", whose entire diff is three added
lines and one removed line in `docs/plan.md`, rewriting one clause of the
phase-2 backlog paragraph:

```
-(wurk dogfooding its own workflow, blocked on `install.rb`).
+(wurk dogfooding its own workflow - both named blockers, `install.rb` and a
+git remote, are cleared; the beads tracker, `.claude/wurk.json` manifest,
+and `bd prime` hook are live and verified end to end against this repo).
```

`docs/plan.md` matches no entry in this repo's `gate.build_paths` or
`gate.also_gated_paths`. No document under `docs/` writes up the incident;
`docs/plan.md`'s wu-902 references are phase-2 definition-of-done tracking,
unrelated to the conflict.

### 6. Prior art already in the repo's own backlog

[`docs/plan.md:1208-1213`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/plan.md#L1208-L1213), under "Backlog (after phase 4; not scheduled)":

> **wurk-conflict-scout** (agent): when refresh/mr abort on a rebase
> conflict, a read-only agent examines the captured conflict and reports
> scope and likely difficulty ("both sides touched the exit-set logic;
> theirs is a rename, yours is behavioral; ~10-minute manual merge") so the
> human gate is an informed one. Authority unchanged: it never resolves
> anything.

The same backlog section states the bar for any wurk agent
([`docs/plan.md:1195-1200`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/plan.md#L1195-L1200)): "noisy-context absorption or independent
judgment; scripts for anything deterministic." Eight agents exist today under
`agents/`; `wurk-gate-reader` is the one `/wurk:mr` already dispatches, for
gate output ([`skills/wurk:mr/SKILL.md:129-131`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L129-L131)).

Note the ordering tension this backlog item shares with wu-y7d: the scout is
described as examining "the captured conflict", but what survives the abort
today is a list of filenames, not conflict markers or hunks.

## Code References

- [`skills/wurk:kit/scripts/rebase_onto.rb:15-18`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L15-L18) - the stated "no resolve path" policy and its authority-table justification
- [`skills/wurk:kit/scripts/rebase_onto.rb:36-83`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L36-L83) - `perform`, the only rebase code path in the kit
- [`skills/wurk:kit/scripts/rebase_onto.rb:44-54`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L44-L54) - capture, abort, `block!`, return `{status: "conflict"}`
- [`skills/wurk:kit/scripts/rebase_onto.rb:106-114`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L106-L114) - `dry_run_steps`, which renders the conflict-path commands without executing
- [`skills/wurk:kit/scripts/test/rebase_onto_test.rb:41-63`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/rebase_onto_test.rb#L41-L63) - the capture-before-abort ordering assertion
- [`skills/wurk:kit/scripts/test/rebase_onto_test.rb:65-70`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/rebase_onto_test.rb#L65-L70) - source-text refutation of `checkout --ours/--theirs`, `git add`, `rebase --continue`
- [`skills/wurk:kit/scripts/worktree_refresh.rb:65-69`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L65-L69) - the per-worktree map and envelope aggregation
- [`skills/wurk:kit/scripts/worktree_refresh.rb:100-123`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L100-L123) - `refresh_one`: currency check, dirty check, `RebaseOnto.perform`, status branch
- [`skills/wurk:kit/scripts/worktree_refresh.rb:125-131`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L125-L131) - `confirm_green`, the per-worktree loop gate
- [`skills/wurk:kit/scripts/lib/gate_paths.rb:36-51`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/gate_paths.rb#L36-L51) - `touches_build?`, `gate_applicable?`, and the one path-matching rule
- [`skills/wurk:kit/scripts/gate.rb:97-112`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/gate.rb#L97-L112) - how the changed-path set is computed
- [`skills/wurk:kit/scripts/gate.rb:232-235`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/gate.rb#L232-L235) - `carve_out_reason`
- `skills/wurk:kit/scripts/gate.rb:311,327-346` - `applicable`, `carve_out_reason` in the envelope, and the short-circuit
- [`skills/wurk:kit/scripts/lib/manifest.rb:271-281`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/manifest.rb#L271-L281) - `gate_build_paths`, `gate_also_gated_paths`, `gate_moving_files`
- [`skills/wurk:kit/scripts/lib/manifest.rb:344-350`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/manifest.rb#L344-L350) - `repair_when`, `repair`
- `skills/wurk:kit/scripts/lib/envelope.rb:41-44,53-55,61-64` - `block!`, `ok?`, `emit`
- [`skills/wurk:kit/scripts/judge.rb:10-20`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/judge.rb#L10-L20) - the script/model/skill division of labor
- [`skills/wurk:kit/scripts/judge.rb:278-301`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/judge.rb#L278-L301) - propose/refute, `block!` on a survivor, named skips
- [`skills/wurk:kit/scripts/test/contract_test.rb:30-39`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/contract_test.rb#L30-L39) - the fixed banned-call list
- [`skills/wurk:kit/scripts/test/contract_test.rb:442-460`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/contract_test.rb#L442-L460) - the ADR-0006 drift check
- [`skills/wurk:kit/REFERENCE.md:153-185`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/REFERENCE.md#L153-L185) - step-scoping, the banned-operation list, and the judgment-stays-in-prose paragraph
- [`skills/wurk:kit/REFERENCE.md:302-348`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/REFERENCE.md#L302-L348) - the `judge.rb` contract as documented
- [`skills/wurk:kit/REFERENCE.md:350-374`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/REFERENCE.md#L350-L374) - "Writing a new script"
- [`skills/wurk:mr/SKILL.md:85-121`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L85-L121) - step 3, the rebase, and the conflict-stops-the-run instruction
- [`skills/wurk:mr/SKILL.md:123-157`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L123-L157) - step 4, the gate, refusal on red, skip classification, carve-out
- [`skills/wurk:mr/SKILL.md:168-183`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L168-L183) - step 6's summary template
- [`skills/wurk:mr/SKILL.md:210-224`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L210-L224) - the request body's four bullets
- [`skills/wurk:refresh/SKILL.md:53-66`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:refresh/SKILL.md#L53-L66) - the single-script sweep
- [`skills/wurk:refresh/SKILL.md:68-104`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:refresh/SKILL.md#L68-L104) - result vocabulary and the report table
- [`skills/wurk:refresh/SKILL.md:113-118`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:refresh/SKILL.md#L113-L118) - "a rebase conflict is signal for a human, not something to paper over mid-sweep"
- `.claude/wurk/mr.md:1-27` - the judge step wired in after the gate
- `.claude/wurk.json` - `gate.build_paths`, `gate.also_gated_paths: []`, `gate.moving_files: []`, `judge.registry`

## Architecture Documentation

- **ADR-0006** ([`docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md:20-40`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md#L20-L40))
  fixes the script contract: system Ruby, stdlib only, one JSON envelope,
  exit 0/1/2, `--dry-run` on every mutating script, all shell-outs through
  `lib/sh.rb`, and an absolute banned-operation list enforced by a
  contract test that parses the ADR's own paragraph.
- **ADR-0004** ([`docs/adr/0004-manifest-and-extension-seams.md:26-29`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/adr/0004-manifest-and-extension-seams.md#L26-L29)): two
  seams, manifest for machine-consumed constants and
  `.claude/wurk/<skill>.md` for domain prose. Extensions add, never override;
  a consumer needing different generic behavior means the schema is missing a
  field.
- **ADR-0005** ([`docs/adr/0005-gate-contract-tiers.md:31-33`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/adr/0005-gate-contract-tiers.md#L31-L33)): "Skills degrade
  honestly: judgment that needs an absent capability does not fire, and every
  green states which tier produced it. Weaker is acceptable; vaguer is not."
- **ADR-0008** (`docs/adr/0008-merge-time-judge-over-generic-skill-prose.md`)
  is the settled precedent for a model judgment inside this workflow. Its
  shape, from `0008:80-131`: state the constraint in prose; put the mechanism
  at an irreversible-action seam and deliberately outside the required
  deterministic gate; wire it through the extension seam; script owns diff
  plumbing and prompt assembly, model owns the verdict, skill prose owns what
  to do about a finding; registry is data; fail-closed parsing; a skip
  reports a named reason; no test makes a real model call. `0008:157-162`
  adds that if findings prove noisy the response is harder grounding or
  measurement on fixtures, "never a downgrade of the finding to advisory, and
  never a mechanical pre-filter."
- **ADR-0009** ([`docs/adr/0009-upstream-beads-without-a-workspace.md:51-53`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/adr/0009-upstream-beads-without-a-workspace.md#L51-L53))
  is a recent worked example of the same boundary in the other direction: a
  label read is "a deterministic read ... not sizing leaking upstream", while
  actual sizing stays a model judgment requiring the codebase in reach.
- **[`docs/architecture.md:27`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/architecture.md#L27)** names the four-part skill prose shape - "What
  to run / How to read the result / Judgment / Report" - so judgment has a
  designated home in skill documents.
- **[`docs/architecture.md:38-47`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/architecture.md#L38-L47)** restates the contract and adds that the
  banned operations "stay literal skill instructions so a human-meaningful
  gate sits in front of every irreversible action."
- **CLAUDE.md hard rules**: generic skills and kit scripts contain no
  consumer constants; extensions add, never override; `docs/manifest.md` and
  `lib/manifest.rb` move in the same commit; the kit test suite is the gate
  for any script change.

## Historical Context

- [`docs/plan.md:1208-1213`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/plan.md#L1208-L1213) - the `wurk-conflict-scout` backlog item (read-only
  conflict triage, never resolves), plus [`docs/plan.md:1202-1206`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/plan.md#L1202-L1206) on why
  backlog items are not beads until someone intends to do them.
- [`docs/plan.md:427`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/plan.md#L427) - `rebase_onto.rb`'s manifest conversion row
  (`parallelism.repair_when/repair/warm_globs`); [`docs/plan.md:430`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/plan.md#L430) -
  `worktree_refresh.rb`'s row, noting `gate.moving_files` has no consumer.
- [`docs/plan.md:758`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/docs/plan.md#L758) - the `/wurk:mr` sequence as planned: "rebase via kit,
  gate, human confirmation, hand-run push + PR/MR".
- `docs/plans/260810-wu-0b2-wurk-skill-prose-judge.md` - the implementation
  plan for ADR-0008's judge; the closest existing precedent for phasing a
  model-judgment feature in this repo.
- [`skills/wurk:kit/scripts/rebase_onto.rb:9-13`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L9-L13) records that this block was extracted so `/wurk:mr`
  and `/wurk:refresh` could not drift, citing statifier-ex's
  `260806-st-hzf-skill-mechanics-scripts.md` Phase 4.

## Related Research

- `docs/research/260810-wu-ubm-direction-model-reality-vs-doc.md` - the only
  other research document in this repo; on `models.direction` reality vs.
  `docs/manifest.md`. Not topically related, but it is the format precedent.

## Open Questions

Recorded, not answered - no human was available during this research stage.

1. **What material would a resolver actually see?** Today the only artifact
   surviving a conflict is a list of filenames. Conflict markers, hunks, and
   `git diff --diff-filter=U` content all vanish with the abort
   ([`skills/wurk:kit/scripts/rebase_onto.rb:51`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/rebase_onto.rb#L51)). Whether any bounded resolution - or even the
   backlogged conflict-scout triage - is possible without changing what the
   script captures is unresolved. A "capture more, still abort" variant and a
   "leave it conflicted" mode are materially different in risk and were not
   distinguished by the bead.
2. **Does [`skills/wurk:kit/scripts/test/rebase_onto_test.rb:65-70`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/test/rebase_onto_test.rb#L65-L70) bind a future design?** Those source
   scans live in this script's own test file, not `contract_test.rb`. Whether
   they are a settled invariant (like the contract test's list, which has an
   ADR drift check behind it) or an artifact of the current single-behavior
   design is a decision, not a fact recoverable from the code.
3. **What is the safety net for a doc-only resolution?** In this repo, a
   `docs/` conflict reaches `gate.rb` with `applicable: false`
   (`.claude/wurk.json` `build_paths: ["skills/wurk:kit/scripts/"]`), so the
   gate never runs. Nothing mechanical would catch a wrong doc merge; the
   step 6 summary and request body that would name it are hand-written prose
   with no script behind them ([`skills/wurk:mr/SKILL.md:168-183`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L168-L183), `210-224`).
4. **How would "gate-guarded file" be defined for a stop rule?** Three
   candidate predicates exist and disagree: `gate_build_paths` alone
   (`touches_build?`), the union with `also_gated_paths` (`gate_applicable?`),
   and `gate.moving_files` + `gate.guard_ledger` (the contract test's guarded
   set, which has no production consumer). The bead's "gate-guarded file" maps
   cleanly onto none of them. Note also that in this repo
   `also_gated_paths` and `moving_files` are both `[]`.
5. **What identifies a lockfile or a manifest generically?** The kit has no
   such predicate. `parallelism.repair_when` names one lockfile path and only
   for repair purposes ([`skills/wurk:kit/scripts/lib/manifest.rb:344-346`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/lib/manifest.rb#L344-L346)), and this repo sets none.
   "Lockfile" and "manifest" as stop categories would need either a new
   manifest field (CLAUDE.md: change the schema and `docs/manifest.md` in the
   same commit) or a rule stated in skill prose.
6. **Would the change trip its own judge?** `.claude/wurk.json`'s registry
   focus covers "a step that used to state ... a human gate ... deleted
   during a rewrite rather than restated", scoped to `skills/**/SKILL.md`.
   [`skills/wurk:mr/SKILL.md:104-115`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:mr/SKILL.md#L104-L115) is such a stated gate. Whether narrowing
   it survives `judge.rb`'s propose/refute at merge time is unknown and,
   per `.claude/wurk/mr.md:13-19`, only a person may decide a finding is
   wrong.
7. **Where would a resolution live in `/wurk:refresh`'s architecture?** The
   sweep is one script call with no per-worktree model turn and only `path`
   and `branch` in hand ([`skills/wurk:kit/scripts/worktree_refresh.rb:65-66`](https://github.com/riddler/wurk/blob/717999bba09bf4efc5c2f399f56862bc5a06159d/skills/wurk:kit/scripts/worktree_refresh.rb#L65-L66)). Any per-worktree
   judgment implies restructuring the sweep, dispatching an agent per
   worktree, or moving the loop into skill prose. The bead's stated lean
   (`/wurk:mr` only, at least at first) is consistent with that, but the cost
   of the alternative was not previously written down.
8. **Relationship to the backlogged `wurk-conflict-scout`.** Both read a
   captured conflict; one reports, one resolves. Whether wu-y7d supersedes
   the backlog item, subsumes it as a first phase, or is a separate thing is
   not recorded anywhere.

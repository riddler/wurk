---
date: 2026-08-11
planner: Claude
branch: wu-y7d-rebase-auto-resolve
repository: wurk
beads_issue: wu-y7d
topic: "A bounded, opt-in auto-resolution path for trivially-mergeable rebase conflicts in /wurk:mr"
status: draft
---

# Bounded rebase-conflict auto-resolution Implementation Plan

## Overview

Give `/wurk:mr` a narrow, opt-in path that resolves a rebase conflict without
stopping when - and only when - the conflict is confined to files the
consumer's manifest has allowlisted in advance, is a plain both-modified
content conflict, produces a merge that a deterministic line-set invariant
proves is purely additive, and survives an independent model refutation pass.
Everything else stops with `needs: "human"` exactly as it does today.
`rebase_onto.rb` and `/wurk:refresh` are not changed at all.

Beads issue: `wu-y7d`

## Current State Analysis

`RebaseOnto.perform` (`skills/wurk:kit/scripts/rebase_onto.rb:36-83`) is the
only rebase code path in the kit. `/wurk:mr` shells out to it
(`skills/wurk:mr/SKILL.md:93`); `/wurk:refresh` calls it as an in-process
library method from `skills/wurk:kit/scripts/worktree_refresh.rb:112`,
sharing one `Envelope`.

On a failed rebase it captures `git diff --name-only --diff-filter=U`, then
runs `git rebase --abort`, then `env.block!(code: "rebase_conflict", needs:
"human")` (`rebase_onto.rb:44-54`). Two guarantees ride on the abort, and on
the capture-before-abort ordering that `rebase_onto_test.rb:41-63` pins:

1. the conflicting file list survives into a report assembled afterward;
2. the worktree returns to exactly its pre-rebase state, which is what
   `/wurk:refresh` reports verbatim as `"conflict in <files>, aborted,
   unchanged"` (`worktree_refresh.rb:116`).

`rebase_onto_test.rb:65-70` reads the script's own source text and refutes
`checkout --ours|--theirs`, `git add`, and `rebase --continue`. It is a
file-level scan, so any resolve mechanics placed in that file fail it
regardless of a guarding flag.

The contract test (`test/contract_test.rb:30-39`) bans five irreversible
operations - `git push`, `gh pr create`, `glab mr create`, `bd close`, `bd
edit` - plus manifest-declared guarded writes, `system`/backticks,
non-interactive `cp`/`rm`/`mv`, consumer vocabulary, and hardcoded
default-branch refs. It does not ban model judgment; that rule is prose
(`skills/wurk:kit/REFERENCE.md:182-185`), and `judge.rb` is the shipped
counter-example of a kit script that shells the `claude` CLI under ADR-0008's
split.

`lib/gate_paths.rb` has exactly two predicates over one matching rule
(trailing `/` is a directory prefix, anything else is an exact path, no
globbing). There is no generic lockfile predicate and no manifest predicate
anywhere in the kit; `parallelism.repair_when` names one lockfile path for
repair purposes only, and this repo sets none. `gate.moving_files` has no
production consumer. `docs/plan.md` - the file in the motivating wu-902
incident - matches no entry in this repo's `build_paths`
(`["skills/wurk:kit/scripts/"]`) or `also_gated_paths` (`[]`), so a docs-only
resolution reaches `gate.rb` with `applicable: false` and no gate runs.

`/wurk:mr`'s step 6 summary and step 7 request body are hand-written skill
prose (`skills/wurk:mr/SKILL.md:168-183`, `210-224`). No script emits either.

`/wurk:refresh` is one script invocation for the whole sweep, with no
per-worktree model turn; `worktree_refresh.rb:65-66` discards everything the
survey knew about a worktree except `path` and `branch`.

`docs/plan.md:1208-1213` already carries a `wurk-conflict-scout` backlog
item: a read-only agent that triages a captured conflict so the human gate is
an informed one, with "Authority unchanged: it never resolves anything."

## Desired End State

After this plan:

- The manifest has a new optional section, `rebase.auto_resolve_paths`,
  defaulting to `[]`. Empty means the feature is off, which is every
  consumer's state until it opts in.
- `lib/manifest.rb` refuses to load a manifest whose `auto_resolve_paths`
  intersects `gate.build_paths`, `gate.also_gated_paths`,
  `gate.moving_files`, `gate.guard_ledger`, or `parallelism.repair_when`, or
  which allowlists anything at or under `.claude/`. A consumer cannot
  allowlist a gate-guarded file, a lockfile, or its own manifest even by
  accident.
- A new kit script, `skills/wurk:kit/scripts/rebase_resolve.rb`, owns the
  entire conflicted window inside one invocation: it re-creates the conflict,
  screens it deterministically, asks a model to merge and then independently
  asks a model to refute the merge, proves the merge additive with a pure
  function, applies it, and continues the rebase - or aborts and blocks with
  `needs: "human"`. It never returns with a worktree mid-rebase.
- `/wurk:mr` step 3 gains a bounded resolution branch, states the policy in
  its own prose, and requires any resolution to be named in step 6's summary
  and step 7's request body.
- `/wurk:refresh` states, in one sentence, that the sweep never auto-resolves
  and why.
- `rebase_onto.rb`'s conflict behavior, its module header, and every
  assertion in `rebase_onto_test.rb` are unchanged.

Verify by: running the gate; reading `docs/manifest.md` against
`lib/manifest.rb`; running `judge.rb` on the branch; and exercising the
script end to end in a throwaway git repo per the Testing Strategy below.

### Key Discoveries:

- `rebase_onto_test.rb:65-70` is treated here as a **settled invariant, not
  an artifact to amend**. See "Implementation Approach" for why, and note
  that designing around it is also what mechanically scopes this feature to
  `/wurk:mr`: `/wurk:refresh` reaches the rebase only through
  `RebaseOnto.perform`, which this plan does not touch.
- ADR-0008 fixes the split this feature must follow
  (`docs/adr/0008-...:94-106`): the script owns plumbing and prompt assembly,
  the model owns the verdict, the skill prose owns what to do about the
  result. `judge.rb:145-148` is the CLI-call shape to copy (`--tools ""
  --strict-mcp-config`, `Sh.run`, timeout), and `judge.rb:190-212` is the
  fail-closed parsing shape.
- ADR-0008's consequences forbid "a mechanical pre-filter" that downgrades a
  finding. The deterministic screens in this plan run in the opposite
  direction - they only ever cause more stopping, never less - so they are
  not that anti-pattern. The plan states this distinction so a later reader
  does not have to re-derive it.
- `judge.rb`'s refute polarity is inverted here. There, an unparseable refute
  means "not a violation" and the request proceeds. Here, an unparseable
  refute means "the objection stands" and the resolution is abandoned. Both
  fail closed toward stopping; the polarity differs because the risky action
  differs.
- The bead's stop categories - code, lockfile, manifest, gate-guarded file -
  have no generic predicate in the kit and would each need one. An allowlist
  plus a validated disjointness rule makes all four fall out by
  construction, which is both smaller and strictly safer than four
  denylists. "Manifest" is the one that does not fall out of the existing
  path lists, so Phase 2 adds an explicit rule against `.claude/`, the
  directory ADR-0004 gives both seams.
- `gate.rb` never runs for a docs-only branch in this repo, so the gate is
  not the safety net for the file class most likely to qualify. The line-set
  invariant in Phase 3 is the mechanical net; the reporting requirement in
  Phase 4 is the human one.
- ADR-0008's first open question ("should the scope also cover
  `docs/manifest.md` and the schema seam?") is triggered by this bead, which
  re-expresses part of a judgment call as a manifest key. Phase 1 answers it
  for this change rather than leaving it dangling.

## What We're NOT Doing

- **Not touching `rebase_onto.rb`'s conflict path, its header comment, or
  `rebase_onto_test.rb`'s refutations.** Phase 3 refactors only the
  post-rebase repair block out of `perform` into a public method; that
  introduces none of the refuted strings.
- **Not adding auto-resolution to `/wurk:refresh`.** The sweep is one script
  call with no per-worktree model turn and only `path` and `branch` in hand
  (`worktree_refresh.rb:65-66`); giving it a per-worktree judgment means
  restructuring the sweep or dispatching an agent per worktree, and the
  worktree it would be resolving belongs to a session that is not this one.
  `/wurk:refresh` keeps today's behavior in full. This is stated in that
  skill's prose in Phase 4 so it reads as a decision rather than an omission.
- **Not adding generic "is this a lockfile / a manifest / code" predicates.**
  The allowlist subsumes all three, and a denylist of unbounded categories is
  the wrong shape for "bias hard toward stopping".
- **Not making the merge tolerant of reflowed prose.** A merge that re-wraps
  a paragraph invents lines that exist in none of base / ours / theirs, and
  the Phase 3 invariant stops it. This is deliberate and may mean the exact
  wu-902 incident stops rather than resolves, depending on whether its merge
  needed a re-wrap. Widening this is future work gated on measurement, not a
  first-pass convenience - the same discipline ADR-0008's consequences apply
  to noisy findings.
- **Not building `wurk-conflict-scout`.** Phase 1 re-scopes the backlog item
  to conflicts outside `rebase.auto_resolve_paths`, where it still has a job;
  it stays unscheduled.
- **Not widening the contract test's banned-operation list.** `git add` and
  `git rebase --continue` are local and reversible and are not on it;
  `rebase_onto.rb` already runs `git rebase` and `git rebase --abort`.
- **Not auto-resolving anywhere else** - not in `/wurk:commit`, not in
  `/wurk:branch`, not on a merge as opposed to a rebase.
- **Not shipping a fixture corpus for the prompts in the first pass.**
  ADR-0008's own open question left that choice to the implementing bead;
  this plan takes the propose/refute unit seams plus the deterministic
  invariant and defers a corpus until a first disputed resolution exists.

## Implementation Approach

**The strategy is to make the risky window as small as one script
invocation, and to make everything outside the model's verdict
deterministic.**

Three decisions carry the design.

**1. `rebase_onto_test.rb:65-70` is a settled invariant; the resolver lives
in a new file.** Those refutations are what make `rebase_onto.rb` legible as
*the* no-resolve rebase - the one `/wurk:refresh` uses, the one whose header
cites the consumer authority table. Amending them to add a flag would trade a
strong file-level property for a weak conditional one, and would silently
widen `/wurk:refresh` too, since both callers share the file. A new script,
`rebase_resolve.rb`, keeps the old guarantee intact and buys the scoping for
free: what `/wurk:refresh` calls is unchanged, so it cannot auto-resolve even
if someone later forgets that it should not.

**2. The judgment goes in the script, under ADR-0008's split, because that is
what keeps the worktree out of a mid-rebase state across a model turn.** The
alternative - abort, hand the captured material to `/wurk:mr`'s model, resolve
from skill prose - means either leaving the worktree conflicted across a turn
(surrendering both of the abort's guarantees, and making every error path in
skill prose responsible for the cleanup) or re-creating the conflict from
prose anyway. Putting rebase, capture, verdict, apply, and continue-or-abort
inside one invocation gives a single place to guarantee the exit states.
This satisfies the bead's "no model judgment inside `scripts/`" the same way
`judge.rb` does: the script contains no judgment, only prompt assembly,
fail-closed parsing, and deterministic checks; the model supplies the verdict;
`/wurk:mr`'s prose decides what to do about it.

**3. Eligibility is an opt-in allowlist, plus deterministic screens that only
ever narrow.** The bead names four stop categories. Rather than build four
predicates the kit does not have, the consumer names in its own manifest the
only paths where the question may even be asked, and `lib/manifest.rb`
refuses a manifest that allowlists anything gated, guarded, or lockfile-ish.
On top of that the script requires every conflicted path to be in the
allowlist (not just some), requires every unmerged entry to be a plain `UU`
both-modified content conflict, caps the file count and the blob size, and
proves the proposed merge additive by a pure line-set function before writing
a byte. The model is consulted only after all of that passes, and its
proposal is then attacked by an independent call before it is trusted.

Phases land the decision, then the data, then the mechanism, then the wiring -
so each is committable on its own and the mechanism exists, tested and
unreachable, before anything invokes it.

---

## Phase 1: ADR-0010 and backlog reconciliation

### Overview

Record the decision as an ADR before any code exists, and reconcile the
`wurk-conflict-scout` backlog item with it. Doc-only.

### Changes Required:

#### 1. The decision record

**File**: `docs/adr/0010-bounded-rebase-conflict-auto-resolution.md` (new)
**Changes**: New ADR, `Status: accepted`, following ADR-0008's shape
(Context / Decision / Consequences). It must state, at minimum:

- The context: `rebase_onto.rb`'s unconditional stop, the wu-902 incident,
  and the bead's own warning that a wrong auto-resolver is worse than none
  because it replaced the only check on itself.
- **Decision 1 - opt-in allowlist.** Auto-resolution is considered only for a
  conflict whose every path matches `rebase.auto_resolve_paths`, a new
  manifest list defaulting to `[]`, validated disjoint from
  `gate.build_paths`, `gate.also_gated_paths`, `gate.moving_files`,
  `gate.guard_ledger`, and `parallelism.repair_when`, and additionally
  disjoint from the manifest's own directory (`.claude/`, which holds the
  manifest and every extension file). Those five lists cover the bead's
  "code", "lockfile", and "gate-guarded file"; the `.claude/` rule covers
  "manifest". All four stop categories are therefore satisfied by validated
  construction rather than by four new content predicates - and validated,
  not documented, because a documented rule is one a careful consumer
  follows and a careless one does not.
- **Decision 2 - `rebase_onto.rb` is untouched.** Its source-text refutations
  are a settled invariant. The resolver is a separate script, which also
  scopes the feature to `/wurk:mr`, since `/wurk:refresh` reaches the rebase
  only through `RebaseOnto.perform`.
- **Decision 3 - the ADR-0008 split applies verbatim.** Script owns rebase
  plumbing, blob capture, deterministic screens, prompt assembly, and
  fail-closed parsing; the model owns the merge and the refutation; `/wurk:mr`
  prose owns what to do about the result. No test makes a real model call.
- **Decision 4 - the deterministic net.** A resolution is applied only if a
  pure function proves that every whitespace-normalized non-empty line unique
  to either side survives into the merge, that the merge invents no line
  absent from all three of base / ours / theirs, and that no conflict markers
  remain. Reflowed prose therefore stops. This exists because for the file
  class most likely to qualify - docs - the gate does not run at all in this
  repo.
- **Decision 5 - reporting is part of the mechanism.** A resolution that is
  not named in `/wurk:mr`'s step 6 summary and step 7 request body is a
  defect, not a nicety; it is the substitute for the gate that will not run.
- **Decision 6 - the refute polarity is inverted relative to `judge.rb`**, and
  why (the risky action is applying a merge, not blocking a request).
- **Consequences**, including: `/wurk:refresh` unchanged; every consumer off
  by default; the reflow limitation; model spend and latency land on
  `/wurk:mr` runs that actually conflict inside the allowlist and nowhere
  else; a widening of the invariant must be measured, never assumed.
- **An explicit answer to ADR-0008's first open question** for this change:
  the schema seam is in scope for the judged surface only insofar as the
  skill-side half is, which this change keeps in prose; the manifest key here
  carries a path list (data), not the policy call, and the policy call stays
  stated in `skills/wurk:mr/SKILL.md`.

#### 2. Backlog reconciliation

**File**: `docs/plan.md` (around line 1208)
**Changes**: Re-scope the `wurk-conflict-scout` bullet so it does not read as
contradicted. It stays unscheduled, and its job becomes triage for conflicts
that stop - which after this plan is every conflict outside
`rebase.auto_resolve_paths`, plus every allowlisted one that the screens, the
invariant, or the refute pass rejected. Cite ADR-0010 in the bullet.

### Success Criteria:

#### Automated Verification:
- [x] `ruby skills/wurk:kit/scripts/test/run.rb` is green (unchanged; proves
      the doc commit touched no script)
- [x] `docs/adr/0010-bounded-rebase-conflict-auto-resolution.md` exists and
      its first two lines are a `# ADR-0010:` heading and a `Status:` line,
      matching every other file in `docs/adr/`
- [x] `grep -n "ADR-0010" docs/plan.md` matches inside the
      `wurk-conflict-scout` bullet
- [x] `grep -rn "0010" docs/adr/0008-merge-time-judge-over-generic-skill-prose.md`
      is empty (ADR-0008 is not edited; ADR-0010 cites it, not the reverse)

#### Manual Verification:
- [ ] The ADR states all six decisions above and does not defer any of them
- [ ] The ADR's answer to ADR-0008's open question 1 is legible to someone
      who has read ADR-0008 and not this plan
- [ ] The re-scoped backlog bullet still describes a thing worth doing, not a
      dead item kept for politeness
- [ ] Plain ASCII punctuation throughout, per CLAUDE.md

**Implementation Note**: Doc-only; CLAUDE.md says doc-only changes commit on
review of the diff. Run the gate anyway to prove nothing else moved.

---

## Phase 2: Manifest schema - `rebase.auto_resolve_paths`

### Overview

Add the data seam and its validation, with no consumer. The field is
exercised by its own tests and by the disjointness refusal, so the phase is
gate-verifiable on its own.

### Changes Required:

#### 1. Schema and accessor

**File**: `skills/wurk:kit/scripts/lib/manifest.rb`
**Changes**:

- `KNOWN[nil]` gains `rebase`; `KNOWN` gains `"rebase" => %w[auto_resolve_paths]`.
- New accessor:

```ruby
# The only paths a rebase conflict may be auto-resolved in. Empty - the
# default - means the feature is off, which is where every consumer starts.
# Same matching rule as the gate path lists (see lib/gate_paths.rb): a
# trailing "/" is a directory prefix, anything else is an exact path.
def rebase_auto_resolve_paths
  Array(fetch("rebase.auto_resolve_paths"))
end
```

- New `validate_rebase`, called from `validate!` alongside `validate_judge`:
  - the section, when present, must be an object, and `auto_resolve_paths`
    must be a list of non-empty strings;
  - an entry equal to `"/"`, `""`, or `"."` is an error (an allowlist that
    matches the whole repo is not an allowlist);
  - an entry is an error if it matches, or is matched by, any entry of
    `gate.build_paths + gate.also_gated_paths + gate.moving_files`, the
    `gate.guard_ledger` path, or `parallelism.repair_when`. "Matches or is
    matched by" is deliberate and both directions must be checked: allowing
    `docs/` when `docs/plan.md` is guarded is as wrong as the reverse.
    The error message names the entry and the list it collides with.
  - an entry is an error if it is, or is under, the directory holding the
    manifest itself - `File.dirname(Manifest::FILENAME)`, i.e. `.claude/`.
    That directory holds the manifest and every extension file (ADR-0004's
    two seams), so it is the bead's "manifest" stop category expressed as a
    kit constant rather than left to each consumer's `guard_ledger`. Without
    this, `auto_resolve_paths: [".claude/wurk.json"]` would validate cleanly,
    and the acceptance criterion would be satisfied only by whoever wrote the
    allowlist happening to be careful. The five path lists above cover code,
    lockfiles, and gate-guarded files; this rule covers manifests.

#### 2. The eligibility predicate

**File**: `skills/wurk:kit/scripts/lib/conflict_paths.rb` (new)
**Changes**: One predicate, reusing `GatePaths.match_one?` so the matching
rule has exactly one definition site in the kit.

```ruby
# True only when there is at least one path and EVERY path is allowlisted.
# All, not any: a conflict spanning an allowlisted doc and a source file is
# not an allowlisted conflict, and the union is where a careless widening
# would hide.
def auto_resolvable?(paths, manifest: Manifest.current)
  entries = manifest.rebase_auto_resolve_paths
  return false if entries.empty?

  list = Array(paths)
  !list.empty? && list.all? { |p| entries.any? { |e| GatePaths.match_one?(p, e) } }
end
```

#### 3. Documentation

**File**: `docs/manifest.md`
**Changes**: A new `## rebase.auto_resolve_paths` section stating the
default, the matching rule (cross-referencing "Two path lists, not one"), the
disjointness rules and why they are validated rather than documented, and a
pointer to ADR-0010. Add the key to the "Required, optional, and defaults"
table and the disjointness rules to the "Validation" section. CLAUDE.md
requires this in the same commit as `lib/manifest.rb`.

#### 4. Tests

**File**: `skills/wurk:kit/scripts/test/manifest_test.rb`
**Changes**: absent section defaults to `[]`; a well-formed list round-trips;
each of the five disjointness classes produces a validation error naming the
colliding list; a non-list, an empty-string entry, and `"/"` each error; an
entry that is a *prefix of* a guarded path errors, and an entry that is
*prefixed by* a guarded path errors (both directions); `.claude/wurk.json`,
`.claude/`, and `.claude/wurk/mr.md` each error against the
manifest-directory rule.

**File**: `skills/wurk:kit/scripts/test/conflict_paths_test.rb` (new)
**Changes**: empty allowlist is false for any input; empty path list is
false; all-in is true; any-out is false; directory-prefix entry matches a
nested path; exact entry does not match a sibling with the same prefix (e.g.
entry `docs/plan.md` must not match `docs/plan.md.bak`).

**File**: `skills/wurk:kit/scripts/test/fixtures/...`
**Changes**: one fixture manifest carrying a `rebase` section, so the
disjointness tests have something realistic to mutate.

### Success Criteria:

#### Automated Verification:
- [x] `ruby skills/wurk:kit/scripts/test/run.rb` is green
- [x] `grep -c "auto_resolve_paths" skills/wurk:kit/scripts/test/manifest_test.rb`
      is at least 10 - the five path-list classes, both match directions, the
      manifest-directory rule, and the shape errors
- [x] `conflict_paths_test.rb` exists and covers empty-allowlist,
      empty-paths, all-in, any-out, prefix, and exact-vs-sibling
- [x] `ruby skills/wurk:kit/scripts/repo_state.rb` returns `ok: true` against
      this repo's own manifest (which sets no `rebase` section yet)
- [x] `grep -n "auto_resolve_paths" docs/manifest.md` matches in the new
      section, the defaults table, and the validation section

#### Manual Verification:
- [ ] `docs/manifest.md` and `lib/manifest.rb` agree, key for key, in this
      one commit
- [ ] Each new validation test genuinely fails when its guard is removed -
      delete each `validate_rebase` check in turn, re-run the suite, confirm
      red, restore. This is mutation testing and no command in this plan does
      it for you
- [ ] The disjointness error messages name both the entry and the list it
      collided with, so a consumer can fix it without reading the source
- [ ] No consumer-project constant appears in `lib/manifest.rb` or
      `lib/conflict_paths.rb`

**Implementation Note**: The field has no reader outside its own tests at the
end of this phase. That is intentional and the phase is still
gate-verifiable, because the validation refusals are the behavior being
added, not scaffolding for a later phase.

---

## Phase 3: `rebase_resolve.rb` - the bounded resolver

### Overview

The mechanism, fully tested and reachable by nothing. One invocation owns the
entire conflicted window and guarantees the worktree ends either fully
rebased or fully pre-rebase - never mid-rebase.

### Changes Required:

#### 1. Expose the repair block for reuse

**File**: `skills/wurk:kit/scripts/rebase_onto.rb`
**Changes**: Extract lines 59-80 (the `lock_changed` check, the repair
recipe, and `copy_warm_caches`) into a public method that `perform` calls:

```ruby
# The post-rebase half, public so rebase_resolve.rb can run it after
# continuing a rebase it resolved. Extracted, not duplicated: a second
# copy of the repair recipe is exactly the drift this file was created to
# prevent (see the header).
def repair_after(path, env, manifest, before:)
  ...
  { lock_changed: lock_changed, repaired: repaired }
end
```

`perform`'s behavior is byte-for-byte identical. Nothing in the extracted
text contains `checkout --ours|--theirs`, `git add`, `rebase --continue`,
`"cp", "-R`, or `--force`, so every assertion in `rebase_onto_test.rb`
continues to pass unedited. **If any assertion in `rebase_onto_test.rb`
requires editing, the refactor is wrong; revert and reshape it.**

#### 2. The resolver

**File**: `skills/wurk:kit/scripts/rebase_resolve.rb` (new)
**Changes**: `RebaseResolve.perform(path, env, manifest, dry_run:)` plus a
`run` entry point taking `<path>`, with `--dry-run`, `--model NAME`, and no
narrowing flags. Called only after `rebase_onto.rb` has already reported
`status: "conflict"` for the same worktree, and only when no fetch has
happened in between - `/wurk:mr` step 3 fetches once, so `origin/<default>`
cannot move between the two runs.

Sequence, every shell-out through `Sh.run`:

1. `git rev-parse HEAD` -> `before`.
2. `git rebase <manifest.remote_default_branch>` - expected to fail.
   **If it succeeds**, the worktree changed under us: emit `status:
   "conflict_not_reproduced"`, `block!(needs: "human")`. The worktree is
   rebased, which is a safe state; the skill reports it and stops.
3. `git status --porcelain`. Every unmerged entry must have status exactly
   `UU`. Anything else - `DU`, `UD`, `AA`, `DD`, a rename - is a structural
   conflict, not a content one: **abort and block**.
4. Conflicted paths from `git diff --name-only --diff-filter=U`.
   `ConflictPaths.auto_resolvable?(files, manifest: manifest)` must be true -
   the script re-derives eligibility itself and never trusts the caller.
   Otherwise **abort and block**. This is the step that makes the bead's
   acceptance criterion "code, lockfile, manifest, gate-guarded file still
   stops" true, via Phase 2's validated allowlist.
5. Caps: at most `MAX_FILES = 3` conflicted files, and each of the three
   blobs per file at most `MAX_BLOB_BYTES = 64 * 1024`. Over either -
   **abort and block**. Kit constants, not consumer values.
6. Per file, capture `git show :1:<path>` (merge base), `:2:<path>`, and
   `:3:<path>`. **During a rebase, stage 2 is the upstream side being
   rebased onto and stage 3 is the branch commit being replayed** - the
   opposite of the everyday reading of "ours" and "theirs". The prompts must
   label them `upstream` and `branch` by role, never `ours`/`theirs`, and a
   comment must say why.
7. **Propose**: one `claude` CLI call per file, argv shaped exactly like
   `judge.rb:145-148` (`-p`, `--output-format json`, `--tools ""`,
   `--strict-mcp-config`, `--model`, a timeout constant). The prompt ships
   base, upstream, and branch content labeled by role, states that only a
   purely additive, non-overlapping merge is acceptable, and asks for JSON
   only: `{"mergeable": true, "merged": "<full file content>", "rationale":
   "<one line>"}` or `{"mergeable": false, "reason": "..."}`. Parse
   fail-closed with `judge.rb`'s fence-extraction helpers: unparseable, wrong
   shape, missing `merged`, or `mergeable` not literally `true` -> not
   mergeable -> **abort and block**.
8. **Deterministic invariant**, a pure module function, run before any
   refute call and before anything is written:

```ruby
# Purely additive and non-overlapping, stated as arithmetic rather than
# taste. Compares whitespace-normalized non-empty lines as multisets:
#   - every line in upstream and not in base survives into merged
#   - every line in branch and not in base survives into merged
#   - every line in merged appears in at least one of base/upstream/branch
#   - merged carries no conflict marker
# A merge that rewords a shared sentence fails check 1 or 2; a merge that
# reflows a paragraph fails check 3. Both are meant to stop.
def additive_merge?(base, upstream, branch, merged) ... end
```

   Failure -> **abort and block**, naming which check failed.
9. **Refute**: an independent CLI call per file, given base / upstream /
   branch / merged, asked to find any reason this is not a purely additive,
   non-overlapping, mechanical merge - content dropped, content invented, an
   overlapping edit silently picked. JSON only: `{"objection": null}` or
   `{"objection": "..."}`. **Fail-closed inverted from `judge.rb`**:
   unparseable, wrong shape, or ambiguous means the objection stands ->
   **abort and block**. Comment the inversion and its reason at the parser.
10. Apply: `File.write` each merged file, `git add <paths>`,
    `git -c core.editor=true rebase --continue`. `-c core.editor=true`
    rather than an environment variable so the whole invocation is visible in
    the rendered argv `Sh` records.
11. If `--continue` reports further conflicts, repeat from step 3, at most
    `MAX_ROUNDS = 3` times. Exceeded -> **abort and block**.
12. On a clean finish, assert no rebase is in progress
    (`git rev-parse --git-path rebase-merge` and `rebase-apply`, neither
    existing) and `git status --porcelain` shows no unmerged entries;
    otherwise **abort and block**.
13. `RebaseOnto.repair_after(path, env, manifest, before: before)` - the
    replayed upstream commits can still move the lockfile even though the
    resolved files cannot.
14. Emit `data`: `status` in `"rebased" | "conflict" |
    "conflict_not_reproduced" | "dry_run"`, plus `target`, `lock_changed`,
    `repaired`, `resolved: [{file:, rationale:}]`, and `stop_reason` (one of
    a small named set: `not_allowlisted`, `structural_conflict`,
    `too_many_files`, `blob_too_large`, `not_mergeable`, `merge_not_additive`,
    `refuted`, `unparseable_response`, `apply_failed`, `rounds_exceeded`) when
    blocked. A named reason, never a silent stop - ADR-0005 and `judge.rb`'s
    skip vocabulary.

Every **abort and block** above is the same two lines: `git rebase --abort`,
then `env.block!(code: "rebase_conflict", message: "...", needs: "human")` -
the same code `rebase_onto.rb` emits, so `/wurk:mr`'s existing stop branch
needs no new vocabulary. Route them through one private method so there is
one place to be right.

#### 3. Tests

**File**: `skills/wurk:kit/scripts/test/rebase_resolve_test.rb` (new)
**Changes**: `FakeSh` plus a stubbed `claude` response, mirroring
`judge_test.rb`. **No test makes a real model call** (ADR-0008 point 4). Each
case asserts both the envelope and that `git rebase --abort` appears in the
recorded call sequence:

- a conflicted file outside the allowlist: aborts, blocks
  `stop_reason: "not_allowlisted"`, and **registers no CLI expectation**, so
  `FakeSh` raises if the script consulted a model;
- an empty allowlist (no `rebase` section) behaves the same;
- a `DU` / `AA` entry in `git status --porcelain`: aborts,
  `structural_conflict`, no CLI call;
- four conflicted files, and an over-cap blob: abort, no CLI call;
- propose returns `mergeable: false`: abort, `not_mergeable`;
- propose is unparseable / returns no `merged` key: abort,
  `unparseable_response`;
- proposed merge drops a line unique to upstream: abort,
  `merge_not_additive`, and **no refute call is made** (the invariant runs
  first);
- proposed merge invents a line: abort, `merge_not_additive`;
- proposed merge keeps a conflict marker: abort, `merge_not_additive`;
- invariant passes but refute objects: abort, `refuted`;
- refute unparseable: abort, `refuted` (the inverted fail-closed direction);
- happy path: writes the file, `git add`, `git -c core.editor=true rebase
  --continue`, calls `repair_after`, `status: "rebased"`, `data.resolved`
  names the file and a non-empty rationale, and **no abort appears in the
  call sequence**;
- rebase succeeds on the second attempt: `conflict_not_reproduced`, blocked,
  no abort attempted;
- a second round of conflicts resolves; a fourth round aborts with
  `rounds_exceeded`;
- `--dry-run` executes nothing and renders the CLI invocation without a real
  prompt;
- source-text: `refute_match(/--force\b/, source)`.

**File**: `skills/wurk:kit/scripts/test/rebase_resolve_invariant_test.rb`
(new, or a section of the above)
**Changes**: `additive_merge?` as a pure function against synthetic strings -
identical inputs, one-sided addition, two-sided disjoint addition (true);
dropped upstream line, dropped branch line, invented line, reflowed
paragraph, retained conflict marker (false); whitespace-only reindentation
(true, since comparison is normalized).

### Success Criteria:

#### Automated Verification:
- [ ] `ruby skills/wurk:kit/scripts/test/run.rb` is green
- [ ] `rebase_onto_test.rb` passes **with no edits** - confirm with
      `git diff --stat skills/wurk:kit/scripts/test/rebase_onto_test.rb`
      showing no change in the phase commit
- [ ] `contract_test.rb` picks up `rebase_resolve.rb` automatically: shebang,
      executable bit, `--dry-run`, no banned calls, no `system`/backticks, no
      consumer vocabulary, no hardcoded default-branch ref
- [ ] `grep -c "rebase --abort" skills/wurk:kit/scripts/test/rebase_resolve_test.rb`
      is at least 12 - one per stop path in the list above
- [ ] `grep -rn "claude" skills/wurk:kit/scripts/test/rebase_resolve_test.rb`
      shows only stubbed responses; no test shells the real CLI
- [ ] `ruby skills/wurk:kit/scripts/rebase_resolve.rb . --dry-run` emits a
      valid envelope with `status: "dry_run"` and executes nothing

#### Manual Verification:
- [ ] Every stop path in the list above has a test asserting `git rebase
      --abort` **precedes** the block in the recorded call sequence, in the
      style of `rebase_onto_test.rb:57-61`. A green suite does not prove the
      ordering; read the assertions
- [ ] Read both prompts: stages 2 and 3 are labeled `upstream` and `branch`
      by role, never `ours`/`theirs`, and the comment explaining the rebase
      inversion is present
- [ ] The refute parser's inverted fail-closed direction is commented at the
      parser, not only in the ADR
- [ ] Exercise the script by hand in a throwaway git repo per the Testing
      Strategy: confirm a real additive conflict resolves and continues, and
      that `git status` afterward shows no rebase in progress
- [ ] Kill the process mid-run (SIGINT during the propose call) and confirm
      the worktree is recoverable with a single `git rebase --abort`, and
      that the skill prose in Phase 4 says so

**Implementation Note**: This is the largest phase and is still one phase:
the script and its tests cannot be split without leaving an intermediate
commit whose gate proves nothing. Use the loop gate between edits.

---

## Phase 4: Wire it into `/wurk:mr`, scope out `/wurk:refresh`, opt wurk in

### Overview

Make the mechanism reachable, state the policy in prose, make the reporting
mandatory, and turn the feature on for this repo at its narrowest possible
setting.

### Changes Required:

#### 1. `/wurk:mr` step 3

**File**: `skills/wurk:mr/SKILL.md` (the `"conflict"` bullet, lines 108-115)
**Changes**: Replace the current bullet with prose that **states the policy
itself** rather than pointing at the script. It must carry, in this order:

- the unchanged default, in the same voice as today: the script has already
  captured the files and aborted; an aborted rebase ends this run; resolving
  a rebase conflict unasked is not an authority this workflow grants;
- the one exception, stated as a grant the consumer made in advance: when
  every conflicting file matches the consumer's own
  `rebase.auto_resolve_paths`, the consumer has said in writing, before the
  conflict existed, which files it grants that authority for. Nothing else is
  eligible, and an empty list - the default - means nothing is;
- the command, and what to read:

```bash
ruby ~/.claude/skills/wurk:kit/scripts/rebase_resolve.rb .
```

- how to read it: `status: "rebased"` with `data.resolved` non-empty means a
  resolution happened and **must** be carried into step 6 and step 7; any
  block means stop and report `data.stop_reason` verbatim; `status:
  "conflict_not_reproduced"` means the worktree moved and the run stops;
- the division of labor, per ADR-0008: the script owns the rebase plumbing,
  the blob capture, the deterministic screens, the line-set invariant, and
  prompt assembly; a model owns the merge and the independent refutation;
  **this prose owns what to do about the result** - and what it says to do
  about anything short of a clean, unrefuted, provably additive merge is
  stop;
- why the reporting is load-bearing rather than courteous: for the file class
  most likely to qualify, `data.applicable` comes back false in step 4 and no
  gate runs, so the summary and the request body are the only place a human
  ever sees that a merge was made on their behalf. A resolution that reaches
  step 7 unnamed is a defect;
- the recovery note: if the script is interrupted, `git rebase --abort` in
  the worktree restores the pre-rebase state.

**File**: `skills/wurk:mr/SKILL.md` step 6 summary template (lines 172-183)
**Changes**: add a line to the fenced block:

```
Conflict:  none
           (or: auto-resolved in <files> - <rationale>)
```

**File**: `skills/wurk:mr/SKILL.md` step 7 request body (the Notes bullet)
**Changes**: extend the Notes bullet so naming an auto-resolved file and what
the merge did is required there, alongside "which gate ran".

#### 2. `/wurk:refresh` scoping

**File**: `skills/wurk:refresh/SKILL.md` (near lines 113-118)
**Changes**: One short paragraph: the sweep never auto-resolves, whatever the
manifest allowlists. It has no per-worktree model turn, no branch diff, and
no bead context, and the worktree it would be merging in belongs to a session
that is not this one. A conflict here stays what it has always been - signal
that the area labels were wrong or the batch was picked badly. Cite ADR-0010
so this reads as a decision rather than a gap.

#### 3. Opt this repo in

**File**: `.claude/wurk.json`
**Changes**: add, at the narrowest useful setting - one exact path, the file
from the motivating incident:

```json
"rebase": {
  "auto_resolve_paths": ["docs/plan.md"]
}
```

Exact match, not `docs/`: `docs/adr/` holds settled decisions and
`docs/manifest.md` is a manifest in the bead's own stop list. Widening this
is a separate, reviewed decision.

**File**: `docs/manifest.md` ("Per-repo starting values")
**Changes**: add the row for wurk's own value and note that statifier-ex and
predicator-ex start at `[]`.

### Success Criteria:

#### Automated Verification:
- [ ] `ruby skills/wurk:kit/scripts/test/run.rb` is green
- [ ] `ruby skills/wurk:kit/scripts/repo_state.rb` returns `ok: true`, which
      proves the new `.claude/wurk.json` section passes Phase 2's validation,
      including disjointness against this repo's `build_paths`
- [ ] `grep -n "auto_resolve_paths" skills/wurk:mr/SKILL.md
      skills/wurk:refresh/SKILL.md` matches in both
- [ ] `grep -n "Conflict:" skills/wurk:mr/SKILL.md` matches inside the step 6
      fenced template
- [ ] `grep -rn "docs/plan\.md" skills/wurk:mr/SKILL.md
      skills/wurk:refresh/SKILL.md skills/wurk:kit/scripts/rebase_resolve.rb`
      is empty - this repo's allowlist value lives in `.claude/wurk.json`
      only, never in generic prose or the script (the bare namespace string
      `wurk` is not a consumer constant and is expected throughout)

#### Manual Verification:
- [ ] `ruby skills/wurk:kit/scripts/judge.rb` on this branch returns
      `data.status: "clean"`. A surviving finding stops the phase and is a
      conversation, not a reroll (`.claude/wurk/mr.md`). A skip is only
      acceptable for a reason other than `no_cli`, since this branch
      certainly touches scoped prose
- [ ] Read the rewritten step 3 against ADR-0008 point 1 as if judging it:
      does it state the policy, or does it name a script and stop? Does the
      human gate that used to be stated unconditionally survive, restated
      with its exception, rather than deleted?
- [ ] The step 6 and step 7 requirements read as a discipline ("a resolution
      that reaches step 7 unnamed is a defect"), not as a check on an
      artifact - a script confirming a marker exists is the anti-pattern
      ADR-0008 names
- [ ] End-to-end: manufacture an additive `docs/plan.md` conflict between a
      scratch branch and `origin/main` in a clone, run `/wurk:mr` through step
      3, and confirm the resolution happens, the summary names it, and the
      request body would too
- [ ] End-to-end negative: manufacture a conflict touching
      `skills/wurk:kit/scripts/` and confirm the run stops with `needs:
      "human"` and no CLI call

**Implementation Note**: The `.claude/wurk.json` edit is what turns the
feature on. Land it in this phase, not earlier: a live allowlist with no
mechanism behind it is dead config, and a live allowlist with an unwired
mechanism is worse.

---

## Testing Strategy

### Unit Tests:

- `manifest_test.rb` - the schema, the default, and all five disjointness
  refusals in both match directions.
- `conflict_paths_test.rb` - the all-not-any predicate, empty allowlist,
  empty path list, prefix vs. exact matching.
- `rebase_resolve_test.rb` - every stop path asserts an abort precedes the
  block; the happy path asserts no abort; `FakeSh` with no CLI expectation is
  the proof that the screens run before any model is consulted.
- `rebase_resolve_invariant_test.rb` - `additive_merge?` as a pure function,
  including the reflow and dropped-line cases that are the whole point.
- `contract_test.rb` - no change needed; it enumerates `scripts/` and picks
  the new file up.
- `rebase_onto_test.rb` - **no change**, and that is a success criterion.

Key edge cases, all covered above: a conflict spanning an allowlisted and a
non-allowlisted file; a structural (non-`UU`) conflict; a second and a fourth
round of conflicts; an unparseable model response on each of the two calls; a
merge that drops content; a merge that invents content; the rebase succeeding
on the second attempt.

### Manual Testing Steps:

1. In a throwaway clone, create `main` with a `docs/plan.md` paragraph, then
   two branches that each **append a distinct new bullet** to it. Merge one
   into `main`. On the other, run `rebase_onto.rb .` and confirm today's
   stop, then `rebase_resolve.rb .` and confirm it resolves, continues, and
   leaves no rebase in progress.
2. Repeat with the two branches **rewording the same sentence**. Confirm the
   invariant or the refute pass stops it, with a named `stop_reason`.
3. Repeat with a conflict in `skills/wurk:kit/scripts/`. Confirm the stop
   happens at the allowlist screen with no model call - verify by checking
   `env.commands` contains no `claude` invocation.
4. Repeat with `rebase.auto_resolve_paths` absent from the manifest entirely.
   Confirm the stop is identical to today's.
5. Interrupt a run during the propose call; confirm `git rebase --abort`
   fully restores the worktree.
6. Run `/wurk:mr` on this plan's own branch and read step 6's summary and the
   request body for the resolution line - or its absence, correctly, if
   nothing conflicted.

## Decisions taken without a maintainer

No human was available during planning. Each of these is decided, not open;
they are listed because a maintainer may want to overturn one, and the reason
should survive.

1. **`rebase_onto_test.rb:65-70` is a settled invariant.** Decided in favor
   of a new file over amending the assertions, because the assertions are
   what keep `/wurk:refresh`'s rebase path unable to resolve, and a
   flag-guarded resolve path in a shared file is a weaker property that both
   callers inherit.
2. **The model is consulted from inside a script, `judge.rb`-style.**
   Decided over resolving from `/wurk:mr` prose, because the alternative
   leaves a worktree mid-rebase across a model turn and puts the abort on
   every error path in prose.

   **This is the one place the plan reinterprets the bead rather than
   following it literally, and it is the plan's load-bearing decision.** The
   bead's acceptance criterion says "no model judgment inside `scripts/`".
   `rebase_resolve.rb` does shell a `claude` CLI call from inside `scripts/`.
   The reading taken here is ADR-0008's: what must not live in a script is
   the judgment, and none does - the script holds prompt assembly,
   fail-closed parsing, and deterministic screens, while the verdict comes
   back from the model and the response to it is stated in `/wurk:mr`'s
   prose. `judge.rb` is the shipped precedent for exactly that, accepted in
   ADR-0008. A maintainer who reads the criterion literally instead would be
   rejecting `judge.rb`'s own shape, and should say so before Phase 3
   starts, because the alternative design (resolve from skill prose,
   worktree conflicted across a model turn) is a different plan, not a
   variant of this one.
3. **Allowlist, not denylist.** Decided over building lockfile / manifest /
   code predicates the kit does not have. Consequence: a consumer that opts
   in badly can widen the blast radius, which is why Phase 2 validates
   disjointness rather than documenting it - including against `.claude/`,
   which is how the bead's "manifest" stop category is enforced rather than
   merely observed by whoever writes the allowlist.
4. **The line-set invariant is strict enough to stop reflowed prose**, and
   therefore may stop the exact wu-902 incident that motivated the bead. Kept
   strict, per the bead's "bias hard toward stopping". Widening is future
   work gated on measurement.
5. **`/wurk:mr` only.** Decided as the bead leaned and the research supported,
   and enforced mechanically by leaving `RebaseOnto.perform` alone rather
   than by prose.
6. **`wurk-conflict-scout` is re-scoped, not superseded.** Every stop this
   plan produces is still a conflict a human has to triage, so the scout's
   job survives intact; only its "when refresh/mr abort" framing narrows.
7. **This repo's allowlist starts at exactly `["docs/plan.md"]`.** The
   narrowest setting that covers the motivating incident.

## References

- Bead: `wu-y7d`
- Source document: `docs/research/260811-wu-y7d-rebase-conflict-auto-resolution.md`
- New record: `docs/adr/0010-bounded-rebase-conflict-auto-resolution.md` (Phase 1)
- Related ADRs: `docs/adr/0008-merge-time-judge-over-generic-skill-prose.md`
  (the script/model/prose split and the fail-closed discipline),
  `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md` (the script
  contract), `docs/adr/0004-manifest-and-extension-seams.md` (extensions add,
  never override; a missing behavior means a missing schema field),
  `docs/adr/0005-gate-contract-tiers.md` (weaker is acceptable, vaguer is
  not - hence the named `stop_reason`)
- Similar implementation: `skills/wurk:kit/scripts/judge.rb:145-148` (the CLI
  call), `judge.rb:190-212` (fail-closed parsing),
  `skills/wurk:kit/scripts/test/judge_test.rb` (stubbing the CLI)
- Untouched by design: `skills/wurk:kit/scripts/rebase_onto.rb:44-54`,
  `skills/wurk:kit/scripts/test/rebase_onto_test.rb:65-70`,
  `skills/wurk:kit/scripts/worktree_refresh.rb:112`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The ADR states all six decisions above and does not defer any of them
- [ ] The ADR's answer to ADR-0008's open question 1 is legible to someone
      who has read ADR-0008 and not this plan
- [ ] The re-scoped backlog bullet still describes a thing worth doing, not a
      dead item kept for politeness
- [ ] Plain ASCII punctuation throughout, per CLAUDE.md

**Implementation Note**: Doc-only; CLAUDE.md says doc-only changes commit on
review of the diff. Run the gate anyway to prove nothing else moved.

---

### Phase 2

- [ ] `docs/manifest.md` and `lib/manifest.rb` agree, key for key, in this
      one commit
- [ ] Each new validation test genuinely fails when its guard is removed -
      delete each `validate_rebase` check in turn, re-run the suite, confirm
      red, restore. This is mutation testing and no command in this plan does
      it for you
- [ ] The disjointness error messages name both the entry and the list it
      collided with, so a consumer can fix it without reading the source
- [ ] No consumer-project constant appears in `lib/manifest.rb` or
      `lib/conflict_paths.rb`

**Implementation Note**: The field has no reader outside its own tests at the
end of this phase. That is intentional and the phase is still
gate-verifiable, because the validation refusals are the behavior being
added, not scaffolding for a later phase.

---

# Changed-file set: remote base ref and working-tree coverage

## Overview

Four kit call sites answer "what did this branch change" with
`git diff <manifest.default_branch>...HEAD`. That base ref is the *local*
default branch, which under worktree-per-issue is routinely behind
`origin/<default_branch>`, and two of the four sites see only committed
changes. This plan introduces one shared helper - `lib/base_ref.rb` - that
resolves the base ref remote-first (the ladder `judge.rb:89` already uses)
and returns the union of the branch diff and the working tree, then converts
each call site to it. Beads issue: `wu-821`

## Current State Analysis

Four sites, two distinct gaps.

**Base-ref gap (all four sites).** Each builds `"#{manifest.default_branch}...HEAD"`:

- `skills/wurk:kit/scripts/repo_state.rb:126-127` - `changed_files`,
  `touches_build`, `plan_docs`, `changelog_fragments`
- `skills/wurk:kit/scripts/gate.rb:100-101` - `gate_applicable?`, the commit
  carve-out shared with `/wurk:commit` Step 0
- `skills/wurk:kit/scripts/gate.rb:235` - `sabotage_diff_args`, the
  mutation-note scan pathspec
- `skills/wurk:kit/scripts/bead.rb:424` - `resolve_plan_doc_bead`, the
  strong-confidence bead candidate

`manifest.remote_default_branch` already exists (`lib/manifest.rb`, composes
`"origin/#{default_branch}"`) and is used by `rebase_onto.rb:42`,
`rebase_resolve.rb:84`, `worktree_refresh.rb:62,102`,
`worktree_survey.rb:138`, `worktree_create.rb:81`, and `judge.rb:89,230`.
None of the four sites above use it. In a worktree created a week ago from a
main checkout that has not fetched since, `main...HEAD` includes every file a
sibling branch landed in the interim - so `changed_files` over-reports,
`touches_build` and `gate_applicable?` can flip true for a branch that
touched nothing gated, and `resolve_plan_doc_bead` can resolve to *another*
bead's plan document with `strong` confidence.

**Working-tree gap (two of four sites).** `repo_state.rb:136` and
`gate.rb:110-113` already union `git status --porcelain` paths into the
change set, each with its own private copy of `parse_status_porcelain`
(`repo_state.rb:20-28` and `gate.rb:84-92` - byte-identical). The other two
do not:

- `sabotage_diff_args` scans only committed hunks, so a test declaration
  added in the working tree is invisible to the scan that exists to catch
  exactly that.
- `resolve_plan_doc_bead` misses a plan document that has been written but
  not yet committed - the common case immediately after `/wurk:plan`, where
  the strong candidate is precisely what `/wurk:work` wants.

`judge.rb:236-237` already shows the shape that closes the working-tree gap
for a hunk-level scan: resolve the base, `git merge-base <base> HEAD`, then a
*two-dot* `git diff <base_sha>`, which includes uncommitted tracked edits.
Untracked files appear in no diff at all.

### Key Discoveries:

- `judge.rb:87-92` is the reference ladder: first of `--base` override,
  `manifest.remote_default_branch`, `manifest.default_branch` for which
  `git rev-parse --verify --quiet <ref>` succeeds; `nil` when none resolve.
- `judge.rb:236-237` - `merge-base` + two-dot diff is the existing pattern
  for "branch changes including the working tree".
- `repo_state.rb:20-28` and `gate.rb:84-92` are duplicate parsers; the
  duplication is what let the two sites drift from `bead.rb` and
  `sabotage_diff_args` in the first place.
- `gate.rb`'s `scan_sabotage` (`:142-179`) already has an `unverifiable` channel
  with `{reason:, file:, text:, detail:}` entries that report a blind spot
  without flipping `ok` (wu-5fo, commits d95aed8/a7e9d54). An untracked test
  file is exactly that kind of blind spot.
- `test/contract_test.rb:549-556` bans hardcoded default-branch refs
  (`"origin/main"`, `"main...HEAD"`, `"refs/heads/main"`) in non-test kit
  source. Every ref in the new helper must come from `Manifest`.
- `test/support/fake_sh.rb` raises `UnexpectedCommand` for any unstubbed
  shell-out, so every phase that adds a `git rev-parse --verify` call must
  update that script's test stubs in the same commit.
- Tests read fixture manifests only (`test/fixtures/manifests/*.json`,
  `REFERENCE.md` "Fixture manifests"); never this repo's own.
- `docs/manifest.md:134-152` documents `repo.default_branch` as the ref every
  three-dot diff is taken against, and lists the affected behaviors. The
  prose becomes wrong the moment the ladder lands and must move with it.

## Desired End State

One helper, `skills/wurk:kit/scripts/lib/base_ref.rb`, owns three things:

1. `BaseRef.resolve(env, manifest:, override: nil)` - the remote-first
   ladder, emitting a `stale_base_ref` warning when it falls back from the
   remote ref to the local branch, and `nil` when neither resolves.
2. `BaseRef.working_files(env)` - the single `git status --porcelain` parse
   (tracked-dirty plus untracked), replacing both private copies.
3. `BaseRef.changed_files(env, manifest:)` - the union of the three-dot diff
   against the resolved base and `working_files`, uniq and sorted.

All four call sites read from it, and each script resolves the base exactly
once per invocation (`gate.rb` asks the changed-file question twice, so `run`
resolves and threads the answer down) - one ladder, one possible
`stale_base_ref` warning per envelope. The sabotage scan additionally sees
uncommitted tracked edits (merge-base two-dot diff) and reports untracked
files under the manifest's sabotage test roots as `unverifiable` rather than
silently skipping them.

Verify: the kit suite is green
(`ruby skills/wurk:kit/scripts/test/run.rb`), no non-test kit file contains
`"main...HEAD"` or `"origin/main"` (enforced by `contract_test.rb`), and
`grep -rn 'default_branch}\.\.\.HEAD' skills/wurk:kit/scripts` returns
nothing outside `lib/base_ref.rb`.

## What We're NOT Doing

- **Not fetching.** These are read-only, latency-sensitive scripts called on
  every commit; shelling out `git fetch` would make `repo_state.rb` depend on
  the network. If `origin/<default_branch>` is itself stale, that is
  `/wurk:refresh`'s job (`worktree_refresh.rb:53` already warns about exactly
  this). The remote-tracking ref is still strictly fresher than the local
  branch, which is what this bead asks for.
- **Not changing rename handling.** The shared parser keeps today's behavior
  of reporting only the destination path of an `R  old -> new` entry.
  Reporting both sides would widen `dirty_files` in `repo_state`'s envelope,
  which `/wurk:commit` Step 1 shows the user as the scope of the change; that
  is a separate call, not this bead's.
- **Not handling `core.quotepath` / embedded-space paths.** The existing
  `line[3..-1]` parse mishandles quoted paths; switching to `-z` parsing is a
  self-contained follow-up and would obscure this change's diff.
- **Not adding a manifest field.** No schema change, so `lib/manifest.rb` is
  untouched; `docs/manifest.md` changes are prose-accuracy only.
- **Not making the sabotage scan read untracked file contents.** Diff-shaped
  input is what `scan_sabotage` consumes; synthesizing pseudo-hunks for
  untracked files would mean a second, differently-behaved code path. The
  `unverifiable` channel reports them instead, which is what that channel
  exists for.
- **Not touching `rebase_*`, `worktree_*`, or `judge.rb`'s behavior.** They
  already use `remote_default_branch`; `judge.rb` only loses its private
  `resolve_base` in favor of the shared one, with no behavior change.

## Implementation Approach

Bottom-up: land the helper with its own tests first (additive, green on its
own), then convert one call site per phase. Each conversion is a separate
commit because each has a distinct test file whose `FakeSh` stubs must move
with it, and because each changes a different observable (`repo_state`
envelope fields, the gate carve-out, bead resolution, the sabotage report).
Phases 2-4 are independent of one another and could be worked in any order
after Phase 1.

---

## Phase 1: `lib/base_ref.rb` and judge adoption

### Overview

Add the shared helper with unit tests, and prove the extraction by having
`judge.rb` delegate to it - `judge.rb` already has the ladder, so its
existing tests pin the behavior the helper must preserve.

### Changes Required:

#### 1. New shared helper

**File**: `skills/wurk:kit/scripts/lib/base_ref.rb`
**Changes**: New module. Ladder, porcelain parse, and union in one place. All
refs from `Manifest`; no literal branch names (contract rule).

```ruby
# frozen_string_literal: true

require_relative "manifest"
require_relative "sh"

# One answer to "what did this branch change", for every kit script that
# asks. Two things were wrong with the per-site copies this replaces:
# they diffed against the LOCAL default branch, which under
# worktree-per-issue is routinely behind origin because sibling worktrees
# merge and push without every checkout fetching; and half of them saw
# only committed changes. See wu-821.
module BaseRef
  class << self
    # The first of override, the manifest's remote default branch, and its
    # local default branch that `git rev-parse --verify --quiet` accepts.
    # nil when none resolve. Warns when the remote ref is absent and the
    # local branch is used instead - that answer is knowably stale, and a
    # silent fallback is what this bead is about.
    def resolve(env, manifest: Manifest.current, override: nil)
      remote = manifest.remote_default_branch
      local = manifest.default_branch
      ref = [override, remote, local].compact.find do |candidate|
        Sh.run(["git", "rev-parse", "--verify", "--quiet", candidate], envelope: env).success?
      end
      if ref == local && override.nil?
        env.warn(code: "stale_base_ref",
                 message: "#{remote} did not resolve; diffing against local #{local}, " \
                          "which may be behind the remote")
      end
      ref
    end

    # Working-tree paths: tracked-but-uncommitted plus untracked. The single
    # definition site - repo_state.rb and gate.rb each carried a byte-
    # identical private copy of this parse before wu-821.
    def working_files(env)
      res = Sh.run(%w[git status --porcelain], envelope: env)
      parse_status_porcelain(res.out)
    end

    def parse_status_porcelain(out)
      out.to_s.each_line.map do |line|
        line = line.chomp
        next nil if line.empty?

        path = line[3..-1].to_s
        path.include?(" -> ") ? path.split(" -> ").last : path
      end.compact
    end

    # Every path this branch touched: the three-dot diff against the
    # resolved base, unioned with the working tree. An unresolvable base
    # warns and degrades to the working tree alone rather than reporting
    # [] - "nothing changed" would be a lie the callers act on.
    def changed_files(env, manifest: Manifest.current, override: nil)
      base = resolve(env, manifest: manifest, override: override)
      diff_files =
        if base
          res = Sh.run(["git", "diff", "--name-only", "#{base}...HEAD"], envelope: env)
          if res.success?
            res.out.to_s.each_line.map(&:strip).reject(&:empty?)
          else
            env.warn(code: "no_base_ref", message: "could not diff against #{base}")
            []
          end
        else
          env.warn(code: "no_base_ref", message: "no default-branch ref resolved")
          []
        end

      { base: base, diff_files: diff_files, files: (diff_files + working_files(env)).uniq.sort }
    end

    # merge-base of the resolved base and HEAD, for callers that want a
    # TWO-dot diff (which includes uncommitted tracked edits) rather than a
    # name list. nil when the base does not resolve. Mirrors judge.rb.
    def merge_base(env, base)
      return nil unless base

      sha = Sh.run(["git", "merge-base", base, "HEAD"], envelope: env).out.to_s.strip
      sha.empty? ? nil : sha
    end
  end
end
```

#### 2. Judge delegates the ladder

**File**: `skills/wurk:kit/scripts/judge.rb`
**Changes**: Delete the private `resolve_base` (`:87-92`); call
`BaseRef.resolve(env, manifest: manifest, override: base_override)` at `:229`
and `BaseRef.merge_base` at `:236`. Keep the `no_base_ref` skip and its
`tried` message verbatim. Add `require_relative "lib/base_ref"`. Judge's
`--base` override keeps priority over the remote ref, and passing an override
suppresses the `stale_base_ref` warning (an explicit base is not a fallback).

#### 3. Tests

**File**: `skills/wurk:kit/scripts/test/base_ref_test.rb` (new)
**Changes**: Fixture-manifest-driven (`trunk` fixture where one exists, so no
assertion can pass because the repo happens to use `main`). Cover: remote ref
wins when it resolves; fallback to local emits exactly one `stale_base_ref`
warning; both absent returns `nil` plus `no_base_ref`; override wins and
warns nothing; `parse_status_porcelain` over modified / added / untracked /
renamed lines; `changed_files` unions and sorts, and dedupes a path present
in both diff and status; a failed diff degrades to working files with a
warning; `merge_base` returns `nil` for a `nil` base.

**File**: `skills/wurk:kit/scripts/test/judge_test.rb`
**Changes**: Add the `git rev-parse --verify --quiet <remote>` stub to the
existing base-resolution tests. The `trunk` override test at `:339` must stay
green unchanged in intent.

No change is needed to `skills/wurk:kit/scripts/test/run.rb` - it globs
`**/*_test.rb` (`run.rb:19`), so the new file is picked up automatically.

#### 4. Reference doc

**File**: `skills/wurk:kit/REFERENCE.md`
**Changes**: Add `lib/base_ref.rb` to the shared-helpers description
alongside the existing `lib/gate_paths.rb` paragraph, stating the ladder and
that the working tree is part of the answer.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] `skills/wurk:kit/scripts/test/base_ref_test.rb` exists and its cases
      run (visible in the suite's test count)
- [x] `contract_test.rb`'s hardcoded-default-branch and banned-call checks
      pass over the new `lib/base_ref.rb`
- [x] `grep -n resolve_base skills/wurk:kit/scripts/judge.rb` shows no
      private definition remains

#### Manual Verification:
- [ ] `ruby skills/wurk:kit/scripts/judge.rb --dry-run` in this worktree
      still renders the same command list as before the change
- [ ] Each new test has a `# sabotage:` note (or a stated `n/a`) per this
      repo's convention
- [ ] No regressions in `/wurk:mr`'s judge step run by hand

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: `repo_state.rb` and the gate carve-out

### Overview

Convert the two sites that already union the working tree but diff against
the stale local branch, and delete both private `parse_status_porcelain`
copies. This is the phase that changes `/wurk:commit` Step 0's carve-out
input, so it lands on its own.

### Changes Required:

#### 1. Repo state

**File**: `skills/wurk:kit/scripts/repo_state.rb`
**Changes**: Delete `parse_status_porcelain` (`:20-28`); require
`lib/base_ref`. Replace `:98-99` and `:123-136` with:

```ruby
      dirty_files = BaseRef.working_files(env)
      dirty = !dirty_files.empty?
      ...
      changed = BaseRef.changed_files(env, manifest: manifest)
      changed_files = changed[:files]
```

Note the ordering constraint: `working_files` is called once for `dirty_files`
and `changed_files` re-derives its own union, so pass `dirty_files` in rather
than shelling out `git status` twice - add an optional
`working: nil` parameter to `BaseRef.changed_files` in this phase and hand it
the already-computed list. Keep the existing comment at `:123-125` but
restate it: the base is now the resolved remote-first ref. Add
`env.data[:base_ref] = changed[:base]` so a caller can see which ref the
answer was computed against, and keep `env.data[:default_branch]` unchanged
(it reports the manifest value, not the resolved ref).

#### 2. Gate carve-out

**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**: Delete `parse_status_porcelain` (`:84-92`); require
`lib/base_ref`. `gate.rb`'s `run` calls `gate_applicable?` (`:380`) and
`sabotage_scan` (`:382`) in the same process and the same envelope, and
Phase 4 gives `sabotage_scan` a base ref too. **Resolve once in `run` and
thread the result down**, rather than letting each method run the ladder:
`Envelope#warn` does not dedup (`lib/envelope.rb:33-36`), so two independent
ladders would emit two identical `stale_base_ref` warnings in one envelope,
and every full-run test would need two `rev-parse --verify` stubs.

```ruby
    # `changed` is resolved once per run (see run) and threaded in: the
    # ladder shells out, warns on fallback, and gate.rb asks this question
    # twice per invocation.
    def gate_applicable?(manifest, changed)
      GatePaths.gate_applicable?(changed[:files], manifest: manifest)
    end
```

and in `run`, immediately before `:380`:

```ruby
      changed = BaseRef.changed_files(env, manifest: manifest)
      applicable = gate_applicable?(manifest, changed)
```

Phase 4 then reads `changed[:base]` for the sabotage diff, so exactly one
ladder runs per `gate.rb` invocation. Keep the surrounding comment about
`gate_applicable?` vs `touches_build?`.

#### 3. Tests

**File**: `skills/wurk:kit/scripts/test/repo_state_test.rb`
**Changes**: Add a `expect_base_ref` helper stubbing
`git rev-parse --verify --quiet origin/main` (and `origin/trunk` for the
`trunk` fixture case at `:246-256`), and change every
`%w[git diff --name-only main...HEAD]` stub to `origin/main...HEAD`. Add
cases: remote-ref miss falls back to the local branch and surfaces the
`stale_base_ref` warning in the envelope; `data.base_ref` reports the
resolved ref.

**File**: `skills/wurk:kit/scripts/test/gate_test.rb`
**Changes**: Same stub updates for the carve-out tests at `:50-65` and the
`trunk` test at `:124-134` - exactly **one** `git rev-parse --verify --quiet`
stub per full run, since `run` now resolves once. The `sabotage_diff_args`
stub at `:71` stays on the old ref until Phase 4.

**File**: `skills/wurk:kit/scripts/test/base_ref_test.rb`
**Changes**: One case for the `working:` parameter added below - passing a
precomputed list means `git status --porcelain` is not shelled out again
(assert against `@fake.calls`, which is the only way to tell reuse from a
coincidentally identical re-derivation).

#### 4. Docs

**File**: `docs/manifest.md`
**Changes**: Rewrite the `repo.default_branch` section (`:134-152`) so the
diff base is described as the ladder - `origin/<repo.default_branch>` first,
the local branch as a warned fallback - and note that the change set includes
the working tree. Keep the "the remote is always `origin`, unconfigurable"
sentence.

**File**: `skills/wurk:commit/SKILL.md`
**Changes**: Only if its Step 0 prose asserts the diff is committed-only or
names the local branch as the base - check `:150-160` and correct if so;
otherwise leave untouched (extensions add, they never override, and skill
prose carries no branch constants).

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] `grep -n parse_status_porcelain skills/wurk:kit/scripts/repo_state.rb
      skills/wurk:kit/scripts/gate.rb` returns nothing
- [x] `repo_state_test.rb` has a case asserting the `stale_base_ref` warning
      appears in `warnings` when the remote ref is absent
- [x] `contract_test.rb` passes (no hardcoded refs introduced)

#### Manual Verification:
- [ ] `ruby skills/wurk:kit/scripts/repo_state.rb` in this worktree reports a
      `changed_files` list that matches `git diff --name-only
      origin/main...HEAD` plus `git status --porcelain` by eye
- [ ] With an uncommitted edit to a gated path and a clean commit history,
      `ruby skills/wurk:kit/scripts/gate.rb --dry-run` still reports the gate
      as applicable
- [ ] `docs/manifest.md` reads correctly against the code as landed

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: plan-document bead resolution

### Overview

`resolve_plan_doc_bead` produces a `strong`-confidence candidate. Both gaps
bite it: a stale base attributes a sibling's plan document to this branch,
and a committed-only view misses the plan `/wurk:plan` just wrote.

### Changes Required:

#### 1. Bead resolution

**File**: `skills/wurk:kit/scripts/bead.rb`
**Changes**: Require `lib/base_ref`. Replace `:423-426`:

```ruby
    def resolve_plan_doc_bead(env, manifest)
      files = BaseRef.changed_files(env, manifest: manifest)[:files]
      files.each do |f|
        m = File.basename(f).match(/\A\d{6}-(#{Refs.bead_id})-/)
        return m[1] if m
      end
      nil
    end
```

The `return nil unless diff_res.success?` guard goes away - `changed_files`
already degrades to the working tree with a warning, which is the better
answer here: a freshly written, uncommitted plan document is precisely the
case a failed diff should not erase. Because `files` is now sorted rather
than in git's diff order, a branch touching two plan documents resolves to
the lexicographically first; note that in the method comment - the
multi-plan-document case is already ambiguous and the ranking in
`Beads.rank_candidates` is what disambiguates candidates, not this order.

#### 2. Tests

**File**: `skills/wurk:kit/scripts/test/bead_test.rb`
**Changes**: Update the stubs at `:416-465` to `origin/main...HEAD` (and
`origin/trunk...HEAD` for the fixture case at `:465`), add the
`git rev-parse --verify --quiet` and `git status --porcelain` stubs, and add
a case where the diff is empty but `git status --porcelain` shows an
untracked `docs/plans/260814-zz-abc-....md` and the bead still resolves with
`strategy: "plan_doc"`, `confidence: "strong"`.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] A `bead_test.rb` case resolves a `plan_doc` candidate from an untracked
      plan file with no committed diff
- [x] `grep -n 'default_branch}\.\.\.HEAD' skills/wurk:kit/scripts/bead.rb`
      returns nothing

#### Manual Verification:
- [ ] In this worktree, before committing a new plan document,
      `ruby skills/wurk:kit/scripts/bead.rb resolve` reports the plan's bead
      as the strong candidate
- [ ] Resolution still prefers a seeded bead over the plan document

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 4: sabotage scan sees the working tree

### Overview

The sabotage scan exists to catch a test declaration that was never proved to
fail. Today it only reads committed hunks against a possibly stale base - so
the newest test on the branch, the one most likely to be unproved, is the one
it is least likely to see.

### Changes Required:

#### 1. Diff construction

**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**: Replace `sabotage_diff_args` (`:230-238`) with a form that takes
a resolved merge-base sha and produces a **two-dot** diff, which includes
uncommitted tracked edits:

```ruby
    # Two-dot against the merge-base sha, not `<base>...HEAD`: the two-dot
    # form includes uncommitted tracked edits, and an unproved test
    # declaration is likeliest to be exactly that. Same shape as judge.rb.
    # The pathspec keeps the corpus exemptions out at the git level.
    def sabotage_diff_args(manifest, base_sha)
      ["git", "diff", base_sha, "-U0", "--"] +
        manifest.sabotage_test_roots +
        manifest.sabotage_exempt_prefixes.map { |prefix| ":!#{prefix}" }
    end
```

`sabotage_scan` takes the base as a parameter -
`sabotage_scan(env, manifest, base)` - fed `changed[:base]` from the single
resolution Phase 2 put in `run`, and calls only `BaseRef.merge_base(env, base)`
itself. It never runs the ladder a second time, so one `gate.rb` invocation
emits at most one `stale_base_ref` warning and each full-run test needs
exactly one `rev-parse --verify` stub. A `nil` base (or a `nil` merge base)
returns the existing `{scanned: false, ...}` shape with an `unverifiable`
entry of `reason: "no_base_ref"`, matching the `diff_failed` precedent at
`:246-251`.

#### 2. Untracked test files

**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**: After a successful scan, append one `unverifiable` entry per
untracked path (from `BaseRef.working_files`, filtered to `??` origin) that
lies under a `manifest.sabotage_test_roots` prefix and outside
`sabotage_exempt_prefixes`:

```ruby
{ reason: "untracked", file: path, text: nil, detail: nil }
```

This requires `working_files` to distinguish untracked from tracked-dirty, so
extend `BaseRef` with `untracked_files(env)` (same parse, filtered on the
`??` status prefix) rather than re-parsing porcelain in `gate.rb`. Bump the
`lib/base_ref.rb` tests accordingly. Report-only: `unverifiable` never flips
`ok`, exactly as wu-5fo established.

#### 3. Tests

**File**: `skills/wurk:kit/scripts/test/gate_test.rb`
**Changes**: Update the sabotage stub at `:71` to the merge-base form
(`git merge-base origin/main HEAD`, `git diff <sha> -U0 -- test/ :!...`).
The `git rev-parse --verify --quiet origin/main` stub is the one Phase 2
already added for `run`'s single resolution - do not add a second. Assert
that `@fake.calls` contains exactly one `rev-parse --verify` call and that
the envelope carries at most one `stale_base_ref` warning per run. Add cases:
an uncommitted test
declaration with no note lands in `missing`; an untracked file under a test
root produces one `untracked` unverifiable entry and leaves `ok` true; an
untracked file under an exempt prefix produces none; an unresolvable base
returns `scanned: false` with a `no_base_ref` unverifiable entry.

**File**: `skills/wurk:kit/scripts/test/base_ref_test.rb`
**Changes**: Cases for `untracked_files` - `??` lines only, exempting
tracked-modified and staged-added lines.

#### 4. Docs

**File**: `docs/manifest.md`
**Changes**: Update the `gate.sabotage` documentation and the
`repo.default_branch` bullet list so the sabotage pathspec is described as a
two-dot diff against the merge base with the resolved ref, and so the
`unverifiable` reasons list includes `untracked` and `no_base_ref`.

**File**: `skills/wurk:kit/REFERENCE.md`
**Changes**: Same, wherever the `unverifiable` reason vocabulary is stated.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [ ] `gate_test.rb` has a case where an uncommitted, un-noted test
      declaration appears in `data.sabotage.missing`
- [ ] `gate_test.rb` has a case where an untracked test file yields exactly
      one `unverifiable` entry with `reason: "untracked"` and `ok` stays true
- [ ] `gate_test.rb` asserts a full run makes exactly one
      `git rev-parse --verify --quiet` call and emits at most one
      `stale_base_ref` warning
- [ ] `grep -rn 'default_branch}\.\.\.HEAD' skills/wurk:kit/scripts` returns
      nothing

#### Manual Verification:
- [ ] Add an un-noted test to this repo's suite without committing it, run
      `ruby skills/wurk:kit/scripts/gate.rb`, and confirm it is reported
- [ ] Create the same test as a brand-new untracked file and confirm it
      appears as `unverifiable`/`untracked` rather than as a false green
- [ ] The `unverifiable` report reads clearly enough for a human to act on

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/base_ref_test.rb` (new) - the ladder in all four states (remote hit,
  local fallback with warning, override wins silently, nothing resolves),
  porcelain parsing across modified/added/deleted/untracked/renamed lines,
  the diff+working-tree union's dedupe and sort, the `working:` parameter
  suppressing a second `git status --porcelain` shell-out, `merge_base` on a
  `nil` base, and `untracked_files`' `??` filter.
- `test/repo_state_test.rb`, `test/gate_test.rb`, `test/bead_test.rb` - stub
  updates plus one new behavior case each (stale-base warning surfaced,
  uncommitted/untracked test declaration seen, untracked plan document
  resolved).
- `test/judge_test.rb` - unchanged assertions, stub updates only; it is the
  regression net for the extracted ladder.
- `test/contract_test.rb` - no new cases needed; its existing
  hardcoded-default-branch sweep covers `lib/base_ref.rb` automatically.
- Every new test carries a `# sabotage:` note naming the mutation that turns
  it red, per this repo's convention (`gate_test.rb:124` is the model).
- All manifest-derived values come from `test/fixtures/manifests/*.json`; the
  `trunk` fixture is what proves the ref was read rather than hardcoded.

### Manual Testing Steps:

1. In a worktree whose local `main` is behind `origin/main`, run
   `ruby skills/wurk:kit/scripts/repo_state.rb` and confirm `changed_files`
   no longer contains files landed by sibling branches.
2. Delete the remote-tracking ref locally
   (`git update-ref -d refs/remotes/origin/main` in a scratch clone) and
   confirm the `stale_base_ref` warning appears and the script still answers.
3. With an uncommitted edit to a gated path, confirm
   `ruby skills/wurk:kit/scripts/gate.rb --dry-run` reports the gate as
   applicable.
4. Write a plan document without committing it and confirm
   `bead.rb resolve` returns it as the strong candidate.
5. Add an un-noted test both as an uncommitted edit and as an untracked file;
   confirm the first is `missing` and the second `unverifiable`.

## References

- Bead: `wu-821`
- Reference ladder: `skills/wurk:kit/scripts/judge.rb:87-92`, `:229-237`
- Manifest accessor: `skills/wurk:kit/scripts/lib/manifest.rb`
  (`remote_default_branch`), used at `skills/wurk:kit/scripts/worktree_refresh.rb:102`
- Duplicate parsers being removed: `skills/wurk:kit/scripts/repo_state.rb:20-28`,
  `skills/wurk:kit/scripts/gate.rb:84-92`
- Unverifiable channel precedent: `skills/wurk:kit/scripts/gate.rb:180-197`,
  `docs/plans/260813-wu-5fo-unverifiable-sabotage-scan-channel.md`
- Base-ref-from-manifest precedent:
  `docs/plans/260810-wu-2cb-default-branch-base-ref-from-manifest.md`
- Contract rules: `skills/wurk:kit/scripts/test/contract_test.rb:398-418`, `:549-556`
- Related ADRs: `docs/adr/0004-manifest-and-extension-seams.md`,
  `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`
- Docs to keep in sync: `docs/manifest.md:134-152`, `skills/wurk:kit/REFERENCE.md`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] `ruby skills/wurk:kit/scripts/judge.rb --dry-run` in this worktree
      still renders the same command list as before the change
- [ ] Each new test has a `# sabotage:` note (or a stated `n/a`) per this
      repo's convention
- [ ] No regressions in `/wurk:mr`'s judge step run by hand

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 2

- [ ] `ruby skills/wurk:kit/scripts/repo_state.rb` in this worktree reports a
      `changed_files` list that matches `git diff --name-only
      origin/main...HEAD` plus `git status --porcelain` by eye
- [ ] With an uncommitted edit to a gated path and a clean commit history,
      `ruby skills/wurk:kit/scripts/gate.rb --dry-run` still reports the gate
      as applicable
- [ ] `docs/manifest.md` reads correctly against the code as landed

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 3

- [ ] In this worktree, before committing a new plan document,
      `ruby skills/wurk:kit/scripts/bead.rb resolve` reports the plan's bead
      as the strong candidate
- [ ] Resolution still prefers a seeded bead over the plan document

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

# Manifest-driven default branch base ref Implementation Plan

## Overview

Kit scripts hardcode `main` as the branch every comparison is made against:
`git diff main...HEAD` in four places, `origin/main` in six more. A consumer
whose default branch is `master`, `trunk`, or `develop` gets silently wrong
answers from `/wurk:commit` Step 0, `/wurk:mr`, `/wurk:refresh` and the
merge-time judge - not an error, a wrong result, which is worse. This plan
adds one manifest field, `repo.default_branch` (default `"main"`), threads it
through every kit script that names a branch on a code line, and adds a
contract-test guard so the constant cannot come back. Beads issue: `wu-2cb`.
Explicitly deferred from `wu-gd1`
(`docs/plans/260808-wu-gd1-gate-rb-manifest-driven-constants.md:126-134`).

## Current State Analysis

Two distinct shapes, and the difference matters for how each is fixed.

**Shape A - the three-dot diff against the local default branch.** "What did
this branch change, relative to where it forked?" Four sites:

1. `skills/wurk:kit/scripts/gate.rb:90` - `git diff --name-only main...HEAD`
   inside `gate_applicable?`, feeding the carve-out predicate. On failure it
   warns `no_main_ref` (`gate.rb:95`) and treats the branch as having changed
   nothing.
2. `skills/wurk:kit/scripts/gate.rb:165` - `git diff main...HEAD -U0 --`
   inside `sabotage_diff_args`, the pathspec built in `wu-gd1` phase 2. Its
   trailing arguments are already manifest data; only the ref is not.
3. `skills/wurk:kit/scripts/repo_state.rb:117` - the same diff, feeding
   `touches_build`, `plan_docs` and `changelog_fragments`. Same `no_main_ref`
   warning at `:122`. The comment at `:114-116` says this "matches /commit
   Step 0 and /merge-request's gate step exactly", so the three sites are
   already understood as one rule with three spellings.
4. `skills/wurk:kit/scripts/bead.rb:419` - `git diff main...HEAD --name-only`
   in `resolve_plan_doc_bead`, which finds the plan document on the branch to
   infer the bead. A wrong base here returns the wrong bead id, or none.

**Shape B - the remote tracking ref.** "Where is the shared branch now?" Six
sites, all `origin/main`:

- `worktree_create.rb:81-87` - the base-ref ladder, `origin/main` falling back
  to local `main` when `git fetch origin` fails, with the fallback reported in
  `data.base_ref` and a warning.
- `rebase_onto.rb:41`, `:55`, `:107` - `git rebase origin/main`,
  `git rev-parse origin/main`, and the dry-run rendering of the same.
- `worktree_refresh.rb:58` - `git rev-parse origin/main` for the swept-to SHA
  (`data.origin_main`), and `:97` - `git merge-base --is-ancestor origin/main
  HEAD` for staleness.
- `worktree_survey.rb:134` - the same ancestry check, surfaced as
  `ancestor_of_origin_main`.
- `judge.rb:88` - the base-ref ladder `[--base, "origin/main", "main"]`, plus
  the dry-run command rendering at `:302-303` and the `--base` help string at
  `:311`.

**What is not a branch name and must not be touched.** `main` appears in kit
source many times meaning "the main working tree", which is git-worktree
vocabulary independent of any branch name: `Manifest.main_checkout`
(`lib/manifest.rb:153`), `worktree_create.rb:208` `main_checkout_root`,
`repo_state.rb:80-82` where `checkout = is_main ? "main" : "worktree"` is a
two-valued checkout *kind*, `tmux_window.rb:209-243` `main_repo`,
`worktree_survey.rb:90-106` `main_checkout`, `rebase_onto.rb:127-158`
`main_checkout_for`. A naive find-and-replace over `main` breaks all of these
and changes envelope field names that skills read. This is the main risk in
the phase-2 diff and the reason the phase-3 guard is written against
ref-shaped spellings only.

**The schema today.** `lib/manifest.rb:65-81` (`KNOWN`), `:83-93` (`DEFAULTS`),
`:42-52` (`REQUIRED`) and `:463-472` (`validate!`) are the four places a new
field has to land. There is no `repo` or `git` section: the top-level surface
is `wurk beads forge gate parallelism tmux models artifacts commits changelog
release judge` (`lib/manifest.rb:66`). `fetch` (`:436-440`) applies `DEFAULTS`
and treats an explicit `null` as absent, so a test can turn a field back to
its default with `manifest_with(...)`.

**The tests that stub these commands.** `gate_test.rb:50,55,60,65,71,792`;
`repo_state_test.rb:52,79,97,124,146,179,199`; `bead_test.rb:416,430,446`;
`judge_test.rb:96,309,310`; `rebase_onto_test.rb:45,78,79,105,106,131,132,158,
159,188`; `worktree_refresh_test.rb:61,70,82,85,87,90,91,111,113,114,128,130,
131,134,173,175,176,186`; `worktree_survey_test.rb:65,75,125,134`;
`worktree_cleanup_test.rb:70,81,149,159`; `select_batch_test.rb:59`;
`worktree_create_test.rb:135,155,213,241,279`. `FakeSh` raises
`UnexpectedCommand` on any argv it was not told to expect, so an unthreaded
ref shows up as a hard failure rather than a silent pass.

## Desired End State

No kit script names a branch on a code line. Every comparison ref is built
from `Manifest#default_branch`, which reads `repo.default_branch` and defaults
to `"main"`. Concretely:

- `lib/manifest.rb` gains a `repo` section with one key, `default_branch`,
  optional, defaulting to `"main"`, validated as a git-ref-shaped string.
- Two accessors: `default_branch` (`"main"`) and `remote_default_branch`
  (`"origin/main"`). Every call site uses one of them.
- `repo_state.rb` reports the value it used as `data.default_branch`, so skill
  prose that needs the ref can read it from the envelope instead of restating
  the constant.
- `docs/manifest.md` documents the field in the same commit that adds it to
  `lib/manifest.rb` (CLAUDE.md hard rule), including the per-repo table row.
- `test/contract_test.rb` fails on any code line in `skills/wurk:kit/scripts/`
  (outside `test/`) matching a hardcoded ref spelling: `main...HEAD`,
  `main..HEAD`, `origin/main`, `refs/heads/main`.

Verify with `ruby skills/wurk:kit/scripts/test/run.rb` green, plus the greps in
each phase's Automated Verification.

Because the default is `"main"`, no existing consumer manifest and none of the
existing test fixtures need to change, and every existing `FakeSh` stub stays
correct. That is deliberate: it keeps each phase's diff to the threading
itself, and it means the proving work is carried by new tests that set
`repo.default_branch` to something else and assert the emitted argv changed -
which is the assertion that would go red if a site were missed. A phase that
only kept the old stubs green would prove nothing.

### Key Discoveries:

- `lib/manifest.rb:83-93` - `DEFAULTS` is the sanctioned home for a value the
  kit supplies when a consumer says nothing (`commits.trailer.key` = `Refs`,
  `judge.model` = `sonnet`). `"main"` belongs there and only there: it is
  git's own initial-branch convention, not a consumer's domain vocabulary, so
  it does not offend CLAUDE.md's hard rule the way `st-` or `mix quality`
  would. One defaulted definition site is the end state, not a leak.
- `lib/manifest.rb:625-637` - `collect_unknown_keys` only recurses into
  sections listed in `KNOWN`, so a new `repo` section needs both a `KNOWN[nil]`
  entry and its own `KNOWN["repo"]` entry or its keys escape validation
  entirely. `wu-gd1` hit exactly this with `gate.sabotage`
  (`260808-wu-gd1...md:108-110`).
- `lib/manifest.rb:436-440` - `fetch` returns the `DEFAULTS` value for an
  explicit `null`, so `manifest_with("valid", "repo" => {"default_branch" =>
  nil})` is a supported way to assert the default without a new fixture.
- `test/support/manifest_helper.rb:88-98` - `manifest_with` deep-merges, so a
  brand-new top-level section can be injected per test with no fixture churn.
- `test/contract_test.rb:153-169` - `CONSUMER_VOCABULARY` plus
  `consumer_vocabulary` is the exact shape phase 3 copies: a pure function over
  content, comments exempted by `each_code_line`, unit-tested on synthetic
  input by `ContractRulesTest`, applied to `non_test_files` by `ContractTest`,
  and backed by a planted-violation meta-test so it cannot go vacuous. The
  comment at `:147-152` is the precedent for tightening a pattern that would
  fire on an innocent spelling - the same care `repo_state.rb:82`'s `"main"`
  checkout kind needs here.
- `gate.rb:155-159` - `sabotage_diff_args` already takes `manifest`, so site 2
  needs no signature change at all.
- ADR-0004 (manifest and extension seams) and ADR-0006 (kit scripts, constants
  behind `lib/manifest.rb`) are the settled decisions this plan executes. It
  contradicts neither and adds no new direction, so it writes no ADR.
- `docs/architecture.md`'s script contract is untouched: no new shell-out
  bypasses `lib/sh.rb`, no script gains a push/PR/`bd close` capability, every
  envelope keeps its single-JSON-on-stdout shape, and `--dry-run` behavior only
  changes in which ref it renders.

## What We're NOT Doing

- **Not parameterizing the remote name.** Every shape-B site says
  `origin/<branch>`; `origin` stays hardcoded, as does `git fetch origin`
  (`worktree_create.rb:82`, `worktree_refresh.rb:47-53`). A non-`origin`
  remote is a different portability question with a different field
  (`repo.remote`), and none of the three named consumers has one. Bundling it
  would double phase 2's diff for a hypothetical. If a consumer ever needs it,
  the field slots into the same `repo` section this plan creates.
- **Not auto-detecting the default branch from git.** `git symbolic-ref
  refs/remotes/origin/HEAD` would answer without any manifest field, and is
  rejected: it costs a shell-out on every script run, it is unset in a fresh
  clone until someone runs `git remote set-head`, and it answers differently
  in a worktree with a stale remote - so the same repo would gate against
  different refs depending on fetch state. ADR-0004 makes the manifest the
  seam for project-specific values; a value that changes under the script's
  feet is worse than one a human declared.
- **Not making the field required.** Required-with-no-default would make this
  commit break every existing consumer manifest, including this repo's own
  `.claude/wurk.json`, for a value that is `main` in all of them. Optional with
  a `"main"` default is the honest shape: the kit states its assumption in one
  place, and a consumer overrides it in one place.
- **Not renaming `main_checkout`, `main_repo`, `is_main`, `main_checkout_root`
  or the `"main"` value of `repo_state.rb`'s `checkout` field.** These are
  git-worktree vocabulary meaning "the primary working tree", not branch names,
  and `data.is_main` / `data.checkout` are envelope fields skills read
  (`skills/wurk:mr/SKILL.md:52`). Renaming them would be a breaking envelope
  change for zero portability gain.
- **Not touching prose that names `main` as an example.** `docs/manifest.md`,
  `docs/architecture.md`, ADRs and existing plan documents may name a
  consumer's actual value; the hard rule is about kit source. The one prose
  exception is `skills/wurk:mr/SKILL.md:60`, which is an *instruction to run a
  command* rather than an example, and phase 3 fixes it.
- **Not touching `test/fixtures/plans/real_grammar_snapshot.md`.** It is a
  frozen snapshot of a real plan used as test input for the plan grammar
  checker; editing it would change what the grammar tests measure.
- **Not writing an ADR.** ADR-0004 and ADR-0006 already settle that
  project-specific constants live in the manifest. This is their application.
  Schema growth is documented in `docs/manifest.md`, per CLAUDE.md.
- **Not backfilling any consumer's `.claude/wurk.json`.** All three consumers
  and wurk itself use `main`, so all four correctly declare nothing and take
  the default. The first consumer that does not is the one that adds the key.

## Implementation Approach

Three phases, each one commit, each green on
`ruby skills/wurk:kit/scripts/test/run.rb` on its own.

The split is by *shape*, not by file, because the two shapes have different
risk profiles. Phase 1 is shape A - the three-dot diff, which is the bead's
literal scope and the one whose wrongness is silent (a wrong base yields a
plausible-looking file list). Phase 2 is shape B - the remote ref, whose
wrongness is loud (git errors out on an unknown ref), but which must be done
for the field to mean anything: shipping `repo.default_branch` while
`git rebase origin/main` stays hardcoded delivers a manifest field that does
not make the kit portable, and a `master` consumer would still have a broken
`/wurk:refresh`. Phase 3 is the guard, last so it can assert the end state of
both, plus the one skill-prose site.

Phase 1 carries the schema because the schema has no reason to exist without a
reader: `lib/manifest.rb`, `docs/manifest.md`, the accessors, the four call
sites and their tests are one reviewable unit, and the phase's gate exercises
the new accessor through both `manifest_test.rb` and the four scripts. This
mirrors `wu-gd1`'s phase shape, where each phase was schema-plus-code-plus-
docs-plus-tests for one behavior.

Phase 2 is droppable without leaving anything half-migrated: phase 1 is
internally complete and phase 3's guard is what makes phase 2 non-optional in
practice. If phase 2 is ever deferred, phase 3's guard pattern must be
narrowed in the same breath, and the plan says so in that phase.

Every phase keeps `docs/manifest.md` and `lib/manifest.rb` in sync inside its
own commit (CLAUDE.md hard rule).

Style note for the implementer: every file this plan touches is plain-ASCII
(hyphens, not em dashes). Match that.

---

## Phase 1: The schema field and the three-dot diff sites

### Overview

Add `repo.default_branch` to the manifest with a `"main"` default and
ref-shape validation, and thread it through the four `<branch>...HEAD` diff
sites in `gate.rb`, `repo_state.rb` and `bead.rb`.

### Changes Required:

#### 1. Manifest schema
**File**: `skills/wurk:kit/scripts/lib/manifest.rb`
**Changes**: add `repo` to `KNOWN[nil]` and a `KNOWN["repo"]` entry, add the
default, add a validation rule, add two accessors. Not added to `REQUIRED`.

```ruby
# KNOWN[nil] gains "repo"
KNOWN["repo"] = %w[default_branch]

# DEFAULTS gains:
"repo.default_branch" => "main"

# validate! gains: validate_default_branch

# Git ref-name shape, deliberately narrower than git-check-ref-format(1):
# the value is spliced into an argv git already interprets positionally, so
# a leading "-" would become an option rather than a ref. Slashes are
# allowed (release/next is a legitimate default branch); whitespace, "..",
# "~", "^", ":" and a leading "-" are not.
DEFAULT_BRANCH_RE = %r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}

def validate_default_branch
  value = fetch("repo.default_branch")
  return if value.is_a?(String) && value.match?(DEFAULT_BRANCH_RE) && !value.include?("..")

  errors << "#{path}: repo.default_branch must be a git branch name " \
            "(letters, digits, '.', '_', '/', '-'; no leading '-'), got #{value.inspect}"
end

# The branch every "what did this branch change" comparison is made
# against. Defaults to "main" - git's own convention, stated once here
# rather than spelled into each script's argv.
def default_branch
  fetch("repo.default_branch")
end

# The same branch on the shared remote. The remote name is not configurable
# (see the plan's What We're NOT Doing); only the branch is.
def remote_default_branch
  "origin/#{default_branch}"
end
```

`validate_default_branch` needs no `nil` guard: `fetch` applies the default,
so the value is only ever absent-and-defaulted or explicitly wrong.

#### 2. Schema documentation
**File**: `docs/manifest.md`
**Changes**: add a `repo` block to the jsonc sample above `beads` (it is the
most repo-level thing in the file), a `## repo.default_branch` subsection
stating what it is used for and that it is *not* the remote name, a
`repo.default_branch` row in the per-repo starting values table
(`docs/manifest.md:239`) filling its three existing columns - statifier-ex,
predicator-ex, fixative - with `main`, adding no new column (the table has
never carried one for wurk's own manifest, and adding one is a larger
unrequested change), and a line in "Required, optional, and defaults" listing
`repo.default_branch` = `main` among the applied defaults.

```jsonc
"repo": {                           // (opt)
  "default_branch": "main"          // (opt) default "main"; the branch every
                                    // "what did this branch change" diff is
                                    // taken against
},
```

The subsection must say which behaviors move when it changes - the commit
carve-out, the sabotage pathspec, plan-document bead resolution, worktree
rebasing and the judge's base ref - so a consumer setting it to `master` knows
what it just re-pointed.

#### 3. gate.rb
**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**: build both refs from the manifest. `gate_applicable?` already
takes `manifest`; `sabotage_diff_args` already takes `manifest`.

```ruby
def gate_applicable?(env, manifest)
  base = manifest.default_branch
  diff_res = Sh.run(["git", "diff", "--name-only", "#{base}...HEAD"], envelope: env)
  diff_files =
    if diff_res.success?
      diff_res.out.to_s.each_line.map(&:strip).reject(&:empty?)
    else
      env.warn(code: "no_base_ref", message: "could not diff against local #{base}")
      []
    end
  # ... unchanged
end

def sabotage_diff_args(manifest)
  ["git", "diff", "#{manifest.default_branch}...HEAD", "-U0", "--"] +
    manifest.sabotage_test_roots +
    manifest.sabotage_exempt_prefixes.map { |prefix| ":!#{prefix}" }
end
```

The warning code changes from `no_main_ref` to `no_base_ref`: the old code
asserts a branch name that is now configurable. A grep over `docs/`, `skills/`
and `agents/` finds no reader of `no_main_ref` outside the two scripts and
their tests, so this is safe here; see Open Questions for the one thing that
grep could not cover. Also update the module doc if it names the ref.

#### 4. repo_state.rb
**File**: `skills/wurk:kit/scripts/repo_state.rb`
**Changes**: same substitution at `:117`, same warning-code rename at `:122`,
and update the `:114-116` comment so it says "the manifest's default branch"
rather than "local `main`". Add the value to the envelope so skills need not
restate it:

```ruby
env.data[:default_branch] = manifest.default_branch
```

Place it next to `env.data[:is_main]` (`:136`). This is a purely additive
envelope field; no existing reader changes.

#### 5. bead.rb
**File**: `skills/wurk:kit/scripts/bead.rb`
**Changes**: `bead.rb` names `Manifest` nowhere today (`grep -c Manifest
skills/wurk:kit/scripts/bead.rb` returns 0). `run_resolve` (`:386-416`) holds
no manifest local; `Refs.bead_id` works only because `lib/refs.rb:28` defaults
its own `manifest:` parameter to `Manifest.current` internally. So this is not
a threading job, it is a new load: add `manifest = Manifest.require!(env)` at
the top of `run_resolve`, `return env.emit(io) unless manifest` on failure
(the pattern `rebase_onto.rb` and `worktree_survey.rb` use), and pass it down.
Do not reach for `Manifest.current` inside the method - every other script in
the kit passes it explicitly:

```ruby
def resolve_plan_doc_bead(env, manifest)
  diff_res = Sh.run(["git", "diff", "#{manifest.default_branch}...HEAD", "--name-only"], envelope: env)
  # ... unchanged
end
```

Update the single call site in the same file. Blocking on an unavailable
manifest is the right behavior here: silently skipping plan-doc resolution
would degrade the bead ladder to its weak `branch_prefix` rung without saying
so. `test/bead_test.rb`'s `resolve` tests already run inside
`with_manifest(FIXTURE)`, so the added load does not disturb them.

#### 6. Tests
**File**: `skills/wurk:kit/scripts/test/manifest_test.rb`
**Changes**: add cases for the default (`"main"` when the section is absent,
and when `repo.default_branch` is explicitly `null`), a declared value
(`"trunk"`), `remote_default_branch` (`"origin/trunk"`), and validation errors
for a non-string, an empty string, a leading-dash value (`"--upload-pack=x"`),
one containing `".."`, and one containing a space - each asserting the error
message names `repo.default_branch`. Add one asserting an unknown key under
`repo` warns rather than errors, which is what proves `KNOWN["repo"]` was
added and not just `KNOWN[nil]`.

**File**: `skills/wurk:kit/scripts/test/gate_test.rb`
**Changes**: existing stubs at `:50,55,60,65,71,792` stay as-is (the default is
`main`). Add two tests driven by
`manifest_with("gate_tier1", "repo" => {"default_branch" => "trunk"})`:

- the carve-out diff is stubbed as `git diff --name-only trunk...HEAD` and the
  run succeeds - which only passes if `gate_applicable?` reads the manifest,
  because a stub for `main...HEAD` would go unmatched and `FakeSh` would raise
  `UnexpectedCommand`;
- the sabotage pathspec is `git diff trunk...HEAD -U0 -- test/ :!...`, proving
  site 2 moved too.

Add one asserting the warning code is `no_base_ref` when the diff fails.

**File**: `skills/wurk:kit/scripts/test/repo_state_test.rb`
**Changes**: existing stubs stay. Add one test with a `"trunk"` override
asserting the stubbed `git diff --name-only trunk...HEAD` is the one consumed
and that `data.default_branch` is `"trunk"`; add one asserting
`data.default_branch` is `"main"` on a default manifest.

**File**: `skills/wurk:kit/scripts/test/bead_test.rb`
**Changes**: existing stubs at `:416,430,446` stay. Add one `resolve` test with
a `"trunk"` override, stubbing `git diff trunk...HEAD --name-only` returning a
plan document, and asserting the bead resolves with strategy `plan_doc`.

Every new test carries a `# sabotage:` note naming the mutation that would
make it red, per the convention throughout `test/` (e.g. `gate_test.rb:126`).

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] `grep -nE 'main\.\.\.HEAD' skills/wurk:kit/scripts/gate.rb skills/wurk:kit/scripts/repo_state.rb skills/wurk:kit/scripts/bead.rb`
      returns no matches
- [x] `grep -rn 'no_main_ref' skills/wurk:kit/scripts` returns no matches
- [x] `ruby skills/wurk:kit/scripts/lib/manifest.rb check` in this repo exits 0
      with `data.valid` true and no `unknown_key` warning
- [x] A manifest declaring `"repo": {"default_branch": "-x"}` is rejected:
      write it to a scratch file and confirm
      `ruby skills/wurk:kit/scripts/lib/manifest.rb check --file <scratch>`
      exits 1 with a message naming `repo.default_branch`
- [x] `docs/manifest.md` documents `repo.default_branch` in the same commit as
      the `lib/manifest.rb` change (`git show --stat` on the phase commit lists
      both)

#### Manual Verification:
- [ ] `ruby skills/wurk:kit/scripts/repo_state.rb` in this worktree reports the
      same `changed_files`, `touches_build` and `plan_docs` it did before the
      change, and now also `data.default_branch: "main"`
- [ ] The rewritten `repo_state.rb:114-116` comment still makes the "same rule
      as /commit Step 0 and /wurk:mr" point, so the three sites stay
      recognizably one rule
- [ ] `docs/manifest.md`'s new subsection tells a consumer with a `master`
      default branch exactly which behaviors change when they set the field
- [ ] Before merging, grep the sibling consumer checkouts (statifier-ex,
      predicator-ex) for `no_main_ref` - `grep -rn no_main_ref
      <checkout>/.claude`. If any extension file keys on the old warning code,
      revert the rename and change only the message text (Open Question 2).

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: The remote tracking ref sites

### Overview

Replace every `origin/main` on a code line with
`manifest.remote_default_branch`, across `worktree_create.rb`,
`rebase_onto.rb`, `worktree_refresh.rb`, `worktree_survey.rb` and `judge.rb`.

### Changes Required:

#### 1. worktree_create.rb
**File**: `skills/wurk:kit/scripts/worktree_create.rb`
**Changes**: at `:81-88`, build both rungs of the ladder from the manifest and
keep the offline fallback behavior identical:

```ruby
base_ref = manifest.remote_default_branch
fetch_res = Sh.run(%w[git fetch origin], chdir: root, envelope: env)
unless fetch_res.success?
  base_ref = manifest.default_branch
  env.warn(
    code: "fetch_failed",
    message: "git fetch origin failed (offline?); cutting #{name} from local " \
             "#{manifest.default_branch} instead of #{manifest.remote_default_branch}"
  )
end
```

`data.base_ref` keeps reporting whichever rung was used, unchanged in shape.

#### 2. rebase_onto.rb
**File**: `skills/wurk:kit/scripts/rebase_onto.rb`
**Changes**: `:41`, `:55` and the dry-run rendering at `:107` build the argv
from `manifest.remote_default_branch`. The module-doc line at `:20`
("Assumes `origin/main` has already been fetched by the caller") is a comment
and stays, reworded to say "the manifest's remote default branch" so it does
not read as a promise about a specific ref. Confirm `manifest` is in scope at
each site; `:127-133` already uses it for `warm_globs`.

#### 3. worktree_refresh.rb
**File**: `skills/wurk:kit/scripts/worktree_refresh.rb`
**Changes**: `:58` (`git rev-parse <remote default>`) and `:97`
(`git merge-base --is-ancestor <remote default> HEAD`). **The envelope field
`data.origin_main` (`:42`, `:59`) keeps its name** - renaming it would break
`/wurk:refresh`'s reading of it for no portability gain, the same argument
this plan makes for `is_main`. Add a comment at the field saying the name is
historical and the value is the manifest's remote default branch. The
comments at `:47-53` about a stale `origin/main` are prose and get the same
light rewording.

#### 4. worktree_survey.rb
**File**: `skills/wurk:kit/scripts/worktree_survey.rb`
**Changes**: `:134` builds its argv from the manifest - but `survey_one`
(`:121`) does not take a `manifest` parameter today, so add one and pass it
from the call site at `:101`; `run` already holds the manifest at `:79`. The
reported field `ancestor_of_origin_main` (`:135`, `:170`) keeps its name, for
the same reason as above - `select_batch.rb` and `/wurk:cleanup` read it.

#### 5. judge.rb
**File**: `skills/wurk:kit/scripts/judge.rb`
**Changes**: `resolve_base` (`:86-92`) takes the manifest and builds its
ladder from it; the dry-run renderings at `:302-303` and the `--base` help
string at `:311` follow. The skip message at `:228` names the refs it tried,
which becomes dynamic:

```ruby
def resolve_base(env, base_override, manifest)
  [base_override, manifest.remote_default_branch, manifest.default_branch].compact.find do |ref|
    Sh.run(["git", "rev-parse", "--verify", "--quiet", ref], envelope: env).success?
  end
end
```

The `no_base_ref` skip code at `:228` is unchanged - only the message text
moves.

#### 6. Kit reference
**File**: `skills/wurk:kit/REFERENCE.md`
**Changes**: `:308` documents the judge's ladder as "(`--base`, `origin/main`,
`main`, first to resolve wins)". Rewrite it as "(`--base`, then the manifest's
`repo.default_branch` on the remote, then locally)". REFERENCE.md is
documentation and may name example values, but this line reads as a
specification of the ladder, and a wrong specification is worse than a vague
one.

#### 7. Tests
**Files**: `test/worktree_create_test.rb`, `test/rebase_onto_test.rb`,
`test/worktree_refresh_test.rb`, `test/worktree_survey_test.rb`,
`test/worktree_cleanup_test.rb`, `test/select_batch_test.rb`,
`test/judge_test.rb`
**Changes**: existing stubs stay (the default is still `main`). Add one
override-driven test per script, each stubbing the `trunk`-flavored argv and
therefore failing with `FakeSh::UnexpectedCommand` if that script's site was
missed:

- `worktree_create_test.rb` - `data.base_ref` is `origin/trunk` on a
  successful fetch and `trunk` on a failed one, and the `git worktree add`
  argv carries `origin/trunk`;
- `rebase_onto_test.rb` - `git rebase origin/trunk` and
  `git rev-parse origin/trunk`, plus the dry-run `commands[]` naming
  `origin/trunk`;
- `worktree_refresh_test.rb` - `git rev-parse origin/trunk` and the ancestry
  check against `origin/trunk`, with `data.origin_main` still the reported
  field name;
- `worktree_survey_test.rb` - the ancestry check against `origin/trunk`;
- `judge_test.rb` - `base_call_expectations(base_ref: "origin/trunk")` and a
  case where neither `origin/trunk` nor `trunk` resolves, asserting the
  `no_base_ref` skip;
- `worktree_cleanup_test.rb` / `select_batch_test.rb` - only if their stubs
  are reached through a script this phase changed; if the ref they stub comes
  from `worktree_survey.rb`, one override test at the survey level covers
  them and no change is needed here. Confirm by reading, do not guess.

Each new test carries a `# sabotage:` note.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [ ] No `origin/main` outside a comment in kit source - decided by a command,
      not by eye:
      `ruby -e 'bad=Dir.glob("skills/wurk:kit/scripts/**/*.rb").reject{|f| f.include?("/test/")}.flat_map{|f| File.readlines(f).each_with_index.select{|l,_| l !~ /^\s*#/ && l.include?("origin/main")}.map{|_,i| "#{f}:#{i+1}"}}; abort(bad.join(", ")) unless bad.empty?'`
      exits 0
- [ ] `grep -rn 'origin/main' skills/wurk:kit/REFERENCE.md` returns no
      specification-shaped line (the judge ladder line is rewritten)
- [ ] Envelope field names are unchanged:
      `grep -rn 'origin_main\|ancestor_of_origin_main' skills/wurk:kit/scripts --include='*.rb'`
      still finds them, and `ruby skills/wurk:kit/scripts/worktree_survey.rb`
      still emits `ancestor_of_origin_main` per entry

#### Manual Verification:
- [ ] `ruby skills/wurk:kit/scripts/worktree_refresh.rb --dry-run` in the main
      checkout renders the same commands it did before the change
- [ ] `ruby skills/wurk:kit/scripts/judge.rb --help` describes the `--base`
      ladder without naming a branch, and still tells a caller what `--base`
      overrides
- [ ] `ruby skills/wurk:kit/scripts/worktree_create.rb --dry-run <args>` shows
      `origin/main` as the base ref in this repo and reports it in
      `data.base_ref`, i.e. the default path is genuinely unchanged

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 3: A contract-test guard, and the one skill-prose site

### Overview

Phases 1 and 2 remove the constant; nothing stops it coming back. Add a
contract rule beside the existing ones, and fix the single piece of skill
prose that instructs an agent to run a command against a hardcoded ref.

### Changes Required:

#### 1. The rule
**File**: `skills/wurk:kit/scripts/test/contract_test.rb`
**Changes**: add `Contract.hardcoded_default_branch` beside
`consumer_vocabulary` (`:153-169`), following the identical shape - a pure
function over content, comments exempt via `each_code_line`.

```ruby
# A branch name spliced into a git ref on a code line. The branch every
# comparison is made against is manifest data (repo.default_branch, ADR-0004);
# a script that spells it is a constant that belongs in the manifest.
#
# Ref-shaped spellings only, deliberately. "main" as a bare word is also
# git-worktree vocabulary for the primary working tree - repo_state.rb's
# `checkout` field is literally the string "main" meaning "not a worktree",
# and Manifest.main_checkout has nothing to do with branches. A guard that
# fired on those would cost a rename for no rule violation, the same trap
# the "elixir gate config" pattern above was tightened to avoid.
HARDCODED_REFS = {
  "three-dot diff base" => %r{\b(?:main|master|trunk|develop)\.\.\.?HEAD},
  "remote default branch" => %r{\borigin/(?:main|master|trunk|develop)\b},
  "refs/heads default branch" => %r{\brefs/heads/(?:main|master|trunk|develop)\b}
}.freeze

def hardcoded_default_branch(content)
  hits = []
  each_code_line(content) do |code, lineno|
    HARDCODED_REFS.each { |label, re| hits << [lineno, label] if code =~ re }
  end
  hits
end
```

#### 2. The application and its meta-check
**File**: `skills/wurk:kit/scripts/test/contract_test.rb`
**Changes**: add `test_no_hardcoded_default_branch_in_kit_source` over
`non_test_files`, with a failure message that says what to do ("build the ref
from `Manifest#default_branch` / `#remote_default_branch`"). Add
`ContractRulesTest` cases proving a comment mentioning `origin/main` is
exempt, a code line containing it is caught, and `Manifest.main_checkout` /
`is_main ? "main" : "worktree"` are *not* caught. Extend the existing
planted-violation meta-test with a synthetic
`Sh.run(["git", "diff", "main...HEAD"])` so the guard cannot go vacuous.

If phase 2 is ever deferred, this rule must ship with only the `three-dot
diff base` entry, and the other two added when phase 2 lands - a guard that
fails on unmigrated source is not a guard, it is a broken gate.

#### 3. The skill-prose site
**File**: `skills/wurk:mr/SKILL.md`
**Changes**: `:60` instructs the agent to run
`git log origin/main..HEAD --oneline`. Step 1 of that same skill already runs
`repo_state.rb`, which after phase 1 reports `data.default_branch`. Rewrite
the instruction to use it:

```bash
git log origin/<data.default_branch>..HEAD --oneline
```

with a sentence naming where the value comes from, so the skill states no
branch of its own. Keep the parenthetical at `:63-65` explaining why this
check is hand-run rather than taken from `repo_state.rb`'s `commits_ahead`.

This is the only skill that instructs a branch-named command; `/wurk:refresh`,
`/wurk:cleanup` and `/wurk:branch` all go through kit scripts. Confirm with
the grep in the criteria rather than trusting this sentence.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [ ] The guard actually runs over the real files:
      `ruby skills/wurk:kit/scripts/test/run.rb --name test_no_hardcoded_default_branch_in_kit_source`
      reports `1 runs, 0 failures` (a `0 runs` result means the test was named
      differently and this criterion proved nothing)
- [ ] The guard is not vacuous, permanently and unattended: the
      planted-violation meta-test in `ContractRulesTest` asserts a synthetic
      `Sh.run(["git", "diff", "main...HEAD"])` is caught, and
      `ruby skills/wurk:kit/scripts/test/run.rb --name test_no_hardcoded_default_branch_in_kit_source`
      proves the rule also runs over the real files (above)
- [ ] No false positive on worktree vocabulary: after the guard lands,
      `grep -rn 'main_checkout\|is_main\|main_repo' skills/wurk:kit/scripts --include='*.rb'`
      still finds every occurrence and the suite is green
- [ ] `grep -rn 'origin/main\|main\.\.\.HEAD' skills/wurk:*/SKILL.md` returns no
      matches

#### Manual Verification:
- [ ] One-time author sanity check on the guard: temporarily add
      `X = Sh.run(["git", "diff", "main...HEAD"])` to
      `skills/wurk:kit/scripts/repo_state.rb`, confirm the suite goes red
      naming that line, then revert. (This is a hand-run source mutation, so
      it is manual by nature; the meta-test above is its permanent form.)
- [ ] Read each `HARDCODED_REFS` pattern and ask what a false positive looks
      like - in particular whether `develop` or `trunk` appears as an ordinary
      word anywhere a ref-shaped context could form
- [ ] The failure message tells a future implementer what to do, not just that
      something is wrong
- [ ] `/wurk:mr` step 1 still reads as a runnable instruction - an agent
      following it knows to substitute the envelope value, and does not paste
      the angle brackets

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/manifest_test.rb` - the field itself: default applied when absent and
  when explicitly `null`, a declared value returned verbatim,
  `remote_default_branch` composing correctly, and the validation rejections
  (non-string, empty, leading `-`, containing `..`, containing whitespace),
  each asserting the message names `repo.default_branch`. Plus the
  unknown-key-under-`repo` warning, which is what proves `KNOWN["repo"]`
  exists rather than only `KNOWN[nil]`.
- `test/gate_test.rb`, `test/repo_state_test.rb`, `test/bead_test.rb` - one
  override-driven test each per phase-1 site. The proof mechanism is
  `FakeSh::UnexpectedCommand`: the test stubs only the `trunk`-flavored argv,
  so a site still spelling `main` raises rather than quietly passing. This is
  stronger than asserting on `env["commands"]`, which a dry-run path could
  satisfy without the real call moving.
- `test/worktree_create_test.rb`, `test/rebase_onto_test.rb`,
  `test/worktree_refresh_test.rb`, `test/worktree_survey_test.rb`,
  `test/judge_test.rb` - the same pattern for phase 2, plus assertions that
  the historical envelope field names (`origin_main`,
  `ancestor_of_origin_main`, `is_main`, `checkout`) are unchanged.
- `test/contract_test.rb` - `ContractRulesTest` cases for
  `hardcoded_default_branch` on synthetic content (hit on a code line, no hit
  on a comment, no hit on `main_checkout` / `is_main ? "main" : "worktree"`),
  plus the planted-violation meta-test.
- Every new test carries a `# sabotage:` note naming the mutation that would
  make it red, matching the convention throughout `test/`.

### Manual Testing Steps:

1. `ruby skills/wurk:kit/scripts/repo_state.rb` in this worktree - the file
   lists and `touches_build` match a pre-change run, and `data.default_branch`
   is `"main"`.
2. Create a scratch manifest declaring `"repo": {"default_branch": "trunk"}`
   and run `ruby skills/wurk:kit/scripts/lib/manifest.rb check --file <path>` -
   valid, no unknown-key warning. Change it to `"-x"` and confirm it is
   rejected by name.
3. `ruby skills/wurk:kit/scripts/gate.rb --dry-run` and
   `ruby skills/wurk:kit/scripts/worktree_refresh.rb --dry-run` in this repo -
   the rendered `commands[]` are byte-identical to a pre-change run, which is
   what "the default path is unchanged" means concretely.
4. Re-read `docs/manifest.md` against `lib/manifest.rb` field by field for the
   new section - the doc must follow the code exactly (CLAUDE.md hard rule).
5. Read `/wurk:mr` step 1 end to end as an agent would execute it.

## References

- Bead: `wu-2cb`
- Deferred from: `docs/plans/260808-wu-gd1-gate-rb-manifest-driven-constants.md:126-134`
- Shape A sites: `skills/wurk:kit/scripts/gate.rb:90`, `:165`,
  `skills/wurk:kit/scripts/repo_state.rb:117`,
  `skills/wurk:kit/scripts/bead.rb:419`
- Shape B sites: `skills/wurk:kit/scripts/worktree_create.rb:81-87`,
  `skills/wurk:kit/scripts/rebase_onto.rb:41`, `:55`, `:107`,
  `skills/wurk:kit/scripts/worktree_refresh.rb:58`, `:97`,
  `skills/wurk:kit/scripts/worktree_survey.rb:134`,
  `skills/wurk:kit/scripts/judge.rb:88`, `:228`, `:302-303`, `:311`
- Manifest authority: `skills/wurk:kit/scripts/lib/manifest.rb:42-93`,
  `:436-440`, `:463-472`
- Schema doc: `docs/manifest.md`
- Contract guard to model after: `skills/wurk:kit/scripts/test/contract_test.rb:140-169`,
  `:325-335`
- Fixture conventions: `skills/wurk:kit/scripts/test/support/manifest_helper.rb:66-98`
- Related ADRs: `docs/adr/0004-manifest-and-extension-seams.md`,
  `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`
- Skill prose site: `skills/wurk:mr/SKILL.md:60`

## Open Questions

None of these blocks implementation; each records a call made without a human
in the loop, and what would change it.

1. **Section name: `repo.default_branch` vs `forge.default_branch`.** Chosen:
   a new top-level `repo` section. The readers (`gate.rb`, `repo_state.rb`,
   `bead.rb`) never talk to a forge, so putting a git fact under `forge` would
   mean forge-free scripts reading a forge field. The cost is a new section
   holding one key. If the maintainer prefers not to grow the top-level
   surface, `forge.default_branch` is a one-line change to `KNOWN` and the
   accessors, with `docs/manifest.md` following in the same commit.
2. **Renaming the `no_main_ref` warning code to `no_base_ref` (phase 1).** A
   grep over this repo's `docs/`, `skills/` and `agents/` finds no reader, so
   the rename is safe here. What could not be checked from this worktree is
   whether a consumer repo's `.claude/wurk/*.md` extension file keys on the old
   code. Before merging, grep the sibling checkouts (statifier-ex,
   predicator-ex) for `no_main_ref`; if any extension matches on it, keep the
   old code and change only the message text.
3. **Whether phase 2 belongs in this bead at all.** The bead names three
   scripts and the three-dot diff; phase 2 goes wider on the argument that a
   `repo.default_branch` field which leaves `git rebase origin/main`
   hardcoded does not deliver portability, and that phase 3's guard would have
   to be written narrowly to accommodate the gap. If a reviewer disagrees,
   phase 2 splits off cleanly into its own bead - phase 1 stands alone, and
   phase 3 ships with only its `three-dot diff base` pattern.
4. **`develop` and `trunk` in the phase-3 guard patterns.** They are included
   so the guard catches a re-hardcoded ref under any common name, not just
   `main`. They are only matched in ref-shaped contexts (`X...HEAD`,
   `origin/X`, `refs/heads/X`), so an ordinary use of the word "develop" is not
   a hit. If a false positive does appear, drop the extra names and keep
   `main|master` - the guard's job is to catch a relapse, and a relapse will
   spell `main`.

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] `ruby skills/wurk:kit/scripts/repo_state.rb` in this worktree reports the
      same `changed_files`, `touches_build` and `plan_docs` it did before the
      change, and now also `data.default_branch: "main"`
- [ ] The rewritten `repo_state.rb:114-116` comment still makes the "same rule
      as /commit Step 0 and /wurk:mr" point, so the three sites stay
      recognizably one rule
- [ ] `docs/manifest.md`'s new subsection tells a consumer with a `master`
      default branch exactly which behaviors change when they set the field
- [ ] Before merging, grep the sibling consumer checkouts (statifier-ex,
      predicator-ex) for `no_main_ref` - `grep -rn no_main_ref
      <checkout>/.claude`. If any extension file keys on the old warning code,
      revert the rename and change only the message text (Open Question 2).

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

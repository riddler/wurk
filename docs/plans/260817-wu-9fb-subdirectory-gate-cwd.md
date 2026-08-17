---
date: 2026-08-17
planner: Claude
git_commit: 082f019b4f69f1725e2048055eb6b84b462244ae
branch: wu-9fb-subdirectory-gate-root
repository: wurk
beads_issue: wu-9fb
topic: "gate.cwd - gates rooted in a subdirectory of a monorepo consumer"
tags: [plan, kit, gate, manifest, monorepo]
status: ready
last_updated: 2026-08-17
last_updated_by: Claude
---

# gate.cwd for subdirectory-rooted gates Implementation Plan

## Overview

Add an optional `gate.cwd` field to the manifest schema: a repo-root-relative
directory that the kit passes as `chdir:` to `Sh.run` for the five consumer
gate commands (`gate.full`, `gate.loop`, `gate.report`, `gate.report_loop`,
`gate.attest`), so a monorepo consumer whose gated project lives in
`backend/` can keep `.claude/wurk.json` at the repo root. Every other path
the manifest names keeps its current repo-root-relative meaning. Then audit
and harden the kit's remaining repo-root assumptions, which until now have
been implicit in "the process cwd is the checkout root".

Beads issue: `wu-9fb`

The direction was decided and recorded before this plan:
`docs/research/260817-wu-9fb-subdirectory-gate-cwd.md`. Option (b) won;
the consumer-side wrapper-script pattern (option (a)) is explicitly not
blessed. This plan does not reopen that choice.

## Current State Analysis

**The mechanism already exists, unused for this purpose.** `Sh.run` takes
`chdir:` (`skills/wurk:kit/scripts/lib/sh.rb:65-68`) and `Sh.render` already
renders it into the envelope's `commands` audit trail as
`(cd <dir> && <argv>)` (`sh.rb:72-75`). The real runner turns it into
`Open3.popen3`'s `:chdir` option (`sh.rb:96-97`). Nothing new is needed at
the shell-out layer; this is a join, not new machinery.

**Exactly three production files execute manifest gate argv.** Verified by
grep over `skills/wurk:kit/scripts/**/*.rb` excluding `test/`:

- `gate.rb:340-344` (`run_quality`) - runs `gate.report_loop` / `gate.report`
  / `gate.loop` / `gate.full`, with no `chdir:` at all, so the child inherits
  gate.rb's own cwd.
- `gate.rb:474-475` - runs `gate.attest`, same, no `chdir:`.
- `worktree_create.rb:199` (real) and `worktree_create.rb:120` (dry-run
  preview render) - `gate.loop` with `chdir: path`, the new worktree.
- `worktree_refresh.rb:126` (real) and `worktree_refresh.rb:118` (dry-run
  preview render) - `gate.loop` with `chdir: path`, the refreshed worktree.

No other script runs a gate command. `repo_state.rb` and
`lib/conflict_paths.rb` consume gate *path lists*, never gate argv.

**The manifest has no notion of "the root of the checkout it was found in".**
`Manifest#path` is the located `.claude/wurk.json`
(`lib/manifest.rb:100`, `118-123`, `140-149`), and resolution walks up from
`Dir.pwd`, so gate.rb can legitimately be invoked from any subdirectory of a
checkout. Nothing derives the checkout root from `path` today; every
filesystem and pathspec use of a manifest path implicitly assumes
`Dir.pwd == <checkout root>`.

**Three sites depend on that implicit assumption** (this is the bead's audit
question, answered concretely):

1. `gate.rb:324` - `File.exist?(ledger_path)` for `gate.guard_ledger`.
   Resolved against `Dir.pwd`. Invoked from a subdirectory today, this
   silently reports `ledger_exists: false` for a ledger that exists.
2. `gate.rb:261` + `sabotage_diff_args` - `gate.sabotage.test_roots` and
   `exempt_prefixes` are handed to `git diff` as **pathspecs**, and git
   interprets pathspecs relative to the process cwd, not the repo root.
3. `gate.rb:103-107` (`DEFAULT_SABOTAGE_FILE_READER`) - reads working-tree
   files by the relative paths `git diff --name-only` printed, i.e. against
   `Dir.pwd`.

**What is genuinely already correct, and why.** `git diff --name-only` and
`git status --porcelain` - the only two path sources in `lib/base_ref.rb`
(`working_files`, `untracked_files`, `changed_files` at lines 36-77) - both
print repo-root-relative paths regardless of process cwd. So everything that
*matches* manifest path lists against git output is correct unchanged:
`GatePaths.touches_build?` / `gate_applicable?`
(`lib/gate_paths.rb:36-42`, fed from `BaseRef.changed_files`), its two
callers `gate.rb:95` and `repo_state.rb:121`, `lib/conflict_paths.rb:25`
(fed from git's conflict file list), and `Manifest#rebase_collision`
(`lib/manifest.rb:699-717`, pure string comparison), and
`sabotage_untracked_unverifiable` (`gate.rb:228-235`), which prefix-filters
`BaseRef.untracked_files` output. A monorepo consumer
writing `"build_paths": ["backend/lib/", "backend/mix.exs"]` gets correct
answers from all of them.

**Validation in `lib/manifest.rb` is pure.** Nothing in `validate!`
(`lib/manifest.rb:512-524`) touches the filesystem - not even the
`rebase.auto_resolve_paths` collision checks, which are string-only. This is
load-bearing for `manifest.rb check --file PATH`, which must work on a
fixture outside any checkout.

**Test seams are in place.** `FakeSh::Call` already records `chdir`
(`test/support/fake_sh.rb:20`, `51-52`) and matches expectations on argv
only, so adding a `chdir` does not invalidate existing expectations.
`ManifestHelper#in_tmp_repo` (`test/support/manifest_helper.rb:53-62`)
installs a fixture at `<tmpdir>/.claude/wurk.json` and chdirs in, which is
how `gate_test.rb`'s `in_tmp_cwd` already gets a predictable checkout root.
Note that `fixture_manifest` / `manifest_with` build a Manifest whose `path`
is `test/fixtures/manifests/<name>.json`, so a derived checkout root for
those is `test/fixtures` - fine for the worktree tests, which anchor on the
worktree path rather than the checkout root.

## Desired End State

A consumer repo may declare:

```json
"gate": {
  "cwd": "backend",
  "full": ["mix", "quality"],
  "loop": ["mix", "quality", "--profile", "loop"],
  "build_paths": ["backend/lib/", "backend/test/", "backend/mix.exs"]
}
```

and every kit script that runs one of the five gate commands runs it with the
child working directory at `<root of the checkout being gated>/backend`,
while every path-matching predicate keeps reading `backend/...` from the repo
root. The rule, stated in `docs/manifest.md`: **`gate.cwd` scopes execution
of consumer gate commands; it never rescopes matching of manifest paths.**

Verification that the end state holds:

- `ruby skills/wurk:kit/scripts/test/run.rb` is green, including new tests
  that assert the chdir is passed at all four call sites (gate quality, gate
  attest, worktree create, worktree refresh) plus both dry-run preview
  renders, and that an absent `gate.cwd` passes exactly today's `chdir`.
- `ruby skills/wurk:kit/scripts/lib/manifest.rb check` on this repo's own
  manifest still exits 0 with no new warnings (this repo declares no
  `gate.cwd`, and the field is now a known key so a consumer that does
  declare it gets no unknown-key warning).
- `docs/manifest.md` documents the field, its validation, and the
  execution-vs-matching rule, and its "Required, optional, and defaults"
  section says an absent `gate.cwd` means the checkout root.
- `gate.rb`'s guard-ledger check and sabotage scan resolve against the
  manifest's checkout root rather than `Dir.pwd`, so invoking `gate.rb` from
  a subdirectory produces the same envelope as invoking it from the root.

### Key Discoveries:

- `Sh.run`/`Sh.render` already support and audit-trail `chdir`
  (`skills/wurk:kit/scripts/lib/sh.rb:65-75`); the worktree scripts already
  pass it (`worktree_create.rb:199`, `worktree_refresh.rb:126`).
- Four production call sites plus two dry-run preview renders execute or
  render gate argv; there are no others
  (`gate.rb:344`, `gate.rb:475`, `worktree_create.rb:120` and `:199`,
  `worktree_refresh.rb:118` and `:126`).
- `Manifest` has no checkout-root accessor; `Manifest#path`
  (`lib/manifest.rb:100`) is the only anchor available, and
  `File.expand_path("..", File.dirname(path))` is the derivation.
- `git diff --name-only` output is repo-root-relative regardless of cwd,
  which is why `gate.build_paths` and friends stay root-relative
  (`lib/gate_paths.rb:44-51`). Git *pathspecs*, by contrast, are cwd-relative
  - that asymmetry is the whole audit finding.
- `validate!` is filesystem-free (`lib/manifest.rb:512-524`), and
  `ManifestCli` lints arbitrary files, so `gate.cwd` validation must be
  shape-only.
- ADR-0004 is the seam being used: "a consumer needing to change generic
  behavior means the manifest schema is missing a field", with the explicit
  consequence that such pressure "surfaces as schema work in this repo, where
  it is reviewed once for everyone". ADR-0005's tiers are untouched: `gate.cwd`
  changes where a tier's command runs, not which tier the project reached.
- CLAUDE.md hard rule: `docs/manifest.md` and `lib/manifest.rb` change in the
  same commit, code is authority.

## What We're NOT Doing

- **Not blessing the wrapper-script pattern.** Settled in the direction note;
  `bin/gate.sh` doing `cd backend && ...` stays merely possible, never
  documented as the answer, because it hides the real gate command from the
  envelope's `commands` trail and degrades tier-1 reporting review.
- **Not adding a cwd for `parallelism.trust` / `warm` / `repair` /
  `post_branch`.** Open question 1 of the direction note. A monorepo's
  `mix deps.get` warm command has the same problem, but `parallelism` is a
  different section with different semantics (`trust` genuinely wants the
  worktree root, and it is the one field carrying `{path}` substitution). If
  the need materializes it is a separate field decided then. `gate.cwd` is
  never silently applied to a non-gate command.
- **Not making any other manifest path cwd-relative.** `build_paths`,
  `also_gated_paths`, `moving_files`, `guard_ledger`, `sabotage.*`,
  `parallelism.repair_when`, `rebase.auto_resolve_paths`, `artifacts.*` all
  stay repo-root-relative. Making some lists cwd-relative and others not is
  the trap the direction note exists to refuse; the shared `backend/` prefix
  is mild repetition, not broken semantics.
- **Not validating that the `gate.cwd` directory exists.** Direction note
  open question 2, resolved here as no. `validate!` is filesystem-free by
  construction: `manifest.rb check --file PATH` lints fixtures outside any
  checkout, and a worktree path does not exist yet at the time
  `worktree_create.rb` validates. A probe would also make validation depend
  on the process cwd, which is the exact sensitivity this bead is about. Not
  even a warning - a warning that fires whenever the lint runs from the wrong
  place is noise, and the real failure (a wrong `gate.cwd`) surfaces
  immediately and loudly as the gate command failing to start.
- **Not adding `gate.cwd` to the `rebase.auto_resolve_paths` collision
  surface.** `gate.cwd` names where commands run, not a guarded path; a
  collision check against it would reject legitimate manifests (a monorepo's
  `gate.cwd` is a parent of everything it gates).
- **Not fixing `worktree_create.rb`/`worktree_refresh.rb` running
  `gate.loop` on `Sh.run`'s default 60-second timeout** rather than
  `manifest.gate_timeout_seconds`. Noticed while surveying the call sites and
  it looks like a real gap left by the `gate.timeout_seconds` commit
  (082f019), but it is a separate concern from cwd and belongs on its own
  bead so the fix is reviewed as a timeout change. File it; do not fold it in
  here.
- **Not touching `docs/gate-contract.md`'s tier definitions.** The tiers are
  about what a gate command can report, not where it runs. Its tier-0
  paragraph gets one cross-reference sentence in Phase 1 and nothing more.

## Implementation Approach

Two phases, both independently committable and both verified by
`ruby skills/wurk:kit/scripts/test/run.rb`.

Phase 1 is deliberately not split into "schema" then "call sites". A commit
that documents `gate.cwd` in `docs/manifest.md` while no script honors it
would hand a consumer a field that silently does nothing - the plan skill's
own rule ("a structure added in one phase and consumed in the next, with
nothing exercising it in between, is one phase") applies directly, and
CLAUDE.md's same-commit rule for `lib/manifest.rb` plus `docs/manifest.md`
pins the doc to the schema change. So Phase 1 lands the field end to end:
accessor, validation, doc, all four call sites, both dry-run renders, tests.

Phase 2 answers the bead's second half. The audit's finding is that the
root-relative semantics are correct where they are matched against git
*output*, and implicitly cwd-dependent at three sites that read the
filesystem or feed git *pathspecs*. Introducing an explicit checkout-root
concept in Phase 1 is what makes those three fixable rather than merely
documentable, so Phase 2 anchors them on `Manifest#checkout_root` and records
the execution-vs-matching contract in prose.

The design, concretely. `Manifest` gains:

```ruby
# The root of the checkout this manifest was located in: `path` is always
# <root>/.claude/wurk.json, so the root is two levels up. Every kit use of a
# repo-root-relative manifest path resolves against this rather than Dir.pwd,
# because manifest resolution walks up from the working directory (see
# `locate`) and gate.rb is legitimately invoked from a subdirectory.
def checkout_root
  File.expand_path(File.join(File.dirname(path), ".."))
end

# The repo-root-relative directory the five consumer gate commands run in,
# or nil when the project gates from its repo root (the common case).
# See docs/manifest.md: gate.cwd scopes EXECUTION of gate commands; it never
# rescopes MATCHING of manifest paths.
def gate_cwd
  fetch("gate.cwd")
end

# The `chdir:` to hand Sh.run for a gate command, given the root of the
# checkout being gated. nil when the project declares no gate.cwd, so the
# caller's own default applies unchanged - gate.rb passes no chdir at all,
# and the worktree scripts keep passing the worktree path.
def gate_chdir(root: checkout_root)
  gate_cwd && File.join(root, gate_cwd)
end
```

Returning nil rather than the root when the field is absent is the key
choice: it keeps the rendered `commands` audit trail byte-identical for every
consumer that does not use the field, so no existing envelope or test changes
shape.

Call sites become:

```ruby
# gate.rb run_quality and the attest call
res = Sh.run(argv, chdir: manifest.gate_chdir, envelope: env, timeout: manifest.gate_timeout_seconds)

# worktree_create.rb / worktree_refresh.rb, real runs and dry-run renders
chdir = manifest.gate_chdir(root: path) || path
```

## Phase 1: gate.cwd, end to end

### Overview

Add the field to the schema with shape-only validation, document it, and
honor it at all four execution sites and both dry-run preview renders. One
commit; `lib/manifest.rb` and `docs/manifest.md` move together per CLAUDE.md.

### Changes Required:

#### 1. Manifest schema and accessors
**File**: `skills/wurk:kit/scripts/lib/manifest.rb`
**Changes**: add `cwd` to the `gate` section's known keys, add
`checkout_root`, `gate_cwd`, and `gate_chdir`, and add shape-only validation
registered in `validate!`.

```ruby
# in KNOWN, the "gate" entry (currently line 72-73) - add "cwd":
"gate" => %w[cwd full loop report report_loop attest guard_ledger build_paths also_gated_paths
             moving_files project_level_skips not_applicable_skips sabotage timeout_seconds],
```

Accessors as given in "Implementation Approach" above, placed with the other
`gate_*` accessors (after `gate_timeout_seconds`, `lib/manifest.rb:278-280`);
`checkout_root` goes with the top-of-section accessors near
`default_branch`.

```ruby
# Shape only, never the filesystem - see docs/manifest.md and this plan's
# What We're NOT Doing. A `gate.cwd` that names a directory which does not
# exist fails loudly the first time the gate command tries to start; a
# validation-time probe would make `manifest.rb check` depend on the process
# cwd, which is the sensitivity gate.cwd exists to remove.
def validate_gate_cwd
  value = fetch("gate.cwd")
  return if value.nil?

  unless value.is_a?(String) && !value.empty?
    errors << "#{path}: gate.cwd must be a non-empty relative directory path, got #{value.inspect}"
    return
  end

  if value.start_with?("/")
    errors << "#{path}: gate.cwd must be relative to the repo root, got #{value.inspect}"
    return
  end

  if value == "." || value.split("/").include?("..")
    errors << "#{path}: gate.cwd must name a subdirectory of the repo root " \
              "(no '.', no '..' segments); omit the field to gate from the root, got #{value.inspect}"
  end
end
```

Register it in `validate!` next to `validate_gate_timeout_seconds`
(`lib/manifest.rb:522`).

#### 2. gate.rb - the quality run and the attest run
**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**: pass `chdir: manifest.gate_chdir` at both sites, and surface the
resolved directory in the envelope.

```ruby
# run_quality, replacing line 344
res = Sh.run(argv, chdir: manifest.gate_chdir, envelope: env, timeout: manifest.gate_timeout_seconds)

# the attest branch, replacing line 475
verify_res = Sh.run(manifest.gate_attest, chdir: manifest.gate_chdir, envelope: env,
                    timeout: manifest.gate_timeout_seconds)
```

`gate_chdir` defaults its root to `manifest.checkout_root`, not `Dir.pwd`, so
invoking gate.rb from inside the subdirectory does not double-apply the
prefix.

Also set, beside the other `env.data` gate fields (near `gate.rb:462-469`):

```ruby
# Resolved absolute directory the gate command ran in, or nil when the
# project gates from its checkout root. The `commands` trail already shows it
# via Sh.render; this makes it machine-readable for the skills.
env.data[:gate_cwd] = manifest.gate_chdir
```

This resolves direction-note open question 3 as yes.

Note the carve-out early return (`gate.rb:443-454`) must set
`env.data[:gate_cwd] = nil` alongside the other nulled fields, since no gate
command ran.

#### 3. worktree_create.rb - warm check and dry-run preview
**File**: `skills/wurk:kit/scripts/worktree_create.rb`
**Changes**: join `gate.cwd` onto the worktree path at both the render
(line 120) and the run (line 199). Add one private helper so the two cannot
drift:

```ruby
# The gate command runs in the new worktree - under gate.cwd inside it when
# the project gates from a subdirectory (wurk docs/manifest.md). One helper
# so the dry-run render and the real run cannot disagree about where.
def gate_chdir(manifest, path)
  manifest.gate_chdir(root: path) || path
end
```

```ruby
# line 120, in record_dry_run_steps
env.commands << Sh.render(manifest.gate_loop, chdir: gate_chdir(manifest, path))

# line 199, in create_and_warm
quality_res = Sh.run(manifest.gate_loop, chdir: gate_chdir(manifest, path), envelope: env)
```

#### 4. worktree_refresh.rb - post-rebase confirmation and dry-run preview
**File**: `skills/wurk:kit/scripts/worktree_refresh.rb`
**Changes**: identical treatment at lines 118 (`refresh_one`'s `dry_run`
branch) and 126 (`confirm_green`), with the same private helper. Keep the two
helpers as separate private methods in their own scripts rather than hoisting
a shared one into `lib/` - `Manifest#gate_chdir` is already the shared
definition site, and the `|| path` fallback is one expression.

#### 5. Manifest documentation
**File**: `docs/manifest.md`
**Changes**: four edits.

- The commented schema block (line 38-65): add `cwd` as the first `gate` key,
  since it scopes the rest.

  ```
  "gate": {                           // see docs/gate-contract.md for tiers
    "cwd": "backend",                 // (opt) repo-root-relative dir the five gate
                                      // commands RUN in; omit to run at the repo
                                      // root. Scopes execution only - every path
                                      // list below stays repo-root-relative.
  ```

- A new prose section, placed immediately before "Two path lists, not one"
  (line 379), titled ``## `gate.cwd` ``. It states: which five commands it
  applies to; that the resolved directory is
  `<root of the checkout being gated>/<cwd>`, which is the new worktree's
  root for `worktree_create.rb` and `worktree_refresh.rb`; the
  execution-vs-matching rule verbatim from the direction note; that it is
  never applied to `parallelism.*` commands or to any git command the kit
  itself runs; and a worked monorepo example showing
  `"cwd": "backend"` alongside `"build_paths": ["backend/lib/", ...]`.

- "Required, optional, and defaults" (line 505-514): add `gate.cwd` to the
  "absent means the capability is off" paragraph - "no `gate.cwd` means the
  gate commands run at the root of the checkout being gated".

- "Validation" (line 516-537): add a bullet - "**`gate.cwd` must be a
  relative subdirectory path.** An absolute path, `.`, `""`, a non-string,
  or any `..` segment blocks. Existence is deliberately not checked; see
  ``gate.cwd`` above."

#### 6. Kit reference and gate contract cross-references
**File**: `skills/wurk:kit/REFERENCE.md`, `docs/gate-contract.md`
**Changes**: in REFERENCE.md's `gate.rb` entry (around line 272-273, which
already enumerates the five commands), add that each runs in `gate.cwd` when
the manifest declares one, and that `data.gate_cwd` reports the resolved
directory. In `docs/gate-contract.md`'s tier-0 paragraph, one sentence: the
tier is about what a command reports, not where it runs; where it runs is
`gate.cwd`, see `docs/manifest.md`. Both files are generic, so neither may
name a consumer's actual subdirectory - `backend` appears only in
`docs/manifest.md`, which already carries per-repo example values.

#### 7. Fixture and tests
**File**: `skills/wurk:kit/scripts/test/fixtures/manifests/gate_subdir.json`
(new), `test/manifest_test.rb`, `test/gate_test.rb`,
`test/worktree_create_test.rb`, `test/worktree_refresh_test.rb`

New fixture: a copy of `gate_tier1.json` with `"cwd": "backend"` added to the
`gate` section and its path lists prefixed with `backend/`, so it also serves
as the worked example of the intended monorepo shape. Keep the `zz` prefix
and `make` commands so nothing in it can be confused with this repo's values
(`test/support/manifest_helper.rb:8-21`). Note
`ManifestHelper#all_fixture_guarded_paths` scans every fixture's
`moving_files` and `guard_ledger` for the contract test's guarded-write scan,
so prefixing those in the new fixture widens that union - intended and
harmless, but check the contract test stays green.

Tests to add:

- `manifest_test.rb`: `gate_cwd` returns the declared value and nil when
  absent; `checkout_root` is the directory two levels above `path`;
  `gate_chdir` joins onto the default root and onto an explicit `root:`;
  `gate_chdir` is nil when the field is absent, for both root forms; the new
  fixture produces no unknown-key warning (this is the regression that would
  fire if `KNOWN` were missed); validation rejects `"/abs/path"`, `"../up"`,
  `"a/../b"`, `"."`, `""`, and a non-string, each with the field named in the
  message; validation accepts `"backend"` and `"apps/backend"`, and does not
  touch the filesystem (assert a nonexistent directory still validates).
- `gate_test.rb`: with the subdir fixture installed via `in_tmp_repo`, the
  gate command's recorded `FakeSh::Call#chdir` equals
  `File.join(<tmpdir>, "backend")`, the attest call's does too,
  `data.gate_cwd` reports it, and the envelope's `commands` entry renders as
  `(cd <dir> && make report)`. With `gate_tier1` (no `cwd`), both calls'
  `chdir` is nil and `data.gate_cwd` is nil - this is the absent-field no-op
  case, and it is what guards the audit trail from changing shape for
  existing consumers. Plus: the carve-out path reports `gate_cwd: nil`.
- `worktree_create_test.rb`: with a `worktree` fixture variant carrying
  `gate.cwd` (via `manifest_with(FIXTURE, "gate" => {"cwd" => "backend"})`),
  the `gate.loop` call's `chdir` is `File.join(worktree_path, "backend")`,
  and the `--dry-run` envelope's last command renders the same directory.
  Without the field, `chdir` is the worktree path exactly as today.
- `worktree_refresh_test.rb`: the same two assertions for `confirm_green`'s
  run and the dry-run branch's render.

### Success Criteria:

#### Automated Verification:
- [x] `ruby skills/wurk:kit/scripts/test/run.rb` is green
- [x] `ruby skills/wurk:kit/scripts/lib/manifest.rb check` on this repo's
      manifest exits 0 with no warnings
- [x] `ruby skills/wurk:kit/scripts/lib/manifest.rb check --file skills/wurk:kit/scripts/test/fixtures/manifests/gate_subdir.json`
      exits 0 with `data.valid` true and an empty `warnings` array
- [x] `ruby skills/wurk:kit/scripts/gate.rb --profile loop` on this repo
      still emits `data.gate_cwd: null` and a `commands` entry with no
      `(cd ...)` wrapper
- [x] `grep -n '^## `gate.cwd`' docs/manifest.md` returns exactly one hit
      (the new prose section exists as a section, not as a stray mention)
- [x] `grep -rn 'backend' skills/wurk:kit/REFERENCE.md skills/wurk:*/SKILL.md`
      returns nothing (no consumer constant leaked into generic prose). The
      string is expected in `docs/manifest.md`, which already carries per-repo
      example values, and in the new fixture, which is the one place this repo
      legitimately holds per-consumer manifest shapes (ADR-0006, and
      `test/support/manifest_helper.rb:8-21`)
- [x] the contract test's banned-operations and guarded-write scans still
      pass with the new fixture's prefixed `moving_files` / `guard_ledger`

#### Manual Verification:
- [ ] In a scratch monorepo (a git repo with `.claude/wurk.json` at the root,
      `gate.cwd: "sub"`, and `gate.full` a script that prints `pwd`), running
      `gate.rb` from the repo root and again from a third directory both show
      the gate executing in `<root>/sub`
- [ ] The same scratch repo, invoked with the process cwd **already inside**
      `sub/`: the gate still executes in `<root>/sub`, not `<root>/sub/sub`.
      This is the case `gate_chdir`'s default root exists for. It is
      structurally guaranteed - `Manifest.locate` walks up, so `path` and
      therefore `checkout_root` are the same from any invocation directory -
      but it is the one property whose breakage no test in either phase would
      catch, so check it by hand here rather than assuming it
- [ ] `worktree_create.rb --dry-run` in that scratch repo renders the
      `gate.loop` preview as `(cd <worktree>/sub && ...)`, and a real run
      executes there
- [ ] `docs/manifest.md`'s new section reads as one path vocabulary: a
      reviewer who has only read that section can tell, without opening the
      kit, that `build_paths` stays repo-root-relative while the gate command
      runs in `gate.cwd`
- [ ] No regressions in `/wurk:commit`'s gate step or `/wurk:branch`'s warm
      check on this repo, which declares no `gate.cwd`

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: Anchor the kit's root-relative paths on the checkout root

### Overview

The bead's second half: audit every kit consumer of repo-root-relative
manifest paths and settle whether those semantics still hold when all build
paths share one subdirectory prefix. The finding, established in Current
State Analysis, is that they do wherever paths are matched against git
*output*, and that three sites additionally require the process cwd to be the
checkout root. This phase records the audit as the path-semantics contract
and removes the three implicit dependencies by resolving them against
`Manifest#checkout_root`.

### Changes Required:

#### 1. The audit, recorded where an implementer will read it
**File**: `skills/wurk:kit/scripts/lib/gate_paths.rb`, `docs/manifest.md`
**Changes**: `gate_paths.rb`'s module doc gains a paragraph stating why its
lists are repo-root-relative and stay so - `git diff --name-only` prints
root-relative paths regardless of process cwd, so a monorepo consumer's
`backend/lib/` entries match correctly with no cwd handling here, and
`gate.cwd` does not apply to matching. `docs/manifest.md`'s new `gate.cwd`
section gains a short "what is root-relative, and against what" list
enumerating the audited surfaces and their source of paths:

```
matched against git's own output (`git diff --name-only` and
`git status --porcelain` both print repo-root-relative paths regardless of
the process cwd - lib/base_ref.rb is the only source of these lists - so
these are unaffected by gate.cwd and by the process cwd):
  gate.build_paths, gate.also_gated_paths - lib/gate_paths.rb, consumed by
    gate.rb's carve-out and repo_state.rb's touches_build
  gate.moving_files, gate.guard_ledger, parallelism.repair_when,
    rebase.auto_resolve_paths - lib/conflict_paths.rb, and manifest.rb's
    rebase collision validation (pure string comparison)
  gate.sabotage.test_roots / exempt_prefixes, as prefix filters over
    untracked paths - gate.rb sabotage_untracked_unverifiable
resolved on the filesystem or handed to git as a pathspec (root-relative,
resolved against the manifest's checkout root, never the process cwd):
  gate.guard_ledger existence - gate.rb gate_guard_from
  gate.sabotage.test_roots / exempt_prefixes as `git diff` pathspecs -
    gate.rb sabotage_diff_args
  the working-tree file reads behind the `# sabotage:` note check -
    gate.rb's default sabotage file reader
```

#### 2. Guard-ledger existence resolves against the checkout root
**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**: `gate_guard_from` (line 319-327) takes the root and resolves the
ledger against it, so `ledger_exists` is the same answer from any invocation
directory. `data.gate_guard.ledger_path` keeps reporting the manifest's
relative value (it is what the consumer wrote and what a reader recognizes);
only the `File.exist?` argument changes.

```ruby
def gate_guard_from(stages, ledger_path, root)
  stage = Array(stages).find { |s| s["name"] == "Gate guard" }

  {
    ledger_path: ledger_path,
    # Resolved against the manifest's checkout root, not Dir.pwd: manifest
    # resolution walks up from the working directory, so gate.rb is
    # legitimately invoked from a subdirectory, where a bare relative
    # File.exist? silently reports a present ledger as absent.
    ledger_exists: !ledger_path.nil? && File.exist?(File.join(root, ledger_path)),
    stage: stage && { status: stage["status"], summary: stage["summary"], findings: stage["findings"] }
  }
end
```

Both call sites (`gate.rb:452` in the carve-out return, `gate.rb:469` in the
normal path) pass `manifest.checkout_root`.

#### 3. Sabotage scan resolves against the checkout root
**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**: two changes, both about pathspecs and file reads rather than
about `gate.cwd`, which explicitly does not apply to kit-owned git commands.

- The sabotage `git diff` (line 261) gains `chdir: manifest.checkout_root`,
  so `gate.sabotage.test_roots` and `exempt_prefixes` are interpreted as
  root-relative pathspecs regardless of where gate.rb was invoked. This
  changes the rendered command in the `commands` trail to
  `(cd <root> && git diff ...)`; update the `gate_test.rb` assertions that
  match that string, and treat the change as intended - the trail now states
  the directory the pathspecs were resolved in, which is information it was
  previously omitting.
- `DEFAULT_SABOTAGE_FILE_READER` (line 103-107) is called with diff paths,
  which are root-relative, and reads them against `Dir.pwd`. The reader is a
  documented injectable seam (`scan_sabotage(..., file_reader:)`, line 124,
  called through `sabotage_file_lines`, line 166-167), and `gate_test.rb`
  stubs it with the relative paths the diff prints. So do **not** join inside
  `sabotage_file_lines` - that would change what every stub receives.
  Instead replace the constant lambda with a builder that closes over the
  root, and thread `root:` through `sabotage_scan` -> `scan_sabotage` as the
  default reader's only source of the root:

  ```ruby
  # Was a constant lambda reading `path` against Dir.pwd. Diff paths are
  # repo-root-relative, so the reader has to know the root; injected readers
  # (tests) still receive the relative path unchanged, which is what keeps
  # this a seam rather than a signature change.
  def default_sabotage_file_reader(root)
    lambda do |path|
      File.read(File.join(root, path))
    rescue SystemCallError
      nil
    end
  end
  ```

  `scan_sabotage`'s `file_reader:` keyword loses its constant default and
  gains a required-in-practice one supplied by `sabotage_scan`
  (`file_reader: default_sabotage_file_reader(manifest.checkout_root)`).
  `file_lines_by_path`'s keys stay relative, so nothing downstream of the
  read changes.

#### 4. Tests
**File**: `skills/wurk:kit/scripts/test/gate_test.rb`
**Changes**:

- A test that runs `gate.rb` with cwd set to a subdirectory of the tmp repo
  (extend `in_tmp_cwd` with a `from_subdir:` option that `mkdir -p`s and
  chdirs one level down) and asserts `data.gate_guard.ledger_exists` is true
  for a ledger that exists at the root. This is the regression the change
  fixes, and it fails before it.
- The same subdirectory invocation asserts the sabotage `git diff` call's
  recorded `chdir` is the tmp repo root, and that a candidate test
  declaration's `# sabotage:` note is still found (the file read resolved
  correctly).
- `data.gate_guard.ledger_path` still reports the manifest's relative value,
  not an absolute one.

### Success Criteria:

#### Automated Verification:
- [x] `ruby skills/wurk:kit/scripts/test/run.rb` is green
- [x] the suite contains a test that runs `gate.rb` with the process cwd set
      to a subdirectory of the tmp repo and asserts
      `data.gate_guard.ledger_exists` is true - grep the test file for the
      new `from_subdir` helper to confirm it exists and is exercised
- [x] the same subdirectory test asserts the sabotage `git diff` call's
      recorded `FakeSh::Call#chdir` equals the tmp repo root, and that the
      `# sabotage:` note is still found through the root-aware reader
- [x] `data.gate_guard.ledger_path` in that test is still the manifest's
      relative value, not an absolute path
- [x] `ruby skills/wurk:kit/scripts/lib/manifest.rb check` still exits 0 on
      this repo's manifest, and `ruby skills/wurk:kit/scripts/gate.rb
      --profile loop` still emits `data.gate_cwd: null` here

Note deliberately absent from this list: a two-invocation comparison of
`gate.rb` output on **this** repo. Wurk's own manifest declares neither
`gate.guard_ledger` nor `gate.sabotage`, so both fields are null/false here
and the comparison would pass vacuously. The subdirectory regression is
therefore pinned by fixture-driven tests above and by the scratch-repo step
under Manual Verification, not by a command run against this checkout.

#### Manual Verification:
- [ ] Revert each `File.join(root, ...)` resolution locally, one at a time,
      and confirm the corresponding new test goes red - the tests are only
      worth having if they fail without the fix, and no single command can
      decide that
- [ ] In the scratch monorepo from Phase 1 (which does declare a
      `gate.guard_ledger` and a `gate.sabotage` section), `gate.rb` run from
      the root and from `sub/` produce the same `data.gate_guard` and the same
      `data.sabotage` payload
- [ ] The `commands` trail of a real `gate.rb` run reads honestly: the
      sabotage diff now shows the directory its pathspecs were resolved in,
      and nothing else in the trail changed shape
- [ ] `docs/manifest.md`'s audited-surfaces list matches the code - walk each
      of the named files and confirm the classification (git output vs
      filesystem/pathspec) is right
- [ ] A reviewer reading the `gate_paths.rb` module doc can answer "why does
      a monorepo consumer write `backend/lib/` and not `lib/`" without
      opening `docs/manifest.md`

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

All in `skills/wurk:kit/scripts/test/`, mirroring the scripts one-to-one per
the project's convention.

- `manifest_test.rb` - `gate_cwd`, `checkout_root`, `gate_chdir` (default
  root and explicit `root:`, present and absent field), validation
  acceptances and every rejection shape, and the no-unknown-key-warning
  regression that catches a missed `KNOWN` entry. One test asserts validation
  succeeds for a directory that does not exist, pinning the deliberate
  absence of a filesystem probe.
- `gate_test.rb` - chdir pass-through on the quality run and the attest run,
  `data.gate_cwd` present and nil, the rendered `(cd ... && ...)` command,
  the carve-out path reporting `gate_cwd: nil`, and the Phase 2
  subdirectory-invocation tests for the ledger check and the sabotage scan.
- `worktree_create_test.rb` / `worktree_refresh_test.rb` - the
  `File.join(worktree_path, gate.cwd)` join for the real run and for the
  dry-run preview render, plus the absent-field case asserting the chdir is
  still the bare worktree path.
- `contract_test.rb` - not modified, but must stay green: it scans for banned
  operations and guarded writes, and the new fixture's prefixed
  `moving_files` / `guard_ledger` widen the union
  `ManifestHelper#all_fixture_guarded_paths` builds.

Key edge cases: `gate.cwd` with a trailing slash (`"backend/"`) - accepted,
and `File.join` handles it, so a test pins that rather than adding
normalization; a nested `gate.cwd` (`"apps/backend"`); `gate.cwd` combined
with an absent `gate.attest` (no second chdir to assert); `gate.cwd` in the
worktree scripts where the root is a path that does not exist yet at
validation time.

### Manual Testing Steps:

1. Build a scratch monorepo: `git init` a tmpdir, add
   `.claude/wurk.json` with the minimum required keys plus
   `"gate": {"cwd": "sub", "full": ["sh", "-c", "pwd"], "loop": ["sh", "-c", "pwd"]}`,
   and `mkdir sub`.
2. Run `ruby <kit>/gate.rb --profile loop` from the repo root; confirm the
   envelope's `commands` shows `(cd <root>/sub && sh -c pwd)` and
   `data.gate_cwd` is `<root>/sub`.
3. Run it again from a directory outside the repo with the manifest reached
   through the git fallback, and from inside `sub/`; confirm the resolved
   directory is `<root>/sub` in both cases - not `<root>/sub/sub`.
4. Remove `"cwd"` and repeat step 2; confirm the command renders with no
   `(cd ...)` wrapper and `data.gate_cwd` is null.
5. In this repo, run `ruby skills/wurk:kit/scripts/worktree_create.rb --dry-run`
   for a throwaway bead id and confirm the `gate.loop` preview is unchanged
   from before the branch (this repo declares no `gate.cwd`).
6. Extend the scratch repo for Phase 2: add a ledger file at its root and
   declare it as `gate.guard_ledger`, add a `gate.sabotage` section with
   `test_roots: ["sub/test/"]` and a test pattern, commit a test file there
   with a `# sabotage:` note, then run `gate.rb` from the root and again from
   `sub/`. Confirm `data.gate_guard.ledger_exists` is true both times and
   `data.sabotage` is identical both times. Keep this scratch repo around
   between the two phases - Phase 2's manual criteria reuse it.

## Decisions taken without a human in the loop

This plan was authored unattended, so every question that would normally have
been asked was decided here rather than left open. Each has a decision the
implementer can follow as-is; each is also the place to push back if the
judgment was wrong. Nothing below blocks implementation.

1. **Absent `gate.cwd` yields `chdir: nil`, not the checkout root.** Chosen so
   the rendered `commands` audit trail stays byte-identical for every
   consumer that does not use the field, which also means no existing test
   changes shape. The alternative (always pass an explicit root) would make
   every envelope in every repo read `(cd /abs/path && mix quality)` from now
   on - more information, but a churn of every command assertion in the suite
   and a noisier trail for the common case.
2. **No existence check on `gate.cwd`, not even a warning.** Direction-note
   open question 2, resolved as "shape only"; the reasoning is in What We're
   NOT Doing. If a reviewer wants the warning, it belongs in `ManifestCli`
   (which knows it is being run interactively) rather than in `validate!`,
   which must stay filesystem-free.
3. **`data.gate_cwd` is added to gate.rb's envelope.** Direction-note open
   question 3, resolved as yes: it costs one line, gives the skills a
   machine-readable value instead of parsing the `commands` string, and makes
   Phase 1's automated criteria checkable.
4. **A trailing slash in `gate.cwd` is accepted, not normalized.** `File.join`
   handles it and the direction note says no trailing slash is required. A
   normalizing accessor would be a second place for the value to differ from
   what the consumer wrote.
5. **Phase 2 changes the sabotage `git diff` to run with
   `chdir: manifest.checkout_root`,** which alters the rendered command in the
   `commands` trail and requires updating the matching `gate_test.rb`
   assertions. The narrower alternative - leave it alone and document
   "invoke gate.rb from the repo root" - was rejected because the audit's
   whole point is to stop relying on an undocumented invocation constraint.
   If a reviewer prefers the narrower change, drop this bullet's item from
   Phase 2 and keep the ledger and file-reader fixes, which need no trail
   change.
6. **The worktree-script `gate.loop` timeout gap is filed, not fixed.**
   See What We're NOT Doing. If the reviewer would rather it ride along, it is
   a two-line change in Phase 1, but it makes the phase's diff span two
   unrelated concerns.

## References

- Direction document: `docs/research/260817-wu-9fb-subdirectory-gate-cwd.md`
- Related ADRs: `docs/adr/0004-manifest-and-extension-seams.md` (the manifest
  seam this field enters through, and the "schema work reviewed once for
  everyone" consequence), `docs/adr/0005-gate-contract-tiers.md` (tiers are
  unaffected; `gate.cwd` changes where a tier's command runs),
  `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md` (stdlib-only
  system Ruby, one envelope, `--dry-run`),
  `docs/adr/0010-bounded-rebase-conflict-auto-resolution.md` (the rebase
  collision surfaces that stay root-relative)
- Schema: `docs/manifest.md`, `docs/architecture.md` (layer 3 design rules)
- Existing chdir pattern to model after:
  `skills/wurk:kit/scripts/lib/sh.rb:65-75`,
  `skills/wurk:kit/scripts/worktree_create.rb:199`,
  `skills/wurk:kit/scripts/worktree_refresh.rb:126`
- Closest precedent for an optional gate field entering the schema with no
  ADR: `gate.timeout_seconds`, commit 082f019
- Bead: `wu-9fb`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] In a scratch monorepo (a git repo with `.claude/wurk.json` at the root,
      `gate.cwd: "sub"`, and `gate.full` a script that prints `pwd`), running
      `gate.rb` from the repo root and again from a third directory both show
      the gate executing in `<root>/sub`
- [ ] The same scratch repo, invoked with the process cwd **already inside**
      `sub/`: the gate still executes in `<root>/sub`, not `<root>/sub/sub`.
      This is the case `gate_chdir`'s default root exists for. It is
      structurally guaranteed - `Manifest.locate` walks up, so `path` and
      therefore `checkout_root` are the same from any invocation directory -
      but it is the one property whose breakage no test in either phase would
      catch, so check it by hand here rather than assuming it
- [ ] `worktree_create.rb --dry-run` in that scratch repo renders the
      `gate.loop` preview as `(cd <worktree>/sub && ...)`, and a real run
      executes there
- [ ] `docs/manifest.md`'s new section reads as one path vocabulary: a
      reviewer who has only read that section can tell, without opening the
      kit, that `build_paths` stays repo-root-relative while the gate command
      runs in `gate.cwd`
- [ ] No regressions in `/wurk:commit`'s gate step or `/wurk:branch`'s warm
      check on this repo, which declares no `gate.cwd`

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 2

- [ ] Revert each `File.join(root, ...)` resolution locally, one at a time,
      and confirm the corresponding new test goes red - the tests are only
      worth having if they fail without the fix, and no single command can
      decide that
- [ ] In the scratch monorepo from Phase 1 (which does declare a
      `gate.guard_ledger` and a `gate.sabotage` section), `gate.rb` run from
      the root and from `sub/` produce the same `data.gate_guard` and the same
      `data.sabotage` payload
- [ ] The `commands` trail of a real `gate.rb` run reads honestly: the
      sabotage diff now shows the directory its pathspecs were resolved in,
      and nothing else in the trail changed shape
- [ ] `docs/manifest.md`'s audited-surfaces list matches the code - walk each
      of the named files and confirm the classification (git output vs
      filesystem/pathspec) is right
- [ ] A reviewer reading the `gate_paths.rb` module doc can answer "why does
      a monorepo consumer write `backend/lib/` and not `lib/`" without
      opening `docs/manifest.md`

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

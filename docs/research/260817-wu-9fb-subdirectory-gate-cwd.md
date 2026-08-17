---
date: 2026-08-17T11:36:13-0600
researcher: Claude
git_commit: 082f019b4f69f1725e2048055eb6b84b462244ae
branch: wu-9fb-subdirectory-gate-root
repository: wurk
beads_issue: wu-9fb
topic: "Gates rooted in a subdirectory of a monorepo consumer"
tags: [research, direction, kit, gate, manifest, monorepo]
status: complete
last_updated: 2026-08-17
last_updated_by: Claude
---

# Direction: gate.cwd for gates rooted in a subdirectory

**Date**: 2026-08-17T11:36:13-0600
**Git Commit**: 082f019b4f69f1725e2048055eb6b84b462244ae
**Branch**: wu-9fb-subdirectory-gate-root
**Bead**: wu-9fb

## The question

A consumer repo may be a monorepo where the gated project lives in a
subdirectory (e.g. `backend/`) while `.claude/wurk.json` sits at the repo
root. Its gate commands (`mix quality`, `mise run quality`, ...) must run
with the working directory inside that subdirectory, but every kit script
executes gate argv with cwd at the checkout root. wu-9fb enumerates two
answers and defers the choice:

- (a) document a consumer-side wrapper script (`bin/gate.sh` doing
  `cd backend && ...`) as the blessed pattern, no schema change;
- (b) add an optional `gate.cwd` manifest field, passed as `chdir:` to
  `Sh.run` wherever gate argv is executed.

It also asks whether repo-root-relative `gate.build_paths` semantics still
make sense when every build path shares one subdirectory prefix.

## Decision

**Option (b): add an optional `gate.cwd` field to the manifest schema. Every
other gate path in the manifest stays repo-root-relative. The wrapper
pattern is not blessed as the answer.**

`gate.cwd` is a repo-root-relative directory path (a plain string, no
trailing slash required). When present, any kit script that executes one of
the five consumer gate commands - `gate.full`, `gate.loop`, `gate.report`,
`gate.report_loop`, `gate.attest` - resolves the child process working
directory as `File.join(<root of the checkout being gated>, gate.cwd)`
instead of that root itself. When absent, behavior is exactly today's:
the checkout root. Nothing else changes meaning.

### Why (b) over the wrapper

A wrapper script is not a hard-rule violation: it lives in the consumer
repo, so no consumer constant leaks into generic code, and the gate argv is
already fully consumer-defined. Option (a) is workable. It loses on the
merits anyway:

1. **ADR-0004's pressure valve points here.** "A consumer needing to change
   generic behavior means the manifest schema is missing a field", and its
   consequence is explicit: pressure against add-not-override "surfaces as
   schema work in this repo, where it is reviewed once for everyone". Every
   monorepo consumer would otherwise write the same cd-and-exec shim, once
   per gate command (up to five), reviewed nowhere. One optional field is
   exactly the schema work that consequence describes.
2. **The audit trail gets more honest, not less.** `Sh.run` records the
   rendered command into the envelope's `commands` list, and `Sh.render`
   already renders a chdir as `(cd <dir> && <argv>)`
   (`skills/wurk:kit/scripts/lib/sh.rb:72-75`). With `gate.cwd` the
   envelope shows the real gate command and where it ran. With a wrapper
   the envelope shows `bin/gate.sh` and the real command is hidden behind
   a layer the kit cannot see - which also degrades tier-1 reporting
   review, since the reporting command is supposed to be legible manifest
   data, not a shell file.
3. **The mechanism already exists.** `Sh.run` takes `chdir:` today; the
   worktree scripts already pass it (`worktree_create.rb:199`,
   `worktree_refresh.rb:126` run `manifest.gate_loop` with
   `chdir: <worktree path>`). (b) is a join, not new machinery.
4. **Wrappers interact badly with worktrees.** Those two scripts run the
   gate in a checkout other than the one they were invoked from. A wrapper
   that does `cd backend` relative to its own invocation happens to work,
   but nothing in the contract makes it work; each consumer rediscovers
   that constraint alone. `gate.cwd` defines the join once, in the kit,
   with a test.

### What stays repo-root-relative (all of it)

`gate.cwd` changes only where the five gate commands execute. Every path
the manifest names keeps its current repo-root-relative meaning:

- `gate.build_paths`, `gate.also_gated_paths` - matched by
  `lib/gate_paths.rb` against `git diff --name-only` output, which git
  prints repo-root-relative regardless of process cwd. The predicates and
  the carve-out reason string are untouched. A monorepo consumer writes
  `"build_paths": ["backend/lib/", "backend/mix.exs", ...]` - the shared
  prefix is mild repetition, not broken semantics, and keeping one path
  vocabulary for every list in the manifest (these two, `moving_files`,
  `sabotage.*`, `guard_ledger`, `parallelism.repair_when`, the rebase
  collision lists of ADR-0010) is worth far more than saving a prefix.
  Making some lists cwd-relative and others not is the trap this decision
  exists to refuse.
- `gate.moving_files`, `gate.guard_ledger` - consumed as repo-root paths
  (gate.rb's `File.exist?` ledger check runs from the invocation root).
- `gate.sabotage.test_roots` / `exempt_prefixes` - handed to `git diff` as
  pathspecs and compared against diff paths; the scan's file reads
  (`DEFAULT_SABOTAGE_FILE_READER`) resolve diff paths from the repo root.
  `gate.cwd` does not apply to the sabotage diff or to any other git
  command the kit runs; those are kit-owned, not consumer gate argv.
- `artifacts.*`, `parallelism.repair_when` - unchanged.

The doc rule for implementers: `gate.cwd` scopes *execution* of consumer
gate commands; it never rescopes *matching* of manifest paths.

### Scripts that must honor it

The full set of production call sites executing manifest gate argv
(verified by grep; no others exist today):

- `skills/wurk:kit/scripts/gate.rb` - `run_quality` (`gate.full` /
  `gate.loop` / `gate.report` / `gate.report_loop`, line ~344) and the
  attest call (`gate.attest`, line ~475). Resolve against the root the
  manifest was located from (`Manifest#path`'s checkout), not bare
  `Dir.pwd`, so invocation from a subdirectory does not double-apply.
- `skills/wurk:kit/scripts/worktree_create.rb` - the `gate.loop` warm
  check (run at ~199, dry-run preview render at ~120):
  `chdir: File.join(path, gate.cwd)`.
- `skills/wurk:kit/scripts/worktree_refresh.rb` - the post-rebase
  `gate.loop` confirmation (run at ~126, preview at ~118): same join.

Plus, in the same commit (hard rules): `lib/manifest.rb` - add `cwd` to
the `gate` section's known keys, an accessor, and validation (must be a
non-empty relative path, no leading `/`, no `..` segments; see open
question 2 on existence checking) - and `docs/manifest.md` documenting the
field with the execution-vs-matching rule above. `run.rb` suite gains
tests: gate.rb passes the chdir through (FakeSh can assert it), validation
rejects absolute and `..` paths, absent field preserves today's behavior.

### Why this is a research note, not a new ADR

The decision adds one optional field through exactly the mechanism ADR-0004
already settled, and changes no seam, tier (ADR-0005), or contract rule.
Precedent: `gate.timeout_seconds` (commit 082f019) entered the schema with
no ADR, and the wu-4r7 sabotage-scoping direction call of the same scale
was recorded as `docs/research/260812-wu-4r7-sabotage-scope-pathspec.md`.
Amending ADR-0004 for a field addition would set the precedent that every
schema field reopens an accepted record.

## Open questions

1. **Do `parallelism.trust`, `warm`, `repair`, and `post_branch` need a
   cwd of their own?** A monorepo consumer's `mix deps.get` warm command
   has the same subdirectory problem. This decision deliberately does not
   reuse `gate.cwd` for them - they are a different section with different
   semantics (some, like `trust`, genuinely want the worktree root). If
   the need materializes, it is a separate field (e.g. `parallelism.cwd`
   or per-command), decided then. Do not silently apply `gate.cwd` to any
   non-gate command.
2. **Should manifest validation require the `gate.cwd` directory to
   exist?** Suggested: no hard error (the manifest can be linted outside a
   checkout, and worktree paths do not exist yet at validation time); a
   lint-time warning when the directory is absent in the current checkout
   is acceptable. Implementer's call.
3. **Should `gate.rb`'s envelope surface the resolved cwd in `data`?** The
   `commands` audit trail already shows it via `Sh.render`; a
   `data.gate_cwd` field would make it machine-readable for skills. Minor;
   implementer's call.

# ADR-0006: Kit scripts stay Ruby-stdlib with the statifier envelope contract

Status: accepted (2026-08-08), amended (2026-09-13) - see "Amendment
(2026-09-13)" below. The amendment narrows the `--dry-run` rule by one
bounded carve-out; every other decision in this record stands as written.

## Context

Statifier-ex extracted the deterministic mechanics of its skills into Ruby
scripts governed by a written contract: system Ruby, stdlib only, one JSON
envelope on stdout (`ok/script/data/warnings/blocked/commands`), exit codes
0/1/2, `--dry-run` on every mutating script, all shell-outs through a single
argv-array runner (defeating `-i` aliases and injection), a minitest suite
with a fake-shell harness, and a contract test banning irreversible
operations (`git push`, PR/MR creation, `bd close`, `bd edit`) from scripts
entirely. This layer is the most portable asset in the donor repo: it runs
on any Mac's system Ruby with no toolchain install, and its constants are
already concentrated in known sites. Predicator's inline-bash equivalents
are the pre-extraction form of the same logic and demonstrate the cost of
not having the layer.

## Decision

The kit adopts statifier's scripts and their contract wholesale, unchanged
except for constants moving behind `lib/manifest.rb` (ADR-0004). No gems, no
Bundler, no language migration. The contract test ports as-is: the
banned-operations list is project-independent policy - irreversible actions
stay literal skill instructions so a human-meaningful gate fronts each one.
The test suite is this repo's quality gate (ADR-0002).
*(Amended 2026-09-13: "`--dry-run` on every mutating script" above means
"executes nothing" with one bounded carve-out - a fetch that writes only
remote-tracking refs. See "Amendment (2026-09-13)" below for the bound and
for what still violates the rule.)*

**1. The banned-operation list is absolute.** A kit script never runs
`git push`, `gh pr create`, `glab mr create`, `bd close`, or `bd edit`, and
never writes a file the consumer's manifest declares as gate configuration
(`gate.moving_files`) or as the gate-change ledger (`gate.guard_ledger`).
Scripts shell out only through `lib/sh.rb` - never `system` or backticks -
and every argv-literal `cp`, `rm`, or `mv` carries a non-interactive flag.

The donor repo anchored this list in its own ADR-0015 and had its contract
test re-read that ADR's text on every run, so the prose and the enforcement
could not drift apart silently. That mechanism moves here: the check now
parses the constraint above, and a backticked operation added to this
paragraph without a matching `Contract` rule fails the suite.

The guarded-write half is the one part that cannot be a fixed list in this
repo. Which files count as gate configuration is per-consumer data
(statifier's `.credo.exs` and `coveralls.json`, fixative's mise files), so
the scan takes its targets as an argument and the suite supplies the union
of every fixture manifest's declarations. This is what `gate.moving_files`
is for; it had no consumer before.

**2. The version floor is macOS system Ruby, 2.6.** "Any Mac's system Ruby
with no toolchain install" above is a version claim, and the version is
2.6.10 - Apple has not moved it and nothing in a consumer install does. So a
kit script uses no core method added after 2.6: not `filter_map`, `tally`,
`except`, `intersect?`, `ceildiv`, `byteindex`, `byterindex`, `bytesplice`,
`bind_call`, `const_source_location`, `absolute_path?`,
`set_temporary_name`, `Data.define`, or `Enumerator.produce`.

Such a method parses on 2.6 and raises `NoMethodError` only when its line
runs, which makes this the one contract rule a contributor cannot notice by
reading: whoever has a 3.x `ruby` from homebrew or a version manager on
PATH sees a green suite while the gate is red on the Ruby this ADR commits
to. Three call sites did exactly that over five weeks in 2026-09 and left
the suite with 38 errors on the floor. `Contract` therefore scans every
`.rb` under `scripts/` - the tests included, since the suite is the gate -
for these as method calls, and the drift check that guards the list above
guards this list the same way: a method named in this paragraph without a
matching rule fails the suite. The list is named methods rather than a
version sweep on purpose; a rule this absolute has to fire on nothing
innocent.

## Consequences

- Zero install burden for consumers; the scripts run wherever Claude Code
  does.
- The tested, envelope-shaped boundary between skill judgment and script
  mechanics survives the move, including its resistance to interactive-alias
  hangs and shell injection.
- Ruby stays the implementation language even for contributors who would
  prefer another; the stdlib-only rule is the tradeoff that keeps install at
  zero.
- Scripts gain a new required input (the manifest); every script test runs
  against fixture manifests rather than real repos.

## Amendment (2026-09-13): a dry run may refresh remote-tracking refs, and nothing else

Decided under wu-mya.9, on an operator ruling from the `/wurk:verify` walk
of that bead. This amendment narrows the `--dry-run` rule; every other
decision in this record stands as written.

### The rule as it stood

"`--dry-run` on every mutating script" was carried into the kit unqualified,
and `skills/wurk:kit/REFERENCE.md` stated it as the operative contract: a
dry run populates `commands` with what the script would have run and
executes nothing. Every kit script matched that sentence until wu-mya.9.

### What is carved out

`worktree_cleanup.rb` runs `git fetch --prune` once per sweep, before its
per-worktree check loop, and runs it on a dry run as well as a real one.
That is the whole carve-out. The bound is the write set of that one
command: `git fetch --prune` writes remote-tracking refs under
`refs/remotes/` to mirror what the remote already says, and writes nothing
else. It creates, moves, and deletes nothing under `refs/heads/`, nothing in
any worktree, nothing in the tracker, and nothing on the remote. A dry run
that ran it leaves the operator with nothing to undo, which is the property
the rule exists to protect.

This is not a "reads are free" loophole. A fetch is a write - it moves refs
that other commands then read - and it qualifies only because its write set
is exactly the set of refs a stale checkout would otherwise misreport, and
because that set is one nothing in the kit's dry-run promise ever covered.
Any other command's claim to the same carve-out has to be argued on its own
write set, in a record, not inferred from this one.

### Why the carve-out is forced rather than convenient

ADR-0017 makes the sweep decide a sha inequality by `git cherry` against the
manifest's remote default branch. That probe sees only commits reachable
from `refs/remotes/<remote>/<default>` in the local object store, so on a
stale checkout it refuses a worktree whose work has landed - the same
report, for the same reason, as the bug ADR-0017 fixed.

`/wurk:cleanup`'s flow is what turns that from a stale answer into a lost
removal. Its check phase runs `worktree_cleanup.rb --dry-run` and selects
candidates from that envelope; the real removal is then invoked by name,
only for a candidate the check phase already named. If the dry run judges
against stale refs and the real run judges against fetched ones, the two
decide different things about the same worktree, and the one that would
have removed it is never asked. The fetch on the dry run is what makes the
two phases decide against the same refs.

The alternative the plan for wu-mya.9 recorded as the fallback - fetch only on
a real run and have the dry run emit a `refs_not_fetched` warning next to each
probe-based refusal - was not taken: it keeps the under-reporting, and a
warning next to a candidate that was never named is not a candidate. The
operator ruled that the fetch stays as built and gets recorded; the argument
against the fallback is this record's. (`worktree_cleanup.rb` does emit a
warning named `refs_not_fetched`, added in the same walk, but for the
different condition of a fetch that failed - not for a fetch it declined to
run.) `git fetch --dry-run` updates nothing
and so answers nothing. Fetching lazily on the first diverged worktree asks
the same dry-run question with per-sweep state added.

### What still violates the rule

The carve-out is the write set above, and nothing wider. On a dry run, a
kit script still must not:

- create, move, or delete any ref under `refs/heads/`, or run `git branch`
  in any mutating form;
- add, remove, move, prune, or lock a worktree, or write inside one
  (`checkout`, `reset`, `rebase`, `merge`, `stash`, `clean`, or any file
  write);
- run `git push`, or any other command that writes to the remote, whether
  or not it is on the banned-operation list;
- write to the tracker (`bd create`, `bd update`, `bd label`, or any other
  `bd` write; `bd close` and `bd edit` stay banned on every run);
- change tags, notes, the index, the reflog by any means other than the
  fetch itself, or any other local state a later command reads as
  authoritative.

"It is only reading" is not an argument under this amendment; `git fetch` is
not a read. "It is bounded" is not sufficient either; the fetch qualifies
because its bound coincides with the refs the dry run needs current, and
that coincidence is specific to a script whose dry-run output selects the
input of its real run. A second script wanting the same carve-out records
its own argument, and REFERENCE.md's kit-author checklist says so.

### Where the carve-out is stated

- ADR-0017's decision section, which is where the fetch-before-check
  ordering and the dry-run half were first decided, and which this
  amendment now backs from the rule's own record.
- `skills/wurk:kit/REFERENCE.md`, the `--dry-run` section and the
  kit-author checklist, which cite this amendment.
- The comment on the fetch call in `worktree_cleanup.rb`, which cites this
  amendment.
- The plan `docs/plans/260912-wu-mya.9-cleanup-patch-equivalence-after-server-rebase.md`,
  "Recorded open questions" item 1, where the question was first recorded
  as open.

### Consequences of this amendment

- `worktree_cleanup.rb --dry-run` now moves `refs/remotes/*`, and a
  `git reflog` on the remote-tracking default branch shows the dry run's
  fetch. An operator auditing a dry run should expect exactly that and
  nothing else to have moved.
- The contract test does not enforce the carve-out mechanically; it is
  pinned by `worktree_cleanup_test.rb` (the dry run fetches, and removes
  and deletes nothing) and stated in prose here and in REFERENCE.md. A
  mechanical "only one script may `Sh.run` outside a `dry_run` guard" check
  was not added, because the scripts already vary in how they guard, and a
  false-negative scan would be worse than the prose.

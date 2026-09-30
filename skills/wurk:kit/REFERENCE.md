# wurk:kit - the script contract

Deterministic mechanics lifted out of the `wurk:*` skills, so a skill shrinks
to: when to invoke, which script to run, and how to interpret its output.
Every other wurk skill reads this file before touching a script.

Scripts live at `skills/wurk:kit/scripts/` in the wurk repo, which installs
to `~/.claude/skills/wurk:kit/scripts/`. Paths below are written relative to
the kit root.

The layer was extracted in statifier-ex first and parameterized there before
the move; `statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md`
is the plan that built it, and wurk's own `docs/plan.md` phase 1 is the one
that made it portable. Neither is required reading to use a script.

This file is the contract for anyone writing or calling a script here.

## The manifest is an input to the contract

Every project-specific constant these scripts once carried inline - the bead
prefix, the worktrees directory, the gate commands, the tmux session name,
the commit-message limits - now comes from **`.claude/wurk.json`**, a
manifest read by `lib/manifest.rb`. The schema lives in
`~/repos/github/wurk/docs/manifest.md`; that document and `lib/manifest.rb`
change in the same commit, and the loader is the authority.

Why: the set was uncopyable to a sibling repo while each script hardcoded one
project's bead prefix, worktrees directory, gate command, and an absolute
home-directory path. Parameterizing them in place was the prerequisite for
lifting the kit out of that repo at all.

Resolution, in order: walk **up** from the working directory looking for
`.claude/wurk.json` (so a worktree finds its own copy, which is what makes a
schema change testable on the branch that makes it), then fall back to the
main checkout via `git rev-parse --git-common-dir`.

Validation is deliberately asymmetric: an unknown key **warns** (a consumer
repo may be pinned to a newer schema than the installed kit), a missing
required key **blocks** naming the field, an enum with an unrecognized value
**blocks** rather than defaulting (every enum selects a structural behavior),
and a command field that is not an argv array of strings is a schema error,
never something to split on whitespace.

Lint it standalone:

```sh
ruby skills/wurk:kit/scripts/lib/manifest.rb check [--file PATH]
```

Scripts read it through one entry point:

```ruby
manifest = Manifest.require!(env)
return env.emit(io) unless manifest
```

`require!` turns a missing or invalid manifest into an envelope block rather
than an exception mid-run. A capability the manifest does not configure is
reported, never guessed: no `tmux` section blocks `tmux_window.rb`'s
session-addressing subcommands rather than inventing a session name, no
`gate.report` means tier 0, and a forge with no adapter blocks with
`unsupported_forge` (see `lib/forge.rb`) instead of half-working. Both kinds
the schema accepts - `github` and `gitlab` - now have an adapter for every
capability, request-state detection and permalink writing alike, so
`Forge.guard!` checks one list rather than a per-capability one; a self-hosted
instance supplies its own host through `forge.host`. Within a `tmux` section, `tmux.layout` selects the
topology and defaults to `window-per-issue` when absent; `tmux.editor` is an
optional argv array, and its absence means no editor window is opened.

## The machine config is the contract's second input

Alongside the manifest, scripts read one machine-level source:
`~/.claude/wurk.local.json`, resolved and validated by `lib/user_config.rb`.
It carries settings that belong to the machine or the person at it, never
the project - the seeded session's permission mode is the first example
(wu-jhb) - and it is HOME-anchored only, absent-safe, and never checked into
a consumer repo. Scripts consume it exactly like the manifest, through a
typed accessor, never by reading `$HOME` or the file itself directly:

```ruby
user_config = UserConfig.require!(env)
return env.emit(io) unless user_config
```

Schema, validation rules, and the `check` lint: `docs/machine-config.md`.

The schema has a second section, `outbound_scan` - the machine-configured
outbound-scan gate (ADR-0014) - and a third and fourth, `machine` (the
machine's name and its gate-slot cap) and `workloads` (what this machine
runs, for a daemon or a conductor to ask), and a fifth, `metrics` (this
account's token prices and this machine's telemetry sink, read by
`session_metrics.rb`). Their keys, validation, and what
a script does with them are all documented at `docs/machine-config.md`;
this file states only that the sections exist, and one precedence rule
below under `lock.rb`.

## The fleet manifest is not a script input

A project that runs campaigns over several repos may carry a third file,
`.claude/wurk-fleet.json`, read by the `/wurk:conductor` skill and the
`wurk-fleet-scout` agent - never by a kit script on its own behalf. The
kit's part is the lint, `lib/fleet_manifest.rb check [--file PATH]`, which
follows the manifest's asymmetry (unknown keys warn, malformed values
block) and reports the resolved campaign-state paths and the package
topological order in `data`. Schema, validation rules, and the lint's two
filesystem checks: `docs/fleet-manifest.md`.

## Ruby version and syntax

**System Ruby 2.6.10 only** (`/usr/bin/ruby` on macOS). A consumer repo's
toolchain manager provisions that repo's own languages and generally not
Ruby, so the kit assumes nothing is installed for it (ADR-0006). Every
script:

- starts with `#!/usr/bin/env ruby`,
- uses the standard library only - **no gems, no bundler**,
- is written to 2.6 syntax. Specifically avoid, because they need 2.7+:
  - `Data.define`
  - endless methods (`def foo = ...`)
  - hash-value omission (`{x:}`)
  - `Array#filter_map`
  - `Array#intersect?`
  - rightward assignment / pattern matching (`expr => pattern`)
  - numbered block parameters (`_1`, `_2`) are 2.7+ too - use named params

`minitest` ships with 2.6's stdlib, so `require "minitest/autorun"` works
with no install. When in doubt, write plain, boring, compatible Ruby and
verify:

```sh
find skills/wurk:kit/scripts -name '*.rb' -exec /usr/bin/ruby -c {} +
```

## The envelope

Every script prints **exactly one JSON object on stdout**:

```json
{
  "ok": true,
  "script": "worktree_create",
  "data": {},
  "warnings": [{"code": "warm_cache_missing", "message": "..."}],
  "blocked": [{"code": "branch_exists", "message": "...", "needs": "human"}],
  "commands": ["git worktree add ...", "..."]
}
```

- `ok` - `true` only when `blocked` is empty and no wrapped command failed.
- `script` - the script's own name, so a caller reading several results in
  sequence never has to guess which is which.
- `data` - the script's payload. Shape is script-specific; see each script's
  own `--help` and its test file for the exact fields.
- `warnings` - informational. Never affects `ok` or the exit code; the model
  reads these but does not route on them.
- `blocked` - a condition the script refuses to resolve itself. Almost
  always `needs: "human"` - see "Step-scoping" below for why a script never
  works around one of these.
- `commands` **is mandatory and non-negotiable.** CLAUDE.md forbids
  truncating output, and a script that hides what it ran trades one opacity
  for another. Every command a script executes (or would execute, under
  `--dry-run`) is recorded here in order.

Diagnostics (progress messages, stack traces, debug output) go to **stderr**,
never stdout - stdout carries the one JSON object and nothing else.

Build a script's envelope with `Envelope` from `lib/envelope.rb`:

```ruby
require_relative "lib/envelope"

env = Envelope.new(script: "worktree_create")
env.data[:path] = path
env.block!(code: "branch_exists", message: "branch #{name} already exists")
exit env.emit
```

### A blocked message names what to change

A `blocked` entry is read by an agent deciding what to do next, so its
message says **what to change so the next attempt passes**, not only what
went wrong. "branch abc-foo already exists" states the condition; "branch
abc-foo already exists; pick another slug, or remove the old worktree
first" states the condition and the move. The fix belongs in `message`, or
in a `fix` key beside it when a caller needs to route on it separately.
A warning that a caller may act on is written the same way.

The same rule holds for the hooks under `hooks/`, where a deny reason
carries a literal `Fix:` clause - and there it *is* mechanical:
`test/hooks_test.rb` checks every hook's deny reasons for that clause and
requires a hook with no deny path to be listed, with a reason, in its
`HOOKS_WITHOUT_A_DENY_PATH` exempt list.

On the script side it stays a convention, deliberately. No static check can
tell a message that names a fix from one that only sounds like it, and a
check strict enough to catch a bare message flags the `blocked` codes whose
only honest content is a condition a human has to rule on - a preflight
refusing to touch a diverged default branch, a mutex held by a live run.
Flagging a legitimate refusal costs more than the prose saves, so this is
read for in review rather than gated on.

## Exit codes

- **0** - `ok` is `true`.
- **1** - `ok` is `false` (something is `blocked`, or a wrapped command
  failed). The envelope is still printed on stdout.
- **2** - a usage error (bad flags, missing required argument). A plain-text
  message on stderr, **no envelope** - the caller could not have gotten far
  enough to produce one.

## `--dry-run`

Every mutating script supports `--dry-run`: it populates `commands` with
what it would have run, executes nothing, and reports `ok: true` (absent an
unrelated `blocked` condition it can detect without running anything, such
as a pre-existing branch). This is both the audit path for a human reading
what a script intends to do, and how the test suite exercises scripts
without a real `git`, `gh`, or `tmux`.

The one narrow exception: `worktree_cleanup.rb` runs `git fetch --prune`
even on a dry run. A fetch writes only remote-tracking refs
(`refs/remotes/`), mirroring what the remote already says - it creates,
moves, and deletes nothing under `refs/heads/`, nothing in any worktree,
and nothing in the tracker, the three things a dry run exists to promise it
will not touch. It has to run before the dry run's check phase because
`/wurk:cleanup` selects candidates on the dry run and removes them by name
afterwards; a dry run deciding against stale refs would refuse a candidate
the real removal would have accepted. The carve-out and its bound are
recorded in ADR-0006's "Amendment (2026-09-13)", which also lists what
still violates the rule; no other script gets this exception without the
same argument, recorded the same way.

## Step-scoping and the banned-operation list

The consumer repo's CLAUDE.md authority table draws a hard line between what
a session may do on its own and what needs a human ask. A script may never
span that line, and no script anywhere under `scripts/` may contain a code
path that:

- runs `git push`
- runs `gh pr create` or `glab mr create`
- runs `bd close`
- runs `bd edit` (blocks on `$EDITOR` - use `--notes`/`bd note` instead)
- writes any file the consumer's manifest names in `gate.moving_files`
  (its gate configuration) or `gate.guard_ledger` (its gate-change ledger -
  a human's call, recorded, not automated)

This list is ADR-0006's, and `test/contract_test.rb` enforces it
mechanically over every file under `scripts/`. The two halves are enforced
differently on purpose. The four commands are a fixed list: irreversible
actions are project-independent policy. The guarded files are not - which
paths count as gate configuration is per-consumer data, so the scan takes
its targets as an argument and the suite supplies the union of every fixture
manifest's declarations. Widening the guard means adding a path to a
fixture, which is the same edit a real consumer makes in its own
`wurk.json`.

A drift check re-reads ADR-0006 on every run, so an operation named in that
ADR without a matching `Contract` rule fails the suite. Add rules to both
places or neither.

A script that can only *refuse* an operation performs nothing irreversible;
it is itself the human-meaningful gate this list exists to keep in front of
a push, not an exception carved out of it. `outbound_scan.rb` and
`bead.rb sync scan` are both this shape - each blocks a push on a hit and
neither ever issues one - so they extend what the list protects rather than
needing an entry of their own (ADR-0014). `bd dolt push` is not on the
list, and `bead.rb sync push` shells it; what fronts that push is the scan
verb's marker. The list itself does not change.

**The tracker push is two verbs that never chain.** `bead.rb sync scan`
reads the full tracker export (`bd list --all --json`), scans every string
field in process, attributes hits per issue id and field name, and on a
clean result writes a marker under the git common dir
(`.git/wurk/tracker-scan.json`) carrying the export's fingerprint and the
manifest's `beads.scan_refusal` (`all`, `titles`, or `none` -
`docs/manifest.md`). Under `none` the refusal set is empty: the scan still
runs and still attributes every hit, so the marker is written and the push
proceeds, and both verbs then set `data.waived` and warn
`outbound_scan_refusals_waived` with the hit and issue counts - a waived
scan never reads as a clean one, and never borrows the
`outbound_scan_disarmed` code, which means no scan is configured at all.
`bead.rb sync push` never scans: it refuses (`scan_marker_missing`,
`scan_marker_expired` past ten minutes, `scan_marker_stale` when the export
or the refusal set changed, `scan_marker_unreadable`) unless a fresh marker
fingerprints the export it is about to publish, then shells `bd dolt push`
and reports `data.confirmed` - a push that exits 0 saying nothing is
re-run once and, if still silent, reported unconfirmed rather than
successful. Both verbs honor `beads.sync` and do nothing under `local`
(`data.skipped`). There is no verb that scans and pushes in one call, on
purpose: the scan's report - in particular the informational hits under a
`titles` refusal set - is meant to be read before anything is published,
and a chained command is exactly how that reading gets skipped.

The banned list is the mechanical floor, not the whole story: judgment calls
(phase sizing, `bd close` triggers, a project's own testing protocol) stay in
skill prose and extension files even where scripting them is technically
possible.

**A forge CLI's name stays out of the kit's own vocabulary.** `test/contract_test.rb`'s
`FORGE_VOCABULARY` rule bans a `gh_`/`glab_`-shaped identifier and a quoted
GitHub request-state literal (`"MERGED"`, `"OPEN"`, `"CLOSED"`, `"DRAFT"`)
anywhere outside a comment in `scripts/`, because an envelope code, a data
key, or a synthesized value is the kit's own contract and has to outlive
whichever forge it was first written against - see `lib/forge.rb`'s
`REQUEST_MERGED` for the neutral value scripts compare against instead. The
rule is deliberately narrow about what it permits: naming the CLI in an argv
behind `Forge.guard!` (`Sh.run(["gh", "pr", "list", ...])`) and naming it in
a diagnostic message ("gh pr list failed: ...") are both fine and expected -
only the kit's own vocabulary has to stay neutral, not every mention of the
tool that produced a value.

**Draft follows the request's base, not the branch.** No script opens a
request (the contract bans that code path), but the one rule for when a
request opens as a draft lives in `lib/forge.rb` as `Forge.request_draft?(base:,
default_branch:)` so a test pins both paths: true only when the base is a
branch other than the default branch (a stacked request on its unmerged
parent), false when the base is the default branch or no base is named. A
stacked branch whose dispatch overrides the base to the default branch is
mergeable and opens ready for review; `/wurk:mr`'s stacked-branches section
cites this predicate rather than restating it.

**Shelling out goes through one runner.** `Sh.run` (`lib/sh.rb`) always uses
`Open3.capture3`/`popen3` with an argv array - never a shell string - so a
developer's `-i` alias on `cp`/`rm`/`mv` cannot apply and no argument's shell
metacharacters are ever interpreted. `system(...)` and backticks are banned
outside `lib/sh.rb` itself, checked by `test/contract_test.rb`. Every
`cp`/`rm`/`mv` argv still carries its explicit non-interactive flag
(`cp -Rf`, `rm -rf`, ...), per CLAUDE.md - the argv discipline removes the
aliasing hazard, it does not remove the need to ask non-interactively.

## Running the tests

```sh
/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb                # from the wurk repo
/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb -n /pattern/   # a subset by name
```

This suite is wurk's whole quality gate (ADR-0002). It needs no toolchain
beyond system Ruby, and it takes about half a second. Run it before any
commit that touches a script.

What this suite cannot see is a shell regression that only appears under a
bash 4.4+ `/bin/sh`: on macOS `/bin/sh` is bash 3.2. That gap has its own
opt-in lane, `portability_lane.rb` below, which the default suite reports
as a skip rather than running - see `docs/gate-contract.md`.

**A consumer repo that gates its own `.claude/` should stop measuring the
kit.** While these scripts lived in statifier-ex, its `mix quality` ran them
as a `Script tests` stage, and that mattered: `.claude/**` was not a
gate-guarded path, so a branch touching no `lib/`, `test/`, `config/` or
`mix.exs` carved out of ~8k lines of new Ruby entirely and reported green
having measured none of it. The scripts are no longer in that repo, so the
stage should go with them, but the lesson generalizes to whatever a consumer
*does* keep under `.claude/`.

That episode is also why `lib/gate_paths.rb` has two lists rather than one:
`touches_build?` means "touches the project's build" (`gate.build_paths`),
and `gate_applicable?` unions in `gate.also_gated_paths` on top. A gate stage
measuring something outside the build has to be reflected in the predicate
that decides whether the gate runs at all, or it never fires on the branches
it exists for.

`lib/base_ref.rb` is the one answer every script gives to "what did this
branch change" (wu-821). `BaseRef.resolve` is the ladder: the caller's
override, then the manifest's remote default branch
(`origin/<repo.default_branch>`), then the local default branch, taking the
first `git rev-parse --verify --quiet` accepts and warning `stale_base_ref`
only when it falls back to the local branch without an override - an
explicit override is never a fallback, so it never warns. `BaseRef.changed_files`
answers the whole question: the three-dot diff against the resolved base,
unioned with `BaseRef.working_files` (the single `git status --porcelain`
parse - tracked-dirty plus untracked). The working tree is part of the
answer on purpose: a diff alone misses uncommitted and untracked changes,
which is exactly the gap this helper closes. `BaseRef.merge_base` gives
callers that want a two-dot diff (which additionally includes uncommitted
tracked edits, judge.rb's own pattern) the merge-base sha instead of a name
list. `BaseRef.untracked_files` is the `??`-only subset of the working tree,
for a caller (`gate.rb`'s sabotage scan) that needs to tell an untracked path
apart from a tracked-dirty one - an untracked path appears in no diff at all,
even the two-dot form, so it needs its own reporting channel rather than
being silently invisible.

### Fixture manifests

**A test never reads a consumer repo's real `.claude/wurk.json`.**
Asserting that a bead id starts with some prefix would pass for the wrong
reason - that whichever repo the suite happened to run in uses it - and
proves nothing about the value having been read from the manifest at all.
Wurk ships no manifest of its own, so this is now structural rather than a
discipline: there is nothing real to accidentally read.

Tests drive every manifest-derived value from `test/fixtures/manifests/*.json`
via `test/support/manifest_helper.rb`. The fixtures deliberately use a `zz`
bead prefix, `make` gate commands, and names like `faketool` so nothing in
them can be confused with a real value.

```ruby
include ManifestHelper

with_manifest("valid") { assert_equal "zz", Manifest.current.bead_prefix }
manifest_with("worktree", "forge" => {"kind" => "gitlab"})  # one field different
in_tmp_repo("valid") { ... }   # a scratch dir that carries .claude/wurk.json,
                               # for scripts that locate their own manifest
```

`in_tmp_repo` rather than a bare `mktmpdir` for anything that walks up to
find its manifest: inside a bare one the walk-up finds nothing and falls
through to `git rev-parse`, which `FakeSh` correctly refuses.

## `tmux_window.rb open`: the `{id}` seed placeholder

`open <name> <path> <id> <seed>` takes the bead id and the seed prompt as
separate arguments. `{id}` inside `seed` is the placeholder for the id: every
occurrence is replaced with the id verbatim (a plain string replace, not
`format`/`sprintf`, so a seed containing a literal `%` is untouched), on both
the `--no-finish` path and the default finishing path. This is the one
definition of the placeholder - nowhere else in the kit or its docs
describes it; a caller that needs the seed to name the id it was given
writes `{id}` into the seed and nothing more. A seed with no `{id}` is
unchanged, byte for byte, from what it produced before the placeholder
existed.

## `tmux_window.rb open`: `--env NAME=VALUE`

Repeatable. Each assignment is forwarded verbatim to tmux as
`-e NAME=VALUE`, on the `new-window` that creates the seeded window under
`window-per-issue`, and on both the `new-session` and the claude
`new-window` under `session-per-issue`. `data.env_names` reports the names
the call carried, in order; omitting the flag leaves the emitted argv
byte-identical to what it was before the option existed and reports `[]`.
Read it beside `data.skipped` - a call that skipped because the window
already existed opened nothing, so its names were never forwarded anywhere.

Use it when a seeded session needs a variable the surrounding session must
not have. tmux scopes `-e` to the environment of the window it creates and
nothing else - measured against tmux 3.6b on 2026-09-21, a sibling window in
the same session sees nothing and `show-environment -t <session>` reports
`unknown variable`. That is why this is a per-window flag and not a
`set-environment` call: under `window-per-issue` the shared, manifest-named
session also carries the operator's own interactive shells, so a variable set
on the session lands in every one of them. A bot git identity set that way
would rewrite the operator's own commits' author.

Two properties the caller has to know:

- **A `-e` value is an argv element**, visible in `ps` for as long as the
  tmux client runs. Pass an identity, a mode switch, a run id; do not pass a
  token. Nothing in the kit reads a value out of a file or out of the
  calling process's environment into this argv, deliberately: a caller that
  keeps secrets out of its argument list must not have them put back by a
  convenience. `data` therefore reports names only, never values - the value
  is already in the process table, and a machine-readable copy invites a
  caller to log the envelope somewhere more durable. (`commands` renders the
  full argv the way it does for every other flag.)
- **The split is on the first `=` only**, so a VALUE containing `=` is legal
  and survives byte for byte. A malformed assignment - no `=`, or an empty
  NAME - blocks with `env_malformed` and opens nothing, rather than being
  skipped silently.

## `gate.rb`: the quality-gate wrapper

Runs the consumer's own gate commands - `gate.full`, `gate.loop`,
`gate.report`, `gate.report_loop`, `gate.attest` - and reports which tier of
`docs/gate-contract.md` the project reached. It knows no gate tool's flag
surface; every command is manifest data. The most constrained script here.
Each of the five runs in `gate.cwd` when the manifest declares one (default
the checkout root); `data.gate_cwd` reports the resolved directory. See
`docs/manifest.md`.

- `data.skipped_stages` always stays in the payload, for every skip. Whether
  a skip *blocks*, and whether it belongs in what you report, follows a
  three-way `classification`:
  - a gap **in this run** (Dialyzer skipped for a missing PLT, Tests skipped
    because compilation failed) classifies `run_level`, sets `ok` false, and
    warns with `stage_skipped` (blocking);
  - a gap in **what the project checks at all** (`:doctor not installed`,
    `disabled in .quality.exs`) classifies `project_level`, does not block,
    and warns with `stage_skipped_project_level`;
  - a gap the project has declared **permanently inapplicable**
    (`gate.not_applicable_skips`) classifies `not_applicable`, does not
    block, and warns with `stage_skipped_not_applicable`.

  The `project_level` case is not a softening. It is true on every run
  including the green ones, so blocking on it would make `ok` false on every
  full gate run forever - which deletes the signal rather than enforcing it.
  Every skip stays in the payload regardless of classification; `run_level`
  and `project_level` are named in what you report, and `not_applicable`
  need not be - naming a stage that will never apply, forever, is exactly
  the noise that trains readers to stop reading the skip lines at all.
  The taxonomy comes from `gate.project_level_skips` and
  `gate.not_applicable_skips` in the manifest, checked in that precedence
  order (`not_applicable` first, since it is the narrower, explicitly
  enumerated declaration): a project declaring neither gets the strict
  reading, where an unrecognized skip reason blocks, and widening either
  list is an edit to the consumer's own manifest, not to kit source.
- Only one profile argument is accepted: `--profile loop`. It always sets
  `data.attested` to `false`. No `--skip`, `--quick`, or other `--profile`
  value is defined by this script's parser, so passing one is a usage error
  (exit 2), not a narrower run.
- **`data.sabotage.missing` and `data.sabotage.unverifiable` are a report,
  not a gate.** Neither ever blocks or flips `ok`. A present `# sabotage:`
  note (either a real mutation or a stated `n/a` exemption; the prefix is
  matched case-insensitively, so `# Sabotage:` house style counts) is not evidence
  the mutation described was actually run against broken code - only reading
  the diff by hand and confirming the test failed for the right reason is.
  `/commit`'s own Step 0 carries that judgment call; this script only reports
  absence. The scan's scope is the manifest's `gate.sabotage.test_roots`
  pathspec, which may enumerate individual files rather than a whole
  directory.
  The scan itself is a manifest capability, `gate.sabotage` (see
  `docs/manifest.md`): when a project declares no such section,
  `data.sabotage.enabled` is `false` with a `reason`, and `missing` is then
  always `[]` - absence of findings there is not evidence of discipline,
  only evidence the scan never ran.
  `data.sabotage.scanned` is `false` when the scan had nothing to diff
  against at all - the diff-base ladder never resolved
  (`reason: "no_base_ref"`) or the scan's own `git diff` itself failed
  (`reason: "diff_failed"`) - meaning nothing was checked that run;
  `data.sabotage.unverifiable` holds one entry per declaration the scan
  could not check, each with a `reason` of `no_base_ref` or `diff_failed`
  (the whole run, both cases), `file_unreadable` (the file could not be
  read), `declaration_not_found` (the added line could not be located in
  the working-tree file), or `untracked` (a path under a `test_roots`
  prefix that `git status --porcelain` reports as untracked - invisible to
  any diff, so it is reported rather than silently skipped). A consumer
  that only reports the scan names `unverifiable` entries alongside
  `missing` ones; a consumer that gates on the scan decides for itself what
  a non-empty `unverifiable` means - the kit reports, it does not make that
  call.
- **`data.gate_guard` reports; it never writes.** There is no code path in
  `gate.rb` that writes `docs/quality-gate-changes.md` - `test/contract_test.rb`
  asserts that mechanically over every file under `scripts/`.

## `gate_run.rb`: the long-gate runner

Runs the manifest's gate detached, so a gate that outruns a foreground Bash
timeout still finishes and reports rather than dying silently mid-run
(`docs/research/260902-wu-4x9-subagent-long-gate-runs-and-locks.md`). Names
no gate tool of its own: `start` resolves the same manifest fields `gate.rb`
does (`gate.report`/`gate.report_loop`, falling back to `gate.full`/`gate.loop`,
and `gate.cwd`), and bounds the run with `gate.long_timeout_seconds` rather
than `gate.timeout_seconds` - the two timeouts stay separate on purpose: one
bounds a foreground, blocked caller, the other bounds a detached runner that
exists precisely to outlive that bound.

The mechanism is a supervisor, not a bare backgrounded command. `start`
spawns *itself* (`gate_run.rb supervise --run-dir DIR`) detached via
`Sh.spawn_detached`; the supervisor is the gate's real parent, so it is the
only thing that can ever capture and persist the gate's exit status - a
later poller is not the gate's parent and cannot wait on it. The finished
result is written as `result.json.part` and `File.rename`d to `result.json`,
so a reader only ever observes a complete envelope or nothing, never a
half-written one.

### Subcommands

- **`start`** - resolves the manifest, optionally acquires one or more locks
  (see `lock.rb` below), spawns the detached supervisor, and returns
  immediately with the run's identity and a ready-to-run `poll_command`. Does
  not run the gate itself and does not wait for it.
- **`supervise`** - the detached child `start` spawns; not meant to be run by
  hand. Reads `meta.json` from `--run-dir`, runs the resolved gate argv
  through `Sh.run_streaming`, releases any locks named in `meta.json`, and
  writes the `result.json` sentinel.
- **`poll`** - a bounded foreground wait (default 60s) that reports the run's
  current state, re-checking every second until either the state changes or
  the wait elapses.
- **`status`** - the same state computation as `poll` with no wait
  (`--wait-seconds 0` in effect); always exits 0, never blocks or fails,
  because it reports whatever it finds without waiting for it to change.

### Flags

- `start`: `--profile loop` (selects the loop gate commands the way
  `gate.rb` does), `--run-dir DIR` (override the generated run directory),
  `--gate-lock DIR --campaign ID --bead ID` (acquire a gate lock before
  spawning), `--slots-dir DIR [--slots N]` (acquire a machine gate slot
  instead of or alongside the gate lock; the slot count follows the same
  rule as `lock.rb acquire` - the machine config's `machine.gate_slots`
  wins, `--slots N` is the fallback, and `--slots-dir` with neither is a
  usage error), `--wait-seconds N` (bounded lock-acquire wait, default
  600), `--dry-run`.
- `supervise`: `--run-dir DIR` only.
- `poll` and `status`: `--run-dir DIR`, `--wait-seconds N` (`poll` only,
  default 60), `--tail-lines N` (log tail length, default 40).

### The poll loop, worked

```sh
ruby skills/wurk:kit/scripts/gate_run.rb start --profile loop
# -> data.run_dir, data.poll_command (a literal command to run next, verbatim)

ruby skills/wurk:kit/scripts/gate_run.rb poll --run-dir RUN_DIR
# -> data.state: "running" - repeat this exact command
# -> data.state: "finished" - read data.ok and stop
# -> data.state: "abandoned" - the supervisor died or the deadline passed; stop
```

Run `start` once, then run `poll` against the returned `run_dir` (or the
returned `poll_command` verbatim) repeatedly until `data.state` is no longer
`"running"`. Nothing about the loop requires reading this script's source -
`start`'s envelope already hands back the next command to run.

**A `"running"` poll exits 0 by design.** It is not an error or a timeout;
it means the wait elapsed with the gate still going, and the caller's only
job is to run the same `poll_command` again. Only `"finished"` carries the
gate's own `ok`, and only then does `env.fail!` (exit 1) when the gate
itself failed.

### `data` keys

- `data.state` - one of four values:
  - `"running"` - neither a sentinel nor an abandonment reason was found
    within `--wait-seconds`. Carries `elapsed_seconds`, `deadline_at`,
    `log_tail`, and `poll_command`.
  - `"finished"` - `result.json` exists; its own `data` is merged in
    directly (so a finished poll looks like a `gate.rb` envelope), plus
    `ok`.
  - `"abandoned"` - no sentinel, and either the supervisor's pid is
    provably dead (`Process.kill(0, pid)` raised `Errno::ESRCH`) or the
    run's deadline has passed. `poll` reports this as a `blocked` envelope
    (`gate_run_abandoned`) rather than waiting forever on a supervisor that
    can never finish; `data.reason` is `"supervisor_pid_dead"` or
    `"deadline_exceeded"`.
  - `"not_found"` - no `meta.json` in `--run-dir` at all (a bad `--run-dir`,
    or a run directory that was never `start`ed). `poll` reports this as a
    `blocked` envelope (`gate_run_not_found`) too.
- `start` additionally returns `data.run_id`, `data.run_dir`,
  `data.log_path`, `data.sentinel_path`, `data.pid` (the supervisor's),
  `data.deadline_at`, `data.locks` (the locks acquired, if any), and
  `data.poll_command`.

### Exit codes

Standard kit exit codes (see above), with one script-specific rule: `poll`
and `status` never fail or block on `"running"` - only `"finished"` (via the
gate's own `ok`), `"abandoned"`, and `"not_found"` can make either exit
nonzero.

## `portability_lane.rb`: the Linux `/bin/sh` lane

Runs one test file inside a Linux container whose `/bin/sh` is bash 4.4 or
newer, so a shell regression invisible on macOS (where `/bin/sh` is bash
3.2.57) is catchable here. It mounts the repo read-only, repoints
`/bin/sh` at the image bash, and by default runs the hook tests - the
suite whose blind spot the lane exists for.

```sh
ruby skills/wurk:kit/scripts/portability_lane.rb
```

Flags: `--image IMAGE`, `--test PATH` (relative to the repo root),
`--runtime CMD`, `--timeout SECONDS`, and `--dry-run` (renders the
container command, starts nothing).

It is deliberately not part of the default gate, and the reasons are a
contract rather than a preference: the default gate stays stdlib-only
system Ruby, stays green on a machine with no container runtime and no
network, and keeps its measured duration. A missing runtime, a runtime
whose daemon is down, and an image that cannot be pulled are all
`data.status: "skipped"` with a `data.skip_code` naming which, one
warning, and exit 0. A container whose `/bin/sh` does not report bash 4.4+
blocks with `sh_not_modern_bash` even when the run passed, because a green
run under an old shell is the blind spot itself. `data.output` carries the
container output whole.

The default suite reports the lane instead of running it:
`PortabilityLaneTest#test_the_lane_itself` skips with a reason naming
either the missing runtime or the opt-in, and
`WURK_PORTABILITY_LANE=1` turns it into a real run. The full rationale and
the skip taxonomy live in `docs/gate-contract.md`.

## `lock.rb`: the mkdir-mutex

A lock is a directory. Acquiring one is an atomic `Dir.mkdir` - two
processes racing to create the same directory, exactly one succeeds. Backs
`gate_run.rb start`'s optional `--gate-lock`/`--slots-dir` flags and is also
usable standalone by any caller (a campaign mutex, a tracker lock, a
registry lock) that needs the same mutual exclusion. No manifest, and one
shell-out: the keeper spawn (`acquire --hold-seconds`), through
`Sh.spawn_detached` - a lock directory is otherwise a plain CLI argument.

### The owner file

Each held lock directory contains one `owner` file: `key=value` lines, one
per key, written in a fixed order (`campaign`, `bead`, `pid`, `host`,
`purpose`, `acquired_at`, `hold_until`). Not every key is present on every
lock - a human-held lock may carry no `pid`, and `hold_until` is present
only on a lock held through a keeper - and an absent key is simply omitted,
never written empty. A directory that exists with no readable owner file
(briefly, between `mkdir` and the owner file's write, or because a human
made the directory by hand) is reported as held with `owner: null`, never as
an error.

The recorded `pid` must be a process whose lifetime IS the hold, because
`status`/`clear` trust it and nothing else to tell a live hold from a dead
one. There are exactly three legitimate sources: the session itself, for a
lock the session holds on its own behalf (the conductor's campaign mutex,
`--pid <session pid>`); the supervisor `gate_run.rb start` spawns, for a
lock it acquires before running a gate; and the keeper `acquire
--hold-seconds` spawns, for a lock taken on behalf of a worker. A
subagent's `$PPID` is none of these three - it is the conductor session's
process, which outlives no worker and is outlived by none either - so a
worker's lock always goes through `--hold-seconds`, never `--pid`.

### Subcommands

- **`acquire`** - takes one or more locks (`--campaign-mutex`, `--gate-lock`,
  `--tracker-lock`, `--registry-lock` DIRs, and/or a machine slot pool via
  `--slots-dir DIR [--slots N]`) in one bounded wait, all or nothing: if any
  named lock cannot be acquired before the wait elapses, every lock already
  acquired in this call is released and the call reports contention on the
  one that blocked. Requires `--campaign ID --bead ID`, recorded in the
  owner file. Loads the machine config first (`UserConfig.require!`), so an
  invalid `~/.claude/wurk.local.json` blocks the acquire before any
  directory is made. `--hold-seconds N` gives the hold its own process: once
  every named lock is taken, `acquire` spawns a detached keeper
  (`lock.rb keep`, via `Sh.spawn_detached`) that watches every lock this
  call took, records `hold_until` (now + N, ISO-8601 UTC) in each owner
  file, and rewrites each owner file's `pid` to the keeper's. The keeper
  exits `released` once every watched lock is gone, `superseded` once a
  remaining one is owned by neither itself nor the acquiring CLI, or
  `expired` at `hold_until` - leaving the lock exactly as it is, so an
  expired lease is a dead pid `clear` can remove, not a lock the keeper
  frees on its own. `--hold-seconds` and `--pid` are mutually exclusive
  (usage error, exit 2): a hold has exactly one liveness source. A spawn
  failure releases every lock this call just took and blocks
  `keeper_spawn_failed`, rather than leaving a hold whose recorded pid is
  this CLI's own and dies the moment it exits. Even a successful spawn is
  not trusted outright: after the owner rewrite, `acquire` polls the
  keeper's pid briefly (about 1s) for immediate death - a usage exit 2 out
  of the keeper's own argument parsing, an exception during its startup -
  and on a dead keeper rolls back the same way, blocking with its own code,
  `keeper_died_immediately`, so the two spawn failure modes stay tellable
  apart.
- **`keep`** - internal; the detached keeper `acquire --hold-seconds`
  spawns, not meant to be run by hand (like `gate_run.rb supervise`).
  `--dir DIR` (repeatable, at least one), `--acquirer-pid N` (the acquiring
  CLI's pid, counted as the lock's own until the CLI rewrites the owner
  file), `--hold-until ISO`, `--poll-seconds N` (default 2).
- **`release`** - releases one lock directory, refusing (`lock_not_owned`)
  unless the supplied `--campaign`/`--bead`/`--pid` match the recorded owner
  field by field. There is deliberately no `--force`: a foreign or
  ownerless lock is always refused back to a human.
- **`status`** - a read-only probe of one lock directory: whether it is
  held, its owner, its age, and whether it is stale. Always exits 0.
- **`clear`** - removes a lock directory, but only when `status`'s own probe
  would report it provably stale with `staleness_reason: "dead_holder_pid"`.
  Anything else - no owner file, a live holder, an ownerless lock merely
  older than the staleness cutoff - is refused (`lock_not_provably_stale`)
  with the probe attached as evidence, because only a dead holder pid is
  something a script may decide on its own; every other case needs a human.

### The fixed acquisition order

`acquire` always sorts the locks it was given into one fixed order before
taking any of them, regardless of the order the flags were passed in:
campaign mutex and registry lock first (rank 1), then gate lock and tracker
lock (rank 2), then a machine slot (rank 3). Locks release in the reverse of
the order they were acquired. A caller never has to think about
interleaving - it hands `acquire` every lock it wants in any order, and the
normalization here is what turns an out-of-order request into a non-event
instead of a deadlock.

### The slot count: machine config over the flag

The size of the machine slot pool - how many `slot-N` directories an
acquire may take - has two possible sources, and one fixed precedence
(`Lock.resolve_slot_count`, shared by `lock.rb acquire` and
`gate_run.rb start` so the two entry points to one pool can never disagree
about its size):

1. **`machine.gate_slots` in `~/.claude/wurk.local.json`** caps the pool
   when set. The machine config describes the box the acquire is actually
   happening on (ADR-0013). A fleet manifest is checked in and shared by
   every machine that runs the fleet, so a slot count kept there can only be
   right for one of them; nothing relayed from a shared file may raise the
   load above what the machine has said.
2. **`--slots N`** is the fallback for a machine that has not said, and may
   LOWER the machine's cap on one that has: the machine number is how many
   gates the box runs at once across every caller, the flag is how many
   this caller may run, and a caller that asked for fewer gets fewer. Today
   this is how a conductor relays a fleet manifest's number, or states a
   campaign's own cap.

When both are given, the smaller is used. A flag above the cap is lowered
to it and the envelope carries a `slots_overridden` warning naming both
numbers, so a conductor that relayed the fleet's figure can see it was not
the one used; a flag at or below the cap is used as given, with no warning.
`--slots-dir` with no count from either source is a usage error (exit 2)
whose hint names both sources; there is deliberately no default of 1, since
a silent default would let a slot acquire succeed on a machine nobody sized.
`data.slots` and `data.slots_source` (`"machine_config"` or `"flag"`)
report what was used, whenever a slot pool was named.

### `data` keys

- `acquire`: `data.acquired` (the locks taken, each `{kind, dir, owner}`),
  `data.order` (the kinds, in the fixed order), `data.waited_seconds`, and,
  when a slot pool was named, `data.slots` and `data.slots_source`. With
  `--hold-seconds`, also `data.keeper_pid` and `data.hold_until`. On
  contention, `data.acquired` is `[]` and `data.contended` carries
  `{kind, dir, probe}` for the lock that blocked, with `probe` the same
  shape `status` returns.
- `keep`: `data.dirs` (what it was told to watch), `data.reason`
  (`"released"`, `"superseded"`, or `"expired"`), `data.watching` (the dirs
  still held at exit - empty unless `"expired"`).
- `release`: `data.dir`, `data.released` (`true`/`false`).
- `status`: `data.dir`, `data.held`, `data.owner`, `data.age_seconds`,
  `data.holder_alive` (`true`, `false`, or `null` when it cannot be
  determined - no pid recorded, or the owner file could not be read),
  `data.stale`, `data.staleness_reason` (`"dead_holder_pid"`,
  `"ownerless_and_older_than_cutoff"`, or `null`).
- `clear`: `data.dir`, `data.probe` (the same shape as `status`'s payload),
  `data.cleared` (`true`/`false`).

### Exit codes

Standard kit exit codes. `status` always exits 0 (a read-only probe, never
a judgment); `acquire`, `release`, and `clear` exit 1 when they report
`blocked` (contention, a foreign owner, or an unprovable staleness claim).
`acquire` also blocks `keeper_spawn_failed` when `--hold-seconds` could not
spawn its keeper, and `keeper_died_immediately` when the keeper spawned but
was already dead by the time `acquire` checked.

## `campaign_state.rb`: which campaign may a scheduler start

Reads a campaign directory (`--dir`, repeatable; default
`.claude/campaigns`) and reports, per campaign plan, its Status line,
whether a consent file exists and is ADOPTED, and whether the campaign
mutex (`--locks-dir`, a `lock.rb` directory named `campaign-<id>`) is
live-held. `list` and `show ID` are read-only; `arm ID` and `disarm ID`
rewrite exactly one line of one plan file and honor `--dry-run`. Like
`lock.rb` it takes no manifest and runs no `Sh`: every path is an
argument. The file schema, the campaign record's keys, and every
`blocked`/`warnings` code are documented where the conductor reads them:
`skills/wurk:conductor/REFERENCE.md`, "Campaign files and
`campaign_state.rb`". The one rule worth restating here: `arm` refuses
without an ADOPTED consent file and never writes one, because consent is
a human artifact and this script only ever edits the plan's Status line.
`disarm` takes an ARMED or a QUEUED plan back to DRAFTED (dropping a
QUEUED line's `after <id>` tail, `data.before` naming the word cleared)
and warns `not_armed` on anything else. `arm` on a QUEUED plan drops the
old `after <id>` tail too, before writing ARMED (no tail) or, with
`--after`, the new one.
A plan's H1 may read `# Campaign <id>` or `# Campaign: <id>`; `list`
warns (`unparsed_campaign_file`) about an unrecognized top-level `*.md`
under the dir only when its column-1 Status line reads ARMED or QUEUED -
the one shape an unrecognized file could be an armed campaign hiding
from the `--armed` refusal checks (`locate` refuses a bad H1, so only a
hand edit gets one there). A finished WRAPPED or DRAFTED plan in a
legacy H1 shape, or a file with no Status line, stays silent instead of
warning on every `list` call forever. Separately, a plan that DID parse
but carries no column-1 Status line at all gets `status_missing` and is
treated as not armed.
It reads no manifest, but it does read machine config
(`~/.claude/wurk.local.json` via `lib/user_config.rb`), lazily and only
for a plan that carries a `Machine:` binding. `arm --host NAME` writes
only this machine's own `machine.name` into that binding and never
falls back to the OS hostname. A column-1 `Machine:` line that is not a
bare name (operator prose, for instance) is malformed, never a bind: it
is treated as unverified, warns `machine_binding_malformed` naming the
file and the line, and blocks `arm`/`disarm` until a human edits it.

## `report_check.rb`: does a worker's report file actually parse

Takes one or more paths - a campaign's reports directory, or a single
`<bead-id>-report.json` - and reports, per file, whether it parses as the
JSON the conductor's contract says it holds. A file that does not parse
comes back as a `blocked` `report_not_json` entry naming the path, what
shape was found instead (`fenced`, `prose`, `empty`, or a malformed
`bare` document), and a `Fix:` clause: the worker re-emits the report as
bare JSON with no markdown fence and no prose preamble. A named file that
is not there yet is the `report_missing` warning, not a block, because
the sweep asks about beads still in flight; a directory that does not
exist is `reports_path_missing` and one holding no reports is
`no_reports`.

It is a reader: it never edits, moves or deletes a report, and it never
rescues a fenced file into JSON - a reader that tolerates the shape is how
the shape spreads. Like `campaign_state.rb` it takes no manifest, runs no
`Sh`, and has no default directory, so the reports dir stays the caller's
seam value (the fleet manifest's `campaignState.reports`) and is never
spelled in the script. Nothing mutates, so `--dry-run` has nothing to
skip. The guard exists because prose did not hold: in one measured
campaign four of eight report files opened with a code fence or a prose
H1, and every later reader that parses rather than eyeballs lost those
workers' results silently. The conductor runs it at the sweep
(`skills/wurk:conductor/SKILL.md`, "Sweep on every wake, and a heartbeat
so wakes happen").

One field is checked beyond parsing, and only when present: a report
carrying `reviewRound.findingsByLevel` that is not an object of the four
level counts (`mustFix`, `shouldFix`, `note`, `unranked`) as non-negative
integers gets the `findings_by_level_malformed` warning, never a block.
The field is optional ("`finding_severity.rb`: the finding_severity Jev
site"), so a report without it passes; each entry in `data.reports`
carries `findings_by_level` as null (absent), `ok` or `malformed`.

## `session_metrics.rb`: harness metrics from session transcripts

Reads Claude Code session transcripts (JSONL) and reports what the harness
actually did: tool calls by name, tool failure rate, skills fired, tokens
per model, dollar cost when the machine quotes prices, and where sessions
sat still. Read-only in the strongest sense the kit has - it never writes a
transcript, never shells out, never reaches the network, and never puts a
line of session CONTENT into its output. Names and numbers leave here, and
nothing else, because the envelope is read by a conductor and may land in a
journal.

```sh
ruby skills/wurk:kit/scripts/session_metrics.rb report  [--dir DIR] [--file PATH] [--since ISO8601] [--max-sessions N]
ruby skills/wurk:kit/scripts/session_metrics.rb signals [--dir DIR] [--file PATH] [--since ISO8601]
```

`--dir` is the transcripts root and defaults to `~/.claude/projects`;
`--file` reads one transcript instead. A missing root warns and answers
with an empty window - "this machine has no transcripts" is a complete
answer - while a `--file` that is not there blocks. `report` includes
per-session rows capped at `--max-sessions` (default 50, `0` for all) so
one envelope stays one envelope; totals are never capped.

`signals` emits ONLY over-threshold items, so a healthy window answers with
an empty list and a scheduler can route on "is this list non-empty". The
thresholds: a session failure rate at or above 0.20 over at least 5 tool
results, any agent-session stall, and any error event in the machine's
telemetry sink. Everything else is `report`'s job.

**A session id does not identify a transcript.** A parent session and the
sidechain files its subagents write all carry the same `sessionId`, so one
window can produce several signal items under one id with different numbers
behind them. Each item is accurate per transcript, and a reader keying on
the id reads the set as one finding sighted twice - which matters where a
recurrence bar counts INDEPENDENT runs, because two items off one session
are not two runs. So both keys are named: every session-derived signal item
carries a `transcript` beside its `session`, reported relative to the
transcripts root (a path outside the root, and every path under `--file`
which has no root, is reported exactly as it came in), and
`data.sessions_by_id` carries one row per session id - its counts summed
across the transcripts that claim the id, the per-transcript detail nested
under `transcripts`. A reader keying on either gets one row per key, and neither
has to know about the other's. The row deliberately has no `kind`: rule 3
classifies per transcript by construction, and rolling it up would mean
inventing a tie-break between a parent and a sidechain file that classify
differently. The rollup is built from what the envelope already carries -
under `report` the rows that survived `--max-sessions`, under `signals` the
sessions the emitted items name - so it never pushes an envelope past the
size the cap was set to hold.

**The three measurement rules**, each of which a naive gap metric gets
wrong in a way that still looks plausible:

- **Floor and ceiling.** A gap under 300s is ordinary latency - a model
  thinking, a gate running. A gap at or over 4h is a human who closed the
  laptop and resumed, counted as a `resumption`; counting it as a stall
  makes an overnight break the largest incident in the window. Only a gap
  between the two is a stall.
- **Turn boundary.** A gap that ends at a fresh user turn is idle time
  BETWEEN turns - the session was waiting for a person. But a user record
  is not automatically a fresh turn: one whose content carries
  `tool_result` blocks is the harness returning a tool's output mid-turn,
  and a long gap in front of THAT is exactly the stall worth seeing. The
  distinction is the content of the record, not its type.
- **Agent vs interactive.** Gaps in an interactive session are human think
  time and say nothing about the harness; the same gap in an agent session
  is a real stall. They are counted separately and only the agent ones
  become signals. A session is read as interactive unless the transcript
  positively shows automation and shows no human - an absent prompt source
  counts as human, because misreading a person's lunch break as an agent
  stall manufactures signals, while the opposite error only withholds one.
  A subagent's records are agent records whatever session surrounds them.
  The shape of the records is one rule; where the file sits is the other,
  and either is enough. Claude Code writes a subagent's transcript under
  its parent's session directory, `<project>/<session>/subagents/agent-<id>.jsonl`,
  and those records carry no prompt source, so read by shape alone they
  looked like a human's turns. A transcript on that path is an agent
  session outright; the row says which rule fired in `kind_source`
  (`shape`, `path` or `both`), carries the session directory it sits
  under as `parent_session` and the writer's `agent_id`, and reports the
  real project rather than `subagents` as its `project`.

**The classification guard.** `promptSource` and `isSidechain` are written
by the transcript writer, not by this kit, and the conservative default
above means their disappearance is silent: every session would read
interactive, every agent stall would vanish, and `signals` would answer
with the same empty list a genuinely healthy window produces. When a
window holds at least 5 transcripts and NOT ONE of them carries either
field, the envelope takes the `agent_classification_unavailable` warning,
naming the field and the transcript count and saying to re-verify the
classification rule against a current transcript. It is a warning and
never a block - the counts are still true, it is only the classification
that has nothing behind it - and the minimum sample is there for the same
reason the failure rate has one: a handful of unmarked transcripts is
ordinary, and a guard that cries on them is a guard nobody reads.

**Cost** is tokens times a per-model price table read from the machine
config (`metrics.prices`, `docs/machine-config.md`). The kit ships no
prices: an absent table means cost is `null`, never a guess, and one
unpriced model makes the total `null` rather than pricing part of a window
and presenting it as the whole. **Error events** come from the sink at
`metrics.error_events`, read absent-safe - the hook that writes it is a
separate opt-in, so a configured path with no file yet is normal and reads
as zero.

Parsing is defensive throughout: an unknown field is ignored, a malformed
line is counted in `malformed_lines` and skipped (with a warning), an
unreadable file warns, and a record with an unparseable timestamp drops
out of the gap pass instead of ending the run. A transcript is an
append-only log written by a program that ships faster than this one; it
will grow fields, and none of them are a reason for a metrics run to die.

Its tests run over synthetic fixtures under `test/fixtures/sessions/`. A
real transcript from a machine's own `~/.claude/projects` is a MANUAL
check and never a fixture: committing one would put session content into
the tree permanently.

## `build_agents.rb`: agent definitions from templates and blocks

Renders every `<name>.md` in an agents directory (`--dir`, default
`agents`) from `<name>.md.in` plus the shared blocks under `blocks/` that
`routing.yml` routes to it, and lints the routing first (ADR-0019,
proposed). A template is frontmatter followed by prose in which a line
`@include <block>` stands for `blocks/<block>.md`; the generated file is
the template with one `DO NOT EDIT` banner after the frontmatter and each
include replaced by its block. `routing.yml` is `blocks: {<block>:
[<name>, ...]}` and is the authority on who carries what: an include the
file does not route to that agent, a routed agent whose template lacks
the include, a block with no entry, an entry with no block or no
template, a block containing an include, a template without frontmatter,
and a `<name>.md` with no template are each a `blocked` code
(`unauthorized_include`, `missing_include`, `orphan_block`,
`dangling_route`, `unknown_agent`, `nested_include`, `no_frontmatter`,
`ungenerated_agent`; `dangling_include` for an include with no block), and
any of them refuses the build before a file is written.

`--check` compares instead of writing and adds `stale_generated` and
`missing_generated`; `test/build_agents_test.rb` runs it against this
repo's `agents/`, so the kit suite is where a stale generated file is
caught. Without `--check`, files that differ are rewritten (through a
sibling temp file and a rename); `--dry-run` lists them under `commands`
and writes nothing. Like `campaign_state.rb` it takes no manifest and
runs no `Sh`. `data.agents[]` carries `{name, path, status}` with status
`current`, `stale`, or `missing`; `data.blocks[]` carries each routing
entry.

## `judge.rb`: the merge-time prose judge

The mechanism ADR-0008 decided on: a merge-time model judge over
judgment-bearing prose, run at the merge seam (a consumer's own extension
file, never inside `run.rb`) rather than in the required gate. **The
registry is manifest data** - `judge.model` and `judge.registry` (see
`docs/manifest.md`) - so `judge.rb` itself names no scope, no judged text,
and no violation rule; a consumer that declares nothing simply never runs
it. Each registry entry states a `scope_prefix` (and optional
`scope_suffix`), a judged `text` path, and a `focus` string describing what
the propose pass should look for.

- **Collection, in order:** the registry check comes first, before any
  shell-out at all - a consumer with no `judge` section reaches its
  `no_registry` skip without spawning a process. Then CLI presence
  (`which claude`), base-ref resolution (`--base`, then the manifest's
  `repo.default_branch` on the remote, then locally, first to resolve
  wins), `git merge-base`, and a `-U0` diff against it, split into
  per-file chunks and scoped per registry entry.
- **One propose call, one independent refute call, per candidate.** The
  propose pass proposes violations from the scoped hunks and the judged
  text; the refute pass sees the identical hunks (rendered once, shared by
  both prompts) and is asked to independently try to refute each candidate,
  grounded only in the judged text, the claim, or the hunks - "something
  elsewhere in the codebase might compensate" is a hypothesis, not grounds.
  Only survivors are reported.
- **Fail-closed parsing throughout.** An unparseable or wrongly-shaped
  propose response yields no candidates; an unparseable or ambiguous refute
  response yields "not a violation" - never an exception. A CLI response is
  read only from a `"type": "result", "is_error": false` stream event;
  anything else is `nil`.
- **A surviving finding is `blocked` with `needs: "human"`, never a
  warning.** The script cannot resolve it - `blocked` is the envelope's way
  of saying so. What to *do* about a finding (refuse the request, report it,
  stop) is stated in the skill prose that runs this script, not decided
  here.
- **A skip is reported with a named reason, never a silent pass or fail:**
  `no_cli`, `no_base_ref`, `no_scoped_changes`, `no_registry`. A registry
  entry whose judged `text` file does not exist is a configuration error,
  not a skip - it `block!`s as `judge_text_missing`.
- **No test in this suite makes a real model call.** The `claude` CLI is
  invoked only through `Sh.run`, exactly so `FakeSh`'s unauthorized-command
  exception is the backstop: a test that forgot to register a `["claude"]`
  expectation fails loudly rather than spending. `test/judge_test.rb` drives
  every case - scoping, prompt assembly, the survivor and refuted paths, every
  fail-closed parse branch, every skip reason - against the `judge` fixture
  manifest, never against a repo's real `.claude/wurk.json`.

## `critic_eval.rb`: the review-agent trust bar

Scores SAVED review-agent output against a labeled fixture corpus, so a
consumer can say whether one of its `mr.review_agents` has earned the
authority `/wurk:mr` already gives a must-fix finding - the round does not
open the request with one in it. The corpus layout, the meta fields, and
the 0.8 precision/recall bar are documented once, in
`docs/recipes/review-agents.md` ("Trusting a critic"); this section is the
script contract.

- **It never runs a model, and shells out to nothing.** The agent run is a
  hand-run or skill-driven step that saves each case output to
  `<outputs>/<case-id>.md`; the script reads those files. Deterministic in,
  deterministic out - the same saved outputs score the same way twice, and
  a red bar is never an agent having a bad afternoon. It takes no manifest
  either: corpus and outputs are paths, the agent name is a filter.
- **Findings are parsed by two rules.** A line naming exactly one severity
  word starts a finding (a line naming two or more is a vocabulary legend,
  not three findings), and that finding's body runs to the next finding or
  the next heading - the rank and the explanation are almost never the same
  line, and a corpus expectation is matched against the body.
- **Four outcomes, two ratios.** hit / miss / false_positive /
  true_negative per case; `data.precision`, `data.recall`, `data.counts`,
  `data.cases` and `data.meets_bar` for the run. A ratio with no
  denominator is `null`, never `1.0`, and `meets_bar` is false when either
  is - an unmeasured half is not a passed half.
- **Below the bar is a warning, not a block.** `below_trust_bar` carries
  the numbers; the run still exits 0 and the script never edits a manifest.
  Promoting an agent to blocking is a call with a person's name on it
  (ADR-0008). What does block is an incomplete evaluation: a case with no
  saved output (`missing_output`), an unreadable or wrongly-labeled
  `meta.json` (`bad_meta`, `bad_label`), a missing directory. A saved
  output with no case only warns (`unmatched_output`).
- `test/critic_eval_test.rb` drives the scoring rules on synthetic lines
  and the CLI on the four-case worked corpus under
  `test/fixtures/critic_eval/`, which scores 0.5 / 0.5 on purpose.

## typesafe.rb: the Jev client and the call-site contract

The kit's client for TypeSafe's System One API (the Jev model: typed
judgments - `choice`, `noul`, `score` - with probabilities, never free
text). `lib/typesafe.rb` is what a call site requires (`Typesafe.judge`,
`Typesafe.record_outcome`, `Typesafe.site_mode`, `Typesafe.threshold_key`);
`typesafe.rb` is the CLI over it for shell callers, operators and smoke
tests. This section is the contract every call site builds to. Its
configuration is the machine config's `typesafe` section, documented in
`docs/machine-config.md` ("typesafe"); no manifest is read, so the script
works from any directory. It SHIPS DARK: every site is `off` unless the
machine config names it with another mode.

### Usage and `data` keys

```
typesafe.rb call    [--site NAME] --input PATH|-  [--dry-run]
typesafe.rb outcome --call-id ID --site NAME --action LABEL
                    [--decision LABEL] [--agreement agree|disagree|n/a] [--dry-run]
```

- **`call`** reads one JSON input (a file, or stdin with `--input -`):
  `{state, questions: {id: {type, instructions, criteria?}}, question_set:
  {id, version}, source?}`. `state` is a string, object or array; question
  ids and the question-set id match `[a-z0-9][a-z0-9_-]{0,63}`; `version`
  is a positive integer. `question_set` is required with `--site` and
  optional without it (no `--site` is an ad-hoc probe call, mode `probe`).
  `data`: `outcome`, `reason`, `call_id`, `site`, `mode`, `model` (the
  pinned id), `served_model`, `answers`, `usage` (`input_tokens`,
  `output_tokens`), `cost_usd`, `cost_estimated`, `elapsed_ms`,
  `http_status`, `retry_after`, `threshold_key`, `dry_run`, and `request`
  on a dry run. **A caller routes on `data.outcome` alone.** `ok` exits 0
  with no block; any other outcome exits 1 with exactly one `blocked` entry
  whose `code` equals `data.outcome`. `commands` holds
  `POST https://api.typesafe.ai/v1/systemone` when the request was sent
  (or, on a dry run, would be) - never a header.
- **`outcome`** appends the caller's outcome line (below) for a `call_id`
  the `call` envelope returned. `data`: `line`, `written`, `dry_run`.
- **Usage errors exit 2 with no envelope:** no or unknown subcommand, an
  unknown flag, `call` without `--input`, `outcome` without `--call-id`,
  `--site` or `--action`, and a `--call-id`, `--action`, `--decision` or
  `--agreement` value that breaks the label rule. `--help` (first, or
  after a subcommand) prints usage and exits 0.
- **Also blocked, outside the outcome set:** an invalid machine config
  (`user_config_invalid`, with `data` empty), and a failure reading or
  writing the state dir (`state_dir_error`, `needs: "human"`,
  `data.outcome` null). The latter's message names only the exception
  class, never a path, and a live call's spend may be missing from the
  ledger. A caller treats both like any other non-`ok` outcome.
- **An input the CLI cannot read or parse** is `input_invalid` (reason
  `input`) and its message carries the parser's line and column when it
  has them, or the read error's class - never the parser's message, which
  quotes the input.

### Modes

- **`off`** (the default for every site, configured or not) - refused
  first, as `site_off`: no input read, no ledger read, no key touched, no
  log line, no request. This is every dark site's hot path.
- **`shadow`** - call Jev, log its answer beside the caller's own
  decision, and act on the caller's decision only.
- **`on`** - the caller may act on Jev's answer, subject to the caller
  rules below.
- A mode outside these three blocks at config load (`user_config_invalid`
  on every kit script that loads the machine config): the mode decides
  whether text leaves the machine, so guessing is worse than stopping.

### The closed outcome set

| code | when | request sent? | `needs` |
|---|---|---|---|
| `ok` | 200, decodable, served model == pinned model | yes | - (not blocked) |
| `site_off` | the site's mode is `off` | no | `none` |
| `source_restricted` | input `source` is in `typesafe.restricted_sources` | no | `none` |
| `input_invalid` | input unreadable, not JSON, or wrong shape; `reason` names the field | no | `human` |
| `key_missing` | key file `absent`, `unreadable` or `blank` (the `reason`) | no | `human` |
| `budget_exhausted` | `reason` `budget_unset`, `price_unknown`, `spend_unmeasurable` or `cap_reached` | no | `human` |
| `rate_limited_local` | `per_minute` attempts already in the trailing 60 s | no | `none` |
| `unauthorized` | 401 or 403 | yes | `human` |
| `rejected` | 422 | yes | `human` |
| `rate_limited` | 429; `retry_after` passed through (trimmed, at most 64 chars) when sent | yes | `none` |
| `overloaded` | 529 | yes | `none` |
| `other_status` | any other non-200 status | yes | `none` |
| `timeout` | open, read or write timeout, or the overall deadline | yes | `none` |
| `transport` | socket, DNS, TLS, refused/reset connection, EOF, anything unforeseen | yes | `none` |
| `undecodable` | 200 but the body is not a JSON object, or `answers` is missing or not an object | yes | `none` |
| `model_mismatch` | 200 but the response `model` is not the pinned model (or absent); answers discarded | yes | `human` |

`needs: "none"` marks a refusal with nothing for a person to fix right
now; `needs: "human"` marks a configuration or input a person has to
change. For `timeout` and `transport`, `reason` is the exception class
name only, never its message. The pre-call refusals run in a fixed order -
mode, input, privacy, budget, local rate, key - and every one of them
before the key file is touched.

### The fallback rule

**Any outcome other than `ok` means: do exactly what the site did before
Jev existed, and log it.** A non-`ok` outcome is never read as a "no", a
low score, or any other answer. Every block message ends by saying so.

### One attempt, a hard deadline

Exactly one HTTP attempt per call, no retries and no backoff - a 429 or
529 is returned, not retried; the caller falls back. The attempt runs in
a fresh `Net::HTTP.start` block (a new connection, closed when the block
exits, never pooled or reused after a timeout), with the site's
`deadline_ms` (default 1500, at most 60000; a probe call uses the
default) as the open, read and write timeouts and as an overall
`Timeout.timeout` guard.

### Budget and rate

- **Refusal reasons**, checked before any request: `budget_unset` (no
  `typesafe.budget.monthly_usd` - no default; dollars are explicit),
  `price_unknown`, `spend_unmeasurable`, `cap_reached`; then
  `rate_limited_local` against `typesafe.budget.per_minute` (default 60),
  counting this month's ledger lines in the trailing 60 s (and last
  month's file across a month boundary).
- **The price rule.** The pinned model's row in the machine config's
  `metrics.prices` must quote BOTH `input` and `output` in USD per
  million tokens (write `output: 0` when output is free). A missing row,
  or a row missing either, is `price_unknown`: an unknown price is
  could-not-measure, never free. The kit ships no price.
- **Cost.** With usage in the response (any outcome, a `model_mismatch`
  included), and only when both token counts are integers:
  `input_tokens * input + output_tokens * output`, per million,
  `cost_estimated: false`. Without it (timeouts, transport failures, most
  non-200s, a 200 with no usage) the provider may still have billed, so the
  ledger records a conservative bound with `cost_estimated: true`: the
  request body's byte size at the input price, plus 256 output tokens per
  question at the output price. **Assumption:** a token count never
  exceeds the request's byte count - true of common tokenizers, unverified
  for Jev's. Every attempt therefore gets a number, so one slow response
  never turns the month unmeasurable.
- **`cap_reached`** fires when this month's summed `cost_usd` plus this
  request's bound would exceed `monthly_usd`.
- **Unmeasurable spend.** A ledger line whose `cost_usd` is not a number,
  or a line that is not a JSON object (reported as a `ledger_malformed`
  warning with the count, from the client's `ledger_malformed:<count>`),
  makes every later call refuse `spend_unmeasurable` for that month. The
  client never writes a null cost, so this means a hand edit or a damaged
  file. To clear it, an operator checks the provider's bill, then fixes or
  removes the offending line.
- **Two accepted overshoots.** The ledger is not locked across processes,
  so concurrent callers can each pass a check only one of them should
  have, bounded by one call's cost per racer; and the no-usage bound is
  itself an estimate whose error can put spend past the cap by that
  error.

### The logs

Both files live in the state dir (`typesafe.state_dir`, default
`${XDG_STATE_HOME:-$HOME/.local/state}/wurk/typesafe`, created mode 700;
files mode 600, one JSON object per line, one write per line), named by
UTC month:

- **`ledger-YYYY-MM.jsonl`** - one line per live attempt, written even if
  the attempt raised: `ts`, `month`, `call_id`, `site`, `model`,
  `outcome`, `cost_usd`, `cost_estimated`, `input_tokens`,
  `output_tokens` (plus `reason` on `transport`). Pre-call refusals and
  dry runs write no ledger line.
- **`decisions-YYYY-MM.jsonl`**, `kind: "decision"` - one line per `call`
  for every outcome except `site_off`, refusals included: `ts`,
  `call_id`, `site`, `mode`, `question_set` (`{id, version}` or null),
  `threshold_key`, `model`, `served_model`, `outcome`, `reason`,
  `http_status`, `retry_after`, `answers`, `input_tokens`,
  `output_tokens`, `cost_usd`, `latency_ms`. No `state`, `questions` or
  `source` text unless `typesafe.log_state` is true - and never, even
  then, on a `source_restricted` or `input_invalid` line.
- **The same file, `kind: "outcome"`** - the caller's second line, from
  `outcome` / `Typesafe.record_outcome`: `ts`, `call_id`, `site`,
  `action`, `decision`, `agreement`. `action` and `decision` are labels
  (`[A-Za-z0-9_.:-]{1,64}`), never prose, so caller text cannot enter the
  log this way; `agreement` is `agree`, `disagree`, `n/a` or absent. In
  shadow mode this line is where agreement between Jev and the caller is
  recorded.
- A dry run writes neither file.

### Question sets and thresholds

A question set is `{id, version}` in the input, carried beside the
question text it versions. **Any change to a question's instructions or
criteria is a new version.** A threshold is keyed by
`Typesafe.threshold_key`: `<site>:<question-set id>@<version>:<pinned
model>`, reported as `data.threshold_key`; a threshold stored for one key
never applies to another, so a new version or a new pinned model starts
unthresholded. Storing thresholds and sweeping them against a labelled
corpus belong to the eval tooling, not this client.

### Restricted sources

A caller that may pass text from a restricted origin labels it with
`source`. A source listed in `typesafe.restricted_sources` refuses as
`source_restricted` in every mode, `shadow` included, before any text
leaves the machine, and its decision line carries no text even with
`log_state` on. An absent `source` is unlabelled and allowed, so labelling
is the caller's duty: a site that can carry restricted text always sets
it.

### Caller rules every site follows

- Jev may ADD caution - a hold, an escalation - and never remove one. Held
  topics and hard stops stay in code.
- Keep arithmetic, dates, counting and identity out of Jev; compute them in
  code.
- Send only text from a trusted author, never adversarial text.
- A judgment on content that is later edited or cleared is invalidated in
  the same write that changes the content.
- Never apply thresholds from a partial eval run.
- Route on `data.outcome`; apply the fallback rule to everything but
  `ok`; write the outcome line after acting.
- Always pass the site's own name (`--site`, or `site:` to
  `Typesafe.judge`). A call with no site is a `probe` for operators and
  smoke tests: it ignores site modes, so a call site that omits its name
  bypasses the `off` default this contract depends on.

### The model and the key

- **The model is pinned:** `typesafe.model`, default `jev-1.13.0`, never a
  `-latest` id (one blocks at config load). The request always names the
  pinned id, and a response from any other model is `model_mismatch`, its
  answers discarded.
- **The key is a path, never the key:** `typesafe.key_path` (default
  `~/.claude/typesafe-api-token` under the current HOME, mode 600). It is
  read only after every other check passes, and never appears in any
  envelope, log line, exception reason, warning or test output. A key file
  readable by group or others adds a `key_mode_open` warning, never a
  refusal. `--dry-run` shows the request with `Authorization: Bearer
  [REDACTED]` and only checks that the key file exists (it never opens it,
  so an unreadable or blank key surfaces on the first live call); a dry
  run reports the outcome a live call would reach up to the request -
  `site_off` on a dark site - sends nothing and writes nothing. The dry
  run's `data.request.body` does carry the caller's own input back to the
  caller; that is its purpose.

### How the tests prove it without a socket

`test/typesafe_test.rb` (the library) and `test/typesafe_cli_test.rb`
(the CLI, in-process) run every case against `test/support/fake_http.rb`:
a stand-in for `Net::HTTP.start` that replays scripted real
`Net::HTTPResponse` objects, raises on any unscripted start, and records
each attempt so every case asserts exactly one. Loading it also prepends a
lock onto the real `Net::HTTP.start` for the whole test process, so a test
that forgets the seam gets a loud `transport` /
`FakeHTTP::RealNetworkForbidden` instead of a connection. The key is a
random sentinel string in a tmp key file under a tmp HOME (the suite's
HOME guard is in force); `XDG_STATE_HOME` and the state dir are pinned to
tmpdirs; and every Result, envelope, captured stdout and stderr, ledger
and decision file is swept for the sentinel.

## `report_triage.rb`: the report_triage Jev site

The first call site built on the Jev client (previous section). After the
conductor has read a worker's report file and classified it itself - done,
blocked or stuck - this asks Jev the same question over the report's prose
and returns one field a caller routes on. `lib/report_triage.rb` holds the
question set, the state builder and the reading of the answer;
`report_triage.rb` is the CLI the conductor's sweep runs. It SHIPS DARK:
the site is `off` unless the machine config names `report_triage` under
`typesafe.sites` with another mode, and switching it is an operator act.

### Usage and `data` keys

```
report_triage.rb --report PATH --conductor done|blocked|stuck --source LABEL
                 [--threshold N] [--dry-run]
```

`data`: `site`, `mode`, `outcome` (the client's closed-set outcome, or
`site_off`, or null when no call was made), `reason`, `call_id`,
`threshold_key`, `report` (the path passed), `report_digest` (the first 16
hex of the file's SHA256, null when the file was not read), `conductor`,
`jev_class`, `jev_confidence` (the probability Jev gives its chosen class),
`urgency` (the score, or null), `agreement` (`agree`, `disagree`, or `n/a`
when there is no answer), `action`, `add_needs_you`, `threshold`,
`cost_usd`, `dry_run`, `outcome_line_written`, `journal_line` (a one-line
`[probe]` entry for the conductor's journal naming the report basename and
digest, both classes, Jev's confidence, urgency, mode and what changed;
null when the site is off), and `request` on a dry run. No report text
appears in the envelope except in a dry run's `request.body`, as with the
client; the key never appears.

`action` is one of `site_off`, `skipped` (reason `nothing_to_judge`),
`dry_run`, `shadow_logged`, `needs_you_added`, `no_change` (reason
`jev_done`, `conductor_flagged`, `no_threshold` or `below_threshold`) or
`fallback` (reason: the client's outcome, `answer_malformed`,
`report_unreadable` or `state_dir_error`). There is no action that clears,
removes, downgrades or marks anything done.

### Routing and exit codes

**A caller routes on `data.add_needs_you` alone.** It is true only in `on`
mode for an `ok` answer that meets the add rule below; everything else,
every fallback included, changes nothing. Exit 0 on every success, skip,
off and fallback (no `blocked` entry: a dark site is the ordinary state,
unlike `typesafe.rb call`). Exit 1 only for an invalid machine config
(`user_config_invalid`), which a caller treats like any fallback. Exit 2
for usage: a missing `--report`, `--conductor` or `--source`, a conductor
class outside the three, a source that is not a label, a threshold that is
not a number in (0, 1], a stray argument or an unknown flag.

### The question set

`report_triage@1`, two questions over the same state:

- **`state`** (choice): judging only from `report`, where does the task
  stand - `done` (finished, nothing waits on anyone), `blocked` (the worker
  needs something outside itself: a decision, a permission, another task,
  a person) or `stuck` (not finished, and no outside dependency named that
  would unblock it).
- **`urgency`** (score, four levels): how soon the operator must act -
  nothing to do; read at the next review; something waits on the
  operator; act now. Urgency is recorded and journaled only; in this
  version it never adds an item.

Any change to either question's instructions or criteria is a new
version, so it starts unthresholded. The test pins version 1's text by
digest to make that a deliberate step.

### What state is sent

Only the report's prose, and only when present and non-blank:
`openQuestions`, `judgementCalls`, `discoveredDeps` (each entry's `summary`
only), `notesWritten` and `reviewRound.deferred`, under a `report` key. A
report with none of them is skipped (`nothing_to_judge`) with no call.
Excluded on purpose:

- `status` - a self-stated label; sending it makes the judgment
  label-reading.
- `gate`, `committed` - facts code already has.
- identity: `bead`, `repo`, `branch`, `sha`, `mr`, `repos_touched`,
  `scopeAuthority`, and a dependency's `owningRepo` and `existingBead`.
  Identity and counting stay out of Jev.
- any field not listed, including a later optional report field, until a
  new question-set version adds it.

### The add rule, and the never-clears rule

- **`shadow`**: call, journal both classifications (the client's decision
  line holds Jev's answer, the outcome line holds the conductor's class and
  the agreement), act on the conductor's own read only.
  `add_needs_you` is always false.
- **`on`**: `add_needs_you` is true ONLY when the conductor said `done`,
  Jev says `blocked` or `stuck`, a threshold was passed, and Jev's
  confidence is at or above it. A conductor that already said blocked or
  stuck is already surfaced (`conductor_flagged`).
- **Never clears.** Jev may add caution, never remove it. A Jev `done` is
  `no_change` / `jev_done` whatever the conductor said and however
  confident Jev is: it never marks a bead done, clears or downgrades an
  item, or changes a journal entry or a bead's status.

### The fallback rule

Any client outcome other than `ok`, a malformed answer (a class outside the
three, a missing or out-of-range probability for it), an unreadable or
unparseable report, and a state-dir failure are all `action: fallback`
with a warning (`jev_fallback`, `report_unreadable` or `state_dir_error`,
naming labels and exception classes only), `add_needs_you` false and exit
0. A fallback is never read as an answer; the sweep stays exactly as it
was. Client warnings (`key_mode_open`, `ledger_malformed`) pass through as
in `typesafe.rb`.

### Source label and threshold

- **Source.** The conductor passes `--source repo:<repo directory
  basename>`. An operator keeps a repo's reports off the wire by listing
  that label in `typesafe.restricted_sources`, which refuses in `shadow`
  and `on` alike (`source_restricted`, a fallback, no request).
- **Threshold.** `--threshold` is the eval tooling's enabled threshold for
  `data.threshold_key` (`report_triage:report_triage@1:<pinned model>`),
  never a number the conductor picks. Storing and sweeping thresholds
  belongs to the eval tooling. Without one, `on` mode adds nothing
  (`no_threshold`).

### The site pattern

The checklist the next site copies:

- **A lib module** with `SITE`, a frozen `QUESTION_SET` (`{id, version}`),
  `QUESTIONS`, a state builder and an `interpret`.
  - The state builder is a whitelist of trusted-author fields. No
    self-stated labels, no identity, dates, counting or arithmetic; unknown
    fields stay out until a new version adds them.
  - `interpret` can only add caution: a non-`ok` outcome or a malformed
    answer is a fallback, shadow never acts, and no action removes,
    clears or downgrades.
- **A thin CLI** that:
  - always passes its site name to `Typesafe.judge` (a call with no site
    is a probe that bypasses `off`);
  - returns at once on `off` without reading its input;
  - always sets `source`;
  - routes on one site-specific positive field (here `add_needs_you`);
  - exits 0 on every fallback;
  - writes the outcome line with `decision` = the caller's own decision
    and the agreement.
- **Tests** (FakeHTTP only, sentinel key, tmp HOME and state dir) that
  cover: off by default (no read, no call, no file); shadow logs both
  classifications; on only adds; never clears or downgrades; each failure
  outcome falls back with exactly one attempt; a restricted source
  refuses with no request; no input text in any log; and a sentinel sweep
  of every output and file.

## `bead_dedupe.rb`: the bead_dedupe Jev site

A pre-filing check built to the site pattern above. Before a bead is filed,
plain code finds the open beads that share words with it, and Jev answers
one yes/no (a `noul`) per candidate pair: do the two describe the same
issue? `lib/bead_dedupe.rb` holds the question set, the tokenizer and
ranking, the state builder and the reading of the answer; `bead_dedupe.rb`
is the CLI a filer runs. It SHIPS DARK: the site is `off` unless the
machine config names `bead_dedupe` under `typesafe.sites` with another
mode, and switching it is an operator act.

**It never touches the filing.** The script does not file, refuse, close,
edit, link or block a bead; its only tracker access is one read. Every
path but a usage error or an invalid machine config exits 0 with nothing
blocked, and a caller files the bead whatever the script returned -
including a non-zero exit or no output at all.

### Usage and `data` keys

```
bead_dedupe.rb --title TEXT --source LABEL
               [--description TEXT | --description-file PATH]
               [--candidates PATH] [--max-candidates N] [--threshold N] [--dry-run]
```

`data`: `site`, `mode`, `outcome` (the last client outcome, `site_off`, or
null when no call was made), `reason`, `action`, `threshold_key`,
`threshold`, `max_candidates`, `searched` (how many beads the search read),
`candidates`, `likely_duplicates`, `calls` (requests sent), `cost_usd`
(summed over them), `dry_run`, `journal_line` (a one-line `[probe]` entry
naming candidate ids and Jev's yes probabilities, the mode, the action and
what was flagged; null when the site is off), and `request` (the first
pair's) on a dry run. Each `candidates` entry is `id`, `title_overlap`,
`body_overlap`, `jev_yes`, `action`, `reason`, `call_id`. No bead text
appears in the envelope except in a dry run's `request.body`, and the key
never appears.

The top-level `action` is `site_off`, `skipped` (reason
`description_unreadable`, `candidates_unreadable`,
`candidate_search_failed` or `no_candidates`), `dry_run`, `judged` or
`fallback` (reason: the outcome that stopped the run, or
`state_dir_error`). A candidate's `action` is `dry_run`, `shadow_logged`,
`flagged`, `no_change` (reason `no_threshold` or `below_threshold`),
`fallback` (reason: the client's outcome or `answer_malformed`) or
`not_judged` (an earlier pair's outcome stopped the run).

### Routing and exit codes

**A caller routes on `data.likely_duplicates` alone**: the ids Jev flagged.
It is non-empty only in `on` mode, for a candidate whose yes probability is
at or above `--threshold`. Exit 0 on every success, skip, off and fallback;
exit 1 only for an invalid machine config (`user_config_invalid`); exit 2
for usage: a missing or blank `--title`, a missing `--source` or one that
is not a label, both description flags, a `--max-candidates` outside 1 to
10, a threshold that is not a number in (0, 1], a stray argument or an
unknown flag.

### Candidate search is code, not Jev

- **The pool.** `--candidates PATH` (a JSON array of `{id, title,
  description}`) for a caller with its own list; otherwise one read-only
  `bd list --status open,in_progress,blocked --json --limit 0` in the
  current directory. A failed or unparseable read is a skip with a
  warning, never a block.
- **The overlap.** Both sides are tokenized the same way: lower-cased
  words of three or more characters, a fixed stopword list dropped, a
  plural `s` folded. A candidate qualifies on one shared title word, or on
  five shared words across title and description. Candidates rank by
  shared title words, then shared words overall, then id, and at most
  `--max-candidates` (default 3) go to Jev. Counting and ranking stay in
  code; Jev sees one pair at a time and answers one question.
- **Jev adds, never removes.** Every keyword candidate stays in
  `data.candidates` whatever Jev says; a low `jev_yes` never hides one.

### The question set

`bead_dedupe@1`, one question, `same_issue` (noul): `new_bead` is about to
be filed and `candidate` is an open issue already in the tracker - do they
describe the same problem or the same piece of work, so that finishing one
would also finish the other? The false criterion says that sharing an
area, a file or words is not enough, and that a part, follow-up or
prerequisite of the other is not the same issue. The test pins version 1's
text by digest, so a rewording is a deliberate version bump.

### What state is sent

`{new_bead: {title, description?}, candidate: {title, description?}}`,
each text cut to 1500 characters. Excluded on purpose: ids, status,
priority, labels, assignee, dates and every other field - identity and
self-stated labels stay out of Jev. Bead text is authored in the tracker,
so it is trusted-author text in the call-site contract's sense.

### Modes and the fallback rule

- **`shadow`**: call once per candidate, log Jev's answer (the decision
  line) and the filer's own decision (the outcome line: `decision:
  filed_unlinked`, `agreement: n/a` until the eval tooling supplies
  labels), flag nothing.
- **`on`**: flag a candidate only when `jev_yes` meets `--threshold`,
  which is the eval tooling's enabled threshold for `data.threshold_key`
  (`bead_dedupe:bead_dedupe@1:<pinned model>`), never a number the caller
  picks. Without one, nothing is flagged (`no_threshold`).
- **One failure stops the run.** The first non-`ok` outcome - a refusal,
  a timeout, any error - is a `fallback` for that pair, the remaining
  candidates are `not_judged`, and nothing is flagged by that pair. A
  malformed answer (a missing `noul`, or one outside 0 to 1) is a
  fallback for its pair. A state-dir failure is a fallback for the whole
  run and clears any flag it had made. A fallback is never read as a
  "no"; the filer files exactly as it did before this site existed.

### Source label, and the link in on mode

- **Source.** The caller passes `--source repo:<repo directory basename>`.
  Listing that label in `typesafe.restricted_sources` refuses in `shadow`
  and `on` alike, before any text leaves the machine.
- **The link is the caller's, after filing.** In `on` mode a caller that
  may write dependency links links each flagged id as related once the
  bead exists, and says so in its output:
  `bead.rb link <new-id> <flagged-id> --type related`, which runs
  `bd link <new-id> <flagged-id> --type related`. A `related` link is
  not `blocks` (bd's default type) and is removed with
  `bd dep remove <new-id> <flagged-id>`. The script itself never runs it.

## `finding_severity.rb`: the finding_severity Jev site

A call site built on the Jev client, following "The site pattern" in the
report_triage section above. After `/wurk:mr`'s pre-request review round,
it counts the round's findings by level for the worker's report and, when
the site is not off, asks Jev each finding's severity beside the reporting
agent's own rank. `lib/finding_severity.rb` holds the question set, the
rank mapping, the state builder, the reading of the answer and the count;
`finding_severity.rb` is the CLI the review-round step runs. It SHIPS
DARK: the site is `off` unless the machine config names `finding_severity`
under `typesafe.sites` with another mode, and switching it is an operator
act.

### Usage and `data` keys

```
finding_severity.rb --findings PATH --source LABEL [--threshold N] [--dry-run]
```

`--findings` is a JSON array, one object per finding the round's agents
returned: `agent` (the agent's name), `rank` (the severity it wrote,
verbatim, or null), `mustFix` (true when the agent declared the finding
must-fix) and `text` (the finding as written). A file that cannot be read,
is not JSON, or is not an array of objects is the `findings_unreadable`
warning, with nothing counted or sent and `findings_by_level` null.

`data`: `site`, `mode`, `outcome` (`site_off`; `ok` when every call
answered; the first non-`ok` client outcome; or null when no call was
made), `threshold_key`, `findings_path`, `findings` (one entry per
finding: `index`, `agent` when it is a label, `critic_level`, `jev_level`,
`jev_confidence`, `level` (the counted one), `agreement`, `action`,
`reason`, `call_id`), `findings_by_level`, `raised`, `calls` (requests
sent, or on a dry run that would be), `threshold`, `cost_usd` (summed),
`dry_run`, `outcome_lines_written`, `summary_line` (one `[probe]` line of
labels and counts for a bead note), and `request` (the first one) on a dry
run. No finding text appears in the envelope except in a dry run's
`request.body`; the key never appears.

A finding's `action` is one of `site_off`, `skipped` (reason
`nothing_to_judge`: blank text), `dry_run`, `shadow_logged`, `raised`,
`no_change` (reason `critic_must_fix`, `jev_not_higher`, `no_threshold` or
`below_threshold`) or `fallback` (reason: the client's outcome,
`answer_malformed`, `stopped`, `call_cap` or `state_dir_error`). No action
lowers a level.

### The count, and routing

**A caller routes on `data.findings_by_level` alone**: an object with
every bucket present - `mustFix`, `shouldFix`, `note`, `unranked` - each a
count. A worker copies it verbatim into its report as
`reviewRound.findingsByLevel`, an OPTIONAL, additive field: a report
written without it (an older template, a round that did not run, a script
that gave no count) is still a valid report, and `report_check.rb` only
warns (`findings_by_level_malformed`) when the field is present and not
that shape. Counting is code, in every mode, off included: the one
difference from report_triage's pattern is that off still reads the
findings file, locally, to count. Off never touches the key, the ledger,
the logs or the network.

Exit 0 on every success, skip, off and fallback. Exit 1 only for an
invalid machine config (`user_config_invalid`). Exit 2 for usage: a
missing `--findings` or `--source`, a source that is not a label, a
threshold that is not a number in (0, 1], a stray argument or an unknown
flag.

### The critic's level

Code maps each finding's own rank, never Jev: a finding whose agent
declared it must-fix (`mustFix: true`) is `must-fix` whatever its label
says; otherwise a `rank` of `must-fix`, `should-fix` or `note` (case,
spaces and underscores forgiven) is that level; anything else - another
consumer's vocabulary, or no rank - is `unranked`, which counts below
`note` and is never a blocker. The rank label is never sent to Jev: a
self-stated label makes the judgment label-reading.

### The question set

`finding_severity@1`, one `score` question over the finding's text,
three levels each described as a concrete situation: `note` (a real
observation the author may decline; nothing the change does is wrong),
`should-fix` (works, but a reviewer will ask for it before approving),
`must-fix` (should not merge with this in it). Jev's level is the most
probable of the three (a tie goes to the higher, the cautious read), and
that level's probability is the confidence a threshold is compared with.
Any change to the question's instructions or criteria is a new version;
the test pins version 1's text by digest.

### What state is sent

`{finding: <text>}` and nothing else, one call per finding with non-blank
text. Excluded on purpose: the `rank` and `mustFix` (self-stated labels),
the `agent` (identity), the finding's position and the round's counts
(counting stays in code). The first non-`ok` outcome stops the calls:
every later finding falls back (`stopped`) instead of spending or waiting
again against a failing service. At most 25 requests per invocation;
findings past that fall back (`call_cap`).

### The raise rule, and the never-downgrades rule

- **`shadow`**: call, log Jev's level (the client's decision line) beside
  the agent's own level (the outcome line's `decision`, with the
  agreement), count the agent's level only. `raised` is always 0.
- **`on`**: a finding's counted level becomes Jev's ONLY when Jev's level
  is above the agent's, a threshold was passed, and Jev's confidence is
  at or above it. Everything else keeps the agent's level.
- **Never downgrades.** Jev may add caution, never remove it. A finding
  the agent ranked must-fix stays must-fix whatever Jev says
  (`critic_must_fix`), and a Jev level at or below the agent's changes
  nothing (`jev_not_higher`). A raise changes the count and is named in
  the request body; it does not make the finding a must-fix the worker
  must address, because what counts as must-fix stays the reporting
  agent's call (`/wurk:mr`'s review-round step).
- `agreement` is `agree` or `disagree` against a ranked agent, and `n/a`
  for an unranked one or when there is no answer.

### The fallback rule

Any client outcome other than `ok`, a malformed answer (a missing or
out-of-range probability for any level), and a state-dir failure fall
back: the finding keeps the agent's level, with one `jev_fallback`
warning per distinct reason (or `state_dir_error`, naming the exception
class only; after one, every finding keeps its agent's level). A fallback
is never read as an answer. Client warnings (`key_mode_open`,
`ledger_malformed`) pass through once each.

### Source label and threshold

- **Source.** The review-round step passes `--source repo:<repo directory
  basename>`. Findings are model-authored text about a diff, and in a
  consumer they quote that consumer's code, so an operator keeps a repo's
  findings off the wire by listing that label in
  `typesafe.restricted_sources`, which refuses in `shadow` and `on` alike
  (`source_restricted`, a fallback, no request).
- **Threshold.** `--threshold` is the eval tooling's enabled threshold for
  `data.threshold_key` (`finding_severity:finding_severity@1:<pinned
  model>`), never a number the caller picks. Without one, `on` mode raises
  nothing (`no_threshold`).

## Writing a new script

First check that a script is the right home at all:
`wurk/docs/harness-placement.md` is the ordered procedure for choosing
between a script, a hook, a skill, an agent template, a shared block,
`CLAUDE.md`, one of the consumer seams, and memory. A script is the home
for deterministic mechanics behind the envelope contract; prose that a
model should weigh belongs in one of the others.

1. Require `lib/envelope`, `lib/sh`, and `lib/cli` - plus `lib/manifest` if
   the script needs any project-specific value. **Never hardcode one.** If
   the value it needs is not in the schema, add it to the schema and to
   `wurk/docs/manifest.md` in the same commit; do not fork a script.
2. Build the option parser with `Cli.build`, add script-specific flags in the
   block, parse with `Cli.parse!`.
3. Build an `Envelope.new(script: "<name>")`, call `Manifest.require!(env)`
   and return the envelope if it comes back nil, do the work, route
   conditions the script cannot resolve itself into `env.block!`,
   informational notes into `env.warn`, and exit with `env.emit`.
4. Every `Sh.run` call that mutates anything must be skippable under
   `--dry-run` - populate `commands` regardless, but only actually invoke
   `Sh.run` when `options[:dry_run]` is false. The only exception is a call
   that writes solely to `refs/remotes/` (a `git fetch`) and that the check
   phase needs current before a dry run judges anything - see `--dry-run`
   above and ADR-0006's "Amendment (2026-09-13)"; do not assume a new
   exception without that same argument, recorded the same way.
5. Add `test/<name>_test.rb` using `test/support/fake_sh.rb` to fake every
   shelled-out command; a script that shells out to something the test did
   not register a fixture for fails loudly (`FakeSh::UnexpectedCommand`),
   not silently. Drive every manifest-derived value from a fixture manifest
   (`test/support/manifest_helper.rb`), never from the real one.
6. `chmod +x` the script (top-level scripts are the ones directly invoked;
   files under `lib/` and `test/` are not and do not need the executable
   bit). `test/contract_test.rb` checks every direct child of
   `scripts/*.rb` for the shebang and the executable bit.

## Recommended consumer settings

None of this is required to use wurk, and none of it is installed for a
consumer - `settings.json` stays per-project (ADR-0004). These are the
blocks the donor repos converged on, with the reasoning that makes each one
worth copying.

### The `bd prime` SessionStart hook

Beads state is injected at session start rather than discovered by the model:

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "bd prime --hook-json" }] }
    ]
  }
}
```

Without it, a CLAUDE.md that assumes primed bead context is describing
something that never happens. A repo using dolt-synced beads wants
`bd dolt pull` here and `bd dolt push` on `Stop` instead.

### Deny rules over gate configuration

Whatever the manifest names in `gate.moving_files` should also be denied to
the file-editing tools:

```json
{
  "permissions": {
    "deny": ["Edit(.quality.exs)", "Edit(.credo.exs)", "Edit(coveralls.json)"]
  }
}
```

Three details carry the weight:

- **`deny`, not `ask`.** An ask rule prompts on every call, including inside
  seeded `--auto` worktree sessions where nobody is there to answer, and the
  session stalls. A deny fails cleanly and the agent reports it.
- **`Edit(path)` is the whole rule.** Only `Edit` rules are matched against
  file paths, and an `Edit` rule already covers every file-editing tool,
  `Write` and `NotebookEdit` included. Adding `Write()` companions matches
  nothing and makes the harness print a warning per entry at session start.
- **Documented limit: this does not cover `Bash`.** A `sed -i` or a `>`
  redirect goes straight through. Closing that would need Bash patterns,
  which are leaky and catch legitimate commands. This is not a sandbox; it
  makes a gate-config edit unmistakably deliberate in a diff. The kit's own
  contract test is the belt to this brace - it bans kit scripts from writing
  these paths at all.

### Permission-prompt noise

Do not port an accumulated `settings.local.json` allowlist when adopting
wurk. Those entries are organic accretion from one repo's history, not
workflow dependencies, and they go stale silently. Adopt first, then run
`/fewer-permission-prompts` once the new command mix has settled.

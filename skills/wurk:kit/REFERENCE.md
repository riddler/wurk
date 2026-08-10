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
`gate.report` means tier 0, `forge.kind: gitlab` blocks the gh-based and
permalink-writing scripts with `unsupported_forge` (see `lib/forge.rb`)
instead of half-working.

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

The banned list is the mechanical floor, not the whole story: judgment calls
(phase sizing, `bd close` triggers, a project's own testing protocol) stay in
skill prose and extension files even where scripting them is technically
possible.

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
ruby skills/wurk:kit/scripts/test/run.rb                # from the wurk repo
ruby skills/wurk:kit/scripts/test/run.rb -n /pattern/   # a subset by name
```

This suite is wurk's whole quality gate (ADR-0002). It needs no toolchain
beyond system Ruby, and it takes about half a second. Run it before any
commit that touches a script.

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

## `gate.rb`: the quality-gate wrapper

Runs the consumer's own gate commands - `gate.full`, `gate.loop`,
`gate.report`, `gate.report_loop`, `gate.attest` - and reports which tier of
`docs/gate-contract.md` the project reached. It knows no gate tool's flag
surface; every command is manifest data. The most constrained script here.

- `data.skipped_stages` always stays in the payload, for every skip. Whether
  a skip *blocks* follows CLAUDE.md's own distinction - "the reason says
  whether the gap is in this run or in what the project checks at all":
  - a gap **in this run** (Dialyzer skipped for a missing PLT, Tests skipped
    because compilation failed) sets `ok` false;
  - a gap in **what the project checks at all** (`:doctor not installed`,
    `disabled in .quality.exs`) is reported with `project_level: true` and a
    `stage_skipped_project_level` warning, and does not block.

  The second case is not a softening. It is true on every run including the
  green ones, so blocking on it would make `ok` false on every full gate run
  forever - which deletes the signal rather than enforcing it. Either way a
  skipped stage is never a passing one, and both kinds must appear in what
  you report. The taxonomy comes from `gate.project_level_skips` in the
  manifest: a project declaring none gets the strict reading, where an
  unrecognized skip reason blocks, and widening it is an edit to the
  consumer's own manifest, not to kit source.
- Only one profile argument is accepted: `--profile loop`. It always sets
  `data.attested` to `false`. No `--skip`, `--quick`, or other `--profile`
  value is defined by this script's parser, so passing one is a usage error
  (exit 2), not a narrower run.
- **`data.sabotage.missing` is a report, not a gate.** It never blocks and
  never flips `ok`. A present `# sabotage:` note (either a real mutation or
  a stated `n/a` exemption) is not evidence the mutation described was
  actually run against broken code - only reading the diff by hand and
  confirming the test failed for the right reason is. `/commit`'s own
  Step 0 carries that judgment call; this script only reports absence.
  The scan itself is a manifest capability, `gate.sabotage` (see
  `docs/manifest.md`): when a project declares no such section,
  `data.sabotage.enabled` is `false` with a `reason`, and `missing` is then
  always `[]` - absence of findings there is not evidence of discipline,
  only evidence the scan never ran.
- **`data.gate_guard` reports; it never writes.** There is no code path in
  `gate.rb` that writes `docs/quality-gate-changes.md` - `test/contract_test.rb`
  asserts that mechanically over every file under `scripts/`.

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
  (`which claude`), base-ref resolution (`--base`, `origin/main`, `main`,
  first to resolve wins), `git merge-base`, and a `-U0` diff against it,
  split into per-file chunks and scoped per registry entry.
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

## Writing a new script

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
   `Sh.run` when `options[:dry_run]` is false.
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

---
date: 2026-09-02T12:21:25-0600
researcher: Claude
git_commit: 075362f819f11a589e4919fd6b7f3115db74bba8
branch: wu-4x9-long-gate-runner
repository: wurk
beads_issue: wu-4x9
topic: "How wurk runs quality gates today: gate.rb, timeouts, gate call sites, and the campaign lock mechanism"
tags: [research, codebase, gate, kit, conductor, agents]
status: complete
last_updated: 2026-09-02
last_updated_by: Claude
---

# Research: How wurk runs quality gates today

**Date**: 2026-09-02T12:21:25-0600
**Git Commit**: 075362f819f11a589e4919fd6b7f3115db74bba8
**Branch**: wu-4x9-long-gate-runner
**Bead**: wu-4x9

## Research Question

wu-4x9 reports that repo-worker subagents run a repo's long quality gate,
cold runs exceed the Bash tool's 10-minute maximum timeout, the harness
auto-backgrounds the command, the subagent ends its turn expecting
re-invocation on completion, and the gate dies or completes without the
worker ever resuming - leaving uncommitted work and, in one case, a mutex
lock dir whose dead holder never released it.

This document maps the codebase as it exists today: how a gate run is
invoked and bounded, what the gate envelope reports, every call site that
runs a gate and what each says about timeouts, where the FOREGROUND /
600000ms / poll prose lives and who reads it, how the lock mechanism is
specified, and what constraints a new kit script would inherit.

It documents what is; it proposes nothing.

## Summary

The gate is run in exactly two places in Ruby and five places in prose.

**In Ruby.** `skills/wurk:kit/scripts/gate.rb` shells the manifest's gate
command out through `Sh.run` as one single call, bounded by
`manifest.gate_timeout_seconds` (default 600). Output is fully buffered by
`lib/sh.rb` - two reader threads, `stdout.read` / `stderr.read`, returned as
complete strings - never streamed and never written to a file. There is no
staging, chunking, checkpointing, resumption, or partial-progress
persistence anywhere in the gate path. A timeout is binary: `Sh.run` sets
`timed_out`, kills the child (TERM, 0.2s, KILL), and `gate.rb` reports the
fact as a tier-0 failure with a 40-line output tail. Nothing retries or
resumes. [`skills/wurk:kit/scripts/worktree_create.rb:234`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/worktree_create.rb#L234) is the second Ruby
gate invocation (a post-warm `gate.loop` verify), also on
`gate_timeout_seconds`.

Notably, `gate.timeout_seconds` defaults to **600 seconds** - the same
number as the Bash tool's cap that the bead describes, arrived at
independently (`lib/manifest.rb:108`). A gate that outruns the harness also
outruns `gate.rb`'s own kill timer.

**In prose.** Five skills/agents invoke `gate.rb` from a Bash tool
(`/wurk:commit`, `/wurk:implement`, `/wurk:mr`, `/wurk:release`,
`wurk-gate-reader`), and **none of those five call sites says anything about
timeouts, foreground vs background, or polling**. The entire FOREGROUND /
600000ms / poll-do-not-end-your-turn discipline lives in exactly two files:
[`agents/wurk-repo-worker.md:40-57`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/agents/wurk-repo-worker.md#L40-L57) (the worker's standing rule) and
[`skills/wurk:conductor/SKILL.md:136-150`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:conductor/SKILL.md#L136-L150) + `:265-269` (the failure-mode
narrative and the literal dispatch-template text a worker receives). It
reaches an ordinary interactive `/wurk:commit` session not at all.

**The lock.** The mutex the bead refers to is 100% prose. No kit script
implements locking of any kind - I confirmed no `mkdir`-mutex, `flock`, PID
file, or staleness logic exists under `skills/wurk:kit/scripts/`. The
mkdir-mutex is specified in [`skills/wurk:conductor/REFERENCE.md:29-90`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:conductor/REFERENCE.md#L29-L90)
(resource-keyed lock dirs, owner file carrying `campaign=/bead=/pid=`, 10s
polls, fixed acquisition order, `ps`-vs-mtime liveness probe, only a
conductor may clear) and restated for workers in
[`agents/wurk-repo-worker.md:48-52`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/agents/wurk-repo-worker.md#L48-L52).

The relevant settled decisions are ADR-0005 (gate contract tiers) and
ADR-0006 (Ruby stdlib scripts with envelope contract); ADR-0012 (atomic
claim inside the auto walk) is the nearest existing concurrency precedent.

## Detailed Findings

### 1. `gate.rb` - how a gate run is invoked and reported

**Command selection** ([`skills/wurk:kit/scripts/gate.rb:360-373`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/gate.rb#L360-L373)).
`run_quality` prefers the tier-1 reporting variant and falls back:

```
reporting = loop_mode ? manifest.gate_report_loop : manifest.gate_report
argv      = reporting || (loop_mode ? manifest.gate_loop : manifest.gate_full)
```

The script "knows no gate tool's flag surface" (`gate.rb:356-359`,
`gate.rb:431`); every argv comes from the manifest.

**CLI surface** (`gate.rb:426-450`). Exactly one flag: `--profile`, which
accepts only the literal `"loop"` (`gate.rb:444-448`). Anything else is an
`OptionParser::InvalidArgument`, i.e. a usage error, exit 2, before any
envelope exists. There is no `--skip`, no `--quick`, no stage selector, and
no resume flag. `loop_mode = options[:profile] == "loop"` (`gate.rb:458`) is
the only branch it drives. Entry point is `Gate.run(argv, io: $stdout)`
(`gate.rb:452-669`), process entry at `gate.rb:673`.

**Invocation and timeout** (`gate.rb:364`, `gate.rb:589`). Both the quality
run and the optional attest run are single `Sh.run` calls:

```
Sh.run(argv, chdir: manifest.gate_chdir, envelope: env,
       timeout: manifest.gate_timeout_seconds)
```

`manifest.gate_timeout_seconds` is the only timeout concept in the file.

**Output capture.** `gate.rb` sees only the finished strings on
`Sh::Result` - `JSON.parse(res.out)` at `gate.rb:368`, and
`gate_output_tail(res)` at `gate.rb:380-389`, which combines stdout and
stderr ("a gate command may write its failure to either", `gate.rb:377`)
and keeps the last `GATE_OUTPUT_TAIL_LINES = 40` (`gate.rb:378`). Nothing is
streamed to a terminal and nothing is written to a log file.

**No staging, chunking, or resumption.** "Stages" in `gate.rb` are parsed
*out of* the JSON the reporting command already produced
(`report["stages"]`, `gate.rb:564`); the script never runs stages
separately. The gate command is one `Sh.run`; the attest command is one
more. There is no checkpoint state, no partial-progress file, and no
restart-from-where-it-died path. The only partial artifact possible is
`gate_output_tail`'s 40 lines, which is a truncation of already-buffered
output.

**Timeout handling is binary.** If `Sh.run` reports `timed_out?`, `gate.rb`
records it via `gate_failure_output(res)` -> `{exit_status:, timed_out:,
output_tail:}` (`gate.rb:399-405`) and `tier0_failure_message`
(`gate.rb:413-424`), and treats it as a tier-0 failure. No retry, no
resumption, no incremental restart.

**Skip classification** (`gate.rb:291-320`, per ADR-0005 tier 1).
`skipped_from` filters `stages` to `status == "skipped"` and maps each to
`{name:, summary:, classification:}`. `classify_skip` is precedence-ordered:
`not_applicable` if the summary matches `manifest.not_applicable_skip_re`,
else `project_level` if it matches `manifest.project_level_skip_re`, else
`run_level`. `matches?` returns false for a nil regex (`gate.rb:316-320`),
so a project declaring neither list gets the strict default. In `run`
(`gate.rb:636-666`), `not_applicable` and `project_level` warn only;
`run_level` calls `env.block!(code: "stage_skipped")`.

**Tier** (`gate.rb:562`): `tier = report.nil? ? 0 : 1`. Tier 0 means no
reporting command, or its output failed `JSON.parse` (rescued at
`gate.rb:369`). Tier-0 judging uses `res.success?` alone
(`gate.rb:621-631`); tier-1 uses `report["status"] != "ok"`
(`gate.rb:632-634`).

**Envelope `data` keys.** Across the branches: `ran`, `tier`, `status`,
`scope`, `profile`, `stages`, `skipped_stages`, `gate_guard`
(`{ledger_path:, ledger_exists:, stage:}`, `gate_guard_from`,
`gate.rb:335-347`), `gate_cwd`, `gate_output` (nil unless a tier-0 failure),
`attested`, `attestation_message`, `applicable`, `carve_out_reason`, and
`sabotage` (`{enabled:, reason:, scanned:, missing:, unverifiable:}`,
`gate.rb:468-474`). A start failure blocks with
`gate_command_could_not_start` (`gate.rb:538-560`).

**Exit codes.** 2 for a usage error (before the envelope). 1 for a missing
manifest, a command that could not start, a nonzero tier-0 exit
(`env.fail!`, `gate.rb:630`), a tier-1 `status != "ok"` (`gate.rb:633`), or
any `run_level` skip (`gate.rb:660-665`). 0 otherwise;
`project_level`/`not_applicable` skips and sabotage findings never flip `ok`
(`gate.rb:60-67`).

### 2. `lib/sh.rb` - how the shell-out is actually performed

- **`Open3.popen3`**, not `capture3` or backticks (`sh.rb:118-159`). The
  comment at `sh.rb:110-117` explains the choice: `Timeout.timeout` around
  `capture3` would orphan the child, so `popen3` is used to get a real `pid`
  and race a wait thread against the timeout.
- **argv only, never a shell string** (`sh.rb:6-9`, `sh.rb:110-112`).
  `render`/`shell_quote` (`sh.rb:94-107`) exist only to build the
  human-readable `envelope.commands` audit string.
- **Fully buffered, kept separate.** Two threads do `stdout.read` /
  `stderr.read` concurrently (`sh.rb:130-131`) then join
  (`sh.rb:139-140`). `out` and `err` are complete strings on the `Result`
  (`sh.rb:20-28`). No streaming, no incremental delivery, no tee to disk.
- **Timeout**: `run(argv, chdir: nil, timeout: 60)` (`sh.rb:119`) - the
  library default is 60s; `gate.rb` overrides it with
  `manifest.gate_timeout_seconds`. Implemented as
  `wait_thr.join(timeout)`; on expiry it sets `timed_out = true`, calls
  `kill_process_group(wait_thr.pid)`, then `wait_thr.join(2)`
  (`sh.rb:133-137`).
- **`kill_process_group`** (`sh.rb:174-180`) sends TERM, sleeps 0.2s, then
  KILL, rescuing `Errno::ESRCH`. Despite the name it calls `Process.kill` on
  the pid directly - there is no `-pid` process-group form and no
  `Process.setsid` anywhere in the file.

  **Later (2026-09-10):** the helper is now named `kill_child_pid` (wu-2kh).
  The behavior described above is unchanged and deliberate; only the name was
  wrong, because it asserted something the method never did. ADR-0015 records
  the decision. Everything else on this page is as of 2026-09-02.
- **Status shapes**: a real `Process::Status`, or `TimeoutStatus`
  (`sh.rb:51-59`), or `StartFailureStatus` (`sh.rb:65-73`). `Result#success?`
  is `!timed_out && status && status.success?` (`sh.rb:30-32`);
  `#timed_out?` (`sh.rb:34-36`) and `#start_failed?` (`sh.rb:44-46`) let
  callers distinguish "never ran" from "ran and failed".
- **`SystemCallError`** from `popen3` is rescued narrowly (`sh.rb:145-158`)
  and turned into a failed `Result`, preserving the one-envelope contract.
- **Test seam**: `Sh.runner=` (`sh.rb:82-84`) swaps in
  `test/support/fake_sh.rb`.

### 3. `lib/gate_paths.rb` - the carve-out predicate

Pure predicate logic, no shelling out. `touches_build?(paths, manifest:)`
matches `manifest.gate_build_paths` (`gate_paths.rb:45-47`);
`gate_applicable?` matches the union of `gate_build_paths` and
`gate_also_gated_paths` (`gate_paths.rb:49-51`) and is what `gate.rb:97-99`
uses for the carve-out branch. `match_one?` (`gate_paths.rb:58-60`) treats a
trailing `/` as a directory prefix and everything else as an exact match; no
globbing. Consumers per its own comments (`gate_paths.rb:13-29`): `gate.rb`,
`repo_state.rb`, `/wurk:commit` Step 0, `/wurk:mr`'s gate step - shared so
the predicate cannot drift.

### 4. The manifest `gate` schema

**Documented** in [`docs/manifest.md:42-73`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/manifest.md#L42-L73):

- `cwd` (opt, [`docs/manifest.md:43-46`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/manifest.md#L43-L46), detail at `:405-467`) - scopes
  execution only, never path matching.
- `full` (required, `:47`), `loop` (required, `:48`) - argv arrays.
- `report` (opt, tier 1, `:49`), `report_loop` (named in `manifest.rb`'s
  `KNOWN` list and accessor rather than as its own jsonc line), `attest`
  (opt, tier 2, `:51`), `guard_ledger` (opt, tier 2, `:52`).
- `build_paths` (`:53`), `also_gated_paths` (`:54`), `moving_files`
  (`:55-56`) - the path lists; "Two path lists, not one" at `:492-506`.
- `project_level_skips` / `not_applicable_skips` (opt, tier 1, `:57-63`,
  detail `:213-253`) - regex lists; `not_applicable` is checked first when
  both match (`:240-246`).
- `sabotage` (opt, `:64-68`, detail `:255-325`) - report-only, never flips
  `ok`.
- `timeout_seconds` (opt, `:69-72`) - "default 600; seconds Sh.run allows".

**Implemented** in `skills/wurk:kit/scripts/lib/manifest.rb`:

- `KNOWN["gate"]` (`manifest.rb:82-83`) enumerates exactly `cwd full loop
  report report_loop attest guard_ledger build_paths also_gated_paths
  moving_files project_level_skips not_applicable_skips sabotage
  timeout_seconds`; `KNOWN["gate.sabotage"]` at `:84`. Anything else warns
  via `collect_unknown_keys` (`:924-936`).
- `REQUIRED` includes `gate.full` and `gate.loop` (`manifest.rb:47-48`),
  enforced by `validate_required` (`:902-909`).
- `DEFAULTS["gate.timeout_seconds"] = 600` (`manifest.rb:108`) and
  `DEFAULTS["parallelism.timeout_seconds"] = 600` (`:109`). No other
  `gate.*` field has a default.
- Accessors at `manifest.rb:266-366`: `gate_full`, `gate_loop`,
  `gate_report`, `gate_report_loop`, `gate_attest`, `gate_guard_ledger`,
  `gate_timeout_seconds` (`:300-302`), `gate_cwd` / `gate_chdir(root:)`
  (`:308-318`), `gate_build_paths`, `gate_also_gated_paths`,
  `gate_moving_files`, `project_level_skip_re`, `not_applicable_skip_re`
  (compiled via the shared private `skip_re`, `:543-551`), and the
  `sabotage_*` family.
- Validation from `validate!` (`manifest.rb:573-589`): `validate_commands`
  (`:871-887`, argv arrays of strings only, a shell string blocks),
  `validate_regex_lists` (`:853-869`), `validate_sabotage` (`:610-641`),
  `validate_gate_timeout_seconds` (`:646-651`, positive Integer only),
  `validate_gate_cwd` (`:668-686`, relative, no `.` or `..`).
- `parallelism.timeout_seconds` is a deliberately separate knob
  (`manifest.rb:405-413`) covering `parallelism.trust` and each
  `parallelism.warm` command; the comment records that the post-warm gate
  verify uses `gate.timeout_seconds` instead.

**Tiers** (ADR-0005, [`docs/adr/0005-gate-contract-tiers.md:18-33`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/adr/0005-gate-contract-tiers.md#L18-L33);
`docs/gate-contract.md`):

- Tier 0 (`gate-contract.md:8-26`) - only `gate.full` / `gate.loop` need
  exist and exit nonzero on failure. `ok` comes from the exit code alone,
  `report: unavailable`, `attested: false`.
- Tier 1 (`:28-60`) - `gate.report` / `gate.report_loop` emit the JSON
  report schema at `:34-46`; buys stage names and the skip taxonomy.
- Tier 2 (`:62-79`) - two independent capabilities, `gate.attest`
  (per-tool) and the gate guard (`gate.moving_files` +
  `gate.guard_ledger`, language-agnostic, lives in the kit).
- Degradation table at `:81-90`; governing rule "Weaker is acceptable;
  vaguer is not" (also `0005-gate-contract-tiers.md:32-33`).

**Duration.** `docs/gate-contract.md` and ADR-0005 contain no mention of
duration, timeout, or cost. `gate.timeout_seconds` is the only such field in
the whole gate surface.

### 5. Every gate call site, and what it says about timeouts

**Bash-tool invocations of `gate.rb`** (five):

| Call site | Line | Timeout/background prose |
| --- | --- | --- |
| `/wurk:commit` Step 0 | [`skills/wurk:commit/SKILL.md:80`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:commit/SKILL.md#L80) | none |
| `/wurk:implement` verification | [`skills/wurk:implement/SKILL.md:232`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:implement/SKILL.md#L232) | none |
| `/wurk:mr` Step 4 | [`skills/wurk:mr/SKILL.md:183`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:mr/SKILL.md#L183) | none |
| `/wurk:release` Step 2 | [`skills/wurk:release/SKILL.md:159`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:release/SKILL.md#L159) | none |
| `wurk-gate-reader` permitted command | [`agents/wurk-gate-reader.md:32`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/agents/wurk-gate-reader.md#L32) | none |

All five carry only correctness/reporting instructions: fix everything
before proceeding and wait for `data.attested: true`
(`wurk:commit/SKILL.md:83-91`); hand a large red gate to `wurk-gate-reader`
(`implement:235`, `mr:185-188`, `release`); never truncate `data.stages`
(`mr:185`); the script accepts no narrowing flags (`mr:204-206`); no
carve-out applies to a release (`release`). None mentions how long a gate
takes.

**Skills in the bead's list with no direct `gate.rb` call**:

- `/wurk:verify` - no `gate.rb` line at all; only prose at
  [`skills/wurk:verify/SKILL.md:45`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:verify/SKILL.md#L45) that unattended fixes get a "gate re-run
  afterward", with no command and no timeout language.
- `/wurk:refresh` - runs `ruby ~/.claude/skills/wurk:kit/scripts/worktree_refresh.rb`
  ([`skills/wurk:refresh/SKILL.md:54`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:refresh/SKILL.md#L54)), whose prose at `:57-62` says the
  script internally confirms green with `gate.loop`. The gate shell-out
  happens inside the script, so there is no agent-visible Bash timeout to
  set.
- `/wurk:conductor` - never runs a gate itself; it dispatches workers who
  do.
- `wurk-repo-worker` - contains no `gate.rb` line; it delegates to
  `/wurk:work`, `/wurk:implement`, `/wurk:commit`, `/wurk:mr`. It carries the
  most detailed gate-execution prose in the repo (below).
- [`skills/wurk:kit/REFERENCE.md:315-387`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/REFERENCE.md#L315-L387) documents `gate.rb`'s behavior and
  flags but contains no invocation line and no timeout instruction.

**Ruby-level gate shell-outs** (two scripts, three call sites):

- `gate.rb:364` and `gate.rb:589` - `timeout: manifest.gate_timeout_seconds`.
- `worktree_create.rb:234` - the post-warm `gate.loop` verify, also on
  `manifest.gate_timeout_seconds`; the trust and warm commands beside it
  (`worktree_create.rb:222,229`) use `manifest.parallelism_timeout_seconds`.
  A start failure here blocks with the same
  `gate_command_could_not_start` code `gate.rb` uses
  (`worktree_create.rb:237-247`). `skills/wurk:branch/SKILL.md:101,107`
  describes this narratively; no Bash call appears in the skill.

### 6. Where the FOREGROUND / 600000ms / poll prose lives

Three `600000` hits repo-wide, all agent-facing prose, none in code.

**[`agents/wurk-repo-worker.md:40-53`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/agents/wurk-repo-worker.md#L40-L53)**, under "Gate discipline (learned the
expensive way, campaign 004)":

> **Run gates FOREGROUND and watch them.** Pass an explicit long timeout
> (600000ms) on the Bash call. If the harness auto-backgrounds the run
> anyway, do NOT end your turn - poll the task's output file with Read
> until it exits. A worker that ends its turn "waiting" on a background
> gate has, three times out of three, come back to a silently dead gate,
> uncommitted work, and (once) a starved mutex.

Followed immediately by the gate-semaphore rule (`:48-52`) and, at
`:56-57`, "Never wait on detached work. Never sleep, poll, or end your turn
'waiting' on a loop, timer, or background notification (the gate-lock
bounded wait is the one exception, and only when the dispatch names it)."

**[`skills/wurk:conductor/SKILL.md:136-150`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:conductor/SKILL.md#L136-L150)**, "Worker stalls, resumes,
takeovers": "A stopped worker proves nothing about its background children.
Before ANY resume: probe the worktree (fresh commits, mtimes) and the
machine (live gate processes). Expect this failure mode: workers end their
turn on an auto-backgrounded gate that dies silently (three occurrences in
one campaign) - dispatches must say 'gate FOREGROUND, explicit 600000ms
timeout; if auto-backgrounded anyway, poll the output file, do not end your
turn'." The three-rung escalation ladder follows at `:147-156` (resume from
disk; "your wait target is dead, run it foreground"; retire and dispatch a
fresh worker with a takeover brief).

**[`skills/wurk:conductor/SKILL.md:265-269`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:conductor/SKILL.md#L265-L269)**, the literal dispatch template
a worker receives:

> GATE: Run gates FOREGROUND with an explicit 600000ms timeout; if
> auto-backgrounded anyway, poll the task output file with Read - do not
> end your turn on a running gate. `<Gate-semaphore slot: lock dir,
> bounded-wait shape, always-release, staleness = report not break.>`
> `<Known-flake slot.>` Never truncate a failing gate.

Slots are filled per dispatch (`SKILL.md:280-283`).

Who reads what: [`agents/wurk-repo-worker.md:40-57`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/agents/wurk-repo-worker.md#L40-L57) is the worker's own
standing rule for any gate it triggers; `SKILL.md:136-150` is guidance to
the conductor about handling a stalled worker; `SKILL.md:265-269` is the
prompt text a dispatched worker actually receives, duplicating the standing
rule. Nothing in this discipline reaches a plain interactive `/wurk:commit`
or `/wurk:mr` session.

No `10-minute` or `10 min` string anywhere in the repo describes gate
runtime; the single `10-minute` hit ([`docs/plan.md:1237`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/plan.md#L1237)) is
`wurk-conflict-scout`'s estimate of a manual merge.

### 7. The mutex / lock mechanism

**No kit script implements locking.** Grepping every `.rb` under
`skills/wurk:kit/scripts/` (excluding `test/`) for `mkdir`/`lock`/`mutex`/
`flock`/`pid`/`stale`/`holder`: the only `mkdir` hits are
`worktree_create.rb`'s `mkdir -p` for worktree directories, and the only
"lock" hits are `worktree_refresh.rb` / `rebase_onto.rb` referring to
dependency **lockfiles** ("lock repaired" / "lock unchanged" after a
rebase), a different concept. `gate.rb` has no lock code at all.

**The spec is prose**, in [`skills/wurk:conductor/REFERENCE.md:29-90`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:conductor/REFERENCE.md#L29-L90):

- Locks live under a project-level `multiCampaign.locksDir`, conventionally
  `locks/`. Shapes: `locks/registry/` (`REFERENCE.md:33-34`),
  `locks/gate-<repo-dir>/` (one full gate or worktree warm at a time per
  repo, `:68-69`), `locks/tracker-<repo-dir>/` (`:70-71`), and
  `locks/machine-gate-slots/slot-N/` (a machine-wide cap on concurrent full
  gates across all campaigns, `:72-78`; the note records that "warms at 4x
  on one machine produced DB-sandbox failures").
- Locks are keyed by **resource**, not campaign (`:63-66`, restated
  `SKILL.md:50-52`), so two campaigns contending for the same repo wait on
  the same lock.
- **Acquisition** is an instruction to an agent, not a script: registry
  edits are "read-modify-write under the registry lock (`locks/registry/`,
  mkdir-mutex, held only for the edit)" (`:33-34`); workers "mkdir to
  acquire before any full-suite run; bounded wait (the dispatch names the
  loop shape) if held; ALWAYS rmdir after your run, pass or fail"
  ([`agents/wurk-repo-worker.md:48-51`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/agents/wurk-repo-worker.md#L48-L51)). The conductor names a lock dir in
  every dispatch (`SKILL.md:120-124`, template slot at `:266-268`).
- **Acquisition order is fixed** to avoid deadlock: repo gate lock first,
  then a free machine slot, released in reverse; a campaign that caps its
  own concurrency below the machine cap takes its campaign mutex before the
  slot (`REFERENCE.md:74-78`).
- **Metadata**: "the owner file carries `campaign=<id> bead=<id> pid=<pid>`"
  (`REFERENCE.md:81-82`; restated `SKILL.md:53`). No filename or format is
  specified anywhere - it is a prose contract, not a schema.
- **Staleness detection** is manual: 10s polls, "30s starves"
  (`REFERENCE.md:82`); "re-read the owner before any staleness conclusion"
  (`:82-83`); "lock mtime vs `ps` for a live gate process", machine-wide
  (`:85-87`, `SKILL.md:126-127`). A worker whose bounded wait expires twice
  probes `ps` and **reports** staleness - "never break another holder's lock
  yourself" ([`agents/wurk-repo-worker.md:51-52`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/agents/wurk-repo-worker.md#L51-L52)). Only a conductor clears a
  verified-stale lock, journaling it in both campaigns' journals
  (`REFERENCE.md:36,83-87`; `SKILL.md:55-57,61-63`).
- **Release**: worker `rmdir`s after the run, pass or fail
  (`wurk-repo-worker.md:49-50`); the registry lock is held only for the
  edit (`REFERENCE.md:34`). **If the holder dies there is no reaper** - the
  dir sits until a contending worker reports it or a conductor manually
  clears it after an owner re-read and `ps` probe. Locks are explicitly held
  across `/wurk:commit`'s internal gate re-run (`REFERENCE.md:89-90`).

A separate, unrelated serialization axis is "the claim is the lock"
([`skills/wurk:work/SKILL.md:137`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:work/SKILL.md#L137), [`docs/two-tracker-pattern.md:147`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/two-tracker-pattern.md#L147)) - a
tracker-record claim on a bead, not a filesystem lock dir.

### 8. Contract rules a new kit script inherits

From ADR-0006 (`docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`,
accepted 2026-08-08), [`docs/architecture.md:42-58`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/architecture.md#L42-L58), and the root
`CLAUDE.md`:

- System Ruby, stdlib only, no gems or Bundler
  ([`docs/architecture.md:44`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/architecture.md#L44)).
- One JSON envelope on stdout: `ok`, `script`, `data`, `warnings[]`,
  `blocked[]` (with `needs: "human"`), `commands[]`
  ([`docs/architecture.md:47-49`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/architecture.md#L47-L49)). Exit 0 ran and judged, 1 blocked or a
  wrapped command failed (envelope still printed), 2 usage error (plain
  text on stderr, no envelope).
- `--dry-run` on every mutating script ([`docs/architecture.md:50`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/architecture.md#L50)).
- All shelling out through `lib/sh.rb` - argv arrays, no shell
  interpolation, never `system` or backticks
  ([`docs/architecture.md:51-52`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/architecture.md#L51-L52)); every argv-literal `cp`/`rm`/`mv` carries
  a non-interactive flag.
- The banned-operation list is absolute: never `git push`, `gh pr create`,
  `glab mr create`, `bd close`, `bd edit`, and never write a file the
  manifest declares as `gate.moving_files` or `gate.guard_ledger`
  ([`docs/architecture.md:53-56`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/architecture.md#L53-L56); root `CLAUDE.md`).
- No consumer-project constants in generic skills or kit scripts; anything
  project-specific comes from the manifest or an extension file (root
  `CLAUDE.md`; [`docs/architecture.md:34-36`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/architecture.md#L34-L36)).
- Extensions add, they never override; a need for different generic
  behavior means the manifest schema is missing a field
  ([`docs/architecture.md:126-128`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/architecture.md#L126-L128)).
- `docs/manifest.md` and `lib/manifest.rb` stay in sync in the same commit,
  code is authority (root `CLAUDE.md`).

### 9. The kit test suite, and what a new script owes it

**`test/run.rb`** (`run.rb:1-19`): `require "minitest/autorun"` (line 16),
then `Dir.glob("**/*_test.rb").sort.each { |f| require f }` (lines 18-19).
Printing and exit code come entirely from minitest's `at_exit` hook. Helper
files under `support/` and fixtures are excluded by the glob.

**`test/contract_test.rb`** - the static scan, applied over `non_test_files`
(every `.rb` under `scripts/` outside `test/`, globbed at
`contract_test.rb:499-508`, no per-file opt-out):

- `BANNED_CALLS` (`contract_test.rb:30-39`) - `git push`, `gh pr create`,
  `glab mr create`, `bd close`, `bd edit`. Applied by `banned_calls`
  (`:86-95`), which strips trailing comments (`code_only`, `:68-70`) and
  normalizes quotes/brackets/commas to spaces (`:97-99`) so an argv literal
  is caught the same as a string. Enforced at `:510-518`.
- Guarded-file writes (`write_matcher` `:51-53`, `WRITE_CALL` `:58`,
  `guarded_writes` `:103-113`, enforced `:520-529`); targets come from
  `ManifestHelper.all_fixture_guarded_paths`
  (`support/manifest_helper.rb:73-85`), the union of every fixture's
  `gate.moving_files` + `gate.guard_ledger`.
- No `system`/backticks (`system_or_backticks` `:116-122`, enforced
  `:531-537`) - everything through `lib/sh.rb`.
- Non-interactive `cp`/`rm`/`mv` (`:126-136`, enforced `:554-562`).
- Shebang + executable bit for `scripts/*.rb` (`:544-552`) - the one place a
  new **top-level** script is checked by shape rather than glob.
- `CONSUMER_VOCABULARY` (`:153-159`) over code (`:564-574`), over every
  `skills/wurk:*/SKILL.md` (`:598-610`), and over `REFERENCE.md`'s shell
  fences (`:612-619`).
- `HARDCODED_REFS` (`:260-264`, enforced `:621-631`) - no `main...HEAD`,
  `origin/main`, `refs/heads/main` etc.; use `Manifest#default_branch`.
- `FORGE_VOCABULARY` (`:287-290`, enforced `:633-645`).
- Skill cross-references resolve (`SKILL_REF_RE` `:308`, enforced
  `:652-668`).
- A drift check that re-parses ADR-0006's own banned-operation paragraph and
  asserts every operation named there is covered (`:767-785`, with
  `NON_OPERATIONS` at `:763-765`).
- Meta-tests plant violations to prove the scanners are not vacuously green
  (`:588-596`, `:673-695`, `:700-725`, `:731-750`).

`--dry-run` and exit-code discipline are **not** statically scanned; they are
asserted behaviorally per script - e.g. `worktree_create_test.rb:188-268`
asserts `--dry-run` populates `data.dry_run`, records intended commands in
order, and never reaches `FakeSh`; `gate_test.rb:769-791` asserts a usage
error raises `SystemExit` with plain-text stderr and no envelope.

**Helpers.** `support/manifest_helper.rb` supplies `fixture_manifest`
(`:27-34`), `with_manifest` (`:39-46`), `in_tmp_repo` (`:53-62`, copies a
fixture to `<tmp>/.claude/wurk.json` and chdirs so `Manifest.locate`'s
walk-up finds it), `all_fixture_guarded_paths` (`:73-85`), and
`manifest_with` (`:90-93`). Its comment at `:8-13` records the convention:
tests never read the real `.claude/wurk.json`, and the `valid` fixture uses
bead prefix `"zz"` and `make` gate commands so nothing passes for the wrong
reason. `support/fake_sh.rb` is the `Sh.runner` double: `#expect` registers
an argv-prefix expectation (`:48-52`), `#run` matches FIFO or raises
`FakeSh::UnexpectedCommand` (`:55-74`), `#verify!` asserts all consumed
(`:77-81`), and `start_failed: true` simulates the rescued
`SystemCallError` path (`:45-46,64-66`).

**Worked example, `gate_test.rb`.** `setup`/`teardown` install and clear
`FakeSh`, reset `Manifest`, restore `Dir.pwd` (`:16-26`). `run_gate(argv)`
calls `Gate.run(argv, io: StringIO)` and parses the JSON (`:28-32`).
`in_tmp_cwd` (`:44-58`) optionally creates a fake ledger and chdirs into a
subdirectory to exercise `Manifest.locate`. A family of `expect_*` helpers
(`:60-104`) stubs the exact git shell-out sequence. `GREEN_REPORT`
(`:106-113`) is the canned all-green report; the fixture manifest's gate
commands are literally `make report` / `make report-loop` / `make attest`,
so no consumer's build tool is ever named. Because `FakeSh` raises on any
unstubbed call, a test that omits an expectation is itself proof the script
never ran that command (`:129-131`).

**What a new script owes**: a same-named `test/<name>_test.rb` structured
like `gate_test.rb`; fixture-driven manifest behavior via `ManifestHelper`;
a `--dry-run` assertion if it mutates anything; and independent compliance
with every static rule above. No registry needs updating - `run.rb` and
`contract_test.rb` both glob - except that a new **top-level** `scripts/*.rb`
must carry the shebang and executable bit (`contract_test.rb:544-552`).

## Code References

- [`skills/wurk:kit/scripts/gate.rb:360-373`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/gate.rb#L360-L373) - manifest gate-command selection
- [`skills/wurk:kit/scripts/gate.rb:364`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/gate.rb#L364) - the single `Sh.run` gate call with `gate_timeout_seconds`
- [`skills/wurk:kit/scripts/gate.rb:377-389`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/gate.rb#L377-L389) - `gate_output_tail`, last 40 lines of combined out/err
- [`skills/wurk:kit/scripts/gate.rb:399-424`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/gate.rb#L399-L424) - timeout reported as a tier-0 failure, no retry
- [`skills/wurk:kit/scripts/gate.rb:426-450`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/gate.rb#L426-L450) - the whole CLI surface: `--profile loop` only
- [`skills/wurk:kit/scripts/gate.rb:291-320`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/gate.rb#L291-L320) - skip classification
- [`skills/wurk:kit/scripts/gate.rb:562`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/gate.rb#L562) - tier derivation
- [`skills/wurk:kit/scripts/lib/sh.rb:110-159`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/lib/sh.rb#L110-L159) - `Open3.popen3`, buffered reads, timeout race
- [`skills/wurk:kit/scripts/lib/sh.rb:174-180`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/lib/sh.rb#L174-L180) - `kill_process_group`: TERM, 0.2s, KILL, on the pid
- [`skills/wurk:kit/scripts/lib/sh.rb:20-73`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/lib/sh.rb#L20-L73) - `Result`, `TimeoutStatus`, `StartFailureStatus`
- [`skills/wurk:kit/scripts/lib/gate_paths.rb:45-66`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/lib/gate_paths.rb#L45-L66) - carve-out predicates
- [`skills/wurk:kit/scripts/lib/manifest.rb:82-84`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/lib/manifest.rb#L82-L84) - `KNOWN["gate"]`
- [`skills/wurk:kit/scripts/lib/manifest.rb:108-109`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/lib/manifest.rb#L108-L109) - both 600s defaults
- [`skills/wurk:kit/scripts/lib/manifest.rb:646-651`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/lib/manifest.rb#L646-L651) - `validate_gate_timeout_seconds`
- [`skills/wurk:kit/scripts/worktree_create.rb:222-247`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/worktree_create.rb#L222-L247) - warm, trust, and the post-warm gate verify
- [`skills/wurk:commit/SKILL.md:80`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:commit/SKILL.md#L80) - gate call site, no timeout prose
- [`skills/wurk:implement/SKILL.md:232`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:implement/SKILL.md#L232) - gate call site, no timeout prose
- [`skills/wurk:mr/SKILL.md:183`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:mr/SKILL.md#L183) - gate call site, no timeout prose
- [`skills/wurk:release/SKILL.md:159`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:release/SKILL.md#L159) - gate call site, no timeout prose
- [`agents/wurk-gate-reader.md:32`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/agents/wurk-gate-reader.md#L32) - the one permitted gate invocation for the reader agent
- [`skills/wurk:refresh/SKILL.md:54-62`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:refresh/SKILL.md#L54-L62) - gate runs inside `worktree_refresh.rb`, not via Bash
- [`agents/wurk-repo-worker.md:40-57`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/agents/wurk-repo-worker.md#L40-L57) - FOREGROUND/600000ms/poll + gate semaphore + no-detached-work
- [`skills/wurk:conductor/SKILL.md:136-156`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:conductor/SKILL.md#L136-L156) - stall/resume/takeover ladder and the failure narrative
- [`skills/wurk:conductor/SKILL.md:265-269`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:conductor/SKILL.md#L265-L269) - the dispatch template's GATE block
- [`skills/wurk:conductor/SKILL.md:120-127`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:conductor/SKILL.md#L120-L127) - conductor-side lock naming and liveness probe
- [`skills/wurk:conductor/REFERENCE.md:29-90`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:conductor/REFERENCE.md#L29-L90) - the full lock spec
- [`skills/wurk:kit/scripts/test/run.rb:16-19`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/test/run.rb#L16-L19) - suite discovery
- [`skills/wurk:kit/scripts/test/contract_test.rb:30-39`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/test/contract_test.rb#L30-L39) - `BANNED_CALLS`
- [`skills/wurk:kit/scripts/test/contract_test.rb:767-785`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/test/contract_test.rb#L767-L785) - the ADR-0006 drift check
- [`skills/wurk:kit/scripts/test/support/fake_sh.rb:48-81`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/test/support/fake_sh.rb#L48-L81) - the `Sh` double
- [`skills/wurk:kit/scripts/test/support/manifest_helper.rb:53-93`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:kit/scripts/test/support/manifest_helper.rb#L53-L93) - tmp-repo and fixture helpers
- [`docs/manifest.md:42-73`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/manifest.md#L42-L73) - the documented `gate` schema
- [`docs/gate-contract.md:8-90`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/gate-contract.md#L8-L90) - the tier definitions and degradation table

## Architecture Documentation

- **ADR-0005** (accepted 2026-08-08), gate contract tiers. Three tiers, all
  declared purely by which optional `gate.*` fields a manifest carries.
  Skills must degrade honestly and state which tier produced a green -
  "weaker is acceptable; vaguer is not"
  ([`docs/adr/0005-gate-contract-tiers.md:32-33`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/adr/0005-gate-contract-tiers.md#L32-L33)).
- **ADR-0006** (accepted 2026-08-08), Ruby stdlib scripts with the envelope
  contract. Stdlib-only system Ruby, one JSON envelope, exit 0/1/2,
  `--dry-run` on mutating scripts, all shell-outs through `lib/sh.rb`, and
  an absolute banned-operation list enforced by a contract test that
  re-parses the ADR's own prose so text and enforcement cannot drift.
- **ADR-0012** (accepted 2026-08-16), atomic claim inside the greedy walk.
  The repo's nearest existing concurrency precedent: `select_batch.rb`
  claims each bead atomically at take-time under `--auto`, and a contended
  claim is a skip rather than a failure. It explicitly rejects
  claim-everything-then-release-losers.
- **ADR-0011** (accepted 2026-08-12), host-project orientation as an
  extension file - establishes the pattern of forwarding an extension file
  verbatim into an agent's prompt.
- **ADR-0013** (accepted 2026-08-22), a third seam for machine-level config
  - the project-vs-machine placement rule any new config would follow.
- **ADR-0014** (accepted, amended 2026-08-27), an outbound-scan gate on both
  push paths - precedent for a gate-shaped mechanism that only ever refuses.
- No ADR formalizes the conductor's lock protocol or the gate-execution
  discipline; both are operational prose in `skills/wurk:conductor/` and
  `agents/wurk-repo-worker.md`, described in [`docs/architecture.md:15-16`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/architecture.md#L15-L16) as
  "the campaign pair wurk-repo-worker and wurk-fleet-scout".

## Historical Context

- [`docs/plans/260817-wu-9fb-subdirectory-gate-cwd.md:207-213`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/plans/260817-wu-9fb-subdirectory-gate-cwd.md#L207-L213), `:825-828`,
  `:846-847` - while implementing `gate.cwd`, the author noticed that
  `worktree_create.rb` / `worktree_refresh.rb` ran `gate.loop` on `Sh.run`'s
  default 60-second timeout instead of `manifest.gate_timeout_seconds`, "a
  real gap left by the `gate.timeout_seconds` commit (082f019)", and filed
  it as its own bead rather than folding it in. The current
  `worktree_create.rb:234` does pass `gate_timeout_seconds`.
- [`docs/research/260817-wu-9fb-subdirectory-gate-cwd.md:143`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/docs/research/260817-wu-9fb-subdirectory-gate-cwd.md#L143) cites
  `gate.timeout_seconds` (commit 082f019) as the precedent for how a field
  enters the manifest schema.
- The campaign-004 incidents the bead reports are recorded in prose in
  [`agents/wurk-repo-worker.md:40`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/agents/wurk-repo-worker.md#L40) ("learned the expensive way, campaign
  004") and [`skills/wurk:conductor/SKILL.md:141-144`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:conductor/SKILL.md#L141-L144) ("three occurrences in
  one campaign").
- No document in `docs/research/` or `docs/plans/` addresses "long gate
  runner", background-task re-invocation, or the lock mechanism as a named
  topic. The wu-9fb plan's filed-but-fixed timeout gap and the
  conductor/repo-worker prose are the closest prior art.

## Related Research

- `docs/research/260817-wu-9fb-subdirectory-gate-cwd.md` - the `gate.cwd`
  research, which surveys `gate.rb`'s call sites and cites
  `gate.timeout_seconds` as schema precedent.
- `docs/plans/260817-wu-9fb-subdirectory-gate-cwd.md` - the plan carrying
  the timeout-gap observation.
- `docs/research/260819-wu-7l5-dmv-and-open-question-backlog-skill.md` - the
  `/wurk:verify` backlog research; `/wurk:verify --unattended` is what the
  repo-worker runs after implementation.

Sibling beads under the epic wu-ddi, which this bead is a child of, cover
adjacent surfaces: wu-ec5 (conductor dispatch template's foreground rule),
wu-a7i (repo-worker: forbid background waits, prescribe the poll call),
wu-4nc (campaign mutex before machine slot), wu-i0z (carry the
gate-semaphore block into every brief), wu-7rn (worktree_create's internal
warm and the semaphore).

## Open Questions

Recorded during research; no human was available to resolve them.

1. **The Bash tool's actual maximum timeout is not stated anywhere in this
   repo.** The bead says 10 minutes; the prose says "explicit 600000ms".
   Whether 600000ms is the cap or merely a large value below it is not
   documented here, and I did not find a harness document in the repo that
   states it.


   **Settled (2026-09-02):** the cap is 600000ms, and the default a caller gets
   without asking is 120000ms. So "explicit 600000ms" in the conductor prose is
   the ceiling, not an arbitrary large value - and the gap that actually bites
   is the default, five times under the cap. See the same question in the plan
   document for what this means for `poll`'s `--wait-seconds` default (it stays
   at 60, deliberately under the 120s default rather than merely under the
   cap). This is a fact about the harness, not this repo, so it can drift.

2. **`gate.timeout_seconds` defaults to 600 and `gate.rb` enforces it.** A
   gate that outruns the harness also outruns `gate.rb`'s own kill timer, so
   today the two limits coincide by default. Whether that coincidence is
   deliberate is not recorded in `docs/manifest.md`, the ADRs, or the commit
   comments I read.


   **Settled (2026-09-02):** it is a coincidence, as far as any record goes. Commit
   082f019 ("Makes the gate timeout configurable") says `gate.rb` had
   "hard-coded a 600 second timeout at both Sh.run call sites" and made it a
   manifest field for one stated reason: a consumer whose gate runs inside
   docker-compose can exceed it cold. Nothing in that change, in
   `docs/manifest.md`, or in the ADRs refers to any harness limit. The 600 is
   about cold docker builds; matching the Bash cap is accidental.

   The question is also moot going forward: wu-4x9 gives the detached path its
   own `gate.long_timeout_seconds`, precisely so the foreground leash and the
   detached one stop being the same number by accident.

3. **`Sh.kill_process_group` kills only the direct pid**
   (`lib/sh.rb:174-180`), not a process group - there is no
   `Process.setsid` or `-pid` form in the file. What happens to a killed
   gate command's own children is not documented.


   **Settled (2026-09-02):** documented now, and confirmed by running it. `Sh.run`
   kills the direct pid only, so a gate's children survive its timeout. The new
   `Sh.run_streaming` path runs the child in its own process group and kills
   the negative pgid: a grandchild spawned by the gate was dead within 0.5s of
   that timeout firing, where the `Sh.run` path leaves it running. `Sh.run` is
   deliberately unchanged on this branch; the fix, and the misleading
   `kill_process_group` name, are filed as **wu-2kh**.

4. **The lock owner file has no specified filename or format.**
   `REFERENCE.md:81-82` says it "carries `campaign=<id> bead=<id>
   pid=<pid>`" but names no path inside the lock dir and no encoding, so two
   agents could write it differently and neither would be wrong per the
   prose.


   **Settled (2026-09-02):** fixed by this bead. The shipped format is a file named
   `owner` in the lock dir, one `key=value` per line, keys in the fixed order
   `campaign`, `bead`, `pid`, `host`, `purpose`, `acquired_at`. Two agents can
   no longer write it differently. Updating the conductor prose to match is
   sibling work (wu-4nc / wu-i0z).

5. **Which repos actually have gates that exceed 10 minutes cold** is not
   recorded in this repo. wurk's own gate is a fast minitest suite; the
   incidents came from a consumer campaign, and no consumer manifest is
   checked in here.


   **Settled (2026-09-02):** not answerable from this repo, and recorded as such
   rather than left looking unexamined. The one figure this repo does hold is
   in sibling bead wu-ec5: the host repo's full gate budget is 1800s, which is
   what made the conductor's "explicit 600000ms" mandate structurally
   impossible and prompted this epic. Enumerating the rest would need consumer
   manifests that are deliberately not checked in here - which is exactly why
   `gate.long_timeout_seconds` is a manifest field rather than a kit constant.

6. **`/wurk:verify` and `/wurk:refresh` gate runs.** `/wurk:verify` re-runs a
   gate after an unattended fix but names no command
   ([`skills/wurk:verify/SKILL.md:45`](https://github.com/riddler/wurk/blob/075362f819f11a589e4919fd6b7f3115db74bba8/skills/wurk:verify/SKILL.md#L45)), and `/wurk:refresh` runs its gate
   inside `worktree_refresh.rb`. Neither is reachable by a caller-set Bash
   timeout, so how a long gate behaves on those paths is undocumented.

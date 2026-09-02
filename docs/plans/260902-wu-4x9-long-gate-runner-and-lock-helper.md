# Long-gate runner and lock helper Implementation Plan

## Overview

Ship the two kit mechanisms epic wu-ddi names, so the prose siblings can stop
restating discipline and point at scripts instead. Beads issue: `wu-4x9`.

1. A **lock helper** (`lib/lock.rb` + `lock.rb`): mkdir-mutex, an owner file
   carrying campaign/bead/pid, bounded wait, a machine-detectable staleness
   probe (pid liveness vs mtime), and enforcement of the fixed acquisition
   order the conductor spec names (campaign mutex -> repo gate lock ->
   machine slot).
2. A **sanctioned long-gate runner** (`gate_run.rb`): starts the manifest's
   gate detached, tees a log, writes an atomic exit sentinel, and exposes a
   foreground `poll` an agent repeats until the sentinel appears - so a gate
   that outruns the Bash tool's timeout is survivable by re-polling instead
   of by the agent ending its turn.

This bead ships the mechanism only. The skill/agent prose that will point at
it belongs to the sibling beads (wu-ec5, wu-a7i, wu-4nc, wu-i0z, wu-7rn).

## Current State Analysis

From `docs/research/260902-wu-4x9-subagent-long-gate-runs-and-locks.md`
(read in full before planning):

- **No kit script implements locking of any kind.** The mkdir-mutex,
  resource-keyed lock dirs, owner file, bounded wait, fixed acquisition
  order, and `ps`-vs-mtime liveness probe are 100% prose in
  `skills/wurk:conductor/REFERENCE.md:29-90`, restated for workers in
  `agents/wurk-repo-worker.md:48-52`. The owner file has **no specified
  filename and no specified format** - two agents could write it differently
  and neither would be wrong per the prose.
- **The gate runs as exactly one blocking `Sh.run`.** `gate.rb:364` (quality)
  and `gate.rb:589` (attest), plus `worktree_create.rb:234` (post-warm
  verify). Output is fully buffered in memory by two reader threads
  (`lib/sh.rb:130-140`) and never streamed or written to a file. A timeout is
  binary: `Sh.run` sets `timed_out`, kills the child, and `gate.rb` reports a
  tier-0 failure with a 40-line tail. Nothing retries or resumes.
- **`gate.timeout_seconds` defaults to 600** (`lib/manifest.rb:108`) - the
  same order as the harness's Bash cap the bead describes. A gate that
  outruns the harness also outruns `gate.rb`'s own kill timer, so today the
  two limits coincide and there is no configured way to run longer.
- **`Sh.kill_process_group` kills only the direct pid** (`lib/sh.rb:174-180`)
  - despite the name there is no `-pid` form and no `Process.setsid`
  anywhere in the file. A killed gate's own children are orphaned.
- **The FOREGROUND / 600000ms / poll discipline reaches only two files**
  (`agents/wurk-repo-worker.md:40-57`, `skills/wurk:conductor/SKILL.md:136-150`
  and `:265-269`). None of the five Bash-tool `gate.rb` call sites mentions
  timeouts at all.
- **The kit script contract** (ADR-0006, `docs/architecture.md:42-58`):
  stdlib-only system Ruby, one JSON envelope on stdout, exit 0/1/2,
  `--dry-run` on every mutating script, every shell-out through `lib/sh.rb`,
  no `system`/backticks, no consumer constants, absolute banned-operation
  list. `test/contract_test.rb` scans every `.rb` under `scripts/` outside
  `test/` with no opt-out, and re-parses ADR-0006's own prose so text and
  enforcement cannot drift. `test/run.rb:18-19` globs `**/*_test.rb`, so a
  new test file needs no registration; a new **top-level** `scripts/*.rb`
  must carry the shebang and the executable bit
  (`contract_test.rb:544-552`).
- **Test seams that already exist**: `support/fake_sh.rb` (`Sh.runner=`
  double, FIFO argv-prefix expectations, `start_failed:` simulation) and
  `support/manifest_helper.rb` (`fixture_manifest`, `with_manifest`,
  `in_tmp_repo`, `all_fixture_guarded_paths`). Fixtures live in
  `test/fixtures/manifests/`; the `valid` fixture deliberately uses bead
  prefix `zz` and `make` gate commands.

## Desired End State

Two new kit scripts exist, are documented in `skills/wurk:kit/REFERENCE.md`,
and are covered by same-named `_test.rb` files in the kit suite, which stays
green.

**Verification**: `ruby skills/wurk:kit/scripts/test/run.rb` is green, and by
hand in a scratch repo:

```bash
ruby skills/wurk:kit/scripts/lock.rb acquire --gate-lock /tmp/l/gate-x \
  --campaign c1 --bead zz-1 --wait-seconds 5
ruby skills/wurk:kit/scripts/lock.rb status --dir /tmp/l/gate-x
ruby skills/wurk:kit/scripts/gate_run.rb start --profile loop
ruby skills/wurk:kit/scripts/gate_run.rb poll --run-dir <dir> --wait-seconds 30
```

`start` returns immediately with the literal `poll` command to repeat;
repeated `poll` calls each return well inside any Bash timeout and finally
report the gate's real exit status from the sentinel.

### Key Discoveries:

- `skills/wurk:conductor/REFERENCE.md:63-90` is the whole lock spec, and it
  is prose: lock kinds (`gate-<repo-dir>`, `tracker-<repo-dir>`,
  `machine-gate-slots/slot-N`, `registry`), the fixed order (repo gate lock
  first, then a free machine slot, released in reverse; a campaign that caps
  itself below the machine cap takes its campaign mutex before the slot),
  owner file contents, 10s polls, never remove a lock you did not create,
  only a conductor clears a verified-stale lock.
- `lib/sh.rb:110-159` is the single shell-out primitive; `lib/sh.rb:82-84`
  (`Sh.runner=`) is the test seam. Any new process-starting code must live
  here, not in a script, or the "all shelling out through `lib/sh.rb`" rule
  in `docs/architecture.md:51-52` is broken in spirit even though the static
  scan only catches `system`/backticks.
- A **non-parent process cannot reap an exit status.** Whoever polls is not
  the detached gate's parent, so the exit status must be *written down* by
  something that is. This forces the supervisor design below.
- `lib/envelope.rb` computes `ok` and returns the exit code from `#emit`;
  `lib/cli.rb` gives every script `--dry-run`/`--json`/`--help` and exits 2
  with plain text on a usage error.
- ADR-0005 (gate tiers) and ADR-0006 (envelope contract) bound the design;
  ADR-0012 (atomic claim inside the auto walk) is the nearest concurrency
  precedent and rejects claim-everything-then-release-losers.
- `gate.timeout_seconds` entering the schema (commit 082f019) is the cited
  precedent for how a new manifest field lands
  (`docs/research/260817-wu-9fb-subdirectory-gate-cwd.md:143`).

## What We're NOT Doing

- **Not touching sibling-owned prose.** `skills/wurk:conductor/SKILL.md`,
  `skills/wurk:conductor/REFERENCE.md`, `agents/wurk-repo-worker.md`, and
  `worktree_create.rb`'s warm-run lock stay exactly as they are. wu-ec5,
  wu-a7i, wu-4nc, wu-i0z and wu-7rn repoint them once these scripts exist.
  Phase 5 documents the new scripts in `skills/wurk:kit/REFERENCE.md` only,
  which is the kit's own surface.
- **Not changing `Sh.run`'s kill semantics.** `lib/sh.rb:174-180` kills the
  direct pid, not the group. Making `Sh.run` spawn with `pgroup: true` and
  signal `-pgid` would change signal delivery for every existing call site
  (`gh`, `tmux`, `git`, every gate run) in a bead whose subject is long
  gates. Instead the new streaming/detached path gets group semantics
  (Phase 2) and `Sh.run` is left alone; the general fix is a follow-up bead.
  Recorded here so the omission is not read as an oversight.
- **Not chunking or resuming a gate.** Proposal (b) on the bead ("chunk a
  >10-min gate into resumable stages") is rejected: `gate.rb` never runs
  stages separately - stages are parsed out of JSON the reporting command
  already produced (`gate.rb:564`) - so chunking would require every
  consumer's gate tool to grow a resume flag, and ADR-0005's tier model
  forbids the kit assuming any flag surface. Re-polling a whole run is the
  cheaper mechanism and needs nothing from the consumer.
- **Not making `gate.rb` itself long-running.** `gate_run.rb` is a separate
  script that reuses the manifest's gate argv; `gate.rb`'s judgment, tiers,
  skip taxonomy and envelope stay untouched. Merging the two would put a
  detached-process mode inside the script five call sites already invoke
  synchronously.
- **Not adding a daemon, reaper, or cron.** Nothing runs when nobody polls;
  see the deadline decision in Phase 4.
- **Not linting the fleet manifest.** `multiCampaign.locksDir` lives in
  `.claude/wurk-fleet.json`, which wurk does not document or lint
  (`skills/wurk:conductor/REFERENCE.md:11-14`). `lock.rb` takes lock
  directories as arguments; teaching `lib/manifest.rb` about the fleet
  manifest is its own bead.
- **Not a machine-config field.** Nothing here is a per-machine decision
  today (ADR-0013's placement rule); the machine slot count arrives as a CLI
  argument from the conductor that owns it.

## Implementation Approach

Five phases, each independently committable and green on
`ruby skills/wurk:kit/scripts/test/run.rb` by itself.

The load-bearing design decisions:

**A supervisor, not a bare background command.** `gate_run.rb start` does not
spawn the consumer's gate directly. It spawns *itself* -
`gate_run.rb supervise --run-dir <dir>` - detached, and that child runs the
gate through `lib/sh.rb` and writes the result down. This buys three things a
bare `cmd &` cannot: the actual gate shell-out still goes through the one
sanctioned primitive; the exit status is captured by the process's real
parent and persisted, which a later poller (not a parent, so `waitpid` is
unavailable to it) can never recover on its own; and the sentinel write is
ours, so it can be atomic.

**The sentinel is a rename.** The supervisor writes
`<run-dir>/result.json.part` and `File.rename`s it to `<run-dir>/result.json`.
A poller therefore never observes a half-written sentinel: `result.json`
exists and is complete, or it does not exist. `result.json` is a normal kit
envelope, so the poller re-emits its `data` rather than inventing a shape.

**Poll is foreground and bounded, and always exits 0 while running.** `poll`
blocks for at most `--wait-seconds` (default 60, an order of magnitude under
any plausible harness cap), sleeping between stat calls, then returns
`data.state: "running"` with a log tail and the exact command to repeat. A
still-running gate is not an error, so exit stays 0; the run's own red/green
only reaches the exit code once the sentinel exists. That is what makes "re-poll
until the sentinel appears" a loop an agent can execute without ever ending
its turn on detached work.

**Two timeouts, deliberately separate.** `gate.timeout_seconds` (default 600)
keeps bounding the *foreground, buffered* runs in `gate.rb` and
`worktree_create.rb`, where a caller is blocked and 600s is a sane leash.
Reusing it for the detached runner would cap the runner at exactly the
duration it exists to exceed, making the whole mechanism a no-op. So Phase 3
adds `gate.long_timeout_seconds` (optional, default 3600, validated
identically), and Phase 4's supervisor runs the gate under it. Enforcement is
split: the supervisor holds the real leash via `Sh` (it is the parent, so its
kill lands and, with `pgroup: true`, reaps the gate's whole tree); `poll` and
`status` additionally compare `now` against the deadline recorded in
`meta.json` so a run whose supervisor was itself killed is reported as
`abandoned` rather than as eternally `running`.

**Process groups, only on the new path.** The detached spawn and the
streaming run both use `pgroup: true` and signal the negative pgid, so the
long-gate path does not inherit the orphaned-children gap at
`lib/sh.rb:174-180`. `Sh.run` is untouched (see What We're NOT Doing).

**Liveness without `ps`.** The staleness probe uses `Process.kill(0, pid)`:
`Errno::ESRCH` proves dead, `Errno::EPERM` proves alive-but-not-ours, no
exception means alive. This is deterministic, needs no shell-out, works in
tests against a real forked pid, and gives a machine-detectable answer where
the prose spec ("lock mtime vs `ps`") gives a forensic one. When the owner
file records no pid (an agent-held lock with no process behind it), liveness
is reported as `"unknown"` and staleness falls back to mtime age vs
`--stale-after-seconds` - honest degradation in the ADR-0005 spirit ("weaker
is acceptable; vaguer is not").

---

## Phase 1: The lock helper

### Overview

`lib/lock.rb` (pure logic over a filesystem path) plus `lock.rb` (the CLI):
mkdir-mutex acquire with bounded wait, a specified owner-file format,
release that refuses to remove a lock it does not own, a staleness probe, and
a `clear` that refuses anything not provably stale. Fixed acquisition order
is enforced by the script, not asked of the caller.

### Changes Required:

#### 1. Lock logic

**File**: `skills/wurk:kit/scripts/lib/lock.rb`
**Changes**: New module. No `Sh`, no envelope - filesystem and `Process.kill`
only, so it is directly unit-testable.

```
module Lock
  OWNER_FILE = "owner"

  # The fixed acquisition order from skills/wurk:conductor/REFERENCE.md:74-78.
  # Lower rank is taken first and released last. The caller passes locks in
  # any order; this module sorts them, so an out-of-order request is a
  # non-event rather than a deadlock.
  ORDER = { "campaign" => 1, "registry" => 1, "gate" => 2, "tracker" => 2, "slot" => 3 }.freeze

  # Atomic: Dir.mkdir raises Errno::EEXIST when another holder won.
  # The owner file is written immediately after, so a reader may briefly see
  # a lock dir with no owner file; readers retry before concluding "ownerless".
  def self.try_acquire(dir, owner) ... end

  def self.acquire(dir, owner, wait_seconds:, poll_seconds:, clock:, sleeper:) ... end
  def self.acquire_all(specs, ...)   # sorts by ORDER, releases in reverse on partial failure
  def self.acquire_slot(slots_dir, count, owner, ...)  # first free slot-1..slot-N
  def self.read_owner(dir) ... end   # key=value lines -> hash
  def self.probe(dir, now:, stale_after_seconds:) ... end
  def self.release(dir, owner, force: false) ... end
end
```

Owner file format (the thing `REFERENCE.md:81-82` leaves unspecified): one
`key=value` per line, LF-terminated, values with no newlines, keys
`campaign`, `bead`, `pid`, `host`, `purpose`, `acquired_at` (ISO-8601). An
absent or unparseable owner file yields `owner: null` and never raises.

`probe` returns `{held:, owner:, age_seconds:, holder_alive: true|false|nil,
stale:, staleness_reason:}` where `stale` is true only when
`holder_alive == false` (provably dead pid), or when `holder_alive` is nil
*and* `age_seconds` exceeds `stale_after_seconds`. The two reasons are
reported distinctly (`dead_holder_pid` vs `ownerless_and_older_than_cutoff`)
because only the first is proof.

#### 2. The CLI

**File**: `skills/wurk:kit/scripts/lock.rb` (new top-level: shebang +
executable bit, per `contract_test.rb:544-552`)
**Changes**: `Cli.build` with subcommands `acquire`, `release`, `status`,
`clear`, all mutating ones honoring `--dry-run`.

- `acquire [--campaign-mutex DIR] [--gate-lock DIR] [--tracker-lock DIR]
  [--registry-lock DIR] [--slots-dir DIR --slots N] --campaign ID --bead ID
  [--pid N] [--purpose S] [--wait-seconds N (default 600)]
  [--poll-seconds N (default 10)]` - takes every named lock in `ORDER`,
  releasing what it took if a later one cannot be had inside the wait.
  `data`: `{acquired: [{kind:, dir:, owner:}], waited_seconds:, order: [...]}`.
  On a bounded-wait expiry it does **not** fail hard; it emits
  `blocked` with code `lock_contended`, `needs: "human"`, and the contended
  lock's full `probe` output so the caller has the staleness evidence in the
  same envelope (exit 1).
- `release --dir DIR --campaign ID --bead ID [--pid N]` - refuses (blocked,
  `lock_not_owned`) when the owner file names someone else; `--force` is
  deliberately absent here.
- `status --dir DIR [--stale-after-seconds N (default 1800)]` - read-only,
  always exit 0, emits the `probe` hash. This is the machine-detectable
  staleness answer the bead asks for.
- `clear --dir DIR` - removes a lock dir **only** when `probe` reports
  `stale: true` with reason `dead_holder_pid`. Anything else is `blocked`
  with `needs: "human"` and the probe attached, preserving
  `REFERENCE.md:83-87`'s "only a conductor clears, after an owner re-read and
  a liveness probe" - the script supplies the proof, a human still authorizes
  the ambiguous case.

Waiting is done with an injected sleeper (`Kernel.sleep` in production, a
counter in tests) so no test sleeps for real.

#### 3. Tests

**File**: `skills/wurk:kit/scripts/test/lock_test.rb`
**Changes**: New. Uses `Dir.mktmpdir` (stdlib) rather than `FakeSh` - this
script shells out to nothing. Covers: acquire creates dir + owner file;
second acquire on a held lock waits then blocks with `lock_contended`;
acquisition order is normalized regardless of flag order; a failure on the
third lock releases the first two in reverse; slot acquisition takes the
first free slot and blocks when all are taken; `probe` on a lock owned by a
reaped `fork`ed pid reports `holder_alive: false, stale: true,
staleness_reason: "dead_holder_pid"`; `probe` on a lock owned by `Process.pid`
reports alive and not stale regardless of age; `probe` on an ownerless dir
reports `holder_alive: nil`; `release` refuses a foreign owner; `clear`
refuses a live holder and succeeds on a dead one; `--dry-run` creates no
directory and records the intended commands.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] `skills/wurk:kit/scripts/lock.rb` exists, starts with
      `#!/usr/bin/env ruby`, and is executable (asserted by
      `contract_test.rb:544-552`)
- [x] `lock_test.rb` asserts a dead-holder probe returns
      `stale: true, staleness_reason: "dead_holder_pid"`
- [x] `lock_test.rb` asserts `--dry-run` creates nothing on disk
- [x] `lock_test.rb`'s contention test asserts the injected sleeper recorded
      at least one call **and** that the test's own wall clock stayed under
      0.5s - together these decide mechanically that the wait loop went
      through the seam and never reached `Kernel.sleep`

#### Manual Verification:
- [ ] Two shells contending on one lock dir behave as specified: the second
      waits, then reports the first as the live holder
- [ ] `kill -9` the first holder, then `lock.rb status` reports
      `stale: true`, and `lock.rb clear` removes it
- [ ] `lock.rb clear` on a live holder refuses and says why
- [ ] Take a lock, then `Ctrl-C` the acquiring shell before releasing:
      confirm the lock dir survives with its owner file intact and that
      `status` still reads it (the crash case the whole probe exists for)

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: Detached and streaming primitives in `lib/sh.rb`

### Overview

Add the two process primitives the runner needs to the one sanctioned
shell-out site, plus the FakeSh doubles and a contract rule that keeps them
there. Nothing about `Sh.run` changes.

### Changes Required:

#### 1. `Sh.spawn_detached`

**File**: `skills/wurk:kit/scripts/lib/sh.rb`
**Changes**: New runner method returning a pid, never a `Result`.

```
# Starts argv in its own process group, fully detached from this process's
# lifetime, with stdout/stderr redirected to out_path. Returns the pid.
# Its own process group (pgroup: true) is what lets a later signal reach the
# whole tree; Sh.run deliberately keeps its existing single-pid semantics
# (see lib/sh.rb:174-180) so this bead changes no existing call site.
def spawn_detached(argv, chdir: nil, out_path:)
  opts = { pgroup: true, out: out_path, err: [:child, :out] }
  opts[:chdir] = chdir if chdir
  pid = Process.spawn(*argv, opts)
  Process.detach(pid)
  pid
end
```

#### 2. `Sh.run_streaming`

**File**: `skills/wurk:kit/scripts/lib/sh.rb`
**Changes**: Same `popen3` shape as `run`, with two differences: the reader
threads append to `log_path` line by line as output arrives (so a poller has
something to tail) while also keeping a bounded in-memory tail, and the
child is started with `pgroup: true` so the timeout kill signals `-pgid`
and reaps the gate's children instead of orphaning them. Returns the same
`Sh::Result`, with `out` holding the retained tail rather than the whole
stream. A comment states plainly that the full output is on disk and the
`Result` carries only the tail, so no caller assumes otherwise.

#### 3. Test double

**File**: `skills/wurk:kit/scripts/test/support/fake_sh.rb`
**Changes**: `#spawn_detached` returns a canned pid and records the argv;
`#run_streaming` matches an expectation like `#run` and, when the expectation
carries `log:`, writes it to `log_path` so a caller's log handling is
exercised. Both go through the existing FIFO `#expect`/`#verify!` machinery,
so an unstubbed call still raises `FakeSh::UnexpectedCommand`.

#### 4. Contract rule

**File**: `skills/wurk:kit/scripts/test/contract_test.rb`
**Changes**: Extend the existing `system_or_backticks` family with a scan for
process *creation* in any `non_test_files` entry other than `lib/sh.rb`:
`Process.spawn`, `Process.detach`, `Process.fork`, a bare `fork(`,
`IO.popen`, `Open3.`, and `exec(`. Plus a meta-test that plants a violation
to prove the scan is not vacuous (matching the pattern at
`contract_test.rb:673-695`). This turns "all shelling out through
`lib/sh.rb`" from an honor-system rule into an enforced one, which is what
makes it safe to put a detached spawn in the kit at all.

The rule is deliberately scoped to process *creation*, not to `Process.` as a
namespace: Phase 1's `lock.rb` legitimately calls `Process.kill(0, pid)` and
`Process.pid`, which start nothing and are the whole basis of the staleness
probe. A blanket `Process\.` scan would make Phases 1 and 2 mutually
unlandable. Today the only non-comment hits anywhere outside `lib/sh.rb` are
zero (`tmux_window.rb:245` names `Open3.popen3` in a comment, and comments
are exempt by `each_code_line`), so the rule lands green.

#### 5. Tests

**File**: `skills/wurk:kit/scripts/test/sh_test.rb`
**Changes**: Real-process tests (this file already exercises the real
runner). `spawn_detached` on `ruby -e` returns a live pid, writes its output
to `out_path`, and survives the caller's continued execution; the spawned pid
is its own process-group leader (`Process.getpgid(pid) == pid`).
`run_streaming` writes the log incrementally (assert the file is non-empty
while the child is still producing), returns a `Result` whose `out` is the
tail, and on timeout kills a child that itself forked a grandchild - asserting
the grandchild is gone, which is the concrete gap `lib/sh.rb:174-180` leaves
open on the existing path.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] `sh_test.rb` asserts `Process.getpgid(pid) == pid` for a detached spawn
- [x] `sh_test.rb` asserts a grandchild of a `run_streaming` timeout victim
      is reaped
- [x] `contract_test.rb` fails when a planted `Process.spawn` is added to a
      script outside `lib/sh.rb` (meta-test)
- [x] `Sh.run`'s existing tests are unmodified and still pass

#### Manual Verification:
- [ ] A detached spawn genuinely outlives its launcher shell (`ps` after the
      launcher exits)
- [ ] The streamed log is readable with `tail -f` while the command runs
- [ ] Run an existing `Sh.run` caller by hand (`repo_state.rb`) before and
      after this phase and confirm identical output and comparable timing -
      the blocking path must be untouched

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: `gate.long_timeout_seconds` in the manifest

### Overview

One new optional manifest field, added to `lib/manifest.rb` and
`docs/manifest.md` in the same commit (a hard rule in `CLAUDE.md`), with the
same validation shape as `gate.timeout_seconds`.

### Changes Required:

#### 1. Schema

**File**: `skills/wurk:kit/scripts/lib/manifest.rb`
**Changes**:

- Add `long_timeout_seconds` to `KNOWN["gate"]` (`manifest.rb:82-83`).
- `DEFAULTS["gate.long_timeout_seconds"] = 3600` beside the two existing
  600s defaults (`manifest.rb:108-109`).
- Accessor `gate_long_timeout_seconds` beside `gate_timeout_seconds`
  (`manifest.rb:300-302`), with a comment recording *why* it is separate:
  `gate.timeout_seconds` bounds foreground runs whose caller is blocked;
  this one bounds the detached long-gate run, which exists precisely to
  outlive that bound.
- `validate_gate_long_timeout_seconds`, positive Integer only, reusing the
  same helper `validate_gate_timeout_seconds` uses (`manifest.rb:646-651`).
- A validation warning (not a block) when `long_timeout_seconds <
  timeout_seconds`: legal, but almost certainly a mistake.

#### 2. Documentation

**File**: `docs/manifest.md`
**Changes**: A jsonc line in the `gate` block beside `timeout_seconds`
(`docs/manifest.md:69-72`), an entry in the defaults list at `:617-618`, and
a validation bullet beside `:657-660`.

#### 3. Fixtures and tests

**Files**: `skills/wurk:kit/scripts/test/fixtures/manifests/gate_tier1.json`
(add the field), `skills/wurk:kit/scripts/test/manifest_test.rb`
**Changes**: Assert the default when absent, the parsed value when present,
the unknown-key warning is *not* raised for it, a non-positive value is a
validation failure, and the `long < short` warning fires.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] `manifest_test.rb` asserts `gate_long_timeout_seconds == 3600` for a
      manifest that omits the field
- [x] `manifest_test.rb` asserts a zero/negative/non-integer value fails
      validation
- [x] `grep -n long_timeout_seconds docs/manifest.md` returns hits in the
      schema block, the defaults list, and the validation list

#### Manual Verification:
- [ ] Set `gate.long_timeout_seconds` below `gate.timeout_seconds` in a
      scratch manifest and confirm the warning fires with wording that names
      which field bounds which kind of run
- [ ] Run `manifest.rb`-consuming scripts (`gate.rb`, `worktree_create.rb
      --dry-run`) against a manifest that omits the new field and confirm no
      new warning or unknown-key message appears

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 4: `gate_run.rb`, the sanctioned long-gate runner

### Overview

The runner itself: `start` (detached launch, optional lock acquisition),
`supervise` (the detached child), `poll` (the bounded foreground wait an
agent repeats), and `status` (read-only).

### Changes Required:

#### 1. The script

**File**: `skills/wurk:kit/scripts/gate_run.rb` (new top-level: shebang +
executable bit)
**Changes**: Four subcommands.

`start [--profile loop] [--run-dir DIR] [--gate-lock DIR --campaign ID
--bead ID] [--slots-dir DIR --slots N] [--wait-seconds N] [--dry-run]`

1. Resolve the gate argv from the manifest exactly as `gate.rb:360-373`
   does - prefer the reporting variant, fall back to `gate.full`/`gate.loop`
   - and `gate.cwd` via `manifest.gate_chdir`. The script names no gate tool
   and no flag; every argv comes from the manifest.
2. Create the run dir. Default `<repo root>/.claude/wurk-runs/gate/<run-id>`
   where `<run-id>` is `<utc timestamp>-<pid>`; `--run-dir` overrides. This
   is a kit-chosen path, not a consumer constant, so it needs no manifest
   field.
3. When lock flags are given, acquire through `lib/lock.rb` in `ORDER`,
   recording the *supervisor's* pid in the owner file (the pid that is
   actually alive for the duration - which is what makes the Phase 1
   staleness probe meaningful for gate locks). Because the pid is only known
   after the spawn, `start` acquires with its own pid, spawns, then rewrites
   the owner file's `pid=` line; the write is a rename over the owner file so
   a concurrent reader never sees it truncated.
4. Write `meta.json`: run id, argv, chdir, profile, `started_at`,
   `deadline_at` (= `started_at + gate.long_timeout_seconds`), lock dirs
   held, log path, sentinel path.
5. `Sh.spawn_detached` the supervisor.
6. Emit `data: {run_id:, run_dir:, log_path:, sentinel_path:, pid:,
   deadline_at:, locks:, poll_command: "ruby .../gate_run.rb poll --run-dir
   <dir> --wait-seconds 60"}`. `poll_command` is a literal string an agent
   can run verbatim - the whole point is that the next step is handed over,
   not remembered.

`supervise --run-dir DIR` (not for humans; `start` spawns it)

Runs the gate via `Sh.run_streaming(argv, chdir:, timeout:
gate_long_timeout_seconds, log_path: <run-dir>/gate.log)`, then releases any
locks named in `meta.json`, then writes the envelope to
`<run-dir>/result.json.part` and renames it to `result.json`. Locks are
released in reverse acquisition order, and released **before** the sentinel
is written so a poller that sees the sentinel can be sure the lock is free.
The envelope's `data` carries `{exit_status:, timed_out:, duration_seconds:,
log_path:, output_tail:}`; the tail reuses `gate.rb`'s 40-line convention.
Release is wrapped so a crash in release still writes a sentinel - a run that
finished but could not release is reported (`warnings`), never silently
hung.

`poll --run-dir DIR [--wait-seconds N (default 60)] [--tail-lines N (default
40)]`

Foreground. Loops: if `result.json` exists, load it and return
`data.state: "finished"` plus the supervisor's `data`, exiting 1 when the
gate was red or timed out and 0 when green. Else if `now > deadline_at` or
the supervisor pid is not alive, return `data.state: "abandoned"` with the
log tail and exit 1 - a poller must never wait forever on a dead supervisor,
which is precisely the failure the bead reports. Else sleep and re-check
until `--wait-seconds` elapses, then return `data.state: "running"` with
`{elapsed_seconds:, deadline_at:, log_tail:, poll_command:}` and **exit 0**.

`status --run-dir DIR` - the same computation with no waiting, always exit 0.

`--dry-run` on `start` resolves everything, records the intended commands,
creates no run dir, acquires no lock, and spawns nothing.

#### 2. Tests

**File**: `skills/wurk:kit/scripts/test/gate_run_test.rb`
**Changes**: New, modeled on `gate_test.rb`: `FakeSh` installed in `setup`,
`ManifestHelper#in_tmp_repo` for the fixture manifest, and
`GateRun.run(argv, io: StringIO)` parsed as JSON. Covers:

- `start` resolves the reporting argv from the fixture manifest and passes
  it to `spawn_detached` verbatim (proving no gate tool is named in the
  script)
- `start` writes `meta.json` with a `deadline_at` equal to `started_at +
  gate.long_timeout_seconds`, not `+ gate.timeout_seconds`
- `start --dry-run` creates no run dir and calls neither FakeSh method
- `start` with lock flags acquires in `ORDER` and records the supervisor pid
- `poll` on a run dir with no sentinel and a live pid returns
  `state: "running"` and **exit 0**, and includes a `poll_command`
- `poll` on a run dir whose sentinel exists returns `state: "finished"` and
  the supervisor's exit status, exit 1 when red
- `poll` past `deadline_at` returns `state: "abandoned"` and exit 1
- `poll` with a dead supervisor pid and no sentinel returns
  `state: "abandoned"` (the campaign-004 failure, now machine-detected)
- `poll` never observes a partial sentinel: writing `result.json.part`
  without renaming leaves `poll` in `state: "running"`
- `supervise` writes the sentinel by rename, releases locks before writing
  it, and still writes a sentinel when release raises
- a usage error raises `SystemExit` with plain-text stderr and no envelope
  (mirroring `gate_test.rb:769-791`)

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] `skills/wurk:kit/scripts/gate_run.rb` exists with shebang and
      executable bit (`contract_test.rb:544-552`)
- [x] `gate_run_test.rb` asserts `poll` exits 0 while the run is still
      running
- [x] `gate_run_test.rb` asserts a dead supervisor with no sentinel yields
      `state: "abandoned"`
- [x] `gate_run_test.rb` asserts the deadline uses
      `gate.long_timeout_seconds`
- [x] `gate_run_test.rb` asserts `start --dry-run` spawns nothing
- [x] `contract_test.rb`'s consumer-vocabulary scan passes over the new
      script (no gate tool named in code)

#### Manual Verification:
- [ ] Against this repo's own manifest, `gate_run.rb start` returns
      immediately and repeated `poll` calls report progress, then the real
      exit status
- [ ] A gate deliberately made slow (a sleep in a scratch manifest) survives
      several poll cycles and finishes correctly
- [ ] `kill -9` the supervisor mid-run: the next `poll` reports `abandoned`
      rather than hanging, and the gate lock is reported stale by
      `lock.rb status`
- [ ] `tail -f <run-dir>/gate.log` shows live output during a run
- [ ] Run `gate.rb` normally in this repo afterward and confirm the
      foreground path is untouched: same envelope keys, same tier, same
      timeout behavior as before this phase

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 5: Kit reference documentation

### Overview

Document both scripts where the kit documents its scripts, so the sibling
beads have something to point at. Kit surface only; no sibling-owned file is
touched.

### Changes Required:

#### 1. Script reference

**File**: `skills/wurk:kit/REFERENCE.md`
**Changes**: Two new sections in the same shape as the existing `gate.rb`
section (`REFERENCE.md:315-387`): purpose, subcommands, flags, `data` keys,
exit codes. For `gate_run.rb`, include the poll loop as an explicit worked
sequence (`start`, then `poll` repeatedly until `state` is not `"running"`)
and state that a `"running"` poll exits 0 by design. For `lock.rb`, state the
owner-file format, the fixed order, and the rule that `clear` only ever
removes a provably dead holder's lock.

Note: `REFERENCE.md`'s shell fences are scanned by `contract_test.rb:612-619`
for consumer vocabulary, so examples use manifest-driven invocations only.

#### 2. Architecture note

**File**: `docs/architecture.md`
**Changes**: One sentence in the Layer 2 bullet list recording that process
creation of every kind (blocking, streaming, detached) lives in `lib/sh.rb`
and is now enforced by the contract test, so the ADR-0006 rule's scope is
unambiguous to the next author.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
      (this includes `contract_test.rb`'s scans over `REFERENCE.md`'s shell
      fences and every `SKILL.md`)
- [x] `grep -n "gate_run.rb" skills/wurk:kit/REFERENCE.md` and
      `grep -n "lock.rb" skills/wurk:kit/REFERENCE.md` both return hits
- [x] No skill cross-reference breaks (`contract_test.rb:652-668`)

#### Manual Verification:
- [ ] Follow the `gate_run.rb` section top to bottom in a scratch repo
      using only what it says: `start`, then repeated `poll`, then read the
      finished envelope. Confirm no step required knowledge from this plan
      or from the script source.

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

- `test/lock_test.rb` - real temp directories and real pids (a `fork`ed child
  reaped to produce a provably dead pid). No `FakeSh`; this script shells out
  to nothing. The wait loop takes an injected clock and sleeper so contention
  tests are instant.
- `test/sh_test.rb` (extended) - real child processes, as the file already
  does. Process-group assertions (`Process.getpgid`) and a
  child-plus-grandchild timeout case are the two that matter, because they
  are the concrete behaviors the existing `kill_process_group` lacks.
- `test/gate_run_test.rb` - `FakeSh` for both `spawn_detached` and
  `run_streaming`, fixture manifests via `ManifestHelper`, hand-built run
  directories to simulate every sentinel/pid/deadline combination. Because
  `FakeSh` raises on any unstubbed call, a test that omits an expectation is
  itself proof the script never started a process.
- `test/manifest_test.rb` (extended) - default, parse, validation, and the
  `long < short` warning for `gate.long_timeout_seconds`.
- `test/contract_test.rb` (extended) - the process-creation rule plus its
  planted-violation meta-test.

### Manual Testing Steps:

1. In a scratch repo with a manifest whose `gate.loop` is a long sleep, run
   `gate_run.rb start --profile loop` and confirm it returns in under a
   second with a `poll_command`.
2. Run that `poll_command` repeatedly; confirm each call returns inside
   `--wait-seconds`, exits 0 while running, and finally reports the gate's
   real exit status.
3. `tail -f` the run's `gate.log` during step 2 and confirm output appears
   live rather than all at once at the end.
4. `kill -9` the supervisor mid-run; confirm the next `poll` reports
   `abandoned` and exits 1, and that `lock.rb status` on the gate lock
   reports `stale: true, staleness_reason: "dead_holder_pid"`.
5. `lock.rb clear` that stale lock; confirm it succeeds. Re-run with a live
   holder; confirm it refuses with `needs: "human"`.
6. Start two `gate_run.rb start` invocations against the same gate lock;
   confirm the second waits and then reports the first as the live holder
   rather than proceeding.
7. Set `gate.long_timeout_seconds` below the sleep length and confirm the
   run ends with `timed_out: true` and that no gate child process survives
   (`ps` for the gate's grandchildren).

## Open Questions

No human was available during planning; these are recorded rather than
resolved, and none blocks implementation. Each names the decision taken in
the meantime so the plan stays actionable.

1. **The Bash tool's actual maximum timeout is not documented in this repo.**
   The bead says 10 minutes, the prose says "explicit 600000ms". `poll`'s
   default `--wait-seconds` is therefore 60 - an order of magnitude under any
   plausible cap - rather than a value tuned to a number nobody here has
   confirmed. If the real cap is later documented, only the default changes.
2. **`gate.long_timeout_seconds`'s 3600 default is a guess.** No consumer
   manifest is checked into this repo and no record exists of which repos
   actually have gates exceeding 10 minutes cold, so the default was chosen
   as "six times the foreground leash" rather than from data. It is a
   manifest field precisely so a consumer can correct it without a kit
   change.
3. **Whether `Sh.run` should adopt process-group kill semantics.** This plan
   deliberately does not change it (see What We're NOT Doing), which leaves
   `gate.rb`'s foreground timeout still able to orphan a gate's children.
   Recommended as a follow-up bead under wu-ddi rather than folded in here,
   following the precedent set in
   `docs/plans/260817-wu-9fb-subdirectory-gate-cwd.md:207-213`, where the
   same class of adjacent timeout gap was filed separately rather than
   absorbed.
4. **Where lock directories live is still caller-supplied.**
   `multiCampaign.locksDir` is a fleet-manifest field wurk neither documents
   nor lints. `lock.rb` takes directories as arguments, so the conductor
   keeps owning the policy; teaching `lib/manifest.rb` about the fleet
   manifest is out of scope here and worth its own bead.
5. **The owner-file format is being specified here for the first time.**
   `skills/wurk:conductor/REFERENCE.md:81-82` names the three fields but no
   filename or encoding. This plan fixes it at `owner`, `key=value` lines.
   Reconciling the prose with the shipped format is sibling work (wu-4nc /
   wu-i0z), not this bead's.

## References

- Source document:
  `docs/research/260902-wu-4x9-subagent-long-gate-runs-and-locks.md`
- Related ADRs: `docs/adr/0005-gate-contract-tiers.md`,
  `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`,
  `docs/adr/0012-atomic-claim-inside-auto-walk.md`,
  `docs/adr/0013-machine-level-config-seam.md`
- Lock spec being mechanized: `skills/wurk:conductor/REFERENCE.md:29-90`
- Gate execution today: `skills/wurk:kit/scripts/gate.rb:360-424`,
  `skills/wurk:kit/scripts/lib/sh.rb:110-180`
- Similar implementation (script + lib + CLI split):
  `skills/wurk:kit/scripts/plan_state.rb:1-45`,
  `skills/wurk:kit/scripts/outbound_scan.rb`
- Schema precedent: `skills/wurk:kit/scripts/lib/manifest.rb:108`,
  `docs/manifest.md:69-72`
- Epic: `wu-ddi`. Bead: `wu-4x9`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Two shells contending on one lock dir behave as specified: the second
      waits, then reports the first as the live holder
- [ ] `kill -9` the first holder, then `lock.rb status` reports
      `stale: true`, and `lock.rb clear` removes it
- [ ] `lock.rb clear` on a live holder refuses and says why
- [ ] Take a lock, then `Ctrl-C` the acquiring shell before releasing:
      confirm the lock dir survives with its owner file intact and that
      `status` still reads it (the crash case the whole probe exists for)

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 2

- [ ] A detached spawn genuinely outlives its launcher shell (`ps` after the
      launcher exits)
- [ ] The streamed log is readable with `tail -f` while the command runs
- [ ] Run an existing `Sh.run` caller by hand (`repo_state.rb`) before and
      after this phase and confirm identical output and comparable timing -
      the blocking path must be untouched

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 3

- [ ] Set `gate.long_timeout_seconds` below `gate.timeout_seconds` in a
      scratch manifest and confirm the warning fires with wording that names
      which field bounds which kind of run
- [ ] Run `manifest.rb`-consuming scripts (`gate.rb`, `worktree_create.rb
      --dry-run`) against a manifest that omits the new field and confirm no
      new warning or unknown-key message appears

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 4

- [ ] Against this repo's own manifest, `gate_run.rb start` returns
      immediately and repeated `poll` calls report progress, then the real
      exit status
- [ ] A gate deliberately made slow (a sleep in a scratch manifest) survives
      several poll cycles and finishes correctly
- [ ] `kill -9` the supervisor mid-run: the next `poll` reports `abandoned`
      rather than hanging, and the gate lock is reported stale by
      `lock.rb status`
- [ ] `tail -f <run-dir>/gate.log` shows live output during a run
- [ ] Run `gate.rb` normally in this repo afterward and confirm the
      foreground path is untouched: same envelope keys, same tier, same
      timeout behavior as before this phase

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 5

- [ ] Follow the `gate_run.rb` section top to bottom in a scratch repo
      using only what it says: `start`, then repeated `poll`, then read the
      finished envelope. Confirm no step required knowledge from this plan
      or from the script source.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

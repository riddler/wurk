# Lock keeper: a holder pid that is the hold's own process Implementation Plan

## Overview

A lock's owner file records one `pid`, and `lock.rb`'s whole staleness
answer is `Process.kill(0, pid)` on it. That answer is only as good as the
pid: it must be a process whose lifetime IS the hold. For the conductor's
own campaign mutex it is (the conductor session is the holder). For a lock a
worker takes it is not: a `wurk-repo-worker` is a subagent, subagents run
inside the conductor's session process, and so the only pid a worker can
name from its shell (`$PPID`) is the conductor's. The lock then lives and
dies with the conductor's window, not with the worker's work - read as
stale the moment the window closes even if the work it guards (a gate
process, a warm) is still running, and read as alive for hours after the
worker itself crashed, for as long as the conductor keeps running.

This plan gives a hold its own process. `lock.rb acquire --hold-seconds N`
spawns a small detached keeper (`lock.rb keep`) and records the KEEPER's pid
as the owner pid - the same move `gate_run.rb start` already makes when it
rewrites the owner pid to its detached supervisor. The keeper lives exactly
as long as the hold: it exits when the lock is released (its directory
removed) or taken over by another holder, and when the hold's lease
(`hold_until`) runs out it exits without touching the lock, which leaves a
provably dead pid behind for `lock.rb clear`. The staleness probe itself
does not change.

Bead: wu-jm7h

Relayed from a consumer campaign's residue notes; the source
tracker's copy is outside this repo.

## Current State Analysis

- The owner file keys are `campaign bead pid host purpose acquired_at`
  (`skills/wurk:kit/scripts/lib/lock.rb:36`). `owner_content` writes only
  keys in `OWNER_KEYS` (`lib/lock.rb:291-299`), so a key not listed there
  would be silently dropped by `rewrite_owner_pid`
  (`lib/lock.rb:108-115`), which re-serializes the whole owner.
- Liveness is `holder_alive?` - `Process.kill(0, pid)`, ESRCH is dead,
  EPERM is alive, no pid is `nil` (`lib/lock.rb:319-331`). `probe` calls a
  lock stale only on a provably dead pid (`dead_holder_pid`) or on an
  ownerless lock past the cutoff (`lib/lock.rb:222-241`); `clear` removes
  only the first (`lib/lock.rb:268-275`, CLI `lock.rb:268-299`).
- `lock.rb acquire` records whatever `--pid N` it is handed, or no pid at
  all (`skills/wurk:kit/scripts/lock.rb:122`, `build_owner` at
  `lock.rb:173-183`). The CLI has no `Sh` today; its header says so
  (`lock.rb:12-20`).
- Which callers pass which pid:
  - **Conductor, campaign mutex** - `--pid <session pid>`, the session's
    own `$PPID` confirmed with `ps` (`skills/wurk:conductor/SKILL.md:193-203`).
    Correct: the conductor session is the holder.
  - **`gate_run.rb start --gate-lock/--slots-dir`** - acquires under the
    CLI's own `Process.pid` (`gate_run.rb:165-173`), then spawns the
    detached supervisor with `Sh.spawn_detached` and rewrites every owner
    pid to the supervisor's (`gate_run.rb:206-216`). Correct: the
    supervisor's lifetime is the gate run, and it releases the locks
    itself. This is the model this plan generalizes.
  - **Workers (`wurk-repo-worker`) on a short gate or a warm** - the shared
    block tells them to "mkdir to acquire ... ALWAYS rmdir after your run"
    (`agents/blocks/gate-discipline.md:53-57`), and the conductor's
    dispatch template tells them to take the locks "via `lock.rb acquire`"
    (`skills/wurk:conductor/SKILL.md:2040-2045`, `:1044-1049`). Neither
    says which pid. A worker that follows the conductor's own recipe passes
    `$PPID`, which is the conductor's session process - the bug. A worker
    that passes `$$` records a Bash shell that is gone before the next tool
    call, which reads stale at once. A worker that passes nothing gets
    `holder_alive: nil`, which no script may ever clear.
- The owner-file discipline in the conductor reference says only
  `pid=<pid>` (`skills/wurk:conductor/REFERENCE.md:94-103`).
- `campaign_state.rb` reads the campaign mutex through `Lock.probe`
  (`campaign_state.rb:16-26`); it is unaffected as long as `probe` keeps its
  shape.
- `Sh.spawn_detached` already exists: own process group, stdout/stderr to
  `out_path`, `Process.detach`, returns the pid (`lib/sh.rb:246-252`).
  `FakeSh#spawn_detached` returns a fresh canned pid per call and records
  the argv (`test/support/fake_sh.rb:79-87`).
- Tests may spawn real processes (`test/support/dead_pid.rb` does, and
  explains why spawn and never fork); the contract test's
  process-creation scan covers non-test files only
  (`test/contract_test.rb:697-707`).

## Desired End State

- `lock.rb acquire ... --hold-seconds N` acquires as today, then spawns one
  detached keeper for every lock the call took, rewrites each owner file's
  `pid` to the keeper's pid, and records `hold_until` (ISO-8601 UTC) in the
  owner file. The envelope carries `data.keeper_pid` and
  `data.hold_until`. `--hold-seconds` with `--pid` is a usage error (exit
  2): a hold has exactly one liveness source.
- `lock.rb keep --dir DIR [--dir DIR ...] --acquirer-pid N --hold-until ISO
  [--poll-seconds N]` is the keeper (internal, like `gate_run.rb
  supervise`). It exits with reason `released` once every watched
  directory is gone, `superseded` once every remaining one is owned by a
  pid other than its own or the acquirer's, and `expired` at
  `hold_until`, leaving the locks exactly as they are.
- Consequences, which are the bead's acceptance:
  - a worker-held lock outlives the conductor's window: the keeper is not a
    child of anything that window's close kills, and its pid stays alive,
    so `probe` reports `holder_alive: true, stale: false` and `clear`
    refuses;
  - a genuinely dead holder is still stale: a killed keeper, or one whose
    lease expired, leaves a dead pid and `probe` reports
    `dead_holder_pid`, which `clear` removes;
  - both are covered by tests that use real processes.
- The worker gate-semaphore block, the conductor's dispatch slot and the
  conductor's owner-file discipline all say: a lock taken on a worker's
  behalf uses `--hold-seconds`, never the session pid; the session pid is
  for a hold whose holder is the session.
- `lib/lock.rb` still has no `Sh` and no envelope.

Verify: the full gate (`/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb`)
is green after each phase, and the Manual Testing Steps below behave as
described.

### Key Discoveries:
- The fix already exists once in the kit: `gate_run.rb:206-216` spawns a
  detached process and rewrites the owner pid to it. The keeper is that
  pattern without the gate.
- `rewrite_owner_pid` re-serializes through `OWNER_KEYS`
  (`lib/lock.rb:108-115`, `:291-299`), so `hold_until` must be added to
  `OWNER_KEYS` or the rewrite erases it.
- There is a window between the keeper's start and the owner rewrite in
  which the owner file still names the acquiring CLI's pid. The keeper must
  treat both its own pid and `--acquirer-pid` as "still ours", or it would
  see its own lock as superseded and exit immediately. That premise only
  holds if the CLI SEEDS the pid: today `build_owner` writes `pid` only
  when `--pid` is given (`lock.rb:175`), and `--hold-seconds` excludes
  `--pid`, so without a seed the window would show NO pid and the keeper
  would drop the lock on its first poll. `gate_run.rb` seeds its own
  `Process.pid` for the same reason (`gate_run.rb:171`); the CLI must too.
- The keeper's stdout and stderr must not be the caller's: a harness that
  waits for EOF on a tool's stdout would wait on the keeper for the whole
  hold. `spawn_detached` with `out_path: File::NULL` redirects both.
- ADR-0006 (stdlib, envelope, `--dry-run`, all process creation through
  `lib/sh.rb`), ADR-0015 (the detached path is `spawn_detached`; `Sh.run`
  is untouched), ADR-0016 section 2 (on one host `lock.rb` is the lease
  with liveness - this plan makes that lease honest for worker holds rather
  than adding a second mechanism).

## What We're NOT Doing

- **Not changing `probe`, `holder_alive?`, `clear` or the staleness
  reasons.** The bead left open "stale detection that does not trust pid
  alone". Declined: once the pid is the hold's own process, the pid is the
  right and sufficient signal. The second signals available are both worse
  here - a wall-clock TTL on `probe` would make a live long gate clearable,
  and "is a gate process still running" needs to know what a gate process
  looks like, which is a consumer constant the kit may not carry.
- **Not a heartbeat.** A worker blocked on a foreground gate cannot beat,
  and anything that beats for it is a process - which is the keeper, with
  a pid, and needs no file-touching protocol on top.
- **Not a `lock.rb run -- <cmd>` wrapper** (hold the lock for one wrapped
  command). It only covers holds that fit in one tool call, and worker
  holds routinely do not ("Locks are held across wurk:commit's internal
  gate re-run", `skills/wurk:conductor/REFERENCE.md:103`). It would also
  put a second command's output inside `lock.rb`'s one-envelope stdout.
- **Not touching `gate_run.rb`.** Its supervisor is already the right pid.
- **Not changing the conductor's own campaign mutex.** Its holder is the
  session; `--pid <session pid>` stays correct there.
- **No distinct staleness reason for an expired lease.** An expired keeper
  is a dead pid and reads `dead_holder_pid`; see Open Questions.
- **No kit default for `--hold-seconds`.** The conductor sizes it per
  dispatch from its Phase 0 gate measurement; a silent default would let a
  hold expire under a gate nobody sized (the same reasoning as the slot
  count having no default, kit REFERENCE `lock.rb` section).
- **Not mechanically refusing `--pid` on a worker's acquire.** From inside
  `lock.rb` a subagent's `$PPID` and a conductor's `$PPID` are the same
  process; there is nothing to tell apart. The prose carries this rule.
- **No change to the source tracker's copy of this bug.** It lives in a
  consumer repo's local-only tracker; closing it there is that repo's
  operator's call once this lands.

## Implementation Approach

Bind the recorded pid to a process whose lifetime is the hold, and keep
every existing reading of that pid unchanged. The keeper loop is pure
filesystem plus an injected clock and sleeper, so it lives in `lib/lock.rb`
beside `acquire` and is unit-tested there without processes (Phase 1). The
CLI wires it: spawning the keeper through `Sh.spawn_detached`, the owner
rewrite, the `keep` subcommand, and end-to-end tests with real processes
for both acceptance criteria (Phase 2). Then the callers' prose moves to it
(Phase 3). Each phase leaves the gate green on its own: Phase 1's loop is
exercised by its own tests before anything calls it, Phase 2 changes no
existing default behavior (no `--hold-seconds`, no keeper), and Phase 3 is
prose plus the agent rebuild the gate checks.

## Phase 1: `hold_until` and the keeper loop in lib/lock.rb

### Overview
Add the owner key and the pure keeper loop, with unit tests. No CLI change.

### Changes Required:

#### 1. Owner key
**File**: `skills/wurk:kit/scripts/lib/lock.rb`
**Changes**: Append `hold_until` to `OWNER_KEYS` (after `acquired_at`).
Extend the `OWNER_KEYS` comment: `hold_until` is present only on a lock
held through a keeper, and is the time the keeper stops keeping it.

#### 2. The keeper loop
**File**: `skills/wurk:kit/scripts/lib/lock.rb`
**Changes**: New public `Lock.keep`, placed after `clear`.

```ruby
# The loop behind `lock.rb keep`: the process whose pid a keeper-held
# lock records, and which therefore IS the hold as far as probe's
# liveness check is concerned. Watches dirs until one of three things:
#   released   - every watched dir is gone (lock.rb release removed it)
#   superseded - every remaining dir is owned by a pid that is neither
#                own_pid nor acquirer_pid (released, then re-taken)
#   expired    - clock passed hold_until; the dirs are left exactly as
#                they are, so the exit leaves a dead pid behind and probe
#                reports dead_holder_pid, which clear may remove
# acquirer_pid counts as "ours" because the acquiring CLI rewrites the
# owner pid to the keeper only after the keeper has started. A missing or
# unreadable owner file counts as not ours. Pure filesystem + clock: no
# Sh, no envelope. Returns {reason:, watching:} where watching is the
# dirs still held at exit (empty unless expired).
def keep(dirs, own_pid:, acquirer_pid:, hold_until:, poll_seconds:, clock: DEFAULT_CLOCK, sleeper: DEFAULT_SLEEPER)
  ours = [own_pid.to_s, acquirer_pid.to_s]
  watching = dirs.dup
  superseded = false
  loop do
    watching.select! do |dir|
      next false unless Dir.exist?(dir)
      owner = read_owner(dir)
      mine = owner && ours.include?(owner["pid"])
      superseded ||= !mine
      mine
    end
    return { reason: superseded ? "superseded" : "released", watching: [] } if watching.empty?

    now = clock.call
    return { reason: "expired", watching: watching } if now >= hold_until

    sleeper.call([poll_seconds, hold_until - now].min)
  end
end
```

(Exact shape is the implementer's; the three exit reasons, the "ours"
set, and leaving the dirs untouched on expiry are the contract. When some
dirs were released and others superseded, report `superseded`.)

#### 3. Header comment
**File**: `skills/wurk:kit/scripts/lib/lock.rb`
**Changes**: Add a short paragraph to the module header: the recorded pid
must be a process whose lifetime is the hold - the session for a
session-held lock, the gate supervisor for `gate_run.rb`, the keeper for
an `acquire --hold-seconds` hold - because `probe` trusts it and nothing
else.

#### 4. Unit tests
**File**: `skills/wurk:kit/scripts/test/lock_test.rb` (`LockLibTest`)
**Changes**: New tests, all with `Dir.mktmpdir`, `FakeClock` and
`RecordingSleeper` (both already in the file), no real sleeping:
- `test_rewrite_owner_pid_preserves_hold_until` - write an owner with
  `hold_until`, rewrite the pid, `read_owner` still carries `hold_until`.
- `test_keep_returns_released_when_every_dir_is_removed` - sleeper removes
  the dir on its first call; result reason `released`.
- `test_keep_treats_the_acquirer_pid_as_ours_until_rewritten` - owner pid
  starts as `acquirer_pid`, is rewritten to `own_pid` on the first sleep,
  the dir is removed on the second; the loop does not exit before the
  removal and reports `released`.
- `test_keep_drops_a_dir_whose_owner_has_no_pid` - an owner file with no
  `pid` key is not ours (reason `superseded`), pinning why Phase 2 must
  seed the acquirer pid before spawning.
- `test_keep_returns_superseded_when_another_holder_owns_the_dir` - the
  sleeper releases and re-acquires the dir under a third pid; reason
  `superseded`.
- `test_keep_expires_at_hold_until_and_leaves_the_lock_in_place` - clock
  passes `hold_until`; reason `expired`, the dir and owner file are
  untouched, and a following `probe` with the owner pid set to a
  `DeadPid.obtain` pid reports `dead_holder_pid` (the expired keeper's
  exit is what makes it clearable).
- `test_keep_never_sleeps_past_hold_until` - the sleeper records
  durations; none exceeds the remaining lease.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb`
- [x] The new keeper tests are green:
      `/usr/bin/ruby skills/wurk:kit/scripts/test/lock_test.rb -n /keep|hold_until/`
- [x] `lib/lock.rb` still requires nothing but stdlib and names no `Sh` or
      `Envelope`: `grep -nE 'Sh\.|Envelope|require_relative' skills/wurk:kit/scripts/lib/lock.rb`
      prints nothing
- [x] No existing test changed expectation: `git diff main -U0 -- skills/wurk:kit/scripts/test/lock_test.rb | grep -c '^-[^-]'` prints `0`

#### Manual Verification:
- [ ] The new header paragraph and `Lock.keep` comment read correctly to
      someone who knows only the old owner-file shape
- [ ] No regressions in related features: `campaign_state_test.rb` and
      `gate_run_test.rb` untouched and green

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: `acquire --hold-seconds` and `lock.rb keep`

### Overview
Wire the keeper into the CLI, test both acceptance criteria with real
processes, and document it in the kit reference in the same commit.

### Changes Required:

#### 1. CLI
**File**: `skills/wurk:kit/scripts/lock.rb`
**Changes**:
- `require "rbconfig"`, `require_relative "lib/sh"`; add
  `SELF_PATH = File.expand_path(__FILE__)` (as `gate_run.rb:67` does) and
  `KEEPER_POLL_SECONDS = 2`.
- `SUBCOMMANDS` gains `keep`; `usage` lists it.
- `acquire`: new `--hold-seconds N` (Integer). Usage error (exit 2, via
  `usage_error!` with a hint) when it is not positive, or when `--pid` is
  also given ("a keeper-held lock's pid is the keeper's; pass one or the
  other"). `ACQUIRE_USAGE` gains `[--hold-seconds N]`.
- `build_owner`, when `--hold-seconds` is given, adds
  `hold_until = (now + N).utc.iso8601` AND seeds
  `pid = Process.pid.to_s` (the acquiring CLI), exactly as `gate_run.rb`
  seeds its lock owner (`gate_run.rb:171`). Without the seed the owner
  file has no pid during the spawn-to-rewrite window and the keeper would
  read its own lock as not ours (Key Discoveries).
- After `Lock.acquire_all` succeeds with `--hold-seconds`:
  ```ruby
  keeper_argv = [RbConfig.ruby, SELF_PATH, "keep",
                 *result[:locks].flat_map { |l| ["--dir", l[:dir]] },
                 "--acquirer-pid", Process.pid.to_s,
                 "--hold-until", owner["hold_until"],
                 "--poll-seconds", KEEPER_POLL_SECONDS.to_s]
  keeper_pid = Sh.spawn_detached(keeper_argv, out_path: File::NULL)
  result[:locks].each { |l| Lock.rewrite_owner_pid(l[:dir], keeper_pid) }
  ```
  `result[:locks]` carries the concrete slot dir (`slot-N`), not the pool,
  so the keeper watches what was actually taken. Each `acquired[].owner`
  in the envelope shows the keeper pid; `data.keeper_pid` and
  `data.hold_until` are set; `env.commands` gets `Sh.render(keeper_argv)`.
  A `SystemCallError` from the spawn releases every lock just taken
  (`Lock.release(..., force: true)`, reverse order) and blocks
  `keeper_spawn_failed` - a hold with no keeper would record the CLI's pid,
  which is dead the moment the CLI exits.
- `--dry-run` with `--hold-seconds`: spawns nothing, lists the keeper
  command (with a placeholder dir for a slot pool, as the existing dry-run
  does) and reports `data.hold_until`.
- New `run_keep`: `--dir DIR` (repeatable, at least one),
  `--acquirer-pid N`, `--hold-until ISO` (parsed with `Time.iso8601`;
  unparseable is a usage error), `--poll-seconds N` (default
  `KEEPER_POLL_SECONDS`). Calls `Lock.keep(dirs, own_pid: Process.pid, ...)`
  and emits an envelope with `data.reason` and `data.watching` (to
  `/dev/null` in practice, but the contract holds). Under `--dry-run` it
  reports the dirs it would watch and returns at once. Comment it as not
  meant to be run by hand, as `gate_run.rb supervise` is.
- Header comment: replace "No manifest, no Sh" with: no manifest; its one
  shell-out is the keeper spawn, through `Sh.spawn_detached`.

#### 2. CLI tests with FakeSh
**File**: `skills/wurk:kit/scripts/test/lock_test.rb` (`LockCliTest`)
**Changes**: `setup` installs a `FakeSh` (`Sh.runner = @fake`), `teardown`
resets it. New tests:
- `test_acquire_with_hold_seconds_spawns_one_keeper_and_records_its_pid` -
  one `detached_calls` entry, its argv is `lock.rb keep` with the lock's
  `--dir`, `--acquirer-pid` equal to this process, and `--hold-until`
  equal to the owner file's `hold_until`; `out_path` is `File::NULL`; the
  owner file's `pid` and `data.keeper_pid` are the fake's returned pid.
- `test_acquire_with_hold_seconds_hands_the_keeper_every_lock_including_the_slot_taken`
  - `--gate-lock` plus `--slots-dir --slots 2` with `slot-1` pre-taken;
  the keeper argv names the gate dir and `slot-2`, and both owner files
  carry the keeper pid.
- `test_acquire_with_hold_seconds_and_pid_is_a_usage_error` (exit 2,
  nothing created).
- `test_acquire_hold_seconds_dry_run_spawns_nothing` - no dir, no
  `detached_calls`, keeper command listed in `commands`.
- `test_acquire_without_hold_seconds_spawns_no_keeper` - existing
  behavior pinned: no `detached_calls`, no `hold_until` in the owner.
- `test_acquire_with_hold_seconds_seeds_the_acquirer_pid_before_spawning`
  - a `FakeSh` whose `spawn_detached` reads the owner file at call time
  (or records it) sees `pid` equal to this process; after the call the
  owner carries the keeper pid.
- `test_acquire_keeper_spawn_failure_releases_every_lock_and_blocks` -
  `FakeSh` gains an opt-in `spawn_detached` failure (for example
  `FakeSh#fail_detached!(Errno::ENOENT)`, raised on the next call); with
  `--gate-lock` plus a slot pool, the envelope blocks
  `keeper_spawn_failed`, exit 1, and neither lock dir remains.
  **File**: `skills/wurk:kit/scripts/test/support/fake_sh.rb` gets that
  one method; no existing behavior changes.

#### 3. Real-process tests for the acceptance criteria
**File**: `skills/wurk:kit/scripts/test/lock_test.rb` (new class
`LockKeeperProcessTest`)
**Changes**: `Sh.runner = nil` (the real runner). Each test starts the
acquire as its own process with `Process.spawn(RbConfig.ruby, LOCK_RB,
"acquire", ..., out: env_path)` and `Process.wait`s it, so the acquiring
process - standing in for the tool call inside the conductor's session -
is dead before any assertion. `teardown` kills any keeper pid a test left
alive and removes the tmpdir. Bounded waits poll `Process.kill(0, pid)`
every 0.1s up to 10s (five keeper polls of headroom, since each test
boots two interpreters); no unbounded sleep. If these tests are ever
flaky, look first at this margin and at the pid seed above.
- `test_worker_lock_outlives_the_acquiring_process` (acceptance 1) -
  acquire `--gate-lock D --hold-seconds 60`; after the acquirer has exited,
  `data.keeper_pid` differs from the acquirer's pid, `Lock.probe(D)` is
  `holder_alive: true, stale: false`, and `lock.rb clear --dir D` blocks
  `lock_not_provably_stale`. Then `lock.rb release`, and the keeper exits
  within the bounded wait.
- `test_killed_keeper_leaves_a_provably_stale_lock` (acceptance 2) - same
  acquire, `Process.kill("KILL", keeper_pid)`, wait for it to go; `probe`
  reports `dead_holder_pid` and `clear` removes the dir.
- `test_expired_hold_leaves_a_provably_stale_lock` (acceptance 2, the
  crashed-worker case) - `--hold-seconds 1`; the keeper exits by itself
  inside the bounded wait, the dir is still there, `probe` reports
  `dead_holder_pid`, `clear` removes it.
- `test_session_pid_lock_reads_stale_when_the_session_dies` - the bug,
  pinned as the contrast: a stand-in "conductor" is
  `Process.spawn(RbConfig.ruby, "-e", "sleep")`; acquire with
  `--pid <conductor>`; kill and reap the conductor; `probe` reports
  `dead_holder_pid`. Its comment says why a worker hold must not do this.

`LOCK_RB` is the absolute path of `lock.rb`. The spawned processes inherit
the suite's guarded `HOME` (`test/support/home_guard.rb`), so
`UserConfig.require!` reads no real machine config.

#### 4. Kit reference
**File**: `skills/wurk:kit/REFERENCE.md`, section "`lock.rb`: the
mkdir-mutex"
**Changes**:
- Intro: "No manifest and no `Sh`" becomes no manifest, and one shell-out
  (the keeper spawn, through `Sh.spawn_detached`).
- "The owner file": add `hold_until` to the key list, and a paragraph on
  what `pid` must be - a process whose lifetime is the hold - with the
  three sources (the session for its own hold, `gate_run.rb`'s supervisor,
  the keeper), and why a subagent's `$PPID` is none of them.
- "Subcommands": `acquire` gains `--hold-seconds N` (the keeper, its exit
  reasons, what an expired lease leaves behind, mutually exclusive with
  `--pid`); new `keep` entry marked internal.
- "`data` keys": `acquire` gains `data.keeper_pid` and `data.hold_until`
  (present only with `--hold-seconds`); `keep` gets `data.reason` and
  `data.watching`.
- "Exit codes": `acquire` also blocks `keeper_spawn_failed`.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb`
- [ ] The acceptance tests are green:
      `/usr/bin/ruby skills/wurk:kit/scripts/test/lock_test.rb -n /LockKeeperProcessTest/`
- [ ] The FakeSh CLI tests are green:
      `/usr/bin/ruby skills/wurk:kit/scripts/test/lock_test.rb -n /hold_seconds|keeper/`
- [ ] The contract test still passes with `lock.rb` now spawning (it goes
      through `Sh.spawn_detached`, so the process-creation scan stays
      clean): `/usr/bin/ruby skills/wurk:kit/scripts/test/contract_test.rb`
- [ ] No keeper is left running after the suite:
      `pgrep -f 'lock.rb keep'` prints nothing once the suite exits
- [ ] The reference documents the new surface:
      `grep -n "hold-seconds\|hold_until\|keeper_pid\|keeper_spawn_failed" skills/wurk:kit/REFERENCE.md`
      finds each term
- [ ] No existing test changed expectation: `git diff main -U0 -- skills/wurk:kit/scripts/test/lock_test.rb | grep -c '^-[^-]'` prints `0`
      (the `LockCliTest` setup/teardown edits add lines only)

#### Manual Verification:
- [ ] Manual Testing Steps 1-4 below behave as described
- [ ] The keeper survives closing the tmux window it was started from
      (Manual Testing Step 2) - the property the real-process tests can
      only approximate by letting the acquirer exit
- [ ] The reference's `pid` paragraph is clear on which of the three
      sources a caller should use, without reading the code
- [ ] No regressions in related features: `gate_run.rb start --gate-lock`
      still records the supervisor pid and releases on finish

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: Callers take worker locks through the keeper

### Overview
Move the worker's gate-semaphore instructions and the conductor's prose to
`--hold-seconds`, and say plainly which pid belongs to which holder.

### Changes Required:

#### 1. Worker block
**File**: `agents/blocks/gate-discipline.md` (the "Gate semaphore"
bullet), then regenerate `agents/wurk-repo-worker.md` with
`ruby skills/wurk:kit/scripts/build_agents.rb` (ADR-0019; commit the block
and the generated file together).
**Changes**: Replace "mkdir to acquire ... ALWAYS rmdir after your run"
with: take the locks the dispatch names with `lock.rb acquire` and
`--hold-seconds` set to the hold the dispatch names; never pass `--pid` -
your shell's parent is the conductor's session process, not you, so a pid
from it makes your lock live and die with the conductor's window; release
with `lock.rb release` after the run, pass or fail. The bounded-wait and
"never break another holder's lock" rules stay.

#### 2. Conductor skill
**File**: `skills/wurk:conductor/SKILL.md`
**Changes**:
- In "Take the mutex, then run the campaign" (around lines 193-203), one
  sentence after the `<session pid>` explanation: the session pid is right
  here because the conductor session is the holder; a lock taken on a
  worker's behalf never carries it, since subagents run in the same
  process - that is what `--hold-seconds` is for.
- In the concurrency passage that hands `lock.rb acquire` every lock (around
  lines 812-825): the conductor decides the hold as well as the caps -
  its Phase 0 gate measurement plus the commit's internal gate re-run, with
  margin - and relays it; an expired hold becomes clearable.
- In the dispatch template's "Gate-semaphore slot" (around lines
  2040-2045) and the resume rung that repeats it (around lines 1044-1049):
  the CONTENDING GATES wording names `--hold-seconds <N>` alongside the
  lock dirs.

#### 3. Conductor reference
**File**: `skills/wurk:conductor/REFERENCE.md`, "Owner-file discipline"
(around line 94)
**Changes**: `pid=<pid>` gains its rule: the pid of a process whose
lifetime is the hold - the conductor session for its own mutex, the keeper
`lock.rb acquire --hold-seconds` spawns for a worker's lock, the
supervisor for `gate_run.rb start`. Add `hold_until` to the listed fields
for a keeper-held lock.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb`
      (it includes `build_agents.rb --check`, so a stale generated agent
      turns it red)
- [ ] The worker instructions no longer tell anyone to mkdir or rmdir a
      lock by hand: `grep -n "mkdir to acquire\|rmdir after" agents/blocks/gate-discipline.md agents/wurk-repo-worker.md`
      prints nothing
- [ ] Every caller surface names the flag:
      `grep -ln -- "--hold-seconds" agents/blocks/gate-discipline.md agents/wurk-repo-worker.md skills/wurk:conductor/SKILL.md skills/wurk:conductor/REFERENCE.md`
      lists all four files
- [ ] Plain ASCII in the edited prose:
      `git diff main -- agents skills/wurk:conductor | grep '^+' | LC_ALL=C grep -n '[^ -~]'`
      prints nothing

#### Manual Verification:
- [ ] Read as a worker: the gate-semaphore bullet alone tells you which
      command to run, which flag to use, and why not `--pid`
- [ ] Read as a conductor: it is clear the campaign mutex keeps
      `--pid <session pid>` and worker holds do not
- [ ] The merge-time prose judge over `skills/**/SKILL.md` (ADR-0008,
      through `.claude/wurk/mr.md`) passes at `/wurk:mr`
- [ ] No regressions in related features: the conductor's other lock
      prose (fixed acquisition order, "never let workers break locks")
      is unchanged

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
- `lib/lock.rb`: `Lock.keep`'s three exit reasons, the acquirer-pid window,
  the never-past-the-lease sleep, and `hold_until` surviving
  `rewrite_owner_pid` - fake clock and sleeper, no processes (Phase 1).
- `lock.rb` CLI with `FakeSh`: the keeper argv, the owner rewrite, the
  slot dir handed to the keeper, the `--pid` conflict, dry-run, and no
  keeper without the flag (Phase 2).
- Real processes (Phase 2), the bead's acceptance: a worker lock outlives
  the acquiring process; a killed keeper and an expired hold are both
  provably stale and clearable; and the session-pid contrast that pins the
  original bug.
- Key edges: a slot pool (the keeper must watch `slot-N`, not the pool
  dir); release then immediate re-acquire by someone else (superseded, not
  kept); an owner file briefly missing (not ours).

### Manual Testing Steps:
1. In a scratch dir, `ruby skills/wurk:kit/scripts/lock.rb acquire
   --gate-lock /tmp/wu-jm7h-lk/gate-x --campaign c --bead b
   --hold-seconds 120`. `cat` the owner file: `pid` is `data.keeper_pid`,
   `hold_until` is two minutes out, and `ps -p <pid>` shows `lock.rb keep`.
2. Repeat step 1 from a Claude session in its own tmux window, then close
   that window. From another shell, `lock.rb status --dir .../gate-x`
   reports `holder_alive: true, stale: false`; `lock.rb clear` refuses.
3. `lock.rb release --dir .../gate-x --campaign c --bead b`; within a few
   seconds `ps -p <keeper pid>` shows nothing.
4. Acquire again with `--hold-seconds 5`, wait 10 seconds: the dir remains,
   `status` reports `dead_holder_pid`, `clear` removes it.

## Decisions

- **Direction: give the hold its own process (the keeper), not a second
  staleness signal.** The bug is that the recorded pid is the wrong
  process, not that pid liveness is the wrong test. `gate_run.rb` already
  proved the pattern (`gate_run.rb:206-216`). A keeper fixes both failure
  directions at once: the lock no longer dies with the conductor's window,
  and a crashed worker's lock no longer stays alive for as long as the
  conductor does - it expires at `hold_until`.
- **Expiry leaves the lock; it does not release it.** A keeper that removed
  its own lock at the lease could free a resource a slow-but-live gate is
  still using. Leaving a dead pid hands the decision to `lock.rb clear`
  and the conductor's existing verified-stale judgment
  (`skills/wurk:conductor/SKILL.md:818-825`).
- **One keeper per acquire call**, watching every lock that call took, so
  an all-or-nothing acquire has one liveness source.
- **`--hold-seconds` and `--pid` are exclusive.** Two pids would need a
  rule for which one `probe` believes.

## Open Questions

Non-blocking; each has the default this plan takes, so implementation can
proceed without an answer.

1. Should an expired lease report its own `staleness_reason` (say
   `hold_expired`, read from `hold_until` in the past plus a dead pid)
   so a human can tell "ran out of time" from "died"? Default: no - both
   are `dead_holder_pid`; `hold_until` is in the owner file for anyone who
   looks.
2. Should `lock.rb` have a `renew` (extend `hold_until`) for a hold that
   turns out longer than sized? Default: no; the conductor sizes the hold
   with margin, and an expired hold is only clearable, never cleared on its
   own.
3. Is the keeper worth an ADR (a new long-lived process type in the kit)?
   Default: no - it is `gate_run.rb`'s supervisor pattern reused, inside
   ADR-0006 and ADR-0015 as they stand; the kit reference documents it.
4. The consumer tracker's copy of this bug should be closed or annotated
   there once this lands. Default: left to that repo's operator; this repo
   does not write to it.

## References

- Bead: `wu-jm7h`
- Source code: `skills/wurk:kit/scripts/lib/lock.rb:36`, `:108-115`,
  `:222-241`, `:268-275`, `:319-331`; `skills/wurk:kit/scripts/lock.rb:122`,
  `:173-183`, `:268-299`; `skills/wurk:kit/scripts/gate_run.rb:165-173`,
  `:206-216`; `skills/wurk:kit/scripts/lib/sh.rb:246-252`
- Callers: `skills/wurk:conductor/SKILL.md:193-203`, `:812-825`,
  `:1044-1049`, `:2040-2045`; `skills/wurk:conductor/REFERENCE.md:94-103`;
  `agents/blocks/gate-discipline.md:53-57`
- Tests: `skills/wurk:kit/scripts/test/lock_test.rb`,
  `test/support/fake_sh.rb:79-87`, `test/support/dead_pid.rb`,
  `test/contract_test.rb:697-707`
- Prior plan: `docs/plans/260902-wu-4x9-long-gate-runner-and-lock-helper.md`
  (the lock helper and the supervisor pid rewrite)
- Related ADRs: `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`,
  `docs/adr/0015-sh-run-keeps-single-pid-kill-semantics.md`,
  `docs/adr/0016-discovery-claims-belong-to-bd.md`,
  `docs/adr/0019-agent-definitions-from-templates-and-blocks.md`,
  `docs/adr/0008-merge-time-judge-over-generic-skill-prose.md`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The new header paragraph and `Lock.keep` comment read correctly to
      someone who knows only the old owner-file shape
- [ ] No regressions in related features: `campaign_state_test.rb` and
      `gate_run_test.rb` untouched and green

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

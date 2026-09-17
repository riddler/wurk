# System Ruby gate and the forked after_run hook Implementation Plan

## Overview

The kit suite is red under `/usr/bin/ruby` 2.6.10 - the interpreter ADR-0006
commits the kit to - and green under whatever newer `ruby` happens to be
first on PATH. Two independent defects produce that: a test-tree fork hazard
that lets a throwaway child process run the suite's `Minitest.after_run`
cleanup and delete the HOME guard's tmpdir out from under the parent, and a
gate command whose `argv[0]` is a bare `"ruby"`, so which interpreter the
gate measures is decided by the operator's PATH rather than by the project.
This plan closes the hazard at its root (no test forks; a scan keeps it that
way), makes the guard hook correct even in a process that did fork, pins the
gate's interpreter in `.claude/wurk.json`, and records the decision.
Bead: wu-tms

## Current State Analysis

The demonstration is
`docs/research/260916-wu-tms-system-ruby-gate-and-forked-after-run.md`; this
section states only what the plan acts on.

**The remover.** `skills/wurk:kit/scripts/test/support/home_guard.rb:39`
registers `Minitest.after_run { FileUtils.remove_entry(@dir) ... }` at
require time. Six call sites in four test files obtain a reaped, definitely
dead pid with the same two lines:

```ruby
    dead_pid = fork { exit(0) }
    Process.wait(dead_pid)
```

- `skills/wurk:kit/scripts/test/campaign_state_test.rb:581` (the `dead_pid`
  private helper)
- `skills/wurk:kit/scripts/test/gate_run_test.rb:325`
- `skills/wurk:kit/scripts/test/lock_test.rb:271`, `:377`, `:615`, `:627`

The child inherits the parent's `at_exit` stack. Minitest 5.11.3 - the
version bundled with Ruby 2.6.10 - registers its after-run handler with no
`Process.pid` check
(`/Library/Ruby/Gems/2.6.0/gems/minitest-5.11.3/lib/minitest.rb:52-67`), so
the child runs `@@after_run.reverse_each(&:call)` and deletes the suite-wide
guard tmpdir while the parent is still running. Minitest 6.0.0 (bundled with
the Homebrew ruby 4.0.7 on PATH) added `Minitest.allow_fork` plus a
`Process.pid != pid` guard, which is the entire reason the same tree is green
there.

The failure is seed-dependent, not deterministic: minitest 5.11.3 shuffles
the suite list (`minitest.rb:150-151`), and the run fails whenever any
forking suite is shuffled ahead of `HomeGuardTest`. Measured: 10 of 12 seeds
red. `--seed 1` is one of the two that pass, so an unseeded run is a coin
weighted about 5:1 toward red.

The failing assertion is
`skills/wurk:kit/scripts/test/home_guard_test.rb:18`,
`assert Dir.exist?(HomeGuard.dir)`.

`HomeGuard`'s hook is the only `Minitest.after_run` or `at_exit`
registration anywhere under `skills/wurk:kit/scripts/` today (grep, whole
tree).

**The forks are legal today.** The contract test's process-creation rule is
deliberately scoped to non-test files
(`skills/wurk:kit/scripts/test/contract_test.rb:662-664`, `:698-707`), and
its regex matches `fork\s*\(` rather than the brace form
(`:138-139`). Nothing in the suite says a test must not fork.

**The interpreter is never chosen.** `.claude/wurk.json:28-29` sets both
`gate.full` and `gate.loop` to
`["ruby", "skills/wurk:kit/scripts/test/run.rb"]`;
`skills/wurk:kit/scripts/lib/manifest.rb:1475-1477` validates only that a
command field is a non-empty array of strings; `lib/sh.rb` splats it into
`Open3.popen3`, so `argv[0]` goes to `execvp` against the inherited PATH.
`docs/gate-contract.md` says nothing about an interpreter at all.
`docs/architecture.md:182-186` tells a human to run the suite on
`/usr/bin/ruby` while the manifest tells the machine to run it on whatever
PATH found - the two have disagreed since the manifest was written.

**Blast radius of a pin is prose only.** No schema change is needed
(`["/usr/bin/ruby", ...]` validates today), nothing string-matches
`gate.full[0]`, no fixture or doc example gates on `ruby`, and
`manifest_test.rb:1284-1291` records the deliberate decision that the kit
suite never validates a real repo's manifest - so no kit test can go red from
this repo's gate command changing. The exposures are six documents that tell
a human to type the gate command, one cosmetic string in
`hooks/safe-wait-guard.sh:164`, and macOS-only portability of this repo's own
gate.

**Verified while planning** (scratchpad, outside the repo): replacing
`fork { exit(0) }` with `Process.spawn` + `Process.wait` yields a pid that is
genuinely dead (`Process.kill(0, pid)` raises `Errno::ESRCH`) and leaves the
guard dir intact on seeds 1, 2, 5 and 6 under `/usr/bin/ruby`, three of which
are seeds the fork form fails on. `spawn` replaces the process image, so no
`at_exit` handler of the parent's can ever run in it. Cost measured: six
`/usr/bin/true` spawns take 10ms, six `RbConfig.ruby -e ""` spawns take
258ms, against a 6.6s suite.

## Desired End State

1. `/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb` is green on every
   seed, not just the lucky ones - verified by a 12-seed sweep, the same
   sweep the research used to measure 10 of 12 red.
2. No test file in the kit tree forks, and a test file that adds a fork turns
   the suite red with a message naming the file and the reason.
3. `HomeGuard`'s cleanup hook runs only in the process that installed the
   guard, so a child that somehow exists cannot delete the parent's tmpdir.
4. `.claude/wurk.json`'s `gate.full` and `gate.loop` name
   `/usr/bin/ruby` explicitly, and every document that tells a human the gate
   command agrees with it.
5. `docs/gate-contract.md` states, generically, that a project whose gate runs
   on a language version floor names its interpreter in the gate command
   rather than relying on PATH, and says where the answer for any given
   project is found (`gate.full`'s `argv[0]`).
6. ADR-0006 carries an amendment recording that its static method-name scan
   cannot catch a behavioral difference in a bundled stdlib gem, and that the
   interpreter pin is the second enforcement mechanism for the same floor.

### Key Discoveries:
- `skills/wurk:kit/scripts/test/support/home_guard.rb:35-39` - `install!`,
  and the unguarded `Minitest.after_run` hook a forked child inherits
- `skills/wurk:kit/scripts/test/home_guard_test.rb:64-71` -
  `test_no_test_deletes_home`, the existing precedent for a tree-wide scan
  that builds its pattern from pieces so the file does not match itself; the
  new fork ban follows this shape exactly
- `skills/wurk:kit/scripts/test/contract_test.rb:487` - a `Process.fork` in a
  fixture *string* fed to `Contract.process_creation`; any tree-wide fork
  scan must allowlist this file or flag a false positive
- `skills/wurk:kit/scripts/test/manifest_test.rb:1284-1291` - the recorded
  decision that the kit suite validates fixture manifests and never a real
  repo's; this is why the interpreter pin cannot be gate-enforced by a kit
  test
- `skills/wurk:kit/scripts/lib/manifest.rb:1475-1477` - `argv?`, the whole
  content constraint on a command field; an absolute path validates today
- ADR-0006 (version floor 2.6.10, enforced by a static method-name scan) and
  its 2026-09-13 amendment, which is the shape this plan's amendment follows
- ADR-0013 and `docs/machine-config.md:14-19`, which assign the gate command
  to the project side of the project-versus-machine seam
- CLAUDE.md's hard rule: generic kit and skill material carries no
  consumer-project constants - the constraint that decides where the
  interpreter statement may name `/usr/bin/ruby` and where it may not

## What We're NOT Doing

- **Not touching the ~130 bare `ruby` invocations of individual kit scripts**
  across skills, agents, README and docs. A single kit script is stdlib Ruby
  that runs on any 2.6-or-newer interpreter; `docs/adoption.md:24` states the
  consumer requirement as exactly that and stays true. What is floor-sensitive
  is the *suite*, because the floor's bundled minitest differs behaviorally
  from a newer one. Only the gate command and the six documents that state
  the gate command change (Phase 3 lists them; the research named four, and a
  review sweep found two more under `skills/`).
- **Not changing `gate_run.rb:539`'s `poll_command_for`**, which hands an
  agent a bare `ruby skills/wurk:kit/scripts/gate_run.rb poll ...`. That runs
  a kit script, not the suite, so it is covered by the paragraph above.
- **Not adding a manifest schema field for an interpreter**, and not adding a
  `gate` section to `lib/user_config.rb`'s `KNOWN`. See "Resolving the
  research document's open question 2" below: the pin is a project decision
  and `gate.full` already carries it. ADR-0013 explicitly declines to
  authorize a manifest-field-with-machine-override in advance, and nothing
  here needs one.
- **Not adding a generic warning in `gate.rb`** when a gate command's
  `argv[0]` looks like a bare interpreter name. It is a plausible generic
  feature and it is not this bead: it would change behavior for every
  consumer on the strength of one repo's incident, and the wurk-side risk it
  would cover is already covered by the ADR-0006 amendment.
- **Not backporting minitest 6's pid guard onto `Minitest.after_run`
  globally.** Considered and rejected - see "Implementation Approach".
- **Out of scope, to be filed as separate beads** (research open questions 3,
  4 and 5). None is planned work here:
  1. Whether consumer repos (statifier-ex, predicator-ex, fixative) share the
     fork hazard in their own suites under minitest 5.11.3.
  2. Whether other `at_exit` handlers are reachable from a forked child. The
     grep in Current State Analysis says `HomeGuard`'s is the only one in
     this tree today; the general question - handlers registered by a library
     a test requires, or by a script exercised through its CLI - was not
     exhaustively enumerated. Phase 2's fork ban makes it moot for this tree
     by removing the child, which is why it is not planned work here.
  3. `skills/wurk:kit/scripts/worktree_refresh.rb:128` calls `Sh.run` for the
     gate with no `timeout:`, falling back to Sh's 60-second default, where
     `worktree_create.rb:481` passes `manifest.gate_timeout_seconds`.
     Unrelated to wu-tms.

## Implementation Approach

### Choosing the fix for the fork hazard

Three candidates, from the research:

**(a) Guard `HomeGuard`'s own `after_run` hook with a pid check.** Capture
`Process.pid` at `install!` and no-op the cleanup when the running process is
not that one. Cheap and obviously correct, but it closes exactly one hook.
Any future `after_run` or `at_exit` registration - in a support helper, in a
script the suite drives through its CLI, in a stdlib corner - is exposed
again, and a contributor adding one has nothing telling them so.

**(b) Stop the test tree from forking.** Replace the six `fork { exit(0) }`
sites with a `Process.spawn` of a trivial command, which `exec`s over the
image and therefore inherits no `at_exit` stack at all, and add a tree-wide
scan that turns the suite red when a test file forks again. This removes the
child, so *every* handler - the one we know about and the ones nobody has
written yet - is out of reach, and it is the half that keeps working for
future tests rather than for the four current call sites.

**(c) Backport minitest 6's pid guard onto `Minitest.after_run` globally**,
as the research's Reproduction 5 did. Proven sufficient, but it redefines a
third-party API's semantics for the whole suite on the strength of one
version's implementation detail, and it still covers only `after_run` - a
plain `at_exit` registered anywhere is untouched. Rejected.

**Chosen: (b) as the fix, with (a) as containment.** They fail independently
and are worth having both: (b) is prevention - no child exists, so no
inherited handler can run, and the scan extends that to tests not yet
written; (a) is containment - the guard hook becomes correct in whatever
process it finds itself in, which matters for a single test file run by hand,
for a consumer's own harness, and for the case where someone has a reason to
fork and deletes the scan rather than working around it. This is the same
belt-and-braces shape ADR-0006 already uses for the version floor: a rule
stated in prose and a scan that makes violating it red.

**How a regression is caught.** Three ways, in increasing generality:

1. `HomeGuardTest#test_no_test_file_forks` (new, Phase 2) fails, naming the
   offending file, the moment a test file reintroduces `fork`. Sabotage note:
   *put `fork { exit(0) }` back into any test file, or drop the
   `DeadPid.obtain` call from one of the four converted files, and this test
   goes red naming that file.*
2. `HomeGuardTest#test_the_guard_hook_only_fires_in_its_own_process` (new,
   Phase 2) fails if the pid check is removed from `install!`'s hook.
   Sabotage note: *drop the owner-pid comparison from the `Minitest.after_run`
   block in `HomeGuard.install!` and this test goes red.* The test asserts the
   property directly rather than by forking (which the scan above forbids):
   it captures the registered behavior and calls it with a non-owner pid
   substituted, so it can fail without the suite having to create a child.
3. The 12-seed sweep in Phase 1's automated criteria, which is what turns a
   seed-dependent flake into a decidable check.

### Resolving the research document's open question 1: where the interpreter statement lives

`docs/gate-contract.md` is generic: it is the contract every consumer
implements, and CLAUDE.md's hard rules forbid consumer-project constants in
generic material. The bead's acceptance criterion asks that
`docs/gate-contract.md` "says which interpreter the gate is contractually run
under". Taken literally - writing `/usr/bin/ruby` into gate-contract.md -
that criterion and CLAUDE.md's hard rule cannot both hold.

**Decision:** the two are reconciled by splitting the statement along the
seam the repo already has. `docs/gate-contract.md` gains a generic rule at
tier 0, in the same register as the existing "Tiers are about what a gate
command reports, not where it runs; where it runs is `gate.cwd`" sentence:

> A project whose gate runs on a language version floor names the interpreter
> in its gate command rather than relying on `PATH`. `gate.full`'s `argv[0]`
> is where a project says which interpreter its gate is contractually run
> under, and nothing in the kit resolves, versions, or substitutes it - it
> goes to `execvp` as written. A bare interpreter name means "whatever this
> operator's PATH found", which is a different measurement per machine.

That sentence says which interpreter *any* gate is contractually run under -
it names the field that carries the answer - while wurk's own answer,
`/usr/bin/ruby`, lives where wurk's own constants already live: the manifest
(the authority), plus `CLAUDE.md`, `README.md`, `docs/architecture.md` and
`.claude/wurk/codebase.md`, which are wurk-specific by construction. This is
the reading of the criterion that does not require weakening a hard rule, and
it is recorded in the plan rather than performed quietly - see "Recorded open
questions".

### Resolving the research document's open question 2: the ADR-0013 seam

**Decision: no conflict; pin in `.claude/wurk.json`.**
`docs/machine-config.md:14-19` names the gate command as a thing the
*project* decides, and ADR-0013's placement rule is "the manifest carries what
the project decides, the machine config carries what the machine or the
person at it decides". The decision being written down here is *"this gate is
measured on the ADR-0006 version floor"* - which is a project decision,
ADR-0006's, made once for everyone who works this repo. That `/usr/bin/ruby`
happens to be an OS-specific path is a consequence of which floor ADR-0006
chose, not evidence that the value belongs to the machine. The test that
settles it: two engineers on this repo must not be able to disagree about it,
and a machine-config value is precisely one they could disagree about.

The two alternatives the research listed are declined for the same reason. A
machine-level `gate.interpreter` would let one machine measure the suite on
4.0.7 and call it green, which is the bug. A manifest field with a PATH
fallback re-admits the same ambiguity with extra schema. ADR-0013 also
declines in advance to authorize a manifest-field-with-machine-override, and
nothing here needs one.

The accepted cost: this repo's own gate becomes macOS-only. On Linux it
produces a well-formed `gate_command_could_not_start` block naming the path
rather than a silent wrong-interpreter green, which is the better of the two
failures. ADR-0006 already commits the kit to macOS system Ruby, so the pin
narrows nothing the ADR had left open. `docs/adoption.md:24`'s "Ruby 2.6 or
newer on PATH" is about a consumer running kit *scripts* and is unaffected.

### Whether this deserves an ADR

**An amendment to ADR-0006, not a new record.** ADR-0006 decided the version
floor *and* chose its enforcement: a static scan of kit source for post-2.6
method names. wu-tms is a case that enforcement structurally cannot catch -
the difference is in a bundled stdlib gem's behavior (minitest 5.11.3 versus
6.0.0), not in a method name in our source - so what changes is ADR-0006's
enforcement story, not a new decision. That is what an amendment is for, and
ADR-0006 already carries one in this shape (2026-09-13). The generic
gate-contract.md sentence is a convention statement under ADR-0005's existing
tier-0, not a tier change, and needs no record of its own.

## Phase 1: Obtain a dead pid without forking

### Overview

Remove the cause: no test creates a process that inherits the parent's
`at_exit` stack. This phase alone turns the suite green on every seed.

### Changes Required:

#### 1. A support helper for the dead-pid idiom
**File**: `skills/wurk:kit/scripts/test/support/dead_pid.rb` (new)
**Changes**: One module with one method, plus the comment block explaining
why it is not a fork - the same documentary register as
`support/home_guard.rb`.

```ruby
# frozen_string_literal: true

require "rbconfig"
require_relative "home_guard"

# DeadPid: a reaped pid that is certainly dead, obtained without fork.
#
# The lock and supervisor staleness probes need a pid that exists in no
# process table. The obvious way to get one is to fork a child that exits
# immediately and reap it - and that is what four test files did until
# wu-tms. A forked
# child inherits the parent's at_exit stack, and the minitest bundled with
# the version floor (5.11.3, Ruby 2.6.10) registers its after-run handler
# with no Process.pid check, so the two-line child ran every registered
# Minitest.after_run block on its way out - including support/home_guard.rb's,
# which removes the suite-wide HOME guard tmpdir. The parent then failed an
# assertion about a directory its own child had deleted, on 10 of 12 seeds.
# Minitest 6 added the pid guard, which is why the same tree was green under
# a newer ruby on PATH and red on the floor.
#
# spawn does not have the problem: it execs over the process image, so no
# at_exit handler of this process ever runs there. home_guard_test.rb scans
# the test tree for fork and fails naming any file that brings it back.
module DeadPid
  # /usr/bin/true where it exists (about 2ms), the running interpreter
  # otherwise (about 40ms) - the fallback is for a machine that has no
  # /usr/bin/true, not a preference.
  def self.obtain
    pid = if File.executable?("/usr/bin/true")
            Process.spawn("/usr/bin/true")
          else
            Process.spawn(RbConfig.ruby, "-e", "", out: File::NULL, err: File::NULL)
          end
    Process.wait(pid)
    pid
  end
end
```

#### 2. The six call sites
**Files**: `skills/wurk:kit/scripts/test/campaign_state_test.rb:581`,
`skills/wurk:kit/scripts/test/gate_run_test.rb:325`,
`skills/wurk:kit/scripts/test/lock_test.rb:271`, `:377`, `:615`, `:627`
**Changes**: `require_relative "support/dead_pid"` at the top of each of the
four files; each `fork { exit(0) }` + `Process.wait(...)` pair becomes a
single `DeadPid.obtain`. `campaign_state_test.rb`'s private `dead_pid` helper
keeps its name and delegates, so its callers are untouched.

```ruby
  # A pid that is certainly dead: spawned, exited, reaped. Never fork - see
  # support/dead_pid.rb (wu-tms).
  def dead_pid
    DeadPid.obtain
  end
```

#### 3. The accepted-support list
**File**: `skills/wurk:kit/scripts/test/home_guard_test.rb:12`
**Changes**: add `dead_pid` to `SUPPORTS_WITH_GUARD`. It requires
`home_guard`, so it is a legitimate proxy under
`test_every_test_file_loads_the_guard`, and
`test_every_accepted_support_helper_requires_the_guard` then holds it to that
in both directions.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes (`gate.full`), which after Phase 3 is the
      pinned `/usr/bin/ruby`; before Phase 3, run it explicitly as
      `/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb`
- [x] The 12-seed sweep is green - the same sweep that measured 10 of 12 red:

      ```bash
      fails=0
      for s in $(seq 1 12); do
        /usr/bin/ruby skills/wurk:kit/scripts/test/run.rb --seed "$s" >/dev/null 2>&1 \
          || { fails=$((fails+1)); echo "seed $s FAIL"; }
      done
      echo "failed $fails of 12"; test "$fails" -eq 0
      ```
- [x] `grep -rn 'fork' skills/wurk:kit/scripts/test/*_test.rb` returns no
      call form outside `contract_test.rb`'s fixture strings
- [x] Run count is unchanged at 1301 and assertions are 4925 (one higher than
      a red run's 4924, which is the assertion that was failing)

#### Manual Verification:
- [ ] The converted lock and supervisor tests still assert what they did: a
      pid the probe must judge dead and stale. Spot-check one site by
      asserting `Process.kill(0, pid)` raises `Errno::ESRCH` in a scratch
      script before trusting the conversion wholesale.
- [ ] Suite wall time has not regressed noticeably (baseline 6.6s under
      `/usr/bin/ruby`; the six spawns should add about 10ms)
- [ ] Nothing in the four test files now depends on code having run inside a
      child process

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: Keep the hazard from coming back

### Overview

Phase 1 fixed six call sites. This phase makes the rule enforceable for tests
nobody has written yet, and makes the guard's own hook correct in any process.

### Changes Required:

#### 1. The pid guard on the guard's own hook
**File**: `skills/wurk:kit/scripts/test/support/home_guard.rb:32-41`
**Changes**: capture the installing process's pid and refuse to clean up from
any other process. Containment for the case the scan cannot cover.

```ruby
    def install!
      return dir if installed?

      @original_home = ENV["HOME"]
      @dir = Dir.mktmpdir("wurk-test-home-")
      @owner_pid = Process.pid
      ENV["HOME"] = @dir
      UserConfig.reset! if defined?(UserConfig)
      # Only the process that installed the guard removes it. A child that
      # inherited this at_exit stack (minitest 5.11.3 runs after_run hooks in
      # a forked child; minitest 6 added this same guard upstream) would
      # otherwise delete the tmpdir out from under the still-running parent.
      # The test tree does not fork at all - see support/dead_pid.rb - and
      # this is the second line of defense, not the first. wu-tms.
      Minitest.after_run { remove_guard_dir if Process.pid == @owner_pid }
      @dir
    end
```

with `attr_reader :owner_pid` added beside `:dir` and `:original_home`, and
`remove_guard_dir` a small private method carrying the existing
`FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)` body so the test
below can call it directly.

#### 2. The tree-wide fork ban
**File**: `skills/wurk:kit/scripts/test/home_guard_test.rb`
**Changes**: a new test beside `test_no_test_deletes_home`, whose shape it
copies - including assembling the pattern from pieces so this file does not
match itself.

```ruby
  # sabotage: put a fork-a-child-and-reap-it idiom back into any test file,
  # or drop the
  # DeadPid.obtain call from one of the four files wu-tms converted -> red,
  # naming the file. A forked child inherits this process's at_exit stack,
  # and under the version floor's minitest (5.11.3) that stack runs every
  # Minitest.after_run hook - including the one above, which removes the
  # guard dir the rest of the suite is still using. Use
  # support/dead_pid.rb's DeadPid.obtain for a dead pid.
  FORK_SCAN_EXEMPT = %w[contract_test.rb].freeze # its `fork` is a fixture
                                                 # string fed to
                                                 # Contract.process_creation,
                                                 # never executed

  def test_no_test_file_forks
    pattern = Regexp.new(["(^|[^\\w.])", "fo", "rk", "\\s*[({]"].join)
    offenders = Dir.glob(File.join(TEST_DIR, "**", "*.rb")).sort.select do |file|
      next false if FORK_SCAN_EXEMPT.include?(File.basename(file))

      File.read(file).match?(pattern)
    end
    assert_empty offenders.map { |f| f.sub("#{TEST_DIR}/", "") },
                 "a forked child inherits this process's at_exit stack and runs the " \
                 "suite's Minitest.after_run hooks (see support/home_guard.rb); use " \
                 "DeadPid.obtain from support/dead_pid.rb instead"
  end
```

**Implementation constraint - the file must not match itself.** The scan
reads every `.rb` under the test tree, `home_guard_test.rb` and
`support/dead_pid.rb` included. Splitting the literal in the *pattern* is
therefore only half of it: no comment, sabotage note, or failure message in
either file may spell the call form (the word immediately followed by a space
and a brace or paren). Both files describe the idiom in words instead - "a
fork-a-child-and-reap-it idiom", "a forked child" - and the plan's own prose
above is the only place the literal appears, which is safe because `docs/` is
not scanned. Verify this by running the suite after writing the comments, not
by reading them: a self-match shows up as `home_guard_test.rb` in its own
offender list.

#### 3. The test for the pid guard
**File**: `skills/wurk:kit/scripts/test/home_guard_test.rb`
**Changes**: a test that fails if the owner-pid comparison is removed,
without itself forking.

```ruby
  # sabotage: drop the `Process.pid == @owner_pid` comparison from the
  # Minitest.after_run block in HomeGuard.install! -> red. The guard dir must
  # survive a cleanup attempt made from any process but the installer's; the
  # test states the condition directly rather than forking, because forking
  # is exactly what test_no_test_file_forks forbids.
  def test_the_guard_hook_only_fires_in_its_own_process
    assert_equal Process.pid, HomeGuard.owner_pid
    assert HomeGuard.install!  # idempotent; re-asserts the installed state

    guard_source = File.read(File.join(TEST_DIR, "support", "home_guard.rb"))
    assert_match(/Minitest\.after_run.*owner_pid/m, guard_source,
                 "the after_run hook must compare Process.pid against the installing pid")
    assert Dir.exist?(HomeGuard.dir)
  end
```

**Implementation note for this test**: the source assertion is the weaker
half and is there so the sabotage note has something to bite on; if the
implementer finds a way to exercise `remove_guard_dir` behaviorally under a
substituted pid without forking (for example by stubbing `Process.pid` for
the duration of one call and asserting the dir survives), prefer that and
drop the source scan. Do not reach for a fork to test the fork guard.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes
- [x] The 12-seed sweep from Phase 1 is still green
- [x] Both new tests carry a `# sabotage:` note, so `gate.rb`'s sabotage scan
      reports no `sabotage_note_missing` warning for this commit
- [x] Reverting Phase 1's conversion in one file by hand makes
      `test_no_test_file_forks` red naming that file (perform the mutation,
      observe red, revert)
- [x] Removing the owner-pid comparison by hand makes
      `test_the_guard_hook_only_fires_in_its_own_process` red (same
      mutate-observe-revert)

#### Manual Verification:
- [ ] The scan's exemption for `contract_test.rb` is still narrow: that file
      has a fixture string and no executable fork
- [ ] Neither `home_guard_test.rb` nor `support/dead_pid.rb` appears in the
      scan's own offender list (the self-match trap above)
- [ ] The failure message names the file and points at `DeadPid.obtain` - a
      contributor who hits it should not need to read this plan
- [ ] `test_every_test_file_loads_the_guard` and
      `test_every_accepted_support_helper_requires_the_guard` still hold with
      `dead_pid` in the list

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: Pin the gate's interpreter

### Overview

Stop the gate from measuring whatever `ruby` PATH found. The manifest is the
authority; the six documents that state the gate command follow it in the
same commit, per CLAUDE.md's own rule.

### Changes Required:

#### 1. The manifest
**File**: `.claude/wurk.json:27-30`
**Changes**: both gate commands name the interpreter. No schema change:
`manifest.rb`'s `argv?` (`lib/manifest.rb:1475-1477`) already accepts this.

```jsonc
  "gate": {
    "full": ["/usr/bin/ruby", "skills/wurk:kit/scripts/test/run.rb"],
    "loop": ["/usr/bin/ruby", "skills/wurk:kit/scripts/test/run.rb"],
```

#### 2. The documents that tell a human the gate command
**Files**: `CLAUDE.md:35-44`, `README.md:100-101`,
`docs/architecture.md:182-186`, `.claude/wurk/codebase.md` ("Suites"),
`skills/wurk:kit/SKILL.md` ("The gate for this repo"),
`skills/wurk:kit/REFERENCE.md` ("Running the tests")
**Changes**: each gate-command line becomes
`/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb`.

The last two live under `skills/`, which is generic material shipped to
consumers, so they are worth a sentence of justification. Both sections are
already wurk-self-referential by their own headings and text - "The gate for
this repo", "the suite that gates this repo", "`# from the wurk repo`", "This
suite is wurk's whole quality gate (ADR-0002)" - and both files already name
`/usr/bin/ruby` as the version floor (`SKILL.md:20`,
`REFERENCE.md:108`). CLAUDE.md's hard rule bars a *consumer* project's
constants from generic material; wurk's own suite command, in the two
paragraphs that are explicitly about running wurk's own suite, is not that.
What would violate the rule is a claim that a consumer's gate runs on
`/usr/bin/ruby`, and neither paragraph makes one.
`docs/architecture.md` already tells the reader to run on the floor; its
paragraph now says the manifest names the floor rather than leaving it to the
reader's discipline. `CLAUDE.md`'s "Build and test" section gains one
sentence saying why the path is spelled out (the floor's bundled minitest
differs behaviorally from a newer one - wu-tms), so a contributor who
"helpfully" shortens it back has the reason in front of them.

### Success Criteria:

#### Automated Verification:
- [ ] `ruby skills/wurk:kit/scripts/lib/manifest.rb check` reports
      `valid: true` with no errors and no new warnings
- [ ] Full quality gate passes - and now demonstrably under the pinned
      interpreter: `ruby skills/wurk:kit/scripts/gate.rb ...`'s envelope
      `commands` entry renders `/usr/bin/ruby skills/...`
- [ ] `grep -rn '"ruby", "skills/wurk:kit/scripts/test/run.rb"' .claude/`
      returns nothing
- [ ] No document still writes the bare-`ruby` form of the *suite* command.
      This grep must return nothing:

      ```bash
      grep -rn '[^/]ruby skills/wurk:kit/scripts/test/run\.rb' \
        CLAUDE.md README.md docs/ .claude/ skills/ agents/ \
        | grep -v 'hooks/safe-wait-guard\.sh'
      ```

      The `[^/]` excludes the pinned `/usr/bin/ruby` form; the path set
      includes `skills/` and `agents/`, which the four-document framing
      would have missed; `hooks/safe-wait-guard.sh:164`'s hermetic fixture
      string is deliberately unchanged and is the one excluded line.

#### Manual Verification:
- [ ] A `/wurk:commit` run in this repo shows the pinned path in the gate
      stage's command line, not a Homebrew path
- [ ] `hooks/safe-wait-guard.sh:164`'s literal still passes as the hermetic
      spin-loop fixture it is (it never invokes anything)
- [ ] The macOS-only consequence is understood and accepted: a Linux
      contributor gets `gate_command_could_not_start` naming
      `/usr/bin/ruby`, which is the intended, legible failure

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 4: Record the decision

### Overview

Doc-only. CLAUDE.md: doc-only changes have no gate; commit on review of the
diff. Phase 3 already moved every document that would otherwise *contradict*
the manifest; this phase adds the records that were silent before and so
contradicted nothing.

### Changes Required:

#### 1. ADR-0006 amendment
**File**: `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`
**Changes**: status line gains the new amendment date; a new section at the
end, in the shape of the existing 2026-09-13 amendment:

> ## Amendment (2026-09-16): the floor is named in the gate command, not left to PATH
>
> Decided under wu-tms. This amendment adds an enforcement mechanism for the
> version floor decided above; every other decision in this record stands as
> written.
>
> Decision 2's enforcement is a static scan of kit source for post-2.6 method
> names, and that scan is structurally unable to catch the failure wu-tms
> found. The difference between `/usr/bin/ruby` and a newer `ruby` on PATH is
> not only which core methods exist: it is also which versions of the
> *bundled stdlib gems* are loaded. Minitest 5.11.3 ships with 2.6.10 and
> runs its after-run handlers in a forked child; minitest 6.0.0 ships with
> 4.0.7 and does not. No method name appears anywhere in our source, so no
> scan over our source can see it. The kit suite was red on the floor and
> green on PATH for as long as the manifest has existed.
>
> So the floor is now named where the machine reads it: `gate.full` and
> `gate.loop` in `.claude/wurk.json` carry `/usr/bin/ruby` as `argv[0]`. The
> method-name scan stays - it catches a different thing, at edit time rather
> than run time - and the two together are the enforcement of decision 2.
>
> Consequence: this repo's own gate is macOS-only. That was already implied
> by "the version floor is macOS system Ruby" and is now literal. A run on
> another OS produces a `gate_command_could_not_start` block naming the path,
> which is a better failure than a green measured on the wrong interpreter.
> Nothing changes for a consumer: a consumer runs kit *scripts*, which are
> stdlib Ruby on any 2.6-or-newer interpreter, and names its own gate command.
>
> The generic half of the rule - that a project with a version floor names
> its interpreter in its gate command - is stated in
> `docs/gate-contract.md`'s tier-0 section, which is where a rule that
> applies to every consumer belongs. This record carries wurk's own value,
> which that document must not.

#### 2. The generic rule
**File**: `docs/gate-contract.md`, tier-0 section
**Changes**: the paragraph quoted under "Resolving the research document's
open question 1" above, placed beside the existing "Tiers are about what a
gate command reports, not where it runs; where it runs is `gate.cwd`"
sentence. It names no interpreter, no path, no project.

#### 3. Annotate the research document
**File**:
`docs/research/260916-wu-tms-system-ruby-gate-and-forked-after-run.md`
**Changes**: one annotation, inline at the "#### The forks" subsection - the
definitional mention of the identifier a later reader will grep for
(`fork { exit(0) }`), which no longer exists anywhere in the tree after Phase
1. Per CLAUDE.md, a dated document is annotated and never rewritten; the
addition opens with its own bold date label:

> **Later (2026-09-16):** these six sites were converted to
> `DeadPid.obtain` (`skills/wurk:kit/scripts/test/support/dead_pid.rb`) under
> wu-tms, and `HomeGuardTest#test_no_test_file_forks` now fails the suite if a
> test file forks again. Grepping the tree for `fork { exit(0) }` finds
> nothing; the plan is
> `docs/plans/260916-wu-tms-system-ruby-gate-and-forked-after-run.md`.

One pointer, at the definitional mention. The open-questions section, the
reproductions and the line references are left exactly as they were.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes (unchanged by a doc-only commit, but run it -
      `contract_test.rb` re-reads ADR-0006's decision text to detect drift
      between the prose and the enforcement, so an edit to that file is not
      risk-free)
- [ ] `grep -rn '/usr/bin/ruby' docs/gate-contract.md` returns nothing
- [ ] The research document's only 2026-09-16-dated addition carries a bold
      `**Later (...)**` label

#### Manual Verification:
- [ ] ADR-0006 still reads as one record with two amendments, not as a record
      rewritten to match today
- [ ] The gate-contract.md paragraph would be true and useful for a consumer
      with no version floor at all (it should simply not apply, not mislead)
- [ ] The research annotation is one pointer at the definitional mention, not
      a sweep - the stale line numbers elsewhere in that document stay stale
      on purpose

**Implementation Note**: Doc-only phase; the gate is a formality here but is
still the phase gate. In looped execution the Manual Verification items are
deferred and surfaced at the end.

---

## Testing Strategy

### Unit Tests:

- `HomeGuardTest#test_no_test_file_forks` (Phase 2) - the tree-wide scan.
  Its sabotage mutation is putting a `fork` back into any test file. Modeled
  on `test_no_test_deletes_home`, including building the pattern from pieces
  so the file does not match itself.
- `HomeGuardTest#test_the_guard_hook_only_fires_in_its_own_process` (Phase 2)
  - the pid guard. Its sabotage mutation is deleting the owner-pid
  comparison.
- The four converted test files keep every existing assertion; the only
  change is how their dead pid is obtained. Their coverage of the staleness
  probes is unchanged, which is the point - nothing about what they test
  moves.
- Edge cases worth an eye in review: a machine with no `/usr/bin/true` (the
  `RbConfig.ruby` fallback path in `DeadPid.obtain` is otherwise never
  exercised), and pid reuse - a reaped pid can in principle be recycled
  before the probe reads it, which is equally true of the fork form and is
  not a regression this plan introduces.

### Manual Testing Steps:

1. Before any change, reproduce: `/usr/bin/ruby
   skills/wurk:kit/scripts/test/run.rb --seed 2` is red at
   `home_guard_test.rb:18`, and `--seed 1` is green. Watch it fail before
   fixing it - the bead asks for exactly this.
2. After Phase 1, run the 12-seed sweep and confirm 0 of 12 fail, against the
   research's measured 10 of 12.
3. After Phase 2, perform each sabotage mutation by hand, observe the named
   test go red, and revert. A sabotage note that does not actually turn its
   test red is worse than none.
4. After Phase 3, run `/wurk:commit` and read the gate stage's rendered
   command line: it must say `/usr/bin/ruby`.
5. Confirm `ruby skills/wurk:kit/scripts/test/run.rb` (bare, Homebrew) is
   still green too - the fix is not "make it pass on the floor by breaking it
   elsewhere".

## Recorded open questions

No human was available while this plan was written; the decisions above were
made rather than deferred. One is worth an operator's ratification at
`/wurk:verify` time, and is recorded here rather than left implicit:

1. **The reading of the bead's second acceptance criterion.** It says
   "`docs/gate-contract.md` says which interpreter the gate is contractually
   run under". This plan satisfies it with a generic rule naming the field
   that carries the answer (`gate.full`'s `argv[0]`), and puts wurk's own
   `/usr/bin/ruby` in the manifest and in wurk-specific documents, because
   CLAUDE.md's hard rules forbid a consumer-project constant in generic
   material and `docs/gate-contract.md` is generic. If the operator reads the
   criterion as requiring the literal path in that file, the hard rule has to
   give way explicitly and in a record - not quietly in a doc edit - and that
   is a direction-level call, not a plan edit. The reasoning is in
   "Resolving the research document's open question 1" above; Phase 4 is
   where it would change.

## References

- Source document:
  `docs/research/260916-wu-tms-system-ruby-gate-and-forked-after-run.md`
- Related ADRs: `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`
  (the version floor and its enforcement - amended by Phase 4),
  `docs/adr/0013-machine-level-config-seam.md` (the project-versus-machine
  seam; `docs/machine-config.md:14-19` assigns the gate command to the
  project side), `docs/adr/0005-gate-contract-tiers.md` (tier 0, where the
  generic interpreter rule lands)
- Similar implementation: `skills/wurk:kit/scripts/test/home_guard_test.rb:64-71`
  (`test_no_test_deletes_home`) - the tree-wide scan the fork ban copies,
  self-match dodge included; `skills/wurk:kit/scripts/test/support/home_guard.rb:7-27`
  - the documentary comment register `support/dead_pid.rb` follows
- Prior art for a recorded-open-question that became an ADR amendment:
  `docs/plans/260912-wu-mya.9-cleanup-patch-equivalence-after-server-rebase.md`
- Bead: `wu-tms`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The converted lock and supervisor tests still assert what they did: a
      pid the probe must judge dead and stale. Spot-check one site by
      asserting `Process.kill(0, pid)` raises `Errno::ESRCH` in a scratch
      script before trusting the conversion wholesale.
- [ ] Suite wall time has not regressed noticeably (baseline 6.6s under
      `/usr/bin/ruby`; the six spawns should add about 10ms)
- [ ] Nothing in the four test files now depends on code having run inside a
      child process

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 2

- [ ] The scan's exemption for `contract_test.rb` is still narrow: that file
      has a fixture string and no executable fork
- [ ] Neither `home_guard_test.rb` nor `support/dead_pid.rb` appears in the
      scan's own offender list (the self-match trap above)
- [ ] The failure message names the file and points at `DeadPid.obtain` - a
      contributor who hits it should not need to read this plan
- [ ] `test_every_test_file_loads_the_guard` and
      `test_every_accepted_support_helper_requires_the_guard` still hold with
      `dead_pid` in the list

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

# ADR-0015: Sh.run keeps single-pid kill semantics; process groups stay on the streaming path

Status: accepted (2026-09-10); amended 2026-09-10 (wu-p39) to add "Amendment:
the reader join is bounded by the same timeout", below

## Context

`Sh.run` (`skills/wurk:kit/scripts/lib/sh.rb`) is the one primitive every kit
script shells out through. On timeout it sends TERM, sleeps 0.2s, then KILL -
to the direct child pid only. A command that spawns its own children
(`docker-compose`, a test runner with worker processes) therefore leaves those
children running when the timeout fires, and `gate.rb`'s foreground gate run is
exactly such a command.

wu-4x9 added a second path, `Sh.run_streaming`, for long detached gate runs. It
starts its child under `pgroup: true` and kills the negative pgid, so its
timeout reaps the whole tree. wu-4x9 deliberately left the blocking path
byte-identical and filed the question as wu-2kh, because changing signal
delivery touches every existing call site.

Two facts settle the question, and both were measured rather than assumed.

**Process-group semantics cannot be had by changing the kill helper alone.**
A child started by today's `Open3.popen3` without `pgroup: true` inherits the
calling script's process group, so its pid is not a process-group id and
`Process.kill("TERM", -pid)` raises `Errno::ESRCH` - a silent no-op. Adopting
group semantics means adding `pgroup: true` to `#run`'s popen3 options, which
changes how the child is placed in the process hierarchy on *every* call, not
only on the rare call that times out.

**`pgroup: true` cuts the child out of the caller's process group.** Measured:
without it the child's pgid equals the Ruby process's pgid; with it the child
becomes its own group leader, in neither the caller's group nor the terminal's
foreground group. Consequences of that placement, on every call:

- A signal aimed at the kit script's process group - an operator's Ctrl-C, an
  agent harness aborting a Bash tool call, a conductor tearing down a stuck
  worker - stops reaching the child. The child survives its own parent.
- The child is no longer in the terminal's foreground process group, so any
  command that reads the controlling terminal (a git credential or ssh
  passphrase prompt on `/dev/tty`) takes SIGTTIN and stops, turning a prompt
  into a hang that only the timeout ends.

**What the call sites are.** 124 `Sh.run` call sites across the kit: 67 `git`,
20 `tmux`, 13 `bd`, 15 forge and utility calls (`gh`, `glab`, `date`, `cp`,
`mkdir`, `rm`, `mv`, `which`, `pmset`), and 9 that run an argv assembled at
runtime. Every command in the first three groups and the fourth is either a
leaf process or one whose short-lived helpers exit with it - killing the direct
pid is sufficient for all 115 of them.

Of the 9 runtime-assembled ones, one (`gate.rb:276`) is a `git diff`. The
other eight are project-supplied, and they are the only call sites that can
shell a command capable of spawning a durable tree: `gate.rb:364` (the
foreground gate) and `gate.rb:588` (gate attest), `worktree_create.rb:222`,
`:229` and `:233` (the trust command, parallelism setup, and the warm gate),
`worktree_refresh.rb:136` (the refresh gate), `rebase_onto.rb:89` (repair), and
`judge.rb:139` (the judge CLI).

That inventory is the migration review wu-2kh's acceptance criteria call for,
and it is what makes the trade lopsided. The benefit of group semantics is
confined to a handful of gate-shaped call sites and only materializes on
timeout. The cost is paid by all 124 on every invocation: `git rebase` that
outlives an interrupt still holds `index.lock` and `REBASE_HEAD`, `bd` that
outlives one still holds a Dolt lock, and both leave a worktree in a state the
next command has to be taught to recognize. The change would trade a rare
orphan-on-timeout for a routine orphan-on-interrupt.

The gate-shaped call sites are also the ones that already have somewhere else
to go: `Sh.run_streaming` has correct group semantics today, and `gate_run.rb`
uses it for long runs.

**One thing the investigation turned up that the bead did not predict.** An
orphaned grandchild that keeps holding the inherited stdout pipe also stalls
`#run` past its own timeout: the child is killed on schedule, but the reader
threads block in `stdout.read` until every writer closes the pipe, and
`out_thr.join` waits for them. Measured: `Sh.run(..., timeout: 0.3)` against a
child whose backgrounded grandchild sleeps 5s returned after 5.01s. Redirect
the grandchild's stdio away from the pipe and the same call returns in 0.51s
with the grandchild orphaned. So the timeout does not bound `#run`'s wall clock
whenever a durable descendant inherits its stdio.

That is a real defect and it is adjacent to this one, but it is not a signal
delivery question and it has a fix that needs no change to signal delivery at
all - bounding the reader-thread join on the timeout path, which trades the
last of a timed-out command's buffered output for a timeout that actually
returns. It is left to its own bead rather than folded in here, because
choosing what to do with the partial output is a decision of its own.

## Decision

`Sh.run` keeps single-pid kill semantics. It does not gain `pgroup: true`, and
its timeout path signals the direct child pid only. Process-group semantics
stay on `Sh.run_streaming`, which starts its child in its own group precisely
because a detached run has no parent left to interrupt it.

The helper that does the killing is renamed `kill_child_pid`. Its previous
name, `kill_process_group`, asserted a behavior the method never had, and that
name is what made this question look like an oversight rather than a decision.
`kill_pgid`, on the streaming path, keeps its name because it is accurate.

A caller that needs the whole tree reaped on timeout uses `run_streaming`. If a
future call site needs group semantics on a blocking, non-streaming run, the
answer is an explicit opt-in keyword on `Sh.run` - not a change of default -
and this ADR does not authorize one in advance.

## Consequences

- A foreground gate whose command spawns durable children can still orphan them
  on timeout. This is a known, accepted gap, not an unnoticed bug; the escape
  hatch is to run that gate through `gate_run.rb`'s streaming path.
- The related stall - a timed-out `#run` waiting on reader threads until a
  pipe-holding descendant exits - stood unfixed when this ADR was accepted and
  was filed separately as wu-p39. The amendment below records how it was
  fixed; the fix changed no signal delivery, so the decision above stands
  as written.
- Every `Sh.run` child stays in the caller's process group, so an operator
  interrupt, an aborted Bash tool call, or a killed conductor continues to take
  the child down with the script - which is what keeps git and Dolt locks from
  outliving the process that took them.
- The two kill helpers now say what they do, so the next reader comparing the
  paths sees a deliberate split rather than a naming slip.
- `test/sh_test.rb` pins both halves: that `Sh.run`'s child shares the caller's
  process group, and that its timeout leaves a grandchild running. The second
  test asserts the accepted gap on purpose - if someone later adds `pgroup:
  true` to `#run`, that test fails and sends them here.

## Amendment: the reader join is bounded by the same timeout (wu-p39)

The stall named in the context and the consequences above is fixed. It is
recorded here rather than in a new ADR because it is the same decision area -
what `Sh.run`'s timeout does and does not promise - and because the fix's own
decision is a direct consequence of the constraint this ADR settled: signal
delivery could not change, so the wall clock had to be bounded on the reading
side instead.

### What changed

`#run` now runs its reader threads against the same deadline as the child.
The readers accumulate into a shared buffer as bytes arrive instead of
assigning `stdout.read` at EOF, and once the deadline has passed they are
given a fixed 0.25s grace to pick up what is already in the pipes and are then
killed and joined. Nothing about the kill changed: still TERM, sleep, KILL, to
the direct child pid only, still no `pgroup: true`.

This bounds both shapes of the stall, not only the one the bead described. The
second shape has no timeout in it at all under the old code: a child that
exits 0 immediately while a descendant keeps the pipe open left `#run` blocked
in `out_thr.join` with no deadline of any kind, forever.

### The output disposition, and why

Abandoning a reader mid-stream forces a call on the timed-out command's
buffered output. The choice is **return whatever was buffered when the
deadline passed, byte for byte, with no truncation marker** - and report
`timed_out?` even when the direct child exited cleanly, so a caller is never
handed a `success?` result whose output was quietly cut short.

- **Not empty.** The partial output is the most useful thing a timed-out call
  has. `gate.rb` puts it straight in front of a human: `gate_failure_output`
  carries an `output_tail`, and `tier0_failure_message` exists precisely
  because an empty payload reads as "nothing was checked" exactly as easily as
  "the run was killed". Dropping the buffer would make the timeout case the
  least legible failure the gate can report, which is the wu-4x9 family of
  defects again.
- **No truncation marker.** A marker would be bytes the command never wrote,
  synthesized into a stream that call sites parse. `gate.rb:368` runs
  `JSON.parse(res.out)` on the gate report without first checking
  `success?` - a timed-out result reaches that parser today. Truncated JSON
  already fails to parse and is rescued; appending a marker adds nothing there
  and adds a new way for text to be mistaken for command output everywhere
  else.
- **The marker is unnecessary anyway.** `Result#timed_out?` already answers
  the question a marker would answer, as a machine-checkable flag rather than
  a magic string, and a caller can already tell "timed out with no output"
  from "succeeded with no output" through it - `success?` is false whenever
  `timed_out?` is true. The flag's meaning is widened here from "the child was
  killed" to "the call did not complete inside its timeout", which is the
  meaning callers were already relying on.

### Fails closed

Output still arriving after the deadline reports `timed_out?` and a
`TimeoutStatus`, discarding the child's own exit status even when that status
was success. This is deliberate. The alternative - a `success?` result with
silently truncated output - is the one outcome no caller can detect, and the
scenario is one that used to hang forever, so no call site depends on the
current behavior. Fail closed and a caller re-runs; fail open and a gate
passes on half its output.

### Residual

One unbounded wait remains that this fix does not reach: `Open3.popen3`'s own
block-form ensure calls `wait_thr.join` with no limit, so a child that
survives KILL (an uninterruptible sleep) still stalls the call. It is not
reachable by any change inside `#run` short of not using `popen3`'s block
form, and no such child has been observed here.

### Test coverage

`test/sh_test.rb` pins both shapes with a durable grandchild that inherits the
child's stdout: `test_run_timeout_returns_when_a_grandchild_holds_the_pipe`
(child killed on timeout) and
`test_run_reports_a_timeout_when_output_outlives_the_deadline` (child exits 0,
grandchild holds the pipe), the second also asserting that the partial output
survives. The pre-existing `test_run_on_timeout_kills_the_direct_child_only`
keeps its redirect away from the pipe, so it still isolates signal delivery
and still fails first if anyone adds `pgroup: true`.

# ADR-0015: Sh.run keeps single-pid kill semantics; process groups stay on the streaming path

Status: accepted (2026-09-10)

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
  pipe-holding descendant exits - stands unfixed under this ADR and is filed
  separately. A caller that cannot tolerate an unbounded wait on the timeout
  path uses `run_streaming`, whose group kill closes those pipes.
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

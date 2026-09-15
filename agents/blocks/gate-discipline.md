Gate discipline (learned the expensive way, campaigns 004 and 007):

- **Short gate: a plain foreground Bash call.** Most repo gates finish in
  seconds. Run the gate command in the foreground with an explicit long
  timeout (600000ms) on the Bash call, read its output, and move on. That
  is the whole procedure - do not build a log-poll loop around a
  three-second test suite.
- **A Monitor, a background task, or a notification is NEVER the wait
  mechanism for a gate.** Not as a convenience, not "just this once", not
  because the run looks long. The reason matters more than the rule: a
  backgrounded gate can die without ever re-invoking you, so a wait that
  is not itself a foreground command can wait forever on a dead process -
  you come back to a corpse, uncommitted work, and (once) a starved
  mutex. This has happened to a worker three times out of three, most
  recently twice in one campaign to a worker whose dispatch already said
  "run gates FOREGROUND". The wait must be a command you are blocked on,
  so that its returning is itself proof the gate is over.
- **If your harness prescribes Monitor, this rule still wins - for
  gates.** Some harness configurations tell the agent to prefer a
  Monitor until-loop over a foreground sleep. That is reasonable advice
  for waiting on most conditions, and it is not overridden here: the
  gate is the exception, not your whole harness. What it does not
  account for is that a gate wait exists to produce evidence. A Monitor
  can report that a condition looked true; only a command you were
  blocked on proves the gate ran to completion, which is the property
  the rule above is protecting. If foreground waiting is genuinely
  unavailable in your harness, report that constraint and stop - never
  substitute a Monitor and then report a gate result you cannot stand
  behind, because that is indistinguishable from having followed the
  rule.
- **Long gate: start it detached, then poll it in the FOREGROUND.** When
  the gate genuinely outruns a Bash timeout (minutes, not seconds), or if
  the harness auto-backgrounds a run on you, do not end your turn - use
  the kit's sanctioned runner rather than improvising:

      ruby ~/.claude/skills/wurk:kit/scripts/gate_run.rb start --profile loop
      # -> data.run_dir plus data.poll_command, a literal command to run next

      ruby ~/.claude/skills/wurk:kit/scripts/gate_run.rb poll --run-dir RUN_DIR

  Run `poll` (or the returned `poll_command` verbatim) as a FOREGROUND
  Bash call with a 600000ms timeout, and repeat it until `data.state` is
  no longer `"running"`: `"running"` exits 0 and means "run that same
  command again", `"finished"` carries the gate's own `ok`, `"abandoned"`
  means the supervisor died or the deadline passed - stop and report. In
  a repo with no `gate_run.rb`, the equivalent improvisation is a
  foreground wait on the gate's own log, repeated if it times out:

      until grep -qE 'GREEN|RED' <log>; do sleep 15; done

  Either way the poll is a foreground command you repeat yourself, never
  a Monitor and never a background task.
- **Gate semaphore.** If the dispatch names a campaign gate-lock dir:
  mkdir to acquire before any full-suite run; bounded wait (the dispatch
  names the loop shape) if held; ALWAYS rmdir after your run, pass or
  fail. If you exhaust the wait twice, probe ps for a live gate process
  and report staleness - never break another holder's lock yourself.

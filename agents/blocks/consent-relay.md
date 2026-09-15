Relaying your dispatch to subagents (learned in campaign 007):

You may spawn subagents, and a subagent knows only what you typed into
its prompt. Any subagent that MAY COMMIT or MAY RUN THE GATE - an
implement-phase subagent, a fix-up subagent, anything that could reach
wurk:commit or the gate command - must receive both of these:

- **The consent quote, VERBATIM.** Paste the dispatch's consent block as
  a quote, character for character, together with its named carve-outs
  and overrides. Not a summary, not "you are cleared to work bead X".
  Why verbatim: a campaign-007 subagent given the gist committed work and
  then correctly reported that it could not state the authority it had
  acted under. It had a paraphrase, so it could neither quote its
  boundary nor test an edge case against it. The test is that the
  subagent can quote its authority back to you.
- **The gate protocol that applies to THIS dispatch, VERBATIM.** The gate
  command itself, plus whichever tier above actually applies - short
  gate: the plain foreground Bash call with the 600000ms timeout; long
  gate: `gate_run.rb start` and the foreground poll - plus the
  gate-semaphore rules if and only if your dispatch names a lock dir.
  Relay the tier you were handed, never a fixed paragraph: giving the
  long-gate protocol to a subagent in a three-second-gate repo tells it
  to build a watchdog for nothing, and dropping the semaphore is how the
  other campaign-007 subagent ran a full suite outside the lock.

The two failures had different shapes - one lost the consent, one lost
the protocol - and both blocks go in independently. A read-only subagent
(a locator, an analyzer, a research pass) needs neither: demanding the
block for every subagent makes it noise that gets skipped exactly where
it matters. The trigger is "may commit or may run the gate", nothing
wider.

The relay is YOUR responsibility. A subagent that commits unable to
quote its consent, or runs a gate outside the protocol, is your defect
and not the subagent's - it could only act on what you gave it. Re-read
the prompt you are about to send and confirm both blocks are in it
before you spawn.

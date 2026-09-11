# ADR-0016: Discovery-time claims belong to bd; wurk ships no claim channel

Status: accepted (2026-09-10)

## Context

wu-b38 landed the conductor-side mitigation for a cross-session filing race
(`skills/wurk:conductor/SKILL.md`, the claim-and-probe step): a bead-id branch
probe plus a peer-session scan, run before a dispatch and again before a
discovery is filed, with the prose stating plainly that the probe narrows the
race and does not close it. Two conductors can probe in the same second, both
see nothing, and both dispatch.

wu-0uq is the other half. It asks for an advisory claim that "propagates faster
than a full dolt pull", and requires three questions be answered on the merits
rather than assumed: what carries the claim and by what path, how a claim
expires when the holder dies without releasing it, and whether anything ever
refuses to write on seeing one.

Ground truth measured in this repo on 2026-09-10 against bd 1.2.2:

- From inside a worktree, `bd where` resolves the beads dir to the primary
  checkout's `.beads`; `bd context` reports backend dolt, mode embedded, and
  `bd config show` reports `dolt.auto-commit = on`. Every worktree of this repo
  addresses one database file.
- Measured, not inferred: a `bd note` written on wu-0uq from this bead's
  worktree was read back by `bd show wu-0uq` from a sibling worktree
  (`wu-4x9-long-gate-runner`, a live peer worker's cwd) on the next command,
  with no pull, fetch, or sync step in between.
- bd already ships claim-shaped primitives. `bd update --claim` is an atomic
  per-bead claim (ADR-0012 builds the auto-walk on it). `bd merge-slot` is an
  exclusive slot with `status`, `metadata.holder`, and a priority-ordered
  `metadata.waiters` queue. `bd gate create --type=timer --timeout=2h` is a
  lease that expires, resolved by `bd gate check`. `bd kv` is a general side
  channel living in the same database. `bd find-duplicates` and
  `bd federation sync` exist.

## Decision

**wurk ships no claim channel, no claim field convention, and no shim. The
premise that a claim must outrun a dolt pull does not hold in the topology
where the incidents happen, and the primitive that is genuinely missing is a
tracker feature, not a workflow-layer one. The conductor's probe stays a
best-effort verification discipline and stays advisory.**

### 1. What carries the claim, and by what path

For peer sessions on one machine - which is every incident on record, including
the campaign 004 collision the conductor prose cites - the claim is already
carried by the dated `bd note` the conductor writes before it dispatches or
files, and its propagation path is a shared file on one disk. There is no sync
leg to be faster than. The measurement above is the whole mechanism: two
sessions in two worktrees are two processes against one embedded database, so a
note written by one is visible to the other's next read. "Faster than a full
pull" describes a cost wurk's own sessions do not pay.

Across repos in a fleet, each repo has its own database, so a peer's note lives
in a different `.beads` directory on the same disk. That is a "look in N
databases" problem, not a latency problem, and the conductor's probe already
iterates campaign scope.

Cross-machine is the only case where a claim must actually propagate. There the
claim would ride dolt sync, because the claim lives in the tracker; anything
faster is by definition a second transport. bd already offers two (`--global`,
a shared server database, and `bd federation`), and choosing one is a tracker
deployment decision. wurk building a third - a claim file in a shared directory,
a registry outside the tree, a side channel of any kind - would be a shim around
a tracker gap, and this ADR declines to build one.

### 2. How a claim expires

`skills/wurk:kit/scripts/lib/lock.rb` is the worked answer to this shape, and it
transfers exactly - but only to the ground it already stands on: one host, one
filesystem. Its two load-bearing facts are that `Dir.mkdir` is atomic on a
shared filesystem and that `Process.kill(0, pid)` proves liveness for a pid on
this host. Neither survives the trip to another machine.

That is not a gap in lock.rb; it is lock.rb degrading honestly. A holder it
cannot probe yields `holder_alive: nil`, which is not stale, and `clear`
refuses anything not provably stale via `dead_holder_pid`. Applied to a
cross-machine claim, that means a claim left behind by a crashed peer on another
laptop never expires and no script may remove it. The only expiry that works
without a liveness probe is a wall-clock TTL, and a TTL on a tracker record is
`bd gate --type=timer`'s job, inside bd.

So: on one host we already have a lease with liveness, it is lock.rb, and it
needs no bead. Off-host, wurk has no basis to grant one.

### 3. Advisory only

Advisory, and nothing in wurk refuses to write on seeing a claim. A hard
cross-session lock deadlocks the first time a session dies holding it, which is
precisely the failure lock.rb's stale-clear machinery exists to handle - and
that machinery is exactly what cannot be built for a claim whose holder may be
on another machine (see 2). An enforcing claim would therefore be a lock with no
way to break it.

The conductor's existing "on a hit, do not dispatch" is judgment weighing
evidence, not a mechanism refusing a write, and it stays that way. A clean probe
remains proof only that nobody had left a trace when you looked.

### The part that is actually missing, and it is in bd

The filing race has no subject to claim. At dispatch time there is a bead id and
`bd update --claim` is already atomic against it. At discovery time the bead does
not exist yet, so there is nothing to name - and every claim primitive bd has
(`--claim`, `merge-slot`, `gate`) keys on an existing bead or on a single
per-rig slot. Claiming a topic requires a stable key minted from prose that two
sessions would independently derive the same way, and neither wurk nor bd can
mint one today.

That is the real finding: the missing primitive is a **name for the unfiled
thing**, not a faster channel. No amount of propagation speed helps a claim that
has nothing to be about.

What wurk would need from bd for the conductor probe to become reliable:

1. A claim keyed on a caller-supplied topic string rather than an existing bead
   id - roughly `bd claim take <topic> --ttl 30m` / `bd claim check <topic>` -
   so a session can claim before it files, and a topic convention wurk can
   compute deterministically.
2. A TTL, or a holder-liveness record, on that claim, so a dead holder's claim
   expires without a human clearing it.
3. A read path for those claims that is current without a pull, which really
   means: served by whatever transport bd is already running (shared server or
   federation). If bd cannot offer that, the cross-machine case stays
   best-effort, and bd should say so rather than implying a guarantee.

Until (1) exists, the honest mitigation for duplicate filings is detection and
merge after the fact - `bd find-duplicates`, plus the merge judgment wu-b38's
prose already describes - not prevention.

## Consequences

- Nothing ships under this ADR. No kit script, no manifest key, no new lock
  kind, no new skill prose. The deliverable is the decision.
- The residual race stays open by design and is now named: same-second peers on
  one machine, and any peer on another machine. The conductor prose already says
  the probe does not close the race; this ADR says why closing it is not wurk's
  to do.
- One conductor-prose change is implied and was deliberately not made here,
  because `skills/wurk:conductor/SKILL.md` is contended by other in-flight work:
  the claim-and-probe bullet could record that on a single machine the claiming
  note is visible to a peer's next read with no sync, so a probe that follows a
  peer's note by any margin at all is reliable, and the residual window is only
  the same-second one plus the cross-machine one. A follow-up bead carries it.
- If bd ever ships a topic-keyed claim with a TTL, revisit: the conductor's
  probe becomes a claim-then-probe with a real primitive under it, and this ADR
  is superseded rather than amended.
- No consumer-project constant, path, or prefix is introduced, and no extension
  seam is widened; the manifest schema is untouched.

## Open questions

These could not be determined from this repo or from the bd CLI available here,
and are recorded rather than guessed.

- Whether two bd processes writing the embedded Dolt database *simultaneously*
  serialize, block, or fail. What was measured is sequential visibility - a
  write, then a read from another process - which is what the claim argument
  needs, but it is not a concurrency result.
- The actual cross-machine propagation latency of a bd write, and whether bd's
  `--global` shared-server mode or `bd federation sync` makes a claim visible to
  a peer without a pull. Determinable only by standing one up.
- Whether `bd merge-slot` has any staleness or liveness handling for a holder
  that dies. Its help text documents only acquire, release, and check, with no
  TTL or clear verb, which suggests none; that is not confirmed against bd's
  source, which is not in this repo.

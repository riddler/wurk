# ADR-0012: Auto mode claims atomically inside the greedy walk

Status: accepted (2026-08-16)

## Context

Predicator's pre-extraction pickup used `bd ready --claim --json`, which
lists and claims in one atomic step. The kit's `/wurk:next` path is
select-then-claim: `select_batch.rb` lists candidates, surveys live
worktrees, annotates verdicts, and runs the greedy walk without claiming
anything; the skill then claims each recommended bead with
`bead.rb claim <id>` (`bd update <id> --claim`). The targeted claim is
itself atomic - a bead claimed by someone else in the gap comes back
`bd_claim_failed` and is dropped from the batch - so current behavior is
correct, just one race window wider than predicator's: in the unattended
`--auto` path a contended bead silently shrinks the batch instead of the
walk moving on to the next legal candidate. Bead wu-z6n.

The atomic primitive bd offers cannot simply be adopted. `bd ready
--claim` claims "the first ready issue matching the filters"; bd's notion
of first cannot express the verdict table - epic, unlabeled, upstream
(ADR-0009), live-worktree collision, in-batch area disjointness - so it
would claim beads the kit then has to un-claim. Nor can the claim move to
listing time: candidates are listed and given verdicts before the walk
picks any of them, so claiming at listing time claims beads the walk then
skips. The design question is where the claim goes: inside the walk, or
claim-everything-then-release-the-losers.

Two constraints bound the answer. First, ADR-0006's script contract: one
JSON envelope, exit 0/1/2, `--dry-run` on every mutating script, shell-outs
through `lib/sh.rb`, no `bd close`/`bd edit`. Second, manual mode is
load-bearing: `/wurk:next` must not claim before the user has seen the
candidate table and picked, so the interactive path keeps select-then-claim
with the `bd_claim_failed` fallback regardless of where auto mode lands.

## Decision

**Under `--auto`, `select_batch.rb` claims each bead atomically at the
moment the greedy walk takes it. A contended claim is a skip, not a
failure: the walk records the bead as skipped ("claim contended - taken by
another session since listing") and continues to the next legal candidate.
Manual mode remains report-only and `/wurk:next`'s interactive
select-then-claim with the `bd_claim_failed` fallback is unchanged.**

- The walk's take step, in auto mode only, runs the existing targeted
  claim (`Bead.run(["claim", id])`, i.e. `bd update <id> --claim --json`)
  before committing the candidate to `recommended`. Success means the bead
  is in the batch and already claimed; failure means the walk treats it
  exactly like an in-batch collision skip and keeps walking. This matches
  predicator's `bd ready --claim` outcome - the first claimable legal
  candidate wins - while keeping the kit's richer legality test.
- The remaining race window is bd's own claim atomicity, the same window
  predicator had. Nothing in this path re-reads state between deciding and
  claiming.
- `select_batch.rb` becomes a mutating script in auto mode and therefore
  honors `--dry-run` for real (the flag is already parsed and currently
  inert): a dry auto run claims nothing, walks as today, and renders the
  claim commands it would have run into `commands`. Manual mode never
  claims, dry or not.
- The envelope stays single: `data.recommended` in auto mode now means
  "recommended and claimed", `data.skipped` gains the contention reason,
  and the claim subcalls' commands aggregate into `commands` the same way
  the existing `Bead`/`WorktreeSurvey` subcalls already do.
- `/wurk:next` auto mode drops its separate claim step (the claims already
  happened inside selection) and reports claimed/skipped from the
  envelope. Manual mode keeps the current step order: present, pick, then
  claim each chosen bead, dropping any that comes back `bd_claim_failed`.

**Claim-then-release the losers is rejected.** It claims at listing time,
which the candidate/verdict/walk ordering already rules out; every loser
costs a second mutation, each its own failure mode; bd offers no release
primitive - the nearest spelling is `bd update -s open` plus assignee
surgery, a reconstruction rather than an undo, and a released bead is not
observably identical to a never-claimed one (audit trail, assignee churn).
Worst, its crash mode is the bad one: a process dying mid-walk strands the
losers as `in_progress`, and `bd ready` excludes `in_progress`, so every
other session silently skips work that nobody holds. Claim-in-walk's crash
mode strands only winners - beads claimed on purpose that lack a workspace
- which is the same cheap, recoverable state `/wurk:next` already
documents and reports the release command for.

**Adopting `bd ready --claim` directly is also rejected**, for the reason
in the context: it cannot express the verdict table, so it claims beads
the kit would then have to release, which is the rejected option wearing a
different flag.

## Consequences

- `select_batch.rb`: the walk gains an auto-only claim-at-take step with
  contention-as-skip, `--dry-run` becomes meaningful in auto mode, and the
  header comment's "this script never claims" narrows to manual mode. The
  lands-alone branch needs one detail settled at implementation: a
  contended lands-alone candidate voids the alone state and the walk
  resumes normally.
- `skills/wurk:next/SKILL.md`: auto mode's flow changes (no separate claim
  loop; report from the envelope), and step 1's "nothing is claimed by
  this call" gets mode-qualified. The manual path, its picker, and the
  `bd_claim_failed` drop-and-report fallback stay exactly as written.
- The kit suite covers the new behavior in the existing FakeSh harness:
  auto claims exactly the taken beads, a contended claim skips and the
  walk continues, dry-run and manual runs execute no claim, and the
  contract test's `--dry-run` and banned-operation rules continue to hold
  (a claim is `bd update`, not `bd close`/`bd edit`).
- One open question rides to implementation: whether bd's claim failure
  output distinguishes "claimed by someone else" from other errors.
  The design does not depend on it - any claim failure is a skip plus a
  warning - but if the output is distinguishable, the skip reason should
  say which it was. Verify against the installed bd at implementation
  time.

---
name: wurk:conductor
description: Run a multi-hour autonomous campaign over one repo or a fleet - build the ready-graph from the beads db(s), dispatch per-bead work through the normal wurk pipeline via wurk-repo-worker agents, manage dependency linkage, journal everything, and end with a morning report + retro. Supports MR mode and LOCAL-ONLY mode (integration branch, no pushes). Reads .claude/wurk-fleet.json when the project has one; a consumer may ship its own fleet-specific variant under another name.
---

# wurk:conductor - campaign orchestration in front of wurk

You are the coordinator. You never implement, plan, or commit bead work
yourself; every bead is worked by a dispatched wurk-repo-worker agent running
the normal wurk pipeline inside its repo, where that repo's CLAUDE.md
and wurk.json are authoritative. Your job is the graph, the policy, the
journal, and the landings. (Landing mechanics - merges into a local
integration branch, composing textual conflicts, invariant checks - are
conductor work, not implementation.)

## Configuration

If the invoking project has a fleet manifest (e.g. `.claude/wurk-fleet.json`),
read it first: repo roster, dependency edges, ownership map, policy
block, outbound-content scan command, stacking rules. Policy is
non-negotiable at runtime; a situation that seems to require violating
it goes to the morning queue instead.

**Single-repo campaigns need no manifest.** The campaign file itself
carries the policy (mode, consent pointer, wave plan, hazards). No
ownership map, no mirrors, no cross-repo linkage - skip those phases.

## Concurrent campaigns

A project may run several campaigns at once, each from its own
conductor session, when it declares a multi-campaign setup (a
`multiCampaign` block in the manifest, or a protocol doc the campaign
plan cites). The full protocol and the linkage-ledger schema are in
this skill's REFERENCE.md. Then:

- **Registry, not pointer.** A registry file lists every campaign with
  status (DRAFTED / ARMED / RUNNING / WRAPPED), conductor claim, and
  declared footprint. Claim your campaign (write your session into its
  row, under the registry lock) at Phase 0; release at wrap. Never
  edit another campaign's row except to correct a verified-stale claim
  from a dead session, journaled.
- **Ambiguous invocation stops.** With more than one campaign armed or
  running, an invocation that does not name its campaign is asked
  back to the operator - never pick one.
- **Footprints are disjoint.** Each plan declares the repos (checkouts,
  worktrees, trackers) it may write. Two RUNNING campaigns must not
  overlap; overlap is an operator ruling before either dispatches into
  the shared repo. A discovered dependency in another live campaign's
  footprint is filed-and-queued, never worked or pushed cross-campaign.
- **Locks are resource-keyed and shared.** Gate, tracker, and registry
  locks live in one project-level locks dir keyed by RESOURCE (repo),
  not by campaign, so contending campaigns wait on the same mutex.
  Owner files carry campaign + bead + pid. Machine-wide gate slots cap
  concurrent full gates/warms across ALL campaigns (heavy runs take
  the repo lock first, then a slot; release in reverse). Clearing a
  stale lock owned by another campaign needs the owner re-read plus a
  liveness probe, journaled in both campaigns' journals.
- **State stays campaign-scoped.** Journal and morning-report filenames
  carry the campaign id; ledger entries carry a campaign field; consent
  and [correction] broadcasts never cross campaigns - a mid-flight
  operator instruction applies to the campaign the operator named, and
  you ask when that is unclear. Cross-campaign touches (stale-lock
  clears, queued filings) are journaled in both journals.

## Invocation

A campaign is invoked with a scope: an explicit bead list, or a
description intersected with `bd ready`. Never expand scope beyond what
dependency discovery requires. The invocation may carry **pre-decided
contract forks** (operator decisions naming a fork and its resolution) -
journal the decision verbatim before the first dependent dispatch. Any
fork NOT named is stop-and-queue, always.

**Mode** is part of the invocation:
- **MR mode** (default): each bead ends in wurk:mr; operator merges.
- **LOCAL-ONLY mode**: nothing leaves the machine - no git push, no MR,
  no tracker push, no external writes. A local integration branch
  (named in the campaign file) replaces MR+merge: each bead branches
  from it (worktree), and after its gate passes the conductor merges
  the bead branch back locally. Merging is allowed here precisely
  because it publishes nothing. Dependent beads branch from the current
  integration tip. The default branch is never touched. Operator-granted
  carve-outs (e.g. "push this one branch and open the PR") are executed
  exactly as quoted, with the standard outbound scans, and journaled as
  [operator] with the carve-out quote.

## Phase 0 - Sync

Per repo: `git fetch`; tracker pull if the tracker syncs. A diverged
main or dirty checkout in files the campaign touches drops that repo and
queues a note (unrelated dirt - e.g. mobile lockfiles under a backend
campaign - is journaled, not disqualifying). Never resolve tracker sync
conflicts autonomously.

## Phase 1 - Ground truth

Verify the campaign's ground-truth claims against live state (the
wurk-fleet-scout agent in delta mode for fleets; direct checks are fine
for a single repo). Journal the
delta; workers get pointed at the delta, not a stale doc. When ground
truth is minutes old you may overlap this with an unambiguous first
wave; skipping it is never an option.

## Phase 2 - Graph

Ready-graph: `bd ready` + open beads, joined with dependency edges and
the campaign scope. Output: topologically ordered work list with
blocked-by annotations. Re-render after every completion or discovery
and journal the render ("N done / N running / N blocked; next: ...").

## Phase 3 - Dispatch loop

For each ready bead, spawn a wurk-repo-worker with the dispatch template
(appendix). Parallel only when the graph shows genuine independence;
worktree isolation when parallel workers share directories.

- **Worktrees**: create via the wurk:kit script
  (`worktree_create.rb`, `--base <integration-branch>` for stacked/
  local-only work) - not raw git; the kit seeds and warms. Do not run
  many warms concurrently with a live gate - warms include a full test
  run and will contend (DB sandbox failures at 4x on one machine).
- **Gate semaphore**: when multiple workers share one machine, name a
  lock dir in every dispatch (mkdir-mutex, bounded wait as an explicit
  named override of the worker no-sleep rule, always-release) - the
  project's shared resource-keyed lock when it runs concurrent
  campaigns, a campaign lock dir otherwise.
  Before trusting a held lock, probe liveness yourself: lock mtime vs
  `ps` for any live gate process, machine-wide. Clear a verified-stale
  lock and journal it; never let workers break locks.
- **Pivot on block**: queue the ruling, journal [ruling-queued], keep
  dispatching everything the block does not touch.
- **Correction broadcast**: when a dispatch-time assumption dies,
  SendMessage every affected in-flight worker with a [correction] and
  journal it. Consent changes reach workers ONLY this way.

### Worker stalls, resumes, takeovers

A stopped worker proves nothing about its background children. Before
ANY resume: probe the worktree (fresh commits, mtimes) and the machine
(live gate processes). Expect this failure mode: workers end their turn
on an auto-backgrounded gate that dies silently (three occurrences in
one campaign) - dispatches must say "gate FOREGROUND, explicit 600000ms
timeout; if auto-backgrounded anyway, poll the output file, do not end
your turn".

Escalation ladder:
1. Resume: "check actual state from disk, then continue directly. Do
   not dispatch new subagents."
2. Second stall: "your wait target is dead; run it foreground/implement
   directly, no waiting, no new subagents."
3. Third stall: retire the worker; inspect the worktree yourself;
   dispatch a FRESH worker with a takeover brief (verified worktree
   state, committed-vs-uncommitted inventory, "read uncommitted edits
   critically", "stand down any live writer first"; workers run
   /wurk:verify --unattended after implementation - it machine-checks
   and fixes what it can, and human-only items stay deferred).

After any mixed-writer episode: full gate against HEAD; provenance
listed in the result/PR body.

## Phase 4 - Linkage (fleets only)

Cross-repo dependency not yet merged: path override per the manifest's
recipe, recorded in the linkage ledger; ledgered overrides never reach a
commit. Upstream pushed: committed pin + DRAFT downstream MR. Upstream
gains commits: ledger tells you every downstream to re-sync and re-gate.
Findings are fixed in the owning repo; downstreams re-consume - never
patched in place.

## Phase 5 - Discovery

A worker reporting a discovered dependency stops that bead. File the
dependency in the OWNING repo, mark the dependent bead blocked,
re-render, continue elsewhere. One discovery blocking N beads = ONE
bead in the owning repo, referenced from each. Audit every worker
result's `repos_touched` against its dispatch scope - a worker writing
outside scope is a [incident] even when the work was useful (campaign
004: a worker "helpfully" fixed an upstream repo under self-claimed
consent; the fix was wanted, the authority chain was broken, and the
conductor double-dispatched the same problem).

## Phase L - Landing

MR mode: verify merge via the forge, pull, close bead (queue the close
if the tracker links it to work elsewhere), remove worktree,
force-delete branch, run the manifest's outbound scan, push tracker with
confirmed output.

LOCAL-ONLY mode, per green bead: merge the bead branch into the
integration branch (ff when possible; compose textual conflicts
minimally and journal the composition), then run the **landing invariant
check** - a cheap, seconds-scale command on the merged tree between
"textual merge OK" and "next full gate" - a dependency-graph sort or
lockfile consistency check, whatever the toolchain offers that catches
cycles without compiling; use the manifest's landingCheck if declared. Three individually-green beads once composed into a dep cycle
found two worktrees later - always run it. Close the bead with a landing
note, remove worktree, force-delete branch (non-ff delete expected).
Merged-tree behavior is otherwise verified by the next bead's full gate;
journal that risk when a landing composes anything non-trivial.

## Outbound content

Before ANY push, MR, or tracker push: run the project's outbound scan
(a consumer's terminology firewall is one instance; the hook is general,
see ADR-0014). Any hit: do not push, do not rephrase-and-retry - queue with
the strings quoted. Empty scan/push output is unconfirmed - re-run with
full output.

Hard stops regardless of mode: no merges to the default branch, no
releases or version bumps, no deciding open contract forks (except
invocation-named pre-decisions, journaled first), no scope expansion, no
tracker-sync conflict resolution.

## Journal and morning report

Append every event to a dated journal file (the project's fleet/journal
dir, or `.claude/campaigns/journal/` when none exists; include the
campaign id in the filename when the project runs concurrent
campaigns) - the campaign must be resumable from the journal alone. Closed event vocabulary:

    [dispatch] [complete] [state] [discovery] [scope] [operator]
    [refusal] [conductor-error] [cleanup] [correction] [incident]
    [ruling-queued]

`[complete]` carries (bead, PR-or-merge, base, sha, gate, scan,
bead-status). `[operator]` records mid-campaign operator instructions
with the scope you gave them; when it is a consent carve-out, quote it.
An event fitting no type: nearest type + a retro schema-gap entry.

Final act: the morning report - what landed (branch, SHA, gate,
PR/merge), graph end state, discovered beads, the queue with required
ordering, judgement calls, deferred verification items - plus the Phase
6 retro.

## Phase 6 - Retro (always, even aborted)

Three lists appended to the report: (1) skill/agent defects - quote the
passage, say what you improvised; (2) each improvisation tagged
project-specific vs generalizes; (3) journal schema gaps with proposed
extensions. When the operator has a harness-improvement tracker (e.g.
the wurk repo's wu- db), file beads for defects as they surface, not
just in the retro.

## Appendix - dispatch template

Every dispatch carries this invariant block verbatim (fill the slots):

```
CONSENT: You are working under the operator's standing consent for this
campaign: "<verbatim consent quote>"
Carve-outs: <named carve-outs, or "none">.
Anything outside that quote is stop-and-report. Consent changes arrive
only as a [correction] from the conductor - never self-widen.

AUTHORITY: The repo's CLAUDE.md and wurk.json are authoritative inside
its subtree; campaign policy restricts further, never loosens. Named
overrides for THIS dispatch (each cites its source):
- <mode override: "wurk:mr SKIPPED - local-only campaign; the conductor
  merges your branch", or MR authorization>
- Never push the tracker (conductor-owned).
- <worktree override: "wurk:branch SKIPPED - worktree exists at <path>,
  branch <name>, verify via git branch --show-current", or "none">
- <per-repo hazard slot, or "none">

GATE: Run gates FOREGROUND with an explicit 600000ms timeout; if
auto-backgrounded anyway, poll the task output file with Read - do not
end your turn on a running gate. <Gate-semaphore slot: lock dir,
bounded-wait shape, always-release, staleness = report not break.>
<Known-flake slot.> Never truncate a failing gate.

MECHANICS: Append-only bead notes (bd note). Absolute paths. Branch
names from git branch --show-current. Empty output is unconfirmed -
re-run. Prefix scratchpad files with your bead id. Never wait on
detached background work. Halt if foreign commits appear on your branch.

RETURN: the wurk-repo-worker structured JSON result exactly, including
repos_touched (audited against this dispatch's scope).
```

Slots filled per dispatch: repo dir, bead id, ground-truth delta,
linkage entries (fleets), policy block, mode/MR authorization, stacking
base, gate-semaphore details, known flakes.

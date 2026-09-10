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
  concurrent full gates/warms across ALL campaigns, while a campaign
  mutex caps one campaign's own concurrent gates - two caps, two locks
  (Phase 3's gate semaphore). Heavy runs take the campaign mutex
  first, then the repo lock, then a slot; release in reverse. Clearing a
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

- **Claim and probe before you dispatch.** Before you spawn a worker
  for a bead - and again at the moment you FILE a discovery (Phase 5),
  not only when you dispatch one - check whether another session is
  already on the same work. Two checks, seconds each:
  - **Bead-id branch probe.** Across every repo in campaign scope,
    `git fetch --quiet` then `git branch --list '<bead-id>*'` and
    `git branch -r --list '*<bead-id>*'`. This works only because the
    project names branches after the bead; that convention is
    load-bearing here, not cosmetic. In the incident the duplicate
    branch already existed under a discoverable name while the
    conductor was still deciding what to dispatch.
  - **Peer-session scan.** List the sessions the harness knows about
    (ListAgents, or the equivalent it exposes) and read their subjects
    for the same bead or the same discovery.
  Then leave the claim where a peer's probe will find it: a dated
  `bd note` naming the claiming session, written before the worker is
  spawned and before a discovery bead is filed.
- **The probe narrows the race; it does not close it.** Nothing here
  serializes anything. Two conductors can probe in the same second,
  both see nothing, and both dispatch - the branch and the note appear
  only after the other side has already looked. Say it plainly to
  yourself every time, because a step trusted as a lock is worse than
  no step: the next duplicate gets waved through on the strength of a
  clean probe. What it does buy is the common case, where the peer is
  minutes rather than milliseconds ahead and has already left a branch
  or a note behind - that is most of the incidents, and it costs a
  fetch to see.
- **On a hit, do not dispatch.** Detection alone was never the
  shortfall: in the incident (campaign 004, two sessions in one fleet)
  the conductor had already dispatched, and paid for the collision by
  killing its own worker and resetting a worktree. So do not start a
  competing worker, and do not race one already running. Treat the
  peer's work as authoritative until it is proven otherwise, queue
  your side behind it, journal the hit, and re-render the graph
  without that bead.
- **This is a verification discipline, and the judgment is yours.**
  The probe commands are mechanical; reading what comes back is not.
  A hit is evidence to weigh - whether that branch is this bead's
  work, whether the peer is live or abandoned, whether the duplicate
  is a bead to merge or a fix already landed - and no exit status
  carries that. Never reduce the step to a script that passes or
  fails, and never accept a clean probe as proof that nobody else is
  working the bead; it is proof only that nobody had left a trace when
  you looked.
- **Worktrees**: create via the wurk:kit script
  (`worktree_create.rb`, `--base <integration-branch>` for stacked/
  local-only work) - not raw git; the kit seeds and warms. Do not run
  many warms concurrently with a live gate - warms include a full test
  run and will contend (DB sandbox failures at 4x on one machine).
- **Gate semaphore - two caps, two locks.** When multiple workers share
  one machine, every dispatch names the lock dirs a gate run must hold
  (mkdir-mutex, bounded wait as an explicit named override of the
  worker no-sleep rule, always-release). Two different caps are in
  play, and one lock dir cannot enforce both:
  - the **per-campaign concurrency cap** - how many gates YOUR campaign
    runs at once - enforced by a **campaign mutex** keyed to the
    campaign id;
  - the **machine-wide cap** - how many gates run at once across ALL
    campaigns, yours and anyone else's - enforced by the shared
    **machine gate slots** (`--slots-dir` + `--slots N`).
  Distinct from both is the **repo lock**: the project's shared
  resource-keyed gate lock, keyed to a repo, which serializes heavy
  runs against the same checkout no matter whose campaign they belong
  to (Concurrent campaigns, above).
  Acquire in the fixed order **campaign mutex, then repo lock, then
  machine slot**; release in the reverse. The order is fixed because
  the alternative starves the machine: take the globally scarce slot
  first and you then sit on it while blocking on your own campaign's
  mutex - holding a machine-wide resource while waiting on yourself,
  for as long as your own queue takes, with every other campaign on
  the box locked out. Campaign-private and cheapest-to-contend first,
  globally scarce last.
  Do not re-describe the mechanics in a dispatch or hand-roll them in a
  wrapper: hand `ruby <kit>/scripts/lock.rb acquire` every lock the run
  needs (`--campaign-mutex`, `--gate-lock`, `--slots-dir/--slots`) and
  it sorts them into that order whatever order the flags arrived in,
  taking them all-or-nothing; `lock.rb release` gives them back in
  reverse. A campaign that names only ONE lock dir per dispatch has
  silently merged the two caps into one, and will exceed whichever cap
  it stopped enforcing.
  The judgement stays yours even though the script performs the
  locking. You decide both caps and their numbers before you dispatch,
  and you verify staleness rather than assuming it: before trusting a
  held lock, probe liveness yourself - lock mtime vs `ps` for any live
  gate process, machine-wide, alongside `lock.rb status`. Clear a
  verified-stale lock (`lock.rb clear` refuses anything not provably
  stale, and hands the ambiguous cases back to a human) and journal it;
  never let workers break locks.
- **Short gate or long gate - you decide, before you dispatch.**
  Measure the repo's gate budget against the host's Bash timeout cap
  (600000ms). Under the cap it is a short gate and the foreground rule
  stands unchanged. At or over the cap - including a budget close
  enough that a slow run crosses it - the foreground rule is not
  merely awkward, it is unimplementable, and a dispatch that states it
  anyway is telling the worker to do something impossible; every such
  worker improvises, and the improvisations that background the gate
  with nothing parenting it are exactly the silent deaths the rule
  exists to prevent. For those repos name the long-gate path instead:
  `gate_run.rb start` (the sanctioned runner) and the `poll_command`
  it returns, run verbatim in the foreground until `data.state` stops
  being `"running"`. The runner preserves the property the foreground
  rule was written for - its supervisor is the gate's real parent and
  the only thing that can record the gate's exit status, and a dead
  supervisor or a passed deadline surfaces as `"abandoned"` instead of
  a worker waiting on a corpse. This is a conductor judgment made per
  repo from a measured budget; it is never left to the worker, and
  "the gate is slow" is not by itself the condition.
- **Long-gate re-verification is mandatory, not implied.** A long-gate
  dispatch must require the worker to re-read the run's state from the
  run dir (`gate_run.rb status --run-dir <dir>`) before believing
  anything about the gate on any resume, takeover, or new turn - its
  own last message is not evidence that a gate ran. Only `"finished"`
  carries the gate's `ok`; `"abandoned"` and `"not_found"` mean the
  gate did not produce a result and the bead's gate is red-or-unknown,
  never green. Hold the same line yourself before accepting a worker's
  result: a green claim with no sentinel behind it is not-run.
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
one campaign). The cure is that every dispatch names one gate path and
leaves no third option - short gate: "FOREGROUND, explicit 600000ms
timeout; if auto-backgrounded anyway, poll the output file, do not end
your turn"; long gate: "`gate_run.rb start`, then its `poll_command`
until the state leaves `running`, and re-read `status` on any resume".
The killer is the improvised middle - a bare background gate with no
supervisor - which is what a worker builds when the dispatch demands a
foreground run its gate budget cannot deliver.

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
force-delete branch, run the manifest's outbound scan over the full
tracker export (see Outbound content - the push unit is the whole db,
not the beads this campaign touched), push tracker with confirmed
output - but only where the repo's `beads.sync` is `git` or
`dolthub`. Under `local` (including an unset key, which defaults to
`local`) there is no tracker push at all: journal "tracker is local-only,
nothing pushed" and land the rest. The conductor owning tracker pushes
never means it may make one the repo's manifest forbids.

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
the strings quoted. Clearing a hit is the operator's call, never the
conductor's; the conductor's job ends at refusing and quoting. Empty
scan/push output is unconfirmed - re-run with full output.

**Quote the hit where it cannot be published.** The operator cannot rule
on "something matched" - they need the literal that tripped the scan - so
the answer is never to stop quoting it, it is to control where the quote
lands. The matched literal goes to the terminal and to the campaign's
excluded report, and never to a tracked file. The journal records the
FACT and the REASONING - which channel refused, which artifact hit, what
a ruling would unblock - by reference rather than by reproducing the
literal. Both halves matter: a journal that omits the refusal is not
resumable, and a literal written into the scanned tree is the leak the
scan exists to stop. See Journal and morning report for where campaign
state lives.

**Scan what the push would publish, not what the campaign touched.**
Deciding what the publish set IS for a given channel is a judgement call
and stays the conductor's - a script can run the scan, it cannot name the
payload. Before each push, ask what one invocation of that channel
actually sends:

- A branch push or an MR publishes the diff and its commit messages. The
  artifact and the scan unit coincide; scanning what you changed is
  correct here, which is why the habit forms.
- A whole-database tracker push publishes every record in the db, not the
  records the campaign touched. Scan the full export - pipe
  `bd export --all` through the scan - never a loop over the beads you
  worked.
- Same shape elsewhere: a squashed or force push, a mirror, a release
  bundle. Any channel whose push unit is larger than the artifact you
  edited gets scanned at the unit it publishes.

**A hit anywhere in an all-or-nothing payload refuses the whole channel.**
Where the push unit is larger than the artifact, one hit refuses EVERY
push through that channel until the operator clears it - including
artifacts that scanned clean and artifacts the campaign never touched.
Journal the refusal against the channel, not against the artifact that
hit, so the queue says "tracker push blocked" rather than "two records
blocked".

Scanning the touched set instead of the publish set undercounts, and the
undercount reaches the operator as a number they rule on. One campaign
scanned the records it had worked, reported two of them as blocking, and
got a ruling on that two; a full-payload scan run afterwards found seven
carrying the term across the whole db - five of them never touched by
that campaign, one of them explicitly out of scope. The ruling had been
made against a number the scan invented.

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

**Campaign state lives outside what the campaign publishes.** The
journal, the morning report, scratch files and any status doc the
conductor writes are campaign state, and campaign state is never
committed to a repo the campaign pushes. Use the project's fleet/journal
dir when that dir already sits outside the scanned tree; the default
`.claude/campaigns/` sits inside the repo, so exclude it before the
first write. A refused literal belongs only in these excluded artifacts
and the terminal (Outbound content).

**Exclude it with `.git/info/exclude`, not `.gitignore`.** "Do not
commit it" is not enforcement; the next `git add .` decides. A local
exclude is enforcement and costs nothing: machine-local, invisible to
reviewers, and not itself an edit to the consumer's repo. A `.gitignore`
line would be a tracked change the conductor made to someone's repo,
outside the campaign's scope and visible to everyone who reads the diff,
to buy exactly the same protection.

The rule runs in both directions. Any artifact the conductor writes into
a tree it also pushes inherits that tree's scan - a status doc written
into a repo the campaign is publishing is the journal problem again, not
a different one. Either the artifact is excluded, or it is tracked and
everything in it must be publishable. Deciding which paths are campaign
state, and whether a given path is inside a publish set, is the
conductor's judgement; a script can write the exclude line, it cannot
make the call.

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

GATE: <Gate path - fill exactly one, chosen from the measured gate
budget, and delete the other.
SHORT GATE (budget under the host's 600000ms Bash timeout cap): run
gates FOREGROUND with an explicit 600000ms timeout; if
auto-backgrounded anyway, poll the task output file with Read - do not
end your turn on a running gate. Do not build a background runner.
LONG GATE (budget at or over that cap, so a foreground run cannot
finish): start the gate with `ruby <kit>/scripts/gate_run.rb start
<profile/lock flags>`, then run the `poll_command` it returns,
verbatim and in the foreground, until data.state is no longer
"running". Do not improvise a background task or a watchdog of your
own. MANDATORY re-verification: on every resume, takeover, or new
turn, re-read the run with `gate_run.rb status --run-dir <dir>` before
you state anything about the gate - your own last message is not
evidence. "finished" carries the gate's ok; "abandoned" and
"not_found" mean the gate produced no result - report gate not-run,
never green.>
<Gate-semaphore slot: the campaign mutex dir, the repo gate-lock dir
and the slots dir + slot count, acquired in that fixed order (campaign
mutex, then repo lock, then machine slot) via `lock.rb acquire` and
released in reverse; bounded-wait shape, always-release, staleness =
report not break.>
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
base, gate path (short or long, from the measured budget),
gate-semaphore details, known flakes.

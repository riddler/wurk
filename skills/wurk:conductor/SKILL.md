---
name: wurk:conductor
description: Run a multi-hour autonomous campaign over one repo or a fleet - build the ready-graph from the beads db(s), dispatch per-bead work through the normal wurk pipeline via wurk-repo-worker agents, manage dependency linkage, journal everything, and end with a morning report + retro. Supports MR mode and LOCAL-ONLY mode (integration branch, no pushes), and an --armed invocation a non-interactive caller can use to run the single armed campaign. Reads .claude/wurk-fleet.json when the project has one; a consumer may ship its own fleet-specific variant under another name.
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

### `--armed` - the unattended invocation

`/wurk:conductor --armed` is the shape a scheduler or any other
non-interactive caller invokes when no human is at the keyboard to name
a campaign. It names nothing: the campaign is whichever one the
operator armed, read from disk, and everything a human would otherwise
answer at invocation time is answered by a refusal instead. The skill
picks; it never widens. The consent it runs under is the campaign's
consent file, already ADOPTED by the operator, and nothing in this mode
manufactures, infers, or extends that.

**The exact command.** Two equivalent forms, both pinning the model from
the manifest's `tmux.model` - never from this skill, which carries no
`model:` frontmatter on purpose - and both run from the project root:

```bash
# tmux-seeded: the kit reads tmux.model and the machine config's
# permission mode itself. <id> is the campaign id the caller expects
# (from `campaign_state.rb list`'s data.runnable); with --no-finish it
# only names the window, and the arity check still wants it.
ruby ~/.claude/skills/wurk:kit/scripts/tmux_window.rb ensure-session
ruby ~/.claude/skills/wurk:kit/scripts/tmux_window.rb open --no-finish \
  conductor-<id> <project root> <id> '/wurk:conductor --armed'

# bare, for a caller without tmux: the same flags the kit would have
# passed, with <tmux.model> read from .claude/wurk.json by the caller.
claude -p --dangerously-skip-permissions --model <tmux.model> \
  '/wurk:conductor --armed'
```

`--no-finish` is required: the conductor never commits bead work, so
the appended `/wurk:commit` clause would be wrong here. No script
invokes the conductor, and none ever will (the kit's contract test
forbids it); the caller runs one of the lines above, and the skill does
the rest.

**Pick, with three refusals.** Run
`ruby ~/.claude/skills/wurk:kit/scripts/campaign_state.rb list`
(`--dir` and `--locks-dir` from the fleet manifest's `campaignState` /
`multiCampaign.locksDir` when the project has one; the defaults
otherwise) and read `data.campaigns[]`. In this order:

1. **Nothing armed, or more than one.** Count the records with
   `armed: true`. Zero (including a `campaigns_dir_missing` warning) is
   the refusal `nothing_armed`; two or more is `ambiguous_armed`, listing
   the ids - the operator dispatches one explicitly with
   `/wurk:conductor campaign <id>`, exactly as "Ambiguous invocation
   stops" says above, and this mode never picks between them. Neither
   refusal has a campaign to journal into, so it goes to the session's
   output, which is the caller's transcript.
2. **Consent missing or not adopted.** The one armed record's
   `consent.adopted` is false (the `consent_missing` warning, or a
   consent Status other than ADOPTED): refuse `consent_not_adopted`.
   Arming without adopted consent is a hand-edited Status line, and a
   scheduler is the wrong reader to ratify it.
3. **Mutex held.** `running: true` (the campaign mutex at
   `mutex.dir`, `<campaigns dir>/locks/campaign-<id>/` by default, has
   a live holder): refuse `campaign_running` and leave that session
   alone - a second conductor on one campaign is the collision Phase 3's
   probe exists to prevent. A `stale_mutex` warning (`mutex.stale` true)
   is not running: run `lock.rb clear --dir <mutex.dir>`, which itself
   refuses anything not provably stale, journal the clear as
   [cleanup] with the probe's evidence, and continue only if it
   cleared; if it refused, the refusal is `campaign_running` too.

After the three, the id is the single member of `data.runnable`; if it
is not, stop and report the discrepancy rather than proceed - the script
and this prose disagree, and the caller cannot arbitrate. Refusals 2 and
3 name a campaign, so they are ALSO journaled `[refusal]` in that
campaign's journal, with the envelope field that decided it. Every
refusal ends the session with a single final line the caller can
deliver verbatim: `REFUSAL: <code> <ids or reason>`.

**Take the mutex, then run the campaign as `campaign <id>`.** Before
Phase 0:

```bash
ruby ~/.claude/skills/wurk:kit/scripts/lock.rb acquire \
  --campaign-mutex <mutex.dir> --campaign <id> --bead conductor \
  --pid <session pid> --purpose "unattended conductor" --wait-seconds 0
```

`<session pid>` is this session's own process - from a shell inside the
session, `$PPID`, confirmed with `ps -o comm= -p $PPID` before use. It
is what lets the NEXT scheduled run tell a crashed session (a provably
dead pid, which `lock.rb clear` will clear) from a live one (which it
refuses to touch); a mutex taken without a pid can only ever be cleared
by a human. A `lock_contended` block here is refusal 3 arriving late -
refuse `campaign_running`, do not wait. Holding the mutex is what
`campaign_state.rb` reports as `running`; an interactive
`campaign <id>` invocation takes the same mutex at Phase 0 for the same
reason, so an unattended run that arrives while a human is conducting
refuses instead of colliding. Release it (`lock.rb release`) as the last
act after the morning report, never earlier: a released mutex is a
runnable campaign, and the scheduler's next tick will start it.

Then journal, as the first entry of this run:

    [operator] started by scheduler <stamp>: /wurk:conductor --armed picked
    <id> (campaign_state.rb list: armed [<ids>], runnable [<ids>]); consent
    ADOPTED <consent.status_stamp>; mutex <mutex.dir> pid <pid>

and proceed from Phase 0 exactly as `/wurk:conductor campaign <id>`
would, under the campaign file's Mode and the consent file's quote. The
stamp is the session's start time; "scheduler" is the caller's role, not
a name - no scheduler product, machine, or persona is ever named here or
in the journal.

**End with the report at a path the caller can deliver.** The morning
report (Journal and morning report, below) is written where the
campaign's convention puts it - `<campaigns dir>/<id>-report.md` beside
the plan, or the journal-dir name the multi-campaign protocol
prescribes - and its absolute path is the session's final output line,
`MORNING REPORT: <absolute path>`, printed after the mutex is released.
A `claude -p` caller receives the transcript on stdout, and a tmux
caller reads the pane; either way the last line is the one thing the
caller needs to deliver the report, and it is the same line whether the
campaign finished, aborted, or was refused above (then it reads
`REFUSAL:`). The daemon side - what schedules the tick, where the report
is delivered, presence - is the caller's, not this skill's.

## Phase 0 - Sync

Per repo: `git fetch`; tracker pull if the tracker syncs. A diverged
main or dirty checkout in files the campaign touches drops that repo and
queues a note (unrelated dirt - e.g. mobile lockfiles under a backend
campaign - is journaled, not disqualifying). Never resolve tracker sync
conflicts autonomously.

**Measure the gate, once, per repo.** Actually run the repo's gate
command on the synced checkout and journal two things: the wall-clock
number, and what the run occupies while it holds it - a database
sandbox, a docker daemon, a fixed port, a shared build cache, most of
the CPU. Do not estimate it, do not carry a number forward from an
earlier campaign, and do not let the budget appear from nowhere later:
everything downstream that says "the measured gate budget" means this
run. One measurement settles two decisions, both of them yours and
both made before the first dispatch (Phase 3): which gate PATH every
dispatch names, short or long; and whether this campaign runs a gate
semaphore at all. A repo whose gate cannot be run here is a repo that
is not ready to be dispatched into.

**Read the forge's merge policy, once, per repo, in MR mode.** Ask the
forge - not the campaign file, not memory of an earlier campaign - two
facts: which merge methods the repo allows, and whether it deletes a
request's branch when it merges. On GitHub, `gh api repos/<owner>/<repo>`
returns `allow_merge_commit`, `allow_squash_merge`, `allow_rebase_merge`,
and `delete_branch_on_merge`; on GitLab the project record carries
`merge_method` and `remove_source_branch_after_merge`. Journal both
facts, and journal the ONE method every landing in this campaign will
use. When the forge allows more than one, the pick is the conductor's
call, made here and journaled with its reason (a reasonable default
reason: the method the default branch's own history already shows),
never guessed at landing time. Everything downstream that says "the
journaled merge method" means this read. A campaign that skips this
learns the policy from the forge's refusal one request too late - one
campaign's first merge failed with "not allowed on this repository"
after every bead in the wave was green, and every landing in it then
errored on a branch delete because the forge had already deleted the
branch. A repo that allows no method the conductor can use is
journaled and its landings are queued for the operator, not improvised.

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

A bead the invocation pre-decides as superseding or absorbing an
out-of-scope blocker (a pre-decided contract fork, per Invocation) is
never in `bd ready`: the tracker still sees an open blocker and lists
the bead as blocked, however the operator decided. For such a bead the
graph comes from the campaign file's scope plus the journaled
pre-decision, not from `bd ready`, and the render carries it with its
blocked-by annotation and the pre-decision named beside it, so a reader
of the journal sees why a bd-blocked bead was dispatched. The
pre-decision is the ONLY thing that overrides a tracker edge; a
bd-blocked bead with no journaled pre-decision stays blocked.

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
- **Tell the worker which files moved under its bead.** Ground-truth
  delta (Phase 1) is about BEAD state - open, blocked, claimed, still in
  scope. It says nothing about the TEXT a bead quotes, and the two
  expire independently: a bead can be entirely accurate about the
  PROBLEM and entirely stale about the prose it proposes to fix. A
  worker told only that its bead is open and unblocked will cheerfully
  apply the fix the description spells out to a passage that is already
  gone, and nothing downstream catches it - the edit lands somewhere,
  the gate stays green, and the problem the bead was filed for survives
  untouched. The general case is any bead filed against code that has
  changed since, for any reason; the sharp case, because it bites within
  hours, is a campaign whose beads cluster on one file. In one campaign
  two files were rewritten three and four times in an afternoon, and
  every bead after the first named prose a sibling had already replaced
  - one of them by ninety minutes. The hand-written paragraph that
  fixed it is now a slot; fill it.
- **Fill it from your own landings, and judge what belongs in it.**
  Every `[complete]` journal entry already carries the bead, the sha and
  what merged, so the campaign case costs remembering rather than
  research; for a bead filed long before the campaign, the file's
  history since the bead was created is the same lookup. What the slot
  carries is the file, the merge sha that moved it, the section that
  changed, and the instruction to prefer the current text over the
  bead's description of it. WHICH moved files matter to a given bead is
  your judgement and does not reduce to a list of shas: a rewrite of a
  neighbouring section is noise, and pasting every landing into every
  dispatch buries the one entry the worker needed to read. And when
  nothing moved, say that - for the same reason a non-contending gate
  gets an explicit negative: a worker that sees no slot cannot tell
  "nothing moved" from "the conductor did not check".
- **Worktrees**: create via the wurk:kit script
  (`worktree_create.rb`, `--base <integration-branch>` for stacked/
  local-only work) - not raw git; the kit seeds and warms. Do not run
  many warms concurrently with a live gate - warms include a full test
  run and will contend (DB sandbox failures at 4x on one machine).
- **Gate semaphore - first decide whether gates contend at all.** A
  semaphore exists because concurrent gate runs INTERFERE: they
  saturate the CPU, bind the same fixed port, share one database
  sandbox or one docker daemon, thrash one build cache. Contention is
  the condition, not slowness. Duration is the proxy you will reach
  for from the Phase 0 measurement, and it is a good one - a gate long
  enough to still be running when the next worker starts one is a gate
  that gets the chance to interfere, and a few-second suite usually
  does not - but hold on to what it is a proxy FOR, or a fast gate
  that binds a fixed port reads its own three seconds as permission to
  skip a lock it needs on the first overlap. Whether gates contend in
  THIS repo on THIS machine is a judgement, made by you before you
  dispatch; the measurement informs it and never makes it.
- **When they do not contend, say so in the dispatch.** A gate that
  neither contends nor outruns the foreground cap runs under NO
  semaphore: no campaign mutex, no repo lock, no machine slots, no
  lock dir of any kind. Silence is not enough. A dispatch that merely
  omits the semaphore leaves the worker to guess, and the observed
  guess is to build one - a lock dir, a bounded wait, a watchdog
  around a three-second test suite, the same improvised machinery the
  foreground rule exists to stop. Fill the gate-semaphore slot with
  the explicit negative instead, carrying the measured number so the
  worker can see why: "NO semaphore, no lock dir, no slots - gate
  measured at Ns; run it foreground and build no coordination around
  it."
- **When they do contend - two caps, two locks.** Every dispatch names
  the lock dirs a gate run must hold (mkdir-mutex, bounded wait as an
  explicit named override of the worker no-sleep rule,
  always-release). Two different caps are in play, and one lock dir
  cannot enforce both:
  - the **per-campaign concurrency cap** - how many gates YOUR campaign
    runs at once - enforced by a **campaign mutex** keyed to the
    campaign id;
  - the **machine-wide cap** - how many gates run at once across ALL
    campaigns, yours and anyone else's - enforced by the shared
    **machine gate slots** (`--slots-dir` + `--slots N`). The machine
    slot count comes from the machine config's `machine.gate_slots`
    when set; `--slots N` relayed from a fleet manifest is only the
    fallback, and a `slots_overridden` warning in the acquire envelope
    means the relayed number was not the one used.
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
- **Short gate or long gate - you decide, before you dispatch.** Hold
  the Phase 0 measurement against the host's Bash timeout cap
  (600000ms) - that run is the budget, and there is no second one.
  Under the cap it is a short gate and the foreground rule stands
  unchanged. At or over the cap - including a budget close
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
- **Name a report file in every dispatch.** Fill the appendix's REPORT
  slot with an absolute per-bead path `<reports dir>/<bead-id>-report.json`.
  The reports dir sits inside the campaign state dir (Journal and
  morning report, above) - excluded, never committed - defaulting to
  `.claude/campaigns/reports/<campaign-id>/` when the project's fleet
  manifest names no `campaignState.reports`; mkdir it before the first
  dispatch. The file is the record; the worker's returned message,
  task-notifications, SendMessage replies and Monitor events are hints.
  Reason: another harness measured dropped notifications in production,
  and a conductor that treats a notification as the record learns about
  a finished worker only when it happens to look.
- **Pick the worker's model tier per dispatch, from the rubric, and
  pass it on the Agent call.** `wurk-repo-worker`'s frontmatter says
  `model: opus`; that is the agent's default when nothing is passed,
  and it is not the rubric. The rubric is this bullet, and it is your
  judgement per bead: the Agent call's `model` parameter overrides the
  frontmatter, so every dispatch passes `model` explicitly, never
  leaves it to the default. The tier names are the two the stage
  contract in `/wurk:work` already uses, `sonnet` and `opus`; nothing
  here is read from the manifest, because the only stage model that
  differs per project is `models.direction`, and a conductor dispatch
  is workflow policy, not a per-project value.

  **`sonnet` only when every one of these holds**, and `opus` the
  moment one does not:
  - the change is fully specified - the bead says what to write and
    where, and the worker has nothing left to decide about the shape;
  - it touches tests, config, or docs, or at most three runtime
    files, by your own reading of the bead against the tree (the
    number is a proxy for blast radius, and a one-file change to a
    shared contract is still `opus`);
  - it needs no design call and no interpretation of authority,
    consent, or policy - a bead that asks the worker to "decide the
    right shape", or whose acceptance turns on a reading of a rule,
    is `opus` however few files it names;
  - success is tool-checkable: the gate, a grep, a script's envelope
    can say it is done, so the worker never has to judge its own
    result;
  - it is not the first of a look-alike series. When the campaign
    carries a run of beads that apply one pattern across N places, the
    FIRST goes to `opus` so the pattern gets set by the stronger model,
    and the rest may go to `sonnet` with the landed first as their
    example. This clause comes from another harness's rubric, where
    the first-of-series exception was the finding that paid for the
    rest of it.

  Two properties worth holding on to. The tier governs the worker's OWN
  turns - reading the bead, weighing the dispatch, the verify pass, the
  PR body, everything between skill invocations; each wurk skill it
  runs pins its own model in its frontmatter for the turn it is active,
  so a `sonnet` worker still gets `/wurk:work`'s stage tiering underneath
  it, and an `opus` worker's implement subagents are still `sonnet`.
  And the rubric is a floor on caution, not a budget target: a bead you
  cannot confidently place is `opus`, and the reason you journal says
  which clause failed, not "default".
- **Journal the tier and the one-line reason next to the dispatch.** The
  `[dispatch]` journal line carries the tier chosen and the reason in
  one line, in the rubric's own terms ("sonnet: docs-only, fully
  specified, gate-checkable" or "opus: needs a design call on the
  manifest shape" or "opus: first of the three-bead rename series").
  The reason is what makes the tier auditable at retro - a campaign
  whose `sonnet` dispatches stalled can be read back against the
  clause that let them through - and it is what the stall ladder's
  escalation rung reads to know whether a stalled worker has a step
  left above it. A dispatch with a tier and no reason is a
  `[conductor-error]` on yourself.

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
3. Tier escalation, once, for a `sonnet` worker only: when the worker
   that stalled twice was dispatched at `sonnet` (the `[dispatch]`
   line's tier says which), do not spend a third resume on it. Retire
   it, and redispatch the SAME bead ONCE under `opus`, into the SAME
   worktree, with the takeover brief from rung 4 - the worktree's
   committed and uncommitted state is the escalated worker's starting
   point, not a fresh cut. Journal it as a `[dispatch]` whose tier is
   `opus` and whose reason names the escalation and what stalled
   ("opus: escalated from sonnet after two stalls on the gate wait").
   This rung has exactly one step: an `opus` worker that stalls has
   nothing above it and goes to rung 4 directly, and the escalated
   `opus` worker stalling again is rung 4, never a second escalation.
   The reason is the whole point of the bound - a stall that survives
   the stronger model is not a model problem, and rerolling tiers
   would hide that from the retro.
4. Third stall: retire the worker; inspect the worktree yourself;
   dispatch a FRESH worker with a takeover brief (verified worktree
   state, committed-vs-uncommitted inventory, "read uncommitted edits
   critically", "stand down any live writer first"; workers run
   /wurk:verify --unattended after implementation - it machine-checks
   and fixes what it can, and human-only items stay deferred). The
   fresh worker's tier is the rubric's answer for the bead as it now
   stands, and a bead that has stalled a worker is by that fact no
   longer fully specified: it goes to `opus`.

After any mixed-writer episode: full gate against HEAD; provenance
listed in the result/PR body.

### Sweep on every wake, and a heartbeat so wakes happen

Every wake - a task-notification, a SendMessage reply, a Monitor event,
a Monitor expiry, a resume, an operator message - triggers a sweep of
the WHOLE running set, not just the bead the wake names. Sweep = for
each running bead read three things: the report file (exists? then read
it and land the bead as a [complete] or [state] entry exactly as if the
notification had arrived), the report dir's mtimes (`ls -lt <reports
dir>`), and the newest commit / mtime in the bead's worktree (`git -C
<worktree> log -1 --format='%ci %h %s'`, plus `git status --porcelain`
for uncommitted movement). Journal the sweep briefly as [state] when it
changes anything.

The heartbeat: notifications are hints, so do not wait for one. Arm a
Monitor whose only job is to wake you on a clock, and re-arm it at
every expiry (the expiry notice is itself a wake):

    Monitor({
      command: "while true; do sleep 600; echo \"heartbeat $(date -u +%H:%M)\"; done",
      description: "campaign <id> heartbeat - sweep report files and worktrees",
      timeout_ms: 1800000
    })

The harness caps a Monitor at 30 minutes, so re-arm on expiry; a
heartbeat interval of 10 minutes keeps sweeps well inside the staleness
threshold below. This Monitor is the conductor's clock, NOT a gate
wait: the worker's rule that a Monitor is never the wait mechanism for
a gate stands unchanged; this one waits on nothing and merely
guarantees the sweep runs.

### Staleness

The threshold is a campaign-file field, `staleness_minutes`, default
50; a fleet manifest may set `policy.stalenessMinutes` as the
fleet-wide default (REFERENCE.md documents the key), and the campaign
file wins when both are set. Journal the value in force at Phase 0
alongside the gate measurement.

A running bead with NO report file, NO commit or worktree mtime fresher
than the threshold, and NO fresh journal event of its own is
stale-by-evidence. That is a trigger to LOOK, never a verdict: check
directly - ListAgents (or the harness equivalent) for the worker's
liveness, `git -C <worktree> log -1` and `git status --porcelain` for
movement, `ps` for a live gate process rooted in that worktree - before
assuming the worker alive OR dead. Journal the check as [stale] with
what each probe returned.

Both silent (no live agent, no movement) -> the worker is dead; take
the escalation ladder above from rung 4 (retire, inspect, fresh worker
with a takeover brief), or from rung 3, the one-step tier escalation,
when the dead worker was a `sonnet` dispatch. One alive -> journal
[stale] with the evidence and keep waiting; a slow gate or a long
implement phase is not a dead worker. Resist the pull to redispatch on a stale mtime alone: a
duplicate worker on a live bead is the collision Phase 3's probe exists
to prevent, and this time you would be the peer.

Why 50: another harness settled on the same order of magnitude (45-60
minutes) after measuring the gap between a worker's last visible
movement and its completion; shorter thresholds redispatch onto live
workers during long gates, longer ones leave a dead worker's bead idle
for an hour.

### Resume from state, never re-triage

1. State before graph. On any resume (a new session picking the
   campaign up, or your own continuation after a context loss) read the
   campaign state FIRST - the journal's last render and every event
   since it, the campaign file, the registry row when there is one -
   and reconstruct the running set from it. Do not re-run Phase 1 and
   Phase 2 from scratch: a re-triage re-dispatches beads that are
   mid-flight, because the graph does not know a worker exists. The
   journal is what "resumable from the journal alone" (Journal and
   morning report) is for.
2. Report files before ListAgents. For every bead the state says is
   running, read its report file first - a finished worker whose
   notification was dropped is fully described there and lands
   normally - then the worktree, then ListAgents. A live agent listing
   tells you a process exists; it does not tell you what it finished.
3. Redispatch only when both are silent. A bead with no report file AND
   no live worker (per the Staleness checks above) is the only bead a
   resume redispatches, and it goes through the takeover brief (rung
   4, or the one-step tier escalation at rung 3 when the dead worker
   was a `sonnet` dispatch), never a fresh Phase 3 dispatch that
   ignores the worktree's uncommitted edits. Everything else keeps its
   worker and waits for the next sweep.

A resume's first journal entry is a [state] render saying what was
reconstructed and from which files, so the next resume can verify it.

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

MR mode: where the operator's consent quotes a carve-out letting the
conductor merge this campaign's requests, merge with the journaled
merge method from Phase 0 and never with one the forge disallows;
without such a carve-out the operator merges (the mode's default) and
the conductor only verifies. Either way: verify merge via the forge,
pull, close bead (queue the close if the tracker links it to work
elsewhere; a pre-decided supersede/absorb lands as supersede-then-close,
below), remove worktree, delete the remote branch only where the
forge left one, run the manifest's outbound scan over the full
tracker export (see Outbound content - the push unit is the whole db,
not the beads this campaign touched), push tracker with confirmed
output - but only where the repo's `beads.sync` is `git` or
`dolthub`. Under `local` (including an unset key, which defaults to
`local`) there is no tracker push at all: journal "tracker is local-only,
nothing pushed" and land the rest. The conductor owning tracker pushes
never means it may make one the repo's manifest forbids.

Supersede-then-close, both modes: the tracker enforces its edges at
close time - `bd close` on a bead with an open blocker is refused
("blocked by open <id>") no matter what the invocation decided, so a
bead dispatched on a pre-decided supersede/absorb fork cannot land as a
plain close. Resolve the edge first, exactly as the journaled
pre-decision named it: `bd supersede <blocker> --with <bead>` (closes
the blocker with a reference to its replacement), or the absorb
resolution the pre-decision spelled out; then close the bead. The
pre-decision must already be in the journal verbatim (the Invocation
section requires it before the first dependent dispatch); a supersede
with no journaled pre-decision behind it is stop-and-queue, never a
conductor judgement, because closing someone else's bead is a decision
the operator makes. Journal the supersede as its own landing line.

When Phase 0 journaled that the forge deletes merged branches, "remote
ref does not exist" against a request the forge reports merged is the
expected outcome - journal it as success, not as an error to retry or
investigate. The local branch goes with the worktree (the kit's
worktree_cleanup.rb removes it on the forge's merged signal).

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
    [ruling-queued] [stale]

`[dispatch]` carries (bead, worktree, model tier, the one-line tier
reason from Phase 3's rubric; on an escalation, the rung it came from).
`[complete]` carries (bead, PR-or-merge, base, sha, gate, scan,
bead-status). `[stale]` carries (bead, minutes since last
report/commit/journal movement, each liveness probe and what it
returned, decision). `[operator]` records mid-campaign operator
instructions with the scope you gave them; when it is a consent
carve-out, quote it. An event fitting no type: nearest type + a retro
schema-gap entry.

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
  branch <name>, verify via git branch --show-current", or "none". When
  the worker cuts its own: /wurk:branch's create-and-warm step runs the
  base preflight (`parallelism.preflight`, default true, docs/manifest.md)
  on every cut, and a `blocked preflight_refused` with
  data.preflight.reason in {local_default_diverged,
  default_checked_out_elsewhere, fast_forward_failed} is
  stop-and-report - never a reset of the default branch, never a
  manifest opt-out.>
- <per-repo hazard slot, or "none">

<Moved-files slot - fill exactly one, and never leave it empty. The
bead describes the tree as it stood when it was FILED; what expires is
that description, never the bead's premise.
MOVED: "the file MOVED under you: <path> was rewritten by <bead/change>,
merged as <sha>, in <section> - <repeat per file>. Your worktree is cut
from those merges. READ THE CURRENT TEXT and work the bead's problem
against it; do not apply the bead's description of what the file used
to say."
NOT MOVED: the explicit negative - "<path(s)> unchanged since this bead
was filed - checked against this campaign's landings and the file's
history since.">

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
<Gate-semaphore slot - fill exactly one, and never leave it empty.
CONTENDING GATES: the campaign mutex dir, the repo gate-lock dir
and the slots dir + slot count, acquired in that fixed order (campaign
mutex, then repo lock, then machine slot) via `lock.rb acquire` and
released in reverse; bounded-wait shape, always-release, staleness =
report not break.
NON-CONTENDING GATES: the explicit negative - "NO semaphore, no lock
dir, no slots - gate measured at Ns; run it foreground and build no
coordination around it.">
<Known-flake slot.> Never truncate a failing gate.

MECHANICS: Append-only bead notes (bd note). Absolute paths. Branch
names from git branch --show-current. Empty output is unconfirmed -
re-run. Prefix scratchpad files with your bead id. Never wait on
detached background work. Halt if foreign commits appear on your branch.

TIER: <the model tier this dispatch runs at, `sonnet` or `opus`, and the
one-line reason - the same pair the [dispatch] journal line carries. On
an escalation: "opus, escalated from a sonnet dispatch that stalled at
<what>; the worktree below is that worker's, read its uncommitted edits
critically.">

RETURN: the wurk-repo-worker structured JSON result exactly, including
repos_touched (audited against this dispatch's scope).

REPORT: write that same JSON result to <absolute report file path> as
your literal last action - after the commit, the MR when authorized,
and the bead notes, and after killing your own children by PID. The
file is the record; your returned message is a hint. Never create or
touch it early.
```

Slots filled per dispatch: repo dir, bead id, ground-truth delta,
model tier and its reason (also passed as `model` on the Agent call),
linkage entries (fleets), policy block, mode/MR authorization, stacking
base, moved files (or the explicit "unchanged"), gate path (short or
long, from the measured budget), gate-semaphore details, known flakes,
report file path.

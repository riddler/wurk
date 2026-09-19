# wurk:conductor reference

Companion to SKILL.md. Three contracts the skill relies on: the
multi-campaign protocol and the linkage-ledger schema, both extracted
from a consumer fleet's `.claude/fleet/` docs after surviving twenty-odd
campaigns (the consumer keeps its own copies with its own history
notes), and the campaign-file schema that `campaign_state.rb` reads so a
scheduler can pick an armed campaign without parsing markdown. Nothing
here is consumer-specific.

The fleet manifest (`.claude/wurk-fleet.json`) is documented at
`docs/fleet-manifest.md` in the wurk repo and linted by
`ruby ~/.claude/skills/wurk:kit/scripts/lib/fleet_manifest.rb check`;
the field names used below (`multiCampaign`, `depOverride`,
`campaignState`, `policy`) are the ones the skill reads, and that
document names the reader of every field.

## Multi-campaign protocol

Lets more than one campaign run at once, each from its own conductor
session. Binding on every campaign once a project declares a
`multiCampaign` block.

### 1. The registry

The registry file (`multiCampaign.registry`, conventionally
`campaigns/ACTIVE.md`) is a registry, not a single pointer. One row per
campaign: id, status, conductor claim, declared footprint, journal file.
Statuses:

- **DRAFTED** - plan exists, consent draft empty. Never dispatched.
- **ARMED** - consent quotes recorded; runnable.
- **RUNNING** - a conductor session has claimed it (claim = write your
  session date/identifier into the row at Phase 0).
- **WRAPPED** - morning report + retro done; row kept for the record.
- **ABORTED** - stopped on an environment fault before landing anything;
  report + retro still written; the fault is the queue's first item.
  Re-armable once cleared; holds any campaign queued behind it.

Registry edits are read-modify-write under the registry lock
(`locks/registry/`, mkdir-mutex, held only for the edit). A conductor
claims exactly one campaign, releases the claim at wrap, and never
edits another campaign's row except to correct a verified-stale claim
(dead session), journaled.

**Bare invocation:** with exactly one ARMED campaign and none RUNNING
that the invocation could mean, run it. With more than one plausible
target, stop and ask the operator - never pick. When several campaigns
are armed or running, the operator dispatches explicitly:
`/wurk:conductor campaign <id>`.

### 2. Footprints

Every campaign plan declares its **footprint**: the repos (checkouts,
worktree dirs, trackers) it may write. Rules:

- Two RUNNING campaigns' footprints must be disjoint. Overlap is an
  operator ruling BEFORE either dispatches into the shared repo, never
  a conductor judgment call.
- Project-level fleet state (journal dir, registry, linkage ledger,
  locks) is shared by design and governed by this protocol's locks.
- A discovered dependency landing in another repo is filed in the
  owning repo's tracker under the tracker lock (rule 3). If that
  tracker is inside another RUNNING campaign's declared footprint,
  file locally and QUEUE the push for the operator (or that campaign's
  conductor via the operator) instead - never push into a live
  campaign's tracker from outside it.

### 3. Locks - resource-keyed, campaign-agnostic

All locks live under `multiCampaign.locksDir` and are keyed by the
RESOURCE, not the campaign, so two campaigns contending on one resource
wait on the same lock:

- `locks/gate-<repo-dir>/` - full gate or worktree warm in that repo.
  One at a time per repo.
- `locks/tracker-<repo-dir>/` - tracker push/pull for that repo.
  Serializes cross-campaign tracker writes.
- `locks/machine-gate-slots/slot-1/`, `slot-2/`, ... - at most
  `multiCampaign.machineGateSlots` concurrent full gates/warms
  machine-wide - the preferred source for that count is the machine
  config's `machine.gate_slots` (`~/.claude/wurk.local.json`), which
  `lock.rb acquire` takes over a relayed `--slots N` and flags with a
  `slots_overridden` warning when the two differ; the manifest number
  is the fallback for a box that sets none. (Warms at 4x on one machine
  produced DB-sandbox failures.) A heavy run acquires the repo gate
  lock FIRST, then any free slot; release in reverse order. Fixed
  acquisition order prevents deadlock. A campaign that caps its own
  concurrency below the machine cap takes its campaign mutex before the
  slot.
- `locks/registry/` - rule 1.

Owner-file discipline: the owner file carries `campaign=<id> bead=<id>
pid=<pid>`; 10s polls (30s starves); re-read the owner before any
staleness conclusion; never remove a lock you did not create;
ownerless locks are resolved by a conductor after an owner re-read and
journaled. A conductor may clear a verified-stale lock owned by ANOTHER
campaign only after the owner re-read plus a liveness probe (lock mtime
vs `ps` for a live gate process), and must journal it in BOTH
campaigns' journals (`[cross-campaign]` event, rule 5).

Locks are held across wurk:commit's internal gate re-run.

### 4. Journals, reports, ledger

- Journal file per campaign: `journal/<date>-campaign-<id>.md`.
- Morning report: `journal/<date>-morning-report-campaign-<id>.md`.
  A bare `<date>-morning-report.md` name is retired - two campaigns
  can wrap on one date.
- Every linkage-ledger entry carries a `campaign` field.
- Journal event type `[cross-campaign]` for anything one campaign does
  that touches another's state (stale-lock clears, queued tracker
  filings, footprint questions). Written to both journals.

### 5. Consent and corrections stay campaign-scoped

Each campaign has its own consent doc; nothing carries across
campaigns, and a conductor never messages another campaign's workers.
A mid-flight operator instruction names the campaign it applies to; if
it plausibly applies to more than one, each conductor journals it
`[operator]` with the scope the operator gave THEM, and asks when
unclear.

### 6. Worktrees and branches

Worktree dirs are per-repo (the manifest's `parallelism.worktrees_dir`)
and branch names carry bead ids, so disjoint footprints cannot collide.
Do not relax either convention.

## Campaign files and `campaign_state.rb`

A campaign is a directory of markdown files, `.claude/campaigns/` by
default (excluded from git via `.git/info/exclude`, per SKILL.md's
"Campaign state lives outside what the campaign publishes"; a fleet may
keep it elsewhere and passes that path). The kit script
`campaign_state.rb` (`ruby ~/.claude/skills/wurk:kit/scripts/campaign_state.rb`)
reads this directory and answers, in one JSON envelope, the question a
scheduler asks before it may start a campaign unattended: which
campaigns are ARMED, what they cover, whether their consent is adopted,
and whether one is already running. It is the machine-readable side of
the registry statuses in rule 1 above. What it never does: invoke the
conductor, take or release a lock, or write a consent file.

### The files it reads

| File | Role | How it is recognized |
|---|---|---|
| `<id>.md` | the plan | a top-level `*.md` whose first H1 is exactly `# Campaign <id>`, with `<id>` equal to the file's basename |
| `<id>-consent.md` | the consent, a human artifact | by name, next to the plan; its H1 is `# Campaign <id> consent` so it is never mistaken for a plan |
| `<locks-dir>/campaign-<id>/` | the campaign mutex | a `lock.rb` directory (`--campaign-mutex`); `<locks-dir>` defaults to `<campaigns dir>/locks`, a fleet passes `multiCampaign.locksDir` as `--locks-dir` |

Reports (`<id>-report.md`), journals (`journal/`), and any other document
under the directory are ignored because their H1 does not name their own
basename as a campaign - there is no exclusion list to maintain.

### The Status line - the plan's front matter

The plan's front matter is one line, the first line of the file that
starts with `Status:`, in the shape the conductor already writes by hand:

    Status: ARMED 2026-09-14 18:41 -0600 (consent adopted verbatim in the conductor session). Arming was ...

The grammar is `Status: <WORD> [<stamp>] <anything>`. `<WORD>` is one of
`DRAFTED`, `QUEUED`, `ARMED`, `WRAPPED`, `ABORTED`; `<stamp>` is a date, optionally with a
time and zone offset (`2026-09-14`, `2026-09-14 18:41 -0600`); everything
after the stamp is prose (except that on a QUEUED line the stamp may
be followed by `after <id>`, naming the plan this one queues behind -
see "Queueing" below). A plan with no Status line reads as `status:
null` and is treated as DRAFTED. A word outside the vocabulary is
reported verbatim with an `unknown_status` warning and is never treated
as armed. There is no YAML front matter and no second schema: the
Status line the conductor has always flipped by hand is the schema, and
the script edits exactly that line.

`RUNNING` is deliberately not a Status word. A campaign is running when
its mutex directory is held by a live holder (`lock.rb`'s probe, not
stale); that is a fact about the lock dir, not something a file can claim
about itself, so the script derives it and the file never records it.

`ABORTED` is the wrap of a run that stopped on an environment fault
before landing anything (the `--armed` section's "An abort is ABORTED,
never WRAPPED"). It is not armed, so the scheduler never restarts it
into the same fault; it never satisfies a successor's queue (below); and
it is the one terminal word `arm` accepts, with a `re_armed_after_abort`
warning, because re-arming after the operator clears the fault is what
the status is for. `WRAPPED` stays un-re-armable by script.

The consent file carries the same line shape with the words `DRAFTED` and
`ADOPTED`. Only `ADOPTED` counts.

### Queueing - one campaign behind another

A scheduler keying off `armed` refuses when two plans are ARMED at once
(deliberately: two ARMED plans is an ambiguity only the operator can
resolve). That made "run B tonight, after A wraps" need a human awake at
the handoff. `QUEUED` closes that gap:

    Status: QUEUED 2026-09-16 21:30 -0600 after 042

A QUEUED plan reports `armed: false` - invisible to the scheduler -
until its predecessor (`<after>.md`, same campaigns directory) is
`WRAPPED` **and** the predecessor's mutex is not live-held. Then it is
*virtually promoted*: the record reports `armed: true` and (with an
ADOPTED consent) turns up in `data.runnable`, with no file write. The
file still says QUEUED while the successor runs; the wrap flips it to
WRAPPED as usual. The mutex condition matters because WRAPPED is flipped
while the conductor still holds the mutex - the successor must not start
inside that window.

A missing or invalid predecessor holds the queue (warning
`queue_predecessor_missing`), never releases it - a typo must fail safe.
An `ABORTED` predecessor holds it too (`queue_predecessor_aborted`):
whatever stopped the predecessor is still in the environment, and one
measured night a successor promoted on an abort ran straight into it.
`QUEUED` with no `after` id also holds (`queued_without_after`). Chains
(`044 after 043 after 042`) advance one wrap at a time, because
satisfaction requires the predecessor to be WRAPPED, not merely armed.
The record carries `queued`, `queued_after`, and `queue{after,
satisfied, predecessor_status, predecessor_exists, predecessor_machine,
predecessor_machine_match}` so a scheduler's status display can say what
it is waiting for.

A predecessor bound to another machine (or one this machine cannot
verify) holds the queue too, with a `queue_predecessor_remote` warning:
WRAPPED-and-unheld on this filesystem is not proof the predecessor is
actually done when its mutex lives on a machine this one cannot see. See
"The Machine line" below for the binding itself.

### The Machine line - binding a plan to one machine

A plan file may carry one more line, anywhere, at column 1:

    Machine: mbp

This opts the plan into a per-machine gate on top of everything above.
`campaign_state.rb` parses the first such line and, only for a plan (or,
via queueing, a predecessor) that carries one, compares it against this
machine's own name - the kit's `~/.claude/wurk.local.json` `machine.name`
(`lib/user_config.rb`; see `docs/machine-config.md`). A harness that
mirrors that key in its own config should read this script's answer
rather than compare itself - the mirror is known to drift (ADR-0013).

The comparison resolves to one of four `machine_match` values, carried
on the record:

- `unbound` - no `Machine:` line. Behaves exactly as before this
  feature existed: today's behavior for every existing fleet and every
  single-machine consumer is unchanged.
- `this_machine` - the binding equals this machine's own name.
- `other_machine` - the binding names a different machine. This is the
  normal state of a shared, git-tracked campaigns dir with a
  gitignored, per-machine locks dir: the plan is visible, its binding
  is visible, and it is neither armed nor runnable here. No warning is
  emitted for this state on its own - it is not an error, just not this
  machine's plan to run.
- `unverified` - the binding is present but cannot be resolved: either
  the line names no machine (a blank `Machine:`, `machine_binding_blank`)
  or this machine has no `machine.name` set, or its
  `wurk.local.json` is invalid (`machine_name_unset` /
  `user_config_invalid`). Fail-safe by design: the failure this feature
  exists to prevent is two conductors on one campaign, and a machine
  that cannot prove a bound plan is its own must decline rather than
  guess. `machine_name_unset` and `machine_binding_blank` are only
  raised for a plan whose status is ARMED or QUEUED - a DRAFTED plan
  bound to an unnamed box is not news.

`armed` is gated by this on top of the existing Status/queue rule:
`(Status ARMED, or a satisfied queue) AND machine_match in {unbound,
this_machine}`. A plan bound elsewhere counts toward neither the
unattended invocation's zero-ARMED refusal nor its more-than-one refusal
(see "The unattended invocation reads this record" below) - it is
simply not `armed` here.

Resolution is lazy and read exactly once per invocation: an unbound plan
never touches `wurk.local.json` at all, so a machine with no config file,
or an invalid one, sees no difference in behavior on any plan that does
not opt in. There is no hostname fallback anywhere in this path - a
hostname that differs from the operator's chosen `machine.name` would
match nothing and be hard to debug, so the only source of "this
machine's name" is the config key itself.

`arm --host NAME` (below) is the one writer of the `Machine:` line - a
plan is never bound by hand-editing the file, and never bound to a name
other than the arming machine's own.

### Subcommands

Every subcommand takes `--dir DIR` (repeatable; default `.claude/campaigns`
under the current directory) and `--locks-dir DIR`.

- **`list`** - read-only, always exits 0. `data.campaigns[]` carries one
  record per plan (below), sorted by id; `data.runnable` is the list of ids
  a scheduler may start: `armed && consent.adopted && !running`. A missing
  directory is an empty list plus a `campaigns_dir_missing` warning, not a
  block - "nothing is armed" is a complete answer.
- **`show ID`** - the same record for one campaign, under `data.campaign`.
  Blocks `campaign_not_found` when no plan matches.
- **`arm ID`** - rewrites the Status word and stamp to `ARMED <now>`,
  keeping the rest of the line; inserts a Status line after the H1 when
  the plan has none. Refuses `consent_not_adopted` (needs: human) when the
  consent file is missing or not ADOPTED - arming is the permission a
  scheduler acts on, and the script never manufactures the consent that
  makes it legitimate. Refuses `campaign_wrapped`; an ABORTED plan re-arms
  with a `re_armed_after_abort` warning. Already armed: ok,
  `changed: false`, warning `already_armed`. `--dry-run` reports the
  rewrite in `commands` and touches nothing. With `--after ID`, writes
  `QUEUED <now> after ID` instead (refusing `queued_after_self`); plain
  `arm` on a QUEUED plan is the manual promotion path and flips the file
  to `ARMED <now>` even when the queue already reports it virtually
  armed.

  A plan bound to another machine, or one this machine cannot verify
  ("The Machine line" above), is refused before the consent check:
  `bound_to_other_machine`, or `machine_name_unset` /
  `machine_binding_blank` (needs: human either way) - the binding is
  the claim "this machine will conduct it", only the machine making
  the claim can arm the plan, and a typo'd foreign name would silently
  strand it. Rebinding an already-bound plan away from that claim is a
  hand edit of the `Machine:` line, not something `arm` does.

  `--host NAME` binds the plan to this machine as part of the same
  arm (and composes with `--after`): NAME must equal this machine's
  own `machine.name` (`~/.claude/wurk.local.json`, loaded the same way
  `lock.rb acquire` loads it) or arm refuses `host_not_this_machine`
  (NAME and the actual name, both named in the message) or
  `machine_name_unset` (no `machine.name` set - the message names the
  key) or `user_config_invalid`. The OS host name is never consulted.
  The Status write and the Machine write are independent - each
  happens only if it actually changes the file, so `arm --host <me>`
  on an already-ARMED unbound plan writes only the `Machine:` line
  (Status untouched, `already_armed` still warned, `changed: true`),
  composed with the Status write into one atomic write when both
  apply. `data.machine_before` / `data.machine_after` join
  `data.before` / `data.after`.
- **`disarm ID`** - rewrites the Status to `DRAFTED <now>` the same way.
  Refuses `campaign_running` while the mutex is live-held: the conductor
  holding it has already read ARMED and the file flip would only mislead
  the next reader. Not armed: ok, `changed: false`, warning `not_armed`.
  `--dry-run` as for `arm`. The consent file is never touched, and neither
  is the `Machine:` line - a disarmed plan keeps its binding. Refuses the
  same `bound_to_other_machine` / `machine_name_unset` /
  `machine_binding_blank` set as `arm`, before the `campaign_running`
  check: this machine cannot see a foreign machine's mutex, so a disarm
  from here cannot know whether a conductor there already read ARMED.

Both mutations write via a sibling temp file and rename, so a concurrent
`list` sees the old file or the new one.

### The campaign record

```json
{
  "id": "260914-example",
  "path": "/repo/.claude/campaigns/260914-example.md",
  "title": "# Campaign 260914-example",
  "status": "ARMED",
  "status_stamp": "2026-09-14 18:41 -0600",
  "machine": null,
  "machine_match": "unbound",
  "armed": true,
  "running": false,
  "runnable": true,
  "mode": "MR mode. Each bead ends in /wurk:mr with an open PR.",
  "scope": "In scope (2): zz-1 zz-2\nExplicitly out: every other open bead.",
  "consent": { "path": "...-consent.md", "exists": true, "status": "ADOPTED", "status_stamp": "2026-09-14 18:41 -0600", "adopted": true },
  "mutex": { "dir": "/repo/.claude/campaigns/locks/campaign-260914-example", "held": false, "owner": null, "age_seconds": null, "holder_alive": null, "stale": false, "staleness_reason": null }
}
```

`mode` and `scope` are the bodies of the plan's `## Mode` and `## Scope`
sections (heading prefix match, blank lines trimmed at both ends,
indentation kept), or `null` when absent. `mutex` is `lock.rb status`'s
payload plus `dir`. `arm` and `disarm` add `data.before`, `data.after`
(the Status words), `data.changed`, and `data.dry_run`, and re-read the
record after a real write so `data.campaign` reflects the file.

Warnings a caller should surface: `consent_missing` (ARMED with no
consent file), `stale_mutex` (held but provably stale - not counted as
running; `lock.rb clear` is the tool for that, never this script),
`unknown_status`, `machine_name_unset` (bound, but this machine has no
`machine.name`), `machine_binding_blank` (a `Machine:` line naming no
machine), `queue_predecessor_remote` (queued behind a predecessor bound
elsewhere or unverifiable here), `user_config_invalid` (this machine's
`wurk.local.json` failed validation - only surfaced for a bound plan).

### The unattended invocation reads this record

`/wurk:conductor --armed` (SKILL.md, "`--armed` - the unattended
invocation") is the consumer of `list`: it counts the records with
`armed: true` (zero refuses `nothing_armed`, more than one refuses
`ambiguous_armed` - the bare-invocation rule in rule 1 above, applied
without a human to ask), then reads the one record's `consent.adopted`
(false refuses `consent_not_adopted`) and `running` (true refuses
`campaign_running`; a `stale_mutex` warning is handed to `lock.rb clear`
first). A plan bound to another machine, or one this machine cannot
verify, is never `armed`, so it counts toward neither the zero-ARMED
refusal nor the more-than-one refusal above - it is simply absent from
the count. The survivor is `data.runnable`'s single member. The session then
takes the campaign mutex at `mutex.dir` for its whole life, which is what
turns `running` true for the next `list`, and releases it after the
morning report. A mutation this mode never performs: `arm`, `disarm`, or
writing a consent file - it reads what the operator set and refuses when
that is not enough.

### The plan's sections - the rest of the schema

`campaign_state.rb` reads four things out of a plan: its H1, its
`Status:` line, and the bodies of `## Mode` and `## Scope`. Everything
else is read by a conductor, and the sections below are the ones the
phases in SKILL.md actually go looking for. A missing one fails no
script; it fails hours later, in a dispatch that had to guess.

| Section | Required | Who reads it |
|---|---|---|
| `# Campaign <id>` H1 | yes | `campaign_state.rb`; `<id>` equals the basename, and there is no colon after `Campaign` |
| `Status:` line | yes | `campaign_state.rb`; column 1, in the grammar of "The Status line - the plan's front matter" above |
| `Machine:` line | optional | `campaign_state.rb`; column 1, see "The Machine line - binding a plan to one machine" above |
| header block - id, mode, repo, tracker, drafted, armed, conductor, consent, journal | yes | humans, and the claiming conductor: the `conductor:` row is where a session writes its claim at Phase 0 |
| `## Goal`, carrying an explicit **Exit** condition | yes | Phase 6 and the morning report - the exit is how a reader decides the campaign is done |
| `## Consent` | yes | the pointer to `<id>-consent.md`, whose ADOPTED status is what `arm` reads |
| `## Mode` | yes | `campaign_state.rb`, and every dispatch's mode override |
| `## Scope` | yes | `campaign_state.rb`; this is the footprint the multi-campaign protocol's rule 2 compares between two RUNNING campaigns |
| `## Phase 0 preconditions` | yes | Phase 0, one numbered item per decision it owes |
| `## Waves` | yes | Phase 2's graph render, and the order every dispatch runs in |
| `## Hazards` | yes | Phase 1's claim check, and the dispatch template's per-repo hazard slot |
| `## Closing invariant` | yes | Phase 1, which rejects it unless it is a predicate over paths, and the bead that classifies against it |
| `## Inheritance` | successors only | SKILL.md's "A successor campaign - what a continuation inherits", under Invocation |
| journal path, outbound content, hard stops, retro targets | as they apply | Phase L, the Outbound content section, Phase 6 - a single-repo plan may fold the journal path into the header block, but a campaign with a scan command or a hard stop beyond the skill's own states it in its own section |

Then the rules. Every one of them was paid for by a plan that ran.

**Prose never asserts arm state.** `arm` and `disarm` rewrite the
Status line and nothing else, so a sentence claiming the campaign is
armed - or is not - drifts the moment either runs. One plan carried a
paragraph asserting the opposite of its own header for several hours
after it was armed, and a reader caught it, not the tooling. State the
precondition instead ("`arm` refuses unless the consent file reads
ADOPTED"), which is true whatever the status is.

**Say the mode word in the body of `## Mode`, not only in its
heading.** The heading match is a prefix, so `## Mode - <mode>` is a
legal heading and its suffix is discarded: the record carries the BODY.
A body whose first line is "Settled by the operator on <date>" gives a
scheduler's status display a record with no mode in it. Put the mode
word in the first line of the body and let the heading repeat it.

**Title the footprint section `## Scope`.** The multi-campaign protocol
calls the concept a footprint and a plan may use that word freely in
the prose, but the heading the script matches is `Scope`. A plan headed
`## Footprint` reports `scope: null` and a campaign comparing
footprints reads nothing.

**A fact that can move while the campaign runs is stated as a claim to
re-verify, never as a fact.** File lengths, bead counts, label sets,
request states, gate timings: each was true when the plan was drafted
and the campaign itself is what invalidates them. One plan's line count
for the file its own lane rewrote was 75 lines stale before the first
dispatch and more than 750 out by the last step. The form that works is the one a
gate measurement already uses - the number, then "re-measure at Phase 0
rather than trusting this line; it is a starting expectation, not a
substitute". That is also what makes the campaign-file claim check in
SKILL.md's "Phase 1 - Ground truth" a check rather than a re-read.

**A plan is drafted from a tracker pulled in the same sitting.** A `git
fetch` moves the code and nothing else: under `beads.sync` of `dolthub`
or `git` the tracker is its own remote, so a checkout brought a dozen
commits forward can sit beside a local db hours behind it, still
reporting beads as open whose close records landed with those commits.
One plan was drafted minutes after such a pull, read the open list, and
wrote two beads into its `## Scope` and a Phase 0 precondition as
near-neighbours to read; both had merged that morning. Phase 0's own
tracker pull cannot catch this, because it runs after the plan exists.
So pull the tracker before the survey that becomes the plan, and record
that you did: the `drafted:` header row carries the tracker stamp beside
the git sha - the sha the plan was drafted on, and the time the tracker
was last pulled or pushed - so Phase 1 can tell a fresh draft from one
whose bead states are a guess. A `drafted:` row carrying a sha and no
tracker stamp is the stale case until a reader proves otherwise.

**A hazard states its magnitude, because the magnitude is what the
planning uses.** "One bead carries both area labels" and "four beads
do" are the same hazard and two different wave plans. A hazard with a
count in it is also a claim under the rule above, and gets re-counted.

**The closing invariant is a predicate over paths, and its path list is
a claim like any other.** The rule itself is in SKILL.md; what belongs
here is the drafting consequence. One plan's invariant named a path
that had become a generated artifact and omitted four paths its own
beads legitimately touched - all four in-bead on audit. So draft the
invariant as the predicate (every path in the diff is attributable to a
campaign bead by its `Refs:` trailer, or to the default branch's own
movement) and treat any path list beside it as an expectation to
classify against, never as the definition of what is allowed.

**Amendments go in the consent file, dated, in the operator's words.**
The plan is edited freely while it is drafted; the consent quote is
not, because it is what every dispatch pastes verbatim. An amendment
that changes the quote records the date, what changed, what did not,
and the operator's instruction that authorized it - and says so
explicitly when the edit came after the operator had already said "as
written". A plan whose own body carries its amendment history splits
the record: the dispatch reads the quote, so the quote's history lives
with the quote.

**A rule that landed after the plan was drafted is named, not silently
inherited.** The installed skill text is authoritative and a plan can
neither opt out of it nor restate it usefully. What the plan CAN do is
add a Phase 0 precondition item naming each rule that landed since it
was drafted and what it means here - so a reader of the plan alone can
tell an inherited rule from an overlooked one, and so the conductor
does not discover at wrap that a status word changed meaning under it.
This is the same reasoning as the successor rule in SKILL.md, applied
inside one campaign's own drafting window.

**The template**, with every slot a placeholder - a plan is a
consumer-specific document and every value below comes from the
consumer's manifest, tracker or forge:

    # Campaign <id>

    Status: DRAFTED <date>
    Machine: <machine.name>          # optional - binds this plan to one machine; omit for the unbound default

        id:          <id>
        mode:        <MR | LOCAL-ONLY>
        repo:        <repo root, or the fleet's roster>
        tracker:     <bead prefix> (beads.sync = <local | git | dolthub>)
        drafted:     <date>, on <default branch> at <sha>; tracker pulled <time>
        armed:       <written by campaign_state.rb arm>
        conductor:   -            # the claiming session writes its id here
        consent:     <campaigns dir>/<id>-consent.md
        journal:     <journal dir>/<date>-campaign-<id>.md

    ## Goal

    <what the campaign is for.>

    Exit: <the condition under which it is done, checkable bead by bead.>

    ## Consent

    Lives in `<id>-consent.md`, the file `campaign_state.rb` reads and the
    only one whose ADOPTED status can arm this campaign.

    Carve-outs: <named, each naming the ONE bead it applies to, or "none">.

    ## Mode - <mode>

    <mode> mode. <what that means for branching, landing, the tracker push,
    and who merges.>

    ## Scope

        writes:  <every path, tracker and remote this campaign may write>
        reads:   everything else

    ## Phase 0 preconditions

    1. <sync state expected.>
    2. **Gate measured <date>: <result, wall clock>.** Re-measure at Phase
       0 rather than trusting this line; it is a starting expectation, not
       a substitute.
    3. **Gate path: <SHORT | LONG>.** <why, against the host's timeout cap.>
    4. **Gate semaphore: <NONE | the lock dirs and slot count>.** <what the
       run occupies, or the explicit negative.>
    5. <forge merge policy, read from the forge before the first landing.>
    6. **Rules landed on the default branch since this plan was drafted.**
       <each, with what it means here.>

    ## Waves

    <lanes and steps, serial or parallel, each step's beads with their
    priorities; the hazard for each bead that has one. Dependency edges are
    in the tracker - the plan orders what the graph does not.>

    ## Hazards

    - <each hazard, with its magnitude, as a claim Phase 1 re-checks.>

    ## Closing invariant

    <the predicate over paths, plus the bead-state and tree checks the exit
    condition needs. The verifying bead classifies; it does not confirm.>

### A successor's `## Inheritance` section

A campaign invoked as a continuation of another one ("keep conducting")
carries one extra required section, because the continuation itself is
too short to carry the policy. SKILL.md's
"A successor campaign - what a continuation inherits" says what is
inherited and what must be restated; this section is where the
successor's plan writes that reading down, and its shape is fixed so a
reader can audit it against the predecessor:

- **Predecessor**: the campaign id, its terminal status, and its
  morning report's path. An `ABORTED` predecessor is a stop, not an
  inheritance - the fault is still in the environment.
- **The original consent, quoted.** Verbatim, from the predecessor's
  consent file.
- **The continuation, quoted.** Verbatim, in the operator's words,
  however short.
- **How the second was read against the first**, clause by clause: mode
  carried or restated, each carve-out carried or dropped, each by-name
  fence carried or released, and what the new scope is. A clause the
  continuation does not settle is listed here as a queued ruling, not
  resolved in this section.
- **The unfinished inheritance**: the predecessor's open requests with
  their required merge order, the beads still open behind them, the
  discovered and retro beads it filed, its unresolved rulings, and any
  lane it never dispatched with the reason. This is the handoff section
  of the predecessor's own morning report (SKILL.md, "The report's last
  section is what the next campaign inherits"), carried forward rather
  than re-derived - and a predecessor whose report has no such section
  is itself a finding, because the successor is then reconstructing
  from a tracker that cannot show merge order.

The successor's own consent file is still its own (multi-campaign rule
5: nothing carries across campaigns by itself). The Inheritance section
is a reading offered for correction before the first dispatch, never a
substitute for the ADOPTED status that arms the successor.

## Linkage-ledger schema

The ledger lives at the path declared in the fleet manifest's
`depOverride.ledger`. The stage vocabulary is the manifest's
`depOverride` block: `localStage` (path override to a sibling worktree,
must never reach a commit) and `pushedStage` (committed dependency
pinned to a pushed SHA, downstream MR stays DRAFT).

Top level:

```json
{
  "_note": "free-text provenance",
  "entries": [ "<entry>", "..." ]
}
```

Each entry:

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Stable slug: `<downstream-bead>-<upstream-repo-short>-<upstream-bead>` |
| `stage` | yes | `localStage` or `pushedStage` |
| `opened` | yes | ISO date the override was applied |
| `campaign` | yes | Which campaign/journal owns the entry |
| `downstream` | yes | Object: `repo`, `bead`, `branch`, `branchConfirmed` (from `git branch --show-current`, never the worktree path), plus `stackedOn`, `pushedSha`, `mr`, `mrState` when they exist |
| `upstream` | yes | Object: `repo`, `bead`, `branch`, `sha`, `mr`, `mrState` |
| `pin` | pushedStage only | Object: `previousLockSha`, `newLockSha`, `committed` (bool), `reason`, `verified` (how the committed blob was inspected - inspect the blob, greps over the diff false-positive) |
| `followUp` | when work remains | Object: `action`, `when`, `detail`, `urgency`, then `status`/`resolution` once handled |
| `status` | yes | `active` or `resolved`. wurk:commit / wurk:mr refuse only while an entry with `stage: localStage` and `status: active` names their repo |

Rules:

- Entries are append-and-update, never deleted: a resolved override is
  history the next campaign reads.
- `branchConfirmed` exists because worktree directory names are not
  branch names; a push helper must use this field, populated from the
  checkout.
- One entry per downstream/upstream pair; a second override on the same
  pair reopens the entry (new `opened`, status back to `active`) rather
  than duplicating it.

## Staleness threshold and report files

`policy.stalenessMinutes` (fleet manifest, optional, integer minutes,
default 50) is the fleet-wide default for the campaign file's
`staleness_minutes`; the campaign file wins when both are set.
`campaignState.reports` (fleet manifest, optional, path) is the reports
dir; default `.claude/campaigns/reports/<campaign-id>/` under the same
`.git/info/exclude` treatment the journal gets. Per-bead file
`<bead-id>-report.json` holds the worker's JSON result; written last by
the worker, swept on every wake by the conductor (SKILL.md, "Sweep on
every wake" and "Staleness"). Bare JSON, with no markdown fence and no
prose preamble: the sweep parses the file rather than reading it, through
`report_check.rb` (`skills/wurk:kit/REFERENCE.md`, "`report_check.rb`:
does a worker's report file actually parse"), and one that does not parse
is a `report_not_json` block the sweep queues as a ruling for the worker
to re-emit. `campaignState` and `policy` are already
among the field names the skill reads (top of this file); both keys
live under them rather than under a new top-level key.

## Between-campaigns synthesis - the retro reader

Phase 6 is a single campaign's retro. Friction only visible across
campaigns is mined afterwards by the **wurk-retro-reader** agent
(`agents/wurk-retro-reader.md`), which no conductor spawns: it runs
between campaigns, on an operator's or a scheduler's call, and takes
the campaigns directory as its one required input. It is a reader that
FILES - it never edits a skill, agent, hook, script or manifest, never
commits, never pushes, never closes or edits a bead. The beads it
files are worked later through the normal pipeline.

Three contracts are worth stating here because the agent's prose
assumes them and a reader of the conductor needs them to know what
their journal is feeding.

### The cursor

State lives at `<campaigns dir>/retro-reader/cursor.json` and
`journal.md` - campaign state, under the same `.git/info/exclude`
treatment the campaign journal gets, never committed. The cursor holds
the modification time of the newest artifact the last run mined, **at
sub-second precision**, with the run timestamp and the artifact path
that set it.

The precision is a requirement, not a detail. A cursor truncated to
whole seconds is not newer than an artifact written at `.6` within the
same second, so the newest artifact is re-selected on every run and
each run re-proposes the same cluster - the failure looks like an agent
that cannot stop repeating itself. Store an ISO 8601 timestamp with
fractional seconds or a float epoch, and compare with strict
greater-than. A missing or unparseable cursor is a cold start: mine
everything and say so. The cursor is written last, after the filing,
so a run that dies mid-filing does not claim a window it never
covered.

The cursor bounds SELECTION, not reading. Artifacts newer than it are
what can trigger a run's proposals; older artifacts are read freely as
evidence, because a cluster is by definition partly older than the
cursor.

### The journal's two standing sections

`journal.md` is append-only, one dated entry per run, and carries two
sections the agent reads before proposing anything:

- **Watched-not-actioned** - clusters that did not clear the bar, with
  their evidence. The run that sees the second incident promotes the
  entry and files a bead citing the first, instead of starting the
  case from zero.
- **Decisions / Won't-change** - classes decided against, each with its
  reason and date. The agent HONORS this: a class recorded here is not
  re-proposed in any wording unless a later run brings evidence the
  decision did not have, and then the bead says what is new.

Without those two sections the agent thrashes - it re-files the class
it filed last month and re-proposes the idea the operator already
rejected, and the operator learns to ignore it. They are what makes a
standing reader affordable to keep.

### The recurrence bar

A cluster earns a bead at either bar, and at neither otherwise:

- **two or more independent runs** in which the class occurred -
  independent meaning different campaigns, since two workers in one
  campaign hitting one passage is a single run's evidence; or
- **one unambiguous factual gap** - a rule whose violation is a fact
  rather than a judgement, that landed anyway.

This is the same bar `docs/recipes/lesson-to-guard.md` sets for a
guard, applied a rung earlier: there it decides whether a class earns a
machine check, here whether it earns a bead at all. Everything under
the bar goes to Watched-not-actioned. Each filed bead carries the
incidents quoted with their campaign ids and artifact paths, the
proposed home from `docs/harness-placement.md` with the rung that chose
it, the PROSE-or-GUARD line Phase 6 also writes, and which bar it
cleared. A class that already has a bead gets a `bd note` with the new
incident rather than a twin, because split evidence is how a class
stops clearing a bar it already cleared.

`skills/wurk:kit/scripts/session_metrics.rb` is an optional input: when
it exists, its signals are metric-backed evidence beside the prose;
when it does not, the agent proceeds report-only. A metric strengthens
a cluster the prose already supports and never creates one alone.

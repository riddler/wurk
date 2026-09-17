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
satisfied, predecessor_status, predecessor_exists}` so a scheduler's
status display can say what it is waiting for.

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
- **`disarm ID`** - rewrites the Status to `DRAFTED <now>` the same way.
  Refuses `campaign_running` while the mutex is live-held: the conductor
  holding it has already read ARMED and the file flip would only mislead
  the next reader. Not armed: ok, `changed: false`, warning `not_armed`.
  `--dry-run` as for `arm`. The consent file is never touched.

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
`unknown_status`.

### The unattended invocation reads this record

`/wurk:conductor --armed` (SKILL.md, "`--armed` - the unattended
invocation") is the consumer of `list`: it counts the records with
`armed: true` (zero refuses `nothing_armed`, more than one refuses
`ambiguous_armed` - the bare-invocation rule in rule 1 above, applied
without a human to ask), then reads the one record's `consent.adopted`
(false refuses `consent_not_adopted`) and `running` (true refuses
`campaign_running`; a `stale_mutex` warning is handed to `lock.rb clear`
first). The survivor is `data.runnable`'s single member. The session then
takes the campaign mutex at `mutex.dir` for its whole life, which is what
turns `running` true for the next `list`, and releases it after the
morning report. A mutation this mode never performs: `arm`, `disarm`, or
writing a consent file - it reads what the operator set and refuses when
that is not enough.

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
every wake" and "Staleness"). `campaignState` and `policy` are already
among the field names the skill reads (top of this file); both keys
live under them rather than under a new top-level key.

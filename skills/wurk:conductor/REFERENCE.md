# wurk:conductor reference

Companion to SKILL.md. Two contracts the skill relies on when a project
runs more than one campaign or links work across repos: the
multi-campaign protocol and the linkage-ledger schema. Both were
extracted from a consumer fleet's `.claude/fleet/` docs after surviving
twenty-odd campaigns; the consumer keeps its own copies with its own
history notes. Nothing here is consumer-specific.

The fleet manifest (`.claude/wurk-fleet.json`) is not yet documented or
linted by wurk; the field names used below (`multiCampaign`,
`depOverride`, `campaignState`, `policy`) are the ones the skill reads.

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
  machine-wide (warms at 4x on one machine produced DB-sandbox
  failures). A heavy run acquires the repo gate lock FIRST, then any
  free slot; release in reverse order. Fixed acquisition order
  prevents deadlock. A campaign that caps its own concurrency below the
  machine cap takes its campaign mutex before the slot.
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

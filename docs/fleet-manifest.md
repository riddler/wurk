# Fleet manifest schema (`.claude/wurk-fleet.json`)

`lib/fleet_manifest.rb` (`skills/wurk:kit/scripts/lib/fleet_manifest.rb`)
is the authority; this document follows it in the same commit, the same
rule `docs/manifest.md` and `lib/manifest.rb` follow. JSON, not YAML, for
the same reason as the manifest (ADR-0006).

## What this is, and how it differs from the manifest

`.claude/wurk.json` describes one repo, and every kit script reads it.
`.claude/wurk-fleet.json` describes a *set* of repos a campaign may span,
and holds only what no single repo can know: the roster, the package
edges between the repos, which repo owns which contract area, and where
the campaign state (journal, reports, locks, registry) lives when the
project wants it somewhere other than the defaults.

Its readers are agents, not scripts: the `/wurk:conductor` skill (its
SKILL.md and REFERENCE.md) and the `wurk-fleet-scout` agent read it as
prose-driven instructions. No kit script reads it on its own behalf. The
kit's part is the lint (`fleet_manifest.rb check`), which is what this
document exists to specify: the same "invented key lints clean and is
silently ignored" hazard `docs/manifest.md` closes for the manifest is
closed here for the fleet file.

A single-repo project needs no fleet manifest (SKILL.md, "Single-repo
campaigns need no manifest"): the campaign file carries the policy, and
every campaign-state path has a default. A fleet of one is still valid -
a roster whose single `dir` is `"."` - for a project that wants the
campaign-state keys without a second repo.

Placeholder names throughout (`alpha`, `beta`); every value is the
consumer's.

## The schema

Paths are relative to the **fleet root** - the directory holding the
manifest's `.claude/` - and never absolute: the file is checked in and
shared by every machine that runs the fleet, and an absolute path is right
on at most one of them. Commands are argv arrays. `(opt)` marks a field
with a default or a documented degraded behavior.

```jsonc
{
  "fleet": "example",                 // (opt) the fleet's name, for humans
  "description": "...",               // (opt) for humans; no reader consults it
  "_note": "...",                     // any "_"-prefixed key, anywhere, is an
                                      // annotation: skipped, never warned about

  "repos": [                          // REQUIRED, non-empty: the roster
    {
      "dir": "alpha",                 // required; fleet-root-relative, no "..";
                                      // "." for a fleet of one
      "package": "alpha",             // (opt) the name dependsOn edges use
      "beadsPrefix": "aa",            // (opt) must equal that repo's own
                                      // beads.prefix (the lint checks)
      "note": "the base library"      // (opt) for humans
    },
    { "dir": "beta", "package": "beta", "beadsPrefix": "bb" }
  ],

  "dependsOn": {                      // (opt) package -> [packages it needs]
    "beta": ["alpha"]                 // every name is a repos[].package;
                                      // no self-edge, no cycle
  },

  "ownership": {                      // (opt) contract area -> repos[].dir
    "parser": "alpha",
    "runtime": "beta"
  },

  "policy": {                         // (opt) FREE-FORM, relayed verbatim
    "merge": "never",                 // into every dispatch's policy block
    "stalenessMinutes": 40            // (opt) the one key the conductor
                                      // interprets; positive integer, default 50
  },

  "depOverride": {                    // (opt) the cross-repo linkage recipe
    "ledger": ".claude/fleet/linkage-ledger.json",   // required when present
    "localStage": "path override to a sibling worktree; never reaches a commit",
    "pushedStage": "committed dep pinned to a pushed SHA; downstream MR stays DRAFT"
  },

  "campaignState": {                  // (opt) where campaign state lives
    "dir": ".claude/fleet/campaigns", // (opt) default .claude/campaigns
    "journalDir": ".claude/fleet/journal",           // (opt) default <dir>/journal
    "reports": ".claude/fleet/reports"               // (opt) default
                                      // <dir>/reports/<campaign-id>
  },

  "multiCampaign": {                  // (opt) declares the multi-campaign protocol
    "protocol": ".claude/fleet/multi-campaign-protocol.md",  // (opt) the
                                      // consumer's own copy of the protocol
    "registry": ".claude/fleet/campaigns/ACTIVE.md",         // the registry file
    "locksDir": ".claude/fleet/locks",                       // (opt) default
                                      // <campaignState.dir>/locks
    "machineGateSlots": 2             // (opt) FALLBACK only - see below
  },

  "stacking": {                       // (opt) FREE-FORM, relayed verbatim
    "sameRepo": "sequential branches, each cut from its parent; DRAFT while upstream unmerged",
    "crossRepo": "independent branches from the default branch, linked via depOverride"
  },

  "landingCheck": ["make", "deps-sort"]  // (opt) argv; the landing invariant
                                      // check run on a merged tree
}
```

## Field reference: who reads what

Each field names the reader that consults it today. A field with no
reader is not in the schema; a key a consumer's own conductor variant
reads beyond these warns as unknown until it is promoted here (see
"Extending the schema" below).

### `fleet`, `description`

Two annotation strings for a human opening the file. No skill reads
either. Kept out of the unknown-key warning because every fleet file
reasonably names itself, and a lint that warned on the name would be
ignored wholesale - the same reasoning as the `_` rule below.

### `repos[]` - the roster

Required, non-empty. Read by the conductor as the repo roster (SKILL.md,
"Configuration") and by the scout as the sweep list (`repos[].dir`,
relative to the fleet root). Per entry:

- `dir` (required) - the checkout, relative to the fleet root. Unique
  across the roster. `"."` names the fleet root itself (a fleet of one).
- `package` (opt) - the name `dependsOn` edges refer to. Unique when
  present. A repo with no package has no package edges.
- `beadsPrefix` (opt) - the repo's bead-id prefix, so a bead id can be
  attributed to its repo from the fleet file alone. Unique when present,
  and `fleet_manifest.rb check` blocks when it disagrees with the
  `beads.prefix` that repo's own `.claude/wurk.json` declares - a roster
  prefix that contradicts the repo has no legitimate reading.
- `note` (opt) - for humans.

### `dependsOn`

Package-level edges: `<package>: [<packages it depends on>]`. Every key
and every listed name must be a `repos[].package`; a self-edge and a
cycle both block, because the conductor and the scout join these edges
into the ready-graph (agents/wurk-fleet-scout.md, "Graph mode") and a
cyclic graph has no first repo. `fleet_manifest.rb check` reports the
resolved order as `data.topological_order`, dependencies first - the
default campaign order.

### `ownership`

`<contract area>: <repos[].dir>`. Read in Phase 5 (Discovery): a
discovered dependency is filed in the owning repo, one bead per
discovery, referenced from each blocked bead. Every value must name a
roster dir. Area names are the consumer's vocabulary; the kit never
interprets them.

### `policy` - free-form, one interpreted key

The policy block is relayed verbatim into every dispatch (SKILL.md,
"Configuration": policy is non-negotiable at runtime, and the dispatch
appendix carries it as a slot). Because a worker reads every key, an
unknown key here is not silently ignored, so the lint does not warn on
it - the block is free-form on purpose. One key the conductor interprets
itself:

- `stalenessMinutes` (opt, positive integer, default 50) - the fleet-wide
  default for the campaign file's `staleness_minutes`; the campaign file
  wins when both are set (REFERENCE.md, "Staleness threshold and report
  files").

### `depOverride`

The cross-repo linkage recipe (SKILL.md Phase 4; REFERENCE.md,
"Linkage-ledger schema"). `ledger` is required when the section is
present: it is where the ledger lives, and the stage vocabulary is
meaningless without one. `localStage` and `pushedStage` (opt) describe
the two stages in the consumer's ecosystem terms - what a path override
looks like there, what a pushed-SHA pin looks like - and are relayed as
"the manifest's recipe". The stage *names* are fixed by the ledger
schema; only their descriptions are the consumer's.

### `campaignState`

Where campaign state lives. All three are optional and every default is
the one the conductor already applies to a project with no fleet
manifest, so declaring the section changes locations and nothing else:

- `dir` (opt, default `.claude/campaigns`) - the campaigns dir
  `campaign_state.rb` reads (`--dir`) and the parent of the two below.
- `journalDir` (opt, default `<dir>/journal`) - the journal and
  morning-report dir (SKILL.md, "Journal and morning report"). Filenames
  inside it are fixed by REFERENCE.md rule 4 and carry the campaign id;
  the manifest does not template them.
- `reports` (opt, default `<dir>/reports/<campaign-id>`) - the per-bead
  report files' parent (SKILL.md, "Name a report file in every
  dispatch"; REFERENCE.md, "Staleness threshold and report files"). A
  declared value is used as given; the default appends the campaign id.

Wherever it ends up, campaign state is excluded from git via
`.git/info/exclude` (SKILL.md, "Campaign state lives outside what the
campaign publishes").

### `multiCampaign`

Declaring this block makes the multi-campaign protocol (REFERENCE.md)
binding on every campaign in the project.

- `registry` - the registry file, rule 1 (conventionally `ACTIVE.md`
  under the campaigns dir).
- `locksDir` (opt, default `<campaignState.dir>/locks`) - the
  resource-keyed locks dir, rule 3, and `campaign_state.rb`'s
  `--locks-dir`. The lock *names* inside it are the protocol's:
  `gate-<repo-dir>/`, `tracker-<repo-dir>/`, `machine-gate-slots/slot-N/`,
  `registry/`, and the campaign mutex `campaign-<id>/`. They are not
  manifest fields.
- `machineGateSlots` (opt, positive integer) - a **fallback** for the
  machine-wide gate-slot cap. The preferred source is the machine config's
  `machine.gate_slots` (`docs/machine-config.md`, "`machine.gate_slots`
  wins over the fleet's number"): `lock.rb acquire` takes that over a
  relayed `--slots N` and warns `slots_overridden` when the two differ. A
  shared file can be right for at most one of the machines that run the
  fleet, so a fleet that carries this number should move it into each
  machine's config and drop the key.
- `protocol` (opt, path) - the consumer's own copy of the protocol text,
  for a campaign plan to cite. REFERENCE.md is the generic statement; no
  skill reads this path.

### `stacking` - free-form

Read as "stacking rules" (SKILL.md, "Configuration") and relayed into the
dispatch's stacking-base slot. Free-form for the same reason as `policy`.
The two conventional keys are `sameRepo` and `crossRepo`, describing the
two cases SKILL.md's Phase 4 and `/wurk:branch --base` already implement.

### `landingCheck`

An argv array: the landing invariant check, "a cheap, seconds-scale
command on the merged tree between textual merge OK and next full gate"
(SKILL.md, Phase L, "The landing invariant check, both modes"). Fleet-wide,
so it fits a fleet of one or a fleet whose repos share a toolchain; a fleet
whose repos need different checks has no per-repo slot for them today. A
single-repo campaign has no fleet file at all and names the command in its
campaign file instead, which is why this key's absence is not the only way
a campaign can arrive at a landing check.

## What is deliberately not in the schema

- **The outbound scan.** It is machine-configured (ADR-0014,
  `docs/machine-config.md`, `outbound_scan`), never a fleet field: the
  pattern set is a fact about the machine that pushes, and the gate runs
  on both push paths without the fleet file naming it. A fleet-level
  pointer to a scan doc is a consumer annotation, not a key the conductor
  reads.
- **Lock names, journal and report filenames.** Fixed by the protocol
  (REFERENCE.md rules 3 and 4) so two campaigns can never disagree about
  them. Only the directories are configurable.
- **A `tracker` or `forge` adapter choice.** Both come from each repo's
  own `.claude/wurk.json` (`beads.*`, `forge.*`); the fleet file never
  overrides a repo's manifest.
- **The stage names in `depOverride`.** `localStage` and `pushedStage`
  are the ledger schema's vocabulary; a consumer describes them, it does
  not rename them.

## Annotation keys

Any key whose name starts with `_`, at any depth, is skipped by the lint:
neither validated nor warned about. Fleet files accumulate dated
provenance beside the values they explain (`"_note": "re-verified
2026-09-05 ..."`), and a lint that warned on every such note would be
ignored wholesale. An annotation is never read by a skill; a value the
conductor should see goes in a real key.

## Resolution

`lib/fleet_manifest.rb` walks up from the working directory looking for
`.claude/wurk-fleet.json`; the first hit wins, and the directory holding
that `.claude/` is the fleet root. There is no git fallback, unlike the
manifest: the fleet root is by definition the directory holding the file,
so a checkout's main working tree is not a better guess than "not found".
`fleet_manifest.rb check --file PATH` checks a named file instead.

## Required, optional, and defaults

Required: `repos` (non-empty).

Defaults: `policy.stalenessMinutes` = 50, `campaignState.dir` =
`.claude/campaigns`, `campaignState.journalDir` = `<dir>/journal`,
`campaignState.reports` = `<dir>/reports/<campaign-id>`,
`multiCampaign.locksDir` = `<dir>/locks`.

Everything else absent means the capability is off: no `dependsOn` means
no package edges (bead-level `bd` dependencies are the only edges), no
`ownership` means there is no owning-repo map for discovery routing
(single-repo campaigns skip that phase), no `depOverride` means no cross-repo linkage recipe, no
`multiCampaign` means the multi-campaign protocol is not binding, no
`landingCheck` means the landing runs no invariant check, and no
`multiCampaign.machineGateSlots` means the slot count comes from the
machine config alone.

## Validation

`lib/fleet_manifest.rb` validates on load, with the manifest's asymmetry:

- **Unknown keys warn**, at the top level and inside `repos[]`,
  `depOverride`, `campaignState`, and `multiCampaign`. `policy` and
  `stacking` are free-form and never warn. `_`-prefixed keys never warn.
- **`repos` must be a non-empty array of objects.** Each `dir` must be a
  non-empty relative path with no `..` segment; `package`, `beadsPrefix`,
  and `note` must be non-empty strings when present; `dir`, `package`,
  and `beadsPrefix` must each be unique across the roster.
- **`dependsOn` keys and values must name roster packages**; a self-edge
  and a cycle block.
- **`ownership` values must name roster dirs.**
- **Sections must be objects** when present: `dependsOn`, `ownership`,
  `policy`, `depOverride`, `campaignState`, `multiCampaign`, `stacking`.
- **Path fields must be non-empty and relative**: `depOverride.ledger`,
  `campaignState.dir`, `campaignState.journalDir`, `campaignState.reports`,
  `multiCampaign.registry`, `multiCampaign.locksDir`,
  `multiCampaign.protocol`. A leading `/` blocks.
- **String fields must be non-empty strings**: `fleet`, `description`,
  `depOverride.localStage`, `depOverride.pushedStage`,
  `stacking.sameRepo`, `stacking.crossRepo`.
- **`policy.stalenessMinutes` and `multiCampaign.machineGateSlots` must be
  positive integers.** Zero, a negative, a float, a string, and a boolean
  all block.
- **`landingCheck` must be an argv array of strings.** A shell string is a
  schema error, never something to split on whitespace.

## The lint

```sh
ruby ~/.claude/skills/wurk:kit/scripts/lib/fleet_manifest.rb check [--file PATH]
```

Read-only, so no `--dry-run`. Emits the usual envelope and exits 1 on an
invalid manifest, 0 otherwise; an unknown-key warning does not fail it.
Two checks run here and not on load, because they read the filesystem
(the same split `manifest.rb check` draws for its dolt-remote and
review-agent checks):

- `fleet_repo_dir_missing` (warning) - a roster `dir` is not a directory
  under the fleet root. A warning, because the file is shared and a repo
  not cloned on this machine is a fact about the machine.
- `fleet_beads_prefix_mismatch` (block) - a roster `beadsPrefix` disagrees
  with the `beads.prefix` in that repo's own `.claude/wurk.json`. Only
  present repos with a readable manifest are compared; a missing or
  unparseable repo manifest is that repo's own lint's business.

`data` carries `path`, `fleet_root`, `valid`, `errors`, the resolved
`repos`, `depends_on`, `topological_order` (null on a cycle),
`ownership`, `staleness_minutes`, `machine_gate_slots`, `campaigns_dir`,
`journal_dir`, `reports_dir`, `locks_dir`, `registry`, `ledger`, and
`landing_check`, defaults applied - what a conductor reads instead of
re-deriving the defaults from prose.

## Extending the schema

A consumer whose own conductor variant (SKILL.md's "a consumer may ship
its own fleet-specific variant under another name") reads keys beyond
these gets one `unknown key` warning per key, which is the intended
signal: either the key is consumer-only and the warning is the record of
that, or it is generic and belongs here. Promoting one means adding it to
`FleetManifest::KNOWN` (and its validation) and to this document in the
same commit, and naming the reader in "Field reference" above. Extensions
add, they never override (CLAUDE.md): a consumer variant may read more
than this schema, never redefine what a field here means.

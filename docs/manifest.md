# Manifest schema (`.claude/wurk.json`)

Schema version 1. `lib/manifest.rb` is the authority; this document follows
it in the same commit (see CLAUDE.md). JSON, not YAML: system-Ruby stdlib
parses it with no surprises (ADR-0006).

Commands are argv arrays. Paths are relative to the repo root unless noted.
Fields marked (opt) have a default or a documented degraded behavior; the
defaults are listed under "Defaults" below.

```jsonc
{
  "wurk": 1,                          // schema version, required

  "beads": {
    "prefix": "st",                   // id shape becomes st-[a-z0-9]+(\.\d+)?
    "topology": "beads",              // (opt) or "beads-with-forge-projection" (fixative)
    "areas": {                        // (opt) label vocabulary + batching policy
      "labels": ["area:interpreter", "area:parser", "..."],
      "lands_alone": ["area:build"],
      "always_batchable": ["upstream"]
    }
  },

  "forge": {
    "kind": "github",                 // or "gitlab"; picks gh/glab, PR/MR wording,
                                      // permalink format, close-line syntax
    "labels": {}                      // (opt) e.g. {"agent_filed": "agent-filed"}
  },

  "gate": {                           // see docs/gate-contract.md for tiers
    "full": ["mix", "quality"],
    "loop": ["mix", "quality", "--profile", "loop"],
    "report": ["mix", "quality", "--report", "-"],   // (opt) tier 1
    "attest": ["mix", "gate.verify"],                // (opt) tier 2
    "guard_ledger": "docs/quality-gate-changes.md",  // (opt) tier 2
    "build_paths": ["lib/", "test/", "config/", "mix.exs", "mix.lock"],
    "also_gated_paths": [".claude/scripts/", ".claude/skills/"],
    "moving_files": [".quality.exs", ".credo.exs", "coveralls.json"]
                                      // files whose change invalidates green
  },

  "parallelism": {
    "model": "worktree-per-issue",    // or "branch-in-place" (fixative)
    "worktrees_dir": "../statifier-ex-worktrees",   // model-specific
    "trust": ["mise", "trust", "{path}"],           // (opt) run once per new worktree
    "warm_clone": ["deps", "_build"],               // (opt) dirs cloned from main checkout
    "warm_globs": ["_build/dev/dialyxir_*.plt*"],   // (opt) caches worth reporting/repairing
    "warm": [["mix", "deps.get"]],    // (opt) commands run in the new worktree
    "repair_when": "mix.lock",        // (opt) lockfile that triggers post-rebase repair
    "repair": [["mix", "deps.get"]],  // (opt)
    "post_branch": []                 // (opt) e.g. fixative's xcodegen/icon chain
  },

  "tmux": {                           // (opt) omit = no tmux integration
    "session": "statifier-ex",
    "model": "opus"                   // model for seeded worktree sessions
  },

  "artifacts": {
    "plans": "docs/plans",            // fixative: thoughts/shared/plans
    "research": "docs/research",
    "filename": "YYMMDD-[id-]kebab",  // (opt) the shared grammar; literal for now
    "repository": "statifier-ex"      // (opt) research frontmatter; derived from the
                                      // git remote when absent
  },

  "commits": {
    "style": "s-form",                // (opt) "Adds ..." titles; or "conventional"
    "package_map": {},                // (opt) conventional only: path prefix -> package
    "subject_under": 50,              // (opt) subject must be UNDER this many characters
    "body_line_max": 72,              // (opt) inclusive
    "total_lines_max": 40,            // (opt) inclusive
    "trailer": {"key": "Refs"}        // (opt) the bead trailer scheme, not just a number
  },

  "changelog": {
    "mode": "fragments",              // "fragments" | "keep-a-changelog" | "none"
    "dir": "changelog.d"              // mode-specific fields
  },

  "release": null                     // (opt) recipe for wurk:release, or null.
                                      // predicator: {"kind": "hex", "version_file": "mix.exs",
                                      //   "readme_pin": true, "changelog": "CHANGELOG.md"}
                                      // fixative: {"kind": "xcode-app", ...}
}
```

## Two path lists, not one

`gate.build_paths` and `gate.also_gated_paths` answer different questions,
and conflating them is a real failure mode (statifier once reported "no gate
applicable" for a branch of ~8k lines of Ruby, skipping the only stage that
covered it):

- **build_paths** - does this change touch the project's build? A change
  touching none of them cannot break a compile.
- **also_gated_paths** - paths with no build impact that a gate stage still
  measures, so the commit carve-out must not apply to them.

The carve-out predicate ("does the gate have anything to measure?") is the
union of both. Each entry is a directory prefix when it ends in `/`, and an
exact path otherwise; no globbing.

## `{path}` substitution

`parallelism.trust` is the one command run *about* a new worktree rather
than inside it, so its argv may contain the literal token `{path}`, replaced
with the new worktree's absolute path. No other field templates.

## Per-repo starting values

| Field | statifier-ex | predicator-ex | fixative |
|---|---|---|---|
| beads.prefix | `st` | `px` | (uses GL-NN branch tags; bead prefix TBD) |
| beads.topology | beads | beads | beads-with-forge-projection |
| forge.kind | github | github | gitlab |
| gate.full | mix quality | mix quality | mise run quality |
| gate.loop | mix quality --profile loop | mix quality --profile loop | mise run quality:quick |
| gate.report | yes (ex_quality JSON) | yes | no (tier 0; tier 1 later) |
| gate.attest | mix gate.verify | none | none |
| parallelism.model | worktree-per-issue | worktree-per-issue | branch-in-place |
| tmux.session | statifier-ex | predicator-ex | (renames current window) |
| artifacts.plans | docs/plans | docs/plans | thoughts/shared/plans |
| commits.style | s-form | s-form | conventional + package map |
| changelog.mode | fragments | keep-a-changelog (direct) | keep-a-changelog per package |
| release | null (2.0.0-dev) | hex recipe | xcode-app recipe |

## Resolution

Settled in phase 1 step 2. `lib/manifest.rb` locates the manifest in two
steps:

1. Walk up from the working directory looking for `.claude/wurk.json`.
   First hit wins.
2. Failing that, ask git for the main checkout
   (`git rev-parse --git-common-dir`, whose parent is the main working tree)
   and look there.

Walk-up comes first, rather than going straight to the main checkout as the
plan originally leaned. A worktree is a full checkout and carries its own
`.claude/wurk.json`, so walking up finds the manifest *on the branch being
worked* - which is what makes a schema change testable on the branch that
makes it. Reading main's copy instead would mean every manifest edit landed
untested. Step 2 covers the case where the working directory is outside any
checkout of the repo.

## Required, optional, and defaults

Required: `wurk`, `beads.prefix`, `forge.kind`, `gate.full`, `gate.loop`,
`parallelism.model`, `artifacts.plans`, `artifacts.research`,
`changelog.mode`.

Defaults applied when a key is absent: `beads.topology` = `beads`,
`commits.style` = `s-form`, `commits.subject_under` = 50,
`commits.body_line_max` = 72, `commits.total_lines_max` = 40,
`artifacts.filename` = `YYMMDD-[id-]kebab`.

Everything else absent means the capability is off, and the scripts say so
rather than guessing: no `tmux` section means no tmux integration, no
`gate.report` means tier 0, no `gate.attest` means `attested: false`.

## Validation

`lib/manifest.rb` validates on load, asymmetrically and on purpose:

- **Unknown keys warn.** A consumer repo may be pinned to a newer schema
  than the kit it has installed; refusing to run would make that a hard
  version lock.
- **Missing required keys block**, naming the field and this document.
- **Enum values reject outright** rather than falling back to a default.
  Every enum here selects a structural behavior (which forge, which
  parallelism model, which changelog workflow); guessing one is worse than
  stopping.
- **Command fields must be argv arrays** of strings. A shell string is a
  schema error, never something to split on whitespace.

`ruby .claude/scripts/lib/manifest.rb check [--file PATH]` is the standalone
lint. It emits the usual envelope and exits 1 on an invalid manifest; an
unknown-key warning does not fail it.

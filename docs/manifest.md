# Manifest schema (`.claude/wurk.json`)

Draft v0. This is the design-time schema; `lib/manifest.rb` (docs/plan.md
phase 1) is the authority once it exists, and this document must be kept in
sync with it. JSON, not YAML: system-Ruby stdlib parses it with no surprises
(ADR-0006).

Commands are argv arrays. Paths are relative to the repo root unless noted.
Fields marked (opt) have a default or a documented degraded behavior.

```jsonc
{
  "wurk": 1,                          // schema version, required

  "beads": {
    "prefix": "st",                   // id shape becomes st-[a-z0-9]+(\.\d+)?
    "topology": "beads",              // or "beads-with-forge-projection" (fixative)
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
    "report": ["mix", "quality", "--format", "json", "--report", "-"],  // (opt) tier 1
    "attest": ["mix", "gate.verify"],                                    // (opt) tier 2
    "guard_ledger": "docs/quality-gate-changes.md",                      // (opt) tier 2
    "paths": ["lib/", "test/", "config/", "mix.exs", "mix.lock"],
                                      // gate-applicable paths (the commit carve-out)
    "moving_files": [".quality.exs", ".credo.exs", "coveralls.json"]
                                      // files whose change invalidates green
  },

  "parallelism": {
    "model": "worktree-per-issue",    // or "branch-in-place" (fixative)
    "worktrees_dir": "../statifier-ex-worktrees",   // model-specific
    "warm": [["mix", "deps.get"]],    // (opt) commands after worktree create
    "warm_clone": ["deps", "_build", "priv/plts"],  // (opt) dirs cloned from main checkout
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
    "filename": "YYMMDD-[id-]kebab"   // the shared grammar; literal for now
  },

  "commits": {
    "style": "s-form",                // "Adds ..." titles; or "conventional"
    "package_map": {},                // (opt) conventional only: path prefix -> package
    "subject_max": 50
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

Open question from docs/plan.md: scripts run from worktrees, so the loader
should locate the manifest via the main checkout (leaning: walk up from
`git rev-parse --git-common-dir`). Decide in phase 1 step 2 and record the
rule here.

## Validation

`lib/manifest.rb` validates on load: unknown keys warn (forward
compatibility), missing required keys block with a message naming the field
and this document. Enum fields reject unknown values outright. A
`manifest.rb check` subcommand gives consumers a standalone lint.

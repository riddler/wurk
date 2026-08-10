# Manifest schema (`.claude/wurk.json`)

Schema version 1. `lib/manifest.rb` (`skills/wurk:kit/scripts/lib/manifest.rb`)
is the authority; this document follows it in the same commit (see CLAUDE.md's
hard rules). JSON, not YAML: system-Ruby stdlib parses it with no surprises
(ADR-0006).

Commands are argv arrays. Paths are relative to the repo root unless noted.
Fields marked (opt) have a default or a documented degraded behavior; the
defaults are listed under "Defaults" below.

```jsonc
{
  "wurk": 1,                          // schema version, required

  "repo": {                           // (opt)
    "default_branch": "main"          // (opt) default "main"; the branch every
                                      // "what did this branch change" diff is
                                      // taken against
  },

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
    "moving_files": [".quality.exs", ".credo.exs", "coveralls.json"],
                                      // files whose change invalidates green
    "project_level_skips": [         // (opt) tier 1
      "not\\s+installed",
      "disabled in \\.quality\\.exs"
    ],
    "not_applicable_skips": [        // (opt) tier 1
      "^:gettext not installed$",
      "^no \\.po files"
    ],
    "sabotage": {                    // (opt) report-only mutation-testing scan
      "test_roots": ["test/"],
      "test_pattern": "\\btest\\s+\"",
      "exempt_prefixes": ["test/scion_tests/", "test/scxml_tests/"]
    }
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

  "models": {                         // (opt) stage models that differ per project
    "direction": "fable"              // (opt) the ADR/direction tier wurk:work
                                      // dispatches; default "opus". Illustrative
                                      // here - statifier-ex's own manifest omits
                                      // this section and runs on the default; see
                                      // "Per-repo starting values" below.
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

  "release": null,                    // (opt) recipe for wurk:release, or null.
                                      // predicator: {"kind": "hex", "version_file": "mix.exs",
                                      //   "readme_pin": true, "changelog": "CHANGELOG.md"}
                                      // fixative: {"kind": "xcode-app", ...}

  "judge": {                          // (opt) merge-time judge over judgment-bearing prose
    "model": "sonnet",                // (opt) default "sonnet"
    "registry": [                     // required when judge is present; non-empty
      {
        "key": "adr-0008",
        "label": "ADR-0008",
        "scope_prefix": "skills/",
        "scope_suffix": "SKILL.md",   // (opt)
        "text": "docs/adr/0008-merge-time-judge-over-generic-skill-prose.md",
        "focus": "what the propose pass is asked to look for"
      }
    ]
  }
}
```

## `repo.default_branch`

The branch every "what did this branch change" three-dot diff is taken
against: `git diff <repo.default_branch>...HEAD`. This is *not* the remote
name - the remote is always `origin`, unconfigurable - only the branch name on
it changes. Defaults to `"main"`.

Setting it moves several behaviors at once, all reading the same field:

- the commit carve-out (`gate.rb`'s `gate_applicable?`, `/wurk:commit` Step 0)
- the sabotage mutation-testing pathspec (`gate.rb`'s `sabotage_diff_args`)
- plan-document bead resolution (`bead.rb`'s `resolve_plan_doc_bead`)
- worktree rebasing and staleness checks (`rebase_onto.rb`, `worktree_refresh.rb`,
  `worktree_survey.rb`, `worktree_create.rb`'s base-ref ladder)
- the merge-time judge's base ref

A consumer whose default branch is `master`, `trunk`, or `develop` sets this
field once instead of getting silently wrong diffs from every site above.

## Release recipes

`release` is read by `/wurk:release` and by nothing in the kit, so
`lib/manifest.rb` does not validate below the section. `null` (or absent) means
the project cuts no releases through this workflow, and the skill refuses
rather than guessing which file holds the version.

`release.kind` selects the recipe. Implemented today:

| kind | fields | what the skill edits |
|---|---|---|
| `hex` | `version_file`, `readme_pin` (bool), `changelog` | the version attribute, the README install pin, the changelog's unreleased heading |

`xcode-app` (fixative: `MARKETING_VERSION`, xcodegen regeneration, per-package
changelogs) is phase-4 work. Any unimplemented kind is refused by name - a
half-performed release recipe is indistinguishable from a finished one by
looking.

## `gate.project_level_skips` and `gate.not_applicable_skips`

Two sibling lists of regex source strings, both matched against a skipped
stage's `summary`, that classify a skip beyond "the gate could not measure it
on this run". `gate.rb`'s module doc draws the same line.

The choosing test, stated plainly: *is this a stage the project would run if
someone did the work?* Yes - it belongs in `project_level_skips`; the gap is
real and the nag is doing its job. No, and it never will - it belongs in
`not_applicable_skips`; the stage is permanently out of scope for this
project, not merely unaddressed.

statifier-ex is the worked example. `:doctor not installed` is a
documentation-coverage check for a library with an `@spec`/`@doc` discipline
- a genuine gap, so it stays in `project_level_skips`. `:gettext not
installed` and the `no .po files` summaries are translation tooling for a
library with no user-facing strings - they will never apply, so they belong
in `not_applicable_skips`.

A `project_level_skips` match reports the stage with a warning and does not
block; the report explicitly still names the stage in commit reports and
request bodies, because it is a standing gap someone should eventually close.
A `not_applicable_skips` match also reports with a warning and does not
block, but is explicitly not required in commit reports or request bodies -
naming a permanently inapplicable stage forever is noise, not signal. Either
way a skipped stage is never reported as passing.

**Precedence:** when a summary matches both lists, `gate.rb` checks
`not_applicable_skips` first, so the stage classifies as not-applicable. The
narrower, explicitly-enumerated declaration wins over the broader
standing-gap pattern - the alternative would force every consumer with a
broad `project_level_skips` pattern to rewrite it with a negative lookahead
before `not_applicable_skips` could do anything, which defeats the point of
having a separate field.

Absent means the corresponding list is empty, which is the strict reading:
nothing is project-level and nothing is not-applicable, so every skipped
stage blocks. Widening either list is a review decision made in this file,
not a kit default - see `gate.rb`'s module doc for why the strict direction
is deliberate. statifier-ex's values above are that project's own taxonomy,
not a default any other consumer inherits.

## `gate.sabotage`

`gate.rb`'s sabotage scan is a grep for a comment shape above an added test
declaration: it flags new test declarations in the diff with no `# sabotage:`
note in the comment block directly above them. It is report-only -
`data.sabotage.missing` never flips `ok`, and a present note is not evidence
the mutation was actually run, only that a comment with the right shape
exists.

This whole section is optional, and present-or-absent rather than
partly-on: `test_roots` and `test_pattern` must both be given together, or
neither. Absent means the scan is off - `data.sabotage.enabled` is `false`
with a stated `reason`, `data.sabotage.missing` is always `[]`, and `gate.rb`
shells out to `git diff` zero times for it. An empty `missing` on an enabled
scan means nothing was flagged; an empty `missing` with `enabled: false`
means the scan never ran - the two are not the same claim, and a reader must
not collapse them.

- **test_roots** - directory prefixes passed to `git diff main...HEAD -U0 --`
  as the pathspec, i.e. where the scan looks for new test declarations.
- **test_pattern** - a regex source matched against each added line to
  decide whether it declares a test. statifier's ExUnit shape
  (`\btest\s+"`) is one project's syntax, not a default - a project with a
  different test framework supplies its own.
- **exempt_prefixes** - (opt) path prefixes exempted from the scan, for
  generated test corpora that should never need a hand-written note. This
  one list feeds both the `git diff` pathspec (as `:!prefix` exclusions) and
  the in-scan filter, so there is exactly one definition site for what is
  exempt.

statifier-ex is the only consumer that declares this section today;
predicator-ex and fixative have no sabotage-discipline corpus and get the
off state, honestly.

## `judge`

The merge-time propose/refute judge (ADR-0008) reads this section for what
to judge and where. It is optional, and present-or-absent rather than
partly-on, the same rule `gate.sabotage` follows: `judge.registry` must be a
non-empty array when `judge` is present at all, so a `judge` section with an
empty registry is a schema error, not a silently disabled judge. Absent
means the judge has nothing to judge, not that it judged and found nothing -
a consumer that registers nothing simply never runs it, and `judge?` reports
`false`.

- **model** - (opt) the model the judge calls for both the propose and
  refute passes, overridable per run. Defaults to `sonnet` when the section
  is present but `model` is not given, and `judge_model` returns that
  default even when the whole `judge` section is absent.
- **registry** - required, non-empty array of objects. Each entry:
  - **key** - short identifier for the entry.
  - **label** - human-readable name shown in findings.
  - **scope_prefix** - path prefix a changed file must start with to be in
    scope.
  - **scope_suffix** - (opt) path suffix a changed file must also end with.
  - **text** - path to the judged document (e.g. an ADR) that the propose
    pass is given verbatim.
  - **focus** - what the propose pass is asked to look for; a description
    of the failure mode, not a restatement of the rule the model already has
    in `text`.

Every field but `scope_suffix` must be a non-empty string; a missing or
empty field blocks, naming the field.

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

## `beads.areas.always_batchable`

The field lists labels marking work that **changes no files in this repo** -
the work happens in a sibling project and the bead here tracks it.

That single predicate has **two consequences, not one**: such a bead
collides with nothing (so it is always batchable), *and* it has nothing for
a workspace to do (so no workspace is stood up for it). `select_batch.rb`
reports it as the `upstream` verdict - informational, never recommended -
and `/wurk:work` handles it with an early exit and a coordination report.

The name is narrower than the meaning. ADR-0009 considered renaming and
rejected it: a breaking manifest change bought only for a name. If a
breaking schema change happens for other reasons, the rename rides along.

A bead carrying one of these labels takes no `area:` label; the two are
alternatives.

## `{path}` substitution

`parallelism.trust` is the one command run *about* a new worktree rather
than inside it, so its argv may contain the literal token `{path}`, replaced
with the new worktree's absolute path. No other field templates.

## Per-repo starting values

This table is about downstream consumers of the kit, not wurk itself - wurk
develops the kit rather than consuming it for a separate codebase, so it does
not get a column here. Its own `models.direction` and `judge` values are
called out in the paragraph after the table instead, the same way `judge`
is already handled there.

| Field | statifier-ex | predicator-ex | fixative |
|---|---|---|---|
| repo.default_branch | `main` | `main` | `main` |
| beads.prefix | `st` | `px` | (uses GL-NN branch tags; bead prefix TBD) |
| beads.topology | beads | beads | beads-with-forge-projection |
| forge.kind | github | github | gitlab |
| gate.full | mix quality | mix quality | mise run quality |
| gate.loop | mix quality --profile loop | mix quality --profile loop | mise run quality:quick |
| gate.report | yes (ex_quality JSON) | yes | no (tier 0; tier 1 later) |
| gate.attest | mix gate.verify | none | none |
| gate.sabotage | yes | none | none |
| parallelism.model | worktree-per-issue | worktree-per-issue | branch-in-place |
| tmux.session | statifier-ex | predicator-ex | (renames current window) |
| models.direction | opus (default) | opus (default) | opus (default) |
| artifacts.plans | docs/plans | docs/plans | thoughts/shared/plans |
| commits.style | s-form | s-form | conventional + package map |
| changelog.mode | fragments | keep-a-changelog (direct) | keep-a-changelog per package |
| release | null (2.0.0-dev) | hex recipe | xcode-app recipe |

`models.direction` was added to the schema because statifier-ex and
predicator-ex were observed to disagree on it (statifier wanted Fable,
predicator Opus). That was the intent; neither manifest has ever set the
field, so both run on the loader's `opus` default today. Whether
statifier-ex still wants `fable` was an open question, tracked in
`docs/research/260810-wu-ubm-direction-model-reality-vs-doc.md` (wu-ubm); it
is now settled: yes. The change is pending in statifier-ex's own tracker as
st-4i0; the table above will read `fable` for that column once st-4i0 lands.

None of the three downstream consumers configures `judge`; wurk itself is
the only repo configuring it today, over its own `skills/**/SKILL.md`, per
ADR-0008. wurk's own `.claude/wurk.json` also sets `models.direction` to
`fable` explicitly - the one manifest in this project that does.

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

Defaults applied when a key is absent: `repo.default_branch` = `main`,
`beads.topology` = `beads`,
`commits.style` = `s-form`, `commits.subject_under` = 50,
`commits.body_line_max` = 72, `commits.total_lines_max` = 40,
`commits.trailer.key` = `Refs`, `models.direction` = `opus`,
`artifacts.filename` = `YYMMDD-[id-]kebab`, `judge.model` = `sonnet`.

Everything else absent means the capability is off, and the scripts say so
rather than guessing: no `tmux` section means no tmux integration, no
`gate.report` means tier 0, no `gate.attest` means `attested: false`, no
`gate.project_level_skips` and no `gate.not_applicable_skips` means every
skipped stage blocks, no
`gate.sabotage` means the sabotage scan is off (`data.sabotage.enabled`
false, `missing` always `[]`, no `git diff` shelled out for it), no `judge`
section means `judge?` is `false` and the judge never runs.

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

`ruby skills/wurk:kit/scripts/lib/manifest.rb check [--file PATH]` is the
standalone lint. It emits the usual envelope and exits 1 on an invalid
manifest; an unknown-key warning does not fail it.

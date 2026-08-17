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
                                      // permalink format, close-line syntax.
                                      // The enum accepts "gitlab" today, but
                                      // only "github" is implemented; see
                                      // Forge::IMPLEMENTED in
                                      // skills/wurk:kit/scripts/lib/forge.rb.
    "labels": {}                      // (opt) e.g. {"agent_filed": "agent-filed"}
  },

  "gate": {                           // see docs/gate-contract.md for tiers
    "cwd": "backend",                 // (opt) repo-root-relative dir the five gate
                                      // commands RUN in; omit to run at the repo
                                      // root. Scopes execution only - every path
                                      // list below stays repo-root-relative.
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
    },
    "timeout_seconds": 600            // (opt) default 600; seconds Sh.run allows
                                      // gate.full/gate.loop and gate.attest before
                                      // killing them - raise it for a gate that
                                      // runs inside e.g. docker-compose
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
    "post_branch": [],                // (opt) e.g. fixative's xcodegen/icon chain
    "timeout_seconds": 600            // (opt) default 600; seconds Sh.run allows
                                      // the mise-trust hook and each `warm` command
                                      // before killing them - raise it for a warm
                                      // step that builds container images or fetches
                                      // deps. The post-warm verify runs gate.loop and
                                      // uses gate.timeout_seconds instead.
  },

  "tmux": {                           // (opt) omit = no tmux integration
    "session": "statifier-ex",
    "model": "opus"                   // model for seeded worktree sessions
  },

  "models": {                         // (opt) stage models that differ per project
    "direction": "fable"              // (opt) the ADR/direction tier wurk:work
                                      // dispatches; default "opus". statifier-ex's
                                      // own manifest sets this too (st-4i0); see
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
  },

  "rebase": {                         // (opt) omit = auto-resolution off
    "auto_resolve_paths": []          // (opt) default []; see "rebase.auto_resolve_paths" below
  }
}
```

## `repo.default_branch`

The branch every "what did this branch change" comparison is ultimately taken
against. It names the *local* branch (defaults to `"main"`); the diff base
itself is a small ladder, not that name directly - see `lib/base_ref.rb`
(`BaseRef.resolve`/`BaseRef.changed_files`):

1. `origin/<repo.default_branch>` - the remote-tracking ref, tried first,
   because under worktree-per-issue the local branch is routinely behind
   origin (sibling worktrees merge and push without every checkout
   fetching). This is *not* configurable by remote name - the remote is
   always `origin` - only the branch name on it changes.
2. `<repo.default_branch>` (the local branch) - the fallback when the remote
   ref does not resolve (`git rev-parse --verify --quiet` fails, for example
   in a shallow clone with no `origin` configured). Falling back here warns
   (`stale_base_ref`) rather than silently diffing against a ref that may be
   stale.

The change set a caller acts on is the three-dot diff against whichever ref
resolved, unioned with the working tree (`git status --porcelain`'s modified,
added, and untracked paths) - so uncommitted edits are never invisible to
area labeling, the gate carve-out, or the sabotage scan.

Setting `repo.default_branch` moves several behaviors at once, all reading
the same field:

- the commit carve-out (`gate.rb`'s `gate_applicable?`, `/wurk:commit` Step 0)
- the sabotage mutation-testing pathspec (`gate.rb`'s `sabotage_diff_args`) -
  a **two-dot** diff against `BaseRef.merge_base(resolved base, HEAD)`, not
  the three-dot form the other sites use, so uncommitted tracked edits reach
  the scan too (see `gate.sabotage` below)
- plan-document bead resolution (`bead.rb`'s `resolve_plan_doc_bead`)
- worktree rebasing and staleness checks (`rebase_onto.rb`, `worktree_refresh.rb`,
  `worktree_survey.rb`, `worktree_create.rb`'s base-ref ladder)
- the merge-time judge's base ref
- `repo_state.rb`'s `changed_files`/`dirty_files`, reported alongside the
  resolved ref itself (`data.base_ref`)

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

A third state sits between those two: an enabled scan that ran but could not
check everything. `data.sabotage.scanned` is `false` only when the scan had
nothing to diff against at all - either the diff-base ladder never resolved
(`reason: "no_base_ref"`) or the scan's own `git diff` failed
(`reason: "diff_failed"`) - meaning nothing at all was checked that run; it
is `true` whenever the scan otherwise completed, even if individual
declarations inside it could not be checked. Those per-declaration cases land
in `data.sabotage.unverifiable` too, one entry per declaration, each carrying
a `reason` of `no_base_ref` or `diff_failed` (the whole run, `scanned` is
also `false` for both), `file_unreadable` (the file the declaration lives in
could not be read), `declaration_not_found` (the added line from the diff
could not be located in the working-tree file), or `untracked` (a path under
a `test_roots` prefix that `git status --porcelain` reports as untracked -
invisible to any diff, committed or not, so it is reported rather than
silently skipped). None of this ever flips `ok`; `unverifiable` is a report
on the same terms as `missing`.

A consumer that only reports the scan names the `unverifiable` entries
alongside the `missing` ones and moves on. A consumer that promotes the scan
to a refusal condition in its own `.claude/wurk/commit.md` must decide what a
non-empty `unverifiable` means for it: the honest reading is that those
declarations were not checked, so a refusal keyed on "every new test has a
note" has not been satisfied for them. The kit reports; it does not make that
call, and `unverifiable` never flips `ok`.

- **test_roots** - git pathspecs passed verbatim to
  `git diff <merge-base sha> -U0 --` (the merge base of the resolved
  `repo.default_branch` ref and `HEAD` - see `repo.default_branch` above),
  i.e. where the scan looks for new test declarations. The two-dot form
  against that sha, not a three-dot diff against the branch name, is what
  lets an uncommitted tracked edit reach the scan. A directory prefix
  (`"test/"`) scans every test under it; an
  exact file path or bare glob scopes the scan to enumerated binding tests.
  Entries must not start with `:` - exclusions belong in `exempt_prefixes`,
  the single definition site for what is exempt. Scoping trap: with
  enumerated files, a new binding test in an unlisted file is invisible to
  the scan, so adding a binding test includes adding its path (or covering
  it with a glob) in the same change.
- **test_pattern** - a regex source matched against each added line to
  decide whether it declares a test. statifier's ExUnit shape
  (`\btest\s+"`) is one project's syntax, not a default - a project with a
  different test framework supplies its own.
- **exempt_prefixes** - (opt) path prefixes exempted from the scan, for
  generated test corpora that should never need a hand-written note. This
  one list feeds both the `git diff` pathspec (as `:!prefix` exclusions) and
  the in-scan filter, so there is exactly one definition site for what is
  exempt.

statifier-ex runs the broad form (`test_roots: ["test/"]`), scanning every
new test declaration; predicator-ex runs the narrow form over its
enumerated binding tests; fixative has no sabotage-discipline corpus and
keeps the off state, honestly.

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

## `rebase.auto_resolve_paths`

The only paths a rebase conflict may be auto-resolved in (ADR-0010). Defaults
to `[]`, which is where every consumer starts: an empty list can never
satisfy "every conflicting path is allowlisted", so the feature is off until
a consumer opts in. `lib/conflict_paths.rb` reads it, and
`scripts/rebase_resolve.rb` is the only caller - the resolver `/wurk:mr`
runs when a rebase conflict is confined to allowlisted paths.

Same matching rule as the gate path lists (see "Two path lists, not one"
below): each entry is a directory prefix when it ends in `/`, and an exact
path otherwise; no globbing.

`lib/manifest.rb` validates every entry against the surfaces a rebase
conflict must never be allowed to touch, rather than merely documenting the
rule - a documented-only rule is one a careful consumer follows and a
careless one does not, and the human review step this feature removes was
the only check on that. Per ADR-0010's 2026-08-17 amendment, the surfaces
split into two classes, and only one of them is a disjointness surface:

- An entry equal to `/`, `""`, or `.` is rejected outright. An allowlist
  that resolves to the whole repo is not an allowlist.
- An entry that **matches, or is matched by**, any entry of
  `gate.moving_files`, `gate.guard_ledger`, or `parallelism.repair_when` is
  rejected. Both directions are checked deliberately: allowing `docs/`
  when `docs/plan.md` is one of these is exactly as wrong as allowing
  `docs/plan.md` when `docs/` is. These are hazard surfaces - a machine
  merge of them changes what verification means, not just what it covers:
  `moving_files` is the gate's own configuration, `guard_ledger` is the
  human authorization record for gate changes, and `repair_when` names the
  generated lockfile whose correctness depends on its tool regenerating
  it, not on a line-additive merge being textually clean.
- `gate.build_paths` and `gate.also_gated_paths` are **not** disjointness
  surfaces and a collision with them is accepted. They are coverage lists:
  they declare where the gate looks, so an allowlist entry inside a gated
  tree still gets the full gate run over the merged result, on top of the
  deterministic net and the refute - the most-verified case this feature
  has, not the least. Forbidding that case forbade the wrong one; see
  ADR-0010's amendment for the reasoning.
- An entry that is, or is under, the directory holding the manifest itself
  (`.claude/`, per ADR-0004's two seams - it holds `wurk.json` and every
  extension file) is rejected. This covers the "manifest" stop category;
  without it, `.claude/wurk.json` would otherwise validate cleanly as an
  allowlist entry.

Each rejection names both the offending entry and the list or field it
collided with, so a consumer can fix its manifest without reading the kit
source.

## `gate.cwd`

The repo-root-relative directory the five consumer gate commands
(`gate.full`, `gate.loop`, `gate.report`, `gate.report_loop`, `gate.attest`)
run in. Absent (the common case) means they run at the root of the checkout
being gated. Present, the resolved `chdir:` is
`<root of the checkout being gated>/<gate.cwd>` - the checkout root for
`gate.rb`, and the new (or refreshed) worktree's root for
`worktree_create.rb` and `worktree_refresh.rb`.

**The rule: `gate.cwd` scopes execution of consumer gate commands; it never
rescopes matching of manifest paths.** `gate.build_paths`,
`gate.also_gated_paths`, `gate.moving_files`, `gate.guard_ledger`,
`gate.sabotage.*`, `parallelism.repair_when`, `rebase.auto_resolve_paths`,
and `artifacts.*` all stay relative to the repo root regardless of
`gate.cwd` - see "Two path lists, not one" below. A monorepo consumer whose
gated project lives in `backend/` therefore writes the shared prefix into
every one of those lists, not into a cwd-adjusted subset of them.

`gate.cwd` is never applied outside the five gate commands: not to
`parallelism.trust` / `warm` / `repair` / `post_branch`, and not to any git
command the kit itself runs.

A worked example, a monorepo where the gated project is `backend/`:

```jsonc
"gate": {
  "cwd": "backend",
  "full": ["mix", "quality"],
  "loop": ["mix", "quality", "--profile", "loop"],
  "build_paths": ["backend/lib/", "backend/test/", "backend/mix.exs"]
}
```

`mix quality` runs with its working directory at `<checkout root>/backend`;
`build_paths` still names `backend/lib/` because it is matched against git's
own root-relative output, not resolved as a filesystem path.

**What is root-relative, and against what.** The audit behind this field
walked every kit consumer of a repo-root-relative manifest path:

```
matched against git's own output (`git diff --name-only` and
`git status --porcelain` both print repo-root-relative paths regardless of
the process cwd - whether the list comes from lib/base_ref.rb, as the
changed-file lists do, or from a script's own diff, as the conflicted-file
list in rebase_resolve.rb does - so these are unaffected by gate.cwd and by
the process cwd):
  gate.build_paths, gate.also_gated_paths - lib/gate_paths.rb, consumed by
    gate.rb's carve-out and repo_state.rb's touches_build
  gate.moving_files, gate.guard_ledger, parallelism.repair_when,
    rebase.auto_resolve_paths - lib/conflict_paths.rb, and manifest.rb's
    rebase collision validation (pure string comparison)
  gate.sabotage.test_roots / exempt_prefixes, as prefix filters over
    untracked paths - gate.rb sabotage_untracked_unverifiable
resolved on the filesystem or handed to git as a pathspec (root-relative,
resolved against the manifest's checkout root, never the process cwd):
  gate.guard_ledger existence - gate.rb gate_guard_from
  gate.sabotage.test_roots / exempt_prefixes as `git diff` pathspecs -
    gate.rb sabotage_diff_args
  the working-tree file reads behind the `# sabotage:` note check -
    gate.rb's default sabotage file reader
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
| gate.sabotage | yes | yes (enumerated binding tests) | none |
| parallelism.model | worktree-per-issue | worktree-per-issue | branch-in-place |
| tmux.session | statifier-ex | predicator-ex | (renames current window) |
| models.direction | fable | opus (default) | opus (default) |
| artifacts.plans | docs/plans | docs/plans | thoughts/shared/plans |
| commits.style | s-form | s-form | conventional + package map |
| changelog.mode | fragments | keep-a-changelog (direct) | keep-a-changelog per package |
| release | null (2.0.0-dev) | hex recipe | xcode-app recipe |

The `gate.sabotage` column for predicator-ex describes this schema's
intent, not yet that repo's own manifest: predicator-ex has the narrow
sabotage discipline (see wu-4r7), but adopting `test_roots` with its
enumerated binding-test paths in predicator-ex's own `.claude/wurk.json` is
separate downstream work not yet landed.

`models.direction` was added to the schema because statifier-ex and
predicator-ex were observed to disagree on it (statifier wanted Fable,
predicator Opus). That was the intent, but neither manifest set the field for
a while, so both ran on the loader's `opus` default. Whether statifier-ex
still wanted `fable` was an open question, tracked in
`docs/research/260810-wu-ubm-direction-model-reality-vs-doc.md` (wu-ubm); it
is now settled: yes. st-4i0 landed the change in statifier-ex's own manifest,
so the table above reads `fable` for that column.

None of the three downstream consumers configures `judge`; wurk itself is
the only repo configuring it today, over its own `skills/**/SKILL.md`, per
ADR-0008. wurk's own `.claude/wurk.json` also sets `models.direction` to
`fable` explicitly - the one manifest in this project that does.

`rebase.auto_resolve_paths` follows the same pattern: statifier-ex and
predicator-ex start at the schema default, `[]`, same as fixative and every
other consumer that has not opted in. wurk's own `.claude/wurk.json` sets it
to `["docs/plan.md"]` - the narrowest useful value, the exact file from the
incident that motivated ADR-0010, and nothing wider.

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
`artifacts.filename` = `YYMMDD-[id-]kebab`, `judge.model` = `sonnet`,
`rebase.auto_resolve_paths` = `[]`, `gate.timeout_seconds` = `600`,
`parallelism.timeout_seconds` = `600`.

Everything else absent means the capability is off, and the scripts say so
rather than guessing: no `tmux` section means no tmux integration, no
`gate.report` means tier 0, no `gate.attest` means `attested: false`, no
`gate.project_level_skips` and no `gate.not_applicable_skips` means every
skipped stage blocks, no
`gate.sabotage` means the sabotage scan is off (`data.sabotage.enabled`
false, `missing` always `[]`, no `git diff` shelled out for it), no `judge`
section means `judge?` is `false` and the judge never runs, no `rebase`
section (or an empty `auto_resolve_paths`) means rebase auto-resolution is
off - see "`rebase.auto_resolve_paths`" above, and no `gate.cwd` means the
gate commands run at the root of the checkout being gated.

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
- **`rebase.auto_resolve_paths` entries are validated disjoint** from
  `gate.moving_files`, `gate.guard_ledger`, `parallelism.repair_when`, and
  the manifest's own directory (`.claude/`) - in both match directions -
  plus rejected outright if an entry is `/`, `""`, or `.`. A collision with
  `gate.build_paths` or `gate.also_gated_paths` is accepted: those are
  coverage lists, not hazard surfaces, and an entry inside a gated tree
  still gets the full gate run over the merged result. See
  "`rebase.auto_resolve_paths`" above for why the hazard surfaces are
  validated rather than merely documented, and why the coverage lists are
  not disjointness surfaces.
- **`gate.timeout_seconds` must be a positive integer.** Zero, a negative
  number, a float, and a non-numeric value all block.
- **`parallelism.timeout_seconds` must be a positive integer.** Same rule,
  same validation, as `gate.timeout_seconds` above.
- **`gate.cwd` must be a relative subdirectory path.** An absolute path,
  `.`, `""`, a non-string, or any `..` segment blocks. Existence is
  deliberately not checked; see "`gate.cwd`" above. A `gate.cwd` that does
  not exist (or a gate command missing from `PATH`) is instead caught when
  the gate command tries to start: `gate.rb` reports it as a `blocked`
  envelope entry (`gate_command_could_not_start` / `gate_attest_could_not_start`)
  naming the command and the resolved directory, exit code 1 - never a raw
  traceback (wu-8eh).

`ruby skills/wurk:kit/scripts/lib/manifest.rb check [--file PATH]` is the
standalone lint. It emits the usual envelope and exits 1 on an invalid
manifest; an unknown-key warning does not fail it.

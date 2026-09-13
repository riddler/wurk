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
                                      // Both values are implemented for every
                                      // capability; see Forge::IMPLEMENTED in
                                      // skills/wurk:kit/scripts/lib/forge.rb.
    "host": "gitlab.example.com",     // (opt) a self-hosted instance's bare
                                      // hostname, optionally with a port.
                                      // Absent means the kind's own host
                                      // (github.com, gitlab.com) - see
                                      // "forge.host" below
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
    "timeout_seconds": 600,           // (opt) default 600; seconds Sh.run allows
                                      // gate.full/gate.loop and gate.attest before
                                      // killing them - raise it for a gate that
                                      // runs inside e.g. docker-compose
    "long_timeout_seconds": 3600      // (opt) default 3600; seconds the detached
                                      // long-gate runner (gate_run.rb) allows the
                                      // gate command before killing it. Separate
                                      // from timeout_seconds: that one bounds a
                                      // FOREGROUND run whose caller is blocked, this
                                      // one bounds the DETACHED run that exists to
                                      // outlive that bound
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
    "layout": "window-per-issue",     // (opt) or "session-per-issue"; see ## tmux
    "session": "statifier-ex",        // required under window-per-issue
    "model": "opus",                  // model for seeded worktree sessions
    "editor": ["nvim"]                // (opt) session-per-issue only; omit = no editor window
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
    "adr": "docs/adr",                // (opt) decision records; see "artifacts.adr"
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
  },

  "mr": {                             // (opt) omit = no pre-request review round
    "review_agents": [                // required when mr is present; non-empty.
      "wurk-diff-critic",             // Bare agent names: the repo's own
      "convention-reviewer"           // .claude/agents/<name>.md, or wurk's
    ]                                 // installed roster; see "mr.review_agents"
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

## `forge.host`

Where the forge lives, for a consumer not on the public instance: a
self-hosted GitLab, a GitHub Enterprise server. It is a **bare host** - a
hostname, optionally with a port (`gitlab.example.com`,
`git.example.com:8443`) - and never a URL. The value is interpolated between
`https://` and the project path when a permalink is written
(`Forge.blob_url`), so a scheme, a path, or a trailing slash would produce a
link that is wrong in a way nothing downstream can notice: it is written into
a document and 404s for whoever clicks it weeks later. `lib/manifest.rb`
therefore blocks on the shape rather than warning. It checks the shape only -
no DNS lookup, no reachability probe - the same line `gate.cwd` draws.

**Absent means the forge kind's own host**, and that default lives in
`Forge::DEFAULT_HOSTS` (`github` -> `github.com`, `gitlab` -> `gitlab.com`)
rather than in this schema's defaults table, for two reasons. It is a fact
about the forge and not a consumer value, which is what keeps it out of the
kit's no-consumer-constants rule (CLAUDE.md); and it depends on another field,
which the defaults table - a flat map of dotted key to value - cannot express.
So every manifest written before this field existed keeps validating and keeps
resolving to the same host it always used.

The companion of the host is the **project path**: a repo's identity on its
forge, as one string of `/`-joined namespace segments. That is not a manifest
field - the forge is asked for it (`gh repo view` on GitHub,
`glab api projects/:id` on GitLab, both in `permalinks.rb`) because the git
remote is not a reliable answer: an ssh alias, an `insteadOf` rewrite, or a
fork remote all yield a path the forge would not agree with. It is a path
rather than the `owner` + `repo` pair the kit carried before wu-4wl.1 because
a GitLab project can be `group/subgroup/project` or deeper, which a
two-segment pair cannot hold at all; GitHub's two-segment identity is simply
the shortest case of the same model.

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

## `artifacts.adr`

The directory of the project's decision records, checkout-relative.
`/wurk:plan` and `/wurk:research` forward it to the docs agents beside `artifacts.plans` and `artifacts.research`, and the
Direction stage of `/wurk:work` writes a new record there at the next
free number. Optional, and absent is a distinct state rather than a
default: the docs agents then fall back to their conventional candidates
(`docs/adr/` among them) and say in their report that the root was a
guess, which is the honesty the key exists to remove. There is
deliberately no default of `docs/adr`, so a manifest that says nothing
never claims the project keeps records it does not.

`validate!` checks the shape only: a non-empty, checkout-relative path.
Whether the directory exists is checked by `manifest.rb check`, which
**blocks** (code `artifacts_adr_missing`) on a declared directory that is
not there, the same rule as `mr_review_agent_missing`: a declared root with
nothing behind it has no legitimate reading, and the alternative is a
Direction stage that finds no records to imitate and invents a format.
`manifest.rb check` reports the value as `data.artifacts_adr`, `null` when
absent. A new project that wants records seeds the directory with its
first one before declaring the key; wurk's own ADR-0001 is the shape.

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

## `mr.review_agents`

The read-only review agents this repo ships in `.claude/agents/`, spawned
once against the worktree by `/wurk:mr` after the gate is green and before
the push. Names only: the kit never learns what any of them review, only
which ones to run.

This is not `judge`. `judge` (ADR-0008) is a merge-time propose/refute pass
over **registered documents**, asking whether a change to judgment-bearing
prose broke the rule that document states. This is a review of **the diff**
by agents the consumer wrote, in the consumer's own terms. A repo can
declare both, neither, or either one.

- **review_agents** - required when `mr` is present, non-empty array of
  bare agent names. Each name resolves to the first of two files that
  exists: the repo's own `.claude/agents/<name>.md`, then the installed
  `~/.claude/agents/<name>.md`, which is where `install.rb` links the
  agents wurk ships (`wurk-diff-critic`, `wurk-test-critic`; each ranks its
  findings `must-fix` / `should-fix` / `note`, the vocabulary `/wurk:mr`
  honors). A repo file shadows an installed one of the same name, so a
  consumer can ship its own variant under wurk's name. A name is a
  filename segment and never a path: an entry containing `/`, a `..`
  segment, a leading `-`, or an empty string blocks. A name repeated in
  the list blocks too - the round is deliberately single, so a second
  instance of the same agent is another run rather than another opinion.

**Absent means no round, silently.** Present-or-absent, never
half-present, the same rule `gate.sabotage`, `judge` and `rebase` follow: an
`mr` section with a missing or empty `review_agents` is a schema error, not
a quietly disabled round. Off is spelled by omitting the section, and the
skill skips it without a warning - a repo that ships no review agents is not
a repo with a gap in its process.

The two checks split the same way `beads.sync` splits. Shape - a non-array,
an empty list, a path-shaped name, a duplicate - is validated on every
manifest load. **Whether a declared name has a file behind it is checked
only by `manifest.rb check`**, because `validate!` reads no filesystem; that
check **blocks** (code `mr_review_agent_missing`) rather than warning, since
a name with nothing behind it has no legitimate reading, and the alternative
to rejecting it in the lint is discovering it in `/wurk:mr` after the gate
has run. The installed root is anchored on `HOME` the same way the machine
config is (`docs/machine-config.md`), so a machine that has not run
`install.rb` fails this check for wurk's own names, which is the honest
result: the round would have failed to spawn them.

`manifest.rb check` reports the resolved list as `data.mr_review_agents`,
which is how `/wurk:mr` and `wurk-repo-worker` read the round without
parsing the manifest themselves - empty when the consumer declares none.

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

## `tmux`

`tmux.layout` selects one of two topologies for seeded worktree sessions.
Absent means `window-per-issue`, today's behavior.

- **window-per-issue** (default) - every issue's seeded session lands as a
  new window inside one shared session, named by `tmux.session`.
  `tmux.session` is required under this layout: `ensure-session` and `open`
  address that session by name, so a missing or empty value blocks
  validation.
- **session-per-issue** - each issue gets its own tmux session, named after
  the workspace (the same `<bead-id>-<slug>` string that names the branch
  and the worktree). `tmux.session` is unused under this layout and may be
  absent.

`tmux.editor` is an optional argv array, the same shape as `gate.full` and
`parallelism.trust` - a shell string is a validation error naming
`tmux.editor`, not something split on whitespace. It applies to
`session-per-issue` only: when present, an editor window is opened in the
worktree running the argv as the window's command, named after the argv's
first element's basename (`["nvim"]` names the window `nvim`). Omitting
`tmux.editor` skips the editor window entirely.

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

## `beads.sync`

How this repo's beads database syncs, and therefore whether any skill is
ever allowed to run `bd dolt push` here. Three modes:

- **local** - the beads never leave the machine. `bd dolt push` is
  forbidden. A step that would have pushed reports `not pushed, tracker is
  local` instead and carries on; nothing else about the step changes,
  including the `bd note` that records a request URL on the bead.
- **git** - the dolt remote is a git+ssh URL on the same forge as the code
  (`git+ssh://git@<host>/./<owner>/<repo>.git`). The tracker is pushed
  **after** the code push, because that is the point at which a reviewer
  can see a branch whose bead they cannot.
- **dolthub** - the remote is a DoltHub database rather than a forge URL.
  Same ordering as `git`. The remote name and the credentials differ: a
  DoltHub remote authenticates with `dolt login` / a DoltHub API token
  rather than the ssh key the code push uses, and the remote is often not
  called `origin`. `bd dolt push` with no argument pushes the configured
  default; if a repo's DoltHub remote is named something else, that name is
  the argument, and the repo says so in its `.claude/wurk/mr.md` extension
  rather than in this schema.

**Absent means `local`**, and that default is chosen against the usual
rule. Every other default in this schema is the most common value
(`repo.default_branch` = `main`); this one is the value that does the
least, because the two failure directions are not symmetrical:

- Guessing `git` for a repo whose beads are local publishes an issue
  database that was never meant to leave the machine. Nothing un-publishes
  it - a deleted ref is still in someone's clone and in the forge's logs.
- Guessing `local` for a repo that does push costs one skipped push and a
  warning saying exactly that.

So an absent key can never cause a push. This is the same asymmetry the
rest of "Validation" below rests on: guessing a structural behavior is
worse than stopping, and where a guess must be made it is made only in the
recoverable direction.

An unset key **warns** (never blocks) on every manifest load, naming the
three modes - so a repo that does push is told to declare the key rather
than quietly losing its tracker pushes.

The lint adds a second, environmental warning: **mode `local` (declared or
defaulted) while this checkout's `.beads` still has a dolt remote
configured.** That combination is the footgun the key exists for. It reads
two places, because a remote can be in either:

- `.beads/config.yaml`, the `sync.remote` key `bd` itself reads (commented
  lines do not count - the shipped config documents the key in a comment).
- `.beads/embeddeddolt/*/.dolt/repo_state.json`, dolt's own state, which
  keeps a remote added once even after the yaml no longer mentions it. In
  the incident behind this key the remote was only here, and a guard script
  that kept deleting it from the yaml never reached it.

It is a warning and not a block: the remote may be there for a legitimate
read-only reason, and the real guarantee is upstream of it - under `local`
no skill issues the push at all. The warning exists to get the loaded gun
out of the room. Unlike everything in `validate!`, this check touches the
filesystem, which is why it lives in `manifest.rb check` rather than in
load-time validation.

`manifest.rb check` also reports `data.beads_sync` and
`data.beads_sync_declared`, which is how `/wurk:mr` and `/wurk:cleanup`
gate their tracker push without parsing the manifest themselves. The two
fields are separate because "local because the repo said so" and "local
because nobody said anything" are different sentences in a report.

## `{path}` substitution

`parallelism.trust` is the one command run *about* a new worktree rather
than inside it, so its argv may contain the literal token `{path}`, replaced
with the new worktree's absolute path. No other field templates.

## Per-repo starting values

A Python consumer is worked through in `docs/examples/python.md` rather
than as a column here; it is a starting recipe, not a repo that has
adopted.

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
| beads.sync | git | git | (TBD - declare before the first `/wurk:mr`) |
| forge.kind | github | github | gitlab |
| forge.host | absent (github.com) | absent (github.com) | absent (gitlab.com) unless the instance is self-hosted - declare it before the first permalink run |
| gate.full | mix quality | mix quality | mise run quality |
| gate.loop | mix quality --profile loop | mix quality --profile loop | mise run quality:quick |
| gate.report | yes (ex_quality JSON) | yes | no (tier 0; tier 1 later) |
| gate.attest | mix gate.verify | none | none |
| gate.sabotage | yes | yes (enumerated binding tests) | none |
| parallelism.model | worktree-per-issue | worktree-per-issue | branch-in-place |
| tmux.layout | window-per-issue (default) | window-per-issue (default) | window-per-issue (default) |
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
`beads.topology` = `beads`, `beads.sync` = `local` (and warns - see
"`beads.sync`" above for why the default is the safe value rather than the
common one),
`commits.style` = `s-form`, `commits.subject_under` = 50,
`commits.body_line_max` = 72, `commits.total_lines_max` = 40,
`commits.trailer.key` = `Refs`, `models.direction` = `opus`,
`artifacts.filename` = `YYMMDD-[id-]kebab`, `judge.model` = `sonnet`,
`rebase.auto_resolve_paths` = `[]`, `gate.timeout_seconds` = `600`,
`gate.long_timeout_seconds` = `3600`,
`parallelism.timeout_seconds` = `600`, `tmux.layout` = `window-per-issue`.

One default is not in that list because it cannot be: `forge.host` defaults to
the host of the declared `forge.kind`, which a flat dotted-key table cannot
express. It is resolved in `lib/forge.rb` (`Forge::DEFAULT_HOSTS`) instead -
see "`forge.host`" above.

Everything else absent means the capability is off, and the scripts say so
rather than guessing: no `tmux` section means no tmux integration, and a
`tmux` section with no `layout` means `window-per-issue`; no
`gate.report` means tier 0, no `gate.attest` means `attested: false`, no
`gate.project_level_skips` and no `gate.not_applicable_skips` means every
skipped stage blocks, no
`gate.sabotage` means the sabotage scan is off (`data.sabotage.enabled`
false, `missing` always `[]`, no `git diff` shelled out for it), no `judge`
section means `judge?` is `false` and the judge never runs, no `rebase`
section (or an empty `auto_resolve_paths`) means rebase auto-resolution is
off - see "`rebase.auto_resolve_paths`" above, no `mr` section means
`/wurk:mr` runs no pre-request review round and says nothing about it, and
no `artifacts.adr` means the docs agents locate decision records by
convention and say so, and
no `gate.cwd` means the gate commands run at the root of the checkout being
gated.

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
- **An unset `beads.sync` warns** and resolves to `local`, so the absent
  key can never cause a tracker push. A *bad* value still blocks, like
  every other enum. See "`beads.sync`" above.
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
- **`mr.review_agents` must be a non-empty array of bare agent names**
  when the `mr` section is present. A non-array, an empty list, a name
  containing a path separator or a `..` segment, and a name repeated in the
  list all block. Whether the name resolves to `.claude/agents/<name>.md` is
  checked by `manifest.rb check` only, and blocks there. See
  "`mr.review_agents`" above.
- **`forge.host` must be a bare hostname**, optionally with a port, when the
  field is present. A scheme, a path, a trailing slash, an empty string, and
  a non-string all block; the shape is checked without any DNS or
  reachability probe. An absent field is legal and resolves per forge kind.
  See "`forge.host`" above.
- **`gate.timeout_seconds` must be a positive integer.** Zero, a negative
  number, a float, and a non-numeric value all block.
- **`gate.long_timeout_seconds` must be a positive integer.** Same rule as
  `gate.timeout_seconds` above. A value less than `gate.timeout_seconds` is
  legal but warns, naming which field bounds which kind of run - it is
  almost certainly a mistake, since the long-gate run exists to outlive the
  short one, not the other way around.
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

### Retired keys

`tmux.permission_mode` existed in this schema (wu-b7f) and moved to the
machine-level config in wu-jhb. A manifest that still sets it stays valid
and gets exactly one warning naming the key and pointing at
`docs/machine-config.md`; the value itself is ignored. See that document for
where the setting lives now.

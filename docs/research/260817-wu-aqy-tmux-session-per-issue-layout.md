---
date: 2026-08-17T17:29:34-0600
researcher: Claude
git_commit: cb3ad01bb889c81a2b04de3452654ffa43e8d5f6
branch: wu-aqy-tmux-session-per-issue
repository: wurk
beads_issue: wu-aqy
topic: "tmux session-per-issue layout for wurk:branch: what the codebase does today"
tags: [research, codebase, tmux, manifest, kit]
status: complete
last_updated: 2026-08-17
last_updated_by: Claude
---

# Research: tmux session-per-issue layout for wurk:branch

**Date**: 2026-08-17T17:29:34-0600
**Git Commit**: cb3ad01bb889c81a2b04de3452654ffa43e8d5f6
**Branch**: wu-aqy-tmux-session-per-issue
**Bead**: wu-aqy

## Research Question

wu-aqy asks for an alternative tmux layout in which each issue gets its own
tmux *session* (named what the window would have been today), containing
window 1 = a manifest-configured editor command running in the worktree and
window 2 = `claude`, running the seeded `claude ... /wurk:work <id> --auto`.
The manifest sketch is a `tmux.layout` enum (`window-per-issue` default,
`session-per-issue`) plus an optional `tmux.editor` argv, where omitting the
editor skips that window.

This document records what exists today across everything that would touch:
`tmux_window.rb` and its test, `lib/manifest.rb`'s tmux accessors plus the
manifest fixtures and validation, `docs/manifest.md`'s tmux material and the
doc/code sync discipline, `/wurk:branch`'s call sites, `/wurk:cleanup` and
`worktree_cleanup.rb`, the kit script contract and the test that enforces it,
and the relevant ADRs.

## Summary

Today the kit has exactly **one** tmux topology, and it is not named
anywhere: a single manifest-named session (`tmux.session`) that accumulates
**one window per issue**, the window name being the same `<bead-id>-<slug>`
string that names the branch and the worktree directory.

The mechanics live in one script, `skills/wurk:kit/scripts/tmux_window.rb`,
with six subcommands split cleanly into two groups:

- **Session-addressing** - `ensure-session` and `open`. These two are the
  only ones that read `manifest.tmux_session`, and they are the only two
  gated on the manifest having a `tmux` section at all
  (`tmux_window.rb:136-149`, block code `tmux_not_configured`).
- **Session-agnostic** - `find`, `classify`, `quiesce`, `close`. These work
  purely from a tmux window id. `find` deliberately searches the whole tmux
  server (`tmux list-panes -a`), matching on window **name and pane path
  together**, and never consults the manifest session name at all
  (`tmux_window.rb:421-461`, and the comment stating the split at
  `tmux_window.rb:132-135`).

That split is why the cleanup half of the workflow is already indifferent to
which session a window lives in, while the seeding half is not.

The seeding half is driven entirely from skill prose:
[`skills/wurk:branch/SKILL.md:100-118`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:branch/SKILL.md#L100-L118) runs `ensure-session` then
`open [--no-finish] <name> <path> <id> <seed>`. The `<name>` it passes is
whatever it was given as the branch/worktree name; `worktree_create.rb` is
naming-agnostic and simply propagates that one string into the branch, the
directory and (via the skill) the window name.

The seeded command line is composed in one place,
`claude_command` (`tmux_window.rb:157-160`), as
`caffeinate_prefix + "claude --permission-mode auto --model <tmux.model> '<body>'"`,
where the body is the seed plus the appended `FINISH_TEMPLATE`
(`tmux_window.rb:35-37`) unless `--no-finish` is passed. There is no notion of
any *other* command being launched in a workspace - no editor, no second
window, nothing but the one seeded claude window.

On the manifest side, `tmux` is an optional section with exactly two known
keys, `session` and `model` (`lib/manifest.rb:77`), three accessors
(`lib/manifest.rb:405-415`), no `DEFAULTS` entries, no `ENUMS` entries, and no
dedicated `validate_tmux` method - it participates only in the generic
unknown-key warning pass. `docs/manifest.md` gives it four lines inside the
schema fence ([`docs/manifest.md:93-96`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/manifest.md#L93-L96)) and no `##` subsection of its own.

## Detailed Findings

### tmux_window.rb - the six subcommands

Dispatch is a flat `case` in `run` (`tmux_window.rb:76-91`); an unknown
subcommand warns the usage line and `exit 2`, matching the contract's usage
exit code.

**Module-level constants and invariants** (`tmux_window.rb:22-53`):

- `SHELL_COMMANDS = %w[fish zsh bash sh]` - the definition of "this pane is
  a bare shell, claude is gone".
- `FINISH_TEMPLATE` (`:35-37`) - the appended finishing clause, with `%{id}`
  and `%{trailer}` substituted per call. The header comment (`:25-34`) states
  the reason it is a single template: editing it reaches every seeded session
  without touching the calling skills.
- `SPINNER_TIMER`, `SPINNER_INTERRUPT`, `SGR`, `DIM_SPAN` (`:42-45`) - the
  byte-level idle classifier's inputs.
- `QUIESCE_MAX_POLLS = 15`, `QUIESCE_POLL_INTERVAL_SECONDS = 1`,
  `CLASSIFY_SAMPLE_INTERVAL_SECONDS = 3` (`:47-49`).
- `BATTERY_FLOOR_PERCENT = 40` (`:53`, wu-ds2).

The file's header comment (`tmux_window.rb:18-21`) carries the hard rule:
never `kill-pane`, never `kill -9`/SIGKILL; a quiesce timeout is reported
`blocked`, not escalated. `kill-window` on a window whose every pane is
already a bare shell is explicitly carved out as not that rule.

`session_target(session)` (`:72-74`) returns `"=#{session}"` - the tmux
exact-match form - with a comment recording that the leading `=` is a shell
hazard when copied out of a rendered `commands` line, which is why it is
documented rather than dropped.

**`ensure-session`** (`tmux_window.rb:282-336`):

1. `tmux_manifest(env)` - blocks `tmux_not_configured` if the manifest has no
   `tmux` section.
2. `session = manifest.tmux_session` (`:292`).
3. `main_repo = Manifest.main_checkout` (`:299`) - derived at runtime from
   `git rev-parse --git-common-dir`, blocking `main_checkout_unknown` if git
   gives nothing (`:300-306`). The comment at `:294-298` records why this is
   not a constant.
4. `tmux has-session -t =<session>`; on failure,
   `tmux new-session -d -s <session> -c <main_repo>` (`:308-309`).
5. Dry run renders both, with the second prefixed
   `"(only if has-session fails) "` (`:311-317`).
6. Data: `session`, `created` (and `main_repo` on the create path).

**`open`** (`tmux_window.rb:340-417`), the only mutating seeding path:

- Options: `--no-finish` (`:341-348`). Positional arity is strict -
  `<name> <path> <id> <seed>`, any blank one is a usage error, `exit 2`
  (`:350-353`).
- Duplicate guard: `tmux list-windows -t =<session> -F '#{window_name}'`; an
  exact name hit returns `data.skipped = true` with a reason string, and does
  **not** create a second window (`:364-376`). The comment calls this the
  same shape as `worktree_create.rb`'s branch/directory guards.
- `keys = claude_command(model, seed, id, manifest.trailer_key, no_finish:)`
  (`:378`).
- `tmux new-window -d -P -F '#{window_id}' -t =<session>: -n <name> -c <path>`
  (`:379`).
- **The empty-window-id trap** (`:395-405`): if the captured window id is
  empty, block `window_id_empty` rather than issue any `-t` command, because
  tmux resolves an empty `-t` to the *current* window. The comment dates the
  incident (2026-08-02).
- `tmux send-keys -t <window_id> <keys> Enter`; a failure is a warning
  (`send_keys_failed`), not a block (`:407-408`).
- Data: `window_id`, `name`, `path`, `model`, `no_finish`, `skipped`.

**`find`** (`tmux_window.rb:421-461`): `tmux list-panes -a -F '#{window_id}
#{window_name} #{pane_current_path}'`, matching `wname == name && wpath ==
path`. Zero matches is `found: false` and *not* an error; one match returns
the window id; two or more blocks `ambiguous_window_match`. The comment
(`:438-440`) explains matching on both halves: name alone would close a
renamed window, path alone would close a stray shell.

**`classify`** (`tmux_window.rb:465-511`): blocks `empty_window_id` on a blank
id; then checks `pane_current_command` first, returning `status: "exited"`
when every pane is a bare shell (`:483-489`); otherwise captures twice
~3 s apart via `tmux capture-pane -e -p -t <window_id>` and requires idle
both times to report `idle` (`:491-498`). The pure classifier
(`TmuxWindow.classify`, `:106-121`) is I/O-free and is what the fixtures test.

**`quiesce`** (`tmux_window.rb:515-568`): `send-keys C-u`, then
`send-keys /exit Enter`, then polls `pane_current_command` up to 15 times at
1 s. Exit -> `status: "exited"`; timeout -> block `quiesce_timeout`
(`:550-554`), never escalated.

**`close`** (`tmux_window.rb:572-618`): re-checks `pane_current_command`;
a failed list blocks `list_panes_failed`; a non-bare-shell window returns
`closed: false, reason: "window kept, other panes busy"`; otherwise
`tmux kill-window -t <window_id>` (a kill failure is a warning, not a block).

**Shared** `bare_shell_panes?` (`tmux_window.rb:634-639`) is the single
definition all three of quiesce/close/classify use, with a sabotage comment
naming the three tests that go red if it is broken.

The caffeinate probe (`tmux_window.rb:207-246`) wraps the launched command in
`caffeinate -i` when `which caffeinate` succeeds and `pmset -g batt` reports
AC power or battery strictly above 40%; every failure path degrades to the
empty string, giving a byte-identical unwrapped launch string.

### lib/manifest.rb - tmux accessors, defaults, validation

- `tmux?` - `lib/manifest.rb:405-407`, `!fetch("tmux").nil?`; the same
  section-presence idiom as `judge?` (`:480-482`) and `sabotage?`
  (`:340-342`).
- `tmux_session` - `lib/manifest.rb:409-411`, `fetch("tmux.session")`.
- `tmux_model` - `lib/manifest.rb:413-415`, `fetch("tmux.model")`.
- `trailer_key` - `lib/manifest.rb:458-460`, `fetch("commits.trailer.key")`,
  the other manifest value `tmux_window.rb` reads.

There is no `OPTIONAL` list; a field is optional by being absent from
`REQUIRED` (`lib/manifest.rb:43-53`, which does not name `tmux`). `fetch`
(`:513-517`) is a dotted lookup falling back to `DEFAULTS[dotted]` only when
the raw value is nil; `tmux.*` has no `DEFAULTS` entries, so absence resolves
to plain `nil`.

**The enum pattern a `tmux.layout` would follow**, as it exists for the
current enums:

- `ENUMS` hash keyed by dotted path (`lib/manifest.rb:56-62`), e.g.
  `"parallelism.model" => %w[worktree-per-issue branch-in-place]` (`:59`) and
  `"commits.style" => %w[s-form conventional]`.
- `validate_enums` (`lib/manifest.rb:856-864`) is one shared loop: fetch,
  skip when nil (an absent optional enum is not an error), otherwise append
  an error. The class comment (`:32-34`) states the rule - an unrecognized
  enum value blocks rather than falling back to a default.
- Optional-with-default enum: `commits.style` is not required and carries
  `DEFAULTS["commits.style"] = "s-form"` (`:90`) with a one-line `fetch`
  accessor (`commit_style`, `:442-444`).
- Required-no-default enum: `parallelism.model`, `forge.kind` are in both
  `REQUIRED` (`:47`, `:49`) and `ENUMS`, absent from `DEFAULTS`.
- Known-key registration: `KNOWN["tmux"] = %w[session model]`
  (`lib/manifest.rb:77`); `collect_unknown_keys` (`:869-881`) turns anything
  else in the section into a **warning**, never an error.

Sections with cross-field or nested shape rules (`gate.sabotage`, `judge`,
`rebase`) get dedicated `validate_*` methods; scalar enums do not.

`Manifest.require!` (`lib/manifest.rb:129-140`) is the one entry point
scripts use: it turns an invalid manifest into `env.block!` with code
`manifest_invalid`, a missing/unparseable one into `manifest_unavailable`,
and forwards unknown-key warnings as `manifest_unknown_key`.
`Manifest.main_checkout` (`:160-168`) shells `git rev-parse --git-common-dir`
and returns its parent, or nil.

There is no separate manifest lint script: `lib/manifest.rb` doubles as a CLI
(`ManifestCli`, `:889-938`), `ruby lib/manifest.rb check [--file PATH]`,
emitting the standard envelope with `data.valid`, `data.errors`, warnings as
`unknown_key`, errors as `invalid`, exit 0/1.

### Manifest fixtures and manifest_test.rb

Fixtures live at `skills/wurk:kit/scripts/test/fixtures/manifests/` (20
files): `areas.json`, `areas_wide.json`, `bad_enum.json`, `commits.json`,
`forge_gitlab.json`, `gate_subdir.json`, `gate_tier0.json`, `gate_tier1.json`,
`judge.json`, `malformed.json`, `missing_required.json`, `rebase.json`,
`repo_layout.json`, `shell_string_command.json`, `thoughts_layout.json`,
`tmux.json`, `unknown_key.json`, `valid.json`, `worktree.json`,
`wrong_version.json`.

Only `tmux.json` carries a tmux section -
`{"session": "zz-session", "model": "fakemodel"}` at
[`skills/wurk:kit/scripts/test/fixtures/manifests/tmux.json:55-58`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/fixtures/manifests/tmux.json#L55-L58). `valid.json`
deliberately has none, which is what exercises the absent-section path.

In `manifest_test.rb`:

- `ManifestFixtures` ([`skills/wurk:kit/scripts/test/manifest_test.rb:16-41`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/manifest_test.rb#L16-L41))
  loads a fixture by name, with `load_with(name, overrides)` deep-merging for
  one-field variations. The comment (`:11-15`) states the rule that tests
  never touch the repo's real `.claude/wurk.json`.
- The only tmux accessor test is
  `test_absent_tmux_section_reports_no_tmux_integration`
  (`manifest_test.rb:673-676`) - `refute m.tmux?`, `assert_nil
  m.tmux_session` against `valid`. Value coverage for a populated tmux
  section comes indirectly through `tmux_window_test.rb`, which asserts the
  rendered `--model fakemodel` and `=zz-session` strings.
- `ManifestCliTest#test_every_valid_fixture_manifest_satisfies_the_schema`
  (`manifest_test.rb:937-950`) globs every fixture except a
  `DELIBERATELY_INVALID` list (`:935`) and asserts each validates with zero
  warnings - the net that catches a `KNOWN`/`ENUMS` edit made in only one of
  the two places.
- Validation tests are written with a `sabotage: ... -> red` comment naming
  the branch a mutant would remove (e.g. `manifest_test.rb:58,65,74`), then
  `refute m.valid?` plus `assert_match` on the error text. The enum-rejection
  archetype is `test_unknown_enum_value_blocks_rather_than_defaulting`
  (`manifest_test.rb:59-63`).

### docs/manifest.md and the doc/code sync discipline

The tmux material is four lines inside the single big `jsonc` schema fence
([`docs/manifest.md:12-149`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/manifest.md#L12-L149)):

```
  "tmux": {                           // (opt) omit = no tmux integration
    "session": "statifier-ex",
    "model": "opus"                   // model for seeded worktree sessions
  },
```
([`docs/manifest.md:93-96`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/manifest.md#L93-L96))

Structure of the document: one big schema fence with per-field inline
comments marking `(opt)` and the degraded behavior; then `##`-level headings
for fields that need prose (`repo.default_branch` `:152`, `gate.sabotage`
`:253`, `judge` `:324`, `rebase.auto_resolve_paths` `:354`, `gate.cwd`
`:403`); then cross-cutting sections - `## Per-repo starting values` (a
table, `:507-558`), `## Resolution` (`:560-577`), `## Required, optional, and
defaults` (`:579-604`), `## Validation` (`:606-645`). `tmux` has no `##`
subsection; it appears additionally at `:527` in the per-repo table
(statifier-ex / predicator-ex / "(renames current window)" for fixative) and
at `:595` in the absence rule ("no `tmux` section means no tmux
integration").

Sync is stated at the top: "`lib/manifest.rb` ... is the authority; this
document follows it in the same commit (see CLAUDE.md's hard rules)"
([`docs/manifest.md:3-6`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/manifest.md#L3-L6)), matching CLAUDE.md's hard rule. **No test enforces
that sync.** The one mechanical doc/code drift check in the suite is a
different one: `contract_test.rb` re-parses ADR-0006's banned-operation
paragraph and asserts each backticked operation has a matching rule
([`skills/wurk:kit/scripts/test/contract_test.rb:691-709`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/contract_test.rb#L691-L709)).

### skills/wurk:branch/SKILL.md - the seeding call site

- Frontmatter describes worktree-per-issue as producing "a warmed worktree
  with its own branch and a seeded tmux session"
  ([`skills/wurk:branch/SKILL.md:1-6`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:branch/SKILL.md#L1-L6)); `branch-in-place` is documented as not
  implemented and a clear refusal (`:24-26`).
- Extension seam: `.claude/wurk/branch.md`, read before step 1, add-only
  ([`skills/wurk:branch/SKILL.md:35-41`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:branch/SKILL.md#L35-L41)). No such file exists in this repo.
- Input: optional `--no-finish`, then the branch name, optionally `--` and a
  seed (`:43-49`). The branch name is also the worktree directory name,
  `<bead-id>-<slug>`, slug 2-4 kebab words (`:51-55`), and is never changed
  because "`/wurk:cleanup` matches its tmux window on name and path together,
  and both halves come from this skill" (`:57-59`).
- Step 1 runs `worktree_create.rb <name>` for real, never `--dry-run`
  (`:79-98`).
- Step 2, only after step 1 reports `ok: true`
  ([`skills/wurk:branch/SKILL.md:100-105`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:branch/SKILL.md#L100-L105)):

  ```bash
  ruby ~/.claude/skills/wurk:kit/scripts/tmux_window.rb ensure-session
  ruby ~/.claude/skills/wurk:kit/scripts/tmux_window.rb open [--no-finish] <name> <path> <id> <seed>
  ```

  `<path>` from step 1's `data.path`; `<id>` is the bead id at the front of
  the branch name; `<seed>` is passed verbatim including its leading slash;
  `<id>` stays required even with `--no-finish` (`:107-118`).
- Result reading (`:153-165`): the tmux step is "optional and never fatal" -
  `tmux_not_configured` means skip with a note; `data.skipped: true` means a
  window of that name exists, report and do not make a second;
  `window_id_empty` is the window step failing, not the workspace failing;
  `data.window_id`, `data.name`, `data.path`, `data.model` feed the report.
- The report (`:167-176`) states the tmux window name and id, or why it was
  skipped, and the model the session launched with.
- Guidelines (`:178-211`): the seed names the orchestrator; the finishing
  clause is appended by the script because "the open step is where every
  caller converges"; the session starts in auto permission mode; a seeded
  session cannot spawn a nested claude session (use a sibling workspace
  session instead); nothing is pushed.

Indirect callers: `/wurk:next` invokes `/wurk:branch <id>-<slug> -- /wurk:work
<id> --auto` once per bead ([`skills/wurk:next/SKILL.md:320`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:next/SKILL.md#L320), and it is
`/wurk:next` that computes the full name, `:261-266`), and `/wurk:work`
does the same from the main checkout then stops ([`skills/wurk:work/SKILL.md:110-113`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L110-L113)).
Neither invokes `tmux_window.rb` directly.

`worktree_create.rb` is naming-agnostic: `name = args.first`
([`skills/wurk:kit/scripts/worktree_create.rb:23`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/worktree_create.rb#L23)), `path = File.join(worktrees_root,
name)` (`:66`), `git worktree add <path> -b <name> --no-track <base_ref>`
(`:183`), and `env.data[:name]` / `env.data[:path]` (`:92-93`) are what the
skill's step 2 passes through. The `<bead-id>-<slug>` grammar lives only in
skill prose.

### skills/wurk:cleanup/SKILL.md and worktree_cleanup.rb

The cleanup skill runs four steps
([`skills/wurk:cleanup/SKILL.md:77-168`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:cleanup/SKILL.md#L77-L168)):

1. `worktree_cleanup.rb --dry-run [name]`, reading `data.results[].result`;
   only `"merged in request #<n>, would remove"` becomes a candidate
   (`:79-91`).
2. Quiesce, before touching disk (`:93-123`):
   `tmux_window.rb find <name> <path>` -> `data.found: false` means nothing to
   quiesce, go to step 3; `blocked ambiguous_window_match` means skip both
   the quiesce **and** the removal; otherwise carry `data.window_id` into
   `classify <window_id>`. `busy` -> skip the removal entirely and report
   `"session busy, skipped"`; `exited` -> carry the id straight to the close;
   `idle` -> `quiesce <window_id>`, where `quiesce_timeout` skips the removal
   and is reported, "**Never escalate past this**".
3. `worktree_cleanup.rb <name>` **by name**, so a busy-skipped candidate is
   never touched; then, only once removal succeeded,
   `tmux_window.rb close <window_id>` for candidates that carried an id.
   `closed: false` with `reason: "window kept, other panes busy"` is a normal
   outcome (`:125-145`).
4. Bead closing, from `data.beads_to_close`.

Guidelines ([`skills/wurk:cleanup/SKILL.md:225-229`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:cleanup/SKILL.md#L225-L229)) record why quiesce comes
after the dirty and SHA checks; `:241` cross-references the byte-level
classifier.

`worktree_cleanup.rb` **never touches tmux** - its own header says the tmux
quiescing stays at the skill boundary
([`skills/wurk:kit/scripts/worktree_cleanup.rb:14-24`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/worktree_cleanup.rb#L14-L24)). It has no subcommands;
it is `worktree_cleanup.rb [--dry-run] [name]` (`:36-86`). It enumerates via
`WorktreeSurvey.run` in-process through a `StringIO` (`:94-116`), blocking
`forge_unavailable` (`:105-107`), and filters an optional target by
`File.basename(w["path"]) == target || w["branch"] == target` (`:110-112`).
Per-worktree outcomes in `cleanup_one` (`:118-151`): not merged / dirty /
commits after merge / remove. Removal order is `git worktree remove`,
`git worktree prune`, `git branch -D` (`:165-181`). Data fields: `results`
(`{path, branch, result}`) and `beads_to_close` (`:73-74`); a trailing
`git fetch --prune` runs once per sweep (`:79-83`). Dry run renders those
commands without executing (`:143-148`).

`worktree_survey.rb` contains no tmux/session/window reference at all - it
parses `git worktree list --porcelain` (`:21-49`) and per-worktree request,
bead, area and dirty state (`:121-184`).

### The kit script contract and the test that enforces it

`skills/wurk:kit/REFERENCE.md`:

- Envelope (`:91-133`): exactly one JSON object on stdout with `ok`,
  `script`, `data`, `warnings`, `blocked`, `commands`; `ok` is true only when
  `blocked` is empty and no wrapped command failed (`:106`); `commands` is
  "mandatory and non-negotiable" (`:116-119`); diagnostics go to stderr
  (`:121-122`).
- Exit codes (`:135-142`): 0 ok, 1 not-ok with the envelope still printed,
  2 usage error as plain stderr text with no envelope.
- `--dry-run` (`:144-151`): every mutating script supports it, populates
  `commands`, executes nothing, reports `ok: true` absent an unrelated
  detectable block. Stated purpose includes exercising scripts "without a
  real `git`, `gh`, or `tmux`".
- Banned operations (`:153-198`): `git push`, `gh pr create` / `glab mr
  create`, `bd close`, `bd edit`, plus writes to any manifest
  `gate.moving_files` / `gate.guard_ledger` path; plus the forge-vocabulary
  rule (`:187-198`) and the single-runner rule - `system(...)`/backticks are
  banned outside `lib/sh.rb`, and `cp`/`rm`/`mv` argv must carry a
  non-interactive flag (`:200-207`).
- "Writing a new script" checklist at `:404-427`.
- tmux appears only three times in REFERENCE.md: `:21` (the session name as a
  manifest constant), `:59` ("no `tmux` section blocks `tmux_window.rb`'s
  session-addressing subcommands rather than inventing a session name"), and
  `:151`. There is **no per-subcommand tmux_window.rb section** the way
  `gate.rb` (`:283-355`) and `judge.rb` (`:356-403`) have one; the subcommand
  documentation is the script's own comments.

[`docs/architecture.md:37-57`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/architecture.md#L37-L57) restates the contract for Layer 2 (the kit):
one JSON envelope, exit codes, `--dry-run` on every mutating script, all
shell-outs through `lib/sh.rb`, the banned list, and `lib/manifest.rb` as
new in wurk. The file contains **zero** occurrences of "tmux"; worktrees
appear only conceptually (`:5`), and the parallelism enum is listed among the
explicit structural switches (`:67-68`).

`skills/wurk:kit/scripts/test/contract_test.rb` splits into `Contract` pure
rules and `ContractTest` applying them to the real tree
(`contract_test.rb:303-462`, `:467-710`). Discovery: `**/*.rb` under
`SCRIPTS_ROOT` (`:468-472`), minus `scripts/test/` (`:478-480`); markdown
scans glob `skills/wurk:*/SKILL.md` (`:548-550`) and target `REFERENCE.md`
(`:552-554`). The applied tests are `test_no_banned_calls_outside_comments`
(`:482`), `test_no_writes_to_ledger_or_gate_config` (`:492`),
`test_no_system_or_backticks_everything_goes_through_sh` (`:503`),
`test_top_level_scripts_have_shebang_and_executable_bit` (`:516`),
`test_cp_rm_mv_argv_carries_non_interactive_flag` (`:526`),
`test_no_consumer_vocabulary_in_kit_source` (`:536`),
`test_markdown_scans_cover_every_shipped_skill` (`:560`),
`test_no_consumer_vocabulary_in_skill_markdown` (`:570`),
`test_no_consumer_vocabulary_in_kit_reference_command_blocks` (`:584`),
`test_no_hardcoded_default_branch_in_kit_source` (`:593`),
`test_no_forge_vocabulary_in_kit_source` (`:605`), two meta-tests proving the
scans catch planted violations (`:622`, `:649`), and the ADR-0006 drift check
(`:691`).

Note for anything new here: the consumer-vocabulary scan
(`contract_test.rb:153-169`) bans consumer repo names and toolchain-specific
gate commands in kit source and in skill markdown - which is the rule that
makes a concrete editor command (`nvim`, `vim`, ...) manifest data rather
than something a generic skill or script may name.

### tmux_window_test.rb - how the tmux tests are built

`skills/wurk:kit/scripts/test/tmux_window_test.rb` has two classes:

- `TmuxWindowClassifyTest` (`:17-101`) exercises the pure `TmuxWindow.classify`
  against byte fixtures under `skills/wurk:kit/scripts/test/fixtures/pane/*.txt`,
  read in binary mode (`:20-22`) - verbatim `tmux capture-pane -e -p` output
  with real escape bytes. Tests include the dim placeholder, half-typed
  draft, dialog, empty box, NBSP-padded box, spinner frames (including an
  unlisted verb), last-marker-line handling, and the paste/image/@-mention
  chips.
- `TmuxWindowTest` (`:103-814`) installs `FakeSh` as `Sh.runner` and stubs
  `TmuxWindow.sleep_fn = ->(_seconds) {}` in `setup` (`:113-123`), so the
  quiesce/classify poll loops run instantly. `FakeSh`
  ([`skills/wurk:kit/scripts/test/support/fake_sh.rb:19-82`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/support/fake_sh.rb#L19-L82)) FIFO-matches an
  argv prefix per `#expect` and raises `UnexpectedCommand` on any
  unauthorized shell-out. The manifest comes from
  `ManifestHelper#with_manifest` / `manifest_with`
  ([`skills/wurk:kit/scripts/test/support/manifest_helper.rb:22-99`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/support/manifest_helper.rb#L22-L99)) with
  `FIXTURE = "tmux"`.

  Grouped by subcommand, the tests are:
  - ensure-session: no-tmux-section blocks; main checkout derived from git;
    blocks when git cannot name it; reuse; create; dry-run issues no commands.
  - open: creates and seeds; the finishing clause names the installed skill;
    the trailer key comes from the manifest; `--no-finish` suppresses it and
    the default appends it (including under dry run); skip on existing window
    name; never send-keys on an empty window id; dry run renders a pasteable
    line; plus six caffeinate-probe cases (ENOENT, AC power, absent binary,
    battery above the floor, battery at the floor, unparseable percentage).
  - find: matches on name and path together; no match is not an error; two
    matches block.
  - classify: both samples must be idle; one busy sample is enough; never
    captures with an empty id; bare shell reports `exited`; the bare-shell
    check covers every pane; falls through to the byte classifier when
    `list-panes` fails.
  - quiesce: C-u then /exit then poll; timeout blocked not escalated; never
    issues a command with an empty id; dry run issues no commands.
  - close: kills when every pane is a bare shell; keeps when a pane is busy;
    never issues a command with an empty id; kill-window only targets a
    window confirmed all bare shells.
  - source-level: `test_banned_kill_operations_appear_only_in_the_forbidding_comment`
    greps for `kill-pane`/`kill -9`/`SIGKILL` and asserts every hit is a
    comment.

  Throughout, the session target is the fixture's `=zz-session` and the model
  is `fakemodel`.

`worktree_cleanup_test.rb` has no tmux coverage at all (its tests are the
gitlab block, merged-clean removal, dirty skip, commits-after-merge skip,
forge-unavailable stop, dry run, and two source scans for `bd close` and
`--force`).

## Code References

- [`skills/wurk:kit/scripts/tmux_window.rb:76-91`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/tmux_window.rb#L76-L91) - subcommand dispatch
- [`skills/wurk:kit/scripts/tmux_window.rb:132-149`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/tmux_window.rb#L132-L149) - the session-addressing
  vs session-agnostic split, and the `tmux_not_configured` block
- [`skills/wurk:kit/scripts/tmux_window.rb:157-160`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/tmux_window.rb#L157-L160) - `claude_command`, the
  one place the launched command line is composed
- [`skills/wurk:kit/scripts/tmux_window.rb:207-246`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/tmux_window.rb#L207-L246) - the caffeinate/power probe
- [`skills/wurk:kit/scripts/tmux_window.rb:282-336`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/tmux_window.rb#L282-L336) - `ensure-session`
- [`skills/wurk:kit/scripts/tmux_window.rb:340-417`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/tmux_window.rb#L340-L417) - `open`, including the
  duplicate-name guard and the empty-window-id trap
- [`skills/wurk:kit/scripts/tmux_window.rb:421-461`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/tmux_window.rb#L421-L461) - `find` (`list-panes -a`,
  name+path match, ambiguity block)
- [`skills/wurk:kit/scripts/tmux_window.rb:465-511`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/tmux_window.rb#L465-L511) - `classify`
- [`skills/wurk:kit/scripts/tmux_window.rb:515-568`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/tmux_window.rb#L515-L568) - `quiesce`
- [`skills/wurk:kit/scripts/tmux_window.rb:572-618`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/tmux_window.rb#L572-L618) - `close`
- [`skills/wurk:kit/scripts/tmux_window.rb:634-639`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/tmux_window.rb#L634-L639) - `bare_shell_panes?`
- [`skills/wurk:kit/scripts/lib/manifest.rb:405-415`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/lib/manifest.rb#L405-L415) - tmux accessors
- [`skills/wurk:kit/scripts/lib/manifest.rb:56-62`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/lib/manifest.rb#L56-L62) - `ENUMS`
- [`skills/wurk:kit/scripts/lib/manifest.rb:77`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/lib/manifest.rb#L77) - `KNOWN["tmux"]`
- [`skills/wurk:kit/scripts/lib/manifest.rb:856-864`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/lib/manifest.rb#L856-L864) - `validate_enums`
- [`skills/wurk:kit/scripts/lib/manifest.rb:869-881`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/lib/manifest.rb#L869-L881) - unknown-key warnings
- [`skills/wurk:kit/scripts/lib/manifest.rb:129-168`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/lib/manifest.rb#L129-L168) - `require!`, `main_checkout`
- [`skills/wurk:kit/scripts/test/fixtures/manifests/tmux.json:55-58`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/fixtures/manifests/tmux.json#L55-L58) - the one
  fixture with a tmux section
- [`skills/wurk:kit/scripts/test/manifest_test.rb:673-676`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/manifest_test.rb#L673-L676) - the only tmux
  accessor test
- [`skills/wurk:kit/scripts/test/manifest_test.rb:937-950`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/manifest_test.rb#L937-L950) - every-fixture
  schema check
- [`docs/manifest.md:93-96`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/manifest.md#L93-L96) - the tmux schema block
- [`docs/manifest.md:527`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/manifest.md#L527) - the per-repo `tmux.session` row
- [`docs/manifest.md:595`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/manifest.md#L595) - "no `tmux` section means no tmux integration"
- [`skills/wurk:branch/SKILL.md:100-118`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:branch/SKILL.md#L100-L118) - the ensure-session/open call
- [`skills/wurk:branch/SKILL.md:153-165`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:branch/SKILL.md#L153-L165) - how the tmux envelope is read
- [`skills/wurk:cleanup/SKILL.md:93-145`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:cleanup/SKILL.md#L93-L145) - find / classify / quiesce / close
- [`skills/wurk:kit/scripts/worktree_cleanup.rb:14-24`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/worktree_cleanup.rb#L14-L24) - why tmux stays at the
  skill boundary
- [`skills/wurk:kit/scripts/worktree_create.rb:23-93`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/worktree_create.rb#L23-L93) - name propagation
- [`skills/wurk:kit/REFERENCE.md:91-207`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/REFERENCE.md#L91-L207) - envelope, exit codes, dry run,
  banned operations
- [`skills/wurk:kit/scripts/test/contract_test.rb:467-710`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/contract_test.rb#L467-L710) - the applied
  contract tests
- [`skills/wurk:kit/scripts/test/tmux_window_test.rb:103-123`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/tmux_window_test.rb#L103-L123) - FakeSh and the
  sleep stub

## Architecture Documentation

- **ADR-0004** (`docs/adr/0004-manifest-and-extension-seams.md`, accepted
  2026-08-08) is the governing decision for anything this bead adds. Two
  seams: `.claude/wurk.json` for machine-consumed constants, with "structural
  choices as explicit enums (parallelism model, forge kind, tracker topology,
  changelog mode)"; and `.claude/wurk/<skill>.md` extensions that add and
  never override. The ADR's own context paragraph names the tmux session as
  one of the surveyed constants. It also records that manifest schema changes
  are breaking for all consumers and are versioned via the `wurk` field.
- **ADR-0006** (`docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`)
  is the script contract: stdlib-only system Ruby, envelope, exit codes,
  banned operations - and `contract_test.rb:691-709` re-parses it on every
  run.
- **ADR-0009** (`docs/adr/0009-upstream-beads-without-a-workspace.md`,
  accepted 2026-08-10) is the one other ADR that names the tmux window: it
  fixes the case where an upstream-labeled bead got a full workspace
  (warmed worktree + branch + tmux window + seeded session) with nothing to
  size.
- **No ADR is dedicated to tmux or to worktree-per-issue.** Those decisions
  live inside ADR-0004's survey and are elaborated in `docs/plan.md` and
  `docs/manifest.md`.
- The manifest's asymmetric validation posture ([`docs/manifest.md:606-645`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/manifest.md#L606-L645)):
  unknown keys warn, missing required keys block, enum values reject outright
  rather than falling back, command fields must be argv arrays of strings -
  "a shell string is a schema error, never something to split on whitespace".
  That last rule is the shape any `tmux.editor` argv would be held to.
- Capability-absence is reported, never guessed
  ([`docs/manifest.md:594-604`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/manifest.md#L594-L604), [`skills/wurk:kit/REFERENCE.md:57-63`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/REFERENCE.md#L57-L63)): no
  `tmux` section, no `gate.report`, no `judge`, no `rebase` - each degrades
  to a stated off-state.

## Historical Context

- `docs/plan.md` is the active migration plan and the primary historical
  source here. Lines 79-95 inventory statifier's constants and contrast
  fixative's model (branch in the current checkout, "tmux window renamed, not
  created"). Lines 166-168 and 255-259 record that `tmux_window.rb` once
  hardcoded `SESSION`, `MAIN_REPO`, `MODEL`, and the seeded prompt. Line
  366-370 (item 22) is the decision that the main checkout derives from
  `git rev-parse --git-common-dir` at runtime while the session name stays
  manifest data. Line 437's coupling table maps `tmux_window.rb` to
  `tmux.session`/`tmux.model` and states "no `tmux` section blocks rather
  than inventing a session name". Lines 539-553 record the 2026-08-08 smoke
  run: `ensure-session` was exercised for real against a scratch manifest,
  `open` deliberately was not, because it launches a live claude session.
  Lines 795-798 define `/wurk:branch`'s two strategies -
  `worktree-per-issue` (create + warm + tmux window + seed) and
  `branch-in-place` (switch + rename window + `post_branch`, still
  unimplemented).
- [`docs/plans/260810-wu-2cb-default-branch-base-ref-from-manifest.md:61`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/plans/260810-wu-2cb-default-branch-base-ref-from-manifest.md#L61)
  cites `tmux_window.rb`'s `main_repo` derivation while making the base ref
  manifest-driven.
- `docs/plans/260817-wu-9fb-subdirectory-gate-cwd.md` and its research
  counterpart discuss and defer adding a cwd concept to the `parallelism.*`
  hooks - the nearest precedent for "add a field to a structural section
  rather than fork behavior".
- `docs/plans/260814-wu-821-changed-files-remote-base-and-worktree.md`
  explains why worktree-per-issue forces remote-ref reasoning kit-wide.
- No prior research document covers tmux sessions, windows, or seeding as a
  topic.

## Related Research

- `docs/research/260817-wu-9fb-subdirectory-gate-cwd.md` - the manifest-field
  vs deferred-field judgment on `parallelism.*`
- `docs/research/260810-wu-ubm-direction-model-reality-vs-doc.md` - a
  manifest model field (`models.direction`) whose doc and reality diverged
- `docs/research/260811-wu-y7d-rebase-conflict-auto-resolution.md` - this
  repo's own partially-populated `parallelism` block

## Open Questions

These were recorded rather than resolved; no human was available during this
research pass, and each is a decision for the plan, not a fact about the
code.

1. **What closes a per-issue session at cleanup time.** `close`
   (`tmux_window.rb:572-618`) does `tmux kill-window`. Under
   session-per-issue, killing the last window in a session ends the session
   as a side effect, and a two-window session (editor + claude) would leave
   the editor window alive after the claude window is killed. Today's
   `close` has no session-level concept at all, and the header rule
   (`:18-21`) only carves out `kill-window` on all-bare-shell windows - it
   says nothing about `kill-session` or about a window still running an
   editor.

   **Settled (2026-08-21):** `close` gained an optional `--session
   <name>`: after a successful `kill-window` it issues `kill-session`
   only when every pane of every remaining window is a bare shell,
   reusing `bare_shell_panes?`. A live editor keeps its session.
   Verifying this against real tmux on 2026-08-21 found the guarantee
   did not actually hold - tmux runs a one-element command through the
   shell, so `pane_current_command` reported the shell and a live editor
   read as bare; the editor argv is now wrapped in `sh -c "exec ..."` so
   the editor owns its pane. Confirmed with a human during a
   `/wurk:verify` walk of
   `docs/plans/260817-wu-aqy-tmux-session-per-issue-layout.md`.

2. **What `find` should match under session-per-issue.** `find` searches the
   whole server with `list-panes -a` and matches window name + pane path
   (`:428-443`). Under the proposed layout the claude window would be named
   `claude` (not `<bead-id>-<slug>`) in *every* per-issue session, so a
   name+path match still discriminates only because the path differs - and
   the editor window would share that same path, which is exactly the
   `ambiguous_window_match` block condition (`:453-457`).

   **Settled (2026-08-21):** `find` became layout-aware: under
   `session-per-issue` it lists `session_name` too and matches session +
   window name `claude` + pane path, so it returns the claude window and
   never the editor's. Under `window-per-issue`, and with no `tmux`
   section at all, it is unchanged and still never blocks. Confirmed
   with a human during a `/wurk:verify` walk of
   `docs/plans/260817-wu-aqy-tmux-session-per-issue-layout.md`.

3. **Whether the duplicate guard moves from window name to session name.**
   `open`'s guard lists windows in the one manifest session (`:368-376`);
   under session-per-issue the equivalent guard is "does a session of this
   name already exist", which is what `ensure-session`'s `has-session`
   already does for the shared session.

   **Settled (2026-08-21):** Yes. Under `session-per-issue` `open`'s
   guard is `tmux has-session -t =<name>`; a hit reports `skipped` and
   creates nothing, keeping the same shape as `worktree_create.rb`'s
   guards. Confirmed with a human during a `/wurk:verify` walk of
   `docs/plans/260817-wu-aqy-tmux-session-per-issue-layout.md`.

4. **Whether `tmux.session` stays meaningful under `session-per-issue`.** It
   is currently required-in-practice by `ensure-session` and `open`; under
   the new layout the per-issue session name comes from the workspace name
   instead, and the bead does not say whether `tmux.session` becomes unused,
   becomes a prefix, or stays as the home for non-issue work.

   **Settled (2026-08-21):** `tmux.session` stays the schema's home for
   the shared session and became conditionally required: required under
   `window-per-issue`, permitted to be absent under `session-per-issue`,
   where a stray value is reported as `session_name_unused` rather than
   silently ignored. No prefix scheme. Confirmed with a human during a
   `/wurk:verify` walk of
   `docs/plans/260817-wu-aqy-tmux-session-per-issue-layout.md`.

5. **Where the editor window's working directory and shell come from.** The
   bead says the editor runs "in the worktree"; `open` already passes
   `-c <path>`. Whether the editor argv is sent with `send-keys` (like the
   claude command) or passed as `new-window`'s command argument is
   undecided, and the two differ in what happens when the editor exits.

   **Settled (2026-08-21):** The editor runs as the window's own command
   with `-c <path>`, not via `send-keys`, so its window closes when it
   exits and no argv is ever joined into a shell string. The argv is
   passed as `/bin/sh -c "exec <argv>"` (added 2026-08-21, see question
   1) so tmux execs rather than shell-wrapping it. Confirmed with a
   human during a `/wurk:verify` walk of
   `docs/plans/260817-wu-aqy-tmux-session-per-issue-layout.md`.

6. **Which end of the contract owns the two-window sequence.** Today
   `/wurk:branch` issues two script calls (`ensure-session`, `open`) and the
   script owns everything below that. A session-per-issue layout could be a
   new subcommand, a flag on `open`, or two more skill-level calls; the
   contract permits all three and nothing in the codebase settles it.

   **Settled (2026-08-21):** The script owns it. `open` grows the layout
   branch internally and `ensure-session` becomes a reporting no-op, so
   `/wurk:branch`'s two-command sequence is unchanged and no skill prose
   reads `tmux.layout`. Confirmed with a human during a `/wurk:verify`
   walk of `docs/plans/260817-wu-aqy-tmux-session-per-issue-layout.md`.

7. **Whether `docs/manifest.md` gets a `## tmux` subsection.** It has none
   today (only the schema-fence lines and two cross-references), while every
   field with real prose (`gate.sabotage`, `judge`,
   `rebase.auto_resolve_paths`, `gate.cwd`) has one. A `layout` enum plus an
   `editor` argv is the first tmux material with behavior worth prose.

   **Settled (2026-08-21):** Yes - `docs/manifest.md` gained a `## tmux`
   subsection stating what each layout produces, what omitting `editor`
   does, and what `session` means under each. Confirmed with a human
   during a `/wurk:verify` walk of
   `docs/plans/260817-wu-aqy-tmux-session-per-issue-layout.md`.

8. **How a `tmux.editor` argv avoids the consumer-vocabulary scan.**
   `contract_test.rb`'s scan (`:153-169`) bans consumer-specific commands in
   kit source and skill markdown; a concrete `nvim`/`vim` can appear in a
   fixture manifest and in `docs/manifest.md`'s schema example, but the
   question of whether the doc's example counts as scanned text was not
   resolved here (the markdown scans target `SKILL.md` files and
   `REFERENCE.md` shell fences, not `docs/manifest.md`).

   **Settled (2026-08-21):** It already does; no scan change was needed.
   `docs/manifest.md` is not scanned at all. The rule adopted: a
   concrete editor argv may appear in a fixture manifest and in the
   schema example, while kit source and generic skill markdown name only
   the field `tmux.editor`. Confirmed with a human during a
   `/wurk:verify` walk of
   `docs/plans/260817-wu-aqy-tmux-session-per-issue-layout.md`.

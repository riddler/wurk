---
date: 2026-08-12T07:55:34-0600
researcher: Claude
git_commit: 2a572a6341a23c6fe1fa1f9d32c587b80b005fb2
branch: wu-4r7-narrow-sabotage-scope
repository: wurk
beads_issue: wu-4r7
topic: "How gate.sabotage can be scoped to a subset of the test tree"
tags: [research, direction, kit, gate, sabotage, manifest]
status: complete
last_updated: 2026-08-12
last_updated_by: Claude
---

# Direction: scoping gate.sabotage to enumerated binding tests

**Date**: 2026-08-12T07:55:34-0600
**Git Commit**: 2a572a6341a23c6fe1fa1f9d32c587b80b005fb2
**Branch**: wu-4r7-narrow-sabotage-scope
**Bead**: wu-4r7

## The question

wu-4r7 asks for a way to enable `gate.sabotage` against a subset of the test
tree rather than every new test declaration, so predicator-ex's narrow
discipline (sabotage notes on the binding tests that keep exported artifacts
honest, and on nothing else - see predicator-ex
`docs/research/260808-px-9ab-sabotage-notes.md`) can be enforced by the gate
without demanding a note on every ordinary test. The bead enumerates three
candidate shapes and explicitly defers the choice: a path/glob allowlist
(`gate.sabotage.paths`), a marker convention in the tests themselves, or a
named-file manifest.

## Decision

**No new schema field. The capability already exists in
`gate.sabotage.test_roots`; the gap is documentation, validation wording,
and one edge-case validation fix.** `test_roots` entries are handed verbatim
to `git diff` as a pathspec, and a git pathspec already accepts exact file
paths and bare globs, not only directory prefixes. A project scopes the scan
to its enumerated binding tests by listing those files in `test_roots`. The
all-tests behavior is simply `test_roots: ["test/"]` - a directory prefix is
one kind of pathspec - so nothing changes for statifier-ex and there is no
new default to choose.

This is not ADR-shaped: it adds no schema field, no seam, and no structural
choice - it clarifies the semantics one existing field already had. ADR-0004
(manifest and extension seams) already governs where such data lives, and the
change below stays entirely inside it. Hence this record, not a new ADR.

## Evidence

### The pathspec is the sole scoping mechanism, and it is unfiltered

`sabotage_diff_args` (`skills/wurk:kit/scripts/gate.rb:173-177`) builds:

```
["git", "diff", "<default_branch>...HEAD", "-U0", "--"] +
  manifest.sabotage_test_roots +
  manifest.sabotage_exempt_prefixes.map { |prefix| ":!#{prefix}" }
```

`test_roots` entries land after `--` exactly as written. `scan_sabotage`
(`gate.rb:118-150`) never looks at `test_roots` at all: it scans whatever
diff text it is handed, filtering only by `exempt_prefixes` (a
`start_with?` check at `gate.rb:140`, independent of how the roots were
spelled). So whatever the pathspec selects is exactly what gets scanned -
there is no second filter that assumes directory prefixes.

### Git pathspec behavior, verified empirically (git 2.54.0)

Against a fixture repo with three test files where a feature branch adds one
`test "..."` line to each:

- `git diff main...HEAD -U0 -- test/isa_sync_test.exs
  test/conformance/corpus_freshness_test.exs` - diffs exactly those two
  files. **Exact file paths work.**
- `git diff main...HEAD -U0 -- 'test/**/*freshness*'` - diffs the one
  matching file. **Bare globs work** (default pathspec matching is wildmatch;
  no `:(glob)` magic needed).
- `git diff main...HEAD -U0 -- test/isa_sync_test.exs ':!test/conformance/'`
  - file allowlist and `:!` exclusions compose. **`exempt_prefixes` keeps
  working alongside enumerated files.**
- `git diff main...HEAD -U0 -- test/does_not_exist.exs` - exit 0, empty
  output. **A listed file that does not exist (or matches nothing in the
  diff) degrades to "nothing flagged", not an error.**
- `git diff main...HEAD -U0 -- ""` - **fatal, exit 128** ("empty string is
  not a valid pathspec"). Because `sabotage_missing` (`gate.rb:182-191`)
  returns `[]` when the diff command fails, an empty-string entry today
  silently disables the whole scan. This is a real validation gap, fixed
  below.

### What the current validation and docs actually say

- `validate_sabotage` (`skills/wurk:kit/scripts/lib/manifest.rb:535-564`)
  requires `test_roots` to be a non-empty array of Strings and nothing more.
  Nothing blocks file paths or globs; only the error message's wording
  ("must be a non-empty list of path prefixes") implies directories. It also
  accepts `""`, which is the silent-disable edge above.
- `docs/manifest.md` (~line 231) documents `test_roots` as "directory
  prefixes passed to `git diff main...HEAD -U0 --` as the pathspec" - the
  wording under-sells what the field accepts.
- The per-repo table (~line 374) reads `gate.sabotage | yes | none | none`,
  and the section's closing paragraph says predicator-ex and fixative "have
  no sabotage-discipline corpus", which wu-4r7 shows is wrong for
  predicator-ex: it has the discipline, narrowly scoped.

### The other two candidate shapes, rejected

- **Marker convention** (a module attribute or tag the scan looks for):
  requires the kit to recognize consumer test-framework syntax (an ExUnit
  `@tag` is one project's grammar), which the hard rule forbids, or a second
  regex field that inverts the scan's direction. It also has the same trust
  problem as the note itself - a marker's presence is not evidence of
  anything - while adding a second comment grammar. Rejected.
- **Named-file manifest** (a file listing the binding tests, mirroring
  predicator-ex's research doc): an indirection layer whose only content is
  a path list, which is exactly what a manifest field already is.
  `.claude/wurk.json` is the named-file manifest. Rejected.

## What to implement (one wurk commit, code and doc together)

### 1. `skills/wurk:kit/scripts/lib/manifest.rb` - `validate_sabotage`

No schema change: `KNOWN`, the accessors, and `gate.rb` are untouched.
Tighten the `test_roots` entry check and reword the message:

- Each entry must be a **non-empty** String (closes the silent-disable edge:
  `""` is a fatal pathspec that `sabotage_missing` swallows into `[]`).
- Each entry must **not start with `":"`**. Pathspec magic in `test_roots`
  is disallowed because exclusions must live in `exempt_prefixes` - the one
  definition site that feeds both the `:!` pathspec arguments and the
  in-scan `start_with?` filter (`gate.rb:169-172`). A raw `:!...` in
  `test_roots` would exclude at the git level only, splitting that
  definition site. Other magic (`:(glob)`, `:(top)`) is unnecessary since
  bare globs already work, so the whole `:` prefix is rejected rather than
  enumerating magics.
- Error message: "gate.sabotage.test_roots must be a non-empty list of git
  pathspecs (directory prefixes, exact file paths, or globs; no leading
  ':')" - naming what the field actually accepts.

Update `skills/wurk:kit/scripts/test/manifest_test.rb:117-123` (the message
assertion) and add cases for the `""` and leading-`:` rejections. Run
`ruby skills/wurk:kit/scripts/test/run.rb` before committing.

### 2. `docs/manifest.md` - same commit (hard rule: doc follows code)

- **`test_roots` bullet (~line 231)**: replace "directory prefixes" with:
  entries are git pathspecs passed verbatim to
  `git diff <default_branch>...HEAD -U0 --`; a directory prefix (`"test/"`)
  scans every test under it, an exact file path or bare glob scopes the scan
  to enumerated binding tests. Entries must not start with `:` - exclusions
  belong in `exempt_prefixes`, the single definition site. State the
  scoping trap explicitly: with enumerated files, a new binding test in an
  unlisted file is invisible to the scan, so adding a binding test includes
  adding its path (or covering it with a glob) in the same change.
- **Closing paragraph of the section (~line 243)**: replace "predicator-ex
  and fixative have no sabotage-discipline corpus" with the accurate split:
  statifier-ex runs the broad form (`"test/"`); predicator-ex runs the
  narrow form over its enumerated binding tests; fixative has no
  sabotage-discipline corpus and keeps the off state.
- **Per-repo table (~line 374)**, predicator-ex row for `gate.sabotage`:
  from `none` to `yes (enumerated binding tests)`.
- The schema sketch (~line 56) keeps `"test_roots": ["test/"]` - the broad
  form remains the illustrative example; the bullet text carries the
  narrower option.

### 3. predicator-ex's own manifest - separate repo, separate bead

Not a wurk change, but the concrete configuration this direction commits
that repo's row to (file a px bead for it):

```json
"sabotage": {
  "test_roots": [
    "test/predicator/isa_sync_test.exs",
    "test/predicator/conformance/corpus_freshness_test.exs"
  ],
  "test_pattern": "\\btest\\s+\""
}
```

Paths verified against the predicator-ex checkout on 2026-08-12; the binding
tests named in px-9ab live at `test/predicator/isa_sync_test.exs` and
`test/predicator/conformance/corpus_freshness_test.exs`. No
`exempt_prefixes` needed - the allowlist already excludes everything else.

### 4. Optional, low priority: `skills/wurk:kit/REFERENCE.md`

The `data.sabotage.missing` bullet (~line 287) may gain half a sentence
noting the scan's scope is the manifest's `test_roots` pathspec, which may
enumerate individual files. Nothing there is wrong today; this is
clarification, not correction. `skills/wurk:commit/SKILL.md` needs no
change: it consumes `data.sabotage.missing` without assuming anything about
scope.

## Acceptance criteria, checked against this decision

- *"gate.sabotage can be enabled against a subset of the test tree"* - yes,
  today, via file-path/glob entries in `test_roots`; the implementation
  work makes that documented and validated rather than accidental.
- *"The chosen shape is documented in docs/manifest.md, and the per-repo
  table's predicator-ex row is revisited"* - items 2 above; the row turns
  the field on with the enumerated-files scoping.
- *"The existing all-tests behavior stays available and stays the default"*
  - `"test/"` is itself a pathspec, statifier-ex's manifest is untouched and
  stays valid, no accessor or `gate.rb` behavior changes, and no schema
  version bump: `wurk: 1` still describes every existing manifest.

## Open questions

None blocking. One judgment call deferred to the predicator-ex bead: whether
that repo prefers the two exact paths above or a naming-convention glob
(e.g. a future `*_sync_test.exs` pattern) once it has more than two binding
tests. The wurk-side change is identical either way.

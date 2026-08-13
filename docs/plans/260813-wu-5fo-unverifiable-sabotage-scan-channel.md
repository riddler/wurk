# Unverifiable sabotage scan channel Implementation Plan

## Overview

Give `gate.rb`'s sabotage scan a second reporting channel,
`data.sabotage.unverifiable`, so a run that could not check something is
distinguishable from a run that checked everything and found nothing.
`data.sabotage.missing` keeps its exact current meaning. Bead: wu-5fo

## Current State Analysis

Three code paths in `skills/wurk:kit/scripts/gate.rb` today produce an empty
`missing` for a reason that is not "every new test declaration has a note",
and none of them is visible to a consumer:

1. `sabotage_missing` (gate.rb:227-236): `return [] unless
   diff_res.success?`. A failed `git diff` yields the same `[]` as a clean
   scan, with `ok: true`, no warning, and `enabled: true`.
2. `scan_sabotage` (gate.rb:159-162): `next if file_lines.nil?` - a
   candidate declaration in a file the reader cannot open is silently
   dropped.
3. `sabotage_note_in_file?` (gate.rb:192-195): `return true if
   indices.empty?` - a declaration the scan cannot locate in the working-tree
   file counts as noted.

Paths 2 and 3 are wu-lac's deliberate design and the reasoning stands: a
report-only scan must not manufacture a note-missing warning out of its own
blind spot. This plan does not change that judgment. It only stops the blind
spot from being silent.

The envelope shape today (gate.rb:359-370) is:

```ruby
env.data[:sabotage] = { enabled:, reason:, missing: }
```

with one `sabotage_note_missing` warning per `missing` entry. Consumers of
this payload are `skills/wurk:commit/SKILL.md:129-137` and
`skills/wurk:kit/REFERENCE.md:287-299`; `docs/manifest.md:213-247` documents
`gate.sabotage` and states the enabled/disabled distinction. No consumer
reads `missing` positionally or by index, so adding a sibling key is
additive.

`scan_sabotage` returns a bare array today and is called from
`sabotage_missing` (the only production caller) plus roughly fifteen unit
tests in `skills/wurk:kit/scripts/test/gate_test.rb:810-1186`.

`FakeSh#expect` already accepts `exitstatus:`
(`skills/wurk:kit/scripts/test/support/fake_sh.rb:44`), so a failing
`git diff` is stubbable with no new test infrastructure.

## Desired End State

`gate.rb` reports, for every enabled scan, both what it found missing and
what it could not check:

```jsonc
"sabotage": {
  "enabled": true,
  "reason": null,
  "scanned": true,           // false when the diff itself failed
  "missing": [ {"file": "...", "text": "..."} ],
  "unverifiable": [
    {"reason": "diff_failed",           "file": null, "text": null, "detail": "..."},
    {"reason": "file_unreadable",       "file": "test/a_test.exs", "text": "test \"x\" do", "detail": null},
    {"reason": "declaration_not_found", "file": "test/a_test.exs", "text": "test \"y\" do", "detail": null}
  ]
}
```

plus warnings: `sabotage_scan_failed` (once, for the diff case) and
`sabotage_unverifiable` (one per per-declaration entry). Neither ever flips
`ok` - the scan stays report-only, exactly as the module doc's rule 3 and
`test/contract_test.rb` require.

Verification: `ruby skills/wurk:kit/scripts/test/run.rb` is green, and
`gate_test.rb` contains one test per case asserting the distinct `reason`
value and warning code, plus an assertion that `missing` stays `[]` in each.

### Key Discoveries:
- `scan_sabotage`'s nil-file skip and `sabotage_note_in_file?`'s
  empty-indices `true` are the two per-declaration blind spots
  (gate.rb:162, gate.rb:194); the diff-failure blind spot is at gate.rb:231.
- `Envelope#warn` never affects `ok` (`lib/envelope.rb:33-36`), so every new
  signal here can be a warning without touching the report-only rule.
- `Sh::Result#success?` is false for both a nonzero exit and a timeout
  (`lib/sh.rb:31-33`), so one `success?` check covers both diff failure
  modes; `res.err` carries the detail.
- The gate module doc rule 3 (gate.rb:59-64) states "sabotage is a report":
  the new channel must not call `env.fail!` or `env.block!`. What pins it
  mechanically is `gate_test.rb`'s `assert_equal true, env["ok"]` alongside
  sabotage findings (gate_test.rb:1212, :1229), not `contract_test.rb` -
  that file enforces banned shell-outs, guarded-file writes, and the
  consumer-vocabulary rule, and says nothing about sabotage. Every new test
  here therefore asserts `ok` explicitly.
- No manifest schema field is added or changed, so the
  `docs/manifest.md` / `lib/manifest.rb` sync rule has nothing to enforce
  here beyond keeping the prose describing the envelope accurate.
- ADR-0005 (gate contract tiers) and ADR-0006 (stdlib Ruby envelope
  contract) both hold unchanged: this is a payload addition inside the
  existing envelope, at no tier boundary.

## What We're NOT Doing

- **Not making the scan block.** `unverifiable` never flips `ok`, never
  calls `env.fail!`, never `env.block!`. Whether "could not verify" is a
  refusal is the consumer's policy call, made in its own
  `.claude/wurk/commit.md`, and the kit only hands it the fact.
- **Not changing what `missing` means.** No entry ever moves from
  `unverifiable` into `missing`; a report-only consumer that reads only
  `missing` sees byte-identical behavior on every input it sees today.
- **Not reversing wu-lac.** An unlocatable declaration and an unreadable
  file still do not count as note-missing. They just stop being invisible.
- **Not adding a manifest field** to configure the new channel. It is always
  on when the scan is enabled; a knob for "report blind spots or not" would
  only ever be set to "not" by the project that most needs it.
- **Not deduplicating or capping the `unverifiable` list.** One entry per
  candidate declaration, same cardinality rule `missing` follows.
- **Not touching `data.gate_guard`, the skip taxonomy, or the tier logic.**

## Implementation Approach

Three phases, each independently committable and each leaving
`ruby skills/wurk:kit/scripts/test/run.rb` green on its own.

Phase 1 changes `scan_sabotage`'s return type from an array to a
`{missing:, unverifiable:}` hash and covers the two per-declaration blind
spots (unreadable file, unlocatable declaration), wiring the new key and its
warning into the envelope. Phase 2 covers the diff-failure blind spot in
`sabotage_missing`, which is the only path that can leave the scan having
checked nothing at all, and adds the `scanned` flag. Phase 3 states the
consumer contract in the three places that document this payload.

Phases 1 and 2 are separable because they touch different methods and each
ends with a green suite: after phase 1 the envelope carries `unverifiable`
for the two per-declaration cases and `scanned` does not yet exist; after
phase 2 it also carries the diff case and `scanned`. Phase 3 is doc-only.

The return-type change in phase 1 is deliberate over an out-parameter or a
parallel `scan_sabotage_unverifiable` method: one scan pass produces both
lists, and a second entry point would let them drift. The cost is mechanical
churn in the `gate_test.rb` unit tests, which change from
`missing = Gate.scan_sabotage(...)` to
`result = Gate.scan_sabotage(...)` plus `result[:missing]`.

## Phase 1: Per-declaration unverifiable entries

### Overview

`scan_sabotage` returns both lists; an unreadable file and an unlocatable
declaration each produce an `unverifiable` entry with a distinct `reason`
instead of being dropped. `gate.rb` puts the list in the envelope and warns
once per entry.

### Changes Required:

#### 1. The scan itself

**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**: `scan_sabotage` returns `{missing: [...], unverifiable: [...]}`.
The nil-file branch records `file_unreadable`. `sabotage_note_in_file?` is
replaced at its call site by a three-way answer so the scan can tell
"located and noted" from "located and unnoted" from "not located".

```ruby
# Answers the note question three ways so the caller can tell a real
# missing note from a declaration this scan could not locate at all.
# :noted / :unnoted / :not_found. wu-lac's call stands - :not_found is
# not a missing note - but it is no longer silent.
def sabotage_note_status(file_lines, content)
  indices = file_lines.each_index.select { |i| file_lines[i] == content }
  return :not_found if indices.empty?

  indices.any? { |i| sabotage_comment_block_above?(file_lines, i) } ? :noted : :unnoted
end

# inside scan_sabotage's candidate loop:
if file_lines.nil?
  unverifiable << { reason: "file_unreadable", file: current_file,
                    text: content.strip, detail: nil }
  next
end

case sabotage_note_status(file_lines, content)
when :unnoted then missing << { file: current_file, text: content.strip }
when :not_found
  unverifiable << { reason: "declaration_not_found", file: current_file,
                    text: content.strip, detail: nil }
end
```

`sabotage_note_in_file?` is removed rather than kept as a wrapper: it has no
other caller, and leaving a predicate that collapses `:not_found` into "has
a note" is the exact shape this bead exists to delete. Its comment block
moves onto `sabotage_note_status`, preserving the wu-lac reasoning verbatim
for the `:not_found` case.

`sabotage_missing` is renamed `sabotage_scan` and returns the hash
unchanged from `scan_sabotage`. Both of its early returns - the disabled
case and the failed-diff case - return `{missing: [], unverifiable: []}` in
this phase; the failed-diff branch is left otherwise untouched here, and
phase 2 is what gives it `scanned: false` and its `diff_failed` entry.

#### 2. Envelope wiring

**File**: `skills/wurk:kit/scripts/gate.rb` (in `run`)
**Changes**:

```ruby
scan = sabotage_scan(env, manifest)
env.data[:sabotage] = {
  enabled: manifest.sabotage?,
  reason: manifest.sabotage? ? nil : "no gate.sabotage section in the manifest; the scan is off",
  missing: scan[:missing],
  unverifiable: scan[:unverifiable]
}
# existing sabotage_note_missing warnings, unchanged, then:
scan[:unverifiable].each do |u|
  env.warn(
    code: "sabotage_unverifiable",
    message: "#{u[:file]}: #{u[:text]} could not be checked for a `# sabotage:` note " \
             "(#{u[:reason]}) - this is not a clean result for that declaration"
  )
end
```

The module doc's rule 3 gains a sentence stating that `unverifiable` is a
report on the same terms as `missing`.

#### 3. Tests

**File**: `skills/wurk:kit/scripts/test/gate_test.rb`
**Changes**: every existing `Gate.scan_sabotage` call site reads
`[:missing]`; `test_sabotage_scan_skips_a_file_missing_from_the_working_tree`
additionally asserts one `file_unreadable` entry; a new
`test_sabotage_scan_reports_an_unlocatable_declaration` feeds a diff whose
candidate line is absent from the file body and asserts `missing` is empty
and `unverifiable` holds one `declaration_not_found` entry; a new
end-to-end test through `run_gate` asserts the envelope key and the
`sabotage_unverifiable` warning code with `ok` still true. Each new test
carries a `# sabotage:` note, per this repo's own discipline.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] `gate_test.rb` has a test asserting a `file_unreadable` entry with
      `missing` empty
- [x] `gate_test.rb` has a test asserting a `declaration_not_found` entry
      with `missing` empty
- [x] An end-to-end `run_gate` test asserts
      `data.sabotage.unverifiable` is present, the warning code is
      `sabotage_unverifiable`, and `env["ok"]` is `true`
- [x] `grep -n "sabotage_note_in_file?" skills/wurk:kit/scripts` returns
      nothing

#### Manual Verification:
- [ ] Reading the diff, no `unverifiable` case can reach `missing` and no
      previously-missing case can reach `unverifiable`
- [ ] The wu-lac reasoning for treating `:not_found` as not-missing survives
      in the moved comment, not just in git history
- [ ] No regression in the other sabotage tests' intent (they assert on
      `[:missing]` and still mean what their names say)

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: The failed-diff case and `scanned`

### Overview

A `git diff` that fails no longer looks like a clean scan: the scan reports
`scanned: false`, one `diff_failed` unverifiable entry, and a distinct
warning code.

### Changes Required:

#### 1. `sabotage_scan`

**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**:

```ruby
# A failed diff means this scan checked nothing at all - a different claim
# from "checked everything and found nothing", and the one case where the
# blind spot covers the whole run rather than one declaration.
def sabotage_scan(env, manifest)
  return { scanned: false, missing: [], unverifiable: [] } unless manifest.sabotage?

  diff_res = Sh.run(sabotage_diff_args(manifest), envelope: env)
  unless diff_res.success?
    return { scanned: false, missing: [],
             unverifiable: [{ reason: "diff_failed", file: nil, text: nil,
                              detail: diff_res.err.to_s.strip }] }
  end

  scan_sabotage(...).merge(scanned: true)
end
```

`env.data[:sabotage]` gains `scanned: scan[:scanned]`, placed before
`missing`. The `diff_failed` entry warns under its own code rather than
`sabotage_unverifiable`, because it is a statement about the whole run:

```ruby
env.warn(
  code: "sabotage_scan_failed",
  message: "the sabotage scan's `git diff` failed, so nothing was checked - " \
           "an empty `missing` here is not a clean result"
)
```

The per-entry `sabotage_unverifiable` warning loop skips `diff_failed`
entries so one failure does not produce two warnings.

#### 2. Tests

**File**: `skills/wurk:kit/scripts/test/gate_test.rb`
**Changes**: a new test stubs the sabotage `git diff` with
`exitstatus: 1` and a stderr detail, then asserts through `run_gate` that
`data.sabotage.enabled` is `true`, `scanned` is `false`, `missing` is `[]`,
`unverifiable` holds one `diff_failed` entry carrying the stderr detail, the
warning code is `sabotage_scan_failed`, and `ok` is still `true`. The
existing enabled-and-clean tests assert `scanned: true`, and the
scan-is-off test asserts `scanned: false` with `enabled: false`.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [ ] A `gate_test.rb` test drives a nonzero-exit sabotage `git diff` and
      asserts `scanned: false`, a `diff_failed` entry, `missing == []`, the
      `sabotage_scan_failed` warning code, and `ok == true`
- [ ] A `gate_test.rb` test asserts exactly one warning is emitted for the
      failed-diff case
- [ ] The scan-disabled test asserts `enabled: false` with `scanned: false`
      and no warning

#### Manual Verification:
- [ ] The three `reason` values (`diff_failed`, `file_unreadable`,
      `declaration_not_found`) are each reachable and each distinguishable
      by a consumer reading only the envelope
- [ ] A timed-out diff takes the same path as a nonzero-exit diff
      (`Sh::Result#success?` covers both) and reads sensibly in the message
- [ ] No path added in this phase can flip `ok` or block

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: State the consumer contract

### Overview

Document what the new channel means and what a consumer that gates on the
scan should do with it, in the three places that already describe this
payload.

### Changes Required:

#### 1. The manifest doc

**File**: `docs/manifest.md` (the `gate.sabotage` section, around line 213)
**Changes**: extend the paragraph that already separates "empty `missing` on
an enabled scan" from "empty `missing` with `enabled: false`" to a three-way
distinction, naming `scanned`, `unverifiable`, and the three `reason`
values, and stating the consumer rule:

> A consumer that only reports the scan names the `unverifiable` entries
> alongside the `missing` ones and moves on. A consumer that promotes the
> scan to a refusal condition in its own `.claude/wurk/commit.md` must decide
> what a non-empty `unverifiable` means for it: the honest reading is that
> those declarations were not checked, so a refusal keyed on "every new test
> has a note" has not been satisfied for them. The kit reports; it does not
> make that call, and `unverifiable` never flips `ok`.

#### 2. The kit reference

**File**: `skills/wurk:kit/REFERENCE.md` (the `gate.rb` bullet at 287-299)
**Changes**: add `data.sabotage.unverifiable` and `scanned` to the same
bullet that carries "a report, not a gate", with the three reasons and the
one-line consumer rule.

#### 3. The commit skill

**File**: `skills/wurk:commit/SKILL.md` (the `data.sabotage.missing` bullet
at 129-137)
**Changes**: add a sentence that an `unverifiable` entry (or `scanned:
false` on an enabled scan) is not a clean result for what it names, that
what to do about it is the project's policy in `.claude/wurk/commit.md`
exactly as for `missing`, and that where the project states none, the
entries are named in the Step 4 report. The prose keeps the policy call with
the project, so ADR-0008's judge focus (a policy call handed to a script)
does not apply.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
      (this includes the consumer-vocabulary guard over skill markdown)
- [ ] `grep -rn "unverifiable" docs/manifest.md skills/wurk:kit/REFERENCE.md
      skills/wurk:commit/SKILL.md` returns a hit in each of the three files
- [ ] Each of `diff_failed`, `file_unreadable`, and
      `declaration_not_found` appears in `skills/wurk:kit/scripts/gate.rb`
      and in at least one of the three doc files:
      `grep -c '<value>' skills/wurk:kit/scripts/gate.rb docs/manifest.md
      skills/wurk:kit/REFERENCE.md skills/wurk:commit/SKILL.md` is nonzero
      for `gate.rb` and for one doc file, per value

#### Manual Verification:
- [ ] The docs describe the envelope `gate.rb` actually emits after phases
      1 and 2, field for field
- [ ] The consumer guidance states the choice without making it for the
      consumer
- [ ] No consumer-project constant (bead prefix, repo path, gate command,
      label) entered the generic prose

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Testing Strategy

### Unit Tests:
- `skills/wurk:kit/scripts/test/gate_test.rb`, alongside the existing
  `scan_sabotage` unit tests, using the `sabotage_files` `file_reader` seam
  (gate_test.rb:806) for the per-declaration cases and `FakeSh#expect(...,
  exitstatus: 1)` for the diff case.
- Key edge cases: an unreadable file whose diff carries several candidates
  (one entry per candidate); a declaration renamed in the working tree after
  the diff was taken; a diff that fails while the manifest has the scan
  enabled; the scan disabled entirely (no entries, no warnings, no shell-out).
- Every new test carries its own `# sabotage:` note, and the note must
  describe a mutation that actually turns the test red.

### Manual Testing Steps:
1. In a consumer checkout with `gate.sabotage` configured, run
   `ruby ~/.claude/skills/wurk:kit/scripts/gate.rb --profile loop` and
   confirm `data.sabotage` carries `scanned: true` and an empty
   `unverifiable` on a normal branch.
2. Temporarily point `gate.sabotage.test_roots` at a pathspec `git diff`
   rejects, re-run, and confirm `scanned: false`, one `diff_failed` entry,
   the `sabotage_scan_failed` warning, and exit code 0.
3. Add a new test declaration, commit it, then rename it in the working tree
   without committing; re-run and confirm one `declaration_not_found` entry
   and an empty `missing`.
4. Confirm in all three runs that the envelope is a single JSON object on
   stdout and the exit code is 0.

## References

- Bead: `wu-5fo`
- Source: `skills/wurk:kit/scripts/gate.rb:119-236`, `:344-370`
- Tests: `skills/wurk:kit/scripts/test/gate_test.rb:803-1234`
- Consumer docs: `docs/manifest.md:213-247`,
  `skills/wurk:kit/REFERENCE.md:287-299`,
  `skills/wurk:commit/SKILL.md:129-137`
- Related ADRs: `docs/adr/0005-gate-contract-tiers.md`,
  `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`,
  `docs/adr/0008-merge-time-judge-over-generic-skill-prose.md`
- Prior work: `docs/research/260812-wu-4r7-sabotage-scope-pathspec.md`,
  commit `a12aa0b` (wu-lac's correction note)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Reading the diff, no `unverifiable` case can reach `missing` and no
      previously-missing case can reach `unverifiable`
- [ ] The wu-lac reasoning for treating `:not_found` as not-missing survives
      in the moved comment, not just in git history
- [ ] No regression in the other sabotage tests' intent (they assert on
      `[:missing]` and still mean what their names say)

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

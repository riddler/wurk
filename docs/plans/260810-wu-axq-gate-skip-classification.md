# Gate skip classification: not-applicable vs standing gap Implementation Plan

## Overview

`gate.rb` classifies every skipped stage two ways today - blocking (the gate
could not measure it on this run) or project-level (a standing gap the project
should close, reported with a nag). This plan adds a third classification,
`not_applicable`, declared per project through a new manifest field
`gate.not_applicable_skips`, for stages a human has judged permanently
inapplicable. Those stages are reported in `data.skipped_stages`, never block,
and are explicitly not required in commit reports or request bodies. Bead:
wu-axq.

## Current State Analysis

The classification is a boolean computed in one place and consumed in four:

- `skills/wurk:kit/scripts/gate.rb:185-193` - `skipped_from(stages,
  project_level_re)` maps each skipped stage to `{ name:, summary:,
  project_level: <bool> }`.
- `skills/wurk:kit/scripts/gate.rb:200-204` - `project_level_skip?(summary,
  project_level_re)` is the matcher; `nil` regex means "no match", which is
  the strict default (everything blocks).
- `skills/wurk:kit/scripts/gate.rb:372-390` - the two-branch loop: `true`
  emits the `stage_skipped_project_level` warning whose text ends "still not a
  passing stage, so say so when reporting"; `false` emits `block!` with code
  `stage_skipped`.
- `skills/wurk:kit/scripts/gate.rb:18-44` - the module doc's rule 1 states the
  two-way distinction in prose and is as load-bearing as the code.
- `skills/wurk:kit/scripts/lib/manifest.rb:71-72` - `KNOWN["gate"]` lists
  `project_level_skips`; `:283-292` compiles it via `Regexp.union` into
  `project_level_skip_re`, `nil` when the list is empty or absent; `:476`
  `REGEX_LIST_FIELDS` drives `validate_regex_lists` (`:588-603`), which checks
  "array of strings" and "each entry compiles".
- `docs/manifest.md:48-51` (jsonc sample), `:164-177` (field section),
  `:359-360` (the absent-means-off defaults list).
- `skills/wurk:kit/REFERENCE.md:257-273` - the envelope-level description,
  including "both kinds must appear in what you report".
- `skills/wurk:commit/SKILL.md:114-124` - Step 0's reading rule: an entry with
  `project_level: true` "still gets named in the Step 4 report".
- `skills/wurk:mr/SKILL.md:138-141` - step 4: "Still name them in the request
  body and the final report".
- Tests: `skills/wurk:kit/scripts/test/gate_test.rb:199-370` (five tests over
  the boolean, several with `# sabotage:` notes) and
  `test/manifest_test.rb:88-100, 319-321`.
- Fixture: `test/fixtures/manifests/gate_tier1.json:48-51` declares
  `["not installed", "disabled in \\.quality\\.exs"]`.

What is missing is any way to say "this stage will never apply here". The
consumer strain the bead describes is visible in statifier-ex's manifest,
which carries `^no \.po files found$` alongside the not-installed patterns -
a permanently-inapplicable stage smuggled into the standing-gap list because
there is nowhere else to put it.

`data.skipped_stages[].project_level` is produced only by `gate.rb` and read
only by wurk's own skill prose and the `wurk-gate-reader` agent (which names
`data.skipped_stages` but not the boolean,
`agents/wurk-gate-reader.md:47`). No consumer repo parses it, so the key can
change shape as long as every reader in this repo changes with it.

## Desired End State

`data.skipped_stages[]` carries `classification` instead of `project_level`,
with exactly three values:

| value | meaning | envelope effect |
|---|---|---|
| `"run_level"` | the gate could not measure the stage on this run | `block!`, code `stage_skipped` |
| `"project_level"` | a standing gap in what the project checks at all | `warn`, code `stage_skipped_project_level`, must be named in reports |
| `"not_applicable"` | the project has declared this stage permanently inapplicable | `warn`, code `stage_skipped_not_applicable`, not required in reports |

`gate.not_applicable_skips` is a new optional manifest field, validated
exactly like `gate.project_level_skips` (list of regex source strings, each
compilable, absent means empty). A project declaring neither list still blocks
on every skipped stage.

Verification: `ruby skills/wurk:kit/scripts/test/run.rb` is green, and the
suite contains tests that assert each of the three values, the precedence rule
below, and the unchanged strict default.

### Key Discoveries:

- `Manifest#project_level_skip_re` (`lib/manifest.rb:287-292`) is a
  three-line `Regexp.union` over `fetch(...)`; the sibling field is the same
  shape, so both should read from one private helper rather than being
  copy-pasted.
- `REGEX_LIST_FIELDS` (`lib/manifest.rb:476`) already generalizes the
  validation - adding the field name to that array is the whole of the
  validation work (`:588-603`).
- The strict default is encoded as `re.nil? -> no match`
  (`gate.rb:201`), not as a separate branch, so adding a second nil-able regex
  needs no new default logic.
- CLAUDE.md hard rule: `docs/manifest.md` and `lib/manifest.rb` must move in
  the same commit. That fixes the phase boundary (see Implementation
  Approach).
- ADR-0005 (gate contract tiers) and ADR-0004 (manifest and extension seams)
  both hold here: the classification stays manifest data, the kit ships no
  default patterns, and no consumer vocabulary enters kit source
  (`test/contract_test.rb` guards that).
- `gate_tier1.json`'s existing `"not installed"` pattern is unanchored, so a
  fixture entry of `^:gettext not installed$` in the new list overlaps it -
  which makes the fixture itself the precedence test.

**Precedence, decided:** when a summary matches both lists, it classifies as
`not_applicable`. The narrower, explicitly-enumerated declaration wins over
the broader standing-gap pattern. The alternative (project_level wins) would
force every consumer with a broad pattern to rewrite it with negative
lookahead before the new field could do anything, which is exactly the
workaround this bead exists to remove. This is documented in
`docs/manifest.md` and asserted by a test.

**Warning, not silence:** `not_applicable` still emits a warning
(`stage_skipped_not_applicable`) rather than nothing at all. `gate.rb`'s rule
1 - every skip stays visible in the envelope - is preserved; what changes is
that the message says the stage is declared permanently inapplicable and is
not required in reports. The noise the bead objects to is in commit reports
and PR bodies, and that is where it is removed.

## What We're NOT Doing

- **Not keeping a `project_level` boolean alongside `classification`.** A
  `not_applicable` entry would have to carry `project_level: false`, which is
  the exact value that means "this blocks" today - a reader following stale
  instructions would draw the opposite conclusion. One key, three values.
- **Not adding a compatibility shim or deprecation window** for the removed
  key. Every reader lives in this repo and moves in the same phase.
- **Not editing statifier-ex.** Its manifest edit (moving gettext and the
  `.po` patterns into the new list) is that repo's work, tracked as st-wz4;
  this plan only makes it possible and documents it as the worked example.
- **Not detecting list overlap at manifest-validation time.** Regex overlap is
  not decidable by inspection of two source strings; the precedence rule plus
  its test is the answer.
- **Not making `not_applicable` entries suppress the stage from
  `data.skipped_stages` or `data.stages`.** Dropping a skip from the payload
  is the laundering `gate.rb`'s rule 1 exists to prevent.
- **Not restructuring `agents/wurk-gate-reader.md`.** It never reads the
  boolean, so its input contract is unaffected; it gets one clause added to
  its two-way skip guidance in phase 2 and nothing more.

## Implementation Approach

Two phases, split at the manifest/kit-behavior seam, in this order:

1. **Phase 1 - the schema.** `lib/manifest.rb` accepts, validates, and
   compiles `gate.not_applicable_skips`, with `docs/manifest.md` updated in
   the same commit (CLAUDE.md hard rule) and manifest tests covering it. After
   this commit the field is accepted and validated but not yet consumed by
   `gate.rb`.
2. **Phase 2 - the behavior and every reader of it.** `gate.rb` switches to
   `classification`, and `REFERENCE.md`, `wurk:commit/SKILL.md` and
   `wurk:mr/SKILL.md` change with it in the same commit.

The ordering is deliberate. The alternative (behavior first, prose second)
would leave one commit in which `wurk:commit/SKILL.md` instructs an agent to
read a `project_level` key the envelope no longer emits - prose that is
actively wrong, which is worse than phase 1's field that is merely not yet
wired. Both commits leave `ruby skills/wurk:kit/scripts/test/run.rb` green.

---

## Phase 1: The manifest learns `gate.not_applicable_skips`

### Overview

Add the sibling regex-list field to the schema: known-key surface, validation,
compiled accessor, and documentation. No `gate.rb` behavior change.

### Changes Required:

#### 1. Manifest schema and accessor
**File**: `skills/wurk:kit/scripts/lib/manifest.rb`
**Changes**: add the key to `KNOWN["gate"]` (:71-72) and to
`REGEX_LIST_FIELDS` (:476); add `not_applicable_skip_re`, factored with
`project_level_skip_re` through one private helper so the two cannot drift.

```ruby
# KNOWN["gate"] gains: not_applicable_skips
"gate" => %w[full loop report report_loop attest guard_ledger build_paths also_gated_paths moving_files
             project_level_skips not_applicable_skips sabotage],

REGEX_LIST_FIELDS = %w[gate.project_level_skips gate.not_applicable_skips].freeze

# Compiles gate.project_level_skips into one Regexp, or nil when the
# project declares none. nil is the strict direction: every skipped stage
# blocks. Widening this list is a review decision made in the consumer's
# own manifest, not a default this kit guesses at.
def project_level_skip_re
  skip_re("gate.project_level_skips")
end

# The sibling list, for stages the project has declared permanently
# inapplicable rather than a gap it means to close. Same shape, same
# nil-means-strict default; gate.rb checks this one first (see
# docs/manifest.md).
def not_applicable_skip_re
  skip_re("gate.not_applicable_skips")
end

private

def skip_re(dotted)
  sources = Array(fetch(dotted))
  return nil if sources.empty?

  Regexp.union(sources.map { |s| Regexp.new(s) })
end
```

Check where the existing `private` boundary sits in this file before adding
one; if the accessors are already followed by a private section, put `skip_re`
there rather than introducing a second `private` keyword.

#### 2. Manifest documentation
**File**: `docs/manifest.md`
**Changes**: add `not_applicable_skips` to the jsonc gate sample (:48-51);
rename the `## gate.project_level_skips` section (:164-177) to cover both
fields, stating the choosing test and the precedence rule; add the field to
the absent-means-off list at :359-360.

The choosing test, stated plainly: *is this a stage the project would run if
someone did the work?* Yes - `project_level_skips`, and the nag is doing its
job. No, and it never will be - `not_applicable_skips`. The worked example is
statifier-ex: `:doctor not installed` is a genuine documentation-coverage gap
for a library with an `@spec`/`@doc` discipline, so it stays project-level;
`:gettext not installed` and the `no .po files` summaries are translation
tooling for a library with no user-facing strings, so they are
not-applicable. Include the note that `gate.rb` checks `not_applicable_skips`
first, so a summary matching both lists is not-applicable.

#### 3. Manifest tests
**File**: `skills/wurk:kit/scripts/test/manifest_test.rb`
**Changes**: mirror the four existing `project_level_skips` cases (:88-100,
:319-321) for the new field: non-array blocks naming the field, uncompilable
entry blocks naming the entry, `not_applicable_skip_re` is `nil` when absent,
and is a compiled `Regexp` matching a declared source when present. Carry
`# sabotage:` notes in the same style as the neighbours (e.g. "drop
gate.not_applicable_skips from REGEX_LIST_FIELDS -> red").

### Success Criteria:

#### Automated Verification:
- [ ] `ruby skills/wurk:kit/scripts/test/run.rb` is green
- [ ] the suite contains a test asserting `not_applicable_skip_re` is `nil`
      when the field is absent, and a compiled `Regexp` when it is declared
- [ ] a manifest carrying `"not_applicable_skips": "a string"` fails
      validation with an error naming `gate.not_applicable_skips`
- [ ] a manifest carrying `"not_applicable_skips": ["["]` fails validation
      with an error naming the offending entry
- [ ] `ruby skills/wurk:kit/scripts/lib/manifest.rb check` (the standalone
      lint, `lib/manifest.rb:673-696`) still reports this repo's own
      `.claude/wurk.json` valid - the field is optional

#### Manual Verification:
- [ ] `docs/manifest.md` states the choosing test in a form a human can apply
      to a stage they have never seen, not just a restatement of the field
      names
- [ ] the precedence rule reads as a deliberate decision in the doc, not an
      implementation accident
- [ ] no consumer-project vocabulary entered kit source - the statifier
      examples live in `docs/manifest.md` only

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: `gate.rb` classifies three ways, and every reader follows

### Overview

Replace the `project_level` boolean in `data.skipped_stages[]` with
`classification`, add the third branch to the warn/block loop, and update the
module doc, `REFERENCE.md`, and the two skills that instruct an agent on what
to do with each kind.

### Changes Required:

#### 1. Classification in `gate.rb`
**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**: `skipped_from` takes both regexes and emits `classification`;
`project_level_skip?` is replaced by a `classify_skip` that encodes the
precedence; the call site at :334 passes both; the loop at :372-390 gains a
third branch.

```ruby
def skipped_from(stages, project_level_re, not_applicable_re)
  Array(stages)
    .select { |s| s["status"] == "skipped" }
    .map do |s|
      summary = s["summary"]
      { name: s["name"], summary: summary,
        classification: classify_skip(summary, project_level_re, not_applicable_re) }
    end
end

# Three-way, in precedence order. "not_applicable" is checked first: it is
# the narrower, explicitly enumerated declaration, and a project whose
# project-level pattern is broad ("not installed") must be able to carve one
# stage out of it without rewriting the broad pattern. Both regexes are
# manifest data (gate.not_applicable_skips, gate.project_level_skips), and a
# nil regex never matches - which is what makes "declare neither list and
# every skipped stage blocks" the default rather than a special case.
def classify_skip(summary, project_level_re, not_applicable_re)
  return "not_applicable" if matches?(summary, not_applicable_re)
  return "project_level" if matches?(summary, project_level_re)

  "run_level"
end

def matches?(summary, re)
  return false if re.nil?

  !(summary.to_s =~ re).nil?
end
```

Call site:

```ruby
skipped = skipped_from(stages, manifest.project_level_skip_re, manifest.not_applicable_skip_re)
```

The reporting loop:

```ruby
skipped.each do |s|
  case s[:classification]
  when "not_applicable"
    # Declared permanently inapplicable in the consumer's own manifest.
    # Still in data.skipped_stages - rule 1 does not bend - but naming it
    # in every report forever is noise that trains readers to skim the
    # skip lines, so this warning says so instead of asking for it.
    env.warn(
      code: "stage_skipped_not_applicable",
      message: "#{s[:name]} was skipped (#{s[:summary]}) - declared permanently inapplicable to this " \
               "project (gate.not_applicable_skips); not a passing stage, and not required in reports"
    )
  when "project_level"
    env.warn(
      code: "stage_skipped_project_level",
      message: "#{s[:name]} was skipped (#{s[:summary]}) - a standing project gap, not a failure " \
               "of this run; still not a passing stage, so say so when reporting"
    )
  else
    env.block!(
      code: "stage_skipped",
      message: "#{s[:name]} was skipped (#{s[:summary]}) - the gate could not measure it on this " \
               "run, and a skipped stage is not a passing one"
    )
  end
end
```

Rewrite rule 1 of the module doc (:18-44) as a three-way statement: a gap in
this run blocks; a gap in what the project checks at all is reported with a
nag; a stage the project has declared permanently inapplicable is reported
without one. Keep the existing paragraph on why the second never blocks, and
add one sentence on why the third is still in the payload.

#### 2. Fixture
**File**: `skills/wurk:kit/scripts/test/fixtures/manifests/gate_tier1.json`
**Changes**: add `"not_applicable_skips": ["^:gettext not installed$"]`
alongside the existing `project_level_skips`. The existing `"not installed"`
entry is unanchored, so this fixture deliberately overlaps and is the
precedence case.

#### 3. Gate tests
**File**: `skills/wurk:kit/scripts/test/gate_test.rb`
**Changes**: update the five existing assertions on `project_level`
(:224, :265, :302-306, :338, :368) to the new key and string values.

Note one of them is not a mechanical rename:
`test_project_level_skips_are_reported_but_never_block` (:239-269) runs
against the default `gate_tier1` fixture and includes a stage whose summary is
exactly `":gettext not installed"` (:246), then asserts that all three skips
are project-level and that there are three
`stage_skipped_project_level` warnings (:265, :267). Once the fixture gains
`not_applicable_skips`, that stage reclassifies. Move the Gettext stage out of
this test and into the new precedence test below, leaving this one with the
two genuinely project-level stages (Doctor, ADR judge) and a count of two -
which keeps it a test of "project-level skips warn and never block" rather
than an accidental precedence test.

Then add:

- a not-applicable skip is reported with `classification: "not_applicable"`,
  `ok: true`, no `blocked` entry, and a `stage_skipped_not_applicable`
  warning - and no `stage_skipped_project_level` warning for that stage
  (sabotage: `env.warn` -> `env.block!` in the not_applicable branch -> red);
- precedence: `:gettext not installed` matches both fixture lists and
  classifies `not_applicable`, while `:doctor not installed` matches only the
  broad list and classifies `project_level`, in the same run (sabotage: swap
  the two `return` lines in `classify_skip` -> red);
- the strict default is unchanged with `not_applicable_skips` absent: build a
  manifest with `manifest_with("gate_tier1", "gate" => {
  "not_applicable_skips" => nil, "project_level_skips" => nil })` and assert a
  `:gettext not installed` skip blocks with code `stage_skipped` and
  `classification: "run_level"` (sabotage: make `matches?` return true on a
  nil regex -> red);
- a unit test of `Gate.classify_skip` over the fixture regexes covering all
  three values plus `nil` and `""` summaries.

Note the existing `manifest_with(...)` idiom merges a section, so an
explicitly `nil` value is how a fixture field is removed (see :322).

#### 4. Kit reference
**File**: `skills/wurk:kit/REFERENCE.md`
**Changes**: rewrite the `data.skipped_stages` bullet (:257-273) as three
cases with their `classification` values and warning codes. The sentence
"both kinds must appear in what you report" becomes: every skip stays in the
payload, `run_level` and `project_level` are named in what you report, and
`not_applicable` need not be. Keep the paragraph on why project-level skips
are not a softening.

#### 5. Commit skill
**File**: `skills/wurk:commit/SKILL.md`
**Changes**: rewrite the `data.skipped_stages` bullet (:114-124) for the three
values. `"run_level"` has already set `ok: false`. `"project_level"` does not
block and is still named in the Step 4 report. `"not_applicable"` does not
block and is not required in the report - the project has declared the stage
will never apply, and repeating it in every report is the noise that stops
people reading the skip lines at all. Keep "a skipped stage is not a passing
one" as the governing rule, applied to what an agent may *claim* (never "gate
fully green" when a stage was skipped), not to what it must enumerate.

#### 6. MR skill
**File**: `skills/wurk:mr/SKILL.md`
**Changes**: rewrite step 4's paragraph (:138-141) the same way: entries with
`classification: "project_level"` are named in the request body and the final
report; entries with `"not_applicable"` are not required in either;
`"run_level"` entries have already made the gate red and the step refuses.

#### 7. Gate contract
**File**: `docs/gate-contract.md`
**Changes**: the tier-1 draft schema (:33-45) annotates the report's `level`
field as `"project" skip = warn; "run" skip = block`, and ":54-56" describes
what tier 1 buys as "the run-level vs project-level skip distinction". Both
are the two-way statement. Add the third value to the comment and to that
sentence, keeping the existing note that `gate.rb` is authority over this
draft schema. Note the `level` field here is the *report producer's* vocabulary
(what the consumer's gate tool emits), which `gate.rb` reads only as a
`summary` match today - so this is a documentation alignment, not a new parse
path, and no code reads `level`.

#### 8. Gate reader agent
**File**: `agents/wurk-gate-reader.md`
**Changes**: the two-distinction bullet list (:64-71) and the "Skips worth
knowing about" output section (:145) both state the two-way rule. Add the
third case: a not-applicable skip is not a finding and does not belong in the
summary at all. The agent's input contract (:47) names `data.skipped_stages`
without the boolean and needs no change.

### Success Criteria:

#### Automated Verification:
- [ ] `ruby skills/wurk:kit/scripts/test/run.rb` is green
- [ ] a test asserts a not-applicable skip yields `ok: true`, empty
      `blocked`, `classification: "not_applicable"`, and a
      `stage_skipped_not_applicable` warning
- [ ] a test asserts a summary matching both lists classifies
      `not_applicable`, and one matching only the broad list classifies
      `project_level`, in the same run
- [ ] a test asserts that with both lists absent a familiar-looking summary
      still blocks with code `stage_skipped` and `classification: "run_level"`
- [ ] `grep -rn "project_level:" skills/ docs/manifest.md` returns no hit
      describing the envelope key (the manifest *field* names stay)
- [ ] the contract test still passes, i.e. no consumer vocabulary entered
      `gate.rb`

#### Manual Verification:
- [ ] `gate.rb`'s module doc rule 1 reads as one coherent three-way rule, not
      a two-way rule with a paragraph bolted on
- [ ] `/wurk:commit` Step 0 and `/wurk:mr` step 4 give an agent an
      unambiguous answer for each of the three values, with no residual
      instruction to name a not-applicable stage
- [ ] running the wurk gate through `gate.rb` in this repo still produces a
      sane envelope (this repo is tier 0, so `skipped_stages` is empty - the
      check is that nothing regressed, not that a skip appears)
- [ ] statifier-ex's manifest could be edited today to move gettext and the
      `.po` patterns into the new list, with no wurk change left outstanding
      (read st-wz4's requirement against the shipped field; do not edit that
      repo here)

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

- `test/manifest_test.rb` - validation of `gate.not_applicable_skips`
  (non-array, uncompilable entry) and the compiled accessor (nil when absent,
  `Regexp` when present). Mirrors the existing `project_level_skips` cases so
  a reader sees the two fields treated identically.
- `test/gate_test.rb` - the classification surface: one test per
  classification value end to end through `run_gate`, one precedence test over
  the deliberately overlapping fixture, one strict-default test with both
  lists absent, and one direct unit test of `Gate.classify_skip` including
  `nil` and `""` summaries.
- Every new test carries a `# sabotage:` note naming a specific mutation that
  turns it red, in the style of its neighbours - the repo's own gate scans for
  their presence and the notes are read at review.

### Key edge cases:

- summary matching both lists (precedence);
- summary matching neither, with both lists declared (blocks);
- both lists absent (blocks - the unchanged strict default);
- `nil` and empty-string summaries (never match, so they block);
- a not-applicable skip alongside a run-level one in the same report - the
  run-level one must still block, mirroring the existing
  `test_a_run_level_skip_still_blocks_alongside_project_level_ones`.

### Manual Testing Steps:

1. Read the diff of `gate.rb`'s module doc rule 1 end to end and confirm the
   three-way rule reads as one rule.
2. Read `/wurk:commit` Step 0 and `/wurk:mr` step 4 as an implementing agent
   would, with a fabricated envelope containing one entry of each
   classification, and confirm each has exactly one defensible action.
3. Construct a scratch manifest declaring only `not_applicable_skips` (no
   `project_level_skips`) and confirm by inspection of the code path that an
   unmatched skip still blocks.
4. Check `docs/manifest.md`'s choosing test against a stage neither example
   covers - e.g. a coverage stage skipped because the project has no coverage
   tool installed and does not intend to add one - and confirm the doc gives a
   clear answer.

## References

- Bead: `wu-axq` (worked example and downstream consumer: statifier-ex st-wz4,
  gettext, blocked on this landing; st-1xz, doctor, the contrasting case)
- Prior plan that introduced `gate.project_level_skips`:
  `docs/plans/260808-wu-gd1-gate-rb-manifest-driven-constants.md` (Phase 1)
- Related ADRs: `docs/adr/0004-manifest-and-extension-seams.md`,
  `docs/adr/0005-gate-contract-tiers.md`,
  `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`
- Current implementation: `skills/wurk:kit/scripts/gate.rb:185-204, 334,
  372-390`; `skills/wurk:kit/scripts/lib/manifest.rb:71-72, 283-292, 476,
  588-603`
- Consumers of the classification: `skills/wurk:kit/REFERENCE.md:257-273`,
  `skills/wurk:commit/SKILL.md:114-124`, `skills/wurk:mr/SKILL.md:138-141`
- Contract: `docs/gate-contract.md`, `docs/manifest.md:164-177`

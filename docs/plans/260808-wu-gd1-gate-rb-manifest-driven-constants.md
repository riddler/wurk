# Manifest-driven gate.rb constants Implementation Plan

## Overview

`skills/wurk:kit/scripts/gate.rb` still carries statifier-specific constants
in kit source, which CLAUDE.md's hard rule forbids. This plan moves every one
of them behind `lib/manifest.rb` as new `gate.*` manifest fields, gives the
sabotage scan an honest "off" state for projects that never adopted the
discipline, and adds a contract-test guard so consumer vocabulary cannot creep
back into kit source unnoticed. Beads issue: `wu-gd1`.

## Current State Analysis

Five leaks, all in `skills/wurk:kit/scripts/gate.rb`:

1. `SABOTAGE_DIFF_ARGS` (gate.rb:68-70) hardcodes
   `git diff main...HEAD -U0 -- test/ :!test/scion_tests :!test/scxml_tests`.
   The `test/` pathspec is statifier's test root; the two `:!` exemptions are
   its generated corpora.
2. `EXEMPT_TEST_DIR_PREFIXES` (gate.rb:90) repeats those two corpus dirs as a
   second, differently-spelled definition site (trailing slashes here, none in
   the pathspec).
3. `TEST_LINE_RE = /\btest\s+"/` (gate.rb:78) matches ExUnit's test macro, not
   a generic test declaration.
4. `PROJECT_LEVEL_SKIP_RE` (gate.rb:62-66) matches `disabled in .quality.exs`,
   which is statifier's gate config filename.
5. The `--help` separators (gate.rb:253, 258) say "Wraps mix gate.verify and
   mix quality --format json --report -" - naming one consumer's gate tool in
   user-visible output from a script whose whole point (REFERENCE.md:250-255)
   is that it knows no gate tool's flag surface.

How it was found (ADR-0007:62, quoted in the bead): running `gate.rb` against
wurk itself with a real `.claude/wurk.json` printed statifier's sabotage
pathspec verbatim in a repo with no `test/` directory. Phase 1's grep criterion
(docs/plan.md) looked for bead ids, worktree paths, and `/Users/johnnyt` - not
for domain vocabulary - so it could not catch this class.

What already works and must not be disturbed:

- Everything else in `gate.rb` is already manifest-driven: `gate.full`,
  `gate.loop`, `gate.report`, `gate.report_loop`, `gate.attest`,
  `gate.guard_ledger`, `gate.build_paths`, `gate.also_gated_paths`
  (gate.rb:209-247, 282-345).
- The gate contract tiers (docs/gate-contract.md, ADR-0005) and the two
  load-bearing report rules in the module doc (gate.rb:17-52): a skipped stage
  is always in `data.skipped_stages`; `data.sabotage.missing` and
  `data.gate_guard` never flip `ok`.
- The manifest validation shape (lib/manifest.rb:407-431): unknown keys warn,
  missing required keys block, enums reject, command fields must be argv
  arrays. New fields must extend this, not bypass it.
- `docs/plan.md:817-822` settles the direction for the scan: "The kit's scan
  stays - it is a grep for a comment shape, and a project with no discipline
  just gets an empty list." That plus item 16 (docs/plan.md:330-335, sabotage
  discipline is statifier-only) is why the answer is a manifest section rather
  than deletion.

Consumers of what changes:

- `skills/wurk:commit/SKILL.md:126-133` is the only skill that reads
  `data.sabotage.missing`. It already delegates policy to
  `.claude/wurk/commit.md`; it does not yet know the scan can be off.
- `skills/wurk:kit/REFERENCE.md:263` and `:276-282` document
  `PROJECT_LEVEL_SKIP_RE` and the sabotage report by name.
- `skills/wurk:kit/scripts/test/gate_test.rb` hardcodes the sabotage argv at
  line 71 (used by every gate test through `expect_no_sabotage_diff`), asserts
  `Gate.project_level_skip?` with a bare summary at :225-230, and carries
  `test_sabotage_scan_ignores_scion_and_scxml_test_dirs` at :683-700.
- Fixtures `test/fixtures/manifests/gate_tier1.json` and `gate_tier0.json` are
  the per-consumer shapes the suite is allowed to know (ADR-0006's argument for
  `ManifestHelper.all_fixture_guarded_paths`), so the new fields get their
  values there.

## Desired End State

`grep` over `skills/wurk:kit/scripts/**/*.rb` (excluding `test/`) finds no
statifier domain vocabulary on any code line: no `scion`, no `scxml`, no
`.quality.exs`, no `mix quality`, no `mix gate.verify`, no ExUnit-shaped test
pattern. `gate.rb` reads all five values from the manifest:

- `gate.project_level_skips` - regex sources for skip summaries that describe
  the project's standing configuration. Absent means no summary is
  project-level, so every skipped stage blocks (the strict direction).
- `gate.sabotage.{test_roots,test_pattern,exempt_prefixes}` - the scan's
  inputs. The section absent means the scan is off, `data.sabotage.enabled` is
  `false` with a stated reason, `data.sabotage.missing` is `[]`, and `gate.rb`
  shells out to `git diff` for it zero times.
- The `--help` text names manifest fields and `docs/gate-contract.md`, never a
  gate tool.

`docs/manifest.md` documents both new sections in the same commits that add
them to `lib/manifest.rb`. `test/contract_test.rb` grows a vocabulary guard so
a future edit reintroducing any of this fails the suite.

Verify with: `ruby skills/wurk:kit/scripts/test/run.rb` green, plus the greps
named in each phase's Automated Verification.

### Key Discoveries:

- gate.rb:68-90 - the four sabotage/skip constants, and the comment at :86-89
  admitting `EXEMPT_TEST_DIR_PREFIXES` duplicates the pathspec ("defense in
  depth"). One manifest list can feed both spellings, removing the duplication
  rather than parameterizing it twice.
- gate.rb:39-43 - the module doc argues `PROJECT_LEVEL_SKIP_RE` is deliberately
  narrow and that widening it "belongs in review". Moving it to the manifest
  keeps that property: widening now means editing the consumer's
  `.claude/wurk.json`, which is a reviewed file in the consumer repo, and the
  kit's default (absent = nothing is project-level) is stricter than today's.
- lib/manifest.rb:65-78 - `KNOWN` drives the unknown-key warning and only
  recurses into sections it lists, so a nested `gate.sabotage` needs its own
  `KNOWN` entry or its keys silently escape validation.
- lib/manifest.rb:384-388 - `fetch` treats an explicit `null` the same as
  absent, so tests can turn a field off with `manifest_with(...)` overrides
  without needing a whole new fixture.
- test/support/manifest_helper.rb:66-84 - fixtures are the sanctioned home for
  per-consumer shapes; ADR-0006 makes the same argument for `gate.moving_files`.
- ADR-0004 (manifest and extension seams) and ADR-0006 (kit scripts, constants
  behind `lib/manifest.rb`) are the settled decisions this plan executes; it
  contradicts neither. ADR-0005 (gate tiers) governs the degradation style used
  for both new fields: absent capability degrades honestly and says so.
- docs/plan.md:330-335 (item 16) - sabotage discipline is statifier-only, which
  is exactly why "absent = off" is the right default rather than a built-in
  guess at a test pattern.

## What We're NOT Doing

- **Not parameterizing the `main...HEAD` base ref.** `gate.rb:109`,
  `repo_state.rb:117`, and `bead.rb:419` all hardcode `main` as the default
  branch. That is a real fourth-site portability problem, but it is wider than
  this bead (three scripts, a new required-ish manifest field, and every test
  that stubs a diff), and mixing it in would make each phase here bigger than
  one reviewable commit. The sabotage diff keeps using `main...HEAD` for now,
  matching its sibling at gate.rb:109. **Action for the implementer:** file a
  follow-up bead (`/wurk:issue`, area `area:kit`) naming those three sites
  before closing this one.
- **Not deleting the sabotage scan.** docs/plan.md:817-822 settled that it
  stays. This plan gives it an off switch, not an exit.
- **Not deriving the project-level skip regex from `gate.moving_files`.** The
  bead sketched keying the skip pattern off the gate config filename the
  manifest already knows. Rejected: `moving_files` answers "changing this file
  invalidates a green run", and reusing it here would mean that adding
  `.credo.exs` to `moving_files` silently widens what skip reasons stop
  blocking. Two unrelated questions, two fields. The explicit list also keeps
  the "widening is a review decision" property gate.rb:39-43 argues for.
- **Not writing an ADR.** ADR-0004 and ADR-0006 already decide that constants
  live in the manifest; this is their application, not a new direction.
  Schema growth is documented in `docs/manifest.md` per CLAUDE.md.
- **Not touching `docs/gate-contract.md:38` or `docs/manifest.md:141-144`.**
  Those name `.quality.exs` and `mix quality` as *examples of a named consumer*
  in prose, which the architecture explicitly allows (docs/architecture.md's
  per-repo tables do the same). The hard rule is about kit source, not about
  documentation that names which project has which value.
- **Not adding `data.sabotage` to `agents/wurk-gate-reader.md`.** It omits the
  field today (it triages red gates; the sabotage report never makes a gate
  red). Out of scope, and not a regression this plan introduces.
- **Not backfilling a real consumer's `.claude/wurk.json`.** statifier's own
  manifest gains `gate.sabotage` and `gate.project_level_skips` at plan phase 2
  step 8, which is where its manifest is edited under human review. This repo's
  `.claude/wurk.json` deliberately declares neither: wurk has no sabotage
  corpus discipline and is a tier-0 consumer of itself, so "off" is the correct
  and now-honest state.

## Implementation Approach

Three phases, each one commit, each green on
`ruby skills/wurk:kit/scripts/test/run.rb` on its own.

Phase 1 and phase 2 are split because they touch different behaviors with
different degradation stories (skip taxonomy vs sabotage scan), and each is a
self-contained schema-plus-code-plus-docs-plus-tests unit. Neither leaves the
other's constant half-migrated: phase 1 removes `PROJECT_LEVEL_SKIP_RE` and the
help text entirely, phase 2 removes the three sabotage constants entirely.
Phase 3 is the guard, deliberately last so it can assert the end state of both.

Every phase keeps `docs/manifest.md` and `lib/manifest.rb` in sync inside its
own commit (CLAUDE.md hard rule), and adds no capability that could change
`ok` in a direction the current code would not: the new degradations are
strictly at-least-as-strict as today's constants.

Style note for the implementer: `gate.rb`, `manifest.rb`, `REFERENCE.md`, and
`docs/manifest.md` are plain-ASCII files (hyphens, not em dashes). Match that.

---

## Phase 1: Project-level skip reasons and help text from the manifest

### Overview

Replace `PROJECT_LEVEL_SKIP_RE` with a manifest-supplied list of regex sources,
and rewrite the `--help` separators so they name manifest fields instead of one
consumer's gate tool.

### Changes Required:

#### 1. Manifest schema
**File**: `skills/wurk:kit/scripts/lib/manifest.rb`
**Changes**: add the key to `KNOWN["gate"]`, add a regex-list validation rule,
add a typed accessor that compiles the sources into one `Regexp` (or `nil`).

```ruby
# KNOWN["gate"] gains: project_level_skips

# A new validation class alongside COMMAND_FIELDS/COMMAND_LIST_FIELDS: a list
# of regex source strings, each of which must compile.
REGEX_LIST_FIELDS = %w[gate.project_level_skips].freeze

def validate_regex_lists
  REGEX_LIST_FIELDS.each do |dotted|
    value = fetch(dotted)
    next if value.nil?

    unless value.is_a?(Array) && value.all? { |v| v.is_a?(String) }
      errors << "#{path}: #{dotted} must be a list of regex source strings, got #{value.inspect}"
      next
    end

    value.each do |source|
      Regexp.new(source)
    rescue RegexpError => e
      errors << "#{path}: #{dotted} entry #{source.inspect} is not a valid regular expression (#{e.message})"
    end
  end
end

# Typed accessor. nil means the project declares no project-level skip
# reasons, which is the strict direction: every skipped stage blocks.
def project_level_skip_re
  sources = Array(fetch("gate.project_level_skips"))
  return nil if sources.empty?

  Regexp.union(sources.map { |s| Regexp.new(s) })
end
```

#### 2. Schema documentation
**File**: `docs/manifest.md`
**Changes**: add `project_level_skips` to the `gate` block in the jsonc sample
with a `// (opt) tier 1` marker; add a short subsection explaining the
semantics and the absent-means-strict default, and add a line to the "Required,
optional, and defaults" section noting that absent means every skipped stage
blocks. Keep the existing statifier example values in the sample (the doc is
allowed to name a consumer's values; the code is not).

#### 3. gate.rb
**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**: delete `PROJECT_LEVEL_SKIP_RE`; thread the compiled regex through
`skipped_from` and `project_level_skip?`; rewrite the module doc paragraph at
:39-43 and the `--help` separators at :251-262.

```ruby
def skipped_from(stages, project_level_re)
  Array(stages)
    .select { |s| s["status"] == "skipped" }
    .map do |s|
      summary = s["summary"]
      { name: s["name"], summary: summary,
        project_level: project_level_skip?(summary, project_level_re) }
    end
end

# True when the skip describes what this project checks at all, rather than
# something this run could not do. The patterns are manifest data
# (gate.project_level_skips): a project that declares none gets the strict
# reading, where every skipped stage blocks.
def project_level_skip?(summary, project_level_re)
  return false if project_level_re.nil?

  !(summary.to_s =~ project_level_re).nil?
end
```

Help text, replacing every separator that names a gate tool:

```ruby
opts.separator "Runs the gate commands the manifest names (gate.full, gate.loop,"
opts.separator "gate.report, gate.report_loop, gate.attest) and reports which tier of"
opts.separator "wurk docs/gate-contract.md the project reached. It knows no gate tool's"
opts.separator "flag surface."
```

The `--profile loop` paragraph and the `data.sabotage.missing` paragraph stay,
with `mix quality` in the former replaced by "the gate command".

#### 4. Kit reference
**File**: `skills/wurk:kit/REFERENCE.md`
**Changes**: at :263-271, replace "`PROJECT_LEVEL_SKIP_RE` is narrow by design"
with the manifest-field statement: the taxonomy comes from
`gate.project_level_skips`, a project declaring none gets the strict reading,
and widening it is an edit to the consumer's manifest. Keep the example skip
reasons - REFERENCE.md is documentation and may name a consumer's values.

#### 5. Tests
**File**: `skills/wurk:kit/scripts/test/fixtures/manifests/gate_tier1.json`
**Changes**: add
`"project_level_skips": ["not installed", "disabled in \\.quality\\.exs"]`
to the `gate` object, so the existing tier-1 project-level tests keep asserting
the same behavior from data instead of from code.

**File**: `skills/wurk:kit/scripts/test/gate_test.rb`
**Changes**:
- rewrite `test_unrecognized_skip_reason_blocks_by_default` (:224-230) to build
  the regex from the fixture manifest and pass it to
  `Gate.project_level_skip?`;
- add a test proving that with `gate.project_level_skips` absent, a
  `:doctor not installed` skip blocks - built with
  `manifest_with("gate_tier1", "gate" => { "project_level_skips" => nil })`,
  asserting `ok` false, `blocked` code `stage_skipped`, and
  `project_level: false` in `data.skipped_stages`;
- add a test that a declared pattern makes the same summary
  `project_level: true` and non-blocking (the mirror of the above, proving the
  field is actually read rather than the strictness being unconditional).

**File**: `skills/wurk:kit/scripts/test/manifest_test.rb`
**Changes**: add cases for a non-array `project_level_skips` (error naming the
field) and an uncompilable source such as `"["` (error naming the entry), and
one asserting `project_level_skip_re` is `nil` when the key is absent.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] `grep -nE 'quality\.exs|gate\.verify|mix quality' skills/wurk:kit/scripts/gate.rb`
      returns no matches
- [x] `grep -n PROJECT_LEVEL_SKIP_RE -r skills/wurk:kit/scripts` returns no
      matches outside `test/`
- [x] `ruby skills/wurk:kit/scripts/lib/manifest.rb check --file skills/wurk:kit/scripts/test/fixtures/manifests/gate_tier1.json`
      exits 0 with `data.valid` true
- [x] `docs/manifest.md` documents `gate.project_level_skips` in the same
      commit as the `lib/manifest.rb` change (verify with
      `git show --stat` on the phase commit)

#### Manual Verification:
- [ ] `ruby skills/wurk:kit/scripts/gate.rb --help` reads as instructions for
      any project, not for an Elixir one, names no gate tool, and still says
      everything a caller needs about `--profile loop`
- [ ] The rewritten module-doc paragraph still makes the run-level vs
      project-level argument as forcefully as gate.rb:17-43 did
- [ ] No regressions in `/wurk:commit` Step 0 reading of the gate envelope
      (field names unchanged: `data.skipped_stages[].project_level`)

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: The sabotage scan becomes a manifest capability

### Overview

Move the scan's three inputs into a `gate.sabotage` manifest section, and make
an absent section mean the scan is off - reported as off, with no `git diff`
shelled out for it.

### Changes Required:

#### 1. Manifest schema
**File**: `skills/wurk:kit/scripts/lib/manifest.rb`
**Changes**: add `sabotage` to `KNOWN["gate"]`, add `KNOWN["gate.sabotage"]`,
validate the section when present, add accessors.

```ruby
KNOWN["gate.sabotage"] = %w[test_roots test_pattern exempt_prefixes]

# Present-or-absent, never half-present: a section that declares roots but no
# pattern (or vice versa) is a schema error, not a partly-on scan.
def validate_sabotage
  section = fetch("gate.sabotage")
  return if section.nil?

  unless section.is_a?(Hash)
    errors << "#{path}: gate.sabotage must be an object (see wurk docs/manifest.md)"
    return
  end

  roots = section["test_roots"]
  unless roots.is_a?(Array) && !roots.empty? && roots.all? { |r| r.is_a?(String) }
    errors << "#{path}: gate.sabotage.test_roots must be a non-empty list of path prefixes"
  end

  pattern = section["test_pattern"]
  if !pattern.is_a?(String) || pattern.empty?
    errors << "#{path}: gate.sabotage.test_pattern must be a regex source string"
  else
    begin
      Regexp.new(pattern)
    rescue RegexpError => e
      errors << "#{path}: gate.sabotage.test_pattern is not a valid regular expression (#{e.message})"
    end
  end

  exempt = section["exempt_prefixes"]
  unless exempt.nil? || (exempt.is_a?(Array) && exempt.all? { |p| p.is_a?(String) })
    errors << "#{path}: gate.sabotage.exempt_prefixes must be a list of path prefixes"
  end
end

def sabotage?
  !fetch("gate.sabotage").nil?
end

def sabotage_test_roots
  Array(fetch("gate.sabotage.test_roots"))
end

def sabotage_test_pattern
  source = fetch("gate.sabotage.test_pattern")
  source && Regexp.new(source)
end

def sabotage_exempt_prefixes
  Array(fetch("gate.sabotage.exempt_prefixes"))
end
```

#### 2. Schema documentation
**File**: `docs/manifest.md`
**Changes**: add the `sabotage` object to the `gate` block in the jsonc sample,
and a subsection stating: what the scan does (a grep for a comment shape above
an added test declaration), that it is report-only and never flips `ok`, that
an absent section turns it off and the envelope says so, and that
`exempt_prefixes` feeds both the `git diff` pathspec and the in-scan filter so
there is one definition site. Add a `gate.sabotage` row to the per-repo table
(statifier: yes; predicator, fixative: none).

#### 3. gate.rb
**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**: delete `SABOTAGE_DIFF_ARGS`, `TEST_LINE_RE`, and
`EXEMPT_TEST_DIR_PREFIXES`; keep `SABOTAGE_NOTE_RE` and `COMMENT_LINE_RE`
(comment-shape grammar, not consumer data - the note form is wurk's own
convention, dogfooded in this repo's own test files). Thread the manifest
values through.

```ruby
# One definition site for the corpus exemptions: the pathspec keeps them out
# of the diff at the git level, and scan_sabotage filters them again in case
# it is ever handed diff text from elsewhere. Both read the same list.
def sabotage_diff_args(manifest)
  %w[git diff main...HEAD -U0 --] +
    manifest.sabotage_test_roots +
    manifest.sabotage_exempt_prefixes.map { |prefix| ":!#{prefix}" }
end

def scan_sabotage(diff_text, test_re:, exempt_prefixes: [])
  # ... unchanged body, with TEST_LINE_RE -> test_re and
  # EXEMPT_TEST_DIR_PREFIXES -> exempt_prefixes
end

def sabotage_missing(env, manifest)
  return [] unless manifest.sabotage?

  diff_res = Sh.run(sabotage_diff_args(manifest), envelope: env)
  return [] unless diff_res.success?

  scan_sabotage(diff_res.out,
                test_re: manifest.sabotage_test_pattern,
                exempt_prefixes: manifest.sabotage_exempt_prefixes)
end
```

In `run`, the payload gains an explicit off state:

```ruby
missing = sabotage_missing(env, manifest)
env.data[:sabotage] = {
  enabled: manifest.sabotage?,
  reason: manifest.sabotage? ? nil : "no gate.sabotage section in the manifest; the scan is off",
  missing: missing
}
```

`missing` stays present and `[]` when off, so no existing reader breaks. No
warning is emitted for the off state: it is a standing project property, true
on every run, and warning on it every time is the same signal-deleting mistake
the module doc rejects for project-level skips (gate.rb:30-37).

The module doc's rule 3 and the `--help` sabotage paragraph both gain one
sentence: the scan runs only when the manifest declares `gate.sabotage`.

#### 4. Kit reference and the one skill that reads the field
**File**: `skills/wurk:kit/REFERENCE.md`
**Changes**: at :276-282, add that the scan is a manifest capability -
`data.sabotage.enabled` is `false` with a `reason` when the project declares no
`gate.sabotage` section, and `missing` is then always `[]` (absence of findings
is not evidence of discipline).

**File**: `skills/wurk:commit/SKILL.md`
**Changes**: at :126-133, add one sentence to the existing bullet: when
`data.sabotage.enabled` is `false` the project has not configured the scan, so
an empty `missing` says nothing - do not report it as a clean result. The
existing delegation to `.claude/wurk/commit.md` is unchanged.

#### 5. Tests
**File**: `test/fixtures/manifests/gate_tier1.json`
**Changes**: add the section, keeping the statifier-shaped values that the
existing tests assert against:

```json
"sabotage": {
  "test_roots": ["test/"],
  "test_pattern": "\\btest\\s+\"",
  "exempt_prefixes": ["test/scion_tests/", "test/scxml_tests/"]
}
```

`gate_tier0.json` deliberately gains nothing: it becomes the fixture that
exercises the off path.

**File**: `skills/wurk:kit/scripts/test/gate_test.rb`
**Changes**:
- `expect_no_sabotage_diff` (:69-74) derives its argv from the same rule the
  script uses, so the expected pathspec is
  `git diff main...HEAD -U0 -- test/ :!test/scion_tests/ :!test/scxml_tests/`
  (note the trailing slashes: one list now feeds both spellings, and git treats
  `:!test/scion_tests/` the same as the old un-slashed form);
- remove the `expect_no_sabotage_diff` calls from the four `gate_tier0` tests
  (:311-373) - with the section absent, any sabotage `git diff` would raise
  `FakeSh::UnexpectedCommand`, which is the proof that the off path shells out
  zero times;
- add `test_sabotage_scan_is_off_when_the_manifest_declares_no_section`
  (tier-0 fixture): asserts `data.sabotage.enabled` false, a non-nil `reason`,
  `missing` `[]`, and `ok` unaffected;
- update the direct `Gate.scan_sabotage` unit tests (:545-700) to pass
  `test_re:` and `exempt_prefixes:` explicitly; the corpus-exemption test
  (:683-700) now proves the prefixes are honored from data;
- add a test that a different `test_pattern` (for example
  `"\\bdef test_"`) flags a Python/Ruby-shaped declaration and ignores the
  ExUnit-shaped one, proving the pattern is genuinely data-driven.

**File**: `skills/wurk:kit/scripts/test/manifest_test.rb`
**Changes**: cases for a `gate.sabotage` missing `test_roots`, missing
`test_pattern`, an uncompilable `test_pattern`, a non-array `exempt_prefixes`,
and one asserting `sabotage?` is false with no section and that
`sabotage_exempt_prefixes` is `[]` rather than nil.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [ ] `grep -niE 'scion|scxml' skills/wurk:kit/scripts/gate.rb` returns no
      matches
- [ ] `grep -nE 'SABOTAGE_DIFF_ARGS|TEST_LINE_RE|EXEMPT_TEST_DIR_PREFIXES' -r skills/wurk:kit/scripts`
      returns no matches outside `test/`
- [ ] Running the real script in this repo (which declares no `gate.sabotage`)
      reports the scan off and names no `test/` pathspec:
      `ruby skills/wurk:kit/scripts/gate.rb | ruby -rjson -e 'e=JSON.parse($stdin.read); abort("enabled") if e["data"]["sabotage"]["enabled"]; abort("pathspec leaked") if e["commands"].join(" ").include?("scion")'`
- [ ] `docs/manifest.md` documents `gate.sabotage` in the same commit as the
      `lib/manifest.rb` change

#### Manual Verification:
- [ ] With statifier-shaped fixture data, the scan still flags exactly what it
      flagged before (spot-check the diff of `gate_test.rb` assertions: the
      expected findings should be unchanged, only their inputs moved)
- [ ] The `/wurk:commit` Step 0 wording makes the off state unmistakable - a
      reader cannot mistake an empty `missing` for a clean bill of health
- [ ] `docs/manifest.md`'s new subsection is comprehensible to someone
      onboarding a project that has never heard of the sabotage protocol

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 3: A contract-test guard against consumer vocabulary

### Overview

The bead's own diagnosis is that phase 1's grep criterion looked for bead ids,
worktree paths, and home directories, not for domain vocabulary, so this class
of leak had no mechanical catcher. Add one to the contract test, which is
already the enforcement site for "what kit scripts may not contain".

### Changes Required:

#### 1. The rule
**File**: `skills/wurk:kit/scripts/test/contract_test.rb`
**Changes**: add a `Contract.consumer_vocabulary` rule beside the existing
ones, following the same shape (a pure function over content, unit-tested on
synthetic input by `ContractRulesTest`, applied to the real `non_test_files` by
`ContractTest`).

```ruby
# Domain vocabulary from the consumer repos wurk serves. A kit script that
# names one has a constant that belongs in the manifest (CLAUDE.md's hard
# rule; ADR-0004). Comments are exempt, same as every other rule here - a
# comment may cite where a behavior came from; a code line may not encode it.
#
# This list is allowed to name consumer values precisely because it is the
# enforcement site, the same way BANNED_CALLS names the operations it bans.
CONSUMER_VOCABULARY = {
  "statifier corpus dirs" => /scion|scxml/i,
  "elixir gate config" => /\.(quality|credo|sobelow-conf)\b|coveralls\.json/,
  "mix gate commands" => /\bmix\s+(quality|gate\.\w+)\b/,
  "exunit test macro" => /\\btest\\s\+"/,
  "consumer repo names" => /statifier|predicator|fixative/i
}.freeze

def self.consumer_vocabulary(content)
  hits = []
  each_code_line(content) do |code, lineno|
    CONSUMER_VOCABULARY.each { |label, re| hits << [lineno, label] if code =~ re }
  end
  hits
end
```

#### 2. The application and its meta-check
**File**: `skills/wurk:kit/scripts/test/contract_test.rb`
**Changes**: add `test_no_consumer_vocabulary_in_kit_source` over
`non_test_files`, with a failure message that says what to do (move the value
into the manifest and document it in `docs/manifest.md`), and extend the
existing planted-violation meta-test so a synthetic file containing
`EXEMPT = ["test/scion_tests/"]` is caught. The meta-check matters here for the
same reason it does for the banned-call scan: a vocabulary guard that matches
nothing is worse than none.

#### 3. Known exception
**File**: `skills/wurk:kit/scripts/lib/beads.rb`
**Changes**: line 134 has `"stale branch name (statifier-ex ADR-0010)"` in a
user-facing string, which the new rule catches. Rewrite the string to describe
the condition without citing a consumer's ADR ("stale branch name - the branch
predates the bead id"), and keep the citation as a comment above it if the
provenance is worth keeping. This is the one live violation outside `gate.rb`;
confirm with the grep in the criteria below before assuming there are no
others.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [ ] The guard is not vacuous: temporarily add
      `X = ["test/scion_tests/"]` to `skills/wurk:kit/scripts/gate.rb`, confirm
      `ruby skills/wurk:kit/scripts/test/run.rb` goes red naming that line, then
      revert. (The planted-violation meta-test asserts the same thing
      permanently.)
- [ ] The guard really runs over the real files, not just its synthetic unit
      cases:
      `ruby skills/wurk:kit/scripts/test/run.rb --name test_no_consumer_vocabulary_in_kit_source`
      reports `1 runs, 0 failures` (a `0 runs` result means the test was named
      differently and this criterion proved nothing)

#### Manual Verification:
- [ ] The vocabulary list is neither so wide it fires on legitimate generic
      words nor so narrow it only re-catches the five leaks this plan already
      fixed - read each pattern and ask what a false positive would look like
- [ ] The failure message tells a future implementer what to do, not just that
      something is wrong
- [ ] The rewritten `beads.rb` message still tells a user what happened

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/manifest_test.rb` - validation of both new sections: wrong types,
  uncompilable regex sources, a half-declared `gate.sabotage`, and the accessor
  defaults when the keys are absent (`nil` regex, `[]` prefixes, `sabotage?`
  false).
- `test/gate_test.rb` - the behavioral halves: a skip summary blocks when no
  `project_level_skips` are declared and warns when a matching one is;
  the sabotage scan honors `test_pattern` and `exempt_prefixes` from data, and
  shells out zero times when the section is absent (proved by `FakeSh` raising
  on an unexpected command rather than by an assertion that could rot).
- `test/contract_test.rb` - `ContractRulesTest` cases for
  `consumer_vocabulary` on synthetic content (a hit on a code line, no hit on a
  comment line), plus the planted-violation meta-test.
- Every new test in this repo carries a `# sabotage:` note naming the mutation
  that would make it red, matching the convention already used throughout
  `test/` (for example `gate_test.rb:126`).

### Manual Testing Steps:

1. `ruby skills/wurk:kit/scripts/gate.rb --help` - read it as someone whose
   project is not Elixir. Nothing should name a gate tool.
2. `ruby skills/wurk:kit/scripts/gate.rb` in this repo (no `gate.sabotage`, no
   `project_level_skips`) - the envelope's `data.sabotage.enabled` is `false`
   with a stated reason, `commands[]` contains no `test/` pathspec, and the run
   still reports its tier honestly.
3. Point the script at a fixture manifest that does declare both sections (via
   a scratch `in_tmp_repo`-style directory) and confirm the emitted
   `commands[]` shows the pathspec built from that manifest's values.
4. Re-read `docs/manifest.md` against `lib/manifest.rb` field by field for the
   two new sections - the doc must follow the code exactly (CLAUDE.md).

## References

- Bead: `wu-gd1`
- Source constants: `skills/wurk:kit/scripts/gate.rb:62-90`, `:196-199`,
  `:250-269`
- Manifest authority: `skills/wurk:kit/scripts/lib/manifest.rb:65-89`,
  `:404-431`
- Schema doc: `docs/manifest.md`
- Related ADRs: `docs/adr/0004-manifest-and-extension-seams.md`,
  `docs/adr/0005-gate-contract-tiers.md`,
  `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`,
  `docs/adr/0007-beads-for-issue-tracking.md` (where the leak was recorded)
- Gate contract: `docs/gate-contract.md`
- Migration plan context: `docs/plan.md:330-335` (item 16),
  `:645-650` (backlog), `:817-822` (the scan stays)
- Similar manifest-driven refactor to model after: the carve-out reason at
  `skills/wurk:kit/scripts/gate.rb:209-212` and its test at
  `test/gate_test.rb:380-391`
- Fixture conventions: `skills/wurk:kit/scripts/test/support/manifest_helper.rb:66-84`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] `ruby skills/wurk:kit/scripts/gate.rb --help` reads as instructions for
      any project, not for an Elixir one, names no gate tool, and still says
      everything a caller needs about `--profile loop`
- [ ] The rewritten module-doc paragraph still makes the run-level vs
      project-level argument as forcefully as gate.rb:17-43 did
- [ ] No regressions in `/wurk:commit` Step 0 reading of the gate envelope
      (field names unchanged: `data.skipped_stages[].project_level`)

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

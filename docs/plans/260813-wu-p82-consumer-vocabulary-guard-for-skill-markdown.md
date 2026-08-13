# Consumer-vocabulary guard for skill markdown Implementation Plan

## Overview

Extend `Contract.consumer_vocabulary`'s reach from kit Ruby source to the
markdown this repo ships as instructions, so a consumer constant landing in a
`skills/wurk:*/SKILL.md` fails the gate instead of passing unnoticed. The rule
for markdown is not the code rule with a wider glob: it is drawn by file class
(instruction surface vs documentation surface), because markdown legitimately
cites consumer projects as provenance and as worked examples. Bead: wu-p82

## Current State Analysis

`skills/wurk:kit/scripts/test/contract_test.rb` holds every mechanical rule
this repo enforces over its own source, as pure functions on `Contract` plus a
`ContractTest` that applies them to real files.

- `Contract::CONSUMER_VOCABULARY` (contract_test.rb:153-159) is five labelled
  regexes: statifier corpus dirs, elixir gate config, mix gate commands,
  exunit test macro, consumer repo names.
- `Contract.consumer_vocabulary` (contract_test.rb:163-169) walks
  `each_code_line`, which strips a trailing `# ...` comment via `code_only`
  (contract_test.rb:68-79). Comments are exempt by design: "a comment may cite
  where a behavior came from; a code line may not encode it."
- `ContractTest#test_no_consumer_vocabulary_in_kit_source`
  (contract_test.rb:380-390) applies it to `non_test_files` - every `**/*.rb`
  under `skills/wurk:kit/scripts/` except the `test/` subtree
  (contract_test.rb:315-324).
- Nothing scans markdown. `skills/wurk:*/SKILL.md` (14 files) and
  `skills/wurk:kit/REFERENCE.md` are unguarded, so a bead prefix, a gate
  command, or a corpus directory in skill instructions violates CLAUDE.md's
  hard rule and ADR-0004 with no test noticing.

Facts verified against the tree at this branch (all five regexes applied to
`skills/**/*.md`):

- **Zero hits in any `skills/wurk:*/SKILL.md`.** The strict rule below is
  green today with no content edits.
- **Five hits in `skills/wurk:kit/REFERENCE.md`**, all legitimate:
  - `:11`, `:12` - prose naming statifier-ex as where the layer was extracted,
    plus a path to statifier's own plan document (provenance).
  - `:208` - prose explaining why a consumer's `mix quality` should stop
    running this suite (provenance and rationale).
  - `:264` - `` `disabled in .quality.exs` `` inside prose, quoting an example
    skip reason a gate might report.
  - `:410` - `.quality.exs` / `.credo.exs` / `coveralls.json` inside a
    ` ```json ` fence that is a worked example of a *consumer's*
    `settings.json` deny list.
- Very many hits in
  `skills/wurk:kit/scripts/test/fixtures/plans/real_grammar_snapshot.md`, a
  frozen copy of a real consumer plan used as test input.
- `agents/*.md` and `.claude/wurk/*.md`: zero hits (checked, for scope
  reasoning below).
- Fence languages actually used across `skills/**/*.md`: `bash` (22), `sh`
  (5), `ruby` (3), `json` (3). Every fence opener in REFERENCE.md carries an
  info string; the only bare ` ``` ` lines are closers.

Line 410 is the hard case the bead flags: it is a code block, but a legitimate
worked example. Any rule of the form "code blocks violate, prose does not"
must handle it.

## Desired End State

`ruby skills/wurk:kit/scripts/test/run.rb` fails when a consumer constant
appears anywhere in a `skills/wurk:*/SKILL.md`, or inside a shell command
block in `skills/wurk:kit/REFERENCE.md`. It stays green on the tree as it
stands today, including all five REFERENCE.md citations. The scan cannot go
vacuous unnoticed: a test asserts every `skills/wurk:*/` directory contributes
a scanned `SKILL.md` and that REFERENCE.md exists at the expected path. A
planted violation in each surface is caught by a meta-test, and the prose-vs-
instruction distinction is written out at the enforcement site.

Verify by: running the gate (green), then temporarily inserting
`statifier-ex` into any `skills/wurk:*/SKILL.md` and into a ` ```sh ` block in
REFERENCE.md and confirming both go red, and into REFERENCE.md prose and its
` ```json ` block and confirming both stay green.

### Key Discoveries:

- `Contract.code_only` strips everything after `#` (contract_test.rb:68-70).
  Markdown **cannot** reuse `each_code_line`: `#` opens a heading, so every
  ATX heading would be blanked and a `#`-prefixed line would be silently
  exempt. Markdown needs its own line walk.
- The file header (contract_test.rb:14-18) records why an inline-citation
  escape hatch was rejected for these rules: it "is the opposite of absolute."
  So the markdown rule must draw its exemption **structurally, by file class
  and block kind**, never with a per-line `<!-- allowed -->` marker.
- `ContractTest` already reaches outside the scripts tree by relative path for
  the ADR-0006 drift check (contract_test.rb:443-444), so
  `SCRIPTS_ROOT/../../..` is the established spelling for the repo root.
- CLAUDE.md's hard rule and ADR-0004 put every project constant behind the
  manifest or an extension file; `docs/architecture.md:25-32` states the same
  for generic skills. That is why SKILL.md can be scanned strictly with no
  exemption at all - the rule already says a skill may contain none.
- ADR-0008 puts *judgment* over skill prose at the merge seam with a model
  judge, deliberately out of `run.rb`. This plan adds no judgment: "does this
  file contain this literal string" is mechanical, belongs in the
  deterministic gate, and does not overlap the judge's surface.
- `ManifestHelper.all_fixture_guarded_paths` shows the established pattern for
  proving a scan is not vacuous (contract_test.rb:216-217).

## What We're NOT Doing

- **Not scanning `docs/**`, including `docs/manifest.md`.** Its per-repo
  starting-values table is nothing but consumer values, and by ADR-0004 that
  document is precisely where consumer example values belong. Out of scope by
  the glob, with the reason stated at the enforcement site (satisfies the
  bead's "out of scope or explicitly exempt").
- **Not scanning `skills/wurk:kit/scripts/test/fixtures/**`.** Fixtures are
  frozen real-world inputs; `real_grammar_snapshot.md` is a consumer plan
  document on purpose. The globs exclude it structurally (it is not a
  `SKILL.md` and not REFERENCE.md), so no exemption list is needed.
- **Not scanning `agents/*.md`.** They are generic instruction text and would
  fit the strict rule (verified: zero hits today), but the bead's acceptance
  criteria name two surfaces and adding a third widens the change without a
  stated need. Zero hits today means a follow-up bead loses nothing by
  waiting.
- **Not scanning `.claude/wurk/*.md`.** Those are wurk-as-consumer extension
  files (ADR-0007); consumer values are legitimate there by construction.
- **Not adding a per-line or per-block exemption marker.** Rejected for the
  reason the file header already gives for inline citations.
- **Not scanning ` ```ruby ` or ` ```json ` fences in REFERENCE.md.** They
  illustrate someone else's file or someone else's code, which is the same
  citation licence the surrounding prose has. This is the rule that keeps
  :407-413 green without a special case.
- **Not writing a new ADR.** This implements CLAUDE.md's existing hard rule
  and ADR-0004; nothing new is being decided at direction level.
- **Not touching `Contract::CONSUMER_VOCABULARY`'s regexes.** The vocabulary
  list is settled; only its reach changes.

## Implementation Approach

Two rules, chosen by what the file *is*:

1. **`skills/wurk:*/SKILL.md` - strict, every line.** A skill is executed, not
   read for background. CLAUDE.md's hard rule says a generic skill contains no
   consumer constants at all, so there is no legitimate mention to protect:
   provenance belongs in REFERENCE.md, an ADR, or a plan document. Prose,
   headings, tables and code blocks are all in scope. Green today at zero
   hits, so strictness costs nothing now and is the honest reading of the
   rule.

2. **`skills/wurk:kit/REFERENCE.md` - shell command blocks only.** REFERENCE
   is documentation. It states where the layer came from, why a consumer's own
   gate should stop measuring the kit, and what a consumer's `settings.json`
   looks like - citations and worked examples, all legitimate. What is *not*
   legitimate is a command a reader is told to run with a consumer's value
   baked into it. So the scanned surface is exactly the fenced blocks whose
   info string names a shell (`sh`, `bash`, `shell`, `zsh`, `console`,
   `fish`). That is what makes line 410's ` ```json ` deny-list example pass
   while a `mix quality` inside a ` ```sh ` block would fail - the distinction
   is "instruction the reader executes" vs "citation or example", and a shell
   fence is the mechanical proxy for the former.

Both are added as pure functions on `Contract` (Phase 1, unit-tested against
synthetic content the way every existing rule is), then applied to the real
tree with a non-vacuity guard and a meta-test (Phase 2). The split keeps each
phase independently green: Phase 1 ships functions plus the tests that
exercise them, Phase 2 ships the whole-tree assertions.

Known and accepted false negatives, to be stated in the code comment beside
the existing `code_only` trade-off note:

- An unlabelled fence (bare ` ``` `) in REFERENCE.md is treated as an example,
  not a command block. No opener in the file is bare today; a future author
  who drops the info string loses syntax highlighting, which makes the
  omission visible in review.
- Indented (four-space) code blocks in REFERENCE.md are not detected. The file
  uses fences throughout.
- A consumer command spread across a shell block with a line continuation such
  that no single line matches is not caught. Same single-line matching
  limitation every other rule in this file has.

---

## Phase 1: Markdown scanning primitives and their unit tests

### Overview

Add the markdown line walk, the shell-fence detector, and the two rule
functions to `Contract`, with unit tests in `ContractRulesTest` that prove
each catches what it claims and exempts what it claims. No whole-tree
assertions yet, so this phase cannot go red on repo content.

### Changes Required:

#### 1. Contract module

**File**: `skills/wurk:kit/scripts/test/contract_test.rb`
**Changes**: after `consumer_vocabulary` (currently ending line 169), add the
markdown surface: a documented comment block stating the file-class rule, the
shell-fence language list, `each_shell_fence_line`, and the two rule
functions. Plain ASCII punctuation, matching the file.

```ruby
  # The markdown surfaces this kit ships. The rules above answer "does a
  # script encode a consumer constant"; these answer it for the text this
  # repo ships as instructions - and the answer is not the same rule with a
  # wider glob, because markdown legitimately cites consumer projects.
  #
  # The line between a citable mention and a violating instruction is drawn
  # by file class and block kind, never by a per-line escape hatch: an
  # inline "allowed here" marker is the opposite of absolute, for the same
  # reason this file's header gives for rejecting inline citations.
  #
  # - skills/wurk:*/SKILL.md is instruction text end to end. A skill is
  #   executed, not read for background, and CLAUDE.md's hard rule with
  #   ADR-0004 puts every project constant behind the manifest or an
  #   extension file. So every line counts, prose included: there is
  #   nothing a generic skill needs to say about a consumer repo that is
  #   not either a manifest field or provenance belonging in REFERENCE.md,
  #   an ADR, or a plan document.
  #
  # - skills/wurk:kit/REFERENCE.md is documentation. It states where this
  #   layer was extracted from, why a consumer's own gate should stop
  #   measuring the kit, and what a consumer's settings.json deny list
  #   looks like. Those are citations and worked examples and they stay
  #   legal. What is not legal there is a command a reader is told to run
  #   with a consumer's value baked in, so the scanned surface is exactly
  #   the fenced blocks whose info string names a shell. A ```json or
  #   ```ruby fence is an example of someone else's file, which carries the
  #   same licence the prose around it has.
  #
  # - docs/** is out of scope entirely, docs/manifest.md included: its
  #   per-repo table of starting values is consumer values by definition
  #   (ADR-0004), and scripts/test/fixtures/** holds frozen consumer
  #   documents used as test input. Both are excluded structurally by the
  #   globs in ContractTest rather than by an exemption list.
  #
  # Markdown gets its own line walk rather than each_code_line: code_only
  # strips everything after a "#", which in markdown blanks every ATX
  # heading. Accepted false negatives, in the spirit of code_only's own
  # note: a bare unlabelled fence reads as an example, four-space indented
  # blocks are not detected, and a command split across lines so that none
  # matches on its own is missed.
  SHELL_FENCE_LANGS = %w[sh bash shell zsh console fish].freeze

  # Yields [line, lineno] for each line inside a fenced block whose info
  # string names a shell. Fence lines themselves are never yielded; a
  # closing fence carries no info string, which is what flips the state
  # back off.
  def each_shell_fence_line(content)
    fence = nil
    content.each_line.with_index(1) do |line, lineno|
      if (match = line.match(/^\s*(?:```|~~~)\s*([A-Za-z0-9_+-]*)\s*$/))
        fence = fence.nil? ? match[1].downcase : nil
        next
      end
      next unless fence && SHELL_FENCE_LANGS.include?(fence)

      yield line, lineno
    end
  end

  # Returns [[lineno, label], ...] for every consumer-vocabulary hit on any
  # line. The SKILL.md rule.
  def consumer_vocabulary_anywhere(content)
    hits = []
    content.each_line.with_index(1) do |line, lineno|
      CONSUMER_VOCABULARY.each { |label, re| hits << [lineno, label] if line =~ re }
    end
    hits
  end

  # Returns [[lineno, label], ...] for hits inside shell command blocks
  # only. The REFERENCE.md rule.
  def consumer_vocabulary_in_shell_fences(content)
    hits = []
    each_shell_fence_line(content) do |line, lineno|
      CONSUMER_VOCABULARY.each { |label, re| hits << [lineno, label] if line =~ re }
    end
    hits
  end
```

#### 2. Rule unit tests

**File**: `skills/wurk:kit/scripts/test/contract_test.rb`
**Changes**: in `ContractRulesTest`, after
`test_consumer_vocabulary_ignores_comments` (currently line 282-285), add
tests covering: a hit in SKILL-style prose, a hit under a markdown heading
(the `code_only` trap), a shell fence hit, prose and ` ```json ` exempt from
the fence rule, and a closing fence ending the block.

```ruby
  def test_consumer_vocabulary_anywhere_flags_prose_and_headings
    assert_equal [[1, "consumer repo names"]],
                 Contract.consumer_vocabulary_anywhere("Run this in statifier-ex.\n")
    assert_equal [[1, "mix gate commands"]],
                 Contract.consumer_vocabulary_anywhere("## Reading mix quality output\n")
  end

  def test_consumer_vocabulary_in_shell_fences_flags_only_command_blocks
    doc = <<~MD
      Extracted from statifier-ex first.

      ```json
      "deny": ["Edit(.quality.exs)", "Edit(.credo.exs)"]
      ```

      ```sh
      mix quality
      ```

      Back to prose about .credo.exs.
    MD

    assert_equal [[8, "mix gate commands"]],
                 Contract.consumer_vocabulary_in_shell_fences(doc)
  end

  def test_shell_fence_walk_stops_at_the_closing_fence
    doc = "```bash\nmix quality\n```\nmix quality\n"

    assert_equal [2], Contract.consumer_vocabulary_in_shell_fences(doc).map(&:first)
  end
```

(Confirm the expected line numbers against the heredoc when writing; the
assertion must name the real line, not an approximate one.)

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] The new `ContractRulesTest` tests run and pass:
      `ruby skills/wurk:kit/scripts/test/run.rb -n /shell_fence|vocabulary_anywhere/`

#### Manual Verification:
- [ ] Sabotage check, mutated by hand and reverted: changing the fence regex
      to treat a closing fence as an opener turns
      `test_shell_fence_walk_stops_at_the_closing_fence` red.
- [ ] The comment block reads as the rule a future author would apply, not as
      a description of the code beneath it.
- [ ] Punctuation is plain ASCII and the style matches the surrounding file.
- [ ] No regressions in related features: the existing `.rb` rules are
      untouched and `Contract::CONSUMER_VOCABULARY` is unchanged.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: Apply the rules to the shipped markdown

### Overview

Wire the Phase 1 functions to the real tree in `ContractTest`: the SKILL.md
strict scan, the REFERENCE.md command-block scan, a non-vacuity test, and a
meta-test that plants violations. Add the one-line pointer in
`docs/architecture.md` so the layer-1 rule says where it is enforced.

### Changes Required:

#### 1. Whole-tree scans

**File**: `skills/wurk:kit/scripts/test/contract_test.rb`
**Changes**: in `ContractTest`, add a `REPO_ROOT` constant beside
`SCRIPTS_ROOT` (contract_test.rb:313), the two file locators, and three tests.
Place them after `test_no_consumer_vocabulary_in_kit_source`
(contract_test.rb:390).

```ruby
  REPO_ROOT = File.expand_path(File.join(SCRIPTS_ROOT, "..", "..", ".."))

  def skill_markdown_files
    Dir.glob(File.join(REPO_ROOT, "skills", "wurk:*", "SKILL.md")).sort
  end

  def kit_reference_file
    File.join(REPO_ROOT, "skills", "wurk:kit", "REFERENCE.md")
  end

  # Without this, a rename or a moved directory would empty the globs and
  # both scans below would pass by scanning nothing - the same vacuity trap
  # test_guarded_writes_detected_for_every_fixture_declared_path guards
  # against. Every skill directory must contribute a scanned file.
  def test_markdown_scans_cover_every_shipped_skill
    dirs = Dir.glob(File.join(REPO_ROOT, "skills", "wurk:*")).select { |d| File.directory?(d) }
    refute_empty dirs, "no skill directories found - the markdown scans would be vacuous"

    missing = dirs.reject { |d| File.exist?(File.join(d, "SKILL.md")) }
    assert_empty missing.map { |d| File.basename(d) },
                 "skill directory without a SKILL.md - the strict markdown scan would miss it"
    assert_path_exists kit_reference_file, "the kit REFERENCE.md moved; update this scan with it"
  end

  def test_no_consumer_vocabulary_in_skill_markdown
    offenders = []
    skill_markdown_files.each do |file|
      Contract.consumer_vocabulary_anywhere(File.read(file)).each do |(lineno, label)|
        offenders << "#{file}:#{lineno} (#{label})"
      end
    end
    assert_empty offenders,
                 "consumer vocabulary found in skill instructions: #{offenders.join(', ')} - " \
                 "a generic skill names no consumer constant anywhere, prose included; take the " \
                 "value from the manifest (docs/manifest.md) or an extension file, and put " \
                 "provenance in REFERENCE.md or an ADR"
  end

  def test_no_consumer_vocabulary_in_kit_reference_command_blocks
    offenders = Contract.consumer_vocabulary_in_shell_fences(File.read(kit_reference_file))
                        .map { |(lineno, label)| "#{kit_reference_file}:#{lineno} (#{label})" }
    assert_empty offenders,
                 "consumer vocabulary in a REFERENCE.md command block: #{offenders.join(', ')} - " \
                 "citing a consumer in prose or in a worked example is fine; telling a reader to " \
                 "run a consumer's command is not"
  end
```

#### 2. Meta-test

**File**: `skills/wurk:kit/scripts/test/contract_test.rb`
**Changes**: add a markdown counterpart beside
`test_meta_the_scan_actually_catches_a_planted_violation`
(contract_test.rb:407-425), proving both directions - the planted violation is
caught, and the legitimate citation shapes are not.

```ruby
  # The markdown half of the meta-check. Both directions matter here: a rule
  # that flagged the REFERENCE.md citations would have been "fixed" by
  # deleting true provenance.
  def test_meta_the_markdown_scan_catches_planted_violations
    Dir.mktmpdir do |dir|
      skill = File.join(dir, "SKILL.md")
      File.write(skill, "# Some skill\n\nRun `mix quality` in statifier-ex.\n")
      refute_empty Contract.consumer_vocabulary_anywhere(File.read(skill)),
                   "the markdown scan failed to catch a planted consumer constant in a SKILL.md"

      reference = File.join(dir, "REFERENCE.md")
      File.write(reference, <<~MD)
        Extracted from statifier-ex, whose `mix quality` ran this suite.

        ```json
        "deny": ["Edit(.quality.exs)", "Edit(.credo.exs)", "Edit(coveralls.json)"]
        ```

        ```sh
        mix quality
        ```
      MD

      hits = Contract.consumer_vocabulary_in_shell_fences(File.read(reference))
      refute_empty hits, "the command-block scan failed to catch a planted consumer command"
      assert_equal ["mix gate commands"], hits.map(&:last).uniq,
                   "the command-block scan flagged prose or a worked example, not just the command"
    end
  end
```

#### 3. Architecture pointer

**File**: `docs/architecture.md`
**Changes**: in the layer-1 paragraph (lines 25-32), after the sentence
listing what a generic skill may not contain, add one sentence naming the
enforcement site and the split, e.g.: "The contract test enforces this
mechanically over `skills/wurk:*/SKILL.md` (every line) and over the command
blocks of `skills/wurk:kit/REFERENCE.md`, which stays free to cite consumer
repos as provenance." Keep the file's existing ASCII punctuation.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes on the unmodified tree:
      `ruby skills/wurk:kit/scripts/test/run.rb`
- [x] Non-vacuity: `test_markdown_scans_cover_every_shipped_skill` passes and
      reports 14 skill directories worth of coverage (all `skills/wurk:*` have
      a SKILL.md).
- [x] Planted violation caught: `test_meta_the_markdown_scan_catches_planted_violations`
      passes.

#### Manual Verification:
- [ ] Sabotage check, run by hand and reverted (the "Manual Testing Steps"
      procedure below): appending `statifier-ex` to any
      `skills/wurk:*/SKILL.md` turns the gate red; appending `mix quality`
      inside REFERENCE.md's existing ` ```sh ` block at :46-48 turns it red;
      the untouched REFERENCE.md citations at :11, :12, :208, :264 and :410
      keep it green.
- [ ] The two failure messages tell a future author what to do (manifest or
      extension file for a constant; REFERENCE.md or an ADR for provenance),
      not just that a regex matched.
- [ ] `docs/architecture.md` still reads as architecture, not as a test
      changelog.
- [ ] `docs/manifest.md` and `scripts/test/fixtures/plans/real_grammar_snapshot.md`
      are untouched and unscanned, and the reason is findable at the
      enforcement site.
- [ ] No regressions in related features: the ADR-0006 drift check and the
      `.rb` scans behave as before.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Testing Strategy

### Unit Tests:

All tests live in `skills/wurk:kit/scripts/test/contract_test.rb`, matching the
file's existing two-class split: `ContractRulesTest` for the pure functions
against synthetic content, `ContractTest` for the real tree.

- Fence state machine: opener with a shell language, opener with a non-shell
  language, closing fence ends the block, unlabelled fence is not a command
  block, `~~~` fences behave like backtick fences.
- `consumer_vocabulary_anywhere`: hit in prose, hit in a heading (the
  `code_only` trap that motivated a separate line walk), hit in a code block.
- `consumer_vocabulary_in_shell_fences`: hit inside ` ```sh `, no hit for the
  same string in prose, in backticked inline code, or inside ` ```json `.
- Whole-tree: strict SKILL.md scan, REFERENCE.md command-block scan,
  non-vacuity, meta-test in both directions.

### Manual Testing Steps:

1. Run `ruby skills/wurk:kit/scripts/test/run.rb` on a clean tree; expect
   green.
2. Append `Use statifier-ex's bead prefix.` to `skills/wurk:commit/SKILL.md`;
   re-run; expect red naming that file and line. Revert.
3. Append `mix quality` inside the ` ```sh ` block at
   `skills/wurk:kit/REFERENCE.md:46-48`; re-run; expect red. Revert.
4. Append `Extracted from statifier-ex.` to REFERENCE.md prose and
   `"Edit(.credo.exs)"` inside its ` ```json ` block at :407-413; re-run;
   expect green (these are the citation shapes the rule protects). Revert.
5. Confirm `git status` is clean before committing the phase.

## References

- Bead: `wu-p82`
- Enforcement site: `skills/wurk:kit/scripts/test/contract_test.rb:138-169`
  (existing rule), `:380-390` (existing tree scan), `:407-425` (meta-test
  pattern), `:442-460` (drift-check pattern)
- Surfaces scanned: `skills/wurk:*/SKILL.md`, `skills/wurk:kit/REFERENCE.md`
  (citations at `:11`, `:12`, `:208`, `:264`, `:407-413`)
- Related ADRs: `docs/adr/0004-manifest-and-extension-seams.md` (constants
  come from the manifest or an extension),
  `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md` (script
  contract and the drift-check discipline),
  `docs/adr/0008-merge-time-judge-over-generic-skill-prose.md` (judgment over
  skill prose stays at the merge seam; this plan adds only mechanical checks)
- Project rules: `CLAUDE.md` hard rules, `docs/architecture.md:25-32`
- Prior plan that added the rule being extended:
  `docs/plans/260808-wu-gd1-gate-rb-manifest-driven-constants.md`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Sabotage check, mutated by hand and reverted: changing the fence regex
      to treat a closing fence as an opener turns
      `test_shell_fence_walk_stops_at_the_closing_fence` red.
- [ ] The comment block reads as the rule a future author would apply, not as
      a description of the code beneath it.
- [ ] Punctuation is plain ASCII and the style matches the surrounding file.
- [ ] No regressions in related features: the existing `.rb` rules are
      untouched and `Contract::CONSUMER_VOCABULARY` is unchanged.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 2

- [ ] Sabotage check, run by hand and reverted (the "Manual Testing Steps"
      procedure below): appending `statifier-ex` to any
      `skills/wurk:*/SKILL.md` turns the gate red; appending `mix quality`
      inside REFERENCE.md's existing ` ```sh ` block at :46-48 turns it red;
      the untouched REFERENCE.md citations at :11, :12, :208, :264 and :410
      keep it green.
- [ ] The two failure messages tell a future author what to do (manifest or
      extension file for a constant; REFERENCE.md or an ADR for provenance),
      not just that a regex matched.
- [ ] `docs/architecture.md` still reads as architecture, not as a test
      changelog.
- [ ] `docs/manifest.md` and `scripts/test/fixtures/plans/real_grammar_snapshot.md`
      are untouched and unscanned, and the reason is findable at the
      enforcement site.
- [ ] No regressions in related features: the ADR-0006 drift check and the
      `.rb` scans behave as before.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

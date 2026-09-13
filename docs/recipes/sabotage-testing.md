# Recipe: sabotage testing

Sabotage testing is a per-test discipline: before a new test is committed,
its author breaks the code it covers, watches the test go red, reverts the
break, and records the mutation in a one-line note above the test. A test
that cannot be made to fail is not testing anything, and the note is the
evidence that someone checked.

Wurk ships the scanner for the note (`gate.rb`'s sabotage scan, configured
by `gate.sabotage`) and nothing else. The discipline, the refusal
condition, and the decision about what an unverifiable declaration means
are consumer policy, stated in the consumer's own extension file. This
recipe is the discipline written out once so a new consumer does not have
to reconstruct it from the scanner's behavior, and the extension file it
ends with is the one that makes it binding.

## The protocol

For every new test declaration:

1. **Write the test and see it pass.**
2. **Break the code under test**, in the smallest way that the test's
   assertion should notice: flip a comparison, drop a branch, return a
   constant, off-by-one a bound. Not the test; the code.
3. **Run the test and see it fail.** If it stays green, the test is not
   load-bearing: fix the assertion, not the mutation, and go back to 2.
4. **Revert the break.** `git checkout -- <file>` or the editor's undo;
   the diff must be clean of it before commit.
5. **Write the note** in the comment block directly above the
   declaration, naming the mutation and the failure it produced.

The loop is a minute per test when done as the test is written and an
afternoon when done for a file after the fact, which is why the refusal
condition (below) is at commit time and not at review time.

**Recompile between mutations.** In a compiled or cached toolchain a
mutation that lands within the same mtime second as the previous build
can be served a stale artifact and pass falsely. Force a rebuild between
step 2 and step 3 when the toolchain caches (wu-9k4 tracks baking this
into the kit's guidance). Python's bytecode cache keys on source mtime
and size, so the same hazard exists in principle; `pytest -p no:cacheprovider`
or `PYTHONDONTWRITEBYTECODE=1` removes it for the mutation run.

## The two note forms

The discipline uses two shapes, in the contiguous comment block directly
above the declaration (a blank line breaks the block). The scanner checks
less than that: it matches the `# sabotage:` prefix, case-insensitively,
and nothing after it, so the shape of what follows is held by review, not
by the scan:

```
# sabotage: <what was broken> -> <what went red>
# sabotage: n/a - <why this declaration needs no mutation>
```

Real examples from this repo's own suite, which carries the discipline by
hand:

```ruby
# sabotage: read a hardcoded "main...HEAD" in gate_applicable? instead of
# manifest.default_branch -> red (FakeSh::UnexpectedCommand: no stub is
# registered for "main...HEAD" here, only for "trunk...HEAD")
def test_gate_applicable_diff_uses_the_manifests_default_branch
```

The first form names both halves because either alone is unverifiable
later: "broke the comparison" without the failure says nothing about
whether the test noticed, and "went red" without the mutation cannot be
repeated. The `n/a` form is for a declaration the pattern matches that is
not a test (a helper named `test_support`, a parametrized generator) or a
test whose subject is exhaustively covered by a sibling's mutation; the
reason must be readable by someone who disagrees.

In Python the comment syntax is the same `#`, so the shapes carry over
unchanged:

```python
# sabotage: return [] from parse_rules() -> red (assert len(rules) == 3
# fails with 0)
def test_parse_rules_reads_all_three():
```

## Enabling the scan

Two keys, present together or not at all (`docs/manifest.md`,
"`gate.sabotage`"):

```jsonc
"gate": {
  "sabotage": {
    "test_roots": ["tests/"],            // git pathspecs the scan diffs
    "test_pattern": "\\bdef test_",      // regex source for a declaration line
    "exempt_prefixes": ["tests/fixtures/"]   // (opt) never need a note
  }
}
```

`test_pattern` is the project's test framework's declaration shape, not a
default: `\bdef test_` for pytest and unittest, `\btest\s+"` for ExUnit,
`\bdef test_` or `\btest\s+"` for minitest depending on style. Match the
line that declares, not the body. One limit to know before choosing a
pattern: the scanner walks `#`-prefixed comment lines only, so a language
whose comments are `//` (Rust, Go, Swift, JavaScript) can adopt the
discipline but not the scan today; every declaration there would be
reported as missing whatever note it carries.

`test_roots` decides the scan's reach. `["tests/"]` scans every new
declaration under it; an enumerated list of files scopes the discipline to
a corpus (predicator-ex's binding tests, wu-4r7), at the cost that a new
test in an unlisted file is invisible to the scan.

The scan diffs the working tree against the merge base with the default
branch, so an uncommitted test is seen; an untracked file is reported as
`unverifiable` with reason `untracked` rather than scanned, because no
diff can see it.

## What the scanner reports, and what it never does

`gate.rb`'s envelope carries `data.sabotage` with `enabled`, `scanned`,
`missing` (declarations with no note) and `unverifiable` (declarations the
scan could not check, each with a reason). None of it flips `ok`. A
present note is not evidence the mutation was run; it is evidence a
comment of the right shape exists. The kit reports; the discipline is
yours.

Three states a reader must keep apart: `enabled: false` means the project
never configured the scan and an empty `missing` says nothing;
`scanned: false` means the scan ran and could check nothing (no base ref,
or the diff failed); `scanned: true` with empty `missing` and empty
`unverifiable` means everything was checked and everything had a note.

Known limits, each an open bead in this repo: a repo-level records file
instead of inline notes is not recognized (wu-vny); the untracked-file
half of wu-meh; the recompile guard above (wu-9k4).

## Making it binding: `.claude/wurk/commit.md`

`/wurk:commit` reads `data.sabotage` and does exactly what the project's
extension says; with no extension it names the missing entries in its
report and commits anyway. The extension that promotes the scan to a
refusal condition, in the shape statifier-ex uses:

```markdown
# /wurk:commit extension: sabotage discipline

## Refusal condition (the pre-commit-checks step, after reading the gate envelope)

Every new test declaration carries a `# sabotage:` note, in one of the two
forms `docs/recipes/sabotage-testing.md` in wurk describes. Refuse the
commit when:

- `data.sabotage.enabled` is `false` - the scan is misconfigured, and a
  commit made while it is off is a commit made without the discipline;
- `data.sabotage.missing` is non-empty - name each entry and stop;
- `data.sabotage.unverifiable` is non-empty - those declarations were not
  checked, so "every new test has a note" is not established for them.
  An `untracked` entry means the file is not yet `git add`ed: add it and
  re-run the gate. Any other reason is reported and the commit refused.

`scanned: false` is a refusal for the same reason as `enabled: false`.

The note is evidence of the protocol, not the protocol. A note whose
mutation would not turn the test red is a lie the scan cannot detect; the
reviewer of the request can, and `mr.review_agents` may include a test
critic that checks exactly this.
```

The choice about `unverifiable` is the one the kit refuses to make for
you (`docs/manifest.md`, "`gate.sabotage`"): the honest reading is that an
unchecked declaration is not a checked one. A project may choose a softer
line for `declaration_not_found`; it should say so in this file rather than
leave the skill to guess.

## Mutation tools and hand sabotage are complements

A mutation-testing tool (mutmut, cosmic-ray for Python; muzak for Elixir;
cargo-mutants for Rust) generates many mutations mechanically, runs the
whole suite against each, and reports the survivors. Hand sabotage does
one targeted mutation per new test, at the moment the test is written,
and records it.

They answer different questions. The tool answers "how much of the code
is any test sensitive to?" over the whole tree, slowly, and belongs in the
gate as its own stage when the project wants a floor on mutation score
(`docs/recipes/coverage.md` treats a floor the same way). The note answers
"did the author of this test check that it can fail?" per test, at commit
time, in seconds. A green mutation run does not excuse a missing note: the
tool's mutations may not touch the line the new test is about, and a
survivor report arrives long after the test's author has moved on. A note
does not excuse a low mutation score either.

A project that runs a tool declares it in `gate.full` (or a separate
long-running stage under `gate_run.rb`, since a full mutation run is
rarely under the foreground timeout) and adopts the note discipline
independently. Neither is configured by the other's keys.

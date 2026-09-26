# Invariant block scope fence derived from the plan Implementation Plan

## Overview

A consumer's campaign dispatched every worker under an invariant block
whose scope fence ("<path> untouched") was the PREVIOUS campaign's fence,
not its own. The new campaign's plan did not fence that path, one worker
obeyed the stale fence, and the bead cost a round. The generic dispatch
template gives a scope fence no home at all, so a conductor writes one
wherever it fits and, when it starts a campaign's `invariant-block.md`
from the last campaign's file, carries it forward without noticing.

This plan gives the fence one named home in the block - a SCOPE slot that
quotes its source lines verbatim from THIS campaign plan's `## Scope`
section and names the campaign it belongs to - and adds a read-only kit
check, `campaign_state.rb fence ID --block PATH`, that blocks when the
slot names another campaign, quotes a line the current plan's `## Scope`
does not contain, or cites a path the current plan's `## Scope` does not
name.

Bead: wu-wgoa

## Current State Analysis

- The dispatch template is `skills/wurk:conductor/SKILL.md`, "Appendix -
  dispatch template" (currently lines 1979-2063). Its slots are CONSENT,
  AUTHORITY (mode override, tracker push, worktree override, per-repo
  hazard), the moved-files slot, GATE, gate-semaphore, known-flake,
  MECHANICS, TIER, RETURN, REPORT. There is no scope or fence slot.
- "Carrying the block - once per campaign, not once per dispatch"
  (SKILL.md, currently lines 2065-2123) says the filled block is written
  once per campaign into `invariant-block.md` beside the journal, and
  lists what goes IN the file (AUTHORITY preamble, gate path,
  gate-semaphore, known-flake, MECHANICS, RETURN shape) and what stays
  per-dispatch. It says nothing about where the file's first draft comes
  from, so nothing forbids starting it from a predecessor's file - which
  is how the reported fence crossed campaigns.
- The Phase 3 bullet "Carry the invariant block by file, the consent by
  paste" (SKILL.md, currently lines 866-873) points at that appendix
  section.
- "A successor campaign - what a continuation inherits" (SKILL.md,
  currently lines 309-370) lists scope as never inherited and a by-name
  fence ("do not touch <bead>...") as inherited by default and restated.
  It does not say where a carried fence is written, so it reads as
  permission for a fence to live in the block independently of the plan.
- `skills/wurk:conductor/REFERENCE.md`, "The plan's sections - the rest
  of the schema" (currently lines 476-500): `## Scope` is required and is
  read by `campaign_state.rb` as the footprint multi-campaign rule 2
  compares. The template body is `writes: <paths...>` / `reads:
  everything else` (currently lines 623-626). The "Title the footprint
  section `## Scope`" rule is at currently lines 518-522.
- `skills/wurk:kit/scripts/campaign_state.rb`: `section(content, name)`
  (lines 232-251) returns the body of the first `## <name>...` heading,
  blank lines trimmed at both ends, indentation kept. Subcommands are
  `list show arm disarm` (lines 475-476); `run` (lines 479-520) dispatches
  on the id, and `--host` is already an arm-only option rejected for other
  subcommands with exit 2 (lines 498-501) - the pattern a fence-only
  `--block` follows. `locate` (lines 728-735) resolves an id to a plan
  path or blocks `campaign_not_found`.
- Tests: `skills/wurk:kit/scripts/test/campaign_state_test.rb` has a
  `CampaignFixtures` module (`write_plan` with a `default_body` carrying a
  `## Scope` section, lines 20-94), a pure-function class
  (`CampaignStateLibTest`) and a CLI class (`CampaignStateCliTest`,
  `run_cli`, `capture_exit`). One helper's comment (line 58) says earlier
  work left `write_plan` untouched and only added helpers.
- `lib/envelope.rb`: `block!(code:, message:, needs: "human")`, blocked
  is an array; `needs: "human"` is the only value any kit script uses.
- No manifest field is involved; `docs/manifest.md` and `lib/manifest.rb`
  are untouched.

## Desired End State

- The dispatch template carries a SCOPE slot, file-carried (it is
  campaign-constant), in a fixed grammar:

  ```
  SCOPE: campaign <id>, derived from `## Scope` in <absolute plan path>.
  | <line, verbatim from that section>
  | <line, verbatim from that section>
  Anything written outside those lines is stop-and-report. This fence is
  re-derived from this campaign's plan whenever the block is written; it
  is never carried from an earlier campaign's block.
  ```

- The appendix's carrying section says: the file is written fresh from
  this template for every campaign, never started from a predecessor's
  `invariant-block.md`; the SCOPE slot is the ONLY place the block states
  a scope fence; a path the conductor wants fenced goes into the plan's
  `## Scope` first and the block quotes it; and the conductor runs
  `campaign_state.rb fence` after writing the file and after any
  `[adoption]` change to it, before the next dispatch.
- The successor section says a carried by-name fence is written into the
  successor plan's `## Scope` (so the block can quote it), never into the
  block directly.
- `ruby ~/.claude/skills/wurk:kit/scripts/campaign_state.rb fence <id>
  --block <path> [--dir DIR]` is a read-only subcommand that exits 0 when
  the SCOPE slot matches the plan and exits 1 with one blocked entry per
  finding otherwise. REFERENCE.md documents it and its grammar.

Verify: the kit suite passes; a block copied from another campaign, a
block with an extra fence path, and a block quoting a line the plan does
not contain each come back blocked from the new subcommand.

### Key Discoveries:
- `section()` already gives the check the plan side for free
  (`campaign_state.rb:232-251`); `locate` gives it id resolution
  (`campaign_state.rb:728-735`).
- `--host` being arm-only (`campaign_state.rb:498-501`) is the in-file
  precedent for a subcommand-only flag with a usage exit.
- `report_check.rb` (commit 5fd85bd, wu-isro) is the precedent for a
  conductor-run kit check over campaign state whose blocked message names
  the fix; the conductor then fixes its own artifact.
- ADR-0006 (stdlib Ruby scripts with the envelope contract) bounds the
  check's shape.
- The block lives in campaign state (excluded, never committed), at a
  path "beside the journal" that varies per consumer, so the check takes
  it as a required `--block` argument rather than deriving a default.

## What We're NOT Doing

- Not checking fences written OUTSIDE the SCOPE slot. The check cannot
  tell a scope fence in, say, the per-repo hazard slot from a legitimate
  path (lock dirs, the kit path, a report path) without a grammar for
  every slot. The skill prose makes the SCOPE slot the only place a fence
  may be stated, and the check enforces that slot; a conductor that
  writes a fence elsewhere breaks a prose rule the check does not see.
  This is the "if mechanizable" limit, stated honestly.
- Not generating the SCOPE slot mechanically (a `campaign_state.rb`
  subcommand that emits the filled slot). Filling the block is the
  conductor's work under the appendix; a check is enough to stop the
  failure, and an emitter would be a second definition of the template.
- Not checking the per-dispatch slots or the CONSENT paragraph.
- Not touching the trailing "Slots filled per dispatch" list at the end
  of the appendix, which predates the carrying section and still lists
  campaign-constant slots (gate path, semaphore, flakes) as per-dispatch.
  That inconsistency is real but separate; it is not this bead's bug.
- Not changing the manifest, `docs/manifest.md`, or any consumer file.
- Not checking that the SCOPE header's plan path equals the located
  plan's path: a campaigns dir can be reached through a symlink, and the
  campaign-id check already catches a copied header.
- Not running the check from any script automatically; the conductor
  runs it, as it runs `report_check.rb`.

## Implementation Approach

Two phases. Phase 1 is the mechanism: a pure function plus the `fence`
subcommand, its tests, and REFERENCE.md's subcommand and schema text in
the same commit (code is authority, doc follows in the same commit).
Phase 2 is the rule: the conductor SKILL.md template slot, the carrying
section, the Phase 3 bullet and the successor section, all citing the
Phase 1 subcommand by name. Phase 1 is independently useful and
gate-verified; Phase 2 is doc-only and leaves the gate green.

The check's grammar (defined in Phase 1, used in Phase 2):

- **The slot** is the paragraph starting at the first line of the block
  file that begins `SCOPE:` in column 1 and ending at the next blank line
  or end of file.
- **The header** is that first line; it must match
  `SCOPE: campaign <id>` (the id is the next whitespace-delimited token,
  trailing `,` or `.` stripped).
- **Source lines** are the slot's lines whose first non-blank character
  is `|`; the text after `|` and one optional space, stripped, is the
  quoted line. A quoted line that is empty after stripping is ignored.
- **Path tokens** are the whitespace-delimited tokens on the slot's other
  lines (not the header, not source lines) that contain `/`, after
  stripping surrounding backticks, quotes, and parentheses and trailing
  `.,;:`.
- **The plan side** is `section(plan, "Scope")`, compared line by line
  after stripping each line.

Findings, each a blocked entry (`needs: "human"`, the kit's only value;
the message ends with a `Fix:` clause naming the re-derivation):

| code | when |
|---|---|
| `invariant_block_missing` | `--block` names no readable file |
| `scope_missing` | the plan has no `## Scope` section |
| `fence_missing` | the block has no `SCOPE:` paragraph |
| `fence_wrong_campaign` | the header names a campaign id other than ID (names both) |
| `fence_unsourced` | the slot has no non-empty source line |
| `fence_line_not_in_plan` | a source line is not a stripped line of the plan's `## Scope` (one entry per line) |
| `fence_path_not_in_plan` | a path token is not a substring of the plan's `## Scope` body (one entry per path) |

`campaign_not_found` comes from `locate` as for `show`. The first three
short-circuit (nothing further can be read); the last four are all
reported together so one run lists every stale line.

## Phase 1: The `fence` check in campaign_state.rb

### Overview
Add a pure `CampaignState.fence_findings` and a read-only `fence ID
--block PATH` subcommand, with tests, and document both in REFERENCE.md.

### Changes Required:

#### 1. Pure function
**File**: `skills/wurk:kit/scripts/campaign_state.rb`
**Changes**: Add, in the `CampaignState` singleton near `section`:

```ruby
# The SCOPE slot of an invariant block, checked against a plan's ## Scope
# body. Returns {campaign:, source_lines:, paths:, findings: [{code:,
# message:}]}; findings is empty when the slot is derived from this plan.
def fence_findings(block_content, id, scope_body)
  # parse slot per the grammar in REFERENCE.md "fence ID --block PATH";
  # fence_missing / fence_wrong_campaign / fence_unsourced /
  # fence_line_not_in_plan / fence_path_not_in_plan
end
```

Constants for the header and source-line regexes sit beside the existing
ones (`SCOPE_HEADER = /\ASCOPE:[ \t]*campaign[ \t]+(\S+)/`, trailing
`,`/`.` stripped from the capture; `SCOPE_SOURCE = /\A[ \t]*\|[ ]?(.*)\z/`).
Update the module comment (lines 12-33) to say `fence` also reads one
invariant-block file named on the command line, and still writes nothing.

#### 2. Subcommand
**File**: `skills/wurk:kit/scripts/campaign_state.rb`
**Changes**:
- `SUBCOMMANDS` gains `fence`; `USAGE` gains `fence ID --block PATH`.
- `Cli.build` gains `opts.on("--block PATH", "fence only: the
  invariant-block.md to check")`.
- Usage exit 2 when `--block` is given to any other subcommand (the
  `--host` pattern) and when `fence` is called without `--block`.
- `run_fence(env, options, id, io, this_machine)`: `locate` the plan;
  read `--block` (missing or unreadable -> `invariant_block_missing`);
  `section(plan, "Scope")` (nil -> `scope_missing`); call
  `fence_findings`; `env.block!` each finding; set `data.fence =
  {block_path:, plan_path:, campaign:, source_lines:, paths:}`; emit.
  Never writes; `--dry-run` is accepted (Cli) and changes nothing.

#### 3. Tests
**File**: `skills/wurk:kit/scripts/test/campaign_state_test.rb`
**Changes**: additions only (following that helper's precedent). A
`write_block(dir, content)` helper and a new `CampaignStateFenceTest`
class (tmpdir fixtures, `run_cli`, `capture_exit` as the CLI class does).
Fixture paths are neutral (`lib/widgets`, `vendor/old-engine`) - no
consumer path. Cases:
- a block quoting the plan's `## Scope` lines verbatim, header naming the
  id -> exit 0, `data.fence.source_lines` and `data.fence.campaign` set,
  `blocked` empty;
- quoted lines with different leading indentation from the plan's
  indented body still match;
- a note line citing a path the plan's Scope names (backticked) -> ok;
- **the reported bug**: correct header and source lines plus a line
  `vendor/old-engine untouched` the plan does not name ->
  `fence_path_not_in_plan` naming `vendor/old-engine`, exit 1;
- a block whose header names another campaign id (a predecessor's
  copied file) -> `fence_wrong_campaign` naming both ids;
- a source line not in the plan -> `fence_line_not_in_plan`; two such
  lines -> two entries;
- no `|` lines -> `fence_unsourced`;
- no `SCOPE:` paragraph -> `fence_missing`;
- `--block` path absent -> `invariant_block_missing`;
- plan without `## Scope` -> `scope_missing`;
- unknown id -> `campaign_not_found`;
- `fence ID` without `--block` -> exit 2; `show ID --block x` -> exit 2;
- the block file and the plan are byte-identical after a run (read-only).
Pure-function tests in `CampaignStateLibTest` for the slot ending at a
blank line (a path after the blank line is NOT checked) and for token
stripping (`` `a/b`. `` -> `a/b`).

#### 4. Reference
**File**: `skills/wurk:conductor/REFERENCE.md`
**Changes**:
- "Subcommands": a `fence ID --block PATH` bullet - read-only, the
  grammar above, the finding codes, `data.fence`, exit codes, and that
  the check covers the SCOPE slot only.
- "The plan's sections" table, `## Scope` row "Who reads it": add "and
  `campaign_state.rb fence`, which checks the invariant block's SCOPE
  slot against it".
- "Title the footprint section `## Scope`" rule: one sentence that
  `fence` reads the same heading, so a `## Footprint` plan also fails
  the fence check with `scope_missing`.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb`
- [x] `contract_test.rb` passes unchanged (envelope shape, no banned operations)
- [x] The new fence tests exist and pass, including the stale-fence case asserting `fence_path_not_in_plan`
- [x] `grep -n "fence ID --block PATH" skills/wurk:conductor/REFERENCE.md` finds the subcommand bullet

#### Manual Verification:
- [ ] Sabotage: delete the path-token check in `fence_findings`, run the suite, confirm the stale-fence test goes red, restore
- [ ] Run `campaign_state.rb fence` by hand against a scratch campaigns dir with a copied predecessor block and read the blocked messages - each names the offending line or path and a `Fix:`
- [ ] REFERENCE.md's grammar text matches the regexes in the code
- [ ] No regressions in `list`/`show`/`arm`/`disarm`

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: The SCOPE slot and derivation rule in the conductor skill

### Overview
Put the SCOPE slot into the dispatch template, make the carrying section
say where the fence comes from and when the check runs, and reconcile
the successor section's by-name fence with it. Doc-only.

### Changes Required:

#### 1. Template slot
**File**: `skills/wurk:conductor/SKILL.md`, "Appendix - dispatch template"
**Changes**: Insert the SCOPE slot (grammar in Desired End State) as its
own paragraph after the AUTHORITY paragraph and before the moved-files
slot, as a fill-me slot in the template's existing `<...>` style, saying
the source lines are copied verbatim from THIS plan's `## Scope`.

#### 2. Carrying section
**File**: `skills/wurk:conductor/SKILL.md`, "Carrying the block - once
per campaign, not once per dispatch"
**Changes**:
- Add the SCOPE slot to the "What goes IN the file" list.
- A new paragraph, "The SCOPE slot is derived, never carried": the
  incident in generic terms (a campaign's block carried its
  predecessor's "<path> untouched" fence and a worker lost a round
  obeying a fence the new plan never drew); the file is written fresh
  from this appendix for every campaign, never started from an earlier
  campaign's `invariant-block.md`; the SCOPE slot is the only place the
  block states a scope fence - a path to fence goes into the plan's
  `## Scope` first and the block quotes it; then run

      ruby ~/.claude/skills/wurk:kit/scripts/campaign_state.rb fence <id> --block <absolute path to invariant-block.md>

  after writing the file at wave zero and after every `[adoption]`
  change to it, before the next dispatch. A blocked result is fixed by
  re-deriving the slot from the plan, not by editing the plan to match
  the block unless the operator's scope actually says so; journal the
  check's result with the wave-zero entries. State the limit: the check
  sees only the SCOPE slot.

#### 3. Phase 3 bullet
**File**: `skills/wurk:conductor/SKILL.md`, the "Carry the invariant
block by file, the consent by paste" bullet
**Changes**: one sentence: the file is written fresh per campaign, its
SCOPE slot quotes this plan's `## Scope`, and `campaign_state.rb fence`
passes before the first dispatch.

#### 4. Successor section
**File**: `skills/wurk:conductor/SKILL.md`, "A successor campaign - what
a continuation inherits"
**Changes**: under the by-name fence bullet, one sentence: a carried
fence is written into the successor plan's `## Scope` (and its
`## Inheritance` reading), and the successor's block quotes it from
there like any other scope line - never copied from the predecessor's
block.

#### 5. Reference cross-link
**File**: `skills/wurk:conductor/REFERENCE.md`, the `## Scope` rule
**Changes**: if Phase 1's sentence does not already, point at the
appendix's carrying section by name.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb`
- [ ] `grep -n "^SCOPE: campaign" skills/wurk:conductor/SKILL.md` finds the slot inside the appendix template
- [ ] `grep -n "campaign_state.rb fence" skills/wurk:conductor/SKILL.md` finds the carrying section's command
- [ ] `git diff main -- skills/wurk:conductor | ruby -ne 'print if /^\+/ && !$_.ascii_only?'` prints nothing (plain ASCII in added lines)

#### Manual Verification:
- [ ] The template's SCOPE slot text parses under the Phase 1 grammar when filled (paste a filled copy into a scratch block and run `fence` against a scratch plan)
- [ ] No step number is cited from outside a skill; cross-references use section names
- [ ] No consumer path, bead prefix or campaign id appears in the new prose
- [ ] The successor section's by-name fence rule and the new derivation rule read as one rule, not two in tension

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
- `CampaignStateLibTest`: `fence_findings` on slot boundaries, token
  stripping, indentation-insensitive line matching, empty source lines.
- `CampaignStateFenceTest` (new class, same file): every finding code
  through the envelope, the ok path, usage exits, read-only guarantee.
- Key edge cases: a fenced path that IS in the plan's Scope passes; a
  path after the slot's terminating blank line is ignored; the stale
  predecessor block is caught both by header (wrong id) and, when the
  header was re-typed, by its path.

### Manual Testing Steps:
1. In a scratch dir, write plan `a.md` (Scope: `writes: lib/widgets`)
   and `b.md` (Scope: `writes: lib/gadgets`, `reads: vendor/old-engine
   untouched`), plus consent files.
2. Write b's block per the template, plus a note line `vendor/old-engine untouched` under the source lines; `fence b --block b-block.md` -> ok (b's Scope names that path).
3. Copy b's block as a's; `fence a --block a-block.md` ->
   `fence_wrong_campaign`, `fence_line_not_in_plan`.
4. Fix the header only; re-run -> `fence_line_not_in_plan` and
   `fence_path_not_in_plan` for `vendor/old-engine`.

## Decisions taken without a human

No human was reachable while this plan was written; each call below was
made by the planner and is open to reversal at review.

1. **Mechanized, as a `campaign_state.rb` subcommand, not a new script.**
   It reuses `locate` and `section` and the same `--dir` resolution;
   a separate script would re-implement both. Reversal cost: small.
2. **The check covers the SCOPE slot only.** A fence written into
   another slot is caught by prose, not the check (see What We're NOT
   Doing). Making every slot parseable is a much larger change.
3. **A negative fence must be in the plan too.** "Cites a path the
   current plan does not name" is read literally: a path the block says
   is untouched has to appear in the plan's `## Scope` (e.g. on its
   `reads:` line). This makes the plan the single source, which is the
   bead's point.
4. **Path heuristic: a token containing `/`.** Bare top-level names
   without a slash (`Makefile`) are not treated as paths by the path
   check; they are still covered when quoted as source lines.
5. **`needs: "human"` on every finding**, because it is the kit's only
   value, even though the conductor fixes its own block; the `Fix:`
   clause in each message says so.

## References

- Source: bead `wu-wgoa` (acceptance criteria)
- Related ADRs: `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`
- Similar implementation: `skills/wurk:kit/scripts/campaign_state.rb:498-501` (`--host`, a subcommand-only flag); `report_check.rb` (commit 5fd85bd, a conductor-run check over campaign state)
- Conductor sections: SKILL.md "Appendix - dispatch template", "Carrying the block - once per campaign, not once per dispatch", "A successor campaign - what a continuation inherits"; REFERENCE.md "Subcommands", "The plan's sections - the rest of the schema"
- Bead: `wu-wgoa`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Sabotage: delete the path-token check in `fence_findings`, run the suite, confirm the stale-fence test goes red, restore
- [ ] Run `campaign_state.rb fence` by hand against a scratch campaigns dir with a copied predecessor block and read the blocked messages - each names the offending line or path and a `Fix:`
- [ ] REFERENCE.md's grammar text matches the regexes in the code
- [ ] No regressions in `list`/`show`/`arm`/`disarm`

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

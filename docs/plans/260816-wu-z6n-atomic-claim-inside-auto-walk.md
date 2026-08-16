# Atomic claim inside the auto walk Implementation Plan

## Overview

Close the read-then-claim race in `/wurk:next --auto` by having
`select_batch.rb` claim each bead at the moment the greedy walk takes it,
treating a contended claim as a named skip and walking on. Manual mode stays
report-only and `/wurk:next`'s interactive select-then-claim with its
`bd_claim_failed` fallback is unchanged. This implements ADR-0012 exactly;
the direction is settled and is not re-opened here. Beads issue: `wu-z6n`

## Current State Analysis

**`skills/wurk:kit/scripts/select_batch.rb`** (370 lines) is report-only
today:

- `run/2` (lines 31-76) parses args, lists candidates, surveys live
  worktrees, annotates verdicts, calls `walk(candidates, options[:n])`
  (line 66) and emits. It never mutates anything.
- The header comment (lines 20-26) states flatly "This script never claims a
  bead and never creates a worktree". After this change that sentence is
  only true of manual mode.
- `--dry-run` is parsed (line 102, into `options[:dry_run]`) and then never
  read anywhere in the file. It is inert.
- `walk/2` (lines 286-349) is a pure function over the annotated candidate
  list: it takes `free` candidates whose areas are disjoint from
  `batch_areas`, takes a `lands-alone` candidate only into an empty batch
  and then `break`s with `alone = true`, and records every other candidate
  into `skipped` with a reason string. `ceiling_hit` (line 320) is computed
  from `alone`, `recommended.length` and `idx`, and the post-loop block
  (lines 327-346) assigns `unreached_reason` to everything the walk never
  reached.
- Sub-script calls already follow one shape: run the other script into a
  `StringIO`, `JSON.parse` it, `env.commands.concat(parsed["commands"])`,
  then branch on `parsed["ok"]` (see `explicit_candidates/2` lines 165-181,
  `bead_ready/2` lines 183-196, `held_areas_map/1` lines 200-219). The claim
  call has a ready-made template here.

**`skills/wurk:kit/scripts/bead.rb`** already has the exact primitive
needed. `run_claim/2` (lines 168-193) builds `["bd", "update", id,
"--claim", "--json"]`, honors `--dry-run` by pushing `Sh.render(cmd)` into
`commands` and setting `data.claimed = nil` without shelling out, and on
failure emits `blocked` code `bd_claim_failed` with bd's stderr as the
message. No change to `bead.rb` is needed.

**`skills/wurk:next/SKILL.md`** (375 lines):

- Step 1 (lines 131-203) says "**Nothing is claimed by this call** - it only
  reports" (line 140), unqualified by mode.
- Step 2's auto paragraph (lines 245-248) takes `data.recommended` as-is.
- Step 4 (lines 258-291) is the claim loop: `bead.rb claim <id>` per bead,
  the `bd_claim_failed` drop-and-report fallback (lines 268-271), the
  override note (lines 273-282, manual only), then one `bead.rb sync push`
  for the batch (lines 284-291).
- Guidelines (lines 343-375) restate "claim the whole batch before creating
  any workspace" and "manual mode presents, it does not impose".

**`skills/wurk:kit/scripts/test/select_batch_test.rb`** (412 lines) drives
everything through `FakeSh` (`test/support/fake_sh.rb`) plus the
`areas_wide` fixture manifest. `FakeSh#run` raises `UnexpectedCommand` on
any argv no expectation matched, so "the script must not shell out to X" is
already assertable by simply not registering X, and `@fake.calls` records
every argv for positive assertions.

**The gate** is exactly `ruby skills/wurk:kit/scripts/test/run.rb`.
`test/contract_test.rb` enforces ADR-0006's banned-operation list (`git
push`, `gh pr create`, `glab mr create`, `bd close`, `bd edit`) over every
file under `scripts/`. A claim is `bd update`, which is on none of those
lists, so no contract rule is touched or weakened. `contract_test.rb`
contains no mechanical `--dry-run` rule, so the dry-run behavior has to be
proved by `select_batch_test.rb` itself.

**bd, verified on the installed binary (bd 1.1.2, Homebrew, 2026-08-16):**
`bd update --help` documents `--claim` as "Atomically claim the issue (sets
assignee to you, status to in_progress; idempotent if already claimed by
you)". A failing `bd update <id> --claim --json` exits 1 with a plain-text
message on **stderr** and empty stdout (verified with a nonexistent id:
`Error resolving wu-zzzzz: no issue found matching "wu-zzzzz"`).
`bead.rb`'s `err_or/2` already lifts that stderr into the
`bd_claim_failed` message, which settles ADR-0012's open question - see
"Implementation Approach" below.

## Desired End State

`ruby skills/wurk:kit/scripts/select_batch.rb --auto` claims every bead it
puts in `data.recommended`, at the moment the walk takes it, and nothing
else. A bead that cannot be claimed appears in `data.skipped` with a
contention reason, a `claim_contended` warning rides in `warnings`, `ok`
stays `true`, and the walk continues to the next legal candidate up to `n`.
`--auto --dry-run` claims nothing and renders each would-be
`bd update <id> --claim --json` into `commands`. A run without `--auto`
executes no `bd update` at all, dry or not. `/wurk:next` auto mode reports
claims from that envelope instead of running its own claim loop; the manual
path is byte-for-byte unchanged apart from the mode qualifiers it needs to
stay true.

Verify by: the kit suite green; the new `select_batch_test.rb` cases
asserting the exact `bd update ... --claim` calls made and not made; and a
live `select_batch.rb --auto --dry-run` in a real checkout showing the claim
commands in `commands` with no bead's status changed.

### Key Discoveries:

- ADR-0012 is accepted and is the authority for every design call here; it
  also rejects claim-then-release-the-losers and direct `bd ready --claim`
  with reasons that are not re-argued in this plan.
- `select_batch.rb:66` is the single seam: `walk` is the only place a
  candidate becomes `recommended`, so claim-at-take is one call site plus
  one branch, not a restructure.
- `bead.rb:168-193` gives claim, dry-run claim, and a stderr-bearing failure
  message for free. Passing `--dry-run` straight through to it is what makes
  `select_batch.rb --dry-run` meaningful with no new rendering code.
- `select_batch.rb:165-219` fixes the sub-script call shape (StringIO,
  `JSON.parse`, `env.commands.concat`, branch on `ok`) that the claim call
  must follow.
- `FakeSh` raising on unregistered argv (`test/support/fake_sh.rb:54-57`)
  means "manual mode claims nothing" is provable, not merely asserted.
- ADR-0009's `upstream` verdict must keep never entering `recommended`;
  since the claim hangs off the take step, an `upstream` bead is still never
  claimed, in either mode.
- ADR-0008's merge-time prose judge scopes `skills/**/SKILL.md`. Phase 3 is
  exactly the diff shape it hunts - a claim step in prose being handed to a
  script - so the phase keeps the policy prose in the skill and cites
  ADR-0012 in the text and in the commit body.

## What We're NOT Doing

- Not touching `bead.rb`. `claim` already does everything needed, including
  `--dry-run`.
- Not adopting `bd ready --claim` and not implementing
  claim-then-release-the-losers. Both are rejected in ADR-0012.
- Not adding a release/un-claim path. Wurk still has no un-claim primitive,
  and ADR-0012's crash analysis says claim-in-walk does not need one: a
  crash strands only beads that were claimed on purpose, the state
  `/wurk:next` already reports with a release command.
- Not changing manual mode's behavior, its picker, its override path, or its
  `bd_claim_failed` fallback.
- Not changing `data`'s key set. `recommended`, `skipped`, `ceiling_hit`,
  `alternatives`, `mode`, `n`, `candidates` stay as they are; in auto mode
  `recommended` simply now means "recommended and claimed" (ADR-0012). No
  `data.claimed` key is added: a caller already knows from `data.mode`, and a
  second list of the same ids invites the two drifting apart.
- Not weakening `contract_test.rb`. Nothing in this change comes near the
  banned-operation list.
- Not adding a retry or a second pass over contended beads. A contention is a
  skip, once, and the report says so.
- Not touching `/wurk:work`'s own `bead.rb claim` (SKILL.md:134,160). A
  second claim of a bead this session already claimed is idempotent per bd's
  own `--claim` documentation.
- Not adding a `select_batch.rb` entry to `skills/wurk:kit/REFERENCE.md`.
  REFERENCE.md documents the shared contract and two named scripts
  (`gate.rb`, `judge.rb`); it carries no per-script catalog, so there is no
  existing text about this script to keep true.

## Implementation Approach

Three phases, in order, each independently committable and each green on
`ruby skills/wurk:kit/scripts/test/run.rb` on its own.

Phase 1 lands the direction record and this plan, so the two later phases
have a committed authority to cite. Phase 2 does the whole behavior change -
script and tests together, because the tests are what makes the script
change gate-verifiable and neither half is meaningful alone. Phase 2 is the
big one: besides six new cases it has to update the twelve existing
auto-mode cases whose walks now claim, since `FakeSh` raises on any
unauthorized command and the script's new correct behavior is exactly such a
command. Phase 3 updates
`/wurk:next`'s prose to match.

Phase 2 landing before Phase 3 is deliberate and safe: in the intermediate
state auto mode claims inside selection *and* `/wurk:next` step 4 claims
again, which bd defines as idempotent for a claim you already hold. The
reverse order would leave a window where nobody claims at all, so the order
is a real constraint, not a preference.

**ADR-0012's open question is resolved, not carried.** The question was
whether bd's claim failure distinguishes "claimed by someone else" from
other errors. The resolution does not depend on the answer: the skip reason
embeds bd's own failure message verbatim (via `bead.rb`'s existing
`bd_claim_failed` message, which is bd's stderr), so whatever bd chooses to
say ends up in the report without the kit having to classify it. The reason
string is worded to cover both ("claim failed - ..."), and the warning code
is `claim_contended` because contention is the case operators act on.

## Phase 1: Land the direction record

### Overview

ADR-0012 and this plan document are both untracked in the working tree.
Commit them first so Phases 2 and 3 cite a committed record rather than a
file that only exists locally.

### Changes Required:

#### 1. Direction record and plan

**File**: `docs/adr/0012-atomic-claim-inside-auto-walk.md`,
`docs/plans/260816-wu-z6n-atomic-claim-inside-auto-walk.md`
**Changes**: Add both files as they stand. Do not edit ADR-0012's content -
it is accepted, and this phase is a `git add`, not a revision.

Commit title: `Adds ADR-0012 and the wu-z6n plan` (37 chars).

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes (`ruby skills/wurk:kit/scripts/test/run.rb`)
- [x] `git ls-files docs/adr/0012-atomic-claim-inside-auto-walk.md` prints
      the path (the ADR is tracked)
- [x] `ruby skills/wurk:kit/scripts/plan_state.rb validate docs/plans/260816-wu-z6n-atomic-claim-inside-auto-walk.md`
      reports `data.sections_missing` empty

#### Manual Verification:
- [ ] ADR-0012's committed text is identical to the accepted version - no
      incidental edits rode along
- [ ] The commit contains only these two documents

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: Claim at take inside the auto walk

### Overview

`select_batch.rb` claims each bead as the walk takes it, in auto mode only;
a failed claim becomes a named skip and the walk continues; `--dry-run`
becomes meaningful; the header comment narrows. The new
`select_batch_test.rb` cases land in the same commit - they are what makes
the change gate-verifiable, and the script change without them would pass
the gate while proving nothing.

### Changes Required:

#### 1. The greedy walk gains an auto-only claim step

**File**: `skills/wurk:kit/scripts/select_batch.rb`
**Changes**: thread `env` and the two flags into `walk`, add a `claim_take`
helper following the existing sub-script call shape, branch both take sites
(`lands-alone` and `free`) through it, and narrow the header comment.

```ruby
# run/2, replacing the current call at line 66
walked = walk(candidates, options[:n], env, claim: options[:auto], dry_run: options[:dry_run])
```

```ruby
# new private helper, modeled on explicit_candidates/2 and bead_ready/2
#
# Returns nil when the bead is (or would be) claimed, and the failure
# message when the claim was refused. In manual mode it is never called.
# --dry-run is passed straight through to bead.rb claim, which renders the
# command into its own `commands` without shelling out - that is what makes
# a dry auto run claim nothing while still reporting what it would claim.
def claim_take(id, env, dry_run:)
  argv = ["claim", id]
  argv << "--dry-run" if dry_run

  io = StringIO.new
  Bead.run(argv, io: io)
  parsed = JSON.parse(io.string)
  env.commands.concat(parsed["commands"] || [])
  return nil if parsed["ok"]

  message = (parsed["blocked"] || []).map { |b| b["message"] }.join("; ")
  message.empty? ? "bd update --claim failed" : message
end
```

```ruby
# walk/5: both take sites go through the same guard.
def walk(candidates, n, env, claim: false, dry_run: false)
  ...
  when "lands-alone"
    if recommended.empty?
      failure = claim ? claim_take(c[:id], env, dry_run: dry_run) : nil
      if failure
        # A contended lands-alone candidate does not take the batch: the
        # alone state is never entered and the walk resumes normally
        # (ADR-0012's implementation detail).
        skipped << { "id" => c[:id], "reason" => contention_reason(failure) }
        env.warn(code: "claim_contended", message: "#{c[:id]}: #{failure}")
      else
        recommended << c[:id]
        alone = true
        break
      end
    else
      ...
    end
  else # "free"
    overlap = batch_areas & c[:areas]
    if overlap.empty?
      failure = claim ? claim_take(c[:id], env, dry_run: dry_run) : nil
      if failure
        skipped << { "id" => c[:id], "reason" => contention_reason(failure) }
        env.warn(code: "claim_contended", message: "#{c[:id]}: #{failure}")
      else
        recommended << c[:id]
        batch_areas |= c[:areas]
      end
    else
      ...
    end
  end
end

def contention_reason(failure)
  "claim failed - taken by another session since listing (bd: #{failure})"
end
```

Notes that must hold in the final code:

- The claim happens **after** the candidate is judged legal and **before**
  it is appended to `recommended` or unioned into `batch_areas`. A contended
  bead must not consume the batch's area budget.
- `ceiling_hit` keeps its current meaning: it is computed from `alone`,
  `recommended.length` and `idx` after the loop, and a contention skip
  leaves `recommended` short, so a contended run reports the same way a
  collision-heavy run does.
- Contention never blocks and never flips `ok`. `bead.rb`'s `blocked` entry
  lives in its own envelope; only its message crosses into this one.

**Changes**: the header comment (lines 20-26) narrows from "This script
never claims a bead" to a mode-qualified statement, citing ADR-0012, and
keeping the rest of the paragraph (recommendation-not-outcome, the picker
lives in the skill, ADR-0009's `upstream` verdict) as written. The usage
string (line 130) gains `[--dry-run]`.

#### 2. Test coverage for claim, contention, dry-run and manual

**File**: `skills/wurk:kit/scripts/test/select_batch_test.rb`
**Changes**: five new cases, each with a `# sabotage:` note above it
matching the file's existing convention (see the `zz-sdv` block at lines
331-411). Register claim expectations with the prefix
`["bd", "update", "<id>", "--claim"]`; assert the negative cases against
`@fake.calls` rather than only relying on `FakeSh` raising.

```ruby
# sabotage: drop the claim_take call from the "free" branch -> red, no
# bd update call is recorded for either recommended bead
def test_auto_claims_exactly_the_beads_the_walk_took
  # two free beads in disjoint areas plus one that collides in-batch;
  # assert bd update --claim appears for the two taken ids and for no
  # other id.
end

# sabotage: treat a failed claim as a take (ignore claim_take's return)
# -> red, the contended bead appears in recommended
def test_contended_claim_skips_and_the_walk_continues
  # zz-a's claim expectation exits 1 with stderr; zz-b's succeeds.
  # recommended == ["zz-b"], skipped names zz-a with the contention
  # reason, warnings carries claim_contended, ok stays true, exit 0.
end

# sabotage: union zz-a's areas into batch_areas before the claim ->
# red, zz-b (sharing an area with zz-a) is skipped as an in-batch
# collision instead of being taken
def test_contended_bead_does_not_consume_the_batch_area_budget
end

# sabotage: drop the `--dry-run` passthrough in claim_take -> red,
# FakeSh raises on an unauthorized bd update
def test_dry_run_auto_claims_nothing_and_renders_the_claim_commands
  # no bd update expectation registered; assert @fake.calls has no
  # ["bd", "update", ...] entry and env["commands"] includes
  # "bd update zz-a --claim --json".
end

# sabotage: call claim_take unconditionally (drop the `claim` guard) ->
# red, FakeSh raises on an unauthorized bd update in manual mode
def test_manual_mode_executes_no_claim
end
```

A sixth case covers the lands-alone detail:

```ruby
# sabotage: on a contended lands-alone candidate, still set alone = true
# and break -> red, the following free bead is never taken
def test_contended_lands_alone_candidate_voids_alone_and_the_walk_resumes
  # zz-bld (area:build, claim refused) then zz-int (area:alpha):
  # recommended == ["zz-int"], and zz-bld's skip reason is the
  # contention reason, not "lands alone".
end
```

#### 3. Every existing auto-mode test that reaches the take step

**File**: `skills/wurk:kit/scripts/test/select_batch_test.rb`
**Changes**: this is the bulk of the phase's test work, not an afterthought.
`FakeSh#run` raises `UnexpectedCommand` on any argv no expectation matched
(`test/support/fake_sh.rb:54-57`), so the moment the walk starts claiming,
**every existing `--auto` test whose fixture produces a non-empty
`data.recommended` raises** - the script doing its job correctly is what
breaks them. They must be updated in this same commit or the phase gate is
red.

Add one helper next to `expect_ready`:

```ruby
# Auto mode claims at take (ADR-0012), so every auto test whose walk takes
# a bead must authorize that bead's claim. Registering it per id rather
# than as a blanket prefix keeps FakeSh's "unauthorized command" raise as
# the check that the script claims exactly what it took and nothing else.
def expect_claim(*ids, exitstatus: 0, err: "")
  ids.each do |id|
    @fake.expect(["bd", "update", id, "--claim"],
                 out: JSON.generate([{ "id" => id }]), err: err, exitstatus: exitstatus)
  end
end
```

Then add an `expect_claim` call to each of these twelve existing cases, for
exactly the ids that case expects in `recommended`:

- `test_area_build_takes_the_batch_alone` (`zz-bld`)
- `test_unreached_upstream_keeps_its_own_reason` (`zz-fst`)
- `test_stale_worktree_areas_do_not_block` (`zz-new`)
- `test_2026_08_05_phantom_collision_regression` (`zz-d9g`)
- `test_dependency_edge_not_batched_across_epic_row_absorbs_it` (`zz-child`)
- `test_ceiling_hit_false_when_the_pool_ran_out` (`zz-a`, `zz-b`)
- `test_ceiling_hit_true_when_batch_full_before_pool_exhausted` (`zz-a`,
  `zz-b`)
- `test_label_filter_that_actually_filtered_proceeds_normally` (`zz-a`)
- `test_every_candidate_carries_a_summary_derived_from_the_description_in_default_mode`
  (`zz-a`, `zz-b`)
- `test_summary_present_in_explicit_selection_mode_too` (`zz-trm`)
- `test_candidate_with_empty_description_carries_summary_key_with_nil_value`
  (`zz-nod`)
- `test_identical_titles_with_different_descriptions_produce_different_summaries`
  (`zz-trm`, `zz-tgv`)

The remaining `--auto` cases need no change because their walks take
nothing: the unlabeled, upstream, epic-verdict, manifest-driven-upstream,
live-collision and `n_too_large` cases all end with `recommended` empty, and
the manual cases never claim at all. **Do not "fix" a raise by widening an
expectation to a bare `["bd", "update"]` prefix** - the per-id registration
is what keeps an over-claim detectable.

Verify the enumeration rather than trusting this list: run the suite after
the script change and treat every `UnexpectedCommand` as a case that belongs
above. A case that raises and is *not* on this list means the script claimed
something the walk did not take, which is a bug in the script, not a missing
expectation.

Commit title: `Claims at take inside the auto walk` (34 chars).

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes (`ruby skills/wurk:kit/scripts/test/run.rb`)
- [x] `contract_test.rb` passes unchanged - no rule edited, no banned
      operation introduced (`bd update` is on no banned list)
- [x] `ruby skills/wurk:kit/scripts/select_batch.rb --help` prints a usage
      line containing `--dry-run` and exits 0
- [x] The six new `select_batch_test.rb` cases exist and pass, and each
      carries a `# sabotage:` note
- [x] Every pre-existing auto-mode test that takes a bead now registers that
      bead's claim: no `FakeSh::UnexpectedCommand` anywhere in the suite
      output
- [x] `grep -c "never claims a bead" skills/wurk:kit/scripts/select_batch.rb`
      returns 0 (the unqualified sentence is gone)

#### Manual Verification:
- [ ] Each sabotage note was actually exercised: the described mutation was
      applied, the suite watched go red for the stated reason, and the
      mutation reverted
- [ ] `ruby skills/wurk:kit/scripts/select_batch.rb --n 2 --auto --dry-run`
      in a live checkout lists the `bd update <id> --claim --json` commands
      in `commands` and leaves every bead's status unchanged
      (`bd show <id>` before and after)
- [ ] `ruby skills/wurk:kit/scripts/select_batch.rb --n 2` (manual) leaves
      every bead's status unchanged
- [ ] A real `--auto` run claims exactly the recommended beads and nothing
      else, confirmed with `bd show` on both a taken and a skipped id
- [ ] No regressions in the verdict table: epic, unlabeled, upstream, and
      live-worktree-collision beads are still skipped and still unclaimed

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: Mode-qualify /wurk:next's claim prose

### Overview

`/wurk:next` auto mode drops its separate claim loop and reports claims from
the envelope; step 1's unqualified "nothing is claimed" becomes
mode-qualified. The manual path - the picker, the override note, the
`bd_claim_failed` drop-and-report fallback - is unchanged.

### Changes Required:

#### 1. The skill's step 1, step 2 and step 4

**File**: `skills/wurk:next/SKILL.md`
**Changes**:

- **Step 1** (lines 139-140): replace "**Nothing is claimed by this call** -
  it only reports" with a mode-qualified pair of sentences: in manual mode
  nothing is claimed and the call only reports; under `--auto` the script
  claims each bead at the moment its walk takes it, so `data.recommended` is
  "recommended and claimed" (ADR-0012).
- **Step 1's `data.recommended` bullet** (lines 178-180): keep "an option to
  present, not the outcome to report" as the manual-mode reading, and add
  the auto-mode reading.
- **Step 1's `data.skipped` bullet** (lines 181-182): add that a skip reason
  can now be a contended claim - a bead another session took between listing
  and the walk - and that a `claim_contended` warning accompanies it.
- **Step 2's auto paragraph** (lines 245-248): state that the beads in
  `data.recommended` are already claimed, so auto mode goes straight to step
  3 and skips step 4's claim loop.
- **Step 4** (lines 258-291): retitle as the manual-mode claim step and say
  so in its first line. Keep the whole body - the per-bead `bead.rb claim`,
  the `bd_claim_failed` drop-and-report fallback, the override note, and the
  claimed-before-any-workspace rationale - as written, because it is still
  exactly what manual mode does. Add a short auto-mode clause: the claims
  already happened inside selection, so auto mode runs only the
  `bead.rb sync push` at the end of the step.
- **Guidelines** (lines 355-357): keep "claim the whole batch before
  creating any workspace" and note that under `--auto` the claim happens
  earlier still, inside selection, which strengthens rather than relaxes the
  rule.

**The manual-mode prose is not rewritten, condensed, or "tidied".** Only the
sentences that became false get qualified.

**ADR-0008 note for the implementer**: this diff is the shape wurk's
merge-time prose judge looks for - a claim step stated in a skill being
handed to a script. It is sanctioned by ADR-0012, and the way to pass the
judge honestly is to leave the policy visible: the drop-on-contention rule,
the claim-before-workspace ordering, and the never-claim-an-`upstream`-bead
rule all stay stated in the skill, and the auto-mode text cites ADR-0012 by
number. The judge runs at merge time via `.claude/wurk/mr.md`, not in the
gate, so it will not appear in this phase's gate run.

Commit title: `Reports auto claims from the envelope` (36 chars).

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes (`ruby skills/wurk:kit/scripts/test/run.rb`)
- [x] `grep -n "Nothing is claimed by this call" skills/wurk:next/SKILL.md`
      returns nothing (the unqualified sentence is gone)
- [x] `grep -n "bd_claim_failed" skills/wurk:next/SKILL.md` still returns the
      manual-mode fallback
- [x] `grep -n "ADR-0012" skills/wurk:next/SKILL.md` returns at least one
      line
- [x] `git diff` for the phase touches only `skills/wurk:next/SKILL.md`

#### Manual Verification:
- [ ] `/wurk:next --auto` end to end: the beads reported as claimed are
      claimed, contended beads are reported as skipped with their reason,
      and no bead is claimed twice or left claimed without a workspace being
      attempted
- [ ] `/wurk:next` (manual) still presents the candidate table, claims
      nothing before the pick, and drops a `bd_claim_failed` bead from the
      batch while keeping the rest
- [ ] `bead.rb sync push` still runs once per batch in both modes
- [ ] The merge-time judge (`/wurk:mr`) does not flag the skill diff; if it
      does, the finding is answered on its merits rather than by deleting
      the judged prose

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

All in `skills/wurk:kit/scripts/test/select_batch_test.rb`, on the existing
`FakeSh` + `areas_wide` fixture harness. No new support file, no new
fixture manifest.

**Existing cases first.** Auto mode claiming at take makes twelve existing
`--auto` cases raise `FakeSh::UnexpectedCommand`, because their walks take
beads whose claims were never authorized. Phase 2 updates all of them with
an `expect_claim` call (enumerated in that phase); that is the larger half
of the phase's test work, and the phase is not green until it is done.
New cases:

- Auto claims exactly the beads the walk took, and no others - asserted
  positively on `@fake.calls` so an over-claim is caught as well as an
  under-claim.
- A contended claim skips: `recommended` excludes it, `skipped` names it
  with the contention reason, `warnings` carries `claim_contended`, `ok`
  stays `true`, exit code 0, and the walk still takes the next legal
  candidate.
- A contended bead does not consume the batch's area budget - the next
  candidate sharing its area is still takeable.
- A contended `lands-alone` candidate does not set the alone state; the walk
  resumes and takes the following free bead.
- `--auto --dry-run` executes no `bd update`, and `commands` carries the
  rendered claim commands.
- Manual mode (with and without `--dry-run`) executes no `bd update`.

Edge cases deliberately covered by the existing suite and not re-tested:
epic / unlabeled / upstream / live-worktree-collision skips (they never
reach the take step, so they can never be claimed), `n_too_large`,
`ambiguous_input`, and `unverified_filter` - all of which return before the
walk runs.

### Manual Testing Steps:

1. Run `ruby skills/wurk:kit/scripts/select_batch.rb --n 2 --auto --dry-run`
   in a live checkout. Confirm `commands` contains one
   `bd update <id> --claim --json` per recommended bead and that
   `bd show <id>` reports each still `open`.
2. Run `ruby skills/wurk:kit/scripts/select_batch.rb --n 2` (manual).
   Confirm no bead's status changed.
3. Run `ruby skills/wurk:kit/scripts/select_batch.rb --n 2 --auto`. Confirm
   every id in `data.recommended` is now `in_progress` and every id in
   `data.skipped` is untouched.
4. Simulate contention: claim one high-priority ready bead from a second
   session (`bead.rb claim <id>`), then run the auto selection and confirm
   that bead is absent from `bd ready`'s set or, if it still appears,
   reported as a contention skip with bd's own message in the reason.
5. Run `/wurk:next --auto` end to end and confirm the report names claimed
   and skipped beads and that each claimed bead got a workspace attempt.
6. Run `/wurk:next` interactively and confirm the picker still gates every
   claim.

## References

- Direction record: `docs/adr/0012-atomic-claim-inside-auto-walk.md`
- Related ADRs: `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`
  (script contract), `docs/adr/0009-upstream-beads-without-a-workspace.md`
  (the `upstream` verdict this must not disturb),
  `docs/adr/0008-merge-time-judge-over-generic-skill-prose.md` (the judge
  Phase 3's diff will meet)
- Selection mechanics: `skills/wurk:kit/scripts/select_batch.rb:31-76`,
  `:286-349`
- The claim primitive: `skills/wurk:kit/scripts/bead.rb:168-193`
- The skill: `skills/wurk:next/SKILL.md:131-203`, `:245-248`, `:258-291`
- Test harness: `skills/wurk:kit/scripts/test/select_batch_test.rb`,
  `skills/wurk:kit/scripts/test/support/fake_sh.rb:45-66`
- Bead: `wu-z6n`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

Verified 2026-08-16, after the loop finished. Seven boxes are confirmed
below; four are left open with the reason recorded on each. The four open
ones share one root cause: at verification time only one bead was ready
(`wu-hu2`), and it skips as a live-worktree collision against this very
worktree (`area:kit`, held by `wu-z6n`), so the walk had nothing takeable
and the positive claim path could not be exercised live.

### Phase 1

- [x] ADR-0012's committed text is identical to the accepted version - no
      incidental edits rode along. `git diff e2cda01..HEAD` on the ADR is
      empty; the later touches to this plan are the loop ticking its own
      automated boxes and appending this section.
- [x] The commit contains only these two documents - `e2cda01` is exactly
      two files, 789 insertions

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 2

- [x] Each sabotage note was actually exercised: the described mutation was
      applied, the suite watched go red for the stated reason, and the
      mutation reverted. All six: dropping the claim from the free branch
      gives 4 failures, ignoring the claim's return 2, unioning areas before
      the claim 1, and the lands-alone, `--dry-run`-passthrough and
      `claim`-guard mutations each fail in exactly their named test. Tree
      clean after every revert.
      Note: the lands-alone mutation only goes red when applied as written,
      `alone = true` *and* `break`. Setting `alone = true` alone is
      unobservable in that fixture, since nothing follows the taken bead.
- [x] `ruby skills/wurk:kit/scripts/select_batch.rb --n 2 --auto --dry-run`
      in a live checkout lists the `bd update <id> --claim --json` commands
      in `commands` and leaves every bead's status unchanged
      (`bd show <id>` before and after)
      Verified indirectly: the live run had nothing takeable, so its
      `commands` was legitimately empty. The passthrough was confirmed one
      level down instead - `bead.rb claim wu-hu2 --dry-run` renders
      `bd update wu-hu2 --claim --json` and leaves the bead `open`,
      unassigned - plus the unit case that pins the rendering into
      `commands`.
- [x] `ruby skills/wurk:kit/scripts/select_batch.rb --n 2` (manual) leaves
      every bead's status unchanged - no `--claim` in `commands`, `wu-hu2`
      still `open`/unassigned
- [ ] A real `--auto` run claims exactly the recommended beads and nothing
      else, confirmed with `bd show` on both a taken and a skipped id
      **Half done.** A real (non-dry) `--auto` run was made: `recommended`
      was empty, no claim executed, and the skipped `wu-hu2` was `open`
      before and after - so the skipped-id half holds under a genuinely
      mutating run. The taken-id half is unexercised because nothing was
      takeable. Explicit ids do not help: `annotate` computes the collision
      verdict for every candidate regardless of how it was listed. Exercising
      it needs a ready bead whose areas no live worktree holds.
- [ ] No regressions in the verdict table: epic, unlabeled, upstream, and
      live-worktree-collision beads are still skipped and still unclaimed
      **Partial.** live-worktree-collision confirmed live and unclaimed.
      epic, unlabeled and upstream had no live instances at verification
      time and rest on unit coverage only. They never reach the take step,
      so they can never be claimed, which is why this is a low-risk gap.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 3

- [ ] `/wurk:next --auto` end to end: the beads reported as claimed are
      claimed, contended beads are reported as skipped with their reason,
      and no bead is claimed twice or left claimed without a workspace being
      attempted
      **Not run** - same blocker as phase 2's real-`--auto` box: no takeable
      bead. Worth running deliberately the first time a non-colliding ready
      bead exists, rather than meeting it in anger.
- [x] `/wurk:next` (manual) still presents the candidate table, claims
      nothing before the pick, and drops a `bd_claim_failed` bead from the
      batch while keeping the rest
      Verified structurally in `skills/wurk:next/SKILL.md`: step 2 keeps
      "Nothing is claimed until the user picks" mode-qualified to manual,
      and step 4 keeps the `bd_claim_failed` drop-and-report intact. Not
      exercised interactively.
- [x] `bead.rb sync push` still runs once per batch in both modes - step 4's
      push sits after the auto path's "skip straight to this step's
      `bead.rb sync push`" jump, so both modes land on the one call
- [ ] The merge-time judge (`/wurk:mr`) does not flag the skill diff; if it
      does, the finding is answered on its merits rather than by deleting
      the judged prose
      **Deferred to `/wurk:mr` by decision** - the judge runs there anyway,
      so it was not run twice. Expect it to raise this diff: a claim step
      moving from skill prose into a script is the shape ADR-0008's judge
      hunts. The answer on merits is ADR-0012, cited by number at four
      points in the skill.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

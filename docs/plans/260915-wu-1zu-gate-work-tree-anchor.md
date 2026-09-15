---
date: 2026-09-15
planner: Claude
git_commit: e99173620641df3c547e1f920e271b401d1322db
branch: wu-1zu-sabotage-scan-worktree
repository: wurk
beads_issue: wu-1zu
topic: "gate.rb anchors the tree it measures on git's working-tree root, not on the manifest's checkout"
tags: [plan, kit, gate, manifest, worktree]
status: ready
last_updated: 2026-09-15
last_updated_by: Claude
---

# gate.rb anchors on the working tree it is gating Implementation Plan

## Overview

`gate.rb` measures one tree and reports on another. `Manifest#checkout_root`
is two directories above the located manifest, so it is the root of the
checkout *the manifest was found in*, which is the working tree only when
that working tree carries its own `.claude/wurk.json`. Every gate-side use of
it - the sabotage `git diff` and its working-tree file reads, the
`gate.guard_ledger` existence check, and the `chdir:` for the consumer's own
gate commands - therefore points at the wrong checkout whenever a consumer
gitignores `.claude/` and works in a worktree.

This plan introduces one anchor, resolved once per invocation from
`git rev-parse --show-toplevel`, threads it through `gate.rb` and
`gate_run.rb`, and reports it as `data.work_tree_root` so the tree a gate
measured is legible in the envelope instead of inferred. `checkout_root`
keeps its definition and its correct uses (`.claude/` siblings of the
manifest).

Beads issue: `wu-1zu`

The investigation is complete and is not reopened here:
`docs/research/260915-wu-1zu-gate-sabotage-scan-worktree-checkout-root.md`.
It classifies all thirteen `checkout_root` resolution sites, reproduces the
bug empirically, and prices four candidate approaches. This plan takes
approach (b) - a new anchor applied to the sites the research classifies as
incorrectly manifest-relative - bounded to the gate path, and records why
four sites are excluded.

## Current State Analysis

**The anchor is a pure function of where the manifest was found.**
`Manifest#checkout_root` (`skills/wurk:kit/scripts/lib/manifest.rb:262-264`)
is `File.expand_path(File.join(File.dirname(path), ".."))`. Its own comment
(`:258-261`) states the intent it was introduced for: "gate.rb is
legitimately invoked from a subdirectory", which is true and is why a bare
`Dir.pwd` anchor was wrong.

**Two independent conditions make it diverge from the working tree**, both
reducing to one statement: the bug fires whenever the working tree does not
carry its own manifest.

1. `Manifest.locate`'s fallback (`manifest.rb:194-203`): the walk-up finds
   nothing, so `main_checkout` (`:212-220`, `git rev-parse --git-common-dir`)
   supplies the main checkout.
2. The walk-up itself (`:224-234`) landing on an *ancestor*: a worktree
   nested under the main checkout finds the main checkout's manifest. No
   fallback runs, and the outcome is identical.

The research reproduced both empirically (case A and case C of its item 1)
and confirmed the failure shape is a silent false clean: worktrees share one
object database, so the merge-base sha computed in the worktree resolves
fine inside the main checkout, the diff exits 0, and the envelope reports
`scanned: true` with `missing: []`. A gate that checked nothing reports
itself as having verified everything. It does not reproduce in `wurk` itself,
where `.claude/wurk.json` is tracked.

**gate.rb mixes two anchors inside one invocation.** `lib/base_ref.rb` passes
`chdir:` on none of its five shell-outs (`:23,37,58,77,99`), so the base ref,
the merge-base, the changed-file list and the untracked list are all the
working tree's; the sabotage diff, its file reads and the ledger check are
the manifest's checkout. One envelope, two trees:
`data.applicable: true` beside `sabotage.missing: []` reads as "there were
changes and they were clean", and `data.sabotage.unverifiable` is assembled
from both trees at once (research item 3).

**The nine sites this plan changes**, from the research's classification
table (item 2):

| # | Site | What it resolves |
|---|---|---|
| 1 | `gate.rb:276` | `chdir:` for the sabotage `git diff` |
| 2 | `gate.rb:286` | root for the sabotage working-tree file reads |
| 3 | `gate.rb:523` | `gate_guard` ledger `File.exist?` (carve-out path) |
| 4 | `gate.rb:546` | same (gate-could-not-start path) |
| 5 | `gate.rb:574` | same (normal path) |
| 6 | `gate.rb:364` | `chdir:` for the CONSUMER'S OWN GATE COMMAND |
| 7 | `gate.rb:588` | `chdir:` for `gate.attest` |
| 8 | `gate.rb:547`, `:579` | the reported `data.gate_cwd` |
| 9 | `gate_run.rb:149` | `chdir:` for the detached long gate |

Sites 6-9 all take `Manifest#gate_chdir`'s default `root: checkout_root`
(`manifest.rb:451-453`). Verified by grep: `gate.rb` (four sites) and
`gate_run.rb` (one) are the *only* production callers that take that default.
`worktree_create.rb:439-440` and `worktree_refresh.rb:161-162` already pass
`root: path` explicitly and are already correct - they are the existing proof
that `root:` is the intended seam.

**Sites 6-7 are plausibly more severe than the reported symptom.** A consumer
that declares `gate.cwd` and works in a worktree without its own manifest
runs its whole test suite in the main checkout and then attests the result.
It is latent and self-cancelling for everyone else: with `gate.cwd` absent,
`gate_chdir` returns nil, `Sh.run` passes no `chdir` (`lib/sh.rb:197`), and
the command runs in `Dir.pwd`, which is the worktree. Correct by accident,
and the reason nobody has hit it.

**`git rev-parse --show-toplevel` is the one anchor correct for both cases.**
Verified in the research (item 2): invariant across subdirectories within a
checkout - the property wu-9fb needed - and per-worktree correct, which is
the property this bead needs. `worktree_create.rb:571-581`
(`main_checkout_root`) is the existing precedent: it already calls
`--show-toplevel` through `Sh.run` with `envelope: env` and already degrades
by returning nil.

**The documented contract already disagrees with itself.**
`docs/manifest.md:624-630` says the gate commands "run at the root of the
checkout being gated" and in the next clause equates that with "the checkout
root for `gate.rb`"; the audit block at `:677-683` says "resolved against the
manifest's checkout root". Both readings are the same thing only under the
Resolution section's premise at `:1001` - "A worktree is a full checkout and
carries its own `.claude/wurk.json`" - which is asserted as fact and is false
for the consumer in this bead. The doc is internally consistent and
externally wrong at the same time.

**The test suite has no real git and no worktree fixture.** `Sh.runner` is
`FakeSh` in every gate test (`test/support/fake_sh.rb:20`), matching on argv
prefix and raising `UnexpectedCommand` on anything unregistered (`:97-102`).
No test anywhere in the suite runs `git init` or `git worktree add` for real.
`in_tmp_repo` (`test/support/manifest_helper.rb:54-63`) installs the fixture
manifest at the same root it chdirs into, so `checkout_root == Dir.pwd` for
all 44 of its `gate_test.rb` uses - which is exactly why none of them can see
this bug.

**The stub churn is bounded and measured.** `expect_no_sabotage_diff` has 35
call sites and `expect_no_subdir_sabotage_diff` 4, but the new shell-out is
not sabotage-specific: it is resolved once in `run` and needed on every path,
including the carve-out. So it belongs in `expect_base_ref`
(`gate_test.rb:62-64`), which the four `expect_*_diff` helpers all call.
Measured mechanically over `gate_test.rb`: exactly **one** test calls
`run_gate` without going through an `expect_base_ref`-family helper -
`test_unresolvable_base_reports_scanned_false_with_no_base_ref_unverifiable`
(`:1542`), which stubs the ladder by hand. Every other `run_gate` test is
covered by editing one helper.

**FakeSh prefix matching does not collide.** Matching is
`argv[0, prefix.length] == prefix`, so `["git","rev-parse","--show-toplevel"]`
cannot match `["git","rev-parse","--verify","--quiet",ref]` (argv[0,3] differs)
and cannot be matched by it (length differs), and neither collides with
`["git","rev-parse","--git-common-dir"]`. Registration order between them is
therefore irrelevant.

**No test asserts the full `commands` array or its order.** Grep over
`gate_test.rb` and `gate_run_test.rb` finds only `.any?` predicates
(`gate_test.rb:1671`, `:1698`, `gate_run_test.rb:221`), so inserting a new
shell-out into the trail breaks no existing assertion.

**Baseline.** `ruby skills/wurk:kit/scripts/test/run.rb` is green at
`e991736`: 1293 runs, 4898 assertions, 0 failures, 0 errors, 0 skips.

## Desired End State

`gate.rb` and `gate_run.rb` resolve the working tree once per invocation and
measure that tree. Concretely, for a consumer that gitignores `.claude/` and
runs the gate from a worktree:

- the sabotage `git diff` runs with `chdir:` set to the worktree, its file
  reads resolve under the worktree, and an unnoted test declaration on the
  worktree's branch is reported as `missing` rather than silently passing;
- `data.gate_guard.ledger_exists` answers about the worktree's branch;
- a declared `gate.cwd` resolves under the worktree, so the consumer's test
  suite and its `gate.attest` run in the tree being gated;
- `gate_run.rb`'s detached gate runs in the worktree, while its run-state
  directory stays under the manifest's `.claude/` (deliberate, see What We're
  NOT Doing);
- `data.work_tree_root` reports the absolute path gate.rb anchored on, so the
  tree a gate measured is a machine-readable fact rather than something a
  reader infers from the `commands` trail.

And the subdirectory case wu-9fb exists for still works: invoked from
`<root>/sub`, every one of the above resolves against `<root>`, because
`--show-toplevel` is invariant across subdirectories.

Verified by: the kit suite green with new tests that fail under the current
anchor (a fixture where the manifest's checkout root and the working tree
differ), plus the by-hand checks in Deferred Manual Verification that real
git behaves as assumed.

### Key Discoveries:

- `Manifest#checkout_root` is a pure function of `path`
  (`lib/manifest.rb:262-264`); the bug is not in the accessor, it is in nine
  callers asking it a question about tracked tree content
  (research item 2).
- `Manifest#gate_chdir`'s `root:` default is taken by exactly five production
  call sites, all of them in the gate path and all of them wrong; the two
  correct callers already pass `root:` explicitly
  (`worktree_create.rb:439-440`, `worktree_refresh.rb:161-162`).
- `worktree_create.rb:571-581` already resolves a working tree from git
  through `Sh.run` with `envelope: env` and degrades by returning nil - the
  template to follow, minus its git-dir-vs-common-dir main-checkout guard,
  which answers a different question.
- `sabotage_scan` short-circuits on a nil merge base before it ever needs a
  root (`gate.rb:265-269`), which is what makes the degraded-behavior choice
  below cheap: the realistic "not in a work tree" case is already reported
  through `no_base_ref`.
- The three sites in `docs/manifest.md`'s audit block (`:677-683`) will no
  longer share one anchor, so the block splits; the Resolution section's
  premise at `:1001` is a factual claim about consumers that is false and has
  to be corrected, not softened.
- ADR-0006 (`docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`):
  stdlib-only system Ruby, one JSON envelope on stdout, every shell-out
  through `lib/sh.rb` with `envelope: env` so it lands in the `commands`
  trail, and `gate.rb` acquires no write path. `contract_test.rb` enforces
  all of it and is not weakened here.
- ADR-0004 (`docs/adr/0004-manifest-and-extension-seams.md`): the manifest is
  the one seam for project-specific values. Nothing in this plan adds a
  manifest field, so no schema change and no extension change is involved -
  but `docs/manifest.md` still moves with `lib/manifest.rb` in Phase 3 per
  CLAUDE.md's same-commit rule.

## What We're NOT Doing

Every exclusion below is a site the research classifies, so silence is not
available. Each names the reason and, where a follow-up is owed, says so.

- **Not re-anchoring the `artifacts.adr` directory check (research site 10,
  `manifest.rb:1657`, `:1662`).** It lives in `manifest.rb`'s lint, not in
  the gate, and it is entangled with site 13 below, which pulls the opposite
  way. Making the lint git-dependent changes what `manifest.rb check` can do
  - wu-9fb established that `validate!` is filesystem-free by construction so
  a fixture can be linted outside any checkout, and the lint is where
  environment questions belong, but the lint still runs in places where git
  may not answer at all. Severity is low: `docs/adr/` is long-lived, so both
  trees have it; it misjudges only a branch introducing the directory for the
  first time. **File a follow-up bead covering sites 10 and 13 together** -
  the lint's anchoring is one question and should be decided once.
- **Not re-anchoring `beads_dolt_remotes` (research site 13,
  `manifest.rb:350`).** This is the one site a mechanical sweep would make
  *worse*. It reads two sources: `.beads/config.yaml`, tracked and present in
  every worktree, and `.beads/embeddeddolt/*/.dolt/repo_state.json`,
  gitignored and present only in the main checkout - and the second source is
  the whole point of the check, because the incident behind `beads.sync` had
  a remote surviving there after a guard removed it from the yaml. The
  research measured it in this repo today: run from a worktree it already
  misses the `embeddeddolt` source. It wants `Manifest.main_checkout`, not a
  work-tree anchor. Excluded deliberately, and it rides on the same follow-up
  bead as site 10.
- **Not moving `gate_run.rb`'s run-state write (research site 11,
  `gate_run.rb:152`).** This plan agrees with the research's classification:
  the path is a sibling of the manifest inside the same `.claude/`, not
  tracked tree content, and the poller resolves it by the same rule, so
  writer and reader agree. Moving it to the work tree would let
  `/wurk:cleanup` remove a worktree out from under a detached run that is
  still writing its sentinel there, turning a completed gate into a lost one.
  Centralizing every run's state under the main checkout's
  `.claude/wurk-runs/` is now a stated behavior rather than an accident: the
  detached gate *runs* in the work tree and *records* beside the manifest.
- **Not touching `mr_review_agent_*` (research site 12,
  `manifest.rb:700-718`).** `<root>/.claude/agents/<name>.md` is a sibling of
  the manifest inside the same `.claude/`; "the directory the manifest lives
  in" is the semantic anchor, not an approximation of one. Correct as it
  stands.
- **Not changing `checkout_root` itself** (the research's approach (c)). It
  would break sites 11 and 12, where the manifest's directory is the correct
  anchor, and it would turn a pure string function - called freely from
  lint-adjacent code - into a git shell-out, making every caller
  FakeSh-visible. The two-concept problem it claims to remove would come back
  as an opt-out keyword on the other side.
- **Not changing `Manifest.locate`** (the research's fourth option). Having
  the walk-up or the fallback prefer a manifest in the current working tree
  would make cases A and C behave like case B, but it changes every script's
  manifest resolution and it contradicts the Resolution section's deliberate
  ordering (`docs/manifest.md:1000-1006`), which exists so a manifest edit is
  testable on the branch that makes it. Rejected explicitly rather than
  silently.
- **Not requiring consumers to track `.claude/wurk.json`** (the research's
  open question 5). Making the doc's premise true by having
  `worktree_create.rb` place a manifest in each new worktree, or by declaring
  tracking a requirement, is a consumer-facing decision larger than this
  bead. This plan removes the code's *dependence* on the premise and corrects
  the doc's claim; it does not legislate consumer layout.
- **Not adding a `no_work_tree` value to `data.sabotage.unverifiable`.** See
  the degraded-behavior decision in Implementation Approach. It would be a
  contract addition every reader of that list has to tolerate, for a case
  that is already reported through `no_base_ref`.
- **Not adding a real-git fixture capability to the suite.** Priced and
  rejected in Testing Strategy; the properties FakeSh cannot reach go to
  Deferred Manual Verification instead of being faked.
- **Not fixing the duplicate test definition in `gate_run_test.rb`.** Noticed
  while measuring Phase 3's stub churn:
  `test_start_on_an_unusable_run_dir_blocks_with_an_envelope` is defined
  twice, at `:137` (at column zero, which is itself the tell) and again at
  `:176`. Ruby silently lets the second override the first, so the body at
  `:137` never runs - a dead test that the suite's run count conceals. It is
  a real defect and it is adjacent to this plan's work, so Phase 3 must
  leave it alone rather than half-fix it while adding a stub: whichever
  definition survives, deciding that is a test-coverage question, not an
  anchoring one. **File a follow-up bead.** Phase 3 adds the work-tree stub
  to whichever definition is live and does not deduplicate.
- **Not sweeping stale line numbers through dated documents.** Two
  annotations are added to
  `docs/plans/260817-wu-9fb-subdirectory-gate-cwd.md`, each at one
  definitional mention, in the `**Later (2026-09-15):** ...` shape. Nothing
  else in `docs/plans/` or `docs/research/` is edited.

## Implementation Approach

Three phases, split by site family. Each is independently committable, each
leaves `ruby skills/wurk:kit/scripts/test/run.rb` green, and each carries its
own documentation edit so no commit leaves a doc describing behavior the code
no longer has.

**The mechanism: one resolution, threaded.** A new `lib/work_tree.rb` answers
"what working tree am I standing in" once:

```ruby
# frozen_string_literal: true

require_relative "sh"

# The root of the git working tree the process is standing in. Distinct from
# Manifest#checkout_root, which is the root of the checkout the MANIFEST was
# found in: the two differ whenever the working tree carries no
# .claude/wurk.json of its own (a worktree of a consumer that gitignores
# .claude/, or a worktree nested under the main checkout, whose walk-up finds
# an ancestor's copy). Every kit question about TRACKED TREE CONTENT - what a
# git pathspec matches, whether a tracked file exists, where a gate command
# should run - resolves against this; questions about siblings of the
# manifest inside .claude/ stay on checkout_root. See wu-1zu.
#
# --show-toplevel rather than --git-common-dir or a Dir.pwd walk: it is
# invariant across subdirectories within one checkout (the property wu-9fb's
# checkout_root was introduced for) and per-worktree correct (the property
# wu-1zu needs). No other anchor has both.
#
# nil when git cannot answer - outside any working tree, or inside a bare
# repository. Callers decide; see gate.rb, which warns and falls back.
module WorkTree
  class << self
    def root(env)
      res = Sh.run(%w[git rev-parse --show-toplevel], envelope: env)
      return nil unless res.success?

      out = res.out.to_s.strip
      out.empty? ? nil : File.expand_path(out)
    end
  end
end
```

`gate.rb#run` resolves it once, immediately after the manifest guard, and
threads the value the way `changed` is already threaded (`gate.rb:94-96`,
`:464`) rather than re-shelling at each site. Threading rather than
memoizing is deliberate: a module-level memo on `class << self` would leak
between the many `Gate.run` calls a single test process makes.

**Resolution is unconditional, not lazy.** With sites 3-9 in scope every
gate.rb path needs the anchor, including the carve-out path (which still
calls `gate_guard_from`), so a lazy form would buy nothing and cost a memo
with test-leak hazards. It does add one `git rev-parse --show-toplevel` line
to every consumer's `commands` trail, which revises wu-9fb's stated
preference for a byte-identical trail (its decision 1). That revision is
deliberate and is recorded below: the anchor is now something gate.rb
*reports*, and the reason this bug was invisible for a month is that nothing
in the envelope said which tree had been measured.

**Degraded behavior when `--show-toplevel` fails: warn once and fall back to
`manifest.checkout_root`.** Of the three shapes the research prices
(`:773-798`) this one is chosen, and the other two are rejected on these
grounds:

- It matches the existing precedent for "I must use a knowably worse answer":
  `BaseRef.resolve`'s `stale_base_ref` warning (`base_ref.rb:26-29`).
- It is *one* mechanism for all nine sites. An `unverifiable` entry only
  covers the sabotage scan; the ledger check and `gate_chdir` still need some
  root, so the third shape would mean one degradation story for the scan and
  a second, unstated one for everything else.
- It keeps `gate.rb` usable outside a working tree, which `Manifest.locate`'s
  step 2 exists to support. Blocking would be a new hard constraint.
- It adds no new contract value, so `/wurk:commit`'s reading of
  `data.sabotage.unverifiable` (its pre-commit-checks step,
  `skills/wurk:commit/SKILL.md:144`) and
  `REFERENCE.md:423-429`'s enumeration of `reason` values need no change.
- The false-clean risk the third shape guards against is already covered.
  `sabotage_scan` computes the merge base first and returns
  `scanned: false` with `reason: "no_base_ref"` when it is nil
  (`gate.rb:265-269`), and gate.rb already warns `sabotage_scan_failed` with
  "an empty missing list here is not a clean result" (`:489-495`). Outside a
  working tree the base-ref ladder fails first, so that path already fires. A
  `no_work_tree` reason would only ever fire in the residual case where a
  base ref *and* a merge base resolved but `--show-toplevel` did not.

The "a warning is easy to skim past" objection is answered structurally
rather than with a second channel: `data.work_tree_root` makes the anchor
machine-readable, which is the legibility the third shape was reaching for,
without a new `reason` value. It reports the path actually used - the git
answer normally, the fallback when the warning fired - so it always answers
"which tree did this gate measure".

**Phase order.** Phase 1 lands the mechanism together with its first
consumer, the sabotage sites, which is the bead as filed; it also absorbs all
the test-helper churn, so Phases 2 and 3 add almost none. Phase 2 moves the
ledger check. Phase 3 changes `Manifest#gate_chdir`'s signature and the five
callers that took its default, and carries the two large `docs/manifest.md`
passages. Phase 1 is not split into "add the helper" then "use it": a commit
adding `lib/work_tree.rb` with no caller is the structure-without-a-consumer
shape /wurk:plan's own sizing rule tells us to fold together.

`docs/manifest.md`'s audit block (`:677-683`) is edited in all three phases,
once per family as that family's anchor moves. Three small edits rather than
one at the end, because each commit must describe the behavior it ships; a
single trailing edit would leave the block wrong for two commits.

## Phase 1: The work-tree anchor and the sabotage scan

### Overview

Adds `lib/work_tree.rb`, resolves the anchor once in `gate.rb#run`, reports
it as `data.work_tree_root`, and uses it for the sabotage `git diff` and the
sabotage file reader (research sites 1-2 - the bead as filed). Adds the
worktree test fixture the suite has never had, and updates the shared stub
helper so the rest of the suite keeps passing.

### Changes Required:

#### 1. The new anchor

**File**: `skills/wurk:kit/scripts/lib/work_tree.rb` (new)
**Changes**: as given verbatim in Implementation Approach above.

#### 2. gate.rb - resolve once, thread into the sabotage scan

**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**: `require_relative "lib/work_tree"` beside the existing requires.
Resolve immediately after the manifest guard in `run`, and thread the value.

```ruby
# in run, replacing the line after `return env.emit(io) unless manifest`
# The tree this gate measures, resolved once and threaded (the way `changed`
# is) rather than re-asked at each site. Not manifest.checkout_root: that is
# the root of the checkout the MANIFEST was found in, which is a different
# checkout whenever the working tree carries no .claude/wurk.json of its own
# - and then the sabotage diff inspects whatever branch that other checkout
# has out and reports a false clean. See wu-1zu and lib/work_tree.rb.
work_tree = WorkTree.root(env)
if work_tree.nil?
  env.warn(
    code: "work_tree_unresolved",
    message: "git rev-parse --show-toplevel did not answer, so the paths this gate resolves " \
             "on the filesystem fall back to the manifest's checkout root " \
             "(#{manifest.checkout_root}), which is the right tree only if the manifest was " \
             "found in the tree being gated"
  )
end
root = work_tree || manifest.checkout_root
env.data[:work_tree_root] = root
```

```ruby
# sabotage_scan gains the anchor as a parameter rather than reaching for the
# manifest, so one invocation cannot use two different roots.
def sabotage_scan(env, manifest, base, root)
  ...
  diff_res = Sh.run(sabotage_diff_args(manifest, merge_base), chdir: root, envelope: env)
  ...
  result = scan_sabotage(diff_res.out,
                          test_re: manifest.sabotage_test_pattern,
                          exempt_prefixes: manifest.sabotage_exempt_prefixes,
                          file_reader: default_sabotage_file_reader(root)).merge(scanned: true)
```

The `chdir` comment at `gate.rb:271-275` is rewritten: the pathspec reason
and the "never gate.cwd" clause both stand, but "chdir here" now names the
work-tree anchor and says why it is not `checkout_root`.
`default_sabotage_file_reader`'s comment (`:107-110`) has its last sentence
updated for the same reason - it currently explains the root as the thing the
reader has to know, which stays true, but names the wrong root implicitly.

Call site in `run`: `scan = sabotage_scan(env, manifest, changed[:base], root)`.

#### 3. The worktree fixture the suite has never had

**File**: `skills/wurk:kit/scripts/test/support/manifest_helper.rb`
**Changes**: a sibling of `in_tmp_repo`, not a change to it - 44
`gate_test.rb` tests depend on `in_tmp_repo`'s current shape, in which the
manifest sits at the root it chdirs into.

```ruby
# A scratch WORKTREE: the manifest is installed in a sibling checkout and the
# block runs in a directory that carries no manifest of its own, so
# Manifest#checkout_root and the working tree are DIFFERENT paths. This is
# the shape in_tmp_repo cannot express, and the only shape in which wu-1zu's
# bug is visible: with the two equal, every anchor looks correct.
#
# `nested: true` puts the worktree under the manifest's checkout instead of
# beside it, which reaches the same divergence through Manifest.locate's
# walk-up (case C of wu-1zu's research) rather than its --git-common-dir
# fallback (case A) - and so needs no rev-parse stub at all. The caller
# stubs --git-common-dir for the sibling form; see gate_test.rb.
#
# Yields the working-tree path and the manifest's checkout root, in that
# order: a test that conflates them is the bug under test.
def in_tmp_worktree(fixture = "valid", nested: false)
  Manifest.reset!
  Dir.mktmpdir do |dir|
    main = nested ? dir : File.join(dir, "main")
    tree = File.join(main, "wt")
    tree = File.join(dir, "wt") unless nested
    FileUtils.mkdir_p(File.join(main, ".claude"))
    FileUtils.cp(fixture_path(fixture), File.join(main, ".claude", "wurk.json"))
    FileUtils.mkdir_p(tree)
    Dir.chdir(tree) { yield tree, main }
  end
ensure
  Manifest.reset!
end
```

The contract is what matters, not the body's exact shape:
`yield <working tree>, <manifest checkout root>` with the two distinct; in
the sibling form (`nested: false`) no `.claude/wurk.json` anywhere on the
working tree's walk-up path, so `Manifest.locate` genuinely falls through to
the `--git-common-dir` branch; in the nested form (`nested: true`) the
manifest sits at the tmpdir root so the walk-up from `<dir>/wt` finds it.

**The sibling form must assert that precondition, not assume it.** This is
the one place the fixture can silently stop testing what it claims, and the
suite's existing guard does not cover it: `HomeGuard`
(`test/support/home_guard.rb`) repoints `ENV["HOME"]` so `UserConfig` cannot
read the operator's real `~/.claude/wurk.local.json`, but
`Manifest.walk_up` (`lib/manifest.rb:224-234`) walks *real filesystem paths
from `Dir.pwd`* and never consults `HOME`. So if `Dir.tmpdir` happens to sit
under a directory that has a `.claude/wurk.json` above it, the walk-up
escapes the fixture, finds that manifest, and the case-A test exercises the
walk-up instead of the fallback - passing or failing for a reason that has
nothing to do with this bead. This is not hypothetical: on the machine this
plan was written on, `Dir.tmpdir` is `$HOME/.claude/tmp/claude-1000`, which
is three levels below `$HOME/.claude/` - it works today only because
`$HOME/.claude/wurk.json` does not happen to exist.

So the helper walks from `tree` to the filesystem root and raises if it
finds a `.claude/wurk.json`, with a message naming the file it found and
saying the fixture needs a temp directory outside any checkout:

```ruby
# Manifest.walk_up reads the real filesystem from Dir.pwd, so HomeGuard
# cannot shield this fixture the way it shields UserConfig - if anything
# above Dir.tmpdir carries a manifest, the walk-up escapes and this fixture
# silently tests the walk-up branch instead of the fallback. Fail loudly at
# construction rather than produce a test that passes for the wrong reason.
def refute_manifest_above(dir)
  probe = dir
  loop do
    found = File.join(probe, Manifest::FILENAME)
    raise "in_tmp_worktree: #{found} is on the walk-up path from #{dir}, so " \
          "Manifest.locate will find it instead of falling through to " \
          "--git-common-dir; run the suite with a TMPDIR outside any checkout" if File.file?(found)

    parent = File.dirname(probe)
    break if parent == probe

    probe = parent
  end
end
```

`Manifest::FILENAME` is already `.claude/wurk.json`, so `File.join(probe,
FILENAME)` is the same expression `walk_up` uses - the guard and the thing
it guards cannot drift.

**File**: `skills/wurk:kit/REFERENCE.md`
**Changes**: the `in_tmp_repo` note at `:360-362` gains a sentence naming
`in_tmp_worktree` and what it is for. Same commit, same reason as the
manifest doc rule: the helper roster is documented there.

#### 4. The shared stub helper

**File**: `skills/wurk:kit/scripts/test/gate_test.rb`
**Changes**: `expect_base_ref` registers the new shell-out, so every test
reaching `run` through an `expect_*_diff` helper is covered by one edit.

```ruby
# Stubs the base-ref ladder's remote-first rung as a hit, so BaseRef.resolve
# picks `ref` (default "origin/main") without falling back or warning, and
# the work-tree anchor gate.rb resolves once per run (wu-1zu). `toplevel`
# defaults to Dir.pwd, which is what real git reports for every fixture
# whose working tree IS the cwd. A fixture whose cwd is NOT its working-tree
# root has to say so - see the from_subdir and worktree callers below, which
# is the whole point of the parameter.
def expect_base_ref(ref: "origin/main", toplevel: nil)
  @fake.expect(%w[git rev-parse --show-toplevel], out: "#{toplevel || Dir.pwd}\n")
  @fake.expect(["git", "rev-parse", "--verify", "--quiet", ref], exitstatus: 0)
end
```

**The `from_subdir` fixtures must pass `toplevel:` explicitly, and this is
the trap in the whole phase.** `in_tmp_cwd(from_subdir: true)` chdirs to
`<root>/sub`, so the `Dir.pwd` default would stub `--show-toplevel` as
`<root>/sub` - which is not what real git reports there. Left on the
default, the sabotage diff would chdir to `<root>/sub`, the file read would
resolve `<root>/sub/test/foo_test.exs` (absent), and the renamed
subdirectory test would go red for a fixture reason rather than a code one -
while appearing to prove the opposite of what it asserts. So:

- `expect_base_ref` grows `toplevel:` as above;
- the four `expect_*_diff` helpers (`gate_test.rb:66-88`) grow a
  `toplevel: nil` parameter and forward it to `expect_base_ref`, since they
  are how the `from_subdir` tests reach the ladder;
- the two `from_subdir: true` call sites pass the checkout root:
  `test_ledger_exists_is_true_when_gate_rb_is_invoked_from_a_subdirectory`
  (`:1810`, whose block does not currently bind the yielded root and so
  needs `do |root|`) and the sabotage subdirectory test (`:1832`, which
  already binds it).

That is the correct stub in both fixtures for the same reason the real fix
is correct: `--show-toplevel` is invariant across subdirectories, so the
fixture that models real git must be invariant too.

Plus the one test that stubs the ladder by hand and so needs the new
expectation directly:
`test_unresolvable_base_reports_scanned_false_with_no_base_ref_unverifiable`
(`:1542`). Measured mechanically: it is the only `run_gate` test in the file
that does not reach the ladder through one of those helpers, and no test in
the file calls `run_gate` or a base-ref helper more than once, so one
expectation per test is exactly right.

The two `expect_no_*sabotage_diff` helpers need no change: they do not stub
the anchor, their `merge-base` / `git diff` / `git status` prefixes cannot
collide with `["git","rev-parse","--show-toplevel"]`, and their callers all
run with cwd at the working-tree root.

Note that `gate_test.rb` calls `@fake.verify!` nowhere today, so an
unconsumed expectation is currently harmless in this file. The
sibling-worktree test below is the first to call it, deliberately - it is
how that test proves `Manifest.locate` took the fallback branch.

#### 5. Tests

**File**: `skills/wurk:kit/scripts/test/work_tree_test.rb` (new)
**Changes**: unit tests over `WorkTree.root` - the happy path returns the
expanded toplevel, a non-zero exit returns nil, empty output returns nil, and
the call appears in the envelope's `commands` trail (ADR-0006).

```ruby
# sabotage: return res.out.to_s.strip without the success? guard -> red
# (a failed rev-parse whose stderr carries "fatal: not a git repository"
# would come back as "" rather than nil, and the nil assertion fails)
def test_root_is_nil_when_git_cannot_answer
```

**File**: `skills/wurk:kit/scripts/test/gate_test.rb`
**Changes**: the reproduction tests, plus the two updates the research names.

New, in the sibling-worktree fixture (research case A) - this is the test
that fails under the current anchor:

```ruby
# sabotage: anchor the sabotage diff on manifest.checkout_root again instead
# of the threaded work-tree root -> red (diff_call.chdir is the manifest's
# checkout, not the worktree, and the unnoted declaration written into the
# WORKTREE goes unreported, so `missing` comes back empty)
def test_sabotage_diff_and_file_reads_resolve_against_the_worktree_not_the_manifests_checkout
```

It asserts `File.realpath(diff_call.chdir) == File.realpath(tree)`,
`refute_equal File.realpath(main), File.realpath(diff_call.chdir)`, and one
`missing` entry for a declaration written under the worktree - with the
manifest's checkout carrying a *noted* copy of the same file, so an anchor
that points there reports a clean result and the test distinguishes the two
anchors rather than merely one of them. `File.realpath` on both sides for the
reason already recorded at `gate_test.rb:1850-1852`.

New, in the nested fixture (research case C), asserting the same anchor with
no `--git-common-dir` stub involved, because the walk-up finds the ancestor's
manifest and the fallback never runs:

```ruby
# sabotage: fix only Manifest.locate's --git-common-dir fallback and leave
# the walk-up alone -> red (this fixture reaches the divergence through the
# walk-up, so a fallback-only fix still anchors on the ancestor's checkout)
def test_sabotage_anchor_is_the_worktree_when_the_walk_up_finds_an_ancestors_manifest
```

New, the degraded path:

```ruby
# sabotage: drop the `work_tree_unresolved` warning and silently use
# manifest.checkout_root -> red (the warning code is absent, and the silent
# fallback is the exact failure shape wu-1zu is about)
def test_an_unresolvable_work_tree_warns_and_falls_back_to_the_manifests_checkout_root
```

asserting the warning code, and `data.work_tree_root == checkout_root`.

New, the reported field:

```ruby
# sabotage: report manifest.checkout_root as data.work_tree_root instead of
# the resolved anchor -> red (the two differ in this fixture, which is the
# whole reason the fixture exists)
def test_work_tree_root_reports_the_tree_the_gate_measured
```

**Updated, not deleted** -
`test_sabotage_diff_and_file_reads_resolve_against_the_checkout_root_from_a_subdirectory`
(`:1831`). It is the only pin on the subdirectory behavior wu-9fb existed to
create, and its fixture cannot distinguish the two anchors (in `in_tmp_cwd`
the manifest's checkout root and the working tree are the same path), so the
assertion stays true under the fix. What goes stale is its `# sabotage:` note
at `:1827-1830`, which names `chdir: manifest.checkout_root` - a line that no
longer exists. Rename the test to name the work tree, and rewrite the note:

```ruby
# sabotage: resolve the work-tree anchor from Dir.pwd instead of
# `git rev-parse --show-toplevel` -> red (FakeSh records chdir as
# <root>/sub, not <root>, and the file read behind the note check resolves
# under sub/, missing the noted candidate below)
def test_sabotage_diff_and_file_reads_resolve_against_the_work_tree_root_from_a_subdirectory
```

That mutation is the one that matters now: it is the wu-9fb regression, and
it is exactly what a reader would reach for if they mistook "the working
tree" for "the working directory".

**Also updated**: the fixture-construction comment at `:185-191`, which
explains why these tests need a *located* manifest rather than
`with_manifest(manifest_with(...))`. The reason survives but changes shape -
an in-memory fixture manifest's `checkout_root` is
`skills/wurk:kit/scripts/test`, and with the anchor now coming from
`--show-toplevel` the stub value is what has to line up with `Dir.pwd`. And
`in_tmp_cwd`'s doc comment at `:40-43`, which describes the `from_subdir`
case in terms of `Manifest.locate`'s walk-up; it now also has to say that
`--show-toplevel` is stubbed to the checkout root, not the subdirectory,
because that is what real git would report.

#### 6. Documentation

**File**: `docs/manifest.md`
**Changes**: the audit block at `:677-683` splits. The two sabotage entries
move under a new heading naming the work-tree anchor; `gate.guard_ledger`
stays where it is until Phase 2.

```
resolved on the filesystem or handed to git as a pathspec, against the root
of the WORKING TREE the kit is standing in (`git rev-parse --show-toplevel`,
see lib/work_tree.rb) - which is the manifest's checkout root only when the
working tree carries its own .claude/wurk.json:
  gate.sabotage.test_roots / exempt_prefixes as `git diff` pathspecs -
    gate.rb sabotage_diff_args
  the working-tree file reads behind the `# sabotage:` note check -
    gate.rb's default sabotage file reader
resolved against the manifest's checkout root, never the process cwd:
  gate.guard_ledger existence - gate.rb gate_guard_from
```

**File**: `skills/wurk:kit/REFERENCE.md`
**Changes**: the `gate.rb` section gains `data.work_tree_root` - what it is,
that it is the tree the run measured, and that a `work_tree_unresolved`
warning means it is the manifest's checkout root as a fallback rather than
git's answer.

**File**: `docs/plans/260817-wu-9fb-subdirectory-gate-cwd.md`
**Changes**: one annotation, at the definitional mention of the invariant
this bead falsifies (`:519-525`, the manual-verification item; the verbatim
restatement at `:860-866` gets nothing - it is the same fact twice, and
CLAUDE.md says one pointer per document per thing). A reader greps
`checkout_root` and lands on `:522-523`, which is what makes this the pointer
worth leaving.

```
**Later (2026-09-15):** the structural guarantee stated here - "`path` and
therefore `checkout_root` are the same from any invocation directory" - holds
only for invocation directories inside ONE checkout. Across git worktrees it
is false whenever the worktree carries no `.claude/wurk.json` of its own, and
`gate.rb` was silently gating the wrong checkout as a result (wu-1zu). The
subdirectory property this item checks is unchanged and still wanted;
`gate.rb` now gets it from `git rev-parse --show-toplevel`
(`lib/work_tree.rb`), which is invariant across subdirectories and also
per-worktree correct.
```

### Success Criteria:

#### Automated Verification:
- [x] The kit suite passes: `ruby skills/wurk:kit/scripts/test/run.rb`, 0
      failures, 0 errors, 0 skips, and a run count above the 1293 baseline.
- [x] `test_sabotage_diff_and_file_reads_resolve_against_the_worktree_not_the_manifests_checkout`
      fails when the sabotage diff's `chdir:` is reverted to
      `manifest.checkout_root` (the mutation its `# sabotage:` note names).
- [x] `test_sabotage_anchor_is_the_worktree_when_the_walk_up_finds_an_ancestors_manifest`
      passes with no `git rev-parse --git-common-dir` expectation registered,
      proving the nested case is reached through the walk-up.
- [x] The sibling-worktree test calls `@fake.verify!` and passes, proving
      its `git rev-parse --git-common-dir` expectation was actually consumed
      - i.e. `Manifest.locate` really took the fallback branch and the
      walk-up did not escape the fixture to some manifest above `Dir.tmpdir`.
- [x] The renamed subdirectory test passes, i.e. the wu-9fb case still works:
      invoked from `<root>/sub`, the sabotage diff's recorded `chdir` is
      `<root>`.
- [x] `contract_test.rb` passes unchanged - `lib/work_tree.rb`'s shell-out
      goes through `Sh.run` with `envelope: env`, and `gate.rb` acquires no
      write path.
- [x] `ruby skills/wurk:kit/scripts/gate.rb` run in this repo emits
      `data.work_tree_root` equal to this worktree's root, and its `commands`
      trail contains `git rev-parse --show-toplevel`.

#### Manual Verification:
- [ ] In a scratch repo whose `.gitignore` names `.claude/`, with a sibling
      worktree on a branch that adds an unnoted test declaration, `gate.rb`
      run from the worktree reports that declaration in
      `data.sabotage.missing`. Before this phase the same fixture reports
      `missing: []` with `scanned: true` - the research built exactly this
      fixture and recorded both halves.
- [ ] The same scratch repo with the worktree nested under the main checkout
      (case C) gives the same result.
- [ ] `gate.rb` run from a subdirectory of this repo still reports the repo
      root as `data.work_tree_root` and still finds the ledger and the
      sabotage candidates - real git, not a stub.
- [ ] No regressions in `/wurk:commit`'s reading of `data.sabotage`: run it
      on this branch and confirm its pre-commit-checks step report is
      unchanged in shape.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: The gate-guard ledger existence check

### Overview

Research sites 3-5. `gate.guard_ledger` names a tracked file in the tree
(statifier's `docs/quality-gate-changes.md`), so whether it exists is a
property of the branch being gated. The anchor is already a parameter of
`gate_guard_from`; the three call sites hand it the wrong value.

### Changes Required:

#### 1. gate.rb - three call sites

**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**: `gate_guard_from([], ledger_path, manifest.checkout_root)`
becomes `gate_guard_from([], ledger_path, root)` at `:523` (carve-out path)
and `:546` (gate-could-not-start path), and
`gate_guard_from(stages, ledger_path, root)` at `:574` (normal path). The
threaded `root` from Phase 1 is already in scope at all three.

The comment at `:341-343` is updated. It currently states the subdirectory
reason for anchoring on the manifest's checkout root, which was correct for
that case and wrong across worktrees:

```ruby
# Resolved against the root of the working tree being gated, not Dir.pwd and
# not the manifest's checkout root: manifest resolution walks up from the
# working directory, so gate.rb is legitimately invoked from a subdirectory,
# where a bare relative File.exist? silently reports a present ledger as
# absent - and the manifest may have been found in a DIFFERENT checkout
# entirely, where the ledger's presence answers about another branch. See
# lib/work_tree.rb and wu-1zu.
```

#### 2. Tests

**File**: `skills/wurk:kit/scripts/test/gate_test.rb`
**Changes**: one new test in the worktree fixture, and the existing
subdirectory ledger test left alone.

```ruby
# sabotage: pass manifest.checkout_root to gate_guard_from instead of the
# threaded work-tree root -> red (ledger_exists comes back true from the
# ledger in the manifest's checkout, though the tree being gated has none)
def test_ledger_exists_answers_about_the_worktree_not_the_manifests_checkout
```

The fixture writes `docs/quality-gate-changes.md` into the *manifest's*
checkout and not into the worktree, so the current code answers `true` and
the fixed code answers `false`. That direction is deliberate: it is the
branch-adds-or-removes-the-ledger case the research names as the live
failure, and a fixture that put the ledger in both trees could not tell the
anchors apart.

`test_ledger_exists_is_true_when_gate_rb_is_invoked_from_a_subdirectory`
(`:1809`) stays as it is and must stay green - it is the wu-9fb pin, and its
`# sabotage:` note names `File.join(root, ledger_path)` versus a bare
`ledger_path`, which is still the live mutation. Only the value of `root`
changed, not the shape of the check.

#### 3. Documentation

**File**: `docs/manifest.md`
**Changes**: the `gate.guard_ledger existence` line moves from the
manifest-checkout-root list into the work-tree list in the audit block, which
leaves the manifest-checkout-root list in that block empty for the gate
family - so the block's second heading is dropped and the remaining
manifest-relative uses (the ADR lint, the review-agent roots) are named
instead, with a pointer that they are deliberately still manifest-relative
and why (siblings of the manifest inside `.claude/`, except the ADR check,
which is the follow-up bead named in What We're NOT Doing).

### Success Criteria:

#### Automated Verification:
- [x] The kit suite passes: `ruby skills/wurk:kit/scripts/test/run.rb`, 0
      failures, 0 errors, 0 skips.
- [x] `test_ledger_exists_answers_about_the_worktree_not_the_manifests_checkout`
      fails when any of the three call sites is reverted to
      `manifest.checkout_root`.
- [x] `test_ledger_exists_is_true_when_gate_rb_is_invoked_from_a_subdirectory`
      still passes, unmodified.
- [x] `rg "gate_guard_from\(.*checkout_root" skills/wurk:kit/scripts/` returns
      nothing.

#### Manual Verification:
- [ ] In the scratch fixture from Phase 1, add
      `docs/quality-gate-changes.md` on the worktree's branch only, and
      confirm `data.gate_guard.ledger_exists` is true when run from the
      worktree and that the main checkout's absence of the file no longer
      decides the answer.
- [ ] `data.gate_guard.ledger_path` still reports the manifest's own relative
      value, not an absolute path - the distinction `gate_test.rb:1820-1823`
      records.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: The consumer's own gate commands, and the contract

### Overview

Research sites 6-9, the family the research argues is more severe than the
reported symptom: a consumer that declares `gate.cwd` and works in a worktree
without its own manifest runs its entire test suite in the main checkout and
attests the result. This phase makes `Manifest#gate_chdir`'s `root:` keyword
required, so no caller can silently inherit a wrong anchor again, and carries
the `docs/manifest.md` passages that the whole change makes false.

### Changes Required:

#### 1. manifest.rb - `root:` becomes required

**File**: `skills/wurk:kit/scripts/lib/manifest.rb`
**Changes**:

```ruby
# The `chdir:` to hand Sh.run for a gate command, given the root of the
# checkout being gated. nil when the project declares no gate.cwd, so the
# caller's own default applies unchanged - gate.rb passes no chdir at all,
# and the worktree scripts keep passing the worktree path.
#
# `root:` is REQUIRED, not defaulted to checkout_root. It defaulted until
# wu-1zu, and every one of the five production callers that took the default
# was thereby anchored on the checkout the MANIFEST was found in rather than
# the tree being gated - which under worktrees is a consumer's whole gate
# running somewhere nobody asked about. A required keyword makes that class
# of mistake an ArgumentError instead of a silent wrong answer.
def gate_chdir(root:)
  gate_cwd && File.join(root, gate_cwd)
end
```

Removing the default rather than leaving it is CLAUDE.md's replace-don't-
deprecate rule: after this phase no production caller takes it, and a default
nobody takes is a footgun aimed at the next caller.

#### 2. gate.rb and gate_run.rb - pass the anchor

**File**: `skills/wurk:kit/scripts/gate.rb`
**Changes**: `run_quality` takes the anchor and passes it on; the four sites
become explicit.

```ruby
def run_quality(env, manifest, loop_mode, root)
  ...
  res = Sh.run(argv, chdir: manifest.gate_chdir(root: root), envelope: env,
                     timeout: manifest.gate_timeout_seconds)
```

```ruby
# the attest branch (was :588)
verify_res = Sh.run(manifest.gate_attest, chdir: manifest.gate_chdir(root: root), envelope: env,
                    timeout: manifest.gate_timeout_seconds)
```

```ruby
# both data.gate_cwd sites (was :547, :579)
env.data[:gate_cwd] = manifest.gate_chdir(root: root)
```

**File**: `skills/wurk:kit/scripts/gate_run.rb`
**Changes**: `require_relative "lib/work_tree"`; resolve the anchor once
after the manifest guard with the same warn-and-fall-back shape as gate.rb,
report it as `data.work_tree_root`, and use it for the gate `chdir`. The
resolution goes above the `--dry-run` return (`:159-162`) so the dry-run
preview reports the same `chdir` the real run would use.

```ruby
# was :149
chdir = manifest.gate_chdir(root: root)
```

`run_dir` at `:152` keeps `manifest.checkout_root` and gains a comment saying
so deliberately: the detached gate *runs* in the work tree and *records*
beside the manifest, so a `/wurk:cleanup` that removes the worktree cannot
orphan a run still writing its sentinel. See What We're NOT Doing.

The module doc at `gate_run.rb:47` ("and `gate.cwd` via
`manifest.gate_chdir`") names the accessor, and is updated in the same hunk
to name the root it now passes - which is also what makes this phase's grep
criterion decidable.

#### 3. Tests

**File**: `skills/wurk:kit/scripts/test/manifest_test.rb`
**Changes**: the two tests that call `gate_chdir` with no argument
(`:1101-1104`, `:1107-1110`) pass an explicit root. The second one stops
being "joins onto the default checkout root" and becomes the required-keyword
pin:

```ruby
# sabotage: give `root:` a default of checkout_root again -> red
# (ArgumentError is no longer raised, and the assertion that it is fails)
def test_gate_chdir_requires_an_explicit_root
  assert_raises(ArgumentError) { m.gate_chdir }
end
```

`test_gate_chdir_joins_gate_cwd_onto_an_explicit_root` (`:1115-1117`) and
`test_checkout_root_is_two_directories_above_path` (`:1091-1094`) stay exactly
as they are - `checkout_root`'s own definition is unchanged by this plan, and
that test is the pin proving it.

**File**: `skills/wurk:kit/scripts/test/gate_test.rb`
**Changes**: one new test in the worktree fixture, with the `gate_cwd` fixture
already used by the existing `gate.cwd` tests:

```ruby
# sabotage: pass manifest.gate_chdir(root: manifest.checkout_root) instead of
# the threaded work-tree root -> red (the rendered `(cd ... && make report)`
# names <manifest checkout>/backend, and the assertion on
# <worktree>/backend fails)
def test_the_gate_command_runs_under_the_worktree_when_gate_cwd_is_declared
```

The two existing `gate_chdir` tests at `:1651` and `:1678` keep their notes:
`drop chdir: manifest.gate_chdir from run_quality's Sh.run` is still the live
mutation, and nil-when-absent is unchanged.

**File**: `skills/wurk:kit/scripts/test/gate_run_test.rb`
**Changes**: `gate_run.rb start` currently registers no `git` expectations at
all - `Sh.spawn_detached` needs none - so every `start` test that reaches
`Manifest.require!` (`gate_run.rb:143`) needs the new one. Measured: there
are 11 `def test_start_*` methods; `test_start_usage_error_on_slots_dir_without_slots_count`
never calls `run_gr` and the lock-spec usage errors return at `:129`, above
the manifest load, so they need nothing; the rest do. Add a local helper
rather than editing them one at a time:

```ruby
# gate_run.rb start resolves the work-tree anchor once (wu-1zu), the same as
# gate.rb, so every start test authorizes it. Defaults to Dir.pwd, which is
# what real git reports for in_tmp_repo's fixture.
def expect_work_tree(toplevel: nil)
  @fake.expect(%w[git rev-parse --show-toplevel], out: "#{toplevel || Dir.pwd}\n")
end
```

plus one new test that the detached gate's recorded `chdir` is the work tree
while its `run_dir` is under the manifest's checkout:

```ruby
# sabotage: resolve the detached gate's chdir from manifest.checkout_root
# again -> red (the DetachedCall's chdir is the manifest's checkout, not the
# worktree the run was started from)
def test_the_detached_gate_runs_in_the_worktree_and_records_beside_the_manifest
```

#### 4. Documentation

**File**: `docs/manifest.md`
**Changes**, three passages, in the same commit as `lib/manifest.rb` per
CLAUDE.md:

- The `gate.cwd` section (`:624-643`). "The root of the checkout being gated"
  is disambiguated rather than left to be read two ways: for `gate.rb` and
  `gate_run.rb` it is the root of the working tree git reports
  (`git rev-parse --show-toplevel`), and for `worktree_create.rb` /
  `worktree_refresh.rb` it is the worktree path they were handed. The old
  clause "the checkout root for `gate.rb`" is removed, not softened - it is
  the sentence that made the wrong reading look deliberate.
- The restatement at `:1050-1051` ("no `gate.cwd` means the gate commands run
  at the root of the checkout being gated") picks up the same
  disambiguation in one clause.
- The Resolution section's premise (`:1000-1006`). "A worktree is a full
  checkout and carries its own `.claude/wurk.json`" is corrected to a
  conditional: it is true when the consumer *tracks* the file, which is a
  convention and not a guarantee, and when the consumer gitignores `.claude/`
  the walk-up crosses into another checkout or step 2 supplies the main
  checkout. Step 2's stated scope ("the working directory is outside any
  checkout of the repo") is corrected too: it also fires, and routinely, for
  a working directory squarely inside a worktree that has no manifest above
  it. The walk-up-first ordering and its rationale are unchanged and stay -
  what changes is the claim that the ordering makes the manifest's checkout
  and the working tree the same thing. A closing sentence records that the
  kit's gate path no longer depends on the premise (`lib/work_tree.rb`,
  `data.work_tree_root`) and names the lint sites that still do.

**File**: `skills/wurk:kit/REFERENCE.md`
**Changes**: `:370-372` currently reads "Each of the five runs in `gate.cwd`
when the manifest declares one (default the checkout root)". "The checkout
root" becomes the working-tree root, cross-referencing `data.work_tree_root`
from Phase 1.

**File**: `docs/plans/260817-wu-9fb-subdirectory-gate-cwd.md`
**Changes**: one annotation, at the prose that defines `gate_chdir`'s default
root (`:355`) - the definitional mention of a signature this phase removes,
and therefore the thing a reader will grep for. The code fence at `:264`
showing the same signature gets nothing; one pointer per document per thing.

```
**Later (2026-09-15):** `gate_chdir`'s `root:` keyword no longer has a
default. Defaulting it to `manifest.checkout_root` was correct for the
subdirectory case this plan addressed and wrong across git worktrees, where
the manifest may have been found in a different checkout entirely - so a
consumer with `gate.cwd` ran its whole gate in the wrong tree (wu-1zu).
`root:` is now required, and `gate.rb` / `gate_run.rb` pass the working-tree
root from `git rev-parse --show-toplevel` (`lib/work_tree.rb`). The
subdirectory guarantee this paragraph is about is unchanged: that anchor is
invariant across subdirectories too.
```

### Success Criteria:

#### Automated Verification:
- [ ] The kit suite passes: `ruby skills/wurk:kit/scripts/test/run.rb`, 0
      failures, 0 errors, 0 skips.
- [ ] `rg -nP "manifest\.gate_chdir(?!\(root:)"` over
      `skills/wurk:kit/scripts/gate.rb` and
      `skills/wurk:kit/scripts/gate_run.rb`
      returns nothing: every call through the accessor names its root, and
      `gate_run.rb`'s module doc at `:47` has been updated along with it.
      Scoped to those two files on purpose - the `gate_chdir(manifest, path)`
      helpers in `worktree_create.rb` and `worktree_refresh.rb` are a
      different, correctly-anchored local function, and the `# sabotage:`
      notes at `gate_test.rb:1651` and `:1678` name
      `chdir: manifest.gate_chdir` as a mutation and deliberately keep that
      wording.
- [ ] `test_gate_chdir_requires_an_explicit_root` fails if `root:` is given a
      default again.
- [ ] `test_the_gate_command_runs_under_the_worktree_when_gate_cwd_is_declared`
      fails when the anchor is reverted to `manifest.checkout_root`.
- [ ] `test_the_detached_gate_runs_in_the_worktree_and_records_beside_the_manifest`
      passes, and asserts both halves (gate `chdir` under the work tree,
      `run_dir` under the manifest's checkout).
- [ ] `ruby skills/wurk:kit/scripts/manifest.rb check` is clean in this repo -
      the accessor change did not break the lint.
- [ ] `ruby skills/wurk:kit/scripts/gate_run.rb start --dry-run` in this repo
      reports a `chdir` consistent with `data.work_tree_root`.
- [ ] `contract_test.rb` passes unchanged, including its `--dry-run` check on
      `gate_run.rb`.

#### Manual Verification:
- [ ] In a scratch monorepo fixture that gitignores `.claude/`, declares
      `"gate": {"cwd": "backend"}`, and has a sibling worktree: `gate.rb` run
      from the worktree runs the gate command in
      `<worktree>/backend`, not `<main>/backend`. This is the behavior change
      consumers will see, and it is the point of the phase.
- [ ] `gate.rb` in a consumer with no `gate.cwd` still passes no `chdir` at
      all - `data.gate_cwd` is null and the `commands` trail shows no
      `(cd ... && ...)` for the gate command.
- [ ] `docs/manifest.md`'s corrected Resolution section reads correctly to
      someone who has not seen this bead: the premise is conditional, step
      2's scope is right, and the walk-up-first rationale still stands.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Testing Strategy

### The FakeSh-versus-real-git decision

**Chosen: FakeSh, with a new worktree fixture.** No test in
`skills/wurk:kit/scripts/test/` creates a real git repository, commit, or
worktree today, and this plan does not make that suite's first one. The
reasoning, priced honestly:

- `setup` installs `Sh.runner = FakeSh.new` globally, so a real-git fixture
  would have to bypass `Sh` entirely (backticks or `system`) to build its
  repo. That is a second execution path for shell-outs in the test layer, and
  the suite's whole design is that there is exactly one.
- It would need `git init`, a committer identity (`user.name` / `user.email`
  are not guaranteed present in a sandbox or in CI), at least one commit, and
  `git worktree add` - per test, inside `Dir.mktmpdir`, on every platform the
  kit claims (system Ruby at the 2.6.10 floor, ADR-0006). That is a new
  capability with its own failure modes, and it would be carried for one
  bead's worth of coverage.
- The bug is exactly expressible without it. It is a question about *which
  string becomes the anchor*, and a fixture in which
  `manifest.checkout_root != <the stubbed --show-toplevel>` decides it:
  the assertion `diff_call.chdir == <worktree>` is false under the current
  code and true under the fix. That is a genuine regression test, not a
  tautology - which is why each new test above carries a `# sabotage:` note
  naming a mutation that turns it red.
- The fixture can reach both reproduction cases. Case A (sibling worktree,
  no manifest on the walk-up) needs a
  `git rev-parse --git-common-dir` stub for `Manifest.locate`'s fallback;
  case C (nested worktree) needs none, because the walk-up finds the
  ancestor's manifest. Having both is what stops a fallback-only fix from
  passing.

**What FakeSh cannot prove, and where it goes instead.** That real
`git rev-parse --show-toplevel` reports the worktree root rather than the main
checkout, and that it is invariant across subdirectories, are properties of
git and not of this code. The research verified both by hand; this plan does
not re-assert them in a stub that would only be testing its own fixture.
They are Deferred Manual Verification items, run against real git in a real
worktree.

### Unit Tests:

- `test/work_tree_test.rb` (new) - `WorkTree.root` over FakeSh: success
  returns the expanded toplevel; non-zero exit returns nil; empty stdout
  returns nil; the call lands in the envelope's `commands` trail.
- `test/gate_test.rb` - the four new anchor tests (sibling worktree, nested
  worktree, unresolved fallback, `data.work_tree_root`), the ledger test in
  the worktree fixture, and the `gate.cwd` test in the worktree fixture. Two
  existing tests updated in place rather than replaced: the subdirectory
  sabotage test (`:1831`, renamed with a rewritten note) and the
  fixture-construction comment at `:185-191`.
- `test/gate_run_test.rb` - the detached gate's `chdir` versus its `run_dir`,
  plus the `expect_work_tree` helper for the 11 existing `start` tests.
- `test/manifest_test.rb` - `gate_chdir` requires `root:`;
  `checkout_root`'s own definition unchanged and still pinned.
- `test/contract_test.rb` - unchanged, and that is a criterion: the new
  shell-out must satisfy its existing rules rather than need new exemptions.

Key edges covered: the two divergence mechanisms (fallback and walk-up), the
subdirectory invariant, the degraded path when git cannot answer, and the
distinction between "the tree being gated" and "the directory the manifest
lives in" at every site that now resolves one of them.

### Manual Testing Steps:

1. Build the research's scratch fixture (its item 1, "Empirical
   reproduction"): a repo whose `.gitignore` names `.claude/`, one committed
   noted test, a sibling worktree on a branch adding an unnoted test
   declaration, a manifest declaring `gate.sabotage.test_roots`.
2. Run `gate.rb` from the worktree. Confirm `data.sabotage.missing` names the
   unnoted declaration, `data.work_tree_root` is the worktree, and the
   `commands` trail shows the sabotage diff running with `(cd <worktree> &&
   ...)`.
3. Move the worktree to be nested under the main checkout and repeat. Same
   result, and the trail shows no `--git-common-dir` call.
4. Add `"cwd": "backend"` to the fixture's `gate`, with a `backend/`
   directory in both trees, and confirm the gate command runs in
   `<worktree>/backend`.
5. Delete `.git` from the fixture's worktree (or run from `/tmp`) and confirm
   the `work_tree_unresolved` warning fires, `data.work_tree_root` is the
   manifest's checkout root, and the envelope is still well-formed.
6. In this repo - where `.claude/wurk.json` is tracked, so the bug does not
   reproduce - run `gate.rb` from the repo root and from
   `skills/wurk:kit/scripts/` and confirm `data.work_tree_root` is identical
   both times. This is the wu-9fb regression case against real git.

## Decisions taken without a human in the loop

This plan was authored unattended, so every question that would normally have
been asked was decided here rather than left open. Each has a decision the
implementer can follow as-is; each is also the place to push back if the
judgment was wrong. Nothing below blocks implementation.

1. **Scope is the gate path: research sites 1-9, not just the bead's 1-2, and
   not sites 10 and 13.** The bead names the two sabotage sites. Sites 3-5
   ride along because they are in the same method chain, on the same threaded
   value, and leaving them would mean one gate.rb envelope reporting
   `sabotage` from one tree and `gate_guard` from another - the mixed-anchor
   incoherence the research documents as a finding in its own right. Sites
   6-9 ride along because the research's severity argument is convincing: a
   consumer with `gate.cwd` runs its whole suite in the wrong checkout and
   attests it, which is worse than the reported symptom and has the identical
   one-line-per-site fix once the anchor exists. Stopping at 1-2 would be
   fixing the reported bug and knowingly leaving a worse instance of the same
   root cause in the same file, which CLAUDE.md's "finish the job" rules out.
   Sites 10 and 13 are excluded because they are in `manifest.rb`'s lint
   rather than the gate, pull in opposite directions from each other, and
   want one decision made together - a follow-up bead, named in What We're
   NOT Doing. If a reviewer wants the narrow bead, Phases 2 and 3 drop
   cleanly and Phase 1 alone closes wu-1zu as filed.
2. **Degraded behavior is warn-and-fall-back, not `block!` and not a new
   `unverifiable` reason.** Reasoned at length in Implementation Approach.
   The load-bearing part: an `unverifiable` entry would cover only the
   sabotage scan while the ledger and `gate_chdir` still need a root, so it
   would leave two degradation stories; and the realistic failure is already
   reported through `no_base_ref`, which fires first. If a reviewer wants the
   `no_work_tree` reason anyway, it is additive - a fourth `reason` value in
   `gate.rb`'s scan plus a sentence in `REFERENCE.md:423-429` and one in
   `skills/wurk:commit/SKILL.md` - and it does not change anything else in
   this plan.
3. **`data.work_tree_root` is added to the envelope.** One line, and it is
   what makes the fix verifiable in the envelope rather than only in the
   rendered `commands` string. It is also the answer to the "a warning is
   easy to skim" objection against decision 2. Same reasoning wu-9fb used to
   add `data.gate_cwd` (its decision 3).
4. **The resolution is unconditional, which adds one line to every
   consumer's `commands` trail.** This revises wu-9fb's decision 1, which
   chose `chdir: nil` for absent `gate.cwd` specifically to keep the trail
   byte-identical for consumers not using the field. The revision is
   deliberate: every gate.rb path now needs the anchor (the carve-out path
   included, via `gate_guard_from`), a lazy form would need a memo that leaks
   across the many `Gate.run` calls one test process makes, and the reason
   this bug was invisible is that nothing in the envelope said which tree had
   been measured. A reviewer who values the byte-identical trail more should
   expect a memo with an explicit reset in the test teardown, not a cheaper
   fix.
5. **`Manifest#gate_chdir`'s `root:` becomes required (Phase 3).** After this
   plan no production caller takes the default, and a default nobody takes is
   aimed at the next caller. Making it required converts this bug class into
   an `ArgumentError`. It costs two `manifest_test.rb` edits and one
   annotation on the wu-9fb plan. If a reviewer prefers the smaller diff,
   keeping the default is a one-line revert of that hunk and the rest of
   Phase 3 stands.
6. **Tests are FakeSh-level; the suite gains no real-git capability.**
   Reasoned in Testing Strategy. The two properties FakeSh cannot reach are
   properties of git, and they go to Deferred Manual Verification rather than
   into a stub that would test the fixture.
7. **The new helper is `in_tmp_worktree`, a sibling of `in_tmp_repo` rather
   than a parameter on it.** 44 `gate_test.rb` tests depend on
   `in_tmp_repo`'s invariant that the manifest sits at the root it chdirs
   into; a flag that broke that invariant conditionally would put the
   fixture's shape in the caller's head rather than in the helper's name.
8. **Two annotations on the wu-9fb plan, not a sweep.** `:519-525` (the
   invariant, in Phase 1) and `:355` (the removed `gate_chdir` default, in
   Phase 3). The verbatim restatement at `:860-866` and the code fence at
   `:264` get nothing: one pointer per document per thing, at the
   definitional mention. Both are annotations in the
   `**Later (2026-09-15):** ...` shape and neither rewrites a word of the
   original. No stale line numbers or step positions are chased through any
   dated document.
9. **`docs/manifest.md`'s audit block is edited in each of the three phases**
   rather than once at the end, so no commit ships code whose documentation
   describes the previous behavior. The cost is that a reader of the
   three-commit range sees the block change three times; the alternative is
   two commits with a knowingly wrong doc, which the same-commit rule exists
   to prevent.

## Open questions recorded rather than resolved

No human was available, so these are recorded here and repeated in the plan
stage's report. None blocks implementation; each is a thing a reviewer may
decide differently, and each names what would change if they did.

1. **Which consumer hit this** (research open question 6). The bead's framing
   implies a specific consumer repo that gitignores `.claude/`; knowing which
   one, and whether its worktrees are siblings (case A) or nested (case C),
   would let someone confirm the reproduction matches the report and run the
   manual verification against the real thing rather than a scratch fixture.
   The fix covers both cases, so this does not block - but the Phase 1 manual
   item is weaker for having to build its own fixture.
2. **Whether tracking `.claude/wurk.json` should become a stated
   requirement** (research open question 5). This plan corrects the doc's
   claim that a worktree always carries its own manifest and removes the
   gate's dependence on it. It does not decide whether `/wurk:branch` or
   `worktree_create.rb` should place a manifest in each new worktree, or
   whether the convention should be documented as a requirement. That is a
   consumer-facing decision and wants its own bead if anyone wants it.
3. **Whether the follow-up bead for sites 10 and 13 should also revisit
   `Manifest.main_checkout` versus `main_checkout_root`.** The two
   similarly-named mechanisms are a deliberate coexistence
   (`docs/plans/260810-wu-2cb-default-branch-base-ref-from-manifest.md:174`
   decided against renaming), and site 13 wants the first of them. With
   `WorkTree.root` added there are now three root concepts in the kit; a
   reviewer may want them named as a set in `docs/architecture.md`. This plan
   documents the rule in `lib/work_tree.rb`'s own comment and in
   `docs/manifest.md`, and does not open the naming question.

## References

- Research document:
  `docs/research/260915-wu-1zu-gate-sabotage-scan-worktree-checkout-root.md`
  (the thirteen-site classification, the empirical reproduction of cases A
  and C, the four candidate approaches, and the three degraded-behavior
  shapes)
- Direct predecessor:
  `docs/plans/260817-wu-9fb-subdirectory-gate-cwd.md` (introduced
  `checkout_root`, `gate.cwd` and `gate_chdir`; its manual-verification item
  states the invariant this bead falsifies) and
  `docs/research/260817-wu-9fb-subdirectory-gate-cwd.md`
- Related ADRs: `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`
  (stdlib-only system Ruby, one envelope, every shell-out through
  `lib/sh.rb` with `envelope: env`, `contract_test.rb` enforcing it),
  `docs/adr/0004-manifest-and-extension-seams.md` (the manifest seam; no
  schema field is added here, but `docs/manifest.md` moves with
  `lib/manifest.rb`), `docs/adr/0005-gate-contract-tiers.md` (tiers are
  unaffected - this changes where a tier's command runs, not what it proves)
- Schema and contract: `docs/manifest.md` (`gate.cwd` at `:622-684`,
  Resolution at `:989-1006`, the restatement at `:1050-1051`),
  `skills/wurk:kit/REFERENCE.md` (`gate.rb`'s envelope at `:364-429`, the
  `in_tmp_repo` note at `:360-362`), `docs/architecture.md:43-67` (the script
  contract)
- Existing `--show-toplevel` pattern to model after:
  `skills/wurk:kit/scripts/worktree_create.rb:571-581` (`main_checkout_root`
  - its `--show-toplevel` call and nil-on-failure degradation, without its
  main-checkout guard)
- The correct `root:` callers, and the proof the seam already works:
  `skills/wurk:kit/scripts/worktree_create.rb:439-440`,
  `skills/wurk:kit/scripts/worktree_refresh.rb:161-162`
- The warn-on-a-worse-answer precedent:
  `skills/wurk:kit/scripts/lib/base_ref.rb:26-29` (`stale_base_ref`)
- Sabotage-note discipline: `docs/recipes/sabotage-testing.md`
- Bead: `wu-1zu`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Build the research's case-A scratch fixture (a repo whose `.gitignore`
      names `.claude/`, a committed noted test, a sibling worktree on a
      branch adding an unnoted test declaration, `gate.sabotage.test_roots`
      declared). Run `gate.rb` from the worktree and confirm
      `data.sabotage.missing` names the unnoted declaration. The research
      recorded the before state for this exact fixture - `missing: []` with
      `scanned: true` - so the comparison is direct
- [ ] Repeat with the worktree nested under the main checkout (case C). Same
      result, and no `--git-common-dir` call in the trail
- [ ] Run `gate.rb` in this repo from the root and from
      `skills/wurk:kit/scripts/`. Confirm `data.work_tree_root` is identical
      both times, and that the ledger and sabotage results are identical
      both times. This is the wu-9fb subdirectory invariant against real
      git, and it is the one property no stub can establish
- [ ] Confirm `/wurk:commit`'s pre-commit-checks step report on this
      branch is unchanged in shape - no new `reason` value reaches it,
      which is what decision 2 is betting on

### Phase 2

- [ ] In the case-A fixture, add `docs/quality-gate-changes.md` on the
      worktree's branch only and declare it as `gate.guard_ledger`. Confirm
      `data.gate_guard.ledger_exists` is true from the worktree, and that
      deleting it from the main checkout does not change the answer
- [ ] Confirm `data.gate_guard.ledger_path` still reports the manifest's own
      relative value rather than an absolute path

### Phase 3

- [ ] In the case-A fixture, add `"cwd": "backend"` to `gate` with a
      `backend/` directory in both trees. Confirm the gate command runs in
      `<worktree>/backend` and not `<main>/backend`. This is the
      consumer-visible behavior change and the point of the phase
- [ ] Confirm a consumer with no `gate.cwd` still gets no `chdir` for its
      gate command at all: `data.gate_cwd` null, and no `(cd ... && ...)`
      wrapper on the gate command in the `commands` trail
- [ ] Start a detached gate from the worktree (`gate_run.rb start`) and
      confirm the gate runs in the worktree while the run directory is under
      the manifest's checkout `.claude/wurk-runs/gate/`, and that `poll` and
      `status` find it
- [ ] Read the corrected Resolution section in `docs/manifest.md` cold and
      confirm it is right: the worktree premise is conditional, step 2's
      scope includes a manifest-less worktree, and the walk-up-first
      rationale still stands on its own

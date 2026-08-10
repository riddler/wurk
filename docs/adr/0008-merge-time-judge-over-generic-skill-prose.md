# ADR-0008: Wurk judges its own generic skill prose at merge time

Status: accepted (2026-08-10)

## Context

Statifier-ex's ADR-0017 restates what it calls constraint 4 - judgment is
not scriptable - and scopes its model judge (`Mix.Statifier.AdrJudge`) to
the extension files that repo still owns, `.claude/wurk/**`. Its second
open question is explicitly an upstream flag: because extensions add and
never override (ADR-0004), the natural direction for a policy call to
erode is upward, into the generic SKILL.md the extension extends. Once a
judgment step is generalized into `skills/wurk:*/SKILL.md` it leaves every
downstream gate's reach at once. From the downstream side the migration
reads as a deletion; from this side it reads as a generalization; no judge
anywhere reads the two together. Statifier's ADR-0016 named the exposure
and correctly declined to decide it downstream. This record is the
upstream answer (bead wu-0b2, filed from statifier st-jjk).

The exposure is not hypothetical about this repo's content. The generic
skills are dense in exactly the prose at stake: `wurk:commit`'s auto-mode
refusal conditions and its gate-guard ledger rule ("a human's call, never
auto mode's"), `wurk:implement`'s phase-advancement gate and its
stop-the-loop refusals, `wurk:mr`'s refuse-on-red and its
never-close-the-bead rule, `wurk:work`'s sizing buckets and
pick-the-heavier-one tie-break. Each is a policy call stated in prose that
a future edit could quietly hand to a script - and the kit makes that easy,
because the sanctioned home for mechanics is right next door (ADR-0006).
The tell, as statifier's ADR-0017 fixes it, is prose that turns a
discipline into a check on its own artifact: a script can confirm a
marker comment exists, which converts "break the code and watch it go
red" into a comment-formatting rule.

Four responses were priced:

- **A model judge in this repo, at the merge seam.** The statifier module
  is 719 lines of Elixir, but most of that is Elixir-specific packaging
  (mix task, ExQuality finding contract, Sobelow workarounds). What
  transfers is small and language-neutral: a registry entry (data), diff
  collection scoped by path prefix, two prompts (propose, then an
  independent refute grounded in the same hunks), fail-closed parsing.
  Statifier measured the grounded propose/refute design at 0 false
  positives and 0 false negatives on its 8-fixture corpus, with a real
  run near 20 seconds on sonnet. A Ruby-stdlib rewrite on the kit's
  existing `lib/sh.rb` and FakeSh harness is a few hundred lines plus
  tests.
- **Do nothing.** Review is the only cover, this repo changes fast and
  largely by agent, and a swallowed judgment step is precisely the diff
  review is worst at: it looks like tidying. The downstream judges cannot
  compensate - they never see a wurk diff.
- **A cheaper non-model check.** Ruled out by the constraint's own
  premise, which statifier's ADR-0015 stated and this repo inherits: a
  script that claimed to detect swallowed judgment would itself be the
  violation. Deciding whether a SKILL.md rewrite delegated a policy call
  is a judgment call by construction.
- **Push it downstream via the gate contract (ADR-0005).** Wrong seam.
  Consumer gates run over consumer diffs; a wurk skill edit reaches a
  consumer only at `git pull` time (ADR-0002), after it has landed, with
  no diff in front of any downstream judge. Making consumers re-judge
  pulled skill text would also duplicate one authoritative check into N
  drifting echoes - the exact anti-pattern statifier's ADR-0017 point 3
  warns against.

One more constraint shapes the mechanism. This repo's required gate is
`ruby skills/wurk:kit/scripts/test/run.rb`: offline, deterministic,
zero-install on system Ruby (ADR-0002, ADR-0006). A check that needs a
`claude` CLI, a network round trip, and real spend does not belong inside
it. Statifier faced the same tension and put its judge at the merge seam,
opt-in, skipping cleanly with a stated reason when it cannot run. Wurk is
a consumer of itself (ADR-0007), so it has the same seam available: its
own `.claude/wurk/mr.md` extension, read by the generic `wurk:mr` skill.

## Decision

**Wurk takes up the mirrored constraint-4 judge over its own
`skills/**/SKILL.md` prose, as a kit script under the envelope contract,
invoked at merge time through wurk's own `wurk:mr` extension - not inside
the required deterministic gate.**

1. **The constraint, stated for this surface.** A `skills/*/SKILL.md`
   file may name a kit script for mechanics, and must state the policy
   itself wherever a step is a policy call, a human gate, or a
   verification discipline. Handing such a step to a script - or deleting
   it during a rewrite rather than restating it - is the violation. The
   failure mode is a step that used to state a decision now delegating
   it, and the tell is prose that turns a discipline into a check on its
   own artifact: a script can confirm a note or marker exists, which
   converts a verification discipline into a formatting rule. When a step
   needs judgment, the script reports the inputs and the model decides.
   This paragraph must be readable standing alone, because it is the text
   shipped to the judge; statifier's ADR-0017 is the long-form reasoning
   and its ADR-0015 holds the two original worked examples.

2. **The mechanism is a kit script, judged mechanics only.** A script
   (working name `skill_judge.rb`) collects the branch diff against its
   base, scopes it to `skills/**/SKILL.md`, ships the scoped hunks plus
   this ADR's text to a model twice - one call proposes violations, an
   independent second call is prompted to refute each, grounded in the
   same hunks - and reports only survivors. It speaks the ADR-0006
   envelope, shells out (git and the `claude` CLI alike) through
   `lib/sh.rb`, parses fail-closed (an unparseable response is "no
   finding" on propose and "not a violation" on refute), and touches
   nothing on the banned-operation list. This split is itself
   constraint-4-shaped and deliberate: the script owns diff plumbing and
   prompt assembly, the model owns the verdict, and the skill prose owns
   what to do about a finding.

3. **It runs at the merge seam, not in `run.rb`.** The required gate
   stays offline and deterministic. Wurk's own `.claude/wurk/mr.md`
   extension declares the judge as an additional pre-request step, which
   `wurk:mr` already honors as required (extensions add). A finding that
   survives the refute pass is a refusal condition for opening the
   request. When the `claude` CLI is absent or no base ref resolves, the
   script reports a skip with its reason in the envelope rather than
   failing or passing silently - ADR-0005's rule that weaker is
   acceptable and vaguer is not applies to this repo's own seams too.
   The generic `wurk:mr` skill learns nothing wurk-specific; the step
   enters through the same consumer seam every other project uses
   (ADR-0004), which is also a live test of that seam (ADR-0007).

4. **The script's mechanics are still gated.** The suite covers scoping,
   prompt assembly, envelope shape, fail-closed parsing, and skip
   behavior against a stub caller; the contract test covers it like any
   other script. No test makes a real model call - statifier's st-c8c
   incident (a forgotten stub costing minutes of gate time and real
   spend per run) is the reason that rule is stated here rather than
   left to taste.

5. **The registry is data and starts at one entry.** Scope prefix
   `skills/`, suffix `SKILL.md`, judged text: this file. Adding a second
   judged constraint later means adding an entry, not a mechanism.

## Consequences

- Statifier-ex's ADR-0017 second open question is resolved by citing this
  record: yes, wurk carries the mirrored judge, upstream, over the surface
  the downstream judges cannot see. The two judges now tile the migration
  path - a policy call leaving `.claude/wurk/*.md` is judged there as a
  deletion, and its arrival in a generic skill is judged here as a
  rewrite of `skills/**/SKILL.md`.
- Follow-up implementation work is implied and is not part of this
  record: the script, its tests, and wurk's `.claude/wurk/mr.md` (which
  does not exist yet - this repo currently consumes itself through the
  manifest alone). This ADR is written to be the judge's verbatim input,
  so the implementation cites it by path and restates nothing.
- The required gate's properties are preserved: `run.rb` stays green or
  red for the same tree on any Mac with no network and no credentials.
  The cost of that choice is that skill-prose-only branches are judged
  only when they go through `wurk:mr` - a branch merged by hand around
  the skill is not judged. That is the same exposure statifier accepted
  for its merge-profile stage, and the same answer applies: the judge
  fronts the request seam because that is where an irreversible action
  is about to happen.
- Model spend and ~20-60 seconds of wall clock land on merge requests
  that touch skill prose, and nowhere else. Diffs touching only scripts,
  docs, or agents skip with a stated reason.
- A false positive blocks a request rather than a commit. The
  adversarial refute pass is what makes that bar tolerable; if findings
  prove noisy in practice, the fix is the statifier route - ground the
  prompts harder, measure on fixtures - never a downgrade of the finding
  to advisory, and never a mechanical pre-filter (point 2's split is
  load-bearing).
- Three repos' records now describe one constraint at three scopes:
  statifier ADR-0015 (history and worked examples), statifier ADR-0017
  (`.claude/wurk/**` downstream), this record (`skills/**/SKILL.md`
  upstream). Predicator-ex and fixative inherit the upstream coverage
  without doing anything.

## Open questions

Recorded rather than guessed at; no maintainer was available when this
record was written.

- **Should the scope also cover `docs/manifest.md` and the schema seam?**
  The judged surface is skill prose, but ADR-0004 gives policy a second
  way out of prose entirely: re-expressing a judgment call as a manifest
  key whose value a script consumes. That move lands as a schema change
  plus a skill edit, so the skill-side half is in scope here, but the
  seam mirrors statifier's own open question about `.claude/wurk.json`
  (tracked there as st-8nj). Left as written until such a change is
  actually proposed; whoever proposes one should read both questions
  first.
- **Should wurk's own `.claude/wurk/*.md` files, once they exist, join
  the scope?** They would be judgment-bearing prose this repo owns, and
  the marginal cost is one registry entry. Deferred until the first such
  file exists with a policy call in it; `mr.md` as specified here is
  procedural and thin.
- **Which model, and measured how?** Statifier picked its default by
  running a fixture corpus against two models and letting latency decide
  after accuracy tied. The implementation bead should decide whether to
  port a corpus harness in the first pass or start with the propose and
  refute unit seams only and add the corpus when the first disputed
  finding arrives.

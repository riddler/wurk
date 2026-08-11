# ADR-0010: Bounded, opt-in auto-resolution of rebase conflicts in /wurk:mr

Status: accepted (2026-08-11)

## Context

`RebaseOnto.perform` (`skills/wurk:kit/scripts/rebase_onto.rb`) has exactly
one behavior on a failed rebase: capture the conflicting paths, `git rebase
--abort`, and `block!(code: "rebase_conflict", needs: "human")`. That is
correct for a genuine semantic collision and heavy-handed for the common
case. On wu-902 (2026-08-09), a branch and main both edited disjoint clauses
of the same `docs/plan.md` paragraph - a two-line mechanical merge - and a
human was asked to authorize it, costing a full abort-then-restart skill
cycle.

The bead that opened this work (wu-y7d) states its own warning up front: an
auto-resolver that is wrong is worse than one that never runs, because the
human gate it replaces was the only check on it. It names four categories
that must never auto-resolve - code, a lockfile, a manifest, or a
gate-guarded file - and it names the safety net's real gap: the gate runs
after the rebase in both skills, so a bad code resolution is caught, but a
bad doc resolution is not, and doc files are precisely the ones most likely
to qualify as "simple." "Bias hard toward stopping" is the bead's own
framing, not an addition made here.

## Decision

**A bounded, opt-in auto-resolution path is added to `/wurk:mr` only, gated
by a manifest allowlist, a deterministic additive-merge proof, and an
adversarial model refute - and `rebase_onto.rb` is not touched.**

1. **Opt-in allowlist.** Auto-resolution is considered only for a conflict
   whose every path matches `rebase.auto_resolve_paths`, a new manifest list
   that defaults to `[]`. The list is validated disjoint from
   `gate.build_paths`, `gate.also_gated_paths`, `gate.moving_files`,
   `gate.guard_ledger`, and `parallelism.repair_when`, and additionally
   disjoint from the manifest's own directory (`.claude/`, which holds the
   manifest itself and every extension file, per ADR-0004's two seams).
   Those five path lists cover the bead's "code", "lockfile", and
   "gate-guarded file" categories; the `.claude/` rule covers "manifest".
   All four stop categories are therefore satisfied by validated
   construction, not by four new content predicates written against this
   feature - and validated, not documented, because a documented rule is
   one a careful consumer follows and a careless one does not. An
   allowlist that resolves to the whole repo (an entry of `/`, `""`, or
   `.`) is also rejected; naming everything is not opting in to anything.

2. **`rebase_onto.rb` is untouched.** Its source-text refutations in
   `rebase_onto_test.rb` (no `checkout --ours|--theirs`, no `git add`, no
   `rebase --continue`) are a settled invariant, not an artifact this
   change amends. The resolver lives in a new script instead. This also
   scopes the feature to `/wurk:mr` for free: `/wurk:refresh` reaches the
   rebase only through `RebaseOnto.perform`, which this change does not
   call, so `/wurk:refresh` cannot auto-resolve even by later omission.

3. **The ADR-0008 split applies verbatim.** The new script owns rebase
   plumbing, blob capture, the deterministic screens, prompt assembly, and
   fail-closed parsing of the model's responses. The model owns two things
   only: proposing a merge, and independently refuting it. `/wurk:mr`'s own
   prose owns what to do about the result - report it, request it, or stop.
   No test in the suite makes a real model call, for the same reason
   ADR-0008 states it for `judge.rb`: a forgotten stub costs spend and gate
   time on every run, not just the first.

4. **The deterministic net.** A proposed resolution is applied only if a
   pure function proves three things: every whitespace-normalized,
   non-empty line unique to either side of the conflict survives into the
   merge; the merge invents no line absent from all three of base, ours,
   and theirs; and no conflict markers remain. This is what makes reflowed
   prose stop rather than resolve - a re-wrapped paragraph invents lines
   that exist in none of the three inputs, so the invariant rejects it by
   construction. This net exists because, for the file class most likely
   to qualify under an allowlist (documentation), the gate does not run at
   all in this repo: `docs/plan.md` matches neither `build_paths` nor
   `also_gated_paths` here, so a docs-only resolution would otherwise reach
   `gate.rb` with `applicable: false` and no check at all.

5. **Reporting is part of the mechanism.** A resolution that is not named
   in `/wurk:mr`'s step 6 summary and carried into step 7's request body is
   a defect, not a nicety. It is the substitute for the gate coverage
   Decision 4 explains is missing for the file class this feature targets;
   silence would mean the one class of change most likely to auto-resolve
   is also the one a reviewer is least likely to know happened.

6. **The refute polarity is inverted relative to `judge.rb`.** In
   `judge.rb`, an unparseable refute response means "not a violation" and
   the request proceeds - fail-closed there means closed toward blocking a
   request. Here, an unparseable refute response means "the objection
   stands" and the resolution is abandoned in favor of the ordinary
   abort-and-stop path - fail-closed here means closed toward *not*
   applying a merge. Both directions fail closed toward the same value,
   stopping rather than proceeding; they read as opposite polarities only
   because the risky action they guard is reversed. In `judge.rb` the risky
   action is blocking a request that should have gone through; here the
   risky action is applying a merge that should not have been trusted.

## Consequences

- `/wurk:refresh` is unchanged in every respect; it keeps today's
  capture-abort-report behavior for every conflict, and this ADR does not
  ask it to do otherwise (see Decision 2).
- Every consumer starts with the feature off: `rebase.auto_resolve_paths`
  defaults to `[]`, and an empty allowlist can never satisfy Decision 1's
  "every path matches" test.
- The reflow limitation is permanent for this pass, not a bug to be fixed
  next: a merge that needs a re-wrapped paragraph will stop under Decision
  4 even when a human would call it obviously fine. Widening the invariant
  to tolerate reflow is future work gated on measurement against real
  disputed cases, not a first-pass convenience.
- Model spend and latency land only on `/wurk:mr` runs that both conflict
  on rebase and have every conflicting path inside the consumer's
  allowlist. Every other run - no conflict, a conflict outside the
  allowlist, or a consumer that never opts in - pays nothing new.
- A widening of `rebase.auto_resolve_paths`, or of the deterministic
  invariant in Decision 4, is a decision to be measured against real
  outcomes when proposed, never assumed as a natural next step of this
  ADR.

### Answer to ADR-0008's first open question, for this change

ADR-0008 left open whether its judged surface should also cover
`docs/manifest.md` and "the schema seam" - the observation that a policy
call can leave prose entirely by being re-expressed as a manifest key a
script consumes, which is exactly what `rebase.auto_resolve_paths` is.

For this change, the answer is: the schema seam is in scope for the judged
surface only to the extent the skill-side half of the same decision is, and
this change keeps that half in prose. `rebase.auto_resolve_paths` itself
carries no policy - it is a path list, data, validated for disjointness by a
kit script the way any other manifest field is. The policy call this
feature makes - that a conflict confined to an allowlisted path, passing the
deterministic net and the refute pass, may be applied without a human -
is stated as prose in `skills/wurk:mr/SKILL.md`, where ADR-0008's judge
already looks. A consumer manifest can therefore turn the feature on or off
per project without that act alone being a policy change subject to the
judge; only a rewrite of the `/wurk:mr` prose that states the policy is.

## Open questions

None carried forward from ADR-0008 remain unanswered for this change; its
first open question is answered above. Its second and third open questions
concern `.claude/wurk/*.md` scope and model selection for
`skill_judge.rb`, which this ADR does not touch.

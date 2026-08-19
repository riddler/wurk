---
date: 2026-08-19T04:01:22-0600
researcher: Claude
git_commit: cb3ad01bb889c81a2b04de3452654ffa43e8d5f6
branch: wu-7l5-dmv-backlog-skill
repository: wurk
beads_issue: wu-7l5
topic: "How Deferred Manual Verification items and open questions are produced, stored, and could be enumerated for a /wurk:dmv backlog skill"
tags: [research, codebase, plan_state, skills, dmv, open-questions]
status: complete
last_updated: 2026-08-19
last_updated_by: Claude
---

# Research: the DMV and open-question backlog, as the codebase holds it today

**Date**: 2026-08-19T04:01:22-0600
**Git Commit**: cb3ad01bb889c81a2b04de3452654ffa43e8d5f6
**Branch**: wu-7l5-dmv-backlog-skill
**Bead**: wu-7l5

## Research Question

wu-7l5 asks for a new `/wurk:dmv` skill that works the backlog of Deferred
Manual Verification items and open questions left behind after
`/wurk:work --auto` finishes. This document maps what exists today, so a plan
can be written against reality rather than against the bead's description of
it: how DMV items are produced and stored, how open questions are recorded,
what the Direction stage actually is and where a shared copy of it could live,
what the kit script contract and test harness would demand of any new script,
what the skill conventions are, and which accepted ADRs constrain the answer.

## Summary

The two halves of the wanted backlog are not symmetric, and that asymmetry is
the central finding.

**Deferred Manual Verification is a real, machine-parsed grammar.** It has one
anchored regex ([`skills/wurk:kit/scripts/plan_state.rb:29`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/plan_state.rb#L29)), one writer
(`plan_state.rb defer`, called by `/wurk:implement --loop`), a fixed
three-line intro paragraph that appears verbatim in every plan that has one,
a stable `### Phase N` subheading per phase, and GFM checkboxes as the item
unit. `plan_state.rb validate` already reports the section's presence and
line, and `work_state.rb` already surfaces that per bead. Thirteen of the
repo's thirteen plan documents carry the section; seven of them still hold
102 unchecked items across them. What the kit does *not* have is any way to
read the items back out of that section, or to check one off: `parse` reports
`deferred_manual_section: {present:, line:}` and nothing more, and
`check`/`uncheck` operate only on a phase's Automated Verification boxes,
refusing a `--line` that targets a Manual box
(`plan_state.rb:301-318`). Enumerating and marking DMV items is therefore a
small, well-defined extension of an existing parser, not new territory.

**Open questions have no grammar at all.** The heading is optional everywhere,
it is written in at least four distinguishable forms across the corpus
(`## Open Questions`, `## Open questions`, `### Open questions`, and one with
a parenthetical suffix), the content underneath is prose in some documents and
numbered bold-lead-in lists in others, no document anywhere uses checkboxes
for them, and resolution is marked three different ways (strikethrough plus
bold "Settled", a nested "**Settled after the loop**" sub-note, or an inline
"Resolved:" prefix). Worse, the same heading carries two different meanings:
in research documents it means "genuinely unresolved", while in the three plan
documents that have one it means "a non-blocking judgment call, recorded so it
can be overturned cheaply" - because `/wurk:plan` forbids unresolved questions
in a final plan ([`skills/wurk:plan/SKILL.md:336`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:plan/SKILL.md#L336), `:399-401`) while
`/wurk:work` simultaneously instructs its subagents to record open questions in
the artifact they produce ([`skills/wurk:work/SKILL.md:266-270`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L266-L270)). No script
parses any of this. A machine-readable convention for open questions does not
exist today and would have to be established.

**The Direction stage is prose, not a skill.** It is the one row of
`/wurk:work`'s stage table with nothing to mirror: no stage skill, a prompt
composed directly into the Agent call
([`skills/wurk:work/SKILL.md:245`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L245), `:256-260`, `:277-293`), and a model read
from the manifest's `models.direction`
(default `opus`, accessor at `lib/manifest.rb:422-424`). There is no precedent
in this repo for one SKILL.md reading another SKILL.md as shared content. The
one shared document skills are told to go read is
`skills/wurk:kit/REFERENCE.md`, cited by a fixed sentence in twelve skills.
The established idiom for skill-to-skill sharing is citation by name, stated
explicitly at [`skills/wurk:iterate/SKILL.md:14-16`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:iterate/SKILL.md#L14-L16): "link to it by name rather
than restating it - two copies drift."

**Adding a skill is mechanically free.** `install.rb` globs `skills/wurk:*`
([`install.rb:49`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/install.rb#L49), `:73-75`); no registry, no test, and no list enumerates
skills by name. The contract test globs `skills/wurk:*/SKILL.md` and will
scan a new file automatically for consumer vocabulary.

## Detailed Findings

### 1. How Deferred Manual Verification items are produced and stored

**The grammar.** [`skills/wurk:kit/scripts/plan_state.rb:20-29`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/plan_state.rb#L20-L29) defines the
whole surface:

```ruby
ANY_HEADING_RE = /\A\#{2,4} /.freeze
H2_RE = /\A## /.freeze
PHASE_HEADING_RE = /\A## Phase (\d+): (.+?)\s*\z/.freeze
AUTOMATED_HEADING_RE = /\A#### Automated Verification:/.freeze
MANUAL_HEADING_RE = /\A#### Manual Verification:/.freeze
CHECKBOX_RE = /\A- \[( |x)\] (.+)\z/.freeze
DEFERRED_HEADING_RE = /\A## Deferred Manual Verification\s*\z/.freeze
```

`CHECKBOX_RE` (`plan_state.rb:28`) is the item unit for both Automated and
Manual Verification, and it is the same syntax the deferred section inherits,
because `defer` copies manual lines verbatim.

**The writer.** `PlanStateCli.run_defer` (`plan_state.rb:328-402`) is called
by `/wurk:implement --loop` once per phase
([`skills/wurk:implement/SKILL.md:97-103`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:implement/SKILL.md#L97-L103)). It takes the phase's Manual
Verification block via `PlanState.manual_block_lines`
(`plan_state.rb:162-187`), and appends it under a fresh `### Phase N`
subheading. On first use it creates the section together with a fixed intro
(`plan_state.rb:379-390`):

```
## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase N
```

On subsequent uses it finds the section, walks to the next `## ` heading, and
inserts `["", "### Phase N", ""] + manual_lines` at the end of the section
(`plan_state.rb:362-377`). It refuses with `phase_already_deferred` rather
than risking a duplicate (`plan_state.rb:364-367`). Envelope data on success:
`path`, `phase`, `deferred: true`, `items_deferred` (a count of lines matching
`CHECKBOX_RE`). When a phase has no manual items it emits `deferred: false`
plus a `no_manual_items` warning (`plan_state.rb:348-354`).

**A quirk that matters for enumeration.** `manual_block_lines` copies
everything between the `#### Manual Verification:` heading and the next
heading of level 2-4, trimming only blank lines at the edges. In real plans
that block often ends with an `**Implementation Note**:` paragraph and a `---`
rule, and those get copied into the deferred section verbatim alongside the
checkboxes. See
`docs/plans/260808-wu-gd1-gate-rb-manifest-driven-constants.md` from line 722
onward for a live example. Continuation lines are also common: a checkbox item
frequently wraps across several indented lines, which `extract_checkbox_section`
folds back into one `text` when parsing a phase
(`plan_state.rb:147-149`) but which a naive line-based reader of the deferred
section would split.

**What `plan_state.rb` reports vs. only writes.** `PlanState.parse`
(`plan_state.rb:50-62`) returns `bead_id`, `sections_missing`, `phases`,
`next_phase`, and `deferred_manual_section`. That last is only
`{present: true|false, line: n|nil}` (`find_deferred_section`,
`plan_state.rb:154-157`). **There is no reader for the items inside the
deferred section.** `parse_phases` reads Manual Verification items *inside a
phase* and exposes them as `manual: {total:, checked:, items: [text]}`
(`plan_state.rb:113-118`), but the deferred copies are not reachable that way,
because they live under `## Deferred Manual Verification` rather than under
any `## Phase N:` heading, and `parse_phases` scopes each phase from its
heading to the next `## ` line (`plan_state.rb:96-102`).

**Nothing in the kit can check a deferred item off.** `run_mutate`'s
no-`--line` form bulk-toggles only `phase[:automated_items]`
(`resolve_targets`, `plan_state.rb:301-302`), and the `--line` form explicitly
refuses a Manual box (`plan_state.rb:310-316`):

```ruby
env.block!(
  code: "manual_verification_refused",
  message: "line #{line} is a Manual Verification box; check/uncheck only ever operate on Automated boxes"
)
```

Even if that refusal were relaxed, the lookup is `phase[:automated_items] +
phase[:manual_items]` matched by absolute line - a deferred line is in neither
list, so the call would block with `not_a_checkbox` today.

**What `/wurk:implement` says about the handoff.**
[`skills/wurk:implement/SKILL.md:165-170`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:implement/SKILL.md#L165-L170): after the last phase commits, print
the accumulated section as the final report, and "Do not remove the section
from the plan; a human confirming it later checks the items off the same way
interactive mode does." [`skills/wurk:implement/SKILL.md:264`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:implement/SKILL.md#L264) restates it:
"Do not check off manual testing steps until the user confirms them." That
sentence is the seam wu-7l5 wants to automate the *walking* of, without
automating the *deciding*.

**The corpus, as of this commit.** All 13 plan documents under `docs/plans/`
carry a `## Deferred Manual Verification` section. Unchecked / checked item
counts inside those sections:

| Plan | unchecked | checked |
|---|---|---|
| 260808-wu-gd1-gate-rb-manifest-driven-constants.md | 0 | 9 |
| 260810-wu-0b2-wurk-skill-prose-judge.md | 0 | 8 |
| 260810-wu-2cb-default-branch-base-ref-from-manifest.md | 0 | 11 |
| 260810-wu-axq-gate-skip-classification.md | 7 | 0 |
| 260810-wu-lyc-upstream-and-decision-beads.md | 0 | 9 |
| 260811-wu-y7d-rebase-conflict-auto-resolution.md | 18 | 0 |
| 260812-wu-mkm-host-project-orientation-codebase-extension.md | 24 | 0 |
| 260813-wu-5fo-unverifiable-sabotage-scan-channel.md | 9 | 0 |
| 260813-wu-p82-consumer-vocabulary-guard-for-skill-markdown.md | 9 | 0 |
| 260814-wu-821-changed-files-remote-base-and-worktree.md | 11 | 0 |
| 260816-wu-z6n-atomic-claim-inside-auto-walk.md | 4 | 7 |
| 260817-wu-9fb-subdirectory-gate-cwd.md | 10 | 0 |
| 260817-wu-mya.1-gh-only-audit-and-forge-neutral-contract.md | 0 | 10 |

That is 92 unchecked items across 7 plans, and it is the concrete backlog
wu-7l5 exists to work. Note `260816-wu-z6n` is partially walked (4 unchecked,
7 checked) - evidence that resume-from-where-you-stopped is a real case, not a
hypothetical.

**Prior art for the pass itself.** `docs/plans/260808-wu-gd1-...` records a
completed walk in the section's own prose: "All items below were walked and
confirmed on 2026-08-08, after the three phase commits landed. Two findings
came out of the walk and are recorded inline; one was fixed in the same pass,
the other filed as wu-p82." That is the shape of the report wu-7l5 describes,
already written by hand once. [`docs/plan.md:1078-1081`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/plan.md#L1078-L1081) records another: a DMV
pass during the phase-2 cutover found and fixed an unrelated doc-citation
defect in `.claude/wurk/mr.md`, and the fix's need for a green gate is what
forced a deletion to be handed to a different bead.

### 2. How open questions are recorded

**`/wurk:research`** puts `## Open Questions` in its body template at
[`skills/wurk:research/SKILL.md:231`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:research/SKILL.md#L231), glossed only as
`[areas needing further investigation]` (`:233`). The template is introduced
as prose the writing session composes, not a skeleton any script emits
(`:185-186`).

**`/wurk:plan`** has `**Open Questions:**` at
[`skills/wurk:plan/SKILL.md:180`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:plan/SKILL.md#L180) - but that is inside the *interactive
mid-research message* the skill sends the human in Step 2, not a section of
the plan document. The authoritative final-plan template
([`skills/wurk:plan/SKILL.md:239-326`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:plan/SKILL.md#L239-L326)) has no Open Questions section, and
`plan_state.rb`'s `MANDATORY_SECTIONS` (`plan_state.rb:33-43`) has no entry
for one. Two rules forbid it outright:

- [`skills/wurk:plan/SKILL.md:336`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:plan/SKILL.md#L336): "**no unresolved open questions remain
  anywhere in the document** - every decision is made"
- [`skills/wurk:plan/SKILL.md:399-401`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:plan/SKILL.md#L399-L401): "**No open questions in the final
  plan**: if one appears during planning, STOP and resolve it - research it or
  ask. The plan must be complete and actionable before it is presented."

[`skills/wurk:iterate/SKILL.md:209-211`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:iterate/SKILL.md#L209-L211) mirrors the rule for plan edits.
[`agents/wurk-plan-critic.md:84-89`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/agents/wurk-plan-critic.md#L84-L89) checks it adversarially, by prose-described
grep heuristics ("TBD", "we should decide", "either ... or", "open question",
"figure out", a "?" where a value belongs), not by a checked-in regex.

**`/wurk:work`** creates the tension. [`skills/wurk:work/SKILL.md:266-270`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L266-L270)
tells every stage subagent: "**No human is available.** Say so, and say what
to do instead: record open questions *in the artifact it produces* and return
them in its report; never block on a question." And `:344-345` obligates the
final report to name "any **Deferred Manual Verification** items the loop
surfaced, and any open questions a stage recorded in its artifact." Research
documents have a slot for that; plans are told not to have one. The three
plans that do carry the heading resolve the tension by reframing: each opens
with wording like "None of these blocks implementation; each records a call
made without a human in the loop, and what would change it"
([`docs/plans/260810-wu-2cb-default-branch-base-ref-from-manifest.md:803-804`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/plans/260810-wu-2cb-default-branch-base-ref-from-manifest.md#L803-L804)).

**What real documents look like.** Every heading found under the three
artifact roots, plus the two design docs that also carry one:

| File | Heading, exactly | Structure |
|---|---|---|
| [`docs/research/260810-wu-ubm-direction-model-reality-vs-doc.md:58`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/research/260810-wu-ubm-direction-model-reality-vs-doc.md#L58) | `## Open Questions` | one prose paragraph opening "Resolved: yes, ..." |
| [`docs/research/260811-wu-y7d-rebase-conflict-auto-resolution.md:560`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/research/260811-wu-y7d-rebase-conflict-auto-resolution.md#L560) | `## Open Questions` | intro sentence, then numbered list, bold question lead-ins |
| [`docs/research/260812-wu-4r7-sabotage-scope-pathspec.md:210`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/research/260812-wu-4r7-sabotage-scope-pathspec.md#L210) | `## Open questions` | single prose paragraph, "None blocking." |
| [`docs/research/260817-wu-9fb-subdirectory-gate-cwd.md:149`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/research/260817-wu-9fb-subdirectory-gate-cwd.md#L149) | `## Open questions` | numbered list, bold lead-ins |
| [`docs/research/260817-wu-mya.1-gh-only-assumptions-and-glab-equivalents.md:537`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/research/260817-wu-mya.1-gh-only-assumptions-and-glab-equivalents.md#L537) | `## Open Questions` | numbered list, bold lead-ins |
| [`docs/research/260817-wu-mya.2-gitlab-merged-request-detection.md:510`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/research/260817-wu-mya.2-gitlab-merged-request-detection.md#L510) | `## Open Questions` | numbered list, bold lead-ins |
| [`docs/plans/260810-wu-lyc-upstream-and-decision-beads.md:576`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/plans/260810-wu-lyc-upstream-and-decision-beads.md#L576) | `## Open Questions` | intro, one bold-lead-in bullet |
| [`docs/plans/260810-wu-2cb-default-branch-base-ref-from-manifest.md:801`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/plans/260810-wu-2cb-default-branch-base-ref-from-manifest.md#L801) | `## Open Questions` | intro, numbered list; item 2 carries a nested "**Settled after the loop**" note |
| [`docs/plans/260812-wu-mkm-host-project-orientation-codebase-extension.md:597`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/plans/260812-wu-mkm-host-project-orientation-codebase-extension.md#L597) | `## Open Questions` | intro, one bold-lead-in bullet |
| [`docs/adr/0008-merge-time-judge-over-generic-skill-prose.md:169`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/adr/0008-merge-time-judge-over-generic-skill-prose.md#L169) | `## Open questions` | prose, referring to other records' questions |
| [`docs/adr/0010-bounded-rebase-conflict-auto-resolution.md:142`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/adr/0010-bounded-rebase-conflict-auto-resolution.md#L142) | `## Open questions` | prose, "None carried forward ... remain unanswered" |
| [`docs/adr/0010-bounded-rebase-conflict-auto-resolution.md:262`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/adr/0010-bounded-rebase-conflict-auto-resolution.md#L262) | `### Open questions` | **level 3**, inside a later `## Amendment` section; one bullet |
| [`docs/adr/0011-codebase-orientation-extension-file.md:160`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/adr/0011-codebase-orientation-extension-file.md#L160) | `## Open questions` | intro, three bold-lead-in bullets |
| [`docs/plan.md:1266`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/plan.md#L1266) | `## Open questions (settle during the phase that hits them)` | plain bullets; **parenthetical suffix in the heading** |
| [`docs/two-tracker-pattern.md:184`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/two-tracker-pattern.md#L184) | `## Open questions` | three plain bullets |

Coverage: 6 of 6 research documents, 3 of 13 plans, 4 of 12 ADRs (one with
two sections).

**Heading-case and structural variation, summarized.** Title case
(`Open Questions`) dominates research documents and plans; sentence case
(`Open questions`) is used by every ADR and by the two design docs. Level is
`##` everywhere except `0010`'s amendment, which uses `###`. One heading
carries a parenthetical suffix. Content is prose in some, numbered lists with
bold lead-ins in most, plain bullets in two. **No document anywhere uses
checkboxes for an open question** - `- [ ]` is reserved in this repo for plan
success criteria, per `CHECKBOX_RE`.

Empty or resolved sections are also unconventionalized: no file writes a bare
"None"; the corpus instead uses prose openers ("None blocking.", "None block
implementation.", "None of these blocks implementation"), and marks resolution
three ways - strikethrough plus bold Settled ([`docs/plan.md:1278-1280`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/plan.md#L1278-L1280)), a
nested bold sub-note (`docs/plans/260810-wu-2cb-...:821-823`), or an inline
"Resolved:" prefix (`docs/research/260810-wu-ubm-...:60`).

**Does a machine-readable convention exist?** No. Three independent obstacles:

1. A regex anchored to `^## Open Questions$` misses the sentence-case files,
   the level-3 amendment section, and the parenthetical one. A tolerant
   `^#{2,3} Open [Qq]uestions\b` would find all 15 headings, but that is a
   convention this bead would be *establishing*, not one it would be reading.
2. Absence is ambiguous. Ten of thirteen plans have no section because the
   template says they must not; research documents without one would mean
   something else. A scanner cannot tell those apart without knowing the
   artifact type.
3. Semantics differ under the same heading: research usage means "unresolved";
   plan usage means "non-blocking judgment call already made". Nothing
   distinguishes them mechanically.
4. There is no marker for "this individual question is now settled" that a
   second pass could read, so an interrupted walk over open questions has
   nothing to resume from - unlike DMV, whose checkboxes give that for free.

### 3. The Direction stage definition

**The table row.** [`skills/wurk:work/SKILL.md:241-246`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L241-L246):

| Stage | Skill | Agent type | `model` |
|---|---|---|---|
| Direction | *(no stage skill - prompt below)* | `general-purpose` | manifest `models.direction` |

**Why it is special.** [`skills/wurk:work/SKILL.md:256-260`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L256-L260): "**Direction is the
one row with nothing to mirror.** No stage skill fits what it produces (a
decision, not a plan or an implementation), so its prompt is composed directly
in the Agent call. Its model is the one stage model projects genuinely
disagree about, so it comes from the manifest's `models.direction` (default
`opus`) rather than being stated here."

**The prompt itself.** [`skills/wurk:work/SKILL.md:277-293`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L277-L293), the
"### Direction stage prompt" section, tells the subagent to read the bead in
full and the files it names; read the project's existing architecture-decision
records and architecture documents to judge whether the bead asks for a new
record, an amendment, or a narrower call; write the decision at the next free
number in the project's own shape and status convention, with a too-narrow
call going to `artifacts.research` instead; and return the artifact path plus
a one-line statement of the decision (or the open question it could not
resolve, per the no-human invariant). [`skills/wurk:work/SKILL.md:295-301`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L295-L301)
adds the after-the-artifact rule: some Direction beads are terminal, others
re-enter step 2 to size what is left.

**The bucket definition** lives separately, in the sizing table at
[`skills/wurk:work/SKILL.md:181`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L181), with the `decision` bd-type signal explained
at `:184-193` and the workspace rationale at `:195-203`.

So the Direction "definition" is currently three disjoint pieces of one
SKILL.md: a table row, a rationale paragraph, and a prompt section.

**The manifest field.** `models.direction`, accessor at
[`skills/wurk:kit/scripts/lib/manifest.rb:422-424`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/lib/manifest.rb#L422-L424):

```ruby
def direction_model
  fetch("models.direction")
end
```

Default `"opus"` in `DEFAULTS` (`lib/manifest.rb:95`), declared valid at
`lib/manifest.rb:78` (`"models" => %w[direction]`). The comment at
`lib/manifest.rb:417-421` records that `/wurk:work` reads it from the manifest
JSON directly in skill prose and the accessor "exists so a script that needs it
later goes through the same typed path as everything else" - i.e. an accessor
already waiting for exactly the kind of consumer wu-7l5 would add. Documented
at [`docs/manifest.md:98-103`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/manifest.md#L98-L103) and in the per-repo table at `:528`. This repo's
own manifest sets it to `fable`.

**Where a shared definition could live: the precedent survey.**

- `skills/wurk:kit/REFERENCE.md` is the only document skills are told to *go
  read*. Twelve skills carry the identical sentence: "See
  `~/.claude/skills/wurk:kit/REFERENCE.md` for the envelope contract shared by
  every script below." (branch:32, commit:16, implement:17, issue:14,
  iterate:18, mr:29, next:33, plan:14, refresh:25, release:18, research:36,
  work:21). [`skills/wurk:kit/SKILL.md:12-13`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/SKILL.md#L12-L13) states it as a rule for script
  work. Its headings today are all `##`: the manifest as contract input (`:18`),
  Ruby version (`:65`), the envelope (`:91`), exit codes (`:135`),
  `--dry-run` (`:144`), banned operations (`:153`), running the tests (`:209`),
  `gate.rb` (`:283`), `judge.rb` (`:356`), writing a new script (`:404`),
  recommended consumer settings (`:429`). Its content today is entirely about
  the script layer; nothing about agent dispatch, stage models, or prompts
  lives there.
- **No SKILL.md reads another SKILL.md.** Every cross-skill reference found is
  citation by name, not transclusion: `work:61-63` cites `next`'s
  direct-manifest-read pattern as precedent, `issue:113` names what
  `/wurk:next` consumes, `refresh:137` defers a judgment to `/wurk:mr`,
  `next:359` and `release:129` describe another skill's behavior,
  `plan:377` routes to `/wurk:iterate`.
- The idiom is stated as policy at [`skills/wurk:iterate/SKILL.md:14-16`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:iterate/SKILL.md#L14-L16):
  "`/wurk:plan` is the authority on the plan template, the phase sizing rule,
  and the success-criteria split. This skill edits documents that skill wrote;
  where a rule is stated there, link to it by name rather than restating it -
  two copies drift." Restated at [`skills/wurk:iterate/SKILL.md:142`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:iterate/SKILL.md#L142).

So there are exactly two shapes with precedent for sharing the Direction
definition: cite `/wurk:work` by name from `/wurk:dmv` (the `iterate`->`plan`
pattern, zero new files), or move the definition into a shared reference
document that both read (the `REFERENCE.md` pattern, which currently has no
non-script content and no second file beside it). ADR-0008's constraint (see
below) bears on which is acceptable, because the Direction prompt is judgment
prose, not mechanics.

### 4. The kit script contract and test harness

**The envelope.** [`skills/wurk:kit/REFERENCE.md:93-104`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/REFERENCE.md#L93-L104) shows the object;
`:106-119` explains each key: `ok` (true only when `blocked` is empty and no
wrapped command failed), `script`, `data` (shape documented per-script by
`--help` and its test file, not in REFERENCE.md), `warnings` (never affects
`ok`), `blocked` (almost always `needs: "human"`), `commands` (mandatory -
every command run or, under `--dry-run`, would-be-run, in order). Diagnostics
go to stderr, never stdout (`:121-122`). Exit codes at `:135-142`: 0 = ok,
1 = ok false with the envelope still printed, 2 = usage error, plain text on
stderr, no envelope. `--dry-run` at `:144-151`, required on every mutating
script, and doubling as the mechanism tests use to exercise scripts without a
real `git`/`gh`/`tmux`.

**Banned operations**, `REFERENCE.md:153-176`: no `git push`, no
`gh pr create` / `glab mr create`, no `bd close`, no `bd edit`, no writes to
`gate.moving_files` / `gate.guard_ledger`. Forge-CLI vocabulary is kept out of
kit vocabulary (`:187-198`); all shell-outs go through `Sh.run`, with
`system`/backticks banned outside `lib/sh.rb` (`:200-207`).

**Where a new script gets documented.** REFERENCE.md does *not* carry a
per-script entry for each script - only `gate.rb` (`:283-354`) and `judge.rb`
(`:356-402`) have dedicated sections, being the two most mechanism-heavy. An
ordinary script's contract is satisfied by `--help` plus its test file. The
"Writing a new script" recipe is `REFERENCE.md:404-427`: require
`lib/envelope`, `lib/sh`, `lib/cli` (plus `lib/manifest` rather than any
hardcoded constant); build with `Cli.build`, parse with `Cli.parse!`;
`Envelope.new`, `Manifest.require!` with an early return on nil, `env.block!`
for unresolvable conditions, `env.warn` for notes, `env.emit` to exit; make
every mutating `Sh.run` skippable under `--dry-run` while still populating
`commands`; add `test/<name>_test.rb` using `test/support/fake_sh.rb` and
`test/support/manifest_helper.rb`; `chmod +x` the script.

**Helper APIs.** `Envelope.new(script:)` (`lib/envelope.rb:22-29`);
`#warn(code:, message:)` (`:33-36`); `#block!(code:, message:, needs: "human")`
(`:41-44`); `#fail!` (`:48-51`); `#ok?` (`:53-55`); `#emit(io = $stdout)`
returning 0/1 (`:61-64`); `attr_reader :script, :data, :warnings, :blocked,
:commands` (`:20`). `Cli.build(banner, options = {})` pre-wires `--dry-run`,
`--json`, `--help` and yields the `OptionParser`, returning `[parser, options]`
(`lib/cli.rb:26-56`); `Cli.parse!(parser, argv)` exits 2 on a parse error
(`:62-68`). `Sh.run(argv, chdir:, timeout:, envelope:)` (`lib/sh.rb:89-92`)
records into `envelope.commands` and returns an `Sh::Result`;
`Sh.runner=` (`:78-84`) is the test seam. `Manifest.require!(env, start:)`
(`lib/manifest.rb:129-140`) is the single entry point, blocking and returning
nil on an invalid manifest.

**The suite.** [`skills/wurk:kit/scripts/test/run.rb:16-19`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/run.rb#L16-L19) requires
`minitest/autorun` then globs `**/*_test.rb` under `test/` and requires each -
no registration list, so a new `dmv_test.rb` (or added
`plan_state_test.rb` cases) is picked up automatically. Run with
`ruby skills/wurk:kit/scripts/test/run.rb`, or `-n /pattern/` for a subset.

**`plan_state_test.rb` structure** (364 lines, two `Minitest::Test`
subclasses):

- `PlanStateLibTest` (`:12-166`) tests the pure `PlanState.parse` in-process.
  `setup`/`teardown` (`:30-37`) install and restore a fixture manifest via
  `ManifestHelper` (needed because `parse` reaches `Refs.bead_id`, which reads
  the manifest). Fixtures are both inline heredocs (`:119-159`) and files read
  from `test/fixtures/plans/*.md` via `read_fixture` (`:39-41`), including a
  frozen real-plan snapshot (`:15-24`, the file
  `test/fixtures/plans/real_grammar_snapshot.md`).
- `PlanStateCliTest` (`:170-364`) tests the mutating CLI against `Dir.mktmpdir`
  copies of fixtures (`setup` `:175-179`, `copy_fixture` `:186-190`). The
  invocation pattern is in-process with a `StringIO`, never a subprocess
  (`:192-196`):

  ```ruby
  def run_cli(argv)
    io = StringIO.new
    code = PlanStateCli.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end
  ```

  Assertions read the parsed envelope directly (`:205-216`), and `--dry-run`
  cases assert `data.changed_lines` is populated while the file on disk is
  unchanged (`:260-269`).

Existing deferred-section fixtures already exist:
`test/fixtures/plans/deferred_present.md:70` has the section, and
`test/plan_state_test.rb:345-352` exercises creating it from
`missing_section.md`.

**`contract_test.rb` (710 lines)** applies these checks to every script,
each of which a new script must pass automatically: no banned calls outside
comments (`:482-490`), no writes to guarded paths (`:492-501`), no
`system`/backticks (`:503-509`), shebang plus executable bit on every
top-level `scripts/*.rb` (`:516-524`), non-interactive flags on `cp`/`rm`/`mv`
argv (`:526-534`), no consumer vocabulary in kit source (`:536-546`), no
consumer vocabulary in any `SKILL.md` line (`:570-582`) or in REFERENCE.md's
shell-fenced blocks (`:584-591`), no hardcoded default branch (`:593-603`), no
forge vocabulary (`:605-617`), plus meta-tests that plant violations to prove
the scanners are not vacuous (`:622-674`) and a drift check that re-reads
ADR-0006's banned-operation paragraph every run (`:691-709`).

**Sizing reference points.** 18 top-level scripts. Small: `work_state.rb` 130,
`commit_message.rb` 151, `repo_state.rb` 151, `permalinks.rb` 159. Medium:
`doc_meta.rb` 392, `select_batch.rb` 418, `plan_state.rb` 424. Test files run
roughly 1x to 3x their script's length (`plan_state.rb` 424 ->
`plan_state_test.rb` 364; `worktree_create.rb` 321 -> 615).

### 5. Skill conventions

**Frontmatter.** All 14 skills use `name`, `description`, and (except
`wurk:kit`) `model` and `argument-hint`. `model: opus` on iterate, plan,
research, work; `model: sonnet` on branch, cleanup, commit, implement, issue,
mr, next, refresh, release; `wurk:kit` has none, and is also the only skill
whose `argument-hint` is a bare string rather than an array. Every workflow
skill's `description` ends with the fixed clause "Reads .claude/wurk.json;
honors .claude/wurk/<skill>.md."

[`skills/wurk:work/SKILL.md:16-19`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L16-L19) explains why `model:` matters here: a
skill's frontmatter governs the turn it is active for, independent of the
session's model - which is also why the stage table's `model` column mirrors
each skill's frontmatter rather than overriding it (`:250-254`).

**Body shape.** Title heading, a short intro, the REFERENCE.md pointer
sentence, a `## Project extension` section, `## Input` where arguments are
parsed, numbered `## Step N` sections (or `## Process`), and a closing
`## Guidelines`. The extension boilerplate's fullest form (e.g.
[`skills/wurk:work/SKILL.md:24-30`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L24-L30)): "If `.claude/wurk/<skill>.md` exists,
**read it before <point>** and treat its content as additional required steps,
placed where it says. Extensions add; they never override. Typical content:
<examples>." Skills that spawn `wurk-codebase-*` agents add the forwarding
clause about `.claude/wurk/codebase.md` (`research:32-34`, `plan:26-28`).

**The no-consumer-constants rule.** [`docs/architecture.md:29-35`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/architecture.md#L29-L35): "A generic
skill may contain no project constants - no bead prefixes, paths, gate
commands, label vocabularies, model names, or ADR numbers of any consumer
repo." Enforced mechanically over every line of every `SKILL.md`
(`contract_test.rb:570-582`). [`CLAUDE.md:14-18`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/CLAUDE.md#L14-L18) states the same as a hard rule.

**Installing.** [`install.rb:49`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/install.rb#L49) `SKILL_GLOB = "skills/wurk:*"`; `:73-75`
globs and sorts directories. No registry to update. [`README.md:31`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/README.md#L31) and
[`docs/architecture.md:13`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/architecture.md#L13) describe the family generically; [`docs/plan.md:138-153`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/plan.md#L138-L153)
carries a "Skill rename map" listing all 14 by name, and
[`docs/plan.md:157-181`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/plan.md#L157-L181) a cross-reference update checklist (other SKILL.md
cross-references, `tmux_window.rb` templates, script tests asserting on skill
names, consumer CLAUDE.md files, consumer docs, bead-note grammar, agent
names) that applies whenever a skill is added or renamed. [`CLAUDE.md:52-55`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/CLAUDE.md#L52-L55)
requires renames to update every referencing skill, script, and script test in
the same commit.

**Locating artifacts by bead id.** `work_state.rb` is the only script that
globs a directory for a bead's documents. `WorkState.doc_id_pattern(id)`
(`work_state.rb:25-27`) is `/\A\d{6}-#{Regexp.escape(id)}(-|\.md\z)/`,
deliberately matching `doc_meta.rb`'s `YYMMDD-[issue-id-]kebab-description.md`
grammar; `find_docs(dir, id)` (`:33-38`) returns `[]` for a missing directory,
else the sorted matching paths. `WorkStateCli.run` (`:50-88`) calls it once
with `manifest.research_dir` and once with `manifest.plans_dir`
(`lib/manifest.rb:426-436`, reading `artifacts.plans` / `artifacts.research`),
warns `multiple_research_docs` / `multiple_plan_docs` when either returns more
than one (`:76-77`), and emits `id`, `bead`, `research_docs`, `plan_docs`,
`loop_notes`, `last_loop_note`, and `plan` (`:79-85`). The bead read is
in-process via `Bead.run(["show", id], io: StringIO.new)` with the wrapped
`commands` folded into this envelope (`:102-115`); `plan_summary`
(`:117-126`) calls `PlanState.parse` and passes through `path`, `next_phase`,
`phases`, `sections_missing`, `deferred_manual_section`. `docs/adr/` is not
named by any `artifacts.*` field, so no existing script locates ADRs.

That is the complete existing answer to "given a bead id, find its plan and
research documents" - a `/wurk:dmv` invoked with a bead id has it already, and
a `/wurk:dmv` invoked with a plan path needs nothing.

### 6. ADRs and prior art

All 12 ADRs are `accepted`; none superseded.

| # | Title |
|---|---|
| 0001 | Record architecture decisions |
| 0002 | Standalone repo, installed by symlink |
| 0003 | `wurk:` colon namespace, not a plugin |
| 0004 | Manifest and extension seams |
| 0005 | Gate contract tiers |
| 0006 | Ruby-stdlib scripts with envelope contract |
| 0007 | Beads for issue tracking, including wurk's own |
| 0008 | Merge-time judge over generic skill prose |
| 0009 | Upstream beads without a workspace |
| 0010 | Bounded rebase-conflict auto-resolution (amended 2026-08-17) |
| 0011 | Codebase-orientation extension file |
| 0012 | Atomic claim inside auto walk |

The four that constrain this work:

**ADR-0008** is the binding constraint on how `/wurk:dmv`'s prose must be
written, and it is the reason the "shared Direction definition" question is
not purely cosmetic
([`docs/adr/0008-merge-time-judge-over-generic-skill-prose.md:80-90`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/adr/0008-merge-time-judge-over-generic-skill-prose.md#L80-L90)):

> A `skills/*/SKILL.md` file may name a kit script for mechanics, and must
> state the policy itself wherever a step is a policy call, a human gate, or a
> verification discipline. Handing such a step to a script - or deleting it
> during a rewrite rather than restating it - is the violation. The failure
> mode is a step that used to state a decision now delegating it, and the tell
> is prose that turns a discipline into a check on its own artifact: a script
> can confirm a note or marker exists, which converts a verification
> discipline into a formatting rule. When a step needs judgment, the script
> reports the inputs and the model decides.

Two direct consequences. First, "is this DMV item actually verified" is a
judgment call, so a script may report unchecked boxes but must never decide
one is satisfied - and prose that reduces the discipline to "the box is
checked" is exactly the tell the judge looks for. Second, this repo's own
`.claude/wurk/mr.md` runs that judge over `skills/**/SKILL.md` at merge time
via the `adr-0008` registry entry in `.claude/wurk.json`, so a new
`skills/wurk:dmv/SKILL.md` is in the judged surface from its first commit.

**ADR-0006** makes the banned-operation list absolute
(`docs/adr/0006-...:29-32`): a kit script never runs `git push`,
`gh pr create`, `glab mr create`, `bd close`, or `bd edit`, and never writes a
manifest-declared gate config or ledger file. The final touch-up commit
wu-7l5 wants therefore goes through `/wurk:commit`, as the bead already says.

**ADR-0004** (`docs/adr/0004-...:19-29`) fixes the two seams: `.claude/wurk.json`
for machine constants, `.claude/wurk/<skill>.md` for domain prose, extensions
add and never override, and "A consumer needing to change generic behavior
means the manifest schema is missing a field." A `.claude/wurk/dmv.md` needs
no schema change; a new manifest field would need `lib/manifest.rb` and
`docs/manifest.md` updated in the same commit ([`CLAUDE.md:25-27`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/CLAUDE.md#L25-L27),
[`docs/manifest.md:3-4`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/manifest.md#L3-L4)).

**ADR-0011** is the precedent for a prose-shaped payload that a skill forwards
verbatim, with the reasoning that a vocabulary list fits a JSON field and a
paragraph of discipline does not (`docs/adr/0011-...:33-34`).

**`docs/plan.md`** names no `/wurk:dmv` anywhere - not in the rename map
(`:138-153`), not in the unscheduled backlog (`:1221-1248`), which currently
holds `wurk-conflict-scout` and `wurk:init` in exactly the shape a `dmv` entry
would take. The only DMV mentions are `:775-778` (describing the deferred
section as a mechanism `/wurk:implement` drives) and the phase-2 retrospective
at `:1078-1081`. [`docs/plan.md:211`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/plan.md#L211) explicitly lists "no unresolved open
questions" among the things `plan_state.rb validate` does *not* cover.

**`docs/research/260810-wu-ubm-direction-model-reality-vs-doc.md`** is the
one research document about the Direction stage. Its finding: neither
statifier-ex nor predicator-ex ever shipped a `models` block, so both ran on
the loader's `opus` default while `docs/manifest.md`'s table claimed
statifier-ex used `fable` - a documented intent from a migration phase that
never landed. It was fixed by correcting the doc here and filing st-4i0 in
statifier's own tracker to make the value true there, preserving the rule that
wurk does not commit into a consumer repo. [`docs/manifest.md:540-552`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/manifest.md#L540-L552) records
that st-4i0 has since landed. That case is both a caution about adding
manifest surface and a worked example of the class of defect a DMV pass
catches.

## Code References

- [`skills/wurk:kit/scripts/plan_state.rb:12`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/plan_state.rb#L12) - the module doc naming the
  `- [ ]`/`- [x]` checkbox handling and the deferred section
- [`skills/wurk:kit/scripts/plan_state.rb:28`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/plan_state.rb#L28) - `CHECKBOX_RE`
- [`skills/wurk:kit/scripts/plan_state.rb:29`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/plan_state.rb#L29) - `DEFERRED_HEADING_RE`
- [`skills/wurk:kit/scripts/plan_state.rb:33-43`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/plan_state.rb#L33-L43) - `MANDATORY_SECTIONS`, with no
  Open Questions entry
- [`skills/wurk:kit/scripts/plan_state.rb:50-62`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/plan_state.rb#L50-L62) - `PlanState.parse`, the full
  read-only report
- [`skills/wurk:kit/scripts/plan_state.rb:130-152`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/plan_state.rb#L130-L152) - `extract_checkbox_section`,
  including continuation-line folding
- [`skills/wurk:kit/scripts/plan_state.rb:154-157`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/plan_state.rb#L154-L157) - `find_deferred_section`,
  presence and line only
- [`skills/wurk:kit/scripts/plan_state.rb:162-187`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/plan_state.rb#L162-L187) - `manual_block_lines`, the
  verbatim block `defer` copies
- [`skills/wurk:kit/scripts/plan_state.rb:301-318`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/plan_state.rb#L301-L318) - `resolve_targets` and the
  `manual_verification_refused` block
- [`skills/wurk:kit/scripts/plan_state.rb:328-402`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/plan_state.rb#L328-L402) - `run_defer`, the whole
  append path including the fixed intro paragraph
- [`skills/wurk:kit/scripts/work_state.rb:25-38`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/work_state.rb#L25-L38) - `doc_id_pattern` and
  `find_docs`, the bead-to-artifact lookup
- [`skills/wurk:kit/scripts/work_state.rb:69-85`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/work_state.rb#L69-L85) - the manifest-driven doc scan
  and the envelope data keys
- [`skills/wurk:kit/scripts/work_state.rb:117-126`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/work_state.rb#L117-L126) - `plan_summary`, which
  passes `deferred_manual_section` through
- [`skills/wurk:kit/scripts/lib/manifest.rb:78`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/lib/manifest.rb#L78) - `"models" => %w[direction]`
- [`skills/wurk:kit/scripts/lib/manifest.rb:95`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/lib/manifest.rb#L95) - the `opus` default
- [`skills/wurk:kit/scripts/lib/manifest.rb:417-424`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/lib/manifest.rb#L417-L424) - `direction_model` and its
  comment about a future script consumer
- [`skills/wurk:implement/SKILL.md:88-103`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:implement/SKILL.md#L88-L103) - the loop's `check` and `defer`
  instructions to the phase subagent
- [`skills/wurk:implement/SKILL.md:165-170`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:implement/SKILL.md#L165-L170) - the batched final report and the
  do-not-remove-the-section rule
- [`skills/wurk:implement/SKILL.md:264`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:implement/SKILL.md#L264) - do not check off manual steps until
  the user confirms
- [`skills/wurk:work/SKILL.md:181`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L181) - the Direction bucket row in the sizing table
- [`skills/wurk:work/SKILL.md:241-260`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L241-L260) - the stage table and the Direction
  rationale
- [`skills/wurk:work/SKILL.md:266-270`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L266-L270) - the "no human is available" invariant
- [`skills/wurk:work/SKILL.md:277-301`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L277-L301) - the Direction stage prompt and what
  happens after the artifact
- [`skills/wurk:work/SKILL.md:340-346`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L340-L346) - step 5's report obligations, the
  sentence wu-7l5 asks to point at `/wurk:dmv`
- [`skills/wurk:plan/SKILL.md:180`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:plan/SKILL.md#L180) - `**Open Questions:**` in the interactive
  Step 2 message template
- [`skills/wurk:plan/SKILL.md:336`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:plan/SKILL.md#L336) - no unresolved open questions anywhere in
  the document
- [`skills/wurk:plan/SKILL.md:399-401`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:plan/SKILL.md#L399-L401) - the "No open questions in the final
  plan" guideline
- [`skills/wurk:research/SKILL.md:231-233`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:research/SKILL.md#L231-L233) - the `## Open Questions` template
  slot
- [`skills/wurk:iterate/SKILL.md:14-16`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:iterate/SKILL.md#L14-L16) - "link to it by name rather than
  restating it - two copies drift"
- [`agents/wurk-plan-critic.md:84-89`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/agents/wurk-plan-critic.md#L84-L89) - the prose-described grep heuristics for
  surviving open questions
- [`skills/wurk:kit/REFERENCE.md:91-151`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/REFERENCE.md#L91-L151) - envelope, exit codes, `--dry-run`
- [`skills/wurk:kit/REFERENCE.md:153-176`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/REFERENCE.md#L153-L176) - banned operations
- [`skills/wurk:kit/REFERENCE.md:404-427`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/REFERENCE.md#L404-L427) - "Writing a new script"
- [`skills/wurk:kit/scripts/test/run.rb:16-19`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/run.rb#L16-L19) - glob-based suite discovery
- [`skills/wurk:kit/scripts/test/plan_state_test.rb:186-196`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/plan_state_test.rb#L186-L196) - `copy_fixture`
  and the in-process `run_cli` pattern
- [`skills/wurk:kit/scripts/test/plan_state_test.rb:345-352`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/plan_state_test.rb#L345-L352) - the existing
  defer-creates-the-section test
- [`skills/wurk:kit/scripts/test/contract_test.rb:570-582`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:kit/scripts/test/contract_test.rb#L570-L582) - the SKILL.md
  consumer-vocabulary scan a new skill file lands under
- [`install.rb:49`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/install.rb#L49) and [`install.rb:73-75`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/install.rb#L73-L75) - the skill glob, requiring no
  registry edit

## Architecture Documentation

- **ADR-0004** fixes the two seams and the "extensions add, never override"
  rule; a `.claude/wurk/dmv.md` is the sanctioned place for project-specific
  verification discipline, and a new generic behavior knob would be a manifest
  schema change with `docs/manifest.md` updated in the same commit.
- **ADR-0006** makes the banned-operation list absolute, which is why the
  final touch-up must go through `/wurk:commit` rather than any script.
- **ADR-0008** requires that policy calls, human gates, and verification
  disciplines stay stated in the skill's own prose, with scripts reporting
  inputs rather than deciding. It names the specific failure mode of prose
  that turns a discipline into a check on its own artifact. This repo runs
  that judge over its own `skills/**/SKILL.md` at merge time through
  `.claude/wurk/mr.md` and the `adr-0008` registry entry in
  `.claude/wurk.json`.
- **ADR-0011** is the precedent for a free-form markdown payload forwarded
  verbatim by a skill, with agent-side fallback.
- [`docs/architecture.md:29-35`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/architecture.md#L29-L35) states the no-consumer-constants rule for
  generic skills, enforced by `contract_test.rb` over every line of every
  `SKILL.md`.
- [`docs/architecture.md:42-51`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/architecture.md#L42-L51) restates the script contract; [`CLAUDE.md:14-27`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/CLAUDE.md#L14-L27)
  restates both as hard rules.
- The established cross-skill sharing idiom is citation by name
  ([`skills/wurk:iterate/SKILL.md:14-16`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:iterate/SKILL.md#L14-L16)); the only document skills are told to
  read is `skills/wurk:kit/REFERENCE.md`, whose content is currently entirely
  about the script layer.

## Historical Context

- `docs/plans/260808-wu-gd1-gate-rb-manifest-driven-constants.md` records a
  completed DMV walk in the deferred section's own prose, including that the
  walk produced two findings, one fixed in the pass and one filed as a new
  bead. That is the report shape wu-7l5 describes, already written by hand.
- [`docs/plan.md:1078-1081`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/plan.md#L1078-L1081) records a DMV pass during the phase-2 cutover that
  found an unrelated doc-citation defect in `.claude/wurk/mr.md` and needed a
  green gate to land the fix on - which forced a staged deletion to be handed
  to a different bead. Evidence that a DMV pass produces real commits with
  real gate interactions, not just checkbox ticks.
- `docs/research/260810-wu-ubm-direction-model-reality-vs-doc.md` documents
  `models.direction` drifting from documented intent to actual manifest
  contents, and the authority split used to fix it (wurk corrects its own doc;
  the consumer's own bead makes the value true).
- [`docs/plan.md:211`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/plan.md#L211) lists "no unresolved open questions" among what
  `plan_state.rb validate` deliberately does not cover.
- [`docs/plan.md:1221-1248`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/docs/plan.md#L1221-L1248) is the unscheduled backlog where speculative future
  skills live; `/wurk:dmv` is not in it, nor in the rename map at `:138-153`.

## Related Research

- `docs/research/260810-wu-ubm-direction-model-reality-vs-doc.md` - the
  Direction stage model, doc vs. reality
- `docs/research/260817-wu-9fb-subdirectory-gate-cwd.md` and
  `docs/research/260817-wu-mya.1-gh-only-assumptions-and-glab-equivalents.md` -
  recent examples of the research-document open-questions convention this
  document describes

## Open Questions

Recorded rather than guessed at; no human was available while this research
ran. None blocks planning.

1. **Whether `docs/adr/` is in scope for an open-questions sweep.** Four of
   twelve ADRs carry an `Open questions` section, and ADR-0010's amendment
   carries a second one at level 3. But no `artifacts.*` manifest field names
   an ADR directory, and `work_state.rb` has no way to find ADRs for a bead.
   Including ADRs would mean either a new manifest field or a convention-based
   guess at the directory - both of which are plan-level decisions.
2. **Whether a `/wurk:dmv` pass should normalize the open-questions heading
   across existing documents, or only tolerate the variants.** A tolerant
   regex (`^#{2,3} Open [Qq]uestions\b`, optional parenthetical suffix) covers
   all 15 headings found today without touching any file; normalizing would
   make future passes cheaper but is a corpus-wide edit that no bead currently
   asks for.
3. **How an open question gets marked worked, so an interrupted pass resumes.**
   DMV items have checkboxes; open questions have none, and the three
   resolution idioms in the corpus (strikethrough plus bold Settled, a nested
   "**Settled after the loop**" note, an inline "Resolved:" prefix) are prose,
   not markers. Inventing a fourth is a decision; adopting one of the three is
   also a decision.
4. **Whether the Direction definition moves to a shared document or is cited
   by name.** Both have precedent in this repo, and they point opposite ways:
   [`skills/wurk:iterate/SKILL.md:14-16`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:iterate/SKILL.md#L14-L16) says link by name, while
   `skills/wurk:kit/REFERENCE.md` is the proven shape for content two skills
   both need to read. ADR-0008 bears on it, because the Direction prompt is
   judgment prose rather than mechanics, and moving judgment prose out of a
   SKILL.md is close to the failure mode that ADR describes. Not resolvable
   from the codebase alone.
5. **The skill's name.** The bead itself raises it: `/wurk:dmv` names one of
   the two backlogs the skill works. Nothing in the codebase settles it, and
   [`CLAUDE.md:52-55`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/CLAUDE.md#L52-L55) makes a later rename a same-commit sweep of every
   reference, so the choice is cheapest now.
6. **Whether it gets an `--auto` form.** The bead leaves it undecided. If it
   does, `/wurk:work`'s "no human is available" invariant
   ([`skills/wurk:work/SKILL.md:266-270`](https://github.com/riddler/wurk/blob/cb3ad01bb889c81a2b04de3452654ffa43e8d5f6/skills/wurk:work/SKILL.md#L266-L270)) applies, which is in direct tension
   with a pass whose whole point is confirming things with a human.

---
name: wurk:plan
description: Create a detailed implementation plan through interactive research and iteration - phases sized to be independently committable and gate-verifiable, success criteria split into automated and manual, validated and adversarially reviewed before it is presented. Reads .claude/wurk.json; honors .claude/wurk/plan.md.
model: opus
argument-hint: ["bead ID, or path to a research/design doc"]
---

# Implementation plan

Create detailed implementation plans through an interactive, iterative
process. Be skeptical, be thorough, and work collaboratively with the user to
produce a high-quality technical specification.

See `~/.claude/skills/wurk:kit/REFERENCE.md` for the envelope contract shared
by every script below.

## Project extension

If `.claude/wurk/plan.md` exists, **read it before step 1** and treat its
content as additional required steps and additional template sections. It is
where a project states the success criteria it always wants (a corpus or
ratchet step, a spec-conformance check), the optional sections its plans
carry, and the domain patterns a plan should follow. The critic in step 5
checks the plan against it.

---

## MANDATORY output requirements

**Follow these exactly. Re-read this section before writing the final plan.**

### File location

**ALWAYS** write the plan into the directory the manifest names as
`artifacts.plans`, with the filename built by:

```bash
ruby ~/.claude/skills/wurk:kit/scripts/doc_meta.rb filename \
  --dir <artifacts.plans> --description "<kebab-description>" [--issue <id>]
```

`data.path` is the filename rule - the single definition site this skill
shares with `/wurk:research`, so the two cannot drift. **NEVER** write the
plan to `.claude/`, the project root, or anywhere else.

### Template structure

The one authoritative template lives under "Step 4: detailed plan writing".
It must include every section it lists, in that order, and every phase must
split its success criteria into Automated and Manual Verification.
`plan_state.rb validate` checks that mechanically before you present the
plan.

---

## Initial response

1. **If parameters were provided**: read any given file FULLY, immediately,
   and begin researching. Supported inputs are a bead ID (`bd show <id>`), a
   research or design document path, or a task description.

2. **If no parameters were provided**, respond with:

   ```
   I'll help you create a detailed implementation plan. Let me start by
   understanding what we're building.

   Please provide:
   1. The task description, bead ID, or research document
   2. Any relevant context, constraints, or specific requirements
   3. Links to related research or previous implementations
   ```

   Then wait.

## Process

### Step 1: Context gathering and initial analysis

1. **Read all mentioned files immediately and FULLY** - research documents,
   related plans, the project's accepted ADRs (settled decisions the plan
   must fit), and any data files named.

   - Use the Read tool WITHOUT limit/offset parameters
   - **DO NOT spawn sub-agents before reading these files yourself in the
     main context**
   - **NEVER** read a mentioned file partially

   **From a bead**: fetch with `bd show <id>`; note dependencies, labels, and
   linked issues, and check its notes for existing research documents.

   **From a research doc**: it has already done the investigation. Use it as
   the foundation and focus on structuring the implementation rather than
   re-researching. Validate that its findings are still current if it is old.

2. **Spawn research sub-agents to gather context** when the input did not
   arrive with full `file:line` detail - in parallel, before asking the user
   anything. Give each one a narrow question and ask for `file:line`
   references back. Pick by what the question needs:

   - **wurk-codebase-locator** - WHERE files and components live
   - **wurk-codebase-analyzer** - HOW a specific component works
   - **wurk-codebase-pattern-finder** - existing patterns to model after
   - **wurk-docs-locator** / **wurk-docs-analyzer** - prior research, plans,
     and ADRs. Pass the manifest's `artifacts.research` and `artifacts.plans`
     (and the ADR directory) in the prompt.
   - **Explore** - a read-only breadth-first sweep when the question is "what
     touches X" and no specialized agent fits
   - **general-purpose** - only when the question needs more than reading:
     running a snippet, checking behavior in a REPL, or reading a sibling
     checkout. Say explicitly in the prompt when an agent should look outside
     this repo.

   The research agents are documentarians: they describe what exists and do
   not critique it. Accepted ADRs are settled - cite the number, do not
   re-argue the decision.

3. **Read all files the sub-agents identified**, FULLY, into the main
   context. This ensures complete understanding before proceeding.

4. **Analyze and verify understanding**: cross-reference the requirements
   against the actual code, identify discrepancies, note assumptions needing
   verification, and determine the true scope based on codebase reality.

5. **Present informed understanding and focused questions**:

   ```
   Based on the issue and my research, I understand we need to [summary].

   I've found that:
   - [current implementation detail with file:line]
   - [pattern or constraint discovered, e.g. an ADR that bounds the design]
   - [complexity or edge case identified]

   Questions my research couldn't answer:
   - [specific technical question needing human judgment]
   - [design preference that affects implementation]
   ```

   Only ask what you genuinely cannot answer through code investigation.

### Step 2: Research and discovery

1. **If the user corrects a misunderstanding**: do not just accept it. Spawn
   new research sub-agents to verify, read the files they mention, and only
   proceed once you have verified the facts yourself.

2. **Track the research tasks** as todos.

3. **Spawn parallel sub-agents for deeper research**, same menu as step 1.2,
   each focused on one area, with explicit directory context in the prompt.

4. **Wait for ALL sub-agents to complete** before proceeding.

5. **Present findings and design options**:

   ```
   Based on my research, here's what I found:

   **Current State:**
   - [key discovery about existing code]
   - [pattern or convention to follow]

   **Design Options:**
   1. [Option A] - [pros/cons]
   2. [Option B] - [pros/cons]

   **Open Questions:**
   - [technical uncertainty]
   - [design decision needed]

   Which approach aligns best with your vision?
   ```

### Step 3: Plan structure development

1. **Propose the phase outline**:

   ```
   Here's my proposed plan structure:

   ## Overview
   [1-2 sentence summary]

   ## Implementation Phases:
   1. [Phase name] - [what it accomplishes]
   2. [Phase name] - [what it accomplishes]

   Does this phasing make sense? Should I adjust the order or granularity?
   ```

   Phases split along module boundaries where possible, so they can be
   parallelized across branches.

   **A phase is the smallest unit that is independently gate-verifiable and
   independently committable.** If two candidate phases would leave an
   intermediate gate red on their own - a structure added in one phase and
   consumed in the next, with nothing exercising it in between - combine them
   into one phase rather than splitting. This is what keeps `/wurk:implement
   --loop`'s per-phase gate meaningful, and it is the answer to grouping
   small phases: sizing happens at authoring time, not at runtime.

2. **Get feedback on the structure** before writing details.

### Step 4: Detailed plan writing

1. **You MUST write the plan to disk before presenting your summary.**

   - **Re-read "MANDATORY output requirements" NOW**
   - Compose the full document following the template below
   - Write it to the path `doc_meta.rb filename` produced
   - Validate before presenting:

     ```bash
     ruby ~/.claude/skills/wurk:kit/scripts/plan_state.rb validate <path>
     ```

     `data.sections_missing` must be empty - it checks for exactly the nine
     mandatory sections, in order. Fix and re-validate; do not present a plan
     it still flags.
   - Present the proposed path and a brief description, ask permission to
     write, write on approval, and confirm.

2. **The template** (the one authoritative statement of it in this skill - do
   not restate it elsewhere):

````markdown
# [Feature/Task Name] Implementation Plan

## Overview

[Brief description of what we're implementing and why. Bead: <id>]

## Current State Analysis

[What exists now, what's missing, key constraints discovered]

## Desired End State

[A specification of the end state after this plan is complete, and how to
verify it]

### Key Discoveries:
- [Important finding with file:line reference]
- [Pattern to follow]
- [Constraint to work within, e.g. an ADR number]

## What We're NOT Doing

[Explicit out-of-scope items, to prevent scope creep]

## Implementation Approach

[High-level strategy and reasoning]

## Phase 1: [Descriptive Name]

### Overview
[What this phase accomplishes]

### Changes Required:

#### 1. [Component/File Group]
**File**: `path/to/file.ext`
**Changes**: [Summary of changes]

```
# specific code to add or modify
```

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes
- [ ] [any project-specific automated check]

#### Manual Verification:
- [ ] [behavior verified interactively]
- [ ] [edge case checked by hand]
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: [Descriptive Name]

[Same structure, with both automated and manual success criteria]

---

## Testing Strategy

### Unit Tests:
- [What to test, and where]
- [Key edge cases]

### Manual Testing Steps:
1. [Specific step to verify the feature]
2. [Another verification step]

## References

- Source document: `<path>`
- Related ADRs: `<paths>`
- Similar implementation: `[file:line]`
- Bead: `<id>`
````

Sections beyond the nine mandatory ones are optional - include one only when
it applies to this plan. The project's extension file may require additional
sections; those are as mandatory as the nine when it does.

3. **Before presenting, confirm the things `plan_state.rb` cannot check:**

   - the file is at the `artifacts.plans` path `doc_meta.rb` produced, not
     somewhere else
   - **no unresolved open questions remain anywhere in the document** - every
     decision is made
   - every automated criterion is something a command can actually decide
   - every section the extension file requires is present

### Step 5: Adversarial review before presentation

Spawn the **wurk-plan-critic** agent with the plan's path, the bead id, and
the path of `.claude/wurk/plan.md` if the project has one. It reads the plan
with fresh context - deliberate blindness to this conversation is the point -
and checks what `plan_state.rb validate` cannot: whether phases are genuinely
independently committable and gate-verifiable, whether success criteria are
actually verifiable, whether anything contradicts an accepted ADR, whether
open questions survive, and whether the extension file's requirements are
met.

**The critic reports; this session judges.** A finding is not an instruction:
some are real and get fixed, some rest on context the critic could not see.
Fix what is real before presenting.

A finding you decline to act on gets written into the plan itself - in "What
We're NOT Doing", or in the phase it concerns - so the reason survives for
whoever implements it. Do not record critic findings on the bead: bead notes
are the loop's state channel, and review chatter dilutes it.

### Step 6: Review

1. **Present the plan**:

   ```
   I've created the implementation plan at `<path>`

   Please review it and let me know:
   - Are the phases properly scoped?
   - Are the success criteria specific enough?
   - Any technical details that need adjustment?
   - Missing edge cases or considerations?
   ```

2. **Iterate on feedback** - add missing phases, adjust the approach, clarify
   criteria, add or remove scope. Continue until the user is satisfied.
   Substantial later changes are `/wurk:iterate`'s job.

## Important guidelines

1. **Be skeptical**: question vague requirements, identify issues early, ask
   "why" and "what about", and verify with code rather than assuming.

2. **Be interactive**: don't write the full plan in one shot; get buy-in at
   each major step and allow course corrections.

3. **Be thorough**: read all context files completely before planning,
   research actual code patterns with parallel sub-agents, include specific
   paths and line numbers, and write measurable success criteria with a clear
   automated/manual split.

4. **Be practical**: focus on incremental, testable changes; think about edge
   cases; include what you are NOT doing.

5. **Defer to accepted ADRs**: a plan that would contradict one needs a
   direction-level decision, not a quiet plan edit. Flag it; never silently
   contradict it.

6. **No open questions in the final plan**: if one appears during planning,
   STOP and resolve it - research it or ask. The plan must be complete and
   actionable before it is presented.

## Success criteria guidelines

Always separate success criteria into two categories:

1. **Automated verification** - things an execution agent can run: the
   project's loop gate while iterating, the full gate as the per-phase bar,
   machine-readable gate output when a decision routes on results, and
   specific files that should exist. Name them by what they check, and let
   the manifest's `gate.*` commands supply the exact invocation.

2. **Manual verification** - things needing a human: judgment calls about
   correctness against a spec, behavior exercised interactively, edge cases
   that are hard to automate, and user acceptance.

## Sub-agent spawning best practices

1. **Spawn multiple sub-agents in parallel** for efficiency
2. **Each should be focused** on one specific area
3. **Give detailed instructions**: exactly what to search for, which
   directories, what to extract, and the expected output shape
4. **Be specific about directories**, including when a sub-agent should look
   at a sibling checkout rather than this repo
5. **Prefer read-only agents.** The `wurk-*` research agents and `Explore`
   all are, which is what research wants. Reach for `general-purpose` only
   when the question genuinely needs execution or a repo outside this
   checkout.
6. **Request `file:line` references** in responses
7. **Wait for all sub-agents to complete** before synthesizing
8. **Verify their results**: spawn a follow-up when something looks off,
   cross-check against the codebase, and don't accept results that seem
   wrong.

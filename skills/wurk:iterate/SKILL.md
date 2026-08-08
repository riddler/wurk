---
name: wurk:iterate
description: Update an existing implementation plan from user feedback - surgical edits grounded in codebase reality, re-validated structurally and re-reviewed by the plan critic after substantive changes. Reads .claude/wurk.json; honors .claude/wurk/iterate.md.
model: opus
argument-hint: ["path to plan file", "description of changes needed"]
---

# Iterate on an implementation plan

Update an existing plan based on user feedback. Be skeptical, be thorough,
and keep the changes grounded in actual codebase reality.

`/wurk:plan` is the authority on the plan template, the phase sizing rule,
and the success-criteria split. This skill edits documents that skill wrote;
where a rule is stated there, link to it by name rather than restating it -
two copies drift.

See `~/.claude/skills/wurk:kit/REFERENCE.md` for the envelope contract shared
by every script below.

## Project extension

If `.claude/wurk/iterate.md` exists, **read it before step 1**; so is
`.claude/wurk/plan.md`, since its required sections and success criteria
apply to any plan this skill edits.

## Initial response

1. **Parse the input** for a plan file path and the requested changes.

2. **If NO plan file was given**:

   ```
   I'll help you iterate on an existing implementation plan.

   Which plan would you like to update? Please provide the path to the plan
   file.
   ```

   Wait, then re-check for feedback.

3. **If a plan file was given but NO feedback**:

   ```
   I've found the plan at [path]. What changes would you like to make?

   For example:
   - "Add a phase for <follow-on work>"
   - "Update the success criteria to include <check>"
   - "Adjust the scope to exclude <thing>"
   - "Split Phase 2 into two separate phases"
   ```

   Wait.

4. **If both were given**: proceed straight to step 1.

## Process

### Step 1: Read and understand the current plan

1. **Read the plan COMPLETELY** - the Read tool with no limit/offset. Note
   the structure, the phases, the scope, the success criteria, and the
   implementation approach.

2. **Check its structural state**:

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/plan_state.rb validate <path>
   ```

   `data.sections_missing`, `data.phases` (each with its automated and manual
   checkbox counts and `complete` flag), `data.next_phase`, and
   `data.deferred_manual_section` are the same structural facts a hand read
   would reconstruct by eye. Read them here so the edits in step 4 start from
   an accurate picture of what is already checked, missing, or deferred.

   **Work already checked off is work that landed.** An edit to a completed
   phase changes a record of what was done, not a plan for what to do - say
   so explicitly rather than editing it quietly.

3. **Understand the requested changes**: what to add, modify, or remove;
   whether they need codebase research; and the scope of the update.

### Step 2: Research if needed

**Only spawn sub-agents if the changes require new technical understanding.**
Simple edits do not.

When they do, track the tasks and spawn in parallel, picking by what the
question needs - the same menu `/wurk:plan` step 1.2 lists
(`wurk-codebase-locator`, `wurk-codebase-analyzer`,
`wurk-codebase-pattern-finder`, `wurk-docs-locator`, `wurk-docs-analyzer`,
`Explore`, and `general-purpose` only when the answer needs execution or a
repo outside this checkout). Pass the manifest's `artifacts.*` roots to the
docs agents. Be explicit about directories. Read any new files they identify
FULLY into the main context, wait for all of them, then continue.

### Step 3: Present understanding and approach

```
Based on your feedback, I understand you want to:
- [change 1 with specific detail]
- [change 2 with specific detail]

My research found:
- [relevant code pattern or constraint]
- [discovery that affects the change]

I plan to update the plan by:
1. [specific modification]
2. [another modification]

Does this align with your intent?
```

Get confirmation before editing.

### Step 4: Update the plan

1. **Make focused, precise edits**: use Edit for surgical changes, keep the
   existing structure unless the change is structural, keep every `file:line`
   reference accurate, and update success criteria where they moved.

2. **Ensure consistency**:
   - A new phase follows the existing pattern and the sizing rule in
     `/wurk:plan` step 3 - independently committable and gate-verifiable
   - A scope change updates "What We're NOT Doing"
   - An approach change updates "Implementation Approach"
   - The automated/manual split in success criteria is maintained
   - A phase's Implementation Note keeps the interactive/`--loop` wording
     `/wurk:plan`'s template defines; link by name, don't restate it
   - **Flag, don't silently edit, a change that would contradict an accepted
     ADR.** That needs a direction-level decision. `plan_state.rb` has no ADR
     awareness and never will; this is a judgment call made here, in the
     session, not something delegated to a script.

3. **Preserve quality standards**: specific paths and line numbers for new
   content, measurable success criteria, the project's gate commands (from
   the manifest's `gate.*`) for automated verification, and clear actionable
   language.

4. **Re-validate**:

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/plan_state.rb validate <path>
   ```

   `data.sections_missing` must come back empty, and every phase you touched
   must still carry both an Automated and a Manual Verification list. Fix and
   re-run before presenting - the same check step 1 ran before any edits, now
   confirming they kept the document well-formed.

5. **Re-run the critic after a substantive change** - a new or re-split
   phase, a changed approach, a scope change, or reworked success criteria.
   Spawn **wurk-plan-critic** exactly as `/wurk:plan` step 5 describes,
   passing the plan path, the bead id, and the extension file path. A
   typo fix or a clarified sentence does not need it.

   The critic reports; this session judges. A finding you decline to act on
   is written into the plan itself, not onto the bead.

### Step 5: Review

```
I've updated the plan at `<path>`

Changes made:
- [specific change 1]
- [specific change 2]

The updated plan now:
- [key improvement]

Would you like any further adjustments?
```

Be ready to iterate further.

## Important guidelines

1. **Be skeptical**: don't blindly accept a change request that seems
   problematic, question vague feedback, verify technical feasibility against
   the code, point out conflicts with existing phases, and flag anything that
   would contradict an accepted ADR.

2. **Be surgical**: precise edits, not wholesale rewrites. Preserve good
   content, research only what the specific change needs, and don't
   over-engineer.

3. **Be thorough**: read the entire plan first, research when the change
   needs new understanding, and verify the success criteria are still
   measurable.

4. **Be interactive**: confirm understanding before editing, show what you
   plan to change, allow course corrections, and don't disappear into
   research without saying so.

5. **No open questions**: if a requested change raises one, ask. Do not
   update the plan with unresolved questions - every change must be complete
   and actionable.

---
name: wurk:implement
description: Implement an approved plan phase by phase with verification - interactively, or unattended with --loop, where each phase is dispatched to a subagent and /wurk:commit --auto is the advancement gate. Reads .claude/wurk.json; honors .claude/wurk/implement.md.
model: sonnet
argument-hint: ["path to plan file", "--loop", "--from-phase N"]
---

# Implement plan

Implement an approved plan from the project's plans directory. Plans contain
phases with specific changes and success criteria.

For an unattended, phase-by-phase run with no human confirmation between
phases, pass `--loop` - see "Looped execution mode". Everything else here
describes the default, interactive mode.

See `~/.claude/skills/wurk:kit/REFERENCE.md` for the envelope contract shared
by every script below.

## Project extension

If `.claude/wurk/implement.md` exists, **read it before starting** and treat
its content as additional required steps. Typical content: the project's
test-verification discipline, domain rules a change must follow, and the
debugging move that works in this codebase. In `--loop` mode, the phase
subagent has no memory of this session - pass the extension file's path in
its prompt and tell it to read the file.

## Before you start: claim the bead and pick a branch

- The plan references a bead. Claim it before touching code:

  ```bash
  ruby ~/.claude/skills/wurk:kit/scripts/bead.rb claim <id>
  ```

- **Stand the branch up with `/wurk:branch <id>`** rather than by hand. It
  reads `parallelism.model` from the manifest and does the right thing for
  the project - a warmed per-issue worktree, or a branch in the current
  checkout - along with whatever post-branch setup the manifest configures.
  One bead, one branch.

- Working directly in an existing checkout is fine; the claim still happens
  first.

- Record progress other sessions might need with
  `ruby ~/.claude/skills/wurk:kit/scripts/bead.rb note <id> "..."`.

## Looped execution mode

**Trigger**: `/wurk:implement <path> --loop`, optionally with
`--from-phase N`.

**Preconditions**: the bead is claimed and the tree is clean. Check both:

```bash
ruby ~/.claude/skills/wurk:kit/scripts/repo_state.rb
```

`data.branch_bead` (or the id you already claimed) covers the claim;
`data.dirty` covers the tree. If `data.dirty` is true, stop and report rather
than looping over an already-dirty tree.

**Per-phase procedure**, repeated from the first phase with an unchecked
Automated Verification box (or from `--from-phase N`) through the last phase:

1. **Identify the phase's full text.**

   ```bash
   ruby ~/.claude/skills/wurk:kit/scripts/plan_state.rb validate <path>
   ```

   `data.next_phase` is the phase to run. `data.phases` names each phase's
   `line_start`/`line_end` - read those lines from the plan file yourself to
   get the phase's complete text, heading through its success criteria.

2. **Dispatch one subagent** (`subagent_type: general-purpose`,
   `run_in_background: false`) with a **fully self-contained prompt**: the
   plan path, the phase number and its complete text, the bead id, the path
   of `.claude/wurk/implement.md` if the project has one, and explicit
   instructions to:

   - read the plan, the bead, and the extension file itself (it has no memory
     of this conversation),
   - implement only this phase, following the plan's intent and the project's
     conventions,
   - keep the project's loop gate (`gate.loop`) green while iterating,
   - check off this phase's Automated Verification boxes once satisfied:

     ```bash
     ruby ~/.claude/skills/wurk:kit/scripts/plan_state.rb check <path> <phase-n>
     ```

     and **never** check off a Manual Verification box - the script refuses a
     `--line` targeting one, and the bulk form used here only ever touches
     automated boxes,
   - append this phase's Manual Verification items, verbatim, to the running
     deferred section at the bottom of the plan:

     ```bash
     ruby ~/.claude/skills/wurk:kit/scripts/plan_state.rb defer <path> <phase-n>
     ```

     (which creates the section, with its standard intro, on first use)
     instead of blocking on them,
   - **not** commit, **not** run the full gate as a final bar (the
     orchestrator does both), and **not** close the bead,
   - **implement the phase itself**: this loop is already the per-phase
     orchestrator, so it must not delegate the phase to a further subagent
     and must not invoke `/wurk:implement` or `/wurk:work`. Either would
     re-dispatch phases a level down, outside this orchestrator's
     `/wurk:commit --auto` advancement gate. A narrowly-scoped sub-task for
     debugging or exploring unfamiliar territory is still fine; the rule is
     against delegating the phase, not against every use of a subagent,
   - end by reporting what changed and whether it believes the phase is
     complete.

   **The spawn budget is three layers**: this orchestrator, the phase
   subagent, and one narrow leaf task under it. `wurk-gate-reader` is a leaf
   and never a spawner - if the orchestrator hands it a red gate, that is the
   third layer, not a fourth.

   `general-purpose` stays the agent type here rather than something
   narrower: the phase subagent legitimately needs the Agent tool for that
   leaf task, and the prompt instruction above - not a tool restriction - is
   what keeps it from delegating the phase.

3. **The orchestrator - not the subagent - runs `/wurk:commit --auto`.** This
   is the automated advancement gate: the full gate, the unrelated-changes
   check, the bead checks, and whatever the project's extension adds all run
   for real, independent of the subagent's self-report.

   - **Refused** (red gate, narrowed gate, unrelated changes, no bead
     detected, or a project-specific refusal): stop the loop immediately - no
     retry. **Uncheck this phase's Automated Verification boxes** if the
     subagent checked any before the gate ran:

     ```bash
     ruby ~/.claude/skills/wurk:kit/scripts/plan_state.rb uncheck <path> <phase-n>
     ```

     The resume scan keys off those boxes, and a refusal means this phase's
     work never landed, whatever the subagent's checklist says. Leave every
     other file exactly as the subagent left it - the refusal is diagnostic
     information for the human or the next resume, not something to clean up.
     Then:

     ```bash
     ruby ~/.claude/skills/wurk:kit/scripts/bead.rb note <id> \
       "loop stopped at Phase N: <refusal reason>"
     ```

     Report the reason and the phase, then end the turn.

   - **Committed**: record the handoff a later invocation (or a human) reads
     to see what happened in a session that no longer exists:

     ```bash
     ruby ~/.claude/skills/wurk:kit/scripts/bead.rb note <id> \
       "loop: Phase N complete, commit <sha>"
     ```

     Advance to the next phase.

4. **After the last phase commits**, print the accumulated deferred manual
   verification section (if non-empty) as the final report - the same items
   interactive mode reports per phase, batched instead. `plan_state.rb
   validate`'s `data.deferred_manual_section` confirms it is there. Do not
   remove the section from the plan; a human confirming it later checks the
   items off the same way interactive mode does.

**Resuming after a stop**: re-running `/wurk:implement <path> --loop` re-runs
`plan_state.rb validate` and reads `data.next_phase` - the first phase with
an unchecked Automated Verification box. Pass `--from-phase N` to force a
starting phase, e.g. after a human fixed the failure by hand and wants to
skip a phase that is actually done but whose boxes were never checked.

## Getting started

Given a plan path:

- Read the plan completely and note any existing checkmarks
- Read the bead (`bead.rb show <id>`) and every file the plan mentions
- **Read files fully** - never use limit/offset; you need complete context
- Think about how the pieces fit together
- Track progress as todos
- Start implementing once you understand what needs doing

If no plan path was given, ask for one.

## Implementation philosophy

Plans are carefully designed, but reality can be messy:

- Follow the plan's intent while adapting to what you find
- Implement each phase fully before moving to the next
- Verify the work makes sense in the broader codebase context
- Update checkboxes in the plan as you complete sections
- Keep the project's loop gate green between edits. Where that gate formats
  code for you, do not run the formatter as a separate step.

When something doesn't match the plan, think about why and communicate
clearly. The plan is the guide; your judgment matters too.

On a mismatch:

- STOP and think about why the plan can't be followed
- Present it plainly:

  ```
  Issue in Phase [N]:
  Expected: [what the plan says]
  Found: [actual situation]
  Why this matters: [explanation]

  How should I proceed?
  ```

## Verification approach

After implementing a phase:

- Follow the project's test-verification discipline where its extension file
  states one. A test that passed on its first run has been observed, not
  verified; projects that care about this say how they check it, and where
  they do, that discipline is part of the phase rather than something to
  defer.
- Run the success criteria checks: the loop gate while iterating, then the
  full gate as the phase bar (also the pre-commit bar):

  ```bash
  ruby ~/.claude/skills/wurk:kit/scripts/gate.rb
  ```

  On a red gate whose output is more than trivially small, hand it to the
  **wurk-gate-reader** agent rather than reading it all in this session.
- Fix issues before proceeding
- Update progress in both the plan and your todos
- Check off completed items in the plan file itself:

  ```bash
  ruby ~/.claude/skills/wurk:kit/scripts/plan_state.rb check <path> <phase-n>
  ```

- **In interactive (non-`--loop`) mode, pause for human verification.** After
  the automated verification passes for a phase:

  ```
  Phase [N] Complete - Ready for Manual Verification

  Automated verification passed:
  - [checks that passed]

  Please perform the manual verification steps listed in the plan:
  - [manual items from the plan]

  Let me know when manual testing is complete so I can proceed to Phase [N+1].
  ```

  In `--loop` mode, see "Looped execution mode" instead: automated
  verification gates advancement and manual items are deferred to a batched
  report at the end.

Do not check off manual testing steps until the user confirms them.

## If you get stuck

- First, make sure you have read and understood all the relevant code
- Use the debugging move the project's extension file names, where it names
  one - that is usually faster than a general search
- Consider whether the codebase has evolved since the plan was written
- Present the mismatch clearly and ask for guidance

Use sub-tasks sparingly - mainly for targeted debugging or exploring
unfamiliar territory.

## Wrapping up

- When all phases are complete and the full gate is green, report status.
  **Do not close the bead** - closing fires only on a verified merge, and
  this skill never pushes or merges anything, so that trigger has not fired.
  The bead stays in progress.
- Capture discovered work immediately (`bd q`) and link it rather than
  chasing it mid-task
- Leave commit, push, and merge decisions to the user unless explicitly
  instructed otherwise
- In `--loop` mode this happens once, after the last phase's commit, not per
  phase. Discovered work still goes to the queue as it is found.

## Resuming work

If the plan has existing checkmarks:

- Trust that completed work is done
- Pick up from the first unchecked item
- Verify previous work only if something seems off

You're implementing a solution, not checking boxes. Keep the end goal in mind
and maintain forward momentum.

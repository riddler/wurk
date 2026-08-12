# ADR-0011: Host-project orientation travels as a codebase extension file

Status: accepted (2026-08-12)

## Context

Phase 2 step 3 stripped the consumer-specific blocks from the three codebase
agents (wurk-codebase-locator, -analyzer, -pattern-finder): a "Project
Layout" section naming source and test roots and the suite split, a "Project
Context" section naming the pipeline and its invariants, and pattern
categories written in one consumer's domain vocabulary. The hard rule
forbids all of it in generic prose, so each agent got an "Orienting" ladder
instead: prompt-supplied context first, then the repo's own CLAUDE.md /
README / architecture docs, then a directory listing. Correct, but weaker
than what statifier had - guidance like "Appendix D function names are the
best search keys" and "describe a ported function against the spec
pseudocode rather than inferring intent" changes an agent's output, and no
amount of reading CLAUDE.md reliably reproduces it. Every invocation pays a
rediscovery cost and may still guess wrong (bead wu-mkm).

The docs pair already has this seam solved (cracks item 9): prompt-supplied
roots first, then the manifest's `artifacts.*`, then a conventional glob
reported as a guess. That solution does not transplant directly, because its
payload is two paths and this one is prose-shaped and much larger.

Three candidates were priced, plus a hybrid:

- **A manifest section** (e.g. `codebase`): source roots, test roots, module
  families, vocabulary. Fits the manifest pattern mechanically, but misfits
  it in kind. ADR-0004 defines the manifest as machine-consumed constants
  loaded by `lib/manifest.rb` and handed to scripts - and no script consumes
  this payload; only prompts do. The payload is also the wrong shape for
  JSON: a vocabulary list fits a field, "port Appendix D literally, do not
  idiomatize" does not. And the one structured fact a script does need -
  which paths are the project's build - already lives in `gate.build_paths`;
  a `codebase` section would be a second, divergence-prone statement of
  overlapping facts. Finally, every schema field costs a `docs/manifest.md`
  plus `lib/manifest.rb` change in lockstep, priced against zero machine
  consumers.
- **Nothing - lean on the repo's CLAUDE.md**, today's behavior. Zero new
  machinery and a human already maintains the file, but it is unbounded, not
  shaped for this use, re-read on every invocation, and structurally unable
  to carry agent-facing search strategy: no project writes "our element
  names are the highest-yield grep keys" into a file addressed to every
  agent and human alike.
- **An extension file the invoking skill forwards into agent prompts.**
  Prose stays prose, authoring cost is low, and it matches how domain
  content already travels (ADR-0004 layer 4). The migration plan already
  routes most of this exact material into extensions - phase 2 step 2's
  extraction table sends statifier's pipeline-layer vocabulary to
  `wurk/research.md` and its Appendix D rule and common patterns to
  `wurk/plan.md` - and the step 3 outcome notes anticipated the mechanism:
  the invoking skill reads the extension and passes it down. Two gaps
  remain, and they are the actual decision here: keyed per skill, one
  orientation payload would be triplicated across `research.md`, `plan.md`,
  and `iterate.md`; and no stated seam yet forwards extension content into a
  subagent prompt or lets an agent find it when invoked standalone.

The hybrid (structured facts in the manifest, prose in an extension) fails
on the manifest half for the reasons above: it buys validation for fields
nothing validates against, splits one payload across two files, and the
"structured" half is only ever consumed as prompt text anyway.

## Decision

**Host-project orientation lives in one new extension file,
`.claude/wurk/codebase.md`, keyed by the agent family it feeds rather than
by a skill. Invoking skills forward it verbatim in codebase-agent prompts;
agents that can read fall back to reading it themselves; absent the file,
behavior is exactly today's. The manifest is deliberately untouched.**

1. **Content is free-form markdown, addressed to the codebase agents.**
   Suggested headings, none required: layout (source and test roots), test
   suites and what distinguishes them, module families worth mining for
   patterns, terms-of-art vocabulary, and guidance prose (error conventions,
   purity, spec-port reading rules, best search keys). No schema and no
   validation - like every other extension file, the consumer maintains it
   and a wrong entry misleads exactly as far as a wrong CLAUDE.md line
   would. Consumers should keep it around a screenful: it is pasted into
   every codebase-agent prompt, so its length is a per-invocation cost.

2. **The fast path: skills forward it.** `wurk:research`, `wurk:plan`, and
   `wurk:iterate` - the three skills that spawn codebase agents - read
   `.claude/wurk/codebase.md` at the same point they read their own
   extension, and paste its content into each codebase-agent prompt under an
   explicit heading (e.g. "Project orientation, from the repo's
   .claude/wurk/codebase.md"). This is the same move those skills already
   make for the docs pair with `artifacts.*` roots, carrying prose instead
   of two paths. The skills learn nothing project-specific; they learn to
   forward a file whose name is fixed.

3. **The standalone path: agents read it at runtime.** Each codebase
   agent's Orienting ladder gains one rung, directly after the prompt:

   1. the prompt (unchanged, authoritative);
   2. `.claude/wurk/codebase.md`, when it exists and the prompt supplied no
      orientation;
   3. the repo's own orientation documents (unchanged);
   4. a directory listing (unchanged).

   wurk-codebase-analyzer and wurk-codebase-pattern-finder have Read and
   take the rung literally. wurk-codebase-locator has no Read tool; it may
   Grep the file for its headings or skip the rung, and in practice its
   orientation arrives by prompt - which the fast path makes the common
   case. One file read is the whole standalone cost; no JSON parsing, no
   Ruby, no manifest resolution walk.

4. **Absent configuration degrades to today's behavior.** No
   `codebase.md`, no manifest, no `.claude/` directory at all: the ladder
   falls through to repo orientation docs and a listing, and the agent says
   it oriented by guesswork, exactly as the agents behave now. Nothing
   fails and nothing warns.

5. **Add, never override.** Orientation content is facts about the project
   and search guidance - it cannot re-role an agent. The generic agent
   prose (documentarian not critic, output format, tool discipline) stands
   regardless of what the file says, the same way a skill extension adds
   steps without changing a skill's judgment rules.

6. **The extraction table reroutes.** The rows of phase 2 step 2's table
   that are orientation - statifier's pipeline-layer vocabulary (slated for
   `wurk/research.md`) and the Appendix D pseudocode rule and pattern
   categories (slated for `wurk/plan.md`) - are written to `codebase.md`
   instead when step 7 writes statifier's extensions. The per-skill files
   keep the genuinely skill-facing remainder: reference-checkout guidance
   and areas needing their own sub-agent in `research.md`, corpus/ratchet
   success criteria and required plan sections in `plan.md`.

This record extends ADR-0004 rather than amending or superseding it: the
extension seam's directory, format, reading discipline, and add-not-override
rule are unchanged, and the seam gains a second key shape - `.claude/wurk/`
holds per-skill files and now one agent-family file. ADR-0004's sentence
"Extensions `.claude/wurk/<skill>.md`" reads henceforth as naming the common
case, not an exhaustive rule.

## Consequences

- Implementation (not part of this record) touches: the three codebase
  agents' Orienting sections (one new rung each); the spawn sections of
  `skills/wurk:research`, `skills/wurk:plan`, and `skills/wurk:iterate` (one
  forwarding instruction each, next to the existing `artifacts.*`
  forwarding); `docs/architecture.md` layer 4 (the "per-skill markdown"
  wording and the examples list); and `docs/plan.md` step 7's extraction
  routing. `docs/manifest.md` and `lib/manifest.rb` change not at all -
  that is a stated property of this decision, not an omission.
- Consumer onboarding is unchanged in kind: one JSON file and zero-or-more
  markdown files; `codebase.md` is one more optional markdown file.
- The rediscovery cost moves from every agent invocation to one authoring
  session per consumer, plus maintenance when the project's shape changes.
  A stale `codebase.md` misleads agents with confidence; the mitigation is
  the same as for CLAUDE.md - a human owns it - and is not mechanized here.
- The fast path spends prompt tokens on every codebase-agent spawn
  proportional to the file's length. The one-screenful guidance in point 1
  is advisory; a consumer that writes ten screenfuls pays for them on every
  invocation, visibly, in its own sessions.
- Wurk itself may write a `.claude/wurk/codebase.md` (kit layout, script
  contract vocabulary) and thereby test the seam as its own consumer
  (ADR-0007), but nothing requires it to.

## Open questions

Recorded rather than guessed at; no maintainer was available when this
record was written.

- **Verbatim or excerpted forwarding when the file is long?** Point 2 says
  verbatim because excerpting is a judgment call the skill would make on
  every invocation, invisibly. If long files show up in practice, the
  choices are a documented soft cap the skill states when it truncates, or
  leaving it to the consumer's own restraint. Decide when it first hurts.
- **Does `codebase.md` join a judge registry?** ADR-0008 already holds the
  general form of this question for wurk's own `.claude/wurk/*.md` files.
  Orientation content as specified here is facts and search guidance, not
  policy, so nothing is judged today; a consumer whose `codebase.md` grows
  a policy call should look at its own judge's scope first.
- **Does the docs pair want the same rung?** Item 9's two-path lookup has
  been sufficient, and nothing here changes the docs agents. If a project's
  document conventions ever need prose-shaped orientation, the same file
  (or a sibling) is the obvious home; deferred until a real case exists.

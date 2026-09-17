# Harness placement: where a piece of harness content lives

You are about to write something that changes how an agent behaves - a
rule, a reminder, a procedure, a constant, a check. Wurk has ten places it
could go, and the choice is not a matter of taste: each home has a
different reader, loads at a different moment, and can or cannot be
enforced by a machine. Put a rule where nothing reads it and it does
nothing; put it where everything reads it and it costs every session
context it did not need.

This document is the decision procedure. It does not re-argue the seams it
routes to: ADR-0004 settled the manifest and extension seams, ADR-0013
added the machine-config seam, ADR-0019 settled templates and blocks, and
`docs/architecture.md` describes the four layers those live in. This is the
"which one, and why that one" that sits on top of them.

Read it before writing harness content. `skills/wurk:kit/REFERENCE.md`'s
writing-a-new-script section, ADR-0019, and `docs/architecture.md` each
point here, because those are the three places a person is standing when
the question comes up.

## The homes

| Home | Who reads it | When it loads | Machine can enforce it | Carries |
| --- | --- | --- | --- | --- |
| `CLAUDE.md` | every session in the repo, main thread and subagents alike | at session start, unconditionally | no | behavior |
| `skills/wurk:<name>/SKILL.md` | the session that invokes the skill | on demand, when a task triggers it | no | behavior |
| `agents/blocks/<block>.md` | every agent `agents/routing.yml` routes it to | when one of those agents is spawned | only that the copies agree | behavior |
| `agents/<name>.md.in` | that one agent | when that agent is spawned | only that the generated file is current | behavior |
| `hooks/<name>.sh` | the harness, not the model | at its hook event, every time, whatever the model intended | yes - it can deny the call | behavior, enforced |
| `skills/wurk:kit/scripts/<name>.rb` | a skill or agent step that runs it | when that step runs it | yes - `blocked[]` and the exit code | mechanics |
| `.claude/wurk.json` (manifest) | kit scripts, through `lib/manifest.rb` | whenever a script runs in that repo | yes - schema validation | fact the project decides |
| `~/.claude/wurk.local.json` (machine config) | kit scripts, through `lib/user_config.rb` | whenever a script runs on that machine | yes - schema validation | fact the machine decides |
| `.claude/wurk/<skill>.md` (extension) | the generic skill that names it | when that skill runs in that repo | no | behavior, consumer-specific |
| memory (`bd remember`, auto-memory) | every session the tracker primes | at prime time, `bd prime` | no | fact about the world |

### `CLAUDE.md`

The repo's always-on prose. Every session in the subtree reads it before it
does anything, which makes it the right home for the small number of rules
that have no trigger - the authority table, the hard rules, the commit
conventions - and the wrong home for anything a session only needs
sometimes. Its budget is its cost: every line is paid for by every session,
including the ones working something the line has nothing to do with. A
rule that arrives here because nowhere else was obvious is a rule that will
be skimmed.

### A skill

`skills/wurk:<name>/SKILL.md` is prose that loads when a task triggers it,
so it is where a procedure belongs: long, ordered, with judgment in it,
needed by whoever is doing that one kind of work. A skill may hold as much
as the work needs, because nobody who is not doing that work pays for it.
Generic skills carry no consumer constant - that is a hard rule, and the
contract test enforces it over every line of `skills/wurk:*/SKILL.md`. What
a skill needs from the project comes from the manifest or from its
extension file.

### A shared block

`agents/blocks/<block>.md`, routed by `agents/routing.yml`, is the home for
text that two or more agents must carry word for word. The point is not
brevity, it is that an edit reaches every copy: before ADR-0019 the
gate-wait discipline and the dispatch-relay rules lived in one agent, and a
consumer's forked variant carried a copy that nothing kept current. A block
is spliced in verbatim; it has no frontmatter and no includes of its own.
An agent belongs on a block's list when it may do the thing the block
governs, not when the text looks vaguely relevant to it.

### An agent template

`agents/<name>.md.in` is one agent's own prose: what only that agent does,
in the words only it needs. This is the default home for agent behavior,
and a block is the exception to it. Both are edited as sources - the
generated `agents/<name>.md` is committed but never hand-edited, and
`build_agents.rb --check` turns the gate red when one drifts (ADR-0019).

### A hook

`hooks/<name>.sh` is read by the harness rather than by the model, which is
the entire reason to use one: it fires whatever the model intended, so it
holds what prose has demonstrably failed to hold. The cost is that it must
be genuinely deterministic - a hook cannot weigh a situation, only match
one. Wurk's hooks are `#!/bin/sh`, fail-open (a malformed input lets the
call through rather than wedging the session), tested by the kit suite
through their own shebang, and installed only on an explicit opt-in. A
denial states the fix; see the rules of thumb below.

### A kit script

`skills/wurk:kit/scripts/<name>.rb` is where deterministic mechanics live -
the work that should not vary with which model is driving. It speaks the
envelope contract: stdlib-only system Ruby, one JSON envelope on stdout,
exit 0/1/2, `--dry-run` on every mutating path, shell-outs through
`lib/sh.rb`, and never a `git push`, request-opening, `bd close`, or
`bd edit`. A script is also a place to enforce a rule rather than merely
perform a step: a condition it cannot resolve becomes a `blocked[]` entry
with `needs: "human"`, and that refusal is a machine check the way a hook
is. Prefer a script over a hook when the check belongs to a step someone
already runs; prefer a hook when the thing to catch is something nobody
chose to run.

### The consumer seams

Three homes exist because the content is the same everywhere but a value in
it is not.

- **A manifest field** (`.claude/wurk.json`, `docs/manifest.md`) carries
  what the *project* decides: the bead prefix, the gate command, the forge,
  the worktrees directory. Data, not code - commands are argv arrays, and
  structural choices are explicit enums rather than inferred.
- **The machine config** (`~/.claude/wurk.local.json`,
  `docs/machine-config.md`) carries what the *machine or the person at it*
  decides: permission mode, what this box is called, how many full gates it
  can run at once. A value of this shape in the manifest would force one
  setting on everyone who works the repo (ADR-0013).
- **An extension file** (`.claude/wurk/<skill>.md`) carries a consumer's
  own *extra steps* rather than a value - a domain judge at the merge seam,
  a sabotage protocol, an orientation file for the codebase agents. A
  generic skill states where in its flow it reads its extension and honors
  the content as additional required steps.

The line between the first two and the third is data versus extra steps: if
a script consumes it, it is a field; if a skill reads it as prose and does
what it says, it is an extension.

Extensions add; they never override. A consumer that needs *different*
generic behavior has found a missing manifest field - change the schema and
`docs/manifest.md` in the same commit - not a skill to fork. The same rule
gives the manifest and the machine config their discipline: a script never
hardcodes a project value, and a new field's documentation moves in the
commit that adds it (`docs/manifest.md` with `lib/manifest.rb`,
`docs/machine-config.md` with `lib/user_config.rb`).

### Memory

`bd remember` stores a durable fact and `bd prime` injects it at session
start, so memory reaches every session in the repo without anyone loading
it. That makes it look like `CLAUDE.md` and it is not: memory is for facts
about the world that were learned rather than decided - this tracker is
local-only, this remote went private on a date, this identifier means that
thing. A behavior belongs in one of the homes above, where it is reviewed,
committed, and greppable. A fact that a reviewer would have to take on
trust belongs in memory, where it is not pretending to be a rule.

## The decision procedure

Ask these in order and stop at the first yes. The order is by cost: the
earlier rungs reach further for less.

1. **Is it a fact rather than a behavior?** A thing that is true about the
   world, not a thing an agent should do. Memory (`bd remember`). Stop.
2. **Is it deterministic, and has prose already failed to hold it?** Both
   halves matter. A machine check written for a rule nobody has broken is
   guessing at the failure; a rule that keeps being broken is not going to
   start working because it was restated more firmly. A hook when the thing
   to catch is something nobody chose to run; a kit check when it belongs
   to a step someone already runs. `docs/recipes/lesson-to-guard.md` is
   this rung in detail - the triage question, the refusal rule for
   judgement-only and flaky checks, the third form (a contract test over
   the tree), and the scaffold a guard carries before it lands.
3. **Does every session in this repo need it?** No trigger, no task it
   belongs to, wanted before the work starts. `CLAUDE.md`. Stop.
4. **Is it task-triggered, or long?** A procedure for one kind of work, or
   content too big to make every session carry. A skill. Stop.
5. **Do two or more agents need it word for word?** A shared block plus its
   `routing.yml` entry and an include in each template. Stop.
6. **Otherwise it is one agent's prose.** The agent's `.md.in`, rebuilt and
   committed with the generated file.
7. **Does any of it vary per consumer or per machine?** Asked last, of
   whatever home the earlier rungs chose, because it does not move the
   content - it moves the value out of it. A project value becomes a
   manifest field, a machine value becomes a machine-config key, and extra
   steps a single consumer needs become that consumer's extension file. The
   generic content keeps its home and reads the seam. Never a constant.

Two rungs are worth restating because they are the ones people skip. Rung 2
is the only rung that produces a machine check, and it is deliberately
narrow: everything else here is prose, which means it is advice a model may
weigh against the situation. Rung 7 is asked even when rungs 1 through 6
gave a confident answer - a correct home with a consumer's path baked into
it is still a hard-rule violation, and the contract test finds it.

## Rules of thumb

- **The cheapest home that still reaches the moment.** The question is not
  "who might want to know this" but "who is standing where, when the rule
  applies". A rule that only matters while writing a script belongs where
  someone writing a script is standing, not in the file every session
  reads. Reaching too far is the more common error, because it feels safe.
- **A block with one consumer is a smell.** Blocks exist so an edit reaches
  copies that would otherwise drift. One consumer means there are no copies
  yet, so the routing entry buys nothing and costs a lookup. Write it as
  template prose and extract it when the second agent appears - unless the
  second consumer is a known fork outside this repo, which is the case
  ADR-0019 was decided for.
- **Never restate a block; point to it.** A paraphrase beside a block is a
  second copy that the build check cannot see, and it is the copy that will
  be wrong. The same holds for a manifest field described in prose and for
  an ADR's reasoning: cite it by name and let the one authority answer.
- **A guard's failure output carries an actionable `Fix:` clause.** A hook
  or a script that refuses has the reader's full attention exactly once, and
  a refusal that only names the rule leaves them to guess the remedy - which
  is how a guard gets disabled instead of satisfied. Say what was wrong and
  what to do about it, in the denial itself.
- **Documentation moves in the same commit as the thing it documents.**
  This is already a hard rule for the manifest and the machine config, and
  it is the general case: a home whose doc lags is a home whose readers
  learn the old shape.
- **Cite steps by name, not by number.** A number is a position, and every
  step inserted above it silently invalidates the citation. This applies to
  every home here, and it is what lets a pointer survive the next edit.

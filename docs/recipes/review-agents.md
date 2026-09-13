# Recipe: pre-request review agents

`/wurk:mr` runs one round of adversarial review after the gate is green
and before the push, when the manifest names the agents to run. The round
is generic; the reviewers are not. This recipe is how a consumer declares
the round, which reviewers wurk ships, what a reviewer of the consumer's
own must look like, and how the round differs from the two other
adversarial passes wurk has.

## Declaring the round

```jsonc
"mr": {
  "review_agents": ["wurk-diff-critic", "wurk-test-critic"]
}
```

Absent means no round, silently. Present means every name resolves to a
file, or `manifest.rb check` blocks (`mr_review_agent_missing`): a name is
looked up first as the repo's own `.claude/agents/<name>.md`, then as the
installed `~/.claude/agents/<name>.md`, which is where `install.rb` links
the agents wurk ships. A repo file shadows an installed one of the same
name, so a consumer can ship a variant under wurk's name. The section is
present-or-absent: an empty list is a schema error, not a disabled round
(`docs/manifest.md`, "`mr.review_agents`").

## The two wurk ships

Both are read-only, spawned fresh each run, and rank every finding with
one of three words that `/wurk:mr` honors as the reporting agent's call:
`must-fix` (the request is not opened with this in it), `should-fix`
(carried into the request body), `note` (carried, may be declined).

- **`wurk-diff-critic`** reads the branch's diff against the bead's
  acceptance criteria: a criterion with no hunk, a hunk outside the bead's
  scope, an edge or error path the new code mishandles, a contract changed
  without its callers, a commit message that claims what the diff does not
  do.
- **`wurk-test-critic`** reads the tests the branch adds or changes and
  asks, for each, which single-line mutation of the subject it would
  catch. An assertion that cannot fail, a mock standing in for the unit
  under test, a test that passes with the feature removed, a `# sabotage:`
  note whose mutation the assertion is blind to, a weakened or skipped
  existing test: each is a finding. It complements the sabotage scan
  (`docs/recipes/sabotage-testing.md`), which checks that a note exists;
  the critic checks that the note is true.

Neither knows anything about a particular project. A project with a rule
of its own (a privacy modifier that must be on every new view, an
instruction-set drift check, a records-file convention) writes its own
agent for it.

## Writing one of your own

An agent is a markdown file with frontmatter, under `.claude/agents/`.
The shape wurk's two use, reduced to what the round depends on:

```markdown
---
name: convention-reviewer
description: Reviews a finished branch for <the project's rule>, run by /wurk:mr's pre-request review round. Read-only. Ranks findings must-fix / should-fix / note.
tools: Bash, Read, Grep, Glob
model: sonnet
color: red
---

You are an adversarial reviewer of a branch that is about to become a
request. You did not write it and have not seen the conversation that
produced it.

## What you are given

The checkout path, the bead id, and the default branch to diff against.

## What to run

Only `git diff <base>...HEAD` and `git show`; read the files the diff
touches. Nothing that writes.

## What to check

<The rule, as a question the diff can answer. One numbered item per
distinct failure the rule has. Name the input or state that exposes it.>

## Severity vocabulary

Exactly these: **must-fix**, **should-fix**, **note**. An unranked
finding is not a blocker; do not leave one unranked.

## Output Format

<A fixed template: verdict line, then one block per finding with
severity, file:line, what the diff does, what is wrong, and the smallest
fix; then a "checks that passed" list naming what you looked at.>

## What NOT to do

Don't edit, don't commit, don't re-review the plan, don't rank higher to
be safe, don't record anything on the bead.
```

Four properties are load-bearing, and `/wurk:mr` relies on each:

- **Read-only, with Bash limited to reading the diff.** The skill makes
  the fixes and commits them; an agent that edits produces changes the
  gate never saw.
- **Fresh context.** The agent's value is that it has not argued a
  position about this branch. Do not give it the plan or the conversation;
  give it the diff and the bead.
- **A severity vocabulary the agent states and uses on every finding.**
  The skill never re-ranks and never promotes an unranked finding, so a
  finding with no severity is carried as a note at best.
- **Findings specific enough to act on without a second round.** The
  round is single by design: file, line, input, outcome, smallest fix.

## What the round is not

`judge` is a merge-time propose-and-refute pass over **registered
documents**: does this change to judgment-bearing prose break the rule a
named record states (ADR-0008, `docs/recipes/adrs.md`). The review round
is a review of **the diff** in the consumer's own terms. A repo can run
either, both, or neither.

`wurk-plan-critic` reviews the **plan** before it is presented, at plan
time. The review round reviews the **branch** after it is built, at
request time. The same finding can surface at both; the plan critic
catching it is cheaper.

## What happens with the findings

`/wurk:mr` spawns one fresh instance of each named agent in a single
batch, addresses the must-fix findings, commits the fixes with
`/wurk:commit` (whose gate run is the re-gate) when the tree changed, and
carries every other finding into the summary and the request body, filing
a bead for anything that deserves its own work. It never spawns a second
round to check the fixes; a round whose findings are large enough to want
one is a signal that the branch is not ready.

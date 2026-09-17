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

## Trusting a critic

A must-fix finding stops a request from opening. Nothing in the round asks
whether the agent that reported it deserves that authority, and the two
ways an undeserving one fails are both expensive: an agent that ranks
everything must-fix trains the reader to wave the round through, and an
agent that ranks nothing must-fix costs the round its point. So a critic
earns blocking authority the same way any other gate does - by being
measured on cases whose answer is already known.

The bar is **recall and precision of at least 0.8** over a labeled corpus.
Below it the agent still has value; it just runs **advisory** - kept out of
`mr.review_agents` and hand-run, its findings read rather than honored -
until a revision clears the bar. Declaring it is what makes it blocking,
so the manifest entry is the promotion.

### The corpus

One directory per case, each holding the diff the agent is given and a
`meta.json` that says what the right answer is:

```
corpus/
  swallowed-error/
    diff             the diff the agent reviews
    meta.json        the label
  scoped-refactor/
    diff
    meta.json
```

```jsonc
{
  "label": "bad",                  // "bad" = a finding is owed here;
                                   // "good" = nothing here blocks
  "agent": "wurk-diff-critic",     // (opt) whose case this is; omit for
                                   // a case every agent should get right
  "expect": {
    "severity": "must-fix",        // (opt) this case's blocking rank
    "contains": "error path"       // (opt) a substring the finding must
                                   // carry to count as a hit
  },
  "why": "the rescue turns a failed write into a silent success"
}
```

`expect.contains` is what keeps a hit honest. Without it, an agent that
ranks every diff must-fix scores perfect recall by accident; with it, the
finding has to name the planted defect. Write it as the shortest phrase the
right finding cannot avoid, and never as a phrase only one wording of the
right answer would produce.

Four or five cases is a floor, not a target, and roughly half should be
`good`: precision is measured entirely on the cases where the right answer
is silence, and a corpus of nothing but planted defects measures only
eagerness. Keep the diffs small and self-contained - a case is read by a
human deciding whether the label is right, and one that needs the whole
repo to judge will be relabeled wrong later.

**Label the cases yourself.** A corpus labeled by running the critic and
recording what it said measures nothing: it is the agent grading its own
homework, and every miss is baked in as the right answer.

### The saved outputs

Run each case by hand or from a harness of your own and save the agent's
output verbatim, one file per case:

```
outputs/
  swallowed-error.md
  scoped-refactor.md
```

The scorer never runs a model. That is the contract (ADR-0006): a kit
script is deterministic, so the same saved outputs score the same way
twice, and a red bar is never an agent having a bad afternoon. It also
means a run is reviewable - the output that produced a miss is on disk to
read.

### Scoring

```bash
ruby ~/.claude/skills/wurk:kit/scripts/critic_eval.rb \
  --corpus corpus --outputs outputs --agent wurk-diff-critic
```

Each case lands on one of four outcomes: a `bad` case with a blocking
finding that carries the expected substring is a **hit**, a `bad` case
without one is a **miss**, a `good` case with any blocking finding is a
**false positive**, and a `good` case without one is a **true negative**.
Precision is hits over hits plus false positives; recall is hits over the
`bad` cases. The mandated summary line is exempt: a `Verdict:` line whose
only severity mention is a count (`N findings (M must-fix)`) reports how
many findings carry a rank rather than asserting one, so it is not itself a
finding - a `Verdict:` line that ranks something instead still is. `data.meets_bar` answers the question the bar asks;
`data.cases` says which case moved the number, which is the half worth
reading when it fails.

A run below the bar is still a successful run - the script reports and
warns (`below_trust_bar`), and never edits a manifest. Promoting an agent
to blocking, or demoting one, is a call with a person's name on it
(ADR-0008); a script that flipped the field on a score would be making it
for them.

The kit ships a four-case worked example under
`skills/wurk:kit/scripts/test/fixtures/critic_eval/` - one of each
outcome, scoring 0.5 and 0.5. It is what the scorer's own tests run on,
and it is a corpus that fails the bar on purpose: a critic with one hit,
one miss and one false positive out of four is exactly the one that should
not be blocking anything yet. A second, two-case corpus sits beside it under
`incidents/`, holding the output shapes that once scored wrong - a clean
review carrying only the summary line, and a finding whose body quotes code.
It scores 1.0 and 1.0, and is kept separate so the worked example's numbers
stay the ones this section names.

### When to re-run it

Whenever the agent's own prose changes, and whenever a real round produces
a finding that surprises you in either direction - a must-fix nobody
agreed with, or a defect the round let through. Add that case to the
corpus with the label you wish the agent had produced, and the next run
says whether the revision fixed it or moved the problem.

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

An agent that cannot run is **fail-open, loudly**: the round proceeds, and
`review agent <name> did not run` goes into the request body and onto the
bead, because an agent that reported nothing is not an agent that found
nothing. `/wurk:mr`'s review-round step states the rule and where the line
is recorded.

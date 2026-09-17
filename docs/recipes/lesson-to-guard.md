# Recipe: turning a lesson into a guard

A campaign retro files a defect bead for every passage someone had to
improvise around. Most of those beads get fixed as prose, because prose is
what the retro was reading when it noticed. Some of them should not be:
a gate verdict read through a pipe, a note appended to the wrong line, a
generated file hand-edited are mistakes a machine can catch, and prose is
the weakest home a machine-catchable mistake can have - it is advice a
model weighs against the situation, and the situation is exactly what was
misjudged the first time.

This recipe is the triage between the two, and the bar and the scaffold a
guard has to clear before it earns a place in the gate. It does not decide
*where* harness content lives: that is `docs/harness-placement.md`, whose
decision procedure routes a deterministic rule that prose has failed to
hold to a hook or a kit check. Read that first and come here when it sends
you; this is the detail behind that one rung, deliberately kept out of it.
For the test half - how a new check proves it can fail - see
`docs/recipes/sabotage-testing.md`.

## The triage question

One question, asked of the incident and not of the category:

> Could a machine have caught **this** incident, from an input available
> at the moment the mistake was made, with the same verdict every time?

Three things have to be true together. The verdict is deterministic. The
input exists where the check would run - a command line, a file, a
tree. And the check is right, not merely reproducible: a pattern that
fires on the mistake and on four legitimate neighbors is not a guard, it
is a false alarm with a regex.

Worked both ways from this repo's own history:

- "A gate verdict was read through `| tail`" - the command line is the
  input, the shape is a pattern, the verdict never varies. Guard.
- "A hook denied a call without saying how to fix it" - the input is the
  hooks directory, the check is a scan, and `test/hooks_test.rb` is now
  the guard that holds it.
- "The dispatch under-specified the bead, so the worker guessed" - no
  input names under-specification, and judging it is the work. Prose.
- "A worker widened its own consent" - the incident is a judgement made
  wrongly, not a shape. Prose, and a strongly worded one.

## The refusal rule

Refuse to write the guard, and say so on the bead, when any of these
holds. Refusing is an outcome, not a failure to deliver:

- **It needs judgement.** The check would have to weigh a situation, rank
  a severity, or decide whether a passage means what it says. No static
  check tells a message that names a fix from one that only sounds like
  it (`skills/wurk:kit/REFERENCE.md`, "A blocked message names what to
  change"), and that is the general case, not a quirk of that one rule.
- **It would be flaky.** The verdict moves with timing, machine load,
  network, file ordering, or the wording a model happened to choose. A
  guard that fires on a clean tree gets disabled, and disabling it takes
  the real cases with it - so a flaky guard is worse than the prose it
  replaced, not merely equal to it.
- **It cannot state its own fix.** If the check can detect the condition
  but cannot say what to do about it, the denial reaches a reader who is
  already stuck and leaves them there. That is how a guard gets worked
  around instead of satisfied.

A refusal goes back on the bead in one line naming which of the three it
tripped, so the next retro that sees the same class does not re-open the
question from zero.

## The bar

One guard per genuine recurring deterministic class. A class qualifies at:

- **two or more campaigns** in which the same class of mistake happened,
  whoever made it; or
- **one unambiguous factual gap** - a rule whose violation is a fact
  rather than a judgement, that landed anyway. A hand-edited generated
  file and a non-ASCII character in a repo that requires ASCII are facts;
  "the paragraph was unclear" is not.

A single incident that could have gone either way is prose plus a note in
the bead. If it recurs, the bead filing the second incident is the one
that qualifies the class, and it cites the first. The bar is there
because guards are cheap to add and expensive to own: each one runs on
every gate forever, and each false positive spends trust that the next
guard needs.

## The three forms

Wurk has three places a deterministic check can live. The placement
procedure already chooses between the first two at its
deterministic-and-prose-has-failed rung; the third is a check over the
tree itself, which belongs to nobody's step.

1. **A hook** - `hooks/<name>.sh`, for catching a call nobody chose to
   run. It is `#!/bin/sh`, fail-open, installed only on an explicit
   opt-in, its deny reason carries a literal `Fix:` clause, and it ships
   its own `--self-test`. `hooks/safe-wait-guard.sh` is the exemplar.
2. **A kit check** - a refusal inside a script some step already runs,
   surfaced as a `blocked[]` entry with a message that names the move and
   an exit code the caller honors. `worktree_create.rb`'s base preflight
   (`preflight_refused`) is the exemplar: it stops the cut, names the
   reason, and leaves the repair to a human.
3. **A contract test** - a test file under
   `skills/wurk:kit/scripts/test/`, which `run.rb`'s glob picks up with
   no registration, asserting a property of the tree. `hooks_test.rb`'s
   deny-message contract over every hook (with its
   `HOOKS_WITHOUT_A_DENY_PATH` exempt list) and `contract_test.rb`'s
   banned-operation scan are the two exemplars.

Choosing between them is one question: is the thing you are guarding a
**call** (hook), a **step's input or state** (kit check), or a
**property of the committed tree** (contract test)?

## The scaffold

Whatever the form, a guard is not finished until it carries all of these.

1. **A self-test that runs both ways.** Fail on the bad input *and* pass
   on the clean one. A check exercised only against the mistake is a
   check that might deny everything, and that failure shows up as a
   session working around it rather than as a red suite. A hook's
   `--self-test` enumerates allow cases beside deny cases; a kit check
   and a contract test get a test of each.
2. **An actionable `Fix:` clause.** The refusal names what was wrong and
   what to do next, in the refusal itself. Hooks carry the literal
   clause and `hooks_test.rb` checks for it; a script's `blocked`
   message carries the same content by convention.
3. **A test named for the incident.** Name it
   `test_denies_a_self_matching_pgrep_loop`, not `test_rule_three`. The
   name is what makes the suite a regression corpus: a reader who hits
   the red test learns which real mistake bought the check, and a later
   retro greps the class and finds the guard instead of filing it again.
4. **Exemptions that cost something.** If legitimate exceptions exist,
   enumerate them in the source with a reason each - the way
   `HOOKS_WITHOUT_A_DENY_PATH` requires a written justification per entry
   - never a flag that turns the guard off.
5. **A sabotage note.** Break the thing the guard covers, watch the test
   go red, revert, record the mutation
   (`docs/recipes/sabotage-testing.md`). A guard whose test cannot be
   made to fail is decoration.

## Wiring it into the gate

- **A contract test** needs no wiring: `run.rb` globs `**/*_test.rb`
  under the test directory. Landing the file is the wiring.
- **A kit check** runs when its script runs, so the wiring is on the
  calling side - the skill that runs the script must read the new
  `blocked` code and stop on it, and that prose lands in the same commit.
- **A hook** needs two things, because a hook only fires for someone who
  installed it: cases in `test/hooks_test.rb` so the kit gate covers the
  script, and an install path (`install.rb --with hooks` plus the
  settings wiring it prints). The consequence is that a hook is never the
  only home a rule has - state the rule in its prose home as well, and
  let the hook hold it for the people who opted in.

Last, write the guard's path and its test name back into the bead that
filed the lesson. That line is what turns the next retro's grep of the
same class into a pointer rather than a duplicate.

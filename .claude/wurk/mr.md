# /wurk:mr extension: wurk

## Additional step, after step 4 (the gate) and before step 6

Run the prose judge over this branch:

    ruby skills/wurk:kit/scripts/judge.rb

It judges the branch diff's `skills/**/SKILL.md` hunks against ADR-0008,
proposing violations and then independently trying to refute each one, and
reports only what survives. The registry it reads is `judge` in
`.claude/wurk.json`.

**A surviving finding refuses the request.** Report the finding - file, line,
and the claim - and stop. Do not push, do not open the request, and do not
re-run the judge hoping for a different verdict: a second sample is not
evidence, and a finding that a human disagrees with is a conversation to
have, not a result to reroll. Only a person may decide a finding is wrong;
this step never decides that on their behalf.

**A skip is not a pass.** `data.status: "skipped"` with `no_cli`,
`no_base_ref`, `no_scoped_changes`, or `no_registry` means the judge did not
run. Say which reason in the request body and the final report. A branch that
touches no skill prose skips for a good reason and is fine to push; a branch
that touches skill prose and skipped because the CLI was missing was not
judged, and saying so is the whole point of reporting the reason.

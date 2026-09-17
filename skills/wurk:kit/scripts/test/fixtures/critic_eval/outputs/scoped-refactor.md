# Diff review

Verdict: findings below. Severity vocabulary: must-fix / should-fix / note.

## Findings

1. lib/queue_reader.rb:8 - must-fix
   The new predicate has no test in this diff, so the branch must not open
   a request.

## Checks that passed

- No caller needs updating.

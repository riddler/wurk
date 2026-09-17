# Diff review

Verdict: findings below. Severity vocabulary: must-fix / should-fix / note.

## Findings

1. lib/report_writer.rb:14 - must-fix
   The new rescue swallows the error path: a failed write returns nil and
   the caller reports a report it never wrote. Re-raise, or return a
   result the caller checks.

2. lib/report_writer.rb:12 - note
   `render` is called inside the begin block; only the write needs guarding.

## Checks that passed

- No public contract changed.

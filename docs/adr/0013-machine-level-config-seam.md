# ADR-0013: A third seam for machine-level config

Status: accepted (2026-08-22)

## Context

ADR-0004 settled two seams, both in the consumer repo, on the premise that
everything a script needs is either a project constant (the manifest) or
project domain prose (an extension). wu-b7f found a value that is neither:
the seeded session's permission mode is a property of the machine and the
person at it, not of the project. Putting it in the manifest forces one
setting on every engineer working the repo, and changing it means editing
and committing a tracked file.

This ADR amends ADR-0004; it does not contradict it. The two seams ADR-0004
settled are unchanged - this adds a third for the one shape of value neither
covers.

## Decision

A third seam, `~/.claude/wurk.local.json`, read by `lib/user_config.rb`.
HOME-anchored (never resolved by walking up from the working directory, and
never falling back to a git checkout), absent-safe (no file is a normal,
valid state with documented defaults), and validated on the same asymmetry
as the manifest (an unrecognized key warns, an enum value outside the known
set blocks). Documented in `docs/machine-config.md`.

The placement rule going forward: the manifest carries what the project
decides, the machine config carries what the machine or the person at it
decides, and a value that is genuinely both is a manifest field with a
machine-level override - which nothing needs yet and which this ADR does
not authorize in advance.

## Consequences

- Consumer repos never carry a permission-mode setting; it is removed from
  the manifest schema entirely rather than left as a project-level default.
- A new machine onboards with zero files, because absent is the default.
- A fourth kind of value now has a home, so schema pressure has somewhere to
  go besides the manifest.
- The kit gains a second config reader (`lib/user_config.rb` alongside
  `lib/manifest.rb`) to keep in step with the first.

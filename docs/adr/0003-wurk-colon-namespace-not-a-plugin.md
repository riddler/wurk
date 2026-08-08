# ADR-0003: The wurk: namespace via colon-named skill directories, not a plugin

Status: accepted (2026-08-08)

## Context

Shared skills in `~/.claude/skills` are visible in every project, so generic
names (`commit`, `create-plan`, `work`) would collide with or shadow skills a
project defines locally. Claude Code plugins provide namespacing
(`plugin:skill`) plus versioning, but add marketplace/packaging overhead. The
existing personal skills `present:kit` / `present:deck` prove that a colon in
a skill directory name is just a directory-name character - the namespace
works with no special support.

## Decision

All wurk skills are directories named `wurk:<name>` (wurk:work, wurk:plan,
wurk:research, wurk:implement, wurk:commit, wurk:mr, wurk:next, wurk:branch,
wurk:refresh, wurk:cleanup, wurk:issue, wurk:iterate, wurk:release), with
`wurk:kit` as the shared foundation skill holding REFERENCE.md and the
scripts, mirroring the proven `present:kit` pattern. "wurk" is a deliberate
misspelling so nothing legitimate ever wants the prefix. Plugin packaging is
explicitly deferred, not rejected: the layout is nearly identical, so
graduating later is cheap.

## Consequences

- No collisions with project-local skills; project skills can even wrap wurk
  ones under their old names during migration.
- Cross-skill references use installed names (`/wurk:commit`); renames are
  atomic across skills, scripts, and script tests.
- No plugin registry, versioning, or distribution machinery to maintain now;
  the trigger to revisit is consumers needing to pin divergent versions.

# wurk

A shared, project-agnostic development workflow for Claude Code: bead-tracked
issues driven through research -> plan -> implement -> commit -> merge, with
parallel per-issue worktrees, packaged as skills under the `wurk:` namespace
(a deliberate misspelling of "work", so the names never collide with skills a
project defines for itself).

Wurk generalizes the skill set grown in
[statifier-ex](../statifier-ex) and kept (drifting) in sync by hand with
[predicator-ex](../predicator-ex), with
[fixative](../fixative) (Rust + Swift, GitLab) as the cross-language target.
Projects consume it by writing a small manifest (`.claude/wurk.json`) and
optional per-skill extension files - they do not copy skills, so improvements
land everywhere at once.

## Status

Design phase. The plan an implementing agent should follow is
`docs/plan.md`. Nothing is installed or ported yet.

## Layout (target)

```
skills/wurk:*/       generic skills (wurk:work, wurk:plan, wurk:commit, ...)
skills/wurk:kit/     shared foundation: REFERENCE.md + the Ruby scripts layer
agents/              the six read-only research agents
install.rb           symlinks skills + agents into ~/.claude
docs/                plan, architecture, manifest schema, gate contract
docs/adr/            settled decisions; cite numbers instead of re-arguing
```

## Reading order

1. `docs/architecture.md` - the four layers and where project-specific
   content lives
2. `docs/manifest.md` - what a consumer repo declares
3. `docs/gate-contract.md` - how quality gates plug in across languages
4. `docs/plan.md` - the migration, phase by phase
5. `docs/adr/` - why it is shaped this way

## Testing

The kit's minitest suite is this repo's quality gate, standalone on system
Ruby: `ruby skills/wurk:kit/scripts/test/run.rb` (once the kit lands in
phase 2).

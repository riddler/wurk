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
optional markdown extension files - they do not copy skills, so improvements
land everywhere at once.

## Status

Phase 2 (lifting the workflow into this repo) is underway and most of it is
done: the kit's Ruby scripts layer, all 14 generic `wurk:*` skills, and the
ten agents (eight read-only research agents plus the campaign pair) are
ported and pass their test suite, and
`install.rb` symlinks them into `~/.claude`. Phase 1 (parameterizing
statifier-ex in place) landed on a statifier-ex branch but is not yet merged,
which blocks the remaining phase 2 steps (slimming statifier-ex back down).
Phases 3 (predicator-ex adoption) and 4 (fixative) have not started. See
`docs/plan.md` for the phase-by-phase state.

## Layout

```
skills/wurk:*/       generic skills (wurk:work, wurk:plan, wurk:commit, ...)
skills/wurk:kit/     shared foundation: REFERENCE.md + the Ruby scripts layer
agents/              eight read-only research agents + wurk-repo-worker, wurk-fleet-scout
install.rb           symlinks skills + agents into ~/.claude
docs/                plan, architecture, manifest schema, gate contract
docs/adr/            settled decisions; cite numbers instead of re-arguing
```

## Install

```
ruby install.rb              # symlink skills/wurk:* and agents/*.md into ~/.claude
ruby install.rb --dry-run    # say what would happen, change nothing
ruby install.rb --uninstall  # remove only the symlinks that point into this clone
```

Re-running is a no-op. Anything in the way that wurk did not create - a real
directory, a real file, a symlink pointing somewhere else - is refused by name
and left untouched; the run exits 1 and you move it aside by hand. Skills and
agents are linked, not copied, so an edit in this clone is live immediately.

## Reading order

1. `docs/architecture.md` - the four layers and where project-specific
   content lives
2. `docs/manifest.md` - what a consumer repo declares
3. `docs/gate-contract.md` - how quality gates plug in across languages
4. `docs/plan.md` - the migration, phase by phase
5. `docs/adr/` - why it is shaped this way

## Testing

The kit's minitest suite is this repo's quality gate, standalone on system
Ruby: `ruby skills/wurk:kit/scripts/test/run.rb`.

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
done: the kit's Ruby scripts layer, all 15 generic `wurk:*` skills, and the
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
agents/              eight read-only research agents + wurk-repo-worker,
                     wurk-fleet-scout, wurk-retro-reader
                     (generated from *.md.in + blocks/ by build_agents.rb; edit those)
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

## Adopting wurk in a repo

Once per machine, clone wurk and link it (macOS has the Ruby this needs;
elsewhere install Ruby 2.6 or newer first):

```bash
git clone <wurk remote> ~/repos/github/wurk
cd ~/repos/github/wurk && ruby install.rb
```

Then open a Claude Code session at the root of the repo to adopt and paste:

> Read docs/adoption.md in the wurk clone, then run /wurk:init --defaults
> in this repo. Pilot shape: nothing committed, nothing pushed, no bd
> bootstrap, no bd dolt push. Install any missing tool after asking me.

The skill installs what the machine lacks (Homebrew, mise, beads, tmux,
the forge CLI, a current Ruby if the system one is too old), one tool at a
time with your consent, then takes every structural default without
asking: beads as the tracker (always, even with Jira or Linear upstream),
worktree-per-issue with a tmux session, a local-only tracker, decision
records, sabotage notes, and a pre-request review round. It ends with a
linted manifest, a green gate through the kit, and nothing in the repo's
history; `docs/adoption.md` is the same path by hand, and
`docs/local-only-pilot.md` is what the pilot shape promises and forbids.
Drop `--defaults` to be asked each choice instead.

## Reading order

1. `docs/architecture.md` - the four layers and where project-specific
   content lives
2. `docs/manifest.md` - what a consumer repo declares
3. `docs/gate-contract.md` - how quality gates plug in across languages
4. `docs/plan.md` - the migration, phase by phase
5. `docs/adr/` - why it is shaped this way

A repo adopting wurk from nothing follows `docs/adoption.md` - the ordered
checklist from prerequisites to the first merged bead, landing in the
zero-footprint pilot shape that `docs/local-only-pilot.md` describes and
whose prohibitions it states. `docs/examples/` holds per-language worked
manifests and `docs/recipes/` the optional disciplines (sabotage testing, a
coverage floor, decision records, a pre-request review round). These are
adoption guidance rather than part of the reading order above.

## Testing

The kit's minitest suite is this repo's quality gate, standalone on system
Ruby: `/usr/bin/ruby skills/wurk:kit/scripts/test/run.rb`.

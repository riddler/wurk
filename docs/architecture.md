# Architecture

Wurk is a shared, project-agnostic implementation of a bead-tracked
development workflow (research -> plan -> implement -> commit -> merge,
with parallel per-issue worktrees), packaged as Claude Code skills under the
`wurk:` namespace. Projects consume it by writing a small manifest and
optional extension files; they do not copy skills.

## The four layers

```
~/repos/github/wurk (this repo, installed by symlink into ~/.claude)
  skills/wurk:*/SKILL.md      generic skills: judgment, sequencing, reporting
  skills/wurk:kit/            shared foundation: REFERENCE.md + scripts/
  agents/*.md                 the six read-only research agents

<consumer repo>/.claude/
  wurk.json                   the manifest: every project-specific constant
  wurk/<skill>.md             extensions: domain content a skill reads and honors
  settings.json               hooks (bd prime) and deny rules stay per-project
  CLAUDE.md                   authority table; wurk defers to it, never widens it
```

### Layer 1: generic skills

Ported from statifier-ex's post-extraction form: prose organized as
"What to run / How to read the result / Judgment / Report". A generic skill
may contain no project constants - no bead prefixes, paths, gate commands,
label vocabularies, model names, or ADR numbers of any consumer repo. Anything
a skill needs from the project comes from the manifest (via kit scripts) or
from an extension file.

### Layer 2: the kit (scripts)

The deterministic mechanics, in Ruby (system Ruby, stdlib only - ADR-0006).
Ported from statifier-ex's `.claude/scripts/` with its contract intact:

- One JSON envelope on stdout: `ok`, `script`, `data`, `warnings[]`,
  `blocked[]` (with `needs: "human"`), `commands[]`. Exit 0 = ran and judged,
  1 = crashed, 2 = usage error.
- `--dry-run` on every mutating script.
- All shelling out through `lib/sh.rb` (argv arrays, no shell
  interpolation, timeout support, FakeSh-swappable for tests).
- Banned operations, enforced by the contract test: scripts never
  `git push`, `gh pr create` / `glab mr create`, `bd close`, or `bd edit`.
  Those stay literal skill instructions so a human-meaningful gate sits in
  front of every irreversible action.
- Minitest suite; runs standalone (`scripts/test/run.rb`) and is this repo's
  quality gate.

New in wurk: `lib/manifest.rb`, the single place that locates, parses, and
validates the consumer repo's `.claude/wurk.json` and hands typed values to
the other scripts.

### Layer 3: the manifest

`.claude/wurk.json` in the consumer repo. Schema and per-repo example values:
`docs/manifest.md`. Design rules:

- Data, not code. Commands appear as argv arrays, not shell strings.
- Everything optional has a documented default or a documented
  degraded behavior (see the gate tiers in `docs/gate-contract.md`).
- Structural switches are explicit enums, not inferred: parallelism model
  (`worktree-per-issue` | `branch-in-place`), forge (`github` | `gitlab`),
  tracker topology (`beads` | `beads-with-forge-projection`), changelog mode
  (`fragments` | `keep-a-changelog` | `none`).

### Layer 4: extensions

Optional per-skill markdown at `.claude/wurk/<skill>.md` (e.g. `wurk/mr.md`,
`wurk/plan.md`). A generic skill states where in its flow it reads its
extension and treats the content as additional required steps or domain
patterns. Examples of what lives here rather than in wurk:

- statifier-ex: ADR judge invocation at merge time, sabotage protocol,
  corpus/ratchet success criteria, Appendix D conventions.
- predicator-ex: ISA Impact sections, ISA sizing rule, hex release recipe.
- fixative: UniFFI/SwiftUI-privacy plan patterns, bead-to-GitLab promotion.

Extensions add; they do not override. A project needing to change generic
behavior (not just extend it) is a signal the manifest schema is missing a
field - fix the schema, do not fork the skill.

The same split applies to agents: wurk ships the shared roster (the
`wurk-*` agents), and a consumer repo's `.claude/agents/` holds domain
agents that would never generalize (a sabotage auditor, an ISA-drift
checker). Wurk skills tolerate project agents but never depend on one.

## Authority model

Unchanged from the consumer repos: each repo's CLAUDE.md carries the
trigger-gated authority table (what may be committed, pushed, closed, and by
whom). Wurk skills read and defer to it. The kit's banned-operations list is
the mechanical floor under that; the table is the per-repo ceiling. Wurk
never ships an authority grant of its own.

## Install

`install.rb` symlinks each `skills/wurk:*` directory and each `agents/*.md`
file into `~/.claude/`. Idempotent, `--dry-run`, refuses to replace an
existing non-symlink entry. Updating wurk = `git pull` in this repo; the
symlinks pick it up. This follows the pattern already proven by
`~/.claude/skills/present:kit` (colon-named skill directories are plain
directories; nothing special is needed for the namespace).

## Testing and gates for this repo

The kit's minitest suite is the gate here, run directly (no mix, no mise
required): `ruby skills/wurk:kit/scripts/test/run.rb`. The contract test is
part of that suite. Consumer repos stop gating skill content they no longer
contain; statifier-ex narrows its ADR judge scope accordingly (recorded in a
statifier ADR, per docs/plan.md phase 2).

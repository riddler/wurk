# Project instructions for AI agents

## What this repo is

Wurk: the generalized, shared implementation of the bead-tracked development
workflow used by statifier-ex, predicator-ex, and (later) fixative. It is
installed into `~/.claude` by symlink and consumed by those repos through a
manifest + extension files. Read `docs/architecture.md` before changing
anything; `docs/plan.md` is the active migration plan; `docs/adr/` records
settled decisions - cite ADR numbers instead of re-arguing them.

## Hard rules

- Generic skills and kit scripts contain no consumer-project constants: no
  bead prefixes, repo paths, gate commands, label vocabularies, or consumer
  ADR numbers. Anything project-specific comes from the manifest
  (`docs/manifest.md`) or a consumer extension file.
- The kit keeps statifier's script contract (see
  `docs/architecture.md`): stdlib-only system Ruby, one JSON envelope on
  stdout, exit 0/1/2, `--dry-run` on every mutating script, all shell-outs
  through `lib/sh.rb`. Scripts never `git push`, open a PR/MR, `bd close`,
  or `bd edit` - the contract test enforces this; do not weaken it.
- Extensions add, they never override. If a consumer needs different generic
  behavior, the manifest schema is missing a field - change the schema (and
  `docs/manifest.md` in the same commit), do not fork a skill.
- Keep `docs/manifest.md` and `lib/manifest.rb` in sync; the code is
  authority, the doc must follow in the same commit.

## Build and test

No toolchain beyond system Ruby. The gate is the kit test suite:

```bash
ruby skills/wurk:kit/scripts/test/run.rb   # once the kit lands (plan phase 2)
```

Run it before any commit that touches scripts. Doc-only changes have no gate;
commit on review of the diff.

## Conventions

- Commit titles < 50 chars, simple present tense ("Adds ...", "Fixes ...");
  body wrapped at ~72 chars. No AI attribution trailers.
- Plain ASCII punctuation in this repo's docs and code comments (hyphens, not
  em dashes).
- Skills are markdown at `skills/wurk:<name>/SKILL.md`; the colon is part of
  the directory name. Cross-references between skills use the installed name
  (`/wurk:commit`), and renames must update every referencing skill, script,
  and script test in the same commit.

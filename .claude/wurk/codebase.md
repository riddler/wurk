# Project orientation: wurk

Wurk is the consumer here: this is the one repo where its own
consumer-specific constants (layout, suite, vocabulary) are correct to
state, because wurk is orienting agents to itself.

## Layout

- `skills/wurk:<name>/SKILL.md` - the generic skills; the colon is part of
  the directory name.
- `skills/wurk:kit/` - shared foundation: `REFERENCE.md` (the script
  contract), `scripts/*.rb`, `scripts/lib/*.rb`, `scripts/test/*.rb`.
- `agents/*.md` - the eight subagents the skills spawn: six read-only
  research agents, plus `wurk-gate-reader` (triages a failing gate; the one
  with a Bash tool) and `wurk-plan-critic`.
- `docs/` - `architecture.md`, `manifest.md`, `gate-contract.md`, `plan.md`
  (active migration plan), `docs/adr/` (settled decisions), `docs/plans/`
  (per-bead implementation plans), `docs/research/` (dated research docs).
- `install.rb` - symlinks this repo into `~/.claude`.

## Suites

One: `skills/wurk:kit/scripts/test/run.rb`, minitest on system Ruby, no
other toolchain. `contract_test.rb` enforces the script contract (envelope
shape, banned operations, `--dry-run`) and is the first place to look when a
script change fails the gate.

## Module families worth mining

- `scripts/*.rb` - one file per script, all sharing the same envelope
  shape; any existing script is a template for a new one.
- `scripts/lib/*.rb` - shared helpers (`manifest.rb`, `sh.rb`, `envelope.rb`,
  `beads.rb`, `forge.rb`, etc.), one concern per file.
- `scripts/test/*_test.rb` - mirror the scripts one-to-one; a new script
  wants a same-named test file alongside it.

## Terms of art

manifest, extension, envelope, gate tier, bead, kit, seam, rung - and the
`wurk:` / `wurk-` split: colon-named directories are skills
(`skills/wurk:research/`), hyphen-named files are agents
(`agents/wurk-codebase-locator.md`).

## Reading rules

- Scripts are stdlib-only system Ruby, one JSON envelope on stdout, exit
  0 (`ok: true`) / 1 (`ok: false` - something is blocked, or a wrapped
  command failed, envelope still printed) / 2 (usage error, plain text on
  stderr, no envelope). Exit 1 is a judgment, not a crash: a gate that ran
  fine and found the tests red exits 1 with a good envelope. Every
  shell-out goes through `lib/sh.rb`.
- Generic skill and agent prose carries no consumer-project constants; those
  come from a consumer's manifest or extension file, never hardcoded here.
- Accepted ADRs under `docs/adr/` are settled decisions - cite the number
  rather than re-arguing them.

# ADR-0004: Project specifics enter through a JSON manifest and markdown extensions

Status: accepted (2026-08-08)

## Context

The 2026-08-08 survey found every project-specific value in the statifier-ex
skill set concentrated in known sites (bead prefix, worktrees dir, tmux
session, gate commands, label vocabulary, artifact paths, carve-out paths),
while domain content (ADR judge, ISA Impact sections, sabotage protocol,
UniFFI patterns) lives as prose inside otherwise generic skills. Fixative
already demonstrates the consumption pattern: its `.claude/diataxis.md` is a
project-local manifest read by generic `~/.claude` documentation skills.
Generalizing requires two different seams, because constants and domain prose
have different shapes and different consumers (scripts vs skills).

## Decision

Two seams, both in the consumer repo:

- **Manifest** `.claude/wurk.json` - all machine-consumed constants, loaded
  by the kit's `lib/manifest.rb`. JSON (not YAML) so system-Ruby stdlib
  parses it; commands as argv arrays; structural choices as explicit enums
  (parallelism model, forge kind, tracker topology, changelog mode). Schema
  documented in `docs/manifest.md`.
- **Extensions** `.claude/wurk/<skill>.md` - domain content a generic skill
  reads at a stated point in its flow and honors as additional steps or
  patterns. Extensions add; they never override. A consumer needing to change
  generic behavior means the manifest schema is missing a field.

## Consequences

- A new project onboards with one JSON file and zero-or-more markdown files;
  no skill copying.
- Scripts become testable against fixture manifests instead of hardcoded
  constants.
- The add-not-override rule keeps generic skills genuinely shared; pressure
  against it surfaces as schema work in this repo, where it is reviewed once
  for everyone.
- Manifest schema changes are breaking changes for all consumers and get
  versioned via the manifest's `wurk` field.

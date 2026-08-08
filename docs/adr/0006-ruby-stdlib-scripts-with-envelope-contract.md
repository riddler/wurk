# ADR-0006: Kit scripts stay Ruby-stdlib with the statifier envelope contract

Status: accepted (2026-08-08)

## Context

Statifier-ex extracted the deterministic mechanics of its skills into Ruby
scripts governed by a written contract: system Ruby, stdlib only, one JSON
envelope on stdout (`ok/script/data/warnings/blocked/commands`), exit codes
0/1/2, `--dry-run` on every mutating script, all shell-outs through a single
argv-array runner (defeating `-i` aliases and injection), a minitest suite
with a fake-shell harness, and a contract test banning irreversible
operations (`git push`, PR/MR creation, `bd close`, `bd edit`) from scripts
entirely. This layer is the most portable asset in the donor repo: it runs
on any Mac's system Ruby with no toolchain install, and its constants are
already concentrated in known sites. Predicator's inline-bash equivalents
are the pre-extraction form of the same logic and demonstrate the cost of
not having the layer.

## Decision

The kit adopts statifier's scripts and their contract wholesale, unchanged
except for constants moving behind `lib/manifest.rb` (ADR-0004). No gems, no
Bundler, no language migration. The contract test ports as-is: the
banned-operations list is project-independent policy - irreversible actions
stay literal skill instructions so a human-meaningful gate fronts each one.
The test suite is this repo's quality gate (ADR-0002).

**1. The banned-operation list is absolute.** A kit script never runs
`git push`, `gh pr create`, `glab mr create`, `bd close`, or `bd edit`, and
never writes a file the consumer's manifest declares as gate configuration
(`gate.moving_files`) or as the gate-change ledger (`gate.guard_ledger`).
Scripts shell out only through `lib/sh.rb` - never `system` or backticks -
and every argv-literal `cp`, `rm`, or `mv` carries a non-interactive flag.

The donor repo anchored this list in its own ADR-0015 and had its contract
test re-read that ADR's text on every run, so the prose and the enforcement
could not drift apart silently. That mechanism moves here: the check now
parses the constraint above, and a backticked operation added to this
paragraph without a matching `Contract` rule fails the suite.

The guarded-write half is the one part that cannot be a fixed list in this
repo. Which files count as gate configuration is per-consumer data
(statifier's `.credo.exs` and `coveralls.json`, fixative's mise files), so
the scan takes its targets as an argument and the suite supplies the union
of every fixture manifest's declarations. This is what `gate.moving_files`
is for; it had no consumer before.

## Consequences

- Zero install burden for consumers; the scripts run wherever Claude Code
  does.
- The tested, envelope-shaped boundary between skill judgment and script
  mechanics survives the move, including its resistance to interactive-alias
  hangs and shell injection.
- Ruby stays the implementation language even for contributors who would
  prefer another; the stdlib-only rule is the tradeoff that keeps install at
  zero.
- Scripts gain a new required input (the manifest); every script test runs
  against fixture manifests rather than real repos.

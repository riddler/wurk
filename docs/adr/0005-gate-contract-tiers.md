# ADR-0005: Skills depend on a tiered gate contract, not on ex_quality

Status: accepted (2026-08-08)

## Context

The donor skills lean on ex_quality (`mix quality`): profiles, a JSON report
with a skip taxonomy, `mix gate.verify` attestation, and the ADR-0011 gate
guard. ex_quality is Elixir-only; fixative's gate is `quality.sh` behind
`mise run quality`. Requiring ex_quality everywhere would block cross-language
adoption; dropping its guarantees everywhere would weaken the Elixir repos.
Examining what the skills actually consume shows three separable capability
levels, and shows that parts of the periphery (the gate guard's
diff-vs-ledger policy) contain no language-specific logic at all.

## Decision

Wurk defines a gate contract with three tiers (full text:
`docs/gate-contract.md`), declared per project in the manifest:

- Tier 0 (required): full and inner-loop commands that exit non-zero on
  failure. Convention: expose them as mise tasks (`mise run quality`,
  `mise run quality:loop`) so every project shares one invocation surface.
- Tier 1 (optional): a command emitting the language-neutral wurk gate
  report JSON (stages, status, run-level vs project-level skips). ex_quality's
  JSON maps onto it via an adapter; a shell gate can emit it directly.
- Tier 2 (optional): attestation (a per-gate-tool command like
  `mix gate.verify`) and the gate guard, which moves into the kit because it
  is pure git-diff-vs-policy logic driven by manifest data.

Skills degrade honestly: judgment that needs an absent capability does not
fire, and every green states which tier produced it. Weaker is acceptable;
vaguer is not.

## Consequences

- Fixative onboards at tier 0 with zero gate work and climbs when it is
  worth it.
- ex_quality becomes one producer of the report format rather than a
  dependency; the adapter lives in the kit (or later upstream in ex_quality).
- The gate guard reaches non-Elixir repos for free once ported to the kit;
  Elixir repos may run both kit guard and `mix gate.check` (they agree by
  construction on the same manifest data).
- Attestation stays per-implementation; repos without it accept the
  documented weaker "fresh full run" bar with `attested: false` on record.

# ADR-0001: Record architecture decisions

Status: accepted (2026-08-08)

## Context

Wurk sits upstream of several consumer repos that all run on "cite the ADR
number instead of re-arguing it" discipline (statifier-ex, predicator-ex,
fixative). The decisions that shaped wurk were made once, during the
2026-08-08 design survey of those repos; without a record, every agent
session that touches wurk will re-litigate them.

## Decision

Architecture decisions are recorded as numbered ADRs in `docs/adr/`, in the
same lightweight format the consumer repos use (Status / Context / Decision /
Consequences). ADRs here start as `accepted`; there is no proposed state.
Small choices that do not constrain future work live in the docs, not in ADRs.

## Consequences

- Agents and humans cite ADR numbers instead of re-deriving rationale.
- The format stays compatible with the consumers' tooling expectations
  (including a possible future ADR judge over this repo, out of scope now).

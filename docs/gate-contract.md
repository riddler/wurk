# The gate contract

Wurk's skills never depend on ex_quality (or any specific gate tool); they
depend on this contract. ex_quality is the Elixir implementation of it;
fixative's `quality.sh` behind mise is a tier-0 implementation today. See
ADR-0005.

## Tier 0: invocation + exit code (required)

The manifest provides `gate.full` and `gate.loop` commands that exit non-zero
on failure. That is the whole requirement. Convention for new projects:
expose them as `mise run quality` and `mise run quality:loop` - mise is
already the toolchain manager in all current consumer repos, so a one-line
mise task wrapping `mix quality` (or anything else) gives every project the
same invocation surface.

At tier 0 the kit's `gate.rb` reports `ok` from the exit code, marks
`report: unavailable` and `attested: false`, and skill judgment that needs
stage-level detail (skip taxonomy, coverage presence) simply does not fire.
Skills phrase their refusal conditions against what the report can prove, and
say so: a tier-0 green is "the gate command passed", never "a full attested
gate is green". Tiers are about what a gate command reports, not where it
runs; where it runs is `gate.cwd`, see `docs/manifest.md`.

Rules that hold at every tier: never truncate gate output; a scoped or quick
green is not a full green; never go green by weakening the check.

## Tier 1: machine-readable report (optional)

The manifest's `gate.report` command emits the wurk gate report on stdout -
a small language-neutral JSON schema (draft; `gate.rb` is authority once
ported):

```jsonc
{
  "ok": true,
  "stages": [
    {"name": "Format",   "status": "pass"},
    {"name": "Dialyzer", "status": "skip", "reason": "disabled in .quality.exs",
     "level": "project"},          // "run" skip = block; "project" skip = warn;
                                    // "not_applicable" skip = warn, not required in reports
    {"name": "Tests",    "status": "fail", "detail": "..."}
  ],
  "attested": false                 // tier 2 sets this true
}
```

Producers:

- ex_quality already emits JSON (`--format json --report -`); a thin adapter
  in `gate.rb` maps it to this shape (or, later, ex_quality grows this as an
  output format upstream).
- A bash/Ruby gate like fixative's assembles the same JSON from its per-stage
  results in a few dozen lines, invoked as a mise task.

What tier 1 buys: the run-level vs project-level vs not-applicable skip
distinction (a stage skipped by this run blocks; a stage the project never
enables warns and is named in reports; a stage the project has declared
permanently inapplicable warns but need not be named), stage names in
reports, and honest "what was actually measured" summaries.

## Tier 2: attestation and the gate guard (optional)

Two independent capabilities:

- **Attestation** (`gate.attest`): a command that runs the gate and exits
  non-zero if the run was profiled, scoped, quick, or skip-flagged -
  ex_quality's `mix gate.verify`. Inherently coupled to the gate tool's flag
  surface, so it stays per-implementation. Where absent, "prove it was a full
  gate" downgrades to "run `gate.full` fresh and report its exit code", and
  the report records `attested: false`.
- **Gate guard**: "a branch that edits a gate-moving file needs a human ledger
  entry". This is pure git-diff-vs-policy logic with no language in it, so it
  belongs in the kit, not in ex_quality: the protected list is
  `gate.moving_files` + the manifest's guard additions, the ledger is
  `gate.guard_ledger`. Porting it into the kit gives every consumer repo the
  guard for free; ex_quality's `mix gate.check` remains as the in-gate
  enforcement for Elixir repos (both can run; they agree by construction on
  the same manifest data).

## Degradation summary

| Capability | present | absent |
|---|---|---|
| gate.report | stage detail, skip taxonomy | exit-code-only judgment |
| gate.attest | attested full green | fresh run, `attested: false` |
| gate.guard_ledger | guard enforced by kit | guard not applicable |

The skills always state which tier a green came from. Weaker is acceptable;
vaguer is not.

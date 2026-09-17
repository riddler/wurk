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
`data.tier: 0` and `attested: false` with an empty `stages` list, and
skill judgment that needs stage-level detail (skip taxonomy, coverage
presence) simply does not fire.
Skills phrase their refusal conditions against what the report can prove, and
say so: a tier-0 green is "the gate command passed", never "a full attested
gate is green". Tiers are about what a gate command reports, not where it
runs; where it runs is `gate.cwd`, see `docs/manifest.md`.

A project whose gate runs on a language version floor names the interpreter
in its gate command rather than relying on PATH. `gate.full`'s argv[0] is
where a project says which interpreter its gate is contractually run under,
and nothing in the kit resolves, versions, or substitutes it - it goes to
execvp as written. A bare interpreter name means "whatever this operator's
PATH found", which is a different measurement per machine.

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

## The portability lane: what shell the gate ran under

Tiers answer "what did the gate report". This section answers a question
none of them do: which shell, and therefore which shell's behavior, the gate
was able to see at all.

Wurk ships `#!/bin/sh` hooks under `hooks/`, and the kit's hook tests run
them through their shebang. On macOS `/bin/sh` is bash 3.2.57, which
predates bash 4.4's `command substitution: ignored null byte in input`
warning entirely, so a regression that only manifests under a modern bash
cannot turn the default gate red on a developer machine - and the default
gate is the only gate this repo has. That is not hypothetical: the hook
`read_input` NUL-byte regression was green on macOS both before and after
its fix, reproduced only on a Linux image whose `/bin/sh` is bash 5.1, and
was found by an outside contributor rather than by the maintainer's gate
(wu-269, wu-kxo, wu-5yo).

`skills/wurk:kit/scripts/portability_lane.rb` is the lane that closes that
gap. It mounts the repo read-only into a Linux container, repoints
`/bin/sh` at the image's bash, and runs one test file there - by default the
hook tests, the suite whose blind spot the lane exists for.

```sh
/usr/bin/ruby skills/wurk:kit/scripts/portability_lane.rb
/usr/bin/ruby skills/wurk:kit/scripts/portability_lane.rb --image IMAGE --test PATH
```

### It is not part of the default gate, on purpose

Two properties of the default gate are load-bearing and the lane must not
move either:

- **Stdlib-only system Ruby, and green on a machine with no container
  runtime and no network.** A missing runtime is a *reported skip*, never a
  red gate. A lane that made a container runtime mandatory would break the
  contract it exists to strengthen.
- **Its measured duration.** Callers treat the default gate as a short
  foreground run and size their waits on that number. A container pull on
  that path would change it.

So the lane is its own entry point, and the default suite carries only an
opt-in test (`PortabilityLaneTest#test_the_lane_itself`) which reports the
lane as skipped and names why - either "no container runtime on PATH" or
"opt-in only". Its runtime probe is a PATH lookup, not a subprocess, so the
report costs nothing. To run the lane through the suite:

```sh
WURK_PORTABILITY_LANE=1 /usr/bin/ruby skills/wurk:kit/scripts/test/run.rb -n /the_lane_itself/
```

Everything else in that file runs against `FakeSh` and starts no container.

### What is a skip and what is a failure

The distinction is the whole safety property: "the lane could not be
exercised" is never reported as "the lane found a regression".

| `data.skip_code` | Means |
|---|---|
| `runtime_missing` | no runtime binary on PATH |
| `runtime_unavailable` | the binary is installed but the daemon does not answer |
| `image_unavailable` | the image is not in the local image store and could not be pulled (no network) |

All three are `data.status: "skipped"`, one warning, `ok: true`, exit 0. An
image already in the local store needs no network, which is what makes the
lane runnable offline once it has run once.

Not ok: the test run inside the container failing (`status: "failed"`),
running out of its budget (`status: "timeout"`), and one case worth naming -
a container whose `/bin/sh` does not report bash 4.4 or newer *blocks* with
`sh_not_modern_bash` even when the run passed. A green run under an ancient
`/bin/sh` reproduces the macOS blind spot exactly, so it must never read as
a pass; the lane verifies the shell it got rather than trusting the image
tag. `data.output` carries the container's combined output whole, never
truncated, because that output is the evidence the lane produces.

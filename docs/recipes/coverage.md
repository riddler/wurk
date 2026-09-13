# Recipe: code coverage as a gate stage

Wurk has no coverage feature, and this recipe does not propose one. A
coverage floor is a stage of the project's gate, the gate is a command
that exits non-zero, and the kit's whole relationship to it is the gate
contract (`docs/gate-contract.md`, ADR-0005). What wurk adds is the
discipline around the number: where the floor lives, who may move it, and
what a green means when it came from a tier that cannot see stages.

## The floor is in `gate.full`

Whatever tool measures coverage has a threshold flag that turns a shortfall
into a non-zero exit. That flag, in the command the manifest names as
`gate.full`, is the entire mechanism:

| Toolchain | Stage | Non-zero on shortfall |
|---|---|---|
| Python | `pytest --cov=src --cov-fail-under=85` (pytest-cov) | `--cov-fail-under` |
| Elixir | `mix coveralls` with `minimum_coverage` in `coveralls.json` | ex_quality's coverage stage |
| Rust | `cargo llvm-cov --fail-under-lines 85` | `--fail-under-lines` |
| JavaScript | `jest --coverage` with `coverageThreshold` in the config | `coverageThreshold` |

Put it in the full gate, not the loop: `gate.loop` is the fast subset a
developer runs between edits, and a coverage number measured over a
scoped run is meaningless (a single test file "covers" its subject
completely). `/wurk:commit` runs `gate.full`; that is where the floor
bites.

Measure the tree, not the diff. Diff coverage tools exist and are useful
in review, but a floor on the whole tree is what stops a project's
coverage from drifting down one small commit at a time, and it is the only
number a tier-0 gate can express.

## The floor is a gate-moving file

The threshold lives in a config file (`pyproject.toml`'s
`[tool.coverage.report] fail_under`, `coveralls.json`, the wrapper script
that passes the flag). That file belongs in `gate.moving_files`, and every
entry there gets an `Edit()` deny rule in `.claude/settings.json`
(`docs/examples/python.md` shows both). The effect is that lowering the
floor is not something a session does on the way to green; it is a
deliberate, visible edit a human makes, which is the "never go green by
weakening the check" rule (`docs/gate-contract.md`) made mechanical.

A project whose gate tool implements the gate guard (tier 2,
`docs/gate-contract.md`) gets one more layer: a branch that edits a gate-moving file
needs a human-written ledger entry at `gate.guard_ledger`, the gate
reports a "Gate guard" stage, and `/wurk:commit` in any mode reports a
missing entry and stops rather than writing one. Today that enforcement
lives in the gate tool (ex_quality's `mix gate.check` for Elixir); the
kit only echoes the stage, and porting the check into the kit is stated
intent, not shipped. A tier-0 Python project has the deny rules and the
diff, which is enough to make the edit visible, and no ledger.

## Raising the floor: the ratchet

A floor that never moves is a floor the project will sit on. The usual
discipline is a ratchet: a plan whose work raises coverage also raises the
threshold to the new number, so the gain is kept. Wurk's place for that
rule is the project's `.claude/wurk/plan.md`, which `/wurk:plan` reads
as additional required success criteria and the plan critic checks
against:

```markdown
# /wurk:plan extension: coverage ratchet

## Required success criterion

Any phase that adds tests states the coverage number before and after
(`make check` prints it), and a phase that raises it by a full point or
more also raises `fail_under` in `pyproject.toml` to the new floor,
rounded down, in the same commit. Coverage may never be lowered by a plan;
a phase that needs to remove tests says why in "What We're NOT Doing".
```

The critic will flag a plan that adds tests without the criterion, and
the implement loop's automated verification runs the gate, so a phase
that promised a raised floor and did not deliver goes red on its own
terms.

## What the kit sees at each tier

**Tier 0** (an exit code, which is where a new project starts): the kit
knows the gate passed or failed, not which stage. A coverage shortfall
looks exactly like a lint failure in the envelope; the output tells the
human which it was, and `wurk-gate-reader` infers the stage from the
output's own structure. The skills report "the gate command passed" and
never "coverage is above the floor", because they cannot know
(`docs/gate-contract.md`, "coverage presence" is named there as judgment
that does not fire at tier 0).

**Tier 1** (`gate.report` emits the report JSON): a coverage stage is a
`stages[]` entry with a name the project chose and a status, and the
skills name it in commit reports and request bodies:

```jsonc
{"name": "Coverage", "status": "pass", "detail": "87.2% (floor 85)"}
```

A stage the project has not enabled yet is a `project_level_skips` entry,
which warns and is named in every report as a standing gap; a stage the
project has decided is permanently inapplicable is a
`not_applicable_skips` entry, which warns quietly (`docs/manifest.md`,
"`gate.project_level_skips` and `gate.not_applicable_skips`"). A coverage
stage that was turned off for one run is neither: it blocks, because a
run-level skip is the gate being weakened.

Only ex_quality emits this report today. A Python producer is a few dozen
lines that run each stage and assemble the JSON (wu-7yd.11); until it
exists, a Python project is at tier 0 and the report above is what it is
missing, not what it has.

## What this recipe deliberately leaves out

A manifest key for the threshold. The number belongs to the tool that
enforces it; a copy in `.claude/wurk.json` would be a second place for it
to be wrong and would put the kit in the business of reading coverage
output, which is the per-language knowledge the hard rule keeps out of
generic scripts. If a second consumer finds a genuine need for the kit to
know the number, that is `docs/manifest.md` work at that time.

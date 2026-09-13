# Worked example: a Python project

The manifest values and settings for a pytest project managed with `uv`,
on GitHub, worked through the same way `docs/manifest.md`'s per-repo table
works through the Elixir and Rust+Swift consumers. Poetry or pip
equivalents are noted where they differ. Nothing here is a default the kit
applies; every value is one this project decided (ADR-0004), and the
reasoning beside each is what to re-check when the project differs.

The closest existing template is wurk's own `.claude/wurk.json`: no warm
step, `changelog.mode: none`, `release: null`, and a plain gate command.
Swap Ruby for Python, put the gate behind a mise task, and it is most of
the way there.

## The manifest

```jsonc
{
  "wurk": 1,

  "beads": {
    "prefix": "acme",
    "sync": "local",                    // pilot; decided for real at graduation
    "areas": {
      "labels": ["area:api", "area:cli", "area:docs"],
      "lands_alone": [],
      "always_batchable": []
    }
  },

  "forge": {"kind": "github"},

  "gate": {
    "full": ["mise", "run", "check"],   // ruff + mypy + pytest with the coverage floor
    "loop": ["uv", "run", "pytest", "-x", "-q"],
    "build_paths": ["src/", "tests/"],
    "moving_files": [
      "mise.toml",                      // holds the check task
      "pyproject.toml",                 // holds [tool.pytest], [tool.coverage], [tool.ruff]
      "uv.lock"
    ],
    "sabotage": {
      "test_roots": ["tests/"],
      "test_pattern": "\\bdef test_",
      "exempt_prefixes": ["tests/fixtures/"]
    }
  },

  "parallelism": {
    "model": "worktree-per-issue",
    "worktrees_dir": "../acme-worktrees",
    "trust": ["mise", "trust", "{path}"],
    "warm": [["uv", "sync"]],
    "repair_when": "uv.lock",
    "repair": [["uv", "sync"]]
  },

  "tmux": {"session": "acme"},

  "artifacts": {
    "plans": "docs/plans",
    "research": "docs/research"
  },

  "changelog": {"mode": "none"},
  "release": null
}
```

A solo developer who does not need two beads open at once drops the
`tmux` section and sets `parallelism` to `{"model": "branch-in-place"}`;
the warm and repair keys then do nothing and can go.

## Why each value

**`gate.full` is a wrapper, not `pytest` alone.** Tier 0 of the gate
contract (`docs/gate-contract.md`) needs one argv that exits non-zero when
anything the project trusts fails. A pytest project usually trusts three
things: the linter, the type checker, and the tests with a coverage
floor. Put them behind one mise task so the kit runs one command
(`docs/gate-contract.md` names mise tasks as the convention for new
projects):

```toml
# mise.toml
[tasks.lint]
run = "uv run ruff check src tests"

[tasks.typecheck]
run = "uv run mypy src"

[tasks.test]
run = "uv run pytest --cov=src --cov-fail-under=85 -q"

[tasks.check]
depends = ["lint", "typecheck", "test"]
```

`mise run check` exits non-zero when any dependency fails, which is the
whole tier-0 requirement. A project that prefers a `Makefile`, `tox`,
`nox`, or a `scripts/check.sh` writes that argv instead; the kit never
learns what is inside. The task names are the project's own; `quality` and
`quality:loop` are what the Elixir consumers call theirs.

**`gate.loop` is the fast subset.** `pytest -x -q` stops at the first
failure and prints little; it is what `/wurk:implement` runs while
iterating inside a phase. The phase boundary runs the full gate through
`/wurk:commit`, so the loop gate is never the last word on a phase, and
the skills say which one produced a green.

**`gate.moving_files` names what changes the gate's verdict.** For a
Python project that is `pyproject.toml` (pytest, coverage, ruff and mypy
all read it), the wrapper itself, and the lockfile. Anything on this list
gets a matching deny rule in `.claude/settings.json` (below), so a branch
that lowers the coverage floor or silences a lint rule is an unmistakable,
deliberate edit in the diff. Add `.coveragerc`, `tox.ini`, `setup.cfg`,
`mypy.ini`, or `ruff.toml` if the project uses them instead of
`pyproject.toml` sections.

**`gate.sabotage.test_pattern` is pytest's declaration shape.** `\bdef
test_` matches a function-style test and a method inside a `Test*` class
alike; the scan runs it against added lines only, so a helper named
`test_helper` is flagged once, when it is added, and a `# sabotage:` note
above it (`# sabotage: n/a - helper, not a test`) satisfies the scan. The
JSON form needs the backslash doubled. `exempt_prefixes` covers generated
or vendored test data that will never carry a hand-written note. The
discipline itself is `docs/recipes/sabotage-testing.md`; the scan is
report-only until the project's `.claude/wurk/commit.md` promotes it.

**`parallelism.warm` is `uv sync`, and `warm_clone` deliberately omits
`.venv`.** A virtualenv is bound to its own path: `pyvenv.cfg` and every
console-script shebang inside it carry the absolute directory it was
created in, so a `.venv` copied into a worktree points back at the main
checkout, and a test that imports the project gets the wrong tree. Let
`uv sync` build a fresh one per worktree; with a warm cache it is seconds.
Poetry: `[["poetry", "install"]]` with `repair_when: "poetry.lock"`. Plain
pip: `[["python", "-m", "venv", ".venv"], [".venv/bin/pip", "install",
"-e", ".[dev]"]]` with `repair_when: "requirements.txt"` (or the pinned
file the project regenerates).

**`parallelism.trust` runs `mise trust` on each new worktree.** mise
refuses to run tasks from a `mise.toml` it has not been told to trust, and
trust is per directory, so a fresh worktree needs it before `warm` or the
gate can run there; `{path}` is substituted with the worktree, and is
available to no other field. A project that gates through something other
than mise omits the key.

**`beads.areas.labels` are a collision prediction, not a topic tag.**
Two beads with disjoint area labels may be worked in parallel; two that
share one are expected to touch the same files. Pick labels by which
files a bead is likely to edit (`skills/wurk:issue/SKILL.md`).

**`changelog.mode: none` and `release: null` are honest, not lazy.** The
three changelog modes are `fragments` (one bead-named fragment file per
change under `changelog.dir`, promoted at release time; not towncrier's
format, though the idea is the same), `keep-a-changelog`, and `none`; a
project that keeps no changelog says `none` rather than promising one.
There is no `pypi` release recipe today (`docs/manifest.md`, "Release
recipes", implements `hex` only), so `release` stays `null`,
`/wurk:release` refuses rather than guessing which file holds the
version, and version bumps and publishing happen outside wurk. A recipe
for `pyproject.toml` versions is schema work in this repo, not a consumer
extension.

## `.claude/settings.json`

```json
{
  "hooks": {
    "SessionStart": [
      {"matcher": "", "hooks": [{"type": "command", "command": "bd prime --hook-json"}]}
    ]
  },
  "permissions": {
    "deny": ["Edit(mise.toml)", "Edit(pyproject.toml)", "Edit(uv.lock)"]
  }
}
```

The deny list is `gate.moving_files`, one `Edit()` per entry; `Edit` alone
covers every file-editing tool, and `Bash` is a documented gap, not an
oversight (`skills/wurk:kit/REFERENCE.md`, "Recommended consumer
settings"). Denying `uv.lock` means a dependency change is made by running
`uv add` or `uv lock`, which is how it should be made anyway.

## `.claude/wurk/codebase.md`

Optional, and worth ten minutes once the pilot is real: the layout
(`src/acme/`, `tests/`), the test conventions (fixtures in `conftest.py`,
markers in use), the terms of art, and where generated code lives. The
research agents read it before they read the tree (ADR-0011). A project
with one package and one test directory can skip it; a project with a
`src/` layout, a plugin namespace, or a compiled extension should not.

## What a Python project does not get today

- **Tier 1 gate reports.** `gate.report` expects a command that emits the
  wurk gate report JSON, and the only existing producer is Elixir's
  ex_quality. Without it, the kit cannot name stages or classify skips,
  and a green is reported as "the gate command passed". A small pytest
  emitter is tracked as wu-7yd.11; `docs/recipes/coverage.md` shows what
  it would report.
- **A release recipe.** As above.
- **Attestation** (`gate.attest`). Nothing in the Python toolchain proves
  a run was unscoped and unprofiled; the kit reports `attested: false`
  and the skills run `gate.full` fresh when they need proof.

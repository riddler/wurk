# ADR-0007: Beads for issue tracking, including wurk's own work

Status: accepted (2026-08-08)

## Context

Wurk had no tracker of its own. Its work lived in `docs/plan.md`, which is a
migration plan and not a queue: it has no ids to cite from a commit trailer,
no ready computation, and no place to put work discovered mid-session.

The choice is unusual here only because of what this repo is. Wurk does not
merely *use* a bead-tracked workflow, it *is* the implementation of one - the
skills, the kit scripts that shell out to `bd`, and the manifest schema that
describes a project's tracker topology. Tracking wurk's own work anywhere else
would mean the repo that defines the workflow is the one repo not running it,
and every skill and script here would be exercised only against consumer repos
that are slower to change than wurk is.

The four properties the consumer repos settled on apply unchanged, and a
replacement tracker would have to supply all four: local and in-process,
structured enough to compute over, durable across sessions and worktrees and
machines, and reversible for routine writes. Statifier's ADR-0007 and
predicator's ADR-0007 argue them at length; the practice arrived here from
there and this ADR does not restate the case.

What is specific to wurk is that adopting `bd` here is also a test. The kit
shells out to `bd` through `lib/beads.rb`, carries a workaround for a live
`bd` bug (beads#5358), and encodes a claim protocol in `wurk:next`. None of
that is exercised by wurk's own suite, which runs against fixtures and a fake
shell. Running the real workflow here is the only thing that meets it.

## Decision

**Wurk's work is tracked in `bd` (beads), prefix `wu`.** Not GitHub Issues,
not TodoWrite, not markdown TODO lists. The `wu-` id is the durable reference
cited in commit `Refs:` trailers and in plan and research filenames.

Bead state syncs over Dolt on the same GitHub remote as the code
(`refs/dolt/data`), and `bd dolt push` stays gated on the git side of the same
change having already reached `origin`.

`.claude/settings.json` carries the SessionStart `bd prime --hook-json` hook.
`AGENTS.md` states the rule as a stub and defers the command reference to
`bd prime`, so this repo holds no second copy of a command surface that
belongs to the tool.

**`docs/plan.md` keeps its job and loses one.** It remains the phased
migration plan - the sequence, the cracks inventory, the definitions of done.
It is no longer where in-flight work or discovered work is recorded; that is
a bead.

**Wurk is a consumer of itself.** `.claude/wurk.json` (ADR-0004) describes
this repo to the same generic skills every other consumer gets, and no skill
or kit script learns anything about wurk specifically. The bootstrap ordering
runs the other way from the rest of the migration: beads is usable here
immediately, while the skills that automate it are not resolvable until
`install.rb` exists.

## Consequences

- **The dogfooding is the point, and it works.** Within minutes of pointing
  the kit at this repo, `gate.rb` emitted statifier's sabotage pathspec
  (`:!test/scion_tests`) in a repo with no `test/` directory - a hard-rule
  violation that phase 1's grep criterion could not catch, because it looked
  for bead ids and paths rather than domain vocabulary. Filed as `wu-gd1`.
  Expect more of these; they are the return on the decision.
- **Wurk now detects `bd` regressions on its own behalf**, rather than
  inheriting a consumer's report of one.
- **This repo is public and its tracker is not.** A visitor sees skills,
  docs, and ADRs, and no issue list. The cost is smaller here than in the
  consumer repos: `docs/plan.md` is public and remains the readable statement
  of intent.
- **Onboarding a second machine needs `bd` installed** and a `bd bootstrap`
  after clone, on top of `install.rb`. That is one more thing between a clone
  and a working setup, on a repo whose whole premise is portability
  (plan item 22).
- **A `bd` behavior change now moves two things at once** - wurk's own
  tracker and the kit that automates `bd` for three other repos. Upgrades
  should be treated as kit changes, re-verifying the workarounds the kit
  carries rather than only checking that `bd` still runs here.
- **Switching trackers later is a migration, not a configuration change.**
  `wu-` ids are cited from commit trailers and document filenames that cannot
  be rewritten. Changing the tracker supersedes this ADR; adding a label
  vocabulary or a topology on top of `bd` does not.

# ADR-0002: Standalone repo, installed into ~/.claude by symlink

Status: accepted (2026-08-08)

## Context

The skills started in statifier-ex's `.claude/`, hand-copied to predicator-ex,
and drifted. Statifier deliberately built machinery to keep its `.claude`
inside its quality gate: the Ruby script suite runs as a `mix quality` stage,
and the ADR judge's ADR-0015 scope reads `.claude/skills/**/SKILL.md`. Moving
the skills out of the project takes them out of that gate scope, so the shared
layer needs a gate of its own. `~/.claude/skills` also already hosts personal
skills (`present:kit`), so cloning a repo directly there would tangle wurk
with unrelated content.

## Decision

Wurk is its own git repository at `~/repos/github/wurk`. An `install.rb`
symlinks each `skills/wurk:*` directory and each agent file into `~/.claude/`;
updating wurk is `git pull`. The kit's minitest suite (including the ported
contract test) is this repo's quality gate, runnable standalone on system
Ruby. Consumer repos narrow their own gate scope to what remains in-repo
(manifest + extensions) and record that scope change in their own ADRs.

## Consequences

- One source of truth; improvements reach every consumer on pull, ending the
  copy-and-drift cycle.
- The scripts keep a tested gate even though no consumer's gate measures them
  anymore.
- Symlinks make the installed state inspectable and reversible; install.rb
  must be idempotent and refuse to replace non-symlink entries.
- Versioning across consumers is by git ref; if consumers ever need to pin
  different versions, that is the trigger to revisit packaging (see
  ADR-0003's plugin note).

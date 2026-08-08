# Instructions for AI agents

Read `CLAUDE.md` first: it is the authority on what this repo is, its hard
rules, and its gate. This file carries only the parts that are not
Claude-Code-specific.

## Beads issue tracker

This project tracks its work in **bd (beads)** - not TodoWrite, not markdown
TODO lists. Bead ids are `wu-<hash>`. Run `bd prime` for the command reference
and the session-close protocol, and `bd remember` for knowledge that should
outlive the session.

Claude Code injects `bd prime` at session start (see `.claude/settings.json`),
so this section is deliberately a stub.

Note for `bd` maintainers: `bd integrate --update` will want to re-expand this
into the full managed block. It is redundant here - keep the stub.

## Agent authority in this repo

Conservative profile: agents create, claim, update, and note beads freely, and
run the gate freely. Committing, pushing, opening a PR, and `bd close` all
need the user to ask in their own words.

The kit's own script contract already bans `git push`, PR/MR creation,
`bd close`, and `bd edit` outright (see `docs/architecture.md`); this rule is
the same boundary stated for the session rather than for the scripts.

## Non-interactive shell commands

`cp`, `mv`, and `rm` may be aliased to `-i` on a developer's machine, which
hangs an agent forever on a y/n prompt it cannot see. Always pass the
non-interactive form: `cp -f`, `mv -f`, `rm -f`, `rm -rf`, `cp -rf`. Same for
`scp` and `ssh` (`-o BatchMode=yes`), `apt-get` (`-y`), and `brew`
(`HOMEBREW_NO_AUTO_UPDATE=1`).

Also avoid `bd edit`, which opens `$EDITOR` and blocks. Use
`bd update <id> --title/--description/--notes/--design` instead.

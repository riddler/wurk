# Machine config (`~/.claude/wurk.local.json`)

See ADR-0013 for why this seam exists and how it is scoped against the
manifest (ADR-0004).

Schema version 1. `lib/user_config.rb`
(`skills/wurk:kit/scripts/lib/user_config.rb`) is the authority; this
document follows it in the same commit, same rule as `docs/manifest.md` and
`lib/manifest.rb`. JSON, not YAML, for the same reason as the manifest
(ADR-0006): system-Ruby stdlib parses it with no surprises.

## What this is, and why it is not a manifest field

`.claude/wurk.json` is checked into a consumer repo and shared by everyone
who works it - it is the right home for anything the *project* decides
(the bead prefix, the gate command, the forge). It is the wrong home for
anything the *machine* or the *person at it* decides, because a value there
forces one setting on every engineer working the repo, and changing it means
editing and committing a tracked file.

Permission mode is the first value of that second kind. One engineer runs
seeded sessions with `--permission-mode auto`; another wants
`--dangerously-skip-permissions` for speed on a throwaway box. Neither
choice belongs to the project, so `~/.claude/wurk.local.json` is where it
lives instead: a per-machine file the kit reads alongside the manifest,
never committed anywhere.

## Path: HOME-anchored only

The file lives at `~/.claude/wurk.local.json` - `File.join(home, ".claude",
"wurk.local.json")`, where `home` is `ENV["HOME"]` (or `Dir.home` as a
fallback). Unlike the project manifest, resolution never walks up from the
working directory and never falls back to a git checkout. That is
deliberate: a manifest legitimately lives at different paths depending on
which repo you're standing in, but a machine has exactly one home directory,
and a stray `.claude/wurk.local.json` committed inside some checkout (by
accident, or by a template) must never be mistaken for machine config the
way a project manifest is found by walking up.

`.local.json` mirrors Claude Code's own `settings.json` /
`settings.local.json` convention: `settings.json` is shared and checked in,
`settings.local.json` is this machine only and never committed. This file is
the second half of that pair for wurk.

## Schema

The minimal useful file is one line:

```jsonc
{
  "tmux": { "permission_mode": "acceptEdits" }
}
```

Every field is optional, including `wurk` itself - an absent schema version
is treated as compatible, since the file may be handwritten and one line is
the point.

```jsonc
{
  "wurk": 1,                          // (opt) schema version

  "tmux": {                           // (opt) omit = today's default behavior
    "permission_mode": "auto"         // (opt) default "auto"; see enum below
  }
}
```

## `tmux.permission_mode`

Selects the permission flag the seeded session's command line carries.
Optional; absent defaults to `"auto"`, today's behavior. Allowed values:

- `"auto"` (default), `"default"`, `"acceptEdits"`, `"plan"` - passed through
  verbatim as `claude --permission-mode <value>`.
- `"skip-permissions"` - swaps the flag entirely for
  `claude --dangerously-skip-permissions`, with no `--permission-mode` flag
  alongside it. For a machine where unattended/loop sessions should run
  without stopping on permission prompts.

## Absent-safe behavior

No file at all is a normal, valid state: every value falls back to its
default (`"auto"` for `tmux.permission_mode`), and `tmux_window.rb open`
composes exactly the command line it always has. A new machine onboards with
zero files - there is nothing to seed and nothing to opt into.

## Validation: block vs warn

`lib/user_config.rb` is the authority on this, matching the manifest's own
asymmetry (`docs/manifest.md`'s Validation section):

- **Unrecognized JSON, or a non-object top level** blocks. A typo in your
  own config should be loud rather than silently defaulted.
- **An enum value outside the known set blocks** (`tmux.permission_mode` is
  the only enum today). It selects a structural flag on a shelled command
  line, and guessing one is worse than stopping - `tmux_window.rb open`
  refuses to run rather than reach the shell with an unvalidated value.
- **A schema version other than the one this kit implements blocks.**
- **An unknown key warns**, never blocks - a machine may be running an
  older or newer kit than the file was written for.

A block from `tmux_window.rb open` costs nothing: the config is validated
before any `tmux new-window` / `tmux new-session` command is issued, and
before the caffeinate probe, so an invalid file never opens a window.

## Checking it

```sh
ruby skills/wurk:kit/scripts/lib/user_config.rb check
```

Read-only, no `--dry-run`. Emits the kit's standard JSON envelope; exits 0
on a valid config (including no file at all) and 1 on an invalid one.
`data.tmux_permission_mode` answers "what mode will my sessions get" without
reading the code.

## Not a consumer concern

This file is never checked into a consumer repo, is never referenced from
`.claude/wurk.json`, and a consumer project has no say in it - the same rule
stated from the opposite direction in CLAUDE.md's no-consumer-constants
requirement for generic kit scripts. There is no precedence to state between
it and the manifest, because the manifest no longer carries this field at
all: `tmux.permission_mode` was retired from the manifest schema in wu-jhb.
See `docs/manifest.md`'s "Retired keys" note.

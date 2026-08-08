---
name: wurk:kit
description: Shared foundation for the wurk:* workflow skills - the Ruby scripts layer that does the deterministic mechanics (beads, worktrees, gate runs, commit messages, plan state), the JSON envelope contract every script speaks, and the .claude/wurk.json manifest that supplies every project-specific value. Invoke directly to lint a repo's manifest or run a single script; the other wurk skills read this skill's REFERENCE.md.
argument-hint: "check-manifest | <script> [args]"
---

This is the shared kit for the `wurk:*` workflow skills. It is a foundation,
not a workflow: it holds no judgment about when to do anything.

## First: read the reference

**Read `~/.claude/skills/wurk:kit/REFERENCE.md` before running or writing any
script.** It holds the envelope contract, the manifest resolution rules, the
banned-operation list, the Ruby-version constraints, and the recommended
consumer `settings.json` blocks.

## What lives here

`scripts/` is stdlib-only system Ruby - no gems, no bundler, no toolchain
beyond `/usr/bin/ruby`. Top-level scripts are the callable surface; `lib/` is
shared machinery; `test/` is the suite that gates this repo.

Every script prints exactly one JSON object on stdout and exits 0 (ran and
judged), 1 (blocked or a wrapped command failed), or 2 (usage error).
Mutating scripts all take `--dry-run`.

## Every project value comes from the manifest

Scripts read the consumer repo's `.claude/wurk.json` through
`lib/manifest.rb`. **Never hardcode a project constant in a script, and never
infer one.** A capability the manifest does not configure is reported, not
guessed: the script blocks and says which field is missing.

If a script needs a value the schema does not have, the schema is what
changes - `lib/manifest.rb` and `docs/manifest.md` in the same commit. Do not
fork a script for one consumer.

Lint a repo's manifest:

```sh
ruby ~/.claude/skills/wurk:kit/scripts/lib/manifest.rb check
```

## The gate for this repo

```sh
ruby skills/wurk:kit/scripts/test/run.rb
```

About half a second. Run it before any commit that touches a script. The
contract test is part of it and enforces the banned-operation list over the
whole tree.

## What a script may never do

Scripts never `git push`, never open a PR or MR, never `bd close`, never
`bd edit`, and never write the files a consumer's manifest declares as gate
configuration. These stay literal instructions in skill prose so a human
gate sits in front of every irreversible action. The full statement is
ADR-0006; REFERENCE.md explains how each half is enforced.

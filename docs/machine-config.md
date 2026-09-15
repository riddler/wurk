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

The machine's own facts are the same kind of value: what it is called, how
many full gates it can run at once, and which workloads (checkouts, fleet
umbrellas) it runs. One harness identity can run on two machines with
different capacities and different workloads, and a fleet manifest - checked
in, shared by every machine that runs the fleet - cannot carry a number that
is right for only one of them. Those facts live here too (`machine`,
`workloads`), so a conductor or a daemon can ask "what does this machine
run, and how much at once" without a shared file having to guess.

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
  },

  "outbound_scan": {                  // (opt) omit = disarmed, pushes allowed
    "patterns_file": "<path to a pattern file this operator maintains outside any repo>",
    "control_term": "<a token the pattern file is expected to match>"
  },

  "machine": {                        // (opt) facts about this box
    "name": "<a name for this machine>",   // (opt) non-blank string; no default
    "gate_slots": 2                   // (opt) positive integer; no default - see below
  },

  "workloads": [                      // (opt) what this machine runs; omit = []
    {
      "root": "<path to a checkout or fleet umbrella>",   // required; "~" expands
      "fleet_manifest": "<path to that workload's fleet manifest>",  // (opt)
      "enabled": true,                // (opt) default true
      "primary": true                 // (opt) default false; at most one entry
    }
  ]
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

## `outbound_scan`

See ADR-0014 for why this section exists and what it gates: a refusal-only
scan of outbound content on the two push paths the kit can reach, configured
here because the pattern set it points at is decided by the operator, not
the project.

- `outbound_scan.patterns_file` (opt) - a path to an operator-maintained
  pattern file that lives outside every repo. A pointer, not an inline list:
  the pattern set itself is never written into this file, into any tracked
  file, or into any envelope this kit emits.
- `outbound_scan.control_term` (opt) - a positive-control token the pattern
  file is expected to match, used to prove the scan pipeline can actually
  hit before a clean result is trusted.

`UserConfig` validates only the **shape** of this section - it never reads
the pattern file itself, since that would mean every script that loads the
config also touches the filesystem for a value most scripts never use.
Whether the file exists, is readable, and is non-empty is checked at scan
time instead (see the outbound-scan tooling this section feeds).

Section absent is the normal, valid, disarmed state. When present, this
section must configure something: an empty `outbound_scan` object, or a
non-string or blank value for either key, blocks. A section with only one of
the two keys is valid at load time - completeness is checked when a scan
actually runs, not here, so an unrelated script never fails on a half-written
scan config.

## Arming the outbound scan, and checking that it is armed

Configuring the section above is only half of it: the section says what to
scan for, and the per-repo hook is what puts the scan in front of a push.
The three steps, in order:

1. **Arm the machine.** Add the `outbound_scan` section to this file, with
   `patterns_file` pointing at a pattern file you maintain outside every
   repo and `control_term` set to a token that file is expected to match.
   Absent means disarmed, and disarmed pushes are allowed with an advisory
   warning - never reported as "scanned clean".
2. **Install the hook, per repo.** From inside the target checkout:

   ```sh
   ruby skills/wurk:kit/scripts/outbound_scan.rb install
   ```

   This is deliberately per-repo rather than part of `install.rb`, so no
   repo gains a push gate you did not ask it to have. It writes a
   marker-delimited block into the effective hooks directory's `pre-push`
   file, above anything already there, and leaves the rest of that file
   byte for byte. Takes `--dry-run` (which reports the exact action it
   would take), and `--uninstall`, which removes only the wurk block.

   If your `core.hooksPath` points somewhere outside the checkout, the
   effective hooks directory is shared by every repo on the machine, and
   the installer refuses rather than gating all of them behind your back.
   Pass `--allow-shared-hooks-path` if that is genuinely what you want.

3. **Check that it is armed.**

   ```sh
   ruby skills/wurk:kit/scripts/outbound_scan.rb status
   ```

   Read-only, no `--dry-run`. `data.armed` says whether this machine
   declares a scan at all; `data.probe_ok` says whether the pipeline was
   proved able to hit, by running the pattern set over a synthesized string
   containing your `control_term`; `data.patterns_count` says how many
   patterns were compiled. A count, never a listing - nothing from the
   pattern file is ever rendered. `armed: true` with `probe_ok: false` is
   the important state to notice: the gate is on but cannot hit, so a
   zero-hit result would mean nothing, and pushes are refused rather than
   trusted.

### What it covers, and what it does not

Covered: the two push paths this kit can reach. Git's own `pre-push` hook
scans everything a push would publish to that remote - the full post-image
content of every added or modified file in every newly published commit
(a rename included, so a move cannot carry content past the gate
invisibly), every one of those commits' messages, and the ref names
themselves. `bead.rb sync scan` scans every string field of the full
tracker export before `bead.rb sync push` shells the tracker's own push;
which fields an outbound-scan hit refuses on is the manifest's
`beads.scan_refusal` (`all` or `titles`).

Not covered: anything that leaves the machine by a route the kit never
touches - a push run from another tool or another checkout that has no hook
installed, a web UI, a paste into a browser, an attachment. A deletion (an
all-zero local sha) is not scanned, because it publishes no content. And
the gate only ever refuses: it never rewrites, redacts, or amends anything
for you.

On a hit, the refusal names locations and counts and nothing else - never
the matched text, never the pattern that matched. That is the whole point
of it, and it means a refusal tells you where to look rather than
reproducing the thing you were trying not to publish.

## `machine`

Facts about the box this file lives on. Both keys are optional and neither
has a default: an absent key means "this machine has not said", and the
readers below treat that as exactly that rather than inventing a value.

- `machine.name` (opt) - a non-blank string naming the machine for a human
  or a journal. Not a hostname, and never defaulted to one: a caller that
  wants the hostname asks the OS. `UserConfig#machine_name` returns it, or
  nil.
- `machine.gate_slots` (opt) - a positive integer: the machine-wide cap on
  concurrent full gates and warms, which is the number of `slot-N`
  directories `lock.rb acquire` and `gate_run.rb start` may take from a
  slot pool. `UserConfig#machine_gate_slots` returns it, or nil. A value of
  zero, a negative, a fraction, or a string blocks: the value becomes a
  count of directories an acquire may create, and anything else is a pool
  that can never grant.

### `machine.gate_slots` wins over the fleet's number

The slot count used to reach `lock.rb` and `gate_run.rb` only as `--slots
N`, relayed by a conductor from a fleet manifest. It still can, and that is
the fallback. But when this file sets `machine.gate_slots`, that value is
used and the flag is not, because the machine config describes the box the
acquire is actually happening on while a fleet manifest is shared by every
machine that runs the fleet and can only be right for one of them. The
rule lives in one place, `Lock.resolve_slot_count`, and both entry points
to the slot pool call it, so they can never disagree about its size. The
full statement, with the `slots_overridden` warning and the `data.slots` /
`data.slots_source` keys that report what was used, is in
`skills/wurk:kit/REFERENCE.md` under `lock.rb`. A fleet that carries a slot
count in its shared manifest should move it here, one file per machine,
and stop relaying it.

## `workloads`

An array of the workloads this machine runs, for a daemon or a conductor to
ask "what does this machine run" without walking the filesystem. Absent
means `[]`. Each entry is an object:

- `root` (required) - a non-blank string, the path to a checkout or a fleet
  umbrella. Expanded with `File.expand_path`, so `~` works and two spellings
  of one directory count as the same root. Two entries with the same root
  block: one workload, one entry.
- `fleet_manifest` (opt) - a non-blank string, the path to that workload's
  fleet manifest, when it is a fleet. Nil when absent.
- `enabled` (opt, default `true`) - `true` or `false`. `false` keeps the
  entry on file without offering it: "this machine knows how to run it,
  but is not running it right now".
- `primary` (opt, default `false`) - `true` or `false`. At most one entry
  may be primary; two block, because "which one?" is a question this file
  must not leave to the reader.

Readers: `UserConfig#workloads` returns every entry normalized with all
four keys present (so a caller never has to know the defaults),
`#enabled_workloads` the subset with `enabled: true`, and
`#primary_workload` the one primary entry or nil. Like `outbound_scan`,
validation here is shape only - whether a root or a fleet manifest exists
on disk is the caller's concern, not a load-time one.

What is deliberately not here: anything a persona harness layers on top
(its tracker of record for a workload, its posting targets, its own
identity). Those belong to that harness's own config file beside this
one; the kit reads none of them, and this schema has no slot for them.

## Absent-safe behavior

No file at all is a normal, valid state: every value falls back to its
default (`"auto"` for `tmux.permission_mode`; `outbound_scan` absent means
disarmed; `machine.name` and `machine.gate_slots` nil, so `--slots N`
decides the slot count as before; `workloads` empty), and `tmux_window.rb
open` composes exactly the command line it always has. A new machine
onboards with zero files - there is nothing to seed and nothing to opt
into.

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
- **`outbound_scan`, when present, must configure something.** A non-object
  section, an empty object, or a non-string or blank `patterns_file` /
  `control_term` blocks. A section with only one of the two keys does not
  block here - see `## outbound_scan` above.
- **`machine`, when present, must be an object**; a non-string or blank
  `name`, or a `gate_slots` that is not a positive integer, blocks.
- **`workloads`, when present, must be an array of objects**, each with a
  non-blank string `root`; a blank `fleet_manifest`, a non-boolean
  `enabled` or `primary`, a duplicated root, or more than one primary
  blocks.
- **An unknown key warns**, never blocks - a machine may be running an
  older or newer kit than the file was written for. Inside a `workloads`
  entry the warning names the entry's index (`workloads[1].nickname`).

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
reading the code. `data.outbound_scan_declared` answers "is an outbound scan
configured at all" the same way - deliberately without a
`data.outbound_scan_patterns_file` field, since a lint envelope has no reason
to carry even a pointer at the pattern set. `data.machine_name`,
`data.machine_gate_slots`, and `data.workloads` (the normalized entries)
answer "what does this machine call itself, how many gates may it run at
once, and what does it run".

## Not a consumer concern

This file is never checked into a consumer repo, is never referenced from
`.claude/wurk.json`, and a consumer project has no say in it - the same rule
stated from the opposite direction in CLAUDE.md's no-consumer-constants
requirement for generic kit scripts. There is no precedence to state between
it and the manifest, because the manifest no longer carries this field at
all: `tmux.permission_mode` was retired from the manifest schema in wu-jhb.
See `docs/manifest.md`'s "Retired keys" note.

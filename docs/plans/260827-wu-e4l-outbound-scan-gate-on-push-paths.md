---
date: 2026-08-27
issue: wu-e4l
status: draft
---

# Outbound-scan gate on both push paths Implementation Plan

## Overview

Implement ADR-0014: a refusal-only outbound-content scan that runs on both
push paths the harness can reach - git's `pre-push` hook and the kit's own
`bead.rb sync push` - so a configured scan cannot be chained past by shell
command ordering. The scan configuration lives wholly in the machine config
(`~/.claude/wurk.local.json`), never in a tracked file. Beads issue: `wu-e4l`.

The incident this closes (wu-e4l): a scan and a push were composed as one
chained shell command, so the push ran before anyone read the scan result.
The fix is structural - the refusal and the failed push are the same event.

## Current State Analysis

**What exists.**

- `skills/wurk:kit/scripts/lib/user_config.rb` - the machine-config reader
  (ADR-0013). One section today, `tmux`, with one enum key. Its validation
  asymmetry is the pattern to copy: unknown key warns
  (`collect_unknown_keys`, `user_config.rb:171`), enum value blocks
  (`validate_enums`, `user_config.rb:159`), non-object top level blocks
  (`initialize`, `user_config.rb:104`). `UserConfig.require!`
  (`user_config.rb:79`) is the one entry point scripts use; it turns errors
  into `env.block!` entries and warnings into `env.warn`.
- `skills/wurk:kit/scripts/bead.rb` `run_sync` (`bead.rb:441-479`) - shells
  `["bd", "dolt", direction]`. Push is best-effort today: a failure is
  `env.warn(code: "dolt_push_failed")`, never a block. It has a
  silent-success retry and a `confirmed` field. Dry-run renders the command
  and emits nulls.
- `skills/wurk:kit/scripts/lib/sh.rb` - the only shell-out primitive.
  `Sh.run(argv, chdir:, timeout:, envelope:)`, argv arrays only, no shell.
  **It closes the child's stdin** (`sh.rb:129`), so no kit script can feed
  data to a subprocess on stdin today.
- `skills/wurk:kit/scripts/lib/envelope.rb` - `ok`/`script`/`data`/
  `warnings`/`blocked`/`commands`; exit 0 when ok, 1 when blocked or failed.
- `skills/wurk:kit/scripts/lib/cli.rb` - `--dry-run`/`--json`/`--help`;
  usage errors exit 2 with no envelope.
- `install.rb` - machine-level symlink setup only. Its refusal rule
  ("an entry that is NOT our symlink is never touched", `install.rb:127-145`)
  is the model for the hook installer's refusal behavior, and its
  action-list-then-apply shape (`install.rb:84`, `install.rb:108`) is what
  makes `--dry-run` exact rather than narrated.
- `skills/wurk:kit/scripts/test/contract_test.rb` - the mechanical contract.
  Constraints that bind this work directly:
  - `test_no_system_or_backticks_everything_goes_through_sh` - no
    `system(...)` and **no backticks anywhere on a code line**. A shell
    template embedded in Ruby must contain no backtick.
  - `test_no_banned_calls_outside_comments` - no `git push` on a code line.
    A pre-push hook template must never spell that phrase outside a comment.
  - `test_no_consumer_vocabulary_in_kit_source` - the kit names no consumer
    project, corpus, or gate file.
  - `test_top_level_scripts_have_shebang_and_executable_bit` - every
    `scripts/*.rb` needs `#!/usr/bin/env ruby` and the executable bit.
  - `test_no_forge_vocabulary_in_kit_source` - no `gh_`/`glab_` identifiers,
    no bare request-state string literals.
  The contract test needs **no change**: the new script refuses pushes, it
  never performs one, so the banned-operation list is untouched (ADR-0014,
  Consequences).
- `skills/wurk:kit/scripts/test/support/user_config_helper.rb` -
  `with_user_config` (injected seam) and `in_tmp_home` (real resolution
  against a scratch `$HOME`). Both are what the new config tests use.
- `skills/wurk:kit/scripts/test/support/fake_sh.rb` - `FakeSh` with argv
  prefix expectations; an unexpected argv raises.
- Test-comment convention: `# sabotage:` notes above a test declaration
  naming the mutation that would turn it red (see `user_config_test.rb:18`).
  `gate.sabotage` is not enabled in this repo's manifest, so it is a
  convention here, not a gate check - follow it anyway.

**What is missing.** Nothing scans outbound content. There is no hooks
tooling, no pattern-set reader, and no code path that can refuse a push.

**Key constraints discovered by probing** (2026-08-27, `bd` 1.2.2):

1. `bd hooks install` **honors `core.hooksPath`**. It resolves the hooks
   directory the same way git does, not by hardcoding `.git/hooks`. On a
   machine with a global `core.hooksPath` it writes into that global
   directory, which is shared by every repo on the machine.
2. `bd hooks install` over an existing foreign `pre-push` **appends a
   marker-delimited section** (`# --- BEGIN BEADS INTEGRATION v<version>
   ---` ... `# --- END BEADS INTEGRATION v<version> ---`) to the end of the
   file and preserves the pre-existing content verbatim above it. It does
   not rename, back up, or refuse. `--chain` is not required for this;
   appending is the default behavior. `--force` overwrites instead.
3. That append is textually preserving but **semantically fragile**: a
   foreign hook that ends in `exit 0` means the appended beads section never
   executes. `bd hooks list` still reports the hook as installed. So "bd's
   section is in the file" is not the same claim as "bd's section runs".
4. `git rev-parse --git-path hooks` returns the effective hooks directory,
   honoring `core.hooksPath`, and returns the shared (common) hooks
   directory from inside a linked worktree. This is the correct resolver
   for the installer.
5. `bd list --all --json` in this repo: 0.25-0.28 s wall, ~188 KB, 82
   issues, measured three times.

### Key Discoveries:

- ADR-0014 is the accepted shape; this plan implements it and does not
  relitigate it. Two places where the ADR's *mechanism* text does not
  survive contact with the probes are resolved below under "ADR-0014:
  mechanism refinements", both consistent with the ADR's stated
  *composition rule* and both requiring a small ADR amendment as follow-up.
- `lib/user_config.rb:33-47` - `ENUMS`/`KNOWN`/`DEFAULTS` are the three
  tables a new section extends. `outbound_scan` adds to `KNOWN` only: it has
  no enum and no default.
- `lib/sh.rb:129` closes child stdin, so anything the scan needs from git
  must come back through argv-only commands. This rules out
  `git diff-tree --stdin` and `git cat-file --batch`, and shapes the
  git-payload assembly into per-commit and per-blob calls.
- `bead.rb:477` - the existing `dolt_<direction>_failed` warning is the
  claim the ADR's Consequences insist must stay distinct from a scan hit.
- `install.rb:136-141` - refuse-by-name rather than overwrite. Same rule,
  same wording style, for the hook installer.
- ADR-0006 / `contract_test.rb` - a component that can only *refuse*
  performs nothing irreversible; the banned-operation list does not change.

## Desired End State

On a machine with `outbound_scan` configured in `~/.claude/wurk.local.json`:

- `git push` from a checkout where the operator ran the installer runs the
  scan over the full content being published; any hit refuses the push, with
  the hit **locations and counts** printed and no matched text, no pattern
  text, and no pattern identity anywhere in the output.
- `bead.rb sync push` runs the scan over the full tracker export before
  shelling `bd dolt push`; a hit is an envelope `blocked` entry and the push
  never runs. A dolt *sync* failure remains a `warning`, unchanged.
- A zero-hit result is only ever reported after a positive-control probe
  proved the pipeline can hit. A failed probe blocks.
- A missing, unreadable, or empty patterns file blocks. A wholly absent
  `outbound_scan` section allows the push and says so in one advisory line.

Verification: the gate (`ruby skills/wurk:kit/scripts/test/run.rb`) is green;
`ruby skills/wurk:kit/scripts/outbound_scan.rb status` reports
`data.armed` truthfully on a machine with and without the section; a
throwaway repo with the shim installed refuses a push of a commit containing
a fixture control token and allows one without it.

## What We're NOT Doing

- **Not covering ungated paths.** `bd dolt push` typed at a shell outside
  the kit, `dolt push` run in the embedded database directory, `git push`
  from a checkout with no hook installed, and content leaving through a
  forge web UI or API all remain operator discipline (ADR-0014 point 5).
  Nobody should read this gate as "outbound content is safe".
- **Not adding the pattern set to any tracked file.** Not to the manifest,
  not to a fixture, not to a doc, not to a comment, not as an example. wu-be9
  records why: the pattern enumerates the vocabulary being guarded, so
  quoting it is the leak. Tests use invented nonsense tokens only.
- **Not passing pattern text through argv or a temp file.** The process
  table is readable by other users on the machine. This rules out `git grep`
  and `rg` as the scanning engine; scanning happens in-process in Ruby.
- **Not changing `docs/manifest.md` or `lib/manifest.rb`.** ADR-0014 point 3
  is explicit: this is machine config, not a manifest field, and no
  manifest-with-machine-override mechanism is introduced.
- **Not changing the contract test's banned-operation list**, and not
  weakening any contract rule to accommodate the new script.
- **Not adding stdin support to `lib/sh.rb`.** It would be the tidier way to
  batch git object reads, but it changes a primitive every script shares for
  a performance concern this plan measures as not binding. Recorded here so
  a future implementer knows it was considered and declined; if push sizes
  ever make per-blob shell-outs hurt, that is the change to make, in its own
  bead.
- **Not gating `bead.rb sync pull`.** Only outbound content matters.
- **Not scanning file *names* separately from content on the git path.** A
  path that contains a guarded term appears in the location string the hook
  reports, and path strings are included in the scanned payload for each
  object (see Phase 3), so a separate pass would be redundant.
- **Not auto-repairing a `bd hooks install` that landed after ours.** The
  installer detects and reports it; re-running the installer is the fix.

## Implementation Approach

**Two files, one definition site.** `lib/outbound_scan.rb` holds the pure
logic (config resolution, pattern-set loading, compiled scanning, redacted
result construction, the control probe). `outbound_scan.rb` is the CLI
wrapper plus the git-payload assembly and the hook installer. `bead.rb`
requires the lib directly, so the tracker path is in-process with no
shell-out and no second implementation. This split is what lets Phase 2 be
committable and gate-verifiable before any caller exists.

**Redaction is a first-class invariant, not a habit.** The result object
carries only `{location, count}` pairs. The scanner never stores matched
text, never stores which pattern matched, and never renders a pattern into a
message. Pattern-file parse errors are reported by **line number only**. One
test in every phase that produces output asserts the serialized envelope does
not contain the fixture's secret token.

**Fail-closed everywhere except fully-absent.** Absent section = disarmed,
allow, one advisory. Every state adjacent to a working configuration -
partial section, missing/unreadable/empty patterns file, uncompilable
pattern line, failed control probe, missing Ruby or missing scan script at
hook-run time - blocks.

### ADR-0014: mechanism refinements

Two points where the probes contradict the ADR's mechanism text. Both keep
the ADR's stated composition rule ("every installed pre-push participant
runs, and any participant's refusal refuses the push") and its stated
scope rule; both need a small ADR amendment, filed as a follow-up bead.

**Refinement 1 - prepend a marker block, do not exec a preserved hook.**
ADR-0014 point 2 says the shim "execs the preserved hook with the same
stdin/arguments after its own scan passes". The probe shows `bd hooks
install` appends its section to the *end* of whatever file is there. Under
the exec design, wurk's shim would exec-and-not-return, so any beads section
appended below it would be dead code - and `bd hooks list` would still
report beads as installed. Under a prepend design, wurk inserts its own
marker-delimited block immediately after the shebang and **falls through**
rather than exiting on success, so the pre-existing content and any later
beads append both still run, in file order, with wurk's refusal first.
This is strictly better composition with the tool the ADR names as the
coexistence case, and it needs no move-aside file. Stdin is preserved by
capturing it to a temp file and re-pointing the script's own stdin at that
file before falling through, so later participants read the same ref lines.

**Refinement 2 - `core.hooksPath` makes "the checkout's hooks directory"
sometimes machine-wide.** ADR-0014 points 2/5/6 assume the hooks directory
is per-checkout ("Git worktrees share the common hooks directory, so one
installed hook covers every worktree of a checkout") and make per-repo scope
come from installation. When `core.hooksPath` is set - which it is on the
machine this bead came from - the effective directory is shared by every
repo, so installing there silently converts a per-repo opt-in into a
machine-wide one. Installing into `.git/hooks` instead would be worse: git
would never run the hook, and a gate that looks armed and is not is the
exact failure mode the ADR's advisory line exists to prevent. Resolution:
the installer resolves the effective directory with `git rev-parse
--git-path hooks`, classifies it as `repo` or `shared`, and **refuses to
install into a `shared` directory unless `--allow-shared-hooks-path` is
given**, reporting the directory and the scope in the envelope either way.
Per-repo remains the default; machine-wide is available, explicit, and
visible.

### Phasing note

The suggested phasing put all docs last. `docs/machine-config.md` is moved
into Phase 1 instead, because CLAUDE.md's hard rule is that the code is
authority and the doc follows **in the same commit** - the same rule
`docs/manifest.md` lives under. Phase 6 carries only the docs that are not
under that rule.

---

## Phase 1: Machine-config schema - the `outbound_scan` section

### Overview

Extend `lib/user_config.rb` with an optional `outbound_scan` section and its
two keys, following the existing validation asymmetry exactly. Update
`docs/machine-config.md` in the same commit. No scanning yet.

### Changes Required:

#### 1. The schema tables

**File**: `skills/wurk:kit/scripts/lib/user_config.rb`
**Changes**: add `outbound_scan` to `KNOWN`; add nothing to `ENUMS` (the
section has no enum) and nothing to `DEFAULTS` (both keys are optional with
no default - absent means disarmed, and a default would invent a policy).

```ruby
  KNOWN = {
    nil => %w[wurk tmux outbound_scan],
    "tmux" => %w[permission_mode],
    "outbound_scan" => %w[patterns_file control_term]
  }.freeze
```

#### 2. Shape validation, and the split with runtime validation

**File**: `skills/wurk:kit/scripts/lib/user_config.rb`
**Changes**: a new `validate_outbound_scan` pass in `validate!`. It checks
**shape only** - `UserConfig` is a parser and must not touch the filesystem,
which is what keeps it cheap enough for every script to require. Whether the
pattern file exists, is readable, and is non-empty is a Phase 2 concern,
checked at scan time.

Rules:

- Section absent: valid, disarmed. No error, no warning.
- Section present but not a JSON object: error (mirrors the top-level rule).
- `patterns_file` or `control_term` present and not a String: error.
- `patterns_file` present and blank after strip: error.
- `control_term` present and blank after strip: error.
- Section present as an object with **neither** key: error - a present
  section that configures nothing is a typo, and the fail-closed rule says
  the states adjacent to a working configuration are the dangerous ones.
- Exactly one of the two keys present: **not** an error here; it is a Phase 2
  scan-time block (`scan_config_incomplete`). Reason: a machine may carry a
  half-written section that only matters when something actually scans, and
  making it a load-time error would block `tmux_window.rb open` and every
  other unrelated script on a config problem that has nothing to do with
  them.

An unknown key under `outbound_scan` warns, via the existing
`collect_unknown_keys` walk - no new code needed, only the `KNOWN` entry.

#### 3. Accessors

**File**: `skills/wurk:kit/scripts/lib/user_config.rb`
**Changes**: two readers plus one predicate, in the style of
`tmux_permission_mode`.

```ruby
  def outbound_scan_patterns_file
    fetch("outbound_scan.patterns_file")
  end

  def outbound_scan_control_term
    fetch("outbound_scan.control_term")
  end

  # Whether the machine declares an outbound scan at all. False means the
  # gate is disarmed and pushes are allowed with an advisory; it never
  # means "scanned clean".
  def outbound_scan_declared?
    raw.key?("outbound_scan")
  end
```

#### 4. The standalone lint

**File**: `skills/wurk:kit/scripts/lib/user_config.rb` (`UserConfigCli`)
**Changes**: add `data[:outbound_scan_declared]` to the emitted envelope.
Deliberately **not** `data[:outbound_scan_patterns_file]`: the path to an
operator's pattern file is not the pattern set, but it is a pointer at it,
and there is no reason for a lint envelope to carry it.

#### 5. Documentation

**File**: `docs/machine-config.md`
**Changes**: a new `## outbound_scan` section after `## tmux.permission_mode`,
plus the `outbound_scan` block in the annotated schema example and a mention
in "Absent-safe behavior". Written against **key names only** - the doc
describes the file the operator points at abstractly and never shows a
pattern, an example pattern, or a real path. Cite ADR-0014.

### Success Criteria:

#### Automated Verification:
- [x] `ruby skills/wurk:kit/scripts/test/run.rb` passes
- [x] New tests in `skills/wurk:kit/scripts/test/user_config_test.rb` cover:
      absent section is valid and `outbound_scan_declared?` is false; a full
      section reads both values back; an unknown key under the section warns
      and does not block; a non-string `patterns_file` blocks; a non-object
      section blocks; an empty-object section blocks; a section with one key
      only is **valid at load time**
- [x] `ruby skills/wurk:kit/scripts/lib/user_config.rb check` exits 0 on a
      machine with no section and reports `data.outbound_scan_declared: false`

#### Manual Verification:
- [ ] The doc's new section is readable on its own terms by someone who has
      never seen ADR-0014
- [ ] Nothing in the diff names or hints at any real guarded term, and
      `docs/machine-config.md` carries no pattern text and no filesystem
      path outside a `<placeholder>` form

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: `lib/outbound_scan.rb` - the scan engine and the control probe

### Overview

The single definition site for scan logic: load the pattern set, compile it,
scan a payload, run the positive-control probe, and return a redacted result.
Pure Ruby over strings and files; no git, no bd, no shelling out. Fully
unit-testable, and green on any machine with no private data present.

### Changes Required:

#### 1. The result and hit value objects

**File**: `skills/wurk:kit/scripts/lib/outbound_scan.rb` (new)
**Changes**:

```ruby
# A single hit, reported as a LOCATION and a COUNT and nothing else.
# There is deliberately no field for the matched text, the matching
# pattern, or the pattern's index: this component exists because echoing
# any of those into an envelope, a message, or a log is itself the leak it
# guards against (wu-be9). Adding such a field is not an enhancement, it
# is a defect.
Hit = Struct.new(:location, :count, keyword_init: true) do
  def to_h
    { "location" => location, "count" => count }
  end
end
```

`Result` carries `armed` (boolean), `probe_ok` (boolean or nil when
disarmed), `hits` (array of `Hit`), `scanned_locations` (integer), and
`errors` (array of `{code, message}` where every message is
pattern-free). `Result#clean?` is `armed && probe_ok && hits.empty? &&
errors.empty?`. `Result#refuse?` is `!hits.empty? || !errors.empty?`.

#### 2. Pattern-set loading

**File**: `skills/wurk:kit/scripts/lib/outbound_scan.rb`
**Changes**: `PatternSet.load(path)` reads the file, drops blank lines and
lines whose first non-space character is `#`, and compiles each remaining
line as `Regexp.new(line, Regexp::IGNORECASE)`.

- Missing or unreadable file: raise `LoadError` carrying code
  `patterns_file_unreadable` and a message naming the **configured key**,
  not the path contents. The path itself may appear in the message (it is
  the operator's own config value and they need it to fix the problem);
  nothing from inside the file ever does.
- Zero usable patterns after filtering: `patterns_file_empty`.
- A line that fails `Regexp.new`: `patterns_file_unparseable`, message
  `"line <n> of the configured patterns file is not a valid regular
  expression"` - **line number only, never the line text or the Ruby
  exception message**, since `RegexpError` quotes the offending source.

The compiled set is held in memory for the process lifetime and never
written anywhere, never rendered, never passed to a subprocess.

#### 3. Scanning

**File**: `skills/wurk:kit/scripts/lib/outbound_scan.rb`
**Changes**: `Scanner#scan_payload(payload)` where `payload` is an
enumerable of `[location_string, text]` pairs. For each pair it counts
matches across the whole compiled set and appends one `Hit` per location
with a nonzero total. Binary-looking content (a NUL byte in the first 8 KB)
is scanned as-is after forcing `Encoding::BINARY` with an ASCII-8BIT
comparison, so a mis-encoded blob cannot raise mid-scan and silently skip.
An invalid-encoding string is scrubbed before matching, never skipped -
skipping is how a gate quietly stops gating.

#### 4. The positive-control probe

**File**: `skills/wurk:kit/scripts/lib/outbound_scan.rb`
**Changes**: `Scanner#probe` builds a synthetic string containing the
configured `control_term` (with generic filler around it) and runs the same
compiled set over it. Zero hits means the pipeline cannot hit, so a zero-hit
payload result proves nothing.

- The probe runs on **every** scan, before the payload is scanned, and its
  outcome is recorded in `Result#probe_ok`.
- A failed probe produces error code `scan_pipeline_broken` and forces
  `refuse?` true regardless of what the payload scan found.
- The probe string is synthesized in memory; it is never written to disk.

#### 5. The entry point the callers use

**File**: `skills/wurk:kit/scripts/lib/outbound_scan.rb`
**Changes**: `OutboundScan.run(payload, config: UserConfig.current)` returns
a `Result`, resolving the four configuration states:

| Config state | Behavior |
|---|---|
| section absent | `armed: false`, no probe, no scan, `refuse?` false, one advisory the caller renders |
| section present, exactly one key | `armed: true`, error `scan_config_incomplete`, refuse |
| section present, both keys, patterns file bad | `armed: true`, error from `PatternSet.load`, refuse |
| section present, both keys, file good | probe, then scan; refuse on probe failure or any hit |

#### 6. Envelope rendering helper

**File**: `skills/wurk:kit/scripts/lib/outbound_scan.rb`
**Changes**: `OutboundScan.apply_to_envelope(result, env, path_label:)` -
the one place a `Result` becomes envelope entries, so the git path, the
tracker path, and the CLI cannot drift in what they disclose.

- disarmed: `env.warn(code: "outbound_scan_disarmed", message: "no outbound
  scan is configured on this machine; this push was not scanned")`
- hits: `env.block!(code: "outbound_scan_hit", message: "<n> outbound scan
  hit(s) in <m> location(s); see data.outbound_scan.hits for locations and
  counts")`
- errors: `env.block!(code: <result error code>, message: <its message>)`
- always: `env.data["outbound_scan"] = result.to_h`

### Success Criteria:

#### Automated Verification:
- [x] `ruby skills/wurk:kit/scripts/test/run.rb` passes
- [x] New `skills/wurk:kit/scripts/test/outbound_scan_test.rb` covers: a
      pattern file with comments and blanks compiles only the real lines;
      missing / unreadable / empty file each produce their own error code; an
      uncompilable line reports its line number; a hit reports location and
      count; multiple hits in one location collapse to one entry with the
      right count; case-insensitive matching; the probe passes when a pattern
      matches the control term and fails when it does not; a failed probe
      refuses even with zero payload hits; an absent section is `armed:
      false` and does not refuse; a one-key section refuses with
      `scan_config_incomplete`
- [x] **The redaction test**: build a fixture pattern file matching an
      invented token, scan a payload containing that token, serialize the
      whole `Result#to_h` and the rendered envelope to JSON, and assert the
      token, the pattern text, and the pattern file's contents appear
      nowhere in either string
- [x] **The unparseable-line redaction test**: a pattern line that is an
      invalid regex and also contains an invented token; assert the token
      does not appear in the error message (this is the case where Ruby's
      own `RegexpError` would leak it)

#### Manual Verification:
- [ ] Read `lib/outbound_scan.rb` end to end asking one question: is there
      any path by which pattern text or matched text reaches a string that
      leaves this object?
- [ ] The suite passes on a machine with no `~/.claude/wurk.local.json`
- [ ] Every fixture in this phase uses invented nonsense tokens written
      inline in the test, and no fixture reads anything outside the repo
      (a property of how the tests are written, so it is read, not run)

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: `outbound_scan.rb` CLI - `status`, `scan`, and `git-refs`

### Overview

The invokable script: report whether the gate is armed, scan an arbitrary
payload, and assemble-and-scan the git payload from pre-push ref lines. No
hook is installed yet; `git-refs` is exercised by hand and by tests against
a scratch repo.

### Changes Required:

#### 1. The script skeleton

**File**: `skills/wurk:kit/scripts/outbound_scan.rb` (new, `#!/usr/bin/env
ruby`, mode 0755)
**Changes**: subcommand dispatch in the shape of `bead.rb:33-46`:

```
usage: outbound_scan.rb <status|scan|git-refs|install> [options]
```

`install` lands in Phase 4; Phase 3 ships `status`, `scan`, `git-refs`, and
a usage error for `install` until then. All three Phase 3 subcommands are
read-only, so none takes `--dry-run`.

#### 2. `status`

**Changes**: loads the config, runs `OutboundScan` with an empty payload (so
the probe still runs), and emits `data.armed`, `data.probe_ok`,
`data.patterns_count`. Exits 0 when armed and probing, 0 when disarmed with
the advisory warning, 1 when armed and broken. This is the "is my gate
actually armed" answer that does not require attempting a push.

`data.patterns_count` is a count, not a listing. It is the one number that
tells an operator their file was read without disclosing anything from it.

#### 3. `scan`

**Changes**: `--file PATH` or `--stdin`. One payload, one location label
(the file path, or `"stdin"`). The generic entry point; also what makes the
whole pipeline testable without git.

#### 4. `git-refs` - the git payload (open question (c), resolved)

**Changes**: reads git's pre-push ref lines from stdin
(`<local ref> <local sha> <remote ref> <remote sha>`), plus the remote name
as `--remote NAME` (git passes it as `$1`).

**The scan reads full blob content of every newly published object, not
pushed-range diffs.** Three independent reasons, any one of which is
sufficient:

1. **Renames and moves.** `git diff` with rename detection renders a moved
   file as a rename with zero content lines. A guarded term inside a file
   that is merely moved into a public path would be published and invisible
   to a diff-based scan. `--no-renames` fixes that particular case, but only
   for files the range touches.
2. **Commit messages are not in any diff.** The wu-e4l incident class
   includes terms in bead descriptions and commit messages. A diff-only scan
   cannot see them at all.
3. **Correctness is what a refusal gate trades cost for.** Full blob content
   is a strict superset of the diff's added lines, so it cannot be worse; and
   the object set is bounded by what is actually being published, not by
   repository size.

Assembly, per ref line, skipping deletions (all-zero local sha):

- Commits: `git rev-list <local_sha> --not --remotes=<remote>`. This is the
  exact "what this push publishes to this remote" set, and it handles the
  new-branch case (all-zero remote sha) without a special branch.
- Blob versions: for each commit, `git diff-tree -r --no-commit-id --root
  --no-renames --diff-filter=AM --raw <commit>`, taking the post-image blob
  sha and path. `--no-renames` so a move contributes its full content;
  `--root` so the initial commit is not silently skipped. Blob shas are
  deduped across commits, so a file touched in twenty commits is read once
  per distinct content.
- Blob content: `git cat-file blob <sha>` per distinct blob. Location label
  `blob:<short-sha>:<path>`. The path is part of the location, so a guarded
  term in a filename is reported by the location itself.
- Commit messages: one `git log --format=%B%x00 --no-walk=unsorted <shas>`
  call for the whole set (arguments, not stdin - `lib/sh.rb` closes child
  stdin). Location `commit-message:<short-sha>`.
- Ref names: the `<local ref>` and `<remote ref>` strings themselves,
  location `ref-name`. Branch names are outbound content.

Cost and honesty: per-blob and per-commit shell-outs are N calls, and
`lib/sh.rb` gives no way to batch them (see "What We're NOT Doing"). Emit
`data.objects_scanned` and `data.commits_scanned`, and `env.warn(code:
"outbound_scan_large_push")` above 2000 distinct blobs. A warning, never a
block and never a skip: a gate that opts out on size is not a gate.

Every git invocation goes through `Sh.run` with an argv array. No pattern
text is ever an argument to any of them.

### Success Criteria:

#### Automated Verification:
- [x] `ruby skills/wurk:kit/scripts/test/run.rb` passes
- [x] New tests in `test/outbound_scan_test.rb` (or a sibling
      `outbound_scan_cli_test.rb`) using `FakeSh`: `git-refs` issues
      `rev-list`, `diff-tree`, `cat-file`, and `log` with the expected argv;
      a deletion ref line is skipped entirely; an all-zero remote sha still
      produces a `--not --remotes=<remote>` rev-list; duplicate blob shas
      across commits produce one `cat-file` call; a hit in blob content
      blocks and exits 1; a hit in a commit message blocks; a hit in a ref
      name blocks; a clean push exits 0
- [x] A test asserts **no `Sh.run` argv in any recorded `FakeSh` call
      contains the fixture pattern token** - the process-table invariant,
      made mechanical
- [x] `status` exits 0 and reports `armed: false` under `with_user_config(nil)`
- [x] `outbound_scan.rb` has the `#!/usr/bin/env ruby` shebang and the
      executable bit (enforced by the existing
      `test_top_level_scripts_have_shebang_and_executable_bit`)
- [x] The existing `contract_test.rb` passes **unchanged**

#### Manual Verification:
- [ ] In a throwaway git repo with a fixture patterns file configured, feed
      a hand-written ref line to `git-refs` on stdin and confirm a term
      introduced only by a `git mv` is reported
- [ ] Confirm a term present only in a commit message is reported
- [ ] Confirm the printed refusal names locations and counts and shows no
      content

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 4: The `pre-push` shim and the `install` subcommand

### Overview

Add `outbound_scan.rb install [--dry-run] [--uninstall]
[--allow-shared-hooks-path]`, which writes a marker-delimited block into the
effective hooks directory's `pre-push` file, preserving everything already
there and refusing rather than overwriting anything it cannot preserve.

### Changes Required:

#### 1. Hooks-directory resolution and scope classification

**File**: `skills/wurk:kit/scripts/outbound_scan.rb`
**Changes**:

- Effective directory: `git rev-parse --path-format=absolute --git-path
  hooks`. This honors `core.hooksPath` and, from a linked worktree, returns
  the shared common hooks directory - which is what makes one install cover
  every worktree of a checkout.
- Common git dir: `git rev-parse --path-format=absolute --git-common-dir`.
- Scope: `"repo"` if the hooks directory is inside the common git dir,
  otherwise `"shared"`.
- `data.hooks_dir` and `data.hooks_dir_scope` are always emitted.
- A `"shared"` scope without `--allow-shared-hooks-path` is a refusal:
  `env.block!(code: "shared_hooks_path", message: "the effective hooks
  directory is outside this checkout (core.hooksPath), so installing here
  would gate every repository on this machine; pass
  --allow-shared-hooks-path to do that deliberately")`.

#### 2. The shim block

**File**: `skills/wurk:kit/scripts/outbound_scan.rb`
**Changes**: a frozen heredoc constant, marker-delimited in the same style
`bd` uses, so both tools' blocks are recognizable and neither is tempted to
touch the other's:

```
# --- BEGIN WURK OUTBOUND SCAN v1 ---
# Managed by outbound_scan.rb install. Do not edit between these markers.
# ... capture stdin, run the scan, restore stdin, fall through ...
# --- END WURK OUTBOUND SCAN v1 ---
```

Body requirements, in POSIX `sh`:

- Capture stdin to a `mktemp` file, since git feeds the ref lines there and
  later participants in the same file need them too.
- Run the scan with the captured file as stdin.
- On nonzero, remove the temp file and `exit 1` - the refusal.
- On zero, `exec < "$tmp"` to re-point the script's own stdin at the
  captured lines, then remove the temp file (the descriptor stays open), and
  **fall through** so the rest of the file still runs. No `exit 0`.
- Resolve the scan script at `${HOME}/.claude/skills/wurk:kit/scripts/
  outbound_scan.rb` - the symlinked install location (ADR-0002), so the hook
  survives the worktree it was installed from being removed.
- If that script or `ruby` is missing, print a message and `exit 1`.
  **Fail closed**: the operator installed this block deliberately, and a
  vanished scanner is exactly the "adjacent to a working configuration"
  state ADR-0014 says must block. The message names the one command that
  fixes it (re-run the installer, or `--uninstall` to remove the block).
- The block contains **no backtick** and does not spell the banned push
  phrase outside a comment, so `contract_test.rb`'s rules hold over the
  Ruby file that carries it.

#### 3. Composition with an existing file

**File**: `skills/wurk:kit/scripts/outbound_scan.rb`
**Changes**: build an action list, then apply - `install.rb:84/108`'s shape,
which is what makes `--dry-run` exact.

- No `pre-push` file: create it with `#!/bin/sh` and the block, mode 0755.
- File exists, already contains our markers: replace the text between them
  in place. Idempotent; a version bump in the marker rewrites cleanly.
- File exists without our markers: insert the block immediately **after** the
  shebang line (or at the very top if there is none), preserving every
  original byte below it. Prepending is what keeps a later `bd hooks
  install` append alive and what puts the refusal first.
- Refuse, do not write, when: the file is not readable or not writable; the
  content is not valid UTF-8 (a binary or compiled hook cannot be
  meaningfully prepended to); the shebang names an interpreter that is not a
  POSIX shell (`sh`, `bash`, `dash`, `zsh`, optionally via `env`) - a Ruby or
  Python `pre-push` cannot host a shell block; or a `BEGIN` marker appears
  with no matching `END`. Each refusal names the file and says what to do,
  in `install.rb:136-141`'s voice.
- `--uninstall` removes only our block and leaves the rest of the file byte
  for byte; if the file becomes nothing but a shebang, it is left in place
  rather than deleted (deleting a file we did not create is the rule this
  repo does not break).
- Detect and report, without repairing, a beads block sitting **above** our
  block, or any `exit` statement above ours: `env.warn(code:
  "hook_participant_above_scan", message: "another pre-push participant runs
  before the wurk scan block; re-run this installer to restore ordering")`.

#### 4. Answer to ADR-0014's `bd hooks install` open question

Probed on `bd` 1.2.2. `bd hooks install` **appends** a marker-delimited
section to an existing `pre-push` and preserves prior content verbatim
above it; it does not rename, back up, or refuse, and `--chain` is not
needed for that. It also honors `core.hooksPath`.

Consequence for the documentation ADR-0014 point 2 asks for: **re-running
the wurk installer after `bd hooks install` is advice, not a hard
requirement** - bd appends below our block, so our block survives and still
runs first. It becomes worth doing only because bd may append below a
pre-existing foreign hook that exits, in which case bd's own section is
dead; the wurk installer's `hook_participant_above_scan` warning is what
surfaces that. Document both facts in Phase 6.

### Success Criteria:

#### Automated Verification:
- [x] `ruby skills/wurk:kit/scripts/test/run.rb` passes
- [x] Tests using a `Dir.mktmpdir` hooks directory and `FakeSh` for the
      `git rev-parse` calls cover: fresh install creates an executable
      `pre-push` containing the markers; re-install is a no-op (`unchanged`);
      install over a foreign hook preserves every original byte and places
      the block after the shebang; install over a file already carrying a
      beads section preserves that section; `--dry-run` writes nothing and
      reports the same actions; `--uninstall` removes only our block;
      refusal on a non-shell shebang; refusal on a `BEGIN` with no `END`;
      refusal on `shared` scope without the flag, and success with it
- [x] A test asserts the generated block contains no backtick and does not
      contain the banned push phrase outside a comment line
- [x] A test executes the generated block with `/bin/sh -n` (syntax check
      only, no side effects) and asserts it parses
- [x] `contract_test.rb` passes unchanged

#### Manual Verification:
- [ ] In a throwaway repo with a local `core.hooksPath`, install, then run
      `bd hooks install`, then confirm both blocks are present and the wurk
      block is above the beads block
- [ ] With a fixture patterns file configured, attempt a real push of a
      commit containing the fixture token to a local bare remote and confirm
      git refuses; remove the token, confirm it succeeds
- [ ] Confirm the refusal output contains no matched text

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 5: The tracker path - `bead.rb sync push`

### Overview

Run the scan in-process inside `run_sync` before `bd dolt push` is shelled,
over the **full** tracker export, and block on a hit while leaving a dolt
sync failure a warning.

### Changes Required:

#### 1. The gate, in front of the existing push

**File**: `skills/wurk:kit/scripts/bead.rb` (`run_sync`, currently
`bead.rb:441-479`)
**Changes**: `require_relative "lib/outbound_scan"`. For `direction ==
"push"` and not `--dry-run`, before the existing `Sh.run(cmd, ...)`:

1. `bd list --all --json` through `Sh.run` (open question (b): measured 0.25-
   0.28 s and ~188 KB for 82 issues in this repo, three runs - cheap enough
   to sit in every push unconditionally). A failure or unparseable output is
   a **block**, code `tracker_export_unavailable`: a scan that could not read
   the tracker cannot clear the push. Note the deliberate asymmetry with
   `dolt_push_failed` - reading is a precondition, pushing is best-effort.
2. `bd search`-style title scanning is explicitly not used (wu-caq): it
   excludes closed issues and reads titles only, which is the known-weak form
   that made every pre-2026-08-26 tracker scan weaker than believed.
3. Build the payload per issue and per field rather than as one blob, so the
   location is actionable: `tracker:<issue id>:<field>` for each string field
   (title, description, design, acceptance criteria, notes, labels, and any
   other string-valued field present), walking the parsed JSON generically so
   a bd schema addition is scanned without a code change. Unknown/nested
   structures are walked recursively; the location carries the JSON path.
4. `OutboundScan.apply_to_envelope(result, env, path_label: "tracker")`.
5. If `result.refuse?`, emit and return **without shelling `bd dolt push`**.
   `data["pushed"] = false`.
6. Size advisory: `env.warn(code: "outbound_scan_large_tracker")` above 5 MB
   of export, so a fleet whose tracker has outgrown the measurement gets a
   line rather than a surprise. Never a skip.

#### 2. Keeping the two claims distinct

**File**: `skills/wurk:kit/scripts/bead.rb`
**Changes**: nothing about the existing failure handling changes. After this
phase the envelope distinguishes three states explicitly:

- `blocked[].code == "outbound_scan_hit"` - the push did not run, by refusal.
- `warnings[].code == "dolt_push_failed"` - the push ran and failed.
- `warnings[].code == "dolt_push_unconfirmed"` - the push ran, exit 0, no
  output, twice.

`data["scan"]` carries `armed`/`probe_ok`/`hits`; `data["succeeded"]` keeps
its existing meaning and is `nil` when the scan refused.

#### 3. Dry run

**File**: `skills/wurk:kit/scripts/bead.rb`
**Changes**: per ADR-0014, the dry-run form **reports that the scan would
run** rather than running it - dry-run does not shell out, and
`bd list --all --json` is a shell-out. Add `data["scan_would_run"] =
config.outbound_scan_declared?` and render the `bd list --all --json`
command into `commands` alongside the existing `bd dolt push`.

#### 4. Pull is untouched

`bead.rb sync pull` gains nothing. Only outbound content is gated.

### Success Criteria:

#### Automated Verification:
- [x] `ruby skills/wurk:kit/scripts/test/run.rb` passes
- [x] New tests in `test/bead_test.rb` alongside the existing sync tests:
      with no `outbound_scan` section, `sync push` behaves exactly as today
      plus one `outbound_scan_disarmed` warning, and every existing sync test
      still passes; with a fixture section and a clean export, `bd dolt push`
      runs; with a fixture section and an export containing the fixture
      token, **`FakeSh` records no `bd dolt push` call at all** and the
      envelope has an `outbound_scan_hit` block; a failing `bd list --all
      --json` blocks with `tracker_export_unavailable` and does not push; a
      dolt push failure is still a warning, not a block, in the armed case
- [x] A redaction test: the serialized `sync push` envelope from a hit run
      contains neither the fixture token nor the fixture pattern text
- [x] `--dry-run` emits `scan_would_run` and shells nothing (asserted by an
      empty `FakeSh#calls`)
- [x] `contract_test.rb` passes unchanged

#### Manual Verification:
- [ ] Run `bead.rb sync push --dry-run` in this repo and read the envelope
- [ ] On the operator's machine, with the real configuration in place, run
      `outbound_scan.rb status` and confirm `probe_ok` is true

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 6: Documentation

### Overview

The docs not covered by the code-is-authority same-commit rule (that was
`docs/machine-config.md`, in Phase 1).

### Changes Required:

#### 1. Architecture

**File**: `docs/architecture.md`
**Changes**: Layer 2's bullet list currently states the banned-operations
rule. Add a short paragraph after it: the kit now also ships a refusal-only
gate, why a component that can only refuse is consistent with ADR-0006
rather than an exception to it, and the two paths it covers. Under
`## Install`, note that hook installation is deliberately **not** part of
`install.rb` - it is a per-repo opt-in run from the target checkout - and
that the effective hooks directory is whatever `core.hooksPath` says it is,
which the installer classifies and refuses to widen silently.

There is no script inventory table in `docs/architecture.md` today (the
layer sections describe families, not files), so no inventory row is needed.
`.claude/wurk/codebase.md` describes `scripts/*.rb` as a family and needs no
change either.

#### 2. Kit reference

**File**: `skills/wurk:kit/REFERENCE.md`
**Changes**: there is no per-script inventory in this file - only `gate.rb`
and `judge.rb` have dedicated sections, and the rest of the scripts are
described by contract rather than enumerated. So two targeted edits, not a
new inventory row:

- `## The machine config is the contract's second input` - add
  `outbound_scan` as the second section of the machine-config schema,
  by key name only, pointing at `docs/machine-config.md`.
- `## Step-scoping and the banned-operation list` - add a paragraph after
  the list: a script that can only *refuse* an operation performs nothing
  irreversible and is itself the human-meaningful gate the list exists to
  protect, so `outbound_scan.rb` and the scan inside `bead.rb sync push`
  are consistent with the list rather than exceptions to it, and the list
  itself does not change (ADR-0014).

Any shell fence added must contain no consumer vocabulary
(`test_no_consumer_vocabulary_in_kit_reference_command_blocks`).

#### 3. `docs/manifest.md`

**Unchanged, deliberately.** ADR-0014 point 3 and its Consequences both say
so. A reviewer seeing no manifest change is seeing the decision, not an
omission.

#### 4. Follow-up bead

File a bead to amend ADR-0014 with the two mechanism refinements this plan
resolved (prepend-with-fallthrough instead of exec-chaining; the
`core.hooksPath` scope guard) and with the `bd hooks install` answer, so the
ADR's text matches the shipped mechanism. The ADR's *decision* stands
unchanged; only its mechanism prose and its Open questions section need
updating.

### Success Criteria:

#### Automated Verification:
- [ ] `ruby skills/wurk:kit/scripts/test/run.rb` passes (the markdown scans
      in `contract_test.rb` cover `REFERENCE.md` shell fences)
- [ ] Plain ASCII punctuation throughout the changed docs, checked by a
      command that must produce no output over them:
      `LC_ALL=C grep -n '[^ -~\t]' <changed docs>`

#### Manual Verification:
- [ ] A reader who has not seen ADR-0014 can install the hook, verify it is
      armed, and understand what it does and does not cover, from the docs
      alone
- [ ] The follow-up bead exists and is linked to wu-e4l
- [ ] No pattern text, no real path, and no guarded term appears in any
      changed doc - read the whole diff, not a search for known strings,
      since the terms this guards against are exactly the ones that must
      not be written down to search for

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/user_config_test.rb` - the `outbound_scan` section's shape
  validation, the accessors, the warn/block asymmetry, and the deliberate
  choice that a one-key section is valid at load time.
- `test/outbound_scan_test.rb` - the engine: pattern loading and its four
  failure codes, matching and counting, the control probe in both outcomes,
  the four configuration states, and the redaction invariant.
- `test/outbound_scan_cli_test.rb` - the CLI: `status`, `scan`, `git-refs`
  argv shapes under `FakeSh`, the deletion and new-branch ref-line cases,
  blob dedupe, and the install/uninstall action list over a `Dir.mktmpdir`
  hooks directory.
- `test/bead_test.rb` - the sync-push gate, and every existing sync test
  still passing with the gate disarmed.

**Fixture discipline, applying to every one of these.** Every pattern, every
token, and every "secret" in every test is an invented nonsense string
written inline in the test file. No test reads a file outside the repo, no
test depends on `~/.claude/wurk.local.json` existing, and the whole suite
passes on a machine with no private data present. This is not only a
firewall requirement (wu-be9) but a correctness one: a suite that needs the
operator's data is a suite nobody else can run.

**Key edge cases:**

- A pattern file that is all comments (empty after filtering) - blocks.
- A control term the pattern set does not match - blocks even with a clean
  payload. This is the whole point of the probe.
- A push that deletes a branch - no scan, no refusal.
- A push of a brand-new branch with no remote-tracking overlap.
- A file introduced only by a rename - must hit.
- A term only in a commit message - must hit.
- A term only in a branch name - must hit.
- A blob with invalid UTF-8 - scanned, never skipped.
- A `pre-push` that is a Ruby script - installer refuses, writes nothing.
- A tracker export that fails to fetch - blocks the push.

### Manual Testing Steps:

1. In a throwaway git repo under a scratch directory (never this repo), set
   a local `core.hooksPath`, write a fixture patterns file outside any repo,
   and point a scratch `$HOME`'s `wurk.local.json` at it.
2. `outbound_scan.rb install --dry-run`, read the actions, then install.
3. `git mv` a file containing the fixture token into a new path, commit,
   and push to a local bare remote. Confirm git refuses and that the output
   names a `blob:` location with a count and shows no content.
4. Remove the token, amend, push again. Confirm it succeeds.
5. Put the token only in a commit message. Confirm refusal.
6. Break the patterns file (delete it). Confirm the push is refused with
   `patterns_file_unreadable`, not allowed.
7. Change the control term to something the pattern set does not match.
   Confirm the push is refused with `scan_pipeline_broken` even though the
   content is clean.
8. Run `bd hooks install` in the throwaway repo. Confirm both blocks are
   present, wurk's above beads', and that a push still refuses on a hit.
9. Unset the `outbound_scan` section entirely. Confirm the push is allowed
   and the advisory line is printed.
10. `outbound_scan.rb install --uninstall`; confirm the foreign and beads
    content survives byte for byte.

## References

- Bead: `wu-e4l`. Context: `wu-caq` (tracker scans must read the full
  database), `wu-be9` (never transcribe the pattern into a committed
  artifact).
- ADR: `docs/adr/0014-outbound-scan-gate-on-push-paths.md` (the accepted
  shape this plan implements)
- Related ADRs: `docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md`
  (the script contract and the banned-operation list),
  `docs/adr/0013-machine-level-config-seam.md` (the config seam this
  extends), `docs/adr/0004-manifest-and-extension-seams.md`,
  `docs/adr/0002-standalone-repo-installed-by-symlink.md` (why the hook
  resolves the scan script under `~/.claude`)
- Machine config: `docs/machine-config.md`,
  `skills/wurk:kit/scripts/lib/user_config.rb`
- The tracker push path: `skills/wurk:kit/scripts/bead.rb:441-479`
- The refusal-not-overwrite pattern: `install.rb:127-145`
- The contract this must satisfy unchanged:
  `skills/wurk:kit/scripts/test/contract_test.rb`
- Probes run while planning (2026-08-27), in a throwaway git repo under the
  session scratchpad, prefixed `wu-e4l-`: `bd hooks install` behavior over a
  foreign `pre-push` (`bd` 1.2.2), `git rev-parse --git-path hooks` under
  `core.hooksPath`, and three timed runs of `bd list --all --json` in this
  worktree. One probe wrote beads hooks into the operator's global hooks
  directory as a side effect (because `bd hooks install` honors
  `core.hooksPath`); the five created files were removed and the directory
  restored to its prior contents. No hooks were installed into this repo.

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The doc's new section is readable on its own terms by someone who has
      never seen ADR-0014
- [ ] Nothing in the diff names or hints at any real guarded term, and
      `docs/machine-config.md` carries no pattern text and no filesystem
      path outside a `<placeholder>` form

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 2

- [ ] Read `lib/outbound_scan.rb` end to end asking one question: is there
      any path by which pattern text or matched text reaches a string that
      leaves this object?
- [ ] The suite passes on a machine with no `~/.claude/wurk.local.json`
- [ ] Every fixture in this phase uses invented nonsense tokens written
      inline in the test, and no fixture reads anything outside the repo
      (a property of how the tests are written, so it is read, not run)

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 3

- [ ] In a throwaway git repo with a fixture patterns file configured, feed
      a hand-written ref line to `git-refs` on stdin and confirm a term
      introduced only by a `git mv` is reported
- [ ] Confirm a term present only in a commit message is reported
- [ ] Confirm the printed refusal names locations and counts and shows no
      content

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 4

- [ ] In a throwaway repo with a local `core.hooksPath`, install, then run
      `bd hooks install`, then confirm both blocks are present and the wurk
      block is above the beads block
- [ ] With a fixture patterns file configured, attempt a real push of a
      commit containing the fixture token to a local bare remote and confirm
      git refuses; remove the token, confirm it succeeds
- [ ] Confirm the refusal output contains no matched text

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 5

- [ ] Run `bead.rb sync push --dry-run` in this repo and read the envelope
- [ ] On the operator's machine, with the real configuration in place, run
      `outbound_scan.rb status` and confirm `probe_ok` is true

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

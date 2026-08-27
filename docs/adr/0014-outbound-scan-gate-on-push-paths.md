# ADR-0014: An outbound-scan gate on both push paths, configured at the machine seam

Status: accepted (2026-08-27)

## Context

Incident (wu-e4l, 2026-08-27): an operator composed an outbound terminology
scan and `bd dolt push` as one chained shell command. The push ran before
anyone read the scan result, and content the scan would have flagged reached
a public remote. The standing rule "scan and push are separate commands" is
discipline, and discipline is exactly what a chained command bypasses. The
wanted fix is harness-shaped: a gate that runs the configured scan itself
and refuses the push on any hit, so it cannot be chained past by
construction.

Two distinct push paths exist:

- **The git path** (`git push`). Kit scripts never run it (ADR-0006), so
  the only interception point is git's own `pre-push` hook. `bd hooks
  install` also installs git hooks, including a chaining `pre-push`, so any
  hook wurk installs must coexist with bd's. Git worktrees share the common
  hooks directory, so one installed hook covers every worktree of a
  checkout.
- **The tracker path** (`bd dolt push`). `bd` has no hook on `bd dolt
  push` - `bd hooks` installs git hooks only - so there is no native
  interception point. But the kit already owns a `bd dolt push` code path:
  `bead.rb sync push` (`skills/wurk:kit/scripts/bead.rb`) shells it today,
  lawfully, because `bd dolt push` is not on ADR-0006's banned list. That
  makes `sync push` an in-process interception point for every tracker push
  that goes through the kit.

The configuration problem is the load-bearing part. The scan's pattern set
for a fleet like the one in the incident enumerates the private vocabulary
being guarded, so writing that pattern into a tracked file in a public repo
is itself the leak the gate exists to prevent (the same failure wu-be9
records for plan documents). That rules out the manifest carrying the
patterns, and it forces an honest answer under ADR-0013's placement rule.

Related: wu-caq (tracker scans must read the full database, not `bd search`
over open-issue titles) informs what the tracker-path scan should read.

## Decision

**1. The gate lives in both paths, sharing one scan implementation.**

- A kit script (working name `outbound_scan.rb`; the plan stage fixes the
  name) owns the scan logic: load the configured pattern set, scan the
  outbound payload, emit the standard envelope, exit non-zero on any hit.
  It is the single definition site.
- The git path gets a `pre-push` hook: a thin shim that invokes the kit
  scan script over the content being pushed (the ref ranges git hands the
  hook on stdin) and propagates a non-zero exit, which makes git refuse the
  push. The shim scans and refuses; it never pushes.
- The tracker path gets an in-process check inside `bead.rb sync push`:
  before shelling `bd dolt push`, run the scan over the tracker's full
  content (`bd list --all --json`, per wu-caq - titles-of-open-issues
  scanning is the known-weak form), and refuse the push with a `blocked`
  envelope entry on any hit. The dry-run form reports that the scan would
  run.

This is consistent with ADR-0006, not a violation of it. The contract bans
kit scripts from *performing* irreversible operations so that a
human-meaningful gate fronts each one; a component that can only *refuse*
performs nothing irreversible and is itself such a gate - it strengthens the
seam the contract exists to protect. For the tracker path the question does
not even arise as a change: `bd dolt push` is not on the banned list, `sync
push` already runs it, and this decision adds a refusal condition in front
of an operation the script was already permitted. The banned-operation list
itself does not change under this ADR.

**2. Coexistence with `bd hooks install`: chain, never clobber.**

The hook installer (point 6) must treat the `pre-push` file as shared
territory:

- If no `pre-push` exists, install the wurk shim.
- If a `pre-push` exists that is not the wurk shim (bd's, or anything
  else), preserve it: the wurk shim execs the preserved hook with the same
  stdin/arguments after its own scan passes, so both run and either can
  refuse. If the existing hook cannot be preserved this way, the installer
  refuses with instructions rather than overwriting - the same
  never-touch-what-is-not-ours rule `install.rb` applies to symlinks.
- If `bd hooks install` runs after wurk's shim is installed, bd's own
  chaining behavior is expected to preserve the shim; the installer's
  documentation tells the operator to re-run the wurk installer afterwards
  and verify, because bd's exact preservation mechanics are outside this
  repo's control (see Open questions).

The composition rule either way: every installed pre-push participant runs,
and any participant's refusal refuses the push.

**3. Config seam: the machine config, entirely; not a manifest field.**

Where does the value fall under ADR-0013's rule (manifest = what the project
decides; machine config = what the machine or the person at it decides)?
Honestly: the pattern set is decided by the operator, not the project. A
public repo, as a project, has no private vocabulary - the guard exists
because of the private context of the person pushing from this machine. The
closest thing to a project-side claim ("pushes from this repo must be
scanned") cannot be stated in the manifest without either leaking (naming
what is guarded) or being vacuous (requiring a scan the project cannot
define). And the hard constraint stands on its own: the pattern set must
never appear in, or be derivable from, a tracked file in a public repo.

So the scan configuration lives wholly in `~/.claude/wurk.local.json`
(ADR-0013's seam, read by `lib/user_config.rb`), as a new optional section
- working key `outbound_scan`. This is an addition to the machine-config
schema, which is exactly the pressure valve ADR-0013 created; it is
deliberately *not* a manifest field with a machine-level override, so the
override mechanism ADR-0013 declined to authorize in advance stays
unneeded and unauthorized. Per-repo applicability comes from installation
(point 6), not from configuration: the scan config is machine-wide, and it
gates a given repo's pushes only where the hook is installed (git path) or
wherever the kit's `sync push` runs (tracker path).

**4. What the configuration contains.**

- `outbound_scan.patterns_file`: a path to an operator-maintained pattern
  file that lives outside every repo (e.g.
  `"<path to the operator's pattern file>"`). A pointer, not an inline
  list: it keeps one definition site the operator's other scan tooling can
  share, and it keeps the patterns out of the config file, envelopes, and
  logs. The scan script must never echo the patterns into its envelope or
  its refusal message - it reports hit locations and counts, not the
  matching pattern text.
- `outbound_scan.control_term`: a positive-control token (an obviously
  fictional, non-private string) that the pattern set is required to match.
  Before trusting a zero-hit result, the gate runs the pipeline over a
  synthetic probe containing the control term; if the probe does not
  produce a hit, the gate refuses the push and reports the scan pipeline
  broken. This is the fleet's existing scan discipline (wu-caq) made
  mechanical: a zero-hit result is only meaningful from a pipeline proven
  able to hit.
- **Absent configuration allows the push.** Most projects have no private
  vocabulary; making every push on every machine fail until a scan is
  configured would be wrong for them, and "absent is a normal, valid state"
  is the machine config's established contract (ADR-0013). The gate says so
  when it can: the pre-push shim prints one advisory line that no outbound
  scan is configured, so a disarmed gate is at least visibly disarmed
  rather than indistinguishable from a passing one. The failure mode is
  stated plainly: a deleted or renamed `wurk.local.json` (or a typo'd
  section key) disarms the gate, and only that advisory line separates
  "scanned clean" from "never scanned". That residual risk is accepted.
- **Present-but-broken configuration refuses the push.** A `patterns_file`
  that is missing, unreadable, or empty, or a control probe that fails,
  blocks - fails closed. The dangerous states are the ones adjacent to a
  working configuration, and those all refuse; only the fully-absent state
  allows.

**5. What is and is not covered.**

Covered:

- `git push` from any worktree of a checkout where the hook is installed
  (the shared hooks directory covers all worktrees).
- `bd dolt push` issued through `bead.rb sync push` - which includes the
  conductor and every wurk skill that syncs the tracker through the kit.

Not covered - these remain operator discipline:

- `bd dolt push` typed directly at a shell, outside the kit. There is no
  native hook point; the standing separate-commands rule still applies
  there, and the honest posture is to route tracker pushes through
  `bead.rb sync push` precisely because that path is gated.
- A `dolt push` run with the dolt CLI directly inside the embedded
  database directory.
- `git push` from a checkout where the operator never installed the hook.
- Content that leaves through a forge's web UI or API rather than a push.

Nobody should read this gate as "outbound content is safe"; it is one
mechanical layer under the operator's scan discipline, covering the two
paths the harness can reach.

**6. Installation is per-repo, explicit, by the operator.**

A kit script subcommand (working form: the scan script's `install` mode,
run from the target checkout) installs the pre-push shim into that
checkout's shared hooks directory. Idempotent, `--dry-run` like every
mutating kit script, chaining per point 2, refusing per point 2. It is
deliberately not part of `install.rb`: that script is machine-level symlink
setup, and hook installation is a per-repo opt-in the operator makes for
the repos whose pushes need gating. The tracker-path check requires no
installation at all - it ships inside `bead.rb sync push` and arms itself
whenever the machine config declares a scan.

## Consequences

- The incident's failure shape is closed by construction on both gated
  paths: there is no ordering of shell commands that lands a push before
  the scan result is acted on, because the gate runs the scan in-process
  and the refusal is the same event as the failed push.
- `lib/user_config.rb` and `docs/machine-config.md` gain the
  `outbound_scan` section (second member of the machine seam, after
  `tmux.permission_mode`), following the existing validation asymmetry;
  `docs/manifest.md` changes not at all.
- `bead.rb sync push` becomes gating in one narrow way on a machine that
  configures a scan, while staying best-effort for sync failures: a dolt
  *sync* failure is still a warning, but a scan *hit* is a block. Those are
  different claims and the envelope keeps them distinct.
- The contract test's banned-operation list is unchanged; the scan script
  must itself pass that test (it refuses pushes, it never performs one).
- A pre-existing hit already present in tracker history blocks all future
  tracker pushes until scrubbed. That is the correct behavior - the leak
  exists and the gate says so - but it means arming the gate on a fleet
  with an unscrubbed remote is loud by design.
- The uncovered paths in point 5 are now written down, which is itself a
  guard against over-trusting the gate.

## Open questions

Recorded for the plan stage; none block accepting the shape:

- The exact preservation mechanics of `bd hooks install` when a foreign
  `pre-push` already exists (does it chain by exec, rename, or refuse?).
  The installer must probe rather than assume, and the answer determines
  whether "re-run the wurk installer after bd hooks install" is advice or
  a hard requirement.
- Whether the tracker-path scan of the full database (`bd list --all
  --json`) is fast enough to sit inside every `sync push`, or needs a
  size-triggered warning. Expected cheap; measure, do not guess.
- Whether the git-path scan reads the pushed ref ranges' diffs only or
  full blob content of new commits; the plan stage picks the form that
  cannot miss a term introduced in a moved or renamed file.

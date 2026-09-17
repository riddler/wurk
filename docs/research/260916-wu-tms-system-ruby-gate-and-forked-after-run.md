---
date: 2026-09-16T19:28:09-0600
researcher: Claude
git_commit: d3a2a204840289d8667ae3601ff59950c6b6a9fa
branch: wu-tms-system-ruby-gate
repository: wurk
beads_issue: wu-tms
topic: "What removes HomeGuard.dir during a full kit-suite run under macOS system Ruby 2.6.10, and what the gate's interpreter surface is"
tags: [research, codebase, kit, gate, tests]
status: complete
last_updated: 2026-09-16
last_updated_by: Claude
---

# Research: the kit suite under macOS system Ruby, and the gate's interpreter surface

**Date**: 2026-09-16T19:28:09-0600
**Git Commit**: d3a2a204840289d8667ae3601ff59950c6b6a9fa
**Branch**: wu-tms-system-ruby-gate
**Bead**: wu-tms

## Research Question

Three questions, from wu-tms:

1. What removes `HomeGuard.dir` during a full run of
   `skills/wurk:kit/scripts/test/run.rb` under `/usr/bin/ruby` 2.6.10, when
   the same tree is green under the Homebrew ruby that is first on PATH?
2. Where does the repo decide which ruby binary runs the gate, and what do
   the docs say the contractual interpreter is?
3. What is the blast radius of making the gate name its interpreter instead
   of trusting PATH?

## Summary

**The remover is a forked child process running the parent's
`Minitest.after_run` hook.** Four test files fork a throwaway child to get a
reaped, definitely-dead pid for a staleness probe
(`fork { exit(0) }; Process.wait(pid)`). The child inherits the parent's
`at_exit` stack. Under the minitest bundled with Ruby 2.6.10 (5.11.3) that
stack contains an unguarded handler that calls every registered
`Minitest.after_run` block - including the one
[`skills/wurk:kit/scripts/test/support/home_guard.rb:39`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/support/home_guard.rb#L39) registers, whose body
is `FileUtils.remove_entry(@dir)`. So the two-line child, whose only job is to
exist and die, deletes the suite-wide HOME guard tmpdir out from under the
still-running parent. Minitest 6.0.0, which ships with the Homebrew ruby
4.0.7, added a pid guard to that handler
(`Minitest.allow_fork` plus `Process.pid != pid`), which is the entire reason
the same tree is green there. The failure is seed-dependent rather than
deterministic because minitest shuffles the suite list
(`minitest.rb:151`); it fails whenever any forking suite is shuffled ahead of
`HomeGuardTest`, which was 10 of 12 seeds measured.

**The interpreter is never chosen anywhere except by `execvp` against the
inherited PATH.** `.claude/wurk.json:28-29` sets `gate.full` and `gate.loop`
to `["ruby", "skills/wurk:kit/scripts/test/run.rb"]`; `manifest.rb` validates
only that the value is a non-empty array of strings and hands it through
untouched; `lib/sh.rb` splats it into `Open3.popen3`. Every one of the 28
kit scripts carries `#!/usr/bin/env ruby`, machine-enforced at
`contract_test.rb:719`. The only absolute interpreter path anywhere in
executable code is `RbConfig.ruby`, used by `gate_run.rb` to re-spawn itself
and never for the consumer gate command. `/usr/bin/ruby` appears only in
prose - most sharply at [`docs/architecture.md:183-185`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/docs/architecture.md#L183-L185), which tells a human
to run the gate on the floor while the manifest tells the machine to run it
on whatever PATH found. `docs/gate-contract.md` says nothing at all about the
interpreter.

**The blast radius of pinning is small in code and entirely in prose.**
Nothing string-matches `gate.full[0]`, no fixture or example uses `ruby` as a
gate command, no test reads the repo's own manifest, and the schema already
accepts an absolute path ([`docs/local-only-pilot.md:67-68`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/docs/local-only-pilot.md#L67-L68) mandates absolute
paths for a different reason). The exposures are four docs that tell a human
to type `ruby <path>`, one cosmetic hook fixture, and the fact that
`/usr/bin/ruby` is a macOS-only path being written into a file that
[`docs/machine-config.md:14-19`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/docs/machine-config.md#L14-L19) says is the home for what the *project*
decides, not what the *machine* does.

## Detailed Findings

### 1. What removes HomeGuard.dir

#### The guard and the hook

`skills/wurk:kit/scripts/test/support/home_guard.rb` is required by `run.rb`
before any test file, and by every guard-carrying support helper. At require
time it points `ENV["HOME"]` at a fresh tmpdir and registers a cleanup hook:

```ruby
      @original_home = ENV["HOME"]
      @dir = Dir.mktmpdir("wurk-test-home-")
      ENV["HOME"] = @dir
      UserConfig.reset! if defined?(UserConfig)
      Minitest.after_run { FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir) }
```

([`skills/wurk:kit/scripts/test/support/home_guard.rb:35-39`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/support/home_guard.rb#L35-L39))

The failing assertion is [`skills/wurk:kit/scripts/test/home_guard_test.rb:18`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/home_guard_test.rb#L18),
`assert Dir.exist?(HomeGuard.dir)`.

#### The forks

Four test files create a child process purely to obtain a reaped pid that is
guaranteed dead, which is the input the lock and supervisor staleness probes
need:

- [`skills/wurk:kit/scripts/test/campaign_state_test.rb:581`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/campaign_state_test.rb#L581) - the `dead_pid`
  private helper
- [`skills/wurk:kit/scripts/test/gate_run_test.rb:325`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/gate_run_test.rb#L325) - inside
  `test_poll_with_dead_supervisor_pid_and_no_sentinel_is_abandoned`
- [`skills/wurk:kit/scripts/test/lock_test.rb:271`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/lock_test.rb#L271), `:377`, `:615`, `:627` -
  `test_probe_on_a_lock_owned_by_a_reaped_forked_pid_reports_dead_and_stale`,
  `test_clear_succeeds_on_a_dead_holder`,
  `test_clear_succeeds_on_a_dead_holder_via_cli`,
  `test_clear_dry_run_removes_nothing`

All six sites are the same two lines:

```ruby
    dead_pid = fork { exit(0) }
    Process.wait(dead_pid)
```

These are legal under the kit's contract. The process-creation rule is
deliberately scoped to non-test files
([`skills/wurk:kit/scripts/test/contract_test.rb:662-664`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/contract_test.rb#L662-L664),
[`skills/wurk:kit/scripts/test/contract_test.rb:698-707`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/contract_test.rb#L698-L707)), and in any case the
regex matches `fork\s*\(`, not the brace form
([`skills/wurk:kit/scripts/test/contract_test.rb:138-139`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/contract_test.rb#L138-L139)).

**Later (2026-09-16):** these six sites were converted to `DeadPid.obtain`
(`skills/wurk:kit/scripts/test/support/dead_pid.rb`) under wu-tms, and
`HomeGuardTest#test_no_test_file_forks` now fails the suite if a test file
forks again. Grepping the tree for `fork { exit(0) }` finds nothing; the
plan is `docs/plans/260916-wu-tms-system-ruby-gate-and-forked-after-run.md`.

#### The minitest difference

System Ruby 2.6.10 bundles minitest 5.11.3. Its `autorun` registers a nested
`at_exit` with no process check:

```ruby
  def self.autorun
    at_exit {
      next if $! and not ($!.kind_of? SystemExit and $!.success?)

      exit_code = nil

      at_exit {
        @@after_run.reverse_each(&:call)
        exit exit_code || false
      }

      exit_code = Minitest.run ARGV
    } unless @@installed_at_exit
    @@installed_at_exit = true
  end
```

(`/Library/Ruby/Gems/2.6.0/gems/minitest-5.11.3/lib/minitest.rb:52-67`)

By the time a test forks, the outer handler has already been entered and
popped; what the child inherits is the *inner* handler. So the child runs
`@@after_run.reverse_each(&:call)` - the HomeGuard cleanup - and then
`exit exit_code || false`, with `exit_code` still `nil` in the child. The
child never re-runs the suite, which is why nothing in the output looks
unusual.

Ruby 4.0.7 bundles minitest 6.0.0, which added the guard:

```ruby
  def self.autorun
    Warning[:deprecated] = true

    at_exit {
      next if $! and not ($!.kind_of? SystemExit and $!.success?)

      exit_code = nil

      pid = Process.pid
      at_exit {
        next if !Minitest.allow_fork && Process.pid != pid
        @@after_run.reverse_each(&:call)
        exit exit_code || false
      }

      exit_code = Minitest.run ARGV
    } unless @@installed_at_exit
    @@installed_at_exit = true
  end
```

(`/opt/homebrew/lib/ruby/gems/4.0.0/gems/minitest-6.0.0/lib/minitest.rb:69-87`,
with `cattr_accessor :allow_fork` and `self.allow_fork = false` at `:63-64`)

Versions, measured:

```
$ /usr/bin/ruby -v
ruby 2.6.10p210 (2022-04-12 revision 67958) [universal.arm64e-darwin25]
$ /usr/bin/ruby -e 'require "minitest"; puts "minitest #{Minitest::VERSION}"'
minitest 5.11.3
$ ruby -v
ruby 4.0.7 (2026-09-15 revision 229531a6cf) +PRISM [arm64-darwin25]
$ ruby -e 'require "minitest"; puts "minitest #{Minitest::VERSION}"'
minitest 6.0.0
$ /usr/bin/ruby -e 'require "minitest"; p Minitest.respond_to?(:allow_fork)'
false
```

#### Reproduction 1: the mechanism in isolation

A 20-line scratchpad file, outside the repo, with one test that forks and one
that checks a tmpdir registered with `Minitest.after_run`:

```ruby
require "minitest/autorun"
require "tmpdir"
require "fileutils"

DIR = Dir.mktmpdir("guard-")
Minitest.after_run { FileUtils.remove_entry(DIR) if Dir.exist?(DIR) }

class AForkTest < Minitest::Test
  def test_a_fork_and_reap
    pid = fork { exit(0) }
    Process.wait(pid)
    assert pid
  end
end

class ZGuardTest < Minitest::Test
  def test_guard_dir_still_exists
    assert Dir.exist?(DIR), "guard dir #{DIR} was removed mid-suite"
  end
end
```

```
$ /usr/bin/ruby fork_repro.rb --seed 1
Run options: --seed 1

# Running:

.F

  1) Failure:
ZGuardTest#test_guard_dir_still_exists [fork_repro.rb:19]:
guard dir /var/folders/.../T/guard-20260916-29114-28h67e was removed mid-suite

2 runs, 2 assertions, 1 failures, 0 errors, 0 skips

$ ruby fork_repro.rb --seed 1
2 runs, 2 assertions, 0 failures, 0 errors, 0 skips
```

#### Reproduction 2: which process runs the hook

The same shape, with the hook printing its pid:

```ruby
require "minitest/autorun"
PARENT = Process.pid
Minitest.after_run { warn "after_run hook ran in pid=#{Process.pid} (parent=#{PARENT})" }
class AForkTest < Minitest::Test
  def test_fork; pid = fork { exit(0) }; Process.wait(pid); assert pid; end
end
```

```
$ /usr/bin/ruby who.rb
after_run hook ran in pid=29213 (parent=29207)
.after_run hook ran in pid=29207 (parent=29207)
1 runs, 1 assertions, 0 failures, 0 errors, 0 skips

$ ruby who.rb
.after_run hook ran in pid=29214 (parent=29214)
1 runs, 1 assertions, 0 failures, 0 errors, 0 skips
```

Under 2.6.10 the hook runs twice, once in the forked child (29213) before the
parent's own run has finished. Under 4.0.7 it runs once, in the parent.

#### Reproduction 3: the real suite, narrowed to one file plus the guard

A scratchpad driver that requires `support/home_guard`, one real test file,
and `home_guard_test.rb`, and nothing else:

```ruby
require "minitest/autorun"
HERE = File.expand_path("skills/wurk:kit/scripts/test")
require File.join(HERE, "support", "home_guard")
require ENV.fetch("FILE")
require File.join(HERE, "home_guard_test.rb")
```

```
$ FILE=.../campaign_state_test.rb /usr/bin/ruby pairs.rb --seed 2
56 runs, 202 assertions, 0 failures, 0 errors, 0 skips
$ FILE=.../campaign_state_test.rb /usr/bin/ruby pairs.rb --seed 5
56 runs, 201 assertions, 1 failures, 0 errors, 0 skips
$ FILE=.../campaign_state_test.rb /usr/bin/ruby pairs.rb --seed 7
56 runs, 201 assertions, 1 failures, 0 errors, 0 skips
$ FILE=.../gate_run_test.rb /usr/bin/ruby pairs.rb --seed 2
28 runs, 105 assertions, 1 failures, 0 errors, 0 skips
$ FILE=.../gate_run_test.rb /usr/bin/ruby pairs.rb --seed 5
28 runs, 105 assertions, 1 failures, 0 errors, 0 skips
$ FILE=.../gate_run_test.rb /usr/bin/ruby pairs.rb --seed 7
28 runs, 106 assertions, 0 failures, 0 errors, 0 skips
$ FILE=.../lock_test.rb /usr/bin/ruby pairs.rb --seed 2
50 runs, 146 assertions, 1 failures, 0 errors, 0 skips
$ FILE=.../lock_test.rb /usr/bin/ruby pairs.rb --seed 5
50 runs, 146 assertions, 1 failures, 0 errors, 0 skips
$ FILE=.../lock_test.rb /usr/bin/ruby pairs.rb --seed 7
50 runs, 147 assertions, 0 failures, 0 errors, 0 skips
```

Every one of the three forking files reproduces the failure on its own,
against `home_guard_test.rb` alone. A sweep of all 44 other test files the
same way flagged exactly `gate_run_test.rb` and `lock_test.rb` on that run's
random seeds, and `campaign_state_test.rb` on a seed where its forking test
was shuffled ahead of `HomeGuardTest`.

#### Reproduction 4: the seed dependence

Minitest 5.11.3 shuffles the suite list:

```ruby
  def self.__run reporter, options
    suites = Runnable.runnables.reject { |s| s.runnable_methods.empty? }.shuffle
```

(`/Library/Ruby/Gems/2.6.0/gems/minitest-5.11.3/lib/minitest.rb:150-151`)

Suite order is therefore seeded, not load-ordered, and the failure occurs
whenever any of the three forking suites is shuffled ahead of `HomeGuardTest`.
Twelve full-suite runs under `/usr/bin/ruby`:

```
$ for s in 1..12; /usr/bin/ruby skills/wurk:kit/scripts/test/run.rb --seed $s
seed 1 pass
seed 2 FAIL
seed 3 pass
seed 4 FAIL
seed 5 FAIL
seed 6 FAIL
seed 7 FAIL
seed 8 FAIL
seed 9 FAIL
seed 10 FAIL
seed 11 FAIL
seed 12 FAIL
failed 10 of 12
```

This refines the bead's "reproducibly (2/2)": the full run fails on most
seeds, not all. A default (unseeded) run is a coin weighted about 5:1 toward
red.

#### Reproduction 5: the pid guard alone is sufficient

Backporting minitest 6's guard onto `after_run`, from a scratchpad file
preloaded with `-r` and touching nothing in the repo:

```ruby
require "minitest"
module Minitest
  class << self
    alias_method :after_run_unguarded, :after_run
    def after_run(&block)
      owner = Process.pid
      after_run_unguarded { block.call if Process.pid == owner }
    end
  end
end
```

```
$ /usr/bin/ruby -r.../pidguard skills/wurk:kit/scripts/test/run.rb --seed 2
1301 runs, 4925 assertions, 0 failures, 0 errors, 0 skips
$ /usr/bin/ruby -r.../pidguard skills/wurk:kit/scripts/test/run.rb --seed 5
1301 runs, 4925 assertions, 0 failures, 0 errors, 0 skips
$ /usr/bin/ruby -r.../pidguard skills/wurk:kit/scripts/test/run.rb --seed 6
1301 runs, 4925 assertions, 0 failures, 0 errors, 0 skips
```

Seeds 2, 5 and 6 are three of the ten that fail unguarded. Suppressing the
after_run hook in non-owner processes, and changing nothing else, turns all
three green. The assertion count also rises from 4924 to 4925, which is the
one assertion that was failing.

#### Things ruled out

- **Not a recent regression.** The bead records a reproduction at 431326a,
  the pre-pull tip.
- **Not a `spawn`/`system`/`Open3` child.** Those `exec` over the image, so no
  Ruby `at_exit` handler of the parent's ever runs in them. `lib/sh.rb` is
  the only process-creation site in kit source
  ([`skills/wurk:kit/scripts/test/contract_test.rb:698-707`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/contract_test.rb#L698-L707)) and it uses
  `Open3.popen3(*argv)` and `Process.spawn(*argv, opts)`, both argv-array
  forms.
- **Not a test deleting HOME or the tmpdir directly.**
  `home_guard_test.rb:64-71` scans the whole test tree for
  `ENV.delete("HOME")` and is green.
- **Not `Dir.mktmpdir` finalization.** `HomeGuard.install!` calls the
  no-block form, which registers no finalizer.

### 2. The interpreter surface

#### Where the gate command is defined

`.claude/wurk.json:27-30`:

```jsonc
  "gate": {
    "full": ["ruby", "skills/wurk:kit/scripts/test/run.rb"],
    "loop": ["ruby", "skills/wurk:kit/scripts/test/run.rb"],
    "build_paths": ["skills/wurk:kit/scripts/"],
```

These two lines are the only occurrences of `"ruby"` as a gate argv[0]
anywhere in the repo. Every test fixture under
`skills/wurk:kit/scripts/test/fixtures/manifests/` gates on `make`, and every
doc example gates on `mix`, `mise`, `uv`, or an absolute shell script.

#### How it becomes a process

[`skills/wurk:kit/scripts/gate.rb:360-364`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/gate.rb#L360-L364):

```ruby
    def run_quality(env, manifest, loop_mode)
      reporting = loop_mode ? manifest.gate_report_loop : manifest.gate_report
      argv = reporting || (loop_mode ? manifest.gate_loop : manifest.gate_full)

      res = Sh.run(argv, chdir: manifest.gate_chdir, envelope: env, timeout: manifest.gate_timeout_seconds)
```

`Sh.run` records `Sh.render(argv, chdir:)` into the envelope's `commands`
audit trail and then splats the array into `Open3.popen3(*argv, opts)`
(`skills/wurk:kit/scripts/lib/sh.rb`). With two or more elements that is the
no-shell form, so `argv[0]` goes to `execvp` and is resolved against the
inherited `PATH`. Nothing resolves, validates, version-checks, or normalizes
it. The header states the rule the mechanism enforces
([`skills/wurk:kit/scripts/lib/sh.rb:5-9`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/lib/sh.rb#L5-L9)):

```ruby
# Sh is the one place any script under .claude/scripts/ shells out from.
# Every call goes through Open3.capture3 with an argv array - never a shell
# string - so a developer's `-i` aliases (cp/mv/rm) cannot apply and no shell
# metacharacter in an argument is ever interpreted.
```

Three other scripts spawn the gate command the same way: `gate_run.rb:148`
(which additionally persists `"argv" => gate_argv` into `meta.json` at `:219`
for a detached supervisor to re-execute at `:324`),
`worktree_create.rb:387` and `:481`, and `worktree_refresh.rb:128` and `:136`.

#### What resolves through PATH

Four distinct mechanisms select an interpreter, and only one of them names a
path:

1. `gate.full` / `gate.loop` argv[0] = `"ruby"` - PATH, via `execvp`.
2. `#!/usr/bin/env ruby` on all 28 top-level kit scripts and `install.rb` -
   PATH. Machine-enforced at
   [`skills/wurk:kit/scripts/test/contract_test.rb:719`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/contract_test.rb#L719):

   ```ruby
      assert_equal "#!/usr/bin/env ruby", first_line, "#{file} is missing the #!/usr/bin/env ruby shebang"
   ```

   There are zero `#!/usr/bin/ruby` shebangs in the repo.
3. `RbConfig.ruby` - the only absolute interpreter path in executable code,
   at [`skills/wurk:kit/scripts/gate_run.rb:206`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/gate_run.rb#L206), `:233` and `:287`, and it is
   used only for the supervisor re-spawning `gate_run.rb` itself. The
   `poll_command` it hands back to an agent reverts to a bare `ruby`
   ([`skills/wurk:kit/scripts/gate_run.rb:539`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/gate_run.rb#L539)).
4. The installed pre-push shim writes a bare `ruby` and fails closed if it is
   absent ([`skills/wurk:kit/scripts/outbound_scan.rb:404-410`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/outbound_scan.rb#L404-L410)).

Every skill, agent definition, and doc that tells a human or an agent to run
a kit script writes a bare `ruby` - roughly 130 occurrences across
`skills/wurk:*/SKILL.md`, `agents/*.md`, `README.md`, `CLAUDE.md` and
`docs/`.

#### What the docs say

`docs/gate-contract.md` says **nothing** about the interpreter. Its only
`ruby` token is about a gate producer, not about wurk's own interpreter
([`docs/gate-contract.md:54`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/docs/gate-contract.md#L54)):

```
- A bash/Ruby gate like fixative's assembles the same JSON from its per-stage
```

Its tier-0 requirement is purely about invocation and exit code
([`docs/gate-contract.md:10-15`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/docs/gate-contract.md#L10-L15)):

```
The manifest provides `gate.full` and `gate.loop` commands that exit non-zero
on failure. That is the whole requirement. Convention for new projects:
expose them as `mise run quality` and `mise run quality:loop` - mise is
already the toolchain manager in all current consumer repos, so a one-line
mise task wrapping `mix quality` (or anything else) gives every project the
same invocation surface.
```

[`docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md:55-72`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/docs/adr/0006-ruby-stdlib-scripts-with-envelope-contract.md#L55-L72) states the
floor and names the PATH hazard in so many words, but binds nothing:

```
**2. The version floor is macOS system Ruby, 2.6.** "Any Mac's system Ruby
with no toolchain install" above is a version claim, and the version is
2.6.10 - Apple has not moved it and nothing in a consumer install does. So a
kit script uses no core method added after 2.6: ...

Such a method parses on 2.6 and raises `NoMethodError` only when its line
runs, which makes this the one contract rule a contributor cannot notice by
reading: whoever has a 3.x `ruby` from homebrew or a version manager on
PATH sees a green suite while the gate is red on the Ruby this ADR commits
to. Three call sites did exactly that over five weeks in 2026-09 and left
the suite with 38 errors on the floor.
```

The mitigation ADR-0006 shipped is a static scan of kit source for post-2.6
method names ([`skills/wurk:kit/scripts/test/contract_test.rb:325-359`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/contract_test.rb#L325-L359)), not an
interpreter pin. ADR-0006 never writes `/usr/bin/ruby`.

[`CLAUDE.md:35-44`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/CLAUDE.md#L35-L44) names system Ruby and then writes a bare `ruby`:

> ## Build and test
>
> No toolchain beyond system Ruby. The gate is the kit test suite:
>
> ```bash
> ruby skills/wurk:kit/scripts/test/run.rb
> ```
>
> Run it before any commit that touches scripts.

[`CLAUDE.md:18-22`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/CLAUDE.md#L18-L22) restates the script contract as "stdlib-only system Ruby"
without a version or a path.

`docs/architecture.md` is the only doc that both names the path and instructs
a human to use it. [`docs/architecture.md:45-48`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/docs/architecture.md#L45-L48):

```
The deterministic mechanics, in Ruby (system Ruby, stdlib only - ADR-0006).
The version floor is macOS system Ruby, 2.6.10 at `/usr/bin/ruby`: no core
method added after 2.6 (ADR-0006's version-floor constraint, enforced by the
contract test).
```

and [`docs/architecture.md:182-186`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/docs/architecture.md#L182-L186):

```
The kit's minitest suite is the gate here, run directly (no mix, no mise
required): `ruby skills/wurk:kit/scripts/test/run.rb`. Run it on the version
floor - `/usr/bin/ruby` - since a newer `ruby` on PATH hides exactly the
breakage the floor rule exists to catch. The contract test is
part of that suite.
```

Two other kit docs state the floor as a path:
[`skills/wurk:kit/REFERENCE.md:108`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/REFERENCE.md#L108) ("**System Ruby 2.6.10 only**
(`/usr/bin/ruby` on macOS)") two lines above `:113`, which requires the
`#!/usr/bin/env ruby` shebang; and [`skills/wurk:kit/SKILL.md:20`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/SKILL.md#L20) ("no
toolchain beyond `/usr/bin/ruby`").

Pulling the other way, [`docs/adoption.md:24`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/docs/adoption.md#L24) states the requirement as a
floor-or-newer on PATH:

```
| Ruby 2.6 or newer on `PATH` | every kit script is stdlib Ruby (ADR-0006); macOS ships 2.6.10 at `/usr/bin/ruby`, most Linux distributions need a package | `ruby -v` |
```

and [`skills/wurk:init/SKILL.md:122-125`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:init/SKILL.md#L122-L125) will install `ruby@latest` via mise
when `ruby -v` is absent or older than 2.6. `docs/manifest.md` and
`docs/machine-config.md` name no ruby version and no interpreter path.

### 3. Blast radius of pinning the interpreter

#### Schema

`gate.full` and `gate.loop` are required keys
([`skills/wurk:kit/scripts/lib/manifest.rb:43-52`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/lib/manifest.rb#L43-L52)) and known subkeys of `gate`
(`:101-102`). They appear in no `ENUMS`, `DEFAULTS`, `RETIRED`, or
`REGEX_LIST_FIELDS` entry. The accessors are pass-through
([`skills/wurk:kit/scripts/lib/manifest.rb:389-395`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/lib/manifest.rb#L389-L395)):

```ruby
  def gate_full
    argv(fetch("gate.full"))
  end

  def gate_loop
    argv(fetch("gate.loop"))
  end
```

The complete content constraint is
[`skills/wurk:kit/scripts/lib/manifest.rb:1475-1477`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/lib/manifest.rb#L1475-L1477):

```ruby
  def argv?(value)
    value.is_a?(Array) && !value.empty? && value.all? { |v| v.is_a?(String) }
  end
```

Array, non-empty, all strings. No non-blank check on elements, no known-program
check on argv[0], no executable or PATH probe, no absolute-versus-relative
rule. `["/usr/bin/ruby", "skills/wurk:kit/scripts/test/run.rb"]` validates
today with no schema change, so `docs/manifest.md` would not need a schema
edit either. What `docs/manifest.md` documents about these fields is the argv
rule and nothing more ([`docs/manifest.md:8`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/docs/manifest.md#L8), `:1065-1066`):

```
Commands are argv arrays. Paths are relative to the repo root unless noted.
```

```
- **Command fields must be argv arrays** of strings. A shell string is a
  schema error, never something to split on whitespace.
```

The manifest envelope does not carry the value:
`manifest.rb check` emits `path`, `wurk`, `valid`, `errors`, `beads_*`,
`mr_review_agents`, `artifacts_adr`, `external_tracker`
([`skills/wurk:kit/scripts/lib/manifest.rb:1553-1575`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/lib/manifest.rb#L1553-L1575)). No skill can be reading
`gate.full` out of an envelope, because no envelope has it.

#### Runtime consumers

Four, all of which either spawn the array or render it for display:

| Site | Use |
| --- | --- |
| [`skills/wurk:kit/scripts/gate.rb:362`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/gate.rb#L362) | select, then spawn via `Sh.run` |
| [`skills/wurk:kit/scripts/gate_run.rb:148`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/gate_run.rb#L148) | select, serialize to `meta.json:219`, spawn later at `:324` |
| [`skills/wurk:kit/scripts/worktree_create.rb:387`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/worktree_create.rb#L387), `:481` | render (dry run), spawn in the new worktree |
| [`skills/wurk:kit/scripts/worktree_refresh.rb:128`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/worktree_refresh.rb#L128), `:136` | render (dry run), spawn post-rebase |

The display join is `Sh.render` ([`skills/wurk:kit/scripts/lib/sh.rb:340-352`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/lib/sh.rb#L340-L352)),
whose own comment says it is "for the `commands` audit trail only - never used
to actually execute anything". Its safe-character class includes `/`, so
`/usr/bin/ruby` would render unquoted. Nothing parses `commands` back.

The one place argv[0] is read as data is the start-failure diagnostic
([`skills/wurk:kit/scripts/lib/sh.rb:336-345`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/lib/sh.rb#L336-L345)), which interpolates
`argv.first` into the message that becomes the
`gate_command_could_not_start` block at [`skills/wurk:kit/scripts/gate.rb:554-558`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/gate.rb#L554-L558),
`worktree_create.rb:492-494`, and `worktree_refresh.rb:146-148`. After a pin it
would read `(command: "/usr/bin/ruby")`. No test asserts on that substring for
the gate path.

#### Tests

`skills/wurk:kit/scripts/test/contract_test.rb` asserts nothing about
`gate.full`; it scans kit source, not the manifest, and its consumer-vocabulary
ban list does not include `ruby` or `/usr/bin/ruby`.

`skills/wurk:kit/scripts/test/manifest_test.rb` asserts only the shape:
`:932-935` checks `@m.gate_full == %w[make check]` against a fixture, and
`:81-86` checks that a shell string blocks. Critically, `:1284-1291` records
that the suite deliberately does not validate this repo's own
`.claude/wurk.json`. So no test can go red from the repo's gate command
changing.

[`skills/wurk:kit/scripts/test/gate_run_test.rb:64-66`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/gate_run_test.rb#L64-L66) asserts on
`meta["argv"]`, but against fixture manifests (`%w[make check]`), so it is
unaffected.

#### What would actually need changing, and what could break

Nothing in code. The exposures:

1. **Portability.** `/usr/bin/ruby` exists on macOS and essentially nowhere
   else. Pinning binds this repo's own gate to macOS. A Linux run would
   produce a well-formed `gate_command_could_not_start` block naming the
   path, not a silent failure - but it would not run.
2. **Four docs that tell a human to type the gate command** and would then
   disagree with the manifest: [`CLAUDE.md:36-40`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/CLAUDE.md#L36-L40), [`README.md:100-101`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/README.md#L100-L101),
   [`docs/architecture.md:182-186`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/docs/architecture.md#L182-L186), `.claude/wurk/codebase.md:26`. None is
   machine-read. CLAUDE.md's own rule is that the doc follows the authority
   file in the same commit.
3. **`docs/gate-contract.md` says nothing about the interpreter at all**, so
   the bead's acceptance criterion ("docs/gate-contract.md says which
   interpreter the gate is contractually run under") is an addition, not an
   edit. Note that gate-contract.md is generic - it is the contract every
   consumer implements - so a statement there about *wurk's* interpreter
   would be a consumer constant in a generic document, which CLAUDE.md's
   hard rules forbid. A generic statement ("the manifest's gate command
   names its own interpreter when the project has a version floor") does not
   have that problem.
4. **One cosmetic fixture:** [`hooks/safe-wait-guard.sh:164`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/hooks/safe-wait-guard.sh#L164) embeds the
   literal `ruby skills/wurk:kit/scripts/test/run.rb` as a hermetic test
   string for the spin-loop guard. It passes either way.
5. **The audit trail and `meta.json` change shape.** Nothing parses either
   back. Second-order: `gate_run.rb` persists the argv and a detached
   supervisor re-executes it later, so a PATH that differed between `start`
   and `supervise` could silently switch interpreters today. A named
   interpreter removes that.

#### The machine-config seam

`~/.claude/wurk.local.json` exists (ADR-0013) and
[`skills/wurk:kit/scripts/lib/user_config.rb:44-50`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/lib/user_config.rb#L44-L50) lists its complete key
surface:

```ruby
  KNOWN = {
    nil => %w[wurk tmux outbound_scan machine workloads],
    "tmux" => %w[permission_mode],
    "outbound_scan" => %w[patterns_file control_term],
    "machine" => %w[name gate_slots],
    "workloads[]" => %w[root fleet_manifest enabled primary]
  }.freeze
```

There is no `gate` section, no accessor for one, and no gate script reads
`UserConfig` when building the argv (`gate.rb` never loads it; `gate_run.rb`
loads it only for `machine_gate_slots` at `:129`). A `gate.interpreter` key
placed there today would land as an unknown-key warning and be ignored.

The doctrine cuts against moving it there anyway
([`docs/machine-config.md:14-19`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/docs/machine-config.md#L14-L19)):

```
`.claude/wurk.json` is checked into a consumer repo and shared by everyone
who works it - it is the right home for anything the *project* decides
(the bead prefix, the gate command, the forge). It is the wrong home for
anything the *machine* or the *person at it* decides, because a value there
forces one setting on every engineer working the repo, and changing it means
editing and committing a tracked file.
```

That sentence names the gate command as a project decision. The tension a pin
creates is that `/usr/bin/ruby` is an OS fact written into a project file.
There is one existing precedent for machine-bound absolute paths in
`gate.full` - [`docs/local-only-pilot.md:60-68`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/docs/local-only-pilot.md#L60-L68) mandates them - but it is
scoped by `:83-90` to an untracked config belonging to one machine, which is
not this case.

## Code References

- [`skills/wurk:kit/scripts/test/support/home_guard.rb:32-41`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/support/home_guard.rb#L32-L41) - `install!`, and
  the `Minitest.after_run` hook at `:39` that the forked child runs
- [`skills/wurk:kit/scripts/test/home_guard_test.rb:15-20`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/home_guard_test.rb#L15-L20) - the failing test;
  the assertion is `:18`
- [`skills/wurk:kit/scripts/test/run.rb:24-29`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/run.rb#L24-L29) - requires the guard before any
  test file, then globs and requires every `*_test.rb`
- [`skills/wurk:kit/scripts/test/campaign_state_test.rb:580-583`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/campaign_state_test.rb#L580-L583) - `dead_pid`
- [`skills/wurk:kit/scripts/test/gate_run_test.rb:323-326`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/gate_run_test.rb#L323-L326) - fork in
  `test_poll_with_dead_supervisor_pid_and_no_sentinel_is_abandoned`
- [`skills/wurk:kit/scripts/test/lock_test.rb:271`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/lock_test.rb#L271) - fork in
  `test_probe_on_a_lock_owned_by_a_reaped_forked_pid_reports_dead_and_stale`
- [`skills/wurk:kit/scripts/test/contract_test.rb:662-664`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/contract_test.rb#L662-L664) - `non_test_files`,
  which exempts the test tree from the process-creation rule
- [`skills/wurk:kit/scripts/test/contract_test.rb:698-707`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/contract_test.rb#L698-L707) - the
  process-creation rule itself
- [`skills/wurk:kit/scripts/test/contract_test.rb:714-722`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/contract_test.rb#L714-L722) - the
  `#!/usr/bin/env ruby` shebang rule
- [`skills/wurk:kit/scripts/test/contract_test.rb:325-359`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/test/contract_test.rb#L325-L359) - the post-2.6
  method-name scan, ADR-0006's mitigation for the PATH hazard
- `.claude/wurk.json:28-29` - the gate command
- [`skills/wurk:kit/scripts/gate.rb:360-364`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/gate.rb#L360-L364) - gate argv selection and spawn
- [`skills/wurk:kit/scripts/gate.rb:530-558`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/gate.rb#L530-L558) - `gate_command_could_not_start`
- [`skills/wurk:kit/scripts/gate_run.rb:148`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/gate_run.rb#L148) - gate argv selection
- [`skills/wurk:kit/scripts/gate_run.rb:206`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/gate_run.rb#L206) - `RbConfig.ruby`, the only
  absolute interpreter path in executable code
- [`skills/wurk:kit/scripts/gate_run.rb:219`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/gate_run.rb#L219) - `"argv" => gate_argv` persisted
  to `meta.json`
- [`skills/wurk:kit/scripts/gate_run.rb:539`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/gate_run.rb#L539) - `poll_command_for`, which hands
  back a bare `ruby`
- [`skills/wurk:kit/scripts/lib/sh.rb:5-9`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/lib/sh.rb#L5-L9) - the argv-array rule
- [`skills/wurk:kit/scripts/lib/sh.rb:336-345`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/lib/sh.rb#L336-L345) - `start_failure_message`
- [`skills/wurk:kit/scripts/lib/manifest.rb:389-395`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/lib/manifest.rb#L389-L395) - `gate_full` / `gate_loop`
- [`skills/wurk:kit/scripts/lib/manifest.rb:878-892`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/lib/manifest.rb#L878-L892) - `argv` and
  `COMMAND_FIELDS`
- [`skills/wurk:kit/scripts/lib/manifest.rb:1475-1477`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/lib/manifest.rb#L1475-L1477) - `argv?`, the whole
  content constraint
- [`skills/wurk:kit/scripts/lib/user_config.rb:44-50`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/lib/user_config.rb#L44-L50) - `KNOWN`
- [`skills/wurk:kit/scripts/worktree_create.rb:387`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/worktree_create.rb#L387) and `:481` - gate.loop
- [`skills/wurk:kit/scripts/worktree_refresh.rb:128`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/worktree_refresh.rb#L128) and `:136` - gate.loop
- [`skills/wurk:kit/scripts/outbound_scan.rb:404-410`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/skills/wurk:kit/scripts/outbound_scan.rb#L404-L410) - the pre-push shim's
  bare `ruby`, failing closed
- [`hooks/safe-wait-guard.sh:164`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/hooks/safe-wait-guard.sh#L164) - the cosmetic gate-command fixture

External (not in this repo, quoted above):

- `/Library/Ruby/Gems/2.6.0/gems/minitest-5.11.3/lib/minitest.rb:52-67` -
  `autorun`, unguarded
- `/Library/Ruby/Gems/2.6.0/gems/minitest-5.11.3/lib/minitest.rb:150-151` -
  `__run`, `.shuffle`
- `/opt/homebrew/lib/ruby/gems/4.0.0/gems/minitest-6.0.0/lib/minitest.rb:63-64`,
  `:69-87` - `allow_fork` and the pid guard

## Architecture Documentation

- **ADR-0006** commits the kit to macOS system Ruby 2.6.10, stdlib only, with
  the version floor enforced by a static method-name scan rather than by a
  runtime interpreter check. The ADR text at `:63-67` describes the exact
  situation wu-tms is about: a 3.x ruby on PATH showing green while the floor
  is red. The gap is that the ADR's enforcement mechanism catches post-2.6
  *method names* in kit source, and cannot catch a behavioral difference in a
  *bundled stdlib gem* - which is what minitest 5.11.3 versus 6.0.0 is.
- **ADR-0013** (via `docs/machine-config.md`) draws the project-versus-machine
  seam and explicitly assigns the gate command to the project side.
- The gate contract (`docs/gate-contract.md`, ADR-0005) is deliberately
  interpreter-agnostic: tier 0 is "a command that exits non-zero on failure"
  and nothing else.
- `lib/sh.rb` as the single process-creation site, enforced by the contract
  test, is what makes the interpreter surface small enough to describe: three
  spawn forms, all argv arrays, all in one file.
- The kit's HOME guard (`support/home_guard.rb`, from wu-yi7.11) is itself a
  process-wide singleton installed at require time, which is what makes it
  inheritable by `fork` and therefore reachable from a child.

## Historical Context

- `docs/research/260902-wu-4x9-subagent-long-gate-runs-and-locks.md` covers
  the long-gate supervisor that `gate_run.rb` implements, which is the code
  path that persists the gate argv to `meta.json` and re-executes it detached.
- `docs/research/260817-wu-9fb-subdirectory-gate-cwd.md` and its plan
  (`docs/plans/260817-wu-9fb-subdirectory-gate-cwd.md`) established
  `gate.cwd`, the other half of "where the gate runs"; gate-contract.md's
  tier section points at it explicitly ("Tiers are about what a gate command
  reports, not where it runs; where it runs is `gate.cwd`").
- The comment block at `support/home_guard.rb:7-27` records wu-yi7.11, the
  order-dependent flake that printed the operator's real machine config into
  the terminal, which is why the guard exists and why it is blunt.
- ADR-0006's "three call sites did exactly that over five weeks in 2026-09 and
  left the suite with 38 errors on the floor" is the prior incident of the
  same shape as wu-tms: the gate measured on the wrong interpreter.

## Related Research

- `docs/research/260902-wu-4x9-subagent-long-gate-runs-and-locks.md`
- `docs/research/260817-wu-9fb-subdirectory-gate-cwd.md`

## Open Questions

No human was available during this research; these are recorded rather than
asked.

1. **Where should the interpreter statement live?**
   `docs/gate-contract.md` is a generic document describing the contract every
   consumer implements, and CLAUDE.md's hard rules forbid consumer constants
   in generic documents. The bead's acceptance criterion asks
   gate-contract.md to say "which interpreter the gate is contractually run
   under". Whether that means a generic rule (a project with a version floor
   names its interpreter in its gate command) or wurk's own `/usr/bin/ruby`
   is unresolved.
2. **Does pinning to `/usr/bin/ruby` conflict with ADR-0013's
   project-versus-machine seam?** [`docs/machine-config.md:14-19`](https://github.com/riddler/wurk/blob/d3a2a204840289d8667ae3601ff59950c6b6a9fa/docs/machine-config.md#L14-L19) names the
   gate command as a project decision, but `/usr/bin/ruby` is an OS fact. The
   alternatives visible from here are: pin in `.claude/wurk.json` and accept
   macOS-only for this repo's own gate; add a manifest field for an
   interpreter that has a PATH fallback; or add a `gate` section to
   `user_config.rb`'s `KNOWN` and have gate.rb consult it, which nothing does
   today.
3. **Does the same class of bug affect consumer repos?** The kit is installed
   into `~/.claude` by symlink and consumed by statifier-ex, predicator-ex and
   fixative. Their own suites do not run this kit suite, but any consumer test
   suite that forks under minitest 5.11.3 has the same hazard with its own
   `after_run` hooks. Not investigated.
4. **Is `home_guard_test.rb:18` the only assertion the forked child can
   break?** The after_run hook is the only registered one found, but other
   at_exit handlers registered anywhere in the suite would also run in the
   child. Not exhaustively enumerated.
5. **`worktree_refresh.rb:128` calls `Sh.run` for the gate without a
   `timeout:`**, falling back to Sh's 60-second default, where
   `worktree_create.rb:481` passes `manifest.gate_timeout_seconds`. Noticed in
   passing during the blast-radius sweep; unrelated to wu-tms and not
   investigated.

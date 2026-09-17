# frozen_string_literal: true

require "rbconfig"
require_relative "home_guard"

# DeadPid: a reaped pid that is certainly dead, obtained without fork.
#
# The lock and supervisor staleness probes need a pid that exists in no
# process table. The obvious way to get one is to fork a child that exits
# immediately and reap it - and that is what four test files did until
# wu-tms. A forked child inherits the parent's at_exit stack, and the
# minitest bundled with the version floor (5.11.3, Ruby 2.6.10) registers
# its after-run handler with no Process.pid check, so the two-line child ran
# every registered Minitest.after_run block on its way out - including
# support/home_guard.rb's, which removes the suite-wide HOME guard tmpdir.
# The parent then failed an assertion about a directory its own child had
# deleted, on 10 of 12 seeds. Minitest 6 added the pid guard, which is why
# the same tree was green under a newer ruby on PATH and red on the floor.
#
# spawn does not have the problem: it execs over the process image, so no
# at_exit handler of this process ever runs there. home_guard_test.rb scans
# the test tree for fork and fails naming any file that brings it back.
module DeadPid
  # /usr/bin/true where it exists (about 2ms), the running interpreter
  # otherwise (about 40ms) - the fallback is for a machine that has no
  # /usr/bin/true, not a preference.
  def self.obtain
    pid = if File.executable?("/usr/bin/true")
            Process.spawn("/usr/bin/true")
          else
            Process.spawn(RbConfig.ruby, "-e", "", out: File::NULL, err: File::NULL)
          end
    Process.wait(pid)
    pid
  end
end

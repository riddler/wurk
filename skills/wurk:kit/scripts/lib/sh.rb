# frozen_string_literal: true

require "open3"

# Sh is the one place any script under .claude/scripts/ shells out from.
# Every call goes through Open3.capture3 with an argv array - never a shell
# string - so a developer's `-i` aliases (cp/mv/rm) cannot apply and no shell
# metacharacter in an argument is ever interpreted. See
# .claude/scripts/README.md and CLAUDE.md's non-interactive-shell section.
#
#   result = Sh.run(["git", "worktree", "list", "--porcelain"])
#   result.out    # => stdout
#   result.err    # => stderr
#   result.status # => Process::Status-like, responds to #success? and #exitstatus
#   result.timed_out? # => true if the timeout wrapper killed the child
#
# Sh.runner= swaps in a fake (see test/support/fake_sh.rb) so tests never
# shell out for real.
class Sh
  class Result
    attr_reader :out, :err, :status

    def initialize(out:, err:, status:, timed_out: false)
      @out = out
      @err = err
      @status = status
      @timed_out = timed_out
    end

    def success?
      !@timed_out && !!status && status.success?
    end

    def timed_out?
      @timed_out
    end

    # True when the child process never started at all - a missing
    # executable or a chdir directory that does not exist - as opposed to a
    # process that ran and exited nonzero. Callers that only check
    # #success? get the right answer either way; this is for callers that
    # need to tell the two apart to report a diagnosable cause instead of an
    # ordinary command failure.
    def start_failed?
      status.is_a?(StartFailureStatus)
    end
  end

  # A fake, successful Process::Status-alike for the timeout case, where no
  # real child status is available.
  class TimeoutStatus
    def success?
      false
    end

    def exitstatus
      nil
    end
  end

  # A fake Process::Status-alike for when Open3.popen3 could not start the
  # child at all (Errno::ENOENT: missing executable or missing chdir
  # directory). Same shape as TimeoutStatus - no real exitstatus exists -
  # kept as its own class so Result#start_failed? can tell the two apart.
  class StartFailureStatus
    def success?
      false
    end

    def exitstatus
      nil
    end
  end

  class << self
    # The active runner. Defaults to the real implementation; tests replace
    # it with a FakeSh instance via Sh.runner=.
    def runner
      @runner ||= RealRunner.new
    end

    def runner=(runner)
      @runner = runner
    end

    # Runs argv (an array of strings - never a shell string) and returns a
    # Result. Optionally records the rendered command line into an
    # Envelope's `commands` list via the envelope: keyword.
    def run(argv, chdir: nil, timeout: 60, envelope: nil)
      envelope.commands << render(argv, chdir: chdir) if envelope
      runner.run(argv, chdir: chdir, timeout: timeout)
    end

    # Renders argv the way it would be typed at a shell, for the `commands`
    # audit trail only - never used to actually execute anything.
    def render(argv, chdir: nil)
      line = argv.map { |part| shell_quote(part) }.join(" ")
      chdir ? "(cd #{shell_quote(chdir)} && #{line})" : line
    end

    private

    def shell_quote(part)
      return part if part =~ /\A[A-Za-z0-9_.\-\/=:@]+\z/

      "'" + part.gsub("'", "'\\\\''") + "'"
    end
  end

  # The real implementation: Open3.capture3 with an argv array (no shell), so
  # a developer's `-i` aliases and shell metacharacters never come into play.
  #
  # Timeout.timeout alone would not help here: it interrupts the calling
  # thread but leaves an Open3.capture3 child running as an orphan. Instead
  # this uses Open3.popen3 to get a real pid, races a wait thread against a
  # timeout thread, and on timeout sends TERM then KILL to the child so a
  # hung `gh` or `tmux` poll cannot stall a session indefinitely.
  class RealRunner
    def run(argv, chdir: nil, timeout: 60)
      opts = {}
      opts[:chdir] = chdir if chdir

      out = +""
      err = +""
      status = nil
      timed_out = false

      Open3.popen3(*argv, opts) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        out_thr = Thread.new { out = stdout.read }
        err_thr = Thread.new { err = stderr.read }

        unless wait_thr.join(timeout)
          timed_out = true
          kill_process_group(wait_thr.pid)
          wait_thr.join(2)
        end

        out_thr.join
        err_thr.join
        status = timed_out ? TimeoutStatus.new : wait_thr.value
      end

      Result.new(out: out, err: err, status: status, timed_out: timed_out)
    rescue SystemCallError => e
      # Open3.popen3 raises before a child ever exists when the executable is
      # missing from PATH (Errno::ENOENT) or chdir names a directory that does
      # not exist (also Errno::ENOENT) or is not accessible/not a directory
      # (Errno::EACCES / Errno::ENOTDIR). Rescued narrowly - SystemCallError,
      # not StandardError - so this is the one primitive every script shells
      # out through, and a too-wide rescue here would silently eat unrelated
      # bugs from every caller at once. Every other exception still escapes.
      #
      # Returned as a normal failed Result, never raised: the caller (gate.rb
      # among others) gets something to build an envelope from instead of a
      # bare Ruby traceback on stderr, which is what broke the kit's one
      # JSON-envelope-on-stdout contract in the first place.
      Result.new(out: "", err: start_failure_message(argv, chdir, e), status: StartFailureStatus.new)
    end

    private

    # Names the concrete cause in the same message a reader sees in
    # Result#err: which executable could not be run, and (when chdir was
    # passed) which directory - so a typo'd gate.cwd is distinguishable from
    # a gate command simply missing from PATH without a traceback.
    def start_failure_message(argv, chdir, error)
      command = argv.first
      detail = chdir ? "#{error.message} (command: #{command.inspect}, chdir: #{chdir.inspect})"
                     : "#{error.message} (command: #{command.inspect})"
      "could not start command - #{detail}"
    end

    def kill_process_group(pid)
      Process.kill("TERM", pid)
      sleep 0.2
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      # already exited
    end
  end
end

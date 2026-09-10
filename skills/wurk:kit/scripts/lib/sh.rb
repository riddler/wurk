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
#   result.timed_out? # => true if the call ran out of its timeout budget
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

    # True when the call did not complete inside its timeout - either the
    # child was still running and was killed, or its output was still
    # arriving past the deadline and the readers were abandoned. In both
    # cases #out and #err carry whatever had been buffered when the deadline
    # passed and may be truncated mid-stream; nothing is appended to say so,
    # because this flag is the signal and a marker in the stream would be
    # bytes the command never wrote. See ADR-0015.
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

    # Starts argv detached from this process's lifetime, in its own process
    # group, with stdout/stderr redirected to out_path. Returns the pid, not
    # a Result - nobody downstream of a detached spawn is the child's parent,
    # so there is no exit status to hand back here (see lib/sh.rb's own
    # supervisor-design note in the long-gate-runner plan: whatever wants an
    # exit status must be the process that actually waits on this pid).
    def spawn_detached(argv, chdir: nil, out_path:)
      runner.spawn_detached(argv, chdir: chdir, out_path: out_path)
    end

    # Same popen3 shape as #run, but the child runs in its own process group
    # and its output is streamed to log_path as it arrives rather than only
    # buffered - see RealRunner#run_streaming for the reason and the
    # in-memory tail tradeoff.
    def run_streaming(argv, chdir: nil, timeout: 60, log_path:)
      runner.run_streaming(argv, chdir: chdir, timeout: timeout, log_path: log_path)
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
  #
  # That kill reaches the direct child only, so a command that spawns durable
  # children can still orphan them on timeout. ADR-0015 records why the
  # blocking path keeps single-pid semantics rather than adopting
  # `pgroup: true`, and points a caller that needs the whole tree reaped at
  # #run_streaming.
  #
  # The timeout bounds the whole call, not just when the child is signalled.
  # An orphaned descendant that inherited the child's stdout keeps that pipe
  # open after the child dies, so a reader thread waiting for EOF waits for
  # the descendant - which is how a 0.3s timeout used to return after 5s.
  # The readers are therefore joined against the same deadline and abandoned
  # when it passes; ADR-0015 records the rule that follows from abandoning
  # them, which is that a call the timeout could not complete reports
  # #timed_out? even when the direct child exited cleanly.
  class RealRunner
    # Grace the reader threads get to drain what is already sitting in the
    # pipes once the timeout budget is spent. A killed child has no budget
    # left by definition, and the bytes it wrote just before dying are worth
    # this much wall clock; a descendant still holding the pipe costs exactly
    # this and no more.
    READER_DRAIN_GRACE_SECONDS = 0.25

    # Bytes a reader thread asks for per read. Only a buffering choice - the
    # readers loop until EOF or until they are abandoned.
    READ_CHUNK_BYTES = 16_384

    # A byte buffer a reader thread appends to as output arrives, safe to
    # read from another thread at any moment. #run needs this rather than
    # `out = stdout.read`: a thread that only assigns its result at EOF
    # yields nothing at all when it is abandoned mid-stream, so the buffer
    # has to be filled incrementally for a timed-out call to have anything
    # to return.
    class Buffer
      def initialize
        @mutex = Mutex.new
        @bytes = +"".b
      end

      def <<(chunk)
        @mutex.synchronize { @bytes << chunk }
        self
      end

      # A snapshot, tagged with the same encoding IO#read would have given
      # the whole stream. Chunk boundaries can split a multibyte character,
      # so the tagging happens once, on the joined bytes, never per chunk.
      def value
        @mutex.synchronize { @bytes.dup.force_encoding(Encoding.default_external) }
      end
    end

    def run(argv, chdir: nil, timeout: 60)
      opts = {}
      opts[:chdir] = chdir if chdir

      out_buf = Buffer.new
      err_buf = Buffer.new
      status = nil
      timed_out = false

      Open3.popen3(*argv, opts) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        deadline = Time.now + timeout
        readers = [Thread.new { drain(stdout, out_buf) }, Thread.new { drain(stderr, err_buf) }]

        unless wait_thr.join(timeout)
          timed_out = true
          kill_child_pid(wait_thr.pid)
          wait_thr.join(2)
        end

        # Fails closed: output still arriving after the deadline is a call
        # that did not finish inside its timeout, whatever the child's own
        # exit status says, so it is reported as a timeout rather than as a
        # success with quietly truncated output.
        timed_out = true unless drain_readers(readers, deadline)
        status = timed_out ? TimeoutStatus.new : wait_thr.value
      end

      Result.new(out: out_buf.value, err: err_buf.value, status: status, timed_out: timed_out)
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

    # Starts argv in its own process group, fully detached from this
    # process's lifetime, with stdout/stderr redirected to out_path. Returns
    # the pid. Its own process group (pgroup: true) is what lets a later
    # signal reach the whole tree; #run above deliberately keeps its
    # existing single-pid kill semantics (kill_child_pid, below) so this
    # method changes no existing call site.
    def spawn_detached(argv, chdir: nil, out_path:)
      opts = { pgroup: true, out: out_path, err: [:child, :out] }
      opts[:chdir] = chdir if chdir
      pid = Process.spawn(*argv, opts)
      Process.detach(pid)
      pid
    end

    # The number of trailing lines of combined stdout/stderr kept in memory
    # for a streaming run's Result. The full output always lives on disk at
    # log_path; this bound only protects a long-running gate from growing an
    # unbounded in-memory buffer while it streams.
    STREAMING_TAIL_LINES = 200

    # Same popen3/thread/timeout shape as #run, with two differences: the
    # reader threads also append every line to log_path as it arrives, so a
    # poller elsewhere has something to tail while the command is still
    # running, and the child starts in its own process group (pgroup: true)
    # so a timeout kill signals the whole group instead of leaving
    # grandchildren orphaned the way #run's single-pid kill can.
    #
    # The full output is on disk at log_path. The returned Result's #out and
    # #err carry only the last STREAMING_TAIL_LINES lines of each stream, not
    # the whole thing - a caller that needs the complete output must read
    # log_path itself.
    def run_streaming(argv, chdir: nil, timeout: 60, log_path:)
      opts = { pgroup: true }
      opts[:chdir] = chdir if chdir

      out_tail = []
      err_tail = []
      status = nil
      timed_out = false
      log = File.open(log_path, "w")
      log_mutex = Mutex.new

      begin
        Open3.popen3(*argv, opts) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          out_thr = Thread.new { stream_to_log(stdout, log, log_mutex, out_tail) }
          err_thr = Thread.new { stream_to_log(stderr, log, log_mutex, err_tail) }

          unless wait_thr.join(timeout)
            timed_out = true
            kill_pgid(wait_thr.pid)
            wait_thr.join(2)
          end

          out_thr.join
          err_thr.join
          status = timed_out ? TimeoutStatus.new : wait_thr.value
        end
      ensure
        log.close
      end

      Result.new(out: out_tail.join, err: err_tail.join, status: status, timed_out: timed_out)
    rescue SystemCallError => e
      # Same rationale as #run's rescue above: Open3.popen3 can raise before
      # a child exists at all (missing executable, bad chdir).
      Result.new(out: "", err: start_failure_message(argv, chdir, e), status: StartFailureStatus.new)
    end

    private

    # Reads io into buffer until EOF, or until the stream is closed out from
    # under the thread - which is what an abandoned reader gets. Whatever
    # arrived before that point stays in buffer.
    def drain(io, buffer)
      loop { buffer << io.readpartial(READ_CHUNK_BYTES) }
    rescue EOFError, IOError, SystemCallError
      nil
    end

    # Joins the reader threads against the call's own deadline and returns
    # true if both reached EOF. When the deadline is gone - always the case
    # on the timeout path, where the budget was spent waiting on the child -
    # they still get READER_DRAIN_GRACE_SECONDS to pick up what is already in
    # the pipes. Readers that are still blocked after that are killed and
    # joined before the caller returns, so no thread is left reading a stream
    # that Open3 is about to close.
    def drain_readers(readers, deadline)
      finish = Time.now + [deadline - Time.now, READER_DRAIN_GRACE_SECONDS].max
      return true if readers.all? { |thr| thr.join([finish - Time.now, 0].max) }

      readers.each(&:kill)
      readers.each { |thr| thr.join(READER_DRAIN_GRACE_SECONDS) }
      false
    end

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

    # Reads io line by line, writing each line to log immediately (so a
    # `tail -f` on log_path sees output as it happens) while keeping only
    # the last STREAMING_TAIL_LINES lines in tail. Two threads (stdout and
    # stderr) share log and log_mutex, so writes are serialized to keep a
    # single line from interleaving with another mid-write.
    def stream_to_log(io, log, log_mutex, tail)
      io.each_line do |line|
        log_mutex.synchronize do
          log.write(line)
          log.flush
        end
        tail << line
        tail.shift while tail.length > STREAMING_TAIL_LINES
      end
    rescue IOError
      # The stream was closed out from under us during shutdown; nothing
      # left to read.
    end

    # Signals the direct child pid only, never a process group - #run's
    # child shares this process's group (no pgroup: true), so its pid is not
    # a process-group id and a negative-pid signal would be a silent no-op.
    # That single-pid delivery is deliberate, not an oversight: see ADR-0015.
    def kill_child_pid(pid)
      Process.kill("TERM", pid)
      sleep 0.2
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      # already exited
    end

    # Like kill_child_pid, but signals the negative pid - the whole process
    # group - instead of the single pid. Only used by #run_streaming's
    # timeout path, whose child really is its own group leader (pgroup:
    # true). #run keeps single-pid semantics; ADR-0015 records why.
    def kill_pgid(pid)
      Process.kill("TERM", -pid)
      sleep 0.2
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      # already exited
    end
  end
end

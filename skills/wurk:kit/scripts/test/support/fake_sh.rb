# frozen_string_literal: true

require_relative "../../lib/sh"

# FakeSh is a recording/replaying double for Sh, installed via
# Sh.runner = FakeSh.new so no test ever shells out for real.
#
# Register expected calls with #expect(argv_prefix, ...), matching on a
# prefix of argv (so a test can match `["git", "worktree", "add"]` without
# spelling out every trailing argument). An argv that does not match any
# registered expectation raises - a script that shells out to something the
# test did not authorize fails loudly rather than silently doing nothing.
#
#   fake = FakeSh.new
#   fake.expect(["git", "worktree", "list"], out: "...", err: "", exitstatus: 0)
#   Sh.runner = fake
#   ...
#   fake.verify! # optional: asserts every expectation was consumed
class FakeSh
  Call = Struct.new(:argv, :chdir, :timeout)

  class UnexpectedCommand < StandardError; end

  class FakeStatus
    def initialize(exitstatus)
      @exitstatus = exitstatus
    end

    def success?
      @exitstatus == 0
    end

    attr_reader :exitstatus
  end

  DetachedCall = Struct.new(:argv, :chdir, :out_path)

  attr_reader :calls, :detached_calls

  def initialize
    @expectations = []
    @calls = []
    @detached_calls = []
    @next_detached_pid = 424_242
  end

  # Registers a fake response for the next call whose argv starts with
  # argv_prefix. Expectations are consumed in FIFO order among matches.
  # start_failed: true simulates Sh::RealRunner's rescued SystemCallError
  # case (missing executable / bad chdir) instead of an ordinary exit -
  # exitstatus/timed_out are meaningless together with it and are ignored.
  # log: is only meaningful for a #run_streaming expectation: when given,
  # #run_streaming writes it to the call's log_path so a caller's log
  # handling gets exercised without a real subprocess.
  def expect(argv_prefix, out: "", err: "", exitstatus: 0, timed_out: false, start_failed: false, log: nil)
    @expectations << { prefix: argv_prefix, out: out, err: err, exitstatus: exitstatus,
                        timed_out: timed_out, start_failed: start_failed, log: log }
    self
  end

  # Sh-compatible entry point.
  def run(argv, chdir: nil, timeout: 60)
    @calls << Call.new(argv, chdir, timeout)
    result_for(argv)
  end

  # Sh-compatible entry point for Sh.run_streaming. Matches an expectation
  # exactly like #run does, and additionally writes an expectation's log:
  # (when given) to log_path.
  def run_streaming(argv, chdir: nil, timeout: 60, log_path:)
    @calls << Call.new(argv, chdir, timeout)
    index = expectation_index_for(argv)
    exp = @expectations[index]
    File.write(log_path, exp[:log]) if exp && exp[:log]
    result_for(argv)
  end

  # Sh-compatible entry point for Sh.spawn_detached. Returns a canned pid
  # (a different one each call) and records the argv/chdir/out_path for
  # assertions - no expectation queue, since a detached spawn has no
  # Result to script.
  def spawn_detached(argv, chdir: nil, out_path:)
    @detached_calls << DetachedCall.new(argv, chdir, out_path)
    @next_detached_pid += 1
  end

  # Asserts every registered expectation was called.
  def verify!
    return if @expectations.empty?

    raise "FakeSh had unconsumed expectations: #{@expectations.map { |e| e[:prefix] }.inspect}"
  end

  private

  def expectation_index_for(argv)
    index = @expectations.find_index { |e| argv[0, e[:prefix].length] == e[:prefix] }
    raise UnexpectedCommand, "FakeSh received unauthorized command: #{argv.inspect}" unless index

    index
  end

  def result_for(argv)
    exp = @expectations.delete_at(expectation_index_for(argv))
    if exp[:start_failed]
      return Sh::Result.new(out: exp[:out], err: exp[:err], status: Sh::StartFailureStatus.new)
    end

    Sh::Result.new(
      out: exp[:out],
      err: exp[:err],
      status: FakeStatus.new(exp[:exitstatus]),
      timed_out: exp[:timed_out]
    )
  end
end

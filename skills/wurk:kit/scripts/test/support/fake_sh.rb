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

  attr_reader :calls

  def initialize
    @expectations = []
    @calls = []
  end

  # Registers a fake response for the next call whose argv starts with
  # argv_prefix. Expectations are consumed in FIFO order among matches.
  # start_failed: true simulates Sh::RealRunner's rescued SystemCallError
  # case (missing executable / bad chdir) instead of an ordinary exit -
  # exitstatus/timed_out are meaningless together with it and are ignored.
  def expect(argv_prefix, out: "", err: "", exitstatus: 0, timed_out: false, start_failed: false)
    @expectations << { prefix: argv_prefix, out: out, err: err, exitstatus: exitstatus,
                        timed_out: timed_out, start_failed: start_failed }
    self
  end

  # Sh-compatible entry point.
  def run(argv, chdir: nil, timeout: 60)
    @calls << Call.new(argv, chdir, timeout)

    index = @expectations.find_index { |e| argv[0, e[:prefix].length] == e[:prefix] }
    unless index
      raise UnexpectedCommand, "FakeSh received unauthorized command: #{argv.inspect}"
    end

    exp = @expectations.delete_at(index)
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

  # Asserts every registered expectation was called.
  def verify!
    return if @expectations.empty?

    raise "FakeSh had unconsumed expectations: #{@expectations.map { |e| e[:prefix] }.inspect}"
  end
end

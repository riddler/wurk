# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/sh"
require_relative "../lib/envelope"

class ShTest < Minitest::Test
  def teardown
    Sh.runner = nil
  end

  def test_run_captures_stdout_stderr_and_status
    result = Sh.run(["/bin/echo", "-n", "hello"])

    assert_equal "hello", result.out
    assert result.success?
    refute result.timed_out?
  end

  def test_failing_command_is_not_success
    result = Sh.run(["/usr/bin/false"])

    refute result.success?
    refute result.timed_out?
  end

  def test_argv_is_never_shelled_out_a_metacharacter_in_an_argument_is_literal
    # If Sh ever ran this through a shell, `; touch` would execute as a
    # second command. Passed as argv it must be echoed back literally.
    payload = "hello; touch /tmp/should-not-exist-#{Process.pid}"
    result = Sh.run(["/bin/echo", "-n", payload])

    assert_equal payload, result.out
    refute File.exist?("/tmp/should-not-exist-#{Process.pid}")
  end

  def test_missing_executable_returns_a_start_failed_result_instead_of_raising
    result = Sh.run(["/no/such/executable-#{Process.pid}"])

    refute result.success?
    assert result.start_failed?
    refute result.timed_out?
    assert_match(/could not start command/, result.err)
    assert_match(/no-such-executable-#{Process.pid}|no\/such\/executable-#{Process.pid}/, result.err)
  end

  def test_nonexistent_chdir_returns_a_start_failed_result_instead_of_raising
    bad_dir = "/tmp/wu-8eh-does-not-exist-#{Process.pid}"

    result = Sh.run(["/bin/echo", "hi"], chdir: bad_dir)

    refute result.success?
    assert result.start_failed?
    refute result.timed_out?
    assert_match(/could not start command/, result.err)
    assert_match(/#{Regexp.escape(bad_dir)}/, result.err)
  end

  def test_timeout_kills_the_child_and_reports_timed_out
    result = Sh.run(["/bin/sleep", "5"], timeout: 0.2)

    assert result.timed_out?
    refute result.success?
  end

  # ADR-0015: #run does not pass pgroup: true, so its child stays in this
  # process's group and a signal aimed at the group - an operator's Ctrl-C,
  # an aborted Bash tool call - still reaches it. If someone adds
  # pgroup: true to #run, this test is the first thing that fails.
  def test_run_leaves_the_child_in_the_callers_process_group
    result = Sh.run(["/bin/sh", "-c", "ps -o pgid= -p $$"])

    assert result.success?
    assert_equal Process.getpgid(0), result.out.strip.to_i
  end

  # The deliberate counterpart to
  # test_run_streaming_on_timeout_kills_the_whole_process_group below: same
  # child-plus-grandchild shape, opposite assertion. #run signals the direct
  # child only, so the grandchild survives. ADR-0015 accepts that gap and
  # names run_streaming as the path for callers that cannot live with it.
  def test_run_on_timeout_kills_the_direct_child_only
    Dir.mktmpdir do |dir|
      pid_file = File.join(dir, "grandchild.pid")
      # The grandchild's stdio is redirected away from the inherited pipe on
      # purpose. A grandchild that keeps holding that pipe also stalls #run
      # past its own timeout, because the reader threads block until the
      # pipe closes - a separate defect this test is not about (ADR-0015's
      # consequences record it).
      script = "sleep 30 >/dev/null 2>&1 & echo $! > #{pid_file}; wait"
      grandchild_pid = nil

      begin
        result = Sh.run(["/bin/bash", "-c", script], timeout: 0.3)

        assert result.timed_out?
        refute result.success?

        grandchild_pid = wait_for_pid_file(pid_file)
        refute_nil grandchild_pid, "grandchild never recorded its pid - test setup broke"

        sleep 0.3
        assert alive?(grandchild_pid),
               "grandchild was reaped - #run appears to have gained process-group semantics (see ADR-0015)"
      ensure
        begin
          Process.kill("KILL", grandchild_pid) if grandchild_pid
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end

  def test_run_records_rendered_command_into_envelope
    env = Envelope.new(script: "example")

    Sh.run(["git", "status"], envelope: env)

    assert_equal ["git status"], env.commands
  end

  def test_render_quotes_arguments_with_shell_metacharacters
    rendered = Sh.render(["echo", "a b", "c;d", "plain"])

    assert_equal "echo 'a b' 'c;d' plain", rendered
  end

  def test_render_wraps_chdir_in_a_subshell_cd
    rendered = Sh.render(["git", "status"], chdir: "/tmp/some dir")

    assert_equal "(cd '/tmp/some dir' && git status)", rendered
  end

  def test_runner_can_be_swapped_for_a_fake
    require_relative "support/fake_sh"
    fake = FakeSh.new
    fake.expect(["git", "status"], out: "clean", exitstatus: 0)
    Sh.runner = fake

    result = Sh.run(["git", "status"])

    assert_equal "clean", result.out
    assert_equal [["git", "status"]], fake.calls.map(&:argv)
  end

  def test_spawn_detached_returns_a_live_pid_and_writes_output_to_out_path
    Dir.mktmpdir do |dir|
      out_path = File.join(dir, "out.log")

      pid = Sh.spawn_detached(["/bin/sh", "-c", "echo hello"], out_path: out_path)

      begin
        _, status = Process.waitpid2(pid)
        assert status.success?
        assert_equal "hello\n", File.read(out_path)
      rescue Errno::ECHILD
        # Process.detach already reaped it - the assertion above on the
        # written file is the meaningful one regardless.
        sleep 0.2
        assert_equal "hello\n", File.read(out_path)
      end
    end
  end

  def test_spawn_detached_starts_its_own_process_group
    Dir.mktmpdir do |dir|
      out_path = File.join(dir, "out.log")

      pid = Sh.spawn_detached(["/bin/sleep", "1"], out_path: out_path)

      assert_equal pid, Process.getpgid(pid)
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
      # already exited before we could kill it - fine, the assertion ran
    end
  end

  def test_spawn_detached_survives_the_caller_continuing_past_the_call
    Dir.mktmpdir do |dir|
      out_path = File.join(dir, "out.log")

      pid = Sh.spawn_detached(["/bin/sh", "-c", "sleep 0.3; echo done"], out_path: out_path)

      # The caller keeps running immediately; spawn_detached does not block
      # on the child the way Sh.run does.
      assert_equal "", File.read(out_path)

      sleep 0.5
      assert_equal "done\n", File.read(out_path)
    rescue Errno::ESRCH
      flunk "spawned process #{pid} was already gone - detached spawn did not outlive the call"
    end
  end

  def test_run_streaming_writes_the_log_incrementally
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "run.log")

      thread = Thread.new do
        Sh.run_streaming(["/bin/sh", "-c", "echo first; sleep 0.4; echo second"], log_path: log_path)
      end

      sleep 0.15
      assert_match(/first/, File.read(log_path))

      result = thread.value
      assert result.success?
      assert_match(/first/, File.read(log_path))
      assert_match(/second/, File.read(log_path))
    end
  end

  def test_run_streaming_returns_a_result_whose_out_is_the_tail
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "run.log")

      result = Sh.run_streaming(["/bin/echo", "-n", "hello"], log_path: log_path)

      assert result.success?
      assert_equal "hello", result.out
      assert_equal "hello", File.read(log_path)
    end
  end

  def test_run_streaming_on_timeout_kills_the_whole_process_group
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "run.log")
      pid_file = File.join(dir, "grandchild.pid")

      # bash -c backgrounds a grandchild sleep and then waits on it. Both
      # bash and the backgrounded sleep share the process group created by
      # pgroup: true, so killing the group (not just bash's own pid) is
      # what's needed to reap the grandchild.
      script = "sleep 30 & echo $! > #{pid_file}; wait"
      result = Sh.run_streaming(["/bin/bash", "-c", script], timeout: 0.3, log_path: log_path)

      assert result.timed_out?
      refute result.success?

      # Give the pid file a moment to land, then confirm the grandchild is
      # actually gone rather than orphaned.
      grandchild_pid = wait_for_pid_file(pid_file)
      refute_nil grandchild_pid, "grandchild never recorded its pid - test setup broke"

      sleep 0.3
      assert_raises(Errno::ESRCH) { Process.kill(0, grandchild_pid) }
    end
  end

  def test_fake_sh_spawn_detached_records_argv_and_returns_a_canned_pid
    require_relative "support/fake_sh"
    fake = FakeSh.new
    Sh.runner = fake

    pid = Sh.spawn_detached(["gate_run.rb", "supervise"], out_path: "/tmp/out.log")

    assert_kind_of Integer, pid
    assert_equal [["gate_run.rb", "supervise"]], fake.detached_calls.map(&:argv)
    assert_equal ["/tmp/out.log"], fake.detached_calls.map(&:out_path)
  end

  def test_fake_sh_run_streaming_matches_an_expectation_and_writes_the_log
    require_relative "support/fake_sh"
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "run.log")
      fake = FakeSh.new
      fake.expect(["make", "quality"], out: "ok", exitstatus: 0, log: "line one\nline two\n")
      Sh.runner = fake

      result = Sh.run_streaming(["make", "quality"], log_path: log_path)

      assert_equal "ok", result.out
      assert_equal "line one\nline two\n", File.read(log_path)
      assert_equal [["make", "quality"]], fake.calls.map(&:argv)
    end
  end

  def test_fake_sh_run_streaming_raises_on_an_unexpected_command
    require_relative "support/fake_sh"
    fake = FakeSh.new
    Sh.runner = fake

    assert_raises(FakeSh::UnexpectedCommand) do
      Sh.run_streaming(["make", "quality"], log_path: "/tmp/whatever.log")
    end
  end

  private

  # Polls for the pid a backgrounded grandchild writes to pid_file. Returns
  # the pid, or nil if the file never lands within the deadline.
  def wait_for_pid_file(pid_file, deadline_seconds: 2)
    deadline = Time.now + deadline_seconds
    while Time.now < deadline
      return File.read(pid_file).strip.to_i if File.exist?(pid_file) && !File.zero?(pid_file)

      sleep 0.05
    end
    nil
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end

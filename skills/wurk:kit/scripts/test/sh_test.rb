# frozen_string_literal: true

require "minitest/autorun"
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
end

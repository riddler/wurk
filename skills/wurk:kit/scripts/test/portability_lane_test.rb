# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../portability_lane"
require_relative "support/fake_sh"

# The Linux /bin/sh portability lane (wu-5yo).
#
# Everything here runs against FakeSh and starts no container, because this
# file IS part of the default gate and the default gate must stay
# stdlib-only system Ruby, must pass on a machine with no container runtime
# and no network, and must keep its measured duration. The one test that
# really runs the lane is opt-in and reports itself as a skip otherwise -
# see test_the_lane_itself, which is also the acceptance criterion's
# "reports the lane as skipped, naming why".
class PortabilityLaneTest < Minitest::Test
  GREEN_OUTPUT = <<~OUT
    #{PortabilityLane::SH_MARKER} GNU bash, version 5.2.15(1)-release (aarch64-unknown-linux-gnu)
    Run options: --seed 1

    # Running:

    ................

    Finished in 0.263966s, 60.6138 runs/s, 526.5828 assertions/s.

    16 runs, 139 assertions, 0 failures, 0 errors, 0 skips
  OUT

  RED_OUTPUT = <<~OUT
    #{PortabilityLane::SH_MARKER} GNU bash, version 5.2.15(1)-release (aarch64-unknown-linux-gnu)
    Run options: --seed 1

    # Running:

    ...F............

    Failure:
    HooksTest#test_malformed_input_is_ignored_and_prints_nothing:
    Expected: ""
      Actual: "bash: warning: command substitution: ignored null byte in input\\n"

    16 runs, 139 assertions, 1 failures, 0 errors, 0 skips
  OUT

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
  end

  def lane(argv = [])
    io = StringIO.new
    code = PortabilityLane.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  # The probes the happy path always makes before the run: the daemon
  # answers, and the image is already local so nothing is pulled.
  def expect_runtime_and_local_image
    @fake.expect(%w[docker version], out: "29.6.1\n")
    @fake.expect(%w[docker image inspect])
  end

  # --- pure helpers ----------------------------------------------------------

  # sabotage: make parse_sh_version match any "version N.M" line -> the
  # minitest banner or a stray dependency version would satisfy the bash
  # floor and this goes red on the no-marker case.
  def test_parse_sh_version_reads_only_the_lane_marker_line
    assert_equal [5, 2], PortabilityLane.parse_sh_version(GREEN_OUTPUT)
    assert_nil PortabilityLane.parse_sh_version("GNU bash, version 5.2.15(1)-release\n")
    assert_nil PortabilityLane.parse_sh_version("#{PortabilityLane::SH_MARKER} not a shell at all\n")
    assert_nil PortabilityLane.parse_sh_version("")
  end

  # The floor is the whole point of the lane: bash 3.2.57 is what macOS
  # /bin/sh is, and a lane running under it would be green for exactly the
  # reason the lane exists.
  #
  # sabotage: compare only the major version -> 4.0 and 3.2 read as modern
  # and this goes red.
  def test_modern_bash_accepts_the_floor_and_above_and_rejects_below_it
    assert PortabilityLane.modern_bash?([4, 4])
    assert PortabilityLane.modern_bash?([4, 5])
    assert PortabilityLane.modern_bash?([5, 2])
    refute PortabilityLane.modern_bash?([4, 3])
    refute PortabilityLane.modern_bash?([3, 2])
    refute PortabilityLane.modern_bash?(nil)
  end

  # sabotage: drop the ":ro" from the mount -> red. The repo is mounted
  # read-only so a container running as root cannot write into the
  # operator's checkout.
  def test_run_argv_mounts_the_repo_read_only_and_passes_the_test_path_as_an_argument
    argv = PortabilityLane.run_argv(runtime: "docker", root: "/repos/wurk", image: "img:1",
                                    test: "a/b_test.rb")

    assert_includes argv, "/repos/wurk:/repo:ro"
    assert_equal %w[-w /repo], argv[argv.index("-w"), 2]
    assert_equal "a/b_test.rb", argv.last, "the test path is the container script's $1"
    refute_includes PortabilityLane::CONTAINER_SCRIPT, "a/b_test.rb",
                    "the test path must not be interpolated into the shell script"
    assert_includes PortabilityLane::CONTAINER_SCRIPT, "ln -sf /bin/bash /bin/sh"
  end

  # runtime_on_path? is what the default suite's own skip reason keys off,
  # so it must answer from the filesystem and start no process at all.
  #
  # sabotage: implement it by shelling out through Sh -> FakeSh raises
  # UnexpectedCommand and this goes red.
  def test_runtime_on_path_is_a_filesystem_lookup_and_starts_no_process
    Dir.mktmpdir("wurk-lane-path-") do |dir|
      exe = File.join(dir, "faketool")
      File.write(exe, "#!/bin/sh\n")
      FileUtils.chmod(0o755, exe)

      with_path(dir) do
        assert PortabilityLane.runtime_on_path?("faketool")
        refute PortabilityLane.runtime_on_path?("nosuchtool")
      end
    end
    assert_empty @fake.calls
  end

  # --- the skip contract -----------------------------------------------------

  # The hard constraint from the bead: a missing runtime is a reported skip,
  # never a red gate.
  #
  # sabotage: report the missing runtime with block! or fail! instead of a
  # warning -> exit code 1 and this goes red.
  def test_a_missing_container_runtime_is_a_named_skip_and_still_ok
    @fake.expect(%w[docker version], start_failed: true)

    code, env = lane

    assert_equal 0, code
    assert env["ok"]
    assert_equal "skipped", env["data"]["status"]
    assert_equal "runtime_missing", env["data"]["skip_code"]
    assert_equal "runtime_missing", env["warnings"].first["code"]
    assert_includes env["data"]["skip_reason"], "docker"
    assert_empty env["blocked"]
  end

  # An installed binary whose daemon is not running is a different machine
  # state from having no runtime at all, and a caller must be able to tell
  # them apart from the envelope without reading prose.
  #
  # sabotage: collapse the two probes into one skip code -> red.
  def test_an_installed_runtime_whose_daemon_is_down_is_its_own_skip_code
    @fake.expect(%w[docker version], err: "Cannot connect to the Docker daemon", exitstatus: 1)

    code, env = lane

    assert_equal 0, code
    assert_equal "runtime_unavailable", env["data"]["skip_code"]
    assert_includes env["data"]["skip_reason"], "Cannot connect to the Docker daemon"
  end

  # The no-network case: the image is not local and cannot be pulled. The
  # lane could not be exercised, which is not the same claim as the lane
  # having found a regression - so it is a skip, and nothing is run.
  #
  # sabotage: treat a failed pull as a lane failure -> exit 1 and this goes
  # red.
  def test_an_image_that_cannot_be_pulled_is_a_skip_and_the_lane_does_not_run
    @fake.expect(%w[docker version], out: "29.6.1\n")
    @fake.expect(%w[docker image inspect], exitstatus: 1)
    @fake.expect(%w[docker pull], err: "dial tcp: lookup registry: no such host", exitstatus: 1)

    code, env = lane

    assert_equal 0, code
    assert env["ok"]
    assert_equal "image_unavailable", env["data"]["skip_code"]
    assert_includes env["data"]["skip_reason"], "no network"
    refute_includes @fake.calls.map { |c| c.argv[1] }, "run"
  end

  # sabotage: pull unconditionally instead of inspecting first -> the
  # already-local case makes a network call and this goes red on the
  # image_pulled assertion.
  def test_a_local_image_is_used_without_a_pull
    expect_runtime_and_local_image
    @fake.expect(%w[docker run], out: GREEN_OUTPUT)

    _code, env = lane

    assert_equal false, env["data"]["image_pulled"]
    refute_includes @fake.calls.map { |c| c.argv[1] }, "pull"
  end

  # --- the run itself --------------------------------------------------------

  # sabotage: set status from the marker alone rather than the exit status
  # -> a red container run reads as passed and this goes red.
  def test_a_green_container_run_passes_and_records_what_shell_it_ran_under
    expect_runtime_and_local_image
    @fake.expect(%w[docker run], out: GREEN_OUTPUT)

    code, env = lane

    assert_equal 0, code
    assert env["ok"]
    assert_equal "passed", env["data"]["status"]
    assert_equal "5.2", env["data"]["sh_version"]
    assert_equal "29.6.1", env["data"]["runtime_version"]
  end

  # The watch-it-fail path. The output is the evidence the lane produces,
  # so it is carried whole - the gate contract's never-truncate rule.
  #
  # sabotage: truncate data.output to a tail, or drop stderr from it -> red.
  def test_a_failing_container_run_fails_the_lane_and_keeps_the_whole_output
    expect_runtime_and_local_image
    @fake.expect(%w[docker run], out: RED_OUTPUT, err: "exit status 1\n", exitstatus: 1)

    code, env = lane

    assert_equal 1, code
    refute env["ok"]
    assert_equal "failed", env["data"]["status"]
    assert_includes env["data"]["output"], "ignored null byte in input"
    assert_includes env["data"]["output"], "exit status 1"
    assert_equal RED_OUTPUT + "exit status 1\n", env["data"]["output"]
  end

  # The blind spot, guarded: an image whose /bin/sh is bash 3.2 (or dash,
  # or anything unparsable) reproduces the macOS gap, so a green run under
  # it must never read as a pass. Exit status 0 on purpose here - that is
  # the whole trap.
  #
  # sabotage: check the exit status before the shell version, or skip the
  # version check when the run passed -> red.
  def test_a_green_run_under_an_old_bin_sh_is_blocked_not_passed
    expect_runtime_and_local_image
    @fake.expect(%w[docker run],
                 out: "#{PortabilityLane::SH_MARKER} GNU bash, version 3.2.57(1)-release\n0 failures\n")

    code, env = lane

    assert_equal 1, code
    assert_equal "sh_not_modern_bash", env["blocked"].first["code"]
    assert_equal "failed", env["data"]["status"]
    assert_includes env["blocked"].first["message"], "4.4"
  end

  # sabotage: report a timeout as an ordinary failure -> the "timeout"
  # status disappears and this goes red. A lane that ran out of budget did
  # not measure anything, and says so in its own word.
  def test_a_timed_out_run_is_reported_as_a_timeout
    expect_runtime_and_local_image
    @fake.expect(%w[docker run], out: "", timed_out: true)

    code, env = lane

    assert_equal 1, code
    assert_equal "timeout", env["data"]["status"]
    assert_equal "lane_timed_out", env["warnings"].first["code"]
  end

  # sabotage: let --dry-run fall through to the probes -> FakeSh records
  # calls and this goes red.
  def test_dry_run_renders_the_command_and_starts_nothing
    code, env = lane(["--dry-run"])

    assert_equal 0, code
    assert_equal "dry_run", env["data"]["status"]
    assert_includes env["commands"].first, "docker run --rm"
    assert_empty @fake.calls
  end

  # sabotage: drop the existence check -> a typo'd --test spends a pull and
  # a container run before failing inside the container, and this goes red
  # on the empty-calls assertion.
  def test_a_missing_test_file_blocks_before_touching_the_runtime
    code, env = lane(["--test", "no/such_test.rb"])

    assert_equal 1, code
    assert_equal "test_file_missing", env["blocked"].first["code"]
    assert_empty @fake.calls
  end

  # sabotage: hardcode the image or the test path in run_argv -> red.
  def test_the_image_and_subject_are_overridable
    @fake.expect(%w[podman version], out: "5.0.0\n")
    @fake.expect(%w[podman image inspect])
    @fake.expect(%w[podman run], out: GREEN_OUTPUT)

    _code, env = lane(["--runtime", "podman", "--image", "other:2",
                       "--test", "skills/wurk:kit/scripts/test/hooks_test.rb"])

    assert_equal "other:2", env["data"]["image"]
    assert_equal "podman", env["data"]["runtime"]
    run_call = @fake.calls.find { |c| c.argv[1] == "run" }
    assert_includes run_call.argv, "other:2"
  end

  # --- the lane, for real ----------------------------------------------------

  # The opt-in integration run, and the default gate's report of the lane.
  #
  # It is skipped by default and the skip names why, which is what the
  # acceptance criterion asks the default gate to report on a machine with
  # no container runtime. Opt in with:
  #
  #   WURK_PORTABILITY_LANE=1 /usr/bin/ruby skills/wurk:kit/scripts/test/run.rb -n /the_lane_itself/
  #
  # Run directly, the lane is skills/wurk:kit/scripts/portability_lane.rb.
  #
  # sabotage: make this test run the container unconditionally -> the
  # default gate grows a container pull, its duration moves, and it goes
  # red on a machine with no runtime. That is the failure this shape exists
  # to prevent, so the guard is the assertion.
  def test_the_lane_itself
    unless PortabilityLane.runtime_on_path?
      skip "portability lane skipped: no container runtime (docker) on PATH - " \
           "the lane needs one, the default gate does not (see docs/gate-contract.md)"
    end

    unless ENV["WURK_PORTABILITY_LANE"] == "1"
      skip "portability lane skipped: opt-in only - set WURK_PORTABILITY_LANE=1 to run it, " \
           "since a container pull does not belong in the default gate's duration " \
           "(see docs/gate-contract.md)"
    end

    Sh.runner = nil
    io = StringIO.new
    code = PortabilityLane.run([], io: io)
    env = JSON.parse(io.string)

    assert_equal 0, code, "the portability lane was not ok: #{io.string}"
    refute_equal "failed", env["data"]["status"]
  end

  private

  def with_path(dir)
    original = ENV["PATH"]
    ENV["PATH"] = dir
    yield
  ensure
    ENV["PATH"] = original
  end
end

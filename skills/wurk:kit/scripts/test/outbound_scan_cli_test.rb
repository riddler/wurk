# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../outbound_scan"
require_relative "support/fake_sh"
require_relative "support/user_config_helper"

# Phase 3 coverage for outbound_scan.rb: the CLI wrapper (`status`, `scan`,
# `git-refs`) driven end to end through FakeSh and an injected stdin. Every
# fixture token and pattern here is invented nonsense (see
# outbound_scan_test.rb's header) - that discipline is itself the property
# the process-table-invariant test below is checking mechanically.
class OutboundScanCliTest < Minitest::Test
  include UserConfigHelper

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
    UserConfig.reset!
  end

  def run_cli(argv, stdin_text: "")
    io = StringIO.new
    stdin = StringIO.new(stdin_text)
    code = OutboundScanCli.run(argv, io: io, stdin: stdin)
    [code, JSON.parse(io.string)]
  end

  def armed_config(patterns_path, control_term)
    { "outbound_scan" => { "patterns_file" => patterns_path, "control_term" => control_term } }
  end

  def write_patterns(dir, content)
    path = File.join(dir, "patterns.txt")
    File.write(path, content)
    path
  end

  # --- status -------------------------------------------------------------

  # sabotage: default armed to true when the section is absent, or exit
  # nonzero on the disarmed path -> red
  def test_status_exits_0_and_reports_armed_false_when_disarmed
    with_user_config(nil) do
      code, body = run_cli(["status"])
      assert_equal 0, code
      assert_equal false, body["data"]["armed"]
      assert_equal ["outbound_scan_disarmed"], body["warnings"].map { |w| w["code"] }
    end
  end

  def test_status_reports_patterns_count_without_listing_them
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, "zqiblorf-control-1\nzqiblorf-secret-2\nzqiblorf-secret-3")
      with_user_config(armed_config(path, "zqiblorf-control-1")) do
        code, body = run_cli(["status"])
        assert_equal 0, code
        assert_equal true, body["data"]["armed"]
        assert_equal true, body["data"]["probe_ok"]
        assert_equal 3, body["data"]["patterns_count"]
        refute_includes body.to_json, "zqiblorf-secret"
      end
    end
  end

  def test_status_exits_1_when_armed_and_broken
    with_user_config("outbound_scan" => { "patterns_file" => "/nonexistent/zqiblorf.txt" }) do
      code, body = run_cli(["status"])
      assert_equal 1, code
      assert_equal true, body["data"]["armed"]
      assert_equal ["scan_config_incomplete"], body["blocked"].map { |b| b["code"] }
    end
  end

  # --- scan -----------------------------------------------------------------

  def test_scan_stdin_clean_payload_exits_0
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, "zqiblorf-control-1\nzqiblorf-secret")
      with_user_config(armed_config(path, "zqiblorf-control-1")) do
        code, body = run_cli(["scan", "--stdin"], stdin_text: "nothing guarded in here")
        assert_equal 0, code
        assert_empty body["data"]["outbound_scan"]["hits"]
        assert_empty body["blocked"]
      end
    end
  end

  # sabotage: report the wrong location label for a --file scan -> red
  def test_scan_file_hit_blocks_and_reports_file_path_as_location
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, "zqiblorf-control-1\nzqiblorf-secret")
      target = File.join(dir, "outbound.txt")
      File.write(target, "leading zqiblorf-secret trailing")
      with_user_config(armed_config(path, "zqiblorf-control-1")) do
        code, body = run_cli(["scan", "--file", target])
        assert_equal 1, code
        hits = body["data"]["outbound_scan"]["hits"]
        assert_equal 1, hits.length
        assert_equal target, hits.first["location"]
      end
    end
  end

  def test_scan_requires_exactly_one_of_file_or_stdin
    capture_stderr do
      exc = assert_raises(SystemExit) { run_cli(["scan"]) }
      assert_equal 2, exc.status
    end
  end

  # install is Phase 4's subcommand - see outbound_scan_install_test.rb for
  # its coverage. It is still a dispatched subcommand (not a usage error) as
  # of Phase 4, which is the property test_dispatches_every_known_subcommand
  # over in that file checks.

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  # --- git-refs: argv shape -------------------------------------------------

  DELETE_LINE = "refs/heads/gone #{OutboundScanCli::NULL_SHA} refs/heads/gone deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n"

  def test_git_refs_issues_rev_list_diff_tree_cat_file_and_log_with_expected_argv
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, "zqiblorf-control-1")
      local_sha = "1111111111111111111111111111111111111a"
      remote_sha = "2222222222222222222222222222222222222b"
      blob_sha = "3333333333333333333333333333333333333c"

      @fake.expect(["git", "rev-list", local_sha, "--not", "--remotes=origin"], out: "#{local_sha}\n")
      @fake.expect(
        ["git", "diff-tree", "-r", "--no-commit-id", "--root", "--no-renames", "--diff-filter=AM", "--raw", local_sha],
        out: ":100644 100644 0000000000000000000000000000000000000000 #{blob_sha} A\tfile/a.txt\n"
      )
      @fake.expect(["git", "cat-file", "blob", blob_sha], out: "clean content")
      @fake.expect(["git", "log", "--format=%B%x00", "--no-walk=unsorted", local_sha], out: "a message\x00")

      with_user_config(armed_config(path, "zqiblorf-control-1")) do
        code, body = run_cli(
          ["git-refs", "--remote", "origin"],
          stdin_text: "refs/heads/main #{local_sha} refs/heads/main #{remote_sha}\n"
        )
        assert_equal 0, code
        assert_equal 1, body["data"]["objects_scanned"]
        assert_equal 1, body["data"]["commits_scanned"]
      end

      argvs = @fake.calls.map(&:argv)
      assert_includes argvs, ["git", "rev-list", local_sha, "--not", "--remotes=origin"]
      assert_includes argvs, ["git", "diff-tree", "-r", "--no-commit-id", "--root", "--no-renames",
                               "--diff-filter=AM", "--raw", local_sha]
      assert_includes argvs, ["git", "cat-file", "blob", blob_sha]
      assert_includes argvs, ["git", "log", "--format=%B%x00", "--no-walk=unsorted", local_sha]
    end
  end

  # sabotage: stop skipping a deletion ref line -> red (an unexpected
  # rev-list call for the all-zero local sha would raise FakeSh::UnexpectedCommand)
  def test_a_deletion_ref_line_is_skipped_entirely
    with_user_config(nil) do
      code, body = run_cli(["git-refs", "--remote", "origin"], stdin_text: DELETE_LINE)
      assert_equal 0, code
      assert_empty @fake.calls
      assert_equal 0, body["data"]["commits_scanned"]
    end
  end

  # sabotage: special-case the all-zero remote sha instead of always issuing
  # the same --not --remotes=<remote> rev-list -> red
  def test_all_zero_remote_sha_still_issues_not_remotes_rev_list
    local_sha = "4444444444444444444444444444444444444d"
    @fake.expect(["git", "rev-list", local_sha, "--not", "--remotes=origin"], out: "")

    with_user_config(nil) do
      code, = run_cli(
        ["git-refs", "--remote", "origin"],
        stdin_text: "refs/heads/new-branch #{local_sha} refs/heads/new-branch #{OutboundScanCli::NULL_SHA}\n"
      )
      assert_equal 0, code
    end

    assert_equal [["git", "rev-list", local_sha, "--not", "--remotes=origin"]], @fake.calls.map(&:argv)
  end

  # sabotage: cat-file once per commit instead of once per distinct blob sha
  # -> red (a second unexpected cat-file call would raise
  # FakeSh::UnexpectedCommand, since only one expectation is registered)
  def test_duplicate_blob_shas_across_commits_produce_one_cat_file_call
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, "zqiblorf-control-1")
      sha1 = "5555555555555555555555555555555555555e"
      sha2 = "6666666666666666666666666666666666666f"
      blob_sha = "7777777777777777777777777777777777777a"

      @fake.expect(["git", "rev-list", sha1, "--not", "--remotes=origin"], out: "#{sha1}\n#{sha2}\n")
      @fake.expect(
        ["git", "diff-tree", "-r", "--no-commit-id", "--root", "--no-renames", "--diff-filter=AM", "--raw", sha1],
        out: ":100644 100644 0000000000000000000000000000000000000000 #{blob_sha} A\tfile/a.txt\n"
      )
      @fake.expect(
        ["git", "diff-tree", "-r", "--no-commit-id", "--root", "--no-renames", "--diff-filter=AM", "--raw", sha2],
        out: ":100644 100644 0000000000000000000000000000000000000000 #{blob_sha} M\tfile/a.txt\n"
      )
      @fake.expect(["git", "cat-file", "blob", blob_sha], out: "clean content")
      @fake.expect(["git", "log", "--format=%B%x00", "--no-walk=unsorted", sha1, sha2], out: "m1\x00m2\x00")

      with_user_config(armed_config(path, "zqiblorf-control-1")) do
        code, body = run_cli(
          ["git-refs", "--remote", "origin"],
          stdin_text: "refs/heads/main #{sha1} refs/heads/main deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n"
        )
        assert_equal 0, code
        assert_equal 1, body["data"]["objects_scanned"]
      end

      cat_file_calls = @fake.calls.select { |c| c.argv[0, 2] == %w[git cat-file] }
      assert_equal 1, cat_file_calls.length
    end
  end

  # --- git-refs: refusals ----------------------------------------------------

  def test_a_hit_in_blob_content_blocks_and_exits_1
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, "zqiblorf-control-1\nzqiblorf-secret")
      local_sha = "8888888888888888888888888888888888888b"
      blob_sha = "9999999999999999999999999999999999999c"

      @fake.expect(["git", "rev-list", local_sha, "--not", "--remotes=origin"], out: "#{local_sha}\n")
      @fake.expect(
        ["git", "diff-tree", "-r", "--no-commit-id", "--root", "--no-renames", "--diff-filter=AM", "--raw", local_sha],
        out: ":100644 100644 0000000000000000000000000000000000000000 #{blob_sha} A\tfile/a.txt\n"
      )
      @fake.expect(["git", "cat-file", "blob", blob_sha], out: "leading zqiblorf-secret trailing")
      @fake.expect(["git", "log", "--format=%B%x00", "--no-walk=unsorted", local_sha], out: "clean message\x00")

      with_user_config(armed_config(path, "zqiblorf-control-1")) do
        code, body = run_cli(
          ["git-refs", "--remote", "origin"],
          stdin_text: "refs/heads/main #{local_sha} refs/heads/main deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n"
        )
        assert_equal 1, code
        assert_equal ["outbound_scan_hit"], body["blocked"].map { |b| b["code"] }
        hit_locations = body["data"]["outbound_scan"]["hits"].map { |h| h["location"] }
        assert_equal ["blob:#{blob_sha[0, 7]}:file/a.txt"], hit_locations
      end
    end
  end

  def test_a_hit_in_a_commit_message_blocks
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, "zqiblorf-control-1\nzqiblorf-secret")
      local_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

      @fake.expect(["git", "rev-list", local_sha, "--not", "--remotes=origin"], out: "#{local_sha}\n")
      @fake.expect(
        ["git", "diff-tree", "-r", "--no-commit-id", "--root", "--no-renames", "--diff-filter=AM", "--raw", local_sha],
        out: ""
      )
      @fake.expect(
        ["git", "log", "--format=%B%x00", "--no-walk=unsorted", local_sha],
        out: "message with zqiblorf-secret inside\x00"
      )

      with_user_config(armed_config(path, "zqiblorf-control-1")) do
        code, body = run_cli(
          ["git-refs", "--remote", "origin"],
          stdin_text: "refs/heads/main #{local_sha} refs/heads/main deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n"
        )
        assert_equal 1, code
        hit_locations = body["data"]["outbound_scan"]["hits"].map { |h| h["location"] }
        assert_equal ["commit-message:#{local_sha[0, 7]}"], hit_locations
      end
    end
  end

  def test_a_hit_in_a_ref_name_blocks
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, "zqiblorf-control-1\nzqiblorf-secret")
      local_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

      @fake.expect(["git", "rev-list", local_sha, "--not", "--remotes=origin"], out: "")

      with_user_config(armed_config(path, "zqiblorf-control-1")) do
        code, body = run_cli(
          ["git-refs", "--remote", "origin"],
          stdin_text: "refs/heads/zqiblorf-secret-branch #{local_sha} refs/heads/zqiblorf-secret-branch " \
                       "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n"
        )
        assert_equal 1, code
        hit_locations = body["data"]["outbound_scan"]["hits"].map { |h| h["location"] }
        assert_equal ["ref-name", "ref-name"], hit_locations
      end
    end
  end

  def test_a_clean_push_exits_0
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, "zqiblorf-control-1\nzqiblorf-secret")
      local_sha = "cccccccccccccccccccccccccccccccccccccccc"[0, 40]

      @fake.expect(["git", "rev-list", local_sha, "--not", "--remotes=origin"], out: "#{local_sha}\n")
      @fake.expect(
        ["git", "diff-tree", "-r", "--no-commit-id", "--root", "--no-renames", "--diff-filter=AM", "--raw", local_sha],
        out: ":100644 100644 0000000000000000000000000000000000000000 dddddddddddddddddddddddddddddddddddddddd A\tfile/a.txt\n"
      )
      @fake.expect(["git", "cat-file", "blob", "dddddddddddddddddddddddddddddddddddddddd"], out: "clean content")
      @fake.expect(["git", "log", "--format=%B%x00", "--no-walk=unsorted", local_sha], out: "clean message\x00")

      with_user_config(armed_config(path, "zqiblorf-control-1")) do
        code, body = run_cli(
          ["git-refs", "--remote", "origin"],
          stdin_text: "refs/heads/main #{local_sha} refs/heads/main deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n"
        )
        assert_equal 0, code
        assert_empty body["blocked"]
      end
    end
  end

  # --- the process-table invariant, made mechanical --------------------------
  #
  # No Sh.run argv anywhere may contain pattern text or matched secret text -
  # the process table is readable by other users on the machine. This test
  # walks every recorded FakeSh call across the whole hit-producing git-refs
  # run above and asserts none of them carry the fixture token.
  #
  # sabotage: pass pattern text or matched text as an argv element to any
  # git invocation -> red
  def test_no_sh_run_argv_ever_contains_the_fixture_pattern_token
    Dir.mktmpdir do |dir|
      token = "zqorbex-secret-fixture-7723"
      path = write_patterns(dir, "zqorbex-control-1\n#{token}")
      local_sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      blob_sha = "ffffffffffffffffffffffffffffffffffffffff"[0, 40]

      @fake.expect(["git", "rev-list", local_sha, "--not", "--remotes=origin"], out: "#{local_sha}\n")
      @fake.expect(
        ["git", "diff-tree", "-r", "--no-commit-id", "--root", "--no-renames", "--diff-filter=AM", "--raw", local_sha],
        out: ":100644 100644 0000000000000000000000000000000000000000 #{blob_sha} A\tfile/#{token}.txt\n"
      )
      @fake.expect(["git", "cat-file", "blob", blob_sha], out: "leading #{token} trailing")
      @fake.expect(["git", "log", "--format=%B%x00", "--no-walk=unsorted", local_sha], out: "message #{token}\x00")

      with_user_config(armed_config(path, "zqorbex-control-1")) do
        code, body = run_cli(
          ["git-refs", "--remote", "origin"],
          stdin_text: "refs/heads/#{token} #{local_sha} refs/heads/#{token} deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n"
        )
        assert_equal 1, code
        refute_empty body["blocked"]
      end

      @fake.calls.each do |call|
        call.argv.each do |arg|
          refute_includes arg.to_s, token, "Sh.run argv leaked the fixture token: #{call.argv.inspect}"
        end
      end
    end
  end
end

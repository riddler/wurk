# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../report_check"
require_relative "support/home_guard"

# Every fixture here is written into a tmpdir by the test itself. This repo's
# own .claude/campaigns is live state for whatever campaign is running while
# the suite runs, and it is git-excluded besides, so no test ever reads a
# real report - the shapes below are synthetic copies of the four that were
# found, not the files themselves.
module ReportFixtures
  GOOD = { "bead" => "zz-1", "status" => "complete", "gate" => "green" }.freeze

  def bare(dir, id, payload = GOOD)
    write(dir, id, "#{JSON.pretty_generate(payload)}\n")
  end

  # The three fenced files that were found: a line reading "json" after a
  # fence opener, the JSON, then a closing fence.
  def fenced(dir, id, payload = GOOD)
    fence = "```"
    write(dir, id, "#{fence}json\n#{JSON.pretty_generate(payload)}\n#{fence}\n")
  end

  # The fourth: a prose H1 above the fence.
  def prose_preamble(dir, id, payload = GOOD)
    fence = "```"
    write(dir, id, "# #{id} worker report (2026-09-14)\n\n#{fence}json\n#{JSON.pretty_generate(payload)}\n#{fence}\n")
  end

  def write(dir, id, content)
    path = File.join(dir, "#{id}-report.json")
    File.write(path, content)
    path
  end

  def run_check(*args)
    io = StringIO.new
    code = ReportCheckCli.run(args, io: io)
    [JSON.parse(io.string), code]
  end

  def codes(envelope, key)
    envelope[key].map { |entry| entry["code"] }
  end
end

class ReportCheckTest < Minitest::Test
  include ReportFixtures

  # sabotage: return "bare" from ReportCheck.shape for a fenced document ->
  # red (the message asserts "markdown code fence" and got "its JSON itself
  # is malformed"); and drop the block! call entirely -> red (blocked is
  # empty, exit 0)
  def test_blocks_on_a_fenced_worker_report
    Dir.mktmpdir do |dir|
      path = fenced(dir, "zz-cvi")
      envelope, code = run_check(dir)

      assert_equal 1, code
      refute envelope["ok"]
      assert_equal ["report_not_json"], codes(envelope, "blocked")
      message = envelope["blocked"].first["message"]
      assert_includes message, path
      assert_includes message, "markdown code fence"
      assert_includes message, "Fix: have the worker re-emit the report as bare JSON"
      assert_equal "human", envelope["blocked"].first["needs"]
      assert_equal [path], envelope["data"]["unparseable"]
    end
  end

  # sabotage: make ReportCheck.shape return "fenced" whenever the document
  # contains a fence anywhere rather than on its first non-blank line -> red
  # (this report opens with prose and the message then claims a fence)
  def test_blocks_on_an_h1_prose_preamble_worker_report
    Dir.mktmpdir do |dir|
      path = prose_preamble(dir, "zz-yi7.11")
      envelope, code = run_check(dir)

      assert_equal 1, code
      assert_equal ["report_not_json"], codes(envelope, "blocked")
      assert_includes envelope["blocked"].first["message"], "it opens with prose, not JSON"
      assert_includes envelope["blocked"].first["message"], "Fix:"
      assert_equal [path], envelope["data"]["unparseable"]
    end
  end

  # sabotage: block! on every report instead of only the unparseable ones ->
  # red (ok is false and blocked carries report_not_json for a file that
  # parses)
  def test_passes_a_bare_json_worker_report
    Dir.mktmpdir do |dir|
      bare(dir, "zz-ok1")
      bare(dir, "zz-ok2")
      envelope, code = run_check(dir)

      assert_equal 0, code
      assert envelope["ok"]
      assert_empty envelope["blocked"]
      assert_empty envelope["data"]["unparseable"]
      assert_equal 2, envelope["data"]["checked"]
    end
  end

  # sabotage: stop at the first unparseable report instead of judging every
  # one -> red (only one blocked entry for a directory holding two bad files)
  def test_sweeps_a_whole_reports_dir_and_names_every_bad_file
    Dir.mktmpdir do |dir|
      bad_fence = fenced(dir, "zz-cvi")
      bad_prose = prose_preamble(dir, "zz-yi7.11")
      bare(dir, "zz-ok1")
      envelope, code = run_check(dir)

      assert_equal 1, code
      assert_equal 2, envelope["blocked"].length
      assert_equal [bad_fence, bad_prose].sort, envelope["data"]["unparseable"].sort
      assert_equal 3, envelope["data"]["checked"]
    end
  end

  # sabotage: glob "*.json" instead of "*-report.json" -> red (the campaign's
  # own state.json is picked up and blocks)
  def test_sweeps_only_the_per_bead_report_file_name
    Dir.mktmpdir do |dir|
      bare(dir, "zz-ok1")
      File.write(File.join(dir, "state.json"), "not json at all\n")
      File.write(File.join(dir, "zz-ok1-report.md"), "# morning report\n")
      envelope, code = run_check(dir)

      assert_equal 0, code
      assert_equal 1, envelope["data"]["checked"]
    end
  end

  # sabotage: accept a directly named file only when it matches the glob ->
  # red (the named path is never inspected and blocked comes back empty)
  def test_checks_a_single_report_file_named_directly
    Dir.mktmpdir do |dir|
      path = fenced(dir, "zz-cvi")
      envelope, code = run_check(path)

      assert_equal 1, code
      assert_equal [path], envelope["data"]["unparseable"]
    end
  end

  # sabotage: block! instead of warn on a report that is not there yet -> red
  # (a bead still in flight fails the sweep, exit 1 instead of 0)
  def test_a_report_not_written_yet_warns_rather_than_blocks
    Dir.mktmpdir do |dir|
      envelope, code = run_check(File.join(dir, "zz-later-report.json"))

      assert_equal 0, code
      assert_equal ["report_missing"], codes(envelope, "warnings")
      assert_empty envelope["blocked"]
    end
  end

  # sabotage: treat a missing directory the same as an empty one -> red (the
  # warning code is no_reports, not reports_path_missing)
  def test_a_missing_reports_dir_and_an_empty_one_warn_differently
    Dir.mktmpdir do |dir|
      missing, = run_check(File.join(dir, "nope"))
      assert_equal ["reports_path_missing"], codes(missing, "warnings")

      empty, code = run_check(dir)
      assert_equal 0, code
      assert_equal ["no_reports"], codes(empty, "warnings")
    end
  end

  # sabotage: rescue the fence and parse the JSON inside it -> red (the
  # tolerant read reports parsed: true and nothing blocks, which is exactly
  # how the shape would spread)
  def test_a_fenced_report_is_never_rescued_into_json
    Dir.mktmpdir do |dir|
      path = fenced(dir, "zz-cvi")
      report = ReportCheck.inspect_report(path)

      refute report[:parsed]
      assert_equal "fenced", report[:shape]
      refute_nil report[:error]
    end
  end

  # sabotage: report "fenced" for an empty file -> red (shape is asserted as
  # "empty", and a truncated write is a different fix from a fence)
  def test_an_empty_or_truncated_report_is_diagnosed_as_itself
    Dir.mktmpdir do |dir|
      empty = write(dir, "zz-empty", "")
      truncated = write(dir, "zz-cut", "{\n  \"bead\": \"zz-cut\",\n")

      assert_equal "empty", ReportCheck.inspect_report(empty)[:shape]
      assert_equal "bare", ReportCheck.inspect_report(truncated)[:shape]

      envelope, code = run_check(dir)
      assert_equal 1, code
      assert_equal 2, envelope["blocked"].length
      assert_includes envelope["blocked"].map { |b| b["message"] }.join("\n"), "it is empty"
    end
  end
end

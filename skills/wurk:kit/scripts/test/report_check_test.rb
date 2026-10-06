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

  COUNTS = { "mustFix" => 1, "shouldFix" => 0, "note" => 2, "unranked" => 0 }.freeze

  def with_review(counts)
    review = { "agents" => ["wurk-diff-critic"], "findings" => 3, "mustFix" => 1,
               "addressed" => 1, "deferred" => [] }
    review["findingsByLevel"] = counts unless counts == :absent
    GOOD.merge("reviewRound" => review)
  end

  # sabotage: require reviewRound.findingsByLevel, or check it when
  # reviewRound is null -> red (a report on the old template, or with no
  # round, would warn or block)
  def test_findings_by_level_is_optional
    Dir.mktmpdir do |dir|
      bare(dir, "zz-old", with_review(:absent))
      bare(dir, "zz-none", GOOD.merge("reviewRound" => nil))
      bare(dir, "zz-new", with_review(COUNTS))
      envelope, code = run_check(dir)

      assert_equal 0, code
      assert_empty envelope["blocked"]
      assert_empty envelope["warnings"]
      states = envelope["data"]["reports"].map { |r| [File.basename(r["path"]), r["findings_by_level"]] }
      assert_equal({ "zz-old-report.json" => nil, "zz-none-report.json" => nil,
                     "zz-new-report.json" => "ok" }, states.to_h)
    end
  end

  # sabotage: block! on a malformed field, or accept a missing bucket, a
  # negative count, a float or a string -> red
  def test_a_malformed_findings_by_level_warns_and_never_blocks
    bad = [COUNTS.reject { |k, _| k == "unranked" }, COUNTS.merge("note" => -1),
           COUNTS.merge("note" => 1.5), COUNTS.merge("extra" => 0), "3 must-fix", []]
    bad.each_with_index do |counts, i|
      Dir.mktmpdir do |dir|
        path = bare(dir, "zz-bad#{i}", with_review(counts))
        envelope, code = run_check(dir)

        assert_equal 0, code, counts.inspect
        assert envelope["ok"], counts.inspect
        assert_empty envelope["blocked"], counts.inspect
        assert_equal ["findings_by_level_malformed"], codes(envelope, "warnings"), counts.inspect
        assert_includes envelope["warnings"].first["message"], path
      end
    end
  end
end

# --notes-dir: the caller writes each bead's notes to DIR/<bead-id>.txt and
# the script cross-checks a complete report against the bead's last note.
# The notes text below is the shape bd note stores and `bd show <id> --json`
# returns: one note per line, verbatim, no stamp added by bd.
class ReportCheckNotesTest < Minitest::Test
  include ReportFixtures

  def report(dir, id, status)
    bare(dir, id, { "bead" => id, "status" => status, "gate" => "green" })
  end

  def notes(notes_dir, id, text)
    FileUtils.mkdir_p(notes_dir)
    File.write(File.join(notes_dir, "#{id}.txt"), text)
  end

  CLAIM = "2026-10-06 14:52Z claimed by conductor session c-1; dispatching a worker."

  # sabotage (targeted run only): make ReportCheck.partial? match any note
  # (return !note.nil?) -> the no-marker test below goes red; this one
  # stays green, which is why both exist
  def test_a_complete_report_with_a_partial_last_note_warns_naming_the_bead
    Dir.mktmpdir do |dir|
      notes_dir = File.join(dir, "notes")
      path = report(dir, "zz-p1", "complete")
      notes(notes_dir, "zz-p1", "#{CLAIM}\n[partial] worker: all but the sabotage test landed\n")
      envelope, code = run_check("--notes-dir", notes_dir, dir)

      assert_equal 0, code
      assert envelope["ok"]
      assert_empty envelope["blocked"]
      assert_equal ["status_contradicts_notes"], codes(envelope, "warnings")
      message = envelope["warnings"].first["message"]
      assert_includes message, "zz-p1"
      assert_includes message, path
      assert_includes message, "\"complete\""
      assert_includes message, "[partial] worker: all but the sabotage test landed"
      assert_equal notes_dir, envelope["data"]["notes_dir"]
    end
  end

  # sabotage (targeted run only): ReportCheck.partial? returning true for any
  # note -> red (this complete report warns status_contradicts_notes)
  def test_a_complete_report_with_no_marker_in_its_notes_does_not_warn
    Dir.mktmpdir do |dir|
      notes_dir = File.join(dir, "notes")
      report(dir, "zz-c1", "complete")
      notes(notes_dir, "zz-c1", "#{CLAIM}\nworker: implemented, gate green, verify pass run.\n" \
                                "Request: https://forge.example/r/1\n")
      envelope, code = run_check("--notes-dir", notes_dir, dir)

      assert_equal 0, code
      assert_empty envelope["warnings"]
    end
  end

  # sabotage: cross-check every parsed report regardless of status -> red
  # (the blocked report with a [partial] note warns)
  def test_a_blocked_report_with_a_partial_note_does_not_warn
    Dir.mktmpdir do |dir|
      notes_dir = File.join(dir, "notes")
      report(dir, "zz-b1", "blocked")
      notes(notes_dir, "zz-b1", "#{CLAIM}\n[partial] stopped at the contract question\n")
      envelope, code = run_check("--notes-dir", notes_dir, dir)

      assert_equal 0, code
      assert_empty envelope["warnings"]
    end
  end

  # sabotage: scan every note instead of the last one -> red (an earlier
  # [partial] note that a later note superseded warns)
  def test_only_the_last_note_counts
    Dir.mktmpdir do |dir|
      notes_dir = File.join(dir, "notes")
      report(dir, "zz-l1", "complete")
      notes(notes_dir, "zz-l1", "[partial] first PR, one test left\nworker: last test landed, whole scope done\n\n")
      envelope, = run_check("--notes-dir", notes_dir, dir)

      assert_empty envelope["warnings"]
    end
  end

  # The indented, right-padded `bd show <id>` rendering reads the same as
  # the raw field. sabotage: drop the strip in ReportCheck.last_note -> red
  # (the warning's quoted note carries the padding)
  def test_the_indented_bd_show_rendering_reads_the_same
    Dir.mktmpdir do |dir|
      notes_dir = File.join(dir, "notes")
      report(dir, "zz-r1", "complete")
      notes(notes_dir, "zz-r1", "  first note    \n  [partial] one test left    \n")
      envelope, = run_check("--notes-dir", notes_dir, dir)

      assert_equal ["status_contradicts_notes"], codes(envelope, "warnings")
      assert_includes envelope["warnings"].first["message"], "\"[partial] one test left\"."
    end
  end

  # sabotage: block! instead of warn on a missing notes file -> red (exit 1)
  def test_a_missing_notes_file_warns_notes_missing_and_never_blocks
    Dir.mktmpdir do |dir|
      notes_dir = File.join(dir, "notes")
      FileUtils.mkdir_p(notes_dir)
      report(dir, "zz-m1", "complete")
      envelope, code = run_check("--notes-dir", notes_dir, dir)

      assert_equal 0, code
      assert envelope["ok"]
      assert_empty envelope["blocked"]
      assert_equal ["notes_missing"], codes(envelope, "warnings")
      assert_includes envelope["warnings"].first["message"], "zz-m1"
      assert_includes envelope["warnings"].first["message"], File.join(notes_dir, "zz-m1.txt")
    end
  end

  # The envelope this script emitted before --notes-dir existed, captured
  # from the unchanged script over these same fixtures, with the tmpdir
  # replaced by __DIR__. sabotage: always set data.notes_dir, or add a key to
  # each report entry -> red (the bytes differ)
  BEFORE = '{"ok":true,"script":"report_check","data":{"paths":["__DIR__","__DIR__/zz-later-report.json"],' \
           '"reports":[{"path":"__DIR__/zz-blk-report.json","exists":true,"parsed":true,"shape":"bare",' \
           '"error":null,"findings_by_level":null},{"path":"__DIR__/zz-done-report.json","exists":true,' \
           '"parsed":true,"shape":"bare","error":null,"findings_by_level":null},' \
           '{"path":"__DIR__/zz-later-report.json","exists":false,"parsed":false,"shape":null,"error":null}],' \
           '"checked":2,"unparseable":[]},"warnings":[{"code":"report_missing",' \
           '"message":"no report file at __DIR__/zz-later-report.json yet"}],"blocked":[],"commands":[]}' \
           "\n"

  def test_without_the_flag_the_envelope_is_byte_identical
    Dir.mktmpdir do |dir|
      report(dir, "zz-done", "complete")
      bare(dir, "zz-blk", { "bead" => "zz-blk", "status" => "blocked", "gate" => "red" })
      notes(File.join(dir, "notes"), "zz-done", "[partial] would contradict if checked\n")
      io = StringIO.new
      ReportCheckCli.run([dir, File.join(dir, "zz-later-report.json")], io: io)

      assert_equal BEFORE, io.string.gsub(dir, "__DIR__")
    end
  end
end

# as_of: the worker's list of mutable facts, each with the probe that
# re-checks it and the time it was true. Old-shape reports carry no as_of
# key at all; the key's presence is what marks a report as written on the
# template that asks for it.
class ReportCheckAsOfTest < Minitest::Test
  include ReportFixtures

  REQUEST = "https://forge.example/r/7"
  HEAD = { "fact" => "head_sha", "value" => "abc1234",
           "probe" => "git -C /wt rev-parse HEAD", "at" => "2026-10-06T17:00:00Z" }.freeze
  PR_STATE = { "fact" => "request_state", "value" => "open",
               "probe" => "gh pr view 7 --json state", "at" => "2026-10-06T17:01:00Z" }.freeze

  def complete(as_of = :absent, mr: REQUEST)
    payload = GOOD.merge("mr" => mr)
    payload["as_of"] = as_of unless as_of == :absent
    payload
  end

  # sabotage (targeted run only): skip the head-SHA requirement in
  # ReportCheck.as_of_problems -> red (nothing blocks, exit 0)
  def test_a_complete_report_with_a_request_and_no_head_sha_entry_blocks_with_the_fix
    Dir.mktmpdir do |dir|
      path = bare(dir, "zz-h1", complete([PR_STATE]))
      envelope, code = run_check(dir)

      assert_equal 1, code
      refute envelope["ok"]
      assert_equal ["as_of_head_sha_missing"], codes(envelope, "blocked")
      message = envelope["blocked"].first["message"]
      assert_includes message, path
      assert_includes message, REQUEST
      assert_includes message, "Fix: have the worker re-emit the report"
      assert_includes message, "\"head_sha\""
      assert_equal "human", envelope["blocked"].first["needs"]
    end
  end

  # The same requirement holds for an empty list: it is still the new shape.
  def test_an_empty_as_of_with_a_request_blocks
    Dir.mktmpdir do |dir|
      bare(dir, "zz-h2", complete([]))
      envelope, code = run_check(dir)

      assert_equal 1, code
      assert_equal ["as_of_head_sha_missing"], codes(envelope, "blocked")
    end
  end

  # sabotage: block or warn on a well-formed list, or drop entries when
  # reading -> red
  def test_a_well_formed_as_of_round_trips
    Dir.mktmpdir do |dir|
      path = bare(dir, "zz-ok", complete([HEAD, PR_STATE]))
      envelope, code = run_check(dir)

      assert_equal 0, code
      assert envelope["ok"]
      assert_empty envelope["blocked"]
      assert_empty envelope["warnings"]
      assert_equal [HEAD, PR_STATE], JSON.parse(File.read(path))["as_of"]
      assert_empty ReportCheck.as_of_problems(JSON.parse(File.read(path)))
    end
  end

  # sabotage (targeted run only): accept an entry with no probe (drop
  # "probe" from ReportCheck::AS_OF_FIELDS) -> red (the no-probe report
  # passes)
  def test_an_entry_missing_probe_is_blocked_by_name
    Dir.mktmpdir do |dir|
      path = bare(dir, "zz-p1", complete([HEAD, PR_STATE.reject { |k, _| k == "probe" }]))
      envelope, code = run_check(dir)

      assert_equal 1, code
      assert_equal ["as_of_entry_incomplete"], codes(envelope, "blocked")
      message = envelope["blocked"].first["message"]
      assert_includes message, path
      assert_includes message, "\"request_state\""
      assert_includes message, "missing probe"
      assert_includes message, "Fix:"
    end
  end

  # sabotage: drop "at" from ReportCheck::AS_OF_FIELDS, or treat a blank
  # string as present -> red
  def test_an_entry_missing_at_or_with_a_blank_at_is_blocked_by_name
    [HEAD.reject { |k, _| k == "at" }, HEAD.merge("at" => "  ")].each do |entry|
      Dir.mktmpdir do |dir|
        bare(dir, "zz-a1", complete([entry]))
        envelope, code = run_check(dir)

        assert_equal 1, code, entry.inspect
        assert_equal ["as_of_entry_incomplete"], codes(envelope, "blocked"), entry.inspect
        assert_includes envelope["blocked"].first["message"], "missing at", entry.inspect
        assert_includes envelope["blocked"].first["message"], "\"head_sha\"", entry.inspect
      end
    end
  end

  # An entry missing both is named once, with both fields.
  def test_an_entry_missing_probe_and_at_names_both
    Dir.mktmpdir do |dir|
      bare(dir, "zz-a2", complete([HEAD.reject { |k, _| %w[probe at].include?(k) }]))
      envelope, = run_check(dir)

      assert_equal ["as_of_entry_incomplete"], codes(envelope, "blocked")
      assert_includes envelope["blocked"].first["message"], "missing probe, at"
    end
  end

  # sabotage: iterate a non-array as_of, or skip the non-object entry ->
  # red (an error raised, or nothing blocks)
  def test_a_malformed_as_of_blocks
    ["head_sha abc1234", nil, { "head_sha" => "abc" }, [HEAD, "abc1234"]].each do |as_of|
      Dir.mktmpdir do |dir|
        bare(dir, "zz-m1", complete(as_of))
        envelope, code = run_check(dir)

        assert_equal 1, code, as_of.inspect
        assert_equal ["as_of_malformed"], codes(envelope, "blocked"), as_of.inspect
        assert_includes envelope["blocked"].first["message"], "Fix:", as_of.inspect
      end
    end
  end

  # Reports written before as_of existed still read. sabotage: require
  # as_of on every report -> red (exit 1 for the old shape)
  def test_a_pre_change_report_with_no_as_of_and_no_request_parses_ok
    Dir.mktmpdir do |dir|
      bare(dir, "zz-old1", GOOD)
      bare(dir, "zz-old2", GOOD.merge("mr" => nil))
      envelope, code = run_check(dir)

      assert_equal 0, code
      assert envelope["ok"]
      assert_empty envelope["blocked"]
      assert_empty envelope["warnings"]
    end
  end

  # A report with a request and no as_of key at all cannot be told from an
  # old-template report, so it warns naming the fix instead of blocking.
  # sabotage: block on the absent key -> red (every pre-change request
  # report would block the sweep); or stay silent -> red
  def test_a_request_report_with_no_as_of_key_warns_and_never_blocks
    Dir.mktmpdir do |dir|
      path = bare(dir, "zz-old3", complete)
      envelope, code = run_check(dir)

      assert_equal 0, code
      assert envelope["ok"]
      assert_empty envelope["blocked"]
      assert_equal ["as_of_absent"], codes(envelope, "warnings")
      assert_includes envelope["warnings"].first["message"], path
      assert_includes envelope["warnings"].first["message"], "head_sha"
    end
  end

  # The head-SHA requirement is for a complete report that names a request;
  # entries are still checked on every report that carries the list.
  # sabotage: require head_sha regardless of status -> red
  def test_the_head_sha_requirement_is_only_for_complete_reports_with_a_request
    Dir.mktmpdir do |dir|
      bare(dir, "zz-b1", GOOD.merge("status" => "blocked", "mr" => REQUEST, "as_of" => [PR_STATE]))
      bare(dir, "zz-l1", complete([PR_STATE], mr: nil))
      envelope, code = run_check(dir)

      assert_equal 0, code
      assert_empty envelope["blocked"]

      bare(dir, "zz-b2", GOOD.merge("status" => "blocked", "as_of" => [{ "fact" => "bead_status" }]))
      envelope, code = run_check(dir)
      assert_equal 1, code
      assert_equal ["as_of_entry_incomplete"], codes(envelope, "blocked")
    end
  end
end

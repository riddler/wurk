# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "securerandom"
require "fileutils"
require "tmpdir"
require "digest"
require_relative "../bead_dedupe"
require_relative "../typesafe"
require_relative "support/user_config_helper"
require_relative "support/fake_http"
require_relative "support/fake_sh"

# bead_dedupe.rb driven in-process: BeadDedupeCli.run with StringIOs, a tmp
# HOME holding the machine config, a tmp key file holding a sentinel string
# (never a real key), a tmp state dir, XDG_STATE_HOME pinned to a tmpdir,
# FakeHTTP as the only transport and FakeSh as the only shell. The beads are
# synthetic fixtures, never the live tracker. Every output captured here and
# every file left under the tmp HOME is swept for the sentinel key; the
# state dir is also swept for the beads' own text (TEXT_MARK), which must
# never reach a log.
class BeadDedupeTest < Minitest::Test
  include UserConfigHelper

  SENTINEL_KEY = "sentinel-dedupe-#{SecureRandom.hex(12)}"
  TEXT_MARK = "dedupetextmark#{SecureRandom.hex(6)}"
  MODEL = "jev-1.13.0"
  PRICE = { "input" => 0.042, "output" => 0 }.freeze
  REQUEST = "POST https://api.typesafe.ai/v1/systemone"
  SOURCE = "repo:wurk"
  # A tracker write of any kind, or a refusal of the filing.
  WRITES = /\A(create|close|edit|update|link|dep|note|label|delete|reopen)\z/.freeze

  NEW_TITLE = "Cleanup removes local branches holding commits nobody pushed"
  NEW_DESCRIPTION = "When a finished worktree is removed, its branch goes with it even if the " \
                    "branch carries commits that no remote has, so that work is lost. #{TEXT_MARK}"

  # The paraphrased duplicate: the same problem, different words.
  DUPLICATE = {
    "id" => "fx-dup", "status" => "open", "priority" => 1, "labels" => ["area:kit"],
    "title" => "Worktree cleanup deletes branches that still have unpushed commits",
    "description" => "Removing a worktree after its work lands also deletes the local branch, " \
                     "including any commits that were never pushed anywhere."
  }.freeze
  # Shares a title word with the new bead but is about something else.
  NEAR_MISS = {
    "id" => "fx-near", "status" => "open",
    "title" => "Commit message titles over fifty characters pass the linter",
    "description" => "The commit title check counts bytes, not characters."
  }.freeze
  # Shares nothing: never a candidate, never sent.
  UNRELATED = {
    "id" => "fx-other", "status" => "open",
    "title" => "Morning report omits the gate duration",
    "description" => "The report shows pass or fail but not how long the suite ran."
  }.freeze

  def setup
    @saved_xdg = ENV.key?("XDG_STATE_HOME") ? ENV["XDG_STATE_HOME"] : :unset
    @xdg = Dir.mktmpdir("wurk-bead-dedupe-xdg-")
    ENV["XDG_STATE_HOME"] = @xdg
    @fake = FakeHTTP.new
    @sh = FakeSh.new
    @saved_runner = Sh.runner
    Sh.runner = @sh
    @outputs = []
  end

  def teardown
    @outputs.each { |text| refute_includes text.to_s, SENTINEL_KEY }
  ensure
    Sh.runner = @saved_runner
    if @saved_xdg == :unset
      ENV.delete("XDG_STATE_HOME")
    else
      ENV["XDG_STATE_HOME"] = @saved_xdg
    end
    FileUtils.remove_entry(@xdg) if File.exist?(@xdg)
  end

  # ---- helpers -------------------------------------------------------------

  # A tmp HOME whose machine config sets the bead_dedupe site to `mode` (nil
  # writes no config at all). `extra` merges into the typesafe section.
  def with_home(mode = "shadow", extra: {})
    in_tmp_home(nil) do |dir|
      @home = dir
      @key_path = File.join(dir, "key", "typesafe-api-token")
      @state_dir = File.join(dir, "state")
      FileUtils.mkdir_p(File.dirname(@key_path))
      File.write(@key_path, "#{SENTINEL_KEY}\n")
      File.chmod(0o600, @key_path)
      unless mode.nil?
        section = { "key_path" => @key_path, "state_dir" => @state_dir,
                    "budget" => { "monthly_usd" => 1.0 },
                    "sites" => { "bead_dedupe" => { "mode" => mode } } }.merge(extra)
        write_raw_user_config(dir, JSON.generate("typesafe" => section,
                                                 "metrics" => { "prices" => { MODEL => PRICE } }))
      end
      yield dir
      sweep_files(dir)
    end
  end

  def sweep_files(dir)
    Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).each do |path|
      next unless File.file?(path)
      next if path == @key_path

      refute_includes File.read(path), SENTINEL_KEY, "sentinel key found in #{path}"
    end
    state_paths.each do |path|
      text = File.read(path)
      refute_includes text, TEXT_MARK, "bead text found in #{path}"
      refute_includes text, "unpushed", "candidate text found in #{path}"
    end
  end

  def state_paths
    Dir.exist?(@state_dir) ? Dir.glob(File.join(@state_dir, "*")).sort : []
  end

  def write_candidates(list = [DUPLICATE, NEAR_MISS, UNRELATED])
    path = File.join(@home, "candidates.json")
    File.write(path, list.is_a?(String) ? list : JSON.generate(list))
    path
  end

  def body_for(yes, model: MODEL)
    JSON.generate("model" => model,
                  "answers" => { "same_issue" => { "type" => "noul", "noul" => yes } },
                  "usage" => { "input_tokens" => 300, "output_tokens" => 0 })
  end

  # [exit_code, parsed_envelope_or_nil, stdout, stderr]
  def run_cli(argv, http_class: @fake)
    io = StringIO.new
    code = nil
    out, err = capture_io do
      code = BeadDedupeCli.run(argv, io: io, http_class: http_class)
    end
    @outputs << io.string << out << err
    body = io.string.start_with?("{") ? JSON.parse(io.string) : nil
    [code, body, io.string + out, err]
  end

  def dedupe(candidates: :file, threshold: nil, extra: [])
    argv = ["--title", NEW_TITLE, "--description", NEW_DESCRIPTION, "--source", SOURCE]
    argv += ["--candidates", candidates == :file ? write_candidates : candidates] unless candidates.nil?
    argv += ["--threshold", threshold.to_s] unless threshold.nil?
    run_cli(argv + extra)
  end

  def decisions
    path = Dir.glob(File.join(@state_dir, "decisions-*.jsonl")).first
    path ? File.readlines(path).map { |l| JSON.parse(l) } : []
  end

  # Filing goes ahead: exit 0, nothing blocked, and no tracker write.
  def assert_filing_unaffected(code, body)
    assert_equal 0, code
    assert_empty body["blocked"]
    assert_equal true, body["ok"]
    @sh.calls.each do |call|
      assert_equal "bd", call.argv[0]
      refute_match WRITES, call.argv[1].to_s, "tracker write: #{call.argv.inspect}"
    end
  end

  def ids(body)
    body["data"]["candidates"].map { |c| c["id"] }
  end

  # ---- off: the default ----------------------------------------------------

  # sabotage: default the site to shadow, or read the tracker or the
  # description file before the mode check -> red
  def test_no_config_is_site_off_and_touches_nothing
    with_home(nil) do
      code, body, = run_cli(["--title", NEW_TITLE, "--description-file",
                             File.join(@home, "absent.txt"), "--source", SOURCE])
      assert_filing_unaffected(code, body)
      data = body["data"]
      assert_equal "off", data["mode"]
      assert_equal "site_off", data["outcome"]
      assert_equal "site_off", data["action"]
      assert_empty data["likely_duplicates"]
      assert_empty data["candidates"]
      assert_nil data["journal_line"]
      assert_empty body["warnings"]
      assert_empty body["commands"]
      assert_empty @sh.calls, "the tracker was read on a dark site"
      assert_empty @fake.calls
      assert_empty state_paths
      refute Dir.exist?(File.join(@xdg, "wurk")), "default state dir created"
    end
  end

  # ---- the acceptance fixture ---------------------------------------------

  # sabotage: stop the keyword filter excluding a bead with no shared words,
  # or flag below the threshold -> red
  def test_on_flags_the_paraphrased_duplicate_and_not_the_unrelated_beads
    with_home("on") do
      @fake.respond(200, body: body_for(0.96)).respond(200, body: body_for(0.04))
      code, body, = dedupe(threshold: 0.9)
      assert_filing_unaffected(code, body)
      data = body["data"]
      assert_equal %w[fx-dup fx-near], ids(body), "the unrelated bead is not a candidate"
      assert_equal ["fx-dup"], data["likely_duplicates"]
      dup, near = data["candidates"]
      assert_equal "flagged", dup["action"]
      assert_in_delta 0.96, dup["jev_yes"]
      assert_equal "no_change", near["action"]
      assert_equal "below_threshold", near["reason"]
      assert_equal "judged", data["action"]
      assert_equal 2, data["calls"]
      assert_equal 2, @fake.calls.size
      assert_equal 3, data["searched"]
      assert_includes data["journal_line"], "flagged fx-dup"
      assert_includes data["journal_line"], "filing unchanged"
      refute_includes data["journal_line"], TEXT_MARK
      outcomes = decisions.select { |l| l["kind"] == "outcome" }
      assert_equal %w[flagged no_change], outcomes.map { |l| l["action"] }
      assert_equal ["filed_unlinked"], outcomes.map { |l| l["decision"] }.uniq
    end
  end

  # sabotage: send an id, status, priority or labels, or skip the source ->
  # red
  def test_request_carries_titles_and_descriptions_only
    with_home("shadow") do
      @fake.respond(200, body: body_for(0.5)).respond(200, body: body_for(0.5))
      dedupe
      sent = JSON.parse(@fake.calls[0].request.body)
      assert_equal %w[candidate new_bead], sent["state"].keys.sort
      assert_equal %w[description title], sent["state"]["new_bead"].keys.sort
      assert_equal %w[description title], sent["state"]["candidate"].keys.sort
      assert_equal DUPLICATE["title"], sent["state"]["candidate"]["title"]
      text = JSON.generate(sent["state"])
      %w[fx-dup fx-near area:kit open].each { |word| refute_includes text, word }
      assert_equal ["same_issue"], sent["questions"].keys
      assert_equal "noul", sent["questions"]["same_issue"]["type"]
      assert_equal MODEL, sent["model"]
      refute sent.key?("source"), "the source label is a local privacy gate, not request content"
    end
  end

  # ---- shadow: log only ----------------------------------------------------

  # sabotage: flag in shadow, or skip the outcome line -> red
  def test_shadow_logs_and_never_flags
    with_home("shadow") do
      @fake.respond(200, body: body_for(0.99)).respond(200, body: body_for(0.99))
      code, body, = dedupe(threshold: 0.1)
      assert_filing_unaffected(code, body)
      data = body["data"]
      assert_empty data["likely_duplicates"]
      assert_equal %w[shadow_logged shadow_logged], data["candidates"].map { |c| c["action"] }
      assert_in_delta 0.99, data["candidates"][0]["jev_yes"]
      lines = decisions
      assert_equal %w[decision outcome decision outcome], lines.map { |l| l["kind"] }
      assert_equal lines[0]["call_id"], lines[1]["call_id"]
      assert_equal data["candidates"][0]["call_id"], lines[1]["call_id"]
      lines.each { |l| refute l.key?("state"), "decision line carries state text" }
      assert_equal [REQUEST], body["commands"]
    end
  end

  # ---- on: flag only -------------------------------------------------------

  # sabotage: compare with > instead of >=, or default a threshold -> red
  def test_on_threshold_edges_and_no_threshold
    with_home("on") do
      @fake.respond(200, body: body_for(0.9)).respond(200, body: body_for(0.2))
      _, body, = dedupe(threshold: 0.9)
      assert_equal ["fx-dup"], body["data"]["likely_duplicates"], "equal to the threshold flags"
    end
    with_home("on") do
      @fake.respond(200, body: body_for(0.99)).respond(200, body: body_for(0.99))
      code, body, = dedupe
      assert_filing_unaffected(code, body)
      assert_empty body["data"]["likely_duplicates"]
      assert_equal ["no_threshold"], body["data"]["candidates"].map { |c| c["reason"] }.uniq
    end
  end

  # sabotage: let a Jev "no" drop a keyword candidate from the list -> red
  def test_a_no_never_removes_a_keyword_candidate
    with_home("on") do
      @fake.respond(200, body: body_for(0.01)).respond(200, body: body_for(0.01))
      code, body, = dedupe(threshold: 0.5)
      assert_filing_unaffected(code, body)
      assert_equal %w[fx-dup fx-near], ids(body)
      assert_empty body["data"]["likely_duplicates"]
    end
    BeadDedupe::ACTIONS.each { |a| refute_match(/close|refuse|block|remov|delete|link/, a) }
  end

  # ---- failures leave filing unchanged -------------------------------------

  # sabotage: read a non-ok outcome as a no, go on calling after a failure,
  # retry, or exit non-zero -> red
  def test_every_jev_failure_falls_back_after_one_attempt
    cases = {
      "timeout" => ->(f) { f.raise_error(Net::ReadTimeout.new) },
      "other_status" => ->(f) { f.respond(500) },
      "rate_limited" => ->(f) { f.respond(429, headers: { "Retry-After" => "5" }) },
      "overloaded" => ->(f) { f.respond(529) },
      "unauthorized" => ->(f) { f.respond(401) },
      "transport" => ->(f) { f.raise_error(Errno::ECONNREFUSED.new) },
      "undecodable" => ->(f) { f.respond(200, body: "not json") },
      "model_mismatch" => ->(f) { f.respond(200, body: body_for(0.99, model: "jev-9.9.9")) }
    }
    cases.each do |outcome, script|
      @fake = FakeHTTP.new
      with_home("on") do
        script.call(@fake)
        code, body, = dedupe(threshold: 0.5)
        assert_filing_unaffected(code, body)
        data = body["data"]
        assert_equal outcome, data["outcome"], outcome
        assert_equal "fallback", data["action"], outcome
        assert_empty data["likely_duplicates"], outcome
        first, second = data["candidates"]
        assert_equal "fallback", first["action"], outcome
        assert_equal outcome, first["reason"], outcome
        assert_nil first["jev_yes"], outcome
        assert_equal "not_judged", second["action"], outcome
        assert_equal 1, @fake.calls.size, "#{outcome}: one attempt, then stop"
        assert_includes body["warnings"].map { |w| w["code"] }, "jev_fallback", outcome
        assert_includes data["journal_line"], "filing unchanged"
      end
    end
  end

  # sabotage: accept a noul outside [0, 1] or a missing one -> red
  def test_malformed_answers_fall_back
    [1.5, nil, "0.9"].each do |bad|
      @fake = FakeHTTP.new
      with_home("on") do
        @fake.respond(200, body: body_for(bad)).respond(200, body: body_for(bad))
        code, body, = dedupe(threshold: 0.1)
        assert_filing_unaffected(code, body)
        assert_empty body["data"]["likely_duplicates"], bad.inspect
        assert_equal ["answer_malformed"], body["data"]["candidates"].map { |c| c["reason"] }.uniq
      end
    end
  end

  # sabotage: drop the source from the input -> red (the restricted label
  # would be sent)
  def test_restricted_source_refuses_in_shadow_and_on
    %w[shadow on].each do |mode|
      @fake = FakeHTTP.new
      with_home(mode, extra: { "restricted_sources" => [SOURCE] }) do
        code, body, = dedupe(threshold: 0.1)
        assert_filing_unaffected(code, body)
        assert_equal "source_restricted", body["data"]["outcome"], mode
        assert_equal "fallback", body["data"]["action"], mode
        assert_empty @fake.calls, mode
        assert_empty body["commands"], mode
      end
    end
  end

  # sabotage: let budget_unset through to a request -> red
  def test_budget_unset_falls_back_without_a_call
    with_home("shadow", extra: { "budget" => {} }) do
      code, body, = dedupe
      assert_filing_unaffected(code, body)
      assert_equal "budget_exhausted", body["data"]["outcome"]
      assert_empty @fake.calls
    end
  end

  # sabotage: let the state-dir SystemCallError escape run, or keep a flag
  # through it -> red
  def test_state_dir_failure_falls_back_with_class_only
    with_home("on") do
      FileUtils.mkdir_p(File.dirname(@state_dir))
      File.write(@state_dir, "not a directory")
      @fake.respond(200, body: body_for(0.99))
      code, body, stdout, stderr = dedupe(threshold: 0.5)
      assert_filing_unaffected(code, body)
      assert_equal "fallback", body["data"]["action"]
      assert_equal "state_dir_error", body["data"]["reason"]
      assert_empty body["data"]["likely_duplicates"]
      warning = body["warnings"].find { |w| w["code"] == "state_dir_error" }
      assert_match(/\(Errno::[A-Z]+\)/, warning["message"])
      refute_includes stdout, @state_dir
      assert_empty stderr
    end
  end

  # ---- candidate search ----------------------------------------------------

  # sabotage: search with anything but a read-only bd list, or drop the
  # comma-joined status -> red
  def test_tracker_search_is_one_read_only_bd_list
    with_home("on") do
      @sh.expect(["bd", "list"], out: JSON.generate([UNRELATED, DUPLICATE]))
      @fake.respond(200, body: body_for(0.95))
      code, body, = dedupe(candidates: nil, threshold: 0.9)
      assert_filing_unaffected(code, body)
      assert_equal [BeadDedupeCli::LIST_ARGV], @sh.calls.map(&:argv)
      assert_equal ["fx-dup"], body["data"]["likely_duplicates"]
      assert_includes body["commands"], "bd list --status 'open,in_progress,blocked' --json --limit 0"
    end
  end

  # sabotage: exit non-zero or block when the search fails -> red
  def test_search_failures_skip_and_file_anyway
    with_home("on") do
      @sh.expect(["bd", "list"], err: "no db", exitstatus: 1)
      code, body, = dedupe(candidates: nil, threshold: 0.9)
      assert_filing_unaffected(code, body)
      assert_equal "skipped", body["data"]["action"]
      assert_equal "candidate_search_failed", body["data"]["reason"]

      code, body, = dedupe(candidates: write_candidates("not json"), threshold: 0.9)
      assert_filing_unaffected(code, body)
      assert_equal "candidates_unreadable", body["data"]["reason"]

      code, body, = dedupe(candidates: write_candidates([UNRELATED]), threshold: 0.9)
      assert_filing_unaffected(code, body)
      assert_equal "no_candidates", body["data"]["reason"]
      assert_empty @fake.calls
      assert_empty state_paths
    end
  end

  # sabotage: ignore --max-candidates -> red
  def test_max_candidates_caps_the_calls
    with_home("shadow") do
      @fake.respond(200, body: body_for(0.5))
      code, body, = dedupe(extra: ["--max-candidates", "1"])
      assert_filing_unaffected(code, body)
      assert_equal ["fx-dup"], ids(body)
      assert_equal 1, @fake.calls.size
    end
  end

  # sabotage: send or write on a dry run, or leak the key -> red
  def test_dry_run_redacts_and_writes_nothing
    with_home("on") do
      code, body, = dedupe(threshold: 0.1, extra: ["--dry-run"])
      assert_filing_unaffected(code, body)
      data = body["data"]
      assert_equal "dry_run", data["action"]
      assert_equal %w[dry_run dry_run], data["candidates"].map { |c| c["action"] }
      assert_empty data["likely_duplicates"]
      assert_equal "Bearer [REDACTED]", data["request"]["headers"]["Authorization"]
      assert_equal "bead_dedupe:bead_dedupe@1:#{MODEL}", data["threshold_key"]
      assert_equal [REQUEST], body["commands"]
      assert_equal 0, data["calls"]
      assert_empty @fake.calls
      assert_empty state_paths
    end
  end

  # sabotage: skip UserConfig.require! -> red
  def test_invalid_config_exits_1
    with_home("maybe") do
      code, body, = dedupe
      assert_equal 1, code
      assert_equal ["user_config_invalid"], body["blocked"].map { |b| b["code"] }.uniq
      assert_empty @fake.calls
      assert_empty @sh.calls
    end
  end

  # ---- usage ---------------------------------------------------------------

  # sabotage: accept any of these argv shapes, or print an envelope -> red
  def test_usage_errors_exit_2_with_no_envelope
    with_home("shadow") do
      good = ["--title", NEW_TITLE, "--source", SOURCE]
      [
        ["--source", SOURCE],
        ["--title", NEW_TITLE],
        ["--title", " ", "--source", SOURCE],
        ["--title", NEW_TITLE, "--source", "has spaces"],
        good + ["--description", "x", "--description-file", "y"],
        good + ["--max-candidates", "0"],
        good + ["--max-candidates", "11"],
        good + ["--max-candidates", "two"],
        good + ["--threshold", "0"],
        good + ["--threshold", "1.5"],
        good + ["stray"],
        good + ["--nope"]
      ].each do |argv|
        code, body, stdout, stderr = run_cli(argv)
        assert_equal 2, code, argv.inspect
        assert_nil body, argv.inspect
        assert_empty stdout, argv.inspect
        assert_includes stderr, "usage:", argv.inspect
      end
      assert_empty @fake.calls
      assert_empty @sh.calls
    end
  end

  # sabotage: route --help through Cli.build's handler (it calls exit) -> red
  def test_help_exits_0
    code, body, stdout, = run_cli(["--help"])
    assert_equal 0, code
    assert_nil body
    assert_includes stdout, "bead_dedupe.rb --title TEXT"
  end

  # ---- the library ---------------------------------------------------------

  # sabotage: let the CLI's SENT list drift from the client CLI's -> red
  def test_sent_matches_the_client_cli
    assert_equal TypesafeCli::SENT.sort, BeadDedupeCli::SENT.sort
  end

  # sabotage: drop the stopword filter or the plural fold -> red
  def test_tokens_and_ranking_are_plain_code
    assert_equal %w[worktree cleanup delete branch], BeadDedupe.tokens("The worktree cleanup deletes the branch")
    ranked = BeadDedupe.rank(new_title: NEW_TITLE, new_description: NEW_DESCRIPTION,
                             candidates: [UNRELATED, NEAR_MISS, DUPLICATE, "junk", { "id" => "x" }],
                             max: 3)
    assert_equal %w[fx-dup fx-near], ranked.map { |c| c["id"] }
    assert_operator ranked[0]["title_overlap"], :>, ranked[1]["title_overlap"]
    long = BeadDedupe.input_for(new_title: "t", new_description: "x" * 5000,
                                candidate: DUPLICATE, source: SOURCE)
    assert_equal BeadDedupe::MAX_TEXT_CHARS, long["state"]["new_bead"]["description"].length
    assert_equal SOURCE, long["source"]
  end

  # The question text version 1 was written against. Changing the
  # instructions or criteria turns this red: bump QUESTION_SET's version in
  # the same change, then re-pin this digest.
  QUESTIONS_V1_DIGEST = "d0c029b2b0d03b88"

  # sabotage: edit the question's wording without bumping the version -> red
  def test_question_set_version_is_pinned_to_the_question_text
    digest = Digest::SHA256.hexdigest(JSON.generate(BeadDedupe::QUESTIONS))[0, 16]
    assert_equal({ "id" => "bead_dedupe", "version" => 1 }, BeadDedupe::QUESTION_SET)
    assert_equal QUESTIONS_V1_DIGEST, digest,
                 "question text changed: bump QUESTION_SET's version, then re-pin the digest"
    assert BeadDedupe::QUESTION_SET.frozen?
    assert_equal %w[false true], BeadDedupe::QUESTIONS["same_issue"]["criteria"].keys.sort
  end
end

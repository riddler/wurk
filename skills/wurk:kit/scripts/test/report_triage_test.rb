# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "securerandom"
require "fileutils"
require "tmpdir"
require_relative "../report_triage"
require_relative "../typesafe"
require_relative "support/user_config_helper"
require_relative "support/fake_http"

# report_triage.rb driven in-process: ReportTriageCli.run with StringIOs, a
# tmp HOME holding the machine config, a tmp key file holding a sentinel
# string (never a real key), a tmp state dir, XDG_STATE_HOME pinned to a
# tmpdir, and FakeHTTP as the only transport. Every output captured here and
# every file left under the tmp HOME is swept for the sentinel key; the state
# dir is also swept for the report's own text (PROSE_MARK), which must never
# reach a log.
class ReportTriageTest < Minitest::Test
  include UserConfigHelper

  SENTINEL_KEY = "sentinel-triage-#{SecureRandom.hex(12)}"
  PROSE_MARK = "triageprosemark-#{SecureRandom.hex(6)}"
  STATUS_MARK = "statusmark-#{SecureRandom.hex(6)}"
  MODEL = "jev-1.13.0"
  PRICE = { "input" => 0.042, "output" => 0 }.freeze
  REQUEST = "POST https://api.typesafe.ai/v1/systemone"
  SOURCE = "repo:wurk"
  CLEARING = /clear|remov|downgrad|mark.*done|resolv/i.freeze

  def setup
    @saved_xdg = ENV.key?("XDG_STATE_HOME") ? ENV["XDG_STATE_HOME"] : :unset
    @xdg = Dir.mktmpdir("wurk-report-triage-xdg-")
    ENV["XDG_STATE_HOME"] = @xdg
    @fake = FakeHTTP.new
    @outputs = []
  end

  def teardown
    @outputs.each { |text| refute_includes text.to_s, SENTINEL_KEY }
  ensure
    if @saved_xdg == :unset
      ENV.delete("XDG_STATE_HOME")
    else
      ENV["XDG_STATE_HOME"] = @saved_xdg
    end
    FileUtils.remove_entry(@xdg) if File.exist?(@xdg)
  end

  # ---- helpers -------------------------------------------------------------

  # A tmp HOME whose machine config sets the report_triage site to `mode`
  # (nil writes no config at all). `extra` merges into the typesafe section.
  def with_home(mode = "shadow", extra: {}, site: :default)
    in_tmp_home(nil) do |dir|
      @home = dir
      @key_path = File.join(dir, "key", "typesafe-api-token")
      @state_dir = File.join(dir, "state")
      FileUtils.mkdir_p(File.dirname(@key_path))
      File.write(@key_path, "#{SENTINEL_KEY}\n")
      File.chmod(0o600, @key_path)
      unless mode.nil?
        sites = site == :default ? { "report_triage" => { "mode" => mode } } : site
        section = { "key_path" => @key_path, "state_dir" => @state_dir,
                    "budget" => { "monthly_usd" => 1.0 }, "sites" => sites }.merge(extra)
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
      refute_includes File.read(path), PROSE_MARK, "report text found in #{path}"
    end
  end

  def state_paths
    Dir.exist?(@state_dir) ? Dir.glob(File.join(@state_dir, "*")).sort : []
  end

  def report_hash(**over)
    {
      "bead" => "wu-abc", "repo" => "wurk", "status" => "complete #{STATUS_MARK}",
      "branch" => "wu-abc-branch", "sha" => "deadbeef", "gate" => "green",
      "committed" => true, "mr" => nil,
      "reviewRound" => { "agents" => ["critic"], "findings" => 2, "mustFix" => 0,
                         "addressed" => 2, "deferred" => ["a deferred nit"] },
      "repos_touched" => ["wurk"], "scopeAuthority" => [],
      "notesWritten" => ["wrote the plan note"],
      "discoveredDeps" => [{ "summary" => "needs the parser bead", "owningRepo" => "wurk",
                             "existingBead" => "wu-dep" }],
      "openQuestions" => ["should the flag default on? #{PROSE_MARK}"],
      "judgementCalls" => ["kept the old name"]
    }.merge(over.each_with_object({}) { |(k, v), h| h[k.to_s] = v })
  end

  def write_report(content = report_hash)
    path = File.join(@home, "wu-abc-report.json")
    File.write(path, content.is_a?(String) ? content : JSON.generate(content))
    path
  end

  def answers(choice: "blocked", prob: 0.9, score: 2.2)
    probs = { "done" => 0.05, "blocked" => 0.05, "stuck" => 0.05 }
    probs[choice] = prob if probs.key?(choice)
    {
      "state" => { "type" => "choice", "choice" => choice, "probabilities" => probs,
                   "confidence" => 0.8 },
      "urgency" => { "type" => "score", "score" => score,
                     "legend" => { "0" => "nothing", "1" => "read", "2" => "waits", "3" => "now" },
                     "probabilities" => { "0" => 0.05, "1" => 0.15, "2" => 0.6, "3" => 0.2 },
                     "confidence" => 0.7 }
    }
  end

  def body_for(ans = answers, model: MODEL)
    JSON.generate("model" => model, "answers" => ans,
                  "usage" => { "input_tokens" => 450, "output_tokens" => 0 })
  end

  # [exit_code, parsed_envelope_or_nil, stdout, stderr]
  def run_cli(argv, http_class: @fake)
    io = StringIO.new
    code = nil
    out, err = capture_io do
      code = ReportTriageCli.run(argv, io: io, http_class: http_class)
    end
    @outputs << io.string << out << err
    body = io.string.start_with?("{") ? JSON.parse(io.string) : nil
    [code, body, io.string + out, err]
  end

  def triage(conductor, path = write_report, threshold: nil, extra: [])
    argv = ["--report", path, "--conductor", conductor, "--source", SOURCE]
    argv += ["--threshold", threshold.to_s] unless threshold.nil?
    run_cli(argv + extra)
  end

  def decisions
    path = Dir.glob(File.join(@state_dir, "decisions-*.jsonl")).first
    path ? File.readlines(path).map { |l| JSON.parse(l) } : []
  end

  def assert_unchanged(code, body)
    assert_equal 0, code
    assert_equal false, body["data"]["add_needs_you"]
    assert_empty body["blocked"]
  end

  # ---- off: the default ----------------------------------------------------

  # sabotage: default the site to shadow, block on off like typesafe.rb, or
  # read the report before the mode check -> red (a nonexistent report
  # would then fall back as report_unreadable)
  def test_no_config_is_site_off_and_touches_nothing
    with_home(nil) do
      code, body, = triage("done", File.join(@home, "missing-report.json"))
      assert_unchanged(code, body)
      data = body["data"]
      assert_equal "off", data["mode"]
      assert_equal "site_off", data["outcome"]
      assert_equal "site_off", data["action"]
      assert_nil data["journal_line"]
      assert_nil data["report_digest"]
      assert_empty body["warnings"]
      assert_empty body["commands"]
      assert_empty @fake.calls
      assert_empty state_paths
      refute Dir.exist?(File.join(@xdg, "wurk")), "default state dir created"
    end
  end

  # sabotage: treat a configured site with no mode as shadow -> red
  def test_site_named_without_mode_defaults_off
    with_home(nil, site: {}) do
      write_raw_user_config(@home, JSON.generate(
        "typesafe" => { "state_dir" => @state_dir, "budget" => { "monthly_usd" => 1.0 },
                        "sites" => { "report_triage" => { "deadline_ms" => 900 } } }
      ))
      code, body, = triage("done")
      assert_unchanged(code, body)
      assert_equal "off", body["data"]["mode"]
      assert_equal "site_off", body["data"]["action"]
      assert_empty @fake.calls
      assert_empty state_paths
    end
  end

  # ---- shadow: journals both classifications -------------------------------

  # sabotage: skip the outcome line, record Jev's class as the decision, or
  # log the state text -> red
  def test_shadow_agree_logs_both_classifications
    with_home("shadow") do
      @fake.respond(200, body: body_for(answers(choice: "done", prob: 0.85, score: 0.3)))
      code, body, = triage("done")
      assert_unchanged(code, body)
      data = body["data"]
      assert_equal "shadow_logged", data["action"]
      assert_equal "agree", data["agreement"]
      assert_equal "done", data["jev_class"]
      assert_in_delta 0.85, data["jev_confidence"]
      assert_in_delta 0.3, data["urgency"]
      assert_equal true, data["outcome_line_written"]
      assert_equal [REQUEST], body["commands"]
      assert_equal 1, @fake.calls.size
      lines = decisions
      assert_equal %w[decision outcome], lines.map { |l| l["kind"] }
      assert_equal lines[0]["call_id"], lines[1]["call_id"]
      assert_equal data["call_id"], lines[1]["call_id"]
      assert_equal "done", lines[0]["answers"]["state"]["choice"]
      assert_equal "done", lines[1]["decision"]
      assert_equal "agree", lines[1]["agreement"]
      assert_equal "shadow_logged", lines[1]["action"]
      refute lines[0].key?("state"), "decision line carries state text"
    end
  end

  # sabotage: compute agreement against Jev's own class, or add in shadow ->
  # red
  def test_shadow_disagree_journals_both_classes_and_never_adds
    with_home("shadow") do
      @fake.respond(200, body: body_for(answers(choice: "blocked", prob: 0.99)))
      code, body, = triage("done", threshold: 0.5)
      assert_unchanged(code, body)
      data = body["data"]
      assert_equal "shadow_logged", data["action"]
      assert_equal "disagree", data["agreement"]
      line = data["journal_line"]
      assert_includes line, "conductor done"
      assert_includes line, "jev blocked 0.99"
      assert_includes line, "urgency 2.2"
      assert_includes line, "mode shadow"
      assert_includes line, "changed nothing"
      assert_includes line, "wu-abc-report.json@#{data['report_digest']}"
      refute_includes line, PROSE_MARK
      outcome = decisions.last
      assert_equal "done", outcome["decision"]
      assert_equal "disagree", outcome["agreement"]
    end
  end

  # ---- on: add only --------------------------------------------------------

  # sabotage: drop the threshold comparison, or require conductor != done
  # -> red
  def test_on_adds_when_conductor_done_and_jev_flags_at_threshold
    %w[blocked stuck].each do |jev|
      with_home("on") do
        @fake.respond(200, body: body_for(answers(choice: jev, prob: 0.92)))
        code, body, = triage("done", threshold: 0.9)
        assert_equal 0, code
        data = body["data"]
        assert_equal true, data["add_needs_you"], jev
        assert_equal "needs_you_added", data["action"]
        assert_equal jev, data["jev_class"]
        assert_includes data["journal_line"], "added needs-you item"
        assert_equal "needs_you_added", decisions.last["action"]
        assert_equal "disagree", decisions.last["agreement"]
      end
    end
  end

  # sabotage: compare with > instead of >= , or ignore the threshold -> red
  def test_on_threshold_edges
    with_home("on") do
      @fake.respond(200, body: body_for(answers(choice: "blocked", prob: 0.9)))
      _, body, = triage("done", threshold: 0.9)
      assert_equal true, body["data"]["add_needs_you"], "equal to the threshold adds"
    end
    with_home("on") do
      @fake.respond(200, body: body_for(answers(choice: "blocked", prob: 0.89)))
      code, body, = triage("done", threshold: 0.9)
      assert_unchanged(code, body)
      assert_equal "no_change", body["data"]["action"]
      assert_equal "below_threshold", body["data"]["reason"]
    end
  end

  # sabotage: fall back to a default threshold when none is passed -> red
  def test_on_without_threshold_adds_nothing
    with_home("on") do
      @fake.respond(200, body: body_for(answers(choice: "stuck", prob: 0.99)))
      code, body, = triage("done")
      assert_unchanged(code, body)
      assert_equal "no_change", body["data"]["action"]
      assert_equal "no_threshold", body["data"]["reason"]
      assert_nil body["data"]["threshold"]
    end
  end

  # sabotage: let a Jev "done" produce any action other than no_change, or
  # add a clearing action for a flagged conductor -> red
  def test_on_never_clears_a_flagged_report
    %w[blocked stuck].each do |conductor|
      with_home("on") do
        @fake.respond(200, body: body_for(answers(choice: "done", prob: 0.99, score: 0.0)))
        code, body, = triage(conductor, threshold: 0.05)
        assert_unchanged(code, body)
        data = body["data"]
        assert_equal "no_change", data["action"]
        assert_equal "jev_done", data["reason"]
        assert_equal "disagree", data["agreement"]
        data.each_key { |k| refute_match CLEARING, k }
        refute_match CLEARING, data["action"]
        assert_includes data["journal_line"], "changed nothing"
      end
    end
    assert_equal %w[fallback shadow_logged needs_you_added no_change].sort,
                 ReportTriage::ACTIONS.sort
    ReportTriage::ACTIONS.each { |a| refute_match CLEARING, a }
  end

  # sabotage: add whenever Jev flags, regardless of the conductor -> red
  def test_on_conductor_already_flagged_adds_nothing
    with_home("on") do
      @fake.respond(200, body: body_for(answers(choice: "blocked", prob: 0.99)))
      code, body, = triage("stuck", threshold: 0.5)
      assert_unchanged(code, body)
      assert_equal "no_change", body["data"]["action"]
      assert_equal "conductor_flagged", body["data"]["reason"]
    end
  end

  # ---- failures leave the sweep unchanged ----------------------------------

  # sabotage: read a non-ok outcome as an answer, retry, or exit non-zero on
  # a Jev failure -> red
  def test_every_jev_failure_falls_back_unchanged
    cases = {
      "timeout" => ->(f) { f.raise_error(Net::ReadTimeout.new) },
      "other_status" => ->(f) { f.respond(500) },
      "rate_limited" => ->(f) { f.respond(429, headers: { "Retry-After" => "5" }) },
      "overloaded" => ->(f) { f.respond(529) },
      "transport" => ->(f) { f.raise_error(Errno::ECONNREFUSED.new) },
      "undecodable" => ->(f) { f.respond(200, body: "not json") },
      "model_mismatch" => ->(f) { f.respond(200, body: body_for(model: "jev-9.9.9")) }
    }
    cases.each do |outcome, script|
      @fake = FakeHTTP.new
      with_home("on") do
        script.call(@fake)
        code, body, = triage("done", threshold: 0.5)
        assert_unchanged(code, body)
        data = body["data"]
        assert_equal outcome, data["outcome"], outcome
        assert_equal "fallback", data["action"], outcome
        assert_equal outcome, data["reason"], outcome
        assert_equal "n/a", data["agreement"]
        assert_nil data["jev_class"]
        assert_equal 1, @fake.calls.size, "#{outcome}: exactly one attempt"
        assert_includes body["warnings"].map { |w| w["code"] }, "jev_fallback", outcome
        assert_includes data["journal_line"], "jev fell back (#{outcome}); changed nothing"
        assert_equal "fallback", decisions.last["action"]
        assert_equal "n/a", decisions.last["agreement"]
      end
    end
  end

  # sabotage: accept a choice outside the class set, or default a missing
  # probability to 1.0 -> red
  def test_malformed_answers_fall_back
    bad_choice = answers(choice: "finished")
    no_prob = answers(choice: "blocked")
    no_prob["state"]["probabilities"].delete("blocked")
    [bad_choice, no_prob].each do |ans|
      @fake = FakeHTTP.new
      with_home("on") do
        @fake.respond(200, body: body_for(ans))
        code, body, = triage("done", threshold: 0.1)
        assert_unchanged(code, body)
        assert_equal "ok", body["data"]["outcome"]
        assert_equal "fallback", body["data"]["action"]
        assert_equal "answer_malformed", body["data"]["reason"]
        assert_includes body["warnings"].map { |w| w["code"] }, "jev_fallback"
      end
    end
  end

  # sabotage: drop the source from the input -> red (the restricted label
  # would be sent)
  def test_restricted_source_sends_nothing
    with_home("on", extra: { "restricted_sources" => [SOURCE] }) do
      code, body, = triage("done", threshold: 0.1)
      assert_unchanged(code, body)
      assert_equal "source_restricted", body["data"]["outcome"]
      assert_equal "fallback", body["data"]["action"]
      assert_empty @fake.calls
      assert_empty body["commands"]
    end
  end

  # sabotage: stop excluding status or identity fields, or drop a prose field
  # from the whitelist -> red
  def test_request_state_is_the_prose_whitelist_only
    with_home("shadow") do
      @fake.respond(200, body: body_for)
      triage("done")
      sent = JSON.parse(@fake.calls[0].request.body)
      report = sent["state"]["report"]
      assert_equal %w[discoveredDeps judgementCalls notesWritten openQuestions reviewRound],
                   report.keys.sort
      assert_equal({ "deferred" => ["a deferred nit"] }, report["reviewRound"])
      assert_equal ["needs the parser bead"], report["discoveredDeps"]
      text = JSON.generate(sent["state"])
      refute_includes text, STATUS_MARK
      %w[wu-abc wu-abc-branch deadbeef wu-dep].each { |id| refute_includes text, id }
      assert_equal %w[state urgency], sent["questions"].keys.sort
      assert_equal MODEL, sent["model"]
    end
  end

  # sabotage: send a report with no prose, or send on an unparseable report
  # -> red
  def test_nothing_to_judge_and_unreadable_send_nothing
    with_home("on") do
      path = write_report(report_hash(openQuestions: [], judgementCalls: [" "], notesWritten: nil,
                                      discoveredDeps: [], reviewRound: nil))
      code, body, = triage("done", path, threshold: 0.1)
      assert_unchanged(code, body)
      assert_equal "skipped", body["data"]["action"]
      assert_equal "nothing_to_judge", body["data"]["reason"]
      assert_match(/\A\h{16}\z/, body["data"]["report_digest"])

      path = write_report("```json\n{\"openQuestions\": [\"#{PROSE_MARK}\"]}\n```\n")
      code, body, stdout, = triage("done", path, threshold: 0.1)
      assert_unchanged(code, body)
      assert_equal "fallback", body["data"]["action"]
      assert_equal "report_unreadable", body["data"]["reason"]
      assert_equal ["report_unreadable"], body["warnings"].map { |w| w["code"] }
      refute_includes stdout, PROSE_MARK

      code, body, = triage("done", File.join(@home, "absent-report.json"))
      assert_unchanged(code, body)
      assert_equal "report_unreadable", body["data"]["reason"]
      assert_empty @fake.calls
      assert_empty state_paths
    end
  end

  # sabotage: send or write on a dry run, or leak the key into the request
  # -> red
  def test_dry_run_redacts_and_writes_nothing
    with_home("on") do
      code, body, = triage("done", threshold: 0.1, extra: ["--dry-run"])
      assert_unchanged(code, body)
      data = body["data"]
      assert_equal "dry_run", data["action"]
      assert_equal true, data["dry_run"]
      assert_equal "Bearer [REDACTED]", data["request"]["headers"]["Authorization"]
      assert_equal "report_triage:report_triage@1:#{MODEL}", data["threshold_key"]
      assert_equal false, data["outcome_line_written"]
      assert_equal [REQUEST], body["commands"]
      assert_empty @fake.calls
      assert_empty state_paths
    end
  end

  # sabotage: let budget_unset through to a request, or add on it -> red
  def test_budget_unset_in_shadow_falls_back_without_a_call
    with_home("shadow", extra: { "budget" => {} }) do
      code, body, = triage("done")
      assert_unchanged(code, body)
      assert_equal "budget_exhausted", body["data"]["outcome"]
      assert_equal "fallback", body["data"]["action"]
      assert_includes body["warnings"].map { |w| w["message"] }.join, "budget_unset"
      assert_empty @fake.calls
    end
  end

  # sabotage: let the state-dir SystemCallError escape run -> red
  def test_state_dir_failure_falls_back_with_class_only
    with_home("shadow") do
      FileUtils.mkdir_p(File.dirname(@state_dir))
      File.write(@state_dir, "not a directory")
      @fake.respond(200, body: body_for)
      code, body, stdout, stderr = triage("done")
      assert_unchanged(code, body)
      assert_equal "fallback", body["data"]["action"]
      assert_equal "state_dir_error", body["data"]["reason"]
      warning = body["warnings"].find { |w| w["code"] == "state_dir_error" }
      assert_match(/\(Errno::[A-Z]+\)/, warning["message"])
      refute_includes stdout, @state_dir
      assert_empty stderr
    end
  end

  # sabotage: skip UserConfig.require! -> red
  def test_invalid_config_exits_1
    with_home("maybe") do
      code, body, = triage("done")
      assert_equal 1, code
      assert_equal ["user_config_invalid"], body["blocked"].map { |b| b["code"] }.uniq
      assert_empty @fake.calls
    end
  end

  # ---- usage ---------------------------------------------------------------

  # sabotage: accept any of these argv shapes, or print an envelope for one
  # -> red
  def test_usage_errors_exit_2_with_no_envelope
    with_home("shadow") do
      path = write_report
      good = ["--report", path, "--conductor", "done", "--source", SOURCE]
      [
        ["--conductor", "done", "--source", SOURCE],
        ["--report", path, "--source", SOURCE],
        ["--report", path, "--conductor", "done"],
        ["--report", path, "--conductor", "finished", "--source", SOURCE],
        ["--report", path, "--conductor", "done", "--source", "has spaces"],
        good + ["--threshold", "0"],
        good + ["--threshold", "1.5"],
        good + ["--threshold", "high"],
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
    end
  end

  # sabotage: route --help through Cli.build's handler (it calls exit) -> red
  def test_help_exits_0
    code, body, stdout, = run_cli(["--help"])
    assert_equal 0, code
    assert_nil body
    assert_includes stdout, "report_triage.rb --report PATH"
  end

  # ---- the library ---------------------------------------------------------

  # sabotage: let the CLI's SENT list drift from the client CLI's -> red
  def test_sent_matches_the_client_cli
    assert_equal TypesafeCli::SENT.sort, ReportTriageCli::SENT.sort
  end

  # sabotage: let an unknown report field or a non-Hash through -> red
  def test_state_for_excludes_unknown_fields_and_non_hashes
    assert_nil ReportTriage.state_for("text")
    assert_nil ReportTriage.state_for("futureProse" => "later field")
    state = ReportTriage.state_for("futureProse" => "later", "openQuestions" => ["q"])
    assert_equal({ "report" => { "openQuestions" => ["q"] } }, state)
  end

  # sabotage: read urgency as a trigger for adding -> red
  def test_urgency_never_adds
    ok = Typesafe::Result.new(outcome: "ok", answers: answers(choice: "done", prob: 0.9, score: 3.0))
    read = ReportTriage.interpret(ok, mode: "on", conductor: "done", threshold: 0.1)
    assert_equal false, read["add_needs_you"]
    assert_in_delta 3.0, read["urgency"]
    assert_equal "agree", read["agreement"]
  end

  # The question text version 1 was written against. Changing any
  # instruction or criterion turns this red: bump QUESTION_SET's version in
  # the same change, then re-pin this digest.
  QUESTIONS_V1_DIGEST = "f548cf57c38d9c12"

  # sabotage: edit a question's wording without bumping the version -> red
  # (the digest no longer matches version 1's text)
  def test_question_set_version_is_pinned_to_the_question_text
    require "digest"
    digest = Digest::SHA256.hexdigest(JSON.generate(ReportTriage::QUESTIONS))[0, 16]
    assert_equal({ "id" => "report_triage", "version" => 1 }, ReportTriage::QUESTION_SET)
    assert_equal QUESTIONS_V1_DIGEST, digest,
                 "question text changed: bump QUESTION_SET's version, then re-pin the digest"
    assert ReportTriage::QUESTION_SET.frozen?
    assert_equal %w[blocked done stuck], ReportTriage::QUESTIONS["state"]["criteria"].keys.sort
    assert_equal 4, ReportTriage::QUESTIONS["urgency"]["criteria"].size
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "securerandom"
require "fileutils"
require "tmpdir"
require_relative "../finding_severity"
require_relative "../typesafe"
require_relative "support/user_config_helper"
require_relative "support/fake_http"

# finding_severity.rb driven in-process: FindingSeverityCli.run with
# StringIOs, a tmp HOME holding the machine config, a tmp key file holding a
# sentinel string (never a real key), a tmp state dir, XDG_STATE_HOME pinned
# to a tmpdir, and FakeHTTP as the only transport. Every output captured here
# and every file left under the tmp HOME is swept for the sentinel key; the
# envelope and the state dir are also swept for the findings' own text
# (TEXT_MARK), which must never reach either.
class FindingSeverityTest < Minitest::Test
  include UserConfigHelper

  SENTINEL_KEY = "sentinel-severity-#{SecureRandom.hex(12)}"
  TEXT_MARK = "severitytextmark-#{SecureRandom.hex(6)}"
  RANK_MARK = "rankmark-#{SecureRandom.hex(6)}"
  MODEL = "jev-1.13.0"
  PRICE = { "input" => 0.042, "output" => 0 }.freeze
  REQUEST = "POST https://api.typesafe.ai/v1/systemone"
  SOURCE = "repo:wurk"
  LOWERING = /clear|remov|downgrad|lower|demot/i.freeze

  def setup
    @saved_xdg = ENV.key?("XDG_STATE_HOME") ? ENV["XDG_STATE_HOME"] : :unset
    @xdg = Dir.mktmpdir("wurk-finding-severity-xdg-")
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

  # A tmp HOME whose machine config sets the finding_severity site to `mode`
  # (nil writes no config at all). `extra` merges into the typesafe section.
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
                    "sites" => { "finding_severity" => { "mode" => mode } } }.merge(extra)
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
      refute_includes File.read(path), TEXT_MARK, "finding text found in #{path}"
    end
  end

  def state_paths
    Dir.exist?(@state_dir) ? Dir.glob(File.join(@state_dir, "*")).sort : []
  end

  def finding(rank, must_fix: false, text: "the parser drops the last line #{TEXT_MARK}")
    { "agent" => "wurk-diff-critic", "rank" => rank, "mustFix" => must_fix, "text" => text }
  end

  def write_findings(content)
    path = File.join(@home, "wu-abc-findings.json")
    File.write(path, content.is_a?(String) ? content : JSON.generate(content))
    path
  end

  # A score answer whose most probable level is `level` (0 note, 1
  # should-fix, 2 must-fix) at probability `prob`.
  def answer(level, prob: 0.9)
    rest = ((1.0 - prob) / 2).round(4)
    probs = { "0" => rest, "1" => rest, "2" => rest }
    probs[level.to_s] = prob
    { "severity" => { "type" => "score", "score" => level.to_f, "probabilities" => probs,
                      "confidence" => 0.8 } }
  end

  def body_for(ans, model: MODEL)
    JSON.generate("model" => model, "answers" => ans,
                  "usage" => { "input_tokens" => 300, "output_tokens" => 0 })
  end

  # [exit_code, parsed_envelope_or_nil, stdout, stderr]
  def run_cli(argv, http_class: @fake)
    io = StringIO.new
    code = nil
    out, err = capture_io do
      code = FindingSeverityCli.run(argv, io: io, http_class: http_class)
    end
    @outputs << io.string << out << err
    body = io.string.start_with?("{") ? JSON.parse(io.string) : nil
    # A dry run's request.body carries the caller's own input back to it by
    # design (the client contract); nothing else in the envelope may.
    rest = body ? JSON.generate(body.merge("data" => body["data"].reject { |k, _| k == "request" })) : io.string
    refute_includes rest, TEXT_MARK, "finding text in the envelope"
    [code, body, io.string + out, err]
  end

  def score(findings, threshold: nil, extra: [])
    path = findings.is_a?(String) ? findings : write_findings(findings)
    argv = ["--findings", path, "--source", SOURCE]
    argv += ["--threshold", threshold.to_s] unless threshold.nil?
    run_cli(argv + extra)
  end

  def decisions
    path = Dir.glob(File.join(@state_dir, "decisions-*.jsonl")).first
    path ? File.readlines(path).map { |l| JSON.parse(l) } : []
  end

  def counts(must: 0, should: 0, note: 0, unranked: 0)
    { "mustFix" => must, "shouldFix" => should, "note" => note, "unranked" => unranked }
  end

  def only(body)
    assert_equal 1, body["data"]["findings"].size
    body["data"]["findings"][0]
  end

  # ---- off: the default, and the count still exists -------------------------

  # sabotage: default the site to shadow, or skip counting when off -> red
  def test_no_config_is_site_off_and_counts_locally
    with_home(nil) do
      code, body, = score([finding("must-fix", must_fix: true), finding("should-fix"),
                           finding("note"), finding("major")])
      assert_equal 0, code
      assert_empty body["blocked"]
      data = body["data"]
      assert_equal "off", data["mode"]
      assert_equal "site_off", data["outcome"]
      assert_equal counts(must: 1, should: 1, note: 1, unranked: 1), data["findings_by_level"]
      assert(data["findings"].all? { |f| f["action"] == "site_off" })
      assert_equal 0, data["calls"]
      assert_empty body["warnings"]
      assert_empty body["commands"]
      assert_empty @fake.calls
      assert_empty state_paths
      refute Dir.exist?(File.join(@xdg, "wurk")), "default state dir created"
    end
  end

  # sabotage: key the count by Jev instead of the critic when off, or drop a
  # bucket from the field -> red
  def test_counts_have_every_bucket_even_when_empty
    with_home(nil) do
      _, body, = score([])
      assert_equal counts, body["data"]["findings_by_level"]
      assert_includes body["data"]["summary_line"], "0 finding(s), mode off"
    end
  end

  # ---- shadow: records both levels, acts on neither -------------------------

  # sabotage: act on Jev's level in shadow, or record Jev's level as the
  # decision -> red
  def test_shadow_disagreement_both_ways_keeps_the_critic_level
    with_home("shadow") do
      # Jev lower than the critic, then Jev higher than the critic.
      @fake.respond(200, body: body_for(answer(0, prob: 0.99)))
      @fake.respond(200, body: body_for(answer(2, prob: 0.99)))
      code, body, = score([finding("must-fix", must_fix: true), finding("note")], threshold: 0.5)
      assert_equal 0, code
      data = body["data"]
      down, up = data["findings"]
      assert_equal %w[must-fix note must-fix note],
                   [down["critic_level"], down["jev_level"], up["jev_level"], up["level"]]
      assert_equal "must-fix", down["level"]
      [down, up].each do |f|
        assert_equal "shadow_logged", f["action"]
        assert_equal "disagree", f["agreement"]
      end
      assert_equal counts(must: 1, note: 1), data["findings_by_level"]
      assert_equal 0, data["raised"]
      assert_equal 2, data["calls"]
      assert_equal [REQUEST], body["commands"]
      assert_equal 2, data["outcome_lines_written"]
      outcomes = decisions.select { |l| l["kind"] == "outcome" }
      assert_equal %w[must-fix note], outcomes.map { |l| l["decision"] }
      assert_equal %w[disagree disagree], outcomes.map { |l| l["agreement"] }
      decisions.select { |l| l["kind"] == "decision" }.each do |l|
        refute l.key?("state"), "decision line carries state text"
      end
    end
  end

  # sabotage: compute agreement against Jev's own level -> red
  def test_shadow_agreement_and_unranked_is_n_a
    with_home("shadow") do
      @fake.respond(200, body: body_for(answer(1)))
      @fake.respond(200, body: body_for(answer(1)))
      _, body, = score([finding("Should Fix"), finding(nil)])
      agreed, unranked = body["data"]["findings"]
      assert_equal "should-fix", agreed["critic_level"]
      assert_equal "agree", agreed["agreement"]
      assert_equal "unranked", unranked["critic_level"]
      assert_equal "n/a", unranked["agreement"]
      assert_equal "unranked", unranked["level"]
    end
  end

  # ---- on: raise only, never downgrade a must-fix -----------------------------

  # sabotage: let Jev's lower level replace a critic's must-fix -> red
  def test_on_must_fix_stays_must_fix_whatever_jev_says
    [0, 1].each do |jev|
      with_home("on") do
        @fake.respond(200, body: body_for(answer(jev, prob: 0.99)))
        code, body, = score([finding("note", must_fix: true)], threshold: 0.05)
        assert_equal 0, code
        f = only(body)
        assert_equal "must-fix", f["critic_level"], "the agent's must-fix declaration wins"
        assert_equal "must-fix", f["level"]
        assert_equal "no_change", f["action"]
        assert_equal "critic_must_fix", f["reason"]
        assert_equal "disagree", f["agreement"]
        assert_equal counts(must: 1), body["data"]["findings_by_level"]
      end
    end
  end

  # sabotage: let Jev lower a should-fix to a note -> red
  def test_on_jev_lower_never_lowers
    with_home("on") do
      @fake.respond(200, body: body_for(answer(0, prob: 0.99)))
      _, body, = score([finding("should-fix")], threshold: 0.05)
      f = only(body)
      assert_equal "should-fix", f["level"]
      assert_equal "no_change", f["action"]
      assert_equal "jev_not_higher", f["reason"]
      assert_equal counts(should: 1), body["data"]["findings_by_level"]
    end
  end

  # sabotage: drop the threshold comparison, or refuse to raise -> red
  def test_on_jev_higher_raises_at_threshold
    with_home("on") do
      @fake.respond(200, body: body_for(answer(2, prob: 0.9)))
      @fake.respond(200, body: body_for(answer(1, prob: 0.95)))
      _, body, = score([finding("note"), finding("wibble")], threshold: 0.9)
      note, unranked = body["data"]["findings"]
      assert_equal "raised", note["action"]
      assert_equal "must-fix", note["level"]
      assert_equal "raised", unranked["action"]
      assert_equal "should-fix", unranked["level"]
      assert_equal counts(must: 1, should: 1), body["data"]["findings_by_level"]
      assert_equal 2, body["data"]["raised"]
      assert_equal %w[raised raised],
                   decisions.select { |l| l["kind"] == "outcome" }.map { |l| l["action"] }
    end
  end

  # sabotage: compare with > instead of >=, or default a threshold -> red
  def test_on_threshold_edges_and_no_threshold
    with_home("on") do
      @fake.respond(200, body: body_for(answer(2, prob: 0.89)))
      _, body, = score([finding("note")], threshold: 0.9)
      assert_equal "below_threshold", only(body)["reason"]
      assert_equal "note", only(body)["level"]
    end
    with_home("on") do
      @fake.respond(200, body: body_for(answer(2, prob: 0.99)))
      _, body, = score([finding("note")])
      assert_equal "no_threshold", only(body)["reason"]
      assert_equal counts(note: 1), body["data"]["findings_by_level"]
      assert_nil body["data"]["threshold"]
    end
  end

  # sabotage: add an action that lowers or clears a level -> red
  def test_no_action_lowers
    FindingSeverity::ACTIONS.each { |a| refute_match LOWERING, a }
    ok = ->(level) { Typesafe::Result.new(outcome: "ok", answers: answer(level, prob: 0.99)) }
    FindingSeverity::LEVELS.each_with_index do |critic, ci|
      3.times do |jev|
        %w[shadow on].each do |mode|
          read = FindingSeverity.interpret(ok.call(jev), mode: mode, critic_level: critic,
                                                         threshold: 0.05)
          assert_operator FindingSeverity.rank_of(read["level"]), :>=, ci,
                          "#{mode}: critic #{critic}, jev #{jev}"
        end
      end
    end
  end

  # ---- failures keep the critic's level ------------------------------------

  # sabotage: read a non-ok outcome as an answer, retry, keep calling after a
  # failure, or exit non-zero -> red
  def test_every_jev_failure_falls_back_and_stops_calling
    cases = {
      "timeout" => ->(f) { f.raise_error(Net::ReadTimeout.new) },
      "other_status" => ->(f) { f.respond(500) },
      "rate_limited" => ->(f) { f.respond(429, headers: { "Retry-After" => "5" }) },
      "overloaded" => ->(f) { f.respond(529) },
      "transport" => ->(f) { f.raise_error(Errno::ECONNREFUSED.new) },
      "undecodable" => ->(f) { f.respond(200, body: "not json") },
      "model_mismatch" => ->(f) { f.respond(200, body: body_for(answer(2), model: "jev-9.9.9")) }
    }
    cases.each do |outcome, script|
      @fake = FakeHTTP.new
      with_home("on") do
        script.call(@fake)
        code, body, = score([finding("note"), finding("should-fix")], threshold: 0.05)
        assert_equal 0, code
        assert_empty body["blocked"]
        data = body["data"]
        assert_equal outcome, data["outcome"], outcome
        first, second = data["findings"]
        assert_equal ["fallback", outcome], [first["action"], first["reason"]], outcome
        assert_equal %w[fallback stopped], [second["action"], second["reason"]], outcome
        assert_equal 1, @fake.calls.size, "#{outcome}: exactly one attempt, then stop"
        assert_equal counts(should: 1, note: 1), data["findings_by_level"], outcome
        assert_includes body["warnings"].map { |w| w["code"] }, "jev_fallback", outcome
      end
    end
  end

  # sabotage: accept a level outside the three, or default a missing
  # probability -> red
  def test_malformed_answers_fall_back
    missing = answer(2)
    missing["severity"]["probabilities"].delete("1")
    out_of_range = answer(2, prob: 1.5)
    [missing, out_of_range, { "other" => {} }].each do |ans|
      @fake = FakeHTTP.new
      with_home("on") do
        @fake.respond(200, body: body_for(ans))
        _, body, = score([finding("note")], threshold: 0.05)
        f = only(body)
        assert_equal %w[fallback answer_malformed note], [f["action"], f["reason"], f["level"]]
      end
    end
  end

  # sabotage: drop the source from the input -> red
  def test_restricted_source_sends_nothing
    with_home("on", extra: { "restricted_sources" => [SOURCE] }) do
      code, body, = score([finding("note")], threshold: 0.05)
      assert_equal 0, code
      assert_equal "source_restricted", body["data"]["outcome"]
      assert_equal "fallback", only(body)["action"]
      assert_equal counts(note: 1), body["data"]["findings_by_level"]
      assert_empty @fake.calls
      assert_empty body["commands"]
    end
  end

  # sabotage: send the rank label or the agent name to Jev -> red
  def test_request_state_is_the_finding_text_only
    with_home("shadow") do
      @fake.respond(200, body: body_for(answer(1)))
      score([{ "agent" => "wurk-test-critic", "rank" => RANK_MARK, "mustFix" => false,
               "text" => "weak test #{TEXT_MARK}" }])
      sent = JSON.parse(@fake.calls[0].request.body)
      assert_equal({ "finding" => "weak test #{TEXT_MARK}" }, sent["state"])
      assert_equal %w[severity], sent["questions"].keys
      assert_equal MODEL, sent["model"]
      refute_includes JSON.generate(sent), RANK_MARK
      refute_includes JSON.generate(sent), "wurk-test-critic"
    end
  end

  # sabotage: call Jev on a finding with no text, or count only judged ones
  # -> red
  def test_blank_text_is_counted_but_not_sent
    with_home("on") do
      code, body, = score([finding("should-fix", text: "  ")], threshold: 0.05)
      assert_equal 0, code
      assert_equal %w[skipped nothing_to_judge], [only(body)["action"], only(body)["reason"]]
      assert_equal counts(should: 1), body["data"]["findings_by_level"]
      assert_empty @fake.calls
    end
  end

  # sabotage: echo file text in a warning, or count a malformed file -> red
  def test_unreadable_findings_count_nothing
    with_home("on") do
      ["{\"text\": \"#{TEXT_MARK}\"}", "not json #{TEXT_MARK}", "[\"#{TEXT_MARK}\"]"].each do |raw|
        code, body, = score(write_findings(raw))
        assert_equal 0, code
        assert_nil body["data"]["findings_by_level"]
        assert_equal ["findings_unreadable"], body["warnings"].map { |w| w["code"] }
      end
      _, body, = score(File.join(@home, "absent.json"))
      assert_nil body["data"]["findings_by_level"]
      assert_empty @fake.calls
    end
  end

  # sabotage: lift the cap -> red (an unscripted start raises)
  def test_call_cap_bounds_one_invocation
    with_home("shadow") do
      FindingSeverityCli::MAX_CALLS.times { @fake.respond(200, body: body_for(answer(0))) }
      _, body, = score(Array.new(FindingSeverityCli::MAX_CALLS + 2) { finding("note") })
      data = body["data"]
      assert_equal FindingSeverityCli::MAX_CALLS, @fake.calls.size
      assert_equal %w[call_cap call_cap], data["findings"].last(2).map { |f| f["reason"] }
      assert_equal counts(note: FindingSeverityCli::MAX_CALLS + 2), data["findings_by_level"]
    end
  end

  # sabotage: send or write on a dry run, or leak the key -> red
  def test_dry_run_redacts_and_writes_nothing
    with_home("on") do
      code, body, = score([finding("note"), finding("should-fix")], threshold: 0.05,
                                                                    extra: ["--dry-run"])
      assert_equal 0, code
      data = body["data"]
      assert_equal %w[dry_run dry_run], data["findings"].map { |f| f["action"] }
      assert_equal "Bearer [REDACTED]", data["request"]["headers"]["Authorization"]
      assert_equal "finding_severity:finding_severity@1:#{MODEL}", data["threshold_key"]
      assert_equal counts(should: 1, note: 1), data["findings_by_level"]
      assert_equal 0, data["outcome_lines_written"]
      assert_equal [REQUEST], body["commands"]
      assert_empty @fake.calls
      assert_empty state_paths
    end
  end

  # sabotage: let the state-dir SystemCallError escape run, or keep a raise
  # after it -> red
  def test_state_dir_failure_falls_back_with_class_only
    with_home("on") do
      FileUtils.mkdir_p(File.dirname(@state_dir))
      File.write(@state_dir, "not a directory")
      @fake.respond(200, body: body_for(answer(2, prob: 0.99)))
      code, body, stdout, stderr = score([finding("note")], threshold: 0.05)
      assert_equal 0, code
      f = only(body)
      assert_equal %w[fallback state_dir_error note], [f["action"], f["reason"], f["level"]]
      warning = body["warnings"].find { |w| w["code"] == "state_dir_error" }
      assert_match(/\(Errno::[A-Z]+\)/, warning["message"])
      refute_includes stdout, @state_dir
      assert_empty stderr
    end
  end

  # sabotage: skip UserConfig.require! -> red
  def test_invalid_config_exits_1
    with_home("maybe") do
      code, body, = score([finding("note")])
      assert_equal 1, code
      assert_equal ["user_config_invalid"], body["blocked"].map { |b| b["code"] }.uniq
      assert_empty @fake.calls
    end
  end

  # ---- usage ---------------------------------------------------------------

  # sabotage: accept any of these argv shapes, or print an envelope -> red
  def test_usage_errors_exit_2_with_no_envelope
    with_home("shadow") do
      path = write_findings([])
      good = ["--findings", path, "--source", SOURCE]
      [
        ["--source", SOURCE],
        ["--findings", path],
        ["--findings", path, "--source", "has spaces"],
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
    assert_includes stdout, "finding_severity.rb --findings PATH"
  end

  # ---- the library ---------------------------------------------------------

  # sabotage: let the CLI's SENT list drift from the client CLI's -> red
  def test_sent_matches_the_client_cli
    assert_equal TypesafeCli::SENT.sort, FindingSeverityCli::SENT.sort
  end

  # sabotage: let a label win over the agent's must-fix, or accept a foreign
  # word as a level -> red
  def test_critic_level_mapping
    assert_equal "must-fix", FindingSeverity.critic_level("rank" => "note", "mustFix" => true)
    assert_equal "must-fix", FindingSeverity.critic_level("rank" => "MUST_FIX")
    assert_equal "should-fix", FindingSeverity.critic_level("rank" => " should fix ")
    assert_equal "unranked", FindingSeverity.critic_level("rank" => "blocker")
    assert_equal "unranked", FindingSeverity.critic_level("rank" => nil, "mustFix" => "yes")
    assert_equal "unranked", FindingSeverity.critic_level("text")
  end

  # The question text version 1 was written against. Changing any
  # instruction or criterion turns this red: bump QUESTION_SET's version in
  # the same change, then re-pin this digest.
  QUESTIONS_V1_DIGEST = "bc5086673bc18370"

  # sabotage: edit the question's wording without bumping the version -> red
  def test_question_set_version_is_pinned_to_the_question_text
    require "digest"
    digest = Digest::SHA256.hexdigest(JSON.generate(FindingSeverity::QUESTIONS))[0, 16]
    assert_equal({ "id" => "finding_severity", "version" => 1 }, FindingSeverity::QUESTION_SET)
    assert_equal QUESTIONS_V1_DIGEST, digest,
                 "question text changed: bump QUESTION_SET's version, then re-pin the digest"
    assert FindingSeverity::QUESTION_SET.frozen?
    assert_equal 3, FindingSeverity::QUESTIONS["severity"]["criteria"].size
    assert_equal FindingSeverity::LEVELS.size, FindingSeverity::QUESTIONS["severity"]["criteria"].size
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "json"
require "securerandom"
require_relative "../lib/typesafe"
require_relative "support/user_config_helper"
require_relative "support/fake_http"

# Client core tests. Every case runs against FakeHTTP and a sentinel key
# built at load; no real key file or network is ever reached.
class TypesafeClientTest < Minitest::Test
  SENTINEL_KEY = "sentinel-#{SecureRandom.hex(12)}"
  MODEL = "jev-1.13.0"
  INPUT = {
    "state" => "synthetic state text",
    "questions" => { "q1" => { "type" => "choice", "instructions" => "pick",
                                "criteria" => %w[a b] } }
  }.freeze
  GOOD_BODY = JSON.generate(
    "model" => MODEL,
    "answers" => { "q1" => { "choice" => "a" } },
    "usage" => { "input_tokens" => 400, "output_tokens" => 0 }
  )

  def setup
    @fake = FakeHTTP.new
  end

  def client(deadline_ms: 1500, key: SENTINEL_KEY, http_class: @fake)
    Typesafe::Client.new(key: key, model: MODEL, deadline_ms: deadline_ms,
                         http_class: http_class)
  end

  def call_once
    result = client.post(INPUT)
    refute_includes result.to_h.to_json, SENTINEL_KEY
    assert_equal 1, @fake.calls.size, "exactly one HTTP attempt, no retries"
    result
  end

  # sabotage: (all cases) put the key in any Result field -> red via call_once
  # sabotage: return "ok" without reading answers, or drop usage parsing -> red
  def test_200_valid_body_is_ok
    @fake.respond(200, body: GOOD_BODY)
    r = call_once
    assert_equal "ok", r.outcome
    assert_equal({ "q1" => { "choice" => "a" } }, r.answers)
    assert_equal MODEL, r.served_model
    assert_equal({ "input_tokens" => 400, "output_tokens" => 0 }, r.usage)
    assert_equal 200, r.http_status
    assert_kind_of Integer, r.elapsed_ms
  end

  # sabotage: map 401 to other_status -> red
  def test_401_and_403_are_unauthorized
    [401, 403].each do |code|
      @fake = FakeHTTP.new.respond(code)
      r = call_once
      assert_equal "unauthorized", r.outcome
      assert_equal code, r.http_status
    end
  end

  # sabotage: map 422 to other_status -> red
  def test_422_is_rejected
    @fake.respond(422)
    assert_equal "rejected", call_once.outcome
  end

  # sabotage: drop the Retry-After passthrough, or retry on 429 -> red
  def test_429_passes_retry_after_through
    @fake.respond(429, headers: { "Retry-After" => " 7 " })
    r = call_once
    assert_equal "rate_limited", r.outcome
    assert_equal "7", r.retry_after
  end

  # sabotage: default retry_after to "0" instead of nil -> red
  def test_429_without_header_has_nil_retry_after
    @fake.respond(429)
    r = call_once
    assert_equal "rate_limited", r.outcome
    assert_nil r.retry_after
  end

  # sabotage: stop capping the header at 64 chars -> red
  def test_429_retry_after_is_capped
    @fake.respond(429, headers: { "Retry-After" => "9" * 200 })
    assert_equal 64, call_once.retry_after.length
  end

  # sabotage: retry on 529, or map it to other_status -> red
  def test_529_is_overloaded
    @fake.respond(529)
    r = call_once
    assert_equal "overloaded", r.outcome
    assert_equal 529, r.http_status
  end

  # sabotage: fold 418 into a named outcome -> red
  def test_other_statuses_are_other_status
    [500, 418].each do |code|
      @fake = FakeHTTP.new.respond(code)
      r = call_once
      assert_equal "other_status", r.outcome
      assert_equal code, r.http_status
    end
  end

  # sabotage: drop Net::WriteTimeout (or OpenTimeout) from the timeout rescue -> red
  def test_socket_timeouts_are_timeout
    [Net::ReadTimeout, Net::OpenTimeout, Net::WriteTimeout].each do |klass|
      @fake = FakeHTTP.new.raise_error(klass.new("boom"))
      r = call_once
      assert_equal "timeout", r.outcome, klass.name
      assert_equal klass.name, r.reason
    end
  end

  # sabotage: remove the Timeout.timeout guard around start -> red (0.5s hang)
  def test_overall_deadline_guard_fires
    @fake.hang(0.5)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    r = client(deadline_ms: 50).post(INPUT)
    refute_includes r.to_h.to_json, SENTINEL_KEY
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    assert_equal 1, @fake.calls.size
    assert_equal "timeout", r.outcome
    assert_operator took, :<, 0.4
  end

  # sabotage: let a plain RuntimeError (or SSLError) escape the rescue list -> red
  def test_transport_errors_never_raise
    errors = [Errno::ECONNREFUSED.new, SocketError.new("dns"),
              OpenSSL::SSL::SSLError.new("tls"), EOFError.new,
              Net::HTTPHeaderSyntaxError.new("hdr"), RuntimeError.new("odd")]
    errors.each do |err|
      @fake = FakeHTTP.new.raise_error(err)
      r = call_once
      assert_equal "transport", r.outcome, err.class.name
      assert_equal err.class.name, r.reason
    end
  end

  # sabotage: put the exception message in reason -> red
  def test_reason_never_carries_the_message
    @fake.raise_error(RuntimeError.new("secret #{SENTINEL_KEY} url"))
    r = call_once
    refute_includes r.reason, SENTINEL_KEY
    refute_includes r.reason, "secret"
  end

  # sabotage: replace the ArgumentError guard with a call anyway -> red
  def test_nil_key_raises_before_any_start
    assert_raises(ArgumentError) { client(key: nil).post(INPUT) }
    assert_empty @fake.calls
  end

  # sabotage: return ok with empty answers for a non-JSON body -> red
  def test_undecodable_bodies
    ["not json", "[]", JSON.generate("model" => MODEL),
     JSON.generate("model" => MODEL, "answers" => [1])].each do |text|
      @fake = FakeHTTP.new.respond(200, body: text)
      r = call_once
      assert_equal "undecodable", r.outcome, text
      assert_nil r.answers
    end
  end

  # sabotage: skip the served-model comparison -> red
  def test_model_mismatch_discards_answers_but_keeps_usage
    wrong = JSON.generate("model" => "jev-9.9.9", "answers" => { "q1" => {} },
                          "usage" => { "input_tokens" => 12, "output_tokens" => 0 })
    absent = JSON.generate("answers" => { "q1" => {} })
    [wrong, absent].each do |text|
      @fake = FakeHTTP.new.respond(200, body: text)
      r = call_once
      assert_equal "model_mismatch", r.outcome
      assert_nil r.answers
    end
    @fake = FakeHTTP.new.respond(200, body: wrong)
    r = call_once
    assert_equal "jev-9.9.9", r.served_model
    assert_equal 12, r.usage["input_tokens"]
  end

  # sabotage: start with use_ssl false or a different timeout, or send -latest -> red
  def test_start_options_and_request_shape
    @fake.respond(200, body: GOOD_BODY)
    call_once
    call = @fake.calls.first
    assert_equal "api.typesafe.ai", call.host
    assert_equal 443, call.port
    assert_equal true, call.opts[:use_ssl]
    %i[open_timeout read_timeout write_timeout].each do |k|
      assert_equal 1.5, call.opts[k]
    end
    req = call.request
    assert_equal "POST", req.method
    assert_equal "/v1/systemone", req.path
    assert_equal "Bearer #{SENTINEL_KEY}", req["Authorization"]
    assert_equal "application/json", req["Content-Type"]
    sent = JSON.parse(req.body)
    assert_equal MODEL, sent["model"]
    assert_equal INPUT["state"], sent["state"]
    assert_equal INPUT["questions"], sent["questions"]
  end

  # sabotage: drop the prepend from support/fake_http.rb -> red at the ancestors
  # assertion, before any call can reach the real host
  def test_network_lock_blocks_the_default_http_class
    assert_includes Net::HTTP.singleton_class.ancestors, FakeHTTP::NetworkLock
    r = Typesafe::Client.new(key: SENTINEL_KEY, model: MODEL, deadline_ms: 1500).post(INPUT)
    refute_includes r.to_h.to_json, SENTINEL_KEY
    assert_equal "transport", r.outcome
    assert_equal "FakeHTTP::RealNetworkForbidden", r.reason
  end

  # sabotage: put the real key in redacted_request or in Client#inspect -> red
  def test_redacted_request_and_inspect
    c = client
    req = c.redacted_request(INPUT)
    assert_equal "Bearer [REDACTED]", req[:headers]["Authorization"]
    assert_equal MODEL, req[:body]["model"]
    refute_includes JSON.generate(req), SENTINEL_KEY
    refute_includes c.inspect, SENTINEL_KEY
    refute_includes c.to_s, SENTINEL_KEY
  end
end

# Policy layer tests: Typesafe.judge and Typesafe.record_outcome. Every test
# pins XDG_STATE_HOME to a tmpdir, names a tmp state_dir and a tmp key_path
# holding the sentinel key, and uses FakeHTTP as the only transport. Every
# test's teardown sweeps its Results, captured output and every file under
# its tmpdir (the key file aside) for the sentinel key.
class TypesafePolicyTest < Minitest::Test
  SENTINEL_KEY = TypesafeClientTest::SENTINEL_KEY
  MODEL = "jev-1.13.0"
  STATE_MARK = "statemark-#{SecureRandom.hex(6)}"
  QUESTION_MARK = "questionmark-#{SecureRandom.hex(6)}"
  SOURCE_MARK = "sourcemark-#{SecureRandom.hex(6)}"
  TEXT_MARKS = [STATE_MARK, QUESTION_MARK, SOURCE_MARK].freeze
  NOW = Time.utc(2026, 9, 15, 12, 0, 0)
  PRICE = { "input" => 0.042, "output" => 0 }.freeze
  GOOD_BODY = JSON.generate(
    "model" => MODEL,
    "answers" => { "q1" => { "choice" => "a" } },
    "usage" => { "input_tokens" => 400, "output_tokens" => 0 }
  )

  def setup
    @saved_xdg = ENV.key?("XDG_STATE_HOME") ? ENV["XDG_STATE_HOME"] : :unset
    @tmp = Dir.mktmpdir("wurk-typesafe-test-")
    ENV["XDG_STATE_HOME"] = File.join(@tmp, "xdg")
    @state_dir = File.join(@tmp, "state")
    @key_path = File.join(@tmp, "typesafe-api-token")
    write_key(@key_path, "#{SENTINEL_KEY}\n")
    @key_files = [@key_path]
    @fake = FakeHTTP.new
    @outputs = []
  end

  def teardown
    sweep_for_sentinel
  ensure
    if @saved_xdg == :unset
      ENV.delete("XDG_STATE_HOME")
    else
      ENV["XDG_STATE_HOME"] = @saved_xdg
    end
    FileUtils.chmod_R(0o700, @tmp)
    FileUtils.remove_entry(@tmp)
  end

  # ---- helpers -------------------------------------------------------------

  def write_key(path, text, mode: 0o600)
    File.write(path, text)
    File.chmod(mode, path)
  end

  def config(budget: { "monthly_usd" => 1.0 }, prices: { MODEL => PRICE },
             sites: { "review" => { "mode" => "shadow" } }, **extra)
    section = { "key_path" => @key_path, "state_dir" => @state_dir, "sites" => sites }
    section["budget"] = budget unless budget.nil?
    extra.each { |k, v| section[k.to_s] = v }
    raw = { "typesafe" => section }
    raw["metrics"] = { "prices" => prices } unless prices.nil?
    cfg = UserConfig.new(path: "(fixture)", raw: raw, exists: true)
    assert_empty cfg.errors, "fixture config must be valid"
    cfg
  end

  def input(**over)
    {
      "state" => "synthetic state #{STATE_MARK}",
      "questions" => { "q1" => { "type" => "choice",
                                  "instructions" => "pick one #{QUESTION_MARK}",
                                  "criteria" => %w[a b] } },
      "question_set" => { "id" => "triage", "version" => 1 },
      "source" => SOURCE_MARK
    }.merge(over.each_with_object({}) { |(k, v), h| h[k.to_s] = v })
  end

  def judge(cfg, inp = input, site: "review", now: NOW, **opts)
    result = nil
    out, err = capture_io do
      result = Typesafe.judge(config: cfg, input: inp, site: site, now: now,
                              http_class: @fake, **opts)
    end
    @outputs << out << err << result.to_h.to_json
    result
  end

  def refused(result, outcome, reason = :any)
    assert_equal outcome, result.outcome
    assert_equal reason, result.reason unless reason == :any
    assert_empty @fake.calls, "#{outcome} must refuse before any request"
    result
  end

  def jsonl(name)
    path = File.join(@state_dir, name)
    return [] unless File.file?(path)

    File.readlines(path).map { |l| JSON.parse(l) }
  end

  def ledger(month = "2026-09")
    jsonl("ledger-#{month}.jsonl")
  end

  def decisions(month = "2026-09")
    jsonl("decisions-#{month}.jsonl")
  end

  def seed_ledger(lines, month: "2026-09")
    FileUtils.mkdir_p(@state_dir)
    File.open(File.join(@state_dir, "ledger-#{month}.jsonl"), "a") do |f|
      lines.each { |l| f.write(l.is_a?(String) ? "#{l}\n" : "#{JSON.generate(l)}\n") }
    end
  end

  def seed_line(ts, cost: 0.0)
    { "ts" => ts.utc.iso8601(3), "month" => ts.utc.strftime("%Y-%m"), "call_id" => "seed",
      "site" => "review", "model" => MODEL, "outcome" => "ok", "cost_usd" => cost,
      "cost_estimated" => false, "input_tokens" => 1, "output_tokens" => 0 }
  end

  # The no-usage bound for `inp` at `price`, computed independently of the
  # library from the documented rule.
  def bound_for(inp, price)
    body = { "state" => inp["state"], "model" => MODEL, "questions" => inp["questions"] }
    JSON.generate(body).bytesize * price["input"] / 1e6 +
      256 * inp["questions"].size * price["output"] / 1e6
  end

  # Records every File class-method touch of `path` for the block.
  def trap_file_access(path)
    touched = []
    methods = %i[file? stat lstat readable? exist? read open foreach readlines]
    wrap = lambda do |list, &body|
      return body.call if list.empty?

      name = list.first
      original = File.method(name)
      File.stub(name, lambda { |*args, &blk|
        touched << name if args.first.to_s == path
        original.call(*args, &blk)
      }) { wrap.call(list.drop(1), &body) }
    end
    wrap.call(methods) { yield }
    touched
  end

  def root?
    Process.uid.zero?
  end

  def sweep_for_sentinel
    @outputs.each { |text| refute_includes text.to_s, SENTINEL_KEY }
    Dir.glob(File.join(@tmp, "**", "*"), File::FNM_DOTMATCH).each do |path|
      next unless File.file?(path)
      next if @key_files.include?(path)

      File.chmod(0o600, path)
      refute_includes File.read(path), SENTINEL_KEY, "sentinel key found in #{path}"
    end
  end

  # ---- 1. mode ------------------------------------------------------------

  # sabotage: move the mode check below the key step (or log site_off) -> red:
  # the directory key path would be read, or a state file would appear
  def test_site_off_touches_nothing
    dark = UserConfig.new(path: "(fixture)", raw: {}, exists: false)
    r = judge(dark)
    refused(r, "site_off")
    assert_equal "off", r.mode
    refute Dir.exist?(File.join(ENV["XDG_STATE_HOME"], "wurk")), "default state dir created"

    key_dir = File.join(@tmp, "key-is-a-directory")
    FileUtils.mkdir_p(key_dir)
    cfg = config(sites: { "other" => { "mode" => "shadow" }, "quiet" => { "mode" => "off" } })
    cfg.raw["typesafe"]["key_path"] = key_dir
    %w[review quiet].each do |site|
      touched = trap_file_access(key_dir) { refused(judge(cfg, site: site), "site_off") }
      assert_empty touched, "site_off touched the key path"
    end
    refute Dir.exist?(@state_dir), "site_off wrote a ledger or decision file"
  end

  # ---- 3. privacy ---------------------------------------------------------

  # sabotage: check restricted_sources only when mode == "on" (or log text on a
  # refusal) -> red for shadow, or a mark in the decision line
  def test_source_restricted_refuses_shadow_and_on_alike
    %w[shadow on].each do |mode|
      [false, true].each do |log_state|
        FileUtils.rm_rf(@state_dir)
        cfg = config(sites: { "review" => { "mode" => mode } },
                     restricted_sources: [SOURCE_MARK], log_state: log_state)
        r = refused(judge(cfg), "source_restricted")
        assert_nil r.reason
        assert_empty ledger, "a refusal spends no ledger line"
        lines = decisions
        assert_equal 1, lines.size
        assert_equal "source_restricted", lines[0]["outcome"]
        text = File.read(File.join(@state_dir, "decisions-2026-09.jsonl"))
        TEXT_MARKS.each { |m| refute_includes text, m, "#{mode}/#{log_state}" }
      end
    end

    cfg = config(restricted_sources: ["some-other-label"])
    @fake.respond(200, body: GOOD_BODY)
    assert_equal "ok", judge(cfg).outcome
    no_source = input
    no_source.delete("source")
    cfg = config(restricted_sources: [SOURCE_MARK])
    @fake.respond(200, body: GOOD_BODY)
    assert_equal "ok", judge(cfg, no_source).outcome, "absent source is unlabelled and allowed"
    assert_equal 2, @fake.calls.size
  end

  # ---- 2. input -----------------------------------------------------------

  # sabotage: drop any one validate_input rule -> red for that case (it would
  # reach FakeHTTP, which has no scripted step)
  def test_input_invalid_rules_refuse_before_any_request
    no_state = input
    no_state.delete("state")
    no_qs = input
    no_qs.delete("question_set")
    cases = {
      "state" => no_state,
      "questions" => input(questions: {}),
      "questions.q1.type" => input(questions: { "q1" => { "type" => "essay", "instructions" => "x" } }),
      "questions.q1.instructions" => input(questions: { "q1" => { "type" => "noul", "instructions" => " " } }),
      "questions.id" => input(questions: { "Bad Id" => { "type" => "noul", "instructions" => "x" } })
    }
    cases["question_set"] = no_qs
    cases["question_set "] = input(question_set: { "id" => "triage", "version" => 0 })
    cases["question_set  "] = input(question_set: { "id" => "triage", "version" => "1" })
    cases["source"] = input(source: "")
    cases["input"] = "not an object"
    cfg = config
    cases.each do |reason, inp|
      r = refused(judge(cfg, inp), "input_invalid", reason.strip)
      TEXT_MARKS.each { |m| refute_includes r.to_h.to_json, m }
    end
    assert_empty ledger

    @fake.respond(200, body: GOOD_BODY)
    r = judge(cfg, no_qs, site: nil)
    assert_equal "ok", r.outcome, "a probe call needs no question_set"
    assert_equal "probe", r.mode
    assert_nil r.threshold_key
    assert_equal 1, @fake.calls.size
  end

  # ---- 6. key -------------------------------------------------------------

  # sabotage: treat a blank or unreadable key file as a key (or skip the
  # File.file? check) -> red; each config has a valid budget and price, so the
  # refusal can only come from the key step
  def test_key_missing_absent_blank_unreadable
    cfg = config
    File.delete(@key_path)
    refused(judge(cfg), "key_missing", "absent")

    write_key(@key_path, "  \n\n")
    refused(judge(cfg), "key_missing", "blank")

    unless root?
      write_key(@key_path, "#{SENTINEL_KEY}\n", mode: 0o000)
      refused(judge(cfg), "key_missing", "unreadable")
    end
    assert_empty ledger, "a key refusal spends no ledger line"
    assert_equal(%w[key_missing], decisions.map { |l| l["outcome"] }.uniq)
  end

  # sabotage: stop warning on a group- or world-readable key file -> red
  def test_open_key_mode_warns_but_does_not_refuse
    write_key(@key_path, "#{SENTINEL_KEY}\n", mode: 0o644)
    @fake.respond(200, body: GOOD_BODY)
    r = judge(config)
    assert_equal "ok", r.outcome
    assert_includes r.warnings, "key_mode_open"
  end

  # sabotage: run the key step before the budget (or rate) step -> red: the
  # outcome turns key_missing and the trap records a stat of the key path
  def test_budget_and_rate_run_before_the_key_is_touched
    File.delete(@key_path)
    cfg = config(budget: nil)
    touched = trap_file_access(@key_path) do
      refused(judge(cfg), "budget_exhausted", "budget_unset")
    end
    assert_empty touched, "the key path was touched before the budget refusal"

    seed_ledger([seed_line(NOW - 5)])
    cfg = config(budget: { "monthly_usd" => 1.0, "per_minute" => 1 })
    touched = trap_file_access(@key_path) do
      refused(judge(cfg), "rate_limited_local", "per_minute")
    end
    assert_empty touched, "the key path was touched before the rate refusal"
  end

  # ---- 4. budget ----------------------------------------------------------

  # sabotage: treat a missing price (or a missing output price) as zero, or a
  # null / malformed ledger line as free, or drop the call bound from the cap
  # check -> red for that reason
  def test_budget_exhausted_reasons_refuse_before_any_request
    refused(judge(config(budget: nil)), "budget_exhausted", "budget_unset")
    refused(judge(config(prices: nil)), "budget_exhausted", "price_unknown")
    refused(judge(config(prices: { "jev-0.0.1" => PRICE })), "budget_exhausted", "price_unknown")
    refused(judge(config(prices: { MODEL => { "input" => 0.042 } })), "budget_exhausted", "price_unknown")

    hour_ago = NOW - 3600
    seed_ledger([seed_line(hour_ago), seed_line(hour_ago).merge("cost_usd" => nil)])
    refused(judge(config), "budget_exhausted", "spend_unmeasurable")

    FileUtils.rm_rf(@state_dir)
    seed_ledger([seed_line(hour_ago), "{not json"])
    r = refused(judge(config), "budget_exhausted", "spend_unmeasurable")
    assert_includes r.warnings, "ledger_malformed:1"

    FileUtils.rm_rf(@state_dir)
    seed_ledger([seed_line(hour_ago, cost: 0.6), seed_line(hour_ago, cost: 0.4)])
    refused(judge(config), "budget_exhausted", "cap_reached")
    assert_equal 2, ledger.size, "a refusal adds no ledger line"

    FileUtils.rm_rf(@state_dir)
    seed_ledger([seed_line(hour_ago, cost: 0.5)])
    @fake.respond(200, body: GOOD_BODY)
    assert_equal "ok", judge(config).outcome, "spend under the cap proceeds"
    assert_equal 1, @fake.calls.size
  end

  # ---- 5. local rate ------------------------------------------------------

  # sabotage: count lines older than 60s, or skip the previous month's file
  # in the first minute of a month -> red
  def test_rate_limited_local_trailing_window
    cfg = config(budget: { "monthly_usd" => 1.0, "per_minute" => 3 })
    seed_ledger(Array.new(3) { seed_line(NOW - 10) })
    refused(judge(cfg), "rate_limited_local", "per_minute")

    FileUtils.rm_rf(@state_dir)
    seed_ledger(Array.new(3) { seed_line(NOW - 61) })
    @fake.respond(200, body: GOOD_BODY)
    assert_equal "ok", judge(cfg).outcome
    assert_equal 1, @fake.calls.size

    @fake = FakeHTTP.new
    FileUtils.rm_rf(@state_dir)
    first_minute = Time.utc(2026, 10, 1, 0, 0, 30)
    seed_ledger(Array.new(3) { seed_line(Time.utc(2026, 9, 30, 23, 59, 50)) }, month: "2026-09")
    refused(judge(cfg, now: first_minute), "rate_limited_local", "per_minute")
  end

  # ---- 7-10. the ok path and the logs -------------------------------------

  # sabotage: put state, questions or source on the decision line by default,
  # or drop answers / tokens / cost / latency from it -> red
  def test_ok_path_ledger_and_decision_line_carry_numbers_not_text
    @fake.respond(200, body: GOOD_BODY)
    r = judge(config)
    assert_equal "ok", r.outcome
    assert_equal 1, @fake.calls.size
    expected_cost = 400 * 0.042 / 1e6
    assert_in_delta expected_cost, r.cost_usd, 1e-15
    assert_equal false, r.cost_estimated
    assert_equal "review:triage@1:#{MODEL}", r.threshold_key
    assert_equal "shadow", r.mode

    lines = ledger
    assert_equal 1, lines.size
    assert_equal "ok", lines[0]["outcome"]
    assert_equal r.call_id, lines[0]["call_id"]
    assert_in_delta expected_cost, lines[0]["cost_usd"], 1e-15
    assert_equal false, lines[0]["cost_estimated"]

    d = decisions
    assert_equal 1, d.size
    line = d[0]
    assert_equal "decision", line["kind"]
    assert_equal r.call_id, line["call_id"]
    assert_equal({ "q1" => { "choice" => "a" } }, line["answers"])
    assert_equal 400, line["input_tokens"]
    assert_equal 0, line["output_tokens"]
    assert_in_delta expected_cost, line["cost_usd"], 1e-15
    assert_kind_of Integer, line["latency_ms"]
    assert_equal MODEL, line["served_model"]
    assert_equal MODEL, line["model"]
    assert_equal r.threshold_key, line["threshold_key"]
    assert_equal({ "id" => "triage", "version" => 1 }, line["question_set"])
    %w[state questions source].each { |k| refute line.key?(k), "decision line carries #{k}" }
    text = File.read(File.join(@state_dir, "decisions-2026-09.jsonl")) +
           File.read(File.join(@state_dir, "ledger-2026-09.jsonl"))
    TEXT_MARKS.each { |m| refute_includes text, m }

    assert_equal 0o700, File.stat(@state_dir).mode & 0o777
    %w[ledger-2026-09.jsonl decisions-2026-09.jsonl].each do |name|
      assert_equal 0o600, File.stat(File.join(@state_dir, name)).mode & 0o777
    end
  end

  # sabotage: ignore log_state (never log text) -> red
  def test_log_state_true_puts_the_text_on_the_decision_line
    @fake.respond(200, body: GOOD_BODY)
    judge(config(log_state: true))
    line = decisions.first
    assert_includes line["state"], STATE_MARK
    assert_includes JSON.generate(line["questions"]), QUESTION_MARK
    assert_equal SOURCE_MARK, line["source"]
    refute_includes File.read(File.join(@state_dir, "ledger-2026-09.jsonl")), STATE_MARK
  end

  # ---- 8. cost ------------------------------------------------------------

  # sabotage: write cost_usd null (or zero) for a usage-less attempt, or price
  # a model_mismatch as free -> red; a null would also refuse the next call
  def test_failed_attempts_are_charged_the_bound_and_do_not_brick_the_month
    price = { "input" => 1.0, "output" => 2.0 }
    cfg = config(prices: { MODEL => price })
    bound = bound_for(input, price)

    @fake.raise_error(Net::ReadTimeout.new("slow"))
    r = judge(cfg)
    assert_equal "timeout", r.outcome
    assert_in_delta bound, r.cost_usd, 1e-12
    assert_equal true, r.cost_estimated
    assert_in_delta bound, ledger.last["cost_usd"], 1e-12
    assert_equal true, ledger.last["cost_estimated"]

    @fake.respond(200, body: GOOD_BODY)
    assert_equal "ok", judge(cfg).outcome, "an ordinary timeout does not brick the month"
    assert_equal 2, @fake.calls.size

    @fake.respond(422, body: "")
    r = judge(cfg)
    assert_equal "rejected", r.outcome
    assert_in_delta bound, ledger.last["cost_usd"], 1e-12
    assert_equal true, ledger.last["cost_estimated"]

    wrong = JSON.generate("model" => "jev-9.9.9", "answers" => { "q1" => {} },
                          "usage" => { "input_tokens" => 12, "output_tokens" => 3 })
    @fake.respond(200, body: wrong)
    r = judge(cfg)
    assert_equal "model_mismatch", r.outcome
    assert_in_delta 12 * 1.0 / 1e6 + 3 * 2.0 / 1e6, ledger.last["cost_usd"], 1e-15
    assert_equal false, ledger.last["cost_estimated"]
    assert_equal 4, ledger.size
    refute(ledger.any? { |l| l["cost_usd"].nil? })
  end

  # ---- 9. exception safety ------------------------------------------------

  # sabotage: move the ledger write out of the ensure (or let judge re-raise)
  # -> red: no ledger line, or an exception escapes
  def test_an_exception_still_spends_a_ledger_line
    @fake.raise_error(RuntimeError.new("odd"))
    r = judge(config)
    assert_equal "transport", r.outcome
    assert_equal "transport", ledger.last["outcome"]
    assert_equal 1, ledger.size

    @fake.respond(200, body: GOOD_BODY)
    Typesafe.stub(:cost_of, ->(*) { raise "boom after the attempt" }) do
      r = judge(config)
    end
    assert_equal "transport", r.outcome
    assert_equal "RuntimeError", r.reason
    assert_equal 2, ledger.size
    assert_equal "transport", ledger.last["outcome"]
    assert_equal true, ledger.last["cost_estimated"]
    refute_nil ledger.last["cost_usd"]
  end

  # ---- record_outcome -----------------------------------------------------

  # sabotage: loosen the label rule to accept prose (or write the line on a
  # dry run) -> red
  def test_record_outcome_writes_a_label_only_second_line
    @fake.respond(200, body: GOOD_BODY)
    cfg = config
    r = judge(cfg)
    line = Typesafe.record_outcome(config: cfg, call_id: r.call_id, site: "review",
                                   action: "kept_caller_decision", decision: "hold",
                                   agreement: "agree", now: NOW)
    assert_equal "outcome", line["kind"]
    lines = decisions
    assert_equal 2, lines.size
    assert_equal %w[decision outcome], lines.map { |l| l["kind"] }
    assert_equal [r.call_id], lines.map { |l| l["call_id"] }.uniq
    assert_equal "agree", lines[1]["agreement"]

    assert_raises(ArgumentError) do
      Typesafe.record_outcome(config: cfg, call_id: r.call_id, site: "review",
                              action: "fell back because the answer looked odd", now: NOW)
    end
    assert_raises(ArgumentError) do
      Typesafe.record_outcome(config: cfg, call_id: r.call_id, site: "review",
                              action: "fell_back", agreement: "mostly", now: NOW)
    end
    Typesafe.record_outcome(config: cfg, call_id: r.call_id, site: "review",
                            action: "fell_back", now: NOW, dry_run: true)
    assert_equal 2, decisions.size
  end

  # ---- threshold_key ------------------------------------------------------

  # sabotage: drop the version or the model from the key -> red
  def test_threshold_key_shape_and_what_changes_it
    qs = { "id" => "triage", "version" => 1 }
    key = Typesafe.threshold_key(site: "review", question_set: qs, model: MODEL)
    assert_equal "review:triage@1:jev-1.13.0", key
    refute_equal key, Typesafe.threshold_key(site: "review", question_set: qs.merge("version" => 2), model: MODEL)
    refute_equal key, Typesafe.threshold_key(site: "review", question_set: qs, model: "jev-1.14.0")
    refute_equal key, Typesafe.threshold_key(site: "dedupe", question_set: qs, model: MODEL)
  end

  # ---- dry run ------------------------------------------------------------

  # sabotage: open the key file on a dry run, send on a dry run, or write a log
  # line on a dry run -> red
  def test_dry_run_stats_the_key_never_opens_it_and_writes_nothing
    skip "chmod 000 does not stop root" if root?

    write_key(@key_path, "#{SENTINEL_KEY}\n", mode: 0o000)
    cfg = config
    r = nil
    touched = trap_file_access(@key_path) { r = judge(cfg, dry_run: true) }
    assert_equal "ok", r.outcome
    refute_includes touched, :read
    refute_includes touched, :open
    assert_empty @fake.calls
    assert_equal "Bearer [REDACTED]", r.request[:headers]["Authorization"]
    assert_equal MODEL, r.request[:body]["model"]
    assert_nil r.answers
    refute Dir.exist?(@state_dir), "a dry run writes nothing"

    refused(judge(cfg), "key_missing", "unreadable")
  end

  # ---- the sweep ----------------------------------------------------------

  # sabotage: put the key on any Result, ledger or decision line, or print it
  # -> red here (and in every test's teardown sweep)
  def test_sentinel_key_never_leaks_across_the_matrix
    cfg = config(log_state: true)
    @fake.respond(200, body: GOOD_BODY).respond(401).respond(429, headers: { "Retry-After" => "3" })
         .raise_error(Net::ReadTimeout.new("x")).raise_error(RuntimeError.new(SENTINEL_KEY))
    5.times { judge(cfg) }
    judge(cfg, dry_run: true)
    judge(config(budget: nil))
    File.delete(@key_path)
    judge(cfg)
    assert_equal 5, @fake.calls.size
    assert_equal 5, ledger.size
    assert_equal 7, decisions.size
    sweep_for_sentinel
  end
end

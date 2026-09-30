# frozen_string_literal: true

require "minitest/autorun"
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

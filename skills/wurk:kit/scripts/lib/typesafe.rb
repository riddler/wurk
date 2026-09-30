# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"

# TypeSafe System One (Jev) client core. One HTTP attempt per call, a hard
# deadline, every result mapped into a closed outcome set, the key never
# emitted. No config, no files, no budget here: those are the policy layer.
module Typesafe
  ENDPOINT = URI("https://api.typesafe.ai/v1/systemone")
  REDACTED = "Bearer [REDACTED]"

  # One call's outcome. `outcome` is always a member of the closed set.
  # Every member is declared here so later phases only fill fields and never
  # reshape the Struct. Serialize with `result.to_h.to_json` (a bare
  # Struct#to_json without json/add/struct is its to_s string).
  Result = Struct.new(:outcome, :reason, :answers, :served_model, :usage,
                      :http_status, :retry_after, :elapsed_ms,
                      :call_id, :site, :mode, :cost_usd, :cost_estimated,
                      :threshold_key, :warnings, :request, keyword_init: true)

  class Client
    RETRY_AFTER_MAX = 64

    def initialize(key:, model:, deadline_ms:, http_class: Net::HTTP,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @key = key
      @model = model
      @deadline_ms = deadline_ms
      @http_class = http_class
      @clock = clock
    end

    # The request body: the caller's state and questions with the PINNED
    # model. Never a -latest id.
    def body(input)
      {
        "state" => fetch(input, "state"),
        "model" => @model,
        "questions" => fetch(input, "questions")
      }
    end

    def redacted_request(input)
      request_parts(input, REDACTED)
    end

    # Exactly one Net::HTTP.start; never raises for a failed attempt. The
    # only raise is ArgumentError for a nil key, before any start.
    def post(input)
      raise ArgumentError, "key is required" if @key.nil?

      payload = JSON.generate(body(input))
      req = Net::HTTP::Post.new(ENDPOINT.request_uri)
      request_parts(input, "Bearer #{@key}")[:headers].each { |k, v| req[k] = v }
      req.body = payload
      secs = @deadline_ms / 1000.0
      started = @clock.call
      begin
        response = Timeout.timeout(secs) do
          @http_class.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true,
                            open_timeout: secs, read_timeout: secs,
                            write_timeout: secs) { |http| http.request(req) }
        end
        finish(response, elapsed(started))
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error => e
        failure("timeout", e, elapsed(started))
      rescue StandardError => e
        # SocketError, SystemCallError, SSLError, EOFError, IOError,
        # Net::HTTPBadResponse, Net::ProtocolError and anything unforeseen.
        failure("transport", e, elapsed(started))
      end
    end

    def inspect
      "#<#{self.class.name} model=#{@model.inspect} deadline_ms=#{@deadline_ms}>"
    end
    alias to_s inspect

    private

    def fetch(input, name)
      input[name] || input[name.to_sym]
    end

    def request_parts(input, authorization)
      {
        method: "POST",
        url: ENDPOINT.to_s,
        headers: {
          "Authorization" => authorization,
          "Content-Type" => "application/json",
          "Accept" => "application/json"
        },
        body: body(input)
      }
    end

    def elapsed(started)
      ((@clock.call - started) * 1000).round
    end

    # reason is the exception CLASS name only: a message can quote a URL or
    # a header.
    def failure(outcome, error, elapsed_ms)
      Result.new(outcome: outcome, reason: error.class.name, elapsed_ms: elapsed_ms)
    end

    def finish(response, elapsed_ms)
      status = response.code.to_i
      case status
      when 200 then decode(response, elapsed_ms)
      when 401, 403 then status_result("unauthorized", status, elapsed_ms)
      when 422 then status_result("rejected", status, elapsed_ms)
      when 429
        retry_after = response["Retry-After"]
        retry_after = retry_after.to_s.strip[0, RETRY_AFTER_MAX] unless retry_after.nil?
        status_result("rate_limited", status, elapsed_ms, retry_after: retry_after)
      when 529 then status_result("overloaded", status, elapsed_ms)
      else status_result("other_status", status, elapsed_ms)
      end
    end

    def status_result(outcome, status, elapsed_ms, retry_after: nil)
      Result.new(outcome: outcome, http_status: status, retry_after: retry_after,
                 elapsed_ms: elapsed_ms)
    end

    def decode(response, elapsed_ms)
      parsed = parse_object(response.body)
      base = { http_status: 200, elapsed_ms: elapsed_ms }
      return Result.new(outcome: "undecodable", **base) if parsed.nil?

      base[:usage] = usage_of(parsed)
      base[:served_model] = parsed["model"].is_a?(String) ? parsed["model"] : nil
      answers = parsed["answers"]
      return Result.new(outcome: "undecodable", **base) unless answers.is_a?(Hash)
      return Result.new(outcome: "model_mismatch", **base) if base[:served_model] != @model

      Result.new(outcome: "ok", answers: answers, **base)
    end

    def parse_object(text)
      parsed = JSON.parse(text.to_s)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    def usage_of(parsed)
      usage = parsed["usage"]
      usage = {} unless usage.is_a?(Hash)
      { "input_tokens" => int_or_nil(usage["input_tokens"]),
        "output_tokens" => int_or_nil(usage["output_tokens"]) }
    end

    def int_or_nil(value)
      value.is_a?(Integer) ? value : nil
    end
  end
end

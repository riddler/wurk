# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "time"
require "timeout"
require "uri"
require_relative "user_config"

# TypeSafe System One (Jev) client. Client is the core: one HTTP attempt
# per call, a hard deadline, every result mapped into a closed outcome set,
# the key never emitted. The module functions below it are the policy layer
# call sites use: site gating, input and privacy checks, the local budget and
# rate limit, the key file, the ledger and the decision log.
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

  # ---- Policy layer --------------------------------------------------------

  OUTCOMES = %w[ok site_off source_restricted input_invalid key_missing
                budget_exhausted rate_limited_local unauthorized rejected
                rate_limited overloaded other_status timeout transport
                undecodable model_mismatch].freeze
  # Outcomes with nothing for a person to fix right now: the caller falls
  # back and moves on. Every other non-ok outcome needs a human.
  NEEDS_NONE = %w[site_off source_restricted rate_limited_local rate_limited
                  overloaded other_status timeout transport undecodable].freeze
  QUESTION_TYPES = %w[choice noul score].freeze
  LEDGER = "ledger-%<month>s.jsonl"       # month = UTC "YYYY-MM"
  DECISIONS = "decisions-%<month>s.jsonl"
  # Output tokens charged per question when a response reports no usage. A
  # Jev answer is a small typed object; the bound is generous on purpose.
  OUTPUT_TOKENS_PER_QUESTION_BOUND = 256
  RATE_WINDOW_S = 60
  # record_outcome's action and decision: labels, never prose.
  LABEL = /\A[A-Za-z0-9_.:-]{1,64}\z/.freeze
  AGREEMENTS = ["agree", "disagree", "n/a"].freeze
  # Outcomes whose input text never enters a decision line, even with
  # log_state on: restricted text stays out of the log as well as off the
  # wire, and an invalid input is not known to be what the caller meant.
  NEVER_LOG_TEXT = %w[source_restricted input_invalid].freeze

  # The site's mode: "off", "shadow" or "on". A nil site is an ad-hoc probe
  # call and reports "probe".
  def self.site_mode(config, site)
    return "probe" if site.nil?

    config.typesafe_site(site)["mode"]
  end

  # The key a threshold is stored under. A threshold for one key never
  # applies to another: a new question-set version or a new pinned model is
  # a new key.
  def self.threshold_key(site:, question_set:, model:)
    "#{site}:#{question_set['id']}@#{question_set['version']}:#{model}"
  end

  # nil when the input is well formed, else a reason naming the field. Never
  # quotes a value: the value is caller text.
  def self.validate_input(input, site:)
    return "input" unless input.is_a?(Hash)
    return "state" unless [String, Hash, Array].any? { |k| input["state"].is_a?(k) }

    reason = validate_questions(input["questions"])
    return reason if reason

    if input.key?("question_set") || !site.nil?
      return "question_set" unless question_set_of(input)
    end
    if input.key?("source")
      src = input["source"]
      return "source" unless src.is_a?(String) && !src.strip.empty?
    end
    nil
  end

  def self.validate_questions(questions)
    return "questions" unless questions.is_a?(Hash) && !questions.empty?

    questions.each do |id, entry|
      return "questions.id" unless id.is_a?(String) && id.match?(UserConfig::TYPESAFE_NAME)
      return "questions.#{id}" unless entry.is_a?(Hash)
      return "questions.#{id}.type" unless QUESTION_TYPES.include?(entry["type"])

      text = entry["instructions"]
      return "questions.#{id}.instructions" unless text.is_a?(String) && !text.strip.empty?
    end
    nil
  end
  private_class_method :validate_questions

  # {"id", "version"} when the input carries a well-formed question set.
  def self.question_set_of(input)
    qs = input.is_a?(Hash) ? input["question_set"] : nil
    return nil unless qs.is_a?(Hash)
    return nil unless qs["id"].is_a?(String) && qs["id"].match?(UserConfig::TYPESAFE_NAME)
    return nil unless qs["version"].is_a?(Integer) && qs["version"].positive?

    { "id" => qs["id"], "version" => qs["version"] }
  end
  private_class_method :question_set_of

  # One gated call. Returns a Result whose outcome is in OUTCOMES; never
  # raises for anything in that set. The steps run in a fixed order and every
  # check that does not need the key runs before the key file is touched:
  # mode, input, privacy, budget, local rate, key, call, cost, ledger,
  # decision log.
  def self.judge(config:, input:, site: nil, dry_run: false,
                 now: Time.now.utc, http_class: Net::HTTP)
    now = now.utc
    input = stringify(input)
    ctx = {
      config: config, input: input, site: site, dry_run: dry_run, now: now,
      model: config.typesafe_model, state_dir: config.typesafe_state_dir,
      warnings: [], call_id: SecureRandom.hex(8), mode: site_mode(config, site)
    }
    # 1. Mode. The hot path for every dark site: nothing read, nothing logged.
    return result_for(ctx, outcome: "site_off") if ctx[:mode] == "off"

    # 2. Input.
    reason = validate_input(input, site: site)
    return refuse(ctx, "input_invalid", reason) if reason

    ctx[:question_set] = question_set_of(input)
    if site && ctx[:question_set]
      ctx[:threshold_key] = threshold_key(site: site, question_set: ctx[:question_set],
                                          model: ctx[:model])
    end
    # 3. Privacy: a listed source refuses in every mode, shadow included.
    if input.key?("source") && config.typesafe_restricted_sources.include?(input["source"])
      return refuse(ctx, "source_restricted", nil)
    end

    # 4. Budget.
    refusal = check_budget(ctx)
    return refusal if refusal

    # 5. Local rate.
    refusal = check_rate(ctx)
    return refusal if refusal

    # 6. Key.
    key = nil
    refusal = check_key(ctx) { |value| key = value }
    return refusal if refusal

    deadline = site ? config.typesafe_site(site)["deadline_ms"] : UserConfig::TYPESAFE_DEFAULT_DEADLINE_MS
    client = Client.new(key: key, model: ctx[:model], deadline_ms: deadline, http_class: http_class)
    key = nil
    # 7. Call. A dry run shows the request and sends nothing: its client
    # holds no key, so post would raise before any start.
    if dry_run
      return result_for(ctx, outcome: "ok", request: client.redacted_request(input))
    end

    attempt(ctx, client)
  end

  # Steps 7-10 for a live call: one attempt, its cost, the ledger line in an
  # ensure, then the decision line.
  def self.attempt(ctx, client)
    result = nil
    cost = nil
    begin
      result = client.post(ctx[:input])
      cost = cost_of(ctx, result.usage)
    rescue StandardError => e
      # The client maps every failed attempt to an outcome, so this is
      # something in judge itself after the attempt: still a spent call.
      result = Result.new(outcome: "transport", reason: e.class.name)
    ensure
      cost ||= [ctx[:call_bound], true]
      write_ledger(ctx, result, cost)
    end
    fill(ctx, result, cost_usd: cost[0], cost_estimated: cost[1])
    log_decision(ctx, result)
    result
  end
  private_class_method :attempt

  # The caller's second line: what it did next. action and decision are
  # labels (LABEL), never prose; agreement is agree, disagree, n/a or nil.
  # Invalid values raise ArgumentError. Returns the line; dry_run writes
  # nothing.
  def self.record_outcome(config:, call_id:, site:, action:, decision: nil,
                          agreement: nil, now: Time.now.utc, dry_run: false)
    raise ArgumentError, "call_id must be a label" unless call_id.is_a?(String) && call_id.match?(LABEL)
    unless site.nil? || (site.is_a?(String) && site.match?(UserConfig::TYPESAFE_NAME))
      raise ArgumentError, "site must be a site name"
    end
    raise ArgumentError, "action must be a label" unless action.is_a?(String) && action.match?(LABEL)
    unless decision.nil? || (decision.is_a?(String) && decision.match?(LABEL))
      raise ArgumentError, "decision must be a label"
    end
    unless agreement.nil? || AGREEMENTS.include?(agreement)
      raise ArgumentError, "agreement must be one of #{AGREEMENTS.join(', ')}"
    end

    now = now.utc
    line = { "kind" => "outcome", "ts" => stamp(now), "call_id" => call_id, "site" => site,
             "action" => action, "decision" => decision, "agreement" => agreement }
    append_line(config.typesafe_state_dir, format(DECISIONS, month: month_of(now)), line) unless dry_run
    line
  end

  # ---- policy helpers ------------------------------------------------------

  def self.stringify(input)
    return input unless input.is_a?(Hash)

    input.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
  end
  private_class_method :stringify

  def self.result_for(ctx, **fields)
    Result.new(call_id: ctx[:call_id], site: ctx[:site], mode: ctx[:mode],
               threshold_key: ctx[:threshold_key], warnings: ctx[:warnings], **fields)
  end
  private_class_method :result_for

  def self.fill(ctx, result, **fields)
    result.call_id = ctx[:call_id]
    result.site = ctx[:site]
    result.mode = ctx[:mode]
    result.threshold_key = ctx[:threshold_key]
    result.warnings = ctx[:warnings]
    fields.each { |k, v| result[k] = v }
    result
  end
  private_class_method :fill

  # A pre-call refusal: no request, no ledger line; a decision line unless
  # this is a dry run.
  def self.refuse(ctx, outcome, reason)
    result = result_for(ctx, outcome: outcome, reason: reason)
    log_decision(ctx, result)
    result
  end
  private_class_method :refuse

  def self.check_budget(ctx)
    config = ctx[:config]
    monthly = config.typesafe_monthly_usd
    return refuse(ctx, "budget_exhausted", "budget_unset") if monthly.nil?

    price = config.metrics_prices[ctx[:model]]
    unless price.is_a?(Hash) && price["input"].is_a?(Numeric) && price["output"].is_a?(Numeric)
      return refuse(ctx, "budget_exhausted", "price_unknown")
    end

    ctx[:price] = price
    ctx[:call_bound] = call_bound(ctx)
    lines, malformed = read_lines(ctx[:state_dir], format(LEDGER, month: month_of(ctx[:now])))
    ctx[:ledger] = lines
    ctx[:warnings] << "ledger_malformed:#{malformed}" if malformed.positive?
    costs = lines.map { |l| l["cost_usd"] }
    if malformed.positive? || costs.any? { |c| !c.is_a?(Numeric) }
      return refuse(ctx, "budget_exhausted", "spend_unmeasurable")
    end
    return refuse(ctx, "budget_exhausted", "cap_reached") if costs.sum + ctx[:call_bound] > monthly

    nil
  end
  private_class_method :check_budget

  # Ledger lines in the trailing window, reading the previous month's file
  # too when the window starts there.
  def self.check_rate(ctx)
    now = ctx[:now]
    from = now - RATE_WINDOW_S
    lines = ctx[:ledger]
    if month_of(from) != month_of(now)
      prev, = read_lines(ctx[:state_dir], format(LEDGER, month: month_of(from)))
      lines = prev + lines
    end
    recent = lines.count do |l|
      ts = parse_ts(l["ts"])
      ts && ts > from && ts <= now
    end
    return nil if recent < ctx[:config].typesafe_per_minute

    refuse(ctx, "rate_limited_local", "per_minute")
  end
  private_class_method :check_rate

  # The only place the key file is touched. A dry run stats it and never
  # opens it. Yields the key (nil on a dry run) on success.
  def self.check_key(ctx)
    path = ctx[:config].typesafe_key_path
    return refuse(ctx, "key_missing", "absent") unless File.file?(path)

    stat = File.stat(path)
    ctx[:warnings] << "key_mode_open" unless (stat.mode & 0o077).zero?
    if ctx[:dry_run]
      yield nil
      return nil
    end
    return refuse(ctx, "key_missing", "unreadable") unless File.readable?(path)

    key = begin
      File.read(path).strip
    rescue SystemCallError, IOError
      return refuse(ctx, "key_missing", "unreadable")
    end
    return refuse(ctx, "key_missing", "blank") if key.empty?

    yield key
    nil
  end
  private_class_method :check_key

  # The no-usage upper bound for this request: its body bytes at the input
  # price (assumes tokens never exceed bytes) plus the per-question output
  # allowance at the output price.
  def self.call_bound(ctx)
    input = ctx[:input]
    body = Client.new(key: nil, model: ctx[:model], deadline_ms: 1).body(input)
    bytes = JSON.generate(body).bytesize
    price = ctx[:price]
    bytes * price["input"] / 1e6 +
      OUTPUT_TOKENS_PER_QUESTION_BOUND * input["questions"].size * price["output"] / 1e6
  end
  private_class_method :call_bound

  # [cost_usd, cost_estimated]: priced from usage when the response reported
  # it, else the conservative bound. Never nil.
  def self.cost_of(ctx, usage)
    ins = usage.is_a?(Hash) ? usage["input_tokens"] : nil
    outs = usage.is_a?(Hash) ? usage["output_tokens"] : nil
    return [ctx[:call_bound], true] unless ins.is_a?(Integer) && outs.is_a?(Integer)

    price = ctx[:price]
    [ins * price["input"] / 1e6 + outs * price["output"] / 1e6, false]
  end
  private_class_method :cost_of

  def self.tokens(result, name)
    usage = result.usage
    usage.is_a?(Hash) ? usage[name] : nil
  end
  private_class_method :tokens

  def self.write_ledger(ctx, result, cost)
    outcome = result ? result.outcome : "transport"
    line = {
      "ts" => stamp(ctx[:now]), "month" => month_of(ctx[:now]), "call_id" => ctx[:call_id],
      "site" => ctx[:site], "model" => ctx[:model], "outcome" => outcome,
      "cost_usd" => cost[0], "cost_estimated" => cost[1],
      "input_tokens" => result ? tokens(result, "input_tokens") : nil,
      "output_tokens" => result ? tokens(result, "output_tokens") : nil
    }
    line["reason"] = result.reason if result && result.outcome == "transport"
    append_line(ctx[:state_dir], format(LEDGER, month: month_of(ctx[:now])), line)
  end
  private_class_method :write_ledger

  # One decision line per outcome except site_off. No state, question or
  # source text unless log_state is on (and never for NEVER_LOG_TEXT).
  def self.log_decision(ctx, result)
    return if ctx[:dry_run]

    now = ctx[:now]
    line = {
      "kind" => "decision", "ts" => stamp(now), "call_id" => ctx[:call_id],
      "site" => ctx[:site], "mode" => ctx[:mode], "question_set" => ctx[:question_set],
      "threshold_key" => ctx[:threshold_key], "model" => ctx[:model],
      "served_model" => result.served_model, "outcome" => result.outcome,
      "reason" => result.reason, "http_status" => result.http_status,
      "retry_after" => result.retry_after, "answers" => result.answers,
      "input_tokens" => tokens(result, "input_tokens"),
      "output_tokens" => tokens(result, "output_tokens"),
      "cost_usd" => result.cost_usd, "latency_ms" => result.elapsed_ms
    }
    if ctx[:config].typesafe_log_state? && !NEVER_LOG_TEXT.include?(result.outcome)
      input = ctx[:input]
      line["state"] = input["state"]
      line["questions"] = input["questions"]
      line["source"] = input["source"]
    end
    append_line(ctx[:state_dir], format(DECISIONS, month: month_of(now)), line)
  end
  private_class_method :log_decision

  # One JSON line, one write, O_APPEND, mode 600, in a mode-700 dir, so
  # concurrent appenders never interleave inside a line.
  def self.append_line(dir, name, hash)
    FileUtils.mkdir_p(dir, mode: 0o700)
    File.open(File.join(dir, name), File::WRONLY | File::APPEND | File::CREAT, 0o600) do |f|
      f.write("#{JSON.generate(hash)}\n")
    end
  end
  private_class_method :append_line

  # [objects, malformed_count] for a JSONL file; absent file is [[], 0]. A
  # line that is not a JSON object counts as malformed, never as free.
  def self.read_lines(dir, name)
    path = File.join(dir, name)
    return [[], 0] unless File.file?(path)

    objects = []
    malformed = 0
    File.foreach(path) do |raw|
      next if raw.strip.empty?

      parsed = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end
      parsed.is_a?(Hash) ? objects << parsed : malformed += 1
    end
    [objects, malformed]
  end
  private_class_method :read_lines

  def self.month_of(time)
    time.utc.strftime("%Y-%m")
  end
  private_class_method :month_of

  def self.stamp(time)
    time.utc.iso8601(3)
  end
  private_class_method :stamp

  def self.parse_ts(value)
    value.is_a?(String) ? Time.iso8601(value) : nil
  rescue ArgumentError
    nil
  end
  private_class_method :parse_ts
end

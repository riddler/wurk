# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "securerandom"
require "fileutils"
require "tmpdir"
require_relative "../typesafe"
require_relative "support/user_config_helper"
require_relative "support/fake_http"

# typesafe.rb driven in-process: TypesafeCli.run with StringIOs, a tmp HOME
# holding the machine config, a tmp key file holding a sentinel string (never
# a real key), a tmp state dir, XDG_STATE_HOME pinned to a tmpdir, and
# FakeHTTP as the only transport (loading fake_http.rb also locks the real
# Net::HTTP.start for the whole process). Every stdout and stderr captured
# here, and every file left under the tmp HOME, is swept for the sentinel in
# teardown.
class TypesafeCliTest < Minitest::Test
  include UserConfigHelper

  SENTINEL_KEY = "sentinel-cli-#{SecureRandom.hex(12)}"
  MODEL = "jev-1.13.0"
  STATE_MARK = "clistatemark-#{SecureRandom.hex(6)}"
  PRICE = { "input" => 0.042, "output" => 0 }.freeze
  GOOD_BODY = JSON.generate(
    "model" => MODEL,
    "answers" => { "q1" => { "choice" => "a" } },
    "usage" => { "input_tokens" => 400, "output_tokens" => 0 }
  )
  REQUEST = "POST https://api.typesafe.ai/v1/systemone"

  def setup
    @saved_xdg = ENV.key?("XDG_STATE_HOME") ? ENV["XDG_STATE_HOME"] : :unset
    @xdg = Dir.mktmpdir("wurk-typesafe-cli-xdg-")
    ENV["XDG_STATE_HOME"] = @xdg
    @fake = FakeHTTP.new
    @outputs = []
    @swept_dirs = [@xdg]
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

  # A tmp HOME with the machine config written from `section` (nil writes no
  # config at all, the dark default). The key file and state dir live under
  # it. Yields the dir; sweeps every file in it (bar the key) on the way out.
  def with_home(section = :shadow, prices: { MODEL => PRICE }, raw: nil)
    in_tmp_home(nil) do |dir|
      @home = dir
      @key_path = File.join(dir, "key", "typesafe-api-token")
      @state_dir = File.join(dir, "state")
      FileUtils.mkdir_p(File.dirname(@key_path))
      File.write(@key_path, "#{SENTINEL_KEY}\n")
      File.chmod(0o600, @key_path)
      config = raw || build_config(section, prices)
      write_raw_user_config(dir, JSON.generate(config)) unless config.nil?
      yield dir
      sweep_files(dir)
    end
  end

  def build_config(section, prices)
    return nil if section.nil?

    base = { "key_path" => @key_path, "state_dir" => @state_dir,
             "budget" => { "monthly_usd" => 1.0 },
             "sites" => { "review" => { "mode" => "shadow" } } }
    base = base.merge(section) if section.is_a?(Hash)
    raw = { "typesafe" => base }
    raw["metrics"] = { "prices" => prices } unless prices.nil?
    raw
  end

  def sweep_files(dir)
    Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).each do |path|
      next unless File.file?(path)
      next if path == @key_path

      refute_includes File.read(path), SENTINEL_KEY, "sentinel key found in #{path}"
    end
  end

  def input_hash(**over)
    {
      "state" => "synthetic state #{STATE_MARK}",
      "questions" => { "q1" => { "type" => "choice", "instructions" => "pick one",
                                  "criteria" => %w[a b] } },
      "question_set" => { "id" => "triage", "version" => 1 }
    }.merge(over.each_with_object({}) { |(k, v), h| h[k.to_s] = v })
  end

  def write_input(text = JSON.generate(input_hash))
    path = File.join(@home, "input.json")
    File.write(path, text)
    path
  end

  # [exit_code, parsed_envelope_or_nil, stdout, stderr]. Captures the
  # process's own $stdout/$stderr too, so a stray print or warn is swept.
  def run_cli(argv, stdin_text: "", stdin: StringIO.new(stdin_text), http_class: @fake)
    io = StringIO.new
    code = nil
    out, err = capture_io do
      code = TypesafeCli.run(argv, io: io, stdin: stdin, http_class: http_class)
    end
    @outputs << io.string << out << err
    body = io.string.start_with?("{") ? JSON.parse(io.string) : nil
    [code, body, io.string + out, err]
  end

  def state_files
    Dir.exist?(@state_dir) ? Dir.children(@state_dir).sort : []
  end

  def jsonl(prefix)
    path = Dir.glob(File.join(@state_dir, "#{prefix}-*.jsonl")).first
    path ? File.readlines(path).map { |l| JSON.parse(l) } : []
  end

  # ---- call: dark by default ---------------------------------------------

  # sabotage: default a site's mode to shadow, map site_off to needs "human",
  # or read the input before the mode check -> red (stdin is left unread)
  def test_call_on_default_config_is_site_off_and_reads_nothing
    with_home(nil) do
      stdin = StringIO.new(JSON.generate(input_hash))
      code, body, = run_cli(["call", "--site", "review", "--input", "-"], stdin: stdin)
      assert_equal 0, stdin.pos, "a dark site must not read its input"
      assert_equal 1, code
      assert_equal "site_off", body["data"]["outcome"]
      assert_equal "site_off", body["blocked"][0]["code"]
      assert_equal "none", body["blocked"][0]["needs"]
      assert_equal 1, body["blocked"].size
      assert_empty body["commands"]
      assert_empty @fake.calls
      assert_empty state_files
      refute Dir.exist?(File.join(@xdg, "wurk")), "default state dir created"
    end
  end

  # ---- call: live paths against FakeHTTP -----------------------------------

  # sabotage: drop answers from data, or stop recording the request in
  # commands, or put the Authorization header in commands -> red
  def test_call_shadow_200_is_ok_with_answers
    with_home do
      @fake.respond(200, body: GOOD_BODY)
      code, body, = run_cli(["call", "--site", "review", "--input", write_input])
      assert_equal 0, code
      data = body["data"]
      assert_equal "ok", data["outcome"]
      assert_equal({ "q1" => { "choice" => "a" } }, data["answers"])
      assert_equal MODEL, data["model"]
      assert_equal MODEL, data["served_model"]
      assert_equal({ "input_tokens" => 400, "output_tokens" => 0 }, data["usage"])
      assert_equal "review:triage@1:#{MODEL}", data["threshold_key"]
      assert_equal "shadow", data["mode"]
      assert_kind_of Numeric, data["cost_usd"]
      assert_match(/\A\h{16}\z/, data["call_id"])
      refute data.key?("request"), "request is reported on a dry run only"
      assert_empty body["blocked"]
      assert_equal [REQUEST], body["commands"]
      assert_equal 1, @fake.calls.size
      assert_equal 1, jsonl("ledger").size
      assert_equal 1, jsonl("decisions").size
      refute_includes File.read(Dir.glob(File.join(@state_dir, "decisions-*")).first), STATE_MARK
    end
  end

  # sabotage: drop retry_after from data, retry on 429, or mark it needs
  # "human" -> red
  def test_call_429_is_rate_limited_with_retry_after
    with_home do
      @fake.respond(429, headers: { "Retry-After" => "7" })
      code, body, = run_cli(["call", "--site", "review", "--input", write_input])
      assert_equal 1, code
      assert_equal "rate_limited", body["data"]["outcome"]
      assert_equal "7", body["data"]["retry_after"]
      assert_equal 429, body["data"]["http_status"]
      assert_equal "rate_limited", body["blocked"][0]["code"]
      assert_equal "none", body["blocked"][0]["needs"]
      assert_includes body["blocked"][0]["message"], "Retry-After 7"
      assert_equal [REQUEST], body["commands"]
      assert_equal 1, @fake.calls.size
    end
  end

  # sabotage: mark a budget refusal needs "none", or record the request in
  # commands for a pre-call refusal -> red
  def test_pre_call_refusal_needs_human_and_sends_nothing
    with_home("budget" => {}) do
      code, body, = run_cli(["call", "--site", "review", "--input", write_input])
      assert_equal 1, code
      assert_equal "budget_exhausted", body["data"]["outcome"]
      assert_equal "budget_unset", body["data"]["reason"]
      assert_equal "human", body["blocked"][0]["needs"]
      assert_includes body["blocked"][0]["message"], "typesafe.budget.monthly_usd"
      assert_empty body["commands"]
      assert_empty @fake.calls
    end
  end

  # sabotage: give run a default http_class other than Net::HTTP that
  # bypasses the lock, or let the client raise -> red (the process-wide lock
  # turns the real transport into a loud transport outcome)
  def test_default_transport_is_real_net_http_and_locked_in_tests
    assert_includes Net::HTTP.singleton_class.ancestors, FakeHTTP::NetworkLock
    with_home do
      io = StringIO.new
      code = nil
      out, err = capture_io do
        code = TypesafeCli.run(["call", "--site", "review", "--input", write_input], io: io)
      end
      @outputs << io.string << out << err
      body = JSON.parse(io.string)
      assert_equal 1, code
      assert_equal "transport", body["data"]["outcome"]
      assert_equal "FakeHTTP::RealNetworkForbidden", body["data"]["reason"]
    end
  end

  # ---- call: dry run -----------------------------------------------------

  # sabotage: put the real key in the dry-run Authorization header, send on
  # a dry run, or write a ledger/decision line on a dry run -> red
  def test_call_dry_run_redacts_sends_nothing_writes_nothing
    with_home do
      code, body, stdout, = run_cli(["call", "--site", "review", "--input", write_input, "--dry-run"])
      assert_equal 0, code
      data = body["data"]
      assert_equal "ok", data["outcome"]
      assert_equal true, data["dry_run"]
      assert_equal "Bearer [REDACTED]", data["request"]["headers"]["Authorization"]
      assert_equal "https://api.typesafe.ai/v1/systemone", data["request"]["url"]
      assert_equal MODEL, data["request"]["body"]["model"]
      assert_equal [REQUEST], body["commands"]
      assert_empty @fake.calls
      assert_empty state_files
      refute_includes stdout, SENTINEL_KEY
    end
  end

  # sabotage: report a dry run's pre-call refusal as ok, or record the
  # request for it -> red
  def test_call_dry_run_reports_the_refusal_a_live_call_would_reach
    with_home("restricted_sources" => ["private"]) do
      path = write_input(JSON.generate(input_hash(source: "private")))
      code, body, = run_cli(["call", "--site", "review", "--input", path, "--dry-run"])
      assert_equal 1, code
      assert_equal "source_restricted", body["data"]["outcome"]
      assert_equal "none", body["blocked"][0]["needs"]
      assert_empty body["commands"]
      assert_empty @fake.calls
      assert_empty state_files
    end
  end

  # ---- call: input ---------------------------------------------------------

  # sabotage: interpolate the JSON parser's message (it quotes the input)
  # into the block message, or make a parse failure a usage error -> red
  def test_call_malformed_input_is_input_invalid_without_input_text
    with_home do
      path = write_input("{\"state\": \"#{STATE_MARK}\", broken")
      code, body, stdout, stderr = run_cli(["call", "--site", "review", "--input", path])
      assert_equal 1, code
      assert_equal "input_invalid", body["data"]["outcome"]
      assert_equal "human", body["blocked"][0]["needs"]
      assert_includes body["blocked"][0]["message"], "not valid JSON"
      refute_includes stdout, STATE_MARK
      refute_includes stderr, STATE_MARK
      assert_empty @fake.calls
      jsonl("decisions").each { |line| refute_includes line.to_json, STATE_MARK }
    end
  end

  # sabotage: let a missing input file raise out of run (a backtrace) -> red
  def test_call_unreadable_input_file_is_input_invalid
    with_home do
      code, body, _, stderr = run_cli(["call", "--site", "review", "--input", File.join(@home, "nope.json")])
      assert_equal 1, code
      assert_equal "input_invalid", body["data"]["outcome"]
      assert_includes body["blocked"][0]["message"], "Errno::ENOENT"
      refute_includes body["blocked"][0]["message"], @home
      assert_empty stderr
    end
  end

  # sabotage: ignore "-" and treat it as a path -> red
  def test_call_reads_input_from_stdin
    with_home do
      @fake.respond(200, body: GOOD_BODY)
      code, body, = run_cli(["call", "--site", "review", "--input", "-"],
                            stdin_text: JSON.generate(input_hash))
      assert_equal 0, code
      assert_equal "ok", body["data"]["outcome"]
      assert_equal 1, @fake.calls.size
      sent = JSON.parse(@fake.calls[0].request.body)
      assert_equal MODEL, sent["model"]
    end
  end

  # sabotage: accept a call with no --input -> red
  def test_call_without_input_is_a_usage_error
    with_home do
      code, body, stdout, stderr = run_cli(["call", "--site", "review"])
      assert_equal 2, code
      assert_nil body
      assert_empty stdout
      assert_includes stderr, "--input"
    end
  end

  # ---- call: config and state-dir failures ---------------------------------

  # sabotage: skip UserConfig.require! (an unknown mode would then be read
  # as off or passed through) -> red
  def test_invalid_config_blocks_with_user_config_invalid
    with_home("sites" => { "review" => { "mode" => "maybe" } }) do
      code, body, = run_cli(["call", "--site", "review", "--input", write_input])
      assert_equal 1, code
      assert_equal ["user_config_invalid"], body["blocked"].map { |b| b["code"] }.uniq
      assert_empty @fake.calls
    end
  end

  # sabotage: drop the SystemCallError rescue (a backtrace with the path
  # reaches stderr and the exit is not 1), or interpolate the exception
  # message (it carries the path) -> red
  def test_state_dir_failure_is_an_envelope_naming_only_the_class
    with_home do
      FileUtils.mkdir_p(File.dirname(@state_dir))
      File.write(@state_dir, "not a directory")
      code, body, stdout, stderr = run_cli(["call", "--site", "review", "--input", "-"],
                                           stdin_text: JSON.generate(input_hash(state: 7)))
      assert_equal 1, code
      assert_nil body["data"]["outcome"]
      assert_equal "state_dir_error", body["blocked"][0]["code"]
      assert_equal "human", body["blocked"][0]["needs"]
      assert_match(/\(Errno::[A-Z]+\)/, body["blocked"][0]["message"])
      refute_includes stdout, @state_dir
      assert_empty stderr
      assert_empty @fake.calls
    end
  end

  # sabotage: drop the key_mode_open warning mapping -> red
  def test_open_key_mode_warns
    with_home do
      File.chmod(0o644, @key_path)
      code, body, = run_cli(["call", "--site", "review", "--input", write_input, "--dry-run"])
      assert_equal 0, code
      assert_equal ["key_mode_open"], body["warnings"].map { |w| w["code"] }
    end
  end

  # ---- outcome -------------------------------------------------------------

  # sabotage: write the line under another call_id, or not at all -> red
  def test_outcome_writes_the_caller_line
    with_home do
      code, body, = run_cli(["outcome", "--call-id", "abc123", "--site", "review",
                             "--action", "held", "--decision", "hold", "--agreement", "agree"])
      assert_equal 0, code
      assert_equal true, body["data"]["written"]
      lines = jsonl("decisions")
      assert_equal 1, lines.size
      assert_equal "outcome", lines[0]["kind"]
      assert_equal "abc123", lines[0]["call_id"]
      assert_equal "held", lines[0]["action"]
      assert_equal "agree", lines[0]["agreement"]
      assert_equal lines[0], body["data"]["line"]
    end
  end

  # sabotage: write on --dry-run -> red
  def test_outcome_dry_run_writes_nothing
    with_home do
      code, body, = run_cli(["outcome", "--call-id", "abc123", "--site", "review",
                             "--action", "held", "--dry-run"])
      assert_equal 0, code
      assert_equal false, body["data"]["written"]
      assert_equal "abc123", body["data"]["line"]["call_id"]
      assert_empty state_files
    end
  end

  # sabotage: let prose through record_outcome, or emit an envelope for the
  # ArgumentError -> red
  def test_outcome_prose_action_is_a_usage_error_with_no_envelope
    with_home do
      prose = "fell back because #{STATE_MARK}"
      code, body, stdout, stderr = run_cli(["outcome", "--call-id", "abc123", "--site", "review",
                                            "--action", prose])
      assert_equal 2, code
      assert_nil body
      assert_empty stdout
      refute_includes stderr, STATE_MARK
      assert_empty state_files
    end
  end

  # sabotage: make --site optional on outcome -> red
  def test_outcome_missing_flags_is_a_usage_error
    with_home do
      code, body, _, stderr = run_cli(["outcome", "--call-id", "abc123", "--action", "held"])
      assert_equal 2, code
      assert_nil body
      assert_includes stderr, "--site"
    end
  end

  # ---- payload -------------------------------------------------------------

  REPO_ROOT = File.expand_path("../../../..", __dir__)

  # with_home's config plus a payload store under the tmp HOME (never the repo).
  def with_store(keep_days: nil, &block)
    store = { "dir" => "~/payloads" }
    store["keep_days"] = keep_days unless keep_days.nil?
    with_home({ "payload_store" => store }) do |dir|
      @store_dir = File.join(dir, "payloads")
      refute File.expand_path(@store_dir).start_with?("#{REPO_ROOT}/"), "store dir is under the repo"
      block.call(dir)
    end
  end

  def store_files
    Dir.exist?(@store_dir) ? Dir.children(@store_dir).sort : []
  end

  # sabotage: write a payload with the key absent, or add a field to the
  # call envelope when the store is on -> red
  def test_call_envelope_is_the_same_with_the_store_off_or_on
    bodies = []
    with_home do |dir|
      @fake.respond(200, body: GOOD_BODY)
      _, body, = run_cli(["call", "--site", "review", "--input", write_input])
      bodies << body
      assert_empty Dir.glob(File.join(dir, "**", "*.json")).select { |p| File.basename(p).match?(Typesafe::PAYLOAD_FILE) }
    end
    with_store do
      @fake.respond(200, body: GOOD_BODY)
      _, body, = run_cli(["call", "--site", "review", "--input", write_input])
      bodies << body
      assert_equal ["#{body['data']['call_id']}.json"], store_files
    end
    strip = lambda do |b|
      b.merge("data" => b["data"].reject { |k, _| %w[call_id elapsed_ms].include?(k) })
    end
    assert_equal(*bodies.map(&strip))
  end

  # sabotage: return the input (with source) instead of the stored request,
  # or echo a malformed id -> red
  def test_payload_returns_the_stored_request_for_a_known_id
    with_store do
      @fake.respond(200, body: GOOD_BODY)
      _, call, = run_cli(["call", "--site", "review", "--input", write_input])
      id = call["data"]["call_id"]
      code, body, = run_cli(["payload", id])
      assert_equal 0, code
      assert_empty body["blocked"]
      assert_equal id, body["data"]["call_id"]
      assert_equal JSON.parse(@fake.calls.first.request.body), body["data"]["request"]
      assert_includes body["data"]["request"]["state"], STATE_MARK
      assert_equal 1, @fake.calls.size, "reading a payload sends nothing"
    end
  end

  # sabotage: let a restricted source through to the store -> red
  def test_restricted_call_stores_nothing_even_with_the_store_on
    with_home({ "payload_store" => { "dir" => "~/payloads" }, "restricted_sources" => ["private"],
                "log_state" => true }) do |dir|
      code, body, = run_cli(["call", "--site", "review", "--input",
                             write_input(JSON.generate(input_hash(source: "private")))])
      assert_equal 1, code
      assert_equal "source_restricted", body["data"]["outcome"]
      refute Dir.exist?(File.join(dir, "payloads"))
    end
  end

  # sabotage: map an unknown id to a stack trace (or exit 0), or touch the
  # store for a malformed id -> red
  def test_payload_blocks_unknown_and_malformed_ids
    with_store do
      code, body, out, = run_cli(["payload", "e" * 16])
      assert_equal 1, code
      assert_equal "payload_not_found", body["blocked"][0]["code"]
      assert_nil body["data"]["request"]

      ["../../secret", "NOT-HEX", "e" * 17].each do |id|
        code, body, out, = run_cli(["payload", id])
        assert_equal 1, code, id
        assert_equal "call_id_malformed", body["blocked"][0]["code"]
        assert_nil body["data"]["call_id"]
        refute_includes out, id
      end
    end
    with_home do
      code, body, = run_cli(["payload", "e" * 16])
      assert_equal 1, code
      assert_equal "payload_store_off", body["blocked"][0]["code"]
    end
  end

  # sabotage: accept zero or two ids -> red
  def test_payload_needs_exactly_one_id
    [%w[payload], ["payload", "a" * 16, "b" * 16]].each do |argv|
      code, body, = run_cli(argv)
      assert_equal 2, code, argv.inspect
      assert_nil body
    end
  end

  # ---- usage ---------------------------------------------------------------

  # sabotage: route --help through Cli.build's handler (it calls exit) or
  # print usage to stderr -> red
  def test_help_exits_0_first_or_after_a_subcommand
    [["--help"], ["-h"], %w[call --help], %w[outcome -h]].each do |argv|
      code, body, stdout, = run_cli(argv)
      assert_equal 0, code, argv.inspect
      assert_nil body
      assert_includes stdout, "typesafe.rb call"
    end
  end

  # sabotage: treat an unknown subcommand as call, or print an envelope ->
  # red
  def test_unknown_or_missing_subcommand_exits_2_with_no_stdout
    [["bogus"], []].each do |argv|
      code, body, stdout, stderr = run_cli(argv)
      assert_equal 2, code, argv.inspect
      assert_nil body
      assert_empty stdout
      assert_includes stderr, "usage:"
    end
  end

  # sabotage: accept an unknown flag -> red
  def test_unknown_flag_exits_2
    code, body, = run_cli(["call", "--input", "-", "--nope"])
    assert_equal 2, code
    assert_nil body
  end
end

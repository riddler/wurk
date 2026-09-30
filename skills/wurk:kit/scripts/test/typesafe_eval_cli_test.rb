# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "securerandom"
require "fileutils"
require "tmpdir"
require_relative "../typesafe_eval"
require_relative "support/user_config_helper"
require_relative "support/fake_http"

# typesafe_eval.rb driven in-process: TypesafeEvalCli.run with StringIOs, a
# tmp HOME holding the machine config, a tmp key file holding a sentinel
# string (never a real key), XDG_STATE_HOME pinned to a tmpdir, and FakeHTTP
# as the only transport (loading it also locks the real Net::HTTP.start for
# the whole process). This phase makes no call; every captured stdout and
# stderr and every file left under the tmp HOME is swept for the sentinel.
class TypesafeEvalCliTest < Minitest::Test
  include UserConfigHelper

  SENTINEL_KEY = "sentinel-evalcli-#{SecureRandom.hex(12)}"
  FIXTURES = File.expand_path("fixtures/typesafe_eval", __dir__)
  QUESTION_SET = File.join(FIXTURES, "question_set.json")
  STATE_MARK = "Priority: LOW"

  def setup
    @saved_xdg = ENV.key?("XDG_STATE_HOME") ? ENV["XDG_STATE_HOME"] : :unset
    @xdg = Dir.mktmpdir("wurk-eval-cli-xdg-")
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

  # A tmp HOME with a machine config (restricted_sources from `restricted`),
  # the sentinel key file under it, and `@out` for the corpus.
  def with_home(restricted: [])
    in_tmp_home(nil) do |dir|
      @home = dir
      @key_path = File.join(dir, "key", "typesafe-api-token")
      FileUtils.mkdir_p(File.dirname(@key_path))
      File.write(@key_path, "#{SENTINEL_KEY}\n")
      File.chmod(0o600, @key_path)
      write_raw_user_config(dir, JSON.generate(
        "typesafe" => { "key_path" => @key_path, "state_dir" => File.join(dir, "state"),
                        "restricted_sources" => restricted }
      ))
      @out = File.join(dir, "corpus.json")
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
  end

  # [exit_code, parsed_envelope_or_nil, stdout, stderr, prompt_text].
  def run_cli(argv, stdin_text: "")
    io = StringIO.new
    prompt = StringIO.new
    code = nil
    out, err = capture_io do
      code = TypesafeEvalCli.run(argv, io: io, stdin: StringIO.new(stdin_text), prompt: prompt,
                                       http_class: @fake)
    end
    @outputs << io.string << out << err << prompt.string
    body = io.string.start_with?("{") ? JSON.parse(io.string) : nil
    [code, body, io.string + out, err, prompt.string]
  end

  def build_args(*extra)
    ["corpus", "build", "--site", "review", "--question-set", QUESTION_SET, "--out", @out,
     "--from-dir", File.join(FIXTURES, "sources"), "--source", "notes",
     "--from-jsonl", File.join(FIXTURES, "sources.jsonl"), "--source", "feed",
     "--redact-key", "priority", *extra]
  end

  # ---- usage ---------------------------------------------------------------

  # sabotage: read the config before handling --help
  def test_help_exits_0_and_touches_no_config
    code, body, out, err = run_cli(["--help"])
    assert_equal 0, code
    assert_nil body
    assert_includes out, "corpus build"
    assert_includes out, "label"
    assert_empty err
    assert_empty @fake.calls
  end

  # sabotage: let an unknown subcommand fall through to a envelope
  def test_usage_errors_exit_2_with_stderr_and_no_envelope
    [
      [],
      ["frobnicate"],
      ["run"],
      ["corpus"],
      ["corpus", "sweep"],
      ["label"],
      ["corpus", "build", "--site", "review"],
      ["corpus", "build", "--site", "Bad Site", "--question-set", QUESTION_SET, "--out", "x",
       "--from-dir", ".", "--source", "s"],
      ["corpus", "build", "--site", "review", "--question-set", QUESTION_SET, "--out", "x"],
      ["corpus", "build", "--site", "review", "--question-set", QUESTION_SET, "--out", "x",
       "--source", "s"],
      ["corpus", "build", "--site", "review", "--question-set", QUESTION_SET, "--out", "x",
       "--from-jsonl", "f.jsonl", "--source", "s", "--glob", "*.md"],
      ["corpus", "build", "--nonsense"]
    ].each do |argv|
      code, body, out, err = run_cli(argv)
      assert_equal 2, code, "argv #{argv.inspect}"
      assert_nil body
      assert_empty out
      refute_empty err
    end
  end

  # sabotage: default the source label to the path
  def test_a_source_without_a_label_is_a_usage_error
    with_home do
      argv = ["corpus", "build", "--site", "review", "--question-set", QUESTION_SET, "--out", @out,
              "--from-dir", File.join(FIXTURES, "sources"), "--source", "notes",
              "--from-jsonl", File.join(FIXTURES, "sources.jsonl")]
      code, body, _out, err = run_cli(argv)
      assert_equal 2, code
      assert_nil body
      assert_includes err, "--source"
      refute File.exist?(@out)
    end
  end

  # ---- corpus build --------------------------------------------------------

  # sabotage: put case text or a state value in data, or skip the digest
  def test_build_writes_the_corpus_and_reports_counts_only
    with_home do
      code, body, out, err = run_cli(build_args)
      assert_equal 0, code, err
      data = body["data"]
      assert_equal "review", data["site"]
      assert_equal({ "id" => "note-urgency", "version" => 1 }, data["question_set"])
      assert_equal "urgency", data["question"]
      assert_equal 8, data["cases"]
      assert_equal 9, data["redactions"]
      assert_equal 0, data["labels_kept"]
      assert_equal @out, data["out"]
      assert_equal false, data["dry_run"]
      corpus = TypesafeEval.load_corpus(@out)
      assert_equal data["digest"], TypesafeEval.corpus_digest(corpus)
      assert_equal 0o600, File.stat(@out).mode & 0o777
      refute_includes out, "printer toner"
      refute_includes File.read(@out), STATE_MARK
      assert_includes File.read(@out), "Priority: [redacted]"
      assert_empty body["blocked"]
      assert_empty @fake.calls
    end
  end

  # sabotage: write the file under --dry-run
  def test_build_dry_run_writes_nothing
    with_home do
      code, body, = run_cli(build_args("--dry-run"))
      assert_equal 0, code
      assert_equal true, body["data"]["dry_run"]
      assert_equal 8, body["data"]["cases"]
      refute File.exist?(@out)
    end
  end

  # sabotage: check restriction after reading, or write before refusing
  def test_build_refuses_a_restricted_source_and_writes_nothing
    with_home(restricted: ["feed"]) do
      code, body, = run_cli(build_args)
      assert_equal 1, code
      assert_equal ["source_restricted"], body["blocked"].map { |b| b["code"] }
      assert_equal "human", body["blocked"][0]["needs"]
      refute File.exist?(@out)
    end
  end

  # sabotage: map a refusal to needs "none", or fall through to a write
  def test_build_refusals_are_one_blocked_entry_each
    with_home do
      inside = File.join(@home, "src")
      FileUtils.mkdir_p(inside)
      File.write(File.join(inside, "a.md"), "text")
      feed = File.join(@home, "feed.jsonl")
      File.write(feed, %({"id":"a","state":"ok"}\n{"id":"a","state":"again"}\n))
      bad = File.join(@home, "bad.jsonl")
      File.write(bad, %({"id":"a","state":"ok"}\nnot-json-secret-text\n))
      bad_qs = File.join(@home, "qs.json")
      File.write(bad_qs, JSON.generate("question_set" => { "id" => "x", "version" => 1 }))
      base = ["corpus", "build", "--site", "review"]
      cases = {
        "output_inside_source" => [*base, "--question-set", QUESTION_SET, "--out",
                                   File.join(inside, "corpus.json"), "--from-dir", inside, "--source", "s"],
        "duplicate_case_id" => [*base, "--question-set", QUESTION_SET, "--out", @out,
                                "--from-jsonl", feed, "--source", "s"],
        "bad_source_line" => [*base, "--question-set", QUESTION_SET, "--out", @out,
                              "--from-jsonl", bad, "--source", "s"],
        "question_set_invalid" => [*base, "--question-set", bad_qs, "--out", @out,
                                   "--from-jsonl", feed, "--source", "s"]
      }
      cases.each do |code_name, argv|
        code, body, out, = run_cli(argv)
        assert_equal 1, code, code_name
        assert_equal [code_name], body["blocked"].map { |b| b["code"] }
        assert_equal "human", body["blocked"][0]["needs"]
        refute_includes out, "not-json-secret-text"
      end
      refute File.exist?(@out)
    end
  end

  # sabotage: fall through to a stack trace on a missing source
  def test_a_missing_source_dir_is_a_blocked_entry
    with_home do
      argv = ["corpus", "build", "--site", "review", "--question-set", QUESTION_SET, "--out", @out,
              "--from-dir", File.join(@home, "nope"), "--source", "s"]
      code, body, out, = run_cli(argv)
      assert_equal 1, code
      assert_equal ["source_unreadable"], body["blocked"].map { |b| b["code"] }
      refute_includes out, @home
    end
  end

  # sabotage: drop keep_labels! so a rebuild starts from nothing
  def test_rebuild_reports_kept_labels
    with_home do
      run_cli(build_args)
      run_cli(["label", "--corpus", @out], stdin_text: "1\n2\n")
      code, body, = run_cli(build_args)
      assert_equal 0, code
      assert_equal 2, body["data"]["labels_kept"]
    end
  end

  # ---- label ---------------------------------------------------------------

  # sabotage: print state text in the envelope, or the redacted-away text to the prompt
  def test_label_prompts_on_stderr_stream_and_reports_counts_only
    with_home do
      run_cli(build_args)
      code, body, out, _err, prompt = run_cli(["label", "--corpus", @out], stdin_text: "1\ns\nhigh\nq\n")
      assert_equal 0, code
      data = body["data"]
      assert_equal 2, data["labelled"]
      assert_equal 1, data["skipped"]
      assert_equal 5, data["remaining"]
      assert_equal({ "low" => 1, "high" => 1 }, data["per_label"])
      assert_includes prompt, "Priority: [redacted]"
      refute_includes prompt, STATE_MARK
      refute_includes out, "Priority"
      refute_includes out, "staging cluster"
      labels = TypesafeEval.load_corpus(@out)["cases"].map { |c| c["label"] }
      assert_equal 2, labels.compact.size
    end
  end

  # sabotage: label under --dry-run writes the corpus
  def test_label_dry_run_leaves_the_corpus_unchanged
    with_home do
      run_cli(build_args)
      before = File.binread(@out)
      code, body, = run_cli(["label", "--corpus", @out, "--dry-run"], stdin_text: "1\n")
      assert_equal 0, code
      assert_equal 1, body["data"]["labelled"]
      assert_equal before, File.binread(@out)
    end
  end

  # sabotage: let a missing corpus raise
  def test_label_on_a_missing_corpus_is_a_blocked_entry
    with_home do
      code, body, = run_cli(["label", "--corpus", File.join(@home, "absent.json")])
      assert_equal 1, code
      assert_equal ["corpus_invalid"], body["blocked"].map { |b| b["code"] }
    end
  end

  # sabotage: exit on EOF without saving
  def test_label_eof_keeps_given_labels
    with_home do
      run_cli(build_args)
      run_cli(["label", "--corpus", @out], stdin_text: "low\n")
      labels = TypesafeEval.load_corpus(@out)["cases"].map { |c| c["label"] }
      assert_equal "low", labels.first
      assert_equal 1, labels.compact.size
    end
  end

  # ---- run and sweep (Phase 3) ---------------------------------------------

  MODEL = "jev-1.13.0"

  # A tmp HOME whose machine config also carries a budget and a price row, and
  # a labelled 4-case corpus at @out. The key file holds the sentinel.
  def with_eval_home(restricted: [], labels: %w[low high low high])
    with_home(restricted: restricted) do |dir|
      write_raw_user_config(dir, JSON.generate(
        "typesafe" => { "key_path" => @key_path, "state_dir" => File.join(dir, "state"),
                        "restricted_sources" => restricted, "budget" => { "monthly_usd" => 1.0 } },
        "metrics" => { "prices" => { MODEL => { "input" => 0.042, "output" => 0 } } }
      ))
      cases = labels.each_with_index.map do |gold, i|
        { "id" => "case-#{i}", "source" => "notes", "state" => "#{STATE_MARK} #{i}", "redactions" => 0,
          "label" => gold }
      end
      spec = JSON.parse(File.read(QUESTION_SET))
      TypesafeEval.write_corpus(@out, spec.merge("format" => 1, "site" => "review", "labels" => %w[low high],
                                                 "redaction" => { "keys" => [], "labels" => %w[low high] },
                                                 "cases" => cases))
      @state = File.join(dir, "state")
      yield dir
    end
  end

  def answer_body(choice = "low", model: MODEL)
    JSON.generate("model" => model,
                  "answers" => { "urgency" => { "type" => "choice", "choice" => choice, "confidence" => 0.9 } },
                  "usage" => { "input_tokens" => 400, "output_tokens" => 0 })
  end

  def script_ok(count)
    count.times { @fake.respond(200, body: answer_body) }
  end

  def run_file_of(body)
    body["data"]["run_file"]
  end

  # sabotage: send fewer or more requests than cases, or leak state text into data
  def test_run_reports_the_run_and_records_one_command_per_sent_call
    with_eval_home do
      script_ok(4)
      code, body, out, err = run_cli(["run", "--corpus", @out])
      assert_equal 0, code, err
      data = body["data"]
      assert_equal 4, data["cases"]
      assert_equal 4, data["ok_count"]
      assert_equal true, data["complete"]
      assert_nil data["stop_reason"]
      assert_equal "review:note-urgency@1:#{MODEL}", data["threshold_key"]
      assert_operator data["cost_usd"], :>, 0
      assert File.file?(data["run_file"])
      assert_equal 4, body["commands"].size
      assert_equal 4, @fake.calls.size
      refute_includes out, STATE_MARK
      assert_empty body["blocked"]
    end
  end

  # sabotage: exit 0 for a stopped run, or map a budget stop to needs none
  def test_a_stopped_run_is_run_incomplete_with_needs_by_outcome
    with_eval_home do
      script_ok(1)
      @fake.raise_error(Net::ReadTimeout)
      code, body, = run_cli(["run", "--corpus", @out])
      assert_equal 1, code
      assert_equal false, body["data"]["complete"]
      assert_equal "timeout", body["data"]["stop_reason"]
      assert_equal ["run_incomplete"], body["blocked"].map { |b| b["code"] }
      assert_equal "none", body["blocked"][0]["needs"]
      assert_equal 2, body["commands"].size

      # model_mismatch needs a person
      @fake.respond(200, body: answer_body("low", model: "jev-9.9.9"))
      code, body, = run_cli(["run", "--corpus", @out])
      assert_equal 1, code
      assert_equal "human", body["blocked"][0]["needs"]
    end
  end

  # sabotage: let the Interrupt escape the CLI
  def test_an_interrupt_is_run_interrupted_and_the_run_cannot_be_applied
    with_eval_home do
      script_ok(1)
      @fake.raise_error(Interrupt)
      code, body, = run_cli(["run", "--corpus", @out])
      assert_equal 1, code
      assert_equal ["run_interrupted"], body["blocked"].map { |b| b["code"] }
      assert_equal "interrupted", body["data"]["stop_reason"]
      file = run_file_of(body)
      code, body, = run_cli(["sweep", "--run", file, "--corpus", @out, "--apply"])
      assert_equal 1, code
      assert_equal ["partial_run"], body["blocked"].map { |b| b["code"] }
      refute File.exist?(File.join(@state, "eval", "thresholds.json"))
    end
  end

  # sabotage: send under --dry-run, or create the state dir
  def test_run_dry_run_sends_nothing_and_writes_nothing
    with_eval_home do
      code, body, = run_cli(["run", "--corpus", @out, "--dry-run"])
      assert_equal 0, code
      assert_equal true, body["data"]["dry_run"]
      assert_equal 4, body["data"]["would_call"]
      assert_empty body["commands"]
      assert_empty @fake.calls
      refute File.exist?(@state)
    end
  end

  # sabotage: check the source list per call
  def test_run_refuses_a_restricted_source_before_any_call
    with_eval_home(restricted: ["notes"]) do
      code, body, = run_cli(["run", "--corpus", @out])
      assert_equal 1, code
      assert_equal ["source_restricted"], body["blocked"].map { |b| b["code"] }
      assert_empty @fake.calls
      refute File.exist?(File.join(@state, "eval"))
    end
  end

  # sabotage: run an unlabelled corpus
  def test_run_with_nothing_labelled_is_blocked
    with_eval_home(labels: [nil, nil]) do
      code, body, = run_cli(["run", "--corpus", @out])
      assert_equal 1, code
      assert_equal ["nothing_labelled"], body["blocked"].map { |b| b["code"] }
      assert_empty @fake.calls
    end
  end

  # sabotage: apply from a partial run, or fail a report-only sweep
  def test_sweep_reports_a_partial_run_but_only_apply_refuses
    with_eval_home do
      script_ok(1)
      @fake.raise_error(Net::ReadTimeout)
      _code, body, = run_cli(["run", "--corpus", @out])
      file = run_file_of(body)
      store = File.join(@state, "eval", "thresholds.json")

      code, body, = run_cli(["sweep", "--run", file, "--corpus", @out])
      assert_equal 0, code
      assert_equal %w[stopped_early case_missing case_not_ok], body["data"]["partial_reasons"]
      assert_equal ["partial_run"], body["warnings"].map { |w| w["code"] }
      assert_equal false, body["data"]["applied"]
      assert_equal %w[low high], body["data"]["labels"].keys

      code, body, = run_cli(["sweep", "--run", file, "--corpus", @out, "--apply"])
      assert_equal 1, code
      assert_equal ["partial_run"], body["blocked"].map { |b| b["code"] }
      refute File.exist?(store)
    end
  end

  # sabotage: write the store under --dry-run, or skip it on a complete run
  def test_sweep_apply_stores_the_entry_and_dry_run_does_not
    with_eval_home do
      script_ok(4)
      _code, body, = run_cli(["run", "--corpus", @out])
      file = run_file_of(body)
      store = File.join(@state, "eval", "thresholds.json")

      code, body, = run_cli(["sweep", "--run", file, "--corpus", @out, "--apply", "--dry-run"])
      assert_equal 0, code
      assert_equal false, body["data"]["applied"]
      assert_equal true, body["data"]["dry_run"]
      assert_equal [], body["data"]["partial_reasons"]
      refute_nil body["data"]["entry"]
      refute File.exist?(store)

      code, body, = run_cli(["sweep", "--run", file, "--corpus", @out, "--apply"])
      assert_equal 0, code
      assert_equal true, body["data"]["applied"]
      keys = JSON.parse(File.read(store))["keys"]
      assert_equal ["review:note-urgency@1:#{MODEL}"], keys.keys
      assert_nil keys.values.first["labels"]["low"]["threshold"], "4 cases are far below 10 routed: n/a"
      assert_equal "too_few_routed", keys.values.first["labels"]["low"]["reason"]
    end
  end

  # sabotage: fall through to a stack trace for a missing run file
  def test_sweep_on_a_missing_run_is_a_blocked_entry
    with_eval_home do
      code, body, = run_cli(["sweep", "--run", File.join(@home, "nope.jsonl"), "--corpus", @out])
      assert_equal 1, code
      assert_equal ["run_unreadable"], body["blocked"].map { |b| b["code"] }
    end
  end

  # sabotage: treat a missing flag as a blocked envelope
  def test_run_and_sweep_usage_errors_exit_2
    [["run"], ["sweep"], ["sweep", "--run", "x"], ["run", "--corpus", "x", "extra"]].each do |argv|
      code, body, out, err = run_cli(argv)
      assert_equal 2, code, argv.inspect
      assert_nil body
      assert_empty out
      refute_empty err
    end
  end
end

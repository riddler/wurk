# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "securerandom"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../lib/typesafe_eval"
require_relative "support/user_config_helper"
require_relative "support/fake_http"

# Phase 1: the pure math. Every expected Wilson value below is a literal
# worked by hand (z = 1.96, z^2 = 3.8416), never computed by the library.
class TypesafeEvalMathTest < Minitest::Test
  def rows(count, label:, predicted:, confidence:)
    Array.new(count) { { label: label, predicted: predicted, confidence: confidence } }
  end

  # sabotage: drop the "+ z^2/(2n)" centre term and every value below moves
  def test_wilson_10_of_10
    # p = 1: the sqrt term is z*sqrt(z^2/(4n^2)) = z^2/(2n), which cancels the
    # centre's z^2/(2n). lb = 1 / (1 + 3.8416/10) = 10 / 13.8416 = 0.722460
    assert_in_delta 0.722460, TypesafeEval.wilson_lower_bound(10, 10), 1e-6
  end

  # sabotage: use z = 1.645 (90%) and this rises above 0.90
  def test_wilson_34_of_34_is_below_the_bar
    # 34 / (34 + 3.8416) = 34 / 37.8416 = 0.898482
    lb = TypesafeEval.wilson_lower_bound(34, 34)
    assert_in_delta 0.898482, lb, 1e-6
    assert_operator lb, :<, 0.90
  end

  # sabotage: swap the sign of the margin and 35/35 exceeds 1.0
  def test_wilson_35_of_35_is_the_first_to_clear_the_bar
    # 35 / (35 + 3.8416) = 35 / 38.8416 = 0.901096
    lb = TypesafeEval.wilson_lower_bound(35, 35)
    assert_in_delta 0.901096, lb, 1e-6
    assert_operator lb, :>=, 0.90
  end

  # sabotage: use n instead of 2n in the centre term
  def test_wilson_95_of_100
    # p = 0.95
    # z^2/(2n)      = 3.8416 / 200         = 0.019208
    # p(1-p)/n      = 0.0475 / 100         = 0.000475
    # z^2/(4n^2)    = 3.8416 / 40000       = 0.00009604
    # sqrt(0.000475 + 0.00009604) = sqrt(0.00057104) = 0.0238964
    # margin        = 1.96 * 0.0238964     = 0.0468370
    # numerator     = 0.95 + 0.019208 - 0.0468370 = 0.922371
    # denominator   = 1 + 3.8416 / 100     = 1.038416
    # lb            = 0.922371 / 1.038416  = 0.888248
    assert_in_delta 0.888248, TypesafeEval.wilson_lower_bound(95, 100), 1e-6
  end

  # sabotage: divide by n instead of (1 + z^2/n) and this lands near 0.88
  def test_wilson_38_of_40
    # p = 0.95
    # z^2/(2n)      = 3.8416 / 80          = 0.048020
    # p(1-p)/n      = 0.0475 / 40          = 0.0011875
    # z^2/(4n^2)    = 3.8416 / 6400        = 0.0006002500
    # sqrt(0.0011875 + 0.00060025) = sqrt(0.00178775) = 0.0422818
    # margin        = 1.96 * 0.0422818     = 0.0828723
    # numerator     = 0.95 + 0.048020 - 0.0828723 = 0.915148
    # denominator   = 1 + 3.8416 / 40      = 1.09604
    # lb            = 0.915148 / 1.09604   = 0.834958
    assert_in_delta 0.834958, TypesafeEval.wilson_lower_bound(38, 40), 1e-6
  end

  # sabotage: return 0.0 for an empty denominator and the nil check fails
  def test_wilson_no_denominator_is_nil
    assert_nil TypesafeEval.wilson_lower_bound(0, 0)
  end

  # sabotage: delete the argument validation and 5-of-3 returns a number
  def test_wilson_rejects_bad_arguments
    assert_raises(ArgumentError) { TypesafeEval.wilson_lower_bound(4, 3) }
    assert_raises(ArgumentError) { TypesafeEval.wilson_lower_bound(-1, 3) }
    assert_raises(ArgumentError) { TypesafeEval.wilson_lower_bound(1.0, 3) }
    assert_raises(ArgumentError) { TypesafeEval.wilson_lower_bound(1, "3") }
  end

  # sabotage: return the raw probability for noul and the confidence check fails
  def test_interpret_choice_and_noul
    choice = { "type" => "choice", "choice" => "a", "confidence" => 0.7,
               "probabilities" => { "a" => 0.7, "b" => 0.3 } }
    assert_equal ["a", 0.7], TypesafeEval.interpret(choice)
    assert_equal ["true", 0.8], TypesafeEval.interpret("type" => "noul", "noul" => 0.8)
    assert_equal ["false", 0.7], TypesafeEval.interpret("type" => "noul", "noul" => 0.3)
    # 0.5 ties to true, with confidence max(0.5, 0.5)
    assert_equal ["true", 0.5], TypesafeEval.interpret("type" => "noul", "noul" => 0.5)
  end

  # sabotage: accept a score answer and the first assertion fails
  def test_interpret_returns_nil_for_unreadable_answers
    assert_nil TypesafeEval.interpret("type" => "score", "score" => 3, "confidence" => 0.9)
    assert_nil TypesafeEval.interpret("type" => "mystery", "choice" => "a", "confidence" => 0.9)
    assert_nil TypesafeEval.interpret({ "type" => "choice", "choice" => "z", "confidence" => 0.9 },
                                      labels: %w[a b])
    assert_nil TypesafeEval.interpret("type" => "choice", "choice" => "a")
    assert_nil TypesafeEval.interpret("type" => "choice", "choice" => "a", "confidence" => 1.2)
    assert_nil TypesafeEval.interpret("type" => "choice", "choice" => "a", "confidence" => "0.9")
    assert_nil TypesafeEval.interpret("type" => "noul", "noul" => 1.2)
    assert_nil TypesafeEval.interpret("type" => "noul")
    assert_nil TypesafeEval.interpret("nope")
    assert_nil TypesafeEval.interpret(nil)
  end

  # sabotage: return criteria values instead of keys
  def test_labels_for
    q = { "type" => "choice", "instructions" => "x", "criteria" => { "a" => "one", "b" => "two" } }
    assert_equal %w[a b], TypesafeEval.labels_for(q)
    assert_equal %w[true false], TypesafeEval.labels_for("type" => "noul", "instructions" => "x")
  end

  # sabotage: let a score question through and the first raise disappears
  def test_labels_for_refuses_score_and_bad_criteria
    assert_raises(ArgumentError) { TypesafeEval.labels_for("type" => "score", "instructions" => "x") }
    assert_raises(ArgumentError) { TypesafeEval.labels_for("type" => "choice", "criteria" => %w[a b]) }
    assert_raises(ArgumentError) { TypesafeEval.labels_for("type" => "choice", "criteria" => {}) }
    assert_raises(ArgumentError) { TypesafeEval.labels_for("type" => "choice") }
    assert_raises(ArgumentError) { TypesafeEval.labels_for(nil) }
  end

  # sabotage: build the grid with a float accumulator (0.05 * i drift)
  def test_thresholds_grid
    t = TypesafeEval::THRESHOLDS
    assert_equal 19, t.size
    assert_equal 0.05, t.first
    assert_equal 0.95, t.last
    assert_equal 0.15, t[2]
    assert_equal 0.35, t[6]
    assert_equal 0.55, t[10]
    assert_equal 0.85, t[16]
    assert t.frozen?
  end

  # sabotage: pick the highest passing threshold and 0.35 becomes 0.60
  def test_sweep_label_a_picks_the_smallest_clearing_threshold
    judged = rows(36, label: "a", predicted: "a", confidence: 0.60) +
             rows(2, label: "a", predicted: "a", confidence: 0.30) +
             rows(2, label: "c", predicted: "a", confidence: 0.30)
    a = TypesafeEval.sweep(judged, labels: %w[a b c])["a"]
    # t <= 0.30: n = 40, k = 38, lb = 0.834958 (fails). t = 0.35: n = 36,
    # k = 36, lb = 36 / (36 + 3.8416) = 36 / 39.8416 = 0.903578 (passes).
    assert_equal 0.35, a[:threshold]
    assert_equal 36, a[:routed]
    assert_equal 36, a[:correct]
    assert_in_delta 1.0, a[:precision], 1e-9
    assert_in_delta 0.903578, a[:lower_bound], 1e-6
  end

  # sabotage: lower min_routed to 9 and label b gets a threshold
  def test_sweep_label_b_with_nine_routed_is_too_few
    judged = rows(9, label: "b", predicted: "b", confidence: 0.90)
    b = TypesafeEval.sweep(judged, labels: %w[a b c])["b"]
    assert_nil b[:threshold]
    assert_equal "too_few_routed", b[:reason]
    assert_nil b[:best]
  end

  # sabotage: report too_few_routed for every miss and this loses its best
  def test_sweep_label_c_below_bound_reports_best
    judged = rows(12, label: "c", predicted: "c", confidence: 0.95) +
             rows(3, label: "a", predicted: "c", confidence: 0.95)
    c = TypesafeEval.sweep(judged, labels: %w[a b c])["c"]
    # 12/15: p = 0.8; centre 0.8 + 3.8416/30 = 0.928053; sqrt(0.0106667 +
    # 0.0042684) = 0.122209; margin 0.239530; num 0.688523; den 1.256107;
    # lb = 0.548141.
    assert_nil c[:threshold]
    assert_equal "below_bound", c[:reason]
    assert_equal 15, c[:best][:routed]
    assert_equal 12, c[:best][:correct]
    assert_in_delta 0.548141, c[:best][:lower_bound], 1e-6
  end

  # sabotage: iterate only over labels some case predicts
  def test_sweep_includes_labels_no_case_predicts
    judged = rows(12, label: "a", predicted: "a", confidence: 0.9)
    out = TypesafeEval.sweep(judged, labels: %w[a b c])
    assert_equal %w[a b c], out.keys
    assert_equal "too_few_routed", out["c"][:reason]
  end

  # sabotage: drop the n >= min_routed guard and 9 correct passes 0.5 too
  def test_ten_case_rule_has_teeth_on_its_own
    ten = TypesafeEval.sweep(rows(10, label: "a", predicted: "a", confidence: 0.9),
                             labels: %w[a], min_lower_bound: 0.5)["a"]
    # 10/10 lb = 0.722460 >= 0.5, cleared at the first grid step
    assert_equal 0.05, ten[:threshold]
    assert_in_delta 0.722460, ten[:lower_bound], 1e-6
    nine = TypesafeEval.sweep(rows(9, label: "a", predicted: "a", confidence: 0.9),
                              labels: %w[a], min_lower_bound: 0.5)["a"]
    # 9/9 lb = 9 / (9 + 3.8416) = 0.700847 would have passed 0.5 but for n < 10
    assert_nil nine[:threshold]
    assert_equal "too_few_routed", nine[:reason]
  end

  # sabotage: scan thresholds from high to low and the answer becomes 0.50
  def test_smallest_threshold_is_literal_because_the_bound_is_not_monotone
    judged = rows(36, label: "d", predicted: "d", confidence: 0.60) +
             rows(2, label: "x", predicted: "d", confidence: 0.45) +
             rows(40, label: "d", predicted: "d", confidence: 0.40) +
             rows(2, label: "x", predicted: "d", confidence: 0.35)
    d = TypesafeEval.sweep(judged, labels: %w[d x])["d"]
    # The low-confidence errors sit at 0.35 (the plan puts them at 0.05, but
    # then they drop out at t = 0.10 and the answer would be 0.10).
    # t 0.05..0.35: 76/80, lb 0.878375 (fails). t 0.40: 76/78, lb 0.911246
    # (passes). t 0.45: 36/38, lb 0.827142 (fails). t 0.50..0.60: 36/36,
    # lb 0.903578 (passes). The smallest passing t is 0.40, not 0.50.
    assert_equal 0.40, d[:threshold]
    assert_equal 78, d[:routed]
    assert_equal 76, d[:correct]
    assert_in_delta 0.911246, d[:lower_bound], 1e-6
  end

  # sabotage: compare the rounded bound and a 0.8999996 value would pass
  def test_comparison_uses_the_unrounded_bound
    # 34/34 is 0.898482; with the bar set just above the rounded 6-place
    # value, the case must still fail on the unrounded number.
    judged = rows(34, label: "a", predicted: "a", confidence: 0.9)
    out = TypesafeEval.sweep(judged, labels: %w[a], min_lower_bound: 0.8984825)["a"]
    assert_nil out[:threshold]
    assert_equal "below_bound", out[:reason]
  end
end

# Phase 2: the corpus format, redaction, the builder and the labeller.
class TypesafeEvalCorpusTest < Minitest::Test
  include UserConfigHelper

  FIXTURES = File.expand_path("fixtures/typesafe_eval", __dir__)
  QUESTION_SET = File.join(FIXTURES, "question_set.json")
  SENTINEL_KEY = "sentinel-eval-#{SecureRandom.hex(12)}"

  def setup
    @tmp = Dir.mktmpdir("wurk-eval-corpus-")
    @key_path = File.join(@tmp, "key")
    File.write(@key_path, "#{SENTINEL_KEY}\n")
    @out = File.join(@tmp, "out", "corpus.json")
  end

  def teardown
    Dir.glob(File.join(@tmp, "**", "*"), File::FNM_DOTMATCH).each do |path|
      next unless File.file?(path)
      next if path == @key_path

      refute_includes File.read(path), SENTINEL_KEY, "sentinel key found in #{path}"
    end
    FileUtils.remove_entry(@tmp)
  end

  def config(restricted: [])
    body = { "typesafe" => { "key_path" => @key_path, "restricted_sources" => restricted } }
    UserConfig.new(path: "(fixture)", raw: body, exists: true)
  end

  def dir_source(path = File.join(FIXTURES, "sources"), label: "notes", glob: nil)
    { kind: "dir", path: path, source: label, glob: glob }
  end

  def jsonl_source(path = File.join(FIXTURES, "sources.jsonl"), label: "feed")
    { kind: "jsonl", path: path, source: label }
  end

  def build(sources: [dir_source, jsonl_source], keys: ["priority"], config: self.config, **more)
    TypesafeEval.build_corpus(config: config, question_set_file: QUESTION_SET, site: "review",
                              sources: sources, redact_keys: keys, out: @out, **more)
  end

  def refusal_code
    yield
    flunk "expected a Refusal"
  rescue TypesafeEval::Refusal => e
    e.code
  end

  def redact(text, keys: ["priority"], labels: %w[low high])
    TypesafeEval.redact(text, keys: keys, labels: labels)
  end

  # ---- redaction -----------------------------------------------------------

  # sabotage: drop the key-value rule, or let its value run past the newline
  def test_redacts_a_key_value_up_to_the_end_of_the_line
    assert_equal ["Priority: [redacted]\nbody", 1], redact("Priority: LOW\nbody")
  end

  # sabotage: stop the value at the first space instead of , ; | or newline
  def test_key_value_stops_at_a_separator
    assert_equal ["Priority: [redacted], keep this", 1], redact("Priority = very low, keep this")
  end

  # sabotage: drop the bracket form from the tagged-label rule
  def test_redacts_tagged_labels
    assert_equal ["tagged [redacted] here", 1], redact("tagged [high] here")
    assert_equal ["a [redacted] b", 1], redact("a (LOW) b")
    assert_equal ["a [redacted] b", 1], redact("a {low} b")
  end

  # sabotage: require a leading space before the hash, or drop the rule
  def test_redacts_hash_tag_and_label_field
    assert_equal ["[redacted]", 1], redact("#high")
    assert_equal ["label: [redacted]", 1], redact("label: high")
    assert_equal ["label: [redacted]", 1], redact("Label=LOW")
  end

  # sabotage: redact bare label words too and the prose changes
  def test_bare_prose_label_words_are_kept
    assert_equal ["the risk is high", 0], redact("the risk is high")
    assert_equal ["#highway stays", 0], redact("#highway stays")
  end

  # sabotage: drop Regexp.escape and "a.b" matches "axb"
  def test_key_metacharacters_match_literally
    assert_equal ["axb: 1", 0], redact("axb: 1", keys: ["a.b"])
    assert_equal ["a.b: [redacted]", 1], redact("a.b: 1", keys: ["a.b"])
  end

  # sabotage: redact only top-level strings
  def test_walks_objects_and_arrays
    state = { "title" => "x", "notes" => ["fine", "tagged [low]", { "deep" => "Priority: HIGH" }],
              "priority" => "HIGH" }
    out, count = TypesafeEval.redact_state(state, keys: ["priority"], labels: %w[low high])
    assert_equal({ "title" => "x", "notes" => ["fine", "tagged [redacted]", { "deep" => "Priority: [redacted]" }],
                   "priority" => "[redacted]" }, out)
    assert_equal 3, count
    assert_equal "tagged [low]", state["notes"][1], "the input state is not mutated"
  end

  # ---- builder -------------------------------------------------------------

  # sabotage: skip redaction on jsonl sources, or count nothing
  def test_builds_one_corpus_from_a_dir_and_a_jsonl_source
    corpus = build
    ids = corpus["cases"].map { |c| c["id"] }
    assert_equal %w[broken-build.md deploy-freeze.md expired-cert.md lunch-poll.md tidy-notes.md
                    jsonl-1 jsonl-2 jsonl-3], ids
    assert_equal %w[notes notes notes notes notes feed feed feed], corpus["cases"].map { |c| c["source"] }
    assert_equal %w[low high], corpus["labels"]
    assert_equal({ "keys" => ["priority"], "labels" => %w[low high] }, corpus["redaction"])
    assert_equal 1, corpus["format"]
    assert_equal({ "id" => "note-urgency", "version" => 1 }, corpus["question_set"])
    assert_equal "review", corpus["site"]
    # one R1 hit in each of the first three notes and in jsonl-1, one R2 tag
    # in lunch-poll, expired-cert and tidy-notes; jsonl-2 loses its key and
    # jsonl-3 has one "{low}" tag ("(low)" is a bare parenthesised word: R2
    # takes it too, so 2)
    assert_equal({ "broken-build.md" => 1, "deploy-freeze.md" => 1, "expired-cert.md" => 1,
                   "lunch-poll.md" => 1, "tidy-notes.md" => 1, "jsonl-1" => 1, "jsonl-2" => 1,
                   "jsonl-3" => 2 },
                 corpus["cases"].each_with_object({}) { |c, h| h[c["id"]] = c["redactions"] })
    text = JSON.generate(corpus["cases"])
    refute_match(/Priority: (LOW|HIGH)/i, text)
    refute_includes text, "[high]"
    assert_includes text, "Priority: [redacted]"
    assert_includes text, "The risk is high only if", "bare prose label words stay"
    corpus["cases"].each { |c| assert_nil c["label"] }
  end

  # sabotage: open a source for writing, or write next to it
  def test_sources_are_only_read
    before = Dir.glob(File.join(FIXTURES, "**", "*")).select { |f| File.file?(f) }.map do |f|
      [f, File.binread(f), File.mtime(f)]
    end
    build
    after = Dir.glob(File.join(FIXTURES, "**", "*")).select { |f| File.file?(f) }.map do |f|
      [f, File.binread(f), File.mtime(f)]
    end
    assert_equal before, after
  end

  # sabotage: match the glob against the whole path instead of the dir
  def test_dir_glob_narrows_the_files
    corpus = build(sources: [dir_source(glob: "deploy-*.md")], keys: [])
    assert_equal ["deploy-freeze.md"], corpus["cases"].map { |c| c["id"] }
  end

  # sabotage: move the restricted check after the read -> a read error, not source_restricted
  def test_restricted_source_refuses_before_any_read
    missing = File.join(@tmp, "no-such-dir")
    code = refusal_code do
      build(sources: [dir_source(missing, label: "secret")], config: config(restricted: ["secret"]))
    end
    assert_equal "source_restricted", code
    refute File.exist?(@out)
  end

  # sabotage: read the source (File.read) before comparing labels
  def test_restricted_source_is_not_read_even_when_unreadable
    skip "root ignores file modes" if Process.uid.zero?
    locked = File.join(@tmp, "locked.jsonl")
    File.write(locked, "not json at all\n")
    File.chmod(0o000, locked)
    code = refusal_code do
      build(sources: [jsonl_source(locked, label: "secret")], config: config(restricted: ["secret"]))
    end
    assert_equal "source_restricted", code
  ensure
    File.chmod(0o600, locked) if locked && File.exist?(locked)
  end

  # sabotage: check only the first source's label
  def test_a_restricted_second_source_refuses_the_whole_build
    code = refusal_code { build(config: config(restricted: ["feed"])) }
    assert_equal "source_restricted", code
  end

  # sabotage: drop the output-inside-source check
  def test_output_inside_a_source_dir_or_over_a_source_file_is_refused
    src = File.join(@tmp, "src")
    FileUtils.mkdir_p(src)
    File.write(File.join(src, "a.md"), "one")
    @out = File.join(src, "corpus.json")
    assert_equal "output_inside_source", refusal_code { build(sources: [dir_source(src)], keys: []) }
    feed = File.join(@tmp, "feed.jsonl")
    File.write(feed, %({"id":"a","state":"x"}\n))
    @out = feed
    assert_equal "output_inside_source", refusal_code { build(sources: [jsonl_source(feed)], keys: []) }
  end

  # sabotage: let a later case overwrite an earlier one silently
  def test_duplicate_case_ids_refuse_without_quoting_the_id
    feed = File.join(@tmp, "dupes.jsonl")
    File.write(feed, %({"id":"same-id-mark","state":"x"}\n{"id":"same-id-mark","state":"y"}\n))
    error = assert_raises(TypesafeEval::Refusal) { build(sources: [jsonl_source(feed)], keys: []) }
    assert_equal "duplicate_case_id", error.code
    refute_includes error.message, "same-id-mark"
  end

  # sabotage: put the line text in the message
  def test_bad_jsonl_line_names_the_line_number_only
    feed = File.join(@tmp, "bad.jsonl")
    File.write(feed, %({"id":"a","state":"ok"}\n{"id": "b", "state": 42, "leak": "secret-line-text"}\n))
    error = assert_raises(TypesafeEval::Refusal) { build(sources: [jsonl_source(feed)], keys: []) }
    assert_equal "bad_source_line", error.code
    assert_includes error.message, "line 2"
    refute_includes error.message, "secret-line-text"
    File.write(feed, "{not json secret-line-text\n")
    error = assert_raises(TypesafeEval::Refusal) { build(sources: [jsonl_source(feed)], keys: []) }
    assert_equal "bad_source_line", error.code
    refute_includes error.message, "secret-line-text"
  end

  # sabotage: accept a question set that fails the client's validation
  def test_invalid_question_sets_are_refused_by_field
    path = File.join(@tmp, "qs.json")
    good = JSON.parse(File.read(QUESTION_SET))
    bad = [
      [good.merge("question" => "absent"), "question"],
      [good.merge("question_set" => { "id" => "x", "version" => 0 }), "question_set"],
      [good.merge("questions" => { "urgency" => { "type" => "choice", "instructions" => "  " } }),
       "questions.urgency.instructions"],
      [good.merge("questions" => { "urgency" => { "type" => "choice", "instructions" => "i", "criteria" => [] } }),
       "questions.urgency"],
      [good.merge("questions" => { "urgency" => { "type" => "score", "instructions" => "i" } }),
       "questions.urgency"]
    ]
    bad.each do |raw, field|
      File.write(path, JSON.generate(raw))
      error = assert_raises(TypesafeEval::Refusal) do
        TypesafeEval.load_question_set(path, site: "review")
      end
      assert_equal "question_set_invalid", error.code
      assert_includes error.message, field
    end
    File.write(path, "{nope")
    assert_raises(TypesafeEval::Refusal) { TypesafeEval.load_question_set(path, site: "review") }
  end

  # sabotage: always start labels at nil
  def test_rebuild_keeps_unchanged_labels_and_drops_a_changed_ones
    src = File.join(@tmp, "src")
    FileUtils.mkdir_p(src)
    File.write(File.join(src, "a.md"), "alpha text")
    File.write(File.join(src, "b.md"), "bravo text")
    corpus = build(sources: [dir_source(src)], keys: [])
    corpus["cases"][0]["label"] = "low"
    corpus["cases"][1]["label"] = "high"
    TypesafeEval.write_corpus(@out, corpus)
    File.write(File.join(src, "b.md"), "bravo text, edited")
    File.write(File.join(src, "c.md"), "charlie text")
    rebuilt = build(sources: [dir_source(src)], keys: [])
    assert_equal({ "a.md" => "low", "b.md" => nil, "c.md" => nil },
                 rebuilt["cases"].each_with_object({}) { |c, h| h[c["id"]] = c["label"] })
  end

  # ---- digest and file -----------------------------------------------------

  # sabotage: leave labels, case text or question text out of the digest
  def test_digest_changes_with_label_text_and_question_and_not_with_a_rewrite
    corpus = build
    base = TypesafeEval.corpus_digest(corpus)
    assert_match(/\A\h{64}\z/, base)
    TypesafeEval.write_corpus(@out, corpus)
    assert_equal base, TypesafeEval.corpus_digest(TypesafeEval.load_corpus(@out))

    labelled = Marshal.load(Marshal.dump(corpus))
    labelled["cases"][0]["label"] = "low"
    refute_equal base, TypesafeEval.corpus_digest(labelled)
    edited = Marshal.load(Marshal.dump(corpus))
    edited["cases"][0]["state"] += " more"
    refute_equal base, TypesafeEval.corpus_digest(edited)
    asked = Marshal.load(Marshal.dump(corpus))
    asked["questions"]["urgency"]["instructions"] += "!"
    refute_equal base, TypesafeEval.corpus_digest(asked)
  end

  # sabotage: write in place and a mid-write failure truncates the corpus
  def test_write_corpus_is_atomic_and_private
    corpus = build
    TypesafeEval.write_corpus(@out, corpus)
    assert_equal "\n", File.read(@out)[-1]
    assert_equal 0o600, File.stat(@out).mode & 0o777
    assert_equal [File.basename(@out)], Dir.children(File.dirname(@out))
  end

  def test_load_corpus_refuses_a_non_corpus_without_quoting_it
    File.write(@key_path, "x")
    error = assert_raises(TypesafeEval::Refusal) { TypesafeEval.load_corpus(@key_path) }
    assert_equal "corpus_invalid", error.code
    File.write(@key_path, "#{SENTINEL_KEY}\n")
  end

  # ---- labeller ------------------------------------------------------------

  def written_corpus(count = 4)
    cases = Array.new(count) do |i|
      { "id" => "case-#{i + 1}", "source" => "notes", "state" => "text #{i + 1}\nPriority: [redacted]",
        "redactions" => 1, "label" => nil }
    end
    corpus = build(sources: [jsonl_source(jsonl_of(cases))], keys: [])
    corpus["cases"] = cases
    TypesafeEval.write_corpus(@out, corpus)
    corpus
  end

  def jsonl_of(cases)
    path = File.join(@tmp, "seed.jsonl")
    File.write(path, cases.map { |c| JSON.generate("id" => c["id"], "state" => c["state"]) }.join("\n") + "\n")
    path
  end

  def label(text, **opts)
    prompt = StringIO.new
    summary = TypesafeEval.label(corpus_path: @out, input: StringIO.new(text), prompt: prompt, **opts)
    [summary, prompt.string]
  end

  def labels_on_disk
    TypesafeEval.load_corpus(@out)["cases"].map { |c| c["label"] }
  end

  # sabotage: skip advances without counting, or q does not stop the walk
  def test_labeller_records_skips_and_quits
    written_corpus
    summary, shown = label("1\ns\nhigh\nq\n")
    assert_equal({ labelled: 2, skipped: 1, remaining: 1, per_label: { "low" => 1, "high" => 1 } }, summary)
    assert_equal ["low", nil, "high", nil], labels_on_disk
    assert_includes shown, "Priority: [redacted]"
    refute_includes shown, "Priority: LOW"
    assert_includes shown, "1) low"
  end

  # sabotage: only write the corpus when the walk finishes
  def test_eof_mid_walk_keeps_labels_given_so_far
    written_corpus
    summary, = label("2\n")
    assert_equal 1, summary[:labelled]
    assert_equal 3, summary[:remaining]
    assert_equal ["high", nil, nil, nil], labels_on_disk
  end

  # sabotage: record the garbage answer as a label, or stop on it
  def test_unknown_answer_reprompts_without_recording
    written_corpus(1)
    summary, shown = label("maybe\n9\n0\nLOW\n")
    assert_equal 1, summary[:labelled]
    assert_equal ["low"], labels_on_disk
    assert_equal 3, shown.scan("not a choice").size
  end

  # sabotage: write the corpus under dry_run
  def test_dry_run_leaves_the_corpus_bytes_unchanged
    written_corpus
    before = File.binread(@out)
    summary, = label("1\n2\n", dry_run: true)
    assert_equal 2, summary[:labelled]
    assert_equal before, File.binread(@out)
  end

  # sabotage: walk labelled cases without relabel, or drop kept labels
  def test_only_unlabelled_cases_are_walked_unless_relabel
    corpus = written_corpus(2)
    corpus["cases"][0]["label"] = "high"
    TypesafeEval.write_corpus(@out, corpus)
    summary, shown = label("low\n")
    assert_equal 1, summary[:labelled]
    refute_includes shown, "case-1"
    assert_equal %w[high low], labels_on_disk
    summary, = label("s\nhigh\n", relabel: true)
    assert_equal({ labelled: 1, skipped: 1, remaining: 0, per_label: { "low" => 0, "high" => 2 } }, summary)
  end
end

# Phase 3: the eval run through Typesafe.judge, the partial-run rules, the
# threshold store. FakeHTTP is the only transport; every config names a tmp
# state dir and a tmp key file holding a sentinel string, never a real key.
class TypesafeEvalRunTest < Minitest::Test
  include UserConfigHelper

  MODEL = "jev-1.13.0"
  SENTINEL_KEY = "sentinel-evalrun-#{SecureRandom.hex(12)}"
  STATE_MARK = "statemark-#{SecureRandom.hex(6)}"
  QUESTION_TEXT = "Decide how urgent the note is for its reader."
  QSET = { "id" => "note-urgency", "version" => 1 }.freeze
  QUESTION = { "type" => "choice", "instructions" => QUESTION_TEXT,
               "criteria" => { "low" => "Nothing waits.", "high" => "Someone is blocked." } }.freeze
  KEY = "review:note-urgency@1:#{MODEL}"

  def setup
    @saved_xdg = ENV.key?("XDG_STATE_HOME") ? ENV["XDG_STATE_HOME"] : :unset
    @tmp = Dir.mktmpdir("wurk-eval-run-")
    ENV["XDG_STATE_HOME"] = File.join(@tmp, "xdg")
    @state_dir = File.join(@tmp, "state")
    @key_path = File.join(@tmp, "key")
    File.write(@key_path, "#{SENTINEL_KEY}\n")
    File.chmod(0o600, @key_path)
    @corpus_path = File.join(@tmp, "corpus.json")
    @fake = FakeHTTP.new
    @time = Time.utc(2026, 9, 15, 12, 0, 0)
    @slept = []
    @now = -> { @time }
    @sleeper = ->(s) { @slept << s }
  end

  def teardown
    Dir.glob(File.join(@tmp, "**", "*"), File::FNM_DOTMATCH).each do |path|
      next unless File.file?(path)
      next if path == @key_path

      refute_includes File.read(path), SENTINEL_KEY, "sentinel key found in #{path}"
    end
  ensure
    if @saved_xdg == :unset
      ENV.delete("XDG_STATE_HOME")
    else
      ENV["XDG_STATE_HOME"] = @saved_xdg
    end
    FileUtils.remove_entry(@tmp)
  end

  # ---- helpers -------------------------------------------------------------

  def config(model: nil, restricted: [], per_minute: nil, monthly: 1.0)
    budget = { "monthly_usd" => monthly }
    budget["per_minute"] = per_minute if per_minute
    section = { "key_path" => @key_path, "state_dir" => @state_dir, "budget" => budget,
                "restricted_sources" => restricted }
    section["model"] = model if model
    raw = { "typesafe" => section,
            "metrics" => { "prices" => { (model || MODEL) => { "input" => 0.042, "output" => 0 } } } }
    cfg = UserConfig.new(path: "(fixture)", raw: raw, exists: true)
    assert_empty cfg.errors, "fixture config must be valid"
    cfg
  end

  # Cases are (id, gold label or nil). All states have the same length so the
  # no-usage cost bound is the same for every case.
  def write_corpus(golds, site: "review", path: @corpus_path)
    cases = golds.each_with_index.map do |gold, i|
      { "id" => format("case-%02d", i), "source" => "notes", "state" => "#{STATE_MARK} #{format('%02d', i)}",
        "redactions" => 0, "label" => gold }
    end
    corpus = { "format" => 1, "site" => site, "question_set" => QSET, "question" => "urgency",
               "questions" => { "urgency" => QUESTION }, "labels" => %w[low high],
               "redaction" => { "keys" => [], "labels" => %w[low high] }, "cases" => cases }
    TypesafeEval.write_corpus(path, corpus)
    corpus
  end

  def body(choice: "low", confidence: 0.9, model: MODEL, answer: nil)
    answer ||= { "type" => "choice", "choice" => choice, "probabilities" => {}, "confidence" => confidence }
    JSON.generate("model" => model, "answers" => { "urgency" => answer },
                  "usage" => { "input_tokens" => 400, "output_tokens" => 0 })
  end

  def script(count, **opts)
    count.times { @fake.respond(200, body: body(**opts)) }
  end

  def run_eval(cfg = config, **opts)
    TypesafeEval.run(config: cfg, corpus_path: @corpus_path, now: @now, http_class: @fake,
                     sleeper: @sleeper, **opts)
  end

  def run_lines(summary)
    TypesafeEval.read_run(summary[:run_file])
  end

  def corpus
    TypesafeEval.load_corpus(@corpus_path)
  end

  def store_path(cfg = config)
    TypesafeEval.thresholds_path(cfg)
  end

  def apply(lines, cfg = config, **opts)
    TypesafeEval.apply(config: cfg, run_lines: lines, corpus: corpus, now: @now, **opts)
  end

  def assert_apply_refused(lines, cfg = config)
    error = assert_raises(TypesafeEval::Refusal) { apply(lines, cfg) }
    assert_equal "partial_run", error.code
    refute File.exist?(store_path(cfg)), "a partial run must not create thresholds.json"
    error
  end

  def ledger_line(ts, cost: 0.0)
    JSON.generate("ts" => ts.utc.iso8601(3), "month" => ts.utc.strftime("%Y-%m"), "call_id" => "seed",
                  "site" => nil, "model" => MODEL, "outcome" => "ok", "cost_usd" => cost,
                  "cost_estimated" => false, "input_tokens" => 1, "output_tokens" => 0)
  end

  def seed_ledger(lines)
    FileUtils.mkdir_p(@state_dir)
    File.write(File.join(@state_dir, "ledger-2026-09.jsonl"), lines.map { |l| "#{l}\n" }.join)
  end

  # The no-usage bound for one case, from the documented rule.
  def bound_for_case
    body = { "state" => "#{STATE_MARK} 00", "model" => MODEL, "questions" => { "urgency" => QUESTION } }
    JSON.generate(body).bytesize * 0.042 / 1e6
  end

  def rewrite_run(summary)
    lines = File.readlines(summary[:run_file]).map { |l| JSON.parse(l) }
    yield lines
    File.write(summary[:run_file], lines.map { |l| "#{JSON.generate(l)}\n" }.join)
    TypesafeEval.read_run(summary[:run_file])
  end

  # ---- the run -------------------------------------------------------------

  # sabotage: skip a case, or write the state or question text into the run file
  def test_complete_run_records_one_judgment_per_case_and_no_text
    write_corpus(%w[low high low high])
    script(4)
    summary = run_eval
    assert_equal true, summary[:complete]
    assert_nil summary[:stop_reason]
    assert_equal 4, summary[:ok_count]
    assert_equal 4, summary[:sent]
    assert_equal 4, @fake.calls.size
    assert_equal KEY, summary[:threshold_key]
    assert_in_delta 4 * 400 * 0.042 / 1e6, summary[:cost_usd], 1e-9
    lines = run_lines(summary)
    assert_equal %w[run_start judgment judgment judgment judgment run_end], lines.map { |l| l["kind"] }
    assert_equal true, lines.last["complete"]
    assert_equal 4, lines.last["ok_count"]
    assert_equal 4, lines.first["cases"]
    j = lines[1]
    assert_equal %w[case-00 low 0.9 low], [j["case_id"], j["predicted"], j["confidence"].to_s, j["gold"]]
    assert_equal "ok", j["outcome"]
    assert_equal MODEL, j["served_model"]
    text = File.read(summary[:run_file])
    refute_includes text, STATE_MARK
    refute_includes text, QUESTION_TEXT
    assert_equal 0o600, File.stat(summary[:run_file]).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(summary[:run_file])).mode & 0o777
    assert_match(/\A\d{8}T\d{6}Z-[0-9a-f]{4}\z/, summary[:run_id])
    assert_empty TypesafeEval.partial_reasons(lines, corpus: corpus, config: config)
  end

  # sabotage: judge with a site instead of nil, or open a second HTTP path
  def test_cases_are_probe_calls_carrying_the_question_set
    write_corpus(%w[low])
    script(1)
    run_eval
    req = JSON.parse(@fake.calls.first.request.body)
    assert_equal MODEL, req["model"]
    assert_equal({ "urgency" => QUESTION }, req["questions"])
    decision = File.readlines(File.join(@state_dir, "decisions-2026-09.jsonl")).map { |l| JSON.parse(l) }.first
    assert_equal "probe", decision["mode"]
    assert_nil decision["site"]
  end

  # sabotage: send unlabelled cases too
  def test_unlabelled_cases_are_never_sent
    write_corpus(["low", nil, "high", nil])
    script(2)
    summary = run_eval
    assert_equal 2, @fake.calls.size
    assert_equal 2, summary[:cases]
    ids = run_lines(summary).select { |l| l["kind"] == "judgment" }.map { |l| l["case_id"] }
    assert_equal %w[case-00 case-02], ids
    assert_empty TypesafeEval.partial_reasons(run_lines(summary), corpus: corpus, config: config)
  end

  # sabotage: let an empty labelled set run
  def test_nothing_labelled_is_a_refusal_with_no_calls
    write_corpus([nil, nil])
    error = assert_raises(TypesafeEval::Refusal) { run_eval }
    assert_equal "nothing_labelled", error.code
    assert_empty @fake.calls
    refute File.exist?(@state_dir)
  end

  # sabotage: check the source list per call instead of before the run
  def test_restricted_corpus_source_refuses_with_zero_calls_and_no_run_file
    write_corpus(%w[low high])
    error = assert_raises(TypesafeEval::Refusal) { run_eval(config(restricted: ["notes"])) }
    assert_equal "source_restricted", error.code
    assert_empty @fake.calls
    refute File.exist?(File.join(@state_dir, "eval"))
    assert_raises(TypesafeEval::Refusal) { run_eval(config(restricted: ["notes"]), dry_run: true) }
  end

  # sabotage: send from a dry run, or write the run file
  def test_dry_run_sends_and_writes_nothing
    write_corpus(%w[low high low high])
    summary = run_eval(dry_run: true)
    assert_equal true, summary[:dry_run]
    assert_equal 4, summary[:would_call]
    assert_equal "ok", summary[:outcome]
    assert_equal KEY, summary[:threshold_key]
    assert_empty @fake.calls
    refute File.exist?(@state_dir), "a dry run creates no files under the state dir"
  end

  # sabotage: dry run without judging the first case, so a budget refusal is hidden
  def test_dry_run_surfaces_a_budget_refusal
    write_corpus(%w[low high])
    summary = run_eval(config(monthly: 0.0), dry_run: true)
    assert_equal "budget_exhausted", summary[:outcome]
    assert_equal "cap_reached", summary[:reason]
    assert_empty @fake.calls
  end

  # ---- stopping and the partial-run rules ----------------------------------

  # sabotage: keep going after a non-ok outcome, or report complete true
  def test_budget_exhausted_mid_run_stops_and_is_never_applied
    write_corpus(%w[low low low low])
    actual = 400 * 0.042 / 1e6
    seed = 0.001
    # call 2 still fits (seed + actual + bound <= monthly), call 3 does not
    monthly = seed + 1.5 * actual + bound_for_case
    seed_ledger([ledger_line(@time - 3600, cost: seed)])
    script(4)
    cfg = config(monthly: monthly)
    summary = run_eval(cfg)
    assert_equal false, summary[:complete]
    assert_equal "budget_exhausted", summary[:stop_reason]
    assert_equal 2, @fake.calls.size
    lines = run_lines(summary)
    assert_equal false, lines.last["complete"]
    assert_equal "budget_exhausted", lines.last["stop_reason"]
    assert_equal "budget_exhausted", lines[-2]["outcome"]
    reasons = TypesafeEval.partial_reasons(lines, corpus: corpus, config: cfg)
    assert_includes reasons, "stopped_early"
    assert_includes reasons, "case_not_ok"
    assert_apply_refused(lines, cfg)
  end

  # sabotage: retry a timeout, or count it as a judged case
  def test_timeout_stops_the_run_and_is_partial
    write_corpus(%w[low high low])
    script(1)
    @fake.raise_error(Net::ReadTimeout)
    summary = run_eval
    assert_equal "timeout", summary[:stop_reason]
    assert_equal 2, @fake.calls.size
    assert_equal 1, summary[:ok_count]
    lines = run_lines(summary)
    assert_includes TypesafeEval.partial_reasons(lines, corpus: corpus, config: config), "case_not_ok"
    assert_apply_refused(lines)
  end

  # sabotage: accept a served model that differs from the pinned one
  def test_model_mismatch_stops_the_run_and_is_partial
    write_corpus(%w[low high])
    @fake.respond(200, body: body(model: "jev-9.9.9"))
    summary = run_eval
    assert_equal "model_mismatch", summary[:stop_reason]
    lines = run_lines(summary)
    assert_equal "model_mismatch", lines.find { |l| l["kind"] == "judgment" }["outcome"]
    assert_apply_refused(lines)
  end

  # sabotage: treat a missing confidence as 0.0 and carry on
  def test_unreadable_answer_stops_the_run_and_is_partial
    write_corpus(%w[low high])
    @fake.respond(200, body: body(answer: { "type" => "choice", "choice" => "low" }))
    summary = run_eval
    assert_equal "unreadable_answer", summary[:stop_reason]
    assert_equal 1, @fake.calls.size
    lines = run_lines(summary)
    j = lines.find { |l| l["kind"] == "judgment" }
    assert_equal "unreadable_answer", j["outcome"]
    assert_nil j["predicted"]
    assert_includes TypesafeEval.partial_reasons(lines, corpus: corpus, config: config), "case_not_ok"
    assert_apply_refused(lines)
  end

  # sabotage: swallow the Interrupt, or skip the run_end line
  def test_interrupt_closes_the_run_file_and_re_raises
    write_corpus(%w[low high low])
    script(1)
    @fake.raise_error(Interrupt)
    error = assert_raises(TypesafeEval::RunInterrupted) { run_eval }
    summary = error.summary
    assert_equal false, summary[:complete]
    assert_equal "interrupted", summary[:stop_reason]
    lines = run_lines(summary)
    assert_equal "run_end", lines.last["kind"]
    assert_equal "interrupted", lines.last["stop_reason"]
    assert_equal false, lines.last["complete"]
    assert_includes TypesafeEval.partial_reasons(lines, corpus: corpus, config: config), "stopped_early"
    assert_apply_refused(lines)
  end

  # sabotage: let an exception escape without a run_end line
  def test_an_exception_stops_the_run_recorded_by_class_name
    write_corpus(%w[low high low])
    script(3)
    ticks = 0
    @now = lambda do
      ticks += 1
      raise "boom-secret-text" if ticks == 3

      @time
    end
    summary = run_eval
    assert_equal false, summary[:complete]
    assert_equal "RuntimeError", summary[:stop_reason]
    text = File.read(summary[:run_file])
    refute_includes text, "boom-secret-text"
    assert_apply_refused(run_lines(summary))
  end

  # sabotage: write a judgment line for every attempt, or wait a different span
  def test_rate_limited_local_waits_the_window_and_retries
    write_corpus(%w[low high low high])
    seed_ledger([ledger_line(@time), ledger_line(@time)])
    @sleeper = lambda do |s|
      @slept << s
      @time += s
    end
    script(4)
    summary = run_eval(config(per_minute: 2))
    assert_equal true, summary[:complete]
    assert_equal [60, 60], @slept
    assert_equal 4, @fake.calls.size
    assert_equal 4, run_lines(summary).count { |l| l["kind"] == "judgment" }
  end

  # sabotage: retry forever, or retry a non-rate outcome
  def test_rate_limited_local_stops_after_three_waits
    write_corpus(%w[low high])
    seed_ledger([ledger_line(@time), ledger_line(@time)])
    script(2)
    summary = run_eval(config(per_minute: 2))
    assert_equal [60, 60, 60], @slept
    assert_equal "rate_limited_local", summary[:stop_reason]
    assert_equal false, summary[:complete]
    assert_empty @fake.calls
    lines = run_lines(summary)
    judgments = lines.select { |l| l["kind"] == "judgment" }
    assert_equal 1, judgments.size, "only the final attempt writes a judgment line"
    assert_equal "rate_limited_local", judgments.first["outcome"]
    assert_apply_refused(lines)
  end

  # Each single reason on its own, from a complete run edited after the fact.

  def complete_run(golds = %w[low high low high])
    write_corpus(golds)
    script(golds.size)
    run_eval
  end

  # sabotage: treat a missing run_end line as complete
  def test_partial_reason_no_run_end
    lines = rewrite_run(complete_run) { |ls| ls.pop }
    assert_equal ["no_run_end"], TypesafeEval.partial_reasons(lines, corpus: corpus, config: config)
    assert_apply_refused(lines)
  end

  # sabotage: ignore run_end.complete
  def test_partial_reason_stopped_early
    lines = rewrite_run(complete_run) { |ls| ls.last["complete"] = false }
    assert_equal ["stopped_early"], TypesafeEval.partial_reasons(lines, corpus: corpus, config: config)
    assert_apply_refused(lines)
  end

  # sabotage: only check that some judgment exists
  def test_partial_reason_case_missing
    lines = rewrite_run(complete_run) { |ls| ls.delete_at(2) }
    assert_equal ["case_missing"], TypesafeEval.partial_reasons(lines, corpus: corpus, config: config)
    assert_apply_refused(lines)
  end

  # sabotage: accept any judgment outcome
  def test_partial_reason_case_not_ok
    lines = rewrite_run(complete_run) { |ls| ls[1]["outcome"] = "timeout" }
    assert_equal ["case_not_ok"], TypesafeEval.partial_reasons(lines, corpus: corpus, config: config)
    assert_apply_refused(lines)
  end

  # sabotage: skip the digest comparison
  def test_partial_reason_corpus_changed
    summary = complete_run
    changed = corpus
    changed["cases"][0]["label"] = "high"
    TypesafeEval.write_corpus(@corpus_path, changed)
    lines = run_lines(summary)
    assert_equal ["corpus_changed"], TypesafeEval.partial_reasons(lines, corpus: corpus, config: config)
    assert_apply_refused(lines)
  end

  # sabotage: compare the run's key with itself instead of the current one
  def test_partial_reason_key_changed
    lines = run_lines(complete_run)
    moved = config(model: "jev-1.14.0")
    assert_equal ["key_changed"], TypesafeEval.partial_reasons(lines, corpus: corpus, config: moved)
    assert_apply_refused(lines, moved)
  end

  # sabotage: fall back to an empty run when the file is unreadable
  def test_read_run_refuses_a_missing_file_and_skips_a_cut_line
    error = assert_raises(TypesafeEval::Refusal) { TypesafeEval.read_run(File.join(@tmp, "absent.jsonl")) }
    assert_equal "run_unreadable", error.code
    path = File.join(@tmp, "cut.jsonl")
    File.write(path, %({"kind":"run_start"}\n{"kind":"judgm))
    assert_equal [{ "kind" => "run_start" }], TypesafeEval.read_run(path)
  end

  # ---- apply and the store -------------------------------------------------

  # 36 low cases at 0.9 clear the bar (36/39.8416 = 0.9036); 10 high do not.
  def enabled_run
    write_corpus(Array.new(36, "low") + Array.new(10, "high"))
    script(36, choice: "low")
    script(10, choice: "high")
    run_eval
  end

  # sabotage: key the entry by site alone, or store n/a labels as numbers
  def test_apply_writes_one_entry_under_the_threshold_key
    summary = enabled_run
    assert summary[:complete]
    result = apply(run_lines(summary))
    assert_equal KEY, result[:threshold_key]
    assert result[:written]
    store = JSON.parse(File.read(store_path))
    assert_equal 1, store["format"]
    assert_equal [KEY], store["keys"].keys
    entry = store["keys"][KEY]
    assert_equal "review", entry["site"]
    assert_equal summary[:run_id], entry["run_id"]
    assert_equal "2026-09-15T12:00:00.000Z", entry["applied_at"]
    assert_equal 0.05, entry["labels"]["low"]["threshold"]
    assert_equal 36, entry["labels"]["low"]["routed"]
    assert_nil entry["labels"]["high"]["threshold"]
    assert_equal "below_bound", entry["labels"]["high"]["reason"]
    assert_equal 0o600, File.stat(store_path).mode & 0o777
  end

  # sabotage: replace the whole store on apply
  def test_a_second_apply_for_another_key_leaves_the_first_intact
    first = apply(run_lines(enabled_run))
    before = JSON.parse(File.read(store_path))["keys"][KEY]
    @fake = FakeHTTP.new
    @time += 120 # past the first run's per-minute window
    @corpus_path = File.join(@tmp, "other.json")
    write_corpus(Array.new(36, "low") + Array.new(10, "high"), site: "triage", path: @corpus_path)
    script(36, choice: "low")
    script(10, choice: "high")
    apply(run_lines(run_eval))
    keys = JSON.parse(File.read(store_path))["keys"]
    assert_equal [first[:threshold_key], "triage:note-urgency@1:#{MODEL}"], keys.keys
    assert_equal before, keys[KEY]
  end

  # sabotage: write under dry_run
  def test_apply_dry_run_reports_the_entry_and_writes_nothing
    result = apply(run_lines(enabled_run), dry_run: true)
    assert_equal false, result[:written]
    assert_equal 0.05, result[:entry]["labels"]["low"]["threshold"]
    refute File.exist?(store_path)
  end

  # sabotage: return a threshold for an n/a label or another key
  def test_threshold_for_reads_back_only_enabled_labels
    apply(run_lines(enabled_run))
    cfg = config
    assert_equal 0.05, TypesafeEval.threshold_for(config: cfg, threshold_key: KEY, label: "low")
    assert_nil TypesafeEval.threshold_for(config: cfg, threshold_key: KEY, label: "high")
    assert_nil TypesafeEval.threshold_for(config: cfg, threshold_key: KEY, label: "nope")
    assert_nil TypesafeEval.threshold_for(config: cfg, threshold_key: "review:note-urgency@1:jev-9", label: "low")
    assert_nil TypesafeEval.threshold_for(config: config(model: "jev-1.14.0"),
                                          threshold_key: "review:note-urgency@1:jev-1.14.0", label: "low")
  end

  # sabotage: clobber an unreadable store, or let threshold_for raise
  def test_an_invalid_store_is_left_alone_and_reads_as_no_threshold
    lines = run_lines(enabled_run)
    FileUtils.mkdir_p(File.dirname(store_path))
    File.write(store_path, "not json at all")
    error = assert_raises(TypesafeEval::Refusal) { apply(lines) }
    assert_equal "store_invalid", error.code
    assert_equal "not json at all", File.read(store_path)
    assert_nil TypesafeEval.threshold_for(config: config, threshold_key: KEY, label: "low")
  end

  # sabotage: sweep the run's own gold from a changed corpus
  def test_sweep_run_scores_the_recorded_judgments
    labels = TypesafeEval.sweep_run(run_lines(enabled_run), corpus: corpus)
    assert_equal 0.05, labels["low"][:threshold]
    assert_equal 36, labels["low"][:correct]
    assert_nil labels["high"][:threshold]
  end

  # sabotage: open a second HTTP path in the eval code
  def test_eval_code_opens_no_http_connection_of_its_own
    dir = File.expand_path("..", __dir__)
    [File.join(dir, "lib", "typesafe_eval.rb"), File.join(dir, "typesafe_eval.rb")].each do |file|
      refute_match(/Net::HTTP\.(start|new)/, File.read(file), file)
    end
  end
end

# Phase 4: the read-only on-gate. Decision and outcome lines are written into
# the tmp state dir by the tests; no call is ever made (FakeHTTP has no
# scripted step and its call list is asserted empty).
class TypesafeEvalGateTest < Minitest::Test
  include UserConfigHelper

  MODEL = "jev-1.13.0"
  SITE = "review"
  QSET = { "id" => "note-urgency", "version" => 1 }.freeze
  KEY = "review:note-urgency@1:#{MODEL}"
  APPLIED = Time.utc(2026, 9, 1, 0, 0, 0)
  DAY = 86_400

  def setup
    @tmp = Dir.mktmpdir("wurk-eval-gate-")
    @state_dir = File.join(@tmp, "state")
    FileUtils.mkdir_p(@state_dir)
    @fake = FakeHTTP.new
    @seq = 0
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def config(model: nil)
    section = { "key_path" => File.join(@tmp, "absent-key"), "state_dir" => @state_dir,
                "budget" => { "monthly_usd" => 1.0 } }
    section["model"] = model if model
    cfg = UserConfig.new(path: "(fixture)", raw: { "typesafe" => section }, exists: true)
    assert_empty cfg.errors
    cfg
  end

  def write_store(labels: { "low" => { "threshold" => 0.5 }, "high" => { "threshold" => nil } },
                  key: KEY, applied_at: APPLIED)
    entry = { "site" => SITE, "question_set" => QSET, "question" => "urgency", "labels" => labels,
              "run_id" => "r", "corpus_digest" => "d", "applied_at" => applied_at.utc.iso8601(3) }
    dir = File.join(@state_dir, "eval")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "thresholds.json"),
               JSON.generate("format" => 1, "keys" => { key => entry }))
  end

  def append(month, hash)
    File.open(File.join(@state_dir, "decisions-#{month}.jsonl"), "a") { |f| f.puts(JSON.generate(hash)) }
  end

  def month_of(time)
    time.utc.strftime("%Y-%m")
  end

  # One routed shadow decision (unless overridden) plus, when `agreement` is
  # given, its outcome line one minute later.
  def decision(at, agreement: "agree", label: "low", confidence: 0.9, mode: "shadow", site: SITE,
               key: KEY, outcome: "ok", answers: nil)
    @seq += 1
    id = format("call%04d", @seq)
    answers ||= { "urgency" => { "type" => "choice", "choice" => label, "probabilities" => {},
                                 "confidence" => confidence } }
    append(month_of(at), "kind" => "decision", "ts" => at.utc.iso8601(3), "call_id" => id, "site" => site,
                         "mode" => mode, "question_set" => QSET, "threshold_key" => key, "model" => MODEL,
                         "served_model" => MODEL, "outcome" => outcome, "answers" => answers)
    outcome_line(id, at + 60, agreement) if agreement
    id
  end

  def outcome_line(id, at, agreement)
    append(month_of(at), "kind" => "outcome", "ts" => at.utc.iso8601(3), "call_id" => id, "site" => SITE,
                         "action" => "act", "decision" => "d", "agreement" => agreement)
  end

  # `count` accepted decisions from `start`, the first at `start` and the
  # last at `start + span`, agreement as given.
  def spread(count, start, span, **opts)
    count.times do |i|
      decision(start + (count == 1 ? 0 : span * i / (count - 1)), **opts)
    end
  end

  def gate(now, cfg = config)
    TypesafeEval.on_gate(config: cfg, site: SITE, question_set: QSET, now: -> { now })
  end

  def tree
    Dir.glob(File.join(@tmp, "**", "*"), File::FNM_DOTMATCH).sort.map do |path|
      File.file?(path) ? [path, File.read(path), File.mtime(path)] : [path]
    end
  end

  START = APPLIED + DAY

  # ---- no enabled threshold ------------------------------------------------

  # sabotage: allow a site whose store is empty, all n/a, or under another key
  def test_refuses_without_an_enabled_threshold_and_writes_nothing
    all_na = { "low" => { "threshold" => nil, "reason" => "below_bound" },
               "high" => { "threshold" => nil, "reason" => "too_few_routed" } }
    cases = {
      "no store" => -> {},
      "all n/a" => -> { write_store(labels: all_na) },
      "old model key" => -> { write_store(key: "review:note-urgency@1:jev-1.12.0") }
    }
    cases.each do |name, setup|
      setup.call
      spread(40, START, 4 * DAY) # plenty of shadow traffic must not matter
      before = tree
      report = gate(START + 10 * DAY)
      assert_equal false, report[:allowed], name
      assert_equal "no_enabled_threshold", report[:code], name
      assert_equal 0, report[:accepted], name
      assert_equal before, tree, "#{name}: the gate must not write"
      assert_empty @fake.calls
      FileUtils.rm_rf(File.join(@state_dir, "eval"))
    end
  end

  # sabotage: keep the entry after the pinned model moves the key
  def test_a_model_change_moves_the_key_and_the_threshold_no_longer_applies
    write_store
    spread(40, START, 4 * DAY)
    assert gate(START + 5 * DAY)[:allowed]
    report = gate(START + 5 * DAY, config(model: "jev-1.14.0"))
    assert_equal "no_enabled_threshold", report[:code]
    assert_equal "review:note-urgency@1:jev-1.14.0", report[:threshold_key]
  end

  # sabotage: read a store that is not format 1, or raise on it
  def test_an_unreadable_store_is_no_enabled_threshold
    FileUtils.mkdir_p(File.join(@state_dir, "eval"))
    File.write(File.join(@state_dir, "eval", "thresholds.json"), "garbage")
    assert_equal "no_enabled_threshold", gate(START)[:code]
    assert_equal "garbage", File.read(File.join(@state_dir, "eval", "thresholds.json"))
  end

  # ---- evidence counting ---------------------------------------------------

  # sabotage: treat 3 days minus a second as enough, or 34 as 35
  def test_35_accepted_over_three_days_plus_a_second_is_allowed
    write_store
    spread(35, START, 3 * DAY + 1)
    report = gate(START + 3 * DAY + 1)
    assert report[:allowed], report.inspect
    assert_nil report[:code]
    assert_equal 35, report[:accepted]
    assert_equal 0, report[:disagreed]
    assert_equal 3 * DAY + 1, report[:span_s]
    assert_equal START.iso8601(3), report[:first_routed_at]
    assert_equal %w[low], report[:enabled_labels]
    assert_empty report[:shortfall]
  end

  # sabotage: count 34, or compare the span with > instead of >=
  def test_34_accepted_is_short_and_so_is_a_span_a_second_under_three_days
    write_store
    spread(34, START, 4 * DAY)
    report = gate(START + 4 * DAY)
    assert_equal "shadow_evidence_short", report[:code]
    assert_equal %w[accepted agreement_bound], report[:shortfall] # 34/34 -> 0.898482 < 0.90
    FileUtils.rm(Dir.glob(File.join(@state_dir, "decisions-*")))
    spread(35, START, 4 * DAY)
    exactly = gate(START + 3 * DAY)
    assert exactly[:allowed]
    short = gate(START + 3 * DAY - 1)
    assert_equal "shadow_evidence_short", short[:code]
    assert_equal %w[days], short[:shortfall]
  end

  # sabotage: count a line the bound should exclude; each variant carries an
  # agree outcome, so a leak raises `accepted` above the 35 baseline
  def test_lines_that_must_not_count
    write_store
    spread(35, START, 4 * DAY)
    at = START + 2 * DAY
    decision(at, mode: "on")
    decision(at, mode: "probe")
    decision(at, site: "other")
    decision(at, key: "review:note-urgency@2:#{MODEL}")
    decision(at, outcome: "model_mismatch")
    decision(APPLIED - 60) # before applied_at
    decision(at, confidence: 0.49) # below the stored 0.5
    decision(at, label: "high") # a non-enabled label
    decision(at, answers: { "other" => { "type" => "choice", "choice" => "low", "confidence" => 0.9 } })
    decision(at, agreement: nil) # no outcome line at all
    decision(at, agreement: "n/a")
    report = gate(START + 5 * DAY)
    assert_equal 35, report[:accepted]
    assert_equal 0, report[:disagreed]
    assert report[:allowed]
  end

  # sabotage: use the first outcome line, or the earliest agreement
  def test_the_latest_outcome_line_decides
    write_store
    spread(35, START, 4 * DAY)
    id = decision(START + DAY, agreement: "agree")
    outcome_line(id, START + DAY + 3600, "disagree")
    report = gate(START + 5 * DAY)
    assert_equal 35, report[:accepted]
    assert_equal 1, report[:disagreed]
    other = decision(START + DAY, agreement: "disagree")
    outcome_line(other, START + DAY + 3600, "agree")
    report = gate(START + 5 * DAY)
    assert_equal 36, report[:accepted]
    assert_equal 1, report[:disagreed]
  end

  # sabotage: read only the current month's decisions file
  def test_decision_lines_spread_over_two_monthly_files_are_both_read
    applied = Time.utc(2026, 9, 25)
    write_store(applied_at: applied)
    start = Time.utc(2026, 9, 28)
    spread(35, start, 7 * DAY) # ends Oct 5
    assert_equal %w[decisions-2026-09.jsonl decisions-2026-10.jsonl],
                 Dir.children(@state_dir).select { |f| f.start_with?("decisions") }.sort
    report = gate(Time.utc(2026, 10, 6))
    assert report[:allowed], report.inspect
    assert_equal 35, report[:accepted]
  end

  # sabotage: start the span at applied_at instead of the first routed decision
  def test_the_span_starts_at_the_first_routed_shadow_decision
    write_store
    decision(APPLIED + 60, mode: "on") # not shadow: must not start the span
    spread(35, START + 5 * DAY, 2 * DAY)
    report = gate(START + 6 * DAY)
    assert_equal (START + 5 * DAY).iso8601(3), report[:first_routed_at]
    assert_equal DAY, report[:span_s]
    assert_includes report[:shortfall], "days"
  end

  # sabotage: skip the malformed-line count, or crash on a torn line
  def test_malformed_lines_are_skipped_and_counted
    write_store
    spread(35, START, 4 * DAY)
    File.open(File.join(@state_dir, "decisions-2026-09.jsonl"), "a") do |f|
      f.puts("{torn")
      f.puts("[1]")
      f.puts("")
    end
    report = gate(START + 5 * DAY)
    assert report[:allowed]
    assert_equal 2, report[:malformed]
  end

  # ---- disagreements count against the bound -------------------------------

  # Wilson lower bounds, z = 1.96 (z^2 = 3.8416), agree / (agree + disagree):
  #   35/36: p = 0.972222; z^2/2n = 0.053356; p(1-p)/n = 0.000750;
  #     z^2/4n^2 = 0.000741; sqrt(0.001491) = 0.038614; * 1.96 = 0.075683;
  #     numerator 0.972222 + 0.053356 - 0.075683 = 0.949895;
  #     denominator 1 + 0.106711 = 1.106711; lb = 0.858300
  #   51/52: lb = 0.898793      52/53: lb = 0.900569      35/35: 35/38.8416 = 0.901096
  # sabotage: ignore disagreements, or count them as advisory only
  def test_disagreements_count_against_the_wilson_bound
    [[35, 1, false, 0.858300], [51, 1, false, 0.898793], [52, 1, true, 0.900569],
     [35, 0, true, 0.901096]].each do |agree, disagree, allowed, bound|
      FileUtils.rm(Dir.glob(File.join(@state_dir, "decisions-*")))
      write_store
      spread(agree, START, 4 * DAY)
      spread(disagree, START + DAY, 2 * DAY, agreement: "disagree")
      report = gate(START + 5 * DAY)
      label = "#{agree} agree + #{disagree} disagree"
      assert_equal allowed, report[:allowed], label
      assert_equal agree, report[:accepted], label
      assert_equal disagree, report[:disagreed], label
      assert_in_delta bound, report[:lower_bound], 1e-6, label
      assert_equal(allowed ? [] : %w[agreement_bound], report[:shortfall], label)
    end
  end
end

# Phase 4: the fixture runner and the model-change trigger. FakeHTTP is the
# only transport.
class TypesafeEvalFixturesTest < Minitest::Test
  include UserConfigHelper

  MODEL = "jev-1.13.0"
  NEW_MODEL = "jev-1.14.0"
  SET_KEY = "review:note-urgency@1"
  QUESTION = { "type" => "choice", "instructions" => "Decide how urgent the note is for its reader.",
               "criteria" => { "low" => "Nothing waits.", "high" => "Someone is blocked." } }.freeze
  SENTINEL_KEY = "sentinel-evalfix-#{SecureRandom.hex(12)}"
  STATE_MARK = "fixmark-#{SecureRandom.hex(6)}"

  def setup
    @tmp = Dir.mktmpdir("wurk-eval-fix-")
    @state_dir = File.join(@tmp, "state")
    @key_path = File.join(@tmp, "key")
    File.write(@key_path, "#{SENTINEL_KEY}\n")
    File.chmod(0o600, @key_path)
    @fake = FakeHTTP.new
    @time = Time.utc(2026, 9, 15, 12, 0, 0)
    @now = -> { @time }
    @sleeper = ->(_s) {}
    @path = File.join(@tmp, "fixtures.json")
  end

  def teardown
    Dir.glob(File.join(@tmp, "**", "*"), File::FNM_DOTMATCH).each do |path|
      next unless File.file?(path)
      next if path == @key_path

      refute_includes File.read(path), SENTINEL_KEY, "sentinel key found in #{path}"
    end
  ensure
    FileUtils.remove_entry(@tmp)
  end

  def config(model: nil, restricted: [])
    section = { "key_path" => @key_path, "state_dir" => @state_dir, "budget" => { "monthly_usd" => 1.0 },
                "restricted_sources" => restricted }
    section["model"] = model if model
    raw = { "typesafe" => section,
            "metrics" => { "prices" => { (model || MODEL) => { "input" => 0.042, "output" => 0 } } } }
    cfg = UserConfig.new(path: "(fixture)", raw: raw, exists: true)
    assert_empty cfg.errors
    cfg
  end

  def write_fixtures(path = @path, expects: [["a", "low"], ["b", "high"], ["c", "low"]], extra: {})
    fixtures = expects.map do |id, label|
      { "id" => id, "state" => "#{STATE_MARK} #{id}", "source" => "synthetic", "expect" => { "label" => label } }
    end
    doc = { "site" => "review", "question_set" => { "id" => "note-urgency", "version" => 1 },
            "question" => "urgency", "questions" => { "urgency" => QUESTION }, "fixtures" => fixtures }
    File.write(path, JSON.generate(doc.merge(extra)))
  end

  def body(choice, confidence: 0.9, model: MODEL)
    JSON.generate("model" => model,
                  "answers" => { "urgency" => { "type" => "choice", "choice" => choice, "confidence" => confidence } },
                  "usage" => { "input_tokens" => 400, "output_tokens" => 0 })
  end

  def script(*choices, model: MODEL)
    choices.each { |c| @fake.respond(200, body: body(c, model: model)) }
  end

  def run_set(cfg = config, **opts)
    TypesafeEval.run_fixtures(config: cfg, fixtures_path: @path, now: @now, http_class: @fake,
                              sleeper: @sleeper, **opts)
  end

  def check(cfg = config, paths: [@path], **opts)
    TypesafeEval.check_fixtures(config: cfg, fixtures_paths: paths, now: @now, http_class: @fake,
                                sleeper: @sleeper, **opts)
  end

  def state
    JSON.parse(File.read(File.join(@state_dir, "eval", "fixtures-state.json")))
  end

  def fresh_fake
    @fake = FakeHTTP.new
  end

  # ---- run -----------------------------------------------------------------

  # sabotage: skip a fixture, or write state text into the results
  def test_all_pass_records_the_run_and_never_the_state_text
    write_fixtures
    script("low", "high", "low")
    result = run_set
    assert_equal true, result[:passed]
    assert_empty result[:failed_ids]
    assert_equal 3, @fake.calls.size
    assert_equal 3, result[:sent]
    assert_equal %w[a b c], result[:results].map { |r| r[:id] }
    assert_equal "low", result[:results][0][:predicted]
    recorded = state["sets"][SET_KEY]
    assert_equal MODEL, recorded["model"]
    assert_equal MODEL, recorded["served_model"]
    assert_equal true, recorded["passed"]
    assert_equal "2026-09-15T12:00:00.000Z", recorded["ran_at"]
    refute_includes File.read(File.join(@state_dir, "eval", "fixtures-state.json")), STATE_MARK
    refute_includes result.inspect, STATE_MARK
  end

  # sabotage: stop at the first failure, or pass on a wrong label
  def test_a_wrong_label_fails_that_fixture_and_still_records_the_run
    write_fixtures
    script("low", "low", "low")
    result = run_set
    assert_equal false, result[:passed]
    assert_equal %w[b], result[:failed_ids]
    assert_equal 3, @fake.calls.size
    assert_equal %w[b], state["sets"][SET_KEY]["failed_ids"]
    assert_equal false, state["sets"][SET_KEY]["passed"]
  end

  # sabotage: ignore min_confidence
  def test_min_confidence_is_enforced
    write_fixtures(expects: [["a", "low"]])
    doc = JSON.parse(File.read(@path))
    doc["fixtures"][0]["expect"]["min_confidence"] = 0.95
    File.write(@path, JSON.generate(doc))
    script("low")
    assert_equal %w[a], run_set[:failed_ids]
  end

  # sabotage: treat a non-ok outcome as a pass
  def test_a_timeout_fails_the_fixture
    write_fixtures(expects: [["a", "low"], ["b", "high"]])
    @fake.raise_error(Net::ReadTimeout)
    script("high")
    result = run_set
    assert_equal %w[a], result[:failed_ids]
    assert_equal "timeout", result[:results][0][:outcome]
    assert_nil result[:results][0][:predicted]
  end

  # sabotage: check restricted sources per call
  def test_a_restricted_source_refuses_the_whole_set_with_zero_calls
    write_fixtures
    error = assert_raises(TypesafeEval::Refusal) { run_set(config(restricted: ["synthetic"])) }
    assert_equal "source_restricted", error.code
    assert_empty @fake.calls
    refute File.exist?(@state_dir)
  end

  # sabotage: accept a label the question does not have, or a duplicate id
  def test_invalid_fixture_sets_are_refused_by_field
    write_fixtures(expects: [["a", "medium"]])
    assert_equal "fixtures_invalid", assert_raises(TypesafeEval::Refusal) { run_set }.code
    write_fixtures(expects: [["a", "low"], ["a", "low"]])
    error = assert_raises(TypesafeEval::Refusal) { run_set }
    assert_equal "fixtures_invalid", error.code
    refute_includes error.message, STATE_MARK
    File.write(@path, "not json")
    assert_equal "fixtures_invalid", assert_raises(TypesafeEval::Refusal) { run_set }.code
    write_fixtures(extra: { "site" => "Bad Site" })
    assert_equal "fixtures_invalid", assert_raises(TypesafeEval::Refusal) { run_set }.code
    assert_empty @fake.calls
  end

  # sabotage: send or write under dry_run
  def test_dry_run_sends_and_writes_nothing
    write_fixtures
    result = run_set(dry_run: true)
    assert_equal 3, result[:would_call]
    assert_empty @fake.calls
    refute File.exist?(@state_dir)
  end

  # ---- the model-change trigger --------------------------------------------

  # sabotage: stamp ran_at before the calls, so the run re-triggers itself
  def test_a_finished_run_does_not_retrigger_itself
    write_fixtures
    script("low", "high", "low")
    run_set
    assert_equal [false, nil], TypesafeEval.model_changed?(config: config, set_key: SET_KEY)
  end

  # sabotage: run every set on every check, or none
  def test_check_runs_a_set_only_when_the_model_changed
    write_fixtures
    script("low", "high", "low")
    run_set
    fresh_fake
    sets = check
    assert_equal 0, @fake.calls.size
    assert_equal false, sets[0][:triggered]
    assert_nil sets[0][:reason]
    assert_nil sets[0][:run]

    script("low", "high", "low", model: NEW_MODEL)
    sets = check(config(model: NEW_MODEL))
    assert_equal 3, @fake.calls.size
    assert_equal true, sets[0][:triggered]
    assert_equal "pinned_model_changed", sets[0][:reason]
    assert_equal true, sets[0][:run][:passed]
    assert_equal NEW_MODEL, state["sets"][SET_KEY]["model"]
    fresh_fake
    check(config(model: NEW_MODEL))
    assert_equal 0, @fake.calls.size
  end

  # sabotage: ignore the served model in later decision lines
  def test_a_later_served_model_change_triggers
    write_fixtures
    script("low", "high", "low")
    run_set
    FileUtils.mkdir_p(@state_dir)
    line = { "kind" => "decision", "ts" => (@time + 3600).iso8601(3), "call_id" => "x", "site" => "other",
             "mode" => "shadow", "model" => MODEL, "served_model" => NEW_MODEL, "outcome" => "model_mismatch" }
    File.write(File.join(@state_dir, "decisions-2026-09.jsonl"), "#{JSON.generate(line)}\n")
    assert_equal [true, "served_model_changed"], TypesafeEval.model_changed?(config: config, set_key: SET_KEY)
    fresh_fake
    script("low", "high", "low")
    sets = check
    assert_equal 3, @fake.calls.size
    assert_equal "served_model_changed", sets[0][:reason]
  end

  # sabotage: count decision lines from before the recorded run
  def test_decision_lines_before_the_recorded_run_do_not_trigger
    write_fixtures
    script("low", "high", "low")
    run_set
    line = { "kind" => "decision", "ts" => (@time - 3600).iso8601(3), "call_id" => "x", "site" => nil,
             "mode" => "probe", "model" => MODEL, "served_model" => NEW_MODEL, "outcome" => "ok" }
    File.open(File.join(@state_dir, "decisions-2026-09.jsonl"), "a") { |f| f.puts(JSON.generate(line)) }
    assert_equal [false, nil], TypesafeEval.model_changed?(config: config, set_key: SET_KEY)
  end

  # sabotage: treat a missing state file as unchanged
  def test_no_state_file_is_no_baseline_and_triggers
    write_fixtures
    assert_equal [true, "no_baseline"], TypesafeEval.model_changed?(config: config, set_key: SET_KEY)
    script("low", "high", "low")
    sets = check
    assert_equal 3, @fake.calls.size
    assert_equal "no_baseline", sets[0][:reason]
  end

  # sabotage: validate lazily, after the first set already spent calls
  def test_check_validates_every_set_before_the_first_call
    write_fixtures
    other = File.join(@tmp, "other.json")
    File.write(other, "not json")
    assert_raises(TypesafeEval::Refusal) { check(paths: [@path, other]) }
    assert_empty @fake.calls
    refute File.exist?(@state_dir)
  end

  # sabotage: send under dry_run
  def test_check_dry_run_reports_and_sends_nothing
    write_fixtures
    sets = check(dry_run: true)
    assert_equal "no_baseline", sets[0][:reason]
    assert_equal 3, sets[0][:run][:would_call]
    assert_empty @fake.calls
    refute File.exist?(@state_dir)
  end

  # sabotage: retry a non-rate outcome, or never wait
  def test_rate_limited_local_waits_and_retries_a_fixture
    write_fixtures(expects: [["a", "low"]])
    slept = []
    sleeper = lambda do |s|
      slept << s
      @time += s
    end
    FileUtils.mkdir_p(@state_dir)
    seed = 60.times.map do
      JSON.generate("ts" => @time.utc.iso8601(3), "month" => "2026-09", "call_id" => "seed", "site" => nil,
                    "model" => MODEL, "outcome" => "ok", "cost_usd" => 0.0, "cost_estimated" => false)
    end
    File.write(File.join(@state_dir, "ledger-2026-09.jsonl"), seed.map { |l| "#{l}\n" }.join)
    script("low")
    result = run_set(sleeper: sleeper)
    assert_equal [60], slept
    assert_equal true, result[:passed]
  end
end

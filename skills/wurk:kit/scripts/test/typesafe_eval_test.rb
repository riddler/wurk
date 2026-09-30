# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "securerandom"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../lib/typesafe_eval"
require_relative "support/user_config_helper"

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

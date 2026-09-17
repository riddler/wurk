# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "support/home_guard"
require_relative "../critic_eval"

# The pure scoring functions, over synthetic outputs rather than the fixture
# corpus, so a rule can be exercised on the one line that expresses it.
class CriticEvalLibTest < Minitest::Test
  def test_findings_reads_a_severity_anywhere_on_the_line
    text = <<~OUT
      1. lib/a.rb:4 - must-fix
      2. lib/a.rb:9 - should-fix
      3. **note** lib/a.rb:11
    OUT

    severities = CriticEval.findings(text).map { |f| f[:severity] }

    assert_equal %w[must-fix should-fix note], severities
  end

  # The vocabulary legend an agent prints in its own header is not three
  # findings. The one-severity-per-line rule is what tells them apart.
  # sabotage: drop the `hits.length == 1` guard -> this goes red
  def test_findings_skips_a_line_naming_more_than_one_severity
    text = "Severity vocabulary: must-fix / should-fix / note.\n"

    assert_empty CriticEval.findings(text)
  end

  def test_findings_does_not_match_a_longer_word
    assert_empty CriticEval.findings("this is a must-fixable nit\n")
  end

  def test_findings_is_case_insensitive
    assert_equal 1, CriticEval.findings("MUST-FIX: lib/a.rb:4\n").length
  end

  # The rank and the explanation are on different lines in every real
  # agent output; matching a corpus's expected substring against the rank
  # line alone would score every such case a miss.
  # sabotage: set :body to the severity line alone -> this goes red
  def test_a_findings_body_runs_to_the_next_finding
    text = <<~OUT
      1. lib/a.rb:4 - must-fix
         The rescue swallows the error path.
      2. lib/a.rb:9 - note
         A smaller nit.
    OUT

    bodies = CriticEval.findings(text).map { |f| f[:body] }

    assert_includes bodies.first, "error path"
    refute_includes bodies.first, "smaller nit"
  end

  # The first real trust-bar run (2026-09-17) scored every clean output a
  # false positive: the mandated summary line names exactly one severity,
  # so it satisfied the one-severity-per-line rule and counted as a
  # blocking finding even while reporting zero of them.
  # sabotage: drop the verdict_summary? guard -> this goes red
  def test_the_mandated_verdict_summary_line_is_not_a_finding
    assert_empty CriticEval.findings("**Verdict**: 2 findings (0 must-fix)\n")
    assert_empty CriticEval.findings("Verdict: 3 findings (1 must-fix)\n")
  end

  # The exemption is the summary line's shape, not the word "Verdict". A
  # count reports how many findings carry a rank; anything else on that
  # line is asserting one, and an over-broad exemption would hide it.
  # sabotage: exempt any Verdict-labeled line -> this goes red
  def test_a_verdict_line_that_asserts_a_rank_is_still_a_finding
    findings = CriticEval.findings("**Verdict**: must-fix - the rescue swallows the error path\n")

    assert_equal ["must-fix"], findings.map { |f| f[:severity] }
  end

  def test_a_verdict_label_elsewhere_in_a_line_is_not_exempt
    assert_equal 1, CriticEval.findings("The bead's verdict: 1 must-fix below\n").length
  end

  # Same run, second artifact: a finding whose body quotes the code it is
  # about was cut off at the first `#` comment inside the fence, before the
  # sentence that named the defect.
  # sabotage: stop treating fenced lines as opaque in body_end -> red
  def test_a_comment_inside_a_fenced_block_does_not_end_a_findings_body
    text = <<~OUT
      1. lib/a.rb:4 - must-fix
         Both of these still read the old name:

      ```ruby
      # line 40, the drain loop
      reader.pending.each { |row| row }
      ```

      Neither of those callers was updated.

      ## Checks that passed
    OUT

    body = CriticEval.findings(text).first[:body]

    assert_includes body, "callers"
    refute_includes body, "Checks that passed"
  end

  # sabotage: drop the fenced check in the starts scan -> this goes red
  def test_a_severity_named_inside_a_fenced_block_is_not_a_finding
    text = "1. lib/a.rb:4 - must-fix\n   Quoting the old output:\n\n```\nSeverity: should-fix\n```\n"

    assert_equal ["must-fix"], CriticEval.findings(text).map { |f| f[:severity] }
  end

  # A fence closes on its own marker, so a ``` quoted inside a ~~~ block
  # does not reopen the document to headings partway through a body.
  def test_a_fence_closes_only_on_its_own_marker
    text = "1. lib/a.rb:4 - must-fix\n   Quoting:\n\n~~~\n```\n# not a heading\n~~~\n\nthe callers are stale.\n"

    assert_includes CriticEval.findings(text).first[:body], "callers"
  end

  def test_a_findings_body_stops_at_the_next_heading
    text = "1. lib/a.rb:4 - must-fix\n   The rescue swallows it.\n\n## Checks that passed\n\n- nothing else\n"

    body = CriticEval.findings(text).first[:body]

    refute_includes body, "Checks that passed"
  end

  def test_blocking_keeps_only_the_blocking_rank
    findings = CriticEval.findings("a must-fix\na note\na should-fix\n")

    assert_equal ["must-fix"], CriticEval.blocking(findings, "must-fix").map { |f| f[:severity] }
  end

  def test_a_bad_case_with_a_matching_blocking_finding_is_a_hit
    scored = score("bad", { "contains" => "error path" }, "1. lib/a.rb:4 - must-fix swallows the error path\n")

    assert_equal "hit", scored[:outcome]
  end

  # An agent that found the file but not the defect is a miss, not a hit:
  # the substring is the whole difference between measuring a critic and
  # measuring its willingness to rank things.
  # sabotage: let `matched` fall back to blocking_findings when the
  # substring misses -> this goes red
  def test_a_bad_case_whose_blocking_finding_misses_the_substring_is_a_miss
    scored = score("bad", { "contains" => "error path" }, "1. lib/a.rb:4 - must-fix the name reads tersely\n")

    assert_equal "miss", scored[:outcome]
  end

  def test_a_bad_case_ranked_only_note_is_a_miss
    scored = score("bad", { "contains" => "rename" }, "1. lib/a.rb:6 - note an unasked rename\n")

    assert_equal "miss", scored[:outcome]
  end

  def test_a_good_case_with_a_blocking_finding_is_a_false_positive
    scored = score("good", nil, "1. lib/a.rb:8 - must-fix no test for this\n")

    assert_equal "false_positive", scored[:outcome]
  end

  def test_a_good_case_with_only_notes_is_a_true_negative
    scored = score("good", nil, "1. lib/a.rb:1 - note a stale comment\n")

    assert_equal "true_negative", scored[:outcome]
  end

  def test_metrics_over_one_of_each_outcome
    counts = { hit: 1, miss: 1, false_positive: 1, true_negative: 1 }

    assert_equal({ precision: 0.5, recall: 0.5 }, CriticEval.metrics(counts))
  end

  # An unmeasurable ratio is nil, never 1.0: a corpus that produced no
  # blocking finding at all has not shown a precision of one.
  # sabotage: return 1.0 instead of nil for a zero denominator -> red
  def test_metrics_are_nil_when_a_denominator_is_zero
    metrics = CriticEval.metrics(hit: 0, miss: 0, false_positive: 0, true_negative: 3)

    assert_nil metrics[:precision]
    assert_nil metrics[:recall]
  end

  def test_meets_bar_is_false_when_a_ratio_is_unmeasurable
    refute CriticEval.meets_bar?({ precision: nil, recall: 1.0 }, 0.8)
  end

  def test_meets_bar_at_exactly_the_bar
    assert CriticEval.meets_bar?({ precision: 0.8, recall: 0.8 }, 0.8)
    refute CriticEval.meets_bar?({ precision: 0.8, recall: 0.79 }, 0.8)
  end

  def test_case_severity_prefers_the_case_over_the_run
    assert_equal "should-fix", CriticEval.case_severity({ "expect" => { "severity" => "should-fix" } }, "must-fix")
    assert_equal "must-fix", CriticEval.case_severity({}, "must-fix")
  end

  def test_for_agent_treats_an_unnamed_case_as_everyones
    assert CriticEval.for_agent?({}, "wurk-diff-critic")
    assert CriticEval.for_agent?({ "agent" => "wurk-diff-critic" }, "wurk-diff-critic")
    refute CriticEval.for_agent?({ "agent" => "wurk-test-critic" }, "wurk-diff-critic")
  end

  private

  def score(label, expect, output)
    meta = { "label" => label }
    meta["expect"] = expect if expect
    CriticEval.score_case(
      id: "case",
      meta: meta,
      findings: CriticEval.findings(output),
      severity: "must-fix"
    )
  end
end

# The CLI over the shipped fixture corpus: one hit, one miss, one false
# positive, one true negative.
class CriticEvalCliTest < Minitest::Test
  FIXTURES = File.expand_path(File.join(__dir__, "fixtures", "critic_eval"))
  CORPUS = File.join(FIXTURES, "corpus")
  OUTPUTS = File.join(FIXTURES, "outputs")
  INCIDENT_CORPUS = File.join(FIXTURES, "incidents", "corpus")
  INCIDENT_OUTPUTS = File.join(FIXTURES, "incidents", "outputs")

  def run_cli(argv)
    io = StringIO.new
    code = CriticEvalCli.run(argv, io)
    [code, JSON.parse(io.string)]
  end

  def test_scores_the_shipped_corpus
    _code, env = run_cli(["--corpus", CORPUS, "--outputs", OUTPUTS])

    assert env["ok"]
    assert_equal({ "hit" => 1, "miss" => 1, "false_positive" => 1, "true_negative" => 1 }, env["data"]["counts"])
    assert_in_delta 0.5, env["data"]["precision"]
    assert_in_delta 0.5, env["data"]["recall"]
    refute env["data"]["meets_bar"]
  end

  def test_each_fixture_case_lands_on_its_labeled_outcome
    _code, env = run_cli(["--corpus", CORPUS, "--outputs", OUTPUTS])

    outcomes = env["data"]["cases"].map { |c| [c["id"], c["outcome"]] }.to_h

    assert_equal "true_negative", outcomes.fetch("comment-only")
    assert_equal "false_positive", outcomes.fetch("scoped-refactor")
    assert_equal "hit", outcomes.fetch("swallowed-error")
    assert_equal "miss", outcomes.fetch("unasked-rename")
  end

  # A run under the bar is still a successful run - the script reports the
  # number and warns; promoting or demoting an agent is the reader's call.
  def test_a_below_bar_run_warns_and_still_exits_zero
    code, env = run_cli(["--corpus", CORPUS, "--outputs", OUTPUTS])

    assert_equal 0, code
    assert_includes env["warnings"].map { |w| w["code"] }, "below_trust_bar"
  end

  # The two cases the first real trust-bar run (2026-09-17) exposed, saved
  # in the mandated output format: a clean review whose only severity count
  # is the Verdict line, and a must-fix whose body quotes code with `#`
  # comments in it. Both scored wrong before the parser rules landed - this
  # corpus reads 0.0 / 0.0 under the old parser and 1.0 / 1.0 under the new
  # one, which is the whole regression.
  def test_the_incident_corpus_scores_clean
    _code, env = run_cli(["--corpus", INCIDENT_CORPUS, "--outputs", INCIDENT_OUTPUTS])

    assert env["ok"]
    assert_equal({ "hit" => 1, "miss" => 0, "false_positive" => 0, "true_negative" => 1 },
                 env["data"]["counts"])
    assert_in_delta 1.0, env["data"]["precision"]
    assert_in_delta 1.0, env["data"]["recall"]
  end

  def test_a_saved_output_whose_only_severity_is_the_verdict_line_blocks_nothing
    _code, env = run_cli(["--corpus", INCIDENT_CORPUS, "--outputs", INCIDENT_OUTPUTS])

    scored = env["data"]["cases"].find { |c| c["id"] == "verdict-summary-only" }

    assert_equal "true_negative", scored["outcome"]
    assert_equal 0, scored["blocking_count"]
    assert_equal 2, scored["findings_count"]
  end

  def test_a_finding_body_carrying_a_fenced_block_is_read_to_its_real_end
    _code, env = run_cli(["--corpus", INCIDENT_CORPUS, "--outputs", INCIDENT_OUTPUTS])

    scored = env["data"]["cases"].find { |c| c["id"] == "fenced-code-body" }

    assert_equal "hit", scored["outcome"]
    assert_equal 1, scored["findings_count"]
  end

  def test_agent_filter_keeps_only_that_agents_cases
    _code, env = run_cli(["--corpus", CORPUS, "--outputs", OUTPUTS, "--agent", "wurk-test-critic"])

    assert_empty env["data"]["cases"]
    assert_includes env["warnings"].map { |w| w["code"] }, "empty_corpus"
  end

  def test_a_bar_the_corpus_clears
    _code, env = run_cli(["--corpus", CORPUS, "--outputs", OUTPUTS, "--bar", "0.5"])

    assert env["data"]["meets_bar"]
    refute_includes env["warnings"].map { |w| w["code"] }, "below_trust_bar"
  end

  def test_a_missing_saved_output_blocks
    Dir.mktmpdir do |dir|
      code, env = run_cli(["--corpus", CORPUS, "--outputs", dir])

      assert_equal 1, code
      refute env["ok"]
      assert_includes env["blocked"].map { |b| b["code"] }, "missing_output"
    end
  end

  def test_an_output_with_no_case_warns
    Dir.mktmpdir do |dir|
      Dir.children(OUTPUTS).each { |f| FileUtils.cp(File.join(OUTPUTS, f), File.join(dir, f)) }
      File.write(File.join(dir, "gone.md"), "1. lib/a.rb:1 - note\n")

      _code, env = run_cli(["--corpus", CORPUS, "--outputs", dir])

      warning = env["warnings"].find { |w| w["code"] == "unmatched_output" }
      refute_nil warning
      assert_includes warning["message"], "gone.md"
    end
  end

  def test_a_bad_label_blocks
    with_corpus_copy do |dir|
      File.write(File.join(dir, "comment-only", "meta.json"), JSON.dump("label" => "maybe"))

      code, env = run_cli(["--corpus", dir, "--outputs", OUTPUTS])

      assert_equal 1, code
      assert_includes env["blocked"].map { |b| b["code"] }, "bad_label"
    end
  end

  def test_unparseable_meta_blocks
    with_corpus_copy do |dir|
      File.write(File.join(dir, "comment-only", "meta.json"), "{not json")

      _code, env = run_cli(["--corpus", dir, "--outputs", OUTPUTS])

      assert_includes env["blocked"].map { |b| b["code"] }, "bad_meta"
    end
  end

  def test_a_missing_directory_blocks_before_any_scoring
    code, env = run_cli(["--corpus", "/nonexistent/corpus", "--outputs", OUTPUTS])

    assert_equal 1, code
    assert_includes env["blocked"].map { |b| b["code"] }, "corpus_not_found"
    assert_empty env["data"]
  end

  def test_the_flags_are_required
    _code, env = run_cli([])

    codes = env["blocked"].map { |b| b["code"] }
    assert_includes codes, "missing_corpus"
    assert_includes codes, "missing_outputs"
  end

  private

  def with_corpus_copy
    Dir.mktmpdir do |dir|
      Dir.children(CORPUS).each { |name| FileUtils.cp_r(File.join(CORPUS, name), File.join(dir, name)) }
      yield dir
    end
  end
end

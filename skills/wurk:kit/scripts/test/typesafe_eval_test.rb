# frozen_string_literal: true

require "minitest/autorun"
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

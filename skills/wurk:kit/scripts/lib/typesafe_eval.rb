# frozen_string_literal: true

# Jev eval library: the pure math a call site must pass before it may move
# from shadow to on. This file holds the Wilson bound, answer
# interpretation, the label lists and the threshold sweep. No IO, no config,
# no network; later phases add the corpus, the run and the gate here.
module TypesafeEval
  Z = 1.96
  MIN_ROUTED = 10
  MIN_LOWER_BOUND = 0.90
  # 0.05..0.95 in steps of 0.05, from integers so there is no float drift.
  THRESHOLDS = (1..19).map { |i| i / 20.0 }.freeze

  # Wilson score lower bound for `correct` of `routed`. nil when nothing was
  # routed: no denominator is never a pass.
  def self.wilson_lower_bound(correct, routed, z: Z)
    unless correct.is_a?(Integer) && routed.is_a?(Integer) &&
           correct >= 0 && routed >= 0 && correct <= routed
      raise ArgumentError, "correct and routed must be integers with " \
                           "0 <= correct <= routed"
    end
    return nil if routed.zero?

    n = routed.to_f
    p = correct / n
    z2 = z * z
    centre = p + z2 / (2 * n)
    margin = z * Math.sqrt(p * (1 - p) / n + z2 / (4 * n * n))
    (centre - margin) / (1 + z2 / n)
  end

  # An answer as [predicted_label, confidence], or nil when it cannot be
  # read (an unreadable_answer). Only choice and noul answers are handled.
  # `labels`, when given, must contain a choice answer's choice.
  def self.interpret(answer, labels: nil)
    return nil unless answer.is_a?(Hash)

    case answer["type"]
    when "choice"
      choice = answer["choice"]
      conf = answer["confidence"]
      return nil unless choice.is_a?(String) && unit_number?(conf)
      return nil if labels && !labels.include?(choice)

      [choice, conf]
    when "noul"
      p = answer["noul"]
      return nil unless unit_number?(p)

      [p >= 0.5 ? "true" : "false", [p, 1 - p].max]
    end
  end

  # The labels a question can predict. Choice: the keys of its criteria
  # object. Noul: true and false. Anything else raises ArgumentError.
  def self.labels_for(question)
    raise ArgumentError, "question must be an object" unless question.is_a?(Hash)

    case question["type"]
    when "choice"
      criteria = question["criteria"]
      unless criteria.is_a?(Hash) && !criteria.empty?
        raise ArgumentError, "choice criteria must be a non-empty object"
      end

      criteria.keys
    when "noul"
      %w[true false]
    else
      raise ArgumentError, "unsupported question type"
    end
  end

  # judged: [{label: gold, predicted:, confidence:}], one per case. Returns
  # {label => result} for every label in `labels`: the smallest threshold
  # whose Wilson bound clears `min_lower_bound` with `min_routed` cases, or
  # a nil threshold with a reason. Reported numbers are rounded to 6 places;
  # the comparison uses the unrounded bound.
  def self.sweep(judged, labels:, min_routed: MIN_ROUTED,
                 min_lower_bound: MIN_LOWER_BOUND, z: Z)
    labels.each_with_object({}) do |label, out|
      out[label] = sweep_label(judged, label, min_routed, min_lower_bound, z)
    end
  end

  def self.sweep_label(judged, label, min_routed, min_lower_bound, z)
    best = nil
    THRESHOLDS.each do |t|
      routed = judged.select do |j|
        j[:predicted] == label && j[:confidence] && j[:confidence] >= t
      end
      n = routed.size
      next if n < min_routed

      k = routed.count { |j| j[:label] == label }
      lb = wilson_lower_bound(k, n, z: z)
      entry = { threshold: t, routed: n, correct: k,
                precision: round6(k.to_f / n), lower_bound: round6(lb) }
      return entry if lb >= min_lower_bound

      best = entry.merge(raw: lb) if best.nil? || lb > best[:raw]
    end
    return { threshold: nil, reason: "too_few_routed", best: nil } if best.nil?

    best.delete(:raw)
    { threshold: nil, reason: "below_bound", best: best }
  end
  private_class_method :sweep_label

  def self.unit_number?(value)
    value.is_a?(Numeric) && value.to_f.finite? && value >= 0 && value <= 1
  end
  private_class_method :unit_number?

  def self.round6(value)
    value.round(6)
  end
  private_class_method :round6
end

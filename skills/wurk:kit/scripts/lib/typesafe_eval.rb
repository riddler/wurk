# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require_relative "typesafe"

# Jev eval library: what a call site must pass before it may move from
# shadow to on. The pure math (Wilson bound, answer interpretation, label
# lists, the threshold sweep) needs no IO. The corpus half (question-set
# file, corpus file and digest, redaction, the builder, the terminal
# labeller) reads and writes files only where the operator names them and
# never touches the network; later phases add the run and the gate here.
# The library never prints and never exits: a refusal is a Refusal.
module TypesafeEval
  # A refusal the CLI turns into one blocked entry. `code` is a fixed label;
  # the message never quotes case text, source text or a state value.
  class Refusal < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  CORPUS_FORMAT = 1
  REDACTED = "[redacted]"

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

  # --- question-set file ----------------------------------------------------

  # {"question_set" => {"id", "version"}, "question" => qid, "questions" =>
  # {...}} from a JSON file, validated with the client's own input rules
  # (a placeholder state stands in for the cases). Any failure is a
  # question_set_invalid Refusal naming the field only.
  def self.load_question_set(path, site:)
    raw = read_json_file(path)
    invalid = ->(field) { Refusal.new("question_set_invalid", "the question-set file is invalid (#{field})") }
    raise invalid.call("file") unless raw.is_a?(Hash)

    questions = raw["questions"]
    question_set = raw["question_set"]
    reason = Typesafe.validate_input(
      { "state" => "", "questions" => questions, "question_set" => question_set }, site: site
    )
    raise invalid.call(reason) if reason

    qid = raw["question"]
    raise invalid.call("question") unless qid.is_a?(String) && questions.key?(qid)

    begin
      labels_for(questions[qid])
    rescue ArgumentError
      raise invalid.call("questions.#{qid}")
    end
    { "question_set" => { "id" => question_set["id"], "version" => question_set["version"] },
      "question" => qid, "questions" => questions }
  end

  def self.read_json_file(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError, EncodingError, SystemCallError
    nil
  end
  private_class_method :read_json_file

  # --- corpus ---------------------------------------------------------------

  # SHA-256 over question set, question, question text, labels and every
  # case's [id, source, state, label]: any text or label change is a new
  # digest; rewriting the file unchanged is not.
  def self.corpus_digest(corpus)
    cases = corpus["cases"].map { |c| [c["id"], c["source"], c["state"], c["label"]] }
    body = [corpus["question_set"], corpus["question"], corpus["questions"], corpus["labels"], cases]
    Digest::SHA256.hexdigest(JSON.generate(body))
  end

  # The parsed corpus at `path`, or a corpus_invalid Refusal (no path, no
  # parser text in the message).
  def self.load_corpus(path)
    corpus = read_json_file(path)
    valid = corpus.is_a?(Hash) && corpus["format"] == CORPUS_FORMAT &&
            corpus["labels"].is_a?(Array) && corpus["cases"].is_a?(Array) &&
            corpus["cases"].all? { |c| c.is_a?(Hash) && c["id"].is_a?(String) }
    raise Refusal.new("corpus_invalid", "the corpus file is missing or not a format-1 corpus") unless valid

    corpus
  end

  # Writes the corpus as one JSON object plus a newline: a tmp file in the
  # same directory (mode 600, the states are source text), then a rename, so
  # an interrupted write keeps the previous file whole.
  def self.write_corpus(path, corpus)
    dir = File.dirname(File.expand_path(path))
    FileUtils.mkdir_p(dir)
    tmp = File.join(dir, ".#{File.basename(path)}.tmp#{Process.pid}")
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
      f.write(JSON.generate(corpus))
      f.write("\n")
    end
    File.rename(tmp, path)
  ensure
    File.delete(tmp) if tmp && File.exist?(tmp)
  end

  # --- redaction ------------------------------------------------------------

  # [text, count]. R1 replaces the value after a `key:` or `key=` (up to the
  # next , ; | or end of line) for each redact key; R2 replaces a whole
  # tagged label ([L] (L) {L} #L, `label: L`) for each label. Bare prose
  # occurrences of a label word are content and are kept.
  def self.redact(text, keys:, labels:)
    count = 0
    out = text.dup
    keys.each do |key|
      out = out.gsub(/\b(#{Regexp.escape(key)})\s*[:=]\s*[^,;|\n]*/i) do
        count += 1
        "#{Regexp.last_match(1)}: #{REDACTED}"
      end
    end
    labels.each do |label|
      escaped = Regexp.escape(label)
      out = out.gsub(/\blabel\s*[:=]\s*#{escaped}(?!\w)/i) do
        count += 1
        "label: #{REDACTED}"
      end
      tagged = /\[\s*#{escaped}\s*\]|\(\s*#{escaped}\s*\)|\{\s*#{escaped}\s*\}|(?<!\w)\##{escaped}(?!\w)/i
      out = out.gsub(tagged) do
        count += 1
        REDACTED
      end
    end
    [out, count]
  end

  # Redacts every string inside a state, recursing through objects and
  # arrays. An object member whose key is a redact key loses its whole value.
  # Returns [state, count].
  def self.redact_state(state, keys:, labels:)
    case state
    when String
      redact(state, keys: keys, labels: labels)
    when Array
      count = 0
      walked = state.map do |item|
        value, n = redact_state(item, keys: keys, labels: labels)
        count += n
        value
      end
      [walked, count]
    when Hash
      redact_hash(state, keys, labels)
    else
      [state, 0]
    end
  end

  def self.redact_hash(state, keys, labels)
    count = 0
    down = keys.map(&:downcase)
    walked = {}
    state.each do |k, v|
      if down.include?(k.to_s.downcase)
        walked[k] = REDACTED
        count += 1
      else
        walked[k], n = redact_state(v, keys: keys, labels: labels)
        count += n
      end
    end
    [walked, count]
  end
  private_class_method :redact_hash

  # --- builder --------------------------------------------------------------

  # Builds a corpus (a Hash) from read-only sources, or raises a Refusal.
  # A source is {kind: "dir", path:, glob:, source:} or {kind: "jsonl",
  # path:, source:}. `out` (the corpus path) is needed to refuse an output
  # inside a source and to keep the labels of an existing corpus there.
  # Nothing is written here; the caller writes the returned corpus.
  def self.build_corpus(config:, question_set_file:, site:, sources:, redact_keys:, out: nil)
    restricted = config.typesafe_restricted_sources
    sources.each do |src|
      unless src[:source].is_a?(String) && !src[:source].strip.empty?
        raise ArgumentError, "every source needs a source label"
      end
      if restricted.include?(src[:source])
        raise Refusal.new("source_restricted",
                          "source #{src[:source]} is listed in typesafe.restricted_sources; " \
                          "nothing was read and nothing was written")
      end
    end
    check_output(out, sources) if out

    spec = load_question_set(question_set_file, site: site)
    labels = labels_for(spec["questions"][spec["question"]])
    cases = read_sources(sources)
    cases.each do |c|
      c["state"], c["redactions"] = redact_state(c["state"], keys: redact_keys, labels: labels)
    end
    keep_labels!(cases, out, labels)
    spec.merge("format" => CORPUS_FORMAT, "site" => site, "labels" => labels,
               "redaction" => { "keys" => redact_keys, "labels" => labels },
               "cases" => cases)
  end

  # The output path may not be a source file or lie inside a source dir.
  def self.check_output(out, sources)
    target = real_path(out)
    sources.each do |src|
      path = real_path(src[:path])
      inside = src[:kind] == "dir" && target.start_with?(path + File::SEPARATOR)
      next unless target == path || inside

      raise Refusal.new("output_inside_source", "the output path is a source file or inside a source dir")
    end
  end
  private_class_method :check_output

  def self.real_path(path)
    full = File.expand_path(path)
    return File.realpath(full) if File.exist?(full)

    dir = File.dirname(full)
    File.exist?(dir) ? File.join(File.realpath(dir), File.basename(full)) : full
  end
  private_class_method :real_path

  # Cases in source order: {"id", "source", "state", "redactions" => 0,
  # "label" => nil}. Sources are only read.
  def self.read_sources(sources)
    seen = {}
    sources.flat_map do |src|
      rows = src[:kind] == "jsonl" ? read_jsonl(src) : read_dir(src)
      rows.map do |id, state|
        if seen.key?(id)
          raise Refusal.new("duplicate_case_id",
                            "a case id appears twice (second time in source #{src[:source]})")
        end
        seen[id] = true
        { "id" => id, "source" => src[:source], "state" => state, "redactions" => 0, "label" => nil }
      end
    end
  end
  private_class_method :read_sources

  def self.read_dir(src)
    unless File.directory?(src[:path])
      raise Refusal.new("source_unreadable", "source #{src[:source]} is not a readable directory")
    end

    base = File.expand_path(src[:path])
    pattern = src[:glob] || "**/*"
    Dir.glob(File.join(base, pattern)).sort.select { |f| File.file?(f) }.map do |file|
      [file[(base.length + 1)..-1], File.read(file).force_encoding("UTF-8").scrub("?")]
    end
  rescue SystemCallError => e
    raise Refusal.new("source_unreadable", "source #{src[:source]} could not be read (#{e.class.name})")
  end
  private_class_method :read_dir

  def self.read_jsonl(src)
    rows = []
    File.foreach(src[:path]).with_index(1) do |line, number|
      next if line.strip.empty?

      row = parse_line(line.force_encoding("UTF-8").scrub("?"))
      unless row.is_a?(Hash) && row["id"].is_a?(String) && !row["id"].empty? &&
             [String, Hash, Array].any? { |k| row["state"].is_a?(k) }
        raise Refusal.new("bad_source_line",
                          "line #{number} of source #{src[:source]} is not {id, state}")
      end
      rows << [row["id"], row["state"]]
    end
    rows
  rescue SystemCallError => e
    raise Refusal.new("source_unreadable", "source #{src[:source]} could not be read (#{e.class.name})")
  end
  private_class_method :read_jsonl

  def self.parse_line(line)
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end
  private_class_method :parse_line

  # Rebuilding over an existing corpus keeps a label whose case id and
  # redacted state are unchanged (and whose label is still a label).
  def self.keep_labels!(cases, out, labels)
    return unless out && File.file?(out)

    old = begin
      load_corpus(out)
    rescue Refusal
      return
    end
    prior = old["cases"].each_with_object({}) { |c, h| h[c["id"]] = c }
    cases.each do |c|
      was = prior[c["id"]]
      next unless was && was["state"] == c["state"] && labels.include?(was["label"])

      c["label"] = was["label"]
    end
  end
  private_class_method :keep_labels!

  # --- labeller -------------------------------------------------------------

  # Walks the unlabelled cases (all of them with relabel) on a terminal:
  # the case is shown on `prompt`, one line is read from `input`. A menu
  # number or a label name records it; s skips; q or EOF stops; anything
  # else re-prompts. The corpus file is rewritten after each recorded label.
  # Returns {labelled:, skipped:, remaining:, per_label:}. No Jev answer is
  # ever shown: the corpus has none.
  def self.label(corpus_path:, input:, prompt:, relabel: false, dry_run: false)
    corpus = load_corpus(corpus_path)
    labels = corpus["labels"]
    todo = corpus["cases"].select { |c| relabel || c["label"].nil? }
    labelled = 0
    skipped = 0
    todo.each_with_index do |c, i|
      show_case(prompt, c, i + 1, todo.size, labels)
      choice = ask(input, prompt, labels)
      break if choice == :quit

      if choice == :skip
        skipped += 1
        next
      end
      c["label"] = choice
      labelled += 1
      write_corpus(corpus_path, corpus) unless dry_run
    end
    per_label = labels.each_with_object({}) { |l, h| h[l] = corpus["cases"].count { |c| c["label"] == l } }
    { labelled: labelled, skipped: skipped, remaining: todo.size - labelled - skipped,
      per_label: per_label }
  end

  def self.show_case(prompt, kase, number, total, labels)
    state = kase["state"].is_a?(String) ? kase["state"] : JSON.pretty_generate(kase["state"])
    prompt.puts
    prompt.puts "case #{number}/#{total}: #{kase['id']} (source: #{kase['source']})"
    prompt.puts "----"
    prompt.puts state
    prompt.puts "----"
    labels.each_with_index { |l, i| prompt.puts "  #{i + 1}) #{l}" }
    prompt.puts "  s) skip   q) quit"
  end
  private_class_method :show_case

  # A label, :skip or :quit.
  def self.ask(input, prompt, labels)
    loop do
      prompt.print "label> "
      line = input.gets
      return :quit if line.nil?

      answer = line.strip
      found = pick_label(answer, labels)
      return found if found
      return :skip if answer.casecmp("s").zero?
      return :quit if answer.casecmp("q").zero?

      prompt.puts "not a choice: enter a menu number, a label name, s or q"
    end
  end
  private_class_method :ask

  def self.pick_label(answer, labels)
    return labels[answer.to_i - 1] if answer.match?(/\A[1-9]\d*\z/) && answer.to_i <= labels.size

    labels.find { |l| l.casecmp(answer).zero? }
  end
  private_class_method :pick_label
end

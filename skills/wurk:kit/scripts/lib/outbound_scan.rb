# frozen_string_literal: true

require_relative "user_config"

# OutboundScan is the single definition site for ADR-0014's outbound-content
# scan: load the operator's pattern set, compile it, scan a payload, run the
# positive-control probe, and hand back a redacted result. Pure Ruby over
# strings and files - no git, no bd, no shelling out - so it is fully
# unit-testable and green on any machine with no private data present.
#
# Redaction is a first-class invariant here, not a habit (wu-be9): nothing
# this file returns ever carries matched text, the matching pattern, or the
# pattern's source line. A Result reports locations and counts. A
# PatternSet.load parse error reports a line number. That is the whole
# vocabulary a caller is allowed to render.
module OutboundScan
  # A single hit, reported as a LOCATION and a COUNT and nothing else.
  # There is deliberately no field for the matched text, the matching
  # pattern, or the pattern's index: this component exists because echoing
  # any of those into an envelope, a message, or a log is itself the leak it
  # guards against (wu-be9). Adding such a field is not an enhancement, it
  # is a defect.
  Hit = Struct.new(:location, :count, keyword_init: true) do
    def to_h
      { "location" => location, "count" => count }
    end
  end

  # Raised by PatternSet.load. Carries a redacted code/message pair only -
  # never the pattern text, never the offending line's source, never the
  # Ruby exception's own message when that exception is a RegexpError (which
  # quotes the source it failed on).
  class LoadError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  # The outcome of one scan attempt (armed or not, probed or not, whatever
  # hits and errors resulted). This is the only object that becomes envelope
  # output - see OutboundScan.apply_to_envelope.
  class Result
    attr_reader :armed, :probe_ok, :hits, :scanned_locations, :errors

    def initialize(armed:, probe_ok: nil, hits: [], scanned_locations: 0, errors: [])
      @armed = armed
      @probe_ok = probe_ok
      @hits = hits
      @scanned_locations = scanned_locations
      @errors = errors
    end

    def armed?
      @armed
    end

    # True only when the gate actually ran, proved it could hit (the probe),
    # and found nothing. Never true for a disarmed result - a disarmed
    # result was never scanned at all, so "clean" would misstate it.
    def clean?
      armed? && probe_ok && hits.empty? && errors.empty?
    end

    # True whenever the push must be refused: any hit, or any error
    # (including a failed probe, which is recorded as an error - see
    # OutboundScan.run).
    def refuse?
      !hits.empty? || !errors.empty?
    end

    def to_h
      {
        "armed" => armed,
        "probe_ok" => probe_ok,
        "hits" => hits.map(&:to_h),
        "scanned_locations" => scanned_locations,
        "errors" => errors
      }
    end
  end

  # Loads and compiles an operator's pattern file. Blank lines and lines
  # whose first non-space character is "#" are dropped; every remaining line
  # is compiled as a case-insensitive Regexp. The compiled set lives in
  # memory for the process lifetime only - never written anywhere, never
  # rendered, never passed to a subprocess.
  module PatternSet
    class << self
      # Returns an Array of compiled Regexp. Raises LoadError (never a bare
      # Errno or RegexpError) on every failure mode, each with its own code.
      def load(path)
        content = read(path)
        patterns = compile_lines(content)
        raise LoadError.new("patterns_file_empty", "the configured patterns file contains no usable patterns") if patterns.empty?

        patterns
      end

      private

      # The configured path is deliberately NOT named in the message. An
      # operator names this file after what it guards, so the path is itself
      # part of the guarded vocabulary - and this message reaches an
      # envelope, a terminal, and a log. The exception class says what went
      # wrong; there is only one configured patterns file, so nothing is
      # ambiguous without it.
      def read(path)
        File.read(path)
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
        raise LoadError.new(
          "patterns_file_unreadable",
          "the configured patterns file could not be read: #{e.class}"
        )
      end

      def compile_lines(content)
        patterns = []
        content.each_line.with_index(1) do |raw_line, lineno|
          line = raw_line.strip
          next if line.empty?
          next if line.start_with?("#")

          begin
            patterns << Regexp.new(line, Regexp::IGNORECASE)
          rescue RegexpError
            # Never interpolate raw_line or the rescued error's own message:
            # RegexpError quotes the offending source, which is exactly the
            # leak this module exists to prevent. Line number only.
            raise LoadError.new(
              "patterns_file_unparseable",
              "line #{lineno} of the configured patterns file is not a valid regular expression"
            )
          end
        end
        patterns
      end
    end
  end

  # Runs a compiled pattern set over a payload and over the positive-control
  # probe. No git, no bd, no shelling out - just strings.
  class Scanner
    def initialize(patterns, control_term:)
      @patterns = patterns
      @control_term = control_term
    end

    # payload is an Enumerable of [location_string, text] pairs. Returns an
    # Array of Hit, one per location with a nonzero total match count across
    # the whole compiled set.
    def scan_payload(payload)
      hits = []
      locations = 0
      payload.each do |location, text|
        locations += 1
        count = count_matches(normalize(text))
        hits << Hit.new(location: location, count: count) if count.positive?
      end
      [hits, locations]
    end

    # Builds a synthetic string containing the control term with generic
    # filler around it, and runs the compiled set over it. True only if at
    # least one pattern hits - proof the pipeline can hit at all, so a
    # zero-hit payload result means something. The probe string is
    # synthesized in memory and never written to disk.
    def probe
      probe_text = "outbound-scan-probe filler #{@control_term} filler outbound-scan-probe"
      count_matches(probe_text).positive?
    end

    private

    # Every text is matched as UTF-8, scrubbed when it does not already hold
    # valid UTF-8, so a mis-encoded or binary blob cannot raise mid-scan and
    # silently drop out of the gate. Scrubbing replaces only the invalid byte
    # sequences, so ASCII and well-formed UTF-8 terms inside a binary blob
    # still match - and nothing is ever skipped, because skipping is how a
    # gate quietly stops gating.
    #
    # Forcing Encoding::BINARY here instead would look equivalent and is not:
    # a pattern with any non-ASCII character in it raises
    # Encoding::CompatibilityError against a BINARY string, which would take
    # the whole scan down mid-push for any operator whose guarded vocabulary
    # is not pure ASCII.
    def normalize(text)
      utf8 = text.encoding == Encoding::UTF_8 ? text : text.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? utf8 : utf8.scrub
    end

    def count_matches(text)
      @patterns.sum { |pattern| text.scan(pattern).length }
    end
  end

  class << self
    # The entry point every caller uses. Resolves the four configuration
    # states (see the plan's table) and returns a Result:
    #
    #   section absent               -> armed: false, no probe, no scan
    #   section present, one key     -> armed: true, scan_config_incomplete
    #   section present, bad file    -> armed: true, PatternSet.load's error
    #   section present, good file   -> probe, then scan
    def run(payload, config: UserConfig.current)
      return Result.new(armed: false) unless config.outbound_scan_declared?

      patterns_file = config.outbound_scan_patterns_file
      control_term = config.outbound_scan_control_term

      if patterns_file.nil? || control_term.nil?
        return Result.new(
          armed: true,
          errors: [{ "code" => "scan_config_incomplete",
                     "message" => "outbound_scan is missing patterns_file or control_term; both are required to arm the scan" }]
        )
      end

      begin
        patterns = PatternSet.load(patterns_file)
      rescue LoadError => e
        return Result.new(armed: true, errors: [{ "code" => e.code, "message" => e.message }])
      end

      scanner = Scanner.new(patterns, control_term: control_term)
      probe_ok = scanner.probe

      unless probe_ok
        return Result.new(
          armed: true,
          probe_ok: false,
          errors: [{ "code" => "scan_pipeline_broken",
                     "message" => "the outbound scan's positive-control probe did not hit; refusing rather than trusting a zero-hit result" }]
        )
      end

      hits, locations = scanner.scan_payload(payload)
      Result.new(armed: true, probe_ok: true, hits: hits, scanned_locations: locations)
    end

    # The one place a Result becomes envelope entries, so the git path, the
    # tracker path, and the CLI cannot drift in what they disclose.
    def apply_to_envelope(result, env, path_label:)
      if !result.armed?
        env.warn(
          code: "outbound_scan_disarmed",
          message: "no outbound scan is configured on this machine; this push was not scanned"
        )
      elsif !result.hits.empty?
        env.block!(
          code: "outbound_scan_hit",
          message: "#{result.hits.sum(&:count)} outbound scan hit(s) in #{result.hits.length} location(s); " \
                   "see data.outbound_scan.hits for locations and counts"
        )
      end

      result.errors.each do |error|
        env.block!(code: error["code"], message: error["message"])
      end

      env.data["outbound_scan"] = result.to_h
      result
    end
  end
end

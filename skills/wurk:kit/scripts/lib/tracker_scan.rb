# frozen_string_literal: true

require "json"
require "digest"
require "time"
require "fileutils"

# TrackerScan is the pure half of the gated tracker push (wu-b4i, extending
# ADR-0014's tracker path): everything `bead.rb sync scan` and `bead.rb sync
# push` need that is not a shell-out or an envelope. Payload assembly from
# a `bd list --all --json` export, the split between the fields a hit
# REFUSES on and the fields a hit only REPORTS on, per-issue attribution of
# hits, the export fingerprint, and the scan marker the push verb demands.
# No Sh, no envelope, no bd - strings, hashes, and one small JSON file - so
# every rule here is unit-testable without a tracker.
#
# The two verbs are separate on purpose and this module is what lets them
# be: a scan writes a marker only when it came back clean, and a push
# refuses unless a marker exists, is younger than the TTL, and fingerprints
# the SAME export the push is about to publish. Neither verb runs the other.
# That is the discipline the fleet already kept by hand - scan, look at the
# result, then push - made mechanical, so the look cannot be skipped by
# chaining the two into one command.
#
# Redaction is inherited from OutboundScan and kept here: nothing this
# module returns or writes carries matched text or a pattern. A hit is an
# issue id, a field NAME (a bd schema name such as "description", never the
# field's content), and a count.
module TrackerScan
  MARKER_VERSION = 1

  # Ten minutes, in the source rather than the manifest: the window is
  # about how long a human's look at a scan result stays a look at THIS
  # result, not a project property. The fingerprint check is the stronger
  # guard; the TTL is what catches a pattern file edited under a marker
  # whose export did not change.
  MARKER_TTL_SECONDS = 600

  # The marker lives under the git common dir - one per beads database,
  # shared by every worktree of the checkout (the worktrees redirect to the
  # main checkout's .beads), never inside the tracked tree, and never in a
  # bd-owned directory.
  MARKER_RELATIVE_PATH = File.join("wurk", "tracker-scan.json").freeze

  # `beads.scan_refusal` values. `all` refuses on any string field; `titles`
  # refuses on each issue's title only and reports the rest.
  REFUSAL_MODES = %w[all titles].freeze

  LOCATION_PREFIX = "tracker"

  class << self
    # --- payload ------------------------------------------------------------

    # Builds [location, text] pairs for every string value in the parsed
    # `bd list --all --json` export, one issue at a time: `tracker:<issue
    # id>:<field>` for the issue's own top-level fields, extended with the
    # JSON path for anything nested, so a schema addition is scanned with
    # no code change here. Every field is scanned in every mode; the mode
    # only decides which hits refuse.
    def payload(issues)
      out = []
      issues.each do |issue|
        next unless issue.is_a?(Hash)

        id = issue["id"].is_a?(String) && !issue["id"].empty? ? issue["id"] : "unknown"
        walk(issue, "#{LOCATION_PREFIX}:#{id}", out)
      end
      out
    end

    # Splits a location back into its issue id and top-level field name.
    # Bead ids never contain ":" (Refs.bead_id is [a-z0-9] plus "-" and
    # "."), so the second segment is always the id and the third starts
    # with the field name.
    def parse_location(location)
      _prefix, id, rest = location.to_s.split(":", 3)
      field = rest.to_s.split(/[:\[]/, 2).first.to_s
      [id.to_s, field]
    end

    # Whether a hit at this location refuses the push under `mode`.
    def refusing?(location, mode)
      return true if mode == "all"

      _id, field = parse_location(location)
      field == "title"
    end

    # [refusing_hits, informational_hits], both Arrays of OutboundScan::Hit.
    def partition_hits(hits, mode)
      hits.partition { |hit| refusing?(hit.location, mode) }
    end

    # Per-issue attribution, sorted by id: [{"id", "count", "fields"}].
    # Field names are bd's schema names, which is the whole vocabulary a
    # report may use - never a literal (the operator rules on which record,
    # and the record is the unit they can scrub).
    def attribute(hits)
      by_id = Hash.new { |h, k| h[k] = { "id" => k, "count" => 0, "fields" => [] } }
      hits.each do |hit|
        id, field = parse_location(hit.location)
        entry = by_id[id]
        entry["count"] += hit.count
        entry["fields"] << field unless field.empty? || entry["fields"].include?(field)
      end
      by_id.values.sort_by { |entry| entry["id"] }.each { |entry| entry["fields"].sort! }
    end

    # --- fingerprint ----------------------------------------------------------

    # The export's bytes, hashed. `bd list --all --json` is deterministic for
    # an unchanged database, so an equal fingerprint means the push publishes
    # exactly what the scan read.
    def fingerprint(raw)
      "sha256:#{Digest::SHA256.hexdigest(raw.to_s)}"
    end

    # --- marker -----------------------------------------------------------------

    def marker_path(common_dir)
      File.join(common_dir, MARKER_RELATIVE_PATH)
    end

    # The marker a clean scan writes. `informational` is the attributed list
    # of hits outside the refusal set, carried so the push verb can re-emit
    # what the scan reported without rescanning.
    def build_marker(fingerprint:, refusal:, armed:, issues:, informational:, now: Time.now)
      {
        "version" => MARKER_VERSION,
        "scanned_at" => now.utc.iso8601,
        "fingerprint" => fingerprint,
        "refusal" => refusal,
        "armed" => armed,
        "issues" => issues,
        "informational" => informational
      }
    end

    # Written whole via a temp file and rename, so a reader never sees a
    # half-written marker as a finished one.
    def write_marker(path, marker)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.pretty_generate(marker) + "\n")
      File.rename(tmp, path)
      path
    end

    # The parsed marker, or :unreadable when a file exists but is not a
    # marker, or nil when there is none.
    def read_marker(path)
      return nil unless File.file?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) && parsed["version"] == MARKER_VERSION ? parsed : :unreadable
    rescue JSON::ParserError, Errno::EACCES, Errno::EISDIR
      :unreadable
    end

    # Decides whether `marker` licenses a push of the export whose
    # fingerprint is `fingerprint` under refusal mode `refusal`, now.
    # Returns {state:, age_seconds:} with state one of:
    #
    #   fresh      - push may proceed
    #   missing    - no scan has been run (or its marker was removed)
    #   unreadable - a file is there but is not a marker this kit wrote
    #   expired    - older than MARKER_TTL_SECONDS
    #   stale      - the tracker export or the refusal mode changed since
    #
    # Every non-fresh state has the same remedy - run `bead.rb sync scan`
    # again - and each is named separately so the reason is in the report.
    def check_marker(marker, fingerprint:, refusal:, now: Time.now, ttl: MARKER_TTL_SECONDS)
      return { state: "missing", age_seconds: nil } if marker.nil?
      return { state: "unreadable", age_seconds: nil } if marker == :unreadable

      scanned_at = parse_time(marker["scanned_at"])
      return { state: "unreadable", age_seconds: nil } unless scanned_at

      age = (now - scanned_at).to_i
      # A marker from the future is a clock the kit cannot trust; it is
      # reported as expired because the remedy is the same rescan.
      return { state: "expired", age_seconds: age } if age > ttl || age.negative?
      return { state: "stale", age_seconds: age } if marker["fingerprint"] != fingerprint || marker["refusal"] != refusal

      { state: "fresh", age_seconds: age }
    end

    private

    def walk(node, location, out)
      case node
      when String
        out << [location, node] unless node.empty?
      when Hash
        node.each { |key, value| walk(value, "#{location}:#{key}", out) }
      when Array
        node.each_with_index { |value, index| walk(value, "#{location}[#{index}]", out) }
      end
    end

    def parse_time(value)
      return nil unless value.is_a?(String)

      Time.iso8601(value)
    rescue ArgumentError
      nil
    end
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "time"
require "fileutils"
require_relative "support/home_guard"
require_relative "../lib/tracker_scan"
require_relative "../lib/outbound_scan"

# TrackerScan (lib/tracker_scan.rb): the pure half of the gated tracker
# push - payload assembly, the refusal split, per-issue attribution, the
# fingerprint, and the marker. No Sh, no bd, no envelope.
class TrackerScanTest < Minitest::Test
  def hit(location, count = 1)
    OutboundScan::Hit.new(location: location, count: count)
  end

  # --- payload ------------------------------------------------------------

  def test_payload_labels_every_string_field_by_issue_id_and_field
    issues = [{ "id" => "zz-abc", "title" => "t", "description" => "d", "priority" => 1, "labels" => %w[a b],
                "nested" => { "deep" => "x" } }]

    assert_equal(
      [
        ["tracker:zz-abc:id", "zz-abc"],
        ["tracker:zz-abc:title", "t"],
        ["tracker:zz-abc:description", "d"],
        ["tracker:zz-abc:labels[0]", "a"],
        ["tracker:zz-abc:labels[1]", "b"],
        ["tracker:zz-abc:nested:deep", "x"]
      ],
      TrackerScan.payload(issues)
    )
  end

  def test_payload_skips_empty_strings_and_non_hash_issues
    assert_equal [["tracker:unknown:title", "t"]], TrackerScan.payload([{ "title" => "t", "notes" => "" }, "junk", nil])
  end

  # --- refusal split --------------------------------------------------------

  def test_parse_location_splits_id_and_top_level_field
    assert_equal %w[zz-abc title], TrackerScan.parse_location("tracker:zz-abc:title")
    assert_equal %w[zz-abc labels], TrackerScan.parse_location("tracker:zz-abc:labels[1]")
    assert_equal %w[zz-abc nested], TrackerScan.parse_location("tracker:zz-abc:nested:deep")
    assert_equal %w[zz-a.1 notes], TrackerScan.parse_location("tracker:zz-a.1:notes")
  end

  # sabotage: make refusing? return true for every field -> red.
  def test_under_all_every_field_refuses
    assert TrackerScan.refusing?("tracker:zz-abc:title", "all")
    assert TrackerScan.refusing?("tracker:zz-abc:description", "all")
    assert TrackerScan.refusing?("tracker:zz-abc:labels[0]", "all")
  end

  def test_under_titles_only_the_title_refuses
    assert TrackerScan.refusing?("tracker:zz-abc:title", "titles")
    refute TrackerScan.refusing?("tracker:zz-abc:description", "titles")
    refute TrackerScan.refusing?("tracker:zz-abc:notes", "titles")
    # A nested key named title is not the issue's title.
    refute TrackerScan.refusing?("tracker:zz-abc:comments[0]:title", "titles")
  end

  def test_partition_hits_keeps_both_halves
    hits = [hit("tracker:zz-abc:title"), hit("tracker:zz-abc:notes", 2), hit("tracker:zz-xyz:description")]
    refusing, informational = TrackerScan.partition_hits(hits, "titles")

    assert_equal ["tracker:zz-abc:title"], refusing.map(&:location)
    assert_equal ["tracker:zz-abc:notes", "tracker:zz-xyz:description"], informational.map(&:location)
    assert_equal [[], []], TrackerScan.partition_hits([], "all")
  end

  # --- attribution ------------------------------------------------------------

  # Per issue id, sorted, summed, field NAMES only - never a literal.
  def test_attribute_groups_by_issue_sums_counts_and_lists_fields_once
    hits = [
      hit("tracker:zz-xyz:description", 2),
      hit("tracker:zz-abc:notes", 1),
      hit("tracker:zz-abc:description", 3),
      hit("tracker:zz-abc:labels[0]", 1),
      hit("tracker:zz-abc:labels[2]", 1)
    ]

    assert_equal(
      [
        { "id" => "zz-abc", "count" => 6, "fields" => %w[description labels notes] },
        { "id" => "zz-xyz", "count" => 2, "fields" => ["description"] }
      ],
      TrackerScan.attribute(hits)
    )
  end

  def test_attribute_of_nothing_is_empty
    assert_equal [], TrackerScan.attribute([])
  end

  # --- fingerprint --------------------------------------------------------------

  def test_fingerprint_is_a_stable_sha256_of_the_bytes
    assert_equal TrackerScan.fingerprint("[]"), TrackerScan.fingerprint("[]")
    refute_equal TrackerScan.fingerprint("[]"), TrackerScan.fingerprint("[ ]")
    assert_match(/\Asha256:[0-9a-f]{64}\z/, TrackerScan.fingerprint("x"))
  end

  # --- marker -------------------------------------------------------------------

  def test_marker_path_is_under_the_common_dir
    assert_equal "/repo/.git/wurk/tracker-scan.json", TrackerScan.marker_path("/repo/.git")
  end

  def test_write_and_read_marker_round_trip_and_leave_no_temp_file
    Dir.mktmpdir do |dir|
      path = TrackerScan.marker_path(dir)
      marker = TrackerScan.build_marker(fingerprint: "sha256:ab", refusal: "titles", armed: true, issues: 3,
                                        informational: [{ "id" => "zz-abc", "count" => 1, "fields" => ["notes"] }],
                                        now: Time.utc(2026, 9, 15, 12, 0, 0))

      TrackerScan.write_marker(path, marker)

      assert_equal marker, TrackerScan.read_marker(path)
      assert_equal "2026-09-15T12:00:00Z", marker["scanned_at"]
      assert_equal [File.basename(path)], Dir.children(File.dirname(path))
    end
  end

  def test_read_marker_distinguishes_missing_from_unreadable
    Dir.mktmpdir do |dir|
      path = TrackerScan.marker_path(dir)
      assert_nil TrackerScan.read_marker(path)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{ not json")
      assert_equal :unreadable, TrackerScan.read_marker(path)

      File.write(path, JSON.generate("version" => 0))
      assert_equal :unreadable, TrackerScan.read_marker(path)

      File.write(path, JSON.generate([1]))
      assert_equal :unreadable, TrackerScan.read_marker(path)
    end
  end

  # --- check_marker -------------------------------------------------------------

  NOW = Time.utc(2026, 9, 15, 12, 0, 0)

  def marker_at(time, fingerprint: "sha256:ab", refusal: "all")
    TrackerScan.build_marker(fingerprint: fingerprint, refusal: refusal, armed: true, issues: 1, informational: [], now: time)
  end

  def check(marker, fingerprint: "sha256:ab", refusal: "all", now: NOW)
    TrackerScan.check_marker(marker, fingerprint: fingerprint, refusal: refusal, now: now)
  end

  def test_a_recent_matching_marker_is_fresh
    assert_equal({ state: "fresh", age_seconds: 30 }, check(marker_at(NOW - 30)))
    assert_equal "fresh", check(marker_at(NOW - TrackerScan::MARKER_TTL_SECONDS))[:state]
  end

  def test_missing_and_unreadable_are_named
    assert_equal({ state: "missing", age_seconds: nil }, check(nil))
    assert_equal({ state: "unreadable", age_seconds: nil }, check(:unreadable))
    assert_equal "unreadable", check({ "version" => 1, "scanned_at" => "yesterday" })[:state]
    assert_equal "unreadable", check({ "version" => 1 })[:state]
  end

  # sabotage: widen the TTL -> red. Ten minutes is in the source on purpose.
  def test_ttl_is_ten_minutes_and_one_second_past_it_expires
    assert_equal 600, TrackerScan::MARKER_TTL_SECONDS
    result = check(marker_at(NOW - 601))
    assert_equal "expired", result[:state]
    assert_equal 601, result[:age_seconds]
  end

  def test_a_marker_from_the_future_is_expired_not_fresh
    assert_equal "expired", check(marker_at(NOW + 5))[:state]
  end

  # sabotage: drop the fingerprint comparison -> red. The marker licenses a
  # push of THIS export, not of whatever the tracker holds now.
  def test_a_changed_export_is_stale
    assert_equal "stale", check(marker_at(NOW - 5), fingerprint: "sha256:cd")[:state]
  end

  def test_a_changed_refusal_set_is_stale
    assert_equal "stale", check(marker_at(NOW - 5, refusal: "titles"))[:state]
  end

  def test_expiry_wins_over_staleness_in_the_report
    assert_equal "expired", check(marker_at(NOW - 9999), fingerprint: "sha256:cd")[:state]
  end
end

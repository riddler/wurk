# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/outbound_scan"
require_relative "../lib/envelope"
require_relative "support/user_config_helper"

# Phase 2 coverage for lib/outbound_scan.rb: pattern-set loading, scanning,
# the control probe, config-state resolution, and envelope rendering. Every
# fixture token and pattern in this file is invented nonsense, never a real
# guarded term (see the plan's "Not adding the pattern set to any tracked
# file" and wu-be9) - that is itself the property the redaction tests below
# are checking.
class OutboundScanPatternSetTest < Minitest::Test
  def write_patterns(dir, content)
    path = File.join(dir, "patterns.txt")
    File.write(path, content)
    path
  end

  # sabotage: stop dropping blank lines or "#"-prefixed lines -> red (a
  # comment or blank line would compile as a pattern, or blow up trying to)
  def test_comments_and_blanks_are_skipped_only_real_lines_compile
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, <<~PATTERNS)
        # a comment line
        zqiblorf-alpha

        # another comment
        zqiblorf-beta
      PATTERNS
      patterns = OutboundScan::PatternSet.load(path)
      assert_equal 2, patterns.length
      assert patterns.all? { |p| p.is_a?(Regexp) }
    end
  end

  # sabotage: rescue Errno::ENOENT more broadly than intended or forget to
  # raise LoadError -> red
  def test_missing_file_raises_patterns_file_unreadable
    error = assert_raises(OutboundScan::LoadError) do
      OutboundScan::PatternSet.load("/nonexistent/does-not-exist-zqiblorf.txt")
    end
    assert_equal "patterns_file_unreadable", error.code
  end

  # sabotage: drop the Errno::EISDIR rescue -> red
  def test_unreadable_file_raises_patterns_file_unreadable
    Dir.mktmpdir do |dir|
      error = assert_raises(OutboundScan::LoadError) { OutboundScan::PatternSet.load(dir) }
      assert_equal "patterns_file_unreadable", error.code
    end
  end

  # sabotage: return an empty array instead of raising when nothing usable
  # remains -> red
  def test_empty_after_filtering_raises_patterns_file_empty
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, "\n# only comments\n\n")
      error = assert_raises(OutboundScan::LoadError) { OutboundScan::PatternSet.load(path) }
      assert_equal "patterns_file_empty", error.code
    end
  end

  def test_wholly_empty_file_raises_patterns_file_empty
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, "")
      error = assert_raises(OutboundScan::LoadError) { OutboundScan::PatternSet.load(path) }
      assert_equal "patterns_file_empty", error.code
    end
  end

  # sabotage: interpolate the raw line, or the rescued RegexpError's own
  # message, into the LoadError message -> red (this is the redaction test
  # for the loader's own error path)
  def test_uncompilable_line_reports_line_number_only
    Dir.mktmpdir do |dir|
      token = "zqiblorf-unparseable-token-4471"
      path = write_patterns(dir, <<~PATTERNS)
        zqiblorf-ok-line
        #{token}(
      PATTERNS
      error = assert_raises(OutboundScan::LoadError) { OutboundScan::PatternSet.load(path) }
      assert_equal "patterns_file_unparseable", error.code
      assert_equal "line 2 of the configured patterns file is not a valid regular expression", error.message
      refute_includes error.message, token
    end
  end
end

class OutboundScanScannerTest < Minitest::Test
  def scanner_for(lines, control_term: "zqiblorf-control-9001")
    patterns = lines.map { |l| Regexp.new(l, Regexp::IGNORECASE) }
    OutboundScan::Scanner.new(patterns, control_term: control_term)
  end

  # sabotage: append a Hit for a location with zero matches -> red
  def test_a_hit_reports_location_and_count
    scanner = scanner_for(["zqiblorf-secret"])
    hits, locations = scanner.scan_payload([["file/a.txt", "nothing here"], ["file/b.txt", "has zqiblorf-secret once"]])
    assert_equal 2, locations
    assert_equal 1, hits.length
    assert_equal "file/b.txt", hits.first.location
    assert_equal 1, hits.first.count
  end

  # sabotage: emit one Hit per match instead of collapsing per location, or
  # miscount across multiple patterns -> red
  def test_multiple_matches_in_one_location_collapse_to_one_hit_with_total_count
    scanner = scanner_for(["zqiblorf-alpha", "zqiblorf-beta"])
    text = "zqiblorf-alpha zqiblorf-alpha zqiblorf-beta"
    hits, = scanner.scan_payload([["file/a.txt", text]])
    assert_equal 1, hits.length
    assert_equal 3, hits.first.count
  end

  # sabotage: drop Regexp::IGNORECASE -> red
  def test_matching_is_case_insensitive
    scanner = scanner_for(["zqiblorf-secret"])
    hits, = scanner.scan_payload([["file/a.txt", "ZQIBLORF-SECRET shouted"]])
    assert_equal 1, hits.length
    assert_equal 1, hits.first.count
  end

  # sabotage: swap the probe to always return true, or to scan the wrong
  # string -> red
  def test_probe_passes_when_a_pattern_matches_the_control_term
    scanner = scanner_for(["zqiblorf-control-9001"], control_term: "zqiblorf-control-9001")
    assert scanner.probe
  end

  def test_probe_fails_when_no_pattern_matches_the_control_term
    scanner = scanner_for(["zqiblorf-unrelated"], control_term: "zqiblorf-control-9001")
    refute scanner.probe
  end

  # A location with zero matches contributes nothing to hits, but still
  # counts toward scanned_locations.
  def test_clean_payload_produces_no_hits_but_counts_locations
    scanner = scanner_for(["zqiblorf-secret"])
    hits, locations = scanner.scan_payload([["file/a.txt", "nothing to see"]])
    assert_empty hits
    assert_equal 1, locations
  end
end

class OutboundScanRunTest < Minitest::Test
  include UserConfigHelper

  def teardown
    UserConfig.reset!
  end

  def fixture_config(dir, patterns_file: nil, control_term: nil)
    section = {}
    section["patterns_file"] = patterns_file if patterns_file
    section["control_term"] = control_term if control_term
    with_user_config("outbound_scan" => section) { |config| yield config }
  end

  def write_patterns(dir, content)
    path = File.join(dir, "patterns.txt")
    File.write(path, content)
    path
  end

  # sabotage: default armed to true when the section is absent -> red
  def test_absent_section_is_disarmed_and_does_not_refuse
    with_user_config(nil) do |config|
      result = OutboundScan.run([], config: config)
      refute result.armed?
      refute result.refuse?
      assert_nil result.probe_ok
      assert_empty result.errors
    end
  end

  # sabotage: let a one-key section pass through to PatternSet.load instead
  # of blocking with scan_config_incomplete -> red
  def test_one_key_section_refuses_with_scan_config_incomplete
    with_user_config("outbound_scan" => { "patterns_file" => "/wherever" }) do |config|
      result = OutboundScan.run([], config: config)
      assert result.armed?
      assert result.refuse?
      assert_equal ["scan_config_incomplete"], result.errors.map { |e| e["code"] }
    end

    with_user_config("outbound_scan" => { "control_term" => "zqiblorf-control-9001" }) do |config|
      result = OutboundScan.run([], config: config)
      assert result.armed?
      assert result.refuse?
      assert_equal ["scan_config_incomplete"], result.errors.map { |e| e["code"] }
    end
  end

  # sabotage: swallow PatternSet.load's LoadError instead of surfacing its
  # code/message on the Result -> red
  def test_bad_patterns_file_refuses_with_the_loaders_error_code
    with_user_config(
      "outbound_scan" => { "patterns_file" => "/nonexistent/zqiblorf.txt", "control_term" => "zqiblorf-control-9001" }
    ) do |config|
      result = OutboundScan.run([], config: config)
      assert result.armed?
      assert result.refuse?
      assert_equal ["patterns_file_unreadable"], result.errors.map { |e| e["code"] }
    end
  end

  # sabotage: run the payload scan even when the probe fails, or skip
  # forcing refuse? true regardless of payload hits -> red
  def test_failed_probe_refuses_even_with_zero_payload_hits
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, "zqiblorf-unrelated-pattern")
      with_user_config(
        "outbound_scan" => { "patterns_file" => path, "control_term" => "zqiblorf-control-9001" }
      ) do |config|
        result = OutboundScan.run([["file/a.txt", "nothing here at all"]], config: config)
        assert result.armed?
        refute result.probe_ok
        assert result.refuse?
        assert_equal ["scan_pipeline_broken"], result.errors.map { |e| e["code"] }
        assert_empty result.hits
      end
    end
  end

  # sabotage: skip the probe when the payload already has hits (short
  # circuit) -> red; the probe must run on every scan, per the plan
  def test_good_config_probes_then_scans_and_reports_hits
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, "zqiblorf-control-9001\nzqiblorf-secret")
      with_user_config(
        "outbound_scan" => { "patterns_file" => path, "control_term" => "zqiblorf-control-9001" }
      ) do |config|
        result = OutboundScan.run([["file/a.txt", "has zqiblorf-secret in it"]], config: config)
        assert result.armed?
        assert result.probe_ok
        assert result.refuse?
        assert_equal 1, result.hits.length
        assert_equal "file/a.txt", result.hits.first.location
        assert_equal 1, result.hits.first.count
        assert_empty result.errors
      end
    end
  end

  def test_good_config_clean_payload_is_clean
    Dir.mktmpdir do |dir|
      path = write_patterns(dir, "zqiblorf-control-9001\nzqiblorf-secret")
      with_user_config(
        "outbound_scan" => { "patterns_file" => path, "control_term" => "zqiblorf-control-9001" }
      ) do |config|
        result = OutboundScan.run([["file/a.txt", "nothing guarded here"]], config: config)
        assert result.clean?
        refute result.refuse?
      end
    end
  end
end

class OutboundScanEnvelopeTest < Minitest::Test
  include UserConfigHelper

  def teardown
    UserConfig.reset!
  end

  # sabotage: warn instead of leaving the envelope untouched, or block, on a
  # disarmed result -> red
  def test_disarmed_result_warns_and_never_blocks
    with_user_config(nil) do |config|
      result = OutboundScan.run([], config: config)
      env = Envelope.new(script: "probe")
      OutboundScan.apply_to_envelope(result, env, path_label: "git")
      assert env.ok?
      assert_equal ["outbound_scan_disarmed"], env.warnings.map { |w| w[:code] }
      assert_empty env.blocked
      assert env.data.key?("outbound_scan")
    end
  end

  # sabotage: drop the block! call for hits, or fail to sum counts across
  # locations -> red
  def test_hits_block_with_a_count_and_location_summary
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "patterns.txt"), "zqiblorf-control-9001\nzqiblorf-secret")
      with_user_config(
        "outbound_scan" => {
          "patterns_file" => File.join(dir, "patterns.txt"),
          "control_term" => "zqiblorf-control-9001"
        }
      ) do |config|
        result = OutboundScan.run([["file/a.txt", "zqiblorf-secret zqiblorf-secret"]], config: config)
        env = Envelope.new(script: "probe")
        OutboundScan.apply_to_envelope(result, env, path_label: "git")
        refute env.ok?
        assert_equal ["outbound_scan_hit"], env.blocked.map { |b| b[:code] }
        assert_match(/2 outbound scan hit\(s\) in 1 location\(s\)/, env.blocked.first[:message])
      end
    end
  end

  # sabotage: forget to block! for each error code -> red
  def test_errors_block_with_their_own_code
    with_user_config("outbound_scan" => { "patterns_file" => "/nonexistent/zqiblorf.txt" }) do |config|
      result = OutboundScan.run([], config: config)
      env = Envelope.new(script: "probe")
      OutboundScan.apply_to_envelope(result, env, path_label: "tracker")
      refute env.ok?
      assert_equal ["scan_config_incomplete"], env.blocked.map { |b| b[:code] }
    end
  end

  # sabotage: only set env.data["outbound_scan"] on the armed/hit path,
  # skipping it when disarmed -> red
  def test_data_outbound_scan_is_always_set
    with_user_config(nil) do |config|
      result = OutboundScan.run([], config: config)
      env = Envelope.new(script: "probe")
      OutboundScan.apply_to_envelope(result, env, path_label: "git")
      assert_equal false, env.data["outbound_scan"]["armed"]
    end
  end
end

# The redaction tests. These are the load-bearing proof that the central
# security property (wu-be9) holds: no matched text, no pattern text, and no
# pattern-file content ever reaches a serialized Result or envelope. Both
# tests search the FULL serialized JSON, not individual fields, because a
# leak through a field neither test author anticipated is exactly the
# failure mode a spot check would miss.
class OutboundScanRedactionTest < Minitest::Test
  include UserConfigHelper

  def teardown
    UserConfig.reset!
  end

  # sabotage: add any field to Hit, or interpolate matched text anywhere in
  # Result#to_h or the envelope -> red
  def test_result_and_envelope_json_never_contain_the_token_or_the_pattern
    Dir.mktmpdir do |dir|
      token = "zqorbex-secret-fixture-8823"
      pattern_line = "zqorbex-secret-fixture-#{'[0-9]' * 3}"
      patterns_content = "# fixture pattern set, invented for this test only\nzqorbex-control-4471\n#{pattern_line}\n"
      File.write(File.join(dir, "patterns.txt"), patterns_content)

      with_user_config(
        "outbound_scan" => {
          "patterns_file" => File.join(dir, "patterns.txt"),
          "control_term" => "zqorbex-control-4471"
        }
      ) do |config|
        result = OutboundScan.run([["fixture/location.txt", "leading text #{token} trailing text"]], config: config)
        assert_equal 1, result.hits.length, "the fixture is expected to hit so this test proves something"

        env = Envelope.new(script: "probe")
        OutboundScan.apply_to_envelope(result, env, path_label: "git")

        result_json = result.to_h.to_json
        envelope_json = env.to_json

        refute_includes result_json, token
        refute_includes envelope_json, token
        refute_includes result_json, pattern_line
        refute_includes envelope_json, pattern_line
        refute_includes result_json, patterns_content
        refute_includes envelope_json, patterns_content
      end
    end
  end

  # sabotage: interpolate the rescued RegexpError's own message (which
  # quotes the offending source) instead of building a line-number-only
  # message -> red
  def test_unparseable_line_error_never_leaks_its_token
    Dir.mktmpdir do |dir|
      token = "zqorbex-unparseable-fixture-5591"
      File.write(File.join(dir, "patterns.txt"), "zqorbex-control-4471\n#{token}(unbalanced\n")

      with_user_config(
        "outbound_scan" => {
          "patterns_file" => File.join(dir, "patterns.txt"),
          "control_term" => "zqorbex-control-4471"
        }
      ) do |config|
        result = OutboundScan.run([], config: config)
        assert_equal ["patterns_file_unparseable"], result.errors.map { |e| e["code"] }
        refute_includes result.errors.first["message"], token

        env = Envelope.new(script: "probe")
        OutboundScan.apply_to_envelope(result, env, path_label: "git")
        refute_includes env.to_json, token
      end
    end
  end
end

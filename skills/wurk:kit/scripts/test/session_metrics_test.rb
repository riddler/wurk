# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require "time"
require_relative "../session_metrics"
require_relative "support/user_config_helper"

# Every transcript this suite reads is a synthetic fixture under
# fixtures/sessions/. A real transcript from the operator's own machine is a
# MANUAL check and never a fixture: committing one would put session content
# - prompts, file paths, whatever was pasted into a window - into this tree
# forever. The fixtures carry the shapes the parser must survive, which is
# all a test needs; realism beyond that is bought at a price nobody wants.
module SessionFixtures
  ROOT = File.expand_path(File.join(__dir__, "fixtures", "sessions"))
  TELEMETRY = File.expand_path(File.join(__dir__, "fixtures", "telemetry", "error-events.jsonl"))

  def fixture(project, name)
    File.join(ROOT, project, "#{name}.jsonl")
  end

  def session(project, name, since: nil)
    SessionMetrics.read_session(fixture(project, name), since: since)
  end

  # A root holding only the named fixtures, so a test that asserts on totals
  # is not reading every other fixture in the tree.
  def with_root(*pairs)
    Dir.mktmpdir("wurk-sessions-") do |dir|
      copy_fixtures(dir, pairs)
      yield dir
    end
  end

  # A root holding EVERY fixture in `project`, plus any extra [project, name]
  # pairs. The classification-availability guard only speaks over a window
  # of several transcripts, so its tests need a whole project rather than a
  # pair or two.
  def with_project_root(project, *pairs)
    all = Dir.glob(File.join(ROOT, project, "*.jsonl")).sort.map { |p| [project, File.basename(p, ".jsonl")] }
    Dir.mktmpdir("wurk-sessions-") do |dir|
      copy_fixtures(dir, all + pairs)
      yield dir
    end
  end

  def copy_fixtures(dir, pairs)
    pairs.each do |project, name|
      FileUtils.mkdir_p(File.join(dir, project))
      FileUtils.cp(fixture(project, name), File.join(dir, project, "#{name}.jsonl"))
    end
  end

  def run_cli(argv)
    io = StringIO.new
    code = SessionMetricsCli.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end
end

# Rule 1 and rule 2: which wall-clock gaps are stalls, and which are not.
class SessionMetricsGapTest < Minitest::Test
  include SessionFixtures

  # sabotage: drop the `next if seconds < STALL_FLOOR_SECONDS` guard -> red.
  # The 299s gap in the fixture is one second under the floor, so a floor
  # that is off by any amount in either direction changes this count.
  def test_a_gap_under_the_floor_is_not_a_stall
    stalls = session("boundary-project", "boundaries")["stalls"]
    refute_includes stalls.map { |s| s["seconds"] }, 299
  end

  # sabotage: raise STALL_CEILING_SECONDS past five hours, or drop the
  # ceiling branch -> red. The five-hour gap is a human closing the laptop
  # and resuming, and counting it makes an overnight break the biggest
  # incident in the window.
  def test_a_gap_over_the_ceiling_is_a_resumption_not_a_stall
    summary = session("boundary-project", "boundaries")
    assert_equal 1, summary["resumptions"]
    refute_includes summary["stalls"].map { |s| s["seconds"] }, 18_000
  end

  # sabotage: flip the comparison to `>` at the ceiling -> this stays green,
  # which is why the neighbouring test pins the exact boundary values below.
  def test_a_gap_between_floor_and_ceiling_is_a_stall
    summary = session("boundary-project", "boundaries")
    assert_equal [400], summary["stalls"].map { |s| s["seconds"] }
  end

  def test_the_floor_and_ceiling_are_the_documented_values
    assert_equal 300, SessionMetrics::STALL_FLOOR_SECONDS
    assert_equal 14_400, SessionMetrics::STALL_CEILING_SECONDS
  end

  # sabotage: drop the turn_start? branch from gap_counts -> red. The
  # fixture's 400s gap into a fresh user turn would join the stall list and
  # make "the session waited for a person" indistinguishable from "the
  # harness hung".
  def test_a_gap_ending_at_a_fresh_user_turn_is_idle_not_a_stall
    summary = session("boundary-project", "boundaries")
    assert_equal 1, summary["idle_between_turns"]
    assert_equal 1, summary["stalls"].length
  end

  # sabotage: make turn_start? test only `type == "user"` -> red. A user
  # record carrying tool_result blocks is the harness returning a tool's
  # output mid-turn, and the long gap in front of it is the one worth
  # seeing. This is the half of the rule that is easy to get backwards.
  def test_a_user_record_carrying_tool_results_is_mid_turn_and_counts
    summary = session("agent-project", "agent-stall")
    assert_equal 1, summary["stalls"].length
    assert_equal 900, summary["stalls"].first["seconds"]
    assert_equal 0, summary["idle_between_turns"]
  end

  def test_turn_start_distinguishes_the_two_user_record_shapes
    fresh = { "type" => "user", "message" => { "content" => [{ "type" => "text" }] } }
    mid = { "type" => "user", "message" => { "content" => [{ "type" => "tool_result" }] } }
    assert SessionMetrics.turn_start?(fresh)
    refute SessionMetrics.turn_start?(mid)
  end

  # sabotage: let CONVERSATION_TYPES include every record kind -> red once a
  # transcript carries editor or queue bookkeeping between two turns, which
  # would silently shrink every real gap.
  def test_only_conversation_records_participate_in_the_gap_pass
    assert_equal %w[user assistant system], SessionMetrics::CONVERSATION_TYPES
  end
end

# Rule 3: an agent's idle time is a stall; a person's is thinking.
class SessionMetricsClassificationTest < Minitest::Test
  include SessionFixtures

  # sabotage: classify on the presence of any user record instead of the
  # prompt source -> red.
  def test_a_typed_prompt_makes_the_session_interactive
    assert_equal "interactive", session("clean-project", "interactive-clean")["kind"]
  end

  def test_a_session_with_no_human_prompt_source_is_an_agent_session
    assert_equal "agent", session("agent-project", "agent-stall")["kind"]
  end

  # sabotage: reverse the asymmetry so an absent promptSource counts as
  # automation -> red. An older transcript that never wrote the field must
  # not be reclassified into a stall source on the strength of a missing key,
  # because that manufactures signals out of somebody's lunch break.
  def test_an_absent_prompt_source_is_read_as_human
    records = [{ "type" => "user", "message" => { "content" => [{ "type" => "text" }] } }]
    assert_equal "interactive", SessionMetrics.classify(records)
  end

  def test_a_transcript_with_no_turns_at_all_is_interactive
    assert_equal "interactive", SessionMetrics.classify([])
  end

  # sabotage: drop the isSidechain clause from gap_kind -> red. A subagent
  # running inside an interactive session is still an agent, and its stalls
  # are real ones even though a human owns the window.
  def test_a_sidechain_gap_is_an_agent_gap_inside_an_interactive_session
    summary = session("sidechain-project", "sidechain")
    assert_equal "interactive", summary["kind"]
    assert_equal 1, summary["agent_stalls"]
    assert_equal 0, summary["interactive_stalls"]
  end

  # sabotage: fold the two stall counts into one -> red. The whole point of
  # rule 3 is that they are reported apart.
  def test_agent_and_interactive_stalls_are_counted_separately
    summary = session("agent-project", "agent-stall")
    assert_equal 1, summary["agent_stalls"]
    assert_equal 0, summary["interactive_stalls"]
  end
end

# Rule 3 can go blind without failing: the fields it classifies on are
# written by the transcript writer, not by this kit.
class SessionMetricsClassificationAvailabilityTest < Minitest::Test
  include SessionFixtures
  include UserConfigHelper

  # sabotage: check the VALUE of promptSource rather than its presence ->
  # red. An agent session's "system" prompt source is evidence that the
  # writer still emits the field, which is the only thing being asked.
  def test_any_prompt_source_at_all_counts_as_evidence
    assert SessionMetrics.classification_evidence?([{ "promptSource" => "system" }])
    assert SessionMetrics.classification_evidence?([{ "promptSource" => "typed" }])
  end

  def test_a_sidechain_marker_counts_as_evidence
    assert SessionMetrics.classification_evidence?([{ "isSidechain" => true }])
    refute SessionMetrics.classification_evidence?([{ "isSidechain" => false }])
  end

  def test_a_transcript_with_neither_field_carries_no_evidence
    records = [{ "type" => "user", "message" => { "content" => [{ "type" => "text" }] } }]
    refute SessionMetrics.classification_evidence?(records)
  end

  # sabotage: drop the guard, or emit it as a signal item instead of a
  # warning -> red. `signals` answers a blind window with the same empty
  # list a healthy one produces, and this warning is the only thing in the
  # envelope that tells those two apart.
  def test_a_window_with_no_classification_evidence_warns_on_signals
    with_user_config(nil) do
      with_project_root("blind-project") do |dir|
        code, envelope = run_cli(["signals", "--dir", dir])
        assert_equal 0, code
        assert envelope["ok"]
        assert_equal [], envelope["data"]["signals"]
        warning = envelope["warnings"].find { |w| w["code"] == "agent_classification_unavailable" }
        refute_nil warning
        assert_match(/5 transcripts/, warning["message"])
        assert_match(/promptSource/, warning["message"])
        assert_match(/re-verify the classification rule/, warning["message"])
      end
    end
  end

  def test_the_same_window_warns_on_report
    with_user_config(nil) do
      with_project_root("blind-project") do |dir|
        _code, envelope = run_cli(["report", "--dir", dir])
        assert_includes envelope["warnings"].map { |w| w["code"] }, "agent_classification_unavailable"
      end
    end
  end

  # sabotage: warn when SOME transcript lacks the field rather than when
  # none carries it -> red. One transcript that still carries promptSource
  # proves the writer is emitting it, whatever the rest of the window looks
  # like.
  def test_one_transcript_carrying_the_field_suppresses_the_warning
    with_user_config(nil) do
      with_project_root("blind-project", %w[agent-project agent-stall]) do |dir|
        _code, envelope = run_cli(["signals", "--dir", dir])
        refute_includes envelope["warnings"].map { |w| w["code"] }, "agent_classification_unavailable"
      end
    end
  end

  def test_an_interactive_transcript_also_suppresses_the_warning
    with_user_config(nil) do
      with_project_root("blind-project", %w[clean-project interactive-clean]) do |dir|
        _code, envelope = run_cli(["report", "--dir", dir])
        refute_includes envelope["warnings"].map { |w| w["code"] }, "agent_classification_unavailable"
      end
    end
  end

  # sabotage: drop the minimum-sample guard -> red. A window of one or two
  # unmarked transcripts is ordinary - an old file, a hand-made one - and
  # warning on it would make the guard noise that gets ignored exactly when
  # it fires for real.
  def test_a_window_under_the_minimum_sample_does_not_warn
    assert_equal 5, SessionMetrics::CLASSIFICATION_MIN_TRANSCRIPTS
    with_user_config(nil) do
      with_root(%w[blind-project blind-1], %w[blind-project blind-2]) do |dir|
        _code, envelope = run_cli(["signals", "--dir", dir])
        refute_includes envelope["warnings"].map { |w| w["code"] }, "agent_classification_unavailable"
      end
    end
  end

  # sabotage: fold the evidence into the per-session summary -> red. The
  # next reader of this data shape is a rollup that has no use for it, and
  # the guard's answer is about the transcript writer rather than about any
  # window's numbers.
  def test_the_evidence_pass_leaves_the_session_summary_shape_alone
    summary = SessionMetrics.read_session(fixture("blind-project", "blind-1"), evidence: [])
    refute_includes summary.keys, "classification_evidence"
  end

  def test_the_evidence_array_gets_one_entry_per_transcript_read
    evidence = []
    SessionMetrics.read_session(fixture("blind-project", "blind-1"), evidence: evidence)
    SessionMetrics.read_session(fixture("agent-project", "agent-stall"), evidence: evidence)
    assert_equal [false, true], evidence
  end
end

# Counting: tools, failures, skills, tokens.
class SessionMetricsCountingTest < Minitest::Test
  include SessionFixtures

  def test_tool_calls_are_counted_by_name
    summary = session("failure-project", "failures")
    assert_equal({ "Read" => 3, "Bash" => 2 }, summary["tool_calls"])
    assert_equal 5, summary["tool_calls_total"]
  end

  # sabotage: count `is_error` as truthy rather than exactly true -> this
  # stays green; the fixture pins the false case instead.
  def test_only_is_error_true_counts_as_a_failure
    summary = session("failure-project", "failures")
    assert_equal 5, summary["tool_results"]
    assert_equal 2, summary["tool_errors"]
    assert_equal 0.4, summary["tool_failure_rate"]
  end

  def test_a_session_with_no_results_has_a_nil_failure_rate
    assert_nil SessionMetrics.rate(0, 0)
  end

  def test_skills_are_counted_by_the_name_the_call_carries
    assert_equal({ "example:skill" => 1 }, session("clean-project", "interactive-clean")["skills"])
  end

  def test_tokens_are_bucketed_per_model
    tokens = session("clean-project", "interactive-clean")["tokens"]
    assert_equal({ "input" => 2200, "output" => 600, "cache_creation" => 400, "cache_read" => 8000 },
                 tokens["test-model-a"])
  end

  def test_counts_sort_descending_so_two_runs_agree_byte_for_byte
    assert_equal %w[Read Bash], session("failure-project", "failures")["tool_calls"].keys
  end
end

# Defensive parsing: a transcript is an append-only log written by a program
# that ships faster than this one.
class SessionMetricsParsingTest < Minitest::Test
  include SessionFixtures

  # sabotage: let parse_line raise instead of returning nil -> red.
  def test_malformed_lines_are_counted_and_skipped
    summary = session("malformed-project", "malformed")
    assert_equal 2, summary["malformed_lines"]
    assert_equal 4, summary["records"]
  end

  def test_unknown_fields_and_block_kinds_are_ignored
    summary = session("malformed-project", "malformed")
    assert_equal({ "Bash" => 1 }, summary["tool_calls"])
  end

  def test_a_string_message_body_is_not_a_content_array
    assert_equal [], SessionMetrics.content_blocks("message" => { "content" => "a plain string" })
  end

  # sabotage: drop the rescue in record_time -> red. One unparseable stamp
  # in a 40MB transcript must not end the run.
  def test_an_unparseable_timestamp_drops_out_of_the_gap_pass
    assert_nil SessionMetrics.record_time("timestamp" => "not-a-timestamp")
    assert_equal [], session("malformed-project", "malformed")["stalls"]
  end

  def test_the_session_id_falls_back_to_the_filename
    assert_equal "no-id", SessionMetrics.session_id("/tmp/x/no-id.jsonl", [{ "type" => "user" }])
  end

  def test_since_drops_records_older_than_the_window
    summary = session("clean-project", "interactive-clean", since: Time.parse("2026-09-16T10:15:00Z"))
    assert_equal 2, summary["records"]
    assert_equal 0, summary["idle_between_turns"]
  end
end

# Cost: derived from the machine config's price table, or not at all.
class SessionMetricsCostTest < Minitest::Test
  include SessionFixtures

  PRICES = {
    "test-model-a" => { "input" => 3.0, "output" => 15.0, "cache_write" => 3.75, "cache_read" => 0.3 }
  }.freeze

  # sabotage: give the kit a default price table -> red. The kit ships no
  # prices: they move, they differ per account, and a number checked in here
  # is a number that is silently wrong later.
  def test_an_absent_price_table_means_cost_is_null_never_a_guess
    tokens = { "test-model-a" => { "input" => 1000, "output" => 100, "cache_creation" => 0, "cache_read" => 0 } }
    cost = SessionMetrics.cost(tokens, {})
    assert_nil cost["total"]
    refute cost["priced"]
  end

  # sabotage: give UserConfig a default price table -> red. The kit ships no
  # prices: they move, they differ per account, and a number checked in here
  # is one that goes silently stale.
  def test_the_kit_ships_no_default_price_table
    config = UserConfig.new(path: "(fixture)", raw: {}, exists: false)
    assert_equal({}, config.metrics_prices)
    assert_empty UserConfig::DEFAULTS.keys.select { |k| k.start_with?("metrics") }
  end

  def test_a_priced_model_costs_tokens_times_the_table
    tokens = { "test-model-a" => { "input" => 1_000_000, "output" => 0, "cache_creation" => 0, "cache_read" => 0 } }
    assert_equal 3.0, SessionMetrics.cost(tokens, PRICES)["total"]
  end

  # sabotage: price the models you can and skip the rest -> red. A partial
  # total reads like a whole one.
  def test_one_unpriced_model_makes_the_total_null
    tokens = {
      "test-model-a" => { "input" => 1_000_000, "output" => 0, "cache_creation" => 0, "cache_read" => 0 },
      "test-model-b" => { "input" => 1_000_000, "output" => 0, "cache_creation" => 0, "cache_read" => 0 }
    }
    cost = SessionMetrics.cost(tokens, PRICES)
    assert_nil cost["total"]
    assert_equal ["test-model-b"], cost["unpriced_models"]
    assert_equal 3.0, cost["by_model"]["test-model-a"]
  end

  # sabotage: treat a missing component as zero -> red when the bucket has
  # tokens in it.
  def test_a_bucket_with_tokens_and_no_price_component_is_unpriced
    tokens = { "m" => { "input" => 0, "output" => 5, "cache_creation" => 0, "cache_read" => 0 } }
    assert_nil SessionMetrics.cost(tokens, "m" => { "input" => 3.0 })["by_model"]["m"]
  end

  def test_an_empty_bucket_needs_no_price_component
    tokens = { "m" => { "input" => 1_000_000, "output" => 0, "cache_creation" => 0, "cache_read" => 0 } }
    assert_equal 3.0, SessionMetrics.cost(tokens, "m" => { "input" => 3.0 })["total"]
  end
end

# The telemetry sink, which does not exist yet.
class SessionMetricsErrorEventsTest < Minitest::Test
  include SessionFixtures

  # sabotage: make the sink read assume the file exists -> red. The hook that
  # writes it ships after this script, so "configured but not yet written" is
  # the normal state and must not be a fault.
  def test_a_configured_sink_that_does_not_exist_yet_reads_as_zero
    events = SessionMetrics.error_events("/nonexistent/telemetry/error-events.jsonl")
    refute events["exists"]
    assert_equal 0, events["count"]
  end

  def test_no_configured_sink_reads_as_zero
    assert_equal 0, SessionMetrics.error_events(nil)["count"]
  end

  def test_only_error_level_events_are_counted
    events = SessionMetrics.error_events(TELEMETRY)
    assert events["exists"]
    assert_equal 2, events["count"]
    assert_equal 1, events["malformed_lines"]
  end

  def test_since_filters_the_sink_too
    events = SessionMetrics.error_events(TELEMETRY, since: Time.parse("2026-09-16T16:02:00Z"))
    assert_equal 1, events["count"]
  end
end

# The CLI: report, signals, and the envelope contract.
class SessionMetricsCliTest < Minitest::Test
  include SessionFixtures
  include UserConfigHelper

  # sabotage: emit a signal for an interactive stall -> red. This is the
  # whole promise of the subcommand: a healthy window emits nothing, so a
  # scheduler that polls it can route on a non-empty list.
  def test_signals_is_empty_on_a_clean_fixture
    with_user_config(nil) do
      with_root(%w[clean-project interactive-clean]) do |dir|
        code, envelope = run_cli(["signals", "--dir", dir])
        assert_equal 0, code
        assert envelope["ok"]
        assert_equal [], envelope["data"]["signals"]
      end
    end
  end

  def test_an_agent_stall_is_a_signal
    with_user_config(nil) do
      with_root(%w[agent-project agent-stall]) do |dir|
        _code, envelope = run_cli(["signals", "--dir", dir])
        signal = envelope["data"]["signals"].first
        assert_equal "agent_stall", signal["kind"]
        assert_equal 900, signal["longest_seconds"]
      end
    end
  end

  # sabotage: drop the minimum-sample guard -> stays green here; the next
  # test pins the guard.
  def test_a_failure_rate_over_the_threshold_is_a_signal
    with_user_config(nil) do
      with_root(%w[failure-project failures]) do |dir|
        _code, envelope = run_cli(["signals", "--dir", dir])
        kinds = envelope["data"]["signals"].map { |s| s["kind"] }
        assert_equal ["tool_failure_rate"], kinds
      end
    end
  end

  # sabotage: lower FAILURE_RATE_MIN_RESULTS to 1 -> red. One error out of
  # two calls is a 50% failure rate and means nothing.
  def test_a_high_rate_over_too_few_results_is_not_a_signal
    assert_equal 5, SessionMetrics::FAILURE_RATE_MIN_RESULTS
    assert_equal 0.20, SessionMetrics::FAILURE_RATE_THRESHOLD
    summary = { "tool_results" => 2, "tool_errors" => 2, "tool_failure_rate" => 1.0,
                "stalls" => [], "session" => "s", "project" => "p" }
    assert_equal [], SessionMetrics.signals([summary], "count" => 0)
  end

  def test_sink_events_become_a_signal
    with_user_config("metrics" => { "error_events" => TELEMETRY }) do
      with_root(%w[clean-project interactive-clean]) do |dir|
        _code, envelope = run_cli(["signals", "--dir", dir])
        signal = envelope["data"]["signals"].first
        assert_equal "error_events", signal["kind"]
        assert_equal 2, signal["count"]
      end
    end
  end

  def test_report_carries_totals_and_per_session_rows
    with_user_config(nil) do
      with_root(%w[clean-project interactive-clean], %w[agent-project agent-stall]) do |dir|
        code, envelope = run_cli(["report", "--dir", dir])
        assert_equal 0, code
        totals = envelope["data"]["totals"]
        assert_equal 2, totals["sessions"]
        assert_equal 1, totals["agent_sessions"]
        assert_equal 1, totals["interactive_sessions"]
        assert_equal 1, totals["agent_stalls"]
        assert_equal 2, envelope["data"]["sessions"].length
      end
    end
  end

  def test_report_warns_and_nulls_cost_with_no_price_table
    with_user_config(nil) do
      with_root(%w[clean-project interactive-clean]) do |dir|
        _code, envelope = run_cli(["report", "--dir", dir])
        assert_nil envelope["data"]["cost"]["total"]
        assert_includes envelope["warnings"].map { |w| w["code"] }, "cost_unavailable"
      end
    end
  end

  def test_report_prices_the_window_when_the_machine_quotes_prices
    prices = { "test-model-a" => { "input" => 3.0, "output" => 15.0, "cache_write" => 3.75, "cache_read" => 0.3 } }
    with_user_config("metrics" => { "prices" => prices }) do
      with_root(%w[clean-project interactive-clean]) do |dir|
        _code, envelope = run_cli(["report", "--dir", dir])
        assert_equal 0.0195, envelope["data"]["cost"]["total"]
        refute_includes envelope["warnings"].map { |w| w["code"] }, "cost_unavailable"
      end
    end
  end

  def test_max_sessions_truncates_the_rows_and_says_so
    with_user_config(nil) do
      with_root(%w[clean-project interactive-clean], %w[agent-project agent-stall]) do |dir|
        _code, envelope = run_cli(["report", "--dir", dir, "--max-sessions", "1"])
        assert_equal 1, envelope["data"]["sessions"].length
        assert_equal 2, envelope["data"]["totals"]["sessions"]
        assert_includes envelope["warnings"].map { |w| w["code"] }, "sessions_truncated"
      end
    end
  end

  def test_a_missing_transcripts_root_is_a_warning_not_a_block
    with_user_config(nil) do
      code, envelope = run_cli(["report", "--dir", "/nonexistent/projects"])
      assert_equal 0, code
      assert envelope["ok"]
      assert_includes envelope["warnings"].map { |w| w["code"] }, "transcripts_root_missing"
    end
  end

  def test_a_named_file_that_is_missing_blocks
    with_user_config(nil) do
      code, envelope = run_cli(["report", "--file", "/nonexistent/one.jsonl"])
      assert_equal 1, code
      assert_equal ["transcript_missing"], envelope["blocked"].map { |b| b["code"] }
    end
  end

  def test_an_unparseable_since_blocks
    with_user_config(nil) do
      code, envelope = run_cli(["report", "--since", "yesterday-ish"])
      assert_equal 1, code
      assert_equal ["since_unparseable"], envelope["blocked"].map { |b| b["code"] }
    end
  end

  def test_malformed_lines_are_reported_as_a_warning
    with_user_config(nil) do
      with_root(%w[malformed-project malformed]) do |dir|
        _code, envelope = run_cli(["report", "--dir", dir])
        assert_includes envelope["warnings"].map { |w| w["code"] }, "malformed_lines"
      end
    end
  end

  # sabotage: emit a transcript's text into data -> red. The envelope is
  # read by a conductor and may land in a journal; what leaves here is names
  # and numbers, never session content.
  def test_no_session_content_reaches_the_envelope
    with_user_config(nil) do
      with_root(%w[clean-project interactive-clean]) do |dir|
        _code, envelope = run_cli(["report", "--dir", dir])
        refute_includes JSON.generate(envelope), "(redacted)"
      end
    end
  end

  def test_an_unknown_subcommand_exits_two_without_an_envelope
    assert_raises(SystemExit) { run_cli(["summarise"]) }
  end
end

# The machine-config seam this script reads.
class SessionMetricsUserConfigTest < Minitest::Test
  include UserConfigHelper

  def test_prices_default_to_an_empty_table
    with_user_config(nil) do |config|
      assert_equal({}, config.metrics_prices)
      refute config.metrics_prices?
      assert_nil config.metrics_error_events_path
    end
  end

  def test_a_price_table_is_read_back_whole
    prices = { "m" => { "input" => 3.0, "output" => 15.0 } }
    with_user_config("metrics" => { "prices" => prices }) do |config|
      assert config.valid?
      assert config.metrics_prices?
      assert_equal 3.0, config.metrics_prices["m"]["input"]
    end
  end

  # sabotage: make a malformed price a warning instead of an error -> red.
  # A price that is a string or negative travels into a dollar figure a
  # human reads and believes; an unknown component name is inert.
  def test_a_malformed_price_blocks
    with_user_config("metrics" => { "prices" => { "m" => { "input" => "three dollars" } } }) do |config|
      refute config.valid?
      assert_match(/metrics\.prices\.m\.input/, config.errors.first)
    end
  end

  def test_a_negative_price_blocks
    with_user_config("metrics" => { "prices" => { "m" => { "input" => -1 } } }) do |config|
      refute config.valid?
    end
  end

  def test_an_empty_price_entry_blocks
    with_user_config("metrics" => { "prices" => { "m" => {} } }) do |config|
      refute config.valid?
    end
  end

  def test_an_unknown_price_component_warns
    with_user_config("metrics" => { "prices" => { "m" => { "input" => 1, "thinking" => 2 } } }) do |config|
      assert config.valid?
      assert_match(/thinking/, config.warnings.first)
    end
  end

  # sabotage: add "metrics.prices" to KNOWN -> red. Model ids are data, not
  # schema, and every model the operator prices would warn as unknown.
  def test_a_model_id_is_not_an_unknown_key
    with_user_config("metrics" => { "prices" => { "some-model-id" => { "input" => 1 } } }) do |config|
      assert_empty config.warnings
    end
  end

  def test_an_unknown_metrics_key_still_warns
    with_user_config("metrics" => { "nope" => 1 }) do |config|
      assert config.valid?
      assert_match(/metrics\.nope/, config.warnings.first)
    end
  end

  def test_a_blank_sink_path_blocks
    with_user_config("metrics" => { "error_events" => "  " }) do |config|
      refute config.valid?
    end
  end

  def test_the_cli_reports_priced_models_without_reporting_prices
    with_user_config(nil) do
      io = StringIO.new
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".claude"))
        File.write(File.join(dir, ".claude", "wurk.local.json"),
                   JSON.generate("metrics" => { "prices" => { "m" => { "input" => 3.0 } } }))
        UserConfigCli.run(["check", "--file", File.join(dir, ".claude", "wurk.local.json")], io: io)
      end
      envelope = JSON.parse(io.string)
      assert_equal ["m"], envelope["data"]["metrics_priced_models"]
      refute_includes io.string, "3.0"
    end
  end
end

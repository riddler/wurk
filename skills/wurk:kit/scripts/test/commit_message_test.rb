# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../commit_message"
require_relative "support/manifest_helper"

# CommitMessage.check (pure function).
#
# The limits are driven from the `commits` fixture (subject under 30, body
# lines at most 60, at most 12 lines, trailer key `Closes`) rather than from
# this repo's own 50/72/40/`Refs` - a test written against the latter passes
# whether or not the check reads the manifest, and a project on a different
# trailer scheme is exactly the case the parameterization exists for.
class CommitMessageLibTest < Minitest::Test
  include ManifestHelper

  FIXTURE = "commits"

  def teardown
    Manifest.reset!
  end

  def check(text, refs: nil)
    CommitMessage.check(text, refs: refs, manifest: fixture_manifest(FIXTURE))
  end

  def test_a_clean_message_with_no_refs_required_passes_every_rule
    message = <<~MSG
      Adds exit set computation

      - Ports compute_exit_set per Appendix D
      - Handles cross-boundary exits
    MSG

    checks = check(message)

    assert checks.all? { |c| c[:ok] }, checks.inspect
    refute_includes checks.map { |c| c[:rule] }, "refs_present_and_last"
  end

  # sabotage: restore a hardcoded SUBJECT_MAX = 49 -> a 30-char subject
  # passes and this goes red
  def test_a_subject_at_the_configured_bound_fails
    subject = "A" * 30
    checks = check(subject)

    refute check_for(checks, "subject_length")[:ok]
  end

  # subject_under is exclusive, so the longest legal subject is one shy
  def test_a_subject_one_under_the_configured_bound_passes
    subject = "A" * 29
    checks = check(subject)

    assert check_for(checks, "subject_length")[:ok]
  end

  def test_empty_subject_fails
    checks = check("\n\nbody\n")

    refute check_for(checks, "subject_length")[:ok]
  end

  # sabotage: restore a hardcoded BODY_LINE_MAX = 72 -> a 61-char line
  # passes and this goes red
  def test_a_body_line_over_the_configured_maximum_fails
    message = "Adds a thing\n\n#{'x' * 61}\n"
    checks = check(message)

    refute check_for(checks, "body_line_length")[:ok]
  end

  def test_a_body_line_at_the_configured_maximum_passes
    message = "Adds a thing\n\n#{'x' * 60}\n"
    checks = check(message)

    assert check_for(checks, "body_line_length")[:ok]
  end

  # sabotage: restore a hardcoded TOTAL_LINES_MAX = 40 -> 13 lines pass
  # and this goes red
  def test_a_message_over_the_configured_line_count_fails
    message = "Adds a thing\n" + (["- line"] * 13).join("\n")
    checks = check(message)

    refute check_for(checks, "total_lines")[:ok]
  end

  def test_a_message_within_the_configured_line_count_passes
    message = "Adds a thing\n" + (["- line"] * 5).join("\n")
    checks = check(message)

    assert check_for(checks, "total_lines")[:ok]
  end

  def test_the_trailer_check_is_absent_when_no_id_is_given
    checks = check("Adds a thing\n")

    assert_nil check_for(checks, "refs_present_and_last")
  end

  # sabotage: hardcode /\ARefs: / back into the trailer regex -> a `Closes:`
  # trailer stops matching and this goes red. The key is a SCHEME, not a
  # number: a project projecting beads onto forge issues writes
  # "Closes #12".
  def test_the_configured_trailer_key_passes_when_it_matches_and_is_last
    message = <<~MSG
      Adds a thing

      - detail

      Closes: zz-abc
    MSG

    checks = check(message, refs: "zz-abc")

    assert check_for(checks, "refs_present_and_last")[:ok]
  end

  def test_a_missing_trailer_fails
    checks = check("Adds a thing\n\n- detail\n", refs: "zz-abc")

    refute check_for(checks, "refs_present_and_last")[:ok]
  end

  def test_a_trailer_that_is_not_last_fails
    message = <<~MSG
      Adds a thing

      Closes: zz-abc

      - detail added after the trailer
    MSG

    checks = check(message, refs: "zz-abc")

    refute check_for(checks, "refs_present_and_last")[:ok]
  end

  def test_a_trailer_naming_the_wrong_id_fails
    checks = check("Adds a thing\n\nCloses: zz-other\n", refs: "zz-abc")

    refute check_for(checks, "refs_present_and_last")[:ok]
  end

  def test_co_authored_by_is_detected
    checks = check("Adds a thing\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n")

    refute check_for(checks, "no_attribution")[:ok]
  end

  def test_generated_with_is_detected
    checks = check("Adds a thing\n\nGenerated with Claude Code\n")

    refute check_for(checks, "no_attribution")[:ok]
  end

  def test_bare_claude_mention_is_detected
    checks = check("Adds a thing\n\nWritten by Claude\n")

    refute check_for(checks, "no_attribution")[:ok]
  end

  def test_no_attribution_passes_a_clean_message
    checks = check("Adds a thing\n\n- detail\n")

    assert check_for(checks, "no_attribution")[:ok]
  end

  private

  def check_for(checks, rule)
    checks.find { |c| c[:rule] == rule }
  end
end

# CommitMessageCli (the stdin-reading, envelope-emitting shell).
class CommitMessageCliTest < Minitest::Test
  include ManifestHelper

  FIXTURE = "commits"

  def teardown
    Manifest.reset!
  end

  def run_check(argv, message)
    io = StringIO.new
    stdin = StringIO.new(message)
    code = nil
    with_manifest(FIXTURE) { code = CommitMessageCli.run(argv, io: io, stdin: stdin) }
    [code, JSON.parse(io.string)]
  end

  def test_a_clean_message_exits_0_and_reports_ok_true
    code, result = run_check([], "Adds a thing\n\n- detail\n")

    assert_equal 0, code
    assert result["ok"]
  end

  def test_check_subcommand_is_accepted_and_behaves_identically
    code, result = run_check(["check"], "Adds a thing\n\n- detail\n")

    assert_equal 0, code
    assert result["ok"]
  end

  # The Success Criteria fixture from the plan, restated against the
  # fixture's limits: an over-long subject, an over-long body line, too many
  # lines, a missing trailer, and a Co-Authored-By line - every rule should
  # fail at once.
  def test_kitchen_sink_bad_message_is_rejected_with_every_rule_named
    subject = "A" * 40
    long_line = "x" * 80
    body_lines = (["- detail"] * 10)
    message = ([subject, "", long_line] + body_lines + ["Co-Authored-By: Claude <noreply@anthropic.com>"]).join("\n") + "\n"

    code, result = run_check(["--refs", "zz-abc"], message)

    assert_equal 1, code
    refute result["ok"]

    failing_rules = result["data"]["checks"].reject { |c| c["ok"] }.map { |c| c["rule"] }
    assert_includes failing_rules, "subject_length"
    assert_includes failing_rules, "body_line_length"
    assert_includes failing_rules, "total_lines"
    assert_includes failing_rules, "refs_present_and_last"
    assert_includes failing_rules, "no_attribution"

    blocked_codes = result["blocked"].map { |b| b["code"] }
    assert_includes blocked_codes, "no_attribution"
  end

  def test_refs_not_required_when_the_flag_is_omitted_even_if_absent
    code, result = run_check([], "Adds a thing\n\n- detail\n")

    assert_equal 0, code
    refute result["data"]["checks"].any? { |c| c["rule"] == "refs_present_and_last" }
    refute result["data"]["refs_required"]
  end

  def test_commands_stays_empty_this_script_never_shells_out
    _code, result = run_check([], "Adds a thing\n")

    assert_equal [], result["commands"]
  end
end

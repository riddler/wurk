# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../plan_state"
require_relative "support/manifest_helper"

# PlanState (pure parsing/mutation logic over an array of lines).
class PlanStateLibTest < Minitest::Test
  include ManifestHelper

  FIXTURES = File.expand_path(File.join(__dir__, "fixtures", "plans"))
  # A frozen copy of a real, completed plan document. It was the donor
  # repo's own live plan while the scripts lived there, parsed in place so a
  # synthetic copy could not go stale against the real grammar. That path
  # does not exist from wurk, so the document is snapshotted into the
  # fixtures instead - see the header comment in the file. What is lost is
  # the staleness alarm; what is kept is the only full-scale grammar case
  # the suite has (12 phases, wrapped manual items, every mandatory
  # heading).
  REAL_PLAN = File.join(FIXTURES, "real_grammar_snapshot.md")

  # PlanState.parse reaches Refs.bead_id, which reads the manifest. In the
  # donor repo the walk-up silently found the real wurk.json; here there is
  # none, which is the convention working as intended - drive it from a
  # fixture.
  def setup
    @manifest_restore = Manifest.instance_variable_get(:@current)
    Manifest.current = fixture_manifest("valid")
  end

  def teardown
    Manifest.current = @manifest_restore
  end

  def read_fixture(name)
    File.read(File.join(FIXTURES, name))
  end

  # --- the full-scale snapshot fixture (see REAL_PLAN above) ---

  def test_parses_the_real_plan_document_with_no_sections_missing
    result = PlanState.parse(File.read(REAL_PLAN))

    assert_equal [], result[:sections_missing]
    assert_equal "zz-hzf", result[:bead_id]
    assert_equal (1..12).to_a, result[:phases].map { |p| p[:n] }
  end

  # The snapshot was taken with all 12 phases landed (the loop mode checks
  # off each phase's Automated Verification boxes as it completes them, and
  # this document was live while that happened). This test asserts the
  # invariant rather than a specific phase number, so it keeps passing
  # whether the plan is still in progress (next_phase present, every prior
  # phase complete, next_phase itself not yet complete) or fully landed
  # (next_phase nil, every phase complete) - the last phase this plan has
  # is exactly the case where nil is correct, not a bug to work around.
  def test_real_plan_document_every_phase_up_to_next_phase_is_complete
    result = PlanState.parse(File.read(REAL_PLAN))
    by_n = result[:phases].each_with_object({}) { |p, h| h[p[:n]] = p }

    next_phase = result[:next_phase]
    if next_phase.nil?
      by_n.each_value { |p| assert p[:complete], "Phase #{p[:n]} should be complete" }
    else
      (1...next_phase).each { |n| assert by_n[n][:complete], "Phase #{n} should be complete" }
      refute by_n[next_phase][:complete], "Phase #{next_phase} (next_phase) should not be complete yet"
    end
  end

  def test_real_plan_document_has_a_deferred_manual_verification_section
    result = PlanState.parse(File.read(REAL_PLAN))

    assert result[:deferred_manual_section][:present]
    assert_kind_of Integer, result[:deferred_manual_section][:line]
  end

  # --- a fixture with a Deferred Manual Verification section already present ---

  def test_deferred_present_fixture_is_recognized
    result = PlanState.parse(read_fixture("deferred_present.md"))

    assert_equal [], result[:sections_missing]
    assert result[:deferred_manual_section][:present]
    assert_equal 2, result[:phases].length
  end

  # --- a phase with zero Manual items ---

  def test_zero_manual_items_phase_reports_empty_manual_section
    result = PlanState.parse(read_fixture("zero_manual.md"))
    phase = result[:phases].first

    assert_equal 0, phase[:manual][:total]
    assert_equal [], phase[:manual][:items]
    refute phase[:complete] # its automated boxes are unchecked
  end

  # --- a plan missing a mandatory section ---

  def test_missing_section_fixture_reports_the_missing_section
    result = PlanState.parse(read_fixture("missing_section.md"))

    assert_equal ["References"], result[:sections_missing]
  end

  def test_missing_title_is_detected
    text = read_fixture("missing_section.md").sub(/\A# .+\n/, "")
    result = PlanState.parse(text)

    assert_includes result[:sections_missing], "title"
  end

  # --- checkbox parsing details ---

  def test_manual_items_include_wrapped_continuation_lines
    text = <<~MD
      # T Implementation Plan

      ## Overview

      Beads issue: `zz-abc`

      ## Current State Analysis

      x

      ## Desired End State

      x

      ## What We're NOT Doing

      x

      ## Implementation Approach

      x

      ## Phase 1: One

      #### Automated Verification:
      - [ ] a

      #### Manual Verification:
      - [ ] wraps onto
            a second physical line

      ## Testing Strategy

      x

      ## References

      x
    MD

    result = PlanState.parse(text)
    phase = result[:phases].first

    assert_equal ["wraps onto a second physical line"], phase[:manual][:items]
  end
end

# PlanStateCli (the file-mutating CLI), driven through tmpdir copies of the
# fixtures - never against a document anyone is still editing.
class PlanStateCliTest < Minitest::Test
  include ManifestHelper

  FIXTURES = File.expand_path(File.join(__dir__, "fixtures", "plans"))

  def setup
    @dir = Dir.mktmpdir
    @manifest_restore = Manifest.instance_variable_get(:@current)
    Manifest.current = fixture_manifest("valid")
  end

  def teardown
    Manifest.current = @manifest_restore
    FileUtils.remove_entry(@dir)
  end

  def copy_fixture(name)
    dest = File.join(@dir, name)
    FileUtils.cp(File.join(FIXTURES, name), dest)
    dest
  end

  def run_cli(argv)
    io = StringIO.new
    code = PlanStateCli.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  # --- validate (default subcommand) --------------------------------------

  def test_bare_path_behaves_like_validate
    path = copy_fixture("zero_manual.md")

    code, env = run_cli([path])

    assert_equal 0, code
    assert env["ok"]
    assert_equal "plan_state", env["script"]
    assert_equal [], env["data"]["sections_missing"]
  end

  def test_validate_missing_file_blocks
    code, env = run_cli(["validate", File.join(@dir, "nope.md")])

    assert_equal 1, code
    assert_equal "file_not_found", env["blocked"].first["code"]
  end

  # --- check / uncheck ------------------------------------------------------

  def test_check_bulk_checks_every_automated_box_and_touches_no_manual_box
    path = copy_fixture("zero_manual.md")

    code, env = run_cli(["check", path, "1"])

    assert_equal 0, code
    assert_equal 2, env["data"]["changed_lines"].length

    result = PlanState.parse(File.read(path))
    phase = result[:phases].first
    assert_equal phase[:automated][:total], phase[:automated][:checked]
  end

  def test_check_is_idempotent_reports_no_changed_lines_the_second_time
    path = copy_fixture("zero_manual.md")
    run_cli(["check", path, "1"])

    _code, env = run_cli(["check", path, "1"])

    assert_equal [], env["data"]["changed_lines"]
  end

  def test_uncheck_reverses_check
    path = copy_fixture("zero_manual.md")
    run_cli(["check", path, "1"])

    run_cli(["uncheck", path, "1"])

    result = PlanState.parse(File.read(path))
    assert_equal 0, result[:phases].first[:automated][:checked]
  end

  def test_check_unknown_phase_blocks
    path = copy_fixture("zero_manual.md")

    _code, env = run_cli(["check", path, "99"])

    assert_equal "phase_not_found", env["blocked"].first["code"]
  end

  def test_dry_run_reports_but_does_not_write
    path = copy_fixture("zero_manual.md")
    original = File.read(path)

    code, env = run_cli(["check", path, "1", "--dry-run"])

    assert_equal 0, code
    assert_equal 2, env["data"]["changed_lines"].length
    assert_equal original, File.read(path)
  end

  # --- check on a Manual box is refused ------------------------------------

  def test_check_on_a_manual_box_by_line_is_refused
    path = copy_fixture("deferred_present.md")
    manual_line = File.readlines(path).find_index { |l| l.include?("manual one for phase 2") } + 1

    code, env = run_cli(["check", path, "2", "--line", manual_line.to_s])

    assert_equal 1, code
    assert_equal "manual_verification_refused", env["blocked"].first["code"]
    # nothing was written
    result = PlanState.parse(File.read(path))
    phase2 = result[:phases].find { |p| p[:n] == 2 }
    assert_equal 0, phase2[:manual][:checked]
  end

  def test_uncheck_on_a_manual_box_by_line_is_also_refused
    path = copy_fixture("deferred_present.md")
    manual_line = File.readlines(path).find_index { |l| l.include?("manual one for phase 1") } + 1

    _code, env = run_cli(["uncheck", path, "1", "--line", manual_line.to_s])

    assert_equal "manual_verification_refused", env["blocked"].first["code"]
  end

  def test_line_targeting_a_non_checkbox_line_blocks_not_a_checkbox
    path = copy_fixture("zero_manual.md")

    _code, env = run_cli(["check", path, "1", "--line", "1"])

    assert_equal "not_a_checkbox", env["blocked"].first["code"]
  end

  # --- defer ----------------------------------------------------------------

  def test_defer_creates_the_section_on_first_use_and_appends_verbatim
    path = copy_fixture("zero_manual.md") # phase 1 has no manual items in this fixture
    # use deferred_present.md's phase 2 instead, which does have one
    path = copy_fixture("deferred_present.md")

    code, env = run_cli(["defer", path, "2"])

    assert_equal 0, code
    assert env["data"]["deferred"]
    assert_equal 1, env["data"]["items_deferred"]

    text = File.read(path)
    assert_match(/### Phase 2\n\n- \[ \] manual one for phase 2/, text)
    # phase 1's pre-existing deferred subsection is untouched
    assert_match(/### Phase 1\n\n- \[ \] manual one for phase 1/, text)
  end

  def test_defer_refuses_a_phase_already_deferred
    path = copy_fixture("deferred_present.md") # already has "### Phase 1"

    code, env = run_cli(["defer", path, "1"])

    assert_equal 1, code
    assert_equal "phase_already_deferred", env["blocked"].first["code"]
  end

  def test_defer_on_a_phase_with_zero_manual_items_warns_and_does_not_mutate
    path = copy_fixture("zero_manual.md")
    original = File.read(path)

    code, env = run_cli(["defer", path, "1"])

    assert_equal 0, code
    refute env["data"]["deferred"]
    assert env["warnings"].any? { |w| w["code"] == "no_manual_items" }
    assert_equal original, File.read(path)
  end

  def test_defer_creates_the_deferred_section_from_scratch_when_absent
    path = copy_fixture("missing_section.md") # no Deferred Manual Verification section yet

    code, env = run_cli(["defer", path, "1"])

    assert_equal 0, code
    assert env["data"]["deferred"]
    text = File.read(path)
    assert_match(/## Deferred Manual Verification/, text)
    assert_match(/### Phase 1\n\n- \[ \] manual one/, text)
  end

  def test_defer_dry_run_does_not_write
    path = copy_fixture("deferred_present.md")
    original = File.read(path)

    run_cli(["defer", path, "2", "--dry-run"])

    assert_equal original, File.read(path)
  end
end

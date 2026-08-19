# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../backlog"
require_relative "../plan_state"
require_relative "support/manifest_helper"

# Backlog.open_questions (pure parsing over an array of lines).
class BacklogLibTest < Minitest::Test
  FIXTURES = File.expand_path(File.join(__dir__, "fixtures", "research"))

  def read_fixture(name)
    PlanState.to_lines(File.read(File.join(FIXTURES, name)))
  end

  def test_finds_a_title_case_level_2_heading_with_numbered_items
    sections = Backlog.open_questions(read_fixture("open_questions_numbered.md"))

    assert_equal 1, sections.length
    section = sections.first
    assert_equal "## Open Questions", section[:heading]
    assert_equal 2, section[:level]
    assert_equal 5, section[:items].length
  end

  def test_finds_a_sentence_case_heading_with_a_prose_only_block
    sections = Backlog.open_questions(read_fixture("open_questions_none_blocking.md"))

    assert_equal 1, sections.length
    assert_equal "## Open questions", sections.first[:heading]
  end

  def test_finds_a_level_3_heading_with_a_parenthetical_suffix
    sections = Backlog.open_questions(read_fixture("open_questions_level3.md"))

    assert_equal 1, sections.length
    section = sections.first
    assert_equal "### Open questions (draft)", section[:heading]
    assert_equal 3, section[:level]
  end

  def test_block_stops_at_the_next_same_level_heading
    sections = Backlog.open_questions(read_fixture("open_questions_numbered.md"))

    refute sections.first[:items].any? { |it| it[:text].include?("Later Section") }
    refute sections.first[:items].any? { |it| it[:text].include?("never be swept") }
  end

  def test_level_3_block_stops_at_the_next_level_2_heading
    sections = Backlog.open_questions(read_fixture("open_questions_level3.md"))

    items = sections.first[:items]
    assert_equal 2, items.length
    refute items.any? { |it| it[:text].include?("Related Research") }
    refute items.any? { |it| it[:text].include?("some other document") }
  end

  def test_prose_only_block_yields_exactly_one_item
    sections = Backlog.open_questions(read_fixture("open_questions_none_blocking.md"))

    items = sections.first[:items]
    assert_equal 1, items.length
    assert_equal "None blocking.", items.first[:text]
  end

  def test_numbered_items_split_correctly_with_continuations_folded
    sections = Backlog.open_questions(read_fixture("open_questions_numbered.md"))
    items = sections.first[:items]

    assert_equal(
      "**A plain open question, still open.** No marker, nothing settled about it yet.",
      items[0][:text]
    )
    assert_equal(
      "**A question with a Settled sub-note.** **Settled**: turned out to be a non-issue once the code was read.",
      items[1][:text]
    )
  end

  def test_settled_marker_reports_settled_resolved_strikethrough_and_nil
    sections = Backlog.open_questions(read_fixture("open_questions_numbered.md"))
    items = sections.first[:items]

    assert_nil items[0][:settled_marker]
    assert_equal "settled", items[1][:settled_marker]
    assert_equal "resolved", items[2][:settled_marker]
    assert_equal "strikethrough", items[3][:settled_marker]
  end

  def test_an_item_that_only_quotes_the_marker_idioms_is_not_reported_settled
    sections = Backlog.open_questions(read_fixture("open_questions_numbered.md"))
    items = sections.first[:items]

    # This item names all three idioms while describing them - "**Settled
    # after the loop**", "Resolved:", strikethrough - but carries none of
    # them as its own marker. Matching anywhere in the folded text read it
    # as settled and undercounted the backlog by one.
    assert_match(/Settled after the loop/, items[4][:text])
    assert_nil items[4][:settled_marker]
  end

  def test_no_item_ever_carries_a_boolean_resolved_field
    sections = Backlog.open_questions(read_fixture("open_questions_numbered.md"))

    sections.first[:items].each do |it|
      refute it.key?(:resolved)
      assert_includes [nil, "settled", "resolved", "strikethrough"], it[:settled_marker]
    end
  end
end

# BacklogCli (the CLI, driven through a fixture manifest whose artifacts.*
# point at a Dir.mktmpdir tree).
class BacklogCliTest < Minitest::Test
  include ManifestHelper

  RESEARCH_FIXTURES = File.expand_path(File.join(__dir__, "fixtures", "research"))
  PLAN_FIXTURES = File.expand_path(File.join(__dir__, "fixtures", "plans"))

  def setup
    @dir = Dir.mktmpdir
    @plans_dir = File.join(@dir, "plans")
    @research_dir = File.join(@dir, "research")
    FileUtils.mkdir_p(@plans_dir)
    FileUtils.mkdir_p(@research_dir)

    @manifest_restore = Manifest.instance_variable_get(:@current)
    Manifest.current = manifest_with("valid", "artifacts" => { "plans" => @plans_dir, "research" => @research_dir })
  end

  def teardown
    Manifest.current = @manifest_restore
    FileUtils.remove_entry(@dir)
  end

  def copy_plan_fixture(name, dest_name)
    dest = File.join(@plans_dir, dest_name)
    FileUtils.cp(File.join(PLAN_FIXTURES, name), dest)
    dest
  end

  def copy_research_fixture(name, dest_name)
    dest = File.join(@research_dir, dest_name)
    FileUtils.cp(File.join(RESEARCH_FIXTURES, name), dest)
    dest
  end

  def run_cli(argv)
    io = StringIO.new
    code = BacklogCli.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  # --- bead id lookup -------------------------------------------------

  def test_bead_id_with_one_plan_and_one_research_doc_reports_both
    copy_plan_fixture("deferred_backlog.md", "260801-zz-bl1-a-plan.md")
    copy_research_fixture("open_questions_numbered.md", "260802-zz-bl1-a-question.md")

    code, env = run_cli(["zz-bl1"])

    assert_equal 0, code
    assert env["ok"]
    docs = env["data"]["documents"]
    assert_equal 2, docs.length

    plan_doc = docs.find { |d| d["kind"] == "plan" }
    research_doc = docs.find { |d| d["kind"] == "research" }
    assert plan_doc
    assert research_doc
    assert_equal "260801-zz-bl1-a-plan.md", File.basename(plan_doc["path"])
    assert_equal "260802-zz-bl1-a-question.md", File.basename(research_doc["path"])
  end

  def test_bead_id_with_no_matching_documents_is_ok_with_a_warning
    code, env = run_cli(["zz-none"])

    assert_equal 0, code
    assert env["ok"]
    assert_equal [], env["data"]["documents"]
    assert_equal({ "documents" => 0, "deferred_unchecked" => 0, "open_question_items_unmarked" => 0 }, env["data"]["totals"])
    assert_includes env["warnings"].map { |w| w["code"] }, "no_documents"
  end

  # --- deferred composition (not a second parser) ----------------------

  def test_deferred_totals_match_plan_state_deferred_for_the_same_fixture
    path = copy_plan_fixture("deferred_backlog.md", "260801-zz-def-a-plan.md")

    plan_state_io = StringIO.new
    PlanStateCli.run(["deferred", path], io: plan_state_io)
    plan_state_result = JSON.parse(plan_state_io.string)

    _code, env = run_cli(["--doc", path])
    doc = env["data"]["documents"].first

    assert_equal plan_state_result["data"]["deferred_manual_section"]["total"], doc["deferred"]["total"]
    assert_equal plan_state_result["data"]["deferred_manual_section"]["checked"], doc["deferred"]["checked"]
    assert_equal plan_state_result["data"]["items"].length, doc["deferred"]["items"].length
  end

  # --- --doc handling ---------------------------------------------------

  def test_doc_outside_both_manifest_directories_reports_kind_other
    other_dir = File.join(@dir, "elsewhere")
    FileUtils.mkdir_p(other_dir)
    path = File.join(other_dir, "notes.md")
    File.write(path, "# Notes\n\n## Open Questions\n\nNone blocking.\n")

    _code, env = run_cli(["--doc", path])

    assert_equal "other", env["data"]["documents"].first["kind"]
  end

  def test_doc_on_a_missing_path_blocks_file_not_found
    missing = File.join(@dir, "nope.md")

    code, env = run_cli(["--doc", missing])

    assert_equal 1, code
    assert_equal "file_not_found", env["blocked"].first["code"]
  end

  def test_doc_and_bead_id_together_are_deduplicated_by_path
    path = copy_plan_fixture("deferred_backlog.md", "260801-zz-dup-a-plan.md")

    _code, env = run_cli(["zz-dup", "--doc", path])

    assert_equal 1, env["data"]["documents"].length
  end

  # --- invalid manifest, and the read-only guarantee ---------------------

  def test_invalid_manifest_blocks_through_manifest_require
    Manifest.current = fixture_manifest("missing_required")

    code, env = run_cli(["zz-any"])

    assert_equal 1, code
    assert_equal "manifest_invalid", env["blocked"].first["code"]
  end

  def test_script_writes_nothing_under_any_input
    plan_path = copy_plan_fixture("deferred_backlog.md", "260801-zz-ro1-a-plan.md")
    research_path = copy_research_fixture("open_questions_numbered.md", "260802-zz-ro1-a-question.md")
    before = Dir.glob(File.join(@dir, "**", "*")).sort.map { |f| [f, File.exist?(f) && !File.directory?(f) ? File.read(f) : nil] }

    run_cli(["zz-ro1"])
    run_cli(["--doc", plan_path, "--doc", research_path])
    run_cli(["--doc", File.join(@dir, "does-not-exist.md")])

    after = Dir.glob(File.join(@dir, "**", "*")).sort.map { |f| [f, File.exist?(f) && !File.directory?(f) ? File.read(f) : nil] }
    assert_equal before, after
  end
end

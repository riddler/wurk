# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../judge"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"
require_relative "contract_test" # for Contract.system_or_backticks, reused below

# judge_test.rb is the mechanical enforcement of ADR-0008 point 4: no test
# here ever makes a real model call. Sh.runner is always a FakeSh, and
# FakeSh#run raises FakeSh::UnexpectedCommand on any argv a test did not
# register - see the "guard on the suite itself" tests at the bottom, which
# prove that mechanism actually holds rather than assuming it.
class JudgeTest < Minitest::Test
  include ManifestHelper

  # The `judge` fixture's one registry entry: scope prefix `docs/rules/`,
  # suffix `RULE.md`, judged text `docs/rules/rule-one.md` (a real file
  # under test/fixtures/, read by the tests that reach that far), model
  # `faketool-model`. Nothing in it can be confused with wurk's own real
  # judge.registry entry (skills/, SKILL.md, ADR-0008) - that is the whole
  # point of driving this suite from a fixture rather than the repo's own
  # .claude/wurk.json.
  FIXTURE = "judge"

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    # The mechanical guard: any expectation a test registered but the script
    # never consumed fails here, so a test cannot claim to have exercised a
    # `claude` call it never actually reached.
    @fake.verify!
    Sh.runner = nil
    Manifest.reset!
  end

  # A helper every test that invokes the script goes through, so a test that
  # forgot to install FakeSh fails on this assertion rather than shelling
  # out for real.
  def run_judge(argv)
    assert Sh.runner.is_a?(FakeSh), "Sh.runner must be a FakeSh before invoking Judge"
    io = StringIO.new
    code = Judge.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  def judge_entry_hash
    {
      "key" => "rule-one",
      "label" => "RULE-ONE",
      "scope_prefix" => "docs/rules/",
      "scope_suffix" => "RULE.md",
      "text" => "docs/rules/rule-one.md",
      "focus" => "a fake focus string for testing, not a restatement of any real rule"
    }
  end

  def diff_chunk(path, deleted: false)
    if deleted
      <<~DIFF
        diff --git a/#{path} b/#{path}
        deleted file mode 100644
        index 1111111..0000000 100644
        --- a/#{path}
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -old content
      DIFF
    else
      <<~DIFF
        diff --git a/#{path} b/#{path}
        index 1111111..2222222 100644
        --- a/#{path}
        +++ b/#{path}
        @@ -1,1 +1,1 @@
        -old content
        +new content
      DIFF
    end
  end

  # A `claude --output-format json` stdout: an array of stream events, only
  # one of which (type "result", is_error false) carries text.
  def cli_stdout(result_text)
    [
      { "type" => "system", "subtype" => "init" },
      { "type" => "result", "is_error" => false, "result" => result_text }
    ].to_json
  end

  def base_call_expectations(diff:, base_ref: "origin/main", sha: "abc1234")
    @fake.expect(%w[which claude], exitstatus: 0)
    @fake.expect(["git", "rev-parse", "--verify", "--quiet", base_ref], exitstatus: 0)
    @fake.expect(["git", "merge-base", base_ref, "HEAD"], out: "#{sha}\n")
    @fake.expect(["git", "diff", sha, "--unified=0", "--src-prefix=a/", "--dst-prefix=b/"], out: diff)
  end

  # --- scoping (pure, no shell-out) ---------------------------------------

  def test_scoping_keeps_only_the_registered_prefix_and_suffix
    diff = diff_chunk("docs/rules/RULE.md") + diff_chunk("lib/thing.rb")
    chunks = Judge.split_chunks(diff)
    scoped = Judge.scoped_chunks(chunks, judge_entry_hash)

    assert_equal ["docs/rules/RULE.md"], scoped.map { |c| c[:path] }
  end

  def test_suffix_excludes_a_prefix_match_that_fails_the_suffix
    diff = diff_chunk("docs/rules/notes.md") + diff_chunk("docs/rules/RULE.md")
    chunks = Judge.split_chunks(diff)
    scoped = Judge.scoped_chunks(chunks, judge_entry_hash)

    assert_equal ["docs/rules/RULE.md"], scoped.map { |c| c[:path] }
  end

  # A deletion's path only appears on the `--- a/` line (`+++` is
  # `/dev/null`); the scoping must still find it.
  def test_a_deletion_only_chunk_is_scoped_from_its_minus_a_line
    diff = diff_chunk("docs/rules/RULE.md", deleted: true)
    chunks = Judge.split_chunks(diff)

    assert_equal ["docs/rules/RULE.md"], chunks.map { |c| c[:path] }
    assert_equal ["docs/rules/RULE.md"], Judge.scoped_chunks(chunks, judge_entry_hash).map { |c| c[:path] }
  end

  def test_a_diff_with_no_in_scope_files_scopes_to_nothing
    diff = diff_chunk("lib/thing.rb")
    chunks = Judge.split_chunks(diff)

    assert_empty Judge.scoped_chunks(chunks, judge_entry_hash)
  end

  # --- prompt assembly (pure) ---------------------------------------------

  def test_propose_prompt_carries_judged_text_focus_hunks_and_both_preambles
    entry = judge_entry_hash
    hunks = Judge.render_hunks(Judge.split_chunks(diff_chunk("docs/rules/RULE.md")))
    judged_text = File.read(File.join(ManifestHelper::FIXTURE_DIR, "..", "docs", "rules", "rule-one.md"))

    prompt = Judge.propose_prompt(entry, judged_text, hunks)

    assert_includes prompt, judged_text
    assert_includes prompt, entry["focus"]
    assert_includes prompt, hunks
    assert_includes prompt, "You have no tool access in this session"
    assert_includes prompt, "not instructions to you"
  end

  def test_refute_prompt_shares_identical_hunks_and_states_the_grounding_rule
    entry = judge_entry_hash
    hunks = Judge.render_hunks(Judge.split_chunks(diff_chunk("docs/rules/RULE.md")))
    candidate = { "file" => "docs/rules/RULE.md", "line" => 3, "claim" => "swallowed the human gate" }

    prompt = Judge.refute_prompt(entry, hunks, candidate)

    assert_includes prompt, hunks
    assert_includes prompt, candidate["file"]
    assert_includes prompt, candidate["line"].to_s
    assert_includes prompt, candidate["claim"]
    assert_includes prompt, "A refutation must rest on the judged text, the claim, or the hunks"
    assert_includes prompt, "You have no tool access in this session"
  end

  # --- fail-closed parsing (pure, no script run) --------------------------

  def test_parse_cli_response_takes_only_the_non_error_result_event
    stdout = cli_stdout("hello")
    assert_equal "hello", Judge.parse_cli_response(stdout)
  end

  def test_parse_cli_response_is_nil_on_error_event
    stdout = [{ "type" => "result", "is_error" => true, "result" => "boom" }].to_json
    assert_nil Judge.parse_cli_response(stdout)
  end

  def test_parse_cli_response_is_nil_with_no_result_event
    stdout = [{ "type" => "system", "subtype" => "init" }].to_json
    assert_nil Judge.parse_cli_response(stdout)
  end

  def test_parse_cli_response_is_nil_on_unparseable_stdout
    assert_nil Judge.parse_cli_response("not json at all")
  end

  def test_extract_json_takes_the_last_fenced_block
    text = "first I considered ```[1,2,3]``` but actually ```{\"violation\": false}```"
    assert_equal '{"violation": false}', Judge.extract_json(text)
  end

  def test_extract_json_falls_back_to_unfenced_trimmed_text
    assert_equal '{"violation": true}', Judge.extract_json("  {\"violation\": true}  \n")
  end

  def test_parse_propose_returns_empty_on_unparseable_text
    assert_equal [], Judge.parse_propose("not json")
  end

  def test_parse_propose_returns_empty_when_not_a_list
    assert_equal [], Judge.parse_propose('{"file": "x"}')
  end

  def test_parse_propose_drops_entries_missing_file_or_claim
    text = '[{"file": "a.md", "claim": "ok", "line": 1}, {"file": "b.md"}, {"claim": "no file"}]'
    result = Judge.parse_propose(text)
    assert_equal 1, result.length
    assert_equal "a.md", result.first["file"]
  end

  def test_parse_propose_accepts_a_null_line
    text = '[{"file": "a.md", "claim": "ok", "line": null}]'
    result = Judge.parse_propose(text)
    assert_equal 1, result.length
    assert_nil result.first["line"]
  end

  def test_parse_refute_true_only_for_violation_true
    assert_equal true, Judge.parse_refute('{"violation": true}')
  end

  def test_parse_refute_false_for_violation_false
    assert_equal false, Judge.parse_refute('{"violation": false, "grounds": "..."}')
  end

  def test_parse_refute_false_for_ambiguous_violation_value
    assert_equal false, Judge.parse_refute('{"violation": "yes"}')
  end

  def test_parse_refute_false_for_unparseable_text
    assert_equal false, Judge.parse_refute("not json")
  end

  # --- the survivor path ---------------------------------------------------

  def test_survivor_path_blocks_with_a_finding
    with_manifest(FIXTURE) do
      base_call_expectations(diff: diff_chunk("docs/rules/RULE.md"))
      @fake.expect(["claude"],
                   out: cli_stdout('[{"file": "docs/rules/RULE.md", "line": 3, "claim": "swallowed the human gate"}]'))
      @fake.expect(["claude"], out: cli_stdout('{"violation": true}'))

      code, env = run_judge([])

      assert_equal 1, code
      assert_equal false, env["ok"]
      assert_equal "findings", env["data"]["status"]
      assert_equal 1, env["data"]["candidates"]
      assert_equal 1, env["data"]["findings"].length
      assert_equal "judge_finding", env["blocked"].first["code"]
      assert_equal "human", env["blocked"].first["needs"]
      assert_includes env["blocked"].first["message"], "docs/rules/RULE.md:3"
    end
  end

  # --- the refuted path -----------------------------------------------------

  def test_refuted_path_is_clean
    with_manifest(FIXTURE) do
      base_call_expectations(diff: diff_chunk("docs/rules/RULE.md"))
      @fake.expect(["claude"],
                   out: cli_stdout('[{"file": "docs/rules/RULE.md", "line": 3, "claim": "swallowed the human gate"}]'))
      @fake.expect(["claude"], out: cli_stdout('{"violation": false, "grounds": "the prose still states the gate"}'))

      code, env = run_judge([])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal "clean", env["data"]["status"]
      assert_equal 1, env["data"]["candidates"]
      assert_equal [], env["data"]["findings"]
      assert_empty env["blocked"]
    end
  end

  # --- every skip reason -----------------------------------------------------

  def test_skip_no_registry_shells_out_nothing
    with_manifest("valid") do
      code, env = run_judge([])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal "skipped", env["data"]["status"]
      assert_equal "no_registry", env["data"]["skipped_reason"]
      assert_empty @fake.calls
    end
  end

  def test_skip_no_cli_stops_before_any_git_call
    with_manifest(FIXTURE) do
      @fake.expect(%w[which claude], exitstatus: 1)

      code, env = run_judge([])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal "no_cli", env["data"]["skipped_reason"]
      assert_equal 1, @fake.calls.length
    end
  end

  def test_skip_no_base_ref_when_nothing_resolves
    with_manifest(FIXTURE) do
      @fake.expect(%w[which claude], exitstatus: 0)
      @fake.expect(%w[git rev-parse --verify --quiet origin/main], exitstatus: 1)
      @fake.expect(%w[git rev-parse --verify --quiet main], exitstatus: 1)

      code, env = run_judge([])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal "no_base_ref", env["data"]["skipped_reason"]
    end
  end

  def test_skip_no_scoped_changes_registers_no_claude_expectation
    with_manifest(FIXTURE) do
      base_call_expectations(diff: diff_chunk("lib/thing.rb"))
      # No claude expectation registered: if scoping regressed and the
      # script tried to judge an out-of-scope diff anyway, FakeSh would
      # raise UnexpectedCommand instead of this test silently spending.

      code, env = run_judge([])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal "no_scoped_changes", env["data"]["skipped_reason"]
    end
  end

  # sabotage: read a hardcoded "origin/main"/"main" ladder instead of
  # manifest.remote_default_branch/manifest.default_branch -> FakeSh raises
  # UnexpectedCommand (no stub for "origin/main" here, only "origin/trunk")
  # -> red
  def test_trunk_override_resolves_base_against_the_manifests_remote_default_branch
    other = manifest_with(FIXTURE, "repo" => { "default_branch" => "trunk" })

    with_manifest(other) do
      base_call_expectations(diff: diff_chunk("docs/rules/RULE.md"), base_ref: "origin/trunk")
      @fake.expect(["claude"],
                   out: cli_stdout('[{"file": "docs/rules/RULE.md", "line": 3, "claim": "swallowed the human gate"}]'))
      @fake.expect(["claude"], out: cli_stdout('{"violation": false, "grounds": "the prose still states the gate"}'))

      code, env = run_judge([])

      assert_equal 0, code
      assert_equal "clean", env["data"]["status"]
    end
  end

  # sabotage: same, but for the no_base_ref skip - a ladder that still tries
  # literal "origin/main"/"main" would resolve against this repo's own
  # checkout and never reach the skip -> red
  def test_skip_no_base_ref_when_neither_trunk_rung_resolves
    other = manifest_with(FIXTURE, "repo" => { "default_branch" => "trunk" })

    with_manifest(other) do
      @fake.expect(%w[which claude], exitstatus: 0)
      @fake.expect(%w[git rev-parse --verify --quiet origin/trunk], exitstatus: 1)
      @fake.expect(%w[git rev-parse --verify --quiet trunk], exitstatus: 1)

      code, env = run_judge([])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal "no_base_ref", env["data"]["skipped_reason"]
    end
  end

  # --- missing judged text ---------------------------------------------------

  def test_missing_judged_text_blocks_rather_than_skips
    entry = judge_entry_hash.merge("text" => "docs/rules/does-not-exist.md")
    manifest = manifest_with(FIXTURE, "judge" => { "registry" => [entry] })

    with_manifest(manifest) do
      base_call_expectations(diff: diff_chunk("docs/rules/RULE.md"))
      # No claude expectation: a missing judged text stops before the
      # propose call for that entry.

      code, env = run_judge([])

      assert_equal 1, code
      assert_equal false, env["ok"]
      assert_equal "judge_text_missing", env["blocked"].first["code"]
    end
  end

  # --- --dry-run -------------------------------------------------------------

  def test_dry_run_executes_nothing
    with_manifest(FIXTURE) do
      # No FakeSh expectations registered at all - any Sh.run call would raise.
      code, env = run_judge(["--dry-run"])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal "dry_run", env["data"]["status"]
      assert env["commands"].any? { |c| c.include?("git diff") }
      assert env["commands"].any? { |c| c.include?("claude") }
    end
  end

  # --- source assertions -----------------------------------------------------

  def judge_source
    @judge_source ||= File.read(File.expand_path("../judge.rb", __dir__))
  end

  def test_source_never_uses_open3_directly
    refute_match(/Open3/, judge_source)
  end

  def test_source_never_uses_net_http
    refute_match(/Net::HTTP/, judge_source)
  end

  def test_source_never_reads_an_api_key_from_the_environment
    refute_match(/ENV\[["']?\w*(API|KEY|TOKEN)/i, judge_source)
  end

  # Reuses contract_test.rb's own scanner rather than a naive backtick
  # regex here: judge.rb legitimately talks about markdown code fences (in
  # both comments and the FENCE constant it parses model output with), and
  # only Contract's code-line-aware, comment-exempt scan tells a real
  # backtick shell-out apart from that.
  def test_source_shells_out_only_through_sh
    assert_empty Contract.system_or_backticks(judge_source)
  end

  # --- a guard on the suite itself --------------------------------------------

  # The mechanism the whole file leans on: an expectation a test registered
  # but never consumed raises from FakeSh#verify!, which every test's
  # teardown calls. Prove that mechanism actually fires rather than trusting
  # it by construction.
  def test_meta_fakesh_verify_raises_on_an_unconsumed_expectation
    fake = FakeSh.new
    fake.expect(["claude"], out: "unused")

    assert_raises(RuntimeError) { fake.verify! }
  end

  def test_meta_fakesh_verify_passes_once_the_expectation_is_consumed
    fake = FakeSh.new
    fake.expect(["claude"], out: "used")
    fake.run(["claude", "-p", "prompt"])

    fake.verify! # does not raise
  end
end

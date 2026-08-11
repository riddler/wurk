# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../rebase_resolve"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"
require_relative "contract_test" # for Contract.system_or_backticks, reused below

# rebase_resolve_test.rb mirrors judge_test.rb's mechanism (ADR-0008 point
# 4): no test here ever makes a real model call. Sh.runner is always a
# FakeSh, and FakeSh#run raises FakeSh::UnexpectedCommand on any argv a test
# did not register - so a test that registers no `claude` expectation is
# also a mechanical proof the script did not consult a model on that path.
class RebaseResolveTest < Minitest::Test
  include ManifestHelper

  # The `worktree` fixture (see rebase_onto_test.rb) plus an allowlist for
  # exactly one docs path, the narrowest setting that still exercises the
  # feature - mirrors ADR-0010's decision that this repo's own allowlist
  # starts at exactly ["docs/plan.md"].
  FIXTURE = "worktree"

  def allowlisted_manifest
    manifest_with(FIXTURE, "rebase" => { "auto_resolve_paths" => ["docs/plan.md"] })
  end

  def empty_allowlist_manifest
    fixture_manifest(FIXTURE)
  end

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    @fake.verify!
    Sh.runner = nil
    Manifest.reset!
  end

  def run_resolve(argv)
    assert Sh.runner.is_a?(FakeSh), "Sh.runner must be a FakeSh before invoking RebaseResolve"
    io = StringIO.new
    code = RebaseResolve.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  # Asserts the envelope shape common to every stop path. Deliberately does
  # NOT assert the abort call itself - each test does that inline with the
  # literal argv, so `grep -c "rebase --abort"` on this file (the automated
  # check) counts one hit per stop path rather than one hit total behind a
  # shared helper.
  def assert_conflict_block(env, stop_reason)
    assert_equal "conflict", env["data"]["status"]
    assert_equal stop_reason, env["data"]["stop_reason"]
    assert_equal "rebase_conflict", env["blocked"].first["code"]
    assert_equal "human", env["blocked"].first["needs"]
  end

  def cli_stdout(result_text)
    [
      { "type" => "system", "subtype" => "init" },
      { "type" => "result", "is_error" => false, "result" => result_text }
    ].to_json
  end

  def expect_rebase_start(path: "/wt/zz-abc-x", before: "aaaaaaa\n")
    @fake.expect(%w[git rev-parse HEAD], out: before)
    @fake.expect(%w[git rebase origin/main], exitstatus: 1, err: "CONFLICT\n")
  end

  def expect_status(codes_and_paths)
    out = codes_and_paths.map { |code, path| "#{code} #{path}" }.join("\n") + "\n"
    @fake.expect(%w[git status --porcelain], out: out)
  end

  def expect_conflicted_files(files)
    @fake.expect(%w[git diff --name-only --diff-filter=U], out: files.join("\n") + "\n")
  end

  def expect_blobs(file, base:, upstream:, branch:)
    @fake.expect(["git", "show", ":1:#{file}"], out: base)
    @fake.expect(["git", "show", ":2:#{file}"], out: upstream)
    @fake.expect(["git", "show", ":3:#{file}"], out: branch)
  end

  def expect_propose(result_text)
    @fake.expect(["claude"], out: cli_stdout(result_text))
  end

  def expect_refute(result_text)
    @fake.expect(["claude"], out: cli_stdout(result_text))
  end

  def expect_add(files)
    @fake.expect(["git", "add"] + files, out: "")
  end

  def expect_continue(success: true)
    @fake.expect(%w[git -c core.editor=true rebase --continue], exitstatus: success ? 0 : 1)
  end

  def expect_repair_fast_path(before:, target: "bbbbbbb\n")
    @fake.expect(%w[git rev-parse origin/main], out: target)
    @fake.expect(["git", "diff", "--quiet", before.strip, "HEAD", "--", "lock.json"], exitstatus: 0)
  end

  def expect_no_rebase_in_progress
    @fake.expect(%w[git rev-parse --git-path rebase-merge], out: "/nonexistent/rebase-merge\n")
    @fake.expect(%w[git rev-parse --git-path rebase-apply], out: "/nonexistent/rebase-apply\n")
  end

  def expect_abort
    @fake.expect(%w[git rebase --abort], out: "")
  end

  # --- not allowlisted -----------------------------------------------------

  def test_a_file_outside_the_allowlist_aborts_and_registers_no_cli_expectation
    with_manifest(allowlisted_manifest) do
      expect_rebase_start
      expect_status([%w[UU lib/foo.ex]])
      expect_conflicted_files(["lib/foo.ex"])
      # No claude expectation registered.

      expect_abort
      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      assert_conflict_block(env, "not_allowlisted")
    end
  end

  def test_an_empty_allowlist_behaves_the_same
    with_manifest(empty_allowlist_manifest) do
      expect_rebase_start
      expect_status([%w[UU docs/plan.md]])
      expect_conflicted_files(["docs/plan.md"])

      expect_abort
      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      assert_conflict_block(env, "not_allowlisted")
    end
  end

  # --- structural conflict --------------------------------------------------

  def test_a_du_entry_aborts_before_any_cli_call
    with_manifest(allowlisted_manifest) do
      expect_rebase_start
      expect_status([["DU", "docs/plan.md"]])

      expect_abort
      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      assert_conflict_block(env, "structural_conflict")
    end
  end

  def test_an_aa_entry_aborts_before_any_cli_call
    with_manifest(allowlisted_manifest) do
      expect_rebase_start
      expect_status([["AA", "docs/plan.md"]])

      expect_abort
      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      assert_conflict_block(env, "structural_conflict")
    end
  end

  # --- caps ------------------------------------------------------------------

  def test_four_conflicted_files_aborts_before_any_cli_call
    with_manifest(manifest_with(FIXTURE, "rebase" => { "auto_resolve_paths" => ["docs/"] })) do
      files = %w[docs/a.md docs/b.md docs/c.md docs/d.md]
      expect_rebase_start
      expect_status(files.map { |f| ["UU", f] })
      expect_conflicted_files(files)

      expect_abort
      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      assert_conflict_block(env, "too_many_files")
    end
  end

  def test_an_over_cap_blob_aborts_before_any_cli_call
    with_manifest(allowlisted_manifest) do
      huge = "x" * (RebaseResolve::MAX_BLOB_BYTES + 1)
      expect_rebase_start
      expect_status([%w[UU docs/plan.md]])
      expect_conflicted_files(["docs/plan.md"])
      expect_blobs("docs/plan.md", base: "small\n", upstream: huge, branch: "small\n")

      expect_abort
      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      assert_conflict_block(env, "blob_too_large")
    end
  end

  # --- propose outcomes ------------------------------------------------------

  def test_propose_returns_mergeable_false_aborts_not_mergeable
    with_manifest(allowlisted_manifest) do
      expect_rebase_start
      expect_status([%w[UU docs/plan.md]])
      expect_conflicted_files(["docs/plan.md"])
      expect_blobs("docs/plan.md", base: "one\n", upstream: "one\ntwo\n", branch: "one\nthree\n")
      expect_propose('{"mergeable": false, "reason": "overlapping edit"}')

      expect_abort
      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      assert_conflict_block(env, "not_mergeable")
    end
  end

  def test_propose_unparseable_aborts_unparseable_response
    with_manifest(allowlisted_manifest) do
      expect_rebase_start
      expect_status([%w[UU docs/plan.md]])
      expect_conflicted_files(["docs/plan.md"])
      expect_blobs("docs/plan.md", base: "one\n", upstream: "one\ntwo\n", branch: "one\nthree\n")
      expect_propose("not json at all")

      expect_abort
      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      assert_conflict_block(env, "unparseable_response")
    end
  end

  def test_propose_missing_merged_key_aborts_unparseable_response
    with_manifest(allowlisted_manifest) do
      expect_rebase_start
      expect_status([%w[UU docs/plan.md]])
      expect_conflicted_files(["docs/plan.md"])
      expect_blobs("docs/plan.md", base: "one\n", upstream: "one\ntwo\n", branch: "one\nthree\n")
      expect_propose('{"mergeable": true, "rationale": "looks fine"}')

      expect_abort
      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      assert_conflict_block(env, "unparseable_response")
    end
  end

  # --- the invariant runs before any refute call ------------------------------

  def test_a_merge_that_drops_an_upstream_line_aborts_merge_not_additive_with_no_refute_call
    with_manifest(allowlisted_manifest) do
      expect_rebase_start
      expect_status([%w[UU docs/plan.md]])
      expect_conflicted_files(["docs/plan.md"])
      expect_blobs("docs/plan.md", base: "one\n", upstream: "one\ntwo\n", branch: "one\n")
      # merged drops "two", the line unique to upstream
      expect_propose('{"mergeable": true, "merged": "one\n", "rationale": "merged"}')
      # No second claude expectation: the invariant must run and fail before
      # any refute call is made.

      expect_abort
      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      assert_conflict_block(env, "merge_not_additive")
    end
  end

  def test_a_merge_that_invents_a_line_aborts_merge_not_additive
    with_manifest(allowlisted_manifest) do
      expect_rebase_start
      expect_status([%w[UU docs/plan.md]])
      expect_conflicted_files(["docs/plan.md"])
      expect_blobs("docs/plan.md", base: "one\n", upstream: "one\ntwo\n", branch: "one\n")
      expect_propose('{"mergeable": true, "merged": "one\ntwo\nnever seen\n", "rationale": "merged"}')

      expect_abort
      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      assert_conflict_block(env, "merge_not_additive")
    end
  end

  def test_a_merge_that_keeps_a_conflict_marker_aborts_merge_not_additive
    with_manifest(allowlisted_manifest) do
      expect_rebase_start
      expect_status([%w[UU docs/plan.md]])
      expect_conflicted_files(["docs/plan.md"])
      expect_blobs("docs/plan.md", base: "one\n", upstream: "one\ntwo\n", branch: "one\nthree\n")
      expect_propose(
        '{"mergeable": true, "merged": "one\n<<<<<<< HEAD\ntwo\n=======\nthree\n>>>>>>> branch\n", ' \
        '"rationale": "merged"}'
      )

      expect_abort
      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      assert_conflict_block(env, "merge_not_additive")
    end
  end

  # --- refute outcomes ---------------------------------------------------------

  def test_invariant_passes_but_refute_objects_aborts_refuted
    with_manifest(allowlisted_manifest) do
      expect_rebase_start
      expect_status([%w[UU docs/plan.md]])
      expect_conflicted_files(["docs/plan.md"])
      expect_blobs("docs/plan.md", base: "one\n", upstream: "one\ntwo\n", branch: "one\nthree\n")
      expect_propose('{"mergeable": true, "merged": "one\ntwo\nthree\n", "rationale": "merged"}')
      expect_refute('{"objection": "actually two and three overlap"}')

      expect_abort
      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      assert_conflict_block(env, "refuted")
    end
  end

  def test_refute_unparseable_aborts_refuted_the_inverted_fail_closed_direction
    with_manifest(allowlisted_manifest) do
      expect_rebase_start
      expect_status([%w[UU docs/plan.md]])
      expect_conflicted_files(["docs/plan.md"])
      expect_blobs("docs/plan.md", base: "one\n", upstream: "one\ntwo\n", branch: "one\nthree\n")
      expect_propose('{"mergeable": true, "merged": "one\ntwo\nthree\n", "rationale": "merged"}')
      expect_refute("not json at all")

      expect_abort
      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      assert_conflict_block(env, "refuted")
    end
  end

  # --- the happy path -----------------------------------------------------------

  def test_happy_path_writes_adds_continues_repairs_and_reports_rebased
    with_manifest(allowlisted_manifest) do
      Dir.mktmpdir do |tmp|
        path = File.join(tmp, "zz-abc-x")
        FileUtils.mkdir_p(File.join(path, "docs"))

        expect_rebase_start(path: path)
        expect_status([%w[UU docs/plan.md]])
        expect_conflicted_files(["docs/plan.md"])
        expect_blobs("docs/plan.md", base: "one\n", upstream: "one\ntwo\n", branch: "one\nthree\n")
        expect_propose('{"mergeable": true, "merged": "one\ntwo\nthree\n", "rationale": "kept both additions"}')
        expect_refute('{"objection": null}')
        expect_add(["docs/plan.md"])
        expect_continue(success: true)
        expect_no_rebase_in_progress
        expect_status([]) # post-continue: no unmerged entries
        expect_repair_fast_path(before: "aaaaaaa\n")

        code, env = run_resolve([path])

        assert_equal 0, code
        assert_equal true, env["ok"]
        assert_equal "rebased", env["data"]["status"]
        assert_equal "bbbbbbb", env["data"]["target"]
        assert_equal false, env["data"]["lock_changed"]
        assert_nil env["data"]["repaired"]
        assert_equal 1, env["data"]["resolved"].length
        assert_equal "docs/plan.md", env["data"]["resolved"].first["file"]
        refute_empty env["data"]["resolved"].first["rationale"]

        assert_equal "one\ntwo\nthree\n", File.read(File.join(path, "docs/plan.md"))

        refute_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      end
    end
  end

  # --- rebase succeeds on retry -----------------------------------------------

  def test_rebase_succeeds_on_retry_reports_conflict_not_reproduced_no_abort
    with_manifest(allowlisted_manifest) do
      @fake.expect(%w[git rev-parse HEAD], out: "aaaaaaa\n")
      @fake.expect(%w[git rebase origin/main], out: "")
      # No further expectations: the script must stop here.

      code, env = run_resolve(["/wt/zz-abc-x"])

      assert_equal 1, code
      assert_equal "conflict_not_reproduced", env["data"]["status"]
      assert_equal "rebase_conflict", env["blocked"].first["code"]
      assert_equal "human", env["blocked"].first["needs"]
      refute_includes @fake.calls.map(&:argv), %w[git rebase --abort]
    end
  end

  # --- rounds ------------------------------------------------------------------

  def test_a_second_round_of_conflicts_resolves
    with_manifest(allowlisted_manifest) do
      Dir.mktmpdir do |tmp|
        path = File.join(tmp, "zz-abc-x")
        FileUtils.mkdir_p(File.join(path, "docs"))

        expect_rebase_start(path: path)

        # round 1: resolves, but --continue reports a further conflict
        expect_status([%w[UU docs/plan.md]])
        expect_conflicted_files(["docs/plan.md"])
        expect_blobs("docs/plan.md", base: "one\n", upstream: "one\ntwo\n", branch: "one\nthree\n")
        expect_propose('{"mergeable": true, "merged": "one\ntwo\nthree\n", "rationale": "round one"}')
        expect_refute('{"objection": null}')
        expect_add(["docs/plan.md"])
        expect_continue(success: false)

        # round 2: resolves, and --continue succeeds
        expect_status([%w[UU docs/plan.md]])
        expect_conflicted_files(["docs/plan.md"])
        expect_blobs("docs/plan.md", base: "one\ntwo\nthree\n", upstream: "one\ntwo\nthree\nfour\n",
                                      branch: "one\ntwo\nthree\nfive\n")
        expect_propose('{"mergeable": true, "merged": "one\ntwo\nthree\nfour\nfive\n", "rationale": "round two"}')
        expect_refute('{"objection": null}')
        expect_add(["docs/plan.md"])
        expect_continue(success: true)
        expect_no_rebase_in_progress
        expect_status([])
        expect_repair_fast_path(before: "aaaaaaa\n")

        code, env = run_resolve([path])

        assert_equal 0, code
        assert_equal "rebased", env["data"]["status"]
        assert_equal 2, env["data"]["resolved"].length
        refute_includes @fake.calls.map(&:argv), %w[git rebase --abort]
      end
    end
  end

  def test_a_fourth_round_of_conflicts_aborts_rounds_exceeded
    with_manifest(allowlisted_manifest) do
      Dir.mktmpdir do |tmp|
        path = File.join(tmp, "zz-abc-x")
        FileUtils.mkdir_p(File.join(path, "docs"))

        expect_rebase_start(path: path)

        3.times do |i|
          expect_status([%w[UU docs/plan.md]])
          expect_conflicted_files(["docs/plan.md"])
          expect_blobs("docs/plan.md", base: "one\n", upstream: "one\ntwo#{i}\n", branch: "one\nthree#{i}\n")
          expect_propose("{\"mergeable\": true, \"merged\": \"one\\ntwo#{i}\\nthree#{i}\\n\", \"rationale\": \"r#{i}\"}")
          expect_refute('{"objection": null}')
          expect_add(["docs/plan.md"])
          expect_continue(success: false)
        end

        expect_abort
        code, env = run_resolve([path])

        assert_equal 1, code
        assert_includes @fake.calls.map(&:argv), %w[git rebase --abort]
        assert_conflict_block(env, "rounds_exceeded")
      end
    end
  end

  # --- --dry-run -----------------------------------------------------------------

  def test_dry_run_executes_nothing_and_renders_the_cli_invocation_without_a_real_prompt
    with_manifest(allowlisted_manifest) do
      # No FakeSh expectations registered at all - any Sh.run call would raise.
      code, env = run_resolve(["/wt/zz-abc-x", "--dry-run"])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal "dry_run", env["data"]["status"]
      assert env["commands"].any? { |c| c.include?("git rebase origin/main") }
      assert env["commands"].any? { |c| c.include?("claude") && c.include?("<prompt>") }
      refute env["commands"].any? { |c| c.include?("-p ") && !c.include?("<prompt>") }
    end
  end

  # --- source assertions ----------------------------------------------------------

  def rebase_resolve_source
    @rebase_resolve_source ||= File.read(File.expand_path("../rebase_resolve.rb", __dir__))
  end

  def test_source_never_forces
    refute_match(/--force\b/, rebase_resolve_source)
  end

  def test_source_shells_out_only_through_sh
    assert_empty Contract.system_or_backticks(rebase_resolve_source)
  end

  def test_at_least_twelve_abort_paths_are_asserted_in_this_file
    this_file = File.read(__FILE__)
    count = this_file.scan(/rebase\s+--abort/).length
    assert_operator count, :>=, 12,
                    "expected at least 12 occurrences of 'rebase --abort' in this test file, found #{count}"
  end
end

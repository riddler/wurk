# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/base_ref"
require_relative "../lib/envelope"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"

# base_ref_test.rb is the regression net for the ladder extracted out of
# judge.rb (wu-821 Phase 1): remote-first base resolution, the shared
# `git status --porcelain` parse, the diff+working-tree union, and the
# merge-base helper. judge_test.rb keeps exercising the same ladder through
# Judge itself; this file is the one that owns BaseRef's own unit coverage.
class BaseRefTest < Minitest::Test
  include ManifestHelper

  FIXTURE = "valid"

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
    @env = Envelope.new(script: "base_ref_test")
  end

  def teardown
    @fake.verify!
    Sh.runner = nil
    Manifest.reset!
  end

  # --- resolve --------------------------------------------------------------

  # sabotage: make resolve return the local branch even when the remote
  # candidate's rev-parse succeeds -> this asserts on "origin/main" itself,
  # not merely on "some ref resolved" -> red
  def test_resolve_remote_ref_wins_when_it_resolves
    with_manifest(FIXTURE) do |manifest|
      @fake.expect(%w[git rev-parse --verify --quiet origin/main], exitstatus: 0)

      base = BaseRef.resolve(@env, manifest: manifest)

      assert_equal "origin/main", base
      assert_empty @env.warnings
    end
  end

  # sabotage: drop the `ref == local && override.nil?` guard so a fallback
  # to the local branch never warns -> this test's assert_equal 1 on
  # warnings.length goes red
  def test_resolve_falls_back_to_local_with_exactly_one_warning
    with_manifest(FIXTURE) do |manifest|
      @fake.expect(%w[git rev-parse --verify --quiet origin/main], exitstatus: 1)
      @fake.expect(%w[git rev-parse --verify --quiet main], exitstatus: 0)

      base = BaseRef.resolve(@env, manifest: manifest)

      assert_equal "main", base
      assert_equal 1, @env.warnings.length
      assert_equal "stale_base_ref", @env.warnings.first[:code]
    end
  end

  # sabotage: read a hardcoded "origin/main"/"main" ladder instead of
  # manifest.remote_default_branch/manifest.default_branch -> FakeSh raises
  # UnexpectedCommand (no stub for "origin/main" here, only "origin/trunk")
  # -> red. Proves the ladder was read from the manifest, not hardcoded -
  # the `trunk` fixture is what makes that assertion possible.
  def test_resolve_reads_the_ladder_from_the_manifest
    manifest = manifest_with(FIXTURE, "repo" => { "default_branch" => "trunk" })
    @fake.expect(%w[git rev-parse --verify --quiet origin/trunk], exitstatus: 0)

    base = BaseRef.resolve(@env, manifest: manifest)

    assert_equal "origin/trunk", base
  end

  # sabotage: return the local branch instead of nil when neither rung
  # resolves -> assert_nil goes red
  def test_resolve_returns_nil_when_both_absent
    with_manifest(FIXTURE) do |manifest|
      @fake.expect(%w[git rev-parse --verify --quiet origin/main], exitstatus: 1)
      @fake.expect(%w[git rev-parse --verify --quiet main], exitstatus: 1)

      base = BaseRef.resolve(@env, manifest: manifest)

      assert_nil base
      assert_empty @env.warnings
    end
  end

  # sabotage: try the remote/local candidates before the override, or check
  # them at all once an override is given -> FakeSh raises UnexpectedCommand
  # (only the override's rev-parse is stubbed) -> red
  def test_resolve_override_wins_and_warns_nothing
    with_manifest(FIXTURE) do |manifest|
      @fake.expect(%w[git rev-parse --verify --quiet my-branch], exitstatus: 0)

      base = BaseRef.resolve(@env, manifest: manifest, override: "my-branch")

      assert_equal "my-branch", base
      assert_empty @env.warnings
    end
  end

  # sabotage: an override that happens to equal the local default branch
  # must still warn nothing (an explicit base is not a fallback) - drop the
  # `override.nil?` half of the warn guard -> red
  def test_resolve_override_equal_to_local_branch_still_warns_nothing
    with_manifest(FIXTURE) do |manifest|
      @fake.expect(%w[git rev-parse --verify --quiet main], exitstatus: 0)

      base = BaseRef.resolve(@env, manifest: manifest, override: "main")

      assert_equal "main", base
      assert_empty @env.warnings
    end
  end

  # --- parse_status_porcelain ------------------------------------------------

  def test_parse_status_porcelain_over_modified_added_untracked_renamed
    out = <<~OUT
       M lib/foo.rb
      A  lib/bar.rb
      ?? lib/new_file.rb
      R  lib/old_name.rb -> lib/new_name.rb
    OUT

    assert_equal %w[lib/foo.rb lib/bar.rb lib/new_file.rb lib/new_name.rb],
                 BaseRef.parse_status_porcelain(out)
  end

  # sabotage: drop the `next nil if line.empty?` guard -> a blank trailing
  # line becomes a bogus empty-string path in the result -> red
  def test_parse_status_porcelain_ignores_blank_lines
    assert_equal [], BaseRef.parse_status_porcelain("\n\n")
  end

  # --- changed_files ----------------------------------------------------------

  # sabotage: return diff_files alone (drop the union with working_files) or
  # skip .uniq/.sort -> this exact sorted, deduped array assertion goes red
  def test_changed_files_unions_sorts_and_dedupes
    with_manifest(FIXTURE) do |manifest|
      @fake.expect(%w[git rev-parse --verify --quiet origin/main], exitstatus: 0)
      @fake.expect(%w[git diff --name-only origin/main...HEAD], out: "b.rb\nshared.rb\n")
      @fake.expect(%w[git status --porcelain], out: " M shared.rb\n?? a.rb\n")

      result = BaseRef.changed_files(@env, manifest: manifest)

      assert_equal "origin/main", result[:base]
      assert_equal %w[b.rb shared.rb], result[:diff_files]
      assert_equal %w[a.rb b.rb shared.rb], result[:files]
    end
  end

  # sabotage: keep the diff result instead of degrading to [] plus a
  # no_base_ref warning when the diff itself fails -> this test's
  # assert_equal ["only_working.rb"], result[:files] goes red, and the
  # missing warning check goes red too
  def test_changed_files_degrades_to_working_files_on_a_failed_diff
    with_manifest(FIXTURE) do |manifest|
      @fake.expect(%w[git rev-parse --verify --quiet origin/main], exitstatus: 0)
      @fake.expect(%w[git diff --name-only origin/main...HEAD], exitstatus: 1)
      @fake.expect(%w[git status --porcelain], out: "?? only_working.rb\n")

      result = BaseRef.changed_files(@env, manifest: manifest)

      assert_equal "origin/main", result[:base]
      assert_equal [], result[:diff_files]
      assert_equal ["only_working.rb"], result[:files]
      assert(@env.warnings.any? { |w| w[:code] == "no_base_ref" })
    end
  end

  # sabotage: report [] with no warning when neither rung resolves, instead
  # of degrading to working_files with a no_base_ref warning -> both the
  # files assertion and the warning-code assertion go red
  def test_changed_files_both_absent_degrades_to_working_files_with_no_base_ref_warning
    with_manifest(FIXTURE) do |manifest|
      @fake.expect(%w[git rev-parse --verify --quiet origin/main], exitstatus: 1)
      @fake.expect(%w[git rev-parse --verify --quiet main], exitstatus: 1)
      @fake.expect(%w[git status --porcelain], out: "?? only_working.rb\n")

      result = BaseRef.changed_files(@env, manifest: manifest)

      assert_nil result[:base]
      assert_equal [], result[:diff_files]
      assert_equal ["only_working.rb"], result[:files]
      assert(@env.warnings.any? { |w| w[:code] == "no_base_ref" })
    end
  end

  # sabotage: ignore the `working:` argument and always derive the union via
  # `working_files(env)` -> FakeSh raises UnexpectedCommand (no second
  # `git status --porcelain` stub registered here) -> red
  def test_changed_files_reuses_a_precomputed_working_list_without_reshelling_status
    with_manifest(FIXTURE) do |manifest|
      @fake.expect(%w[git rev-parse --verify --quiet origin/main], exitstatus: 0)
      @fake.expect(%w[git diff --name-only origin/main...HEAD], out: "b.rb\n")

      result = BaseRef.changed_files(@env, manifest: manifest, working: %w[a.rb])

      assert_equal %w[a.rb b.rb], result[:files]
      refute(@fake.calls.any? { |c| c.argv == %w[git status --porcelain] })
    end
  end

  # --- merge_base ---------------------------------------------------------------

  # sabotage: shell out to `git merge-base` even when base is nil -> FakeSh
  # raises UnexpectedCommand (no expectation registered) -> red
  def test_merge_base_returns_nil_for_a_nil_base
    assert_nil BaseRef.merge_base(@env, nil)
  end

  def test_merge_base_returns_the_resolved_sha
    @fake.expect(%w[git merge-base origin/main HEAD], out: "abc1234\n")

    assert_equal "abc1234", BaseRef.merge_base(@env, "origin/main")
  end
end

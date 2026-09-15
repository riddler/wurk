# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/work_tree"
require_relative "../lib/envelope"
require_relative "support/fake_sh"

# work_tree_test.rb is the unit coverage for WorkTree.root - the single
# `git rev-parse --show-toplevel` resolution gate.rb threads through the
# sabotage scan instead of reaching for Manifest#checkout_root (wu-1zu). See
# gate_test.rb for the integration-level regressions this anchor exists to
# fix.
class WorkTreeTest < Minitest::Test
  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
    @env = Envelope.new(script: "work_tree_test")
  end

  def teardown
    @fake.verify!
    Sh.runner = nil
  end

  # sabotage: drop the File.expand_path call and return `out` as-is -> red
  # (a relative or trailing-slash toplevel would fail the exact-path
  # assertion)
  def test_root_is_the_expanded_toplevel_on_success
    @fake.expect(%w[git rev-parse --show-toplevel], out: "/tmp/some/checkout\n")

    assert_equal "/tmp/some/checkout", WorkTree.root(@env)
  end

  # sabotage: return res.out.to_s.strip without the success? guard -> red
  # (a failed rev-parse whose stderr carries "fatal: not a git repository"
  # would come back as "" rather than nil, and the nil assertion fails)
  def test_root_is_nil_when_git_cannot_answer
    @fake.expect(%w[git rev-parse --show-toplevel], exitstatus: 1, err: "fatal: not a git repository")

    assert_nil WorkTree.root(@env)
  end

  # sabotage: drop the `out.empty?` guard -> red (an empty string would be
  # returned as File.expand_path("") == Dir.pwd instead of nil)
  def test_root_is_nil_when_git_succeeds_with_empty_output
    @fake.expect(%w[git rev-parse --show-toplevel], out: "")

    assert_nil WorkTree.root(@env)
  end

  # sabotage: call Sh.run without envelope: env -> red (env.commands stays
  # empty, and ADR-0006 requires every shell-out to land in the trail)
  def test_the_call_lands_in_the_envelopes_commands_trail
    @fake.expect(%w[git rev-parse --show-toplevel], out: "/tmp/some/checkout\n")

    WorkTree.root(@env)

    assert_includes @env.commands, "git rev-parse --show-toplevel"
  end
end

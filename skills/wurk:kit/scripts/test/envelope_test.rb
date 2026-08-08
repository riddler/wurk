# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../lib/envelope"

class EnvelopeTest < Minitest::Test
  def test_shape_and_ok_true_when_nothing_blocked
    env = Envelope.new(script: "example")
    env.data[:foo] = "bar"
    env.commands << "git status"

    parsed = JSON.parse(env.to_json)

    assert_equal true, parsed["ok"]
    assert_equal "example", parsed["script"]
    assert_equal({ "foo" => "bar" }, parsed["data"])
    assert_equal [], parsed["warnings"]
    assert_equal [], parsed["blocked"]
    assert_equal ["git status"], parsed["commands"]
  end

  def test_warnings_do_not_affect_ok
    env = Envelope.new(script: "example")
    env.warn(code: "plt_missing", message: "no PLT found")

    assert env.ok?
    parsed = JSON.parse(env.to_json)
    assert_equal [{ "code" => "plt_missing", "message" => "no PLT found" }], parsed["warnings"]
  end

  def test_block_drives_ok_false
    env = Envelope.new(script: "example")
    env.block!(code: "branch_exists", message: "branch already exists")

    refute env.ok?
    parsed = JSON.parse(env.to_json)
    assert_equal(
      [{ "code" => "branch_exists", "message" => "branch already exists", "needs" => "human" }],
      parsed["blocked"]
    )
  end

  def test_block_needs_defaults_to_human_but_is_overridable
    env = Envelope.new(script: "example")
    env.block!(code: "x", message: "y", needs: "not_human")

    assert_equal "not_human", env.blocked.first[:needs]
  end

  def test_fail_drives_ok_false_without_a_blocked_entry
    env = Envelope.new(script: "example")
    env.fail!

    refute env.ok?
    assert_empty env.blocked
  end

  def test_emit_writes_one_json_line_and_returns_0_when_ok
    env = Envelope.new(script: "example")
    io = StringIO.new

    code = env.emit(io)

    assert_equal 0, code
    lines = io.string.split("\n")
    assert_equal 1, lines.length
    assert JSON.parse(lines.first)
  end

  def test_emit_returns_1_when_blocked
    env = Envelope.new(script: "example")
    env.block!(code: "x", message: "y")
    io = StringIO.new

    code = env.emit(io)

    assert_equal 1, code
    assert_equal false, JSON.parse(io.string)["ok"]
  end

  def test_emit_returns_1_when_failed
    env = Envelope.new(script: "example")
    env.fail!
    io = StringIO.new

    assert_equal 1, env.emit(io)
  end

  def test_commands_accumulate_in_order
    env = Envelope.new(script: "example")
    env.commands << "first"
    env.commands << "second"

    assert_equal %w[first second], JSON.parse(env.to_json)["commands"]
  end
end

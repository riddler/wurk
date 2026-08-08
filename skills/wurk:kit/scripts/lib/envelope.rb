# frozen_string_literal: true

require "json"

# Envelope is the single output shape every script under .claude/scripts/
# prints on stdout. See .claude/scripts/README.md for the contract.
#
# Usage:
#
#   env = Envelope.new(script: "worktree_create")
#   env.data[:path] = "../worktrees/abc-foo"
#   env.commands << "git worktree add ..."
#   env.warn(code: "warm_cache_missing", message: "no build cache found, the first gate run will be slow")
#   env.block!(code: "branch_exists", message: "branch abc-foo already exists", needs: "human")
#   exit env.emit
#
# ok is computed, never set directly: it is true only when nothing was
# blocked and no wrapped command failed (#fail!).
class Envelope
  attr_reader :script, :data, :warnings, :blocked, :commands

  def initialize(script:)
    @script = script
    @data = {}
    @warnings = []
    @blocked = []
    @commands = []
    @failed = false
  end

  # Record a warning. Warnings never affect ok or the exit code - they are
  # informational, read by the model, not routed on.
  def warn(code:, message:)
    @warnings << { code: code, message: message }
    self
  end

  # Record a blocking condition. A blocked script is never "resolved" by the
  # script itself - see CLAUDE.md's authority table and docs/skill-automation.md's
  # "what must never be scripted" list. needs is almost always "human".
  def block!(code:, message:, needs: "human")
    @blocked << { code: code, message: message, needs: needs }
    self
  end

  # Mark that a wrapped command failed (nonzero exit) even though nothing was
  # blocked outright. This still drives ok to false and the exit code to 1.
  def fail!
    @failed = true
    self
  end

  def ok?
    @blocked.empty? && !@failed
  end

  # Serializes the envelope as the single JSON object contract, writes it to
  # the given IO (stdout by default), and returns the process exit code:
  # 0 when ok, 1 when blocked or failed. Never returns 2 - usage errors are
  # a separate, envelope-less path (see lib/cli.rb).
  def emit(io = $stdout)
    io.puts(to_json)
    ok? ? 0 : 1
  end

  def to_h
    {
      "ok" => ok?,
      "script" => script,
      "data" => data,
      "warnings" => warnings,
      "blocked" => blocked,
      "commands" => commands
    }
  end

  def to_json(*args)
    to_h.to_json(*args)
  end
end

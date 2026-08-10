#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/envelope"
require_relative "lib/cli"
require_relative "lib/manifest"

# CommitMessage is pure validation over an already-drafted commit message -
# it never drafts or fixes one. Encodes /wurk:commit Step 2's three hard limits
# (a maximum subject length, a maximum body line length, a maximum total
# line count), the trailer shape, and the Step 4.4 attribution check, so the
# same rules run both pre-commit (over the drafted message) and post-commit
# (over `git log -1 --pretty=format:%B`). See
# statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 12.
#
# All three limits and the trailer KEY are manifest data (`commits.*`): the
# numbers differ per project, and the key models a scheme rather than a
# number - a project projecting its beads onto forge issues writes
# `Closes #12`, not `Refs: st-abc`. The attribution ban below is the one
# thing here that stays hardcoded: it is a universal rule about what must
# never appear in a commit message, not a project's preference.
#
# There is no --fix flag and none will be added - drafting the message is a
# session-model (or Haiku-delegated, per docs/skill-automation.md's Model
# routing) job; this script only reports pass/fail per rule.
module CommitMessage
  # Same substrings /wurk:commit Step 4.4 checks for - kept in exact sync so the
  # pre-commit draft check and the post-commit verification cannot drift.
  ATTRIBUTION_PATTERNS = ["Co-Authored-By", "Generated with", "Claude"].freeze

  class << self
    # Returns an array of {rule:, ok:, message:}, always in the same order.
    # `refs`, when given, is the bead id /wurk:commit Step 1.5 resolved - the
    # trailer rule is only checked when a caller passes one, since /wurk:commit
    # only requires the trailer when a bead was actually resolved ("If no
    # issue, omit this line entirely" - Step 2). Callers with no bead (the
    # rare interactive fallback where the user skips the prompt) omit
    # `refs` and get no trailer check at all, rather than a forced failure.
    def check(text, refs: nil, manifest: Manifest.current)
      lines = text.to_s.each_line.map { |l| l.chomp }
      checks = [
        subject_check(lines, manifest),
        body_line_check(lines, manifest),
        total_lines_check(lines, manifest)
      ]
      checks << refs_check(lines, refs, manifest) if refs
      checks << attribution_check(text)
      checks
    end

    # `commits.subject_under` is an exclusive bound ("under 50"), so the
    # inclusive limit the check compares against is one less. Spelled once,
    # here, rather than at each call site.
    def subject_max(manifest)
      manifest.subject_under - 1
    end

    def trailer_line_re(manifest)
      /\A#{Regexp.escape(manifest.trailer_key)}: (\S+)\z/
    end

    private

    def subject_check(lines, manifest)
      limit = subject_max(manifest)
      subject = lines.first.to_s
      ok = !subject.empty? && subject.length <= limit
      { rule: "subject_length", ok: ok,
        message: "subject line is #{subject.length} characters (limit #{limit})" }
    end

    def body_line_check(lines, manifest)
      limit = manifest.body_line_max
      body = lines[1..-1] || []
      offenders = body.each_with_index.select { |line, _i| line.length > limit }
      ok = offenders.empty?
      message =
        if ok
          "every body line is #{limit} characters or fewer"
        else
          "line(s) over #{limit} characters: #{offenders.map { |_line, i| i + 2 }.join(', ')}"
        end
      { rule: "body_line_length", ok: ok, message: message }
    end

    def total_lines_check(lines, manifest)
      limit = manifest.total_lines_max
      ok = lines.length <= limit
      { rule: "total_lines", ok: ok, message: "message is #{lines.length} lines (limit #{limit})" }
    end

    def refs_check(lines, refs, manifest)
      key = manifest.trailer_key
      non_blank = lines.reject { |l| l.strip.empty? }
      last = non_blank.last.to_s
      m = last.match(trailer_line_re(manifest))
      ok = !m.nil? && m[1] == refs
      expected = "#{key}: #{refs}"
      message = ok ? "\"#{expected}\" present and last" : "expected \"#{expected}\" as the last non-blank line, found #{last.inspect}"
      { rule: "refs_present_and_last", ok: ok, message: message }
    end

    def attribution_check(text)
      hit = ATTRIBUTION_PATTERNS.find { |p| text.to_s.include?(p) }
      ok = hit.nil?
      message = ok ? "no forbidden attribution text found" : "found forbidden attribution text: #{hit.inspect}"
      { rule: "no_attribution", ok: ok, message: message }
    end
  end
end

# The thin CLI: reads the message from stdin (never as an argument - commit
# messages are multi-line and shell-argument-hostile), runs
# CommitMessage.check, and reports each rule's pass/fail in the envelope.
# `check` is accepted as an optional leading subcommand for symmetry with
# the other scripts' subcommand style, and is also the default - there is
# only one thing this script does.
module CommitMessageCli
  class << self
    def run(argv, io: $stdout, stdin: $stdin)
      argv = argv.dup
      argv.shift if argv.first == "check"

      options = { dry_run: false }
      parser, options = Cli.build("commit_message.rb [check] [--refs ID] < message", options) do |opts|
        opts.on("--refs ID", "require the bead trailer for ID present and last") { |v| options[:refs] = v }
      end
      Cli.parse!(parser, argv)

      text = stdin.read

      env = Envelope.new(script: "commit_message")

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest

      results = CommitMessage.check(text, refs: options[:refs], manifest: manifest)

      env.data[:refs_required] = !options[:refs].nil?
      env.data[:checks] = results

      results.each do |r|
        env.block!(code: r[:rule], message: r[:message]) unless r[:ok]
      end

      env.emit(io)
    end
  end
end

exit CommitMessageCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

# frozen_string_literal: true

require "optparse"

# Cli holds the OptionParser setup shared by every script under
# .claude/scripts/, so each script wires the same three flags the same way:
#
#   --dry-run   populate `commands` without executing anything (mutating
#               scripts only - see README.md)
#   --json      accepted for symmetry; JSON is the only output form a script
#               ever produces, so this flag is a no-op that exists so a
#               caller can pass it uniformly
#   --help      prints usage and exits 0
#
# A usage error (unknown flag, missing required argument) exits 2 with a
# plain-text message on stderr and prints no envelope - see README.md's
# exit-code contract.
#
# Usage:
#
#   options = { dry_run: false }
#   parser = Cli.build("worktree_create.rb [options] <name>") do |opts|
#     opts.on("--slug SLUG", "worktree slug") { |v| options[:slug] = v }
#   end
#   args = Cli.parse!(parser, ARGV)
class Cli
  UsageError = Class.new(StandardError)

  class << self
    # Builds an OptionParser pre-wired with --dry-run, --json, --help.
    # Yields the parser so the caller can add script-specific flags into the
    # same banner. Flags are collected into the returned parser; read
    # options[:dry_run] after parsing.
    def build(banner, options = {})
      options[:dry_run] = false unless options.key?(:dry_run)

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: #{banner}"

        opts.on("--dry-run", "populate commands without executing anything") do
          options[:dry_run] = true
        end

        opts.on("--json", "output JSON (default and only form; accepted for symmetry)") do
          # no-op: every script always emits the JSON envelope
        end

        opts.on("--help", "print this help") do
          puts opts
          exit 0
        end

        yield opts if block_given?
      end

      [parser, options]
    end

    # Parses argv against parser. On a usage error, prints a plain-text
    # message to stderr (no envelope) and exits 2, per the README's
    # exit-code contract.
    def parse!(parser, argv)
      parser.parse!(argv)
      argv
    rescue OptionParser::ParseError => e
      warn "#{e.message}\n\n#{parser}"
      exit 2
    end
  end
end

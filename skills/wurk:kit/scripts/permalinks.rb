#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/manifest"
require_relative "lib/forge"

# Permalinks rewrites backtick-quoted `file:line` (and `file:line-line`)
# references in an already-written document into forge permalinks - a pure
# text transform over the document. The URL shape itself belongs to
# lib/forge.rb, which is where a second forge would be taught one. See
# statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 8.
module Permalinks
  # A backtick-quoted file:line reference not already turned into a markdown
  # link. The (?!\]\() guard is what makes rewriting idempotent: a rewritten
  # reference reads "[`file:line`](url)", so its closing backtick is
  # immediately followed by "](" and a second pass matches nothing further.
  # \x60 is a backtick - written as an escape (rather than a literal ` `
  # pair) so this regex source itself doesn't look like a shell backtick
  # invocation to test/contract_test.rb's textual scan.
  #
  # The path class includes ':' because every kit skill directory is named
  # skills/wurk:<name> - without it, references to kit scripts never match
  # as a whole path (see wu-18l). The trailing ':(\d+)' still binds to the
  # LAST colon before the line number: the path class is greedy, so it
  # consumes as much as it can first and only backs off enough to let the
  # required ':digits' suffix match, which for a path containing an interior
  # colon means the interior colon stays part of the path.
  REFERENCE_RE = /\x60([\w][\w\-.\/:]*\.\w+):(\d+)(?:-(\d+))?\x60(?!\]\()/.freeze

  class << self
    def build_url(owner:, repo:, commit:, file:, line:, end_line: nil, kind: "github")
      Forge.blob_url(kind: kind, owner: owner, repo: repo, commit: commit, file: file, line: line, end_line: end_line)
    end

    # Returns [rewritten_text, substitutions], substitutions being an
    # ordered array of {original:, url:}. Text with no file:line reference
    # at all is returned unchanged, with an empty substitutions array.
    #
    # root:, when given, is a repo root to resolve each matched path
    # against; a match whose path does not exist under root is left alone
    # rather than rewritten into a permalink that would 404 (see wu-18l - a
    # bare basename like `permalinks.rb:24` matches the reference shape but
    # is not a real path from the repo root). root: defaults to nil, which
    # preserves the pre-wu-18l behavior of rewriting every match without an
    # existence check - callers that want the guard must pass root
    # explicitly; the CLI does.
    def rewrite(text, owner:, repo:, commit:, kind: "github", root: nil)
      substitutions = []
      rewritten = text.gsub(REFERENCE_RE) do |match|
        file = ::Regexp.last_match(1)
        line = ::Regexp.last_match(2)
        end_line = ::Regexp.last_match(3)
        next match if root && !File.exist?(File.join(root, file))

        url = build_url(owner: owner, repo: repo, commit: commit, file: file, line: line, end_line: end_line, kind: kind)
        substitutions << { original: match, url: url }
        "[#{match}](#{url})"
      end
      [rewritten, substitutions]
    end
  end
end

# The thin CLI: reads gh/git state, applies Permalinks.rewrite, and either
# reports the substitutions (--dry-run) or writes them back to the file.
module PermalinksCli
  class << self
    def run(argv, io: $stdout)
      options = { dry_run: false }
      parser, options = Cli.build("permalinks.rb <path> [--commit SHA]", options) do |opts|
        opts.on("--commit SHA", "defaults to git rev-parse HEAD") { |v| options[:commit] = v }
      end
      args = Cli.parse!(parser, argv)
      path = args.first
      usage_error!("permalinks.rb <path>", parser) if path.to_s.strip.empty?

      env = Envelope.new(script: "permalinks")

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest
      return env.emit(io) unless Forge.guard!(env, manifest, doing: "permalink rewriting")

      unless File.exist?(path)
        env.block!(code: "file_not_found", message: "no such file: #{path}")
        return env.emit(io)
      end

      repo_res = Sh.run(%w[gh repo view --json owner,name], envelope: env)
      unless repo_res.success?
        env.block!(code: "forge_repo_view_failed", message: err_or(repo_res, "gh repo view failed"), needs: "human")
        return env.emit(io)
      end

      parsed = parse_json(repo_res.out)
      owner = parsed && parsed["owner"].is_a?(Hash) ? parsed["owner"]["login"] : nil
      repo = parsed && parsed["name"]
      if owner.to_s.empty? || repo.to_s.empty?
        env.block!(code: "forge_repo_view_unparseable", message: "gh repo view returned unexpected JSON")
        return env.emit(io)
      end

      commit = options[:commit]
      unless commit
        commit_res = Sh.run(%w[git rev-parse HEAD], envelope: env)
        unless commit_res.success?
          env.block!(code: "git_rev_parse_failed", message: err_or(commit_res, "git rev-parse HEAD failed"))
          return env.emit(io)
        end
        commit = commit_res.out.to_s.strip
      end

      # manifest.path is <repo_root>/.claude/wurk.json (or a consumer
      # equivalent); two dirnames up is the repo root, matching the pattern
      # judge.rb already uses to resolve manifest-relative paths.
      repo_root = File.dirname(File.dirname(manifest.path))

      original = File.read(path)
      rewritten, substitutions = Permalinks.rewrite(
        original, owner: owner, repo: repo, commit: commit, kind: manifest.forge_kind, root: repo_root
      )

      env.data[:path] = path
      env.data[:owner] = owner
      env.data[:repo] = repo
      env.data[:commit] = commit
      env.data[:substitutions] = substitutions
      env.data[:count] = substitutions.length
      env.commands << "write #{path} (#{substitutions.length} permalink substitution(s))"

      File.write(path, rewritten) if !options[:dry_run] && !substitutions.empty?

      env.emit(io)
    end

    private

    def parse_json(text)
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    def err_or(result, fallback)
      msg = result.err.to_s.strip
      msg.empty? ? fallback : msg
    end

    def usage_error!(usage_line, parser)
      warn "usage: #{usage_line}\n\n#{parser}"
      exit 2
    end
  end
end

exit PermalinksCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

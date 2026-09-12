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
# lib/forge.rb, which holds one shape per forge; the repo-identity lookup
# that feeds it a project path is per forge too and lives in this file's CLI,
# beside the other shell-outs. See
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
    # `project` is a forge project path, not an owner/repo pair - see
    # Forge.project_path for why the pair could not hold a GitLab identity.
    # `host` is the manifest's forge.host, nil meaning the kind's default.
    def build_url(project:, commit:, file:, line:, end_line: nil, kind: "github", host: nil)
      Forge.blob_url(kind: kind, project: project, commit: commit, file: file, line: line,
                     end_line: end_line, host: host)
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
    def rewrite(text, project:, commit:, kind: "github", host: nil, root: nil)
      substitutions = []
      rewritten = text.gsub(REFERENCE_RE) do |match|
        file = ::Regexp.last_match(1)
        line = ::Regexp.last_match(2)
        end_line = ::Regexp.last_match(3)
        next match if root && !File.exist?(File.join(root, file))

        url = build_url(project: project, commit: commit, file: file, line: line, end_line: end_line,
                        kind: kind, host: host)
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

      identity = repo_identity(manifest.forge_kind, env)
      if identity.project.nil?
        env.block!(code: identity.code, message: identity.message)
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
        original, project: identity.project, commit: commit, kind: manifest.forge_kind,
        host: manifest.forge_host, root: repo_root
      )

      env.data[:path] = path
      env.data[:project] = identity.project
      env.data[:host] = Forge.resolve_host(manifest.forge_kind, manifest.forge_host)
      env.data[:commit] = commit
      env.data[:substitutions] = substitutions
      env.data[:count] = substitutions.length
      env.commands << "write #{path} (#{substitutions.length} permalink substitution(s))"

      File.write(path, rewritten) if !options[:dry_run] && !substitutions.empty?

      env.emit(io)
    end

    private

    # The repo's project path (Forge.project_path), or the block to emit
    # instead. `project` nil is the one signal that the lookup failed; `code`
    # and `message` then carry the envelope block, so a caller cannot read a
    # half-populated identity as a good one. Every block here needs a human,
    # which is Envelope#block!'s own default - hence no `needs` member.
    Identity = Struct.new(:project, :code, :message, keyword_init: true)

    # Which forge answers "what is this repo's project path", per kind - the
    # same adapter shape request_state.rb uses for request state, and for the
    # same reason: the question is one the forge owns, and the git remote is
    # not a substitute (an ssh alias, an insteadOf rewrite, or a fork remote
    # all produce a path the forge would not agree with).
    #
    # Both adapters go through Forge.project_path so the joined shape has one
    # definition site, and both refuse a payload they cannot read rather than
    # building a partial path - see the header of lib/forge.rb's blob_url for
    # why a wrong permalink is the expensive failure here.
    def repo_identity(kind, env)
      case kind
      when "gitlab" then repo_identity_on_gitlab(env)
      else repo_identity_on_github(env)
      end
    end

    # GitHub's CLI has a field allow-list, and the two fields it is asked for
    # are the two segments of the path: `owner.login` and `name`. GitHub
    # namespaces are always exactly two segments deep, so a payload missing
    # either field is unreadable rather than shorter.
    def repo_identity_on_github(env)
      result = Sh.run(%w[gh repo view --json owner,name], envelope: env)
      unless result.success?
        return Identity.new(code: "forge_repo_view_failed",
                            message: err_or(result, "gh repo view failed"))
      end

      parsed = parse_json(result.out)
      owner = parsed && parsed["owner"].is_a?(Hash) ? parsed["owner"]["login"] : nil
      name = parsed && parsed["name"]
      if owner.to_s.strip.empty? || name.to_s.strip.empty?
        return Identity.new(code: "forge_repo_view_unparseable",
                            message: "the forge repo lookup returned unexpected JSON: " \
                                     "owner.login and name are what the project path is built from")
      end

      Identity.new(project: Forge.project_path([owner, name]))
    end

    # GitLab's side asks the REST project endpoint rather than a `repo view`
    # subcommand, for the same two reasons request_state.rb's commits adapter
    # does: the endpoint and its field names are the documented API surface,
    # and `:id` resolution from the current repo's remote is already the pattern
    # in this tree. The field is `path_with_namespace` - the namespace path
    # already "/"-joined and already carrying every subgroup segment, which is
    # the whole reason the identity model is a path.
    #
    # There is no derive-it-from-`web_url` fallback on purpose: a second way to
    # guess the path would make a changed payload look like a success with a
    # subtly different answer, and the block below names the field a reader has
    # to go look at.
    def repo_identity_on_gitlab(env)
      result = Sh.run(%w[glab api projects/:id], envelope: env)
      unless result.success?
        return Identity.new(code: "forge_repo_view_failed",
                            message: err_or(result, "glab api projects/:id failed"))
      end

      parsed = parse_json(result.out)
      namespace_path = parsed.is_a?(Hash) ? parsed["path_with_namespace"] : nil
      if namespace_path.to_s.strip.empty?
        return Identity.new(code: "forge_repo_view_unparseable",
                            message: "the forge repo lookup returned unexpected JSON: " \
                                     "path_with_namespace is what the project path is read from")
      end

      Identity.new(project: Forge.project_path(namespace_path.to_s.split("/")))
    end

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

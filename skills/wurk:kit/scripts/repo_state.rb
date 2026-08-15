#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/refs"
require_relative "lib/gate_paths"
require_relative "lib/manifest"
require_relative "lib/base_ref"

# RepoState answers "where am I, and what's uncommitted or unpushed here" -
# replacing /wurk:work Step 0.5 (locate-self), /wurk:mr Step 1 (establish
# where you are), and half of /wurk:commit Step 0 (the gate-applicability carve-out).
# See statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 2.
module RepoState
  UNPUSHED_FIELD_SEP = "\x1f"
  UNPUSHED_RECORD_SEP = "\x1e"

  class << self
    # statifier-ex ADR-0010 makes the branch name a creation-time label, not an
    # authority, so this never ships as a bare id - always wrapped with the
    # strategy/confidence pair that marks it as a weak guess.
    def decompose_branch(branch)
      return nil unless branch

      m = branch.match(/\A(#{Refs.bead_id})-/)
      m && { id: m[1], strategy: "branch_prefix", confidence: "weak" }
    end

    def parse_unpushed(out)
      out.to_s.split(UNPUSHED_RECORD_SEP).map do |record|
        next nil if record.strip.empty?

        sha, subject, body = record.split(UNPUSHED_FIELD_SEP, 3)
        next nil if sha.to_s.strip.empty?

        { sha: sha[0, 7], subject: subject.to_s, refs: Refs.beads_from_messages([body.to_s]) }
      end.compact
    end

    # Markdown files directly under `dir`. `dir` is manifest data
    # (artifacts.plans, changelog.dir) and may be absent - a project with
    # `changelog.mode: none` has no fragment directory at all, and reporting
    # [] is the honest answer rather than guessing a conventional path.
    def under_dir(files, dir)
      return [] if dir.to_s.empty?

      prefix = dir.to_s.chomp("/")
      files.select { |f| f.start_with?("#{prefix}/") && f.end_with?(".md") }
    end

    def run(argv, io: $stdout)
      parser, _options = Cli.build("repo_state.rb [options]")
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "repo_state")

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest

      git_dir = Sh.run(%w[git rev-parse --git-dir], envelope: env)
      common_dir = Sh.run(%w[git rev-parse --git-common-dir], envelope: env)
      toplevel = Sh.run(%w[git rev-parse --show-toplevel], envelope: env)

      unless git_dir.success? && common_dir.success? && toplevel.success?
        env.block!(code: "not_a_git_repo", message: "not inside a git repository")
        return env.emit(io)
      end

      is_main = File.expand_path(git_dir.out.to_s.strip) == File.expand_path(common_dir.out.to_s.strip)
      root = toplevel.out.to_s.strip
      checkout = is_main ? "main" : "worktree"

      branch_res = Sh.run(%w[git branch --show-current], envelope: env)
      branch = branch_res.out.to_s.strip
      branch = nil if branch.empty?
      branch_bead = decompose_branch(branch)

      # is_main answers "which checkout am I in" (main vs. worktree);
      # on_default_branch answers "which branch am I on" - a different
      # question that only coincides with is_main under worktree-per-issue,
      # where issue work never happens in the main checkout. A branch
      # committed directly in the main checkout is is_main true but
      # on_default_branch false. Detached HEAD (branch is nil) is not the
      # default branch by definition, so it reads false rather than nil.
      on_default_branch = !branch.nil? && branch == manifest.default_branch

      dirty_files = BaseRef.working_files(env)
      dirty = !dirty_files.empty?

      upstream_res = Sh.run(%w[git rev-parse --abbrev-ref --symbolic-full-name @{upstream}], envelope: env)
      upstream = nil
      commits_ahead = nil
      commits_behind = nil
      unpushed = []

      if upstream_res.success?
        upstream = upstream_res.out.to_s.strip

        ahead_res = Sh.run(["git", "rev-list", "--count", "#{upstream}..HEAD"], envelope: env)
        behind_res = Sh.run(["git", "rev-list", "--count", "HEAD..#{upstream}"], envelope: env)
        commits_ahead = ahead_res.success? ? ahead_res.out.to_s.strip.to_i : nil
        commits_behind = behind_res.success? ? behind_res.out.to_s.strip.to_i : nil

        log_format = "%H#{UNPUSHED_FIELD_SEP}%s#{UNPUSHED_FIELD_SEP}%B#{UNPUSHED_RECORD_SEP}"
        log_res = Sh.run(["git", "log", "#{upstream}..HEAD", "--pretty=format:#{log_format}"], envelope: env)
        unpushed = parse_unpushed(log_res.out) if log_res.success?
      else
        env.warn(code: "no_upstream", message: "branch #{branch.inspect} has no upstream tracking branch")
      end

      # Three-dot diff against the resolved base - origin/<default_branch>
      # first, the local default branch as a warned fallback (BaseRef.resolve)
      # - matching /wurk:commit Step 0 and /wurk:mr's gate step exactly, and
      # unioned with the working tree so uncommitted edits are never
      # invisible to area labeling or the gate carve-out. See lib/gate_paths.rb
      # and lib/base_ref.rb.
      changed = BaseRef.changed_files(env, manifest: manifest, working: dirty_files)
      changed_files = changed[:files]
      touches_build = GatePaths.touches_build?(changed_files, manifest: manifest)
      plan_docs = under_dir(changed_files, manifest.plans_dir)
      changelog_fragments = under_dir(changed_files, manifest.changelog_dir)
      refs_beads = unpushed.flat_map { |c| c[:refs] }.uniq.sort

      env.data[:checkout] = checkout
      env.data[:root] = root
      env.data[:branch] = branch
      env.data[:branch_bead] = branch_bead
      env.data[:is_main] = is_main
      env.data[:on_default_branch] = on_default_branch
      env.data[:default_branch] = manifest.default_branch
      env.data[:base_ref] = changed[:base]
      env.data[:dirty] = dirty
      env.data[:dirty_files] = dirty_files
      env.data[:upstream] = upstream
      env.data[:commits_ahead] = commits_ahead
      env.data[:commits_behind] = commits_behind
      env.data[:unpushed] = unpushed
      env.data[:refs_beads] = refs_beads
      env.data[:touches_build] = touches_build
      env.data[:changed_files] = changed_files
      env.data[:plan_docs] = plan_docs
      env.data[:changelog_fragments] = changelog_fragments

      env.emit(io)
    end
  end
end

exit RepoState.run(ARGV) if __FILE__ == $PROGRAM_NAME

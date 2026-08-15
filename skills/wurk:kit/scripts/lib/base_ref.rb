# frozen_string_literal: true

require_relative "manifest"
require_relative "sh"

# One answer to "what did this branch change", for every kit script that
# asks. Two things were wrong with the per-site copies this replaces:
# they diffed against the LOCAL default branch, which under
# worktree-per-issue is routinely behind origin because sibling worktrees
# merge and push without every checkout fetching; and half of them saw
# only committed changes. See wu-821.
module BaseRef
  class << self
    # The first of override, the manifest's remote default branch, and its
    # local default branch that `git rev-parse --verify --quiet` accepts.
    # nil when none resolve. Warns when the remote ref is absent and the
    # local branch is used instead - that answer is knowably stale, and a
    # silent fallback is what this bead is about.
    def resolve(env, manifest: Manifest.current, override: nil)
      remote = manifest.remote_default_branch
      local = manifest.default_branch
      ref = [override, remote, local].compact.find do |candidate|
        Sh.run(["git", "rev-parse", "--verify", "--quiet", candidate], envelope: env).success?
      end
      if ref == local && override.nil?
        env.warn(code: "stale_base_ref",
                 message: "#{remote} did not resolve; diffing against local #{local}, " \
                          "which may be behind the remote")
      end
      ref
    end

    # Working-tree paths: tracked-but-uncommitted plus untracked. The single
    # definition site - repo_state.rb and gate.rb each carried a byte-
    # identical private copy of this parse before wu-821.
    def working_files(env)
      res = Sh.run(%w[git status --porcelain], envelope: env)
      parse_status_porcelain(res.out)
    end

    def parse_status_porcelain(out)
      out.to_s.each_line.map do |line|
        line = line.chomp
        next nil if line.empty?

        path = line[3..-1].to_s
        path.include?(" -> ") ? path.split(" -> ").last : path
      end.compact
    end

    # The untracked subset of the working tree - `??`-status porcelain lines
    # only. A separate shell-out (not a filter over `working_files`, which
    # discards the status prefix) because the sabotage scan needs to tell an
    # untracked path apart from a tracked-dirty one: the former appears in no
    # diff at all, even the two-dot form, and needs its own `unverifiable`
    # report (see gate.rb).
    def untracked_files(env)
      res = Sh.run(%w[git status --porcelain], envelope: env)
      res.out.to_s.each_line.map(&:chomp).reject(&:empty?).select { |l| l.start_with?("??") }.map do |line|
        line[3..-1].to_s
      end
    end

    # Every path this branch touched: the three-dot diff against the
    # resolved base, unioned with the working tree. An unresolvable base
    # warns and degrades to the working tree alone rather than reporting
    # [] - "nothing changed" would be a lie the callers act on.
    #
    # `working:` lets a caller that already has the working-tree list (e.g.
    # repo_state.rb, which needs it separately for `dirty_files`) hand it in
    # rather than have this method shell out `git status --porcelain` again.
    # nil (the default) derives it here, same as before.
    def changed_files(env, manifest: Manifest.current, override: nil, working: nil)
      base = resolve(env, manifest: manifest, override: override)
      diff_files =
        if base
          res = Sh.run(["git", "diff", "--name-only", "#{base}...HEAD"], envelope: env)
          if res.success?
            res.out.to_s.each_line.map(&:strip).reject(&:empty?)
          else
            env.warn(code: "no_base_ref", message: "could not diff against #{base}")
            []
          end
        else
          env.warn(code: "no_base_ref", message: "no default-branch ref resolved")
          []
        end

      working_list = working || working_files(env)
      { base: base, diff_files: diff_files, files: (diff_files + working_list).uniq.sort }
    end

    # merge-base of the resolved base and HEAD, for callers that want a
    # TWO-dot diff (which includes uncommitted tracked edits) rather than a
    # name list. nil when the base does not resolve. Mirrors judge.rb.
    def merge_base(env, base)
      return nil unless base

      sha = Sh.run(["git", "merge-base", base, "HEAD"], envelope: env).out.to_s.strip
      sha.empty? ? nil : sha
    end
  end
end

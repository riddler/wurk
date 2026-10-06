#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require "pathname"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"

# WorktreeSalvage takes a copy of what a worktree holds that no commit holds,
# before anyone hands that worktree to a new writer. It exists for the
# conductor's takeover path: a worker that stalled or was killed leaves
# staged, unstaged and untracked work behind, the takeover brief already
# names that work, and nothing kept a copy of it. A fresh worker that "reads
# uncommitted edits critically" and decides to start over can lose it in one
# command, and untracked files are the easiest to lose because no git
# operation can bring them back.
#
#   worktree_salvage.rb --out <salvage-root> [--dry-run] <worktree>
#
# Two halves, and they are not equally durable:
#
# - Tracked changes (staged and unstaged, including newly added files):
#   `git stash create` builds a stash commit and prints its sha. It writes no
#   ref and changes no file in the worktree, which is why it is safe to run
#   under a live tree - and also why the sha is only as durable as the
#   object: nothing references it, so a later gc may prune it. The caller
#   records the sha (the conductor journals it); `git stash store` or a
#   branch at that sha is how a human would pin it, and this script does
#   neither.
# - Untracked files: `git stash create` never includes them, so each one is
#   copied under the salvage root at its path relative to the worktree. The
#   copy is the durable half. Ignored files are not salvaged - they are
#   caches and build output by definition, and a worktree's warm caches are
#   rebuilt, not rescued.
#
# The salvage root is a REQUIRED argument: a kit script carries no consumer
# path, so it has no default. It is refused when it sits inside the worktree
# being salvaged (removing the worktree at cleanup would delete the salvage
# with it), inside any git directory, or inside any other git work tree where
# it is not ignored - salvaged files must never land where `git add -A` can
# carry them into a commit. A root under a git-excluded state dir (the
# conductor's campaign state) passes that check. A non-empty root is refused
# too, so a second salvage never overwrites the first.
#
# What it never does: git clean, git stash push/pop/apply/drop, reset,
# checkout, or any write inside the worktree. The worktree's
# `git status --porcelain` output is compared before and after, and a
# difference is reported, because it means some other writer is live there.
module WorktreeSalvage
  STATUS_ARGV = %w[git status --porcelain=v1 -z --untracked-files=all].freeze

  class << self
    def run(argv, io: $stdout)
      options = { out: nil }
      parser, options = Cli.build("worktree_salvage.rb --out DIR [--dry-run] <worktree>", options) do |opts|
        opts.on("--out DIR", "salvage root the untracked copies go under (required)") { |v| options[:out] = v }
      end
      args = Cli.parse!(parser, argv)
      if options[:out].to_s.empty? || args.length != 1
        warn "worktree_salvage.rb needs --out DIR and exactly one worktree path\n\n#{parser}"
        return 2
      end

      env = Envelope.new(script: "worktree_salvage")
      salvage(env, File.expand_path(args.first), File.expand_path(options[:out]), dry_run: options[:dry_run])
      env.emit(io)
    end

    # Parses `git status --porcelain=v1 -z` output into [[xy, path], ...].
    # A rename or copy entry carries its source path as the following
    # NUL-separated field, which is consumed here and not reported as an
    # entry of its own.
    def parse_status_z(text)
      fields = text.to_s.split("\0")
      entries = []
      until fields.empty?
        field = fields.shift
        next if field.empty?

        xy = field[0, 2]
        entries << [xy, field[3..-1]]
        fields.shift if xy.include?("R") || xy.include?("C")
      end
      entries
    end

    private

    def salvage(env, worktree_arg, out_arg, dry_run:)
      env.data[:dry_run] = dry_run

      top = Sh.run(%w[git rev-parse --show-toplevel], chdir: worktree_arg, envelope: env)
      unless top.success?
        env.block!(code: "not_a_work_tree",
                   message: "#{worktree_arg} is not inside a git work tree. Fix: pass the worktree's path.")
        return
      end
      worktree = File.realpath(top.out.strip)
      env.data[:worktree] = worktree

      root = resolve_root(out_arg)
      env.data[:out] = root
      return unless root_allowed?(env, worktree, root)

      before = Sh.run(STATUS_ARGV, chdir: worktree, envelope: env)
      unless before.success?
        env.block!(code: "status_failed", message: "git status failed in #{worktree}: #{before.err.to_s.strip}")
        return
      end

      head = Sh.run(%w[git rev-parse --verify --quiet HEAD], chdir: worktree, envelope: env)
      env.data[:head] = head.success? ? head.out.strip : nil

      entries = parse_status_z(before.out)
      untracked = entries.select { |xy, _| xy == "??" }.map { |_, path| path }
      tracked = entries.reject { |xy, _| xy == "??" }.map { |_, path| path }
      env.data[:tracked_changes] = tracked
      env.data[:untracked] = untracked

      env.data[:stash_sha] = stash(env, worktree, tracked, dry_run)
      copy_untracked(env, worktree, root, untracked, dry_run)

      after = Sh.run(STATUS_ARGV, chdir: worktree, envelope: env)
      unchanged = after.success? && after.out == before.out
      env.data[:status_unchanged] = unchanged
      return if unchanged

      env.warn(code: "status_changed_during_salvage",
               message: "#{worktree}'s git status differed after the salvage. This script writes nothing " \
                        "there, so another writer is live in it: stand it down before any takeover.")
    end

    # The root as an absolute path with every existing ancestor resolved
    # through realpath, so a symlinked parent cannot hide which tree it is in.
    def resolve_root(out_arg)
      existing = out_arg
      rest = []
      until File.exist?(existing) || existing == File.dirname(existing)
        rest.unshift(File.basename(existing))
        existing = File.dirname(existing)
      end
      File.join(File.realpath(existing), *rest)
    end

    def nearest_existing_dir(path)
      dir = path
      dir = File.dirname(dir) until File.directory?(dir) || dir == File.dirname(dir)
      dir
    end

    def inside?(path, dir)
      path == dir || path.start_with?(dir.end_with?(File::SEPARATOR) ? dir : dir + File::SEPARATOR)
    end

    def root_allowed?(env, worktree, root)
      if inside?(root, worktree)
        env.block!(code: "salvage_root_in_worktree",
                   message: "salvage root #{root} is inside the worktree being salvaged (#{worktree}); " \
                            "removing that worktree would delete the salvage. Fix: pass an --out outside it.")
        return false
      end

      probe_dir = nearest_existing_dir(root)
      where = Sh.run(%w[git rev-parse --is-inside-git-dir --is-inside-work-tree], chdir: probe_dir, envelope: env)
      if where.success?
        in_git_dir, in_work_tree = where.out.split("\n").map(&:strip)
        if in_git_dir == "true"
          env.block!(code: "salvage_root_in_git_dir",
                     message: "salvage root #{root} is inside a git directory. Fix: pass an --out outside any repository.")
          return false
        end
        if in_work_tree == "true"
          ignored = Sh.run(["git", "check-ignore", "-q", root], chdir: probe_dir, envelope: env)
          unless ignored.success?
            env.block!(code: "salvage_root_in_work_tree",
                       message: "salvage root #{root} is inside a git work tree and not ignored there, so a " \
                                "commit could carry the salvaged files. Fix: pass an --out outside any work " \
                                "tree, or under a directory that tree ignores (a git-excluded state dir).")
            return false
          end
        end
      end

      if File.exist?(root) && !(File.directory?(root) && Dir.empty?(root))
        env.block!(code: "salvage_root_not_empty",
                   message: "salvage root #{root} already exists and is not an empty directory; a salvage never " \
                            "overwrites an earlier one. Fix: pass a fresh --out.")
        return false
      end

      true
    end

    def stash(env, worktree, tracked, dry_run)
      return nil if tracked.empty? || dry_run

      res = Sh.run(%w[git stash create], chdir: worktree, envelope: env)
      unless res.success?
        env.block!(code: "stash_create_failed",
                   message: "git stash create failed in #{worktree}: #{res.err.to_s.strip}. The tracked changes " \
                            "are NOT salvaged; nothing in the worktree was changed.")
        return nil
      end
      sha = res.out.strip
      return sha unless sha.empty?

      env.warn(code: "stash_create_empty",
               message: "git status listed tracked changes but git stash create built nothing for them")
      nil
    end

    def copy_untracked(env, worktree, root, untracked, dry_run)
      copied = []
      would_copy = []
      not_copied = []

      untracked.each do |rel|
        src = File.join(worktree, rel)
        if rel.end_with?("/") || (File.directory?(src) && !File.symlink?(src))
          # --untracked-files=all lists files one by one; a directory entry
          # here is an embedded repository, which a file copy would flatten.
          not_copied << { path: rel, reason: "nested_repository" }
          next
        end
        if dry_run
          would_copy << rel
          next
        end

        dest = File.join(root, rel)
        FileUtils.mkdir_p(File.dirname(dest))
        if File.symlink?(src)
          File.symlink(File.readlink(src), dest)
        else
          FileUtils.cp(src, dest, preserve: true)
        end
        copied << rel
      end

      env.data[:copied] = copied
      env.data[:would_copy] = would_copy
      env.data[:not_copied] = not_copied
      return if not_copied.empty?

      env.warn(code: "untracked_not_copied",
               message: "not copied (an embedded repository): #{not_copied.map { |n| n[:path] }.join(', ')}. " \
                        "Name it in the takeover brief; it is not salvaged.")
    end
  end
end

exit WorktreeSalvage.run(ARGV) if __FILE__ == $PROGRAM_NAME

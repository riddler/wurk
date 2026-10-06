# frozen_string_literal: true

require "digest"
require_relative "sh"
require_relative "gate_paths"

# TreeSnapshot answers one question for the gate: did running the gate
# command change the tree it was measuring? A stage that writes to the
# tree it measures (a formatter run in fix mode, a test that leaves a file
# behind, a generator that rewrites a checked-in artifact) makes the green
# it reports a statement about a tree that no longer exists, and nothing
# else in the kit notices it.
#
# The method is a per-path signature taken before and after the gate
# command: `git status --porcelain` names every path that differs from
# HEAD (tracked edits and untracked files alike), and each such path is
# paired with its two-letter status and a content hash. A path whose pair
# moved between the two snapshots is a path the gate run changed. That
# covers the four shapes that matter:
#
# - a clean tracked file the gate edits (absent before, present after);
# - a file already dirty before the run that the gate edits again (same
#   status, different hash) - which a status-only diff would miss;
# - a file already dirty before and untouched by the run (identical pair,
#   not reported - the operator's own uncommitted edit is not the gate's);
# - an untracked file the gate creates (absent before, `??` after).
#
# The snapshot itself writes nothing: `--no-optional-locks` keeps git from
# refreshing the index as a side effect of `status`, and the hashes are
# reads. Ignored paths (build output, caches) are invisible to
# `git status` and so never reported - a gate is expected to write those.
#
# Paths are repo-root-relative, the same as every other path list the
# manifest carries, so the allowlist (repo.daemon_written_paths) is matched
# with GatePaths.match_one?: a trailing "/" is a directory prefix, anything
# else an exact path, no globbing.
module TreeSnapshot
  # `-z` so paths arrive unquoted whatever bytes they contain;
  # `--untracked-files=all` so a new file inside a new directory is named
  # as itself rather than as the directory, which is what gives it a
  # content hash.
  STATUS_ARGV = %w[git --no-optional-locks status --porcelain=v1 -z --untracked-files=all].freeze

  class << self
    # { path => "XY signature" } for every path git status lists under
    # `root`, minus any path under an `exclude` prefix (a runner's own
    # in-tree log directory, which it writes to on purpose). nil when
    # git status itself failed - the caller cannot tell "nothing changed"
    # from "could not look", and must not report the former.
    def take(root, envelope: nil, exclude: [])
      res = Sh.run(STATUS_ARGV.dup, chdir: root, envelope: envelope)
      return nil unless res.success?

      parse(res.out).each_with_object({}) do |(xy, path), snap|
        next if exclude.any? { |prefix| path.start_with?(prefix) }

        snap[path] = "#{xy} #{signature(File.join(root, path))}"
      end
    end

    # Porcelain v1 with -z: "XY path\0", and for a rename or copy
    # "XY new\0old\0" - the origin is its own NUL-terminated field, which
    # is skipped (the new path is the one whose content is on disk).
    def parse(out)
      fields = out.to_s.split("\0")
      entries = []
      until fields.empty?
        field = fields.shift
        next if field.length < 4

        xy = field[0, 2]
        entries << [xy, field[3..]]
        fields.shift if xy.include?("R") || xy.include?("C")
      end
      entries
    end

    # The sorted paths whose signature differs between two snapshots,
    # including a path present in only one of them.
    def changed(before, after)
      (before.keys | after.keys).reject { |path| before[path] == after[path] }.sort
    end

    # Splits `paths` into [allowed, blocking] by the allowlist entries.
    def partition(paths, allow)
      paths.partition { |path| allow.any? { |entry| GatePaths.match_one?(path, entry) } }
    end

    # The gate-side verdict over two snapshots, shared by gate.rb and
    # gate_run.rb's supervisor so the long-gate runner reports the same
    # fields the same way. Writes `data.tree_changed` (every path whose
    # signature moved) and `data.tree_changed_allowed` (the subset `allow`
    # claims), and blocks `gate_wrote_tree` on any changed path outside
    # `allow`, naming the paths. A nil snapshot (git status failed) leaves
    # both keys null and warns `tree_snapshot_failed` - the check could not
    # run, which is not the same claim as "the gate wrote nothing".
    def check!(env, root:, allow:, before:, after:)
      if before.nil? || after.nil?
        env.data[:tree_changed] = nil
        env.data[:tree_changed_allowed] = nil
        env.warn(
          code: "tree_snapshot_failed",
          message: "git status failed in #{root}, so whether the gate run wrote to the tree was not " \
                   "checked; data.tree_changed is null, which is not the same as []"
        )
        return env
      end

      changed_paths = changed(before, after)
      allowed, blocking = partition(changed_paths, allow)
      env.data[:tree_changed] = changed_paths
      env.data[:tree_changed_allowed] = allowed
      return env if blocking.empty?

      one = blocking.length == 1
      env.block!(
        code: "gate_wrote_tree",
        message: "the gate run changed #{blocking.join(', ')} in the tree it was measuring, so its result " \
                 "describes a tree that no longer exists. Fix: find the stage that writes " \
                 "#{one ? 'that path' : 'those paths'} and stop it writing into the tree (or write under " \
                 "an ignored path); only if a daemon writes #{one ? 'it' : 'them'} on its own, declare " \
                 "#{one ? 'it' : 'them'} in repo.daemon_written_paths"
      )
    end

    # A content signature that never raises: a regular file's sha256, a
    # symlink's target, or a word for anything that has no content to hash.
    def signature(abs)
      stat = File.lstat(abs)
      if stat.symlink?
        "link:#{File.readlink(abs)}"
      elsif stat.file?
        "sha256:#{Digest::SHA256.file(abs).hexdigest}"
      elsif stat.directory?
        "dir"
      else
        "other"
      end
    rescue Errno::ENOENT, Errno::ENOTDIR
      "absent"
    rescue SystemCallError
      "unreadable"
    end
  end
end

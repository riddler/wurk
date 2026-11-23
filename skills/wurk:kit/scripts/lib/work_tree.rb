# frozen_string_literal: true

require_relative "sh"

# The root of the git working tree the process is standing in. Distinct from
# Manifest#checkout_root, which is the root of the checkout the MANIFEST was
# found in: the two differ whenever the working tree carries no
# .claude/wurk.json of its own (a worktree of a consumer that gitignores
# .claude/, or a worktree nested under the main checkout, whose walk-up finds
# an ancestor's copy). Every kit question about TRACKED TREE CONTENT - what a
# git pathspec matches, whether a tracked file exists, where a gate command
# should run - resolves against this; questions about siblings of the
# manifest inside .claude/ stay on checkout_root. See wu-1zu.
#
# --show-toplevel rather than --git-common-dir or a Dir.pwd walk: it is
# invariant across subdirectories within one checkout (the property wu-9fb's
# checkout_root was introduced for) and per-worktree correct (the property
# wu-1zu needs). No other anchor has both.
#
# nil when git cannot answer - outside any working tree, or inside a bare
# repository. Callers decide; see gate.rb, which warns and falls back.
module WorkTree
  class << self
    def root(env)
      res = Sh.run(%w[git rev-parse --show-toplevel], envelope: env)
      return nil unless res.success?

      out = res.out.to_s.strip
      out.empty? ? nil : File.expand_path(out)
    end
  end
end

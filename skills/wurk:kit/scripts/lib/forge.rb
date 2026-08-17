# frozen_string_literal: true

require_relative "manifest"

# Forge is the one place that answers "which code host is this repo on, and
# is that a host these scripts actually implement?".
#
# The manifest's `forge.kind` enum accepts `gitlab` because the schema is
# shared with a repo that lives there (see wurk docs/manifest.md). Nothing
# under .claude/scripts implements it yet: PR state comes from `gh`, and the
# permalink format is GitHub's `/blob/` shape. Until the GitLab work lands,
# every entry point that depends on the forge stops here with a named block
# rather than half-working - a `gh` call against a GitLab repo fails with a
# message about authentication, which sends the reader somewhere useless.
module Forge
  # Forges these scripts implement today. Growing this list is the phase-4
  # work, not a configuration change.
  IMPLEMENTED = %w[github].freeze

  # The kit's own word for "this request landed". Deliberately not a
  # passthrough of any forge's state enum: GitHub spells it "MERGED" and
  # GitLab spells it "merged", so a forge adapter maps its own value onto
  # this one rather than the kit comparing against whichever casing the
  # forge it was written against happened to use.
  REQUEST_MERGED = "merged"

  module_function

  def implemented?(kind)
    IMPLEMENTED.include?(kind)
  end

  # Records the block on `env` and returns false when the manifest names a
  # forge these scripts cannot drive; returns true otherwise. Callers stop
  # and emit on false.
  def guard!(env, manifest, doing:)
    kind = manifest.forge_kind
    return true if implemented?(kind)

    env.block!(
      code: "unsupported_forge",
      message: "forge.kind is #{kind.inspect} in #{manifest.path}; #{doing} is implemented for #{IMPLEMENTED.join(', ')} only",
      needs: "human"
    )
    false
  end

  # The blob-permalink shape, per forge. Only GitHub's is defined; asking
  # for another raises rather than guessing a URL that would 404 silently in
  # a document nobody re-reads.
  def blob_url(kind:, owner:, repo:, commit:, file:, line:, end_line: nil)
    raise ArgumentError, "no permalink format for forge.kind #{kind.inspect}" unless kind == "github"

    anchor = end_line ? "L#{line}-L#{end_line}" : "L#{line}"
    "https://github.com/#{owner}/#{repo}/blob/#{commit}/#{file}##{anchor}"
  end
end

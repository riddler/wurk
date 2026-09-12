# frozen_string_literal: true

require_relative "manifest"

# Forge is the one place that answers "which code host is this repo on, and
# is that a host these scripts actually implement?".
#
# The manifest's `forge.kind` enum accepts `gitlab` because the schema is
# shared with a repo that lives there (see wurk docs/manifest.md). Support is
# per capability, not per repo: request-state detection speaks both forges
# (see `pr_state.rb`), while permalink writing is still GitHub-shaped - the
# `/blob/` URL below and the repo-identity lookup in `permalinks.rb`. A
# capability a forge has no adapter for stops here with a named block rather
# than half-working - a `gh` call against a GitLab repo fails with a message
# about authentication, which sends the reader somewhere useless.
#
# This module is also the definition site for the kit's forge-neutral
# vocabulary - envelope codes, data keys, and synthesized values like
# `REQUEST_MERGED` below name no forge CLI, so they stay meaningful once a
# second forge adapter lands. `test/contract_test.rb`'s `FORGE_VOCABULARY`
# rule is what keeps that true: it fails the gate if a `gh_`/`glab_`-shaped
# identifier or a forge's own quoted state literal (`"MERGED"`, ...) shows up
# anywhere in `scripts/` outside a comment or an argv behind `guard!`.
module Forge
  # Forges whose request state these scripts can read today, and the default
  # list `guard!` checks against. Growing a list is adapter work, not a
  # configuration change.
  IMPLEMENTED = %w[github gitlab].freeze

  # Forges whose permalink shape these scripts can write. Narrower than
  # IMPLEMENTED on purpose: `blob_url` below renders one host's URL shape,
  # and `permalinks.rb` learns owner/repo from a GitHub-only lookup. A caller
  # that writes permalinks passes this list to `guard!`; when the remaining
  # forge's permalink model lands, this constant and that argument go away
  # together.
  PERMALINK_IMPLEMENTED = %w[github].freeze

  # The kit's own word for "this request landed". Deliberately not a
  # passthrough of any forge's state enum: GitHub spells it "MERGED" and
  # GitLab spells it "merged", so a forge adapter maps its own value onto
  # this one rather than the kit comparing against whichever casing the
  # forge it was written against happened to use.
  REQUEST_MERGED = "merged"

  module_function

  def implemented?(kind, forges = IMPLEMENTED)
    effective(forges).include?(kind)
  end

  # Records the block on `env` and returns false when the manifest names a
  # forge this capability has no adapter for; returns true otherwise. Callers
  # stop and emit on false. `forges:` is the capability's own list, defaulting
  # to the request-state one.
  def guard!(env, manifest, doing:, forges: IMPLEMENTED)
    kind = manifest.forge_kind
    return true if implemented?(kind, forges)

    env.block!(
      code: "unsupported_forge",
      message: "forge.kind is #{kind.inspect} in #{manifest.path}; #{doing} is implemented for #{effective(forges).join(', ')} only",
      needs: "human"
    )
    false
  end

  # Test seam, the same shape as Manifest's `current=`: narrows the
  # implemented-forge list for the duration of a block. Every kind the
  # manifest schema accepts now has a request-state adapter, so the
  # unsupported-forge path - which exists for the forge after these, and
  # which each entry point must refuse in its own voice rather than relay
  # from a script it drives - is otherwise unreachable from a fixture. Tests
  # narrow the list here instead of the suite growing a mocking library.
  def with_implemented(forges)
    previous = @narrowed
    @narrowed = forges
    yield
  ensure
    @narrowed = previous
  end

  def effective(forges)
    @narrowed || forges
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

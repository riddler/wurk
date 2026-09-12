# frozen_string_literal: true

require_relative "manifest"

# Forge is the one place that answers "which code host is this repo on, and
# is that a host these scripts actually implement?".
#
# The manifest's `forge.kind` enum accepts `gitlab` because the schema is
# shared with a repo that lives there (see wurk docs/manifest.md). Every kind
# the enum accepts now has an adapter for every capability: request-state
# detection (`pr_state.rb`) and permalink writing (the `blob_url` shape below
# plus the repo-identity lookup in `permalinks.rb`) both speak both forges.
# `guard!` therefore checks one list - a capability that half-works is worse
# than one that stops with a named block, because a `gh` call against a GitLab
# repo fails with a message about authentication, which sends the reader
# somewhere useless.
#
# This module is also the definition site for the kit's forge-neutral
# vocabulary - envelope codes, data keys, and synthesized values like
# `REQUEST_MERGED` below name no forge CLI, so they stay meaningful once a
# second forge adapter lands. `test/contract_test.rb`'s `FORGE_VOCABULARY`
# rule is what keeps that true: it fails the gate if a `gh_`/`glab_`-shaped
# identifier or a forge's own quoted state literal (`"MERGED"`, ...) shows up
# anywhere in `scripts/` outside a comment or an argv behind `guard!`.
module Forge
  # Forges these scripts implement today, for every capability, and the list
  # `guard!` checks against. Growing it is adapter work, not a configuration
  # change.
  #
  # There was briefly a second, narrower list here (`PERMALINK_IMPLEMENTED`,
  # wu-mya.7) for the capabilities the gitlab adapter had not reached yet, and
  # `guard!` took the capability's list as an argument. wu-4wl.1 landed the
  # gitlab permalink shape, which made the two lists identical, so both the
  # constant and the argument are gone - a per-capability split that no
  # capability differs on is a seam a reader has to check before trusting the
  # guard. Reintroduce it the same way if a third forge lands one capability
  # at a time.
  IMPLEMENTED = %w[github gitlab].freeze

  # The host each forge kind answers on when the manifest declares no
  # `forge.host`. These are facts about the forge, not consumer constants
  # (CLAUDE.md's no-consumer-constants rule): every GitHub.com repo is on
  # github.com whichever repo installs the kit, and a consumer whose instance
  # is elsewhere - self-hosted GitLab, GitHub Enterprise - says so in its own
  # manifest rather than the kit carrying its hostname.
  DEFAULT_HOSTS = {
    "github" => "github.com",
    "gitlab" => "gitlab.com"
  }.freeze

  # The blob-permalink shape, per forge: the path infix that sits between the
  # project path and `blob`, and how a line RANGE is spelled in the fragment.
  # Both differ, and neither is derivable from the other forge's shape:
  #
  #   github  https://github.com/owner/repo/blob/<sha>/<file>#L12-L30
  #   gitlab  https://gitlab.com/group/sub/proj/-/blob/<sha>/<file>#L12-30
  #
  # GitLab's `-/` separator is what keeps a project path of any depth
  # unambiguous - without it the last namespace segment and the `blob`
  # keyword share one namespace - and its range anchor repeats no `L`. A kind
  # absent from this table has no shape, and `blob_url` raises for it rather
  # than guessing a URL that would 404 silently inside a document nobody
  # re-reads.
  BLOB_SHAPES = {
    "github" => { infix: "", range_prefix: "L" },
    "gitlab" => { infix: "-/", range_prefix: "" }
  }.freeze

  # The kit's own word for "this request landed". Deliberately not a
  # passthrough of any forge's state enum: GitHub spells it "MERGED" and
  # GitLab spells it "merged", so a forge adapter maps its own value onto
  # this one rather than the kit comparing against whichever casing the
  # forge it was written against happened to use.
  REQUEST_MERGED = "merged"

  module_function

  def implemented?(kind)
    effective.include?(kind)
  end

  # Records the block on `env` and returns false when the manifest names a
  # forge these scripts have no adapter for; returns true otherwise. Callers
  # stop and emit on false.
  def guard!(env, manifest, doing:)
    kind = manifest.forge_kind
    return true if implemented?(kind)

    env.block!(
      code: "unsupported_forge",
      message: "forge.kind is #{kind.inspect} in #{manifest.path}; #{doing} is implemented for #{effective.join(', ')} only",
      needs: "human"
    )
    false
  end

  # Test seam, the same shape as Manifest's `current=`: narrows the
  # implemented-forge list for the duration of a block. Every kind the
  # manifest schema accepts now has an adapter for every capability, so the
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

  def effective
    @narrowed || IMPLEMENTED
  end

  # A repo's identity on its forge, as ONE string of "/"-joined namespace
  # segments - the project path. This replaced an `owner` + `repo` pair
  # (wu-4wl.1): a pair is a two-segment model, and GitLab's project path can
  # be `group/subgroup/project` or deeper, so the pair could not hold a real
  # GitLab repo's identity at all. A path holds both - GitHub's identity is
  # simply its two-segment case, which is why this is not a per-forge shape
  # like BLOB_SHAPES above.
  #
  # Blank segments are dropped rather than producing an empty path segment:
  # the two forges' identity lookups return different fields (see
  # `permalinks.rb`), and a half-parsed payload must fail the caller's
  # segment check, not quietly build `owner//` into a URL.
  def project_path(segments)
    Array(segments).map { |segment| segment.to_s.strip }.reject(&:empty?).join("/")
  end

  # The forge host to write links against: the manifest's `forge.host` when it
  # declares one (a self-hosted GitLab, a GitHub Enterprise instance),
  # otherwise the kind's default. Returns nil for a kind with no default,
  # which is `blob_url`'s signal to raise.
  def resolve_host(kind, configured = nil)
    declared = configured.to_s.strip
    return declared unless declared.empty?

    DEFAULT_HOSTS[kind]
  end

  # The blob permalink for one file:line (or file:line-line) reference.
  # `project` is a project path (see `project_path`); `host` overrides the
  # kind's default host. Raises rather than guessing for a kind with no shape
  # or a project path that did not parse - a wrong permalink 404s silently
  # inside a document nobody re-reads, so not writing one is the cheaper
  # failure.
  def blob_url(kind:, project:, commit:, file:, line:, end_line: nil, host: nil)
    shape = BLOB_SHAPES[kind]
    raise ArgumentError, "no permalink format for forge.kind #{kind.inspect}" unless shape

    resolved_host = resolve_host(kind, host)
    path = project.to_s.strip
    raise ArgumentError, "no project path to build a #{kind} permalink from" if path.empty?

    anchor = end_line ? "L#{line}-#{shape[:range_prefix]}#{end_line}" : "L#{line}"
    "https://#{resolved_host}/#{path}/#{shape[:infix]}blob/#{commit}/#{file}##{anchor}"
  end
end

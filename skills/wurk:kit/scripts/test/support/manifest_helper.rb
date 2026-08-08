# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require_relative "../../lib/manifest"

# The fixture-manifest convention, in one place. Every test that exercises a
# manifest-derived value drives it from test/fixtures/manifests/, never from
# the repo's real .claude/wurk.json - a test asserting "st-" would go green
# for the wrong reason (this repo happens to be statifier) and red the day a
# sibling repo runs the same suite.
#
#   include ManifestHelper
#
#   def test_something
#     with_manifest("valid") { assert_equal "zz", Manifest.current.bead_prefix }
#   end
#
# The `valid` fixture deliberately uses prefix "zz" and `make` gate commands
# so nothing in it can be confused with this repo's own values.
module ManifestHelper
  FIXTURE_DIR = File.expand_path(File.join(__dir__, "..", "fixtures", "manifests"))

  module_function

  def fixture_path(name)
    File.join(FIXTURE_DIR, "#{name}.json")
  end

  def fixture_manifest(name)
    path = fixture_path(name)
    Manifest.new(path: path, raw: JSON.parse(File.read(path)))
  end

  # Installs a fixture manifest as Manifest.current for the block, restoring
  # whatever was there afterward (nothing, normally - Manifest.reset! puts
  # the process back to "not yet located").
  def with_manifest(name_or_manifest)
    previous = Manifest.instance_variable_get(:@current)
    manifest = name_or_manifest.is_a?(Manifest) ? name_or_manifest : fixture_manifest(name_or_manifest)
    Manifest.current = manifest
    yield manifest
  ensure
    Manifest.current = previous
  end

  # A scratch repo that carries a manifest: a tmpdir with the named fixture
  # installed at .claude/wurk.json, chdir'd into for the block. Scripts that
  # locate their own manifest by walking up need this rather than a bare
  # mktmpdir - inside a bare one the walk-up finds nothing and falls through
  # to `git rev-parse`, which FakeSh correctly refuses.
  def in_tmp_repo(fixture = "valid")
    Manifest.reset!
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".claude"))
      FileUtils.cp(fixture_path(fixture), File.join(dir, ".claude", "wurk.json"))
      Dir.chdir(dir) { yield dir }
    end
  ensure
    Manifest.reset!
  end

  # Every path any fixture manifest declares as gate configuration
  # (gate.moving_files) or as the gate-change ledger (gate.guard_ledger),
  # deduped. The contract test's guarded-write scan runs against this union:
  # which files are gate config is consumer data, so the kit cannot carry a
  # fixed list, and the fixtures are the only per-consumer shapes this repo
  # legitimately knows about (ADR-0006).
  #
  # Widening the guard therefore means adding the path to a fixture, which
  # is the same edit a real consumer makes in its own wurk.json.
  def all_fixture_guarded_paths
    Dir.glob(File.join(FIXTURE_DIR, "*.json")).sort.flat_map { |path|
      raw = begin
        JSON.parse(File.read(path))
      rescue JSON::ParserError
        next [] # the `malformed` fixture is deliberately unparseable
      end
      gate = raw["gate"]
      next [] unless gate.is_a?(Hash)

      Array(gate["moving_files"]) + Array(gate["guard_ledger"])
    }.compact.uniq
  end

  # Builds a one-off manifest from the named fixture with `overrides` deep-
  # merged in, for the cases where a test needs one field different (a
  # gitlab forge, a branch-in-place parallelism model) and nothing else.
  def manifest_with(name, overrides)
    raw = JSON.parse(File.read(fixture_path(name)))
    Manifest.new(path: fixture_path(name), raw: deep_merge(raw, overrides))
  end

  def deep_merge(base, overrides)
    base.merge(overrides) do |_key, old, new|
      old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
    end
  end
end

# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require_relative "../../lib/manifest"
require_relative "home_guard"

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

  # A scratch WORKTREE: the manifest is installed in a sibling checkout and the
  # block runs in a directory that carries no manifest of its own, so
  # Manifest#checkout_root and the working tree are DIFFERENT paths. This is
  # the shape in_tmp_repo cannot express, and the only shape in which wu-1zu's
  # bug is visible: with the two equal, every anchor looks correct.
  #
  # `nested: true` puts the worktree under the manifest's checkout instead of
  # beside it, which reaches the same divergence through Manifest.locate's
  # walk-up (case C of wu-1zu's research) rather than its --git-common-dir
  # fallback (case A) - and so needs no rev-parse stub at all. The caller
  # stubs --git-common-dir for the sibling form; see gate_test.rb.
  #
  # Yields the working-tree path and the manifest's checkout root, in that
  # order: a test that conflates them is the bug under test.
  def in_tmp_worktree(fixture = "valid", nested: false)
    Manifest.reset!
    Dir.mktmpdir do |dir|
      main = nested ? dir : File.join(dir, "main")
      tree = File.join(main, "wt")
      tree = File.join(dir, "wt") unless nested
      refute_manifest_above(dir) unless nested
      FileUtils.mkdir_p(File.join(main, ".claude"))
      FileUtils.cp(fixture_path(fixture), File.join(main, ".claude", "wurk.json"))
      FileUtils.mkdir_p(tree)
      Dir.chdir(tree) { yield tree, main }
    end
  ensure
    Manifest.reset!
  end

  # Manifest.walk_up reads the real filesystem from Dir.pwd, so HomeGuard
  # cannot shield this fixture the way it shields UserConfig - if anything
  # above Dir.tmpdir carries a manifest, the walk-up escapes and this fixture
  # silently tests the walk-up branch instead of the fallback. Fail loudly at
  # construction rather than produce a test that passes for the wrong reason.
  def refute_manifest_above(dir)
    probe = dir
    loop do
      found = File.join(probe, Manifest::FILENAME)
      raise "in_tmp_worktree: #{found} is on the walk-up path from #{dir}, so " \
            "Manifest.locate will find it instead of falling through to " \
            "--git-common-dir; run the suite with a TMPDIR outside any checkout" if File.file?(found)

      parent = File.dirname(probe)
      break if parent == probe

      probe = parent
    end
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

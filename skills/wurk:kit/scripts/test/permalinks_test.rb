# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../permalinks"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"

# Permalinks (pure text transform).
class PermalinksLibTest < Minitest::Test
  # --- build_url ------------------------------------------------------

  def test_build_url_single_line
    url = Permalinks.build_url(owner: "riddler", repo: "statifier-ex", commit: "abc1234",
                                file: "lib/statifier/interpreter.ex", line: "123")

    assert_equal "https://github.com/riddler/statifier-ex/blob/abc1234/lib/statifier/interpreter.ex#L123", url
  end

  # sabotage: let Forge.blob_url fall through to the GitHub format for any
  # kind instead of raising -> red. A guessed URL 404s silently inside a
  # document nobody re-reads, which is worse than not writing one.
  def test_build_url_refuses_a_forge_it_has_no_format_for
    assert_raises(ArgumentError) do
      Permalinks.build_url(owner: "o", repo: "r", commit: "abc1234",
                           file: "lib/foo.rb", line: "1", kind: "gitlab")
    end
  end

  def test_build_url_line_range
    url = Permalinks.build_url(owner: "riddler", repo: "statifier-ex", commit: "abc1234",
                                file: "lib/statifier/interpreter.ex", line: "123", end_line: "145")

    assert_equal "https://github.com/riddler/statifier-ex/blob/abc1234/lib/statifier/interpreter.ex#L123-L145", url
  end

  # --- rewrite ----------------------------------------------------------

  def test_rewrite_replaces_a_single_line_reference
    text = "See `lib/statifier/interpreter.ex:123` for details."

    rewritten, subs = Permalinks.rewrite(text, owner: "o", repo: "r", commit: "c")

    assert_equal(
      "See [`lib/statifier/interpreter.ex:123`](https://github.com/o/r/blob/c/lib/statifier/interpreter.ex#L123) for details.",
      rewritten
    )
    assert_equal 1, subs.length
    assert_equal "`lib/statifier/interpreter.ex:123`", subs.first[:original]
  end

  def test_rewrite_replaces_a_line_range_reference
    text = "`docs/workflow.md:147-191` names the rule."

    rewritten, = Permalinks.rewrite(text, owner: "o", repo: "r", commit: "c")

    assert_includes rewritten, "#L147-L191"
  end

  def test_rewrite_leaves_non_file_line_text_alone
    text = "Plain prose with no backtick references, and a `bare code span`, " \
           "and a version number 2.1.220, and a `zz-a42` bead id."

    rewritten, subs = Permalinks.rewrite(text, owner: "o", repo: "r", commit: "c")

    assert_equal text, rewritten
    assert_equal [], subs
  end

  def test_rewrite_multiple_references_in_document_order
    text = "First `a/b.ex:1`, then `c/d.ex:2-3`."

    _rewritten, subs = Permalinks.rewrite(text, owner: "o", repo: "r", commit: "c")

    assert_equal ["`a/b.ex:1`", "`c/d.ex:2-3`"], subs.map { |s| s[:original] }
  end

  def test_rewrite_is_idempotent
    text = "See `lib/statifier/interpreter.ex:123` and `docs/workflow.md:1-2` for details."

    once, first_subs = Permalinks.rewrite(text, owner: "o", repo: "r", commit: "c")
    twice, second_subs = Permalinks.rewrite(once, owner: "o", repo: "r", commit: "c")

    assert_equal once, twice
    assert_equal 2, first_subs.length
    assert_equal [], second_subs
  end

  # --- rewrite: colon-bearing paths (wu-18l) -----------------------------
  #
  # Every kit skill directory is named skills/wurk:<name>, so a reference
  # into a kit script always has an interior colon before the line-number
  # colon. These prove REFERENCE_RE's path class accepts ':' and that the
  # trailing ':(\d+)' still binds to the LAST colon rather than the first.

  def test_rewrite_replaces_a_colon_bearing_path_reference
    text = "See `skills/wurk:kit/scripts/permalinks.rb:24` for details."

    rewritten, subs = Permalinks.rewrite(text, owner: "o", repo: "r", commit: "c")

    assert_equal(
      "See [`skills/wurk:kit/scripts/permalinks.rb:24`]" \
      "(https://github.com/o/r/blob/c/skills/wurk:kit/scripts/permalinks.rb#L24) for details.",
      rewritten
    )
    assert_equal 1, subs.length
  end

  def test_rewrite_colon_bearing_path_with_line_range_binds_to_the_last_colon
    text = "`skills/wurk:kit/scripts/permalinks.rb:12-30` is the file."

    rewritten, = Permalinks.rewrite(text, owner: "o", repo: "r", commit: "c")

    assert_includes rewritten, "skills/wurk:kit/scripts/permalinks.rb#L12-L30"
  end

  def test_build_url_colon_bearing_path
    url = Permalinks.build_url(owner: "o", repo: "r", commit: "c",
                                file: "skills/wurk:kit/scripts/permalinks.rb", line: "24")

    assert_equal "https://github.com/o/r/blob/c/skills/wurk:kit/scripts/permalinks.rb#L24", url
  end

  # --- rewrite: root: existence guard (wu-18l) ---------------------------
  #
  # root: is nil by default, which preserves the pre-wu-18l behavior
  # (asserted by every test above, none of which pass root:). Passing root:
  # turns on the existence check that keeps a bare basename - or any
  # unresolvable path - from being rewritten into a URL that 404s.

  def test_rewrite_with_root_leaves_an_unresolvable_bare_basename_alone
    Dir.mktmpdir do |root|
      text = "`permalinks.rb:24`"

      rewritten, subs = Permalinks.rewrite(text, owner: "o", repo: "r", commit: "c", root: root)

      assert_equal text, rewritten
      assert_equal [], subs
    end
  end

  def test_rewrite_with_root_rewrites_a_path_that_exists
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      File.write(File.join(root, "lib", "foo.rb"), "")
      text = "`lib/foo.rb:5`"

      rewritten, subs = Permalinks.rewrite(text, owner: "o", repo: "r", commit: "c", root: root)

      assert_equal 1, subs.length
      assert_includes rewritten, "lib/foo.rb#L5"
    end
  end

  def test_rewrite_with_root_rewrites_a_colon_bearing_path_that_exists
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "skills", "wurk:kit", "scripts"))
      File.write(File.join(root, "skills", "wurk:kit", "scripts", "permalinks.rb"), "")
      text = "`skills/wurk:kit/scripts/permalinks.rb:24`"

      rewritten, subs = Permalinks.rewrite(text, owner: "o", repo: "r", commit: "c", root: root)

      assert_equal 1, subs.length
      assert_includes rewritten, "skills/wurk:kit/scripts/permalinks.rb#L24"
    end
  end

  def test_rewrite_with_root_is_idempotent_for_colon_paths
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "skills", "wurk:kit", "scripts"))
      File.write(File.join(root, "skills", "wurk:kit", "scripts", "permalinks.rb"), "")
      text = "See `skills/wurk:kit/scripts/permalinks.rb:24` and `nonexistent.rb:1` for details."

      once, first_subs = Permalinks.rewrite(text, owner: "o", repo: "r", commit: "c", root: root)
      twice, second_subs = Permalinks.rewrite(once, owner: "o", repo: "r", commit: "c", root: root)

      assert_equal once, twice
      assert_equal 1, first_subs.length
      assert_equal [], second_subs
      assert_includes once, "`nonexistent.rb:1`"
    end
  end
end

# PermalinksCli, driven through FakeSh (gh/git) and tmpdir documents.
class PermalinksCliTest < Minitest::Test
  include ManifestHelper

  FIXTURE = "worktree"

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
  end

  def run_cli(argv, fixture: FIXTURE)
    io = StringIO.new
    code = nil
    with_manifest(fixture) { code = PermalinksCli.run(argv, io: io) }
    [code, JSON.parse(io.string)]
  end

  # sabotage: drop the Forge.guard! call from permalinks.rb -> the CLI
  # shells out to `gh repo view` and FakeSh raises UnexpectedCommand -> red
  def test_a_gitlab_repo_blocks_before_touching_the_document
    Dir.mktmpdir do |tmp|
      path = File.join(tmp, "doc.md")
      original = "see `lib/foo.rb:12`\n"
      File.write(path, original)

      code, env = run_cli([path], fixture: "forge_gitlab")

      assert_equal 1, code
      assert_equal "unsupported_forge", env["blocked"].first["code"]
      assert_equal original, File.read(path)
      assert_empty @fake.calls
    end
  end

  def gh_repo_view_json
    JSON.generate({ "owner" => { "login" => "riddler" }, "name" => "statifier-ex" })
  end

  def test_rewrites_and_writes_the_file_by_default
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "See `lib/statifier/interpreter.ex:42` please.\n")

      @fake.expect(%w[gh repo view --json owner,name], out: gh_repo_view_json)
      @fake.expect(%w[git rev-parse HEAD], out: "deadbee1234\n")

      code, env = run_cli([path])

      assert_equal 0, code
      assert_equal "riddler", env["data"]["owner"]
      assert_equal "statifier-ex", env["data"]["repo"]
      assert_equal "deadbee1234", env["data"]["commit"]
      assert_equal 1, env["data"]["count"]

      updated = File.read(path)
      assert_includes updated, "https://github.com/riddler/statifier-ex/blob/deadbee1234/lib/statifier/interpreter.ex#L42"
    end
  end

  def test_dry_run_reports_substitutions_but_does_not_write
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      original = "See `lib/statifier/interpreter.ex:42` please.\n"
      File.write(path, original)

      @fake.expect(%w[gh repo view --json owner,name], out: gh_repo_view_json)
      @fake.expect(%w[git rev-parse HEAD], out: "deadbee1234\n")

      code, env = run_cli([path, "--dry-run"])

      assert_equal 0, code
      assert_equal 1, env["data"]["count"]
      assert_equal original, File.read(path)
    end
  end

  def test_explicit_commit_skips_the_git_rev_parse_call
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "See `lib/statifier/interpreter.ex:42` please.\n")

      @fake.expect(%w[gh repo view --json owner,name], out: gh_repo_view_json)

      _code, env = run_cli([path, "--commit", "custom-sha", "--dry-run"])

      assert_equal "custom-sha", env["data"]["commit"]
    end
  end

  def test_gh_failure_blocks_needs_human_never_falls_back
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "no references here\n")

      @fake.expect(%w[gh repo view --json owner,name], exitstatus: 1, err: "not authenticated\n")

      code, env = run_cli([path])

      assert_equal 1, code
      assert_equal "gh_repo_view_failed", env["blocked"].first["code"]
      assert_equal "human", env["blocked"].first["needs"]
    end
  end

  def test_missing_file_blocks
    _code, env = run_cli(["/no/such/file.md"])

    assert_equal "file_not_found", env["blocked"].first["code"]
  end

  # The CLI's repo root is two dirnames up from manifest.path (see judge.rb
  # for the same convention); for the "worktree" fixture that resolves to
  # test/fixtures, so a reference resolves iff a real file sits there.
  # test/fixtures/lib/statifier/interpreter.ex and
  # test/fixtures/skills/wurk:kit/scripts/example.rb exist for exactly this.

  def test_rewrites_a_colon_bearing_path_reference
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "See `skills/wurk:kit/scripts/example.rb:3` please.\n")

      @fake.expect(%w[gh repo view --json owner,name], out: gh_repo_view_json)
      @fake.expect(%w[git rev-parse HEAD], out: "deadbee1234\n")

      code, env = run_cli([path])

      assert_equal 0, code
      assert_equal 1, env["data"]["count"]
      updated = File.read(path)
      assert_includes updated,
                       "https://github.com/riddler/statifier-ex/blob/deadbee1234/skills/wurk:kit/scripts/example.rb#L3"
    end
  end

  # sabotage: drop the root: argument from the CLI's Permalinks.rewrite call
  # -> the pre-wu-18l default (no existence check) comes back -> this
  # basename gets rewritten into a 404 URL instead of being left alone -> red
  def test_leaves_a_bare_basename_that_does_not_resolve_untouched
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      original = "See `interpreter.ex:42` please.\n"
      File.write(path, original)

      @fake.expect(%w[gh repo view --json owner,name], out: gh_repo_view_json)
      @fake.expect(%w[git rev-parse HEAD], out: "deadbee1234\n")

      code, env = run_cli([path])

      assert_equal 0, code
      assert_equal 0, env["data"]["count"]
      assert_equal original, File.read(path)
    end
  end

  def test_no_references_writes_nothing_and_reports_zero
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      original = "nothing to rewrite here\n"
      File.write(path, original)

      @fake.expect(%w[gh repo view --json owner,name], out: gh_repo_view_json)
      @fake.expect(%w[git rev-parse HEAD], out: "deadbee1234\n")

      code, env = run_cli([path])

      assert_equal 0, code
      assert_equal 0, env["data"]["count"]
      assert_equal original, File.read(path)
    end
  end
end

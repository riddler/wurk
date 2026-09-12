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
    url = Permalinks.build_url(project: "riddler/statifier-ex", commit: "abc1234",
                                file: "lib/statifier/interpreter.ex", line: "123")

    assert_equal "https://github.com/riddler/statifier-ex/blob/abc1234/lib/statifier/interpreter.ex#L123", url
  end

  # sabotage: let Forge.blob_url fall through to the GitHub format for any
  # kind instead of raising -> red. A guessed URL 404s silently inside a
  # document nobody re-reads, which is worse than not writing one.
  def test_build_url_refuses_a_forge_it_has_no_format_for
    assert_raises(ArgumentError) do
      Permalinks.build_url(project: "o/r", commit: "abc1234",
                           file: "lib/foo.rb", line: "1", kind: "bitbucket")
    end
  end

  # sabotage: build the gitlab URL without the "-/" infix, or with GitHub's
  # "L12-L30" range anchor -> red. Both are the shapes GitLab does NOT use,
  # and both produce a link that resolves to nothing.
  def test_build_url_gitlab_single_line
    url = Permalinks.build_url(project: "group/project", commit: "abc1234",
                               file: "lib/foo.rb", line: "12", kind: "gitlab")

    assert_equal "https://gitlab.com/group/project/-/blob/abc1234/lib/foo.rb#L12", url
  end

  def test_build_url_gitlab_line_range_anchor_repeats_no_l
    url = Permalinks.build_url(project: "group/project", commit: "abc1234",
                               file: "lib/foo.rb", line: "12", end_line: "30", kind: "gitlab")

    assert_equal "https://gitlab.com/group/project/-/blob/abc1234/lib/foo.rb#L12-30", url
  end

  # The case the owner/repo pair could not express at all - the reason the
  # identity model is a path (see Forge.project_path).
  def test_build_url_gitlab_nested_subgroups
    url = Permalinks.build_url(project: "group/subgroup/deeper/project", commit: "abc1234",
                               file: "lib/foo.rb", line: "7", kind: "gitlab")

    assert_equal "https://gitlab.com/group/subgroup/deeper/project/-/blob/abc1234/lib/foo.rb#L7", url
  end

  # sabotage: ignore host: and keep the kind's default -> red. A self-hosted
  # consumer's every permalink would point at gitlab.com, where the project
  # does not exist.
  def test_build_url_honors_a_self_hosted_host
    url = Permalinks.build_url(project: "group/sub/project", commit: "abc1234",
                               file: "lib/foo.rb", line: "7", kind: "gitlab",
                               host: "gitlab.example.com:8443")

    assert_equal "https://gitlab.example.com:8443/group/sub/project/-/blob/abc1234/lib/foo.rb#L7", url
  end

  def test_build_url_refuses_an_empty_project_path
    assert_raises(ArgumentError) do
      Permalinks.build_url(project: "", commit: "abc1234", file: "lib/foo.rb", line: "1")
    end
  end

  def test_build_url_line_range
    url = Permalinks.build_url(project: "riddler/statifier-ex", commit: "abc1234",
                                file: "lib/statifier/interpreter.ex", line: "123", end_line: "145")

    assert_equal "https://github.com/riddler/statifier-ex/blob/abc1234/lib/statifier/interpreter.ex#L123-L145", url
  end

  # --- rewrite ----------------------------------------------------------

  def test_rewrite_replaces_a_single_line_reference
    text = "See `lib/statifier/interpreter.ex:123` for details."

    rewritten, subs = Permalinks.rewrite(text, project: "o/r", commit: "c")

    assert_equal(
      "See [`lib/statifier/interpreter.ex:123`](https://github.com/o/r/blob/c/lib/statifier/interpreter.ex#L123) for details.",
      rewritten
    )
    assert_equal 1, subs.length
    assert_equal "`lib/statifier/interpreter.ex:123`", subs.first[:original]
  end

  def test_rewrite_replaces_a_line_range_reference
    text = "`docs/workflow.md:147-191` names the rule."

    rewritten, = Permalinks.rewrite(text, project: "o/r", commit: "c")

    assert_includes rewritten, "#L147-L191"
  end

  def test_rewrite_leaves_non_file_line_text_alone
    text = "Plain prose with no backtick references, and a `bare code span`, " \
           "and a version number 2.1.220, and a `zz-a42` bead id."

    rewritten, subs = Permalinks.rewrite(text, project: "o/r", commit: "c")

    assert_equal text, rewritten
    assert_equal [], subs
  end

  def test_rewrite_multiple_references_in_document_order
    text = "First `a/b.ex:1`, then `c/d.ex:2-3`."

    _rewritten, subs = Permalinks.rewrite(text, project: "o/r", commit: "c")

    assert_equal ["`a/b.ex:1`", "`c/d.ex:2-3`"], subs.map { |s| s[:original] }
  end

  def test_rewrite_is_idempotent
    text = "See `lib/statifier/interpreter.ex:123` and `docs/workflow.md:1-2` for details."

    once, first_subs = Permalinks.rewrite(text, project: "o/r", commit: "c")
    twice, second_subs = Permalinks.rewrite(once, project: "o/r", commit: "c")

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

    rewritten, subs = Permalinks.rewrite(text, project: "o/r", commit: "c")

    assert_equal(
      "See [`skills/wurk:kit/scripts/permalinks.rb:24`]" \
      "(https://github.com/o/r/blob/c/skills/wurk:kit/scripts/permalinks.rb#L24) for details.",
      rewritten
    )
    assert_equal 1, subs.length
  end

  def test_rewrite_colon_bearing_path_with_line_range_binds_to_the_last_colon
    text = "`skills/wurk:kit/scripts/permalinks.rb:12-30` is the file."

    rewritten, = Permalinks.rewrite(text, project: "o/r", commit: "c")

    assert_includes rewritten, "skills/wurk:kit/scripts/permalinks.rb#L12-L30"
  end

  def test_build_url_colon_bearing_path
    url = Permalinks.build_url(project: "o/r", commit: "c",
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

      rewritten, subs = Permalinks.rewrite(text, project: "o/r", commit: "c", root: root)

      assert_equal text, rewritten
      assert_equal [], subs
    end
  end

  def test_rewrite_with_root_rewrites_a_path_that_exists
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      File.write(File.join(root, "lib", "foo.rb"), "")
      text = "`lib/foo.rb:5`"

      rewritten, subs = Permalinks.rewrite(text, project: "o/r", commit: "c", root: root)

      assert_equal 1, subs.length
      assert_includes rewritten, "lib/foo.rb#L5"
    end
  end

  def test_rewrite_with_root_rewrites_a_colon_bearing_path_that_exists
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "skills", "wurk:kit", "scripts"))
      File.write(File.join(root, "skills", "wurk:kit", "scripts", "permalinks.rb"), "")
      text = "`skills/wurk:kit/scripts/permalinks.rb:24`"

      rewritten, subs = Permalinks.rewrite(text, project: "o/r", commit: "c", root: root)

      assert_equal 1, subs.length
      assert_includes rewritten, "skills/wurk:kit/scripts/permalinks.rb#L24"
    end
  end

  def test_rewrite_with_root_is_idempotent_for_colon_paths
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "skills", "wurk:kit", "scripts"))
      File.write(File.join(root, "skills", "wurk:kit", "scripts", "permalinks.rb"), "")
      text = "See `skills/wurk:kit/scripts/permalinks.rb:24` and `nonexistent.rb:1` for details."

      once, first_subs = Permalinks.rewrite(text, project: "o/r", commit: "c", root: root)
      twice, second_subs = Permalinks.rewrite(once, project: "o/r", commit: "c", root: root)

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

  # sabotage: drop the Forge.guard! call from permalinks.rb -> the CLI shells
  # out to a forge CLI and FakeSh raises UnexpectedCommand -> red.
  #
  # Both kinds the schema accepts now have a permalink shape, so the
  # unsupported-forge path is only reachable by narrowing the implemented list
  # - the same seam request_state_test.rb uses, and the reason
  # Forge.with_implemented exists. Narrowing to github alone makes the gitlab
  # fixture the unsupported case again.
  def test_an_unimplemented_forge_blocks_before_touching_the_document
    Dir.mktmpdir do |tmp|
      path = File.join(tmp, "doc.md")
      original = "see `lib/foo.rb:12`\n"
      File.write(path, original)

      code, env = Forge.with_implemented(%w[github]) do
        run_cli([path], fixture: "forge_gitlab")
      end

      assert_equal 1, code
      assert_equal "unsupported_forge", env["blocked"].first["code"]
      assert_equal original, File.read(path)
      assert_empty @fake.calls
    end
  end

  def repo_view_json
    JSON.generate({ "owner" => { "login" => "riddler" }, "name" => "statifier-ex" })
  end

  # The GitLab identity payload, as the REST project object spells it: the
  # namespace path arrives already joined, subgroups included.
  def project_api_json(path_with_namespace = "group/subgroup/project")
    JSON.generate({ "id" => 1234, "path_with_namespace" => path_with_namespace })
  end

  # sabotage: keep the `gh repo view` lookup for every kind -> FakeSh raises
  # UnexpectedCommand on the gitlab fixture -> red. sabotage: emit the GitHub
  # URL shape for gitlab -> the asserted "-/" infix is gone -> red.
  def test_a_gitlab_repo_rewrites_with_the_gitlab_shape_and_subgroups
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "See `lib/statifier/interpreter.ex:42` please.\n")

      @fake.expect(%w[glab api projects/:id], out: project_api_json)
      @fake.expect(%w[git rev-parse HEAD], out: "deadbee1234\n")

      code, env = run_cli([path], fixture: "forge_gitlab")

      assert_equal 0, code
      assert_equal "group/subgroup/project", env["data"]["project"]
      assert_equal "gitlab.com", env["data"]["host"]
      assert_equal 1, env["data"]["count"]
      assert_includes File.read(path),
                      "https://gitlab.com/group/subgroup/project/-/blob/deadbee1234/" \
                      "lib/statifier/interpreter.ex#L42"
    end
  end

  # sabotage: read the manifest's forge.host nowhere -> the link points at
  # gitlab.com, where a self-hosted consumer's project does not exist -> red.
  def test_a_self_hosted_forge_host_from_the_manifest_reaches_the_url
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "See `lib/statifier/interpreter.ex:42` please.\n")

      @fake.expect(%w[glab api projects/:id], out: project_api_json("team/tools"))
      @fake.expect(%w[git rev-parse HEAD], out: "deadbee1234\n")

      manifest = manifest_with("forge_gitlab", "forge" => { "host" => "gitlab.example.com" })
      io = StringIO.new
      code = with_manifest(manifest) { PermalinksCli.run([path], io: io) }
      env = JSON.parse(io.string)

      assert_equal 0, code
      assert_equal "gitlab.example.com", env["data"]["host"]
      assert_includes File.read(path),
                      "https://gitlab.example.com/team/tools/-/blob/deadbee1234/" \
                      "lib/statifier/interpreter.ex#L42"
    end
  end

  # sabotage: fall back to deriving the path from another field, or to a blank
  # project, instead of blocking -> a permalink built on a guess -> red.
  def test_a_gitlab_payload_without_the_namespace_path_blocks
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      original = "See `lib/statifier/interpreter.ex:42` please.\n"
      File.write(path, original)

      @fake.expect(%w[glab api projects/:id], out: JSON.generate({ "id" => 1234 }))

      code, env = run_cli([path], fixture: "forge_gitlab")

      assert_equal 1, code
      assert_equal "forge_repo_view_unparseable", env["blocked"].first["code"]
      assert_equal original, File.read(path)
    end
  end

  def test_a_gitlab_lookup_failure_blocks_needs_human
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "no references here\n")

      @fake.expect(%w[glab api projects/:id], exitstatus: 1, err: "not authenticated\n")

      code, env = run_cli([path], fixture: "forge_gitlab")

      assert_equal 1, code
      assert_equal "forge_repo_view_failed", env["blocked"].first["code"]
      assert_equal "human", env["blocked"].first["needs"]
    end
  end

  def test_rewrites_and_writes_the_file_by_default
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "See `lib/statifier/interpreter.ex:42` please.\n")

      @fake.expect(%w[gh repo view --json owner,name], out: repo_view_json)
      @fake.expect(%w[git rev-parse HEAD], out: "deadbee1234\n")

      code, env = run_cli([path])

      assert_equal 0, code
      assert_equal "riddler/statifier-ex", env["data"]["project"]
      assert_equal "github.com", env["data"]["host"]
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

      @fake.expect(%w[gh repo view --json owner,name], out: repo_view_json)
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

      @fake.expect(%w[gh repo view --json owner,name], out: repo_view_json)

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
      assert_equal "forge_repo_view_failed", env["blocked"].first["code"]
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

      @fake.expect(%w[gh repo view --json owner,name], out: repo_view_json)
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

      @fake.expect(%w[gh repo view --json owner,name], out: repo_view_json)
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

      @fake.expect(%w[gh repo view --json owner,name], out: repo_view_json)
      @fake.expect(%w[git rev-parse HEAD], out: "deadbee1234\n")

      code, env = run_cli([path])

      assert_equal 0, code
      assert_equal 0, env["data"]["count"]
      assert_equal original, File.read(path)
    end
  end
end

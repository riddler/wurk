# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../doc_meta"
require_relative "support/manifest_helper"
require_relative "support/fake_sh"

# DocMeta (pure filename/frontmatter logic).
class DocMetaLibTest < Minitest::Test
  # --- build_filename -----------------------------------------------------

  def test_build_filename_without_an_issue_id
    filename = DocMeta.build_filename(date_stamp: "260802", description: "Improve Error Events")

    assert_equal "260802-improve-error-events.md", filename
  end

  def test_build_filename_with_an_issue_id
    filename = DocMeta.build_filename(date_stamp: "260802", description: "parallel exit sets", issue: "zz-a42")

    assert_equal "260802-zz-a42-parallel-exit-sets.md", filename
  end

  def test_build_filename_with_a_dotted_issue_id
    filename = DocMeta.build_filename(date_stamp: "260802", description: "w3c xsl predicator datamodel", issue: "zz-00p.5")

    assert_equal "260802-zz-00p.5-w3c-xsl-predicator-datamodel.md", filename
  end

  def test_build_filename_reproduces_this_bead_s_real_plan_filename
    filename = DocMeta.build_filename(date_stamp: "260806", description: "skill-mechanics-scripts", issue: "zz-hzf")

    assert_equal "260806-zz-hzf-skill-mechanics-scripts.md", filename
  end

  def test_kebab_collapses_punctuation_and_repeated_hyphens
    assert_equal "a-b-c", DocMeta.kebab("A -- B__C")
    assert_equal "already-kebab", DocMeta.kebab("already-kebab")
    assert_equal "trimmed", DocMeta.kebab("  -trimmed- ")
  end

  # --- frontmatter round-trip ----------------------------------------------

  def test_frontmatter_round_trips_scalar_and_array_fields
    fields = {
      "date" => "2026-08-06T17:16:38-0600",
      "researcher" => "Claude",
      "git_commit" => "af543224c7a803b3ac07fae3bec0a505c6387f6",
      "branch" => "zz-hzf-skill-mechanics-scripts",
      "repository" => "statifier-ex",
      "beads_issue" => "zz-hzf",
      "topic" => "Extracting deterministic skill mechanics into shared scripts",
      "tags" => %w[research skills tooling],
      "status" => "complete",
      "last_updated" => "2026-08-06",
      "last_updated_by" => "Claude"
    }

    rendered = DocMeta.render_frontmatter(fields)
    parsed = DocMeta.parse_frontmatter(rendered)

    fields.each do |key, value|
      assert_equal value, parsed[key], "field #{key.inspect} did not round-trip"
    end
  end

  def test_frontmatter_omits_absent_optional_fields
    fields = {
      "date" => "2026-08-06T17:16:38-0600", "researcher" => "Claude", "git_commit" => "abc1234",
      "branch" => "main", "repository" => "statifier-ex", "topic" => "T", "tags" => [],
      "status" => "complete", "last_updated" => "2026-08-06", "last_updated_by" => "Claude"
    }

    rendered = DocMeta.render_frontmatter(fields)

    refute_match(/beads_issue/, rendered)
    refute_match(/last_updated_note/, rendered)
  end

  def test_frontmatter_topic_is_double_quoted_and_tags_is_bracketed
    fields = {
      "date" => "d", "researcher" => "Claude", "git_commit" => "c", "branch" => "b",
      "repository" => "r", "topic" => "A topic", "tags" => %w[a b],
      "status" => "complete", "last_updated" => "d", "last_updated_by" => "Claude"
    }

    rendered = DocMeta.render_frontmatter(fields)

    assert_match(/^topic: "A topic"$/, rendered)
    assert_match(/^tags: \[a, b\]$/, rendered)
  end

  # sabotage: restore render_value's old `.inspect` branch for topic -> the
  # escaped backslash gains a second level of escaping and this goes red
  def test_topic_with_embedded_double_quotes_round_trips
    topic = 'Research on type="scxml" attribute handling'

    rendered = DocMeta.render_value("topic", topic)

    assert_equal topic, DocMeta.parse_value(rendered)
  end

  def test_topic_with_a_literal_backslash_round_trips
    topic = 'Windows path C:\\Users\\name and a "quoted" segment'

    rendered = DocMeta.render_value("topic", topic)

    assert_equal topic, DocMeta.parse_value(rendered)
  end

  # sabotage: drop the unescape in parse_value -> each apply_follow_up call
  # adds another level of backslash escaping to the quoted topic, so the
  # third run's frontmatter differs from a fresh render of the same fields
  # and this goes red
  def test_repeated_follow_up_runs_leave_frontmatter_byte_identical
    original = <<~DOC
      ---
      date: 2026-08-01T10:00:00-0600
      researcher: Claude
      git_commit: aaa1111
      branch: main
      repository: statifier-ex
      topic: "Topic quoting an XML attribute type=\\"scxml\\" here"
      tags: [research]
      status: complete
      last_updated: 2026-08-01
      last_updated_by: Claude
      ---

      body
    DOC
    topic = 'Topic quoting an XML attribute type="scxml" here'

    once = DocMeta.apply_follow_up(original, date_iso: "2026-08-02T00:00:00-0600", note: "same note")
    twice = DocMeta.apply_follow_up(once, date_iso: "2026-08-03T00:00:00-0600", note: "same note")
    thrice = DocMeta.apply_follow_up(twice, date_iso: "2026-08-04T00:00:00-0600", note: "same note")

    fm_twice = twice[/\A---\n.*?\n---\n/m]
    fm_thrice = thrice[/\A---\n.*?\n---\n/m]

    # last_updated is the only field that changes call to call; strip it
    # before comparing so the assertion is purely about escaping stability
    assert_equal fm_twice.sub(/^last_updated: .*$/, ""), fm_thrice.sub(/^last_updated: .*$/, "")
    assert_equal topic, DocMeta.parse_frontmatter(fm_thrice)["topic"]
  end

  # --- the follow-up mutation is additive -----------------------------------

  def test_apply_follow_up_bumps_last_updated_and_adds_note_and_heading
    original = <<~DOC
      ---
      date: 2026-08-01T10:00:00-0600
      researcher: Claude
      git_commit: aaa1111
      branch: main
      repository: statifier-ex
      topic: "Original topic"
      tags: [research]
      status: complete
      last_updated: 2026-08-01
      last_updated_by: Claude
      ---

      # Research: Original topic

      ## Summary

      Original body content, untouched by the mutation.
    DOC

    updated = DocMeta.apply_follow_up(original, date_iso: "2026-08-07T09:30:00-0600", note: "Added follow-up research for X")

    # additive: original body survives verbatim
    assert_includes updated, "Original body content, untouched by the mutation."
    assert_includes updated, "# Research: Original topic"

    # frontmatter mutated
    fm = DocMeta.parse_frontmatter(updated[/\A---\n.*?\n---\n/m])
    assert_equal "2026-08-07", fm["last_updated"]
    assert_equal "Added follow-up research for X", fm["last_updated_note"]
    assert_equal "Claude", fm["last_updated_by"]
    assert_equal "Original topic", fm["topic"] # untouched field survives

    # a new, timestamped heading was appended
    assert_match(/## Follow-up Research 2026-08-07T09:30:00-0600\n\z/, updated)
  end

  def test_apply_follow_up_is_additive_across_two_calls
    original = <<~DOC
      ---
      date: d
      researcher: Claude
      git_commit: c
      branch: b
      repository: statifier-ex
      topic: "T"
      tags: [research]
      status: complete
      last_updated: 2026-08-01
      last_updated_by: Claude
      ---

      # Research: T

      body
    DOC

    once = DocMeta.apply_follow_up(original, date_iso: "2026-08-02T00:00:00-0600", note: "first follow-up")
    twice = DocMeta.apply_follow_up(once, date_iso: "2026-08-03T00:00:00-0600", note: "second follow-up")

    assert_includes twice, "## Follow-up Research 2026-08-02T00:00:00-0600"
    assert_includes twice, "## Follow-up Research 2026-08-03T00:00:00-0600"
    assert_includes twice, "body"

    fm = DocMeta.parse_frontmatter(twice[/\A---\n.*?\n---\n/m])
    assert_equal "second follow-up", fm["last_updated_note"]
  end

  def test_apply_follow_up_raises_without_a_frontmatter_block
    assert_raises(ArgumentError) do
      DocMeta.apply_follow_up("# No frontmatter here\n", date_iso: "2026-08-07T00:00:00-0600", note: "x")
    end
  end
end

# DocMetaCli, driven through FakeSh (for `metadata`, and `filename`/
# `frontmatter` when no --date/--git-commit/--branch is supplied) and tmpdir
# copies of documents (for `follow-up`).
class DocMetaCliTest < Minitest::Test
  include ManifestHelper

  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
    Manifest.reset!
  end

  # thoughts_layout puts the document directories at thoughts/shared/*, so
  # every --dir assertion below proves the value came from the manifest -
  # docs/plans would have passed either way in this repo.
  def run_cli(argv, fixture: "thoughts_layout")
    io = StringIO.new
    code = nil
    with_manifest(fixture) { code = DocMetaCli.run(argv, io: io) }
    [code, JSON.parse(io.string)]
  end

  # sabotage: restore VALID_DIRS = %w[docs/plans docs/research] -> the
  # manifest's own plans directory is refused and this goes red
  def test_filename_accepts_the_manifest_s_document_directories
    code, env = run_cli(%w[filename --dir thoughts/shared/plans --description a-thing --date 260806])

    assert_equal 0, code
    assert_equal "thoughts/shared/plans/260806-a-thing.md", env["data"]["path"]
  end

  # sabotage: same - with VALID_DIRS hardcoded, docs/plans is accepted here
  def test_filename_refuses_a_directory_this_project_does_not_use
    _code, env = run_cli(%w[filename --dir docs/plans --description x --date 260806])

    assert_equal "invalid_dir", env["blocked"].first["code"]
    assert_match(%r{thoughts/shared/plans}, env["blocked"].first["message"])
  end

  # sabotage: restore the "statifier-ex" default -> red. The name is derived
  # from the remote so a fresh consumer repo needs no manifest entry.
  def test_frontmatter_derives_the_repository_name_from_the_git_remote
    @fake.expect(%w[git remote get-url origin], out: "git@github.com:someone/other-repo.git\n")

    _code, env = run_cli(%w[frontmatter --topic Foo --date d --git-commit c --branch b])

    assert_equal "other-repo", env["data"]["fields"]["repository"]
  end

  # sabotage: read the override after the remote instead of before -> the
  # remote wins and this goes red
  def test_frontmatter_prefers_the_manifest_repository_override
    manifest = manifest_with("thoughts_layout", "artifacts" => { "repository" => "named-in-manifest" })

    io = StringIO.new
    with_manifest(manifest) { DocMetaCli.run(%w[frontmatter --topic Foo --date d --git-commit c --branch b], io: io) }
    env = JSON.parse(io.string)

    assert_equal "named-in-manifest", env["data"]["fields"]["repository"]
    assert_empty @fake.calls
  end

  def test_metadata_shells_the_triple
    @fake.expect(["date", "+%Y-%m-%dT%H:%M:%S%z"], out: "2026-08-06T17:16:38-0600\n")
    @fake.expect(%w[git rev-parse HEAD], out: "af543224c7a8\n")
    @fake.expect(%w[git branch --show-current], out: "zz-hzf-skill-mechanics-scripts\n")

    code, env = run_cli(["metadata"])

    assert_equal 0, code
    assert_equal "2026-08-06T17:16:38-0600", env["data"]["date"]
    assert_equal "af543224c7a8", env["data"]["git_commit"]
    assert_equal "zz-hzf-skill-mechanics-scripts", env["data"]["branch"]
  end

  def test_filename_with_explicit_date_shells_nothing
    code, env = run_cli(%w[filename --dir thoughts/shared/plans --issue zz-hzf --description skill-mechanics-scripts --date 260806])

    assert_equal 0, code
    assert_equal "260806-zz-hzf-skill-mechanics-scripts.md", env["data"]["filename"]
    assert_equal [], env["commands"]
  end

  def test_filename_invalid_dir_blocks
    _code, env = run_cli(%w[filename --dir .claude --description x --date 260806])

    assert_equal "invalid_dir", env["blocked"].first["code"]
  end

  def test_filename_shells_date_when_not_given
    @fake.expect(%w[date +%y%m%d], out: "260806\n")

    _code, env = run_cli(%w[filename --dir thoughts/shared/research --description something])

    assert_equal "260806-something.md", env["data"]["filename"]
  end

  def test_frontmatter_with_explicit_fields_shells_only_the_remote_lookup
    @fake.expect(%w[git remote get-url origin], out: "https://github.com/someone/other-repo\n")

    code, env = run_cli(%w[frontmatter --topic Foo --date d --git-commit c --branch b --tags a,b])

    assert_equal 0, code
    assert_match(/^topic: "Foo"$/, env["data"]["frontmatter"])
    assert_equal %w[a b], env["data"]["fields"]["tags"]
  end

  def test_frontmatter_missing_topic_blocks
    _code, env = run_cli(%w[frontmatter --date d --git-commit c --branch b])

    assert_equal "missing_topic", env["blocked"].first["code"]
  end

  # --- follow-up (file mutation, no Sh involved when --date is given) ------

  def test_follow_up_mutates_the_file_on_disk
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, <<~DOC)
        ---
        date: d
        researcher: Claude
        git_commit: c
        branch: b
        repository: statifier-ex
        topic: "T"
        tags: [research]
        status: complete
        last_updated: 2026-08-01
        last_updated_by: Claude
        ---

        # Research: T

        body
      DOC

      code, env = run_cli(["follow-up", path, "--note", "more research", "--date", "2026-08-07T00:00:00-0600"])

      assert_equal 0, code
      assert_equal "2026-08-07", env["data"]["last_updated"]

      updated = File.read(path)
      assert_includes updated, "## Follow-up Research 2026-08-07T00:00:00-0600"
      assert_includes updated, "body"
    end
  end

  def test_follow_up_dry_run_does_not_write
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      original = "---\ndate: d\nresearcher: Claude\ngit_commit: c\nbranch: b\nrepository: statifier-ex\n" \
                 "topic: \"T\"\ntags: [research]\nstatus: complete\nlast_updated: 2026-08-01\n" \
                 "last_updated_by: Claude\n---\n\nbody\n"
      File.write(path, original)

      run_cli(["follow-up", path, "--note", "x", "--date", "2026-08-07T00:00:00-0600", "--dry-run"])

      assert_equal original, File.read(path)
    end
  end

  def test_follow_up_missing_file_blocks
    _code, env = run_cli(["follow-up", "/no/such/file.md", "--note", "x", "--date", "2026-08-07T00:00:00-0600"])

    assert_equal "file_not_found", env["blocked"].first["code"]
  end

  def test_follow_up_missing_note_blocks
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "---\ndate: d\n---\n\nbody\n")

      _code, env = run_cli(["follow-up", path, "--date", "2026-08-07T00:00:00-0600"])

      assert_equal "missing_note", env["blocked"].first["code"]
    end
  end
end

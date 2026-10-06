# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "support/home_guard"
require_relative "../worktree_salvage"

# worktree_salvage.rb runs real git against throwaway repositories built in a
# tmpdir: the property under test is what `git stash create` captures and
# what it leaves alone, which a FakeSh cannot answer. Nothing here ever
# points the script at a real checkout or a live worktree.
class WorktreeSalvageTest < Minitest::Test
  # git in the fixtures and in the script's children never reads the
  # operator's git config and never inherits a GIT_DIR from whatever runs the
  # suite. The identity is set because `git stash create` builds a commit.
  GIT_ENV = { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL,
              "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_COMMON_DIR" => nil,
              "GIT_INDEX_FILE" => nil,
              "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@example.invalid",
              "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@example.invalid" }.freeze

  def setup
    Sh.runner = nil
    @saved_env = GIT_ENV.keys.map { |k| [k, ENV[k]] }.to_h
    GIT_ENV.each { |k, v| ENV[k] = v }
    @tmp = File.realpath(Dir.mktmpdir("wurk-salvage-"))
  end

  def teardown
    FileUtils.rm_rf(@tmp)
    @saved_env.each { |k, v| ENV[k] = v }
  end

  def git(dir, *args)
    out, err, status = Open3.capture3("git", "-C", dir, *args)
    assert status.success?, "fixture git #{args.join(' ')} failed: #{err}"
    out
  end

  # A repository with one committed file and one linked worktree, the shape
  # the conductor salvages.
  def make_worktree
    main = File.join(@tmp, "main")
    wt = File.join(@tmp, "wt")
    FileUtils.mkdir_p(main)
    git(main, "init", "-q")
    File.write(File.join(main, "tracked.txt"), "original\n")
    git(main, "add", "tracked.txt")
    git(main, "commit", "-q", "-m", "init")
    git(main, "worktree", "add", "-q", "-b", "wt", wt)
    [main, wt]
  end

  def status_bytes(dir)
    git(dir, "status", "--porcelain=v1", "-z", "--untracked-files=all")
  end

  def run_salvage(argv)
    io = StringIO.new
    code = WorktreeSalvage.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  # sabotage: skip the untracked copy (return before the FileUtils.cp in
  # copy_untracked) -> the copied-file assertions go red here.
  def test_salvage_records_a_stash_holding_the_edit_and_copies_untracked_files
    _main, wt = make_worktree
    File.write(File.join(wt, "tracked.txt"), "edited by a dead worker\n")
    FileUtils.mkdir_p(File.join(wt, "notes"))
    File.write(File.join(wt, "notes", "draft.md"), "untracked draft\n")
    out = File.join(@tmp, "salvage", "wt")
    before = status_bytes(wt)

    code, env = run_salvage(["--out", out, wt])

    assert_equal 0, code, env.inspect
    sha = env["data"]["stash_sha"]
    refute_nil sha
    assert_equal "edited by a dead worker\n", git(wt, "show", "#{sha}:tracked.txt")
    assert_equal ["tracked.txt"], env["data"]["tracked_changes"]
    assert_equal ["notes/draft.md"], env["data"]["copied"]
    assert_equal "untracked draft\n", File.read(File.join(out, "notes", "draft.md"))
    assert_equal before, status_bytes(wt), "the worktree's status must be byte-identical after a salvage"
    assert_equal true, env["data"]["status_unchanged"]
    assert_equal "", git(wt, "stash", "list"), "stash create writes no ref"
  end

  def test_a_staged_new_file_is_in_the_stash_tree
    _main, wt = make_worktree
    File.write(File.join(wt, "added.txt"), "staged only\n")
    git(wt, "add", "added.txt")

    code, env = run_salvage(["--out", File.join(@tmp, "s"), wt])

    assert_equal 0, code, env.inspect
    assert_equal "staged only\n", git(wt, "show", "#{env['data']['stash_sha']}:added.txt")
    assert_equal [], env["data"]["copied"]
  end

  def test_a_clean_worktree_reports_no_sha_and_no_copies
    _main, wt = make_worktree

    code, env = run_salvage(["--out", File.join(@tmp, "s"), wt])

    assert_equal 0, code, env.inspect
    assert_nil env["data"]["stash_sha"]
    assert_equal [], env["data"]["copied"]
    assert_equal [], env["data"]["tracked_changes"]
  end

  # sabotage: run the copy under --dry-run (drop the `if dry_run` branch in
  # copy_untracked) -> the salvage root exists and copied is non-empty: red.
  def test_dry_run_copies_nothing_and_lists_the_path
    _main, wt = make_worktree
    File.write(File.join(wt, "tracked.txt"), "edited\n")
    File.write(File.join(wt, "loose.txt"), "untracked\n")
    out = File.join(@tmp, "salvage")

    code, env = run_salvage(["--dry-run", "--out", out, wt])

    assert_equal 0, code, env.inspect
    assert_equal true, env["data"]["dry_run"]
    assert_equal ["loose.txt"], env["data"]["would_copy"]
    assert_equal [], env["data"]["copied"]
    assert_nil env["data"]["stash_sha"]
    refute File.exist?(out), "a dry run creates nothing under the salvage root"
  end

  def test_refuses_a_root_inside_the_worktree_being_salvaged
    _main, wt = make_worktree
    File.write(File.join(wt, "loose.txt"), "untracked\n")
    before = status_bytes(wt)

    code, env = run_salvage(["--out", File.join(wt, "salvage"), wt])

    assert_equal 1, code
    assert_equal "salvage_root_in_worktree", env["blocked"].first["code"]
    assert_equal before, status_bytes(wt)
  end

  def test_refuses_a_root_inside_another_work_tree_that_does_not_ignore_it
    main, wt = make_worktree
    File.write(File.join(wt, "loose.txt"), "untracked\n")

    code, env = run_salvage(["--out", File.join(main, "salvage", "wt"), wt])

    assert_equal 1, code
    assert_equal "salvage_root_in_work_tree", env["blocked"].first["code"]
    refute File.exist?(File.join(main, "salvage"))
  end

  def test_accepts_a_root_under_a_directory_the_enclosing_tree_excludes
    main, wt = make_worktree
    File.write(File.join(wt, "loose.txt"), "untracked\n")
    File.open(File.join(main, ".git", "info", "exclude"), "a") { |f| f.puts("state/") }
    out = File.join(main, "state", "salvage", "wt")

    code, env = run_salvage(["--out", out, wt])

    assert_equal 0, code, env.inspect
    assert_equal "untracked\n", File.read(File.join(out, "loose.txt"))
    assert_equal "", git(main, "status", "--porcelain")
  end

  def test_refuses_a_root_inside_a_git_directory
    main, wt = make_worktree
    File.write(File.join(wt, "loose.txt"), "untracked\n")

    code, env = run_salvage(["--out", File.join(main, ".git", "salvage"), wt])

    assert_equal 1, code
    assert_equal "salvage_root_in_git_dir", env["blocked"].first["code"]
  end

  def test_refuses_a_non_empty_root_so_an_earlier_salvage_is_never_overwritten
    _main, wt = make_worktree
    File.write(File.join(wt, "loose.txt"), "new\n")
    out = File.join(@tmp, "salvage")
    FileUtils.mkdir_p(out)
    File.write(File.join(out, "loose.txt"), "earlier salvage\n")

    code, env = run_salvage(["--out", out, wt])

    assert_equal 1, code
    assert_equal "salvage_root_not_empty", env["blocked"].first["code"]
    assert_equal "earlier salvage\n", File.read(File.join(out, "loose.txt"))
  end

  def test_refuses_a_path_that_is_not_a_work_tree
    plain = File.join(@tmp, "plain")
    FileUtils.mkdir_p(plain)

    code, env = run_salvage(["--out", File.join(@tmp, "s"), plain])

    assert_equal 1, code
    assert_equal "not_a_work_tree", env["blocked"].first["code"]
  end

  def test_a_missing_out_is_a_usage_error
    _main, wt = make_worktree
    _out, err = capture_io { assert_equal 2, WorktreeSalvage.run([wt], io: StringIO.new) }
    assert_match(/--out/, err)
  end

  def test_parse_status_z_consumes_the_rename_source_field
    text = "R  new.txt\0old.txt\0?? loose.txt\0 M a b.txt\0"
    assert_equal [["R ", "new.txt"], ["??", "loose.txt"], [" M", "a b.txt"]],
                 WorktreeSalvage.parse_status_z(text)
  end

  # The bead's hard line: a salvage never runs an operation that can discard
  # or move worktree state. contract_test's banned-call table is ADR-0006's;
  # this check is local to this script and does not widen that table.
  def test_source_never_runs_a_destructive_git_operation
    source = File.read(File.expand_path("../worktree_salvage.rb", __dir__))
    code = source.each_line.reject { |l| l.strip.start_with?("#") }.join
    refute_match(/["']clean["']/, code)
    refute_match(/["']reset["']/, code)
    refute_match(/["']checkout["']/, code)
    refute_match(/["']stash["'],\s*["'](push|pop|apply|drop|clear|store)["']/, code)
    refute_match(/stash\s+(push|pop|apply|drop|clear|store)/, code)
    assert_match(/%w\[git stash create\]/, code)
  end
end

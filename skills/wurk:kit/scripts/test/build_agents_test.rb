# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../build_agents"
require_relative "support/home_guard"

# Fixtures are built in a tmpdir by each test; only the last class below
# reads the repo's real agents/, and it reads only (--check writes nothing).
module AgentFixtures
  FRONTMATTER = "---\nname: zz-worker\ndescription: a fixture agent\nmodel: sonnet\n---\n"

  def write_template(name, body, frontmatter: FRONTMATTER)
    File.write(File.join(@dir, "#{name}.md.in"), "#{frontmatter}#{body}")
  end

  def write_block(name, content)
    FileUtils.mkdir_p(File.join(@dir, "blocks"))
    File.write(File.join(@dir, "blocks", "#{name}.md"), content)
  end

  def write_routing(routing)
    lines = ["blocks:"]
    routing.each do |block, names|
      lines << "  #{block}:"
      names.each { |n| lines << "    - #{n}" }
    end
    File.write(File.join(@dir, "routing.yml"), "#{lines.join("\n")}\n")
  end

  def generated(name)
    File.read(File.join(@dir, "#{name}.md"))
  end

  def run_cli(*flags)
    io = StringIO.new
    code = BuildAgentsCli.run(["--dir", @dir, *flags], io: io)
    [code, JSON.parse(io.string)]
  end

  def codes(envelope)
    envelope["blocked"].map { |b| b["code"] }
  end

  # One routed agent carrying one block, the shape the wurk agents use.
  def seed_valid
    write_template("zz-worker", "\nIntro line.\n\n@include shared-rule\n\nOutro line.\n")
    write_block("shared-rule", "The shared rule, verbatim.\nSecond line of it.\n")
    write_routing("shared-rule" => ["zz-worker"])
  end
end

class BuildAgentsBuildTest < Minitest::Test
  include AgentFixtures

  def setup
    @dir = Dir.mktmpdir("wurk-agents-")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # sabotage: drop the banner line from Set#render, or splice the block
  # without its trailing newline -> red
  def test_build_writes_frontmatter_banner_and_spliced_block
    seed_valid
    code, env = run_cli
    assert_equal 0, code, env.inspect
    assert env["ok"]
    assert_equal ["write #{File.join(@dir, 'zz-worker.md')}"], env["commands"]
    expected = "#{AgentFixtures::FRONTMATTER}#{BuildAgents.banner('zz-worker')}\n" \
               "\nIntro line.\n\nThe shared rule, verbatim.\nSecond line of it.\n\nOutro line.\n"
    assert_equal expected, generated("zz-worker")
  end

  # sabotage: write the file under --dry-run -> red
  def test_dry_run_lists_the_write_and_writes_nothing
    seed_valid
    code, env = run_cli("--dry-run")
    assert_equal 0, code
    assert env["data"]["dry_run"]
    assert_equal 1, env["commands"].size
    refute File.exist?(File.join(@dir, "zz-worker.md"))
  end

  # sabotage: compare rendered text to the file with a normalization
  # (strip, chomp) -> the second build still writes, red
  def test_a_second_build_is_a_no_op
    seed_valid
    run_cli
    code, env = run_cli
    assert_equal 0, code
    assert_empty env["commands"]
    assert_equal [{ "name" => "zz-worker", "path" => File.join(@dir, "zz-worker.md"), "status" => "current" }],
                 env["data"]["agents"]
  end

  # sabotage: replace the include line with the block but keep the include
  # line too, or expand includes inside the frontmatter -> red
  def test_a_template_without_includes_renders_as_itself_plus_the_banner
    write_template("zz-plain", "\nJust prose.\n")
    write_routing({})
    code, = run_cli
    assert_equal 0, code
    assert_equal "#{AgentFixtures::FRONTMATTER}#{BuildAgents.banner('zz-plain')}\n\nJust prose.\n", generated("zz-plain")
  end

  # sabotage: let a block that lacks a final newline splice as-is -> the
  # line after the include runs onto the block's last line, red
  def test_a_block_without_a_trailing_newline_still_ends_its_line
    write_template("zz-worker", "\n@include shared-rule\nNext.\n")
    write_block("shared-rule", "No newline at end")
    write_routing("shared-rule" => ["zz-worker"])
    run_cli
    assert_includes generated("zz-worker"), "No newline at end\nNext.\n"
  end

  # sabotage: build on a missing dir and let Dir.glob's empty answer read as
  # "nothing to do", exit 0 -> red
  def test_a_missing_directory_blocks
    io = StringIO.new
    code = BuildAgentsCli.run(["--dir", File.join(@dir, "nope")], io: io)
    env = JSON.parse(io.string)
    assert_equal 1, code
    assert_equal ["dir_missing"], codes(env)
  end
end

# Every lint case, each proven by a fixture that carries exactly that
# defect and nothing else. A lint finding blocks the build before any file
# is written, in both modes.
class BuildAgentsLintTest < Minitest::Test
  include AgentFixtures

  def setup
    @dir = Dir.mktmpdir("wurk-agents-")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # sabotage: skip the blocks.key? check in lint -> render raises on the
  # fetch instead of the build refusing, red
  def test_dangling_include
    write_template("zz-worker", "\n@include nowhere\n")
    write_routing("nowhere" => ["zz-worker"])
    code, env = run_cli
    assert_equal 1, code
    assert_includes codes(env), "dangling_include"
    assert_empty env["commands"]
    refute File.exist?(File.join(@dir, "zz-worker.md"))
  end

  # sabotage: authorize an include whenever the block file exists -> red
  def test_unauthorized_include
    write_template("zz-worker", "\n@include shared-rule\n")
    write_block("shared-rule", "rule\n")
    write_routing("shared-rule" => ["zz-other"])
    write_template("zz-other", "\n@include shared-rule\n")
    code, env = run_cli
    assert_equal 1, code
    assert_equal ["unauthorized_include"], codes(env)
    assert_includes env["blocked"][0]["message"], "does not route shared-rule to zz-worker"
  end

  # sabotage: drop the routing-lists-an-agent-that-never-includes check ->
  # red. This is the "must carry" half of routing: the file says who
  # carries a block, and a listed agent that lacks it is the defect the
  # bead names.
  def test_missing_include
    write_template("zz-worker", "\nNo include here.\n")
    write_block("shared-rule", "rule\n")
    write_routing("shared-rule" => ["zz-worker"])
    code, env = run_cli
    assert_equal 1, code
    assert_equal ["missing_include"], codes(env)
  end

  # sabotage: iterate routing's keys instead of the block files when
  # looking for orphans -> red
  def test_orphan_block
    write_template("zz-worker", "\nProse.\n")
    write_block("unused", "nobody carries this\n")
    write_routing({})
    code, env = run_cli
    assert_equal 1, code
    assert_equal ["orphan_block"], codes(env)
  end

  # sabotage: only check routing entries that some template includes -> red
  def test_dangling_route
    write_template("zz-worker", "\nProse.\n")
    write_routing("ghost" => [])
    code, env = run_cli
    assert_equal 1, code
    assert_equal ["dangling_route"], codes(env)
  end

  # sabotage: treat an agent routing names but no template defines as
  # merely "missing its include" -> the code differs, red
  def test_unknown_agent
    write_block("shared-rule", "rule\n")
    write_routing("shared-rule" => ["zz-nobody"])
    code, env = run_cli
    assert_equal 1, code
    assert_equal ["unknown_agent"], codes(env)
  end

  # sabotage: expand includes recursively, or ignore them inside blocks ->
  # red either way; the rule is that a block is a leaf and says so
  def test_nested_include
    write_template("zz-worker", "\n@include outer\n")
    write_block("outer", "@include inner\n")
    write_block("inner", "deep\n")
    write_routing("outer" => ["zz-worker"], "inner" => [])
    code, env = run_cli
    assert_equal 1, code
    assert_equal ["nested_include"], codes(env)
  end

  # sabotage: default frontmatter_end to 0 when no fence is found -> the
  # banner lands on line 2 of a body, red
  def test_no_frontmatter
    write_template("zz-worker", "Just prose, no fences.\n", frontmatter: "")
    write_routing({})
    code, env = run_cli
    assert_equal 1, code
    assert_equal ["no_frontmatter"], codes(env)
  end

  # sabotage: glob only *.md.in when deciding what the directory holds ->
  # a hand-written agent beside the templates passes, red
  def test_ungenerated_agent
    write_template("zz-worker", "\nProse.\n")
    write_routing({})
    File.write(File.join(@dir, "zz-handmade.md"), "---\nname: zz-handmade\n---\nwritten by hand\n")
    code, env = run_cli("--check")
    assert_equal 1, code
    assert_includes codes(env), "ungenerated_agent"
  end

  # sabotage: fall through to an empty routing when the file is missing ->
  # the block reads as orphan_block, red
  def test_routing_missing
    write_template("zz-worker", "\nProse.\n")
    write_block("shared-rule", "rule\n")
    code, env = run_cli
    assert_equal 1, code
    assert_equal ["routing_missing"], codes(env)
  end

  # sabotage: accept any YAML document as routing -> a list where the
  # mapping should be walks through .each with the wrong arity, red
  def test_routing_invalid_shape
    write_template("zz-worker", "\nProse.\n")
    File.write(File.join(@dir, "routing.yml"), "blocks:\n  - shared-rule\n")
    code, env = run_cli
    assert_equal 1, code
    assert_equal ["routing_invalid"], codes(env)
  end

  # sabotage: let a Psych::SyntaxError escape -> the process dies with a
  # backtrace instead of an envelope, red
  def test_routing_unparseable
    write_template("zz-worker", "\nProse.\n")
    File.write(File.join(@dir, "routing.yml"), "blocks: [\n")
    code, env = run_cli
    assert_equal 1, code
    assert_equal ["routing_invalid"], codes(env)
  end
end

class BuildAgentsCheckTest < Minitest::Test
  include AgentFixtures

  def setup
    @dir = Dir.mktmpdir("wurk-agents-")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # sabotage: let --check write the regenerated file -> the second
  # assertion sees the block's new text, red
  def test_stale_generated_blocks_and_writes_nothing
    seed_valid
    run_cli
    write_block("shared-rule", "The rule, reworded.\n")
    code, env = run_cli("--check")
    assert_equal 1, code
    assert_equal ["stale_generated"], codes(env)
    assert_equal "stale", env["data"]["agents"][0]["status"]
    assert_includes generated("zz-worker"), "The shared rule, verbatim."
    assert_empty env["commands"]
  end

  # sabotage: treat a hand edit that keeps the banner as current -> red
  def test_a_hand_edit_to_a_generated_file_is_stale
    seed_valid
    run_cli
    path = File.join(@dir, "zz-worker.md")
    File.write(path, File.read(path).sub("Outro line.", "Outro line, edited by hand."))
    code, env = run_cli("--check")
    assert_equal 1, code
    assert_equal ["stale_generated"], codes(env)
  end

  # sabotage: report an absent generated file as stale, or skip it -> red
  def test_missing_generated
    seed_valid
    code, env = run_cli("--check")
    assert_equal 1, code
    assert_equal ["missing_generated"], codes(env)
    assert_equal "missing", env["data"]["agents"][0]["status"]
  end

  def test_check_passes_when_current
    seed_valid
    run_cli
    code, env = run_cli("--check")
    assert_equal 0, code
    assert env["ok"]
    assert_equal "check", env["data"]["mode"]
  end
end

# The kit's own agents: this is `build_agents.rb --check` wired into the
# suite. A committed agents/*.md that drifts from its template, a template
# whose include routing.yml does not authorize, an unrouted block, or a
# hand-written agent beside the templates turns the gate red.
class BuildAgentsShippedTest < Minitest::Test
  REPO_ROOT = File.expand_path(File.join(__dir__, "..", "..", "..", ".."))
  AGENTS_DIR = File.join(REPO_ROOT, "agents")

  # sabotage: edit any agents/*.md by hand without rebuilding, or edit a
  # block or template without rebuilding -> red
  def test_shipped_agents_are_current_with_their_templates
    io = StringIO.new
    code = BuildAgentsCli.run(["--dir", AGENTS_DIR, "--check"], io: io)
    env = JSON.parse(io.string)
    assert_equal 0, code, env["blocked"].map { |b| "#{b['code']}: #{b['message']}" }.join("\n")
    refute_empty env["data"]["agents"], "no shipped agents found - this check would be vacuous"
    assert_empty env["commands"]
  end

  # sabotage: add a routing entry for a block no agent is meant to carry,
  # or drop wurk-repo-worker from either list -> red. The bead's acceptance
  # criterion: the consent-relay and gate-discipline blocks exist as shared
  # blocks and the repo worker carries both.
  def test_repo_worker_carries_the_two_shared_blocks
    set = BuildAgents::Set.new(AGENTS_DIR)
    assert_empty set.lint
    %w[consent-relay gate-discipline].each do |block|
      assert set.blocks.key?(block), "agents/blocks/#{block}.md missing"
      assert_includes set.routing.fetch(block, []), "wurk-repo-worker"
    end
  end

  # sabotage: let a generated file lose its banner (a hand edit that
  # deletes the comment) and skip regeneration -> the shipped check above
  # catches it as stale; this one says why it matters: the banner is what
  # tells an editor which file to edit
  def test_every_shipped_agent_carries_the_banner
    Dir.glob(File.join(AGENTS_DIR, "*.md")).sort.each do |path|
      name = File.basename(path, ".md")
      assert_includes File.read(path), BuildAgents.banner(name), "#{path} lacks the DO NOT EDIT banner"
    end
  end
end

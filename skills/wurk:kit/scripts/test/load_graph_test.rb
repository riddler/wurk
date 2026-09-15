# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "support/home_guard"

# The kit is installed into ~/.claude by symlink, so every script is normally
# invoked through a path that is not its realpath. Ruby's `require_relative`
# canonicalizes what it loads, but the main script - the file named on the
# command line - is never registered as a loaded feature at all. A require
# cycle that leads back to the main script therefore re-executes it, and
# every constant in it warns "already initialized" (wu-cvi: `ruby
# ~/.claude/skills/wurk:kit/scripts/lib/manifest.rb check` printed seventeen
# of them, because lib/gate_paths.rb required lib/manifest.rb back).
#
# Two tests, one per layer of the same rule:
#
# - the static one reads every `require_relative` in the kit and rejects a
#   cycle anywhere in the graph, which is the root cause and the thing a
#   future edit can quietly reintroduce;
# - the runtime one is the bead's acceptance criterion as stated: every
#   entry point, run through a symlink built INSIDE a tmpdir, must put no
#   warning on stderr. It never reads or touches the real ~/.claude symlink,
#   because a test that depends on the developer's install is not a test of
#   the kit.
class LoadGraphTest < Minitest::Test
  SCRIPTS_ROOT = File.expand_path(File.join(__dir__, ".."))
  KIT_ROOT = File.expand_path(File.join(SCRIPTS_ROOT, ".."))
  REQUIRE_RELATIVE = /^\s*require_relative\s+["']([^"']+)["']/.freeze

  # Every non-test Ruby file under scripts/: the top-level scripts and lib/.
  def kit_files
    Dir.glob(File.join(SCRIPTS_ROOT, "**", "*.rb")).sort.reject do |f|
      f.start_with?(File.join(SCRIPTS_ROOT, "test") + File::SEPARATOR)
    end
  end

  # file -> [files it require_relatives], both sides as realpaths under
  # SCRIPTS_ROOT, so the graph is keyed the way Ruby dedupes loads.
  def require_graph
    kit_files.each_with_object({}) do |file, graph|
      graph[file] = File.read(file).each_line.map do |line|
        m = REQUIRE_RELATIVE.match(line)
        m && File.expand_path(m[1] + ".rb", File.dirname(file))
      end.compact
    end
  end

  # Iterative DFS with the usual white/grey/black coloring; returns the first
  # cycle found as a path of files, or nil.
  def find_cycle(graph)
    color = Hash.new(:white)
    graph.keys.sort.each do |start|
      next unless color[start] == :white

      stack = [[start, graph.fetch(start, []).dup]]
      path = [start]
      color[start] = :grey
      until stack.empty?
        node, pending = stack.last
        if pending.empty?
          color[node] = :black
          stack.pop
          path.pop
          next
        end
        nxt = pending.shift
        case color[nxt]
        when :grey then return path[path.index(nxt)..-1] + [nxt]
        when :white
          color[nxt] = :grey
          path << nxt
          stack << [nxt, graph.fetch(nxt, []).dup]
        end
      end
    end
    nil
  end

  def test_require_graph_has_no_cycles
    cycle = find_cycle(require_graph)
    assert_nil cycle, "require_relative cycle in the kit (a main script at its head reloads itself): " \
                      "#{cycle && cycle.map { |f| f.sub(SCRIPTS_ROOT + '/', '') }.join(' -> ')}"
  end

  def test_find_cycle_detects_a_two_file_cycle
    graph = { "a" => ["b"], "b" => ["a"], "c" => ["a"] }
    assert_equal %w[a b a], find_cycle(graph)
  end

  def test_find_cycle_accepts_a_diamond
    graph = { "a" => %w[b c], "b" => ["d"], "c" => ["d"], "d" => [] }
    assert_nil find_cycle(graph)
  end

  def test_require_graph_sees_the_real_kit
    graph = require_graph
    manifest = File.join(SCRIPTS_ROOT, "lib", "manifest.rb")
    gate_paths = File.join(SCRIPTS_ROOT, "lib", "gate_paths.rb")
    assert_includes graph.fetch(manifest), gate_paths, "the parser lost manifest.rb's require of gate_paths"
    refute_includes graph.fetch(gate_paths), manifest, "gate_paths.rb must not require manifest.rb back (wu-cvi)"
  end

  def test_every_entry_point_runs_clean_through_a_symlink
    Dir.mktmpdir("wu-cvi-symlink") do |tmp|
      link = File.join(tmp, "linked-kit")
      File.symlink(KIT_ROOT, link)
      scripts = File.join(link, "scripts")

      # One child per entry point, run concurrently: Ruby releases the GIL
      # while capture3 waits, so the wall time is one startup, not thirty.
      # --help is the one argument every script accepts without touching a
      # manifest, a tracker, or git; a script that prints usage to stderr
      # and exits 2 is fine, only a warning line is a failure.
      results = kit_files.map do |file|
        linked = file.sub(SCRIPTS_ROOT, scripts)
        Thread.new do
          _out, err, _status = Open3.capture3(RbConfig.ruby, "-w", linked, "--help", chdir: tmp)
          [linked, err]
        end
      end.map(&:value)

      offenders = results.select { |(_, err)| err =~ /warning/ }
      assert_empty offenders.map { |(f, err)| "#{f}:\n#{err}" },
                   "warning(s) on stderr running kit scripts through a symlink"
    end
  end
end

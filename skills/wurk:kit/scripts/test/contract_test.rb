# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "support/manifest_helper"

# The mechanical enforcement of ADR-0006's banned-operation constraint
# (scripts are step-scoped; the list is absolute). This file is the
# authoritative and permanent enforcement site, and the drift check at the
# bottom re-reads the ADR on every run so its text and this file's coverage
# cannot part company silently. New rules go in both places or neither.
#
# It arrived here anchored to the donor repo's own ADR-0015, whose amended
# Consequences carry the original decision record and the reason a full
# whole-tree content scan beats a diff-line guard: an added-lines-only check
# with an inline-citation escape hatch that skips without a base ref is the
# opposite of absolute on all three counts.
#
# Contract holds the scanning rules as pure functions over lines of source
# (so they can be unit-tested against synthetic fixtures, proving the regexes
# really catch what they claim to), and ContractTest applies them to the real
# files under this kit's scripts/.
#
# This test is why `git push` and PR/MR creation are hand-run commands in
# /wurk:mr rather than a script step: the consumer's CLAUDE.md authority
# table puts the human gate at the seam between commit and push, and a script
# spanning that seam would relocate a decision nobody decided to move.
module Contract
  BANNED_CALLS = {
    "git push" => /\bgit\s+push\b/,
    "gh pr create" => /\bgh\s+pr\s+create\b/,
    # Named by ADR-0006 ahead of the gitlab forge landing (plan phase 4):
    # the ban is policy, not an implementation detail of a forge wurk
    # already speaks.
    "glab mr create" => /\bglab\s+mr\s+create\b/,
    "bd close" => /\bbd\s+close\b/,
    "bd edit" => /\bbd\s+edit\b/
  }.freeze

  # Which files count as gate configuration is per-consumer data, so unlike
  # BANNED_CALLS there is no list here: guarded_writes takes its targets as
  # an argument and the caller supplies them. The suite supplies the union
  # of every fixture manifest's gate.moving_files and gate.guard_ledger (see
  # ManifestHelper.all_fixture_guarded_paths) - the consumer of
  # gate.moving_files that the field had been waiting for.
  #
  # Targets arrive as plain path strings. The matcher is looser than the
  # string so a relative or absolute spelling of the same file still hits:
  # only the basename has to appear on the line.
  def self.write_matcher(path)
    /#{Regexp.escape(File.basename(path))}/
  end

  # Same false-negative trade as code_only: a write routed through a
  # variable holding the path, or through a shelled-out `cp`, is not caught.
  # Straight-line stdlib Ruby writes files with these calls on one line.
  WRITE_CALL = /File\.(open|write)|IO\.write/.freeze

  NON_INTERACTIVE_FLAG = /-\S*f\S*/.freeze # any dash-flag containing an f, e.g. -f, -Rf, -rf, -Rfc

  module_function

  # Strips a trailing "# ..." comment from a line. Good enough for the
  # straight-line Ruby this codebase writes; a `#` inside a string literal is
  # a false-negative risk this test accepts in exchange for staying simple
  # and dependency-free (no full Ruby parser).
  def code_only(line)
    line.sub(/#.*/, "")
  end

  def each_code_line(content)
    content.each_line.with_index(1) do |line, lineno|
      code = code_only(line)
      next if code.strip.empty?

      yield code, lineno
    end
  end

  # Returns [[lineno, label], ...] for every banned call found in content.
  # Ruby argv arrays write commands as separate string literals
  # (`["git", "push"]`), so quotes/brackets/commas are normalized to spaces
  # before matching - that lets a single word-boundary phrase regex catch
  # both an argv array and a plain string like "git push".
  def banned_calls(content)
    hits = []
    each_code_line(content) do |code, lineno|
      haystack = normalize_for_word_match(code)
      BANNED_CALLS.each do |label, pattern|
        hits << [lineno, label] if haystack =~ pattern
      end
    end
    hits
  end

  def normalize_for_word_match(code)
    code.gsub(/["'\[\],]/, " ")
  end

  # Returns [[lineno, label], ...] for every line that writes one of the
  # guarded files (the ledger and the gate's config files).
  def guarded_writes(content, targets)
    hits = []
    each_code_line(content) do |code, lineno|
      next unless code =~ WRITE_CALL

      targets.each do |path|
        hits << [lineno, path] if code =~ Contract.write_matcher(path)
      end
    end
    hits
  end

  # Returns lines using system(...) or backtick execution instead of Sh.
  def system_or_backticks(content)
    hits = []
    each_code_line(content) do |code, lineno|
      hits << lineno if code =~ /(^|[^\w.])system\s*\(/ || code =~ /`[^`]*`/
    end
    hits
  end

  # Returns argv-literal lines starting with "cp"/"rm"/"mv" that carry no
  # non-interactive flag anywhere on the same line.
  def unsafe_cp_rm_mv(content)
    hits = []
    each_code_line(content) do |code, lineno|
      match = code.match(/\[\s*"(cp|rm|mv)"/)
      next unless match

      cmd = match[1]
      hits << [lineno, cmd] unless code =~ NON_INTERACTIVE_FLAG
    end
    hits
  end

  # Domain vocabulary from the consumer repos wurk serves. A kit script that
  # names one has a constant that belongs in the manifest (CLAUDE.md's hard
  # rule; ADR-0004). Comments are exempt, same as every other rule here - a
  # comment may cite where a behavior came from; a code line may not encode
  # it.
  #
  # This list is allowed to name consumer values precisely because it is the
  # enforcement site, the same way BANNED_CALLS names the operations it bans.
  #
  # "elixir gate config" matches whole filenames, not bare stems: `.quality`
  # without its extension is also how Ruby spells a method call on a `quality`
  # attribute, and a guard that fires on `report.quality` costs a future
  # implementer a rename for no rule violation. Every value this rule exists
  # to catch is a file the consumer names in gate.moving_files, and those are
  # always spelled in full.
  CONSUMER_VOCABULARY = {
    "statifier corpus dirs" => /scion|scxml/i,
    "elixir gate config" => /\.(?:quality|credo)\.exs\b|\.sobelow-conf\b|\bcoveralls\.json\b/,
    "mix gate commands" => /\bmix\s+(quality|gate\.\w+)\b/,
    "exunit test macro" => /\btest\s+"/,
    "consumer repo names" => /statifier|predicator|fixative/i
  }.freeze

  # Returns [[lineno, label], ...] for every consumer-vocabulary hit found in
  # content.
  def consumer_vocabulary(content)
    hits = []
    each_code_line(content) do |code, lineno|
      CONSUMER_VOCABULARY.each { |label, re| hits << [lineno, label] if code =~ re }
    end
    hits
  end
end

class ContractRulesTest < Minitest::Test
  def test_banned_calls_ignores_comments
    hits = Contract.banned_calls("# this mentions git push only in prose\n")
    assert_empty hits
  end

  def test_banned_calls_specific_examples
    assert_equal [[1, "git push"]], Contract.banned_calls(%(Sh.run(["git", "push", "origin", branch])\n))
    assert_equal [[1, "gh pr create"]], Contract.banned_calls(%(Sh.run(["gh", "pr", "create"])\n))
    assert_equal [[1, "glab mr create"]], Contract.banned_calls(%(Sh.run(["glab", "mr", "create"])\n))
    assert_equal [[1, "bd close"]], Contract.banned_calls(%(Sh.run(["bd", "close", id])\n))
    assert_equal [[1, "bd edit"]], Contract.banned_calls(%(Sh.run(["bd", "edit", id])\n))
  end

  # Every path the fixtures declare must actually be catchable - otherwise a
  # consumer could name a file in gate.moving_files and get a guard that
  # silently matches nothing.
  def test_guarded_writes_detected_for_every_fixture_declared_path
    targets = ManifestHelper.all_fixture_guarded_paths
    refute_empty targets, "no fixture manifest declares a guarded path - the scan would be vacuous"

    targets.each do |path|
      line = %(File.write("#{path}", content)\n)
      assert_equal [[1, path]], Contract.guarded_writes(line, targets),
                   "a write to #{path} was not caught"
    end
  end

  # The looser basename matcher, exercised on the spellings a script would
  # plausibly use for a path the manifest states relative to the repo root.
  def test_guarded_writes_match_relative_and_absolute_spellings
    targets = ["docs/quality-gate-changes.md"]

    assert_equal [[1, "docs/quality-gate-changes.md"]],
                 Contract.guarded_writes(%(File.write("quality-gate-changes.md", x)\n), targets)
    assert_equal [[1, "docs/quality-gate-changes.md"]],
                 Contract.guarded_writes(%(File.write("/tmp/r/docs/quality-gate-changes.md", x)\n), targets)
  end

  def test_guarded_writes_ignores_reads_and_comments
    targets = ["docs/quality-gate-changes.md", ".quality.exs"]

    assert_empty Contract.guarded_writes(%(File.exist?("docs/quality-gate-changes.md")\n), targets)
    assert_empty Contract.guarded_writes(%(File.read(".quality.exs")\n), targets)
    assert_empty Contract.guarded_writes(%(# writing to docs/quality-gate-changes.md is not allowed\n), targets)
  end

  def test_system_or_backticks_detected
    assert_equal [1], Contract.system_or_backticks(%(system("git status")\n))
    assert_equal [1], Contract.system_or_backticks(%(out = `git status`\n))
    assert_empty Contract.system_or_backticks(%(Open3.capture3("git", "status")\n))
    assert_empty Contract.system_or_backticks(%(# never call system(...) here\n))
  end

  def test_unsafe_cp_rm_mv_detected
    assert_equal [[1, "rm"]], Contract.unsafe_cp_rm_mv(%(Sh.run(["rm", path])\n))
    assert_empty Contract.unsafe_cp_rm_mv(%(Sh.run(["rm", "-rf", path])\n))
    assert_empty Contract.unsafe_cp_rm_mv(%(Sh.run(["cp", "-Rfc", src, dst])\n))
    assert_empty Contract.unsafe_cp_rm_mv(%(Sh.run(["mv", "-f", src, dst])\n))
  end

  def test_consumer_vocabulary_detected_on_code_line
    assert_equal [[1, "statifier corpus dirs"]],
                 Contract.consumer_vocabulary(%(EXEMPT = ["test/scion_tests/"]\n))
    assert_equal [[1, "exunit test macro"]],
                 Contract.consumer_vocabulary(%(test "some description" do\n))
    assert_equal [[1, "consumer repo names"]],
                 Contract.consumer_vocabulary(%(repo = "statifier-ex"\n))
  end

  # The gate-config rule keys off whole filenames. A bare `.quality` is also
  # how Ruby spells a method call, and firing on that would make the guard a
  # tax on naming rather than a rule about consumer constants.
  # sabotage: drop the `\.exs` from the quality/credo alternation -> red
  def test_consumer_vocabulary_gate_config_needs_the_whole_filename
    assert_equal [[1, "elixir gate config"]],
                 Contract.consumer_vocabulary(%(File.write(".quality.exs", weakened)\n))
    assert_equal [[1, "elixir gate config"]],
                 Contract.consumer_vocabulary(%(moving = [".credo.exs", "coveralls.json"]\n))

    assert_empty Contract.consumer_vocabulary(%(score = report.quality\n))
    assert_empty Contract.consumer_vocabulary(%(return unless res.quality.positive?\n))
  end

  def test_consumer_vocabulary_ignores_comments
    hits = Contract.consumer_vocabulary(%(# statifier's scion/scxml corpora and mix quality are exempt here\n))
    assert_empty hits
  end
end

# Applies the Contract rules to the real files under .claude/scripts/, so a
# future phase cannot introduce a banned operation without this suite
# catching it.
class ContractTest < Minitest::Test
  SCRIPTS_ROOT = File.expand_path(File.join(__dir__, ".."))

  def all_ruby_files
    Dir.glob(File.join(SCRIPTS_ROOT, "**", "*.rb")).sort
  end

  # Everything except this test file's own directory: the checks are about
  # what scripts (lib/ and top-level) do, not about what the tests assert or
  # exercise via fixtures.
  def non_test_files
    all_ruby_files.reject { |f| f.start_with?(File.join(SCRIPTS_ROOT, "test") + File::SEPARATOR) }
  end

  def test_no_banned_calls_outside_comments
    offenders = []
    non_test_files.each do |file|
      Contract.banned_calls(File.read(file)).each do |(lineno, label)|
        offenders << "#{file}:#{lineno} (#{label})"
      end
    end
    assert_empty offenders, "banned call(s) found outside comments: #{offenders.join(', ')}"
  end

  def test_no_writes_to_ledger_or_gate_config
    targets = ManifestHelper.all_fixture_guarded_paths
    offenders = []
    non_test_files.each do |file|
      Contract.guarded_writes(File.read(file), targets).each do |(lineno, label)|
        offenders << "#{file}:#{lineno} (#{label})"
      end
    end
    assert_empty offenders, "write(s) to a guarded file found in: #{offenders.join(', ')}"
  end

  def test_no_system_or_backticks_everything_goes_through_sh
    offenders = []
    non_test_files.each do |file|
      Contract.system_or_backticks(File.read(file)).each { |lineno| offenders << "#{file}:#{lineno}" }
    end
    assert_empty offenders, "system(...)/backticks found (must go through Sh) in: #{offenders.join(', ')}"
  end

  # Every direct child of .claude/scripts/*.rb is a top-level, directly
  # invokable script and must carry the shebang and the executable bit. In
  # Phase 1 there are none yet (only lib/ and test/ files exist) - this test
  # must not require at least one match, since it runs unchanged in every
  # later phase once top-level scripts do exist.
  def test_top_level_scripts_have_shebang_and_executable_bit
    top_level = Dir.glob(File.join(SCRIPTS_ROOT, "*.rb")).sort

    top_level.each do |file|
      first_line = File.open(file, &:readline).chomp
      assert_equal "#!/usr/bin/env ruby", first_line, "#{file} is missing the #!/usr/bin/env ruby shebang"
      assert File.executable?(file), "#{file} is missing the executable bit"
    end
  end

  def test_cp_rm_mv_argv_carries_non_interactive_flag
    offenders = []
    non_test_files.each do |file|
      Contract.unsafe_cp_rm_mv(File.read(file)).each do |(lineno, cmd)|
        offenders << "#{file}:#{lineno} (#{cmd})"
      end
    end
    assert_empty offenders, "cp/rm/mv argv missing a non-interactive flag in: #{offenders.join(', ')}"
  end

  def test_no_consumer_vocabulary_in_kit_source
    offenders = []
    non_test_files.each do |file|
      Contract.consumer_vocabulary(File.read(file)).each do |(lineno, label)|
        offenders << "#{file}:#{lineno} (#{label})"
      end
    end
    assert_empty offenders,
                 "consumer vocabulary found outside comments: #{offenders.join(', ')} - " \
                 "move the value into the manifest (lib/manifest.rb) and document it in docs/manifest.md"
  end

  # A meta-check on the guardrail itself: prove the scan is not vacuously
  # green just because no scripts exist yet in Phase 1. A fixture file with a
  # violation, dropped into a temp copy of the tree shape, must be caught.
  def test_meta_the_scan_actually_catches_a_planted_violation
    Dir.mktmpdir do |dir|
      planted = File.join(dir, "planted.rb")
      File.write(planted,
                 %(Sh.run(["git", "push", "origin", "main"])\nFile.write(".credo.exs", weakened)\n) \
                 "EXEMPT = [\"test/scion_tests/\"]\n")

      content = File.read(planted)

      refute_empty Contract.banned_calls(content), "the contract scan failed to catch a planted git push"
      refute_empty Contract.guarded_writes(content, [".credo.exs"]),
                   "the contract scan failed to catch a planted gate-config write"
      refute_empty Contract.consumer_vocabulary(content),
                   "the contract scan failed to catch a planted consumer-vocabulary constant"
    end
  end

  # The drift check ADR-0006 promises: every backticked operation its
  # banned-operation constraint names must have a matching Contract rule.
  # This is what makes the ADR text and this file unable to drift apart
  # silently - the gap it closes was real in the donor repo, where the write
  # checks covered .quality.exs but not .credo.exs, coveralls.json, or
  # .sobelow-conf.
  #
  # Backticked terms that are not operations are filtered out: file names
  # (lib/sh.rb), manifest field names (gate.moving_files, gate.guard_ledger),
  # and the argv-safety words (system, backticks, cp, rm, mv) each have their
  # own dedicated test above rather than a BANNED_CALLS entry.
  NON_OPERATIONS = %w[
    lib/sh.rb gate.moving_files gate.guard_ledger system backticks cp rm mv
  ].freeze

  def test_contract_coverage_matches_adr_0006_banned_operations
    adr_path = File.join(SCRIPTS_ROOT, "..", "..", "..", "docs", "adr",
                         "0006-ruby-stdlib-scripts-with-envelope-contract.md")
    adr = File.read(adr_path)

    constraint = adr[/^\*\*1\. The banned-operation list is absolute\.\*\*.*?(?=\n\n)/m]
    refute_nil constraint, "could not locate the banned-operation constraint in ADR-0006 (did its wording change?)"

    operations = constraint.scan(/`([^`]+)`/).flatten - NON_OPERATIONS
    refute_empty operations, "the constraint no longer names any backticked operations - drift check is vacuous"

    # The guarded-write half is manifest-driven rather than a fixed list, so
    # coverage for it means "some fixture declares it", not "Contract names
    # it" (ADR-0006's own explanation of why).
    covered = Contract::BANNED_CALLS.keys + ManifestHelper.all_fixture_guarded_paths
    missing = operations - covered

    assert_empty missing, "ADR-0006 names operations Contract does not cover: #{missing.join(', ')}"
  end
end

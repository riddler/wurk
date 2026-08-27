#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/user_config"
require_relative "lib/outbound_scan"

# OutboundScanCli is the invokable half of ADR-0014: report whether the gate
# is armed (`status`), scan an arbitrary payload (`scan`), assemble and scan
# the git payload for a push from pre-push's ref lines on stdin (`git-refs`),
# and write or remove the pre-push shim itself (`install`).
#
# `status`, `scan`, and `git-refs` are read-only - none shells anything that
# writes, so none takes --dry-run. `install` is mutating and takes --dry-run
# like every other mutating kit script.
module OutboundScanCli
  # Above this many distinct blobs in one push, `git-refs` still scans every
  # one of them and only adds a warning (never a block, never a skip) - see
  # the plan's "Cost and honesty" note.
  LARGE_PUSH_WARNING_THRESHOLD = 2000

  NULL_SHA = "0" * 40

  class << self
    def run(argv, io: $stdout, stdin: $stdin)
      argv = argv.dup
      sub = argv.shift

      case sub
      when "status" then run_status(argv, io)
      when "scan" then run_scan(argv, io, stdin)
      when "git-refs" then run_git_refs(argv, io, stdin)
      when "install" then run_install(argv, io)
      else
        warn usage
        exit 2
      end
    end

    private

    def usage
      "usage: outbound_scan.rb <status|scan|git-refs|install> [options]"
    end

    # --- status -----------------------------------------------------------
    #
    # Runs the scan over an empty payload so the positive-control probe still
    # runs (an armed-but-broken pipeline is what this answers). Exits 0 when
    # armed and probing, 0 when disarmed with the advisory warning, 1 when
    # armed and broken - all of that falls straight out of Envelope#emit,
    # since apply_to_envelope already warns-or-blocks the right way.

    def run_status(argv, io)
      parser, = Cli.build("outbound_scan.rb status")
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "outbound_scan_status")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      result = OutboundScan.run([], config: config)
      OutboundScan.apply_to_envelope(result, env, path_label: "status")

      env.data["armed"] = result.armed?
      env.data["probe_ok"] = result.probe_ok
      env.data["patterns_count"] = patterns_count(config)

      env.emit(io)
    end

    # A COUNT only, never a listing (the plan is explicit about this): the
    # one number that tells an operator their file was read without
    # disclosing anything from it. nil whenever there is nothing readable to
    # count - disarmed, half-configured, or an unreadable/empty/unparseable
    # file, each of which OutboundScan.run already reports as its own
    # blocking error.
    def patterns_count(config)
      return nil unless config.outbound_scan_declared?

      patterns_file = config.outbound_scan_patterns_file
      return nil if patterns_file.nil?

      OutboundScan::PatternSet.load(patterns_file).length
    rescue OutboundScan::LoadError
      nil
    end

    # --- scan ---------------------------------------------------------------
    #
    # The generic entry point: one payload, one location label. Also what
    # makes the whole pipeline testable without git.

    def run_scan(argv, io, stdin)
      options = {}
      parser, options = Cli.build("outbound_scan.rb scan (--file PATH|--stdin)", options) do |opts|
        opts.on("--file PATH", "scan this file's content") { |v| options[:file] = v }
        opts.on("--stdin", "scan content read from stdin") { options[:stdin] = true }
      end
      Cli.parse!(parser, argv)

      unless [options[:file], options[:stdin]].compact.length == 1
        warn "outbound_scan.rb scan requires exactly one of --file PATH or --stdin\n\n#{parser}"
        exit 2
      end

      env = Envelope.new(script: "outbound_scan_scan")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      if options[:file]
        location = options[:file]
        text = read_file(options[:file], env)
        return env.emit(io) unless env.blocked.empty?
      else
        location = "stdin"
        text = stdin.read
      end

      result = OutboundScan.run([[location, text]], config: config)
      OutboundScan.apply_to_envelope(result, env, path_label: location)
      env.emit(io)
    end

    def read_file(path, env)
      File.read(path)
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
      env.block!(code: "scan_input_unreadable", message: "could not read #{path}: #{e.class}")
      nil
    end

    # --- git-refs -----------------------------------------------------------
    #
    # Reads git's pre-push ref lines from stdin
    # (`<local ref> <local sha> <remote ref> <remote sha>`) and assembles the
    # full-content payload the plan describes: every newly published commit's
    # blob content (post-image, --no-renames so a move is not invisible),
    # every newly published commit's message, and the ref names themselves.
    # A deletion (all-zero local sha) is skipped entirely - no scan, no
    # refusal.

    def run_git_refs(argv, io, stdin)
      options = {}
      parser, options = Cli.build("outbound_scan.rb git-refs --remote NAME", options) do |opts|
        opts.on("--remote NAME", "the remote name git passes as $1 to pre-push") { |v| options[:remote] = v }
      end
      Cli.parse!(parser, argv)

      if options[:remote].to_s.strip.empty?
        warn "outbound_scan.rb git-refs requires --remote NAME\n\n#{parser}"
        exit 2
      end

      env = Envelope.new(script: "outbound_scan_git_refs")
      config = UserConfig.require!(env)
      return env.emit(io) unless config

      ref_lines = parse_ref_lines(stdin.read).reject { |r| r[:local_sha] == NULL_SHA }

      commits = collect_commits(ref_lines, options[:remote], env)
      return env.emit(io) unless env.blocked.empty?

      blobs = collect_blobs(commits, env)
      return env.emit(io) unless env.blocked.empty?

      payload = build_blob_payload(blobs, env)
      return env.emit(io) unless env.blocked.empty?

      payload.concat(build_commit_message_payload(commits, env))
      return env.emit(io) unless env.blocked.empty?

      ref_lines.each do |r|
        payload << ["ref-name", r[:local_ref].to_s]
        payload << ["ref-name", r[:remote_ref].to_s]
      end

      if blobs.length > LARGE_PUSH_WARNING_THRESHOLD
        env.warn(
          code: "outbound_scan_large_push",
          message: "#{blobs.length} distinct blobs are being scanned for this push; " \
                   "the scan still ran in full, this is advisory only"
        )
      end

      result = OutboundScan.run(payload, config: config)
      OutboundScan.apply_to_envelope(result, env, path_label: "git")

      env.data["objects_scanned"] = blobs.length
      env.data["commits_scanned"] = commits.length

      env.emit(io)
    end

    def parse_ref_lines(input)
      input.to_s.each_line.map(&:strip).reject(&:empty?).map do |line|
        local_ref, local_sha, remote_ref, remote_sha = line.split(/\s+/)
        { local_ref: local_ref, local_sha: local_sha, remote_ref: remote_ref, remote_sha: remote_sha }
      end
    end

    # The exact "what this push publishes to this remote" set for one ref
    # line - and, per the plan, this same rev-list form handles the
    # new-branch case (all-zero remote sha) with no special branch. Distinct
    # commit shas across every ref line in the push.
    def collect_commits(ref_lines, remote, env)
      shas = []
      ref_lines.each do |r|
        result = Sh.run(["git", "rev-list", r[:local_sha], "--not", "--remotes=#{remote}"], envelope: env)
        unless result.success?
          env.block!(code: "git_rev_list_failed", message: err_or(result, "git rev-list failed"))
          return []
        end
        shas.concat(result.out.to_s.each_line.map(&:strip).reject(&:empty?))
      end
      shas.uniq
    end

    # Post-image blob sha and path for every added/modified file in every
    # distinct commit, deduped by blob sha - a file touched in twenty commits
    # is read once per distinct content. --no-renames so a move contributes
    # its full content; --root so the initial commit is not silently skipped.
    def collect_blobs(commits, env)
      blobs = {}
      commits.each do |sha|
        result = Sh.run(
          ["git", "diff-tree", "-r", "--no-commit-id", "--root", "--no-renames",
           "--diff-filter=AM", "--raw", sha],
          envelope: env
        )
        unless result.success?
          env.block!(code: "git_diff_tree_failed", message: err_or(result, "git diff-tree failed"))
          return {}
        end

        result.out.to_s.each_line do |line|
          line = line.strip
          next if line.empty?

          meta, path = line.split("\t", 2)
          next unless meta && path

          new_sha = meta.split(" ")[3]
          next unless new_sha

          blobs[new_sha] ||= path
        end
      end
      blobs
    end

    def build_blob_payload(blobs, env)
      blobs.map do |sha, path|
        result = Sh.run(["git", "cat-file", "blob", sha], envelope: env)
        unless result.success?
          env.block!(code: "git_cat_file_failed", message: err_or(result, "git cat-file blob #{sha[0, 7]} failed"))
          return []
        end
        ["blob:#{sha[0, 7]}:#{path}", result.out]
      end
    end

    # One call for every distinct commit's message (arguments, not stdin -
    # lib/sh.rb closes child stdin). --no-walk=unsorted preserves the given
    # order, so the %x00-delimited output lines back up positionally with
    # `commits`.
    def build_commit_message_payload(commits, env)
      return [] if commits.empty?

      result = Sh.run(["git", "log", "--format=%B%x00", "--no-walk=unsorted"] + commits, envelope: env)
      unless result.success?
        env.block!(code: "git_log_failed", message: err_or(result, "git log failed"))
        return []
      end

      messages = result.out.to_s.split("\x00")
      commits.each_with_index.map { |sha, i| ["commit-message:#{sha[0, 7]}", messages[i].to_s] }
    end

    def err_or(result, fallback)
      msg = result.err.to_s.strip
      msg.empty? ? fallback : msg
    end

    # --- install --------------------------------------------------------------
    #
    # Writes (or, with --uninstall, removes) the pre-push shim: a
    # marker-delimited block in the effective hooks directory's `pre-push`
    # file. See HookInstaller below for the composition rules; this method is
    # only argument parsing, hooks-directory resolution/scope classification,
    # and wiring HookInstaller's plan into the envelope - the same
    # action-list-then-apply shape install.rb uses, which is what makes
    # --dry-run exact rather than narrated.

    def run_install(argv, io)
      options = { uninstall: false, allow_shared_hooks_path: false }
      parser, options = Cli.build(
        "outbound_scan.rb install [--dry-run] [--uninstall] [--allow-shared-hooks-path]", options
      ) do |opts|
        opts.on("--uninstall", "remove only the wurk outbound-scan block, leave everything else untouched") do
          options[:uninstall] = true
        end
        opts.on("--allow-shared-hooks-path",
                "install even though the effective hooks directory is shared by every repo on this machine") do
          options[:allow_shared_hooks_path] = true
        end
      end
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "outbound_scan_install")

      hooks_dir = git_rev_parse(%w[--path-format=absolute --git-path hooks], env)
      common_dir = git_rev_parse(%w[--path-format=absolute --git-common-dir], env)
      return env.emit(io) unless env.blocked.empty?

      scope = HookInstaller.classify_scope(hooks_dir, common_dir)
      env.data["hooks_dir"] = hooks_dir
      env.data["hooks_dir_scope"] = scope

      if scope == "shared" && !options[:allow_shared_hooks_path]
        env.block!(
          code: "shared_hooks_path",
          message: "the effective hooks directory is outside this checkout (core.hooksPath), so installing " \
                   "here would gate every repository on this machine; pass --allow-shared-hooks-path to do " \
                   "that deliberately"
        )
        return env.emit(io)
      end

      pre_push_path = File.join(hooks_dir, "pre-push")
      plan = options[:uninstall] ? HookInstaller.uninstall_plan(pre_push_path) : HookInstaller.install_plan(pre_push_path)

      env.data["pre_push_path"] = pre_push_path
      env.data["action"] = plan.kind.to_s

      if plan.participant_above
        env.warn(
          code: "hook_participant_above_scan",
          message: "another pre-push participant runs before the wurk scan block; re-run this installer to " \
                    "restore ordering"
        )
      end

      if plan.kind == :refuse
        env.block!(code: plan.code, message: "#{pre_push_path} #{plan.message}")
      elsif !options[:dry_run]
        HookInstaller.apply(plan, pre_push_path)
      end

      env.emit(io)
    end

    def git_rev_parse(args, env)
      result = Sh.run(["git", "rev-parse"] + args, envelope: env)
      unless result.success?
        env.block!(code: "git_rev_parse_failed", message: err_or(result, "git rev-parse #{args.join(' ')} failed"))
        return nil
      end
      result.out.to_s.strip
    end
  end
end

# HookInstaller composes the wurk outbound-scan pre-push shim with whatever is
# already at the target `pre-push` path, following install.rb's refusal
# model: an entry that is ours is a no-op; an entry that is not ours, and
# cannot be safely composed with, is refused by name rather than overwritten.
# This module only builds the plan (a Plan value) and applies one when asked
# to - never both in the same call - which is what makes --dry-run exact.
module HookInstaller
  BEGIN_MARKER = "# --- BEGIN WURK OUTBOUND SCAN v1 ---"
  END_MARKER = "# --- END WURK OUTBOUND SCAN v1 ---"

  # The marker-delimited shim body itself, in the same style bd uses so
  # neither tool is tempted to touch the other's block (ADR-0014 point 2).
  # POSIX sh, no backtick anywhere, and it never spells the banned push
  # phrase outside a comment (there is no reason for it to spell that phrase
  # at all, so it simply does not).
  #
  # Behavior: capture stdin to a temp file (git feeds the ref lines there,
  # and later pre-push participants in the same file need them too); run the
  # scan with that file as its stdin; on a nonzero scan exit, remove the temp
  # file and exit 1 (the refusal); on a zero exit, re-point this script's own
  # stdin at the captured lines with `exec < "$tmp"`, remove the temp file
  # (the descriptor stays open), and fall through with no `exit 0`, so the
  # rest of the pre-push file - including anything `bd hooks install`
  # appended below - still runs. The scan script resolves at the symlinked
  # install location (ADR-0002) so the hook survives the worktree it was
  # installed from being removed; a missing script or a missing `ruby` fails
  # closed rather than silently allowing the push.
  SHIM_BLOCK = <<~SHIM.freeze
    #{BEGIN_MARKER}
    # Managed by outbound_scan.rb install. Do not edit between these markers.
    # Captures stdin, runs the wurk outbound scan over it, and on a clean
    # result restores stdin and falls through so later pre-push participants
    # still run. Fails closed if the scanner or ruby cannot be found. See
    # docs/adr/0014.
    wurk_scan_script="${HOME}/.claude/skills/wurk:kit/scripts/outbound_scan.rb"
    if [ ! -f "$wurk_scan_script" ]; then
      echo "wurk outbound scan: scan script missing at $wurk_scan_script; re-run the installer, or pass --uninstall to remove this hook" 1>&2
      exit 1
    fi
    if ! command -v ruby >/dev/null 2>&1; then
      echo "wurk outbound scan: ruby not found on PATH; cannot run the outbound scan" 1>&2
      exit 1
    fi
    wurk_stdin_tmp="$(mktemp)"
    cat > "$wurk_stdin_tmp"
    ruby "$wurk_scan_script" git-refs --remote "$1" < "$wurk_stdin_tmp"
    wurk_scan_status=$?
    if [ "$wurk_scan_status" -ne 0 ]; then
      rm -f "$wurk_stdin_tmp"
      exit 1
    fi
    exec < "$wurk_stdin_tmp"
    rm -f "$wurk_stdin_tmp"
    #{END_MARKER}
  SHIM

  POSIX_SHELLS = %w[sh bash dash zsh].freeze
  BEADS_MARKER_RE = /# --- BEGIN BEADS INTEGRATION/.freeze
  EXIT_STATEMENT_RE = /^\s*exit\b/.freeze

  # kind is one of :create, :insert, :replace, :unchanged, :remove, :refuse.
  # code and message are only meaningful when kind is :refuse (message names
  # the file and says what to do, in install.rb:136-145's voice).
  # participant_above is the detect-and-warn signal, independent of kind.
  Plan = Struct.new(:kind, :code, :message, :participant_above, keyword_init: true) do
    def initialize(participant_above: false, **rest)
      super(participant_above: participant_above, **rest)
    end
  end

  class << self
    def classify_scope(hooks_dir, common_dir)
      return "shared" if hooks_dir.nil? || common_dir.nil?

      (hooks_dir == common_dir || hooks_dir.start_with?(common_dir + File::SEPARATOR)) ? "repo" : "shared"
    end

    # The install-side plan: what would happen to pre_push_path, without
    # touching it. See the module doc for the composition rules.
    def install_plan(pre_push_path)
      return Plan.new(kind: :create, message: "no pre-push hook exists; the wurk block will be created") unless File.exist?(pre_push_path)

      refusal = read_refusal(pre_push_path)
      return refusal if refusal

      content = read_utf8(pre_push_path)
      begin_idx = content.index(BEGIN_MARKER)
      end_idx = content.index(END_MARKER)

      if begin_idx && !end_idx
        return refuse(pre_push_path, "pre_push_unmatched_begin_marker",
                       "contains a wurk BEGIN marker with no matching END marker - fix or remove it by hand, " \
                       "then re-run the installer")
      end

      if begin_idx && end_idx
        kind = block_span(content, begin_idx, end_idx) == SHIM_BLOCK ? :unchanged : :replace
        return Plan.new(kind: kind, participant_above: participant_above?(content, begin_idx))
      end

      shebang = content.each_line.first
      if shebang&.start_with?("#!")
        interpreter = shebang_interpreter(shebang)
        unless POSIX_SHELLS.include?(interpreter)
          return refuse(pre_push_path, "pre_push_non_shell_shebang",
                         "has a #{interpreter.inspect} shebang, not a POSIX shell - a #{interpreter} pre-push " \
                         "cannot host the wurk shell block; move it aside by hand, then re-run the installer")
        end
      end

      Plan.new(kind: :insert, message: "wurk block will be inserted after the shebang")
    end

    # The uninstall-side plan: remove only the wurk block, leave everything
    # else byte for byte. Never deletes the file, even if only a shebang
    # would remain - deleting a file we did not create is the rule this repo
    # does not break.
    def uninstall_plan(pre_push_path)
      unless File.exist?(pre_push_path)
        return Plan.new(kind: :unchanged, message: "no pre-push hook exists; nothing to uninstall")
      end

      refusal = read_refusal(pre_push_path)
      return refusal if refusal

      content = read_utf8(pre_push_path)
      begin_idx = content.index(BEGIN_MARKER)
      return Plan.new(kind: :unchanged, message: "no wurk block found; nothing to uninstall") unless begin_idx

      end_idx = content.index(END_MARKER)
      unless end_idx
        return refuse(pre_push_path, "pre_push_unmatched_begin_marker",
                       "contains a wurk BEGIN marker with no matching END marker - fix or remove it by hand")
      end

      unless File.writable?(pre_push_path)
        return refuse(pre_push_path, "pre_push_unwritable",
                       "is not writable - fix permissions by hand, then re-run the installer")
      end

      Plan.new(kind: :remove, message: "wurk block removed", participant_above: participant_above?(content, begin_idx))
    end

    # Executes one plan against pre_push_path. Never called for :refuse (the
    # caller checks first) and a no-op for :unchanged.
    def apply(plan, pre_push_path)
      case plan.kind
      when :create
        File.write(pre_push_path, "#!/bin/sh\n" + SHIM_BLOCK)
        File.chmod(0o755, pre_push_path)
      when :insert
        File.write(pre_push_path, inserted_content(read_utf8(pre_push_path)))
        File.chmod(0o755, pre_push_path) unless File.executable?(pre_push_path)
      when :replace
        File.write(pre_push_path, spliced_content(read_utf8(pre_push_path), SHIM_BLOCK))
      when :remove
        File.write(pre_push_path, spliced_content(read_utf8(pre_push_path), ""))
      when :unchanged
        # nothing to do
      end
    end

    private

    def read_refusal(pre_push_path)
      unless File.readable?(pre_push_path)
        return refuse(pre_push_path, "pre_push_unreadable",
                       "is not readable - fix permissions by hand, then re-run the installer")
      end

      raw = File.binread(pre_push_path)
      utf8 = raw.dup.force_encoding(Encoding::UTF_8)
      unless utf8.valid_encoding?
        return refuse(pre_push_path, "pre_push_not_utf8",
                       "is not valid UTF-8 - a binary or compiled hook cannot host the wurk shell block; " \
                       "move it aside by hand, then re-run the installer")
      end

      unless File.writable?(pre_push_path)
        return refuse(pre_push_path, "pre_push_unwritable",
                       "is not writable - fix permissions by hand, then re-run the installer")
      end

      nil
    end

    def refuse(pre_push_path, code, message)
      Plan.new(kind: :refuse, code: code, message: message)
    end

    def read_utf8(pre_push_path)
      File.binread(pre_push_path).force_encoding(Encoding::UTF_8)
    end

    def block_span(content, begin_idx, end_idx)
      span_end = end_idx + END_MARKER.length
      span_end += 1 if content[span_end] == "\n"
      content[begin_idx...span_end]
    end

    def spliced_content(content, replacement)
      begin_idx = content.index(BEGIN_MARKER)
      end_idx = content.index(END_MARKER)
      span_end = end_idx + END_MARKER.length
      span_end += 1 if content[span_end] == "\n"
      content[0...begin_idx] + replacement + content[span_end..]
    end

    def inserted_content(content)
      lines = content.each_line.to_a
      if lines.first&.start_with?("#!")
        ([lines.first] + [SHIM_BLOCK] + lines[1..]).join
      else
        ([SHIM_BLOCK] + lines).join
      end
    end

    def shebang_interpreter(shebang_line)
      match = shebang_line.match(/\A#!\s*(\S+)(?:\s+(\S+))?/)
      return nil unless match

      first = File.basename(match[1])
      second = match[2] ? File.basename(match[2]) : nil
      first == "env" && second ? second : first
    end

    # Whether a beads-integration block or a bare `exit` statement sits
    # above our own block (excluding the shebang line, which is not a
    # "participant"). Detected and reported, never repaired (ADR-0014's
    # composition-with-bd note) - re-running the installer is the fix.
    def participant_above?(content, begin_idx)
      before_lines = content[0...begin_idx].each_line.to_a
      before_lines.shift if before_lines.first&.start_with?("#!")
      remainder = before_lines.join
      remainder.match?(BEADS_MARKER_RE) || remainder.match?(EXIT_STATEMENT_RE)
    end
  end
end

exit OutboundScanCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

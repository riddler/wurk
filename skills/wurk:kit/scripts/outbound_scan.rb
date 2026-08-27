#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/user_config"
require_relative "lib/outbound_scan"

# OutboundScanCli is the invokable half of ADR-0014: report whether the gate
# is armed (`status`), scan an arbitrary payload (`scan`), and assemble and
# scan the git payload for a push from pre-push's ref lines on stdin
# (`git-refs`). `install` (the pre-push shim writer) lands in Phase 4; until
# then it is a usage error, same as any unrecognized subcommand.
#
# All three subcommands here are read-only - none shells anything that
# writes, so none takes --dry-run.
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
      when "install"
        warn "outbound_scan.rb install is not implemented yet\n\n#{usage}"
        exit 2
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
  end
end

exit OutboundScanCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

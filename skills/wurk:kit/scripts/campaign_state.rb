#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "lib/envelope"
require_relative "lib/cli"
require_relative "lib/lock"

# CampaignState answers, without parsing markdown by hand, the one question a
# scheduler needs before it can start a campaign unattended: which campaign
# plans are ARMED, what do they cover, is their consent adopted, and is one
# of them already running. It reads plan files, reads consent files, probes
# the campaign mutex (lib/lock.rb, the same mkdir-mutex the conductor takes),
# and - under arm/disarm - rewrites exactly one line of one plan file.
#
# It never invokes the conductor, never takes or releases a lock, and never
# writes a consent file: consent is a human artifact, and arming is only
# meaningful once a human has adopted it (the arm subcommand refuses
# otherwise). The schema it reads is documented in
# skills/wurk:conductor/REFERENCE.md ("Campaign files and campaign_state.rb").
#
# Pure filesystem logic, like lib/lock.rb: no Sh, no manifest. Every path is
# a CLI argument with a conventional default, so a fleet that keeps its
# campaign state elsewhere passes --dir (repeatable) and --locks-dir.
module CampaignState
  DEFAULT_DIR = File.join(".claude", "campaigns")
  LOCKS_SUBDIR = "locks"

  # The plan's Status vocabulary. RUNNING is deliberately absent: a running
  # campaign is one whose mutex is held, which is a fact about the lock dir
  # and not something a file can claim about itself.
  PLAN_STATUSES = %w[DRAFTED ARMED WRAPPED].freeze
  CONSENT_STATUSES = %w[DRAFTED ADOPTED].freeze
  ADOPTED = "ADOPTED"
  ARMED = "ARMED"
  DRAFTED = "DRAFTED"
  WRAPPED = "WRAPPED"

  # `Status: WORD [stamp]` at the start of a line. The stamp is a date with an
  # optional time and zone offset, in the shape the conductor writes by hand
  # ("2026-09-14 18:41 -0600"); anything after it on the line is prose that
  # a rewrite keeps verbatim.
  STATUS_LINE = /\A(Status:[ \t]*)([A-Z]+)((?:[ \t]+\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?(?:[ \t]*(?:[-+]\d{2}:?\d{2}|Z))?)?)/.freeze
  H1 = /\A#[ \t]+(.+?)[ \t]*\z/.freeze
  PLAN_H1 = /\A#[ \t]+Campaign[ \t]+(\S+)[ \t]*\z/.freeze
  H2 = /\A##[ \t]+(.+?)[ \t]*\z/.freeze

  DEFAULT_CLOCK = -> { Time.now }

  class << self
    # Injectable so a test can fix the stamp arm/disarm writes.
    attr_writer :clock

    def clock
      @clock || DEFAULT_CLOCK
    end

    # A plan is a top-level *.md under dir whose first H1 is
    # `# Campaign <id>` with <id> equal to the file's own basename. The
    # consent file (`<id>-consent.md`, H1 "# Campaign <id> consent"), a
    # report (`<id>-report.md`) and anything under journal/ therefore never
    # count, without an exclusion list.
    def plan_paths(dir)
      return [] unless Dir.exist?(dir)

      Dir.glob(File.join(dir, "*.md")).sort.select do |path|
        id = File.basename(path, ".md")
        first_h1(File.read(path)) =~ PLAN_H1 && Regexp.last_match(1) == id
      end
    end

    def first_h1(content)
      content.each_line do |line|
        return line.chomp if line.chomp =~ H1
      end
      nil
    end

    # {status:, stamp:, line:} from the first Status line, or all-nil when
    # the file has none. The word is returned verbatim even outside
    # PLAN_STATUSES / CONSENT_STATUSES so a caller can report it.
    def parse_status(content)
      content.each_line.with_index(1) do |line, lineno|
        match = line.chomp.match(STATUS_LINE)
        next unless match

        stamp = match[3].strip
        return { status: match[2], stamp: stamp.empty? ? nil : stamp, line: lineno }
      end
      { status: nil, stamp: nil, line: nil }
    end

    def known_status?(word)
      PLAN_STATUSES.include?(word)
    end

    # The body of the first `## <name>...` section (heading prefix match, so
    # "## Consent (verbatim, ...)" answers to "Consent"), up to the next H2,
    # with surrounding blank lines dropped. nil when the heading is absent.
    def section(content, name)
      collecting = false
      lines = []
      content.each_line do |line|
        stripped = line.chomp
        if stripped =~ H2
          break if collecting

          collecting = Regexp.last_match(1).start_with?(name)
          next
        end
        lines << stripped if collecting
      end
      return nil unless collecting

      # Trim blank lines at both ends only; a consent quote's indentation is
      # part of the text and must survive.
      lines.shift while lines.first && lines.first.strip.empty?
      lines.pop while lines.last && lines.last.strip.empty?
      lines.join("\n")
    end

    # Rewrites the Status line's word and stamp to `<word> <now>`, keeping
    # everything after the stamp on that line. With no Status line, inserts
    # one as its own paragraph after the first H1 (or at the top when there
    # is no H1). Returns the new content; never touches the filesystem.
    def rewrite_status(content, word, now: clock.call)
      new_head = "Status: #{word} #{stamp(now)}"
      lines = content.lines
      parsed = parse_status(content)

      if parsed[:line]
        index = parsed[:line] - 1
        lines[index] = lines[index].sub(STATUS_LINE, new_head)
        return lines.join
      end

      h1_index = lines.index { |l| l.chomp =~ H1 }
      insert = ["#{new_head}\n", "\n"]
      if h1_index
        lines.insert(h1_index + 1, "\n", *insert)
        # The H1 is normally followed by its own blank line; collapse the
        # double blank that the insert would otherwise leave.
        lines.delete_at(h1_index + 4) if lines[h1_index + 4] == "\n" && lines[h1_index + 3] == "\n"
      else
        lines.unshift(*insert)
      end
      lines.join
    end

    def stamp(time)
      time.strftime("%Y-%m-%d %H:%M %z")
    end

    # Writes content to path via a sibling temp file and rename, so a
    # concurrent reader (a scheduler listing campaigns while a human arms
    # one) sees the old file or the new one, never a half-written one.
    def write_atomically(path, content)
      tmp = "#{path}.tmp-#{Process.pid}"
      File.write(tmp, content)
      File.rename(tmp, path)
    end

    def consent_path(dir, id)
      File.join(dir, "#{id}-consent.md")
    end

    def mutex_dir(locks_dir, id)
      File.join(locks_dir, "campaign-#{id}")
    end

    # One campaign's full record: the shape `list` puts under
    # data.campaigns[] and `show` under data.campaign.
    def inspect_plan(path, locks_dir:)
      dir = File.dirname(path)
      id = File.basename(path, ".md")
      content = File.read(path)
      status = parse_status(content)
      consent = inspect_consent(consent_path(dir, id))
      mutex = inspect_mutex(mutex_dir(locks_dir, id))

      armed = status[:status] == ARMED
      running = mutex[:held] && !mutex[:stale]
      {
        id: id,
        path: path,
        title: first_h1(content),
        status: status[:status],
        status_stamp: status[:stamp],
        armed: armed,
        running: running,
        runnable: armed && consent[:adopted] && !running,
        mode: section(content, "Mode"),
        scope: section(content, "Scope"),
        consent: consent,
        mutex: mutex
      }
    end

    def inspect_consent(path)
      return { path: path, exists: false, status: nil, status_stamp: nil, adopted: false } unless File.file?(path)

      status = parse_status(File.read(path))
      { path: path, exists: true, status: status[:status], status_stamp: status[:stamp], adopted: status[:status] == ADOPTED }
    end

    def inspect_mutex(dir)
      probe = Lock.probe(dir)
      { dir: dir }.merge(probe)
    end
  end
end

# The CLI: list / show read, arm / disarm rewrite one plan file's Status
# line and nothing else. Every subcommand takes the same location flags.
module CampaignStateCli
  SUBCOMMANDS = %w[list show arm disarm].freeze
  USAGE = "campaign_state.rb <list|show ID|arm ID|disarm ID> [--dir DIR ...] [--locks-dir DIR] [--dry-run]"

  class << self
    def run(argv, io: $stdout)
      argv = argv.dup
      subcommand = argv.shift
      unless SUBCOMMANDS.include?(subcommand)
        warn "usage: #{USAGE}"
        exit 2
      end

      options = { dry_run: false, dirs: [] }
      parser, options = Cli.build(USAGE, options) do |opts|
        opts.on("--dir DIR", "campaigns directory (repeatable; default #{CampaignState::DEFAULT_DIR})") { |v| options[:dirs] << v }
        opts.on("--locks-dir DIR", "where campaign mutexes live (default <first --dir>/#{CampaignState::LOCKS_SUBDIR})") { |v| options[:locks_dir] = v }
      end
      args = Cli.parse!(parser, argv)

      options[:dirs] = [File.expand_path(CampaignState::DEFAULT_DIR)] if options[:dirs].empty?
      options[:locks_dir] ||= File.join(options[:dirs].first, CampaignState::LOCKS_SUBDIR)

      env = Envelope.new(script: "campaign_state")
      env.data[:subcommand] = subcommand
      env.data[:dirs] = options[:dirs]
      env.data[:locks_dir] = options[:locks_dir]

      case subcommand
      when "list" then run_list(env, options, io)
      else
        id = args.first
        if id.to_s.strip.empty?
          warn "usage: #{USAGE}\n\n#{parser}"
          exit 2
        end
        send("run_#{subcommand}", env, options, id, io)
      end
    end

    private

    # --- list -----------------------------------------------------------------
    #
    # Read-only, always exit 0. A missing directory is an empty answer with a
    # warning, not a block: "nothing is armed" is a complete answer for a
    # scheduler asking a repo that has never run a campaign.

    def run_list(env, options, io)
      campaigns = []
      options[:dirs].each do |dir|
        unless Dir.exist?(dir)
          env.warn(code: "campaigns_dir_missing", message: "no campaigns directory at #{dir}")
          next
        end
        CampaignState.plan_paths(dir).each do |path|
          campaigns << inspect_and_warn(env, path, options[:locks_dir])
        end
      end
      campaigns.sort_by! { |c| c[:id] }

      env.data[:campaigns] = campaigns
      env.data[:runnable] = campaigns.select { |c| c[:runnable] }.map { |c| c[:id] }
      env.emit(io)
    end

    # --- show -----------------------------------------------------------------

    def run_show(env, options, id, io)
      path = locate(env, options, id)
      return env.emit(io) unless path

      env.data[:campaign] = inspect_and_warn(env, path, options[:locks_dir])
      env.emit(io)
    end

    # --- arm ------------------------------------------------------------------
    #
    # Refuses without an ADOPTED consent file: an ARMED plan is the thing a
    # scheduler is allowed to start, and starting one nobody consented to is
    # the failure this script exists to make impossible. It never creates or
    # edits the consent file to get past its own refusal.

    def run_arm(env, options, id, io)
      path = locate(env, options, id)
      return env.emit(io) unless path

      campaign = inspect_and_warn(env, path, options[:locks_dir])
      env.data[:campaign] = campaign
      env.data[:dry_run] = options[:dry_run]
      env.data[:before] = campaign[:status]
      env.data[:after] = campaign[:status]
      env.data[:changed] = false

      if campaign[:status] == CampaignState::WRAPPED
        env.block!(code: "campaign_wrapped", message: "#{id} is WRAPPED; a wrapped campaign is not re-armed by a script")
        return env.emit(io)
      end

      unless campaign[:consent][:adopted]
        state = campaign[:consent][:exists] ? "Status #{campaign[:consent][:status].inspect}" : "missing"
        env.block!(
          code: "consent_not_adopted",
          message: "consent file #{campaign[:consent][:path]} is #{state}; arming needs an ADOPTED consent, which only a human writes"
        )
        return env.emit(io)
      end

      if campaign[:armed]
        env.warn(code: "already_armed", message: "#{id} is already ARMED (#{campaign[:status_stamp]})")
        return env.emit(io)
      end

      rewrite(env, options, path, campaign, CampaignState::ARMED)
      env.emit(io)
    end

    # --- disarm ---------------------------------------------------------------
    #
    # Flips ARMED back to DRAFTED. Refuses while the campaign's mutex is
    # live-held: the conductor holding it has already read ARMED, and the
    # file flip would not stop it - only mislead the next reader.

    def run_disarm(env, options, id, io)
      path = locate(env, options, id)
      return env.emit(io) unless path

      campaign = inspect_and_warn(env, path, options[:locks_dir])
      env.data[:campaign] = campaign
      env.data[:dry_run] = options[:dry_run]
      env.data[:before] = campaign[:status]
      env.data[:after] = campaign[:status]
      env.data[:changed] = false

      if campaign[:running]
        env.block!(code: "campaign_running", message: "#{id} is running (mutex #{campaign[:mutex][:dir]} is held); disarming the file would not stop it")
        return env.emit(io)
      end

      unless campaign[:armed]
        env.warn(code: "not_armed", message: "#{id} is not ARMED (Status #{campaign[:status].inspect}); nothing to disarm")
        return env.emit(io)
      end

      rewrite(env, options, path, campaign, CampaignState::DRAFTED)
      env.emit(io)
    end

    # --- shared -------------------------------------------------------------------

    def locate(env, options, id)
      options[:dirs].each do |dir|
        path = File.join(dir, "#{id}.md")
        return path if CampaignState.plan_paths(dir).include?(path)
      end
      env.block!(code: "campaign_not_found", message: "no campaign plan #{id}.md (with H1 \"# Campaign #{id}\") under #{options[:dirs].join(', ')}")
      nil
    end

    def inspect_and_warn(env, path, locks_dir)
      campaign = CampaignState.inspect_plan(path, locks_dir: locks_dir)
      id = campaign[:id]

      if campaign[:status] && !CampaignState.known_status?(campaign[:status])
        env.warn(code: "unknown_status", message: "#{id}: Status #{campaign[:status].inspect} is outside #{CampaignState::PLAN_STATUSES.join('/')}; treated as not armed")
      end
      if campaign[:armed] && !campaign[:consent][:exists]
        env.warn(code: "consent_missing", message: "#{id} is ARMED but has no consent file at #{campaign[:consent][:path]}")
      end
      if campaign[:mutex][:stale]
        env.warn(code: "stale_mutex", message: "#{id}: mutex #{campaign[:mutex][:dir]} is held but stale (#{campaign[:mutex][:staleness_reason]}); not counted as running")
      end
      campaign
    end

    def rewrite(env, options, path, campaign, word)
      now = CampaignState.clock.call
      content = File.read(path)
      rewritten = CampaignState.rewrite_status(content, word, now: now)
      env.commands << "rewrite Status line in #{path}: #{campaign[:status] || 'none'} -> #{word} #{CampaignState.stamp(now)}"
      env.data[:after] = word
      env.data[:changed] = true
      return if options[:dry_run]

      CampaignState.write_atomically(path, rewritten)
      env.data[:campaign] = CampaignState.inspect_plan(path, locks_dir: options[:locks_dir])
    end
  end
end

exit CampaignStateCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

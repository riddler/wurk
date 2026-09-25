#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "lib/envelope"
require_relative "lib/cli"
require_relative "lib/lock"
require_relative "lib/user_config"

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
#
# It reads machine config too, but only lazily and only for a plan that
# carries a `Machine:` binding: the kit's `~/.claude/wurk.local.json`
# `machine.name` (lib/user_config.rb) is the authority for whether a bound
# plan is this machine's own. A harness that mirrors that key in its own
# config (Howie's howie.json is one) should read this script's answer
# rather than compare itself - the mirror is known to drift.
module CampaignState
  DEFAULT_DIR = File.join(".claude", "campaigns")
  LOCKS_SUBDIR = "locks"

  # The plan's Status vocabulary. RUNNING is deliberately absent: a running
  # campaign is one whose mutex is held, which is a fact about the lock dir
  # and not something a file can claim about itself. ABORTED is the wrap of
  # a run that stopped on an environment fault before landing anything: it
  # is not armed (the scheduler will not restart it into the same fault),
  # it does NOT satisfy a successor's queue (WRAPPED alone does - one
  # measured night, an aborted predecessor promoted its successor straight
  # into the identical fault), and unlike WRAPPED it may be re-armed by
  # `arm` once the operator has cleared the fault.
  PLAN_STATUSES = %w[DRAFTED QUEUED ARMED WRAPPED ABORTED].freeze
  CONSENT_STATUSES = %w[DRAFTED ADOPTED].freeze
  ADOPTED = "ADOPTED"
  ARMED = "ARMED"
  DRAFTED = "DRAFTED"
  WRAPPED = "WRAPPED"
  QUEUED = "QUEUED"
  ABORTED = "ABORTED"

  # `Status: WORD [stamp]` at the start of a line. The stamp is a date with an
  # optional time and zone offset, in the shape the conductor writes by hand
  # ("2026-09-14 18:41 -0600"); anything after it on the line is prose that
  # a rewrite keeps verbatim.
  STATUS_LINE = /\A(Status:[ \t]*)([A-Z]+)((?:[ \t]+\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?(?:[ \t]*(?:[-+]\d{2}:?\d{2}|Z))?)?)/.freeze
  # `after <id>` immediately following the stamp on a QUEUED Status line;
  # the id names the plan (same campaigns dir) this one queues behind.
  AFTER_TAIL = /\A[ \t]+after[ \t]+([A-Za-z0-9._-]+)/.freeze
  H1 = /\A#[ \t]+(.+?)[ \t]*\z/.freeze
  # Accepts both "# Campaign <id>" and "# Campaign: <id>" - the colon form
  # is what a plan actually gets written as in the wild (see wu-0m0); the
  # trailing \z means "# Campaign <id> consent" still never matches, since
  # \S+ stops at the space before "consent" and leaves it unaccounted for.
  PLAN_H1 = /\A#[ \t]+Campaign:?[ \t]+(\S+)[ \t]*\z/.freeze
  H2 = /\A##[ \t]+(.+?)[ \t]*\z/.freeze

  # `Machine: <name>` at the very start of a line (column 1) - an indented
  # `Machine:` inside prose is not the binding, the same way an indented
  # `Status:` would not be. The only accepted shape after the colon is a
  # bare name in the same character class AFTER_TAIL already uses for a
  # predecessor id ([A-Za-z0-9._-]+), optional trailing whitespace, then
  # end of line (the \z discipline PLAN_H1 uses) - or nothing at all (a
  # blank binding, which is unverified, never unbound - see
  # machine_match). Measured on a real fleet: an operator sometimes writes
  # column-1 prose that happens to start with "Machine:" ("Machine:
  # **personal-air**, QUEUED after RF056 (the operator, ...)."). That line
  # must never be captured as the name - see parse_machine's malformed
  # branch.
  MACHINE_LINE = /\AMachine:[ \t]*([A-Za-z0-9._-]+)?[ \t]*\z/.freeze

  # The four states a campaign's (or a predecessor's) machine binding can
  # be in. "unbound" and "this_machine" both count toward armed/runnable;
  # "other_machine" and "unverified" both gate it off - the two are kept
  # distinct because a consumer's warning text differs (a shared fleet dir
  # vs. a fail-safe this machine cannot resolve).
  MACHINE_MATCHES = %w[unbound this_machine other_machine unverified].freeze

  DEFAULT_CLOCK = -> { Time.now }

  class << self
    # Injectable so a test can fix the stamp arm/disarm writes.
    attr_writer :clock

    def clock
      @clock || DEFAULT_CLOCK
    end

    # A plan is a top-level *.md under dir whose first H1 is `# Campaign
    # <id>` or `# Campaign: <id>` with <id> equal to the file's own
    # basename. The consent file (`<id>-consent.md`, H1 "# Campaign <id>
    # consent"), a report (`<id>-report.md`) and anything under journal/
    # therefore never count, without an exclusion list.
    def plan_paths(dir)
      return [] unless Dir.exist?(dir)

      Dir.glob(File.join(dir, "*.md")).sort.select do |path|
        id = File.basename(path, ".md")
        first_h1(read_utf8(path)) =~ PLAN_H1 && Regexp.last_match(1) == id
      end
    end

    # Every top-level *.md under dir that plan_paths did NOT recognize as a
    # plan, minus the expected companions of a plan it DID recognize
    # (`<id>-consent.md`, `<id>-report.md`). This is the other half of "no
    # plan is ever silently absent" (wu-0m0), narrowed by a second finding
    # from the same bead: a real campaigns dir accumulates finished WRAPPED
    # plans in a legacy H1 shape that nobody will migrate, and a warning
    # that fires on every one of those forever is noise that buries the
    # one case that matters. `locate` (arm/disarm/show) refuses a file
    # whose H1 does not match, so a file with a bad H1 can only carry
    # Status ARMED or QUEUED by hand edit - the exact hazard wu-0m0
    # describes, an armed campaign the --armed refusal checks cannot
    # count. So only THOSE are reported; WRAPPED, DRAFTED, an unknown
    # word, or no Status line at all stays silent. Each entry is
    # {path:, reason:, status:}: reason is the short human sentence
    # naming what failed to match a plan, status is the column-1 Status
    # word read from the file (nil when it has none).
    def unparsed_campaign_files(dir)
      return [] unless Dir.exist?(dir)

      plans = plan_paths(dir)
      companions = plans.flat_map do |path|
        id = File.basename(path, ".md")
        ["#{id}-consent.md", "#{id}-report.md"]
      end

      Dir.glob(File.join(dir, "*.md")).sort.reject do |path|
        plans.include?(path) || companions.include?(File.basename(path))
      end.map do |path|
        { path: path, reason: unparsed_reason(path), status: parse_status(read_utf8(path))[:status] }
      end.select { |file| %w[ARMED QUEUED].include?(file[:status]) }
    end

    # The short reason a file did not parse into a plan record, for
    # unparsed_campaign_files' warning text.
    def unparsed_reason(path)
      id = File.basename(path, ".md")
      h1 = first_h1(read_utf8(path))
      return "no H1 heading" if h1.nil?

      match = h1.match(PLAN_H1)
      return "H1 #{h1.inspect} does not match \"# Campaign <id>\" or \"# Campaign: <id>\"" unless match
      return "H1 names #{match[1].inspect}, not #{id.inspect} (the file's own basename)" unless match[1] == id

      "did not parse as a campaign plan"
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
        after = line.chomp[match[0].length..].to_s[AFTER_TAIL, 1]
        return { status: match[2], stamp: stamp.empty? ? nil : stamp, after: after, line: lineno }
      end
      { status: nil, stamp: nil, after: nil, line: nil }
    end

    def known_status?(word)
      PLAN_STATUSES.include?(word)
    end

    # {machine:, line:, malformed:, raw:} from the first column-1
    # `Machine:` line, or {machine: nil, line: nil, malformed: false,
    # raw: nil} when the plan carries no binding at all. `machine` is `""`
    # for a blank binding ("Machine:" with nothing after it) - distinct
    # from nil, which means either the line is absent (malformed: false)
    # or present but not in the accepted shape (malformed: true, `raw`
    # carries the offending line's text for the warning). `machine` never
    # carries a malformed line's raw text.
    def parse_machine(content)
      content.each_line.with_index(1) do |line, lineno|
        stripped = line.chomp
        next unless stripped.start_with?("Machine:")

        match = stripped.match(MACHINE_LINE)
        return { machine: match[1] || "", line: lineno, malformed: false, raw: nil } if match

        return { machine: nil, line: lineno, malformed: true, raw: stripped }
      end
      { machine: nil, line: nil, malformed: false, raw: nil }
    end

    # Compares a plan's (or a predecessor's) `Machine:` binding against this
    # machine's own name and returns one of MACHINE_MATCHES. A malformed
    # line (see parse_machine) is always "unverified", whatever binding or
    # this_machine were passed - it was never a name to compare. A nil
    # binding (no `Machine:` line) is "unbound" regardless of this_machine
    # - the unbound, single-machine case this whole feature must leave
    # untouched. A blank binding or an unresolved this_machine is
    # "unverified": the fail-safe direction, since the failure being
    # prevented is two conductors on one campaign, and a machine that
    # cannot prove the plan is its own must decline rather than guess.
    def machine_match(binding, this_machine, malformed: false)
      return "unverified" if malformed
      return "unbound" if binding.nil?
      return "unverified" if binding.empty? || this_machine.nil?

      binding == this_machine ? "this_machine" : "other_machine"
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
    # everything after the stamp on that line. `drop_after` also removes an
    # `after <id>` tail directly after the old stamp (disarm on a QUEUED
    # plan: the predecessor means nothing once the plan is DRAFTED); prose
    # past that tail is still kept. With no Status line, inserts one as its
    # own paragraph after the first H1 (or at the top when there is no H1).
    # Returns the new content; never touches the filesystem.
    def rewrite_status(content, word, now: clock.call, tail: nil, drop_after: false)
      new_head = "Status: #{word} #{stamp(now)}"
      new_head += " #{tail}" if tail
      lines = content.lines
      parsed = parse_status(content)

      if parsed[:line]
        index = parsed[:line] - 1
        rest = lines[index][lines[index][STATUS_LINE].length..]
        rest = rest.sub(AFTER_TAIL, "") if drop_after
        lines[index] = new_head + rest
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

    # Rewrites the plan's Machine line to `name`, or inserts one when the
    # plan carries none. When a Machine: line already exists, only its
    # value changes (the same word-only rewrite rewrite_status does for
    # Status); otherwise a new line is inserted directly after the Status
    # line - the shape `arm --host` produces, composing after
    # rewrite_status, or landing on a plan that already had one - or after
    # the H1 the same way rewrite_status does when the plan has no Status
    # line either. Returns the new content; never touches the filesystem.
    def rewrite_machine(content, name)
      lines = content.lines
      parsed = parse_machine(content)

      if parsed[:line]
        index = parsed[:line] - 1
        eol = lines[index].end_with?("\n") ? "\n" : ""
        lines[index] = "Machine: #{name}#{eol}"
        return lines.join
      end

      status = parse_status(content)
      if status[:line]
        lines.insert(status[:line], "Machine: #{name}\n")
        return lines.join
      end

      new_head = "Machine: #{name}"
      h1_index = lines.index { |l| l.chomp =~ H1 }
      insert = ["#{new_head}\n", "\n"]
      if h1_index
        lines.insert(h1_index + 1, "\n", *insert)
        lines.delete_at(h1_index + 4) if lines[h1_index + 4] == "\n" && lines[h1_index + 3] == "\n"
      else
        lines.unshift(*insert)
      end
      lines.join
    end

    def stamp(time)
      time.strftime("%Y-%m-%d %H:%M %z")
    end

    # Reads a campaign file as UTF-8 regardless of the caller's locale. A
    # bare File.read tags the string with Ruby's default external encoding,
    # which under launchd (no LANG/LC_ALL/LC_CTYPE) is US-ASCII; the first
    # regex match against a file with any non-ASCII byte then raises
    # ArgumentError and kills the whole `list` run instead of just this one
    # campaign. Same shape as outbound_scan.rb's read_utf8.
    def read_utf8(path)
      File.binread(path).force_encoding(Encoding::UTF_8)
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
    # data.campaigns[] and `show` under data.campaign. `this_machine` is a
    # callable, invoked at most once and only when this plan (or, via
    # inspect_queue, its predecessor) actually carries a `Machine:`
    # binding with a name in it - an unbound plan never touches machine
    # config, which is what lets every existing single-machine caller and
    # test keep working unchanged with the default (`-> { nil }`).
    def inspect_plan(path, locks_dir:, this_machine: -> { nil })
      dir = File.dirname(path)
      id = File.basename(path, ".md")
      content = read_utf8(path)
      status = parse_status(content)
      machine_parsed = parse_machine(content)
      machine_binding = machine_parsed[:machine]
      consent = inspect_consent(consent_path(dir, id))
      mutex = inspect_mutex(mutex_dir(locks_dir, id))

      queued = status[:status] == QUEUED
      queue = queued ? inspect_queue(dir, status[:after], locks_dir: locks_dir, this_machine: this_machine) : nil

      resolved_machine = machine_binding && !machine_binding.empty? ? this_machine.call : nil
      machine_match_value = machine_match(machine_binding, resolved_machine, malformed: machine_parsed[:malformed])

      # A satisfied QUEUED plan is virtually promoted: it reports armed
      # without a file write, so a scheduler keying off `armed` starts it
      # on its next tick and never sees two ARMED plans during the wait.
      # A plan bound to another machine (or unverifiable on this one) is
      # never armed, whatever its Status word says - the binding is a gate
      # on top of the existing rule, not a replacement for it.
      armed = (status[:status] == ARMED || (queued && queue[:satisfied])) &&
              %w[unbound this_machine].include?(machine_match_value)
      running = mutex[:held] && !mutex[:stale]
      {
        id: id,
        path: path,
        title: first_h1(content),
        status: status[:status],
        status_stamp: status[:stamp],
        queued: queued,
        queued_after: status[:after],
        queue: queue,
        machine: machine_binding,
        machine_match: machine_match_value,
        machine_raw: machine_parsed[:raw],
        armed: armed,
        running: running,
        runnable: armed && consent[:adopted] && !running,
        mode: section(content, "Mode"),
        scope: section(content, "Scope"),
        consent: consent,
        mutex: mutex
      }
    end

    # The predecessor check for one QUEUED plan. Satisfied only when the
    # predecessor plan (same campaigns dir) is WRAPPED and its mutex is not
    # live-held: WRAPPED is flipped while the conductor still holds the
    # mutex, and the successor must not start inside that window. A missing
    # or invalid predecessor is never satisfied - a typo must hold the
    # queue, not release it. An ABORTED predecessor is never satisfied
    # either: whatever stopped it is still there. Only the predecessor's
    # own Status word is read, so a chain (C after B after A) advances one
    # wrap at a time.
    #
    # A predecessor bound to another machine (or unverifiable on this one)
    # also holds the queue: this machine cannot see that machine's mutex,
    # so WRAPPED-and-unheld here is not proof the predecessor is actually
    # done. `this_machine` is the same lazy callable inspect_plan takes,
    # threaded through so it is invoked only when the predecessor itself
    # carries a named binding.
    def inspect_queue(dir, after, locks_dir:, this_machine: -> { nil })
      unless after
        return {
          after: nil, satisfied: false, predecessor_status: nil, predecessor_exists: false,
          predecessor_machine: nil, predecessor_machine_match: nil, predecessor_machine_raw: nil
        }
      end

      path = File.join(dir, "#{after}.md")
      exists = File.file?(path) && first_h1(read_utf8(path)) =~ PLAN_H1 && Regexp.last_match(1) == after
      predecessor_content = exists ? read_utf8(path) : nil
      predecessor_status = exists ? parse_status(predecessor_content)[:status] : nil
      predecessor_parsed = exists ? parse_machine(predecessor_content) : { machine: nil, malformed: false, raw: nil }
      predecessor_binding = predecessor_parsed[:machine]
      predecessor_resolved = predecessor_binding && !predecessor_binding.empty? ? this_machine.call : nil
      predecessor_machine_match = machine_match(predecessor_binding, predecessor_resolved, malformed: predecessor_parsed[:malformed])
      predecessor_mutex = inspect_mutex(mutex_dir(locks_dir, after))
      predecessor_running = predecessor_mutex[:held] && !predecessor_mutex[:stale]
      {
        after: after,
        satisfied: exists && predecessor_status == WRAPPED && !predecessor_running &&
                   %w[unbound this_machine].include?(predecessor_machine_match),
        predecessor_status: predecessor_status,
        predecessor_exists: !!exists,
        predecessor_machine: predecessor_binding,
        predecessor_machine_match: predecessor_machine_match,
        predecessor_machine_raw: predecessor_parsed[:raw]
      }
    end

    def inspect_consent(path)
      return { path: path, exists: false, status: nil, status_stamp: nil, adopted: false } unless File.file?(path)

      status = parse_status(read_utf8(path))
      { path: path, exists: true, status: status[:status], status_stamp: status[:stamp], adopted: status[:status] == ADOPTED }
    end

    def inspect_mutex(dir)
      probe = Lock.probe(dir)
      { dir: dir }.merge(probe)
    end
  end
end

# The CLI: list / show read, arm / disarm rewrite one plan file's Status
# line and nothing else (disarm takes ARMED or QUEUED back to DRAFTED).
# Every subcommand takes the same location flags.
module CampaignStateCli
  SUBCOMMANDS = %w[list show arm disarm].freeze
  USAGE = "campaign_state.rb <list|show ID|arm ID [--after ID] [--host NAME]|disarm ID> [--dir DIR ...] [--locks-dir DIR] [--dry-run]"

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
        opts.on("--after ID", "arm only: queue behind campaign ID (writes Status: QUEUED ... after ID)") { |v| options[:after] = v }
        opts.on("--host NAME", "arm only: bind the plan to this machine; NAME must equal ~/.claude/wurk.local.json machine.name") { |v| options[:host] = v }
      end
      args = Cli.parse!(parser, argv)

      if options[:host] && subcommand != "arm"
        warn "usage: #{USAGE}\n\n#{parser}"
        exit 2
      end

      options[:dirs] = [File.expand_path(CampaignState::DEFAULT_DIR)] if options[:dirs].empty?
      options[:locks_dir] ||= File.join(options[:dirs].first, CampaignState::LOCKS_SUBDIR)

      env = Envelope.new(script: "campaign_state")
      env.data[:subcommand] = subcommand
      env.data[:dirs] = options[:dirs]
      env.data[:locks_dir] = options[:locks_dir]

      this_machine = machine_resolver(env)

      case subcommand
      when "list" then run_list(env, options, io, this_machine)
      else
        id = args.first
        if id.to_s.strip.empty?
          warn "usage: #{USAGE}\n\n#{parser}"
          exit 2
        end
        send("run_#{subcommand}", env, options, id, io, this_machine)
      end
    end

    private

    # A per-run memo: this_machine.call resolves UserConfig.current's
    # machine.name at most once per invocation, however many bound plans
    # (or bound predecessors) end up asking for it. An invalid config or
    # unparseable wurk.local.json warns once (user_config_invalid, message
    # is the errors - UserConfig.parse already strips any file content out
    # of a JSON::ParserError's own message) and resolves nil, which
    # machine_match treats as unverified. Unknown-key warnings are NOT
    # relayed here - user_config.rb check owns those, and they are noise
    # for a reader of `list`/`show`.
    def machine_resolver(env)
      resolved = false
      value = nil
      lambda do
        unless resolved
          resolved = true
          begin
            config = UserConfig.current
            if config.valid?
              value = config.machine_name
            else
              env.warn(code: "user_config_invalid", message: config.errors.join("; "))
            end
          rescue JSON::ParserError => e
            env.warn(code: "user_config_invalid", message: e.message)
          end
        end
        value
      end
    end

    # --- list -----------------------------------------------------------------
    #
    # Read-only, always exit 0. A missing directory is an empty answer with a
    # warning, not a block: "nothing is armed" is a complete answer for a
    # scheduler asking a repo that has never run a campaign.

    def run_list(env, options, io, this_machine)
      campaigns = []
      options[:dirs].each do |dir|
        unless Dir.exist?(dir)
          env.warn(code: "campaigns_dir_missing", message: "no campaigns directory at #{dir}")
          next
        end
        CampaignState.plan_paths(dir).each do |path|
          campaigns << inspect_and_warn(env, path, options[:locks_dir], this_machine)
        end
        CampaignState.unparsed_campaign_files(dir).each do |file|
          env.warn(
            code: "unparsed_campaign_file",
            message: "#{file[:path]}: #{file[:reason]}; Status #{file[:status]} but not counted as a campaign plan"
          )
        end
      end
      campaigns.sort_by! { |c| c[:id] }

      env.data[:campaigns] = campaigns
      env.data[:runnable] = campaigns.select { |c| c[:runnable] }.map { |c| c[:id] }
      env.emit(io)
    end

    # --- show -----------------------------------------------------------------

    def run_show(env, options, id, io, this_machine)
      path = locate(env, options, id)
      return env.emit(io) unless path

      env.data[:campaign] = inspect_and_warn(env, path, options[:locks_dir], this_machine)
      env.emit(io)
    end

    # --- arm ------------------------------------------------------------------
    #
    # Refuses without an ADOPTED consent file: an ARMED plan is the thing a
    # scheduler is allowed to start, and starting one nobody consented to is
    # the failure this script exists to make impossible. It never creates or
    # edits the consent file to get past its own refusal.

    def run_arm(env, options, id, io, this_machine)
      path = locate(env, options, id)
      return env.emit(io) unless path

      campaign = inspect_and_warn(env, path, options[:locks_dir], this_machine)
      env.data[:campaign] = campaign
      env.data[:dry_run] = options[:dry_run]
      env.data[:before] = campaign[:status]
      env.data[:after] = campaign[:status]
      env.data[:changed] = false
      env.data[:machine_before] = campaign[:machine]
      env.data[:machine_after] = campaign[:machine]

      if campaign[:status] == CampaignState::WRAPPED
        env.block!(code: "campaign_wrapped", message: "#{id} is WRAPPED; a wrapped campaign is not re-armed by a script")
        return env.emit(io)
      end

      # A plan bound to another machine, or one this machine cannot verify
      # the binding of, is refused outright: the binding is the claim "this
      # machine will conduct it", only the machine making the claim can arm
      # (or disarm) it, and a typo'd foreign name here would silently
      # strand the plan on a machine that never asked for it.
      return env.emit(io) if refuse_foreign_machine(env, id, campaign, this_machine)

      # ABORTED is the one terminal word arm accepts: re-arming after the
      # operator cleared the fault is exactly what the status exists for.
      if campaign[:status] == CampaignState::ABORTED
        env.warn(code: "re_armed_after_abort", message: "#{id} was ABORTED (#{campaign[:status_stamp]}); re-arming assumes the fault it stopped on is cleared")
      end

      unless campaign[:consent][:adopted]
        state = campaign[:consent][:exists] ? "Status #{campaign[:consent][:status].inspect}" : "missing"
        env.block!(
          code: "consent_not_adopted",
          message: "consent file #{campaign[:consent][:path]} is #{state}; arming needs an ADOPTED consent, which only a human writes"
        )
        return env.emit(io)
      end

      host_name, host_blocked = resolve_host(env, options)
      return env.emit(io) if host_blocked

      if options[:after]
        if options[:after] == id
          env.block!(code: "queued_after_self", message: "#{id} cannot queue behind itself")
          return env.emit(io)
        end
        already_queued = campaign[:status] == CampaignState::QUEUED && campaign[:queued_after] == options[:after]
        env.warn(code: "already_queued", message: "#{id} is already QUEUED after #{options[:after]} (#{campaign[:status_stamp]})") if already_queued
        rewrite(env, options, path, campaign, already_queued ? nil : CampaignState::QUEUED, this_machine, tail: "after #{options[:after]}", host: host_name)
        return env.emit(io)
      end

      # Plain arm on a QUEUED plan is the manual promotion path: the file
      # flips to ARMED even when the queue already reports it virtually
      # armed, so the file stops depending on the predecessor's state.
      already_armed = campaign[:armed] && campaign[:status] != CampaignState::QUEUED
      env.warn(code: "already_armed", message: "#{id} is already ARMED (#{campaign[:status_stamp]})") if already_armed

      rewrite(env, options, path, campaign, already_armed ? nil : CampaignState::ARMED, this_machine, host: host_name)
      env.emit(io)
    end

    # --- disarm ---------------------------------------------------------------
    #
    # Flips ARMED back to DRAFTED, and QUEUED too (dropping its `after <id>`
    # tail), so a queued plan can be taken back out of the queue without a
    # hand edit - from the far machine the peer channel's disarm is the only
    # route. Refuses while the campaign's mutex is live-held: the conductor
    # holding it has already read ARMED (or a satisfied queue), and the file
    # flip would not stop it - only mislead the next reader. DRAFTED and the
    # terminal words warn not_armed and change nothing.

    def run_disarm(env, options, id, io, this_machine)
      path = locate(env, options, id)
      return env.emit(io) unless path

      campaign = inspect_and_warn(env, path, options[:locks_dir], this_machine)
      env.data[:campaign] = campaign
      env.data[:dry_run] = options[:dry_run]
      env.data[:before] = campaign[:status]
      env.data[:after] = campaign[:status]
      env.data[:changed] = false
      env.data[:machine_before] = campaign[:machine]
      env.data[:machine_after] = campaign[:machine]

      # The same refusal arm applies, for the same reason: this machine
      # cannot see a foreign machine's mutex, so a disarm from here cannot
      # know whether a conductor there already read ARMED (the same
      # reasoning as campaign_running below). disarm never touches the
      # Machine line either way.
      return env.emit(io) if refuse_foreign_machine(env, id, campaign, this_machine)

      if campaign[:running]
        env.block!(code: "campaign_running", message: "#{id} is running (mutex #{campaign[:mutex][:dir]} is held); disarming the file would not stop it")
        return env.emit(io)
      end

      # The code stays not_armed although QUEUED now disarms too: consumers
      # (a peer handler relaying disarm) match on it.
      queued = campaign[:status] == CampaignState::QUEUED
      unless campaign[:armed] || queued
        env.warn(code: "not_armed", message: "#{id} is neither ARMED nor QUEUED (Status #{campaign[:status].inspect}); nothing to disarm")
        return env.emit(io)
      end

      rewrite(env, options, path, campaign, CampaignState::DRAFTED, this_machine, drop_after: queued)
      env.emit(io)
    end

    # --- shared -------------------------------------------------------------------

    # show/arm/disarm resolve one named id and never enumerate the
    # directory, so they never emit unparsed_campaign_file - a stray or
    # malformed file elsewhere in the dir has nothing to do with the id
    # the caller asked about. `list` is the enumerator, and is where that
    # warning belongs.
    def locate(env, options, id)
      options[:dirs].each do |dir|
        path = File.join(dir, "#{id}.md")
        return path if CampaignState.plan_paths(dir).include?(path)
      end
      env.block!(code: "campaign_not_found", message: "no campaign plan #{id}.md (with H1 \"# Campaign #{id}\") under #{options[:dirs].join(', ')}")
      nil
    end

    def inspect_and_warn(env, path, locks_dir, this_machine)
      campaign = CampaignState.inspect_plan(path, locks_dir: locks_dir, this_machine: this_machine)
      id = campaign[:id]

      if campaign[:status] && !CampaignState.known_status?(campaign[:status])
        env.warn(code: "unknown_status", message: "#{id}: Status #{campaign[:status].inspect} is outside #{CampaignState::PLAN_STATUSES.join('/')}; treated as not armed")
      end
      if campaign[:status].nil?
        env.warn(code: "status_missing", message: "#{id}: no column-1 Status line found; treated as not armed")
      end
      if campaign[:queued] && !campaign[:queued_after]
        env.warn(code: "queued_without_after", message: "#{id}: Status QUEUED names no predecessor (expected \"Status: QUEUED <stamp> after <id>\"); treated as not armed")
      end
      if campaign[:queued] && campaign[:queued_after] && !campaign[:queue][:predecessor_exists]
        env.warn(code: "queue_predecessor_missing", message: "#{id}: queued after #{campaign[:queued_after]}, but no such campaign plan exists; the queue holds until it does")
      end
      if campaign[:queued] && campaign[:queue][:predecessor_status] == CampaignState::ABORTED
        env.warn(code: "queue_predecessor_aborted", message: "#{id}: queued after #{campaign[:queued_after]}, which ABORTED; the queue holds until the operator re-arms #{campaign[:queued_after]} and it WRAPS")
      end
      if campaign[:queued] && campaign[:queue] && %w[other_machine unverified].include?(campaign[:queue][:predecessor_machine_match])
        predecessor_desc = if campaign[:queue][:predecessor_machine_raw]
                              "whose Machine: line is malformed (#{campaign[:queue][:predecessor_machine_raw].inspect})"
                            else
                              "which is bound to #{campaign[:queue][:predecessor_machine].inspect}"
                            end
        env.warn(
          code: "queue_predecessor_remote",
          message: "#{id}: queued after #{campaign[:queued_after]}, #{predecessor_desc}; that predecessor's mutex is not visible from this machine, so the queue holds - plain \"arm #{id}\" (manual promotion) is the operator's path once they know the predecessor has finished"
        )
      end
      if campaign[:machine_raw]
        env.warn(
          code: "machine_binding_malformed",
          message: "#{id}: Machine: line in #{path} is not a bare machine name (#{campaign[:machine_raw].inspect}); the plan is treated as not armed until the line is edited by hand to a bare name, then arm --host can bind it"
        )
      elsif campaign[:machine] == ""
        env.warn(code: "machine_binding_blank", message: "#{id}: Machine: line is present but names no machine; treated as unverified and not armed")
      elsif campaign[:machine] && campaign[:machine_match] == "unverified" && %w[ARMED QUEUED].include?(campaign[:status])
        env.warn(
          code: "machine_name_unset",
          message: "#{id}: bound to #{campaign[:machine].inspect}, but this machine has no ~/.claude/wurk.local.json machine.name set; the plan is treated as not armed"
        )
      end
      if campaign[:armed] && !campaign[:consent][:exists]
        env.warn(code: "consent_missing", message: "#{id} is ARMED but has no consent file at #{campaign[:consent][:path]}")
      end
      if campaign[:mutex][:stale]
        env.warn(code: "stale_mutex", message: "#{id}: mutex #{campaign[:mutex][:dir]} is held but stale (#{campaign[:mutex][:staleness_reason]}); not counted as running")
      end
      campaign
    end

    # Blocks arm/disarm on a plan bound to another machine, or one whose
    # binding this machine cannot verify (unset machine.name, or a blank
    # Machine: line) - true when it blocked (caller emits and returns),
    # false when the plan is unbound or bound to this machine and the
    # caller should proceed.
    def refuse_foreign_machine(env, id, campaign, this_machine)
      case campaign[:machine_match]
      when "other_machine"
        env.block!(
          code: "bound_to_other_machine",
          message: "#{id} is bound to #{campaign[:machine].inspect}, not this machine (#{this_machine.call.inspect}); " \
                    "arming and disarming happen on the machine a plan is bound to - rebinding it is a hand edit of the Machine: line"
        )
        true
      when "unverified"
        if campaign[:machine_raw]
          env.block!(
            code: "machine_binding_malformed",
            message: "#{id}: Machine: line is not a bare machine name (#{campaign[:machine_raw].inspect}); refusing to arm or disarm until the line is edited by hand to a bare name",
            needs: "human"
          )
        elsif campaign[:machine] == ""
          env.block!(
            code: "machine_binding_blank",
            message: "#{id}: Machine: line is present but names no machine; refusing to arm or disarm until the binding is resolved",
            needs: "human"
          )
        else
          env.block!(
            code: "machine_name_unset",
            message: "#{id}: bound to #{campaign[:machine].inspect}, but this machine has no ~/.claude/wurk.local.json machine.name set; " \
                      "refusing to arm or disarm until the binding can be verified",
            needs: "human"
          )
        end
        true
      else
        false
      end
    end

    # arm --host only: resolves NAME against this machine's own
    # machine.name, blocking rather than falling back to the OS hostname.
    # Returns [name_to_bind, blocked?] - name_to_bind is nil unless --host
    # was given and it resolved cleanly.
    def resolve_host(env, options)
      return [nil, false] unless options[:host]

      config = UserConfig.require!(env)
      return [nil, true] unless config

      machine_name = config.machine_name
      if machine_name.nil?
        env.block!(
          code: "machine_name_unset",
          message: "--host needs this machine's name; set machine.name in ~/.claude/wurk.local.json (the OS host name is never used)",
          needs: "human"
        )
        return [nil, true]
      end

      if options[:host] != machine_name
        env.block!(
          code: "host_not_this_machine",
          message: "--host #{options[:host].inspect} does not match this machine's name #{machine_name.inspect} " \
                    "(~/.claude/wurk.local.json machine.name); arm never binds a plan to a name that is not its own",
          needs: "human"
        )
        return [nil, true]
      end

      [machine_name, false]
    end

    # Writes the Status line, the Machine line, or both - each only when it
    # actually changes the file, so an --host-only rebind of an
    # already-armed plan touches nothing but the Machine line, and a plain
    # already-armed/already-queued no-op (word and host both nil or
    # unchanged) writes nothing at all. Both changes are composed into one
    # write_atomically call.
    def rewrite(env, options, path, campaign, word, this_machine, tail: nil, host: nil, drop_after: false)
      now = CampaignState.clock.call
      content = CampaignState.read_utf8(path)
      changed = false

      if word
        content = CampaignState.rewrite_status(content, word, now: now, tail: tail, drop_after: drop_after)
        dropped = drop_after && campaign[:queued_after] ? " (drops after #{campaign[:queued_after]})" : ""
        env.commands << "rewrite Status line in #{path}: #{campaign[:status] || 'none'} -> #{word} #{CampaignState.stamp(now)}#{tail ? " #{tail}" : ''}#{dropped}"
        env.data[:after] = word
        changed = true
      end

      if host && host != campaign[:machine]
        content = CampaignState.rewrite_machine(content, host)
        before = campaign[:machine].to_s.empty? ? "none" : campaign[:machine]
        env.commands << "write Machine line in #{path}: #{before} -> #{host}"
        env.data[:machine_after] = host
        changed = true
      end

      return unless changed

      env.data[:changed] = true
      return if options[:dry_run]

      CampaignState.write_atomically(path, content)
      env.data[:campaign] = CampaignState.inspect_plan(path, locks_dir: options[:locks_dir], this_machine: this_machine)
    end
  end
end

exit CampaignStateCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

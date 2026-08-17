#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/manifest"

# TmuxWindow is the tmux mechanics shared by /new-worktree (open a seeded
# window) and /wurk:cleanup (find, classify, quiesce, close one), per
# statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 5. It carries the
# most fragile logic in the extraction: a byte-level idle classifier, an
# empty-window-id trap that cost a live window on 2026-08-02, and the rule
# that a session is only ever asked to exit, never signaled.
#
# Subcommands: ensure-session, open, find, classify, quiesce, close.
#
# Never kill-pane, never `kill -9`/SIGKILL, no code path that does - a
# quiesce timeout is reported `blocked`, not escalated. (`kill-window` on a
# window every one of whose panes is already a bare shell, in `close`, is not
# this rule - it targets nothing alive.)
#
# `tmux.layout` (manifest) selects between two topologies. Under
# `window-per-issue` (the default) `ensure-session` and `open` address one
# shared, manifest-named session and add a window per workspace - the
# original shape, byte-identical to before this layout existed. Under
# `session-per-issue`, `open` gives each workspace its own tmux *session*,
# named for the workspace, and `ensure-session` becomes a reporting no-op
# because there is no shared session left to ensure. The kill rules above
# apply unchanged under both layouts - nothing about a second layout loosens
# them. This file ships no default editor: `tmux.editor` is an optional
# manifest argv, and no concrete editor binary is ever named in kit source.
module TmuxWindow
  SHELL_COMMANDS = %w[fish zsh bash sh].freeze

  # session-per-issue: the name of the second window, holding the seeded
  # claude session. The first window - present only when tmux.editor is
  # configured - is named from the editor argv instead, never from a
  # constant here (see Decision 5: no editor name ever appears in this file).
  CLAUDE_WINDOW_NAME = "claude"

  # The convergence point every caller relies on: editing this one template
  # reaches every seeded session without touching the calling skills.
  # `%{id}` is the bead id and `%{trailer}` the manifest's
  # commits.trailer.key, both substituted per call.
  #
  # Both substitutions exist because both were once literals here, and a
  # literal in this template fails silently: the session launches, works,
  # and only the last instruction is wrong, with nobody watching the window.
  # `/wurk:commit` survived the phase 2 rename this way (wu-bls), and "the Refs
  # trailer" is statifier's key, not every project's.
  FINISH_TEMPLATE = " When the work is complete, finish with /wurk:commit --auto " \
                     "- it writes the %{trailer} trailer and refuses if the tree " \
                     "carries changes unrelated to %{id}. Do not run git commit directly."

  # Spinner match: the timer chunk or the literal "esc to interrupt" -
  # *never* the verb ("Cooking…", "Forging…", ...), which is randomized per
  # frame and is not an exhaustive list this script could match against.
  SPINNER_TIMER = /\(\d+s · /
  SPINNER_INTERRUPT = "esc to interrupt"
  SGR = /\e\[[0-9;]*m/.freeze
  DIM_SPAN = /\e\[2m.*?\e\[0m/m.freeze

  QUIESCE_MAX_POLLS = 15
  QUIESCE_POLL_INTERVAL_SECONDS = 1
  CLASSIFY_SAMPLE_INTERVAL_SECONDS = 3

  # wu-ds2: the charge floor above which caffeinate_prefix will still wrap a
  # seeded session on battery. Strictly greater than, not >= - see power_ok?.
  BATTERY_FLOOR_PERCENT = 40

  class << self
    # Swappable sleep, the same shape as Sh.runner= - tests inject a no-op so
    # the poll loops below run at full speed against FakeSh instead of
    # actually waiting up to 15 real seconds.
    attr_writer :sleep_fn

    def sleep_fn
      @sleep_fn ||= ->(seconds) { Kernel.sleep(seconds) }
    end

    # Exact-match target for a session name. Fish and zsh expand a leading
    # `=` as a command path (equals-expansion), so a bare `-t =my-session:`
    # typed at a shell dies with "my-session: not found" before tmux ever
    # sees it (verified 2026-08-02). Sh.run always uses argv with no shell in
    # between, so that quoting hazard cannot occur here - this stays anyway,
    # because anyone reading a rendered `commands` line will copy it into a
    # shell.
    def session_target(session)
      "=#{session}"
    end

    def run(argv, io: $stdout)
      argv = argv.dup
      sub = argv.shift

      case sub
      when "ensure-session" then ensure_session(argv, io)
      when "open" then open_window(argv, io)
      when "find" then find_window(argv, io)
      when "classify" then classify_cmd(argv, io)
      when "quiesce" then quiesce(argv, io)
      when "close" then close_window(argv, io)
      else
        warn usage
        exit 2
      end
    end

    # The idle classifier, as a pure function over already-captured pane
    # text (`tmux capture-pane -e -p`'s stdout) - no I/O in here, which is
    # what makes it testable against byte-for-byte fixtures.
    #
    # -e is required upstream: Claude Code renders a greyed-out suggested
    # next prompt in an otherwise-empty input box, and without -e's ANSI
    # styling that placeholder is indistinguishable from real typed text -
    # every idle session with a suggestion reads as busy. Real typed text is
    # never wrapped in the dim/faint SGR span; only the placeholder is.
    #
    # Returns "busy" or "idle". Callers that need to tell an empty box apart
    # from a placeholder box can inspect the source; the sampling contract
    # (idle both times, ~3s apart) only ever needs this boolean.
    def classify(text)
      # tmux capture-pane's stdout is normally UTF-8, but a raw/binmode read
      # (as the fixture files use) comes back ASCII-8BIT; force it back so
      # the UTF-8 regex literals below (❯) can match against it.
      text = text.to_s.dup.force_encoding(Encoding::UTF_8)
      text = text.scrub unless text.valid_encoding?
      return "busy" if text.include?(SPINNER_INTERRUPT) || text =~ SPINNER_TIMER

      last = last_prompt_line(text)
      return "idle" if last.nil?

      after_marker = last.sub(/\A.*?❯ ?/, "")
      return "idle" unless visible_text?(after_marker)

      wholly_dim_wrapped?(after_marker) ? "idle" : "busy"
    end

    private

    def usage
      "usage: tmux_window.rb <ensure-session|open|find|classify|quiesce|close> [options]"
    end

    # The manifest's `tmux` section is optional: absent means the project
    # opted out of tmux integration entirely, which is a block rather than a
    # default. Guessing a session name would create a second, parallel
    # session nothing else in the kit knows how to find. Only the two
    # subcommands that address a session by name (`ensure-session`, `open`)
    # need this; `find`, `classify`, `quiesce` and `close` all work from a
    # window id and stay session-agnostic.
    def tmux_manifest(env)
      manifest = Manifest.require!(env)
      return nil unless manifest

      unless manifest.tmux?
        env.block!(
          code: "tmux_not_configured",
          message: "no tmux section in #{manifest.path}; this project has not opted into tmux integration"
        )
        return nil
      end

      manifest
    end

    # The seeded session's command line. `--model` is always passed
    # explicitly, never left to whatever ~/.claude/settings.json's global
    # default happens to be: a skill's own `model:` frontmatter governs that
    # skill's invocation once a session is already running, and does not
    # govern the CLI session itself being launched here. The value is
    # `tmux.model` from the manifest; the flag must not be "simplified" away.
    def claude_command(model, seed, id, trailer_key, no_finish: false)
      body = no_finish ? seed : "#{seed}.#{format(FINISH_TEMPLATE, id: id, trailer: trailer_key)}"
      "#{caffeinate_prefix}claude --permission-mode auto --model #{model} '#{body}'"
    end

    # wu-esa: keep the machine from idle-sleeping out from under a seeded
    # session left to run unattended. `caffeinate -i <command>` asserts
    # idle-sleep prevention scoped to the wrapped child's lifetime - awake
    # while the session runs, released the instant it exits, crashes, or is
    # quiesced. No pmset write, no detached daemon, nothing global to
    # remember to undo.
    #
    # This is a runtime probe, not a manifest field: `caffeinate` is a
    # platform capability, not a consumer-project constant, so probing for
    # it needs no manifest schema change and stays correct on a machine that
    # doesn't have it (settled on the bead - see wu-esa's notes). The probe
    # also doubles as the only opt-out; there is no separate flag. Two
    # conditions both have to hold to wrap the command:
    #
    #   1. `caffeinate` exists on PATH.
    #   2. The machine is on AC power, or on battery with charge strictly
    #      above a 40% floor (see power_ok?, which
    #      reads both from the one `pmset -g batt` shell-out). wu-esa shipped
    #      AC-only and rejected a percentage threshold for having no evidence
    #      behind any particular number. On 2026-08-13 that evidence arrived:
    #      four seeded sessions launched unwrapped on battery at 71%, and the
    #      Mac idle-slept mid-run and killed an in-flight /wurk:implement
    #      --loop phase (wu-ds2). 40% is the settled floor from that
    #      incident - high enough to leave real runway, low enough that
    #      "on battery" alone is no longer read as "let it sleep." Below the
    #      floor, the OS's own judgment about when to sleep is left alone -
    #      that is the case wu-esa was actually protecting, and it stays
    #      protected.
    #
    # Accepted limitation (wu-ds2): the probe runs once, at launch, and
    # `caffeinate -i` is lifetime-scoped by design - it cannot re-evaluate
    # once the child is running. Charge is a continuously falling number
    # during the very run the assertion is holding awake, so a session
    # seeded at 41% keeps its assertion all the way down to 0%, while one
    # seeded at 39% never gets it at all. That is a real limit of a
    # launch-string approach applied to a value that keeps changing after
    # launch, not an oversight left to fix later - it is accepted rather
    # than solved by re-probing mid-run, which this script does not do.
    #
    # Either check failing - no `caffeinate`, no `pmset` (non-macOS), on
    # battery at or below the floor, an unparseable or missing percentage,
    # or any shell-out error - degrades to the empty string, giving a launch
    # string byte-identical to the unwrapped one. That degrade is not a
    # warning or an error; it's the expected shape on any platform, power
    # state, or charge level this doesn't apply to.
    def caffeinate_prefix
      return "" unless caffeinate_available? && power_ok?

      "caffeinate -i "
    end

    # Sh.run's real runner shells out via Open3.popen3(*argv), which raises
    # Errno::ENOENT (not a failed Result) when the binary itself is missing
    # - the exact case a platform with no `which` on PATH hits. The comment
    # above promises "any shell-out error degrades to the empty string", so
    # both probes rescue StandardError rather than letting that propagate
    # out of claude_command and break every seeded launch.
    def caffeinate_available?
      Sh.run(["which", "caffeinate"]).success?
    rescue StandardError
      false
    end

    # Both lines come from the one `pmset -g batt` shell-out: the first names
    # the power source, the second carries the percentage, e.g.
    #   Now drawing from 'Battery Power'
    #    -InternalBattery-0 (id=1234)\t71%; discharging; 3:21 remaining present: true
    # AC power short-circuits true without needing the percentage at all -
    # the floor only ever applies on battery. Any failure to shell out, or
    # to find a `\d+%` on the second line, degrades to false, the same as
    # every other path in this probe.
    def power_ok?
      res = Sh.run(["pmset", "-g", "batt"])
      return false unless res.success?

      lines = res.out.to_s.lines
      return true if lines.first.to_s.include?("AC Power")

      percent = lines[1].to_s[/(\d+)%/, 1]
      return false if percent.nil?

      percent.to_i > BATTERY_FLOOR_PERCENT
    rescue StandardError
      false
    end

    # --- classify helpers ------------------------------------------------

    # The transcript echoes every user message with the same ❯ marker, so an
    # earlier line says nothing about the current state - only the last one
    # does.
    def last_prompt_line(text)
      lines = text.each_line.map(&:chomp).select { |l| l.include?("❯") }
      lines.last
    end

    # False when what follows the marker is nothing, or only SGR codes
    # (\e[39m, \e[0m, ...) or whitespace with no visible characters.
    def visible_text?(after_marker)
      !only_styling?(after_marker)
    end

    # True when every visible character after the marker sits inside a
    # \e[2m ... \e[0m span - Claude's suggested-prompt placeholder. Strip
    # complete dim spans first; if anything visible survives outside them,
    # this is real typed text (a draft, or a dialog like " ❯ 1. Yes"), not a
    # placeholder.
    def wholly_dim_wrapped?(after_marker)
      only_styling?(after_marker.gsub(DIM_SPAN, ""))
    end

    # True when nothing but SGR codes and whitespace is left. Whitespace goes
    # through [[:space:]], not the shared blank?'s String#strip, because strip
    # leaves U+00A0 behind.
    def only_styling?(chunk)
      chunk.gsub(SGR, "").gsub(/[[:space:]]/, "").empty?
    end

    # --- ensure-session ----------------------------------------------------

    def ensure_session(argv, io)
      parser, options = Cli.build("tmux_window.rb ensure-session [options]")
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "tmux_window_ensure_session")
      dry_run = options[:dry_run]

      manifest = tmux_manifest(env)
      return env.emit(io) unless manifest

      if manifest.tmux_layout == "session-per-issue"
        # Nothing to ensure: each workspace's session is created by `open`,
        # named after the workspace. Reported rather than silently skipped so
        # the caller can say what happened, and so a stray tmux.session under
        # this layout is visible instead of quietly ignored.
        env.data["layout"] = "session-per-issue"
        env.data["created"] = false
        env.data["skipped"] = true
        env.data["reason"] = "session-per-issue: each workspace gets its own session"
        env.data["session_name_unused"] = !blank?(manifest.tmux_session)
        return env.emit(io)
      end
      env.data["layout"] = "window-per-issue"

      session = manifest.tmux_session

      # The session's working directory is the main checkout, asked of git
      # at runtime rather than read from a constant - a hardcoded absolute
      # path is correct on exactly one machine, and wrong silently
      # everywhere else (the session opens in a directory that is not a
      # checkout of anything).
      main_repo = Manifest.main_checkout
      unless main_repo
        env.block!(
          code: "main_checkout_unknown",
          message: "git rev-parse --git-common-dir gave no main checkout to open the session in"
        )
        return env.emit(io)
      end

      has_argv = ["tmux", "has-session", "-t", session_target(session)]
      new_argv = ["tmux", "new-session", "-d", "-s", session, "-c", main_repo]

      if dry_run
        env.commands << Sh.render(has_argv)
        env.commands << "(only if has-session fails) " + Sh.render(new_argv)
        env.data["session"] = session
        env.data["main_repo"] = main_repo
        return env.emit(io)
      end

      has_res = Sh.run(has_argv, envelope: env)
      if has_res.success?
        env.data["session"] = session
        env.data["created"] = false
        return env.emit(io)
      end

      new_res = Sh.run(new_argv, envelope: env)
      unless new_res.success?
        env.block!(code: "session_create_failed", message: err_or(new_res, "tmux new-session failed"))
        return env.emit(io)
      end

      env.data["session"] = session
      env.data["main_repo"] = main_repo
      env.data["created"] = true
      env.emit(io)
    end

    # --- open --------------------------------------------------------------

    def open_window(argv, io)
      options = { no_finish: false }
      parser, options = Cli.build("tmux_window.rb open [options] <name> <path> <id> <seed>", options) do |opts|
        opts.on("--no-finish", "seed the session with no appended /wurk:commit finishing clause " \
                                "(a seed that makes its own commit, or a workspace whose name " \
                                "carries no bead id)") do
          options[:no_finish] = true
        end
      end
      args = Cli.parse!(parser, argv)
      name, path, id, seed = args
      if [name, path, id, seed].any? { |a| blank?(a) }
        usage_error!("tmux_window.rb open <name> <path> <id> <seed>", parser)
      end

      env = Envelope.new(script: "tmux_window_open")
      dry_run = options[:dry_run]

      manifest = tmux_manifest(env)
      return env.emit(io) unless manifest

      if manifest.tmux_layout == "session-per-issue"
        return open_window_session_per_issue(manifest, name, path, id, seed, options, env, io)
      end

      session = manifest.tmux_session
      model = manifest.tmux_model

      # Guard on the window name, the same way worktree_create.rb refuses an
      # existing branch or directory - a hit here is a normal outcome
      # (report and skip), never a reason to create a second window with the
      # same name.
      list_argv = ["tmux", "list-windows", "-t", session_target(session), "-F", '#{window_name}']
      list_res = Sh.run(list_argv, envelope: env)
      if list_res.success? && list_res.out.to_s.each_line.map(&:chomp).include?(name)
        env.data["name"] = name
        env.data["path"] = path
        env.data["skipped"] = true
        env.data["reason"] = "window #{name} already exists"
        return env.emit(io)
      end

      keys = claude_command(model, seed, id, manifest.trailer_key, no_finish: options[:no_finish])
      new_argv = ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "#{session_target(session)}:", "-n", name, "-c", path]

      if dry_run
        env.commands << Sh.render(new_argv)
        env.commands << Sh.render(["tmux", "send-keys", "-t", "$win", keys, "Enter"])
        env.data["name"] = name
        env.data["path"] = path
        env.data["model"] = model
        env.data["no_finish"] = options[:no_finish]
        env.data["skipped"] = false
        return env.emit(io)
      end

      new_res = Sh.run(new_argv, envelope: env)
      window_id = new_res.out.to_s.strip

      # Refuse to issue any -t command when the captured id is empty. An
      # empty -t "" does not error - tmux resolves it to the *current*
      # window, which cost a live window on 2026-08-02.
      if !new_res.success? || window_id.empty?
        env.block!(
          code: "window_id_empty",
          message: "tmux new-window produced no window id for #{name.inspect}; " \
                    "refusing to target -t with an empty id (#{err_or(new_res, 'no output')})"
        )
        return env.emit(io)
      end

      send_res = Sh.run(["tmux", "send-keys", "-t", window_id, keys, "Enter"], envelope: env)
      env.warn(code: "send_keys_failed", message: err_or(send_res, "tmux send-keys failed")) unless send_res.success?

      env.data["window_id"] = window_id
      env.data["name"] = name
      env.data["path"] = path
      env.data["model"] = model
      env.data["no_finish"] = options[:no_finish]
      env.data["skipped"] = false
      env.emit(io)
    end

    # session-per-issue: the workspace name IS the session name (wu-aqy). The
    # duplicate guard is has-session rather than a window-name scan, because
    # the session is this layout's unique key - same shape as
    # worktree_create.rb's branch/directory guards.
    #
    # `new-session` always creates a first window, so it is used AS the
    # first window rather than leaving an unnamed one behind. With an editor
    # configured that first window is the editor; with none it is claude, and
    # the session has exactly one window. Never three.
    #
    # With tmux.editor configured - three commands after the guard:
    #   tmux has-session -t =<name>                       -> skip if it exists
    #   tmux new-session -d -s <name> -c <path> -n <editor> -- <editor argv...>
    #   tmux new-window  -d -P -F '#{window_id}' -t =<name>: -n claude -c <path>
    #   tmux send-keys   -t <claude window id> <keys> Enter
    #
    # With no tmux.editor - two commands after the guard:
    #   tmux has-session -t =<name>                       -> skip if it exists
    #   tmux new-session -d -P -F '#{window_id}' -s <name> -c <path> -n claude
    #   tmux send-keys   -t <claude window id> <keys> Enter
    #
    # The editor window name is File.basename(editor_argv.first) - derived,
    # never a literal editor name in this file. The claude window id is
    # captured from new-window's -P -F in the editor case and from
    # new-session's own -P -F in the no-editor case; either way the captured
    # id goes through the same empty-window-id trap as window-per-issue's
    # `open` before it is ever used to target a -t. The guard (has-session)
    # is read-only and runs for real even under --dry-run, the same way
    # window-per-issue's list-windows guard already does; only the mutating
    # commands below it are deferred and rendered instead.
    def open_window_session_per_issue(manifest, name, path, id, seed, options, env, io)
      dry_run = options[:dry_run]
      model = manifest.tmux_model
      editor_argv = manifest.tmux_editor_argv

      env.data["layout"] = "session-per-issue"
      env.data["session"] = name
      env.data["name"] = name
      env.data["path"] = path
      env.data["model"] = model
      env.data["no_finish"] = options[:no_finish]

      has_argv = ["tmux", "has-session", "-t", session_target(name)]
      has_res = Sh.run(has_argv, envelope: env)
      if has_res.success?
        env.data["skipped"] = true
        env.data["reason"] = "session #{name} already exists"
        return env.emit(io)
      end

      keys = claude_command(model, seed, id, manifest.trailer_key, no_finish: options[:no_finish])
      editor_name = editor_argv && File.basename(editor_argv.first)
      session_new_argv =
        if editor_argv
          ["tmux", "new-session", "-d", "-P", "-F", '#{window_id}', "-s", name, "-c", path,
           "-n", editor_name, "--"] + editor_argv
        else
          ["tmux", "new-session", "-d", "-P", "-F", '#{window_id}', "-s", name, "-c", path,
           "-n", CLAUDE_WINDOW_NAME]
        end
      claude_window_argv = ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t",
                             "#{session_target(name)}:", "-n", CLAUDE_WINDOW_NAME, "-c", path]

      if dry_run
        env.commands << Sh.render(session_new_argv)
        env.commands << Sh.render(claude_window_argv) if editor_argv
        env.commands << Sh.render(["tmux", "send-keys", "-t", "$win", keys, "Enter"])
        env.data["skipped"] = false
        env.data["editor_window_id"] = nil
        return env.emit(io)
      end

      session_res = Sh.run(session_new_argv, envelope: env)
      unless session_res.success?
        env.block!(code: "session_create_failed", message: err_or(session_res, "tmux new-session failed"))
        return env.emit(io)
      end

      if editor_argv
        editor_window_id = session_res.out.to_s.strip
        env.data["editor_window_id"] = editor_window_id.empty? ? nil : editor_window_id

        new_res = Sh.run(claude_window_argv, envelope: env)
        window_id = new_res.out.to_s.strip

        # Refuse to issue any -t command when the captured id is empty. An
        # empty -t "" does not error - tmux resolves it to the *current*
        # window, which cost a live window on 2026-08-02.
        if !new_res.success? || window_id.empty?
          env.block!(
            code: "window_id_empty",
            message: "tmux new-window produced no window id for #{name.inspect}; " \
                      "refusing to target -t with an empty id (#{err_or(new_res, 'no output')})"
          )
          return env.emit(io)
        end
      else
        env.data["editor_window_id"] = nil
        window_id = session_res.out.to_s.strip

        if window_id.empty?
          env.block!(
            code: "window_id_empty",
            message: "tmux new-session produced no window id for #{name.inspect}; " \
                      "refusing to target -t with an empty id (#{err_or(session_res, 'no output')})"
          )
          return env.emit(io)
        end
      end

      send_res = Sh.run(["tmux", "send-keys", "-t", window_id, keys, "Enter"], envelope: env)
      env.warn(code: "send_keys_failed", message: err_or(send_res, "tmux send-keys failed")) unless send_res.success?

      env.data["window_id"] = window_id
      env.data["skipped"] = false
      env.emit(io)
    end

    # --- find ----------------------------------------------------------------

    def find_window(argv, io)
      parser, = Cli.build("tmux_window.rb find [options] <name> <path>")
      args = Cli.parse!(parser, argv)
      name, path = args
      usage_error!("tmux_window.rb find <name> <path>", parser) if blank?(name) || blank?(path)

      env = Envelope.new(script: "tmux_window_find")
      list_argv = ["tmux", "list-panes", "-a", "-F", '#{window_id} #{window_name} #{pane_current_path}']
      res = Sh.run(list_argv, envelope: env)

      unless res.success?
        env.data["found"] = false
        env.data["window_id"] = nil
        env.warn(code: "list_panes_failed", message: err_or(res, "tmux list-panes failed"))
        return env.emit(io)
      end

      # Match on name and path together - matching on name alone would close
      # a window a human renamed onto something else; matching on path alone
      # would close a stray shell someone happened to cd there.
      matches = res.out.to_s.each_line.map(&:chomp).reject(&:empty?)
                   .map { |l| l.split(" ", 3) }
                   .select { |_wid, wname, wpath| wname == name && wpath == path }

      case matches.length
      when 0
        env.data["found"] = false
        env.data["window_id"] = nil
      when 1
        env.data["found"] = true
        env.data["window_id"] = matches.first[0]
      else
        env.block!(
          code: "ambiguous_window_match",
          message: "more than one window matches name=#{name.inspect} path=#{path.inspect}: " \
                    "#{matches.map { |m| m[0] }.join(', ')} - two windows claiming one worktree is a state a human should look at"
        )
      end

      env.emit(io)
    end

    # --- classify (subcommand: does the I/O, calls the pure classify) -----

    def classify_cmd(argv, io)
      parser, = Cli.build("tmux_window.rb classify [options] <window_id>")
      args = Cli.parse!(parser, argv)
      window_id = args.first

      env = Envelope.new(script: "tmux_window_classify")
      if blank?(window_id)
        env.block!(code: "empty_window_id", message: "refusing to capture: empty window id would target -t as the current window")
        return env.emit(io)
      end

      # Check what the pane is actually running before ever touching the
      # byte-level classifier below. A pane sitting at a bare shell prompt -
      # claude already exited, quiesce already ran, or the session was never
      # started - is not "idle"; idle/busy is a distinction between two
      # states of a running claude session, and a bare shell is neither.
      # Same predicate poll_for_shell and close_window use against
      # pane_current_command, so all three agree on what "exited" means.
      panes_argv = ["tmux", "list-panes", "-t", window_id, "-F", '#{pane_current_command}']
      panes_res = Sh.run(panes_argv, envelope: env)
      if bare_shell_panes?(panes_res)
        env.data["window_id"] = window_id
        env.data["status"] = "exited"
        return env.emit(io)
      end

      first = capture_and_classify(window_id, env)
      TmuxWindow.sleep_fn.call(CLASSIFY_SAMPLE_INTERVAL_SECONDS)
      second = capture_and_classify(window_id, env)

      # Sample twice, ~3s apart, and require idle both times - one capture
      # can land in the gap between a turn ending and the next tool call
      # starting.
      status = (first == "idle" && second == "idle") ? "idle" : "busy"

      env.data["window_id"] = window_id
      env.data["samples"] = [first, second]
      env.data["status"] = status
      env.emit(io)
    end

    def capture_and_classify(window_id, env)
      res = Sh.run(["tmux", "capture-pane", "-e", "-p", "-t", window_id], envelope: env)
      return "busy" unless res.success?

      TmuxWindow.classify(res.out)
    end

    # --- quiesce -----------------------------------------------------------

    def quiesce(argv, io)
      parser, options = Cli.build("tmux_window.rb quiesce [options] <window_id>")
      args = Cli.parse!(parser, argv)
      window_id = args.first

      env = Envelope.new(script: "tmux_window_quiesce")
      if blank?(window_id)
        env.block!(code: "empty_window_id", message: "refusing to quiesce: empty window id would target -t as the current window")
        return env.emit(io)
      end

      poll_argv = ["tmux", "list-panes", "-t", window_id, "-F", '#{pane_current_command}']

      if options[:dry_run]
        env.commands << Sh.render(["tmux", "send-keys", "-t", window_id, "C-u"])
        env.commands << Sh.render(["tmux", "send-keys", "-t", window_id, "/exit", "Enter"])
        env.commands << Sh.render(poll_argv)
        env.data["window_id"] = window_id
        return env.emit(io)
      end

      # C-u first, so /exit cannot land appended to leftover text in the
      # input line.
      Sh.run(["tmux", "send-keys", "-t", window_id, "C-u"], envelope: env)
      Sh.run(["tmux", "send-keys", "-t", window_id, "/exit", "Enter"], envelope: env)

      exited = poll_for_shell(window_id, poll_argv, env)

      env.data["window_id"] = window_id
      if exited
        env.data["status"] = "exited"
      else
        # Never kill-pane, never SIGKILL. A session that will not take
        # /exit is doing something, and the point of this step is to not be
        # the thing that interrupts it - a timeout is reported, not escalated.
        env.block!(
          code: "quiesce_timeout",
          message: "session in window #{window_id} did not exit within " \
                    "#{QUIESCE_MAX_POLLS * QUIESCE_POLL_INTERVAL_SECONDS}s of /exit"
        )
      end

      env.emit(io)
    end

    def poll_for_shell(window_id, poll_argv, env)
      QUIESCE_MAX_POLLS.times do |i|
        res = Sh.run(poll_argv, envelope: env)
        return true if bare_shell_panes?(res)

        TmuxWindow.sleep_fn.call(QUIESCE_POLL_INTERVAL_SECONDS) unless i == QUIESCE_MAX_POLLS - 1
      end
      false
    end

    # --- close ---------------------------------------------------------------

    def close_window(argv, io)
      parser, options = Cli.build("tmux_window.rb close [options] <window_id>")
      args = Cli.parse!(parser, argv)
      window_id = args.first

      env = Envelope.new(script: "tmux_window_close")
      if blank?(window_id)
        env.block!(code: "empty_window_id", message: "refusing to close: empty window id would target -t as the current window")
        return env.emit(io)
      end

      panes_argv = ["tmux", "list-panes", "-t", window_id, "-F", '#{pane_current_command}']
      res = Sh.run(panes_argv, envelope: env)
      unless res.success?
        env.block!(code: "list_panes_failed", message: err_or(res, "tmux list-panes failed for window #{window_id}"))
        return env.emit(io)
      end

      unless bare_shell_panes?(res)
        env.data["window_id"] = window_id
        env.data["closed"] = false
        env.data["reason"] = "window kept, other panes busy"
        return env.emit(io)
      end

      kill_argv = ["tmux", "kill-window", "-t", window_id]

      if options[:dry_run]
        env.commands << Sh.render(kill_argv)
        env.data["window_id"] = window_id
        env.data["closed"] = false
        env.data["reason"] = "all panes bare shell, would close"
        return env.emit(io)
      end

      kill_res = Sh.run(kill_argv, envelope: env)
      unless kill_res.success?
        env.warn(code: "kill_window_failed", message: err_or(kill_res, "tmux kill-window failed for #{window_id}"))
        env.data["window_id"] = window_id
        env.data["closed"] = false
        return env.emit(io)
      end

      env.data["window_id"] = window_id
      env.data["closed"] = true
      env.emit(io)
    end

    # --- shared helpers ------------------------------------------------------

    # The one definition of "every pane in this window is a bare shell, not
    # claude" - poll_for_shell (quiesce), close_window, and classify_cmd all
    # decide the same thing against the same `pane_current_command` output
    # and must not fork the semantics. `res` is a Sh::Result from a
    # `tmux list-panes -F '#{pane_current_command}'` call; a failed capture
    # is never treated as bare shells, so callers fail toward "still
    # running" rather than toward "safe to close/skip".
    # sabotage: body replaced with `false` unconditionally -> red across all
    # three call sites (test_close_kills_the_window_when_every_pane_is_a_bare_shell,
    # test_classify_cmd_reports_exited_when_pane_is_a_bare_shell,
    # test_quiesce_sends_ctrl_u_then_exit_then_polls_to_a_bare_shell) -
    # proof this is one shared definition, not three copies.
    def bare_shell_panes?(res)
      return false unless res.success?

      commands = res.out.to_s.each_line.map(&:chomp).reject(&:empty?)
      !commands.empty? && commands.all? { |c| SHELL_COMMANDS.include?(c) }
    end

    def blank?(value)
      value.to_s.strip.empty?
    end

    def err_or(result, fallback)
      msg = result.err.to_s.strip
      msg.empty? ? fallback : msg
    end

    def usage_error!(usage_line, parser)
      warn "usage: #{usage_line}\n\n#{parser}"
      exit 2
    end
  end
end

exit TmuxWindow.run(ARGV) if __FILE__ == $PROGRAM_NAME

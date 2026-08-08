#!/usr/bin/env ruby
# frozen_string_literal: true

# install.rb - links this repo's skills and agents into ~/.claude/.
#
# Wurk is consumed by symlink (ADR-0002/ADR-0003): the skills live here, in
# git, and ~/.claude points at them, so an edit here is live everywhere with
# no copy step. This script is the whole install mechanism.
#
#   ruby install.rb                 # link everything (idempotent)
#   ruby install.rb --dry-run       # say what would happen, change nothing
#   ruby install.rb --uninstall     # remove only the links that point here
#   ruby install.rb --home DIR      # target DIR/.claude instead of $HOME
#
# Two rules make re-running safe:
#
#   - An entry that is already our symlink is a no-op, not an error.
#   - An entry that is NOT our symlink is never touched. A real directory,
#     a real file, or a symlink pointing outside this repo is refused by
#     name and the run exits 1. Nothing here overwrites what it did not
#     create.
#
# Note the two halves differ in shape. Skills install as directories named
# `wurk:<name>` - the colon is part of the installed name. Agent names may
# not contain a colon, so agents install as individual `wurk-<name>.md`
# files. That is why this script globs twice rather than once.
#
# Output is plain text, not the kit's JSON envelope. The envelope contract
# (docs/adr/0006, skills/wurk:kit/REFERENCE.md) governs scripts that a skill
# runs and a model reads; this one is run by a human at a shell, once per
# machine, and reads better as lines.
#
# Stdlib only, and nothing here knows a username: the repo root comes from
# __dir__ and the destination from $HOME, so a clone on a second machine
# installs with the same command (plan cracks item 22).

require "optparse"
require "fileutils"

module Install
  # One thing to do to one path. `kind` drives both the output label and
  # whether the run is a success; `path` is the destination under ~/.claude.
  Action = Struct.new(:kind, :path, :target, :message, keyword_init: true)

  # kinds that mean "the run did not fully succeed"
  REFUSALS = [:refuse].freeze

  class Installer
    SKILL_GLOB = "skills/wurk:*"
    AGENT_GLOB = "agents/*.md"

    attr_reader :repo_root, :home

    def initialize(repo_root:, home:)
      @repo_root = File.expand_path(repo_root)
      @home = File.expand_path(home)
    end

    def claude_dir
      File.join(home, ".claude")
    end

    def skills_dir
      File.join(claude_dir, "skills")
    end

    def agents_dir
      File.join(claude_dir, "agents")
    end

    # Every skill directory this repo ships. Sorted so output and tests are
    # stable; directories only, so a stray file beside them is not linked.
    def skill_sources
      Dir.glob(File.join(repo_root, SKILL_GLOB)).select { |p| File.directory?(p) }.sort
    end

    def agent_sources
      Dir.glob(File.join(repo_root, AGENT_GLOB)).select { |p| File.file?(p) }.sort
    end

    # The full plan for an install, as data. Nothing is touched until
    # #apply runs it, which is what makes --dry-run exact rather than a
    # narrated guess.
    def install_actions
      actions = []
      [skills_dir, agents_dir].each do |dir|
        actions << Action.new(kind: :mkdir, path: dir) unless File.directory?(dir)
      end

      (pairs(skill_sources, skills_dir) + pairs(agent_sources, agents_dir)).each do |source, dest|
        actions << link_action(source, dest)
      end

      actions
    end

    # Uninstall works from what is installed, not from what this repo
    # currently ships: a skill renamed or deleted since install time still
    # has a link pointing here, and leaving it behind would leave a dangling
    # /wurk:* name that resolves to nothing.
    def uninstall_actions
      [skills_dir, agents_dir].flat_map { |dir| uninstall_actions_in(dir) }
    end

    # Executes actions in order. In dry-run mode it executes nothing and the
    # caller still gets the same lines, refusals included - a dry run of a
    # refusing install exits 1, because that is the answer.
    def apply(actions, dry_run: false, io: $stdout)
      actions.each do |action|
        perform(action) unless dry_run || REFUSALS.include?(action.kind)
        io.puts(format_action(action, dry_run: dry_run))
      end
      io.puts(summary(actions, dry_run: dry_run))
      actions.any? { |a| REFUSALS.include?(a.kind) } ? 1 : 0
    end

    private

    def pairs(sources, dest_dir)
      sources.map { |source| [source, File.join(dest_dir, File.basename(source))] }
    end

    # The four states a destination can be in, and the one refusal among
    # them. Order matters: File.exist? is false for a broken symlink, so
    # the symlink test has to come first or a dangling link looks absent
    # and the create then fails with EEXIST.
    def link_action(source, dest)
      if File.symlink?(dest)
        current = resolve_link(dest)
        if current == source
          Action.new(kind: :ok, path: dest, target: source, message: "already linked")
        elsif inside_repo?(current)
          Action.new(kind: :relink, path: dest, target: source,
                     message: "was linked to #{relative_to_repo(current)}")
        else
          Action.new(kind: :refuse, path: dest, target: source,
                     message: "symlink points outside this repo (#{current}) - remove it by hand if it is stale")
        end
      elsif File.exist?(dest)
        Action.new(kind: :refuse, path: dest, target: source,
                   message: "exists and is not a symlink - move it aside by hand")
      else
        Action.new(kind: :link, path: dest, target: source)
      end
    end

    def uninstall_actions_in(dir)
      return [] unless File.directory?(dir)

      Dir.children(dir).sort.map do |name|
        path = File.join(dir, name)
        next unless File.symlink?(path)

        target = resolve_link(path)
        next unless inside_repo?(target)

        Action.new(kind: :unlink, path: path, target: target)
      end.compact
    end

    def perform(action)
      case action.kind
      when :mkdir then FileUtils.mkdir_p(action.path)
      when :link then File.symlink(action.target, action.path)
      when :relink
        File.unlink(action.path)
        File.symlink(action.target, action.path)
      when :unlink then File.unlink(action.path)
      end
    end

    # Absolute, symlink-resolved-one-hop target of a link. Relative link
    # targets resolve against the link's own directory, which is how a
    # hand-made `ln -s ../../repo/skills/wurk:commit` still gets recognized
    # as ours.
    def resolve_link(path)
      File.expand_path(File.readlink(path), File.dirname(path))
    end

    def inside_repo?(path)
      path == repo_root || path.start_with?(repo_root + File::SEPARATOR)
    end

    def relative_to_repo(path)
      inside_repo?(path) ? path.sub(repo_root + File::SEPARATOR, "") : path
    end

    def display(path)
      path.start_with?(home + File::SEPARATOR) ? path.sub(home, "~") : path
    end

    LABELS = {
      mkdir: "mkdir ",
      link: "link  ",
      relink: "relink",
      unlink: "unlink",
      ok: "ok    ",
      refuse: "REFUSE"
    }.freeze

    def format_action(action, dry_run:)
      line = +"#{LABELS.fetch(action.kind)}  #{display(action.path)}"
      line << " -> #{relative_to_repo(action.target)}" if action.target && action.kind != :unlink
      line << " (#{action.message})" if action.message
      line << "  [dry run]" if dry_run
      line
    end

    def summary(actions, dry_run:)
      counts = actions.group_by(&:kind).transform_values(&:size)
      parts = LABELS.keys.map { |k| "#{counts[k]} #{k}" if counts[k] }.compact
      body = parts.empty? ? "nothing to do" : parts.join(", ")
      dry_run ? "#{body} (dry run - nothing changed)" : body
    end
  end

  module_function

  def main(argv, io: $stdout)
    options = { dry_run: false, uninstall: false, home: ENV["HOME"] || Dir.home }

    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby install.rb [--dry-run] [--uninstall] [--home DIR]"
      opts.on("--dry-run", "print what would change, change nothing") { options[:dry_run] = true }
      opts.on("--uninstall", "remove only the symlinks that point into this repo") { options[:uninstall] = true }
      opts.on("--home DIR", "install under DIR/.claude instead of $HOME") { |v| options[:home] = v }
      opts.on("--help", "print this help") do
        io.puts opts
        return 0
      end
    end

    begin
      parser.parse!(argv)
    rescue OptionParser::ParseError => e
      warn "#{e.message}\n\n#{parser}"
      return 2
    end

    unless argv.empty?
      warn "unexpected argument: #{argv.first}\n\n#{parser}"
      return 2
    end

    installer = Installer.new(repo_root: __dir__, home: options[:home])
    actions = options[:uninstall] ? installer.uninstall_actions : installer.install_actions
    installer.apply(actions, dry_run: options[:dry_run], io: io)
  end
end

exit Install.main(ARGV) if $PROGRAM_NAME == __FILE__

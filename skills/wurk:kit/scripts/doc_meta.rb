#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/manifest"

# DocMeta is the metadata/filename/frontmatter shell around /wurk:research
# and /wurk:plan: the metadata triple, the one filename rule shared by both
# document directories (`artifacts.plans` and `artifacts.research`),
# research-doc frontmatter emission, and the follow-up-research mutation. See
# statifier-ex docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 8.
#
# It emits frontmatter and filenames; it never writes section headings or
# body content into a document. A scaffolding script that emitted section
# headings would invite filling them, and nothing in a skeleton stops a
# model writing recommendations into /wurk:research's output.
module DocMeta
  # Field order for a research-doc frontmatter block, per
  # .claude/skills/research-codebase/SKILL.md's "Generate research document"
  # step. beads_issue and last_updated_note are optional - omitted from the
  # rendered block when absent.
  FRONTMATTER_FIELDS = %w[
    date researcher git_commit branch repository beads_issue topic tags
    status last_updated last_updated_by last_updated_note
  ].freeze

  class << self
    # The document directories this script will write into: the manifest's
    # `artifacts.plans` and `artifacts.research`. A project that keeps them
    # somewhere else entirely (thoughts/shared/plans, say) needs no change
    # here, and a --dir naming anything outside the pair is still refused.
    def valid_dirs(manifest)
      manifest.artifact_dirs
    end

    # Builds "YYMMDD-[issue-id-]kebab-description.md" - one rule for both
    # document directories (a bead-prefix rename once rippled through every
    # one of these filenames, which is the argument for a single builder).
    # issue is used as-is - it may itself contain a dot (e.g. "st-00p.3") -
    # only description is kebab-cased.
    def build_filename(date_stamp:, description:, issue: nil)
      parts = [date_stamp]
      parts << issue if issue && !issue.to_s.strip.empty?
      parts << kebab(description)
      "#{parts.join('-')}.md"
    end

    def kebab(text)
      text.to_s.strip.downcase
          .gsub(/[^a-z0-9.]+/, "-")
          .gsub(/-{2,}/, "-")
          .gsub(/\A-|-\z/, "")
    end

    # Renders the frontmatter block, "---" delimiters included, in field
    # order - skipping any optional field whose value is nil/empty. topic is
    # double-quoted, with backslashes and double quotes escaped; tags renders
    # as a bracketed, comma-separated list.
    def render_frontmatter(fields)
      lines = ["---"]
      FRONTMATTER_FIELDS.each do |key|
        value = fields[key]
        value = fields[key.to_sym] if value.nil?
        next if value.nil? || (value.respond_to?(:empty?) && value.empty?)

        lines << "#{key}: #{render_value(key, value)}"
      end
      lines << "---"
      "#{lines.join("\n")}\n"
    end

    def render_value(key, value)
      case key
      when "topic"
        "\"#{escape_topic(value.to_s)}\""
      when "tags"
        "[#{Array(value).join(', ')}]"
      else
        value.to_s
      end
    end

    # Parses a frontmatter block (leading/trailing "---" included) back into
    # a plain string-keyed hash - the inverse of render_frontmatter, including
    # unescaping a quoted topic's backslashes and double quotes. Good enough
    # for this codebase's controlled format; not a general YAML parser.
    def parse_frontmatter(text)
      inner = text.to_s.sub(/\A---\s*\n/, "").sub(/\n---\s*\n?\z/, "")
      fields = {}
      inner.each_line do |raw|
        line = raw.chomp
        next if line.strip.empty?

        key, value = line.split(":", 2)
        next unless key && value

        fields[key.strip] = parse_value(value.strip)
      end
      fields
    end

    def parse_value(raw)
      if raw.start_with?("[") && raw.end_with?("]")
        raw[1..-2].split(",").map(&:strip).reject(&:empty?)
      elsif raw.start_with?('"') && raw.end_with?('"') && raw.length >= 2
        unescape_topic(raw[1..-2])
      else
        raw
      end
    end

    # render_value's topic escaping: backslash first, then double quote, so
    # the two substitutions don't feed each other (escaping the quote first
    # would have its inserted backslash re-escaped by the backslash pass).
    def escape_topic(text)
      text.gsub("\\", "\\\\\\\\").gsub('"', "\\\"")
    end

    # The inverse of escape_topic: unescape double quotes then backslashes,
    # the reverse order of escape_topic's passes, so a literal \" round-trips
    # to a literal double quote rather than staying escaped.
    def unescape_topic(text)
      text.gsub('\\"', '"').gsub("\\\\", "\\")
    end

    # The follow-up mutation named in .claude/skills/research-codebase/
    # SKILL.md's "Handle follow-up questions" step: bump last_updated,
    # (re)set last_updated_note, and append a timestamped
    # "## Follow-up Research <timestamp>" heading - nothing else. Only the
    # heading is written, never body prose, so this stays additive to
    # whatever the model writes underneath it.
    def apply_follow_up(text, date_iso:, note:)
      fm_text = text[/\A---\n.*?\n---\n/m]
      raise ArgumentError, "no frontmatter block found at the start of the document" unless fm_text

      fields = parse_frontmatter(fm_text)
      fields["last_updated"] = date_iso.to_s[0, 10]
      fields["last_updated_by"] ||= "Claude"
      fields["last_updated_note"] = note

      new_fm = render_frontmatter(fields)
      rewritten = text.sub(fm_text, new_fm)
      "#{rewritten.rstrip}\n\n## Follow-up Research #{date_iso}\n"
    end
  end
end

# The thin CLI: metadata / filename / frontmatter / follow-up.
module DocMetaCli
  SUBCOMMANDS = %w[metadata filename frontmatter follow-up].freeze

  class << self
    def run(argv, io: $stdout)
      argv = argv.dup
      sub = argv.shift

      case sub
      when "metadata" then run_metadata(argv, io)
      when "filename" then run_filename(argv, io)
      when "frontmatter" then run_frontmatter(argv, io)
      when "follow-up" then run_follow_up(argv, io)
      else
        warn usage
        exit 2
      end
    end

    private

    def usage
      "usage: doc_meta.rb <metadata|filename|frontmatter|follow-up> [options]"
    end

    # --- metadata -----------------------------------------------------

    def run_metadata(argv, io)
      parser, = Cli.build("doc_meta.rb metadata")
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "doc_meta_metadata")
      date_res = Sh.run(["date", "+%Y-%m-%dT%H:%M:%S%z"], envelope: env)
      commit_res = Sh.run(%w[git rev-parse HEAD], envelope: env)
      branch_res = Sh.run(%w[git branch --show-current], envelope: env)

      unless date_res.success?
        env.block!(code: "date_failed", message: err_or(date_res, "date failed"))
        return env.emit(io)
      end
      unless commit_res.success?
        env.block!(code: "git_rev_parse_failed", message: err_or(commit_res, "git rev-parse HEAD failed"))
        return env.emit(io)
      end

      branch = branch_res.success? ? branch_res.out.to_s.strip : ""
      env.data[:date] = date_res.out.to_s.strip
      env.data[:git_commit] = commit_res.out.to_s.strip
      env.data[:branch] = branch.empty? ? nil : branch
      env.emit(io)
    end

    # --- filename -------------------------------------------------------

    def run_filename(argv, io)
      options = {}
      parser, options = Cli.build("doc_meta.rb filename --dir <dir> --description <text> [--issue <id>] [--date YYMMDD]", options) do |opts|
        opts.on("--dir DIR", "artifacts.plans or artifacts.research") { |v| options[:dir] = v }
        opts.on("--description TEXT") { |v| options[:description] = v }
        opts.on("--issue ID") { |v| options[:issue] = v }
        opts.on("--date DATE", "YYMMDD; defaults to date +%y%m%d") { |v| options[:date] = v }
      end
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "doc_meta_filename")

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest

      valid_dirs = DocMeta.valid_dirs(manifest)
      unless valid_dirs.include?(options[:dir])
        env.block!(code: "invalid_dir", message: "--dir must be one of #{valid_dirs.join(', ')}")
        return env.emit(io)
      end
      if options[:description].to_s.strip.empty?
        env.block!(code: "missing_description", message: "--description is required")
        return env.emit(io)
      end

      date_stamp = options[:date]
      unless date_stamp
        date_res = Sh.run(["date", "+%y%m%d"], envelope: env)
        unless date_res.success?
          env.block!(code: "date_failed", message: err_or(date_res, "date failed"))
          return env.emit(io)
        end
        date_stamp = date_res.out.to_s.strip
      end

      filename = DocMeta.build_filename(date_stamp: date_stamp, description: options[:description], issue: options[:issue])

      env.data[:dir] = options[:dir]
      env.data[:filename] = filename
      env.data[:path] = File.join(options[:dir], filename)
      env.emit(io)
    end

    # --- frontmatter ------------------------------------------------------

    def run_frontmatter(argv, io)
      options = {}
      parser, options = Cli.build("doc_meta.rb frontmatter --topic TEXT [options]", options) do |opts|
        opts.on("--topic TEXT") { |v| options[:topic] = v }
        opts.on("--beads-issue ID") { |v| options[:beads_issue] = v }
        opts.on("--tags TAGS", "comma-separated") { |v| options[:tags] = v }
        opts.on("--status STATUS", "default: complete") { |v| options[:status] = v }
        opts.on("--repository NAME", "default: artifacts.repository, else the git remote's repo name") { |v| options[:repository] = v }
        opts.on("--researcher NAME", "default: Claude") { |v| options[:researcher] = v }
        opts.on("--date DATE", "ISO date/time; defaults to date +%Y-%m-%dT%H:%M:%S%z") { |v| options[:date] = v }
        opts.on("--git-commit SHA", "defaults to git rev-parse HEAD") { |v| options[:git_commit] = v }
        opts.on("--branch NAME", "defaults to git branch --show-current") { |v| options[:branch] = v }
      end
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "doc_meta_frontmatter")

      manifest = Manifest.require!(env)
      return env.emit(io) unless manifest

      if options[:topic].to_s.strip.empty?
        env.block!(code: "missing_topic", message: "--topic is required")
        return env.emit(io)
      end

      date = options[:date]
      git_commit = options[:git_commit]
      branch = options[:branch]

      if date.nil? || git_commit.nil? || branch.nil?
        date_res = Sh.run(["date", "+%Y-%m-%dT%H:%M:%S%z"], envelope: env)
        commit_res = Sh.run(%w[git rev-parse HEAD], envelope: env)
        branch_res = Sh.run(%w[git branch --show-current], envelope: env)
        date ||= date_res.success? ? date_res.out.to_s.strip : nil
        git_commit ||= commit_res.success? ? commit_res.out.to_s.strip : nil
        branch ||= branch_res.success? ? branch_res.out.to_s.strip : nil
      end

      researcher = options[:researcher] || "Claude"
      fields = {
        "date" => date,
        "researcher" => researcher,
        "git_commit" => git_commit,
        "branch" => branch,
        "repository" => options[:repository] || manifest.repository_override || repository_from_remote(env),
        "beads_issue" => options[:beads_issue],
        "topic" => options[:topic],
        "tags" => (options[:tags] || "").split(",").map(&:strip).reject(&:empty?),
        "status" => options[:status] || "complete",
        "last_updated" => date.to_s[0, 10],
        "last_updated_by" => researcher
      }

      env.data[:frontmatter] = DocMeta.render_frontmatter(fields)
      env.data[:fields] = fields
      env.emit(io)
    end

    # --- follow-up --------------------------------------------------------

    def run_follow_up(argv, io)
      options = { dry_run: false }
      parser, options = Cli.build("doc_meta.rb follow-up <path> --note TEXT [--date DATE]", options) do |opts|
        opts.on("--note TEXT") { |v| options[:note] = v }
        opts.on("--date DATE", "ISO date/time; defaults to date +%Y-%m-%dT%H:%M:%S%z") { |v| options[:date] = v }
      end
      args = Cli.parse!(parser, argv)
      path = args.first
      usage_error!("doc_meta.rb follow-up <path> --note TEXT", parser) if path.to_s.strip.empty?

      env = Envelope.new(script: "doc_meta_follow_up")

      unless File.exist?(path)
        env.block!(code: "file_not_found", message: "no such file: #{path}")
        return env.emit(io)
      end
      if options[:note].to_s.strip.empty?
        env.block!(code: "missing_note", message: "--note is required")
        return env.emit(io)
      end

      date = options[:date]
      unless date
        date_res = Sh.run(["date", "+%Y-%m-%dT%H:%M:%S%z"], envelope: env)
        unless date_res.success?
          env.block!(code: "date_failed", message: err_or(date_res, "date failed"))
          return env.emit(io)
        end
        date = date_res.out.to_s.strip
      end

      original = File.read(path)
      begin
        updated = DocMeta.apply_follow_up(original, date_iso: date, note: options[:note])
      rescue ArgumentError => e
        env.block!(code: "no_frontmatter", message: e.message)
        return env.emit(io)
      end

      env.data[:path] = path
      env.data[:last_updated] = date[0, 10]
      env.data[:note] = options[:note]
      env.commands << "write #{path} (bump last_updated, add last_updated_note, append Follow-up Research heading)"

      File.write(path, updated) unless options[:dry_run]

      env.emit(io)
    end

    # --- shared -------------------------------------------------------

    # The repository name for research frontmatter, when the manifest does
    # not override it: the last path segment of origin's URL, minus any
    # ".git". Derived rather than configured so a fresh consumer repo needs
    # no manifest entry to get this right, and never a hardcoded project
    # name - that was the machine-and-project-bound half of this script.
    # nil when there is no origin to ask; the field is optional and an
    # absent one is better than a wrong one.
    def repository_from_remote(env)
      res = Sh.run(%w[git remote get-url origin], envelope: env)
      return nil unless res.success?

      url = res.out.to_s.strip
      return nil if url.empty?

      name = File.basename(url).sub(/\.git\z/, "")
      name.empty? ? nil : name
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

exit DocMetaCli.run(ARGV) if __FILE__ == $PROGRAM_NAME

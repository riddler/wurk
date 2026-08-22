# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require_relative "../../lib/user_config"

# The UserConfig test-support convention, mirroring ManifestHelper. A machine
# config has no fixture directory the way the manifest does - every test
# builds its hash inline, since the whole schema is one small section.
#
#   include UserConfigHelper
#
#   def test_something
#     with_user_config("tmux" => { "permission_mode" => "acceptEdits" }) do
#       assert_equal "acceptEdits", UserConfig.current.tmux_permission_mode
#     end
#   end
module UserConfigHelper
  module_function

  # Installs a UserConfig built from `hash_or_nil` as UserConfig.current for
  # the block, restoring whatever was there afterward. nil builds the
  # absent-file instance (valid, every value defaulted), matching what
  # UserConfig.load returns when the file is not on disk.
  def with_user_config(hash_or_nil)
    previous = UserConfig.instance_variable_get(:@current)
    path = File.join("(fixture)", UserConfig::FILENAME)
    config =
      if hash_or_nil.nil?
        UserConfig.new(path: path, raw: {}, exists: false)
      else
        UserConfig.new(path: path, raw: hash_or_nil, exists: true)
      end
    UserConfig.current = config
    yield config
  ensure
    UserConfig.current = previous
  end

  # A scratch HOME: a tmpdir with `.claude/wurk.local.json` written from
  # `hash_or_nil` (or deliberately not written, for nil), ENV["HOME"] pointed
  # at it for the block and restored afterward. This is what exercises real
  # resolution rather than the injected seam `with_user_config` provides.
  def in_tmp_home(hash_or_nil)
    UserConfig.reset!
    previous_home = ENV["HOME"]
    Dir.mktmpdir do |dir|
      unless hash_or_nil.nil?
        FileUtils.mkdir_p(File.join(dir, ".claude"))
        File.write(File.join(dir, ".claude", "wurk.local.json"), JSON.generate(hash_or_nil))
      end
      ENV["HOME"] = dir
      yield dir
    end
  ensure
    ENV["HOME"] = previous_home
    UserConfig.reset!
  end

  # For the unparseable-JSON case: writes `string` verbatim to
  # .claude/wurk.local.json under `dir`, bypassing JSON.generate entirely.
  def write_raw_user_config(dir, string)
    FileUtils.mkdir_p(File.join(dir, ".claude"))
    File.write(File.join(dir, ".claude", "wurk.local.json"), string)
  end
end

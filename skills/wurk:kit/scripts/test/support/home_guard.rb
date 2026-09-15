# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "minitest"

# HomeGuard: the suite never reads the operator's real machine config.
#
# lib/user_config.rb resolves ~/.claude/wurk.local.json from ENV["HOME"] and
# memoizes the result process-wide (UserConfig.current). Several scripts the
# suite drives through their CLIs (lock.rb, gate_run.rb, tmux_window.rb,
# bead.rb, outbound_scan.rb) call UserConfig.require! on the way in, so any
# test that reaches one of them without installing a fixture first loads
# whatever is in the real HOME - and, being memoized, hands it to every later
# test in the same process that forgot to reset!. That was wu-yi7.11: an
# order-dependent flake whose failure message printed the operator's real
# config, control term and all, into the terminal.
#
# The guard is blunt on purpose: at require time it points ENV["HOME"] at a
# fresh empty tmpdir and drops the memo, so for the rest of the process the
# "real" home is a directory with no .claude/wurk.local.json in it. A test
# that wants a config still installs one (UserConfigHelper#with_user_config
# or #in_tmp_home); a test that forgets gets the absent-file defaults, never
# the operator's file. Every support helper requires this file, and
# home_guard_test.rb checks that every test file loads one of them, so the
# guard holds whether the suite runs through run.rb or a single file is run
# by hand.
module HomeGuard
  class << self
    attr_reader :dir, :original_home

    def install!
      return dir if installed?

      @original_home = ENV["HOME"]
      @dir = Dir.mktmpdir("wurk-test-home-")
      ENV["HOME"] = @dir
      UserConfig.reset! if defined?(UserConfig)
      Minitest.after_run { FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir) }
      @dir
    end

    def installed?
      !@dir.nil?
    end
  end
end

HomeGuard.install!

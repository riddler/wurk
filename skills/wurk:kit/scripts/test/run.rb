#!/usr/bin/env ruby
# frozen_string_literal: true

# The whole test harness for .claude/scripts/. Stdlib only - minitest ships
# with Ruby 2.6, no gem install required. Run:
#
#   ruby .claude/scripts/test/run.rb
#   ruby .claude/scripts/test/run.rb -n /pattern/
#
# `mix quality` DOES run this suite, as the `Script tests` stage (registered
# in .quality.exs, ledger entry st-hzf per statifier-ex ADR-0011). Running it directly is
# still the fast inner loop - it takes about half a second, where the gate
# takes minutes - but it is no longer the only thing standing between a red
# suite and a push.

require "minitest/autorun"

here = File.expand_path(__dir__)
Dir.glob(File.join(here, "**", "*_test.rb")).sort.each { |f| require f }

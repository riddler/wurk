# frozen_string_literal: true

require "net/http"
require_relative "home_guard"

# FakeHTTP: a stand-in for Net::HTTP that mimics `Net::HTTP.start` and
# replays scripted steps, returning real Net::HTTPResponse objects. Loading
# this file also installs a process-wide network lock (see NetworkLock) so
# no test can open a real HTTP connection.
class FakeHTTP
  class Unscripted < StandardError; end
  class RealNetworkForbidden < StandardError; end

  # Prepended onto Net::HTTP.singleton_class: a real Net::HTTP.start raises.
  module NetworkLock
    def start(*)
      raise FakeHTTP::RealNetworkForbidden, "real Net::HTTP.start is forbidden in tests"
    end
  end

  Net::HTTP.singleton_class.prepend(NetworkLock) unless Net::HTTP.singleton_class.ancestors.include?(NetworkLock)

  Call = Struct.new(:host, :port, :opts, :request)

  attr_reader :calls

  def initialize
    @steps = []
    @calls = []
  end

  def respond(code, body: "", headers: {})
    @steps << [:respond, code, body, headers]
    self
  end

  def raise_error(exc)
    @steps << [:raise, exc]
    self
  end

  def hang(seconds)
    @steps << [:hang, seconds]
    self
  end

  def start(host, port, **opts)
    call = Call.new(host, port, opts, nil)
    @calls << call
    step = @steps.shift
    raise Unscripted, "no scripted step for start ##{@calls.size}" if step.nil?

    yield Connection.new(call, step)
  end

  class Connection
    def initialize(call, step)
      @call = call
      @step = step
    end

    def request(req)
      @call.request = req
      kind, *args = @step
      case kind
      when :raise then raise args[0]
      when :hang then sleep(args[0]) && nil
      else build_response(*args)
      end
    end

    private

    def build_response(code, body, headers)
      klass = Net::HTTPResponse::CODE_TO_OBJ[code.to_s] ||
              (code >= 500 ? Net::HTTPServerError : Net::HTTPResponse)
      res = klass.new("1.1", code.to_s, "fake")
      res.instance_variable_set(:@body, body)
      res.instance_variable_set(:@read, true)
      headers.each { |k, v| res[k] = v }
      res
    end
  end
end

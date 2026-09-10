# frozen_string_literal: true

unless Regexp.method_defined?(:timeout)
  require "timeout"

  class Regexp
    TimeoutError = Class.new(StandardError)
    TIMEOUTS = ObjectSpace::WeakMap.new

    def timeout = TIMEOUTS[self]
  end

  Regexp.singleton_class.prepend(Module.new do
    def new(*arguments, timeout: nil)
      expression = super(*arguments)
      Regexp::TIMEOUTS[expression] = timeout
      expression
    end
  end)

  module Canopus
    def self.with_regexp_timeout(expression)
      expression.timeout ? Timeout.timeout(expression.timeout, Regexp::TimeoutError) { yield } : yield
    end
  end
else
  module Canopus
    def self.with_regexp_timeout(_expression) = yield
  end
end

# frozen_string_literal: true

require "timeout"

unless Regexp.method_defined?(:timeout)
  class Regexp
    TimeoutError = Class.new(RegexpError)
    TIMEOUTS = ObjectSpace::WeakMap.new

    def timeout = TIMEOUTS[self]
  end

  Regexp.singleton_class.prepend(Module.new do
    def new(*arguments, timeout: nil)
      expression = super(*arguments)
      Regexp::TIMEOUTS[expression] = normalize_timeout(timeout)
      expression
    end

    def compile(*arguments, timeout: nil)
      expression = super(*arguments)
      Regexp::TIMEOUTS[expression] = normalize_timeout(timeout)
      expression
    end

    private

    def normalize_timeout(timeout)
      return if timeout.nil?
      raise TypeError, "no implicit conversion to float from string" if timeout.is_a?(String)

      seconds = Float(timeout)
      return if seconds.nan?
      raise ArgumentError, "invalid timeout: #{timeout.inspect}" unless seconds.positive?
      return if seconds < 0.000000001
      return 18_446_744_073.709553 if seconds.infinite?

      (seconds * 1_000_000_000).floor.fdiv(1_000_000_000)
    end
  end)

  Regexp.prepend(Module.new do
    def initialize_copy(other)
      super
      Regexp::TIMEOUTS[self] = other.timeout
    end
  end)

  module Canopus
    REGEXP_TIMEOUT_COMPAT = true

    def self.with_regexp_timeout(expression)
      expression.timeout ? Timeout.timeout(expression.timeout, Regexp::TimeoutError) { yield } : yield
    end
  end
else
  module Canopus
    REGEXP_TIMEOUT_COMPAT = false

    def self.with_regexp_timeout(_expression) = yield
  end
end

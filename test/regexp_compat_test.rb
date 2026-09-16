# frozen_string_literal: true

require_relative "test_helper"

class RegexpCompatTest < Minitest::Test
  def test_constructor_validates_and_normalizes_timeout
    skip "native Regexp owns timeout validation" unless Canopus::REGEXP_TIMEOUT_COMPAT

    assert_raises(ArgumentError) { Regexp.new("a", timeout: 0) }
    assert_raises(ArgumentError) { Regexp.new("a", timeout: -1) }
    assert_raises(TypeError) { Regexp.new("a", timeout: "0.1") }
    assert_equal 1.0, Regexp.new("a", timeout: 1).timeout
  end

  def test_compile_dup_and_clone_preserve_timeout
    skip "native Regexp owns copy behavior" unless Canopus::REGEXP_TIMEOUT_COMPAT

    expression = Regexp.compile("a", timeout: 0.002)
    assert_equal 0.002, expression.timeout
    assert_equal 0.002, expression.dup.timeout
    assert_equal 0.002, expression.clone.timeout
    assert_nil Regexp.new(expression).timeout
  end

  def test_wrapper_uses_the_requested_timeout_without_a_floor
    skip "native Regexp enforces its own timeout" unless Canopus::REGEXP_TIMEOUT_COMPAT
    observed = nil
    timeout = lambda do |seconds, _error, &operation|
      observed = seconds
      operation.call
    end

    Timeout.stub(:timeout, timeout) do
      Canopus.with_regexp_timeout(Regexp.new("a", timeout: 0.002)) { true }
    end
    assert_equal 0.002, observed
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TaskProblemMatcherTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-problem-matcher-")
    FileUtils.mkdir_p(File.join(@root, "lib"))
    File.write(File.join(@root, "lib", "example.rb"), "puts :ok\n")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_single_line_matches_incremental_ansi_and_utf8_output
    matcher = build(pattern: {"regexp" => "^(.+):(\\d+):(\\d+): (warning|error): (.+)$",
      "file" => 1, "line" => 2, "column" => 3, "severity" => 4, "message" => 5})

    refute matcher.feed("\e[31mlib/example.rb:1:")
    assert matcher.feed("2: warning: 日本語\e[0m\n")

    uri, diagnostics = matcher.diagnostics.first
    assert_equal Sadr::Protocol.uri(File.realpath(File.join(@root, "lib", "example.rb"))), uri
    assert_equal 2, diagnostics.first["severity"]
    assert_equal "日本語", diagnostics.first["message"]
    assert_equal({"line" => 0, "character" => 1}, diagnostics.first.dig("range", "start"))
  end

  def test_multiple_line_pattern_restarts_after_a_mismatch
    matcher = build(pattern: [
      {"regexp" => "^(.+):(\\d+)$", "file" => 1, "line" => 2},
      {"regexp" => "^ERROR: (.+)$", "message" => 1}
    ])

    refute matcher.feed("lib/example.rb:1\nnot an error\n")
    assert matcher.feed("lib/example.rb:1\nERROR: broken\n")
    assert_equal ["broken"], matcher.diagnostics.values.flatten.map { |item| item["message"] }
  end

  def test_watch_clears_each_cycle_and_active_on_start_has_standard_meaning
    matcher = build(pattern: basic_pattern,
      background: {"begins_pattern" => "^BEGIN$", "ends_pattern" => "^END$", "active_on_start" => false})
    refute matcher.feed("lib/example.rb:1: ignored\n")
    assert matcher.diagnostics.empty?
    refute matcher.feed("BEGIN\n")
    assert matcher.feed("lib/example.rb:1: first\n")
    assert_equal ["first"], messages(matcher)
    refute matcher.feed("END\nlib/example.rb:1: ignored again\n")
    assert_equal ["first"], messages(matcher)
    assert matcher.feed("BEGIN\n")
    assert_empty matcher.diagnostics

    active = build(pattern: basic_pattern,
      background: {"begins_pattern" => "^BEGIN$", "ends_pattern" => "^END$", "active_on_start" => true})
    assert active.feed("lib/example.rb:1: ready\n")
    assert_equal ["ready"], messages(active)
  end

  def test_ignores_missing_and_outside_files_and_bounds_unterminated_input
    matcher = build(pattern: basic_pattern)
    refute matcher.feed("missing.rb:1: missing\n")
    refute matcher.feed("../outside.rb:1: outside\n")
    refute matcher.feed("x" * (Canopus::Task::ProblemMatcher::MAX_PENDING_BYTES + 100))
    assert_operator matcher.instance_variable_get(:@pending).bytesize,
      :<=, Canopus::Task::ProblemMatcher::MAX_PENDING_BYTES
  end

  def test_rejects_an_existing_symlink_that_resolves_outside_the_workspace
    skip "symlink creation is not generally available on Windows" if Gem.win_platform?
    outside = Dir.mktmpdir("canopus-problem-outside-")
    File.write(File.join(outside, "outside.rb"), "puts :outside\n")
    File.symlink(File.join(outside, "outside.rb"), File.join(@root, "linked.rb"))

    matcher = build(pattern: basic_pattern)
    refute matcher.feed("linked.rb:1: escaped\n")
    assert_empty matcher.diagnostics
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  def test_parser_respects_its_budget_and_continues_complete_lines_without_new_data
    matcher = build(pattern: basic_pattern)
    input = "not a diagnostic\n" * 20_000
    refute matcher.feed(input, max_seconds: 0)
    assert matcher.pending?

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    matcher.feed("", max_seconds: 0.0001)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 0.1
    assert matcher.pending?

    100.times do
      break unless matcher.pending?
      matcher.feed("", max_seconds: 0.01)
    end
    refute matcher.pending?
    assert_empty matcher.diagnostics
  end

  def test_timeout_disables_watch_matcher_without_trying_later_patterns
    evil = "^((a+)+):(\\d+): (.+)$"
    matcher = build(pattern: {"regexp" => evil, "file" => 1, "line" => 3, "message" => 4},
      background: {"begins_pattern" => "^BEGIN$", "ends_pattern" => "^END$", "active_on_start" => true})
    calls = 0
    original = matcher.method(:safe_match)
    matcher.define_singleton_method(:safe_match) do |pattern, line|
      calls += 1
      original.call(pattern, line)
    end
    timeout = lambda do |pattern, &match|
      raise Regexp::TimeoutError if pattern.source == evil
      match.call
    end

    Canopus.stub(:with_regexp_timeout, timeout) do
      line = "aaaa!:1: broken\n"
      refute matcher.feed(line * 4, max_seconds: 1)
      if Canopus::REGEXP_TIMEOUT_COMPAT
        assert_equal 3, calls
        assert matcher.pending?
        refute matcher.feed("", max_seconds: 1)
      end
      expected_calls = Canopus::REGEXP_TIMEOUT_COMPAT ? 6 : 3
      assert_equal expected_calls, calls
      assert matcher.instance_variable_get(:@disabled)
      refute matcher.pending?

      10.times { refute matcher.feed(line, max_seconds: 1) }
      assert_equal expected_calls, calls
    end
  end

  def test_compatibility_timeout_retries_the_pending_line_on_the_next_feed
    skip "only the compatibility implementation retries" unless Canopus::REGEXP_TIMEOUT_COMPAT
    matcher = build(pattern: basic_pattern)
    calls = 0
    timeout = lambda do |_pattern, &match|
      calls += 1
      raise Regexp::TimeoutError if calls == 1
      match.call
    end

    Canopus.stub(:with_regexp_timeout, timeout) do
      refute matcher.feed("lib/example.rb:1: recovered\n", max_seconds: 1)
      assert matcher.pending?
      assert matcher.feed("", max_seconds: 1)
    end
    assert_equal ["recovered"], messages(matcher)
    assert_equal 2, calls
  end

  def test_compatibility_timeout_does_not_retry_unterminated_input_inside_finish
    skip "only the compatibility implementation retries" unless Canopus::REGEXP_TIMEOUT_COMPAT
    matcher = build(pattern: basic_pattern)
    calls = 0
    timeout = lambda do |_pattern|
      calls += 1
      raise Regexp::TimeoutError
    end
    refute matcher.feed("lib/example.rb:1: malicious", max_seconds: 1)

    Canopus.stub(:with_regexp_timeout, timeout) { matcher.finish }
    assert_equal 1, calls
    assert matcher.instance_variable_get(:@disabled)
  end

  def test_feed_coalesces_callbacks_drops_after_limit_and_watch_clear_reopens_capacity
    callbacks = 0
    matcher = build(pattern: basic_pattern,
      background: {"begins_pattern" => "^BEGIN$", "ends_pattern" => "^END$", "active_on_start" => true}) do
      callbacks += 1
    end
    input = (1..1_001).map { |line| "lib/example.rb:#{line}: issue #{line}\n" }.join

    assert matcher.feed(input, max_seconds: 1)
    assert_equal Canopus::Task::ProblemMatcher::MAX_DIAGNOSTICS,
      matcher.diagnostics.values.sum(&:length)
    assert_equal 1, callbacks

    assert matcher.feed("BEGIN\nlib/example.rb:1: fresh\n", max_seconds: 1)
    assert_equal ["fresh"], messages(matcher)
    assert_equal 2, callbacks
  end

  def test_first_pattern_failure_tests_the_line_only_once
    matcher = build(pattern: [basic_pattern, {"regexp" => "^detail: (.+)$", "message" => 1}])
    calls = 0
    original = matcher.method(:safe_match)
    matcher.define_singleton_method(:safe_match) do |pattern, line|
      calls += 1
      original.call(pattern, line)
    end

    refute matcher.feed("not a diagnostic\n", max_seconds: 1)
    assert_equal 1, calls
  end

  private

  def basic_pattern
    {"regexp" => "^(.+):(\\d+): (.+)$", "file" => 1, "line" => 2, "message" => 3}
  end

  def build(pattern:, background: nil, &on_change)
    definition = {"owner" => "ruby", "file_location" => ["relative", @root], "pattern" => pattern}
    definition["background"] = background if background
    Canopus::Task::ProblemMatcher.new(definition, root: @root, &on_change)
  end

  def messages(matcher) = matcher.diagnostics.values.flatten.map { |item| item["message"] }
end

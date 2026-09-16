# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"
require "tmpdir"

class TaskRunnerTest < Minitest::Test
  class Terminal
    Status = Struct.new(:success?)
    attr_reader :options, :signals, :grid, :vt, :reads, :resizes, :pending_calls, :close_calls
    attr_accessor :alive, :signal_error, :alive_error_after

    def initialize(**options)
      @options = options
      @alive = true
      @signals, @reads, @resizes = [], [], []
      @pending_calls = @alive_calls = 0
      @close_calls = 0
      @output = +options.delete(:output).to_s
      @grid = Tarazed::Grid.new(columns: options[:columns], rows: options[:rows], scrollback: options[:scrollback])
      @vt = Tarazed::VT.new(@grid)
    end

    def read(max_bytes:, max_seconds:)
      raise IOError, "read after close" if closed?
      @reads << [max_bytes, max_seconds]
      return nil if !@alive && @output.empty?
      value = @output.slice!(0, max_bytes).to_s
      @vt.feed(value)
      value
    end
    def pending?
      raise IOError, "pending after close" if closed?
      @pending_calls += 1
      !@output.empty?
    end
    def alive?
      @alive_calls += 1
      raise IOError, "alive failed" if @alive_error_after && @alive_calls >= @alive_error_after
      @alive
    end
    def status = @alive ? nil : Status.new(true)
    def signal(name)
      raise @signal_error if @signal_error
      @signals << name
      @alive = false
      true
    end
    def close = (@close_calls += 1; @closed = true; @alive = false; self)
    def closed? = !!@closed
    def resize(columns:, rows:)
      raise IOError, "resize after close" if closed?
      @resizes << [columns, rows]
      @grid.resize(columns: columns, rows: rows)
    end
  end

  def setup
    @created = []
    @runner = Canopus::Task::Runner.new(scrollback: 50, queue_limit_bytes: 65_536,
      terminal_factory: ->(**options) { Terminal.new(**options).tap { |terminal| @created << terminal } })
  end

  def teardown
    @runner.close
  end

  def test_same_label_replaces_by_identity_and_stale_entries_cannot_stop_the_replacement
    old = @runner.run(task("test"))
    replacement = @runner.run(task("test"))
    wait_for_close(old.terminal)

    assert_equal [replacement], @runner.entries
    refute_equal old.id, replacement.id
    refute @runner.stop(old)
    assert replacement.terminal.alive?
    assert old.terminal.closed?
  end

  def test_multiple_tasks_stop_only_the_active_output_and_completed_tasks_can_rerun
    first = @runner.run(task("first"))
    second = @runner.run(task("second"))
    @runner.activate(0)
    assert @runner.stop
    wait_for_close(first.terminal)

    assert_equal ["INT"], first.terminal.signals
    assert_empty second.terminal.signals
    assert second.terminal.alive?
    rerun = @runner.run(task("first"))
    assert_equal [rerun, second], @runner.entries
    refute_equal first.id, rerun.id
  end

  def test_stopped_output_is_retained_without_polling_or_resizing_its_closed_terminal
    output = @runner.run(task("stopped"))
    assert @runner.stop(output)
    wait_for_close(output.terminal)

    refute @runner.drain(max_bytes: 100, max_seconds: 1)
    refute @runner.pending?
    @runner.resize(80, 24)
    assert_equal [output], @runner.entries
    assert_empty output.terminal.reads
    assert_equal 0, output.terminal.pending_calls
    assert_empty output.terminal.resizes
  end

  def test_mutating_public_output_data_does_not_change_close_state_identity
    output = @runner.run(task("mutable"))
    assert @runner.stop(output)
    wait_for_close(output.terminal)
    output.presentation["reveal"] = "never"

    refute @runner.drain(max_bytes: 100, max_seconds: 1)
    refute @runner.pending?
    @runner.resize(80, 24)
    assert_same output, @runner.remove(0)
    assert_equal 1, output.terminal.close_calls
  end

  def test_remove_keeps_the_output_when_a_close_thread_cannot_start
    output = @runner.run(task("kept"))
    Thread.stub(:new, ->(*) { raise ThreadError, "cannot start" }) do
      assert_raises(ThreadError) { @runner.remove(0) }
    end

    assert_equal [output], @runner.entries
    refute output.terminal.closed?

    busy = Object.new
    busy.define_singleton_method(:join) { |_timeout = nil| nil }
    closers = Array.new(Canopus::Task::Runner::MAX_CLOSERS) { [Object.new, busy] }.to_h
    @runner.instance_variable_set(:@close_threads, closers)
    assert_raises(Canopus::Error) { @runner.remove(0) }
    assert_equal [output], @runner.entries
  ensure
    @runner.instance_variable_set(:@close_threads, {}.compare_by_identity)
  end

  def test_close_falls_back_to_synchronous_close_and_joins_started_workers
    3.times { |index| @runner.run(task("close-#{index}")) }
    original = Thread.method(:new)
    calls = 0
    replacement = lambda do |*args, &block|
      calls += 1
      raise ThreadError, "cannot start second closer" if calls == 2
      original.call(*args, &block)
    end

    Thread.stub(:new, replacement) do
      assert_raises(ThreadError) { @runner.close }
    end
    assert @created.all?(&:closed?)
    assert_empty @runner.entries
  end

  def test_close_joins_existing_full_closer_batch_before_closing_retained_outputs
    Canopus::Task::Runner::MAX_OUTPUTS.times { |index| @runner.run(task("close-#{index}")) }
    busy = Object.new
    finished = false
    busy.define_singleton_method(:join) do |timeout = :wait|
      if timeout == :wait
        finished = true
        self
      else
        finished ? self : nil
      end
    end
    closers = Array.new(Canopus::Task::Runner::MAX_CLOSERS) { [Object.new, busy] }.to_h.compare_by_identity
    @runner.instance_variable_set(:@close_threads, closers)

    assert_nil @runner.close
    assert @created.all?(&:closed?)
    assert @created.all? { |terminal| terminal.close_calls == 1 }
    assert_empty @runner.instance_variable_get(:@close_threads)
    assert_empty @runner.instance_variable_get(:@closed_outputs)
    assert_empty @runner.instance_variable_get(:@completed)
    assert_empty @runner.instance_variable_get(:@eof_outputs)
    assert_empty @runner.instance_variable_get(:@blocked_outputs)
  end

  def test_stop_closes_the_terminal_when_signal_or_alive_checks_fail
    [:signal, :alive].each do |failure|
      runner = Canopus::Task::Runner.new(scrollback: 50, queue_limit_bytes: 65_536,
        terminal_factory: ->(**options) { Terminal.new(**options) })
      output = runner.run(task(failure.to_s))
      if failure == :signal
        output.terminal.signal_error = IOError.new("signal failed")
      else
        output.terminal.alive_error_after = 2
      end

      assert runner.stop(output)
      wait_for_close(output.terminal)
      assert output.terminal.closed?
      assert_raises(IOError) { runner.close }
    end
  end

  def test_real_tarazed_buffered_stop_is_no_longer_polled_or_resized
    runner = Canopus::Task::Runner.new(scrollback: 50, queue_limit_bytes: 65_536)
    command = [RbConfig.ruby, "-e", '$stdout.sync = true; STDOUT.write("x" * 100_000); sleep 5']
    output = runner.run(task("real").merge("command" => command))
    wait_until { output.terminal.pending? }
    assert runner.stop(output)
    wait_until { runner.instance_variable_get(:@close_threads).values.all? { |thread| !thread.alive? } }

    refute runner.pending?
    refute runner.drain(max_bytes: 65_536, max_seconds: 1)
    runner.resize(80, 24)
  ensure
    runner&.close
  end

  def test_completion_identity_bookkeeping_is_bounded_by_retained_outputs
    output = @runner.run(task("same"))
    40.times do
      output.terminal.alive = false
      @runner.drain(max_bytes: 65_536, max_seconds: 1)
      assert_equal [output], @runner.completed
      assert_empty @runner.completed
      output = @runner.run(task("same"))
      wait_for_close(@created[-2])
    end

    assert_operator @runner.instance_variable_get(:@completed).length,
      :<=, Canopus::Task::Runner::MAX_OUTPUTS
  end

  def test_dead_process_is_completed_only_after_all_output_and_eof_are_read
    payload = +("x" * 200_000)
    output = @runner.run(task("buffered"))
    output.terminal.instance_variable_set(:@output, payload.dup)
    output.terminal.alive = false
    captured = +""
    completed = nil

    100.times do
      @runner.drain(max_bytes: 12_000, max_seconds: 1) do |_entry, data, _seconds|
        captured << data if data
      end
      completed = @runner.completed.first
      break if completed
    end

    assert_same output, completed
    assert_equal payload, captured
    assert_operator output.terminal.reads.length, :>, 2
    assert_empty @runner.completed
  end

  def test_eof_output_remains_pending_until_its_process_exits
    output = @runner.run(task("eof-before-exit"))
    output.terminal.define_singleton_method(:read) { |max_bytes:, max_seconds:| nil }

    refute @runner.drain(max_bytes: 65_536, max_seconds: 1)
    assert_empty @runner.completed
    assert @runner.pending?

    output.terminal.alive = false
    assert_equal [output], @runner.completed
    assert_empty @runner.completed
  end

  def test_stopped_output_finishes_blocked_consumer_work_before_completion
    output = @runner.run(task("blocked-stop"))
    output.terminal.instance_variable_set(:@output, +"already read\n")
    calls = 0

    assert @runner.drain(max_bytes: 65_536, max_seconds: 1) { false }
    assert @runner.stop(output)
    wait_for_close(output.terminal)

    completed = nil
    10.times do
      @runner.drain(max_bytes: 65_536, max_seconds: 1) do |_entry, data, _seconds|
        assert_equal "".b, data
        calls += 1
        calls >= 3
      end
      completed = @runner.completed.first
      break if completed
    end

    assert_same output, completed
    assert_equal 3, calls
    assert_empty @runner.completed
    assert_equal 1, output.terminal.reads.length
  end

  def test_drains_large_exit_output_and_unterminated_multiline_problem
    root = Dir.mktmpdir("canopus-task-eof-")
    source = File.join(root, "example.rb")
    File.write(source, "puts :ok\n")
    expected_tail = "\n#{source}:1\nERROR: final"
    payload = "x" * 200_000 + expected_tail
    runner = Canopus::Task::Runner.new(scrollback: 50, queue_limit_bytes: 1 << 20,
      terminal_factory: ->(**options) { Terminal.new(**options, output: payload) })
    output = runner.run(task("eof").merge("cwd" => root))
    output.terminal.alive = false
    matcher = Canopus::Task::ProblemMatcher.new({"owner" => "ruby",
      "file_location" => ["relative", File.realpath(root)], "pattern" => [
        {"regexp" => "^(.+):(\\d+)$", "file" => 1, "line" => 2},
        {"regexp" => "^ERROR: (.+)$", "message" => 1}
      ]}, root: root)
    captured = +"".b
    completed = nil
    100.times do
      runner.drain(max_bytes: 12_000, max_seconds: 0.004) do |_entry, data, seconds|
        captured << data if data
        matcher.feed(data.to_s, max_seconds: seconds)
        !matcher.pending?
      end
      completed = runner.completed.first
      break if completed
    end
    matcher.finish

    assert_same output, completed
    assert_operator output.terminal.reads.length, :>, 2
    assert_equal 200_000, captured.scan(/x+/).map(&:length).max
    assert captured.end_with?("ERROR: final")
    assert_equal ["final"], matcher.diagnostics.values.flatten.map { |item| item["message"] }
  ensure
    runner&.close
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  def test_output_count_scrollback_queue_and_frame_reads_are_bounded
    Canopus::Task::Runner::MAX_OUTPUTS.times { |index| @runner.run(task("task-#{index}")) }
    assert_equal Canopus::Task::Runner::MAX_OUTPUTS, @runner.entries.length
    assert_equal 50, @created.last.options[:scrollback]
    assert_equal 65_536, @created.last.options[:queue_limit_bytes]
    assert_raises(Canopus::Error) { @runner.run(task("overflow")) }

    victim = @runner.entries.first
    victim.terminal.alive = false
    refute @runner.drain(max_bytes: 65_536, max_seconds: 1)
    replacement = @runner.run(task("replacement"))
    assert_includes @runner.entries, replacement
    assert_equal Canopus::Task::Runner::MAX_OUTPUTS, @runner.entries.length
  end

  def test_full_runner_preserves_dead_output_until_tail_and_blocked_work_reach_eof
    Canopus::Task::Runner::MAX_OUTPUTS.times { |index| @runner.run(task("task-#{index}")) }
    victim = @runner.entries.first
    victim.terminal.instance_variable_set(:@output, +"unread tail")
    victim.terminal.alive = false

    assert_raises(Canopus::Error) { @runner.run(task("before-tail")) }
    assert_same victim, @runner.entries.first

    captured = +""
    changed = @runner.drain(max_bytes: 65_536, max_seconds: 1) do |output, data, _seconds|
      if output.equal?(victim)
        captured << data.to_s
        false
      else
        true
      end
    end
    assert changed
    assert_equal "unread tail", captured
    assert_raises(Canopus::Error) { @runner.run(task("while-blocked")) }
    assert_same victim, @runner.entries.first

    calls = 0
    changed = @runner.drain(max_bytes: 65_536, max_seconds: 1) do |output, _data, _seconds|
      calls += 1 if output.equal?(victim)
      true
    end
    refute changed
    assert_equal 2, calls
    assert_equal [victim], @runner.completed

    replacement = @runner.run(task("after-eof"))
    assert_same replacement, @runner.entries.first
    refute_includes @runner.entries, victim
  end

  def test_drain_shares_one_byte_budget_and_resize_skips_unchanged_dimensions
    first = @runner.run(task("first"))
    second = @runner.run(task("second"))
    first.terminal.instance_variable_set(:@output, "a" * 100)
    second.terminal.instance_variable_set(:@output, "b" * 100)
    assert @runner.drain(max_bytes: 150, max_seconds: 1)
    assert_equal 150, first.terminal.reads.first.first
    assert_equal 50, second.terminal.reads.first.first

    @runner.resize(80, 24)
    @runner.resize(80, 24)
    assert_equal [[80, 24]], first.terminal.resizes
    assert_equal [[80, 24]], second.terminal.resizes
  end

  def test_drain_rejects_nonfinite_time_budgets
    [Float::NAN, Float::INFINITY, -1].each do |seconds|
      assert_raises(ArgumentError) { @runner.drain(max_bytes: 100, max_seconds: seconds) }
    end
  end

  def test_drain_yields_each_output_chunk
    first = @runner.run(task("first"))
    second = @runner.run(task("second"))
    first.terminal.instance_variable_set(:@output, +"first\n")
    second.terminal.instance_variable_set(:@output, +"second\n")
    chunks = []

    assert @runner.drain(max_bytes: 100, max_seconds: 1) { |output, data, _seconds| chunks << [output, data] }
    assert_equal [[first, "first\n"], [second, "second\n"]], chunks
  end

  private

  def task(label)
    {"label" => label, "command" => ["ruby"], "cwd" => Dir.pwd,
     "presentation" => {"panel" => "output", "reveal" => "always"}}
  end

  def wait_for_close(terminal, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until terminal.closed?
      flunk "terminal did not close" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition was not met" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end
end

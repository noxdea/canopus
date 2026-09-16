# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class DebugConsoleTest < Minitest::Test
  Frame = Data.define(:id)

  class Session
    attr_reader :requests, :scope_requests, :variable_requests

    def initialize
      @requests, @scope_requests, @variable_requests = [], [], []
      @sequence = 0
    end

    def evaluate(expression, frame_id:, context:)
      @sequence += 1
      Megrez::Future.new(@sequence).tap { |future| @requests << [expression, frame_id, context, future] }
    end

    def scopes(frame_id)
      @scope_requests << frame_id
      complete([Megrez::Scope.new(name: "Locals", variables_reference: 101,
        expensive: false, presentation_hint: nil)])
    end

    def variables(reference)
      @variable_requests << reference
      complete([Megrez::Variable.new(name: "local", value: "1", type: "Integer", variables_reference: 0,
        named_count: nil, indexed_count: nil, memory_reference: nil)])
    end

    def close = nil

    private

    def complete(value)
      @sequence += 1
      Megrez::Future.new(@sequence).fulfill(value)
    end
  end

  class DeferredHoverSession < Session
    attr_reader :scope_futures, :variable_futures

    def initialize
      super
      @scope_futures, @variable_futures = [], []
    end

    def scopes(frame_id)
      @scope_requests << frame_id
      deferred(@scope_futures)
    end

    def variables(reference)
      @variable_requests << reference
      deferred(@variable_futures)
    end

    private

    def deferred(collection)
      @sequence += 1
      Megrez::Future.new(@sequence).tap { |future| collection << future }
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-debug-console-")
    @path = File.join(@root, "app.rb")
    @source = <<~'RUBY'
      local = 1
      local
      @ivar
      dangerous()
      "inside"
      # comment
      object.member
      unknown
      Constant
      "single #{local}"
      "before #{
        local
      } after"
    RUBY
    File.write(@path, @source)
    @outside_root = Dir.mktmpdir("canopus-debug-console-outside-")
    @outside = File.join(@outside_root, "outside.rb")
    File.write(@outside, "outside_value\n")
    @queue = []
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root) if File.exist?(@root)
    FileUtils.remove_entry(@outside_root) if File.exist?(@outside_root)
  end

  def test_output_order_metadata_and_adapter_text_are_bounded
    console = build_console
    session = Session.new
    console.attach(session)
    console.output(session, "category" => "stdout", "output" => "one\n\ntrace\n")
    console.output(session, "category" => "stderr", "output" => "two",
      "source" => {"path" => @outside}, "line" => 12)
    console.output(session, "output" => "界" * 10_000,
      "source" => {"name" => @outside}, "line" => 2**100_000)
    assert_equal 1, @queue.length
    drain

    assert_equal "[stdout] one", console.entries[0][:label]
    assert_equal "", console.entries[1][:label]
    assert_equal "trace", console.entries[2][:label]
    assert_equal "[stderr outside.rb:12] two", console.entries[3][:label]
    assert console.entries[4][:label].valid_encoding?
    assert_operator console.entries[4][:label].bytesize, :<=, Canopus::Debug::Console::TEXT_LIMIT
    refute_includes console.entries.join, @outside_root
    assert_match(/\A\[outside\.rb\] /, console.entries[4][:label])
  end

  def test_output_flood_is_queue_bounded_and_replaces_the_tree_once
    console = build_console
    session = Session.new
    console.attach(session)
    replacements = 0
    replace = console.tree.method(:replace)
    console.tree.define_singleton_method(:replace) do |nodes|
      replacements += 1
      replace.call(nodes)
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Thread.new do
      10_000.times { |index| console.output(session, "output" => index.to_s) }
    end.join
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 2
    assert_equal 1, @queue.length
    assert_operator console.instance_variable_get(:@output_queue).length,
      :<=, Canopus::Debug::Console::OUTPUT_QUEUE_LIMIT
    drain
    assert_equal 1, replacements
    assert_equal Canopus::Debug::Console::ITEM_LIMIT, console.entries.length
    assert_equal "0", console.entries.first[:label]
    assert_equal (Canopus::Debug::Console::OUTPUT_QUEUE_LIMIT - 1).to_s, console.entries.last[:label]
  end

  def test_repl_uses_selected_frame_and_discards_cancelled_results
    console = build_console
    session = Session.new
    first, second = Frame.new(1), Frame.new(2)
    console.attach(session)
    console.stopped(session, first)

    future = console.evaluate("answer\nnext")
    assert_equal ["answer\nnext", 1, "repl"], session.requests.last.first(3)
    future.fulfill(variable("42\nnext"))
    drain
    assert_equal ["> answer next", "42 next · Integer"], console.entries.map { |entry| entry[:label] }

    failed = console.evaluate("failure")
    failed.fulfill(error: Canopus::Error.new("bad\nline"))
    drain
    assert_equal "Error: bad line", console.entries.last[:label]

    stale = console.evaluate("old")
    before = console.entries.length
    console.stopped(session, second)
    assert_raises(Megrez::Cancelled) { stale.await(timeout: 0) }
    drain
    assert_equal before, console.entries.length

    console.continued(session)
    assert_raises(Canopus::Error) { console.evaluate("not_stopped") }
  end

  def test_repl_pending_requests_are_limited
    console = build_console
    session = Session.new
    console.attach(session)
    console.stopped(session, Frame.new(1))
    Canopus::Debug::Console::PENDING_LIMIT.times { |index| console.evaluate("value#{index}") }

    assert_raises(Canopus::Error) { console.evaluate("overflow") }
    console.continued(session)
    assert session.requests.all? { |request| request.last.done? }
  end

  def test_detach_discards_queued_output_but_keeps_history_until_the_next_attach
    console = build_console
    first, second = Session.new, Session.new
    console.attach(first)
    console.output(first, "output" => "kept")
    drain
    console.output(first, "output" => "stale")

    console.detach
    drain
    assert_equal ["kept"], console.entries.map { |entry| entry[:label] }
    refute console.output(first, "output" => "late")

    console.attach(second)
    assert_empty console.entries
  end

  def test_workspace_stop_finish_failure_and_close_keep_console_history
    %i[stop finish failure close].each do |route|
      workspace = Canopus::Workspace.new(root: @root)
      session = Session.new
      console = workspace.debug_console
      generation = workspace.instance_variable_get(:@debug_generation)
      workspace.instance_variable_set(:@debug_session, session)
      console.attach(session)
      console.output(session, "output" => route.to_s)
      workspace.drain

      case route
      when :stop then workspace.stop_debugging
      when :finish then workspace.send(:finish_debug_session, session, generation)
      when :failure then workspace.send(:fail_debug_session, session, generation, Canopus::Error.new("failed"))
      when :close then workspace.close
      end

      assert_equal [route.to_s], console.entries.map { |entry| entry[:label] }, route
      refute console.output(session, "output" => "late"), route
      workspace.close unless workspace.instance_variable_get(:@closed)
    end
  end

  def test_workspace_hover_only_evaluates_real_simple_variables
    @workspace = Canopus::Workspace.new(root: @root)
    current = @workspace.open(@path)
    settle_tokens(current)
    session = Session.new
    frame = Frame.new(7)
    @workspace.instance_variable_set(:@debug_session, session)
    @workspace.debug_panel.instance_variable_set(:@session, session)
    @workspace.debug_panel.instance_variable_set(:@selected_frame, frame)

    %w[dangerous inside comment object member Constant].each do |text|
      refute @workspace.debug_hover(current, @source.index(text) + 1), text
    end
    [@source.index('#{local}') + 2, @source.index("  local\n") + 3].each do |offset|
      refute @workspace.debug_hover(current, offset)
    end
    assert_empty session.requests
    assert_empty session.scope_requests
    assert_empty session.variable_requests

    assert @workspace.debug_hover(current, @source.index("unknown") + 1)
    @workspace.drain
    assert_empty session.requests
    assert_equal [7], session.scope_requests
    assert_equal [101], session.variable_requests

    assert @workspace.debug_hover(current, @source.index("local\n") + 1)
    @workspace.drain
    expression, frame_id, context, future = session.requests.last
    assert_equal ["local", 7, "hover"], [expression, frame_id, context]
    future.fulfill(variable("界" * 10_000))
    @workspace.drain
    assert @workspace.hover_card.valid_encoding?
    assert_operator @workspace.hover_card.bytesize, :<=, Canopus::Workspace::DebugAware::DEBUG_HOVER_TEXT_LIMIT

    @workspace.dismiss_hover
    assert_nil @workspace.hover_card
    assert @workspace.debug_hover(current, @source.index("@ivar") + 1)
    expression, frame_id, context, ivar = session.requests.last
    assert_equal ["@ivar", 7, "hover"], [expression, frame_id, context]
    ivar.fulfill(variable("2"))
    @workspace.drain
    assert_match(/@ivar = 2/, @workspace.hover_card)

    @workspace.dismiss_hover
    assert @workspace.debug_hover(current, @source.index("local\n") + 1)
    @workspace.drain
    stale = session.requests.last.last
    @workspace.instance_variable_set(:@debug_generation,
      @workspace.instance_variable_get(:@debug_generation) + 1)
    stale.fulfill(variable("stale"))
    @workspace.drain
    assert_nil @workspace.hover_card

    outside = @workspace.open(@outside)
    refute @workspace.debug_hover(outside, 3)
    assert_equal 3, session.requests.length

    long_path = File.join(@root, "long.rb")
    File.write(long_path, "x" * (Canopus::Workspace::DebugAware::DEBUG_HOVER_EXPRESSION_LIMIT + 1))
    long = @workspace.open(long_path)
    settle_tokens(long)
    refute @workspace.debug_hover(long, 0)
    assert_equal 3, session.requests.length
  ensure
    @workspace&.instance_variable_set(:@debug_session, nil)
  end

  def test_hover_scope_chain_discards_changed_buffers_and_is_cancelled_on_continue
    @workspace = Canopus::Workspace.new(root: @root)
    current = @workspace.open(@path)
    settle_tokens(current)
    session = DeferredHoverSession.new
    frame = Frame.new(7)
    @workspace.instance_variable_set(:@debug_session, session)
    @workspace.debug_panel.instance_variable_set(:@session, session)
    @workspace.debug_panel.instance_variable_set(:@selected_frame, frame)

    assert @workspace.debug_hover(current, @source.index("local\n") + 1)
    scope = session.scope_futures.last
    assert_same scope, @workspace.instance_variable_get(:@debug_hover_request)
    scope.fulfill([Megrez::Scope.new(name: "Locals", variables_reference: 101,
      expensive: false, presentation_hint: nil)])
    @workspace.drain
    variable = session.variable_futures.last
    assert_same variable, @workspace.instance_variable_get(:@debug_hover_request)
    assert_equal 1, [*session.scope_futures, *session.variable_futures, *session.requests.map(&:last)].count { |future| !future.done? }

    current.buffer.edit([[current.buffer.rope.bytesize...current.buffer.rope.bytesize, " "]])
    variable.fulfill([Megrez::Variable.new(name: "local", value: "1", type: "Integer",
      variables_reference: 0, named_count: nil, indexed_count: nil, memory_reference: nil)])
    @workspace.drain
    assert_empty session.requests
    assert_nil @workspace.instance_variable_get(:@debug_hover_request)

    settle_tokens(current)
    assert @workspace.debug_hover(current, @source.index("local\n") + 1)
    pending = session.scope_futures.last
    @workspace.send(:handle_debug_continue, session, @workspace.instance_variable_get(:@debug_generation))
    assert_raises(Megrez::Cancelled) { pending.await(timeout: 0) }
    @workspace.drain
    assert_empty session.requests
  ensure
    @workspace&.instance_variable_set(:@debug_session, nil)
  end

  def test_workspace_registers_console_actions_and_panel
    @workspace = Canopus::Workspace.new(root: @root)

    assert @workspace.panels.key?("debug_console")
    assert @workspace.commands.resolve("debug.console.evaluate")
    assert @workspace.commands.resolve("panel.debug_console")
  end

  private

  def build_console
    Canopus::Debug::Console.new(post: ->(&block) { @queue << block }, request_frame: -> {})
  end

  def drain
    @queue.shift.call until @queue.empty?
  end

  def settle_tokens(current)
    document = current.language_document
    rows = (0...current.buffer.line_count).to_a
    document.request(rows: rows)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until rows.all? { |row| document.tokens_current?(row) }
      document.poll
      raise "timed out waiting for tokens" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.005
    end
  end

  def variable(value)
    Megrez::Variable.new(name: "value", value: value, type: "Integer", variables_reference: 0,
      named_count: nil, indexed_count: nil, memory_reference: nil)
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "megrez/testing"
require "tmpdir"

class DebugSessionTest < Minitest::Test
  Entry = Data.define(:path, :line, :condition, :hit_condition, :log_message, :enabled)

  def setup
    @root = Dir.mktmpdir("canopus-debug-session-")
    @path = File.join(@root, "app.rb")
    File.write(@path, "value = 1\nputs value\n")
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root) if File.exist?(@root)
  end

  def test_handshake_waits_for_initialized_sets_enabled_breakpoints_and_reports_first_frame
    launch_request = nil
    capabilities = Megrez::Testing::FakeAdapter::DEFAULT_CAPABILITIES.merge(
      "supportsHitConditionalBreakpoints" => true
    )
    adapter = Megrez::Testing::FakeAdapter.new(capabilities: capabilities, responses: {
      "launch" => lambda do |_arguments, request|
        launch_request = request
        [{"seq" => 800, "type" => "event", "event" => "initialized", "body" => {}}]
      end,
      "configurationDone" => lambda do |_arguments, request|
        [{"seq" => 801, "type" => "response", "request_seq" => request["seq"],
          "success" => true, "command" => "configurationDone", "body" => {}},
         {"seq" => 802, "type" => "response", "request_seq" => launch_request["seq"],
          "success" => true, "command" => "launch", "body" => {}},
         {"seq" => 803, "type" => "event", "event" => "stopped",
          "body" => {"reason" => "breakpoint", "threadId" => 1}}]
      end
    })
    client = Megrez::Session.new(adapter.transport)
    entries = [Entry.new("app.rb", 2, "ready?", "3", "hit", true),
      Entry.new("app.rb", 1, nil, nil, nil, false)]
    registry = Struct.new(:entries).new(entries)
    session = build_session(client, registry)
    stopped = Queue.new
    session.on(:stopped) { |frame| stopped << frame }

    assert_same session, session.start
    wait_until { !stopped.empty? }
    assert_equal ["initialize", "launch", "setBreakpoints", "configurationDone", "stackTrace"],
      adapter.messages.grep(Hash).select { |message| message["type"] == "request" }.map { |message| message["command"] }
    set = adapter.messages.find { |message| message["command"] == "setBreakpoints" }
    assert_equal [{"line" => 2, "condition" => "ready?", "hitCondition" => "3", "logMessage" => "hit"}],
      set.dig("arguments", "breakpoints")
    frame = stopped.pop
    assert_equal ["app.rb", 1], [frame.source.fetch("path"), frame.line]
  ensure
    session&.close
  end

  def test_launch_rejection_is_reported_without_waiting_for_initialized
    failed_launch = lambda do |_arguments, request|
      [{"seq" => 800, "type" => "response", "request_seq" => request["seq"],
        "success" => false, "command" => "launch", "message" => "bad launch"}]
    end
    adapter = Megrez::Testing::FakeAdapter.new(responses: {"launch" => failed_launch})
    client = Megrez::Session.new(adapter.transport)
    session = build_session(client, Struct.new(:entries).new([]))

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Canopus::Error) { session.start }

    assert_match(/bad launch/, error.message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
  ensure
    session&.close
  end

  def test_launch_rejection_wins_when_initialized_arrives_first
    failed_launch = lambda do |_arguments, request|
      [{"seq" => 800, "type" => "event", "event" => "initialized", "body" => {}},
       {"seq" => 801, "type" => "response", "request_seq" => request["seq"],
        "success" => false, "command" => "launch", "message" => "bad launch"}]
    end
    adapter = Megrez::Testing::FakeAdapter.new(responses: {"launch" => failed_launch})
    client = Megrez::Session.new(adapter.transport)
    session = build_session(client, Struct.new(:entries).new([]))

    error = assert_raises(Canopus::Error) { session.start }

    assert_match(/bad launch/, error.message)
  ensure
    session&.close
  end

  def test_adapter_capabilities_limit_breakpoint_fields_and_configuration_done
    adapter = Megrez::Testing::FakeAdapter.new(capabilities: {}, responses: {
      "launch" => lambda do |_arguments, request|
        [{"seq" => 800, "type" => "response", "request_seq" => request["seq"],
          "success" => true, "command" => "launch", "body" => {}},
         {"seq" => 801, "type" => "event", "event" => "initialized", "body" => {}}]
      end
    })
    client = Megrez::Session.new(adapter.transport)
    entry = Entry.new("app.rb", 2, nil, nil, nil, true)
    session = build_session(client, Struct.new(:entries).new([entry]))

    session.start

    commands = adapter.messages.select { |message| message["type"] == "request" }.map { |message| message["command"] }
    assert_equal ["initialize", "launch", "setBreakpoints"], commands
    set = adapter.messages.find { |message| message["command"] == "setBreakpoints" }
    assert_equal [{"line" => 2}], set.dig("arguments", "breakpoints")
  ensure
    session&.close
  end

  def test_unsupported_conditional_breakpoint_fails_explicitly
    adapter = Megrez::Testing::FakeAdapter.new(capabilities: {}, responses: {
      "launch" => lambda do |_arguments, request|
        [{"seq" => 800, "type" => "response", "request_seq" => request["seq"],
          "success" => true, "command" => "launch", "body" => {}},
         {"seq" => 801, "type" => "event", "event" => "initialized", "body" => {}}]
      end
    })
    client = Megrez::Session.new(adapter.transport)
    entry = Entry.new("app.rb", 2, "ready?", nil, nil, true)
    session = build_session(client, Struct.new(:entries).new([entry]))

    error = assert_raises(Canopus::Error) { session.start }

    assert_match(/does not support condition/, error.message)
  ensure
    session&.close
  end

  def test_stdio_attach_uses_the_same_configuration_handshake
    adapter = Megrez::Testing::FakeAdapter.new
    client = Megrez::Session.new(adapter.transport)
    config = configuration("Attach").merge("request" => "attach")
    session = Canopus::Debug::Session.new(root: @root, configuration: config,
      adapter: {"command" => ["fake-adapter"], "transport" => "stdio"},
      breakpoints: Struct.new(:entries).new([]), client: client, timeout: 2)

    session.start

    commands = adapter.messages.select { |message| message["type"] == "request" }.map { |message| message["command"] }
    assert_equal ["initialize", "attach", "configurationDone"], commands.first(3)
  ensure
    session&.close
  end

  def test_evaluate_forwards_context_and_output_events_in_order
    adapter = Megrez::Testing::FakeAdapter.new
    client = Megrez::Session.new(adapter.transport)
    session = build_session(client, Struct.new(:entries).new([]))
    outputs = Queue.new
    session.on(:output) { |event| outputs << event }
    session.start
    wait_until { session.stopped_thread_id }

    result = session.evaluate("answer", frame_id: 10, context: "repl").await(timeout: 1)
    session.evaluate("watched", frame_id: 10).await(timeout: 1)
    adapter.emit(:output, "category" => "stdout", "output" => "one")
    adapter.emit(:output, "category" => "stderr", "output" => "two")
    wait_until { outputs.length == 2 }

    requests = adapter.messages.select { |message| message["command"] == "evaluate" }
    assert_equal({"expression" => "answer", "context" => "repl", "frameId" => 10}, requests[-2]["arguments"])
    assert_equal({"expression" => "watched", "context" => "watch", "frameId" => 10}, requests[-1]["arguments"])
    assert_equal "42", result.value
    assert_equal %w[one two], 2.times.map { outputs.pop.fetch("output") }
  ensure
    session&.close
  end

  def test_rdbg_tcp_attach_is_rejected_before_spawning
    config = configuration("Attach").merge("request" => "attach")
    session = Canopus::Debug::Session.new(root: @root, configuration: config,
      adapter: {"command" => ["rdbg", "--open"], "transport" => "tcp"},
      breakpoints: Struct.new(:entries).new([]), timeout: 2)

    error = assert_raises(Canopus::Error) { session.start }

    assert_match(/only support launch/, error.message)
  ensure
    session&.close
  end

  def test_workspace_command_selects_configuration_and_tracks_stopped_continued_and_terminated
    File.write(File.join(@root, ".canopus-launch-placeholder"), "")
    FileUtils.mkdir_p(File.join(@root, ".canopus"))
    File.write(File.join(@root, ".canopus", "launch.jsonc"), JSON.generate("configurations" => [
      configuration("First"), configuration("Second")
    ]))
    settings = Canopus::Settings.new("debug_adapters" => {
      "ruby" => {"command" => ["fake-adapter"], "transport" => "stdio"}
    })
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    @workspace.open(@path)
    @workspace.breakpoints.add(@path, 1)
    adapter = Megrez::Testing::FakeAdapter.new
    client = Megrez::Session.new(adapter.transport)
    @workspace.define_singleton_method(:build_debug_session) do |configuration:, adapter:|
      Canopus::Debug::Session.new(root: root, configuration: configuration, adapter: adapter,
        breakpoints: breakpoints, client: client)
    end

    @workspace.call("debug.start")
    assert_equal :debug_configurations, @workspace.palette[:kind]
    @workspace.palette[:index] = 1
    @workspace.palette_accept
    wait_until do
      @workspace.drain
      @workspace.debug_position
    end

    assert_equal [File.realpath(@path), 0], @workspace.debug_position.values_at(:path, :row)
    assert_same @workspace.buffers.fetch(File.realpath(@path)), @workspace.editor.buffer
    assert @workspace.decorations.items_for(@workspace.editor.buffer, 0...1)
      .any? { |item| item.source == :debug_position && item.kind == :line }

    adapter.emit(:continued, "threadId" => 1)
    wait_until { @workspace.drain; @workspace.debug_position.nil? }
    adapter.emit(:terminated)
    wait_until { @workspace.drain; @workspace.debug_session.nil? }
    assert @workspace.notifications.any? { |item| item[:text] == "Debug session ended" }
  end

  def test_workspace_close_stops_the_active_session
    settings = Canopus::Settings.new("debug_adapters" => {
      "ruby" => {"command" => ["fake-adapter"], "transport" => "stdio"}
    })
    FileUtils.mkdir_p(File.join(@root, ".canopus"))
    File.write(File.join(@root, ".canopus", "launch.jsonc"), JSON.generate("configurations" => [configuration("Run")]))
    adapter = Megrez::Testing::FakeAdapter.new(responses: {"launch" => ->(*) { [] }})
    client = Megrez::Session.new(adapter.transport)
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    @workspace.define_singleton_method(:build_debug_session) do |configuration:, adapter:|
      Canopus::Debug::Session.new(root: root, configuration: configuration, adapter: adapter,
        breakpoints: breakpoints, client: client)
    end
    @workspace.call("debug.start")
    wait_until { adapter.messages.any? { |message| message["command"] == "launch" } }

    @workspace.close

    assert_equal :terminated, client.state
    @workspace = nil
  end

  def test_stop_debugging_joins_startup_thread_when_close_fails
    @workspace = Canopus::Workspace.new(root: @root)
    closed = false
    session = Object.new
    session.define_singleton_method(:close) do
      closed = true
      raise Canopus::Error, "close failed"
    end
    thread = Thread.new { Thread.pass until closed }
    @workspace.instance_variable_set(:@debug_session, session)
    @workspace.instance_variable_set(:@debug_thread, thread)

    error = assert_raises(Canopus::Error) { @workspace.stop_debugging }

    assert_equal "close failed", error.message
    refute thread.alive?
  end

  def test_adapter_environment_removes_bundler_injection_and_keeps_explicit_values
    configuration = configuration("Run").merge("env" => {"BUNDLE_GEMFILE" => "explicit", "TOKEN" => "secret"})
    session = Canopus::Debug::Session.new(root: @root, configuration: configuration,
      adapter: {"command" => ["fake-adapter"], "transport" => "stdio"},
      breakpoints: Struct.new(:entries).new([]), client: Object.new)

    environment = session.send(:debug_environment)

    assert_equal "explicit", environment["BUNDLE_GEMFILE"]
    assert_equal "secret", environment["TOKEN"]
    assert_nil environment["RUBYOPT"]
    assert_nil environment["RUBYLIB"]
    assert_nil environment["BUNDLE_BIN_PATH"] if ENV.key?("BUNDLE_BIN_PATH")
  end

  def test_tcp_process_uses_supported_shutdown_signals
    session = build_session(Object.new, Struct.new(:entries).new([]))
    waiter = Object.new
    waiter.define_singleton_method(:pid) { 123 }
    waiter.define_singleton_method(:join) { |_timeout| false }
    signals = []

    Process.stub(:kill, ->(signal, pid) { signals << [signal, pid] }) do
      Gem.stub(:win_platform?, true) { session.send(:stop_process, waiter) }
    end
    assert_equal [["KILL", 123]], signals

    signals.clear
    Process.stub(:kill, ->(signal, pid) { signals << [signal, pid] }) do
      Gem.stub(:win_platform?, false) { session.send(:stop_process, waiter) }
    end
    assert_equal [["TERM", 123], ["KILL", 123]], signals
  end

  def test_stopped_stack_result_is_discarded_after_the_debuggee_continues
    frame = Megrez::StackFrame.new(id: 1, name: "main", source: {"path" => @path},
      line: 1, column: 1, presentation_hint: nil)
    future = Megrez::Future.new(1)
    started = Queue.new
    client = Struct.new(:state, :generation, :future, :started) do
      def stack_trace(*)
        started << true
        future
      end
    end.new(:stopped, 7, future, started)
    owner = Object.new
    owner.define_singleton_method(:close) {}
    session = build_session(owner, Struct.new(:entries).new([]))
    stopped = Queue.new
    session.on(:stopped) { |value| stopped << value }
    worker = Thread.new { session.send(:stopped, client, "threadId" => 1) }
    started.pop

    client.state = :running
    future.fulfill([frame])
    worker.join

    assert_nil session.stopped_thread_id
    assert stopped.empty?
  ensure
    session&.close
  end

  def test_stopped_stack_error_is_discarded_after_the_debuggee_continues
    future = Megrez::Future.new(1)
    started = Queue.new
    client = Struct.new(:state, :generation, :future, :started) do
      def stack_trace(*)
        started << true
        future
      end
    end.new(:stopped, 7, future, started)
    owner = Object.new
    owner.define_singleton_method(:close) {}
    session = build_session(owner, Struct.new(:entries).new([]))
    errors = Queue.new
    session.on(:error) { |error| errors << error }
    worker = Thread.new { session.send(:stopped, client, "threadId" => 1) }
    started.pop

    client.state = :running
    future.fulfill(error: Megrez::Error.new("late failure"))
    worker.join

    assert errors.empty?
  ensure
    session&.close
  end

  def test_invalid_stopped_event_is_still_reported
    client = Struct.new(:state, :generation).new(:running, 7)
    owner = Object.new
    owner.define_singleton_method(:close) {}
    session = build_session(owner, Struct.new(:entries).new([]))
    errors = Queue.new
    session.on(:error) { |error| errors << error }

    session.send(:stopped, client, {})

    assert_equal 1, errors.length
    assert_match(/no thread/, errors.pop.message)
  ensure
    session&.close
  end

  def test_rdbg_tcp_launch_stops_and_highlights_the_workspace_source
    skip "set CANOPUS_RDBG=1 to run the rdbg acceptance test" unless ENV["CANOPUS_RDBG"] == "1"

    FileUtils.mkdir_p(File.join(@root, ".canopus"))
    File.write(File.join(@root, ".canopus", "launch.jsonc"), JSON.generate("configurations" => [
      configuration("Run script").merge("program" => @path, "cwd" => @root)
    ]))
    settings = Canopus::Settings.new("debug_adapters" => {
      "ruby" => {"command" => ["rdbg", "--open", "--stop-at-load"], "transport" => "tcp"}
    })
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    @workspace.breakpoints.add(@path, 1)
    @workspace.call("debug.start")

    wait_until(timeout: 15) do
      @workspace.drain
      @workspace.debug_position
    end
    assert_equal [File.realpath(@path), 0], @workspace.debug_position.values_at(:path, :row)
  end

  private

  def configuration(name)
    {"name" => name, "type" => "ruby", "request" => "launch", "program" => @path, "cwd" => @root}
  end

  def build_session(client, breakpoints)
    Canopus::Debug::Session.new(root: @root, configuration: configuration("Run"),
      adapter: {"command" => ["fake-adapter"], "transport" => "stdio"},
      breakpoints: breakpoints, client: client, timeout: 2)
  end

  def wait_until(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      details = @workspace ? ": #{@workspace.notifications.map { |item| item[:text] }.join('; ')}" : ""
      raise "timed out#{details}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.005
    end
  end
end

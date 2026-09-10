# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/canopus/lsp"
require "stringio"
require "rbconfig"

class LSPRobustnessTest < Minitest::Test
  LSP = Canopus::LSP
  SERVER = <<~'RUBY'
    require "json"
    STDIN.binmode
    STDOUT.binmode
    STDOUT.sync = true
    def send_message(message)
      body = JSON.generate(message)
      STDOUT.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
    end
    messages = []
    loop do
      headers = {}
      while (line = STDIN.gets) && line != "\r\n"
        key, value = line.strip.split(":", 2)
        headers[key] = value.strip
      end
      break unless line
      message = JSON.parse(STDIN.read(headers.fetch("Content-Length").to_i))
      messages << message
      break if message["method"] == "exit"
      next unless message.key?("id") && message.key?("method")
      case message["method"]
      when "initialize"
        result = {capabilities: {positionEncoding: "utf-16", textDocumentSync: {openClose: true, change: 2, save: {includeText: true}}, semanticTokensProvider: {legend: {tokenTypes: ["variable"], tokenModifiers: []}, full: {delta: true}}}}
      when "probe" then result = messages
      when "server_request"
        send_message(jsonrpc: "2.0", id: "server-1", method: message["params"]["method"], params: message["params"].fetch("params", {}))
        result = true
      when "server_notification"
        send_message(jsonrpc: "2.0", method: message["params"]["method"], params: message["params"].fetch("params", {}))
        result = true
      when "stderr"
        STDERR.write("x" * (2 << 20))
        STDERR.flush
        result = true
      when "never" then next
      when "crash" then exit!(1)
      when "textDocument/semanticTokens/full" then result = {resultId: "first", data: [0, 0, 1, 0, 0]}
      when "textDocument/semanticTokens/full/delta" then result = {resultId: "second", edits: [{start: 2, deleteCount: 1, data: [2]}]}
      else result = nil
      end
      send_message(jsonrpc: "2.0", id: message["id"], result: result)
    end
  RUBY

  def client(**options)
    instance = LSP::Client.new(command: [RbConfig.ruby, "-e", SERVER], restart: false, **options).start(timeout: 3)
    yield instance
  ensure
    instance&.stop
  end

  def wait_until(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep(0.005)
    end
  end

  def test_future_callbacks_are_bounded_detachable_and_cancellation_is_once
    cancelled, completed = [], []
    future = LSP::Future.new(9) { |id| cancelled << id }
    subscription = future.on_complete { completed << :detached }
    subscription.detach
    40.times { future.then { raise "失敗" * 1000 } }
    future.on_complete { completed << :finished }
    assert future.cancel
    refute future.cancel
    assert future.done?
    assert_equal [9], cancelled
    assert_equal [:finished], completed
    assert_equal 32, future.callback_errors.length
    assert future.callback_errors.all? { |error| error.message.bytesize <= 2048 }
    assert_raises(LSP::Error) { future.await }
    fulfilled = LSP::Future.new(1) { flunk "completed request cancelled" }
    fulfilled.fulfill(42)
    refute fulfilled.cancel
    assert_equal 42, fulfilled.await(timeout: 0)
    assert_raises(ArgumentError) { fulfilled.await(timeout: Float::NAN) }
  end

  def test_future_wait_yields_the_foreground_fiber_and_timeout_cancels
    executor = Zaniah::TaskExecutor.new(workers: 1)
    future, events = LSP::Future.new(1), []
    task = executor.spawn { events << :waiting; events << future.await(timeout: 1) }
    executor.post { events << :responsive }
    executor.drain
    assert_equal [:waiting, :responsive], events
    refute task.done?
    Thread.new { future.fulfill(:value) }.join
    executor.drain
    assert_equal [:waiting, :responsive, :value], events
    assert task.done?
    cancellations = []
    pending = LSP::Future.new(2) { |id| cancellations << id }
    timed = executor.spawn { pending.await(timeout: 0.005) }
    executor.drain
    sleep(0.01)
    executor.drain
    assert_raises(LSP::Timeout) { timed.await }
    assert_equal [2], cancellations
  ensure
    executor&.shutdown
  end

  def test_invalid_frames_and_jsonrpc_shapes_are_rejected
    [nil, [], {"jsonrpc" => "1.0"}, {"jsonrpc" => "2.0", "method" => 4},
      {"jsonrpc" => "2.0", "method" => "test", "id" => []},
      {"jsonrpc" => "2.0", "method" => "test", "params" => "bad"},
      {"jsonrpc" => "2.0", "id" => 1},
      {"jsonrpc" => "2.0", "id" => 1, "result" => nil, "error" => {}},
      {"jsonrpc" => "2.0", "id" => 1, "error" => {"code" => "bad", "message" => 1}}].each do |value|
      assert_raises(LSP::Error) { LSP::Transport.validate_message(value) }
    end
    ["Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}", "Content-Length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=latin1\r\n\r\n{}", "Content-Length: 1\r\n\r\n\xff".b, "Content-Length: 1\r\n\r\n{"].each do |frame|
      assert_raises(LSP::Error) { LSP::Transport.read_message(StringIO.new(frame)) }
    end
    assert_raises(ArgumentError) { LSP::Transport.new(["bad\0command"]) {} }
  end

  def test_utf16_positions_and_semantic_values_are_checked
    rope = Denebola::Rope.new("🙂a\n日本")
    [-1, "0", nil].each do |bad|
      assert_raises(LSP::Error) { LSP::Protocol.offset(rope, {"line" => 0, "character" => bad}) }
    end
    assert_raises(RangeError) { LSP::Protocol.offset(rope, {"line" => 0, "character" => 1}) }
    assert_equal 5, LSP::Protocol.offset(rope, {"line" => 0, "character" => 1000})
    [[0, 0, 0, 0, 0], [0, 0, 1, -1, 0], [0, 0, 1, 0, 1 << 31], [1]].each do |data|
      assert_raises(LSP::Error) { LSP::Protocol.semantic_tokens(data) }
    end
    assert_raises(LSP::Error) { LSP::Protocol.semantic_tokens([0, 0, 1, 2, 0], legend: {"tokenTypes" => ["type"], "tokenModifiers" => []}) }
    assert_raises(LSP::Error) { LSP::Protocol.semantic_delta([], [{"start" => nil}]) }
    assert_raises(LSP::Error) { LSP::Protocol.path("file:///tmp/x%00") }
    assert_raises(LSP::Error) { LSP::Protocol.path("file:///tmp/x?query") }
    assert_raises(LSP::Error) { LSP::Protocol.diagnostics([{"message" => "bad", "range" => {}}]) }
    assert_raises(LSP::Error) { LSP::Protocol.diagnostics([{"message" => "bad", "range" => {"start" => {"line" => 1, "character" => 0}, "end" => {"line" => 0, "character" => 0}}}]) }
  end

  def test_handler_and_callback_failures_do_not_break_the_reader
    client do |instance|
      instance.on("explode") { raise "boom" }
      instance.on("error") { raise "error handler also failed" }
      assert instance.request("server_request", method: "explode").await
      responses = nil
      wait_until do
        responses = instance.request("probe").await
        responses.any? { |message| message["id"] == "server-1" && message["error"] }
      end
      response = responses.find { |message| message["id"] == "server-1" && message["error"] }
      assert_equal(-32603, response.dig("error", "code"))
      instance.request("probe").then { raise "callback failure" }.await
      assert instance.request("probe").await.is_a?(Array)
      assert_equal :running, instance.state
      assert_operator instance.errors.length, :>=, 2
      assert_raises(LSP::Error) { instance.start }
      assert_equal :running, instance.state
      instance.request("never").tap { |future| assert_raises(LSP::Timeout) { future.await(timeout: 0.01) } }
      assert instance.request("probe").await.any? { |message| message["method"] == "$/cancelRequest" }
    end
  end

  def test_deferred_handlers_and_unsupported_methods_receive_responses
    client do |instance|
      deferred = LSP::Future.new(nil)
      instance.on("deferred") { deferred }
      instance.request("server_request", method: "deferred").await
      deferred.fulfill(false)
      messages = instance.request("probe").await
      assert messages.any? { |message| message["id"] == "server-1" && message["result"] == false }
      instance.request("server_request", method: "unknown").await
      assert instance.request("probe").await.any? { |message| message["id"] == "server-1" && message.dig("error", "code") == -32601 }
    end
  end

  def test_synchronization_semantic_delta_and_stale_diagnostics
    client do |instance|
      buffer = Canopus::Buffer.new("🙂a", path: File.expand_path("test.rb"))
      uri = instance.open_document(buffer, language_id: "ruby")
      assert_equal 1, instance.semantic_tokens(buffer).first[:length]
      buffer.edit([[4...5, "new"]])
      assert_equal 2, instance.semantic_tokens(buffer).first[:length]
      instance.save_document(uri)
      messages = instance.request("probe").await
      change = messages.find { |message| message["method"] == "textDocument/didChange" }
      assert_equal({"line" => 0, "character" => 2}, change.dig("params", "contentChanges", 0, "range", "start"))
      save = messages.find { |message| message["method"] == "textDocument/didSave" }
      assert_equal "🙂new", save.dig("params", "text")
      instance.request("server_notification", method: "textDocument/publishDiagnostics", params: {uri: uri, version: 0, diagnostics: []}).await
      refute instance.diagnostics.key?(uri)
      instance.request("server_notification", method: "textDocument/publishDiagnostics", params: {uri: uri, version: 1, diagnostics: []}).await
      assert_equal [], instance.diagnostics[uri]
    end
  end

  def test_stderr_is_bounded_even_without_newlines
    client do |instance|
      instance.request("stderr").await
      wait_until { instance.transport.stderr_lines.length == 200 }
      assert instance.transport.stderr_lines.all? { |line| line.bytesize <= 8192 }
      assert_equal :running, instance.state
    end
  end

  def test_crash_restarts_process_and_reopens_documents
    client(restart: true) do |instance|
      buffer = Canopus::Buffer.new("hello", path: File.expand_path("test.rb"))
      uri = instance.open_document(buffer, language_id: "ruby")
      pid = instance.transport.pid
      assert_raises(LSP::Error) { instance.request("crash").await }
      wait_until { instance.state == :running && instance.transport.pid != pid }
      messages = instance.request("probe").await
      assert messages.any? { |message| message["method"] == "textDocument/didOpen" && message.dig("params", "textDocument", "uri") == uri }
      buffer.edit([[0...0, "x"]])
      assert_equal 1, instance.request("probe").await.count { |message| message["method"] == "textDocument/didChange" }
    end
  end
end

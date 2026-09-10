# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/canopus/lsp"
require "stringio"
require "rbconfig"

class LSPTest < Minitest::Test
  def frame(message)
    json = JSON.generate(message)
    "Content-Length: #{json.bytesize}\r\n\r\n#{json}"
  end
  def test_framing_utf8_multiple_messages_and_malformed_input
    message = {"jsonrpc" => "2.0", "id" => 1, "result" => "日本🙂"}
    io = StringIO.new(frame(message) * 2)
    assert_equal message, Canopus::LSP::Transport.read_message(io)
    assert_equal message, Canopus::LSP::Transport.read_message(io)
    assert_nil Canopus::LSP::Transport.read_message(io)
    ["Content-Length: -1\r\n\r\n", "Content-Length: 999999999999\r\n\r\n", "Bad\r\n\r\n", "Content-Length: 10\r\n\r\n{}"].each do |invalid|
      assert_raises(Canopus::LSP::Error) { Canopus::LSP::Transport.read_message(StringIO.new(invalid)) }
    end
  end
  def test_utf16_and_semantic_token_deltas
    rope = Denebola::Rope.new("a🙂日\nnext")
    assert_equal({line: 0, character: 3}, Canopus::LSP::Protocol.position(rope, 5))
    assert_equal 5, Canopus::LSP::Protocol.offset(rope, {"line" => 0, "character" => 3})
    data = Canopus::LSP::Protocol.semantic_delta([0, 0, 3, 0, 0], [{"start" => 5, "deleteCount" => 0, "data" => [1, 2, 4, 1, 0]}])
    assert_equal [0, 1], Canopus::LSP::Protocol.semantic_tokens(data).map { |t| t[:line] }
    assert_raises(Canopus::LSP::Error) { Canopus::LSP::Protocol.semantic_delta(data, [{"start" => -1, "deleteCount" => 2}]) }
  end
  def test_real_child_process_initialize_notifications_request_and_shutdown
    server = <<~'RUBY'
      require "json"
      STDIN.binmode
      STDOUT.binmode
      STDOUT.sync = true
      loop do
        headers = {}
        while (line = STDIN.gets) && line != "\r\n"
          key, value = line.strip.split(":", 2)
          headers[key] = value.strip
        end
        break unless line
        data = JSON.parse(STDIN.read(headers.fetch("Content-Length").to_i))
        break if data["method"] == "exit"
        next unless data.key?("id")
        result = case data["method"]
        when "initialize" then {capabilities: {textDocumentSync: 2}}
        when "textDocument/hover" then {contents: "hover 日本"}
        when "shutdown" then nil
        else data["params"]
        end
        body = JSON.generate(jsonrpc: "2.0", id: data["id"], result: result)
        STDOUT.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
      end
    RUBY
    client = Canopus::LSP::Client.new(command: [RbConfig.ruby, "-e", server], restart: false).start(timeout: 3)
    assert_equal :running, client.state
    buffer = Canopus::Buffer.new("日本", path: "/private/tmp/lsp test.rb")
    uri = client.open_document(buffer, language_id: "ruby")
    assert_includes uri, "lsp%20test.rb"
    buffer.edit([[0...0, "x"]])
    assert_equal "hover 日本", client.hover(buffer, 1).await.fetch("contents")
    client.close_document(uri)
    client.stop
    assert_equal :stopped, client.state
  ensure
    client&.stop
  end
end

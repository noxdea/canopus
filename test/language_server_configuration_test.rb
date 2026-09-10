# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "tmpdir"

class LanguageServerConfigurationTest < Minitest::Test
  class FakeClient
    attr_reader :options, :events, :handlers, :diagnostics, :state
    attr_accessor :before_stop, :before_start, :pending
    def initialize(**options)
      @options, @events, @handlers, @documents, @diagnostics = options, [], {}, {}, {}
      @state = :stopped
    end
    def start
      @state = :starting
      @before_start&.call
      @state = :running
      @events << [:start]
      self
    end
    def on(name, &block) = @handlers[name] = block
    def open_document(buffer, language_id:)
      @events << [:open, buffer.path, language_id]
      @documents[Canopus::LSP::Protocol.uri(buffer.path)] = buffer.on_edit { |patch| @events << [:change, buffer.path, patch.after.to_s] }
    end
    def close_document(uri)
      @events << [:close, uri]
      @documents.delete(uri)&.detach
      @diagnostics.delete(uri)
    end
    def stop
      @before_stop&.call
      @before_stop = nil
      @documents.each_value(&:detach)
      @documents.clear
      @diagnostics.clear
      @pending&.fulfill(error: Canopus::LSP::Error.new("language server stopped"))
      @state = :stopped
      @events << [:stop]
    end
    def notify(name, payload) = @events << [name, payload]
    def hover(*) = @pending ||= Canopus::LSP::Future.new(1)
    def capabilities = {}
  end

  def setup
    @root = Dir.mktmpdir("canopus-language-settings-")
    @settings = Canopus::Settings.new("language_servers" => {"ruby" => ["server-a"]})
    @workspace = Canopus::Workspace.new(root: @root, settings: @settings)
    @editor = @workspace.open("first.rb")
    @created = []
  end

  def teardown
    @workspace.close
    FileUtils.remove_entry(@root)
  end

  def with_clients(&block)
    Canopus::LSP::Client.stub(:new, ->(**options) { FakeClient.new(**options).tap { |client| @created << client } }, &block)
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until yield
      raise "language settings did not settle" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.001
    end
  end

  def settle
    wait_until { !@workspace.instance_variable_get(:@language_reload_job)&.alive? }
    @workspace.drain
  end

  def configure(value)
    @settings.merge!("language_servers" => {"ruby" => value})
    @workspace.apply_settings
    settle
  end

  def test_changed_command_closes_old_documents_and_reopens_each_shared_buffer_once
    second = @workspace.open("second.rb")
    @workspace.split
    with_clients do
      old = @workspace.language_client(@editor.buffer)
      assert_equal 2, old.events.count { |event| event.first == :open }
      old.pending = Canopus::LSP::Future.new(9)
      configure(["server-b"])
      current = @workspace.clients.fetch("ruby")
      refute_same old, current
      assert_equal ["server-b"], current.options[:command]
      assert_equal 2, old.events.count { |event| event.first == :close }
      assert_equal 2, current.events.count { |event| event.first == :open }
      assert_raises(Canopus::LSP::Error) { old.pending.await(timeout: 0) }
      second.insert_text("value", auto_indent: false)
      refute old.events.any? { |event| event.first == :change }
      assert_equal 1, current.events.count { |event| event.first == :change }
      assert_same current, @workspace.language_client(@editor.buffer)
      assert_equal 2, @created.length
    end
  end

  def test_unchanged_servers_survive_other_setting_changes_and_configuration_only_notifies
    with_clients do
      original = @workspace.language_client
      @settings.merge!("font_size" => 18, "tab_size" => 2)
      @workspace.apply_settings
      settle
      configure({"command" => ["server-a"], "configuration" => {"ruby" => {"enabled" => false}}})
      assert_same original, @workspace.clients["ruby"]
      assert_equal 1, @created.length
      assert_equal [["workspace/didChangeConfiguration", {settings: {"ruby" => {"enabled" => false}}}]], original.events.select { |event| event.first.is_a?(String) }
      @workspace.apply_settings
      settle
      assert_equal 1, original.events.count { |event| event.first == "workspace/didChangeConfiguration" }
      result = original.handlers.fetch("workspace/configuration").call("items" => [{"section" => "ruby.enabled"}, {"section" => "use_tabs"}])
      assert_equal [false, false], result
    end
  end

  def test_language_specific_server_override_has_precedence_and_reloads_when_it_changes
    @settings.merge!("languages" => {"ruby" => {"language_servers" => {"ruby" => ["override-a"]}}})
    with_clients do
      original = @workspace.language_client
      assert_equal ["override-a"], original.options[:command]
      configure(["global-changed"])
      assert_same original, @workspace.clients["ruby"]
      @settings.merge!("languages" => {"ruby" => {"language_servers" => {"ruby" => ["override-b"]}}})
      @workspace.apply_settings
      settle
      assert_equal ["override-b"], @workspace.clients["ruby"].options[:command]
      assert_equal 2, @created.length
    end
  end

  def test_environment_or_initialization_changes_restart_but_input_mutation_does_not
    with_clients do
      original = @workspace.language_client
      options = {"command" => ["server-a"], "env" => {"TEST_LANGUAGE" => +"one"}, "initialization_options" => {"enabled" => true}}
      configure(options)
      current = @workspace.clients["ruby"]
      refute_same original, current
      assert_equal({"TEST_LANGUAGE" => "one"}, current.options[:env])
      assert_equal({"enabled" => true}, current.options[:initialization_options])
      options["env"]["TEST_LANGUAGE"].replace("mutated")
      assert_equal "one", current.options[:env]["TEST_LANGUAGE"]
      assert current.options[:env].frozen?
    end
  end

  def test_invalid_reloaded_layer_does_not_stop_or_replace_any_client
    path = File.join(@root, "settings.jsonc")
    File.write(path, JSON.generate("language_servers" => {"ruby" => ["server-a"]}))
    @workspace.close
    @settings = Canopus::Settings.new(path)
    @workspace = Canopus::Workspace.new(root: @root, settings: @settings)
    @workspace.open("first.rb")
    with_clients do
      original = @workspace.language_client
      File.write(path, JSON.generate("language_servers" => {"ruby" => ["server-b"], "unused" => []}))
      @workspace.poll_settings(force: true)
      settle
      assert_same @settings, @workspace.settings
      assert_same original, @workspace.clients["ruby"]
      assert_equal :running, original.state
      assert_equal 1, @created.length
      assert_includes @workspace.message, "Settings unchanged"
      File.write(path, JSON.generate("language_servers" => {"ruby" => ["server-b"]}))
      @workspace.poll_settings(force: true)
      settle
      assert_equal ["server-b"], @workspace.clients["ruby"].options[:command]
    end
  end

  def test_null_returns_to_auto_detection_instead_of_disabling_a_server
    Canopus::Language.stub(:executable?, ->(name) { name == "ruby-lsp" }) do
      with_clients do
        @workspace.language_client
        configure(nil)
        assert_equal ["ruby-lsp"], @workspace.clients["ruby"].options[:command]
      end
    end
  end

  def test_no_detected_replacement_stops_old_server_and_later_configuration_reconnects
    Canopus::Language.stub(:executable?, false) do
      with_clients do
        original = @workspace.language_client
        configure(nil)
        assert_empty @workspace.clients
        assert_equal :stopped, original.state
        configure(["server-b"])
        assert_equal ["server-b"], @workspace.clients["ruby"].options[:command]
        assert_equal 1, @created.last.events.count { |event| event.first == :open }
      end
    end
  end

  def test_updates_during_shutdown_coalesce_to_latest_settings
    with_clients do
      original = @workspace.language_client
      entered, release = Queue.new, Queue.new
      original.before_stop = -> { entered << true; release.pop }
      @settings.merge!("language_servers" => {"ruby" => ["obsolete"]})
      @workspace.apply_settings
      wait_until { !entered.empty? }
      worker = @workspace.instance_variable_get(:@language_reload_job)
      @settings.merge!("language_servers" => {"ruby" => ["latest"]})
      @workspace.apply_settings
      assert_same worker, @workspace.instance_variable_get(:@language_reload_job)
      release << true
      settle
      assert_equal [%w[server-a], %w[latest]], @created.map { |client| client.options[:command] }
    ensure
      release << true if release
    end
  end

  def test_old_completed_request_and_edit_dialog_cannot_apply_after_restart
    with_clients do
      old = @workspace.language_client
      @workspace.language_request(:hover)
      wait_until { old.pending }
      old.pending.fulfill({"contents" => "obsolete hover"})
      wait_until { @workspace.instance_variable_get(:@language_jobs).none?(&:alive?) }
      response = old.handlers.fetch("workspace/applyEdit").call("edit" => {"changes" => {}})
      configure(["server-b"])
      assert_nil @workspace.hover_card
      assert_nil @workspace.palette
      refute response.await(timeout: 0).fetch("applied")
      palette = {kind: :completion, editor: @editor, client: old, version: @editor.buffer.version, items: [{"label" => "obsolete"}]}
      assert_raises(Canopus::Error) { @workspace.accept_language_result(palette, 0) }
      assert_equal "", @editor.buffer.text
    end
  end

  def test_close_during_initialization_does_not_publish_or_leak_a_new_client
    entered, release = Queue.new, Queue.new
    factory = lambda do |**options|
      FakeClient.new(**options).tap do |client|
        @created << client
        if options[:command] == ["server-b"]
          client.before_start = -> { entered << true; release.pop }
          client.before_stop = -> { release << true }
        end
      end
    end
    Canopus::LSP::Client.stub(:new, factory) do
      @workspace.language_client
      @settings.merge!("language_servers" => {"ruby" => ["server-b"]})
      @workspace.apply_settings
      wait_until { !entered.empty? }
      @workspace.close
      assert_empty @workspace.clients
      assert @created.all? { |client| client.state == :stopped }
      refute @workspace.instance_variable_get(:@language_reload_job)&.alive?
      assert_raises(Canopus::Error) { @workspace.language_client(@editor.buffer) }
    ensure
      release << true
    end
  end

  def test_real_child_replacement_reopens_current_text_with_new_environment_and_initialize_options
    server = <<~'RUBY'
      require "json"
      STDIN.binmode
      STDOUT.binmode
      STDOUT.sync = true
      documents, initialization = {}, nil
      loop do
        headers = {}
        while (line = STDIN.gets) && line != "\r\n"
          key, value = line.strip.split(":", 2)
          headers[key] = value.strip
        end
        break unless line
        message = JSON.parse(STDIN.read(headers.fetch("Content-Length").to_i))
        params = message.fetch("params", {})
        result = case message["method"]
        when "initialize"
          initialization = params["initializationOptions"]
          {capabilities: {textDocumentSync: {openClose: true, change: 1}}}
        when "textDocument/didOpen"
          document = params.fetch("textDocument")
          documents[document.fetch("uri")] = document
        when "textDocument/didChange"
          document = documents.fetch(params.fetch("textDocument").fetch("uri"))
          document["text"] = params.fetch("contentChanges").last.fetch("text")
        when "textDocument/didClose"
          documents.delete(params.fetch("textDocument").fetch("uri"))
        when "test/state"
          {label: ARGV.first, documents: documents.values, marker: ENV["CANOPUS_TEST_LSP_MARKER"], initialization: initialization}
        when "exit" then break
        end
        next unless message.key?("id")
        body = JSON.generate(jsonrpc: "2.0", id: message["id"], result: result)
        STDOUT.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
      end
    RUBY
    @settings.merge!("language_servers" => {"ruby" => [RbConfig.ruby, "-e", server, "first"]})
    @editor.insert_text("日本\n", auto_indent: false)
    original = @workspace.language_client
    assert_equal "first", original.request("test/state").await(timeout: 3).fetch("label")
    @editor.insert_text("changed", auto_indent: false)
    configure({"command" => [RbConfig.ruby, "-e", server, "second"],
      "env" => {"CANOPUS_TEST_LSP_MARKER" => "new"}, "initialization_options" => {"changed" => true}})
    current = @workspace.clients.fetch("ruby")
    state = current.request("test/state").await(timeout: 3)
    assert_equal :stopped, original.state
    assert_equal "second", state.fetch("label")
    assert_equal "new", state.fetch("marker")
    assert_equal({"changed" => true}, state.fetch("initialization"))
    assert_equal [@editor.buffer.text], state.fetch("documents").map { |document| document.fetch("text") }
    @editor.insert_text("!", auto_indent: false)
    state = current.request("test/state").await(timeout: 3)
    assert_equal @editor.buffer.text, state.fetch("documents").first.fetch("text")
    @workspace.close
    assert_equal :stopped, current.state
    refute current.transport.alive?
  end
end

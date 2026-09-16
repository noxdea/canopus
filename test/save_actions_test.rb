# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SaveActionsTest < Minitest::Test
  class FakeClient
    attr_reader :capabilities, :formatting_calls, :code_action_calls, :resolve_calls, :commands, :events
    attr_accessor :formatting_result, :resolved_action, :before_format, :before_code_action, :before_resolve

    def initialize
      @capabilities = {"documentFormattingProvider" => true, "codeActionProvider" => true}
      @formatting_calls, @code_action_calls, @resolve_calls, @commands, @events, @actions = [], [], [], [], [], {}
      @formatting_result = []
    end

    def actions=(value)
      @actions = value
    end

    def formatting(uri, options)
      @formatting_calls << [uri, options]
      @before_format&.call
      future(@formatting_result)
    end

    def code_action(uri, range, context)
      @code_action_calls << [uri, range, context]
      @before_code_action&.call
      future(@actions.fetch(context.fetch(:only).fetch(0), []))
    end

    def resolve_code_action(action)
      @resolve_calls << action
      @before_resolve&.call
      future(@resolved_action || action)
    end

    def execute_command(command, arguments: [])
      @commands << [command, arguments]
      future(nil)
    end

    def open(document) = @events << [:open, document.version, document.text]
    def change(_uri, version, changes) = @events << [:change, version, changes.last.text]
    def save(_uri) = @events << [:save]
    def close(_uri) = @events << [:close]

    def pending_formatting!
      define_singleton_method(:formatting) do |uri, options|
        @formatting_calls << [uri, options]
        Sadr::Future.new(1)
      end
    end

    private

    def future(value) = Sadr::Future.new(nil).tap { |result| result.fulfill(value) }
  end

  class HandlerClient < FakeClient
    attr_accessor :command_edit, :before_start
    attr_reader :handlers, :start_timeout

    def initialize
      super
      @handlers, @state = {}, :stopped
    end

    def on(name, &block) = @handlers[name] = block
    def start(timeout: nil)
      @start_timeout = timeout
      @before_start&.call(timeout)
      @state = :running
      self
    end
    def stop = @state = :stopped
    def running? = @state == :running
    def did_change_configuration(*) = nil

    def execute_command(command, arguments: [])
      super
      response = @handlers.fetch("workspace/applyEdit").call({"edit" => @command_edit})
      result = response.await(timeout: 1)
      raise result["failureReason"].to_s unless result["applied"]
      Sadr::Future.new(nil).tap { |future| future.fulfill(nil) }
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-save-actions-")
    @path = File.join(@root, "sample.rb")
    File.write(@path, "value\n")
    @settings = Canopus::Settings.new("language_servers" => {"ruby" => ["fake-server"]})
    @workspace = Canopus::Workspace.new(root: @root, settings: @settings)
    @editor = @workspace.open(@path)
    @client = FakeClient.new
  end

  def teardown
    @workspace.close
    FileUtils.remove_entry(@root)
  end

  def edit(text)
    {"range" => {"start" => {"line" => 0, "character" => 0},
      "end" => {"line" => 0, "character" => 0}}, "newText" => text}
  end

  def action(kind, text, version:, command: nil)
    value = {"title" => kind, "kind" => kind, "edit" => {"documentChanges" => [{
      "textDocument" => {"uri" => Sadr::Protocol.uri(@path), "version" => version}, "edits" => [edit(text)]
    }]}}
    value["command"] = {"command" => command, "arguments" => [kind]} if command
    value
  end

  def save
    @workspace.stub(:language_clients, [@client]) { @workspace.save_buffer(@editor.buffer) }
  end

  def test_formatting_and_configured_code_actions_apply_in_order_as_one_undo
    @settings.merge!("format_on_save" => true,
      "code_actions_on_save" => %w[source.organizeImports source.fixAll])
    @client.formatting_result = [edit("F")]
    @client.actions = {
      "source.organizeImports" => [action("source.organizeImports", "O", version: 1)],
      "source.fixAll" => [action("source.fixAll", "X", version: 2, command: "after.fix")]
    }

    save

    assert_equal "XOFvalue\n", File.read(@path)
    assert_equal [["after.fix", ["source.fixAll"]]], @client.commands
    assert_equal %w[source.organizeImports source.fixAll],
      @client.code_action_calls.map { |_uri, _range, context| context.fetch(:only).fetch(0) }
    assert @client.code_action_calls.all? { |_uri, _range, context| context[:triggerKind] == 2 }
    assert_equal 1, @editor.buffer.history.length
    assert @editor.undo
    assert_equal "value\n", @editor.buffer.text
  end

  def test_timeout_and_invalid_edits_notify_but_still_save
    @settings.merge!("format_on_save" => true, "format_on_save_timeout" => 1)
    @editor.insert_text("local ", auto_indent: false)
    @client.pending_formatting!

    save

    assert_equal "local value\n", File.read(@path)
    assert_match(/timed out/, @workspace.notifications.last.fetch(:text))

    @settings.merge!("format_on_save_timeout" => 2_000)
    @client = FakeClient.new
    @client.formatting_result = [{"range" => {"start" => {"line" => 99, "character" => 0},
      "end" => {"line" => 99, "character" => 0}}, "newText" => "invalid"}]
    save
    assert_equal "local value\n", File.read(@path)
    assert_match(/Save actions failed/, @workspace.notifications.last.fetch(:text))
  end

  def test_stale_formatting_is_rejected_and_the_newer_text_is_saved
    @settings.merge!("format_on_save" => true)
    @client.before_format = -> { @editor.buffer.edit([[0...0, "newer "]]) }
    @client.formatting_result = [edit("stale ")]

    save

    assert_equal "newer value\n", File.read(@path)
    refute_includes @editor.buffer.text, "stale"
    assert_match(/document changed/, @workspace.notifications.last.fetch(:text))
  end

  def test_stale_code_action_edit_is_rejected_without_preventing_the_save
    @settings.merge!("code_actions_on_save" => ["source.fixAll"])
    @editor.insert_text("local ", auto_indent: false)
    @client.actions = {"source.fixAll" => [action("source.fixAll", "stale ", version: 0)]}

    save

    assert_equal "local value\n", File.read(@path)
    refute_includes @editor.buffer.text, "stale"
    assert_match(/stale document version/, @workspace.notifications.last.fetch(:text))
  end

  def test_save_action_edit_cannot_reenter_save_actions
    @settings.merge!("format_on_save" => true)
    @client.formatting_result = [edit("F")]
    subscription = @editor.buffer.on_edit { @workspace.save_buffer(@editor.buffer) }

    save

    assert_equal 1, @client.formatting_calls.length
    assert_equal "Fvalue\n", File.read(@path)
  ensure
    subscription&.detach
  end

  def test_nested_save_of_another_buffer_runs_its_own_actions
    second_path = File.join(@root, "second.rb")
    File.write(second_path, "second\n")
    second = @workspace.open(second_path)
    @settings.merge!("format_on_save" => true)
    @client.formatting_result = [edit("F")]
    subscription = @editor.buffer.on_edit { @workspace.save_buffer(second.buffer) }

    @workspace.stub(:language_clients, [@client]) { @workspace.save_buffer(@editor.buffer) }

    assert_equal 2, @client.formatting_calls.length
    assert_equal "Fvalue\n", File.read(@path)
    assert_equal "Fsecond\n", File.read(second_path)
  ensure
    subscription&.detach
  end

  def test_formatting_edit_is_synced_before_the_save_notification
    @settings.merge!("format_on_save" => true)
    @client.formatting_result = [edit("F")]
    @workspace.send(:open_language_document, @client, @editor.buffer, "ruby")

    save

    assert_equal [:open, :change, :save], @client.events.map(&:first)
    assert_equal [1, "F"], @client.events.fetch(1).drop(1)
  end

  def test_command_code_action_applies_server_workspace_edit_without_a_dialog
    @settings.merge!("code_actions_on_save" => ["source.fixAll"])
    @client = HandlerClient.new
    @client.actions = {"source.fixAll" => [{"title" => "Fix", "kind" => "source.fixAll",
      "command" => {"title" => "Fix", "command" => "fix.command"}}]}
    @client.command_edit = {"documentChanges" => [{
      "textDocument" => {"uri" => Sadr::Protocol.uri(@path), "version" => 0}, "edits" => [edit("C")]
    }]}

    Sadr::Client.stub(:new, ->(**) { @client }) do
      @workspace.connect_server("ruby", ["fake-server"])
      @workspace.save_buffer(@editor.buffer)
    end

    assert_equal "Cvalue\n", File.read(@path)
    assert_nil @workspace.palette
    assert_equal [["fix.command", []]], @client.commands
  end

  def test_unsolicited_workspace_edits_still_require_confirmation_before_execute_command
    @settings.merge!("format_on_save" => true, "code_actions_on_save" => ["source.fixAll"])
    @client = HandlerClient.new
    @client.capabilities["codeActionProvider"] = {"resolveProvider" => true}
    @client.actions = {"source.fixAll" => [{"title" => "Fix", "kind" => "source.fixAll"}]}
    @client.resolved_action = {"title" => "Fix", "kind" => "source.fixAll"}
    phases, responses = [], []
    probe = lambda do |phase|
      response = @client.handlers.fetch("workspace/applyEdit").call({"edit" => {"changes" => {
        Sadr::Protocol.uri(@path) => [edit("U")]
      }}})
      phases << phase
      responses << response
      assert_equal :workspace_edit, @workspace.palette.fetch(:kind)
    end
    @client.before_format = -> { probe.call(:formatting) }
    @client.before_code_action = -> { probe.call(:code_action) }
    @client.before_resolve = -> { probe.call(:resolve) }

    Sadr::Client.stub(:new, ->(**) { @client }) { @workspace.save_buffer(@editor.buffer) }

    assert_equal %i[formatting code_action resolve], phases
    assert_equal [true, true, false], responses.map(&:done?)
    assert responses.first(2).all? { |response| !response.await(timeout: 0).fetch("applied") }
    assert_equal 1, @client.resolve_calls.length
    assert_equal "value\n", File.read(@path)
  end

  def test_complete_code_action_edit_does_not_depend_on_resolve
    @settings.merge!("code_actions_on_save" => ["source.fixAll"])
    @client.capabilities["codeActionProvider"] = {"resolveProvider" => true}
    @client.actions = {"source.fixAll" => [action("source.fixAll", "R", version: 0)]}
    @client.define_singleton_method(:resolve_code_action) { |*| raise "completed action was resolved" }

    save

    assert_equal "Rvalue\n", File.read(@path)
  end

  def test_initial_language_server_start_uses_the_save_action_deadline
    @settings.merge!("format_on_save" => true, "format_on_save_timeout" => 10)
    @client = HandlerClient.new
    @client.before_start = lambda do |timeout|
      sleep(timeout)
      raise Sadr::Timeout, "startup timed out"
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    Sadr::Client.stub(:new, ->(**) { @client }) { @workspace.save_buffer(@editor.buffer) }

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator @client.start_timeout, :>, 0
    assert_operator @client.start_timeout, :<=, 0.01
    assert_operator elapsed, :<, 0.2
    assert_equal "value\n", File.read(@path)
    assert_match(/timed out/, @workspace.notifications.last.fetch(:text))
  end

  def test_first_save_as_establishes_the_document_uri_before_actions
    current = @workspace.new_buffer
    current.insert_text("draft", auto_indent: false)
    @settings.merge!("format_on_save" => true)

    @workspace.stub(:language_clients, [@client]) { @workspace.save_buffer(current.buffer, path: "new.rb") }
    assert_equal "draft", File.read(File.join(@root, "new.rb"))
    assert_empty @client.formatting_calls

    @client.formatting_result = [edit("F")]
    @workspace.stub(:language_clients, [@client]) { @workspace.save_buffer(current.buffer) }
    assert_equal "Fdraft", File.read(File.join(@root, "new.rb"))
  end
end

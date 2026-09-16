# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class MultipleLanguageServersTest < Minitest::Test
  class Client
    attr_reader :capabilities, :command, :events, :handlers, :state
    attr_accessor :completions, :actions, :before_stop, :configuration_error, :open_error,
      :publish_on_open, :completion_future, :code_action_future, :code_action_error,
      :diagnostic_future, :diagnostic_error, :stop_failures

    def initialize(command:, **)
      @command = command
      @handlers, @events = {}, []
      @state = :stopped
      @completions, @actions = [], []
      @capabilities = {
        "completionProvider" => true, "definitionProvider" => true,
        "documentFormattingProvider" => true, "codeActionProvider" => true
      }
    end

    def start(timeout: nil)
      @events << [:start, timeout]
      raise Canopus::Error, "start failed" if @command.first == "broken"
      @state = :running
      self
    end
    def stop
      @before_stop&.call
      @events << [:stop]
      if @stop_failures.to_i.positive?
        @stop_failures -= 1
        raise Canopus::Error, "stop failed"
      end
      @state = :stopped
    end
    def running? = @state == :running
    def on(name, &block) = @handlers[name] = block
    def open(document)
      @events << [:open, document.uri, document.version]
      @publish_on_open&.call(document)
      raise @open_error if @open_error
    end
    def change(uri, version, changes) = @events << [:change, uri, version, changes]
    def save(uri) = @events << [:save, uri]
    def close(uri) = @events << [:close, uri]
    def did_change_configuration(settings)
      @events << [:configuration, settings]
      raise @configuration_error if @configuration_error
    end
    def completion(*) = @completion_future || future(@completions)
    def definition(*) = future([{"uri" => "file:///definition.rb", "range" => range}])
    def formatting(*) = future([])
    def code_action(*)
      @events << [:code_action]
      raise @code_action_error if @code_action_error
      @code_action_future || future(@actions)
    end
    def diagnostic(*)
      @events << [:diagnostic]
      raise @diagnostic_error if @diagnostic_error
      @diagnostic_future || future({"items" => []})
    end

    private

    def range
      {"start" => {"line" => 0, "character" => 0}, "end" => {"line" => 0, "character" => 0}}
    end

    def future(value) = Sadr::Future.new(object_id).fulfill(value)
  end

  class TrackingFuture
    attr_reader :timeouts
    attr_reader :cancelled

    def initialize(value = nil, error: nil, delay: 0)
      @value, @error, @delay = value, error, delay
      @timeouts, @done, @cancelled = [], false, false
    end

    def await(timeout: nil)
      @timeouts << timeout
      sleep @delay if @delay.positive?
      raise @error if @error
      @done = true
      @value
    end

    def done? = @done
    def cancel
      @cancelled = true
      @done = true
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-multiple-language-servers-")
    @path = File.join(@root, "sample.rb")
    File.binwrite(@path, "value\n")
    @created = []
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root)
  end

  def configure(servers)
    settings = Canopus::Settings.new("language_servers" => {"ruby" => servers})
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    @editor = @workspace.open(@path)
  end

  def factory
    lambda do |**options|
      Client.new(**options).tap { |client| @created << client }
    end
  end

  def clients
    Sadr::Client.stub(:new, factory) { @workspace.language_clients(@editor.buffer) }
  end

  def settle
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    loop do
      @workspace.drain
      jobs = @workspace.instance_variable_get(:@language_jobs) || []
      break if jobs.none?(&:alive?)
      raise "language requests did not settle" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.001
    end
    @workspace.drain
  end

  def settle_reload
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    while @workspace.instance_variable_get(:@language_reload_job)&.alive?
      raise "language settings did not settle" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.001
    end
    @workspace.drain
  end

  def diagnostic(message)
    {"message" => message, "severity" => 1, "range" => {
      "start" => {"line" => 0, "character" => 0}, "end" => {"line" => 0, "character" => 1}
    }}
  end

  def test_ruby_lsp_and_rubocop_route_order_and_synchronize_each_document
    configure([
      {"command" => ["ruby-lsp"], "features" => %w[completion definition formatting]},
      {"command" => ["rubocop", "--lsp"], "features" => %w[diagnostics codeAction]}
    ])

    ruby_lsp, rubocop = clients
    assert_same ruby_lsp, @workspace.clients.fetch("ruby")
    assert_same ruby_lsp, @workspace.language_client(@editor.buffer, feature: "definition")
    assert_same ruby_lsp, @workspace.language_client(@editor.buffer, feature: "formatting")
    assert_equal [rubocop], @workspace.language_clients(@editor.buffer, feature: "diagnostics")
    assert_equal [rubocop], @workspace.language_clients(@editor.buffer, feature: "codeAction")

    @editor.insert_text("x", auto_indent: false)
    @workspace.save_buffer(@editor.buffer)
    assert_equal 1, ruby_lsp.events.count { |event| event.first == :open }
    assert_equal 1, rubocop.events.count { |event| event.first == :open }
    assert_equal 1, ruby_lsp.events.count { |event| event.first == :change }
    assert_equal 1, rubocop.events.count { |event| event.first == :change }
    assert_equal 1, ruby_lsp.events.count { |event| event.first == :save }
    assert_equal 1, rubocop.events.count { |event| event.first == :save }

    @workspace.close_editor(@editor, discard: true)
    assert_equal 1, ruby_lsp.events.count { |event| event.first == :close }
    assert_equal 1, rubocop.events.count { |event| event.first == :close }
  end

  def test_completion_and_code_actions_keep_the_provider_client
    configure([
      {"command" => ["ruby-lsp"], "features" => %w[completion codeAction]},
      {"command" => ["rubocop", "--lsp"], "features" => %w[completion codeAction]}
    ])
    ruby_lsp, rubocop = clients
    ruby_lsp.completions = [{"label" => "Ruby item"}]
    rubocop.completions = [{"label" => "RuboCop item"}]
    context = {metadata: {}, errors: []}

    completions = @workspace.send(:lsp_completions, @editor.buffer, 0, context)

    assert_equal ["Ruby item", "RuboCop item"], completions.map(&:label)
    assert_same ruby_lsp, context[:metadata].fetch(completions[0]).fetch(:client)
    assert_same rubocop, context[:metadata].fetch(completions[1]).fetch(:client)

    shared = {"title" => "Shared action", "kind" => "quickfix"}
    ruby_lsp.actions = [shared]
    rubocop.actions = [shared.dup, {"title" => "RuboCop action", "kind" => "quickfix"}]
    @workspace.language_request(:codeAction)
    settle
    assert_equal ["Shared action", "RuboCop action"], @workspace.palette.fetch(:items).map { |item| item.fetch("title") }
    assert_equal [ruby_lsp, rubocop], @workspace.palette.fetch(:item_clients)
  end

  def test_diagnostics_are_merged_per_uri_without_cross_client_erasure
    configure([
      {"command" => ["ruby-lsp"], "features" => ["diagnostics"]},
      {"command" => ["rubocop", "--lsp"], "features" => ["diagnostics"]}
    ])
    ruby_lsp, rubocop = clients
    uri = Sadr::Protocol.uri(@editor.buffer.path)
    shared = diagnostic("shared")
    @workspace.send(:accept_diagnostic_notification, ruby_lsp,
      "uri" => uri, "version" => @editor.buffer.version, "diagnostics" => [diagnostic("ruby"), shared])
    @workspace.send(:accept_diagnostic_notification, rubocop,
      "uri" => uri, "version" => @editor.buffer.version, "diagnostics" => [shared.dup, diagnostic("rubocop")])
    assert_equal %w[ruby shared rubocop], @workspace.diagnostics_for(@editor.buffer).map { |item| item.fetch("message") }

    @workspace.send(:forget_language_document, ruby_lsp, @editor.buffer)
    assert_equal %w[shared rubocop], @workspace.diagnostics_for(@editor.buffer).map { |item| item.fetch("message") }
    @workspace.send(:clear_client_diagnostics, rubocop, uri)
    assert_empty @workspace.diagnostics_for(@editor.buffer)
  end

  def test_options_are_snapshotted_and_invalid_features_are_rejected
    servers = [
      {"command" => ["ruby-lsp"], "features" => ["completion"]},
      {"command" => ["rubocop", "--lsp"], "features" => ["diagnostics"]}
    ]
    configure(servers)
    started = clients
    servers[0]["command"][0] = "changed"
    servers[0]["features"] << "definition"
    options = @workspace.instance_variable_get(:@client_options).fetch("ruby")
    assert_equal ["ruby-lsp"], options[0].fetch(:command)
    assert_equal ["completion"], options[0].fetch(:features)
    assert options.frozen?
    assert options[0].fetch(:features).frozen?
    assert_same started[0], @workspace.language_client(@editor.buffer, feature: "completion")
    assert_raises(Canopus::Error) { @workspace.language_client(@editor.buffer, feature: "definition") }

    @workspace.close
    @workspace = nil
    configure([{"command" => ["ruby-lsp"], "features" => ["unknown"]}])
    assert_raises(Canopus::Error) { clients }
  end

  def test_legacy_command_and_individual_restart_remain_available
    configure(["ruby-lsp"])
    legacy = clients.first
    assert_same legacy, @workspace.language_client(@editor.buffer, feature: "definition")

    @workspace.close
    @workspace = nil
    @created.clear
    configure([
      {"command" => ["ruby-lsp"], "features" => ["definition"]},
      {"command" => ["rubocop", "--lsp"], "features" => ["diagnostics"]}
    ])
    ruby_lsp, rubocop = clients
    @workspace.show_language_server_restart
    assert_equal :language_servers, @workspace.palette.fetch(:kind)
    assert_equal ["ruby-lsp (running)", "rubocop (running)"], @workspace.palette.fetch(:matches)
    replacement = Sadr::Client.stub(:new, factory) { @workspace.restart_language_server("ruby", 1) }
    assert_same ruby_lsp, @workspace.clients.fetch("ruby")
    refute_same rubocop, replacement
    assert_equal :stopped, rubocop.state
    assert_equal :running, replacement.state
    assert_equal ["ruby-lsp", "rubocop"], @workspace.language_server_states("ruby").map { |state| state.fetch(:name) }
    assert_equal [:running, :running], @workspace.language_server_states("ruby").map { |state| state.fetch(:state) }
  end

  def test_partial_startup_failure_stops_every_replacement
    configure([
      {"command" => ["ruby-lsp"], "features" => ["definition"]},
      {"command" => ["broken"], "features" => ["diagnostics"]}
    ])

    assert_raises(Canopus::Error) { clients }
    assert_equal 2, @created.length
    assert @created.all? { |client| client.state == :stopped }
    assert_empty @workspace.clients
  end

  def test_feature_changes_reroute_without_restarting_processes
    configure([
      {"command" => ["ruby-lsp"], "features" => ["definition"]},
      {"command" => ["rubocop", "--lsp"], "features" => ["diagnostics"]}
    ])
    ruby_lsp, rubocop = clients
    @workspace.settings.merge!("language_servers" => {"ruby" => [
      {"command" => ["ruby-lsp"], "features" => ["completion"]},
      {"command" => ["rubocop", "--lsp"], "features" => %w[diagnostics definition]}
    ]})

    Sadr::Client.stub(:new, factory) do
      @workspace.apply_settings
      settle_reload
    end

    assert_equal 2, @created.length
    assert_same ruby_lsp, @workspace.clients.fetch("ruby")
    assert_same rubocop, @workspace.language_client(@editor.buffer, feature: "definition")
    assert_equal :running, ruby_lsp.state
  end

  def test_failed_configuration_notification_preserves_every_running_client
    configure([
      {"command" => ["ruby-lsp"], "configuration" => {"mode" => "old"}},
      {"command" => ["rubocop", "--lsp"], "configuration" => {"mode" => "old"}}
    ])
    ruby_lsp, rubocop = clients
    rubocop.configuration_error = Canopus::Error.new("configuration failed")
    @workspace.settings.merge!("language_servers" => {"ruby" => [
      {"command" => ["ruby-lsp"], "configuration" => {"mode" => "new"}},
      {"command" => ["rubocop", "--lsp"], "configuration" => {"mode" => "new"}}
    ]})

    Sadr::Client.stub(:new, factory) do
      @workspace.apply_settings
      settle_reload
    end

    assert_equal [ruby_lsp, rubocop], @workspace.send(:language_client_list, "ruby")
    assert_same ruby_lsp, @workspace.clients.fetch("ruby")
    assert_equal %i[running running], [ruby_lsp.state, rubocop.state]
    assert_equal 2, @created.length
    assert_includes @workspace.message, "configuration failed"
  end

  def test_full_reload_unroutes_old_client_and_accepts_diagnostics_published_during_open
    configure([{"command" => ["old"], "features" => ["diagnostics"]}])
    old = clients.first
    routed_while_stopping = :not_checked
    old.before_stop = -> { routed_while_stopping = @workspace.clients["ruby"] }
    @workspace.settings.merge!("language_servers" => {"ruby" => [
      {"command" => ["new"], "features" => ["diagnostics"]}
    ]})
    replacement_factory = lambda do |**options|
      Client.new(**options).tap do |client|
        @created << client
        client.publish_on_open = lambda do |document|
          client.handlers.fetch("textDocument/publishDiagnostics").call(
            "uri" => document.uri, "version" => document.version, "diagnostics" => [diagnostic("initial")])
        end
      end
    end

    Sadr::Client.stub(:new, replacement_factory) do
      @workspace.apply_settings
      settle_reload
    end

    assert_nil routed_while_stopping
    assert_equal :stopped, old.state
    assert_equal ["initial"], @workspace.diagnostics_for(@editor.buffer).map { |item| item.fetch("message") }
  end

  def test_full_reload_tracks_a_client_whose_stop_failed_until_close_retries_it
    configure([{"command" => ["old"], "features" => ["definition"]}])
    old = clients.first
    old.stop_failures = 1
    @workspace.settings.merge!("language_servers" => {"ruby" => [
      {"command" => ["new"], "features" => ["definition"]}
    ]})

    Sadr::Client.stub(:new, factory) do
      @workspace.apply_settings
      settle_reload
    end

    assert_empty @workspace.clients
    assert_equal :running, old.state
    assert @workspace.instance_variable_get(:@retiring_language_clients).key?(old)
    assert_equal 1, @created.length
    assert_includes @workspace.message, "stop failed"

    @workspace.close
    assert_equal :stopped, old.state
    assert_equal 2, old.events.count { |event| event.first == :stop }
    refute @workspace.instance_variable_get(:@retiring_language_clients).key?(old)
    @workspace = nil
  end

  def test_reload_open_failure_cleans_every_replacement
    configure([{"command" => ["old"], "features" => ["definition"]}])
    old = clients.first
    @workspace.settings.merge!("language_servers" => {"ruby" => [
      {"command" => ["new-a"], "features" => ["definition"]},
      {"command" => ["new-b"], "features" => ["diagnostics"]}
    ]})
    replacement_factory = lambda do |**options|
      Client.new(**options).tap do |client|
        @created << client
        client.open_error = Canopus::Error.new("open failed") if client.command.first == "new-b"
      end
    end

    Sadr::Client.stub(:new, replacement_factory) do
      @workspace.apply_settings
      settle_reload
    end

    assert_equal :stopped, old.state
    assert @created.drop(1).all? { |client| client.state == :stopped }
    assert_empty @workspace.clients
    assert_includes @workspace.message, "open failed"
  end

  def test_individual_restart_open_failure_rolls_back_routing
    configure([
      {"command" => ["ruby-lsp"], "features" => ["definition"]},
      {"command" => ["rubocop", "--lsp"], "features" => ["diagnostics"]}
    ])
    original = clients
    replacement_factory = lambda do |**options|
      Client.new(**options).tap do |client|
        @created << client
        client.open_error = Canopus::Error.new("restart open failed")
      end
    end

    assert_raises(Canopus::Error) do
      Sadr::Client.stub(:new, replacement_factory) { @workspace.restart_language_server("ruby", 1) }
    end

    assert_equal original, @workspace.language_clients(@editor.buffer)
    assert_same original.first, @workspace.clients.fetch("ruby")
    assert_equal %i[running running stopped], @created.map(&:state)
  end

  def test_individual_restart_tracks_the_replaced_client_when_stop_fails
    configure([
      {"command" => ["ruby-lsp"], "features" => ["definition"]},
      {"command" => ["rubocop", "--lsp"], "features" => ["diagnostics"]}
    ])
    ruby_lsp, rubocop = clients
    rubocop.stop_failures = 1

    assert_raises(Canopus::Error) do
      Sadr::Client.stub(:new, factory) { @workspace.restart_language_server("ruby", 1) }
    end
    replacement = @created.last

    assert_equal [ruby_lsp, replacement], @workspace.send(:language_client_list, "ruby")
    refute_includes @workspace.send(:language_client_list, "ruby"), rubocop
    assert_equal :running, rubocop.state
    assert @workspace.instance_variable_get(:@retiring_language_clients).key?(rubocop)

    @workspace.close
    assert_equal :stopped, rubocop.state
    assert_equal 2, rubocop.events.count { |event| event.first == :stop }
    refute @workspace.instance_variable_get(:@retiring_language_clients).key?(rubocop)
    assert_equal :stopped, replacement.state
    @workspace = nil
  end

  def test_removing_diagnostics_feature_clears_only_that_clients_snapshot
    configure([
      {"command" => ["ruby-lsp"], "features" => ["diagnostics"]},
      {"command" => ["rubocop", "--lsp"], "features" => ["diagnostics"]}
    ])
    ruby_lsp, rubocop = clients
    uri = Sadr::Protocol.uri(@editor.buffer.path)
    @workspace.send(:accept_diagnostic_notification, ruby_lsp,
      "uri" => uri, "version" => @editor.buffer.version, "diagnostics" => [diagnostic("ruby")])
    @workspace.send(:accept_diagnostic_notification, rubocop,
      "uri" => uri, "version" => @editor.buffer.version, "diagnostics" => [diagnostic("rubocop")])
    @workspace.settings.merge!("language_servers" => {"ruby" => [
      {"command" => ["ruby-lsp"], "features" => ["completion"]},
      {"command" => ["rubocop", "--lsp"], "features" => ["diagnostics"]}
    ]})

    Sadr::Client.stub(:new, factory) do
      @workspace.apply_settings
      settle_reload
    end

    assert_equal ["rubocop"], @workspace.diagnostics_for(@editor.buffer).map { |item| item.fetch("message") }
    assert_nil @workspace.instance_variable_get(:@lsp_diagnostics)[ruby_lsp]
    assert_same rubocop, @workspace.language_clients(@editor.buffer, feature: "diagnostics").first
    assert_equal 2, @created.length
  end

  def test_save_code_actions_isolate_clients_and_report_the_first_error_only_when_all_fail
    configure([
      {"command" => ["first"], "features" => ["codeAction"]},
      {"command" => ["second"], "features" => ["codeAction"]}
    ])
    first, second = clients
    @workspace.settings.merge!("code_actions_on_save" => ["source.fixAll"])
    first.code_action_error = Canopus::Error.new("first failed")
    second.actions = [{"title" => "second", "kind" => "source.fixAll"}]
    @editor.insert_text("x", auto_indent: false)

    @workspace.save_buffer(@editor.buffer)

    assert_equal 1, first.events.count { |event| event.first == :code_action }
    assert_equal 1, second.events.count { |event| event.first == :code_action }
    assert_empty @workspace.notifications
    assert_equal @editor.buffer.text, File.read(@path)

    second.code_action_error = Canopus::Error.new("second failed")
    @editor.insert_text("y", auto_indent: false)
    @workspace.save_buffer(@editor.buffer)
    assert_includes @workspace.notifications.last.fetch(:text), "first failed"
    assert_equal @editor.buffer.text, File.read(@path)
  end

  def test_aggregate_requests_share_deadlines_and_completion_cancels_failed_futures
    configure([
      {"command" => ["first"], "features" => %w[completion diagnostics codeAction]},
      {"command" => ["second"], "features" => %w[completion diagnostics codeAction]}
    ])
    first, second = clients
    first.code_action_future = TrackingFuture.new([{"title" => "first", "kind" => "quickfix"}], delay: 0.02)
    second.code_action_future = TrackingFuture.new([])
    @workspace.language_request(:codeAction)
    settle
    assert_operator second.code_action_future.timeouts.first, :<, first.code_action_future.timeouts.first

    first.diagnostic_future = TrackingFuture.new({"items" => []}, delay: 0.02)
    second.diagnostic_future = TrackingFuture.new({"items" => []})
    @workspace.language_request(:diagnostic)
    settle
    assert_operator second.diagnostic_future.timeouts.first, :<, first.diagnostic_future.timeouts.first

    first.completion_future = TrackingFuture.new(error: Canopus::Error.new("completion failed"), delay: 0.02)
    second.completion_future = TrackingFuture.new([])
    context = {metadata: {}, errors: []}
    assert_empty @workspace.send(:lsp_completions, @editor.buffer, 0, context)
    assert first.completion_future.cancelled
    assert_operator second.completion_future.timeouts.first, :<, first.completion_future.timeouts.first
  end

  def test_object_without_features_uses_capabilities_and_legacy_transition_reuses_process
    received = []
    configure({"command" => ["server"]})
    capturing_factory = lambda do |**options|
      received << options
      Client.new(**options).tap { |client| @created << client }
    end
    client = Sadr::Client.stub(:new, capturing_factory) { @workspace.language_clients(@editor.buffer).first }
    client.capabilities.delete("definitionProvider")

    assert_raises(Canopus::Error) { @workspace.language_client(@editor.buffer, feature: "definition") }
    assert_same client, @workspace.language_client(@editor.buffer, feature: "completion")
    refute_includes received.first.keys, :features
    refute_includes received.first.keys, :legacy

    @workspace.settings.merge!("language_servers" => {"ruby" => ["server"]})
    Sadr::Client.stub(:new, capturing_factory) do
      @workspace.apply_settings
      settle_reload
    end
    assert_same client, @workspace.language_client(@editor.buffer, feature: "definition")
    assert_equal 1, @created.length
  end

  def test_settings_reject_symbol_server_keys_before_snapshot_and_enforce_one_mib_limit
    assert_raises(Canopus::Error) do
      Canopus::Settings.new("language_servers" => {ruby: {"command" => ["server"]}})
    end
    assert_raises(Canopus::Error) do
      Canopus::Settings.new("language_servers" => {"ruby" => {command: ["server"]}})
    end
    assert_raises(Canopus::Error) do
      Canopus::Settings.new("language_servers" => {"ruby" => {"command" => ["server"], "env" => {HOME: "x"}}})
    end

    configure(["server"])
    options = {"command" => ["server"], "initialization_options" => {"data" => ""}}
    options["initialization_options"]["data"] = "x" * ((1 << 20) - JSON.generate(options).bytesize)
    assert_equal 1 << 20, JSON.generate(options).bytesize
    @workspace.send(:normalize_server_options, options)
    options["initialization_options"]["data"] << "x"
    assert_raises(Canopus::Error) { @workspace.send(:normalize_server_options, options) }
  end
end

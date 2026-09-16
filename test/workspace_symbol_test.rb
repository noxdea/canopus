# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class WorkspaceSymbolTest < Minitest::Test
  class Future
    attr_reader :timeouts, :cancelled

    def initialize(value = nil, error: nil, delay: 0)
      @value, @error, @delay = value, error, delay
      @timeouts, @done = [], false
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

  class BlockingFuture < Future
    attr_reader :entered

    def initialize(value = nil)
      super(value)
      @entered, @release = Queue.new, Queue.new
    end

    def await(timeout: nil)
      @timeouts << timeout
      @entered << true
      @release.pop
      raise Sadr::Timeout, "cancelled" if @cancelled
      @done = true
      @value
    end

    def cancel
      return if @done || @cancelled
      @cancelled = true
      @release << true
    end

    def release = @release << true
  end

  class Client
    attr_reader :capabilities, :queries
    attr_accessor :future, :available

    def initialize(capabilities = {"workspaceSymbolProvider" => true})
      @capabilities, @queries, @available = capabilities, [], true
      @future = Future.new([])
    end

    def workspace_symbols(query)
      @queries << query
      @future
    end

    def running? = @available
    def stop = @available = false
  end

  class SequenceClient < Client
    def initialize(futures, capabilities = {"workspaceSymbolProvider" => true})
      super(capabilities)
      @futures = futures
    end

    def workspace_symbols(query)
      @queries << query
      @futures.shift || raise("unexpected workspace symbol request")
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-workspace-symbol-")
    FileUtils.mkdir_p(File.join(@root, "lib"))
    File.write(File.join(@root, "lib", "alpha.rb"), "alpha\n")
    File.write(File.join(@root, "lib", "beta.rb"), "beta\n")
    File.write(File.join(@root, "lib", "gamma.rb"), "gamma\n")
    @workspace = Canopus::Workspace.new(root: @root)
    @workspace.open("lib/alpha.rb")
  end

  def teardown
    @workspace&.close
    (@workspace&.instance_variable_get(:@language_jobs) || []).each { |job| job.join(3) }
    FileUtils.remove_entry(@root)
  end

  def location(name, path, line: 0, character: 0, container: nil)
    value = {"name" => name, "kind" => 12, "location" => {
      "uri" => Sadr::Protocol.uri(File.join(@root, path)), "range" => {
        "start" => {"line" => line, "character" => character},
        "end" => {"line" => line, "character" => character}
      }
    }}
    value["containerName"] = container if container
    value
  end

  def install_clients(mapping, options)
    @workspace.instance_variable_set(:@language_clients, mapping.transform_values { |clients| clients.freeze })
    @workspace.instance_variable_set(:@client_options, options)
    mapping.each { |language, clients| @workspace.clients[language] = clients.first }
  end

  def settle(job)
    assert job.join(15), "workspace symbol search did not finish"
    @workspace.drain
  end

  def test_active_routed_servers_are_merged_deduplicated_and_filtered_in_configuration_order
    ruby_lsp, rubocop, excluded, text_server = 4.times.map { Client.new }
    shared = location("Shared", "lib/alpha.rb", container: "Root")
    ruby_lsp.future = Future.new([location("Alpha", "lib/alpha.rb"), shared], delay: 0.02)
    rubocop.future = Future.new([shared.dup, location("Beta", "lib/beta.rb")])
    excluded.future = Future.new([location("Excluded", "lib/beta.rb")])
    text_server.future = Future.new([location("Gamma", "lib/gamma.rb")])
    install_clients({"ruby" => [ruby_lsp, rubocop, excluded], "text" => [text_server]}, {
      "ruby" => [
        {features: ["workspaceSymbol"], legacy: false},
        {features: ["workspaceSymbol"], legacy: false},
        {features: ["completion"], legacy: false}
      ],
      "text" => [{features: nil, legacy: false}]
    })

    settle(@workspace.request_workspace_symbols("a"))

    assert_equal %w[Alpha Shared Beta Gamma], @workspace.palette.fetch(:items).map { |item| item.fetch("name") }
    assert_equal ["Alpha alpha.rb:1", "Shared — Root alpha.rb:1", "Beta beta.rb:1", "Gamma gamma.rb:1"],
      @workspace.palette.fetch(:matches)
    assert_equal [0, 1, 2, 3], @workspace.palette.fetch(:indices)
    assert_equal ["a"], ruby_lsp.queries
    assert_equal ["a"], rubocop.queries
    assert_empty excluded.queries
    assert_equal ["a"], text_server.queries
    assert_operator rubocop.future.timeouts.first, :<, ruby_lsp.future.timeouts.first
    assert_operator text_server.future.timeouts.first, :<, ruby_lsp.future.timeouts.first

    @workspace.palette[:query] = "gm"
    @workspace.update_palette
    assert_equal ["Gamma gamma.rb:1"], @workspace.palette.fetch(:matches)
    @workspace.palette_accept
    assert_equal File.realpath(File.join(@root, "lib", "gamma.rb")), @workspace.editor.buffer.path
    assert_equal 0, @workspace.editor.primary.head
  end

  def test_duplicate_labels_keep_original_indices_and_jump_to_the_selected_target
    %w[left right].each do |directory|
      FileUtils.mkdir_p(File.join(@root, directory))
      File.write(File.join(@root, directory, "shared.rb"), directory)
    end
    client = Client.new
    client.future = Future.new([
      location("Twin", "left/shared.rb"), location("Twin", "right/shared.rb")
    ])
    install_clients({"ruby" => [client]}, {"ruby" => [{features: ["workspaceSymbol"], legacy: false}]})

    settle(@workspace.request_workspace_symbols("Twin"))

    assert_equal [0, 1], @workspace.palette.fetch(:indices)
    assert_equal ["Twin shared.rb:1", "Twin shared.rb:1"], @workspace.palette.fetch(:matches)
    @workspace.palette[:query] = "twn"
    @workspace.update_palette
    assert_equal [0, 1], @workspace.palette.fetch(:indices)
    assert_equal ["Twin shared.rb:1", "Twin shared.rb:1"], @workspace.palette.fetch(:matches)
    @workspace.palette[:index] = 1
    @workspace.palette_accept
    assert_equal File.realpath(File.join(@root, "right", "shared.rb")), @workspace.editor.buffer.path
  end

  def test_duplicates_from_an_earlier_provider_do_not_consume_the_combined_limit
    first, second = Client.new, Client.new
    repeated = location("Shared", "lib/alpha.rb")
    first.future = Future.new(Array.new(10_000, repeated))
    second.future = Future.new([location("Later", "lib/beta.rb")])
    install_clients({"ruby" => [first, second]}, {"ruby" => [
      {features: ["workspaceSymbol"], legacy: false}, {features: ["workspaceSymbol"], legacy: false}
    ]})

    settle(@workspace.request_workspace_symbols("symbol"))

    assert_equal %w[Shared Later], @workspace.palette.fetch(:items).map { |item| item.fetch("name") }
    assert_equal [0, 1], @workspace.palette.fetch(:indices)
  end

  def test_no_provider_and_unavailable_provider_use_bounded_alkaid_fallback
    File.write(File.join(@root, "lib", "example.rb"), "日本 ExampleSymbol\n")
    File.write(File.join(@root, "ignored.rb"), "ExampleSymbol\n")
    File.write(File.join(@root, ".gitignore"), "ignored.rb\n")
    unsupported = Client.new({})
    unavailable = Client.new
    unavailable.available = false
    install_clients({"ruby" => [unsupported, unavailable]}, {"ruby" => [
      {features: nil, legacy: false}, {features: ["workspaceSymbol"], legacy: false}
    ]})

    settle(@workspace.request_workspace_symbols("ExampleSymbol"))

    assert_empty unsupported.queries
    assert_empty unavailable.queries
    assert_equal ["example.rb"], @workspace.palette.fetch(:items).map { |item| File.basename(Sadr::Protocol.path(item.dig("location", "uri"))) }
    item = @workspace.palette.fetch(:items).first
    assert_equal 3, item.dig("location", "range", "start", "character")
    @workspace.palette_accept
    assert_equal "日本 ".bytesize, @workspace.editor.primary.head
  end

  def test_failed_provider_falls_back_without_blocking_the_foreground
    client = Client.new
    client.future = Future.new(error: Canopus::Error.new("server unavailable"))
    install_clients({"ruby" => [client]}, {"ruby" => [{features: ["workspaceSymbol"], legacy: false}]})
    File.write(File.join(@root, "lib", "example.rb"), "FallbackName\n")

    job = @workspace.request_workspace_symbols("FallbackName")
    assert_instance_of Thread, job
    settle(job)

    assert_equal ["FallbackName"], client.queries
    assert_equal ["example.rb"], @workspace.palette.fetch(:items).map { |item| File.basename(Sadr::Protocol.path(item.dig("location", "uri"))) }
  end

  def test_fallback_runs_off_thread_and_queries_and_results_are_bounded
    entered, release = Queue.new, Queue.new
    @workspace.define_singleton_method(:workspace_symbol_fallback) do |_query, _generation, _deadline|
      entered << Thread.current
      release.pop
      []
    end

    job = @workspace.request_workspace_symbols("name")
    worker = entered.pop
    refute_equal Thread.current, worker
    assert job.alive?
    release << true
    settle(job)
    assert_raises(Canopus::Error) { @workspace.request_workspace_symbols("") }
    assert_raises(Canopus::Error) { @workspace.request_workspace_symbols("x" * 257) }
    assert_raises(Canopus::Error) { @workspace.request_workspace_symbols("bad\nquery") }
    assert_raises(Canopus::Error) do
      @workspace.send(:normalize_workspace_symbols, Array.new(10_001) { {} })
    end
  ensure
    release << true if release
  end

  def test_new_query_immediately_cancels_the_previous_provider_future
    first = BlockingFuture.new([location("Old", "lib/alpha.rb")])
    second = Future.new([location("New", "lib/beta.rb")])
    client = SequenceClient.new([first, second])
    install_clients({"ruby" => [client]}, {"ruby" => [{features: ["workspaceSymbol"], legacy: false}]})

    old_job = @workspace.request_workspace_symbols("old")
    first.entered.pop
    new_job = @workspace.request_workspace_symbols("new")

    assert first.cancelled
    settle(old_job)
    settle(new_job)
    assert_equal %w[old new], client.queries
    assert_equal ["New"], @workspace.palette.fetch(:items).map { |item| item.fetch("name") }
  end

  def test_loading_palette_accepts_input_and_backspace_and_carries_the_filter_to_results
    future = BlockingFuture.new([location("Alpha", "lib/alpha.rb"), location("Gamma", "lib/gamma.rb")])
    client = Client.new
    client.future = future
    install_clients({"ruby" => [client]}, {"ruby" => [{features: ["workspaceSymbol"], legacy: false}]})
    window = Zaniah::Platform.open_window(backend: :headless, width: 400, height: 300)
    controller = Canopus::Controller.new(@workspace, window)
    job = @workspace.request_workspace_symbols("symbols")
    future.entered.pop

    controller.input(Zaniah::Input::TextInput.new("gm"))
    controller.input(Zaniah::Input::KeyDown.new("backspace", false))
    controller.input(Zaniah::Input::TextInput.new("m"))
    assert_equal "gm", @workspace.palette.fetch(:query)
    assert_empty @workspace.palette.fetch(:matches)

    future.release
    settle(job)
    assert_equal "gm", @workspace.palette.fetch(:query)
    assert_equal ["Gamma gamma.rb:1"], @workspace.palette.fetch(:matches)
    assert_equal [1], @workspace.palette.fetch(:indices)
  ensure
    window&.on_close { true }
    window&.close
  end

  def test_palette_replacement_and_settings_reload_cancel_stale_results
    first, second = BlockingFuture.new, BlockingFuture.new
    client = SequenceClient.new([first, second])
    install_clients({"ruby" => [client]}, {"ruby" => [{features: ["workspaceSymbol"], legacy: false}]})

    replaced = @workspace.request_workspace_symbols("replace")
    first.entered.pop
    @workspace.palette_open(:files)
    assert first.cancelled
    assert replaced.join(3)
    @workspace.drain
    assert_equal :files, @workspace.palette.fetch(:kind)

    reloaded = @workspace.request_workspace_symbols("reload")
    second.entered.pop
    @workspace.stub(:language_server_settings_plan, {}) { @workspace.apply_settings }
    assert second.cancelled
    assert reloaded.join(3)
    @workspace.drain
    assert_nil @workspace.palette
  end

  def test_palette_dismissal_cancels_a_stale_result
    future = BlockingFuture.new
    client = Client.new
    client.future = future
    install_clients({"ruby" => [client]}, {"ruby" => [{features: ["workspaceSymbol"], legacy: false}]})
    job = @workspace.request_workspace_symbols("dismiss")
    future.entered.pop

    @workspace.palette = nil

    assert future.cancelled
    assert job.join(3)
    @workspace.drain
    assert_nil @workspace.palette
  end

  def test_routing_invalidation_cancels_a_stale_result
    future = BlockingFuture.new
    client = Client.new
    client.future = future
    install_clients({"ruby" => [client]}, {"ruby" => [{features: ["workspaceSymbol"], legacy: false}]})
    job = @workspace.request_workspace_symbols("routing")
    future.entered.pop

    @workspace.send(:invalidate_language_client_features, "ruby", client)

    assert future.cancelled
    assert job.join(3)
    @workspace.drain
    assert_nil @workspace.palette
  end

  def test_palette_replacement_cannot_complete_between_current_check_and_result_install
    client = Client.new
    client.future = Future.new([location("Stale", "lib/alpha.rb")])
    install_clients({"ruby" => [client]}, {"ruby" => [{features: ["workspaceSymbol"], legacy: false}]})
    job = @workspace.request_workspace_symbols("stale")
    assert job.join(3)

    checked, release, cancel_entered, cancel_done = 4.times.map { Queue.new }
    current = @workspace.method(:workspace_symbol_request_current?)
    @workspace.define_singleton_method(:workspace_symbol_request_current?) do |request|
      result = current.call(request)
      if result && Thread.current[:workspace_symbol_install_probe]
        checked << true
        release.pop
      end
      result
    end
    cancel = @workspace.method(:cancel_workspace_symbol_search)
    @workspace.define_singleton_method(:cancel_workspace_symbol_search) do
      cancel_entered << true
      result = cancel.call
      cancel_done << true
      result
    end

    installer = Thread.new do
      Thread.current[:workspace_symbol_install_probe] = true
      @workspace.drain
    end
    checked.pop
    replacement = Thread.new { @workspace.palette_open(:files) }
    cancel_entered.pop
    assert_raises(ThreadError) { cancel_done.pop(true) }
    release << true
    assert installer.join(3)
    assert replacement.join(3)
    assert cancel_done.pop
    assert_equal :files, @workspace.palette.fetch(:kind)
  ensure
    release << true if release
    installer&.join(3)
    replacement&.join(3)
  end

  def test_close_cancels_a_pending_result
    future = BlockingFuture.new
    client = Client.new
    client.future = future
    install_clients({"ruby" => [client]}, {"ruby" => [{features: ["workspaceSymbol"], legacy: false}]})
    job = @workspace.request_workspace_symbols("close")
    future.entered.pop

    @workspace.close

    assert future.cancelled
    assert job.join(3)
    assert_nil @workspace.palette
    @workspace = nil
  end

  def test_large_result_labels_and_spica_index_are_prepared_off_the_main_thread
    client = Client.new
    client.future = Future.new(Array.new(10_000) do |index|
      location("#{index}-#{'x' * 1_000}", "lib/alpha.rb")
    end)
    install_clients({"ruby" => [client]}, {"ruby" => [{features: ["workspaceSymbol"], legacy: false}]})
    prepared_on = Queue.new
    original = @workspace.method(:prepare_workspace_symbol_palette)
    @workspace.define_singleton_method(:prepare_workspace_symbol_palette) do |*arguments|
      prepared_on << Thread.current
      original.call(*arguments)
    end

    settle(@workspace.request_workspace_symbols("x"))

    refute_equal Thread.current, prepared_on.pop
    assert_equal 10_000, @workspace.palette.fetch(:all_matches).length
    assert_equal((0...12).to_a, @workspace.palette.fetch(:indices))
    assert_equal 12, @workspace.palette.fetch(:matches).length
    limit = Canopus::Workspace::LanguageAware::WORKSPACE_SYMBOL_LABEL_BYTES
    assert @workspace.palette.fetch(:all_matches).all? { |label| label.bytesize <= limit }
    refute @workspace.palette.key?(:search)
  end

  def test_large_single_line_fallback_bounds_preview_and_checks_cancellation_during_conversion
    File.write(File.join(@root, "large.rb"), "placeholder")
    line = "a" * (10 * 1024 * 1024)
    line.define_singleton_method(:gsub) { |*| raise "whole line scanned" }
    preview_match = Alkaid::Match.new(path: "large.rb", line_number: 1, byte_offset: 128,
      line: line, ranges: [128...132])
    symbol = @workspace.send(:fallback_workspace_symbol, preview_match)
    assert_operator symbol.fetch("name").bytesize, :<=, 512

    late_match = Alkaid::Match.new(path: "large.rb", line_number: 1, byte_offset: line.bytesize - 8,
      line: line, ranges: [(line.bytesize - 8)...(line.bytesize - 4)])
    matches = Array.new(10_000, late_match)
    checks = 0
    cancellation = lambda do |_generation, _deadline|
      checks += 1
      checks > 4
    end
    result = @workspace.stub(:project_search_matches, ->(*, **) { matches }) do
      @workspace.stub(:workspace_symbol_cancelled?, cancellation) do
        @workspace.send(:workspace_symbol_fallback, "aaaa", 1, Float::INFINITY)
      end
    end
    assert_empty result
    assert_operator checks, :<=, 8
  end

  def test_fallback_rejects_a_canonical_path_outside_the_project
    outside = Dir.mktmpdir("canopus-workspace-symbol-outside-")
    path = File.join(outside, "outside.rb")
    File.write(path, "Outside\n")
    relative = File.join("..", File.basename(outside), "outside.rb")
    match = Alkaid::Match.new(path: relative, line_number: 1, byte_offset: 0,
      line: "Outside\n", ranges: [0...7])
    assert_nil @workspace.send(:fallback_workspace_symbol, match)
  ensure
    FileUtils.remove_entry(outside) if outside && File.directory?(outside)
  end
end

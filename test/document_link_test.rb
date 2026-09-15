# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class DocumentLinkTest < Minitest::Test
  class Client
    attr_reader :capabilities, :requests, :resolves, :stopped

    def initialize(*results, resolve: [], provider: {"resolveProvider" => false})
      @capabilities = {"documentLinkProvider" => provider}
      @results, @resolve_results, @requests, @resolves = results, resolve, [], []
    end

    def start = self
    def stop = @stopped = true
    def running? = true
    def state = :running
    def on(*) = nil
    def open(*) = nil
    def change(*) = nil
    def close(*) = nil
    def did_change_configuration(*) = nil
    def diagnostics = {}
    def document_link(uri)
      @requests << uri
      future(@results.shift || [])
    end
    def resolve_document_link(link)
      @resolves << link
      future(@resolve_results.shift)
    end

    private

    def future(result)
      result.respond_to?(:await) ? result : Sadr::Future.new(@requests.length + @resolves.length).fulfill(result)
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-document-link-")
    @path = File.join(@root, "source.rb")
    File.write(@path, "😀web local\n")
    settings = Canopus::Settings.new("language_servers" => {"ruby" => ["fake"]})
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    @editor = @workspace.open(@path)
    @window = Zaniah::Platform.open_window(backend: :headless, width: 640, height: 220)
    @controller = Canopus::Controller.new(@workspace, @window)
  end

  def teardown
    @workspace.close
    @window.on_close { true }
    @window.close
    FileUtils.remove_entry(@root)
  end

  def test_visible_links_use_utf16_highlight_decorations_and_click_regions
    links = [link(2, 5, target: "https://example.test/docs", tooltip: "Open docs")]
    with_client(Client.new(links)) do |client|
      @controller.poll_language_documents
      settle

      items = decorations
      assert_equal [4...7], items.map(&:range)
      assert items.all? { |item| item.kind == :highlight && item.source == :document_link && item.on_click }
      assert_equal [Sadr::Protocol.uri(File.realpath(@path))], client.requests

      opened = []
      @window.define_singleton_method(:open_url) { |target| opened << target }
      @window.request_frame
      @controller.tick
      bounds, = @controller.view.regions.find { |_area, action| action.first == :decoration && action[2].equal?(@editor) }
      @controller.input(Zaniah::Input::MouseDown.new(position: Zaniah::Point.new(bounds.x + 1, bounds.y + 1),
        button: :left, modifiers: [], click_count: 1))
      assert_equal ["https://example.test/docs"], opened
    end
  end

  def test_click_regions_do_not_extend_past_the_link_end
    links = [{"range" => {"start" => point(0), "end" => point(0, line: 1)},
      "target" => "https://example.test/docs"}]
    with_client(Client.new(links)) do
      @controller.poll_language_documents
      settle
      @window.request_frame
      @controller.tick

      regions = @controller.view.regions.select do |_area, action|
        action.first == :decoration && action[2].equal?(@editor)
      end
      assert_equal 1, regions.length
    end
  end

  def test_unresolved_link_is_resolved_on_click_and_range_cannot_move
    unresolved = link(2, 5, data: {"id" => 1})
    resolved = unresolved.merge("target" => "https://example.test/resolved")
    with_client(Client.new([unresolved], resolve: [resolved], provider: {"resolveProvider" => true})) do |client|
      assert @workspace.request_document_links(@editor)
      settle
      opened = []
      @window.define_singleton_method(:open_url) { |target| opened << target }

      assert decorations.first.on_click.call(@editor, 4)
      settle

      assert_equal 1, client.resolves.length
      assert_equal ["https://example.test/resolved"], opened
    end

    moved = resolved.merge("range" => range(6, 11))
    replacement = Client.new([unresolved], resolve: [moved], provider: {"resolveProvider" => true})
    replace_client(replacement)
    assert @workspace.request_document_links(@editor)
    settle
    assert decorations.first.on_click.call(@editor, 4)
    settle
    assert_match(/moved/, @workspace.message)
  end

  def test_split_editors_keep_separate_snapshots_and_edits_cancel_resolution
    unresolved = link(2, 5, data: {"id" => 1})
    cancelled = []
    pending = Sadr::Future.new(9) { |id| cancelled << id }
    client = Client.new([unresolved], [unresolved], resolve: [pending], provider: {"resolveProvider" => true})
    with_client(client) do
      @workspace.split(:horizontal)
      second = @workspace.editor
      @controller.poll_language_documents
      settle
      assert_equal 2, client.requests.length
      assert_equal [4...7], decorations.map(&:range)
      assert_equal [4...7], @workspace.decorations.items_for(second.buffer, 0...1, context: second)
        .select { |item| item.source == :document_link }.map(&:range)

      assert decorations.first.on_click.call(@editor, 4)
      wait_until { client.resolves.length == 1 }
      @editor.insert_text("x", auto_indent: false)
      assert_equal [9], cancelled
      settle
      assert_empty(@workspace.instance_variable_get(:@document_link_cache) || {})
    end
  end

  def test_local_file_links_open_files_and_unsafe_schemes_are_rejected
    target = File.join(@root, "target.rb")
    File.write(target, "target\n")
    with_client(Client.new([link(6, 11, target: Sadr::Protocol.uri(target))])) do
      assert @workspace.request_document_links(@editor)
      settle
      assert decorations.first.on_click.call(@editor, 8)
      assert_equal File.realpath(target), @workspace.editor.buffer.path
      assert_equal 0, @workspace.editor.primary.head
    end

    normalize = ->(value) { @workspace.send(:normalize_document_links, @editor.buffer.rope, value, resolve: false) }
    ["javascript:alert(1)", "command:run", "file://remote/private"].each do |target_uri|
      assert_raises(Canopus::Error) { normalize.call([{"range" => range(0, 1), "target" => target_uri}]) }
    end
  end

  def test_edit_hide_and_client_retirement_cancel_pending_requests
    cancelled = []
    first = Sadr::Future.new(1) { |id| cancelled << id }
    client = Client.new(first)
    with_client(client) do
      assert @workspace.request_document_links(@editor)
      wait_until { client.requests.length == 1 }
      @editor.insert_text("x", auto_indent: false)
      assert_equal [1], cancelled

      second = Sadr::Future.new(2) { |id| cancelled << id }
      client.instance_variable_get(:@results) << second
      assert @workspace.request_document_links(@editor)
      wait_until { client.requests.length == 2 }
      other = File.join(@root, "other.rb")
      File.write(other, "other\n")
      @workspace.open(other)
      assert_equal [1, 2], cancelled

      @workspace.activate_tab(@workspace.active_pane, @editor)
      third = Sadr::Future.new(3) { |id| cancelled << id }
      client.instance_variable_get(:@results) << third
      assert @workspace.request_document_links(@editor)
      wait_until { client.requests.length == 3 }
      replace_client(Client.new([]))
      assert_equal [1, 2, 3], cancelled
      assert client.stopped
    end
  end

  def test_capability_change_discards_a_pending_response
    pending = Sadr::Future.new(1)
    client = Client.new(pending, provider: {"resolveProvider" => true})
    with_client(client) do
      assert @workspace.request_document_links(@editor)
      wait_until { client.requests.length == 1 }
      client.capabilities["documentLinkProvider"]["resolveProvider"] = false
      pending.fulfill([link(2, 5, data: {"id" => 1})])
      settle

      assert_empty decorations
      refute_match(/no target/, @workspace.message)
    end
  end

  def test_language_change_invalidates_a_cached_callback
    with_client(Client.new([link(2, 5, target: "https://example.test/docs")])) do
      assert @workspace.request_document_links(@editor)
      settle
      callback = decorations.first.on_click
      opened = []
      @window.define_singleton_method(:open_url) { |target| opened << target }

      @editor.language = Canopus::Language::PLAIN
      refute callback.call(@editor, 4)
      assert_empty opened
    end
  end

  def test_external_values_are_strict_bounded_and_nonoverlapping
    rope = @editor.buffer.rope
    normalize = ->(value, resolve = false) { @workspace.send(:normalize_document_links, rope, value, resolve: resolve) }
    assert_empty normalize.call(nil)
    assert_equal 1, normalize.call([link(2, 5, data: {"id" => 1})], true).length
    assert_raises(Canopus::Error) { normalize.call(Array.new(10_001, link(2, 5, target: "https://example.test"))) }
    assert_raises(Canopus::Error) { normalize.call([link(2, 5, data: {})]) }
    assert_raises(Canopus::Error) { normalize.call([link(2, 5, target: "https://example.test"), link(4, 6, target: "https://example.test")]) }
    assert_raises(Canopus::Error) { normalize.call([link(1, 2, target: "https://example.test")]) }
    assert_raises(Canopus::Error) { normalize.call([link(2, 5, target: "https://example.test", tooltip: "x" * 4097)]) }
  end

  private

  def point(character, line: 0) = {"line" => line, "character" => character}
  def range(first, last) = {"start" => point(first), "end" => point(last)}
  def link(first, last, target: nil, tooltip: nil, data: nil)
    {"range" => range(first, last)}.tap do |value|
      value["target"] = target if target
      value["tooltip"] = tooltip if tooltip
      value["data"] = data if data
    end
  end

  def with_client(client)
    Sadr::Client.stub(:new, client) { @workspace.language_client(@editor.buffer) }
    yield client
  end

  def replace_client(client)
    Sadr::Client.stub(:new, client) do
      configured = @workspace.send(:normalize_server_options, ["fake"])
      @workspace.instance_variable_get(:@client_options)["ruby"] =
        @workspace.send(:normalize_server_options, ["retired", client.object_id.to_s])
      @workspace.send(:ensure_language_server, "ruby", configured)
    end
  end

  def decorations
    @workspace.decorations.items_for(@editor.buffer, 0...1, context: @editor)
      .select { |item| item.source == :document_link }
  end

  def settle
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    loop do
      @workspace.drain
      jobs = @workspace.instance_variable_get(:@language_jobs) || []
      break unless jobs.any?(&:alive?)
      raise "document link did not settle" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.001
    end
    @workspace.drain
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.001 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    raise "document link request did not start" unless yield
  end
end

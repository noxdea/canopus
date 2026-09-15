# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class CodeLensTest < Minitest::Test
  class Client
    attr_reader :capabilities, :handlers, :requests, :resolves, :executions, :state

    def initialize(results = [], resolved = [], resolve: true)
      @capabilities = {"codeLensProvider" => {"resolveProvider" => resolve}}
      @handlers, @requests, @resolves, @executions = {}, [], [], []
      @results, @resolved, @state = results, resolved, :running
    end

    def start = self
    def stop = @state = :stopped
    def running? = @state == :running
    def on(name, &handler) = @handlers[name] = handler
    def open(*) = nil
    def change(*) = nil
    def close(*) = nil
    def diagnostics = {}
    def code_lens(uri)
      @requests << uri
      future(@results.shift || [])
    end
    def resolve_code_lens(lens)
      @resolves << lens
      future(@resolved.shift || lens)
    end
    def execute_command(command, arguments: [])
      @executions << [command, arguments]
      future(nil)
    end

    private

    def future(value)
      value.is_a?(Sadr::Future) ? value : Sadr::Future.new(@requests.length + @resolves.length).fulfill(value)
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-code-lens-")
    @path = File.join(@root, "source.rb")
    File.write(@path, (0...240).map { |row| "value_#{row} = row\n" }.join)
    @settings = Canopus::Settings.new("language_servers" => {"ruby" => ["fake"]})
    @workspace = Canopus::Workspace.new(root: @root, settings: @settings)
    @editor = @workspace.open(@path)
  end

  def teardown
    @workspace.close
    @window&.on_close { true }
    @window&.close
    FileUtils.remove_entry(@root)
  end

  def position(line, character = 0) = {"line" => line, "character" => character}
  def lens(line, title: nil, command: "rubyLsp.run", arguments: [], **extra)
    value = {"range" => {"start" => position(line), "end" => position(line)}, **extra.transform_keys(&:to_s)}
    value["command"] = {"title" => title, "command" => command, "arguments" => arguments} if title
    value
  end

  def with_client(client)
    Sadr::Client.stub(:new, client) do
      @workspace.language_client(@editor.buffer)
      yield client
    end
  end

  def settle
    @workspace.instance_variable_get(:@language_jobs)&.each(&:join)
    @workspace.drain
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.001 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    raise "code lens request did not settle" unless yield
  end

  def test_ruby_lsp_lenses_are_cached_resolved_only_when_visible_and_clicked_in_order
    unresolved = lens(85, data: {"id" => 1})
    client = Client.new([[lens(5, title: "Run file", arguments: [5]), unresolved,
      lens(85, title: "Debug file", command: "rubyLsp.debug")]],
      [lens(85, title: "Run references", arguments: [{"line" => 85}])])
    with_client(client) do
      assert @workspace.request_code_lenses(@editor, 0...10)
      settle
      assert_equal ["Run file"], @workspace.code_lens_decorations(@editor.buffer, 0...10).map(&:content)
      assert_empty client.resolves

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      1_000.times { raise "cache miss" if @workspace.request_code_lenses(@editor, 80...90) }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.25
      assert_equal ["Debug file"], @workspace.code_lens_decorations(@editor.buffer, 80...90).map(&:content)
      settle
      items = @workspace.code_lens_decorations(@editor.buffer, 80...90)
      assert_equal ["Run references", "Debug file"], items.map(&:content)
      assert_equal [30, 31, 32], @workspace.code_lens_decorations(@editor.buffer, 0...100).map(&:priority)
      assert_equal 1, client.requests.length
      assert_equal [unresolved], client.resolves

      items.each { |item| item.on_click.call(@editor, @editor.buffer.rope.line_start(item.row)) }
      settle
      assert_equal [["rubyLsp.run", [{"line" => 85}]], ["rubyLsp.debug", []]], client.executions
      assert_empty(@workspace.instance_variable_get(:@language_jobs) || [])
    end
  end

  def test_refresh_and_edit_drop_stale_fetch_and_resolve_results
    old_fetch, old_resolve = Sadr::Future.new(1), Sadr::Future.new(2)
    fresh_fetch, fresh_resolve = Sadr::Future.new(3), Sadr::Future.new(4)
    client = Client.new([old_fetch, fresh_fetch], [old_resolve, fresh_resolve])
    with_client(client) do
      assert @workspace.request_code_lenses(@editor, 0...10)
      wait_until { client.requests.length == 1 }
      old_fetch.fulfill([lens(5, data: {"old" => true})])
      wait_until { @workspace.drain; !@workspace.instance_variable_get(:@code_lens_requests)&.key?(1) }
      assert_empty @workspace.code_lens_decorations(@editor.buffer, 0...10)
      refute @workspace.request_code_lenses(@editor, 0...10)
      wait_until { client.resolves.length == 1 }

      client.handlers.fetch("workspace/codeLens/refresh").call({})
      assert @workspace.request_code_lenses(@editor, 0...10)
      wait_until { client.requests.length == 2 }
      fresh_fetch.fulfill([lens(5, data: {"fresh" => true})])
      wait_until { @workspace.drain; @workspace.instance_variable_get(:@code_lens_requests)&.empty? }
      assert_empty @workspace.code_lens_decorations(@editor.buffer, 0...10)
      refute @workspace.request_code_lenses(@editor, 0...10)
      wait_until { client.resolves.length == 2 }
      fresh_resolve.fulfill(lens(5, title: "Fresh"))
      old_resolve.fulfill(lens(5, title: "Old"))
      settle
      assert_equal ["Fresh"], @workspace.code_lens_decorations(@editor.buffer, 0...10).map(&:content)

      @editor.insert_text("# edit\n", auto_indent: false)
      assert_empty @workspace.code_lens_decorations(@editor.buffer, 0...10)
      assert_empty(@workspace.instance_variable_get(:@code_lens_cache) || {})
    end
  end

  def test_disabled_missing_and_stale_commands_are_safe_no_operations
    disabled = lens(2, title: "Unavailable", disabled: {"reason" => "not runnable"})
    client = Client.new([[disabled, lens(3)]], [], resolve: false)
    with_client(client) do
      @workspace.request_code_lenses(@editor, 0...10)
      settle
      items = @workspace.code_lens_decorations(@editor.buffer, 0...10)
      assert_equal ["Unavailable"], items.map(&:content)
      assert_nil items.first.on_click
      assert_empty client.resolves

      active = lens(4, title: "Run")
      @workspace.send(:cache_code_lenses, client, @editor.buffer, @editor.buffer.version, [active],
        @workspace.instance_variable_get(:@code_lens_generation).to_i)
      click = @workspace.code_lens_decorations(@editor.buffer, 0...10).first.on_click
      client.handlers.fetch("workspace/codeLens/refresh").call({})
      refute click.call(@editor, 0)
      assert_empty client.executions

      @workspace.send(:cache_code_lenses, client, @editor.buffer, @editor.buffer.version, [active],
        @workspace.instance_variable_get(:@code_lens_generation).to_i)
      @settings.merge!("code_lens" => {"enabled" => false})
      @workspace.apply_settings
      assert_empty @workspace.code_lens_decorations(@editor.buffer, 0...10)
      assert_empty(@workspace.instance_variable_get(:@code_lens_cache) || {})
    end
  end

  def test_empty_refresh_result_removes_the_previous_block
    client = Client.new([[lens(2, title: "Old")], []])
    with_client(client) do
      @workspace.request_code_lenses(@editor, 0...10)
      settle
      assert_equal ["Old"], @workspace.code_lens_decorations(@editor.buffer, 0...10).map(&:content)

      client.handlers.fetch("workspace/codeLens/refresh").call({})
      assert_empty @workspace.code_lens_decorations(@editor.buffer, 0...10)
      @workspace.request_code_lenses(@editor, 0...10)
      settle
      assert_empty @workspace.code_lens_decorations(@editor.buffer, 0...10)
    end
  end

  def test_unsupported_server_is_not_queried
    client = Client.new
    client.capabilities["codeLensProvider"] = false
    with_client(client) do
      refute @workspace.request_code_lenses(@editor, 0...10)
      assert_empty client.requests
    end
  end

  def test_external_lenses_are_bounded_and_positions_are_exact_utf16_boundaries
    client = Client.new
    cache = ->(buffer, values) do
      @workspace.send(:cache_code_lenses, client, buffer, buffer.version, values,
        @workspace.instance_variable_get(:@code_lens_generation).to_i)
    end
    invalid = [
      lens(@editor.buffer.line_count, title: "outside"),
      lens(1, title: "x" * 4_097),
      lens(1, title: "run", arguments: Array.new(1_001)),
      lens(1, title: "run", command: ""),
      {"range" => {"start" => position(-1), "end" => position(0)}}
    ]
    invalid.each { |value| assert_raises(Canopus::Error) { cache.call(@editor.buffer, [value]) } }
    assert_raises(Canopus::Error) { cache.call(@editor.buffer, Array.new(10_001) { lens(0) }) }

    unicode = Canopus::Buffer.new("😀x")
    assert_raises(Canopus::Error) do
      cache.call(unicode, [{"range" => {"start" => position(0, 1), "end" => position(0, 1)}}])
    end
  ensure
    unicode&.close
  end

  def test_invalid_server_result_is_not_retried_until_invalidation
    invalid = lens(1, title: "run", command: "")
    client = Client.new([[invalid], []])
    with_client(client) do
      @workspace.request_code_lenses(@editor, 0...10)
      settle
      assert_empty @workspace.code_lens_decorations(@editor.buffer, 0...10)
      refute @workspace.request_code_lenses(@editor, 0...10)
      assert_equal 1, client.requests.length

      client.handlers.fetch("workspace/codeLens/refresh").call({})
      assert @workspace.request_code_lenses(@editor, 0...10)
      settle
      assert_equal 2, client.requests.length
    end
  end

  def test_block_lenses_preserve_fold_wrap_and_cursor_coordinates
    buffer = Canopus::Buffer.new("one\nhidden\nlast")
    editor = Canopus::Editor.new(buffer, wrap_width: 3)
    map = editor.display_map
    map.fold(3...11)
    visible = [
      Canopus::Decoration::Item.new(:block, nil, 0, "Run", {height: 20, position: :above}, 30, :code_lens, nil),
      Canopus::Decoration::Item.new(:block, nil, 0, "Debug", {height: 20, position: :above}, 31, :code_lens, nil),
      Canopus::Decoration::Item.new(:block, nil, 1, "Hidden", {height: 20, position: :above}, 32, :code_lens, nil)
    ]
    map.set_overlays(visible, font_size: 14, line_height: 20)

    assert_equal %i[overlay_block overlay_block text text text], map.each_row.map { |row, _| row.kind }
    [0, 2, buffer.rope.bytesize].each do |offset|
      assert_equal offset, map.to_buffer(map.to_display(offset))
    end
    editor.select(buffer.rope.bytesize)
    assert_equal buffer.rope.bytesize, editor.primary.head
  ensure
    editor&.dispose
    buffer&.close
  end

  def test_manual_action_preserves_the_code_lens_palette_and_settings_can_disable_it
    client = Client.new([[], []])
    with_client(client) do
      @workspace.call("language.codeLens")
      settle
      assert_equal 1, client.requests.length
      assert_equal :code_actions, @workspace.palette[:kind]
      assert @workspace.palette[:lens]
      @workspace.call("language.codeLens")
      settle
      assert_equal 2, client.requests.length
    end

    disabled = Canopus::Settings.new("language_servers" => {"ruby" => ["fake"]}, "code_lens" => {"enabled" => false})
    workspace = Canopus::Workspace.new(root: @root, settings: disabled)
    current = workspace.open(@path)
    client = Client.new([[]])
    Sadr::Client.stub(:new, client) do
      refute workspace.request_code_lenses(current, 0...10, start: true)
      assert_empty client.requests
    end
  ensure
    workspace&.close
  end

  def test_visible_document_poll_requests_once_across_scrolls
    client = Client.new([[]])
    @window = Zaniah::Platform.open_window(backend: :headless, width: 800, height: 220)
    controller = Canopus::Controller.new(@workspace, @window)
    document = @editor.language_document
    Sadr::Client.stub(:new, client) do
      document.stub(:request, nil) do
        document.stub(:poll, false) do
          controller.poll_language_documents
          settle
          @editor.scroll(dy: 100)
          controller.poll_language_documents
          settle
        end
      end
    end
    assert_equal 1, client.requests.length
  end

  def test_visible_resolves_are_bounded_per_client
    pending = Sadr::Future.new(1)
    client = Client.new([Array.new(40) { |index| lens(5, data: {"id" => index}) }], Array.new(40, pending))
    with_client(client) do
      @workspace.request_code_lenses(@editor, 0...10)
      settle
      assert_empty @workspace.code_lens_decorations(@editor.buffer, 0...10)
      refute @workspace.request_code_lenses(@editor, 0...10)
      wait_until { client.resolves.length == 32 }
      pending.fulfill(lens(5, title: "Run"))
      settle
      assert_equal 32, @workspace.code_lens_decorations(@editor.buffer, 0...10).length
      refute @workspace.request_code_lenses(@editor, 0...10)
      settle
      assert_equal 40, @workspace.code_lens_decorations(@editor.buffer, 0...10).length
      assert_equal 40, client.resolves.length
    end
  end

  def test_whole_document_decoration_queries_do_not_resolve_offscreen_lenses
    client = Client.new([[lens(5, data: {"visible" => true}), lens(85, data: {"hidden" => true})]],
      [lens(5, title: "Visible"), lens(85, title: "Hidden")])
    with_client(client) do
      @workspace.request_code_lenses(@editor, 0...10)
      settle
      assert_empty @workspace.code_lens_decorations(@editor.buffer, 0...@editor.buffer.line_count)
      assert_empty client.resolves

      refute @workspace.request_code_lenses(@editor, 0...10)
      settle
      assert_equal [5], client.resolves.map { |value| value.dig("range", "start", "line") }
      assert_equal ["Visible"], @workspace.code_lens_decorations(@editor.buffer, 0...10).map(&:content)
    end
  end

  def test_folded_source_rows_are_not_considered_visible
    first = @editor.buffer.rope.line_start(10)
    last = @editor.buffer.rope.line_start(90)
    @editor.display_map.fold(first...last)
    ranges = @workspace.visible_code_lens_ranges(@editor, 0...20)

    assert ranges.any? { |range| range.cover?(10) }
    refute ranges.any? { |range| range.cover?(50) }
  end

  def test_pending_requests_are_bounded
    client = Client.new
    requests = (1..64).to_h { |id| [id, {buffer: Object.new, version: 0, client: client}] }
    @workspace.instance_variable_set(:@code_lens_requests, requests)
    with_client(client) do
      refute @workspace.request_code_lenses(@editor, 0...10)
      assert_empty client.requests
    end
  end

  def test_failed_server_start_can_retry
    workspace = Canopus::Workspace.new(root: @root, settings: @settings)
    current = workspace.open(@path)
    failed, replacement = Client.new, Client.new([[]])
    failed.define_singleton_method(:start) { raise Canopus::Error, "start failed" }
    clients = [failed, replacement]
    Sadr::Client.stub(:new, ->(**) { clients.shift }) do
      assert workspace.request_code_lenses(current, 0...10, start: true)
      wait_until { workspace.drain; workspace.instance_variable_get(:@code_lens_requests)&.empty? }
      assert workspace.request_code_lenses(current, 0...10, start: true)
      workspace.instance_variable_get(:@language_jobs)&.each(&:join)
      workspace.drain
      assert_equal 1, replacement.requests.length
    end
  ensure
    workspace&.close
  end

  def test_server_restart_discards_the_old_clients_cache
    old_client, replacement = Client.new([[lens(1, title: "Old")]]), Client.new([[]])
    clients = [old_client, replacement]
    Sadr::Client.stub(:new, ->(**) { clients.shift }) do
      @workspace.language_client(@editor.buffer)
      @workspace.request_code_lenses(@editor, 0...10)
      settle
      refute_empty @workspace.code_lens_decorations(@editor.buffer, 0...10)

      @settings.merge!("language_servers" => {"ruby" => ["replacement"]})
      @workspace.apply_settings
      wait_until do
        @workspace.drain
        @workspace.clients["ruby"].equal?(replacement) && !@workspace.instance_variable_get(:@language_reload_job)&.alive?
      end
      assert_empty @workspace.code_lens_decorations(@editor.buffer, 0...10)
      assert_empty(@workspace.instance_variable_get(:@code_lens_cache) || {})
      assert_equal :stopped, old_client.state
      assert replacement.handlers.key?("workspace/codeLens/refresh")
    end
  end
end

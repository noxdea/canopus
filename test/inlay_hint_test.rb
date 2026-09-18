# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class InlayHintTest < Minitest::Test
  class Client
    attr_reader :capabilities, :handlers, :requests, :state

    def initialize(results)
      @capabilities = {"inlayHintProvider" => true}
      @handlers, @requests, @results = {}, [], results
      @state = :running
    end

    def start = self
    def stop = nil
    def running? = true
    def on(name, &handler) = @handlers[name] = handler
    def open(_document) = nil
    def change(*) = nil
    def close(*) = nil
    def diagnostics = {}
    def inlay_hint(uri, range)
      @requests << [uri, range]
      result = @results.shift || []
      result.is_a?(Sadr::Future) ? result : Sadr::Future.new(@requests.length).fulfill(result)
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-inlay-")
    @path = File.join(@root, "source.rb")
    @target = File.join(@root, "target.rb")
    File.write(@path, (0...240).map { |row| "value_#{row} = row\n" }.join)
    File.write(@target, "first\nsecond\n")
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

  def settle
    @workspace.instance_variable_get(:@language_jobs)&.each(&:join)
    @workspace.drain
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.001 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    raise "inlay hint request did not settle" unless yield
  end

  def position(line, character = 0) = {"line" => line, "character" => character}
  def location(line = 1) = {"uri" => Sadr::Protocol.uri(@target), "range" => {"start" => position(line), "end" => position(line)}}

  def with_client(*results)
    client = Client.new(results)
    Sadr::Client.stub(:new, client) do
      @workspace.language_client(@editor.buffer)
      yield client
    end
  end

  def test_simultaneous_first_posts_reuse_the_initialized_main_queue
    initialized = @workspace.instance_variable_get(:@main_queue)
    ready, release = Queue.new, Queue.new
    callbacks = []
    workers = 2.times.map do |index|
      Thread.new do
        ready << true
        release.pop
        @workspace.post { callbacks << index }
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    workers.each(&:join)
    @workspace.drain

    refute_nil initialized
    assert_same initialized, @workspace.instance_variable_get(:@main_queue)
    assert_equal [0, 1], callbacks.sort
  end

  def test_ruby_lsp_style_parts_become_ordered_inline_hints_with_padding_and_location_click
    hint = {"position" => position(85, 8), "kind" => 1, "paddingLeft" => true, "paddingRight" => true,
      "label" => [{"value" => ": "}, {"value" => "String", "location" => location}]}
    with_client([hint]) do |client|
      assert @workspace.request_inlay_hints(@editor, 80...90)
      settle

      items = @workspace.decorations.items_for(@editor.buffer, 85...86, context: @editor)
        .select { |item| item.source == :inlay_hint }
      assert_equal [": ", "String"], items.map(&:content)
      assert items.all? { |item| item.kind == :inline && item.range.begin == item.range.end }
      assert_equal [4, 0], items.map { |item| item.style[:padding_left] }
      assert_equal [0, 4], items.map { |item| item.style[:padding_right] }
      assert_nil items.first.on_click
      @editor.display_map.set_overlays(items, font_size: 14, line_height: 20)
      assert_equal @editor.buffer.line_count, @editor.display_map.row_count
      assert_equal [": ", "String"], @editor.display_map.row(85).metadata.map { |placement| placement.item.content }
      @editor.scroll(dy: 80)
      @window = Zaniah::Platform.open_window(backend: :headless, width: 800, height: 220)
      @window.text_system = Zaniah::TextSystem::Renderer.new
      controller = Canopus::Controller.new(@workspace, @window)
      @editor.language_document.stub(:poll, false) { controller.tick }
      region = controller.view.regions.select { |_bounds, action| action.first == :decoration }
      assert_equal 1, region.length
      bounds = region.first.first
      expected_width = @editor.display_map.row(85).metadata.last.width
      assert_in_delta expected_width, bounds.width, 0.01
      @window.input(Zaniah::Input::MouseDown.new(Zaniah::Point.new(bounds.x + 1, bounds.y + 1), :left, [], 1))
      assert_equal File.realpath(@target), @workspace.editor.buffer.path
      assert_equal @workspace.editor.buffer.rope.line_start(1), @workspace.editor.primary.head
      assert_equal 30, client.requests.first.last.start.line
      assert_equal 140, client.requests.first.last.end.line
    end
  end

  def test_scroll_cache_is_bounded_to_the_prefetched_range_and_fast
    with_client([], []) do |client|
      assert @workspace.request_inlay_hints(@editor, 80...90)
      settle
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      1_000.times { raise "cache miss" if @workspace.request_inlay_hints(@editor, 100...110) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 1.0
      assert_equal 1, client.requests.length

      assert @workspace.request_inlay_hints(@editor, 141...150)
      settle
      assert_equal 2, client.requests.length
      assert_equal 91, client.requests.last.last.start.line
      assert_equal 200, client.requests.last.last.end.line
    end
  end

  def test_fold_suffix_and_new_viewport_are_requested_without_a_stale_tick
    map = @editor.display_map
    map.fold(@editor.buffer.rope.line_start(1)...@editor.buffer.rope.line_start(200))
    assert_equal [1...2, 200...201], @workspace.visible_inlay_hint_ranges(@editor, 1...2)

    @editor.viewport_rows = 1
    @window = Zaniah::Platform.open_window(backend: :headless, width: 800, height: 220)
    controller = Canopus::Controller.new(@workspace, @window)
    ranges = []
    request = ->(_editor, rows, **) { ranges << rows; false }
    document = @editor.language_document
    @workspace.stub(:request_inlay_hints, request) do
      @workspace.stub(:language_ready, nil) do
        document.stub(:request, nil) do
          document.stub(:poll, false) do
            controller.poll_language_documents
            initial = ranges.length
            @editor.scroll(dy: 2)
            controller.poll_language_documents
            assert_equal [201...203], ranges.drop(initial)
          end
        end
      end
    end
  end

  def test_manual_action_starts_the_server_for_the_current_viewport
    client = Client.new([[]])
    @editor.viewport_rows = 10
    @editor.scroll(dy: 100)
    Sadr::Client.stub(:new, client) do
      @workspace.call("language.inlayHint")
      settle
    end
    assert_equal 1, client.requests.length
    assert_equal 50, client.requests.first.last.start.line
    assert_equal 161, client.requests.first.last.end.line
  end

  def test_visible_poll_starts_a_configured_server_once_and_skips_an_unsupported_provider
    supported = Client.new([[]])
    @window = Zaniah::Platform.open_window(backend: :headless, width: 800, height: 220)
    controller = Canopus::Controller.new(@workspace, @window)
    document = @editor.language_document
    Sadr::Client.stub(:new, supported) do
      document.stub(:request, nil) do
        document.stub(:poll, false) do
          controller.poll_language_documents
          settle
          controller.poll_language_documents
        end
      end
    end
    assert_equal 1, supported.requests.length

    supported.capabilities.clear
    3.times { controller.poll_language_documents }
    assert_equal 1, supported.requests.length
  end

  def test_edit_and_server_refresh_remove_stale_hints_before_refetch
    hint = {"position" => position(5), "label" => ": String"}
    with_client([hint], [hint]) do |client|
      @workspace.request_inlay_hints(@editor, 0...10)
      settle
      refute_empty @workspace.inlay_hint_decorations(@editor.buffer, 0...10)

      @editor.insert_text("# edit\n", auto_indent: false)
      assert_empty @workspace.inlay_hint_decorations(@editor.buffer, 0...10)
      client.handlers.fetch("workspace/inlayHint/refresh").call({})
      assert_empty @workspace.inlay_hint_decorations(@editor.buffer, 0...10)
      assert @workspace.request_inlay_hints(@editor, 0...10)
      settle
      assert_equal 2, client.requests.length
      refute_empty @workspace.inlay_hint_decorations(@editor.buffer, 0...10)
    end
  end

  def test_kind_filters_and_max_length_apply_per_language
    @settings.merge!("inlay_hints" => {"parameter_names" => false, "max_length" => 5})
    type = {"position" => position(1), "kind" => 1, "label" => "LongType"}
    parameter = {"position" => position(2), "kind" => 2, "label" => "name:"}
    with_client([type, parameter]) do
      @workspace.request_inlay_hints(@editor, 0...10)
      settle
      items = @workspace.inlay_hint_decorations(@editor.buffer, 0...10)
      assert_equal ["Long…"], items.map(&:content)
      assert_equal [1], items.map(&:row)
    end
  end

  def test_refresh_does_not_let_an_old_pending_request_block_or_replace_the_new_result
    old = Sadr::Future.new(1)
    fresh = Sadr::Future.new(2)
    with_client(old, fresh) do |client|
      assert @workspace.request_inlay_hints(@editor, 0...10)
      wait_until { client.requests.length == 1 }
      client.handlers.fetch("workspace/inlayHint/refresh").call({})
      assert @workspace.request_inlay_hints(@editor, 0...10)
      wait_until { client.requests.length == 2 }
      fresh.fulfill([{"position" => position(5), "label" => "fresh"}])
      old.fulfill([{"position" => position(5), "label" => "old"}])
      settle

      assert_equal ["fresh"], @workspace.inlay_hint_decorations(@editor.buffer, 0...10).map(&:content)
      assert_empty @workspace.instance_variable_get(:@inlay_hint_requests)
    end
  end

  def test_close_clears_pending_and_cached_state
    pending = Sadr::Future.new(1)
    with_client(pending) do |client|
      assert @workspace.request_inlay_hints(@editor, 0...10)
      wait_until { client.requests.length == 1 }
      @workspace.close
      assert_empty @workspace.instance_variable_get(:@inlay_hint_requests)
      assert_empty(@workspace.instance_variable_get(:@inlay_hint_cache) || {})
      pending.fulfill([])
      @workspace.instance_variable_get(:@language_jobs).each(&:join)
    end
  end

  def test_overlapping_cache_uses_the_latest_rows_and_evicts_old_entries
    with_client do |client|
      settings = @settings["inlay_hints"]
      version = @editor.buffer.version
      cache = ->(rows, hints, id) do
        @workspace.send(:cache_inlay_hints, client, @editor.buffer, version, rows, hints, id, settings)
      end
      cache.call(0...100, [{"position" => position(5), "label" => "kept"},
        {"position" => position(20), "label" => "old"}], 1)
      cache.call(10...50, [{"position" => position(20), "label" => "new"}], 2)
      assert_equal ["kept", "new"], @workspace.inlay_hint_decorations(@editor.buffer, 0...100).map(&:content)

      65.times { |row| cache.call(row...(row + 1), [], row + 3) }
      assert_equal 64, @workspace.instance_variable_get(:@inlay_hint_cache).length
    end
  end

  def test_positions_are_strict_utf16_boundaries_and_visible_parts_own_padding
    settings = @settings["inlay_hints"].merge("max_length" => 1)
    hint = {"position" => position(1), "paddingLeft" => true, "paddingRight" => true,
      "label" => [{"value" => ""}, {"value" => "String", "location" => location}]}
    item = @workspace.send(:build_inlay_hint_decorations, @editor.buffer, [hint], settings).first
    assert_equal "…", item.content
    assert item.on_click
    assert_equal({color: :muted, padding_left: 4, padding_right: 4, cells: 3}, item.style)

    [{"line" => 1, "character" => 99}, {"line" => @editor.buffer.line_count, "character" => 0}].each do |invalid|
      hint = {"position" => invalid, "label" => "invalid"}
      assert_raises(Canopus::Error) do
        @workspace.send(:build_inlay_hint_decorations, @editor.buffer, [hint], @settings["inlay_hints"])
      end
    end

    unicode = Canopus::Buffer.new("😀x")
    valid = @workspace.send(:build_inlay_hint_decorations, unicode,
      [{"position" => position(0, 2), "label" => "valid"}], @settings["inlay_hints"])
    assert_equal 4, valid.first.range.begin
    assert_raises(Canopus::Error) do
      @workspace.send(:build_inlay_hint_decorations, unicode,
        [{"position" => position(0, 1), "label" => "invalid"}], @settings["inlay_hints"])
    end
  end
end

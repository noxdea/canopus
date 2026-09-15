# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"

class StickyScrollTest < Minitest::Test
  class Client
    attr_reader :capabilities, :handlers, :requests, :state

    def initialize(*results)
      @capabilities = {"documentSymbolProvider" => true}
      @handlers, @requests, @results, @state = {}, [], results, :running
    end

    def start = self
    def stop = @state = :stopped
    def running? = @state == :running
    def on(name, &handler) = @handlers[name] = handler
    def open(*) = nil
    def change(*) = nil
    def close(*) = nil
    def diagnostics = {}
    def document_symbol(uri)
      @requests << uri
      result = @results.shift || []
      result.is_a?(Sadr::Future) ? result : Sadr::Future.new(@requests.length).fulfill(result)
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-sticky-")
    @path = File.join(@root, "source.rb")
    File.write(@path, "class Outer\n  def inner\n#{(0...70).map { |row| "    value_#{row}\n" }.join}  end\nend\n")
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
  def byte_range(first_line, first_column, last_line, last_column)
    {"start" => position(first_line, first_column), "end" => position(last_line, last_column)}
  end
  def range(first, last) = {"start" => position(first), "end" => position(last, @editor.buffer.line(last).length)}
  def document_symbol(name, first, last, selection: first, children: [])
    {"name" => name, "kind" => 5, "range" => range(first, last),
      "selectionRange" => {"start" => position(selection), "end" => position(selection, name.length)}, "children" => children}
  end
  def symbols
    last = @editor.buffer.line_count - 2
    [document_symbol("Outer", 0, last, children: [document_symbol("inner", 1, last - 1)])]
  end

  def with_client(client)
    Sadr::Client.stub(:new, client) do
      @workspace.language_client(@editor.buffer)
      yield client
    end
  end

  def settle
    @workspace.instance_variable_get(:@language_jobs)&.dup&.each(&:join)
    @workspace.drain
  end

  def wait_until(message = "sticky request did not settle")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.001 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    raise message unless yield
  end

  def cache(client, values = symbols)
    normalized = @workspace.send(:normalize_document_symbols, @editor.buffer.rope, values, Sadr::Protocol.uri(@path))
    @workspace.send(:cache_sticky_symbols, client, @editor.buffer, @editor.buffer.version, normalized)
    normalized
  end

  def test_settings_are_defaulted_layered_and_bounded
    assert_equal({"enabled" => true, "max_lines" => 5}, @settings["sticky_scroll"])
    assert_equal "integer", Canopus::Settings.schema.dig("properties", "sticky_scroll", "properties", "max_lines", "type")
    assert_raises(Canopus::Error) { Canopus::Settings.new("sticky_scroll" => {"enabled" => "yes"}) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("sticky_scroll" => {"max_lines" => 21}) }

    layered = Canopus::Settings.new("sticky_scroll" => {"max_lines" => 4},
      "languages" => {"ruby" => {"sticky_scroll" => {"max_lines" => 2}}})
    workspace = Canopus::Workspace.new(root: @root, settings: layered)
    current = workspace.open(@path)
    assert workspace.sticky_scroll_enabled?(current)
    fallback = workspace.send(:sticky_cache_entry, current.buffer, current.buffer.version, nil, cacheless_symbols(current))
    workspace.instance_variable_set(:@sticky_fallback_cache,
      {current => [current.buffer.version, current.language_document, nil, fallback]})
    assert_equal 2, workspace.sticky_context(current, 10).length
  ensure
    workspace&.close
  end

  def test_hierarchical_and_flat_lsp_symbols_are_normalized_to_current_buffer
    client = Client.new
    with_client(client) do
      normalized = cache(client)
      assert_equal %w[Outer inner], normalized.map(&:name)
      assert normalized.all? { |symbol| symbol.range.is_a?(Range) && symbol.selection.is_a?(Range) }
      assert_equal [0, 1], normalized.map(&:depth)
      assert_equal [5, 5], normalized.map(&:kind)
      assert_nil normalized.first.parent_id
      assert_equal normalized.first.id, normalized.last.parent_id
      assert_equal %w[Outer inner], @workspace.sticky_context(@editor, 10).map(&:name)
      generation = @workspace.document_symbol_generation(@editor)
      assert_equal %w[Outer inner], @workspace.document_symbol_chain(@editor, @editor.buffer.rope.line_start(10)).map(&:name)
      assert_equal ["inner"], @workspace.document_symbol_siblings(@editor, normalized.last, generation: generation).map(&:name)
      assert_empty @workspace.document_symbol_siblings(@editor, normalized.last, generation: generation + 1)

      uri = Sadr::Protocol.uri(@path)
      flat = [
        {"name" => "FlatOuter", "kind" => 5,
          "location" => {"uri" => uri, "range" => byte_range(0, 6, 0, 11)}},
        {"name" => "FlatInner", "kind" => 6, "containerName" => "FlatOuter",
          "location" => {"uri" => uri, "range" => byte_range(1, 6, 1, 11)}}
      ]
      flat_symbols = cache(client, flat)
      assert_equal %w[FlatOuter FlatInner], @workspace.sticky_context(@editor, 10).map(&:name)
      assert_equal flat_symbols.first.id, flat_symbols.last.parent_id
      refute_equal generation, @workspace.document_symbol_generation(@editor)

      prefix = "x" * 256
      distinct = [
        {"name" => "#{prefix}first", "kind" => 5,
          "location" => {"uri" => uri, "range" => byte_range(0, 0, 0, 1)}},
        {"name" => "#{prefix}second", "kind" => 5,
          "location" => {"uri" => uri, "range" => byte_range(1, 0, 1, 1)}},
        {"name" => "child", "kind" => 6, "containerName" => "#{prefix}first",
          "location" => {"uri" => uri, "range" => byte_range(2, 0, 2, 1)}}
      ]
      distinct_symbols = cache(client, distinct)
      assert_equal distinct_symbols.first.id, distinct_symbols.last.parent_id

      same_line = [{"name" => "Line", "kind" => 5, "range" => byte_range(2, 0, 3, 0),
        "selectionRange" => byte_range(2, 0, 2, 4), "children" => [
          {"name" => "value", "kind" => 13, "range" => byte_range(2, 4, 2, 9),
           "selectionRange" => byte_range(2, 4, 2, 9)},
          {"name" => "zero", "kind" => 13, "range" => byte_range(2, 10, 2, 11),
           "selectionRange" => byte_range(2, 10, 2, 11)}]}]
      line_symbols = cache(client, same_line)
      line_start = @editor.buffer.rope.line_start(2)
      assert_equal %w[Line value], @workspace.document_symbol_chain(@editor, line_start + 5).map(&:name)
      assert_equal %w[Line zero], @workspace.document_symbol_chain(@editor, line_start + 10).map(&:name)
      assert_equal %w[value zero], @workspace.document_symbol_siblings(@editor, line_symbols.last,
        generation: @workspace.document_symbol_generation(@editor)).map(&:name)
    end
  end

  def test_external_symbol_limits_and_utf16_boundaries_are_rejected
    normalize = ->(values, buffer = @editor.buffer, uri = Sadr::Protocol.uri(@path)) do
      @workspace.send(:normalize_document_symbols, buffer.rope, values, uri)
    end
    assert_raises(Canopus::Error) { normalize.call(Array.new(10_001, symbols.first)) }
    assert_raises(Canopus::Error) { normalize.call([symbols.first.merge("name" => "x" * 4_097)]) }
    assert_raises(Canopus::Error) do
      normalize.call([{"name" => "Elsewhere", "kind" => 1,
        "location" => {"uri" => Sadr::Protocol.uri(File.join(@root, "other.rb")), "range" => range(0, 1)}}])
    end

    nested = document_symbol("deep", 0, 73)
    65.times { nested = document_symbol("deep", 0, 73, children: [nested]) }
    assert_raises(Canopus::Error) { normalize.call([nested]) }

    cyclic = document_symbol("cycle", 0, 73)
    cyclic["children"] = [cyclic]
    assert_match(/cyclic/, assert_raises(Canopus::Error) { normalize.call([cyclic]) }.message)

    unicode = Canopus::Buffer.new("😀x")
    bad = {"name" => "bad", "kind" => 1,
      "range" => {"start" => position(0, 1), "end" => position(0, 1)},
      "selectionRange" => {"start" => position(0, 1), "end" => position(0, 1)}}
    assert_raises(Canopus::Error) { normalize.call([bad], unicode, "file:///unicode") }
  ensure
    unicode&.close
  end

  def test_edit_rejects_pending_lsp_result_and_cleans_cache
    pending = Sadr::Future.new(1)
    client = Client.new(pending)
    with_client(client) do
      assert @workspace.request_sticky_symbols(@editor)
      wait_until { client.requests.length == 1 }
      @editor.insert_text("# changed\n", auto_indent: false)
      pending.fulfill(symbols)
      settle
      assert_empty(@workspace.instance_variable_get(:@sticky_symbol_cache) || {})
      assert_empty(@workspace.instance_variable_get(:@sticky_symbol_requests) || {})
    end
  end

  def test_fixed_rows_reduce_editor_geometry_and_support_focus_jump_and_wheel
    client = Client.new
    with_client(client) do
      cache(client)
      @window = Zaniah::Platform.open_window(backend: :headless, width: 800, height: 240)
      @window.text_system = Zaniah::TextSystem::Renderer.new
      controller = Canopus::Controller.new(@workspace, @window)
      first_pane, first_editor = @workspace.active_pane, @editor
      first_editor.select(first_editor.buffer.rope.line_start(10))
      first_editor.scroll(dy: 10)
      controller.tick

      sticky = controller.view.regions.select { |_bounds, action| action.first == :sticky && action[2].equal?(first_editor) }
      assert_equal [0, first_editor.buffer.rope.line_start(1)], sticky.map { |_bounds, action| action[3] }
      body = controller.view.editor_bounds.fetch(first_editor)
      assert_equal sticky.last.first.bottom, body.y
      assert_equal [(body.height / sticky.first.first.height).floor, 1].max, first_editor.viewport_rows
      assert_operator @window.ime_state.y, :>=, body.y
      expected = first_editor.display_map.to_buffer(Canopus::DisplayPoint.new(first_editor.scroll_y.floor, 0))
      assert_equal expected, controller.view.offset_at(first_editor, Zaniah::Point.new(body.x + 52, body.y + 1))
      vertical = controller.view.regions.find { |_bounds, action| action.first == :scrollbar && action[1].equal?(first_editor) && action[2] == :vertical }
      assert_operator vertical.first.y, :>=, body.y
      start_row = first_editor.display_map.to_display(first_editor.primary.head).row
      first_editor.move(:page_down)
      assert_equal start_row + first_editor.viewport_rows,
        first_editor.display_map.to_display(first_editor.primary.head).row

      first_editor.select(first_editor.buffer.rope.line_start(10))
      first_editor.scroll(dy: 10 - first_editor.scroll_y)
      @workspace.split(:horizontal)
      second_editor = @workspace.editor
      controller.tick
      sticky = controller.view.regions.select { |_bounds, action| action.first == :sticky && action[2].equal?(first_editor) }

      before, other = first_editor.scroll_y, second_editor.scroll_y
      point = Zaniah::Point.new(sticky.last.first.x + 4, sticky.last.first.y + 4)
      controller.input(Zaniah::Input::ScrollWheel.new(point, Zaniah::Point.new(0, 20), 8, []))
      assert_operator first_editor.scroll_y, :>, before
      assert_equal other, second_editor.scroll_y

      controller.input(Zaniah::Input::MouseDown.new(point, :left, [], 1))
      assert_same first_pane, @workspace.active_pane
      assert_same first_editor, @workspace.editor
      assert_equal 1, first_editor.buffer.rope.point_at(first_editor.primary.head).row
      assert controller.view.accessibility.any? { |item| item[:role] == :button && item[:label] == "Go to inner" }
    end
  end

  def test_layout_clamps_before_choosing_sticky_rows_and_after_removing_block_overlays
    client = Client.new
    with_client(client) do
      late = [document_symbol("Late", 69, 72)]
      cache(client, late)
      @editor.instance_variable_set(:@scroll_y, 70)
      @window = Zaniah::Platform.open_window(backend: :headless, width: 800, height: 240)
      @window.text_system = Zaniah::TextSystem::Renderer.new
      controller = Canopus::Controller.new(@workspace, @window)
      controller.tick

      assert_empty controller.view.regions.select { |_bounds, action| action.first == :sticky }
      assert_equal @editor.display_map.row_count - @editor.viewport_rows, @editor.scroll_y

      overlay = Canopus::Decoration::Item.new(:block, nil, 0, "lens",
        {height: 200, position: :above}, 0, :sticky_overlay, nil)
      @editor.display_map.set_overlays([overlay], font_size: 14, line_height: 20)
      @editor.instance_variable_set(:@scroll_y, @editor.display_map.row_count - 1)
      @window.request_frame
      controller.tick
      assert_equal @editor.display_map.row_count - @editor.viewport_rows, @editor.scroll_y

      scope = [{"name" => "Before block", "kind" => 5, "range" => byte_range(8, 0, 10, 0),
        "selectionRange" => byte_range(8, 0, 8, 6)}]
      cache(client, scope)
      below = overlay.with(row: 9, style: {height: 20, position: :below})
      @editor.display_map.set_overlays([below], font_size: 14, line_height: 20)
      block_row = @editor.display_map.each_row.find { |row, _index| row.kind == :overlay_block }.last
      assert_equal ["Before block"], @workspace.sticky_context(@editor, block_row).map(&:name)
    end
  end

  def test_antares_fallback_is_nonblocking_bounded_and_shared_with_tui
    @workspace.close
    settings = Canopus::Settings.new("languages" => {"sticky" => {"sticky_scroll" => {"max_lines" => 2}}})
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    @workspace.register_language("sticky", extensions: [".sticky"], lexer: "ruby")
    path = File.join(@root, "source.sticky")
    FileUtils.cp(@path, path)
    @editor = @workspace.open(path)
    output = StringIO.new
    @window = Zaniah::Platform.open_window(backend: :tui, output: output, width: 320, height: 240)
    controller = Canopus::Controller.new(@workspace, @window)
    wait_until("structure analysis did not settle") do
      controller.poll_language_documents
      @editor.language_document.syntax_ready?
    end
    @editor.select(@editor.buffer.rope.line_start(10))
    @editor.scroll(dy: 10)
    controller.tick

    labels = controller.view.regions.select { |_bounds, action| action.first == :sticky }.map { |_bounds, action| action[3] }
    assert_equal [0, @editor.buffer.rope.line_start(1)], labels
    assert_includes output.string, "class Outer"
    assert_includes output.string, "def inner"
    assert_operator @editor.viewport_rows, :>=, 1
  end

  private

  def cacheless_symbols(current)
    rope = current.buffer.rope
    [Canopus::Language::DocumentSymbol.new(0, "Outer", :structure, 0...rope.bytesize, 0...0, 0, nil),
      Canopus::Language::DocumentSymbol.new(1, "inner", :structure, rope.line_start(1)...rope.line_start(73),
        (rope.line_start(1)...rope.line_start(1)), 1, 0)].freeze
  end
end

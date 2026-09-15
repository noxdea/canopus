# frozen_string_literal: true

require_relative "test_helper"
require "canopus/lazy_rope"
require "stringio"
require "tmpdir"

class MinimapTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-minimap-")
    @path = File.join(@root, "日本語.rb")
    File.write(@path, (0...240).map { |row| "日本語 value_#{row}\n" }.join)
  end

  def teardown
    @workspace&.close
    @window&.on_close { true }
    @window&.close
    FileUtils.remove_entry(@root)
  end

  def test_settings_default_schema_bounds_and_language_override
    settings = Canopus::Settings.new
    assert_equal({"enabled" => false, "width" => 100, "show_diagnostics" => true}, settings["minimap"])
    assert_equal 40, Canopus::Settings.schema.dig("properties", "minimap", "properties", "width", "minimum")
    assert_raises(Canopus::Error) { Canopus::Settings.new("minimap" => {"enabled" => "yes"}) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("minimap" => {"width" => 39}) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("minimap" => {"width" => 401}) }

    settings = Canopus::Settings.new("minimap" => {"enabled" => false},
      "languages" => {"ruby" => {"minimap" => {"enabled" => true, "width" => 80}}})
    workspace = Canopus::Workspace.new(root: @root, settings: settings)
    current = workspace.open(@path)
    assert_equal({"enabled" => true, "width" => 80, "show_diagnostics" => true}, workspace.minimap_settings(current))
  ensure
    workspace&.close
  end

  def test_default_off_and_tui_do_not_reserve_editor_width
    @workspace = Canopus::Workspace.new(root: @root)
    editor = @workspace.open(@path)
    @window = window(width: 600)
    controller = Canopus::Controller.new(@workspace, @window)
    controller.tick
    assert_empty controller.view.minimap_bounds
    assert_equal 600, controller.view.editor_bounds.fetch(editor).right

    @workspace.close
    @window.on_close { true }
    @window.close
    @window = nil
    @workspace = Canopus::Workspace.new(root: @root, settings: enabled_settings)
    editor = @workspace.open(@path)
    output = StringIO.new
    @window = Zaniah::Platform.open_window(backend: :tui, output: output, width: 600, height: 240)
    controller = Canopus::Controller.new(@workspace, @window)
    controller.tick
    assert_empty controller.view.minimap_bounds
    assert_equal 600, controller.view.editor_bounds.fetch(editor).right
  end

  def test_layout_cold_budget_warm_reuse_split_and_accessibility
    @workspace = Canopus::Workspace.new(root: @root, settings: enabled_settings)
    editor = @workspace.open(@path)
    @window = window(width: 640)
    controller = Canopus::Controller.new(@workspace, @window)
    controller.tick

    minimap = controller.view.minimap_bounds.fetch(editor)[:bounds]
    body = controller.view.editor_bounds.fetch(editor)
    assert_equal 80, minimap.width
    assert_equal minimap.x, body.right
    assert_operator @workspace.minimap.generated, :<=, Canopus::Minimap::GENERATION_LIMIT
    assert controller.view.regions.any? { |_bounds, action| action == [:minimap, @workspace.active_pane, editor] }
    assert controller.view.accessibility.any? { |item| item[:role] == :scrollbar && item[:label] == "Document minimap" }
    assert controller.view.regions.select { |_bounds, action| action.first == :breadcrumb }.all? { |bounds, _| bounds.right <= minimap.x }
    assert_operator controller.view.send(:minimap_rows, 10_000, 10_000).length, :<=, Canopus::Minimap::ENTRY_LIMIT

    12.times do
      break unless @workspace.minimap.pending?
      @window.request_frame
      controller.tick
    end
    size = @workspace.minimap.cache_size
    @window.request_frame
    controller.tick
    assert_equal 0, @workspace.minimap.generated
    assert_equal size, @workspace.minimap.cache_size

    first_pane = @workspace.active_pane
    @workspace.split(:horizontal)
    second_editor = @workspace.editor
    @window.request_frame
    controller.tick
    assert_equal 2, controller.view.minimap_bounds.length
    assert_equal @workspace.minimap.cached_rows(editor), @workspace.minimap.cached_rows(second_editor)
    assert_same editor.buffer, second_editor.buffer
    assert controller.view.minimap_bounds.key?(editor)
    assert controller.view.minimap_bounds.key?(second_editor)
    assert_same first_pane.editors.first.buffer, second_editor.buffer
  end

  def test_row_cache_reuses_unedited_lines_maps_newlines_and_is_bounded
    buffer = Canopus::Buffer.new("zero\none\ntwo\nthree\n")
    minimap = Canopus::Minimap.new
    renderer = Zaniah::TextSystem::Renderer.new
    begin_frame(minimap, renderer, 1)
    zero = minimap.texture(buffer, 0, width: 60)
    one = minimap.texture(buffer, 1, width: 60)
    two = minimap.texture(buffer, 2, width: 60)
    assert_same zero, minimap.texture(buffer, 0, width: 60)

    buffer.edit([[buffer.rope.line_start(1)...buffer.rope.line_start(1), "X"]])
    begin_frame(minimap, renderer, 2)
    assert_same zero, minimap.texture(buffer, 0, width: 60)
    refute_same one, minimap.texture(buffer, 1, width: 60)
    assert_same two, minimap.texture(buffer, 2, width: 60)

    before_row = buffer.rope.line_start(2)
    buffer.edit([[before_row...before_row, "new\n"]])
    begin_frame(minimap, renderer, 3)
    assert_same two, minimap.texture(buffer, 3, width: 60)

    newline = buffer.rope.line_start(3) - 1
    buffer.edit([[newline...(newline + 1), ""]])
    begin_frame(minimap, renderer, 4)
    refute_same two, minimap.texture(buffer, 2, width: 60)

    minimap.send(:edited, buffer, Canopus::Patch::Reload.new(buffer.rope, buffer.rope))
    assert_empty minimap.cached_rows(buffer)

    large = Canopus::Buffer.new("x\n" * (Canopus::Minimap::ENTRY_LIMIT + 4))
    empty_layout = Struct.new(:glyphs, :ascent).new([], 0)
    empty_system = Object.new
    empty_system.define_singleton_method(:layout_line) { |*, **| empty_layout }
    row = 0
    frame = 10
    while row < large.line_count
      begin_frame(minimap, empty_system, frame += 1)
      Canopus::Minimap::GENERATION_LIMIT.times do
        break if row >= large.line_count
        minimap.texture(large, row, width: 40)
        row += 1
      end
    end
    assert_operator minimap.cache_size, :<=, Canopus::Minimap::ENTRY_LIMIT
    listeners = large.instance_variable_get(:@listeners).length
    minimap.release(large)
    assert_equal listeners - 1, large.instance_variable_get(:@listeners).length
    assert_empty minimap.cached_rows(large)
  ensure
    minimap&.close
    renderer&.close
    buffer&.close
    large&.close
  end

  def test_search_and_decoration_markers_are_bounded_and_edits_clear_search
    @workspace = Canopus::Workspace.new(root: @root, settings: enabled_settings)
    editor = @workspace.open(@path)
    @workspace.palette_open(:search)
    @workspace.palette[:query] = "value_20"
    @workspace.palette_accept
    assert_equal [20, 200, 201, 202, 203, 204, 205, 206, 207, 208, 209],
      @workspace.minimap.search_rows(editor.buffer, editor.buffer.version)

    @window = window(width: 640)
    controller = Canopus::Controller.new(@workspace, @window)
    controller.tick
    bounds = controller.view.minimap_bounds.fetch(editor)[:bounds]
    git = Canopus::Decoration::Item.new(:gutter, nil, 10, nil, {color: "#00ff00", rows: 40}, 0, :git, nil)
    offset = editor.buffer.rope.line_start(30)
    diagnostic = Canopus::Decoration::Item.new(:highlight, offset...(offset + 1), nil, nil,
      {color: "#ff0000"}, 0, :diagnostics, nil)
    fills = []
    controller.view.stub(:fill, ->(area, color) { fills << [area, color] }) do
      controller.view.send(:paint_minimap_markers, editor, bounds, [git, diagnostic], {"show_diagnostics" => true})
    end
    assert_includes fills.map(&:last), "#00ff00"
    assert_includes fills.map(&:last), "#ff0000"
    assert_operator fills.map { |area, _| area.y }.uniq.length, :<=, bounds.height

    editor.insert_text("changed", auto_indent: false)
    assert_empty @workspace.minimap.search_rows(editor.buffer, editor.buffer.version)
  end

  def test_composite_undo_redo_remaps_unchanged_rows
    buffer = Canopus::Buffer.new("zero\none\ntwo\n")
    minimap = Canopus::Minimap.new
    system = empty_text_system
    begin_frame(minimap, system, 1)
    texture = minimap.texture(buffer, 2, width: 60)
    buffer.begin_undo_group
    buffer.edit([[0...0, "first\n"]])
    buffer.edit([[0...0, "second\n"]])
    buffer.end_undo_group
    begin_frame(minimap, system, 2)
    assert_same texture, minimap.texture(buffer, 4, width: 60)
    assert buffer.undo
    begin_frame(minimap, system, 3)
    assert_same texture, minimap.texture(buffer, 2, width: 60)
    assert buffer.redo
    begin_frame(minimap, system, 4)
    assert_same texture, minimap.texture(buffer, 4, width: 60)
  ensure
    minimap&.close
    buffer&.close
  end

  def test_render_identity_and_width_bound_cache_and_close_detaches
    buffer = Canopus::Buffer.new("value\n")
    minimap = Canopus::Minimap.new
    system = empty_text_system
    begin_frame(minimap, system, 1)
    first = minimap.texture(buffer, 0, width: 40)
    refute_same first, minimap.texture(buffer, 0, width: 50)
    assert_equal 2, minimap.cache_size

    minimap.begin_frame(2, text_system: system, font_size: 15, font_family: nil, scale_factor: 2)
    assert_equal 0, minimap.cache_size
    refute_same first, minimap.texture(buffer, 0, width: 40)
    listeners = buffer.instance_variable_get(:@listeners).length
    minimap.close
    assert_equal listeners - 1, buffer.instance_variable_get(:@listeners).length
    assert_equal 0, minimap.cache_size
  ensure
    minimap&.close
    buffer&.close
  end

  def test_click_drag_wheel_resize_fold_wrap_eof_and_close_preserve_selection
    @workspace = Canopus::Workspace.new(root: @root, settings: enabled_settings("soft_wrap" => true))
    editor = @workspace.open(@path)
    editor.display_map.fold(editor.buffer.rope.line_start(20)...editor.buffer.rope.line_start(80))
    editor.select(3)
    original = editor.primary.range
    first_pane = @workspace.active_pane
    @workspace.split(:horizontal)
    second_editor = @workspace.editor
    @window = window(width: 640)
    controller = Canopus::Controller.new(@workspace, @window)
    controller.tick

    area = controller.view.minimap_bounds.fetch(editor)[:bounds]
    bottom = Zaniah::Point.new(area.x + 4, area.bottom - 2)
    assert_equal :minimap, controller.view.hit(bottom)&.first
    controller.input(Zaniah::Input::MouseDown.new(bottom, :left, [], 1))
    assert_same first_pane, @workspace.active_pane
    assert_equal original, editor.primary.range
    assert_operator editor.scroll_y, :>, 0

    top = Zaniah::Point.new(area.x + 4, area.y + 2)
    controller.input(Zaniah::Input::MouseMove.new(top, []))
    assert_equal 0, editor.scroll_y
    controller.input(Zaniah::Input::MouseUp.new(top, :left, []))
    stopped = editor.scroll_y
    controller.input(Zaniah::Input::MouseMove.new(bottom, []))
    assert_equal stopped, editor.scroll_y

    before, other = editor.scroll_y, second_editor.scroll_y
    controller.input(Zaniah::Input::ScrollWheel.new(bottom, Zaniah::Point.new(0, 20), 8, []))
    assert_operator editor.scroll_y, :>, before
    assert_equal other, second_editor.scroll_y

    old = area
    @window.resize(720, 260)
    controller.tick
    refute_equal old.x, controller.view.minimap_bounds.fetch(editor)[:bounds].x

    editor.select(editor.buffer.rope.bytesize)
    area = controller.view.minimap_bounds.fetch(editor)[:bounds]
    controller.input(Zaniah::Input::MouseDown.new(Zaniah::Point.new(area.x + 2, area.y + area.height / 2), :left, [], 1))
    assert_equal editor.buffer.rope.bytesize, editor.primary.head
    @workspace.close_editor(editor)
    controller.input(Zaniah::Input::MouseMove.new(Zaniah::Point.new(area.x + 2, area.y + 2), []))
    controller.input(Zaniah::Input::MouseUp.new(Zaniah::Point.new(area.x + 2, area.y + 2), :left, []))
  end

  def test_stale_minimap_action_does_not_reactivate_a_hidden_tab
    @workspace = Canopus::Workspace.new(root: @root, settings: enabled_settings)
    editor = @workspace.open(@path)
    @window = window(width: 640)
    controller = Canopus::Controller.new(@workspace, @window)
    controller.tick
    area = controller.view.minimap_bounds.fetch(editor)[:bounds]
    point = Zaniah::Point.new(area.x + 2, area.bottom - 2)
    scroll = editor.scroll_y

    current = @workspace.new_buffer
    controller.input(Zaniah::Input::MouseDown.new(point, :left, [], 1))

    assert_same current, @workspace.editor
    assert_equal scroll, editor.scroll_y
    refute controller.instance_variable_get(:@minimap_drag)
  end

  def test_lazy_rope_and_fonts_without_outlines_do_not_copy_or_fail
    file = File.join(@root, "large.txt")
    File.write(file, "日本語" * 2_000 + "\nnext\n")
    rope = Canopus::LazyRope.new(file)
    rope.define_singleton_method(:to_s) { raise "full rope copy" }
    buffer = Canopus::Buffer.new("", path: file, read_only: true, rope: rope)
    minimap = Canopus::Minimap.new
    renderer = Zaniah::TextSystem::Renderer.new
    begin_frame(minimap, renderer, 1)
    assert minimap.texture(buffer, 0, width: 60)

    font = Object.new
    font.define_singleton_method(:units_per_em) { 1_000 }
    font.define_singleton_method(:outline) { |_| raise Alhena::UnsupportedFont, "bitmap only" }
    glyph = Zaniah::TextSystem::Glyph.new(font, 1, 0, 1, 0.0, 10.0)
    layout = Struct.new(:glyphs, :ascent).new([glyph], 10.0)
    system = Object.new
    system.define_singleton_method(:font) { font }
    system.define_singleton_method(:layout_line) { |*, **| layout }
    begin_frame(minimap, system, 2)
    assert minimap.texture(buffer, 1, width: 60)
  ensure
    minimap&.close
    renderer&.close
    buffer&.close
  end

  private

  def enabled_settings(extra = {})
    Canopus::Settings.new({"minimap" => {"enabled" => true, "width" => 80},
      "dock" => {"left" => {"visible" => false}}}.merge(extra))
  end

  def window(width: 640, height: 240)
    Zaniah::Platform.open_window(backend: :headless, width: width, height: height).tap do |current|
      current.text_system = Zaniah::TextSystem::Renderer.new
    end
  end

  def begin_frame(minimap, renderer, frame)
    minimap.begin_frame(frame, text_system: renderer, font_size: 14, font_family: nil, scale_factor: 1)
  end

  def empty_text_system
    layout = Struct.new(:glyphs, :ascent).new([], 0)
    Object.new.tap { |system| system.define_singleton_method(:layout_line) { |*, **| layout } }
  end
end

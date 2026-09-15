# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"

class WhitespaceRenderingTest < Minitest::Test
  MARKERS = %w[· → □].freeze

  def test_settings_default_schema_and_validation
    settings = Canopus::Settings.new
    assert_equal "boundary", settings["render_whitespace"]
    assert settings["render_ideographic_space"]
    assert_equal %w[none boundary selection all],
      Canopus::Settings.schema.dig("properties", "render_whitespace", "enum")
    assert_equal "boolean", Canopus::Settings.schema.dig("properties", "render_ideographic_space", "type")
    assert_raises(Canopus::Error) { Canopus::Settings.new("render_whitespace" => "visible") }
    assert_raises(Canopus::Error) { Canopus::Settings.new("render_ideographic_space" => nil) }
  end

  def test_all_four_modes_and_independent_ideographic_space
    source = " a b  c\td　e "
    expected = {
      "none" => %w[□],
      "boundary" => %w[· · · → □ ·],
      "selection" => %w[□],
      "all" => %w[· · · · → □ ·]
    }
    expected.each do |mode, markers|
      with_view(source, {"render_whitespace" => mode}) { |_workspace, _editor, window, _view| assert_equal markers, marker_runs(window) }
    end

    with_view(source, {"render_whitespace" => "all", "render_ideographic_space" => false}) do |_workspace, _editor, window, _view|
      refute_includes marker_runs(window), "□"
    end
  end

  def test_selection_and_language_override_control_ascii_markers
    source = "a b\tc　d"
    with_view(source, {"render_whitespace" => "selection"}, selection: 1...4) do |_workspace, _editor, window, _view|
      assert_equal %w[· → □], marker_runs(window)
    end
    with_view(source, {"render_whitespace" => "none", "languages" => {"text" => {"render_whitespace" => "all"}}}) do |_workspace, _editor, window, _view|
      assert_equal %w[· → □], marker_runs(window)
    end
  end

  def test_selection_uses_half_open_source_boundaries
    with_view("a b c", {"render_whitespace" => "selection"}, selection: 2...3) do |_workspace, _editor, window, _view|
      assert_empty marker_runs(window)
    end
    with_view("a b c", {"render_whitespace" => "selection"}, selection: 1...2) do |_workspace, _editor, window, _view|
      assert_equal %w[·], marker_runs(window)
    end
  end

  def test_inline_overlays_at_whitespace_offsets_do_not_duplicate_markers
    source = "a b\tc"
    overlays = [1, 3].map.with_index do |offset, priority|
      Canopus::Decoration::Item.new(:inline, offset...offset, nil, " [hint] ", {}, priority,
        :whitespace_test, nil)
    end
    with_view(source, {"render_whitespace" => "all"}, overlays: overlays) do |_workspace, editor, window, _view|
      assert_equal %w[· →], marker_runs(window)
      assert_equal 2, editor.display_map.row(0).metadata.length
    end
  end

  def test_headless_markers_keep_source_text_and_hit_coordinates
    source = "a\tb　c"
    with_view(source, {"render_whitespace" => "all"}) do |_workspace, editor, window, view|
      assert_equal source, editor.buffer.text
      assert_equal "a   b　c", editor.display_map.row(0).text
      offsets = {"→" => source.b.index("\t".b), "□" => source.b.index("　".b)}
      window.text_runs.select { |run| offsets.key?(run[2]) }.each do |x, y, marker, _color|
        point = view.offset_at(editor, Zaniah::Point.new(x + 0.1, y + 1))
        assert_equal offsets.fetch(marker), point, marker
      end
    end
  end

  def test_tui_renders_wrapped_markers_without_changing_mapping
    output = StringIO.new
    source = "prefix \tmiddle　suffix trailing "
    with_view(source, {"soft_wrap" => true, "render_whitespace" => "all"},
      backend: :tui, output: output, width: 144) do |_workspace, editor, window, _view|
      assert_operator editor.display_map.row_count, :>, 1
      assert_includes output.string, "→"
      assert_includes output.string, "□"
      [source.b.index("\t".b), source.b.index("　".b), source.bytesize].each do |offset|
        assert_equal offset, editor.display_map.to_buffer(editor.display_map.to_display(offset))
      end
      assert_includes window.text_system.runs.map { |run| run[2] }, "·"
    end
  end

  def test_tab_at_soft_wrap_boundary_is_rendered_on_the_continuation_row
    with_view("123456789\tend", {"soft_wrap" => true, "render_whitespace" => "all"},
      backend: :tui, output: StringIO.new, width: 144) do |_workspace, editor, window, _view|
      assert_equal ["123456789", "   end"], editor.display_map.each_row.map { |row, _index| row.text }
      assert_equal %w[→], window.text_system.runs.map { |run| run[2] }.select { |value| MARKERS.include?(value) }
    end
  end

  private

  def with_view(source, values, selection: nil, backend: :headless, output: nil, width: 640, overlays: nil)
    Dir.mktmpdir("canopus-whitespace-") do |root|
      workspace = Canopus::Workspace.new(root: root, settings: Canopus::Settings.new(values))
      editor = workspace.new_buffer
      editor.insert_text(source, auto_indent: false)
      editor.select(selection.begin, selection.end) if selection
      workspace.decorations.register(:whitespace_test) { overlays } if overlays
      options = {backend: backend, width: width, height: 220}
      options[:output] = output if output
      window = Zaniah::Platform.open_window(**options)
      window.text_system = Zaniah::TextSystem::Renderer.new if backend == :headless
      controller = Canopus::Controller.new(workspace, window)
      editor.language_document.stub(:poll, false) { controller.tick }
      yield workspace, editor, window, controller.view
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end

  def marker_runs(window)
    window.text_runs.map { |run| run[2] }.select { |value| MARKERS.include?(value) }
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"

class BracketDecorationTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-brackets-")
    @path = File.join(@root, "sample.js")
    File.write(@path, "const value = [\n\t(inner)\n]\n")
    @settings = Canopus::Settings.new("tab_size" => 4)
    @workspace = Canopus::Workspace.new(root: @root, settings: @settings)
    @editor = @workspace.open(@path)
    @editor.select(@editor.buffer.rope.line_start(1) + 2)
    analyze
  end

  def teardown
    @workspace.close
    @window&.on_close { true }
    @window&.close
    FileUtils.remove_entry(@root)
  end

  def analyze
    document = @editor.language_document
    document.request(first_line: 0, last_line: @editor.buffer.line_count - 1, syntax: true)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    while document.pending?
      @workspace.invalidate_brackets(@editor.buffer) if document.poll
      raise "structure analysis timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.005
    end
  end

  def items(rows = 0...@editor.buffer.line_count)
    @workspace.decorations.items_for(@editor.buffer, rows, context: @editor)
      .select { |item| item.source == :bracket }
  end

  def test_antares_depth_colors_pairs_and_active_tab_guide
    glyphs = items.reject { |item| item.style[:guide] }
    assert_equal ["[", "]", "(", ")"], glyphs.map { |item| @editor.buffer.rope.byteslice(item.range).to_s }
    assert_equal [1, 1, 2, 2], glyphs.map { |item| item.style[:color].to_s.split(".").last.to_i }
    assert glyphs.all? { |item| item.kind == :highlight && item.style[:foreground] }

    guides = items.select { |item| item.style[:guide] }
    assert_equal [4], guides.map { |item| @editor.display_map.to_display(item.range.begin).column }
    assert guides.first.style[:active]
    assert_equal :"indent.guide.active", guides.first.style[:color]
  end

  def test_bracket_palette_cycles_after_six_depths
    source = "([{([{(value)}])}])\n"
    @editor.buffer.edit([[0...@editor.buffer.rope.bytesize, source]])
    analyze

    colors = items.reject { |item| item.style[:guide] }.map { |item| item.style[:color] }
    assert_equal [1, 2, 3, 4, 5, 6, 1].flat_map { |depth| [depth, depth] },
      colors.map { |color| color.to_s.split(".").last.to_i }
  end

  def test_active_guide_follows_the_structure_on_blank_and_deeper_lines
    source = "outer = [\n    inner = [\n            continuation\n\n    ]\n]\n"
    @editor.buffer.edit([[0...@editor.buffer.rope.bytesize, source]])
    analyze

    @editor.select(@editor.buffer.rope.line_start(2) + 12)
    active = items.select { |item| item.style[:active] }
    assert_equal [8], active.map { |item| @editor.display_map.to_display(item.range.begin).column }.uniq

    @editor.select(@editor.buffer.rope.line_start(3))
    active = items.select { |item| item.style[:active] }
    assert_equal [8], active.map { |item| @editor.display_map.to_display(item.range.begin).column }.uniq
  end

  def test_edit_hides_stale_pairs_and_close_drops_cached_items
    refute_empty items
    opening = @editor.buffer.text.index("(")
    @editor.buffer.edit([[opening...opening + 1, "{"]])
    assert_empty items.reject { |item| item.style[:guide] }
    analyze
    assert_equal ["[", "]"], items.reject { |item| item.style[:guide] }
      .map { |item| @editor.buffer.rope.byteslice(item.range).to_s }

    buffer = @editor.buffer
    @workspace.close_editor(@editor, discard: true)
    cache = @workspace.decorations.instance_variable_get(:@cache)
    refute cache.keys.any? { |key| key[0] == :bracket && key[1] == buffer.object_id }
  end

  def test_settings_disable_layers_and_reject_invalid_values
    assert @settings["bracket_colorization"]
    assert_equal({"enabled" => true, "active" => true}, @settings["indent_guides"])
    @settings.merge!("bracket_colorization" => false,
      "indent_guides" => {"enabled" => false, "active" => false})
    @workspace.apply_settings
    assert_empty items
    assert_raises(Canopus::Error) { Canopus::Settings.new("bracket_colorization" => "yes") }
    assert_raises(Canopus::Error) { Canopus::Settings.new("indent_guides" => {"enabled" => nil}) }
    assert_equal "boolean", Canopus::Settings.schema.dig("properties", "indent_guides", "properties", "active", "type")

    theme = File.join(@root, "theme.json")
    File.write(theme, JSON.generate("style" => {"bracket.6" => "#123456", "indent.guide.active" => "#654321"}))
    assert_equal "#123456", Canopus::Theme.load(theme)[:"bracket.6"]
    assert_equal "#654321", Canopus::Theme.load(theme)[:"indent.guide.active"]
  end

  def test_context_changes_do_not_reuse_stale_structural_decorations
    @editor.buffer.edit([[0...@editor.buffer.rope.bytesize, "    value\n"]])
    @editor.select(0)
    assert_equal 1, items.count { |item| item.style[:guide] }

    @editor.tab_size = 2
    @editor.display_map.tab_size = 2
    assert_equal 2, items.count { |item| item.style[:guide] }

    @editor.buffer.edit([[0...@editor.buffer.rope.bytesize, "value = (other)\n"]])
    analyze
    refute_empty items.reject { |item| item.style[:guide] }
    @editor.language = Canopus::Language::PLAIN
    assert_empty items.reject { |item| item.style[:guide] }
  end

  def test_large_read_only_buffer_skips_structural_work
    path = File.join(@root, "large.js")
    File.write(path, "\tvalue()\n")
    buffer = Canopus::Buffer.open(path, large_file_threshold: 0)
    editor = Canopus::Editor.new(buffer)
    assert_empty @workspace.bracket_decorations(buffer, 0...1, editor)
    refute editor.language_document.pending?
  ensure
    editor&.dispose
    buffer&.close
  end

  def test_display_positions_survive_wrap_and_fold
    map = @editor.display_map
    map.wrap_width = 6
    guide = items.find { |item| item.style[:guide] }
    assert_equal 4, map.to_display(guide.range.begin).column
    items.reject { |item| item.style[:guide] }.each do |item|
      assert_equal item.range.begin, map.to_buffer(map.to_display(item.range.begin))
    end

    outer = @editor.language_document.brackets.find { |pair| pair.depth.zero? }
    map.fold(outer.open_range.end...outer.close_range.begin)
    assert_equal outer.close_range.begin, map.to_buffer(map.to_display(outer.close_range.begin))
  end

  def test_headless_view_paints_bracket_spans_and_active_guide
    @window = Zaniah::Platform.open_window(backend: :headless, width: 640, height: 220)
    renderer = Zaniah::TextSystem::Renderer.new
    painted = []
    original = renderer.method(:paint_line)
    renderer.define_singleton_method(:paint_line) do |*arguments, **options|
      painted.concat(options.fetch(:spans, []))
      original.call(*arguments, **options)
    end
    @window.text_system = renderer
    controller = Canopus::Controller.new(@workspace, @window)
    @editor.language_document.stub(:poll, false) { controller.tick }

    colors = painted.map(&:last)
    assert_includes colors, @workspace.theme[:"bracket.1"]
    assert_includes colors, @workspace.theme[:"bracket.2"]
    active = Zaniah::Color.parse(@workspace.theme[:"indent.guide.active"]).to_a
    guides = @window.scene.quads.each_slice(Zaniah::Scene::QUAD_STRIDE)
      .select { |quad| quad[4, 4] == active }
    assert guides.any? { |quad| quad[2] == 2 && quad[3] > 0 }
  end

  def test_tui_view_paints_indent_guides_as_cells
    output = StringIO.new
    @window = Zaniah::Platform.open_window(backend: :tui, output: output, width: 640, height: 220)
    controller = Canopus::Controller.new(@workspace, @window)
    @editor.language_document.stub(:poll, false) { controller.tick }
    assert_includes output.string, "│"
    assert_includes @window.text_system.runs.map { |run| run[2] }, "("
  end

  def test_sync_structure_preserves_unicode_byte_offsets_and_pair_identity
    source = "é(値) # [ignored]\n"
    buffer = Canopus::Buffer.new(source, path: "unicode.rb")
    document = Canopus::Language::Document.new(buffer, background: false)
    opening, closing = source.b.index("("), source.b.index(")")
    assert_equal "(値)", source.byteslice(document.bracket_at(opening))
    assert_same document.bracket_at(opening), document.bracket_at(closing)
    assert_equal [[opening...opening + 1, closing...closing + 1, 0]],
      document.brackets.map { |pair| [pair.open_range, pair.close_range, pair.depth] }
  ensure
    document&.dispose
    buffer&.close
  end
end

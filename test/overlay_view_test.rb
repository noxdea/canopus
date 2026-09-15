# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class OverlayViewTest < Minitest::Test
  def test_inline_and_block_decorations_render_and_click_without_selecting_content
    Dir.mktmpdir("canopus-overlay-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      workspace.register_panel(:problems, side: :right) { Zaniah::Text.new("Problems") }
      workspace.panels.badge(:problems, 3)
      workspace.panels.show(:problems)
      window = Zaniah::Platform.open_window(backend: :headless, width: 800, height: 220)
      window.text_system = Zaniah::TextSystem::Renderer.new
      controller = Canopus::Controller.new(workspace, window)
      editor = workspace.editor
      editor.insert_text("abcd\nsecond", auto_indent: false)
      clicks = []
      callback = ->(_editor, offset) { clicks << offset }
      workspace.decorations.register(:overlay_test) do |_buffer, _rows|
        [Canopus::Decoration::Item.new(:inline, 1...1, nil, "[hint]", {color: :accent}, 0, :overlay_test, callback),
          Canopus::Decoration::Item.new(:block, nil, 1, "lens", {height: 20, position: :above}, 0, :overlay_test, callback)]
      end
      workspace.decorations.register(:breakpoint) do |_buffer, _rows|
        [Canopus::Decoration::Item.new(:gutter, nil, 0, "breakpoint", :accent, 0, :breakpoint, nil)]
      end
      workspace.decorations.register(:debug_position) do |_buffer, _rows|
        [Canopus::Decoration::Item.new(:line, nil, 1, nil, "#33445566", 0, :debug_position, nil)]
      end

      editor.language_document.stub(:poll, false) { controller.tick }

      assert_includes window.text_runs.map { |run| run[2] }, "[hint]"
      assert_includes window.text_runs.map { |run| run[2] }, "lens"
      regions = controller.view.regions.select { |_bounds, action| action.first == :decoration }
      assert_equal 2, regions.length
      inline_bounds = regions.find { |_bounds, action| action.last == 1 }.first
      assert_equal 1, controller.view.offset_at(editor,
        Zaniah::Point.new(inline_bounds.x + inline_bounds.width / 2, inline_bounds.y + 1))
      selection = editor.primary
      regions.each do |bounds, _action|
        window.input(Zaniah::Input::MouseDown.new(Zaniah::Point.new(bounds.x + 1, bounds.y + 1), :left, [], 1))
      end
      assert_equal [1, editor.buffer.rope.line_start(1)], clicks
      assert_equal selection, editor.primary

      expected_ids = %w[syrma:panel:problems syrma:panel:problems:badge syrma:decoration:inline:0
        syrma:decoration:gutter:0:breakpoint syrma:decoration:line:1:debug_position]
      nodes = descendants(controller.view)
      expected_ids.each do |test_id|
        node = nodes.find { |element| element.test_id == test_id }
        refute_nil node, test_id
        assert_operator node.layout_node.bounds.width, :>, 0, test_id
        assert_operator node.layout_node.bounds.height, :>, 0, test_id
        refute_nil node.resolved_style, test_id
      end

      png = File.join(root, "overlay.png")
      window.write_png(png)
      assert_equal "\x89PNG\r\n\x1a\n".b, File.binread(png, 8)
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end

  def test_visible_fold_suffix_supplies_its_inline_decorations
    Dir.mktmpdir("canopus-fold-overlay-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      window = Zaniah::Platform.open_window(backend: :headless, width: 800, height: 220)
      window.text_system = Zaniah::TextSystem::Renderer.new
      controller = Canopus::Controller.new(workspace, window)
      editor = workspace.editor
      editor.insert_text("one\nhidden\nlast", auto_indent: false)
      editor.display_map.fold(3...11)
      workspace.decorations.register(:fold_suffix) do |_buffer, rows|
        if rows.cover?(2)
          [Canopus::Decoration::Item.new(:inline, 11...11, nil, "[hint]", {}, 0, :fold_suffix, nil)]
        else
          []
        end
      end

      editor.language_document.stub(:poll, false) { controller.tick }

      assert_equal "one…last", editor.display_map.row(0).text
      assert_equal ["[hint]"], editor.display_map.row(0).metadata.map { |placement| placement.item.content }
      assert_includes window.text_runs.map { |run| run[2] }, "[hint]"
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end

  private

  def descendants(element) = [element, *element.children.flat_map { |child| descendants(child) }]
end

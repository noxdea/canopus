# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class BlockSelectionTest < Minitest::Test
  def test_block_selection_enumerates_rows_in_both_directions
    first = Canopus::DisplayPoint.new(3, 4)
    last = Canopus::DisplayPoint.new(1, 2)

    assert_equal [
      [Canopus::DisplayPoint.new(1, 4), Canopus::DisplayPoint.new(1, 2)],
      [Canopus::DisplayPoint.new(2, 4), Canopus::DisplayPoint.new(2, 2)],
      [Canopus::DisplayPoint.new(3, 4), Canopus::DisplayPoint.new(3, 2)]
    ], Canopus::BlockSelection.new(first, last).each.to_a
  end

  def test_rectangle_keeps_upward_wrapped_unicode_rows_separate
    editor = Canopus::Editor.new(Canopus::Buffer.new("ab日d\nxy\nmnop"), wrap_width: 3)

    editor.rectangle(Canopus::DisplayPoint.new(3, 2), Canopus::DisplayPoint.new(0, 1))

    assert_equal [[2, 1], [6, 5], [9, 8], [12, 11]],
      editor.selections.map { |selection| [selection.anchor, selection.head] }
    assert editor.selections.all?(&:reversed?)
    editor.insert_text("Z", auto_indent: false)
    assert_equal "aZ日Z\nxZ\nmZop", editor.buffer.text
  ensure
    editor&.dispose
  end

  def test_add_cursor_preserves_display_column_across_short_lines
    editor = Canopus::Editor.new(Canopus::Buffer.new("abcdef\nx\nabcdef"))
    editor.select(5)

    editor.add_cursor(:down)
    editor.add_cursor(:down)

    assert_equal [5, 8, 14], editor.selections.map(&:head)
    assert_equal [nil, 5, 5], editor.selections.map(&:goal)
    editor.add_cursor(:down)
    assert_equal 3, editor.selections.length
    assert_raises(ArgumentError) { editor.add_cursor(:left) }
  ensure
    editor&.dispose
  end

  def test_block_selection_and_vertical_cursors_skip_virtual_rows
    editor = Canopus::Editor.new(Canopus::Buffer.new("abc\ndef"))
    editor.display_map.insert_block(:message, row: 0, text: "note\nmore")

    editor.rectangle(Canopus::DisplayPoint.new(0, 1), Canopus::DisplayPoint.new(3, 2))
    assert_equal [1...2, 5...6], editor.selections.map(&:range)
    editor.insert_text("X", auto_indent: false)
    assert_equal "aXc\ndXf", editor.buffer.text

    editor.undo
    editor.select(1)
    editor.add_cursor(:down)
    assert_equal [1, 5], editor.selections.map(&:head)
    editor.select(5)
    editor.add_cursor(:up)
    assert_equal [1, 5], editor.selections.map(&:head)
  ensure
    editor&.dispose
  end

  def test_alt_drag_and_ctrl_alt_arrows_route_without_changing_vim
    Dir.mktmpdir("canopus-block-selection-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      window = Zaniah::Platform.open_window(width: 640, height: 300)
      controller = Canopus::Controller.new(workspace, window)
      editor = workspace.editor
      editor.insert_text("abcd\nefgh\nijkl", auto_indent: false)
      editor.select(0)
      offsets = [1, 13]
      hit = [:editor, workspace.active_pane, editor]

      controller.view.stub(:hit, hit) do
        controller.view.stub(:offset_at, ->(*) { offsets.shift }) do
          controller.input(Zaniah::Input::MouseDown.new(Zaniah::Point.new(1, 1), :left, [:alt], 1))
          controller.input(Zaniah::Input::MouseMove.new(Zaniah::Point.new(2, 2), [:alt]))
          controller.input(Zaniah::Input::MouseUp.new(Zaniah::Point.new(2, 2), :left, [:alt]))
        end
      end
      assert_equal [1...3, 6...8, 11...13], editor.selections.map(&:range)

      editor.select(0)
      offsets = [1, 13]
      controller.view.stub(:hit, hit) do
        controller.view.stub(:offset_at, ->(*) { offsets.shift }) do
          controller.input(Zaniah::Input::MouseDown.new(Zaniah::Point.new(1, 1), :left, [], 1))
          controller.input(Zaniah::Input::MouseMove.new(Zaniah::Point.new(2, 2), []))
          controller.input(Zaniah::Input::MouseUp.new(Zaniah::Point.new(2, 2), :left, []))
        end
      end
      assert_equal [1...13], editor.selections.map(&:range)

      editor.select(6)
      controller.key("ctrl-alt-up")
      controller.key("ctrl-alt-down")
      assert_equal [1, 6, 11], editor.selections.map(&:head)
      controller.tick
      cursor = Zaniah::Color.parse(workspace.theme[:cursor]).to_a
      carets = window.scene.quads.each_slice(Zaniah::Scene::QUAD_STRIDE).count { |quad| quad[4, 4] == cursor }
      assert_equal 3, carets

      workspace.settings.merge!("vim_mode" => true)
      editor.select(6)
      controller.key("ctrl-alt-down")
      assert_equal [6], editor.selections.map(&:head)
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end
end

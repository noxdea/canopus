# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class MultiCursorExpansionTest < Minitest::Test
  def test_selected_line_edges_are_unique_for_reversed_overlapping_unicode_selections
    editor = Canopus::Editor.new(Canopus::Buffer.new("alpha\n日本\r\nomega\n"))
    rope = editor.buffer.rope
    line_end = ->(row) { rope.line_start(row) + editor.buffer.line(row).bytesize }
    selections = [
      Canopus::Selection.new(1, line_end.call(2), 2, nil),
      Canopus::Selection.new(2, rope.line_start(1), line_end.call(1), nil),
      Canopus::Selection.new(3, line_end.call(1), rope.line_start(2), nil)
    ]
    editor.set_selections(selections, merge: false)

    editor.add_cursors_to_selected_lines(:start)
    assert_equal [0, 6, 14], editor.selections.map(&:head)

    editor.set_selections(selections, merge: false)
    editor.add_cursors_to_selected_lines(:end)
    assert_equal [5, 12, 19], editor.selections.map(&:head)
    assert_raises(ArgumentError) { editor.add_cursors_to_selected_lines(:middle) }
  ensure
    editor&.dispose
  end

  def test_regex_matches_keep_adjacent_unicode_selections_and_zero_width_cursors
    editor = Canopus::Editor.new(Canopus::Buffer.new("a日🙂"))

    assert_equal [0...1, 1...4, 4...8], editor.select_matches(/a|日|🙂/)
    assert_equal [0...1, 1...4, 4...8], editor.selections.map(&:range)

    assert_equal [0...0, 1...1, 4...4], editor.select_matches(/(?=.)/)
    assert_equal [0, 1, 4], editor.selections.map(&:head)
  ensure
    editor&.dispose
  end

  def test_regex_failures_leave_selections_unchanged
    editor = Canopus::Editor.new(Canopus::Buffer.new("aaaa"))
    editor.select(1, 3)
    before = editor.selections

    timeout = ->(_pattern, &) { raise Regexp::TimeoutError, "timeout" }
    Canopus.stub(:with_regexp_timeout, timeout) do
      assert_raises(Regexp::TimeoutError) { editor.select_matches(/a+/) }
    end
    assert_equal before, editor.selections
    assert_raises(RegexpError) { Regexp.new("[") }
    assert_equal before, editor.selections
  ensure
    editor&.dispose
  end

  def test_commands_route_through_the_palette_and_stay_out_of_vim_mode
    Dir.mktmpdir("canopus-multi-cursor-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      window = Zaniah::Platform.open_window(width: 640, height: 260)
      controller = Canopus::Controller.new(workspace, window)
      workspace.editor.insert_text("one\ntwo one", auto_indent: false)
      workspace.editor.select(1, 7)

      workspace.call("edit.add_cursors_to_line_ends")
      assert_equal [3, 11], workspace.editor.selections.map(&:head)

      workspace.call("edit.select_all_regex_matches")
      assert_equal :regex_matches, workspace.palette[:kind]
      controller.input_text("o(?:ne|)")
      controller.key("enter")
      assert_equal [0...3, 6...7, 8...11], workspace.editor.selections.map(&:range)

      before = workspace.editor.selections
      workspace.call("edit.select_all_regex_matches")
      controller.input_text("[")
      controller.input(Zaniah::Input::KeyDown.new("enter", false))
      assert_equal before, workspace.editor.selections
      assert_nil workspace.palette
      refute_empty workspace.message

      workspace.settings.merge!("vim_mode" => true)
      ids = workspace.commands.each(context: workspace.command_context).map(&:id)
      refute_includes ids, "edit.add_cursors_to_line_starts"
      refute_includes ids, "edit.add_cursors_to_line_ends"
      refute_includes ids, "edit.select_all_regex_matches"
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end
end

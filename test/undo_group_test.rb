# frozen_string_literal: true
require_relative "test_helper"

class UndoGroupTest < Minitest::Test
  def test_nested_groups_cross_time_and_kind_without_absorbing_previous_edit
    buffer = Canopus::Buffer.new("word")
    buffer.edit([[4...4, "!"]], time: 0, kind: :typing, group: true)
    buffer.begin_undo_group
    buffer.edit([[0...4, ""]], time: 1, kind: :delete)
    buffer.begin_undo_group
    buffer.edit([[0...0, "new"]], time: 100, kind: :typing, group: true)
    buffer.end_undo_group
    buffer.edit([[3...3, " text"]], time: 500, kind: :paste)
    buffer.end_undo_group
    assert_equal 2, buffer.history.length
    buffer.undo
    assert_equal "word!", buffer.text
    buffer.redo
    assert_equal "new text!", buffer.text
    assert_raises(Canopus::Error) { buffer.end_undo_group }
  end
  def test_multi_buffer_groups_share_source_undo_boundaries
    source = Canopus::Buffer.new("word")
    buffer = Canopus::MultiBuffer.new(excerpts: [[source, 0...4, "Source"]])
    first = buffer.excerpts.first.view_start
    buffer.begin_undo_group
    buffer.edit([[first...(first + 4), "new"]])
    buffer.edit([[(first + 3)...(first + 3), " text"]])
    buffer.end_undo_group
    assert_equal "new text", source.text
    buffer.undo
    assert_equal "word", source.text
    buffer.redo
    assert_equal "new text", source.text
    buffer.close
  end
end

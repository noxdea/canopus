# frozen_string_literal: true

require_relative "test_helper"

class DisplayMapOverlayTest < Minitest::Test
  class Font
    attr_reader :calls
    def initialize = @calls = []
    def advance_width(codepoints, size:)
      @calls << [codepoints, size]
      codepoints.length * 7
    end
  end

  def inline(offset, content = "[]", style = {}, priority: 0, **styles)
    Canopus::Decoration::Item.new(:inline, offset...offset, nil, content, style.merge(styles), priority, :test, nil)
  end

  def block(row, height:, position: :above)
    Canopus::Decoration::Item.new(:block, nil, row, "lens", {height: height, position: position}, 0, :test, nil)
  end

  def test_inline_width_participates_in_wrap_and_coordinate_conversion
    font = Font.new
    editor = Canopus::Editor.new(Canopus::Buffer.new("abcd"), wrap_width: 3)
    changed = editor.display_map.set_overlays([inline(1)], font: font, font_size: 10, line_height: 10)

    assert changed
    assert_equal [["[".ord, "]".ord], 10], font.calls.first
    assert_equal %w[a bcd], editor.display_map.each_row.map { |row, _| row.text }
    placement = editor.display_map.row(0).metadata.fetch(0)
    assert_equal [1, 14.0, 2.0], [placement.offset, placement.width, placement.cell_width]
    assert_equal Canopus::DisplayPoint.new(0, 1), editor.display_map.to_display(1)
    assert_equal 1, editor.display_map.to_buffer(Canopus::DisplayPoint.new(0, 1))
    refute editor.display_map.set_overlays([inline(1)], font: font, font_size: 10, line_height: 10)
    assert_equal 1, font.calls.length

    editor.select(1)
    editor.move(:down)
    assert_equal 2, editor.primary.head
  ensure
    editor&.dispose
  end

  def test_before_aligned_overlay_owns_its_wrapped_boundary
    map = Canopus::DisplayMap.new(Canopus::Buffer.new("abcd"), wrap_width: 3,
      background_threshold: nil)
    map.set_overlays([inline(1, "[]", align: :before)], font_size: 10, line_height: 10)

    assert_equal %w[a b cd], map.each_row.map { |row, _| row.text }
    assert_equal Canopus::DisplayPoint.new(1, 0), map.to_display(1)
    assert_equal 1, map.to_buffer(Canopus::DisplayPoint.new(1, 0))
  ensure
    map&.dispose
  end

  def test_same_offset_inlines_sort_by_priority_and_preserve_input_order_for_ties
    map = Canopus::DisplayMap.new(Canopus::Buffer.new("ab"), background_threshold: nil)
    map.set_overlays([inline(1, "later first", priority: 10), inline(1, "early", priority: 0),
      inline(1, "later second", priority: 10)], font_size: 10, line_height: 10)

    assert_equal ["early", "later first", "later second"],
      map.row(0).metadata.map { |placement| placement.item.content }
  ensure
    map&.dispose
  end

  def test_block_height_and_position_change_display_rows_without_becoming_text
    map = Canopus::DisplayMap.new(Canopus::Buffer.new("a\nb"), background_threshold: nil)
    map.set_overlays([block(1, height: 25)], font_size: 10, line_height: 10)

    assert_equal %i[text overlay_block overlay_block_continuation overlay_block_continuation text],
      map.each_row.map { |row, _| row.kind }
    assert_equal Canopus::DisplayPoint.new(4, 0), map.to_display(2)
    assert_equal 2, map.to_buffer(Canopus::DisplayPoint.new(2, 0))
  ensure
    map&.dispose
  end

  def test_replacing_one_row_of_overlays_only_relays_out_that_source_row
    map = Canopus::DisplayMap.new(Canopus::Buffer.new("a\nb\nc"), background_threshold: nil)
    map.set_overlays([inline(2, "x")], font_size: 10, line_height: 10)
    assert_equal 1, map.recomputed_lines

    map.set_overlays([inline(2, "xx")], font_size: 10, line_height: 10)
    assert_equal 1, map.recomputed_lines
  ensure
    map&.dispose
  end

  def test_removing_an_overlay_after_its_source_row_was_deleted
    buffer = Canopus::Buffer.new("a\nb\nc")
    map = Canopus::DisplayMap.new(buffer, background_threshold: nil)
    map.set_overlays([block(2, height: 10)], font_size: 10, line_height: 10)

    buffer.edit([[0...buffer.rope.bytesize, "x"]])

    assert map.set_overlays([], font_size: 10, line_height: 10)
    assert_equal [[:text, "x"]], map.each_row.map { |row, _| [row.kind, row.text] }
    assert_equal 0, map.recomputed_lines
  ensure
    map&.dispose
  end

  def test_overlay_wrap_keeps_tab_projection_and_round_trips_offsets
    map = Canopus::DisplayMap.new(Canopus::Buffer.new("a\tbc"), tab_size: 4,
      wrap_width: 5, background_threshold: nil)
    map.set_overlays([inline(2)], font_size: 10, line_height: 10)

    assert_equal ["a  ", " bc"], map.each_row.map { |row, _| row.text }
    assert_equal [0, 1, 1, 1], map.row(0).offsets
    assert_equal Canopus::DisplayPoint.new(1, 1), map.to_display(2)
    assert_equal 2, map.to_buffer(Canopus::DisplayPoint.new(1, 1))
  ensure
    map&.dispose
  end

  def test_folded_overlays_are_hidden_and_visible_suffix_overlays_follow_the_fold_root
    buffer = Canopus::Buffer.new("one\nhidden\nlast")
    map = Canopus::DisplayMap.new(buffer, background_threshold: nil)
    map.fold(3...11)
    map.set_overlays([inline(5, "hidden"), inline(11, "shown")], font_size: 10, line_height: 10)

    assert_equal "one…last", map.row(0).text
    assert_equal ["shown"], map.row(0).metadata.map { |placement| placement.item.content }
    assert_equal 3, map.recomputed_lines
  ensure
    map&.dispose
  end

  def test_overlay_inputs_reject_invalid_items_and_geometry
    map = Canopus::DisplayMap.new(Canopus::Buffer.new("a"), background_threshold: nil)

    assert_raises(TypeError) { map.set_overlays([Object.new]) }
    assert_raises(ArgumentError) { map.set_overlays([inline(0, "x", padding_left: -1)]) }
    assert_raises(ArgumentError) { map.set_overlays([inline(0, "", width: 0)]) }
    assert_raises(ArgumentError) { map.set_overlays([inline(0, "x", height: 11)], line_height: 10) }
    combining = Canopus::DisplayMap.new(Canopus::Buffer.new("e\u0301"), background_threshold: nil)
    assert_raises(ArgumentError) { combining.set_overlays([inline(1)]) }
  ensure
    map&.dispose
    combining&.dispose
  end
end

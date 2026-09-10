# frozen_string_literal: true
require_relative "test_helper"

class TerminalUnicodeTest < Minitest::Test
  def test_split_utf8_graphemes_keep_correct_cursor_and_continuation_cells
    grid = Canopus::Terminal::Grid.new(columns: 30, rows: 2)
    terminal = Canopus::Terminal::VT.new(grid)
    text = "🇯🇵👩🏽‍💻1️⃣e\u0301A"
    text.bytes.each { |byte| terminal.feed(byte.chr) }
    assert_equal Zaniah::Unicode.width(text), grid.cursor_x
    assert_equal text, grid.lines.first
    assert_equal [2, 0, 2, 0, 2, 0, 1, 1], grid.cells.first.first(8).map(&:width)
  end
  def test_emoji_presentation_growth_at_right_margin_wraps_as_one_cluster
    grid = Canopus::Terminal::Grid.new(columns: 3, rows: 2)
    terminal = Canopus::Terminal::VT.new(grid)
    terminal.feed("ab❤\ufe0fx")
    assert_equal "ab", grid.lines.first
    assert_equal "❤️x", grid.lines.last
  end
end

# frozen_string_literal: true
require_relative "test_helper"

class LanguageResultsTest < Minitest::Test
  def test_moving_a_block_invalidates_both_old_and_new_rows
    buffer = Canopus::Buffer.new("first\nsecond\nthird")
    map = Canopus::DisplayMap.new(buffer)
    map.insert_block(:same, row: 0, text: "old")
    map.insert_block(:same, row: 2, text: "new")
    assert_equal ["first", "second", "third", "new"], (0...map.row_count).map { |row| map.row(row).text }
  ensure
    map&.dispose
  end
end

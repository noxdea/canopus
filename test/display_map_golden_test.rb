# frozen_string_literal: true

require_relative "test_helper"
require "json"

class DisplayMapGoldenTest < Minitest::Test
  FIXTURE = JSON.parse(File.read(File.expand_path("fixtures/display_map.json", __dir__))).freeze

  def test_fold_wrap_tab_block_and_coordinates_match_the_fixture
    buffer = Canopus::Buffer.new("ab\tcdef\nhidden one\nhidden two\nlast\tline\n")
    map = Canopus::DisplayMap.new(buffer, tab_size: 4, wrap_width: 5, background_threshold: nil)
    map.fold(buffer.rope.line_start(1)...buffer.rope.line_start(3))
    map.insert_block(:diagnostic, row: 4, text: "note\nmore", kind: :diagnostic)

    actual = {
      "rows" => map.each_row.map do |row, index|
        [index, map.source_row(index), row.text, row.offsets, row.kind.to_s, row.metadata&.to_s]
      end,
      "buffer_to_display" => [0, 2, 3, 7, 8, 20, 30, 31, 40].map do |offset|
        point = map.to_display(offset)
        [offset, point.row, point.column]
      end,
      "display_to_buffer" => [[0, 0], [0, 3], [0, 4], [1, 3], [2, 1], [3, 2], [4, 2], [6, 2]].map do |row, column|
        [row, column, map.to_buffer(Canopus::DisplayPoint.new(row, column))]
      end
    }

    assert_equal FIXTURE, actual
  ensure
    map&.dispose
  end
end

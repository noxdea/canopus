# frozen_string_literal: true
require_relative "test_helper"

class LanguageResultsTest < Minitest::Test
  def test_inlay_results_replace_old_blocks_and_empty_results_remove_them
    Dir.mktmpdir("canopus-inlay-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.new_buffer
      editor.insert_text("first\nsecond\nthird")
      map = editor.display_map
      map.insert_block(:plugin, row: 0, text: "keep", kind: :inlay)
      hint = ->(row, text) { {"position" => {"line" => row, "character" => 0}, "label" => text} }
      display = ->(items) { workspace.send(:display_language_result, :inlayHint, items, nil, editor) }
      display.call([hint.call(0, "old"), hint.call(2, "trailing")])
      assert_equal 6, map.row_count
      display.call([hint.call(1, "new")])
      assert_equal 5, map.row_count
      rows = (0...map.row_count).map { |row| map.row(row).text }
      assert_includes rows, "new"
      refute_includes rows, "old"
      refute_includes rows, "trailing"
      assert_raises(Canopus::Error) { display.call([hint.call(99, "invalid")]) }
      assert_equal "new", map.block_map.blocks[[:inlay, 0]].text
      [42, {}, [nil], [hint.call(1, [{"value" => 42}])], [hint.call(1, [{"value" => nil}])]].each do |invalid|
        assert_raises(Canopus::Error) { display.call(invalid) }
        assert_equal "new", map.block_map.blocks[[:inlay, 0]].text
      end
      display.call([])
      assert_equal [:plugin], map.block_map.blocks.keys
      assert_equal 4, map.row_count
    ensure
      workspace&.close
    end
  end

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

# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "json"

class EditorTest < Minitest::Test
  def test_multiple_cursors_edit_and_history_restore_positions
    buffer = Canopus::Buffer.new("abc\ndef")
    editor = Canopus::Editor.new(buffer)
    editor.select(1).select(5, add: true)
    before = editor.selections
    editor.insert_text("🙂")
    assert_equal "a🙂bc\nd🙂ef", buffer.text
    assert_equal [5, 13], editor.selections.map(&:head)
    editor.undo
    assert_equal "abc\ndef", buffer.text
    assert_equal before, editor.selections
    editor.redo
    editor.delete_backward
    assert_equal "abc\ndef", buffer.text
    editor.undo
    assert_equal [5, 13], editor.selections.map(&:head)
  end

  def test_grapheme_movement_and_backspace
    editor = Canopus::Editor.new(Canopus::Buffer.new("a👨‍👩‍👧‍👦e\u0301日"))
    editor.move(:file_end)
    editor.delete_backward
    assert_equal "a👨‍👩‍👧‍👦e\u0301", editor.buffer.text
    editor.delete_backward
    assert_equal "a👨‍👩‍👧‍👦", editor.buffer.text
    editor.move(:left)
    assert_equal 1, editor.primary.head
    editor.delete_forward
    assert_equal "a", editor.buffer.text
  end

  def test_display_transform_roundtrip_and_incremental_update
    buffer = Canopus::Buffer.new("a\tbcd\nsecond\nthird\n" + "unchanged\n" * 1000)
    map = Canopus::DisplayMap.new(buffer, tab_size: 4, wrap_width: 5)
    assert_equal "a   b", map.row(0).text
    assert_equal "cd", map.row(1).text
    assert_equal 2, map.to_buffer(Canopus::DisplayPoint.new(0, 4))
    map.insert_block(:diagnostic, row: 1, text: "error")
    assert_equal :diagnostic, map.row(map.to_display(7).row + 2).kind
    buffer.edit([[0...1, "A"]])
    assert_equal 1, map.recomputed_lines
    assert_equal "A   b", map.row(0).text
    buffer.edit([[0...0, "new\n"]])
    assert_equal "new", map.row(0).text
    assert_equal "A   b", map.row(1).text
    map.tree.check_invariants!
    map.dispose
  end

  def test_fold_maps_to_correct_buffer_offsets
    buffer = Canopus::Buffer.new("one\ntwo\nthree\nfour")
    map = Canopus::DisplayMap.new(buffer)
    map.fold(3...13)
    assert_equal "one…", map.row(0).text
    assert_equal "four", map.row(1).text
    assert_equal 13, map.to_buffer(Canopus::DisplayPoint.new(0, 4))
    map.unfold(4)
    assert_equal 4, map.row_count
  end

  def test_anchor_bias_patch_inverse_and_atomic_failure
    buffer = Canopus::Buffer.new("abc")
    left, right = buffer.anchor(1, bias: :left), buffer.anchor(1, bias: :right)
    patch = buffer.edit([[1...1, "日"]])
    assert_equal [1, 4], [buffer.resolve(left), buffer.resolve(right)]
    assert_equal 1, patch.inverse.map_offset(4)
    buffer.undo
    assert_equal [1, 1], [buffer.resolve(left), buffer.resolve(right)]
    assert_raises(ArgumentError) { buffer.edit([[0...2, "x"], [1...3, "y"]]) }
    assert_equal "abc", buffer.text
  end

  def test_file_encoding_roundtrip_and_conflicts
    Dir.mktmpdir("canopus-save-") do |dir|
      [Encoding::UTF_8, Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::Windows_31J].each_with_index do |encoding, i|
        path = File.join(dir, "test#{i}.txt")
        bom = {Encoding::UTF_16LE => "\xFF\xFE".b, Encoding::UTF_16BE => "\xFE\xFF".b}.fetch(encoding, "".b)
        original = bom + "日本\r\nline\r\n".encode(encoding).b
        File.binwrite(path, original)
        buffer = Canopus::Buffer.open(path)
        assert_equal "\r\n", buffer.line_ending
        buffer.save
        assert_equal original, File.binread(path)
        buffer.edit([[0...0, "X"]])
        File.binwrite(path, "external")
        assert_raises(Canopus::SaveConflict) { buffer.save }
        assert_equal "external", File.binread(path)
        buffer.save(force: true)
        assert_equal bom + "X日本\r\nline\r\n".encode(encoding).b, File.binread(path)
      end
    end
  end

  def test_selection_invariants_search_indent_comment
    editor = Canopus::Editor.new(Canopus::Buffer.new("one one\ntwo"))
    editor.select(0, 3).select_next_occurrence
    assert_equal [0...3, 4...7], editor.selections.map(&:range)
    editor.replace_selections("x")
    assert_equal "x x\ntwo", editor.buffer.text
    editor.select_all
    editor.indent
    assert_equal "    x x\n    two", editor.buffer.text
    editor.toggle_comment
    assert_equal "    # x x\n    # two", editor.buffer.text
    editor.toggle_comment
    editor.indent(outdent: true)
    assert_equal "x x\ntwo", editor.buffer.text
    assert_equal 2, editor.replace_all("x", "日")
    assert_equal "日 日\ntwo", editor.buffer.text
  end

  def test_line_movement_keeps_multibyte_cursors_and_history
    editor = Canopus::Editor.new(Canopus::Buffer.new("top\r\n日本\r\nlast"))
    editor.select(8)
    before = editor.selections
    editor.move_lines(:up)
    assert_equal "日本\r\ntop\r\nlast", editor.buffer.text
    assert_equal 3, editor.primary.head
    moved = editor.selections
    editor.undo
    assert_equal before, editor.selections
    editor.redo
    assert_equal moved, editor.selections
    editor.move_lines(:down)
    assert_equal "top\r\n日本\r\nlast", editor.buffer.text
    assert_equal 8, editor.primary.head
    assert_raises(ArgumentError) { editor.move_lines(:invalid) }
  ensure
    editor&.dispose
  end

  def test_linewise_selection_moved_to_eof_stays_in_bounds
    editor = Canopus::Editor.new(Canopus::Buffer.new("one\ntwo"))
    editor.select(0, 4)
    editor.move_lines(:down)
    assert_equal "two\none", editor.buffer.text
    assert_equal 4...7, editor.primary.range
  ensure
    editor&.dispose
  end

  def test_line_movement_preserves_mixed_separators_and_utf8_carets
    editor = Canopus::Editor.new(Canopus::Buffer.new("a\n日\r\n語"))
    editor.select(7)
    original = editor.selections
    editor.move_lines(:up)
    assert_equal "a\n語\r\n日", editor.buffer.text
    assert_equal 2, editor.primary.head
    editor.buffer.rope.point_at(editor.primary.head)
    editor.undo
    assert_equal original, editor.selections
    editor.redo
    editor.insert_text("X")
    assert_equal "a\nX語\r\n日", editor.buffer.text
  ensure
    editor&.dispose
  end

  def test_line_movement_does_not_merge_adjacent_cr_and_lf_breaks
    editor = nil
    ["A\rB\n", "A\rB\n\n日", "A\rB\n\u2028日"].each do |source|
      editor = Canopus::Editor.new(Canopus::Buffer.new(source))
      editor.select(2)
      count = editor.buffer.line_count
      editor.move_lines(:down)
      assert_equal count, editor.buffer.line_count
      assert_equal "", editor.buffer.line(1)
      assert_equal "B", editor.buffer.line(2)
      assert_equal editor.buffer.rope.line_start(2), editor.primary.head
      editor.undo
      assert_equal source, editor.buffer.text
      assert_equal 2, editor.primary.head
      editor.dispose
    end
  ensure
    editor&.dispose
  end

  100.times do |seed|
    define_method("test_input_replay_#{seed}") do
      random = Random.new(seed)
      text = Array.new(20) { %w[a b 日 🙂].sample(random: random) }.join
      input = JSON.parse(JSON.generate([{action: "insert", text: text}, {action: "home"}, {action: "insert", text: "prefix"}, {action: "undo"}, {action: "end"}, {action: "insert", text: "tail"}]))
      editor = Canopus::Editor.new
      editor.auto_pairs = false
      input.each do |event|
        case event.fetch("action")
        when "insert" then editor.insert_text(event.fetch("text"))
        when "home" then editor.move(:file_start)
        when "end" then editor.move(:file_end)
        when "undo" then editor.undo
        end
      end
      assert_equal text + "tail", editor.buffer.text
      assert_equal editor.buffer.rope.bytesize, editor.primary.head
    end
  end
end

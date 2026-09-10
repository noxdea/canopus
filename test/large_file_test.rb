# frozen_string_literal: true

require_relative "test_helper"
require "canopus/lazy_rope"
require "tempfile"

class LargeFileTest < Minitest::Test
  def with_rope(text, **options)
    Tempfile.create("canopus-lazy-") do |file|
      file.binmode
      file.write(text)
      file.flush
      rope = Canopus::LazyRope.new(file.path, **options)
      begin
        yield rope, file
      ensure
        rope.close
      end
    end
  end

  def test_unicode_and_newlines_across_page_boundaries_match_denebola
    source = "a" * 65_535 + "\r\n日😀\u2028next\rfinal\u2029"
    with_rope(source) do |rope, _|
      reference = Denebola::Rope.new(source)
      assert_equal reference.line_count, rope.line_count
      assert_equal reference.length, rope.length
      assert_equal reference.utf16_length, rope.utf16_length
      assert_equal source, rope.each_chunk.to_a.join
      reference.line_count.times do |row|
        assert_equal reference.line(row), rope.line(row)
        assert_equal reference.line_start(row), rope.line_start(row)
      end
      offsets = [0, 1, 60_000, 65_535, 65_537, 65_540, 65_544, source.bytesize]
      offsets.each do |offset|
        assert_equal reference.point_at(offset), rope.point_at(offset)
        assert_equal reference.utf16_point_at(offset), rope.utf16_point_at(offset)
      end
      assert_raises(RangeError) { rope.byteslice(65_538, 1) }
    end
  end

  def test_empty_bom_and_invalid_input
    with_rope("") { |rope, _| assert_equal [1, "", 0], [rope.line_count, rope.to_s, rope.bytesize] }
    with_rope("\uFEFFhello") { |rope, _| assert_equal "hello", rope.to_s }
    assert_raises(Canopus::Error) { with_rope("bad\xFF".b) { flunk } }
  end

  def test_falls_back_when_positioned_reads_are_unavailable
    Tempfile.create("canopus-lazy-") do |file|
      file.write("\uFEFFhello\nworld")
      file.flush
      opened = File.open(file.path, File::RDONLY | File::BINARY | File::SHARE_DELETE)
      def opened.pread(*) = raise NotImplementedError
      File.stub(:open, opened) do
        rope = Canopus::LazyRope.new(file.path)
        assert_equal ["hello", "world"], [rope.line(0), rope.line(1)]
      ensure
        rope&.close
      end
    end
  end

  def test_read_only_buffer_uses_lazy_display_mapping_and_bounded_cache
    source = "hello 日本\tworld\n" * 150_000
    Tempfile.create("canopus-large-", binmode: true) do |file|
      file.write(source)
      file.flush
      buffer = Canopus::Buffer.open(file.path, large_file_threshold: 1)
      editor = Canopus::Editor.new(buffer)
      assert buffer.read_only
      assert_nil editor.display_map.tree
      assert_equal 0, editor.display_map.recomputed_lines
      assert_equal 150_001, editor.display_map.row_count
      editor.move(:file_end)
      assert_equal source.bytesize, editor.primary.head
      random = Random.new(42)
      1000.times do
        row = random.rand(150_000)
        assert_equal "hello 日本\tworld", buffer.line(row)
        offset = buffer.rope.line_start(row)
        assert_equal row, buffer.rope.point_at(offset).row
      end
      assert_operator buffer.rope.cached_bytes, :<=, 32 * 65_536
      assert_raises(Canopus::Error) { editor.insert_text("x") }
      assert_raises(Canopus::Error) { editor.display_map.wrap_width = 80 }
      assert_raises(Canopus::Error) { buffer.save }
    ensure
      editor&.dispose
      buffer&.close
    end
  end

  def test_disk_changes_are_not_combined_with_cached_pages
    with_rope("hello\nworld") do |rope, file|
      assert_equal "hello", rope.line(0)
      file.truncate(1)
      file.flush
      assert_raises(Canopus::SaveConflict) { rope.line(0) }
    end
  end

  def test_giant_line_navigation_and_unicode_coordinates_are_bounded
    source = "日😀a" * 150_000 + " end"
    Tempfile.create("canopus-long-line-", binmode: true) do |file|
      file.write(source)
      file.flush
      buffer = Canopus::Buffer.open(file.path, large_file_threshold: 1)
      editor = Canopus::Editor.new(buffer)
      reference = Denebola::Rope.new(source)
      [0, 8, 65_536, 800_000, source.bytesize].each do |offset|
        point = buffer.rope.point_at(offset)
        assert_equal reference.point_at(offset), point
        assert_equal offset, buffer.rope.offset_at(point)
        units = buffer.rope.utf16_offset_at(offset)
        assert_equal reference.utf16_offset_at(offset), units
        assert_equal offset, buffer.rope.offset_at_utf16(units)
        assert_equal offset, buffer.rope.offset_at_utf16_point(buffer.rope.utf16_point_at(offset))
        assert_equal offset, editor.display_map.to_buffer(editor.display_map.to_display(offset))
        assert_operator editor.display_map.row(0).text.bytesize, :<=, 16_384
      end
      assert_raises(RangeError) { buffer.rope.offset_at_utf16(2) }
      editor.move(:line_end)
      assert_equal source.bytesize, editor.primary.head
      editor.move(:word_left)
      assert_equal source.bytesize - 3, editor.primary.head
      editor.move(:line_start)
      assert_equal 0, editor.primary.head
      editor.move(:right, count: 2)
      assert_equal 7, editor.primary.head
      editor.move(:left)
      assert_equal 3, editor.primary.head
      assert_operator buffer.rope.cached_bytes, :<=, 32 * 65_536
    ensure
      editor&.dispose
      buffer&.close
    end
  end
end

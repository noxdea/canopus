# frozen_string_literal: true
require_relative "test_helper"

class PixelWrapTest < Minitest::Test
  def setup
    @database = Zaniah::TextSystem::FontDB.new(paths: [])
    @font = @database.find
    @typesetter = Zaniah::TextSystem::Typesetter.new(font: @font, font_db: @database)
  end

  def teardown = @typesetter.close

  def test_shaped_rows_fit_and_preserve_every_utf8_offset
    source = ("AV office 日本 é Wi " * 400)
    offsets, byte = [0], 0
    source.each_char { |char| offsets << (byte += char.bytesize) }
    wrapper = Canopus::WrapMap.new(width: 73.5, font: @font, font_size: 17, font_paths: [])
    rows = wrapper.transform(source, offsets)
    assert_equal source, rows.map(&:first).join
    assert_equal offsets, rows.flat_map.with_index { |(_, positions), index| index.zero? ? positions : positions.drop(1) }
    rows.each do |text, positions|
      assert_operator @typesetter.layout_line(text, size: 17).width, :<=, 73.5
      assert_equal text.length + 1, positions.length
      assert text.valid_encoding?
      refute text.start_with?("\u0301")
    end
    wide = wrapper.transform("WWWWWW", (0..6).to_a).length
    narrow = wrapper.transform("iiiiii", (0..6).to_a).length
    assert_operator wide, :>, narrow
  end

  def test_oversized_grapheme_stays_whole_and_empty_line_survives
    wrapper = Canopus::WrapMap.new(width: 1, font: @font, font_paths: [])
    assert_equal [["", [0]]], wrapper.transform("", [0])
    assert_equal ["é", "👩‍💻"], wrapper.transform("é👩‍💻", [0, 1, 3, 7, 10, 14]).map(&:first)
  end

  def test_terminal_columns_and_tab_stops_use_grapheme_width
    text, offsets = Canopus::TabMap.new(tab_size: 4).transform("日\t👩‍💻\tX", [0, 3, 4, 8, 11, 15, 16, 17])
    assert_equal "日  👩‍💻  X", text
    assert_equal text.length + 1, offsets.length
    assert_equal 17, offsets.last
    wrapper = Canopus::WrapMap.new(width: 4)
    assert_equal ["日本", "語a"], wrapper.transform("日本語a", [0, 3, 6, 9, 10]).map(&:first)
  end

  def test_background_and_foreground_layouts_agree_after_edits
    buffer = Canopus::Buffer.new("office 日本 AV\n" * 40)
    foreground = Canopus::DisplayMap.new(buffer, background_threshold: nil)
    background = Canopus::DisplayMap.new(buffer, background_threshold: 0)
    [foreground, background].each { |map| map.wrap_pixels(55, font: @font, font_size: 14, font_paths: []) }
    2.times do
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      while background.pending?
        background.poll(max_lines: 5)
        Thread.pass
        flunk "background wrap timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      end
      assert_equal foreground.each_row.to_a, background.each_row.to_a
      (0..buffer.rope.bytesize).each do |offset|
        next unless buffer.text.byteslice(0, offset).valid_encoding?
        assert_equal offset, background.to_buffer(background.to_display(offset))
      end
      buffer.edit([[0...0, "iii"]])
    end
  ensure
    foreground&.dispose
    background&.dispose
  end

  def test_default_pixel_wrap_does_not_shape_medium_documents_on_foreground
    buffer = Canopus::Buffer.new("office 日本 AV\n" * 2000)
    map = Canopus::DisplayMap.new(buffer)
    foreground = Thread.current
    shape = Zaniah::TextSystem::Typesetter.instance_method(:layout_line)
    Zaniah::TextSystem::Typesetter.define_method(:layout_line) do |*args, **kwargs|
      raise "shaping on foreground" if Thread.current.equal?(foreground)
      shape.bind_call(self, *args, **kwargs)
    end
    map.wrap_pixels(80, font: @font, font_size: 14, font_paths: [])
    assert map.pending?
    assert_equal 0, map.recomputed_lines
    buffer.edit([[0...0, "changed"]])
    assert map.pending?
  ensure
    map&.dispose
    Zaniah::TextSystem::Typesetter.define_method(:layout_line, shape) if shape
  end
end

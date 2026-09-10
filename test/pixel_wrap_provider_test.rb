# frozen_string_literal: true
require_relative "test_helper"

class PixelWrapProviderTest < Minitest::Test
  class Database
    attr_reader :closed
    def initialize(font) = @font = font
    def find = @font
    def fallback(_, primary) = primary
    def layout_copy = self.class.new(Alhena::Font.new(@font.data, index: @font.index, axes: @font.axis_values))
    def close = @closed = true
  end
  class DoubleShaper
    attr_reader :calls, :closed
    def initialize = @calls = []
    def shape(glyphs, size:, text:)
      @calls << Thread.current
      glyphs.map { |glyph| glyph.with(x: glyph.x * 2, advance: glyph.advance * 2) }
    end
    def layout_copy = self.class.new
    def close = @closed = true
  end
  class Segmenter
    def grapheme_clusters(text) = text.empty? ? [] : [text]
    def layout_copy = self.class.new
  end

  def setup
    @database = Zaniah::TextSystem::FontDB.new(paths: [])
    @font = @database.find
  end

  def drain(map)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    while map.pending?
      map.poll
      Thread.pass
      flunk "background wrapping timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end
  end

  def test_background_custom_typography_matches_rendering_and_closes_only_copies
    database, shaper = Database.new(@font), DoubleShaper.new
    system = Zaniah::TextSystem::Renderer.new(font_db: database, shaper: shaper)
    buffer = Canopus::Buffer.new("a" * 100)
    map = Canopus::DisplayMap.new(buffer)
    map.wrap_pixels(80, typesetter: system, font_size: 14)
    drain(map)
    assert_equal buffer.text, map.each_row.map { |row, _| row.text }.join
    assert_empty shaper.calls
    owned = map.wrap_map.instance_variable_get(:@typesetters).values
    refute_empty owned
    owned.each { |copy| refute_includes copy.shaper.calls, Thread.current }
    map.each_row { |row, _| assert_operator system.layout_line(row.text).width, :<=, 80 }
    map.wrap_width = nil
    owned.each do |copy|
      assert copy.font_db.closed
      assert copy.shaper.closed
    end
    refute database.closed
    refute shaper.closed
  ensure
    map&.dispose
    system&.close
  end

  def test_system_identity_invalidates_wrap_even_when_primary_font_is_unchanged
    first = Zaniah::TextSystem::Typesetter.new(font: @font, font_db: @database)
    second = Zaniah::TextSystem::Typesetter.new(font: @font, font_db: @database, shaper: DoubleShaper.new)
    map = Canopus::DisplayMap.new(Canopus::Buffer.new("a" * 100), background_threshold: nil)
    map.wrap_pixels(80, typesetter: first, font_size: 14)
    previous, count = map.wrap_map, map.row_count
    map.wrap_pixels(80, typesetter: second, font_size: 14)
    refute_same previous, map.wrap_map
    assert_operator map.row_count, :>, count
    assert_empty previous.instance_variable_get(:@typesetters)
  ensure
    map&.dispose
    first&.close
    second&.close
  end

  def test_custom_segmenter_boundaries_are_respected
    system = Zaniah::TextSystem::Typesetter.new(font_db: @database, segmenter: Segmenter.new)
    wrapper = Canopus::WrapMap.new(width: 1, typesetter: system)
    assert_equal [["ab", [0, 1, 2]]], wrapper.transform("ab", [0, 1, 2])
    assert_equal [["", [0]]], wrapper.transform("", [0])
  ensure
    wrapper&.close
    system&.close
  end

  def test_delayed_worker_exit_does_not_release_in_use_copies
    system = Zaniah::TextSystem::Typesetter.new(font_db: @database, shaper: DoubleShaper.new)
    map = Canopus::DisplayMap.new(Canopus::Buffer.new("abc"), background_threshold: nil)
    map.wrap_pixels(80, typesetter: system, font_size: 14)
    copy = map.wrap_map.instance_variable_get(:@typesetters).values.first
    gate = Queue.new
    thread = Thread.new { gate.pop }
    # Model a native call that cannot finish within the worker's close timeout.
    worker = Struct.new(:thread) { def close = nil }.new(thread)
    map.instance_variable_set(:@worker, worker)
    map.dispose
    refute copy.shaper.closed
    gate << true
    thread.join
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until copy.shaper.closed
      Thread.pass
      flunk "layout copy cleanup did not complete" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end
    assert copy.shaper.closed
    refute system.shaper.closed
  ensure
    gate << true if gate && thread&.alive?
    thread&.join
    map&.dispose
    system&.close
  end

  def test_minimal_font_provider_without_copy_disables_wrap_once_without_stopping_frames
    directory = Dir.mktmpdir("canopus-wrap-provider-")
    workspace = Canopus::Workspace.new(root: directory)
    window = Zaniah::Platform.open_window(width: 300, height: 220)
    controller = Canopus::Controller.new(workspace, window)
    database = Database.new(@font)
    database.singleton_class.undef_method(:layout_copy)
    copy_checks = 0
    database.define_singleton_method(:respond_to?) do |name, include_private = false|
      copy_checks += 1 if name == :layout_copy
      super(name, include_private)
    end
    window.text_system = Zaniah::TextSystem::Renderer.new(font_db: database)
    workspace.editor.insert_text("a" * 100, auto_indent: false)
    workspace.editor.display_map.wrap_width = 100
    controller.tick
    assert_nil workspace.editor.display_map.wrap_map.width
    assert_match(/Soft wrap disabled: font_db.*layout_copy/, workspace.message)
    refute_empty controller.view.row_layouts
    assert_equal 1, copy_checks
    controller.tick
    assert_equal 1, copy_checks
    refute_empty controller.view.row_layouts
    refute database.closed
  ensure
    workspace&.close
    window&.on_close { true }
    window&.close
    FileUtils.remove_entry(directory) if directory
  end
end

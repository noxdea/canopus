# frozen_string_literal: true
require_relative "test_helper"
require "tempfile"

class ReloadTest < Minitest::Test
  def test_small_reload_preserves_unaffected_cursor_and_is_undoable
    Tempfile.create("canopus-reload-", binmode: true) do |file|
      file.write("日本\nold line\nlast\n"); file.flush
      buffer = Canopus::Buffer.open(file.path)
      editor = Canopus::Editor.new(buffer)
      editor.select(3)
      File.binwrite(file.path, "日本\nnew line\nlast\n")
      buffer.reload
      assert_equal 3, editor.primary.head
      assert_equal "日本\nnew line\nlast\n", buffer.text
      refute buffer.dirty?
      buffer.undo
      assert_equal "日本\nold line\nlast\n", buffer.text
      assert buffer.dirty?
    ensure
      editor&.dispose
      buffer&.close
    end
  end
  def test_lazy_reload_reopens_changed_file_without_materializing_it
    Tempfile.create("canopus-lazy-reload-", binmode: true) do |file|
      file.write("one\ntwo\nthree\n"); file.flush
      buffer = Canopus::Buffer.open(file.path, large_file_threshold: 1)
      editor = Canopus::Editor.new(buffer)
      editor.select(4)
      File.binwrite(file.path, "one\n日本\n")
      buffer.reload
      assert buffer.rope.lazy?
      assert_equal "日本", editor.display_map.row(1).text
      assert_equal 4, editor.primary.head
      assert_empty buffer.history
    ensure
      editor&.dispose
      buffer&.close
    end
  end
end

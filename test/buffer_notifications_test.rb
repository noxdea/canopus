# frozen_string_literal: true

require_relative "test_helper"

class BufferNotificationsTest < Minitest::Test
  def test_failed_listener_does_not_abort_committed_edit_or_skip_editor_and_excerpt_observers
    buffer = Canopus::Buffer.new("hello")
    buffer.on_edit { raise ArgumentError, "observer broke" }
    editor = Canopus::Editor.new(buffer)
    editor.select(5)
    excerpts = Canopus::MultiBuffer.new(excerpts: [[buffer, 0...5, "result"]])
    anchor = buffer.anchor(5)
    _, errors = capture_io do
      assert_instance_of Canopus::Patch, buffer.edit([[0...5, "日"]])
      assert_equal ["日", 3, 3], [buffer.text, editor.primary.head, buffer.resolve(anchor)]
      assert_equal "result\n日\n\n", excerpts.text
      assert_equal "日", editor.display_map.row(0).text
      assert editor.undo
      assert_equal ["hello", 5, 5], [buffer.text, editor.primary.head, buffer.resolve(anchor)]
      assert_equal "result\nhello\n\n", excerpts.text
      assert editor.redo
      assert_equal ["日", 3, 3], [buffer.text, editor.primary.head, buffer.resolve(anchor)]
      assert_equal "result\n日\n\n", excerpts.text
    end
    assert_equal 3, errors.scan("ArgumentError: observer broke").length
    assert_equal 3, buffer.notification_errors.length
    assert_equal "ArgumentError: observer broke", buffer.notification_errors.last.message
    assert_equal 1, buffer.history.length
  ensure
    excerpts&.close
    editor&.dispose
  end

  def test_notification_diagnostics_are_bounded_and_do_not_retain_exception_backtraces
    buffer = Canopus::Buffer.new("x")
    buffer.on_edit { raise RuntimeError, "日本" * 3000 }
    calls = 0
    buffer.on_edit { calls += 1 }
    capture_io { 40.times { buffer.edit([[0...1, "x"]]) } }
    assert_equal 40, calls
    assert_equal 32, buffer.notification_errors.length
    assert_predicate buffer.notification_errors, :frozen?
    buffer.notification_errors.each do |error|
      assert_instance_of Canopus::Error, error
      assert_match(/\ARuntimeError: 日本/, error.message)
      assert_predicate error.message, :valid_encoding?
      assert_operator error.message.bytesize, :<=, 2048
      assert_nil error.backtrace
      assert_nil error.cause
    end
  end

  def test_broken_diagnostic_output_does_not_skip_remaining_observers
    buffer = Canopus::Buffer.new("a")
    buffer.define_singleton_method(:warn) { |_| raise IOError, "stderr closed" }
    buffer.on_edit { raise "original listener failure" }
    seen = []
    buffer.on_edit { seen << buffer.text }
    assert_instance_of Canopus::Patch, buffer.edit([[0...1, "b"]])
    assert_equal ["b"], seen
    assert_equal "RuntimeError: original listener failure", buffer.notification_errors.last.message
    assert buffer.undo
    assert_equal ["b", "a"], seen
  end

  def test_default_selection_mapping_preserves_unicode_reversed_ranges_and_custom_metadata
    selection_type = Data.define(:anchor, :head, :tag)
    buffer = Canopus::Buffer.new("日本abc")
    before = [selection_type.new(9, 6, :custom), selection_type.new(0, 0, :caret)]
    buffer.selections = before
    buffer.edit([[0...6, "語"], [7...8, ""]])
    assert_equal "語ac", buffer.text
    assert_equal [selection_type.new(5, 3, :custom), selection_type.new(3, 3, :caret)], buffer.selections
    after = buffer.selections
    assert buffer.undo
    assert_equal before, buffer.selections
    assert buffer.redo
    assert_equal after, buffer.selections
  end

  def test_explicit_selection_overrides_are_not_mapped_and_survive_history
    buffer = Canopus::Buffer.new("abc")
    before = [Canopus::Selection.new(7, 3, 3, 8)]
    after = [Canopus::Selection.new(7, 0, 0, nil)]
    buffer.edit([[0...3, "日"]], before_selections: before, selections: after)
    assert_equal after, buffer.selections
    buffer.undo
    assert_equal before, buffer.selections
    buffer.redo
    assert_equal after, buffer.selections
    buffer.edit([[0...3, ""]], selections: [])
    assert_empty buffer.selections
  end

  def test_invalid_anchor_bias_is_rejected_before_it_can_break_an_edit_mid_commit
    buffer = Canopus::Buffer.new("abc")
    assert_raises(ArgumentError) { buffer.anchor(1, bias: :invalid) }
    assert_empty buffer.instance_variable_get(:@anchors)
    assert_instance_of Canopus::Patch, buffer.edit([[0...3, "x"]])
    assert_equal "x", buffer.text
    assert buffer.undo
    assert_equal "abc", buffer.text
  end
end

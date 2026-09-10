# frozen_string_literal: true

require_relative "test_helper"

class MultiBufferTest < Minitest::Test
  class FailingBuffer < Canopus::Buffer
    attr_accessor :failure, :fail_after_edit
    def edit(...)
      raise @failure if @failure && !@fail_after_edit
      result = super
      raise @failure if @failure
      result
    end
  end

  def test_edits_and_history_propagate_to_multiple_sources
    first, second = Canopus::Buffer.new("first\n"), Canopus::Buffer.new("日本 second\n")
    composite = Canopus::MultiBuffer.new(excerpts: [[first, 0...6, "one"], [second, 0...second.rope.bytesize, "two"]])
    starts = composite.excerpts.map(&:view_start)
    composite.edit([[starts[0]...(starts[0] + 5), "FIRST"], [starts[1]...(starts[1] + 6), "Japan"]])
    assert_equal "FIRST\n", first.text
    assert_equal "Japan second\n", second.text
    assert_includes composite.text, "Japan second"
    assert composite.dirty?
    assert composite.undo
    assert_equal "first\n", first.text
    assert_equal "日本 second\n", second.text
    assert composite.redo
    assert_equal "Japan second\n", second.text
    composite.close
  end
  def test_external_edits_refresh_excerpt_and_invalidate_ambiguous_history
    source = Canopus::Buffer.new("hello world")
    composite = Canopus::MultiBuffer.new(excerpts: [[source, 6...11, "result"]])
    source.edit([[0...0, "prefix "]])
    assert_equal "result\nworld\n\n", composite.text
    source.edit([[13...18, "日本"]])
    assert_equal "result\n日本\n\n", composite.text
    refute composite.undo
    composite.close
  end
  def test_protected_headings_and_overlaps_reject_before_mutation
    source = Canopus::Buffer.new("hello world")
    composite = Canopus::MultiBuffer.new(excerpts: [[source, 0...5, "result"]])
    assert_raises(Canopus::Error) { composite.edit([[0...3, "bad"]]) }
    assert_equal "hello world", source.text
    assert_raises(Canopus::Error) { composite.add_excerpt(source, 3...8) }
    composite.close
  end

  def test_external_replacement_normalizes_overlapping_excerpts_without_losing_source_text
    source = Canopus::Buffer.new("a b")
    composite = Canopus::MultiBuffer.new(excerpts: [[source, 0...1, "one"], [source, 2...3, "two"]])
    source.edit([[0...3, "日本"]])
    assert_equal 1, composite.excerpts.length
    assert_equal "one\n日本\n\n", composite.text
    assert_equal 2, source.instance_variable_get(:@anchors).length
    start = composite.excerpts.first.view_start
    composite.edit([[start...(start + 6), "Q"]])
    assert_equal "Q", source.text
    assert_equal "one\nQ\n\n", composite.text
    assert composite.undo
    assert_equal "日本", source.text
    assert_equal "one\n日本\n\n", composite.text
    assert composite.redo
    assert_equal "one\nQ\n\n", composite.text
    composite.close
    assert_empty source.instance_variable_get(:@anchors)
  end

  def test_external_gap_deletion_merges_adjacent_excerpts_but_preserves_other_buffers
    source, other = Canopus::Buffer.new("a b c"), Canopus::Buffer.new("other")
    composite = Canopus::MultiBuffer.new(excerpts: [[source, 4...5, "last"], [other, 0...5, "other"],
      [source, 0...1, "first"], [source, 2...3, "middle"]])
    source.edit([[1...2, ""], [3...4, ""]])
    assert_equal [source, other], composite.excerpts.map(&:buffer)
    assert_equal "last\nabc\n\nother\nother\n\n", composite.text
    start = composite.excerpts.first.view_start
    composite.edit([[(start + 1)...(start + 1), "X"]])
    assert_equal "aXbc", source.text
    assert_equal "last\naXbc\n\nother\nother\n\n", composite.text
    assert_raises(Canopus::Error) { composite.edit([[0...1, "broken heading"]]) }
    composite.close
  end

  def test_listener_failure_commits_all_sources_and_keeps_projection_and_history_current
    first, second = Canopus::Buffer.new("a"), Canopus::Buffer.new("b")
    second.on_edit { raise "listener failure" }
    composite = Canopus::MultiBuffer.new(excerpts: [[first, 0...1, "one"], [second, 0...1, "two"]])
    editor = Canopus::Editor.new(composite)
    editor.select(composite.excerpts.last.view_end)
    starts = composite.excerpts.map(&:view_start)
    _, errors = capture_io do
      composite.edit([[starts[0]...(starts[0] + 1), "AAA"], [starts[1]...(starts[1] + 1), "B"]])
      assert_equal ["AAA", "B", "one\nAAA\n\ntwo\nB\n\n"], [first.text, second.text, composite.text]
      assert_equal composite.excerpts.last.view_end, editor.primary.head
      assert editor.undo
      assert_equal ["a", "b", "one\na\n\ntwo\nb\n\n"], [first.text, second.text, composite.text]
      assert editor.redo
      assert_equal ["AAA", "B", "one\nAAA\n\ntwo\nB\n\n"], [first.text, second.text, composite.text]
      assert_equal composite.excerpts.last.view_end, editor.primary.head
    end
    assert_equal 3, errors.scan("RuntimeError: listener failure").length
    assert_equal [1, 1, 1], [first.history.length, second.history.length, composite.history.length]
  ensure
    editor&.dispose
    composite&.close
  end

  def test_actual_source_failure_restores_mutated_source_and_prior_history_anchors_and_selections
    first, second = Canopus::Buffer.new("first"), FailingBuffer.new("second")
    [first, second].each do |buffer|
      buffer.edit([[buffer.rope.bytesize...buffer.rope.bytesize, "!"]])
      buffer.undo # An unrelated redo entry must survive the failed composite edit.
      buffer.selections = [Canopus::Selection.new(1, 2, 3, nil)]
    end
    composite = Canopus::MultiBuffer.new(excerpts: [[first, 0...5, "one"], [second, 0...6, "two"]])
    anchor = second.anchor(2)
    states = [first, second, composite].map { |buffer| edit_state(buffer) }
    notifications = []
    second.on_edit { notifications << second.text }
    failure = RuntimeError.new("after mutation")
    second.failure, second.fail_after_edit = failure, true
    starts = composite.excerpts.map(&:view_start)
    raised = assert_raises(RuntimeError) do
      composite.edit([[starts[0]...(starts[0] + 5), "A"], [starts[1]...(starts[1] + 6), "B"]])
    end
    assert_same failure, raised
    assert_equal states, [first, second, composite].map { |buffer| edit_state(buffer) }
    assert_equal ["B", "second"], notifications
    assert_equal 2, second.resolve(anchor)
    refute composite.undo
    refute composite.redo
    second.failure = nil
    assert first.redo
    assert second.redo
    assert_equal ["first!", "second!"], [first.text, second.text]
    assert_equal "one\nfirst!\n\ntwo\nsecond!\n\n", composite.text
  ensure
    composite&.close
  end

  def test_precommit_failure_does_not_undo_unrelated_source_history
    first, second = Canopus::Buffer.new("a"), FailingBuffer.new("b")
    second.edit([[0...1, "B"]])
    composite = Canopus::MultiBuffer.new(excerpts: [[first, 0...1, "one"], [second, 0...1, "two"]])
    states = [first, second, composite].map { |buffer| edit_state(buffer) }
    second.failure = RuntimeError.new("before mutation")
    starts = composite.excerpts.map(&:view_start)
    assert_raises(RuntimeError) { composite.edit([[starts[0]...(starts[0] + 1), "A"], [starts[1]...(starts[1] + 1), "X"]]) }
    assert_equal states, [first, second, composite].map { |buffer| edit_state(buffer) }
    second.failure = nil
    assert second.undo
    assert_equal "b", second.text
  ensure
    composite&.close
  end

  def test_failed_edit_inside_open_group_restores_group_transaction_without_using_undo
    first, second = Canopus::Buffer.new("a"), FailingBuffer.new("b")
    composite = Canopus::MultiBuffer.new(excerpts: [[first, 0...1, "one"], [second, 0...1, "two"]])
    composite.begin_undo_group
    starts = composite.excerpts.map(&:view_start)
    composite.edit([[starts[0]...(starts[0] + 1), "A"], [starts[1]...(starts[1] + 1), "B"]])
    states = [first, second, composite].map { |buffer| edit_state(buffer) }
    second.failure, second.fail_after_edit = RuntimeError.new("group failed"), true
    assert_raises(RuntimeError) { composite.edit([[starts[0]...(starts[0] + 1), "X"], [starts[1]...(starts[1] + 1), "Y"]]) }
    assert_equal states, [first, second, composite].map { |buffer| edit_state(buffer) }
    second.failure = nil
    composite.end_undo_group
    assert composite.undo
    assert_equal ["a", "b"], [first.text, second.text]
    assert composite.redo
    assert_equal ["A", "B"], [first.text, second.text]
  ensure
    composite&.close
  end

  def test_compensation_keeps_observer_created_excerpt_anchors_valid
    source = FailingBuffer.new("a b")
    composite = Canopus::MultiBuffer.new(excerpts: [[source, 0...3, "all"]])
    observer = Canopus::MultiBuffer.new(excerpts: [[source, 0...1, "first"], [source, 2...3, "second"]])
    source.failure, source.fail_after_edit = RuntimeError.new("after mutation"), true
    start = composite.excerpts.first.view_start
    assert_raises(RuntimeError) { composite.edit([[start...(start + 3), "z"]]) }
    assert_equal "a b", source.text
    assert_equal "all\na b\n\n", composite.text
    assert_equal "first\na b\n\n", observer.text
    assert_empty source.notification_errors
    source.failure = nil
    start = observer.excerpts.first.view_start
    observer.edit([[start...(start + 1), "A"]])
    assert_equal "A b", source.text
    assert_equal "all\nA b\n\n", composite.text
  ensure
    composite&.close
    observer&.close
  end

  private

  def edit_state(buffer)
    [buffer.rope, buffer.history.map(&:dup), buffer.instance_variable_get(:@redo).dup,
      buffer.selections.dup, buffer.instance_variable_get(:@anchors).dup, buffer.dirty?]
  end
end

# frozen_string_literal: true

require_relative "test_helper"

class DecorationTest < Minitest::Test
  def item(priority: 0, source: nil, row: 1)
    Canopus::Decoration::Item.new(:gutter, nil, row, "mark", :accent, priority, source, nil)
  end

  def test_registry_merges_by_priority_and_owns_the_source
    registry = Canopus::Decoration::Registry.new
    buffer = Canopus::Buffer.new("one\ntwo\n")
    registry.register(:late) { |_buffer, _rows| [item(priority: 20, source: :wrong)] }
    registry.register(:early) { |_buffer, _rows| [item(priority: 10)] }

    items = registry.items_for(buffer, 0...2)

    assert_equal [10, 20], items.map(&:priority)
    assert_equal %i[early late], items.map(&:source)
    assert items.frozen?
  end

  def test_cache_tracks_edits_and_selection_changes_and_can_be_invalidated
    registry = Canopus::Decoration::Registry.new
    buffer = Canopus::Buffer.new("one\ntwo\n")
    calls = 0
    registry.register(:dynamic) do |_buffer, rows|
      calls += 1
      [item(row: rows.begin)]
    end

    assert_same registry.items_for(buffer, 0...1).first, registry.items_for(buffer, 0...1).first
    assert_equal 1, calls
    buffer.selections = [Canopus::Selection.new(1, 0, 1, nil)]
    registry.items_for(buffer, 0...1)
    assert_equal 2, calls
    buffer.edit([[0...1, "x"]])
    registry.items_for(buffer, 0...1)
    assert_equal 3, calls
    registry.invalidate(:dynamic, buffer: buffer, rows: 0...1)
    registry.items_for(buffer, 0...1)
    assert_equal 4, calls
  end

  def test_invalidation_discards_a_supplier_result_already_in_flight
    registry = Canopus::Decoration::Registry.new
    buffer = Canopus::Buffer.new("one\n")
    started, resume = Queue.new, Queue.new
    calls = 0
    registry.register(:dynamic) do |_buffer, _rows|
      calls += 1
      started << true
      resume.pop
      [item]
    end

    pending = Thread.new { registry.items_for(buffer, 0...1) }
    started.pop
    registry.invalidate(:dynamic, buffer: buffer, rows: 0...1)
    resume << true
    pending.value
    resume << true
    registry.items_for(buffer, 0...1)

    assert_equal 2, calls
  end

  def test_workspace_supplies_selections_through_registry
    Dir.mktmpdir("canopus-decoration-") do |directory|
      workspace = Canopus::Workspace.new(root: directory)
      editor = workspace.new_buffer
      editor.insert_text("one\ntwo\n")
      editor.select(0, 3)

      item = workspace.decorations.items_for(editor.buffer, 0...2).find { |value| value.source == :selection_match }
      assert_equal 0...3, item.range
      assert_equal :highlight, item.kind
    ensure
      workspace&.close
    end
  end

  def test_selection_decorations_use_each_split_editors_selection
    Dir.mktmpdir("canopus-decoration-") do |directory|
      workspace = Canopus::Workspace.new(root: directory)
      first = workspace.new_buffer
      first.insert_text("one\ntwo\n")
      workspace.split
      second = workspace.editor
      first.select(0, 3)
      second.select(4, 7)

      first_items = workspace.decorations.items_for(first.buffer, 0...2, context: first)
      second_items = workspace.decorations.items_for(second.buffer, 0...2, context: second)
      assert_equal [0...3], first_items.select { |item| item.source == :selection_match }.map(&:range)
      assert_equal [4...7], second_items.select { |item| item.source == :selection_match }.map(&:range)
    ensure
      workspace&.close
    end
  end

  def test_registry_rejects_invalid_contract_values
    registry = Canopus::Decoration::Registry.new
    buffer = Canopus::Buffer.new
    assert_raises(ArgumentError) { registry.register("git") {} }
    assert_raises(ArgumentError) { registry.items_for(buffer, -1...2) }
    registry.register(:broken) { |_buffer, _rows| nil }
    assert_raises(TypeError) { registry.items_for(buffer, 0...1) }
  end
end

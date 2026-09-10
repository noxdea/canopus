# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SearchAttachmentTest < Minitest::Test
  def test_anchor_copy_requires_shared_snapshot_and_live_handle_and_preserves_bias
    source = Canopus::Buffer.new("日本")
    target = Canopus::Buffer.new(rope: source.rope)
    left = source.anchor(3, bias: :left)
    right = source.anchor(3, bias: :right)
    copied_left, copied_right = target.copy_anchor(source, left), target.copy_anchor(source, right)
    refute_same left, copied_left
    assert_equal [:left, :right], [copied_left.bias, copied_right.bias]
    target.edit([[3...3, "X"]])
    assert_equal [3, 4], [target.resolve(copied_left), target.resolve(copied_right)]
    assert_equal [3, 3], [source.resolve(left), source.resolve(right)]
    assert_raises(ArgumentError) { target.copy_anchor(source, left) }
    same_text = Canopus::Buffer.new(source.text)
    assert_raises(ArgumentError) { same_text.copy_anchor(source, left) }
    snapshot = Canopus::Buffer.new(rope: source.rope)
    source.release_anchor(left)
    assert_raises(KeyError) { snapshot.copy_anchor(source, left) }
    assert_empty snapshot.instance_variable_get(:@anchors)
  end

  def test_attached_projection_keeps_live_encoding_history_and_save_conflict_metadata
    Dir.mktmpdir("canopus-attached-") do |directory|
      path = File.join(directory, "text.txt")
      File.binwrite(path, "\xEF\xBB\xBFtarget\r\n".b)
      source = Canopus::Buffer.open(path)
      source.edit([[0...0, "dirty "]])
      clone = Canopus::Buffer.new(rope: source.rope)
      projection = Canopus::MultiBuffer.new(excerpts: [[clone, 0...clone.rope.bytesize, "result"]])
      text, rope = projection.text, projection.rope
      old_anchors = clone.instance_variable_get(:@anchors).keys
      assert_same projection, projection.attach_sources(clone => source)
      assert_same source, projection.excerpts.first.buffer
      assert_same rope, projection.rope
      assert_equal text, projection.text
      assert_predicate projection, :dirty?
      old_anchors.each { |anchor| assert_raises(KeyError) { clone.resolve(anchor) } }
      assert_empty clone.instance_variable_get(:@listeners)
      first = projection.excerpts.first.view_start
      projection.edit([[first...(first + 5), "saved"]])
      assert_equal "saved target\r\n", source.text
      assert projection.undo
      assert_equal "dirty target\r\n", source.text
      assert projection.redo
      projection.save
      assert_equal "\xEF\xBB\xBFsaved target\r\n".b, File.binread(path)
      refute_predicate projection, :dirty?
      source.edit([[0...5, "later"]])
      assert_includes projection.text, "later target"
      File.binwrite(path, "outside change")
      assert_raises(Canopus::Error) { projection.save }
      assert_equal "outside change", File.binread(path)
      assert_raises(Canopus::Error) { projection.edit([[0...1, "heading"]]) }
      projection.close
      assert_empty source.instance_variable_get(:@anchors)
      assert_empty source.instance_variable_get(:@listeners)
    ensure
      projection&.close
    end
  end

  def test_failed_subscription_registration_leaves_old_sources_untouched
    sources = [Canopus::Buffer.new("one"), Canopus::Buffer.new("two")]
    targets = sources.map { |source| Canopus::Buffer.new(rope: source.rope) }
    projection = Canopus::MultiBuffer.new(excerpts: sources.map { |source| [source, 0...3, "result"] })
    before = sources.map { |source| source.instance_variable_get(:@anchors).dup }
    targets.last.define_singleton_method(:on_edit) { |&_| raise "cannot subscribe" }
    error = assert_raises(RuntimeError) { projection.attach_sources(sources.zip(targets).to_h) }
    assert_equal "cannot subscribe", error.message
    assert_equal sources, projection.excerpts.map(&:buffer)
    assert_equal before, sources.map { |source| source.instance_variable_get(:@anchors) }
    targets.each do |target|
      assert_empty target.instance_variable_get(:@listeners)
      assert_empty target.instance_variable_get(:@anchors)
    end
    sources.first.edit([[0...3, "ONE"]])
    assert_includes projection.text, "ONE"
  ensure
    projection&.close
  end

  def test_failed_anchor_copy_releases_only_staged_handles_and_subscription
    source = Canopus::Buffer.new("one")
    target = Canopus::Buffer.new(rope: source.rope)
    existing = target.anchor(1)
    projection = Canopus::MultiBuffer.new(excerpts: [[source, 0...3, "result"]])
    old_anchors = source.instance_variable_get(:@anchors).dup
    copies = 0
    target.define_singleton_method(:copy_anchor) do |*arguments|
      copies += 1
      raise "cannot copy" if copies == 2
      super(*arguments)
    end
    assert_raises(RuntimeError) { projection.attach_sources(source => target) }
    assert_same source, projection.excerpts.first.buffer
    assert_equal old_anchors, source.instance_variable_get(:@anchors)
    assert_equal({existing => 1}, target.instance_variable_get(:@anchors))
    assert_empty target.instance_variable_get(:@listeners)
    source.edit([[0...3, "ONE"]])
    assert_includes projection.text, "ONE"
  ensure
    projection&.close
  end

  def test_changed_read_only_or_alias_targets_are_rejected_before_mutation
    source = Canopus::Buffer.new("one")
    clone = Canopus::Buffer.new(rope: source.rope)
    projection = Canopus::MultiBuffer.new(excerpts: [[source, 0...3, "result"], [clone, 0...3, "alias"]])
    assert_raises(Canopus::Error) { projection.attach_sources(clone => source) }
    different = Canopus::Buffer.new("one")
    assert_raises(Canopus::Error) { projection.attach_sources(source => different) }
    read_only = Canopus::Buffer.new(rope: source.rope, read_only: true)
    assert_raises(Canopus::Error) { projection.attach_sources(source => read_only) }
    assert_equal [source, clone], projection.excerpts.map(&:buffer)
  ensure
    projection&.close
  end

  def test_constructor_validates_all_sorted_intervals_before_creating_handles
    source = Canopus::Buffer.new("a b c")
    [[4...5, 0...2, 1...3], [4...5, 0...2, 2...3]].each do |ranges|
      assert_raises(Canopus::Error) do
        Canopus::MultiBuffer.new(excerpts: ranges.map { |range| [source, range, "result"] })
      end
      assert_empty source.instance_variable_get(:@anchors)
      assert_empty source.instance_variable_get(:@listeners)
    end
    projection = Canopus::MultiBuffer.new(excerpts: [[source, 4...5, "last"], [source, 0...1, "first"]])
    assert_equal "last\nc\n\nfirst\na\n\n", projection.text
  ensure
    projection&.close
  end

  def test_swapping_snapshot_sources_does_not_detach_replacement_subscriptions
    first = Canopus::Buffer.new("one")
    second = Canopus::Buffer.new(rope: first.rope)
    projection = Canopus::MultiBuffer.new(excerpts: [[first, 0...3, "first"], [second, 0...3, "second"]])
    projection.attach_sources(first => second, second => first)
    assert_equal [second, first], projection.excerpts.map(&:buffer)
    assert_equal [1, 1], [first, second].map { |buffer| buffer.instance_variable_get(:@listeners).length }
    first.edit([[0...3, "ONE"]])
    second.edit([[0...3, "TWO"]])
    assert_equal "first\nTWO\n\nsecond\nONE\n\n", projection.text
  ensure
    projection&.close
  end
end

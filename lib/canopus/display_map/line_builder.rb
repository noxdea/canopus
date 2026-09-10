# frozen_string_literal: true

# A builder owns immutable settings and a persistent Rope snapshot. Neither
# the background thread nor provisional reads mutate the visible Tree.
class Canopus::DisplayMap::LineBuilder
  EMPTY_LINES = Canopus::DisplayMap.const_get(:EMPTY_LINES, false)
  Row = Canopus::DisplayMap.const_get(:Row, false)
  LineSet = Canopus::DisplayMap.const_get(:LineSet, false)
  PendingLineSet = Canopus::DisplayMap.const_get(:PendingLineSet, false)
  UNWRAPPED_LINE = Canopus::DisplayMap.const_get(:UNWRAPPED_LINE, false)
  private_constant :EMPTY_LINES, :Row, :LineSet, :PendingLineSet, :UNWRAPPED_LINE

  attr_reader :rope, :fold, :blocks
  def initialize(rope, fold, tab, wrap, blocks)
    @rope, @tab, @wrap = rope, tab, wrap
    @fold = Canopus::FoldMap.new
    @fold.instance_variable_set(:@ranges, fold.ranges.dup.freeze)
    @fold.freeze
    @blocks = blocks.blocks.values.group_by(&:row).transform_values do |values|
      values.map { |block| Canopus::BlockMap::Block.new(block.id, block.row, block.text.dup.freeze, block.kind) }.freeze
    end.freeze
    freeze
  end

  def line(row, provisional: false, from: 0, checkpoint: nil)
    input = @fold.transform(@rope, row, max_bytes: provisional ? 16_384 : nil, from: from, checkpoint: checkpoint)
    return EMPTY_LINES unless input
    text, offsets = @tab.transform(*input, checkpoint: checkpoint)
    wrapped = provisional ? [[text.freeze, offsets.freeze]] : @wrap.transform(text, offsets, checkpoint: checkpoint)
    rows = wrapped.map { |value, positions| Row.new(value, positions, :text, nil) }
    (@blocks[row] || []).each do |block|
      block.text.split("\n", -1).each do |value|
        checkpoint&.call
        rows << Row.new(value.freeze, Array.new(value.length + 1, offsets.last).freeze, block.kind, block.id)
      end
    end
    LineSet.new(rows.freeze)
  end

  def pending_lines(first, count)
    hidden = @fold.ranges.map { |range| (@rope.point_at(range.begin).row + 1)..@rope.point_at(range.end).row }
    pointer = 0
    Array.new(count) do |index|
      row = first + index
      pointer += 1 while hidden[pointer] && hidden[pointer].end < row
      if hidden[pointer]&.cover?(row)
        EMPTY_LINES
      else
        count = 1 + (@blocks[row] || []).sum { |block| block.text.count("\n") + 1 }
        count == 1 ? UNWRAPPED_LINE : PendingLineSet.new(count)
      end
    end
  end
end

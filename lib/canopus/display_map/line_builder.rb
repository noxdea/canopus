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
  def initialize(rope, fold, overlay, tab, wrap, blocks)
    @rope, @tab, @wrap = rope, tab, wrap
    @overlay = overlay.snapshot
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
    text, offsets = input
    overlays = @overlay.transform(@rope, row, text, offsets)
    wrapped = provisional ? [[text.freeze, offsets.freeze, overlays]] : @wrap.transform(text, offsets,
      checkpoint: checkpoint, overlays: overlays, tab_map: @tab)
    rows = wrapped.map do |value, positions, placements|
      placements ||= []
      value, positions, placements = @tab.transform(value, positions, checkpoint: checkpoint, overlays: placements) if provisional && !placements.empty?
      value, positions = @tab.transform(value, positions, checkpoint: checkpoint) if provisional && placements.empty?
      Row.new(value.freeze, positions.freeze, :text, placements.empty? ? nil : placements)
    end
    rows = overlay_blocks(row, :above) + rows + overlay_blocks(row, :below)
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
        count = 1 + %i[above below].sum { |position| @overlay.blocks(row, position).sum(&:row_span) } +
          (@blocks[row] || []).sum { |block| block.text.count("\n") + 1 }
        count == 1 ? UNWRAPPED_LINE : PendingLineSet.new(count)
      end
    end
  end

  private

  def overlay_blocks(row, position)
    @overlay.blocks(row, position).flat_map do |block|
      anchor = position == :above ? 0 : @rope.line(row).bytesize
      [Row.new("".freeze, [anchor].freeze, :overlay_block, block)] +
        Array.new(block.row_span - 1) { Row.new("".freeze, [anchor].freeze, :overlay_block_continuation, nil) }
    end
  end
end

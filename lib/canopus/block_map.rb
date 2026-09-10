# frozen_string_literal: true

module Canopus
  class BlockMap
    Block = Data.define(:id, :row, :text, :kind)
    attr_reader :blocks
    def initialize = @blocks = {}
    def insert(id, row:, text:, kind: :diagnostic) = @blocks[id] = Block.new(id, row, text, kind)
    def remove(id) = @blocks.delete(id)
    def at(row) = @blocks.values.select { |block| block.row == row }
    def apply(patch)
      @blocks.transform_values! do |block|
        old = patch.before.line_start([block.row, patch.before.line_count - 1].min)
        row = patch.after.point_at(patch.map_offset(old, bias: :left)).row
        Block.new(block.id, row, block.text, block.kind)
      end
    end
  end
end

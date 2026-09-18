# frozen_string_literal: true

module Canopus
  Selection = Data.define(:id, :anchor, :head, :goal) do
    def start = [anchor, head].min
    def end = [anchor, head].max
    def range = self.start...self.end
    def empty? = anchor == head
    def reversed? = head < anchor
  end

  BlockSelection = Data.define(:anchor, :head) do
    include Enumerable

    def each
      return enum_for(__method__) unless block_given?
      first, last = [anchor.row, head.row].minmax
      first.upto(last) do |row|
        yield DisplayPoint.new(row, anchor.column), DisplayPoint.new(row, head.column)
      end
    end
  end
end

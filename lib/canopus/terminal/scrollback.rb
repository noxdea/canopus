# frozen_string_literal: true

require "denebola"

module Canopus
  module Terminal
    class Scrollback
      include Enumerable
      Count = Struct.new(:lines) do
        def self.zero = new(0)
        def +(other) = self.class.new(lines + other.lines)
      end
      Row = Struct.new(:cells) do
        def summary = Count.new(1)
      end
      attr_reader :tree, :limit

      def initialize(limit)
        raise ArgumentError, "scrollback limit must be nonnegative" unless limit.is_a?(Integer) && limit >= 0
        @limit = limit
        clear
      end

      def clear = @tree = Denebola::Tree.new(summary: Count)
      def length = tree.size
      alias size length
      def [](index) = tree[index]&.cells
      def each(&block) = block ? tree.each { |row| block.call(row.cells) } : enum_for(__method__)

      def push(cells)
        return if limit.zero?
        frozen = cells.map { |cell| cell.dup.tap { |copy| copy.text = copy.text.dup.freeze }.freeze }.freeze
        @tree = tree.push(Row.new(frozen).freeze)
        @tree = tree.slice(tree.size - limit, limit) if tree.size > limit
      end
    end
  end
end

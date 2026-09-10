# frozen_string_literal: true

module Canopus
  class TabMap
    attr_reader :tab_size
    def initialize(tab_size: 4)
      raise ArgumentError, "tab size must be positive" unless tab_size.is_a?(Integer) && tab_size.positive?
      @tab_size = tab_size
    end
    def transform(text, offsets, checkpoint: nil)
      output, positions, column, i = +"", [offsets.first], 0, 0
      text.each_grapheme_cluster do |char|
        checkpoint&.call if (i & 1023).zero?
        if char == "\t"
          count = @tab_size - column % @tab_size
          output << " " * count
          (count - 1).times { positions << offsets[i] }
          positions << offsets[i + 1]
          column += count
        else
          output << char
          char.length.times { |index| positions << offsets[i + index + 1] }
          column += char.ascii_only? ? char.length : Zaniah::Unicode.width(char)
        end
        i += char.length
      end
      [output, positions]
    end
  end
end

# frozen_string_literal: true

class Canopus::DisplayMap::OverlayMap
  Inline = Data.define(:item, :offset, :width, :cell_width, :height, :align)
  Block = Data.define(:item, :row, :height, :row_span, :position)

  attr_reader :line_height

  def initialize
    @inlines, @inline_values, @blocks, @line_height, @input = {}.freeze, [].freeze, {}.freeze, 1, nil
  end

  def replace(items, rope:, font: nil, font_size: 14, line_height: 20)
    raise ArgumentError, "decorations must be an array" unless items.is_a?(Array)
    validate_size(font_size, "font size")
    validate_size(line_height, "line height")
    input = [items, font&.object_id, font_size, line_height]
    return [] if @input == input

    inlines, blocks = Hash.new { |hash, key| hash[key] = [] }, Hash.new { |hash, key| hash[key] = [] }
    items.each do |item|
      raise TypeError, "overlays must be decoration items" unless item.is_a?(Canopus::Decoration::Item)
      next unless %i[inline block].include?(item.kind)

      if item.kind == :inline
        offset = item.range&.begin
        raise ArgumentError, "inline decoration requires a range" unless offset.is_a?(Integer)
        raise RangeError, "inline decoration is outside the buffer" unless offset.between?(0, rope.bytesize)
        row = rope.point_at(offset).row
        local = offset - rope.line_start(row)
        unless Zaniah::Unicode.grapheme_boundary?(rope.line(row), local)
          raise ArgumentError, "inline decoration splits a grapheme cluster"
        end
        style = item.style.is_a?(Hash) ? item.style : {}
        align = style.fetch(:align, :after)
        raise ArgumentError, "inline alignment must be before or after" unless %i[before after].include?(align)
        text = item.content.is_a?(String) ? item.content : item.content.respond_to?(:text) ? item.content.text.to_s : item.content.to_s
        text = text.encode(Encoding::UTF_8)
        padding_left = numeric_style(style, :padding_left)
        padding_right = numeric_style(style, :padding_right)
        validate_size(padding_left, "inline left padding", allow_zero: true)
        validate_size(padding_right, "inline right padding", allow_zero: true)
        padding = padding_left + padding_right
        width = numeric_style(style, :width, nil) || (font ? font.advance_width(text.codepoints, size: font_size) : Zaniah::Unicode.width(text) * font_size * 0.6)
        width += padding
        height = numeric_style(style, :height, line_height)
        validate_size(width, "inline width")
        validate_size(height, "inline height")
        raise ArgumentError, "inline height must not exceed line height" if height > line_height
        cells = numeric_style(style, :cells, Zaniah::Unicode.width(text))
        validate_size(cells, "inline cell width", allow_zero: true)
        inlines[row] << Inline.new(item, offset, width.to_f, cells.to_f, height.to_f, align)
      else
        row = item.row
        raise ArgumentError, "block decoration requires a row" unless row.is_a?(Integer)
        raise RangeError, "block decoration is outside the buffer" unless row.between?(0, rope.line_count - 1)
        style = item.style.is_a?(Hash) ? item.style : {}
        position = style.fetch(:position, :above)
        raise ArgumentError, "block position must be above or below" unless %i[above below].include?(position)
        height = numeric_style(style, :height, line_height)
        validate_size(height, "block height")
        blocks[row] << Block.new(item, row, height.to_f, (height.to_f / line_height).ceil, position)
      end
    end
    inlines.each_value { |values| values.sort_by! { |value| [value.offset, value.item.priority] }.freeze }
    blocks.each_value { |values| values.sort_by! { |value| value.item.priority }.freeze }
    inlines, blocks = inlines.to_h.freeze, blocks.to_h.freeze
    inline_values = inlines.values.flatten.sort_by(&:offset).freeze
    return [] if @inlines == inlines && @blocks == blocks && @line_height == line_height

    affected = (@inlines.keys | @blocks.keys | inlines.keys | blocks.keys).select do |row|
      @inlines.fetch(row, nil) != inlines.fetch(row, nil) ||
        @blocks.fetch(row, nil) != blocks.fetch(row, nil) || @line_height != line_height
    end
    @inlines, @inline_values, @blocks, @line_height, @input = inlines, inline_values, blocks, line_height, input
    affected.sort
  end

  def transform(rope, row, text, offsets)
    start = rope.line_start(row)
    first, last = offsets.first + start, offsets.last + start
    index = @inline_values.bsearch_index { |inline| inline.offset >= first }
    return [] unless index
    values = []
    while (inline = @inline_values[index]) && inline.offset <= last
      values << inline
      index += 1
    end
    boundaries, byte = [0], 0
    text.each_char { |character| boundaries << (byte += character.bytesize) }
    values.filter_map do |inline|
      local = inline.offset - start
      column = offsets.bsearch_index { |offset| offset >= local } || offsets.length - 1
      next unless offsets[column] == local
      inline.with(offset: boundaries.fetch(column))
    end.freeze
  end

  def blocks(row, position) = @blocks.fetch(row, []).select { |block| block.position == position }

  def snapshot
    copy = self.class.allocate
    copy.instance_variable_set(:@inlines, @inlines)
    copy.instance_variable_set(:@inline_values, @inline_values)
    copy.instance_variable_set(:@blocks, @blocks)
    copy.instance_variable_set(:@line_height, @line_height)
    copy.instance_variable_set(:@input, nil)
    copy.freeze
  end

  private

  def numeric_style(style, key, default = 0)
    value = style.fetch(key, default)
    raise ArgumentError, "#{key} must be numeric" unless value.nil? || value.is_a?(Numeric)
    value
  end

  def validate_size(value, name, allow_zero: false)
    valid = value.is_a?(Numeric) && value.real? && value.finite? && (allow_zero ? value >= 0 : value.positive?)
    raise ArgumentError, "#{name} must be #{allow_zero ? 'nonnegative' : 'positive'} and finite" unless valid
  end
end

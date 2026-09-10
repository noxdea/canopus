# frozen_string_literal: true

module Canopus
  class WrapMap
    attr_reader :width, :font, :font_size, :font_paths, :typesetter
    def initialize(width: nil, font: nil, font_size: 14, font_paths: nil, typesetter: nil)
      raise ArgumentError, "use typesetter or font/font_paths, not both" if typesetter && (font || font_paths)
      font ||= typesetter&.font
      valid = font ? width.is_a?(Numeric) && width.finite? && width.positive? : width.is_a?(Integer) && width.positive?
      raise ArgumentError, "wrap width must be positive" if width && !valid
      raise ArgumentError, "font size must be finite and positive" unless font_size.is_a?(Numeric) && font_size.finite? && font_size.positive?
      @width, @font, @font_size = width, font, font_size
      @font_paths = font_paths&.frozen? ? font_paths : font_paths&.dup&.freeze
      @typesetter, @typesetters = typesetter, {}
      if @font
        @layout_template = if typesetter
          typesetter.fork(capacity: 32)
        else
          Zaniah::TextSystem::Typesetter.new(
            font: Alhena::Font.new(@font.data, index: @font.index, axes: @font.axis_values),
            font_db: Zaniah::TextSystem::FontDB.new(paths: @font_paths), capacity: 32,
            shaper: :native, segmenter: :native)
        end
      end
    end
    def transform(text, offsets, checkpoint: nil)
      return pixel_rows(text, offsets, checkpoint) if @width && @font
      return [[text.freeze, offsets.freeze]] if !@width || (text.ascii_only? && text.length <= @width)
      rows, offset, chunk, positions, cells = [], 0, +"", [offsets.first], 0
      text.each_grapheme_cluster do |grapheme|
        checkpoint&.call if (offset & 1023).zero?
        advance = grapheme.ascii_only? ? grapheme.length : Zaniah::Unicode.width(grapheme)
        if !chunk.empty? && cells + advance > @width
          rows << [chunk.freeze, positions.freeze]
          chunk, positions, cells = +"", [offsets[offset]], 0
        end
        chunk << grapheme
        cells += advance
        grapheme.length.times do
          checkpoint&.call if (offset & 1023).zero?
          offset += 1
          positions << offsets[offset]
        end
      end
      rows << [chunk.freeze, positions.freeze]
      rows
    end
    def close
      @typesetters.each_value(&:close)
      @typesetters.clear
      @layout_template&.close
      @layout_template = nil
    end

    private
    def pixel_rows(text, offsets, checkpoint)
      # The template is never used for shaping. Each owner copies its complete
      # typography without reading the rendering thread's mutable caches.
      typesetter = @typesetters[Thread.current] ||= @layout_template.fork(capacity: 32)
      rows, pending, positions, column = [], +"", [offsets.first], 0
      # Bound each shaping input; keep grapheme clusters intact, including one
      # unusually large cluster. The last row carries into the next batch.
      pixel_graphemes(typesetter, text).each do |grapheme|
        checkpoint&.call
        pending << grapheme
        grapheme.length.times { column += 1; positions << offsets[column] }
        next if pending.bytesize < 4096
        parts = split_pixels(typesetter, pending, positions, checkpoint)
        pending, positions = parts.pop
        rows.concat(parts)
        pending, positions = pending.dup, positions.dup
      end
      rows.concat(split_pixels(typesetter, pending, positions, checkpoint))
      rows
    end

    def split_pixels(typesetter, text, offsets, checkpoint)
      layout = typesetter.layout_line(text, size: @font_size)
      return [[text.freeze, offsets.freeze]] if layout.width <= @width
      clusters, bytes, columns = pixel_graphemes(typesetter, text).to_a, [0], [0]
      clusters.each { |value| bytes << bytes.last + value.bytesize; columns << columns.last + value.length }
      rows, first = [], 0
      while first < clusters.length
        checkpoint&.call
        origin = layout.x_for_index(bytes[first])
        last = first + 1
        last += 1 while last < clusters.length && layout.x_for_index(bytes[last + 1]) - origin <= @width
        value = loop do
          value = text.byteslice(bytes[first]...bytes[last])
          break value if last == first + 1 || typesetter.layout_line(value, size: @font_size).width <= @width
          last -= 1 # Re-shaping a row can change boundary kerning/ligatures.
        end
        rows << [value.freeze, offsets[columns[first]..columns[last]].freeze]
        first = last
      end
      rows
    end

    def pixel_graphemes(typesetter, text)
      return text.each_grapheme_cluster if typesetter.segmenter.equal?(Zaniah::Unicode)
      parts = typesetter.segmenter.grapheme_clusters(text)
      unless parts.is_a?(Array) && parts.all? { |part| part.is_a?(String) && !part.empty? && part.valid_encoding? } && parts.join == text
        raise Zaniah::Error, "segmenter must partition the UTF-8 text into nonempty strings"
      end
      parts
    end
  end
end

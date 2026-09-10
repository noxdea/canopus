# frozen_string_literal: true

module Canopus
  class FoldMap
    attr_reader :ranges
    def initialize = @ranges = []
    def fold(range)
      ending = range.end + (range.exclude_end? ? 0 : 1)
      raise ArgumentError, "invalid fold" unless range.begin >= 0 && ending > range.begin
      @ranges << (range.begin...ending)
      merged = []
      @ranges.sort_by(&:begin).each do |entry|
        if merged.last && entry.begin < merged.last.end
          previous = merged.pop
          merged << (previous.begin...[previous.end, entry.end].max)
        else
          merged << entry
        end
      end
      @ranges = merged
    end
    def unfold(offset) = @ranges.reject! { |range| range.cover?(offset) }
    def apply(patch)
      @ranges = @ranges.filter_map do |range|
        first, last = patch.map_offset(range.begin, bias: :left), patch.map_offset(range.end, bias: :right)
        first...last if first < last
      end
    end
    def transform(rope, row, max_bytes: nil, from: 0, checkpoint: nil)
      start = rope.line_start(row)
      return nil if @ranges.any? { |range| range.begin < start && range.end >= start }
      finish = line_end(rope, row)
      segments, cursor = [], start
      @ranges.each do |range|
        next if range.end <= cursor || range.begin > finish
        segments << [cursor, range.begin, nil]
        segments << [range.begin, range.end, "…"]
        cursor = range.end
        end_row = rope.point_at(cursor).row
        finish = line_end(rope, end_row)
      end
      segments << [cursor, [finish, cursor].max, nil]
      text, offsets = +"", []
      requested = start + from.clamp(0, finish - start)
      segments.each do |first, last, marker|
        next if last < requested || (last == requested && first < last)
        break if max_bytes && text.bytesize >= max_bytes
        if marker
          offsets << first - start if offsets.empty?
          text << marker
          offsets << last - start
        else
          first = boundary(rope, [first, requested].max, -1)
          last = boundary(rope, [last, first + max_bytes - text.bytesize].min, -1) if max_bytes
          offsets << first - start if offsets.empty?
          value = rope.byteslice(first, [last - first, 0].max).to_s
          append(text, offsets, value, first - start, checkpoint)
        end
      end
      offsets << finish - start if offsets.empty?
      [text, offsets]
    end
    private
    def line_end(rope, row)
      return rope.bytesize if row + 1 == rope.line_count
      ending = rope.line_start(row + 1)
      first = boundary(rope, [ending - 4, rope.line_start(row)].max, 1)
      tail = rope.byteslice(first, ending - first).to_s
      ending - tail[/(?:\r\n|[\r\n\u2028\u2029])\z/].to_s.bytesize
    end
    def boundary(rope, offset, step)
      rope.point_at(offset)
      offset
    rescue RangeError
      offset += step
      retry
    end
    def append(text, offsets, value, local, checkpoint)
      text << value
      value.each_char.with_index do |char, index|
        checkpoint&.call if (index & 1023).zero?
        local += char.bytesize
        offsets << local
      end
    end
  end
end

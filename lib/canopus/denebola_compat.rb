# frozen_string_literal: true

# Canopus asks lazy ropes for a bounded line window while moving cursors. Keep
# this small compatibility shim until that helper is part of Denebola's API.
unless Denebola::LazyRope.method_defined?(:line_window)
  class Denebola::LazyRope
    def line_end(row)
      start = line_start(row)
      ending = row + 1 < line_count(exact: true) ? line_start(row + 1) : bytesize
      tail_start = [ending - 3, start].max
      tail = send(:read_bytes, tail_start, [ending - tail_start, 3].min)
      ending - (tail.end_with?("\r\n") ? 2 : tail.end_with?("\r", "\n") ? 1 : 0)
    end

    def line_window(row, from: 0, max_bytes: 16_384)
      start, ending = line_start(row), line_end(row)
      offset = (start + from).clamp(start, ending)
      offset -= 1 while offset > start && offset < ending && (send(:read_bytes, offset, 1).getbyte(0) & 0xc0) == 0x80
      value = send(:read_bytes, offset, [max_bytes, ending - offset].min)
      finish = value.bytesize
      while finish.positive? && !value.byteslice(0, finish).force_encoding(Encoding::UTF_8).valid_encoding?
        finish -= 1
      end
      [value.byteslice(0, finish).to_s.force_encoding(Encoding::UTF_8), offset - start]
    end
  end
end

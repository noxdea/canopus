# frozen_string_literal: true

module Canopus
  # Read-only UTF-8 rope facade. Newline offsets are packed; document bytes stay
  # on disk and a bounded LRU serves positioned pages independently of IO position.
  class LazyRope
    PAGE_SIZE = 65_536
    attr_reader :bytesize, :cached_bytes, :line_ending
    def initialize(path, page_limit: 32)
      raise ArgumentError, "page limit must be positive" unless page_limit.is_a?(Integer) && page_limit.positive?
      @file = File.open(path, File::RDONLY | File::BINARY | File::SHARE_DELETE)
      @positioned_read, @read_lock = true, Mutex.new
      @stamp = stamp
      @origin = @file.size >= 3 && read_at(3, 0) == "\xEF\xBB\xBF".b ? 3 : 0
      @bytesize = @file.size - @origin
      @pages, @page_limit, @cached_bytes = {}, page_limit, 0
      @starts = [0].pack("Q<")
      @checkpoints = [0, 0, 0].pack("Q<3")
      @length = @utf16_length = 0
      index_lines
      @starts.freeze
      @checkpoints.freeze
      @line_ending ||= "\n"
    rescue StandardError
      @file&.close
      raise
    end
    def lazy? = true
    def line_count = @starts.bytesize / 8
    def length = @length
    def utf16_length = @utf16_length
    def empty? = @bytesize.zero?
    def close = (@file.close unless @file.closed?)
    def line_start(row)
      raise RangeError, "line outside document" unless row.is_a?(Integer) && row.between?(0, line_count - 1)
      @starts.unpack1("Q<", offset: row * 8)
    end
    def line(row)
      start = line_start(row)
      ending = row + 1 < line_count ? line_start(row + 1) : @bytesize
      read_bytes(start, ending - start).force_encoding(Encoding::UTF_8).sub(/(?:\r\n|[\r\n\u2028\u2029])\z/, "")
    end
    def line_end(row)
      ending = row + 1 < line_count ? line_start(row + 1) : @bytesize
      return ending if row + 1 == line_count
      tail = read_bytes([ending - 3, 0].max, [ending, 3].min)
      ending - (tail.end_with?("\r\n") ? 2 : tail.end_with?("\xE2\x80\xA8".b, "\xE2\x80\xA9".b) ? 3 : 1)
    end
    def line_window(row, from: 0, max_bytes: 16_384)
      start, ending = line_start(row), line_end(row)
      offset = (start + from).clamp(start, ending)
      offset -= 1 while offset > start && offset < ending && (read_bytes(offset, 1).getbyte(0) & 0xc0) == 0x80
      value = read_bytes(offset, [max_bytes, ending - offset].min)
      value = value.byteslice(0, complete_utf8_length(value)) unless value.empty?
      [value.force_encoding(Encoding::UTF_8), offset - start]
    end
    def byteslice(offset, count = nil)
      if offset.is_a?(Range)
        range = offset
        offset = range.begin
        count = range.end + (range.exclude_end? ? 0 : 1) - offset
      end
      count ||= @bytesize - offset
      validate_offset(offset)
      validate_offset(offset + count)
      raise RangeError, "negative slice length" if count.negative?
      Denebola::Rope.new(read_bytes(offset, count).force_encoding(Encoding::UTF_8))
    end
    def point_at(offset)
      validate_offset(offset)
      low, high = 0, line_count
      while low < high
        middle = (low + high) / 2
        line_start(middle) <= offset ? low = middle + 1 : high = middle
      end
      row = [low - 1, 0].max
      Denebola::Point.new(row, prefix_count(offset) - prefix_count(line_start(row)))
    end
    def offset_at(point)
      start, ending = line_start(point.row), line_end(point.row)
      base = prefix_count(start)
      raise RangeError, "column outside line" unless point.column.is_a?(Integer) && point.column.between?(0, prefix_count(ending) - base)
      offset_for_count(base + point.column)
    end
    def utf16_point_at(offset)
      point = point_at(offset)
      Denebola::Point.new(point.row, prefix_count(offset, utf16: true) - prefix_count(line_start(point.row), utf16: true))
    end
    def offset_at_utf16_point(point)
      base = prefix_count(line_start(point.row), utf16: true)
      ending = prefix_count(line_end(point.row), utf16: true)
      raise RangeError, "UTF-16 column outside line" unless point.column.is_a?(Integer) && point.column.between?(0, ending - base)
      offset_for_count(base + point.column, utf16: true)
    end
    def utf16_offset_at(offset)
      validate_offset(offset)
      prefix_count(offset, utf16: true)
    end
    def offset_at_utf16(units)
      raise RangeError, "UTF-16 offset outside document" unless units.is_a?(Integer) && units.between?(0, @utf16_length)
      offset_for_count(units, utf16: true)
    end
    def each_chunk
      return enum_for(__method__) unless block_given?
      offset = 0
      while offset < @bytesize
        value = read_bytes(offset, [PAGE_SIZE, @bytesize - offset].min)
        finish = complete_utf8_length(value)
        raise Error, "invalid UTF-8 file" if finish.zero?
        yield value.byteslice(0, finish).force_encoding(Encoding::UTF_8)
        offset += finish
      end
    end
    def to_s = each_chunk.to_a.join
    def apply_edits(*) = raise(Error, "large file is read-only")
    def check_invariants!
      raise Error, "invalid line index" unless line_start(0).zero? && @starts.bytesize % 8 == 0
      true
    end

    private
    def checkpoint(value, dimension)
      low, high = 0, @checkpoints.bytesize / 24
      while low < high
        middle = (low + high) / 2
        @checkpoints.unpack1("Q<", offset: middle * 24 + dimension * 8) <= value ? low = middle + 1 : high = middle
      end
      @checkpoints.byteslice([low - 1, 0].max * 24, 24).unpack("Q<3")
    end
    def prefix_count(offset, utf16: false)
      base, chars, units = checkpoint(offset, 0)
      value = read_bytes(base, offset - base).force_encoding(Encoding::UTF_8)
      utf16 ? units + (value.ascii_only? ? value.bytesize : value.encode(Encoding::UTF_16LE).bytesize / 2) : chars + value.length
    end
    def offset_for_count(count, utf16: false)
      offset, chars, units = checkpoint(count, utf16 ? 2 : 1)
      remaining = count - (utf16 ? units : chars)
      return offset if remaining.zero?
      value = read_bytes(offset, [PAGE_SIZE + 4, @bytesize - offset].min).force_encoding(Encoding::UTF_8)
      value = value.byteslice(0, complete_utf8_length(value))
      value.each_codepoint do |codepoint|
        break if remaining.zero?
        remaining -= utf16 && codepoint > 0xffff ? 2 : 1
        raise RangeError, "inside UTF-16 surrogate pair" if remaining.negative?
        offset += codepoint < 0x80 ? 1 : codepoint < 0x800 ? 2 : codepoint < 0x10000 ? 3 : 4
      end
      raise RangeError, "column outside document" unless remaining.zero?
      offset
    end
    def stamp
      stat = @file.stat
      [stat.size, stat.mtime, stat.ctime]
    end
    def validate_offset(offset)
      raise RangeError, "offset outside document" unless offset.is_a?(Integer) && offset.between?(0, @bytesize)
      raise RangeError, "offset inside UTF-8 character" if offset < @bytesize && (read_bytes(offset, 1).getbyte(0) & 0xC0) == 0x80
    end
    def read_bytes(offset, count)
      raise SaveConflict, "large file changed on disk; reopen it" unless stamp == @stamp
      output = String.new(capacity: count, encoding: Encoding::BINARY)
      while count.positive?
        page, local = offset.divmod(PAGE_SIZE)
        data = @pages.delete(page)
        unless data
          data = read_at([PAGE_SIZE, @bytesize - page * PAGE_SIZE].min, @origin + page * PAGE_SIZE)
          @cached_bytes += data.bytesize
          @cached_bytes -= @pages.shift.last.bytesize while @pages.length >= @page_limit
        end
        @pages[page] = data
        length = [count, data.bytesize - local].min
        raise SaveConflict, "large file was truncated" unless length.positive?
        output << data.byteslice(local, length)
        offset += length
        count -= length
      end
      output
    end
    def complete_utf8_length(value)
      index = value.bytesize - 1
      index -= 1 while index.positive? && (value.getbyte(index) & 0xC0) == 0x80
      leading = value.getbyte(index)
      length = leading < 0x80 ? 1 : leading < 0xE0 ? 2 : leading < 0xF0 ? 3 : 4
      value.bytesize - index < length ? index : value.bytesize
    end
    def read_at(count, offset)
      return @file.pread(count, offset) if @positioned_read
      @read_lock.synchronize { @file.seek(offset); @file.read(count) }
    rescue NotImplementedError
      @positioned_read = false
      retry
    end
    def index_lines
      offset, pending = 0, +"".b
      while offset < @bytesize
        chunk = read_at([PAGE_SIZE, @bytesize - offset].min, @origin + offset)
        pending << chunk
        offset += chunk.bytesize
        complete = complete_utf8_length(pending)
        complete -= 1 if complete.positive? && pending.getbyte(complete - 1) == 13 && offset < @bytesize
        text = pending.byteslice(0, complete).force_encoding(Encoding::UTF_8)
        raise Error, "large-file mode requires valid UTF-8 text" unless text.valid_encoding? && !text.include?("\0")
        base = offset - pending.bytesize
        binary = text.b
        starts = []
        binary.scan(/\r\n|[\r\n]|\xE2\x80[\xA8\xA9]/n) do |ending|
          @line_ending ||= ending.dup.force_encoding(Encoding::UTF_8)
          starts << base + Regexp.last_match.end(0)
        end
        @starts << starts.pack("Q<*")
        @length += text.length
        @utf16_length += text.ascii_only? ? text.bytesize : text.encode(Encoding::UTF_16LE).bytesize / 2
        @checkpoints << [base + complete, @length, @utf16_length].pack("Q<3")
        pending = pending.byteslice(complete..)
      end
      raise Error, "truncated UTF-8 file" unless pending.empty?
    end
  end
end

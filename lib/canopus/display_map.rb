# frozen_string_literal: true

require_relative "fold_map"
require_relative "tab_map"
require_relative "wrap_map"
require_relative "block_map"
require_relative "display_point"

module Canopus
  class DisplayMap
    BACKGROUND_THRESHOLD = 1 << 20
    Row = Data.define(:text, :offsets, :kind, :metadata)
    attr_reader :fold_map, :tab_map, :wrap_map, :block_map, :tree, :recomputed_lines
    attr_reader :layout_error

    def initialize(buffer, tab_size: 4, wrap_width: nil, background_threshold: BACKGROUND_THRESHOLD)
      raise ArgumentError, "background threshold must be nonnegative or nil" unless background_threshold.nil? || (background_threshold.is_a?(Integer) && background_threshold >= 0)
      @background_threshold, @generation = background_threshold, 0
      @buffer, @rope = buffer, buffer.rope
      @fold_map, @tab_map, @wrap_map, @block_map = FoldMap.new, TabMap.new(tab_size: tab_size), WrapMap.new(width: wrap_width), BlockMap.new
      rebuild
      @subscription = buffer.on_edit { |patch| apply(patch) }
    end
    def dispose
      return if @disposed
      @disposed = true
      @layout_error = nil
      @subscription.detach
      stop_wrap(@wrap_map, @worker)
      @worker = @pending_result = nil
      nil
    end
    def pending? = !!(!@disposed && !@failed && !@lazy && @background && (@computed_prefix < @tree.size || @tree.summary.pending_rows.positive?))
    def progress
      return [@rope.line_count, @rope.line_count] if @lazy
      [@computed_prefix - @tree.prefix_summary(@computed_prefix).pending_rows, @tree.size]
    end

    # Call only from the foreground event loop, before painting. Read methods
    # deliberately never install completed work halfway through a frame.
    def poll(max_lines: 256)
      raise ArgumentError, "max_lines must be positive" unless max_lines.is_a?(Integer) && max_lines.positive?
      return false if @disposed || !@worker
      changed, consumed = false, 0
      while consumed < max_lines
        result = @pending_result || @worker.results.pop(true)
        @pending_result = nil
        next unless result.generation == @generation
        if result.error
          @failed = true
          @layout_error = result.error
          @worker.close
          @worker = nil
          raise result.error
        end
        take = [max_lines - consumed, result.lines.length].min
        values = result.lines.take(take)
        replace_values(result.first, take, values)
        @computed_prefix = [@computed_prefix, result.first + take].max if result.first <= @computed_prefix
        take.times { |index| @row_cache.delete(result.first + index) }
        @recomputed_lines += take
        consumed += take
        changed = true
        if take < result.lines.length
          @pending_result = result.with(first: result.first + take, lines: result.lines.drop(take).freeze)
        end
      end
      changed
    rescue ThreadError
      changed
    end
    def row_count = @lazy ? @rope.line_count : @tree.summary.display_rows
    def wrap_width=(width)
      raise Error, "soft wrapping is disabled for large read-only files" if @lazy && width
      return if width == @wrap_map.width && !@wrap_map.font
      replace_wrap(WrapMap.new(width: width))
    end
    def wrap_pixels(width, font: nil, font_size:, font_paths: nil, typesetter: nil)
      raise Error, "soft wrapping is disabled for large read-only files" if @lazy
      current = @wrap_map
      return if current.width == width && current.font.equal?(font || typesetter&.font) && current.font_size == font_size && current.font_paths == font_paths && current.typesetter.equal?(typesetter)
      replace_wrap(WrapMap.new(width: width, font: font, font_size: font_size, font_paths: font_paths, typesetter: typesetter))
    end
    def tab_size=(size)
      return if size == @tab_map.tab_size
      @tab_map = TabMap.new(tab_size: size)
      rebuild(reuse: true)
    end
    def fold(range)
      raise Error, "folding is disabled for large read-only files" if @lazy
      range = range.begin...(range.end + (range.exclude_end? ? 0 : 1))
      @rope.point_at(range.begin)
      @rope.point_at(range.end)
      first, last = affected_lines(@rope.point_at(range.begin).row, @rope.point_at(range.end).row)
      @fold_map.fold(range)
      replace_lines(first, last, last)
    end
    def unfold(offset)
      affected = @fold_map.ranges.select { |range| range.cover?(offset) }
      return if affected.empty?
      first = @rope.point_at(affected.map(&:begin).min).row
      last = @rope.point_at(affected.map(&:end).max).row
      first, last = affected_lines(first, last)
      @fold_map.unfold(offset)
      replace_lines(first, last, last)
    end
    def insert_block(id, row:, text:, kind: :diagnostic)
      raise Error, "inline blocks are disabled for large read-only files" if @lazy
      raise RangeError, "block row outside buffer" unless row.between?(0, @rope.line_count - 1)
      previous = @block_map.blocks[id]
      @block_map.insert(id, row: row, text: text, kind: kind)
      replace_lines(previous.row, previous.row, previous.row) if previous && previous.row != row
      replace_lines(row, row, row)
    end
    def remove_block(id)
      block = @block_map.remove(id)
      replace_lines(block.row, block.row, block.row) if block
    end
    def row(index)
      if @lazy
        raise RangeError, "display row outside buffer" unless index.between?(0, row_count - 1)
        @row_cache.shift if @row_cache.length >= 256
        return @row_cache[index] ||= build_lazy_row(index)
      end
      source, _lines, prefix = locate(index)
      lines = display_lines(source)
      lines.rows[index - prefix.display_rows]
    end
    def source_row(index) = @lazy ? index : locate(index)[0]
    def each_row(range = 0...row_count)
      return enum_for(__method__, range) unless block_given?
      range.each { |i| yield row(i), i if i.between?(0, row_count - 1) }
    end
    def to_buffer(point, bias: :left)
      if @lazy
        source = point.row.clamp(0, row_count - 1)
        line = row(source)
        return @rope.line_start(source) + line.offsets[point.column.clamp(0, line.offsets.length - 1)]
      end
      row = point.row.clamp(0, row_count - 1)
      source, _lines, prefix = locate(row)
      lines = display_lines(source)
      line = lines.rows[row - prefix.display_rows]
      column = point.column.clamp(0, line.offsets.length - 1)
      local = line.offsets[column]
      @rope.line_start(source) + local
    end
    def to_display(offset, bias: :left)
      if @lazy
        point = @rope.point_at(offset)
        local = offset - @rope.line_start(point.row)
        line = row(point.row)
        unless local.between?(line.offsets.first, line.offsets.last)
          line = @row_cache[point.row] = build_lazy_row(point.row, from: [local - 8192, 0].max)
        end
        column = line.offsets.bsearch_index { |position| position >= local } || line.text.length
        return DisplayPoint.new(point.row, column)
      end
      source = @rope.point_at(offset).row
      loop do
        start = @rope.line_start(source)
        folded = @fold_map.ranges.find { |range| range.begin < start && range.end >= start }
        break unless folded
        source = @rope.point_at(folded.begin).row
      end
      local = offset - @rope.line_start(source)
      lines = display_lines(source, local: local).rows
      prefix = @tree.prefix_summary(source).display_rows
      lines.each_with_index do |line, i|
        next unless line.kind == :text
        next if local > line.offsets.last
        column = line.offsets.bsearch_index { |n| bias == :left ? n >= local : n > local }
        column = column ? (bias == :right ? [column - 1, 0].max : column) : line.offsets.length - 1
        return DisplayPoint.new(prefix + i, column)
      end
      DisplayPoint.new(prefix + lines.length - 1, lines.last&.text&.length || 0)
    end

    private
    def replace_wrap(wrap)
      # A copy may own native resources. Cancel/join before closing its providers,
      # then transfer the new immutable typography snapshot to the next worker.
      if @wrap_map.font
        stop_wrap(@wrap_map, @worker)
        @worker = @pending_result = nil
      else
        @wrap_map.close
      end
      @wrap_map = wrap
      rebuild(reuse: true)
    end

    def stop_wrap(wrap, worker)
      worker&.close
      if worker&.thread&.alive?
        # An uninterruptible custom native call can outlive Thread#kill. Never
        # release its providers until it really stops. Default Ruby layout needs
        # no reaper thread; native providers must keep their calls bounded.
        Thread.new { worker.thread.join; wrap.close }.name = "canopus-layout-cleanup"
      else
        wrap.close
      end
    end

    def affected_lines(first, last)
      ranges = @fold_map.ranges.map { |range| [@rope.point_at(range.begin).row, @rope.point_at(range.end).row] }
      loop do
        previous = [first, last]
        ranges.each do |from, to|
          next if to < first || from > last
          first, last = [first, from].min, [last, to].max
        end
        return [first, last] if previous == [first, last]
      end
    end

    def display_lines(source, local: nil)
      value = @tree[source]
      return value unless value.is_a?(PendingLineSet)
      cached = @row_cache[source]
      if cached && local
        positions = cached.rows.first.offsets
        cached = nil unless local.between?(positions.first, positions.last)
      end
      unless cached
        @row_cache.shift if @row_cache.length >= 256
        cached = @row_cache[source] = @builder.line(source, provisional: true, from: local ? [local - 8192, 0].max : 0)
      end
      cached
    end

    def build_lazy_row(row, from: 0)
      @recomputed_lines += 1
      text, offset = @rope.line_window(row, from: from)
      offsets = [offset]
      text.each_char { |char| offset += char.bytesize; offsets << offset }
      value, positions = @tab_map.transform(text, offsets)
      Row.new(value.freeze, positions.freeze, :text, nil)
    end
    def locate(index)
      raise RangeError, "display row outside buffer" unless index.between?(0, row_count - 1)
      return @location_cache[index] if @location_cache.key?(index)
      @location_cache.shift if @location_cache.length >= 256
      @location_cache[index] = @tree.locate(index, :display_rows)
    end
    def build_line(row)
      @recomputed_lines += 1
      @builder.line(row)
    end
    def rebuild(reuse: false)
      @recomputed_lines = 0
      @row_cache = {}
      @location_cache = {}
      @pending_result = nil
      @generation += 1
      @failed = false
      @layout_error = nil
      @lazy = @rope.respond_to?(:lazy?) && @rope.lazy?
      if @lazy
        @worker&.close
        @worker = nil
        return
      end
      @builder = LineBuilder.new(@rope, @fold_map, @tab_map, @wrap_map, @block_map)
      @background = background_layout?(@rope)
      unless reuse && @background && @tree && @tree.size == @rope.line_count
        values = @background ? @builder.pending_lines(0, @rope.line_count) : Array.new(@rope.line_count) { |row| build_line(row) }
        @tree = Denebola::Tree.new(values, summary: Summary)
      end
      @computed_prefix = @background ? 0 : @tree.size
      schedule
    end
    def replace_lines(first, old_last, new_last)
      @generation += 1
      @row_cache = {}
      @pending_result = nil
      @failed = false
      @layout_error = nil
      @builder = LineBuilder.new(@rope, @fold_map, @tab_map, @wrap_map, @block_map)
      replacement = @background ? @builder.pending_lines(first, new_last - first + 1) : Array.new(new_last - first + 1) { |i| build_line(first + i) }
      if first < @computed_prefix
        @computed_prefix = old_last + 1 >= @computed_prefix ? first : @computed_prefix + new_last - old_last
      end
      replace_values(first, old_last - first + 1, replacement)
      @computed_prefix = @tree.size unless @background
      schedule
    end
    def replace_values(first, count, replacement)
      tail = first + count
      @tree = @tree.slice(0, first).append(replacement).append(@tree.slice(tail, @tree.size - tail))
      @location_cache.clear
    end
    def schedule
      if pending?
        @worker ||= Worker.new
        @worker.submit(@generation, @tree, @builder, @computed_prefix)
      else
        @worker&.close
        @worker = nil
      end
    end
    def background_layout?(rope)
      @background_threshold && (@wrap_map.font || rope.bytesize >= @background_threshold)
    end
    def apply(patch)
      if patch.is_a?(Patch::Reload)
        @rope = patch.after
        rebuild
        return
      end
      if patch.is_a?(Patch::Composite)
        patch.patches.each { |part| apply(part) }
        return
      end
      if patch.edits.empty?
        @rope = patch.after
        return
      end
      if @lazy || !!background_layout?(@rope) != !!background_layout?(patch.after)
        @fold_map.apply(patch)
        @block_map.apply(patch)
        @rope = patch.after
        rebuild
        return
      end
      @recomputed_lines = 0
      first = patch.edits.map { |e| patch.before.point_at(e.old_range.begin).row }.min
      old_last = patch.edits.map { |e| patch.before.point_at(e.old_range.end).row }.max
      new_last = patch.edits.map { |e| patch.after.point_at(e.new_range.end).row }.max
      first, old_last = affected_lines(first, old_last)
      new_last = [new_last, patch.after.point_at(patch.map_offset(patch.before.line_start(old_last))).row].max
      @fold_map.apply(patch)
      @block_map.apply(patch)
      @rope = patch.after
      replace_lines(first, old_last, new_last)
    end
  end
end

require_relative "display_map/summary"
require_relative "display_map/line_set"
require_relative "display_map/pending_line_set"

Canopus::DisplayMap::EMPTY_LINES = Canopus::DisplayMap::LineSet.new([].freeze)
Canopus::DisplayMap::UNWRAPPED_LINE = Canopus::DisplayMap::PendingLineSet.new(1)
Canopus::DisplayMap.send(:private_constant, :LineSet, :PendingLineSet, :EMPTY_LINES, :UNWRAPPED_LINE)

require_relative "display_map/line_builder"
require_relative "display_map/worker"
Canopus::DisplayMap.send(:private_constant, :LineBuilder, :Worker)

# frozen_string_literal: true

module Canopus
  module Vim::Motionable
    private
    def source
      if @source_version != @editor.buffer.version
        @source_version = @editor.buffer.version
        @source = @editor.buffer.text
        @characters = @source.grapheme_clusters
        total = 0
        @offsets = [0] + @characters.map { |character| total += character.bytesize }
      end
      @source
    end

    def character_index(offset)
      source
      @offsets.bsearch_index { |value| value >= offset } || @characters.length
    end
    def character_at(offset)
      index = character_index(offset)
      @characters[index] || ""
    end
    def row_at(offset) = @editor.buffer.rope.point_at(offset.clamp(0, @editor.buffer.rope.bytesize)).row
    def line_start(row) = @editor.buffer.rope.line_start(row.clamp(0, @editor.buffer.line_count - 1))
    def line_end(row) = line_start(row) + @editor.buffer.line(row).bytesize
    def last_row
      count = @editor.buffer.line_count
      count > 1 && @editor.buffer.line(count - 1).empty? ? count - 2 : count - 1
    end
    def next_offset(offset)
      index = character_index(offset)
      @offsets[[index + 1, @characters.length].min]
    end
    def previous_offset(offset)
      index = character_index(offset)
      @offsets[[index - 1, 0].max]
    end
    def normal_offset(offset)
      row = [row_at(offset), last_row].min
      first, ending = line_start(row), line_end(row)
      return first if first == ending
      offset.clamp(first, previous_offset(ending))
    end
    def first_nonblank(row)
      line_start(row) + @editor.buffer.line(row)[/\A[ \t]*/].bytesize
    end
    def horizontal(offset, amount, insertion: false)
      index = character_index(offset)
      row = row_at(offset)
      target = @offsets[(index + amount).clamp(0, @characters.length)]
      first, ending = line_start(row), line_end(row)
      ending = previous_offset(ending) if !insertion && ending > first
      target.clamp(first, ending)
    end

    def column_at(offset)
      column = 0
      @editor.buffer.rope.byteslice(line_start(row_at(offset))...offset).to_s.each_grapheme_cluster do |character|
        column += cell_width(character, column)
      end
      column
    end
    def offset_at(row, column, insertion: false)
      offset, current = line_start(row), 0
      @editor.buffer.line(row).each_grapheme_cluster do |character|
        break if current >= column
        width = cell_width(character, current)
        break if current + width > column
        current += width
        offset += character.bytesize
      end
      insertion ? offset : normal_offset(offset)
    end

    def move_to(offset)
      if visual?
        @visual_head = normal_offset(offset)
        update_visual
      else
        @editor.select(normal_offset(offset))
      end
      @editor.reveal_cursor
    end

    def move(key, count, explicit: false)
      if (motion = motion_target(key, count, explicit: explicit))
        move_to(motion.first)
      end
    end

    def motion_target(key, count, explicit: false)
      offset, row = cursor_position, row_at(cursor_position)
      inclusive, linewise = false, false
      vertical = %w[j k up down ctrl-f ctrl-b ctrl-d ctrl-u].include?(key)
      @goal_column = nil unless vertical
      target = case key
      when "h", "left", "l", "right"
        amount = %w[h left].include?(key) ? -count : count
        horizontal(offset, amount, insertion: !!@operator)
      when "0" then line_start(row)
      when "^" then first_nonblank(row)
      when "$"
        inclusive = true
        ending = line_end([row + count - 1, last_row].min)
        ending > line_start([row + count - 1, last_row].min) ? previous_offset(ending) : ending
      when "j", "k", "up", "down", "ctrl-f", "ctrl-b", "ctrl-d", "ctrl-u"
        amount = case key
        when "ctrl-f", "ctrl-b" then [@editor.viewport_rows - 2, 1].max
        when "ctrl-d", "ctrl-u" then [@editor.viewport_rows / 2, 1].max
        else 1
        end
        amount *= -1 if %w[k up ctrl-b ctrl-u].include?(key)
        @goal_column ||= column_at(offset)
        linewise = true
        destination = (row + amount * count).clamp(0, last_row)
        return if destination == row
        offset_at(destination, @goal_column)
      when "G", "gg"
        linewise = true
        destination = key == "G" && !explicit ? last_row : count - 1
        first_nonblank(destination.clamp(0, last_row))
      when "w", "W", "b", "B", "e", "E", "ge", "gE", "ce", "cE"
        return if offset.zero? && %w[b B ge gE].include?(key)
        inclusive = %w[e E ge gE ce cE].include?(key)
        word_target(offset, key, count)
      when "{", "}"
        destination = row
        count.times do
          step = key == "}" ? 1 : -1
          destination += step
          destination += step while destination.between?(1, last_row - 1) && !@editor.buffer.line(destination).strip.empty?
          destination = destination.clamp(0, last_row)
        end
        line_start(destination)
      when "%"
        if explicit
          linewise = true
          first_nonblank(((last_row + 1) * count / 100.0).ceil.clamp(1, last_row + 1) - 1)
        else
          inclusive = true
          bracket_target(offset)
        end
      when ";", ","
        return unless @last_find
        char, kind = @last_find
        kind = {"f" => "F", "F" => "f", "t" => "T", "T" => "t"}.fetch(kind) if key == ","
        inclusive = %w[f t].include?(kind)
        find_character(char, kind, count, repeated: true)
      else return
      end
      target && [target, {inclusive: inclusive, linewise: linewise}]
    end

    def word_class(character, big)
      return :space if !character || character.match?(/\s/)
      big || character.match?(/[\p{Alnum}_]/) ? :word : :punctuation
    end
    def word_target(offset, kind, count)
      index = character_index(offset)
      big = kind.include?("W") || kind.include?("B") || kind.include?("E")
      count.times do |iteration|
        case kind.downcase.delete_prefix("c")
        when "w"
          origin = index
          initial = word_class(@characters[index], big)
          index += 1 while index < @characters.length && word_class(@characters[index], big) == initial && !@characters[index].include?("\n")
          while index < @characters.length && word_class(@characters[index], big) == :space
            break if index > origin && @characters[index].include?("\n") && @characters[index - 1].include?("\n")
            index += 1
          end
        when "b"
          index = [index - 1, 0].max
          while index.positive? && word_class(@characters[index], big) == :space
            break if @characters[index].include?("\n") && @characters[index - 1].include?("\n")
            index -= 1
          end
          initial = word_class(@characters[index], big)
          index -= 1 while initial != :space && index.positive? && word_class(@characters[index - 1], big) == initial
        when "e"
          index += 1 if index < @characters.length - 1 && !(kind.start_with?("c") && iteration.zero?)
          index += 1 while index < @characters.length - 1 && word_class(@characters[index], big) == :space
          initial = word_class(@characters[index], big)
          index += 1 while index < @characters.length - 1 && word_class(@characters[index + 1], big) == initial
        when "ge"
          initial = word_class(@characters[index], big)
          index -= 1 while index.positive? && word_class(@characters[index - 1], big) == initial
          index = [index - 1, 0].max
          index -= 1 while index.positive? && word_class(@characters[index], big) == :space
        end
      end
      @offsets[[index, @characters.length].min]
    end

    def find_character(char, kind, count, repeated: false)
      return unless char.grapheme_clusters.length == 1
      offset = cursor_position
      row = row_at(offset)
      line = @editor.buffer.line(row).grapheme_clusters
      position = @editor.buffer.rope.byteslice(line_start(row)...offset).to_s.grapheme_clusters.length
      direction = %w[F T].include?(kind) ? -1 : 1
      position += direction if repeated && %w[t T].include?(kind)
      count.times do
        position += direction
        position += direction while position.between?(0, line.length - 1) && line[position] != char
        return unless position.between?(0, line.length - 1)
      end
      position -= direction if %w[t T].include?(kind)
      line_start(row) + line.take(position).join.bytesize
    end

    def bracket_target(offset)
      source
      index = character_index(offset)
      pairs = {"(" => ")", "[" => "]", "{" => "}"}
      index += 1 while index < @characters.length && !@characters[index].include?("\n") && !"()[]{}".include?(@characters[index])
      return if index >= @characters.length || @characters[index].include?("\n")
      character = @characters[index]
      direction = pairs.key?(character) ? 1 : -1
      partner = direction == 1 ? pairs[character] : pairs.key(character)
      depth = 1
      while (index += direction).between?(0, @characters.length - 1)
        depth += 1 if @characters[index] == character
        depth -= 1 if @characters[index] == partner
        return @offsets[index] if depth.zero?
      end
      nil
    end

    def line_range(count)
      row = row_at(cursor_position)
      line_start(row)...([row + count, last_row + 1].min < @editor.buffer.line_count ? line_start([row + count, last_row + 1].min) : @editor.buffer.rope.bytesize)
    end

    def visual_ranges
      first, last = [@visual_anchor, @visual_head].minmax
      if @mode == :visual_line
        first_row, last = row_at(first), row_at(last)
        ending = last + 1 < @editor.buffer.line_count ? line_start(last + 1) : @editor.buffer.rope.bytesize
        [line_start(first_row)...ending]
      elsif @mode == :visual_block
        columns = block_columns
        (row_at(first)..row_at(last)).map do |row|
          beginning = offset_at(row, columns[0], insertion: true)
          ending = offset_at(row, columns[1] + 1, insertion: true)
          beginning...ending
        end
      else
        [first...next_offset(last)]
      end
    end

    def update_visual
      ranges = visual_ranges
      selections = ranges.each_with_index.map { |range, i| Selection.new(i, range.begin, range.end, nil) }
      @editor.set_selections(selections)
    end

    def cell_width(character, column)
      return @editor.tab_size - column % @editor.tab_size if character == "\t"
      defined?(Terminal::Grid) ? [Terminal::Grid.width(character), 1].max : 1
    end

    def block_columns
      columns = [@visual_anchor, @visual_head].map { |offset| column_at(offset) }
      endings = [@visual_anchor, @visual_head].zip(columns).map { |offset, column| column + cell_width(character_at(offset), column) - 1 }
      [columns.min, endings.max]
    end

    # A rectangular edge can bisect a tab or a double-width glyph. Keep the
    # unselected cells as spaces while operating on the selected cell span.
    def block_slices
      left, right = block_columns
      right += 1
      first, last = [row_at(@visual_anchor), row_at(@visual_head)].minmax
      (first..last).map do |row|
        offset, column, begin_offset, end_offset = line_start(row), 0, nil, nil
        selected, prefix, suffix, cells = +"", +"", +"", 0
        @editor.buffer.line(row).each_grapheme_cluster do |character|
          width = cell_width(character, column)
          if column < right && column + width > left
            begin_offset ||= offset
            end_offset = offset + character.bytesize
            overlap = [column + width, right].min - [column, left].max
            cells += overlap
            selected << (overlap == width ? character : " " * overlap)
            prefix = " " * (left - column) if column < left
            suffix = " " * (column + width - right) if column + width > right
          end
          offset += character.bytesize
          column += width
        end
        {range: (begin_offset || offset)...(end_offset || offset), text: selected, prefix: prefix, suffix: suffix, row: row, width: cells}
      end
    end

    # Split by screen cells, not bytes; only a tab intersected by the insertion
    # edge is expanded. Vim pads before a bisected wide glyph without deleting it.
    def split_at_column(line, target, replace_wide: false, pad_wide: true)
      offset, column = 0, 0
      line.each_grapheme_cluster do |character|
        break if column >= target
        width = cell_width(character, column)
        if column + width > target
          padding = character == "\t" || pad_wide ? target - column : 0
          prefix = line.byteslice(0, offset) + " " * padding
          suffix = if character == "\t" || replace_wide
            " " * (column + width - target) + line.byteslice(offset + character.bytesize..)
          else
            line.byteslice(offset..)
          end
          return [prefix, suffix]
        end
        offset += character.bytesize
        column += width
      end
      [line.byteslice(0, offset) + " " * [target - column, 0].max, line.byteslice(offset..)]
    end
  end
end

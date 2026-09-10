# frozen_string_literal: true

require "denebola"
require "zaniah"

module Canopus
  module Terminal
    class Grid
      attr_reader :columns, :rows, :cells, :scrollback, :cursor_x, :cursor_y, :scroll_top, :scroll_bottom
      attr_accessor :foreground, :background, :attributes, :hyperlink, :autowrap, :insert_mode, :origin_mode, :cursor_visible

      def initialize(columns: 80, rows: 24, scrollback: 10_000)
        validate_dimensions(columns, rows)
        @columns, @rows = columns, rows
        @scrollback = Scrollback.new(scrollback)
        reset
      end

      def reset
        @foreground = @background = @hyperlink = nil
        @attributes = {}.freeze
        @autowrap = @cursor_visible = true
        @insert_mode = @origin_mode = false
        @cursor_x = @cursor_y = 0
        @wrap_pending = false
        @alternate = nil
        @scroll_top, @scroll_bottom = 0, rows - 1
        @cells = Array.new(rows) { blank_row }
        @tabs = (8...columns).step(8).to_a
        save_cursor
      end

      def [](row, column = nil) = column ? cells[row]&.[](column) : cells[row]
      def alternate? = !@alternate.nil?
      def lines = cells.map { |row| row.map(&:text).join.rstrip }
      def text = lines.join("\n")

      def put(char)
        width = self.class.width(char)
        previous_x = @wrap_pending ? cursor_x : cursor_x - 1
        if previous_x >= 0 && !char.ascii_only?
          previous_x -= 1 if cells[cursor_y][previous_x].width.zero? && previous_x.positive?
          previous = cells[cursor_y][previous_x]
          joined = previous.text + char
          if joined.match?(/\A\X\z/)
            width = [self.class.width(joined), columns].min
            if previous_x + width > columns && autowrap
              cells[cursor_y][previous_x] = blank
              carriage_return
              linefeed
              return put(joined)
            end
            width = [width, columns - previous_x].min
            clear_wide(cursor_y, previous_x + 1) if width == 2 && previous.width < 2
            cells[cursor_y][previous_x + 1] = blank if width < previous.width
            previous.text, previous.width = joined, width
            cells[cursor_y][previous_x + 1] = previous.dup.tap { |cell| cell.text = ""; cell.width = 0 } if width == 2
            @cursor_x = [previous_x + width, columns - 1].min
            @wrap_pending = previous_x + width >= columns && autowrap
            return
          end
        end
        return if width.zero?
        width = 1 if width > columns
        if @wrap_pending || (width == 2 && cursor_x == columns - 1)
          if autowrap
            @cursor_x = 0
            linefeed
          elsif width == 2
            return
          end
          @wrap_pending = false
        end
        insert_characters(width) if insert_mode
        clear_wide(cursor_y, cursor_x)
        clear_wide(cursor_y, cursor_x + 1) if width == 2
        cells[cursor_y][cursor_x] = Cell.new(text: char, width: width, foreground: foreground,
          background: background, attributes: attributes, hyperlink: hyperlink)
        cells[cursor_y][cursor_x + 1] = Cell.new(text: "", width: 0, foreground: foreground,
          background: background, attributes: attributes, hyperlink: hyperlink) if width == 2
        if cursor_x + width >= columns
          @cursor_x = columns - 1
          @wrap_pending = autowrap
        else
          @cursor_x += width
        end
      end

      def self.width(char)
        return 1 if char.bytesize == 1 && char.ord.between?(32, 126)
        Zaniah::Unicode.width(char)
      end

      def move(x: cursor_x, y: cursor_y, relative: false)
        if relative
          x += cursor_x
          y += cursor_y
        end
        top, bottom = origin_mode ? [scroll_top, scroll_bottom] : [0, rows - 1]
        @cursor_x = x.clamp(0, columns - 1)
        @cursor_y = y.clamp(top, bottom)
        @wrap_pending = false
      end

      def position(row, column)
        move(x: column - 1, y: row - 1 + (origin_mode ? scroll_top : 0))
      end

      def carriage_return = move(x: 0)
      def backspace = move(x: cursor_x - 1)

      def linefeed
        @wrap_pending = false
        if cursor_y == scroll_bottom
          scroll_up
        elsif cursor_y < rows - 1
          @cursor_y += 1
        end
      end

      def reverse_index
        @wrap_pending = false
        cursor_y == scroll_top ? scroll_down : @cursor_y = [0, cursor_y - 1].max
      end

      def tab(count = 1, backward: false)
        count.times do
          stop = backward ? @tabs.reverse.find { |column| column < cursor_x } : @tabs.find { |column| column > cursor_x }
          move(x: stop || (backward ? 0 : columns - 1))
        end
      end

      def tab_set = @tabs = (@tabs + [cursor_x]).uniq.sort
      def tab_clear(all: false) = all ? @tabs.clear : @tabs.delete(cursor_x)

      def margins(top = 1, bottom = rows)
        return unless top >= 1 && top < bottom && bottom <= rows
        @scroll_top, @scroll_bottom = top - 1, bottom - 1
        position(1, 1)
      end

      def scroll_up(count = 1)
        [count, scroll_bottom - scroll_top + 1].min.times do
          removed = cells.delete_at(scroll_top)
          scrollback.push(removed) if scroll_top.zero? && scroll_bottom == rows - 1 && !alternate?
          cells.insert(scroll_bottom, blank_row)
        end
      end

      def scroll_down(count = 1)
        [count, scroll_bottom - scroll_top + 1].min.times do
          cells.delete_at(scroll_bottom)
          cells.insert(scroll_top, blank_row)
        end
      end

      def erase_display(mode = 0)
        case mode
        when 0
          erase_line(0)
          ((cursor_y + 1)...rows).each { |row| cells[row] = blank_row }
        when 1
          (0...cursor_y).each { |row| cells[row] = blank_row }
          erase_line(1)
        when 2 then @cells = Array.new(rows) { blank_row }
        when 3 then scrollback.clear
        end
      end

      def erase_line(mode = 0)
        first, last = case mode
        when 0 then [cursor_x, columns - 1]
        when 1 then [0, cursor_x]
        when 2 then [0, columns - 1]
        else return
        end
        (first..last).each { |column| clear_wide(cursor_y, column); cells[cursor_y][column] = blank }
      end

      def erase_characters(count = 1)
        (cursor_x...[cursor_x + count, columns].min).each { |column| clear_wide(cursor_y, column); cells[cursor_y][column] = blank }
      end

      def insert_characters(count = 1)
        clear_wide(cursor_y, cursor_x) if cells[cursor_y][cursor_x].width.zero?
        cells[cursor_y].insert(cursor_x, *Array.new([count, columns - cursor_x].min) { blank })
        cells[cursor_y] = cells[cursor_y].first(columns)
        normalize_row(cursor_y)
      end

      def delete_characters(count = 1)
        clear_wide(cursor_y, cursor_x)
        count = [count, columns - cursor_x].min
        cells[cursor_y].slice!(cursor_x, count)
        cells[cursor_y].concat(Array.new(count) { blank })
        normalize_row(cursor_y)
      end

      def insert_lines(count = 1)
        return unless cursor_y.between?(scroll_top, scroll_bottom)
        [count, scroll_bottom - cursor_y + 1].min.times { cells.delete_at(scroll_bottom); cells.insert(cursor_y, blank_row) }
      end

      def delete_lines(count = 1)
        return unless cursor_y.between?(scroll_top, scroll_bottom)
        [count, scroll_bottom - cursor_y + 1].min.times { cells.delete_at(cursor_y); cells.insert(scroll_bottom, blank_row) }
      end

      def save_cursor
        @saved = [cursor_x, cursor_y, foreground, background, attributes, hyperlink, origin_mode, @wrap_pending]
      end

      def restore_cursor
        return unless @saved
        @cursor_x, @cursor_y, @foreground, @background, @attributes, @hyperlink, @origin_mode, @wrap_pending = @saved
        @cursor_x = cursor_x.clamp(0, columns - 1)
        @cursor_y = cursor_y.clamp(0, rows - 1)
      end

      def alternate(enable, save: true)
        if enable && !alternate?
          save_cursor if save
          @alternate = cells
          @cells = Array.new(rows) { blank_row }
          @cursor_x = @cursor_y = 0
          @scroll_top, @scroll_bottom = 0, rows - 1
          @wrap_pending = false
        elsif !enable && alternate?
          @cells, @alternate = @alternate, nil
          @scroll_top, @scroll_bottom = 0, rows - 1
          restore_cursor if save
        end
      end

      def resize(columns:, rows:)
        validate_dimensions(columns, rows)
        previous_columns = @columns
        @columns, @rows = columns, rows
        [cells, @alternate].compact.each do |screen|
          while screen.length > rows
            removed = screen.shift
            scrollback.push(removed) unless alternate?
            @cursor_y -= 1 if screen.equal?(cells)
          end
          screen << blank_row while screen.length < rows
          screen.each do |row|
            row.slice!(columns, row.length) if row.length > columns
            row << blank while row.length < columns
          end
        end
        cells.each_index { |index| normalize_row(index) }
        @tabs = (@tabs.select { |column| column < columns } + (previous_columns...columns).select { |column| column.positive? && (column % 8).zero? }).uniq.sort
        @scroll_top, @scroll_bottom = 0, rows - 1
        move
      end

      # Coordinates are [column, row]; finish is exclusive, including scrollback
      # when history: true. This is suitable for selection/copy without a renderer.
      def selection(start, finish, history: false)
        source = history ? scrollback.to_a + cells : cells
        start, finish = finish, start if ([start[1], start[0]] <=> [finish[1], finish[0]]) == 1
        (start[1]..finish[1]).map do |row|
          next "" unless source[row]
          first = row == start[1] ? start[0] : 0
          last = row == finish[1] ? finish[0] : columns
          source[row][first...last].to_a.map(&:text).join.rstrip
        end.join("\n")
      end

      def links(row)
        line = cells.fetch(row).map(&:text).join
        explicit = []
        cells[row].each_with_index do |cell, column|
          next unless cell.hyperlink
          if explicit.last && explicit.last[:url] == cell.hyperlink && explicit.last[:end_column] == column
            explicit.last[:end_column] = column + 1
          else
            explicit << {url: cell.hyperlink, column: column, end_column: column + 1}
          end
        end
        line.to_enum(:scan, %r{https?://[^\s<>"']+}).each do
          found = Regexp.last_match
          column = line[0...found.begin(0)].each_char.sum { |char| self.class.width(char) }
          explicit << {url: found[0], column: column, end_column: column + found[0].length}
        end
        explicit.uniq
      end

      def file_paths(row, cwd: Dir.pwd)
        line = cells.fetch(row).map(&:text).join
        line.scan(%r{(?:\A|[\s("'])([^\s:"'()]+):(\d+)(?::(\d+))?}).filter_map do |name, number, column|
          absolute = File.expand_path(name, cwd)
          {path: absolute, line: number.to_i, column: column ? column.to_i : 1} if File.file?(absolute)
        end
      end

      private

      def validate_dimensions(columns, rows)
        raise ArgumentError, "terminal dimensions must be positive integers" unless columns.is_a?(Integer) && rows.is_a?(Integer) && columns.positive? && rows.positive?
      end

      def blank = Cell.new(text: " ", width: 1, foreground: foreground, background: background, attributes: {}.freeze)
      def blank_row = Array.new(columns) { blank }

      def clear_wide(row, column)
        return unless column.between?(0, columns - 1)
        cell = cells[row][column]
        cells[row][column - 1] = blank if cell.width.zero? && column.positive?
        cells[row][column + 1] = blank if cell.width == 2 && column + 1 < columns
      end

      def normalize_row(row)
        cells[row].each_with_index do |cell, column|
          cells[row][column] = blank if (cell.width == 2 && (column == columns - 1 || cells[row][column + 1].width != 0)) ||
            (cell.width.zero? && (column.zero? || cells[row][column - 1].width != 2))
        end
      end
    end
  end
end

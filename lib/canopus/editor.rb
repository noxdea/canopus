# frozen_string_literal: true

require_relative "selection"

module Canopus
  class Editor
    PAIRS = {"(" => ")", "[" => "]", "{" => "}", '"' => '"', "'" => "'"}.freeze
    attr_reader :buffer, :display_map, :selections, :scroll_x, :scroll_y
    attr_accessor :tab_size, :use_tabs, :auto_pairs, :composition, :viewport_rows, :relative_line_numbers

    def initialize(buffer = Buffer.new, wrap_width: nil, tab_size: 4)
      @buffer, @next_selection = buffer, 0
      @tab_size, @use_tabs, @auto_pairs = tab_size, false, true
      @display_map = DisplayMap.new(buffer, wrap_width: wrap_width, tab_size: tab_size)
      @scroll_x, @scroll_y, @viewport_rows = 0, 0, 30
      select(0)
      @subscription = buffer.on_edit do |patch|
        @display_map.block_map.blocks.values.each { |block| @display_map.remove_block(block.id) if block.kind == :git_diff }
        @selections = @selections.map { |s| Selection.new(s.id, patch.map_offset(s.anchor), patch.map_offset(s.head), s.goal) }.freeze
      end
    end
    def dispose
      @subscription.detach
      @display_map.dispose
      @language_document&.dispose
      clear_snippet
    end
    def language_document = @language_document ||= Language::Document.new(@buffer)
    def language=(definition)
      @language_document&.dispose
      @language_document = Language::Document.new(@buffer, definition: definition)
    end
    def primary = @selections.last
    def select(first, last = first, add: false)
      @buffer.rope.point_at(first)
      @buffer.rope.point_at(last)
      selection = Selection.new(@next_selection, first, last, nil)
      @next_selection += 1
      set_selections(add ? [*@selections, selection] : [selection])
      self
    end

    def set_selections(selections)
      merged = []
      selections.sort_by(&:start).each do |selection|
        if merged.last && (selection.start < merged.last.end || (selection.start == merged.last.end && !snippet_active?))
          previous = merged.pop
          merged << Selection.new(previous.id, previous.start, [previous.end, selection.end].max, selection.goal)
        else
          merged << selection
        end
      end
      @selections = merged.freeze
      @buffer.selections = @selections
    end

    def insert_text(text, auto_indent: true)
      raise ArgumentError, "text must be UTF-8" unless text.is_a?(String) && text.valid_encoding?
      texts = @selections.map do |selection|
        if text == "\n" && auto_indent
          indent = language_document.indent_for(selection.start, tab_size: @tab_size, use_tabs: @use_tabs)
          if language_document.definition == Language::PLAIN
            before = @buffer.line(@buffer.rope.point_at(selection.start).row)[0, @buffer.rope.point_at(selection.start).column]
            indent += @use_tabs ? "\t" : " " * @tab_size if before.rstrip.end_with?("{", "[", "(")
          end
          @buffer.line_ending + indent
        elsif @auto_pairs && PAIRS.key?(text)
          text + @buffer.rope.byteslice(selection.range).to_s + PAIRS[text]
        else
          text
        end
      end
      paired = @auto_pairs && PAIRS.key?(text)
      replace_selections(texts, kind: :typing, group: true, cursor_back: paired ? PAIRS[text].bytesize : 0)
      reveal_cursor
    end

    def replace_selections(texts, kind: :edit, group: false, cursor_back: 0, before_selections: @selections)
      texts = Array.new(@selections.length, texts) if texts.is_a?(String)
      raise ArgumentError, "one text per selection required" unless texts.length == @selections.length
      changes = @selections.zip(texts).map { |selection, text| [selection.range, text] }
      @buffer.selections = before_selections
      delta = 0
      after = @selections.zip(texts).map do |selection, text|
        ending = selection.start + delta + text.bytesize - cursor_back
        delta += text.bytesize - (selection.end - selection.start)
        Selection.new(selection.id, ending, ending, nil)
      end
      @buffer.edit(changes, kind: kind, selections: after, before_selections: before_selections, group: group)
      set_selections(after)
    end

    def delete_backward
      before = @selections
      set_selections(@selections.map do |s|
        s.empty? ? Selection.new(s.id, horizontal(s.head, -1), s.head, nil) : s
      end)
      replace_selections("", kind: :backspace, group: true, before_selections: before)
      reveal_cursor
    end
    def delete_forward
      before = @selections
      set_selections(@selections.map do |s|
        s.empty? ? Selection.new(s.id, s.head, horizontal(s.head, 1), nil) : s
      end)
      replace_selections("", kind: :delete, group: true, before_selections: before)
    end
    def undo
      clear_snippet
      return false unless @buffer.undo
      set_selections(@buffer.selections)
      reveal_cursor
      true
    end
    def redo
      clear_snippet
      return false unless @buffer.redo
      set_selections(@buffer.selections)
      reveal_cursor
      true
    end

    def move(direction, extend: false, count: 1)
      next_selections = @selections.map do |selection|
        position, goal = selection.head, selection.goal
        if !extend && !selection.empty? && [:left, :right].include?(direction)
          position = direction == :left ? selection.start : selection.end
        else
          count.times do
            point = @display_map.to_display(position)
            row = @display_map.row(point.row)
            case direction
            when :left, :right
              position = horizontal(position, direction == :left ? -1 : 1)
              goal = nil
            when :up, :down, :page_up, :page_down
              goal ||= point.column
              amount = [:page_up, :page_down].include?(direction) ? @viewport_rows : 1
              amount *= -1 if [:up, :page_up].include?(direction)
              target_row = (point.row + amount).clamp(0, @display_map.row_count - 1)
              position = @display_map.to_buffer(DisplayPoint.new(target_row, goal))
            when :line_start
              position = @buffer.rope.respond_to?(:lazy?) ? @buffer.rope.line_start(point.row) : @display_map.to_buffer(DisplayPoint.new(point.row, 0)); goal = nil
            when :line_end
              position = @buffer.rope.respond_to?(:lazy?) ? @buffer.rope.line_end(point.row) : @display_map.to_buffer(DisplayPoint.new(point.row, row.text.length)); goal = nil
            when :file_start then position = 0; goal = nil
            when :file_end then position = @buffer.rope.bytesize; goal = nil
            when :word_left, :word_right
              position = word(position, direction == :word_left ? -1 : 1); goal = nil
            when :paragraph_up, :paragraph_down
              target = point.row
              step = direction == :paragraph_up ? -1 : 1
              loop do
                target += step
                break if target <= 0 || target >= @display_map.row_count - 1 || @display_map.row(target).text.strip.empty?
              end
              position = @display_map.to_buffer(DisplayPoint.new(target.clamp(0, @display_map.row_count - 1), 0))
            else raise ArgumentError, "unknown movement #{direction}"
            end
          end
        end
        Selection.new(selection.id, extend ? selection.anchor : position, position, goal)
      end
      set_selections(next_selections)
      reveal_cursor
    end

    def select_all = select(0, @buffer.rope.bytesize)
    def select_next_occurrence(all: false)
      needle = @buffer.rope.byteslice(primary.range).to_s
      if needle.empty?
        left, right = word(primary.head, -1), word(primary.head, 1)
        select(left, right)
        needle = @buffer.rope.byteslice(primary.range).to_s
      end
      return if needle.empty?
      text = @buffer.text.b
      cursor, matches = 0, []
      while (found = text.index(needle.b, cursor))
        matches << (found...(found + needle.bytesize))
        cursor = found + needle.bytesize
      end
      matches.reject! { |range| @selections.any? { |s| s.start == range.begin && s.end == range.end } }
      matches = [(matches.find { |range| range.begin >= primary.end } || matches.first)].compact unless all
      matches.each { |range| select(range.begin, range.end, add: true) }
    end

    def rectangle(first, last)
      selections = (first.row..last.row).map do |row|
        anchor = @display_map.to_buffer(DisplayPoint.new(row, first.column))
        head = @display_map.to_buffer(DisplayPoint.new(row, last.column))
        @next_selection += 1
        Selection.new(@next_selection, anchor, head, nil)
      end
      set_selections(selections)
    end
    def indent(outdent: false)
      change_lines(:indent) do |line|
        outdent ? line.sub(/\A(?:\t| {1,#{@tab_size}})/, "") : (@use_tabs ? "\t" : " " * @tab_size) + line
      end
    end
    def toggle_comment(prefix: "#", suffix: nil)
      return if prefix.empty?
      suffix ||= case prefix
      when "/*" then "*/"
      when "<!--" then "-->"
      end
      rows = selected_rows
      uncomment = rows.all? do |row|
        line = @buffer.line(row).strip
        line.start_with?(prefix) && (!suffix || line.end_with?(suffix))
      end
      if suffix && !uncomment && rows.any? { |row| @buffer.line(row).include?(suffix) }
        raise Error, "cannot wrap a line containing the closing comment delimiter #{suffix}"
      end
      change_lines(:comment) do |line|
        if uncomment
          value = line.sub(/\A([ \t]*)#{Regexp.escape(prefix)} ?/, '\1')
          suffix ? value.sub(/ ?#{Regexp.escape(suffix)}([ \t]*)\z/, '\1') : value
        elsif suffix
          line.sub(/\A([ \t]*)(.*?)([ \t]*)\z/) { "#{Regexp.last_match(1)}#{prefix} #{Regexp.last_match(2)} #{suffix}#{Regexp.last_match(3)}" }
        else
          line.sub(/\A([ \t]*)/, "\\1#{prefix} ")
        end
      end
    end
    def duplicate_lines
      rows = selected_rows
      changes = rows.map do |row|
        ending = row + 1 < @buffer.line_count ? @buffer.rope.line_start(row + 1) : @buffer.rope.bytesize
        value = @buffer.line(row) + @buffer.line_ending
        value = @buffer.line_ending + @buffer.line(row) if row == @buffer.line_count - 1
        [ending...ending, value]
      end
      edit(changes, kind: :duplicate)
    end
    def move_lines(direction)
      raise ArgumentError, "line direction must be up or down" unless %i[up down].include?(direction)
      first, last = selected_rows.minmax
      step = direction == :up ? -1 : 1
      return if step.negative? ? first.zero? : last + 1 >= @buffer.line_count
      rope = @buffer.rope
      from, to = step.negative? ? [first - 1, last] : [first, last + 1]
      rows, endings = [], []
      (from..to).each do |row|
        text = @buffer.line(row)
        ending = row + 1 < rope.line_count ? rope.line_start(row + 1) : rope.bytesize
        body_end = rope.line_start(row) + text.bytesize
        rows << text
        endings << rope.byteslice(body_end, ending - body_end).to_s
      end
      # Move contents while preserving the separators at each row, including
      # mixed CRLF/LF/Unicode endings and an unterminated final row.
      rows.rotate!(-step)
      start = rope.line_start(from)
      previous_end = from.positive? ? rope.line_start(from - 1) + @buffer.line(from - 1).bytesize : 0
      trailing_cr = from.positive? && rope.byteslice(previous_end, start - previous_end).to_s == "\r"
      replacement = +""
      rows.each_with_index do |text, index|
        ending = endings[index]
        # An empty moved row can put CR beside LF. Keep two logical breaks by
        # expanding that LF to CRLF instead of silently merging the rows.
        replacement << text
        replacement << "\r" if text.empty? && trailing_cr && ending == "\n"
        replacement << ending
        trailing_cr = ending == "\r"
      end
      finish = to + 1 < rope.line_count ? rope.line_start(to + 1) : rope.bytesize
      changes = [[start...finish, replacement]]
      after = rope.apply_edits(changes)
      move = lambda do |offset|
        row = rope.point_at(offset).row
        target = row + step
        next after.bytesize if target >= after.line_count
        column = row > last ? 0 : [offset - rope.line_start(row), after.line(target).bytesize].min
        after.line_start(target) + column
      end
      selections = @selections.map { |selection| Selection.new(selection.id, move.call(selection.anchor), move.call(selection.head), selection.goal) }
      @buffer.edit(changes, kind: :move_lines, selections: selections, before_selections: @selections)
      set_selections(selections)
    end
    def self.search_pattern(pattern, case_sensitive: true, whole_word: false)
      source = pattern.is_a?(Regexp) ? pattern.source : Regexp.escape(pattern)
      source = "\\b(?:#{source})\\b" if whole_word
      flags = (pattern.is_a?(Regexp) ? pattern.options : 0) | (case_sensitive ? 0 : Regexp::IGNORECASE)
      Regexp.new(source, flags, timeout: pattern.is_a?(Regexp) && pattern.timeout || 0.25)
    end
    def search(pattern, case_sensitive: true, whole_word: false, range: nil)
      regex = self.class.search_pattern(pattern, case_sensitive: case_sensitive, whole_word: whole_word)
      base = range ? range.begin : 0
      source = range ? @buffer.rope.byteslice(range).to_s : @buffer.text
      matches = []
      Canopus.with_regexp_timeout(regex) do
        source.to_enum(:scan, regex).each do
          found = Regexp.last_match
          matches << ((base + found.bytebegin(0))...(base + found.byteend(0)))
        end
      end
      matches
    end
    def replacement_edits(pattern, replacement, case_sensitive: true, whole_word: false, range: nil)
      regex = self.class.search_pattern(pattern, case_sensitive: case_sensitive, whole_word: whole_word)
      source = range ? @buffer.rope.byteslice(range).to_s : @buffer.text
      base = range ? range.begin : 0
      Canopus.with_regexp_timeout(regex) do
        source.to_enum(:scan, regex).map do
          found = Regexp.last_match
          value = replacement.gsub(/\\(?:([0-9&`'+\\])|k<([^>]*)(>)?)/) do
            escape, name, closing = Regexp.last_match.captures
            if name
              raise RuntimeError, "invalid group name reference format" unless closing
              found[name].to_s
            else
              case escape
              when "0", "&" then found[0]
              when "`" then found.pre_match
              when "'" then found.post_match
              when "+" then found.captures.reverse.find(&:itself).to_s
              when "\\" then "\\"
              else found.names.empty? ? found[escape.to_i].to_s : ""
              end
            end
          end
          [(base + found.bytebegin(0))...(base + found.byteend(0)), value]
        end
      end
    end
    def replace_all(pattern, replacement, **options)
      changes = replacement_edits(pattern, replacement, **options)
      edit(changes, kind: :replace)
      changes.length
    end

    # Apply externally computed edits with the same selection history as typing.
    def edit(changes, kind: :edit)
      return if changes.empty?
      after = @buffer.rope.apply_edits(changes)
      patch = Patch.new(@buffer.rope, after, changes)
      selections = @selections.map { |s| Selection.new(s.id, patch.map_offset(s.anchor, bias: :left), patch.map_offset(s.head), nil) }
      @buffer.edit(changes, kind: kind, selections: selections, before_selections: @selections)
      set_selections(selections)
    end

    def scroll(dx: 0, dy: 0)
      @scroll_x = [@scroll_x + dx, 0].max
      @scroll_y = (@scroll_y + dy).clamp(0, [@display_map.row_count - @viewport_rows, 0].max)
    end
    def reveal_cursor
      row = @display_map.to_display(primary.head).row
      @scroll_y = row if row < @scroll_y
      @scroll_y = row - @viewport_rows + 1 if row >= @scroll_y + @viewport_rows
      @scroll_y = [@scroll_y, 0].max
    end

    private
    def horizontal(offset, direction)
      if @buffer.rope.respond_to?(:lazy?)
        rope = @buffer.rope
        point = rope.point_at(offset)
        start, ending = rope.line_start(point.row), rope.line_end(point.row)
        if direction.negative?
          return point.row.zero? ? 0 : rope.line_end(point.row - 1) if offset == start
          size = 8192
          loop do
            text, local = rope.line_window(point.row, from: [offset - start - size, 0].max, max_bytes: size + 4)
            clusters = text.byteslice(0, offset - start - local).grapheme_clusters
            return offset - (clusters.last&.bytesize || 0) if local.zero? || clusters.length > 1
            size *= 2
          end
        end
        return point.row + 1 < rope.line_count ? rope.line_start(point.row + 1) : ending if offset >= ending
        size = 8192
        loop do
          text, = rope.line_window(point.row, from: offset - start, max_bytes: size)
          following = text.each_grapheme_cluster.first
          return offset + following.bytesize if following.bytesize < text.bytesize || offset + text.bytesize == ending
          size *= 2
        end
      end
      point = @display_map.to_display(offset)
      line = @display_map.row(point.row).text
      if direction.negative?
        return @display_map.to_buffer(DisplayPoint.new(point.row - 1, @display_map.row(point.row - 1).text.length)) if point.column.zero? && point.row.positive?
        previous = line[0...point.column].grapheme_clusters.last
        column = point.column - (previous&.length || 0)
      else
        return @display_map.to_buffer(DisplayPoint.new(point.row + 1, 0)) if point.column >= line.length && point.row + 1 < @display_map.row_count
        following = line[point.column..].grapheme_clusters.first
        column = point.column + (following&.length || 0)
      end
      @display_map.to_buffer(DisplayPoint.new(point.row, column), bias: direction.negative? ? :left : :right)
    end
    def word(offset, direction)
      return lazy_word(offset, direction) if @buffer.rope.respond_to?(:lazy?)
      point = @buffer.rope.point_at(offset)
      line = @buffer.line(point.row)
      if direction.negative?
        prefix = line[0...point.column]
        match = prefix[/[\p{Alnum}_]+[^\p{Alnum}_]*\z|[^\p{Alnum}_]+\z/]
        match ? offset - match.bytesize : horizontal(offset, -1)
      else
        suffix = line[point.column..]
        match = suffix[/\A(?:[\p{Alnum}_]+[^\p{Alnum}_]*|[^\p{Alnum}_]+)/]
        match ? offset + match.bytesize : horizontal(offset, 1)
      end
    end
    def lazy_word(offset, direction)
      rope = @buffer.rope
      point = rope.point_at(offset)
      start, ending = rope.line_start(point.row), rope.line_end(point.row)
      return horizontal(offset, direction) if direction.negative? ? offset == start : offset == ending
      phase = nil
      loop do
        text, local = rope.line_window(point.row, from: direction.negative? ? [offset - start - 8192, 0].max : offset - start)
        chars = direction.negative? ? text.byteslice(0, offset - start - local).each_char.to_a.reverse_each : text.each_char
        chars.each do |char|
          word = /[\p{Alnum}_]/.match?(char)
          current = direction.negative? ? !word : word
          return offset if phase == false && current
          phase = current if phase.nil? || !current
          offset += direction * char.bytesize
        end
        return offset if offset == start || offset == ending
      end
    end
    def selected_rows
      @selections.flat_map do |s|
        first, last = @buffer.rope.point_at(s.start).row, @buffer.rope.point_at(s.end).row
        last -= 1 if !s.empty? && last > first && s.end == @buffer.rope.line_start(last)
        (first..last).to_a
      end.uniq.sort
    end
    def change_lines(kind)
      changes = selected_rows.map do |row|
        start = @buffer.rope.line_start(row)
        value = @buffer.line(row)
        [start...(start + value.bytesize), yield(value)]
      end
      edit(changes, kind: kind)
    end
  end
end

require_relative "editor/snippet_expandable"
Canopus::Editor.include Canopus::Editor::SnippetExpandable

# frozen_string_literal: true

module Canopus
  module Vim::OperatorCapable
    private

    CONTROL_KEYS = {"esc" => "\e", "enter" => "\r", "tab" => "\t", "backspace" => "\b", "ctrl-v" => "\x16", "ctrl-r" => "\x12"}.freeze
    def register_keys(text) = text.grapheme_clusters.map { |key| CONTROL_KEYS.key(key) || key }
    def save_macro_register(name) = @registers[name] = [@macros[name].map { |key| CONTROL_KEYS.fetch(key, key) }.join, false]
    def register_entry(name)
      case name
      when "%" then [@editor.buffer.path.to_s, false]
      when "/" then [@search.to_s, false]
      when "_" then ["", false]
      else @registers[name&.downcase]
      end
    end

    def store_register(text, type, operator, width: nil)
      return if @register == "_"
      entry = width ? [text, type, width] : [text, type]
      if @register.match?(/\A[A-Z]\z/)
        name = @register.downcase
        old = @registers[name]
        entry = [(old ? old.first : "") + text, old && old[1] == true ? true : type]
        @registers[name] = entry
      elsif @register != '"'
        @registers[@register] = entry
      end
      if operator == "y"
        @registers["0"] = entry if @register == '"'
      elsif type == true || text.include?("\n")
        9.downto(2) { |index| @registers[index.to_s] = @registers[(index - 1).to_s] if @registers[(index - 1).to_s] }
        @registers["1"] = entry
      else
        @registers["-"] = entry
      end
      @registers['"'] = entry
    end

    def normalized_line_range(range)
      first, last = row_at(range.begin), row_at(range.end)
      last -= 1 if range.end > range.begin && last > first && range.end == line_start(last)
      ending = last + 1 < @editor.buffer.line_count ? line_start(last + 1) : @editor.buffer.rope.bytesize
      line_start(first)...ending
    end

    def operate(operator, range, linewise: false, destination: nil, shift: 1)
      return unless operator && range
      original = cursor_position
      before = [Selection.new(@editor.primary.id, original, original, nil)]
      range = normalized_line_range(range) if linewise
      text = @editor.buffer.rope.byteslice(range).to_s
      if %w[d c y].include?(operator)
        registered = linewise && !text.end_with?("\n") ? text + @editor.buffer.line_ending : text
        store_register(registered, linewise, operator)
      end
      start_group if operator == "c"
      selection = range
      if operator == "d" && linewise && range.end == @editor.buffer.rope.bytesize && range.begin.positive? && !source.end_with?("\n")
        selection = previous_offset(range.begin)...range.end
      end
      @mode = :normal
      @editor.select(selection.begin, selection.end)
      case operator
      when "d"
        @editor.replace_selections("", kind: :vim, before_selections: before) unless selection.begin == selection.end
        @editor.select(first_nonblank([row_at([selection.begin, @editor.buffer.rope.bytesize].min), last_row].min)) if linewise
      when "c"
        indentation = linewise ? text[/\A[ \t]*/] : ""
        replacement = indentation + (linewise && (range.end < @editor.buffer.rope.bytesize || text.end_with?("\n")) ? @editor.buffer.line_ending : "")
        @editor.replace_selections(replacement, kind: :vim, before_selections: before)
        @editor.select(range.begin + indentation.bytesize)
      when "y" then @editor.select(linewise ? original : range.begin)
      when ">", "<"
        indent_rows(range, outdent: operator == "<", before: before, amount: shift)
        @editor.select(first_nonblank(row_at([range.begin, @editor.buffer.rope.bytesize].min)))
      when "=" then reindent(range, before: before)
      when "gu", "gU", "g~"
        transformed = text.public_send({"gu" => :downcase, "gU" => :upcase, "g~" => :swapcase}.fetch(operator))
        @editor.replace_selections(transformed, kind: :vim, before_selections: before)
        @editor.select(range.begin)
      end
      @operator, @register = nil, '"'
      if operator == "c"
        @change_keys, @insert_count, @replace_stack = @command.dup, 1, []
        @insert_prefix_length = @change_keys.length
        @mode = :insert
        @command.clear
      else
        @editor.select(normal_offset(destination || @editor.primary.head))
        operator == "y" ? @command.clear : finish_change
      end
    end

    def operate_visual(operator, count: 1)
      @last_visual = [@mode, @visual_anchor, @visual_head]
      @command = @visual_keys.dup if @visual_keys
      ranges = visual_ranges
      return operate(operator, ranges.first, linewise: @mode == :visual_line, destination: operator == "y" ? ranges.first.begin : nil, shift: count) unless @mode == :visual_block
      first = ranges.first.begin
      width = block_columns[1] - block_columns[0] + 1
      slices = block_slices
      ranges, texts = slices.map { |slice| slice[:range] }, slices.map { |slice| slice[:text] }
      store_register(texts.join("\n"), :block, operator, width: width) if %w[d c y].include?(operator)
      start_group if operator == "c"
      @editor.set_selections(ranges.each_with_index.map { |range, index| Selection.new(index, range.begin, range.end, nil) })
      case operator
      when "d", "c"
        @editor.replace_selections(slices.map { |slice| slice[:prefix] + slice[:suffix] }, kind: :vim)
        delta = 0
        cursors = slices.each_with_index.map do |slice, index|
          range = slice[:range]
          offset = range.begin + delta + slice[:prefix].bytesize
          delta += slice[:prefix].bytesize + slice[:suffix].bytesize - (range.end - range.begin)
          Selection.new(index, offset, offset, nil)
        end
        @editor.set_selections(cursors)
        first = cursors.first.head
      when "gu", "gU", "g~"
        method = {"gu" => :downcase, "gU" => :upcase, "g~" => :swapcase}.fetch(operator)
        @editor.replace_selections(slices.map { |slice| slice[:prefix] + slice[:text].public_send(method) + slice[:suffix] }, kind: :vim)
      when ">", "<"
        unit = @editor.use_tabs ? "\t" * count : " " * (@editor.tab_size * count)
        edits = slices.map do |slice|
          row = slice[:row]
          line = @editor.buffer.line(row)
          prefix, suffix = split_at_column(line, block_columns[0], replace_wide: operator == "<", pad_wide: operator != ">")
          if operator == ">" && !@editor.use_tabs
            whitespace = suffix[/\A[ \t]*/]
            column = block_columns[0]
            whitespace.each_char { |char| column += cell_width(char, column) }
            suffix = " " * (column - block_columns[0]) + suffix.delete_prefix(whitespace)
          end
          value = operator == ">" ? unit + suffix : suffix.sub(/\A(?:\t{1,#{count}}| {1,#{@editor.tab_size * count}})/, "")
          [line_start(row)...line_end(row), prefix + value]
        end
        @editor.buffer.edit(edits, kind: :vim)
      when "=" then reindent(ranges.first.begin...ranges.last.end)
      end
      @operator, @register = nil, '"'
      if operator == "c"
        @change_keys, @insert_count, @replace_stack = @command.dup, 1, []
        @insert_prefix_length = @change_keys.length
        @mode = :insert
        @block_insert_start = @editor.buffer.anchor(first, bias: :left)
        @block_insert_keep_start = false
        @command.clear
      else
        @mode = :normal
        @editor.select(normal_offset(first))
        operator == "y" ? @command.clear : finish_change
      end
    end

    def paste(after, count)
      entry = register_entry(@register)
      return @command.clear unless entry
      text, type, width = entry
      if visual?
        paste_visual(entry, count)
      elsif type == :block
        paste_block(text, after, count, width)
      else
        row = row_at(cursor_position)
        if type == true
          if after && row == last_row && !source.end_with?("\n")
            first = @editor.buffer.rope.bytesize
            inserted = @editor.buffer.line_ending + (text * count).delete_suffix(@editor.buffer.line_ending)
            destination = first + @editor.buffer.line_ending.bytesize
          else
            first = after ? (row + 1 < @editor.buffer.line_count ? line_start(row + 1) : @editor.buffer.rope.bytesize) : line_start(row)
            inserted, destination = text * count, first
          end
        else
          first = after ? horizontal(cursor_position, 1, insertion: true) : cursor_position
          inserted = text * count
          destination = inserted.include?("\n") ? first : first + inserted.bytesize - (inserted.grapheme_clusters.last&.bytesize || 0)
        end
        @editor.select(first)
        @editor.replace_selections(inserted, kind: :vim)
        @editor.select(normal_offset(destination))
      end
      @register = '"'
      finish_change
    end

    def enter_block_insert(key, count)
      @last_visual = [@mode, @visual_anchor, @visual_head]
      @change_keys, @insert_count, @replace_stack = @visual_keys.dup, count, []
      @insert_prefix_length = @change_keys.length
      columns = block_columns
      column = key == "I" ? columns[0] : columns[1] + 1
      ranges = visual_ranges
      rows = ranges.filter_map do |range|
        row = row_at(range.begin)
        finish = line_end(row)
        next if key == "I" && column_at(finish) < column
        row
      end
      edits = rows.map do |row|
        prefix, suffix = split_at_column(@editor.buffer.line(row), column)
        [line_start(row)...line_end(row), prefix + suffix]
      end
      @editor.buffer.edit(edits, kind: :vim_insert) unless edits.empty?
      points = rows.map { |row| offset_at(row, column, insertion: true) }
      points = [ranges.first.begin] if points.empty?
      @editor.set_selections(points.each_with_index.map { |offset, i| Selection.new(i, offset, offset, nil) })
      @block_insert_start = @editor.buffer.anchor(offset_at(rows.first || row_at(ranges.first.begin), columns[0], insertion: true), bias: :left)
      @block_insert_keep_start = true
      @mode = :insert
      @command.clear
    end

    def replace_visual(key)
      return unless key.grapheme_clusters.length == 1
      ranges = visual_ranges
      @last_visual = [@mode, @visual_anchor, @visual_head]
      @command = @visual_keys.dup
      @editor.set_selections(ranges.each_with_index.map { |range, i| Selection.new(i, range.begin, range.end, nil) })
      if @mode == :visual_block
        slices = block_slices
        ranges = slices.map { |slice| slice[:range] }
        @editor.set_selections(ranges.each_with_index.map { |range, i| Selection.new(i, range.begin, range.end, nil) })
        texts = slices.map do |slice|
          slice[:prefix] + key * slice[:width] + slice[:suffix]
        end
      else
        texts = ranges.map do |range|
          @editor.buffer.rope.byteslice(range).to_s.grapheme_clusters.map { |char| char.include?("\n") ? char : key }.join
        end
      end
      @editor.replace_selections(texts, kind: :vim)
      @mode = :normal
      @editor.select(normal_offset(ranges.first.begin))
      finish_change
    end

    def paste_visual(entry, count)
      text, type, width = entry
      mode, ranges = @mode, visual_ranges
      slices = block_slices if mode == :visual_block
      ranges = slices.map { |slice| slice[:range] } if slices
      first = ranges.first.begin
      @last_visual = [@mode, @visual_anchor, @visual_head]
      @command = @visual_keys.dup
      removed = slices ? slices.map { |slice| slice[:text] } : ranges.map { |range| @editor.buffer.rope.byteslice(range).to_s }
      original_eol = source.end_with?("\n")
      @register = '"'
      store_register(removed.join(mode == :visual_block ? "\n" : ""), mode == :visual_line ? true : (mode == :visual_block ? :block : false), "d",
                     width: mode == :visual_block ? block_columns[1] - block_columns[0] + 1 : nil)
      @mode = :normal
      @editor.buffer.begin_undo_group
      begin
        @editor.set_selections(ranges.each_with_index.map { |range, i| Selection.new(i, range.begin, range.end, nil) })
        if mode == :visual_block
          if type == :block || text.include?("\n")
            @editor.replace_selections(slices.map { |slice| slice[:prefix] + slice[:suffix] }, kind: :vim)
            @editor.select(first + slices.first[:prefix].bytesize)
            paste_block(text, false, count, width)
          else
            @editor.replace_selections(slices.map { |slice| slice[:prefix] + text * count + slice[:suffix] }, kind: :vim)
            @editor.select(normal_offset(first + slices.first[:prefix].bytesize))
          end
        else
          replacement = text * count
          if mode == :visual_line
            replacement += @editor.buffer.line_ending unless replacement.end_with?("\n")
            replacement = replacement.delete_suffix(@editor.buffer.line_ending) if ranges.first.end == @editor.buffer.rope.bytesize && !original_eol
            destination = first
          elsif type == true
            replacement = @editor.buffer.line_ending + replacement
            destination = first + @editor.buffer.line_ending.bytesize
          else
            destination = first + replacement.bytesize - (replacement.grapheme_clusters.last&.bytesize || 0)
          end
          @editor.replace_selections(replacement, kind: :vim)
          @editor.select(normal_offset(destination))
        end
      ensure
        @editor.buffer.end_undo_group
      end
    end

    def paste_block(text, after, count, width)
      row, column = row_at(cursor_position), column_at(cursor_position)
      column += cell_width(character_at(cursor_position), column) if after
      lines = source.split(@editor.buffer.line_ending, -1)
      trailing = lines.last == "" && lines.length > 1
      lines.pop if trailing
      chunks = text.split("\n", -1)
      first = nil
      chunks.each_with_index do |chunk, i|
        destination = row + i
        lines << "" while lines.length <= destination
        line = lines[destination]
        prefix, suffix = split_at_column(line, column)
        cells = 0
        chunk.each_grapheme_cluster { |char| cells += cell_width(char, column + cells) }
        value = (chunk + " " * [(width || cells) - cells, 0].max) * count
        lines[destination] = prefix + value + suffix
        first ||= lines.take(destination).sum { |part| part.bytesize + @editor.buffer.line_ending.bytesize } + prefix.bytesize
      end
      replacement = lines.join(@editor.buffer.line_ending) + (trailing ? @editor.buffer.line_ending : "")
      @editor.select_all
      @editor.replace_selections(replacement, kind: :vim)
      @editor.select(normal_offset(first || 0))
    end

    def join_lines(count)
      row = row_at(cursor_position)
      last = [row + [count - 1, 1].max, last_row].min
      return @command.clear if last == row
      first = line_end(row)
      text = @editor.buffer.line(row)
      (row + 1..last).each do |index|
        first = line_start(row) + text.bytesize
        following = @editor.buffer.line(index).lstrip
        text += " " unless text.empty? || text.end_with?(" ", "\t") || following.empty? || following.start_with?(")")
        text += following
      end
      @editor.select(line_start(row), line_end(last))
      @editor.replace_selections(text, kind: :vim)
      @editor.select(normal_offset(first))
      finish_change
    end

    def reindent(range, before: @editor.selections)
      selection = normalized_line_range(range)
      first = row_at(selection.begin)
      last = row_at(selection.end)
      last -= 1 if last > first && selection.end == line_start(last)
      definition = @editor.language_document.definition
      level, previous, replacements, indent_columns = 0, 0, [], [0]
      significant_indentation = %w[python yaml].include?(definition.name)
      (0..last).each do |row|
        line = @editor.buffer.line(row)
        content = line.lstrip
        closing = definition.indent_close.match?(content) && !content.empty?
        level = [level - 1, 0].max if closing
        if significant_indentation && !content.empty?
          column = 0
          line[/\A[ \t]*/].each_char { |char| column += cell_width(char, column) }
          indent_columns.pop while indent_columns.length > 1 && column < indent_columns.last
          indent_columns << column if column > indent_columns.last
        end
        depth = if significant_indentation
          indent_columns.length - 1
        else
          definition == Language::PLAIN ? previous : level
        end
        if row >= first
          indent = content.empty? ? "" : (@editor.use_tabs ? "\t" * depth : " " * (@editor.tab_size * depth))
          replacements << [line_start(row)...line_end(row), indent + content]
        end
        previous = row >= first ? depth : line[/\A[ \t]*/].gsub("\t", " " * @editor.tab_size).length / @editor.tab_size unless content.empty?
        level += 1 if definition.indent_open.match?(content) || (definition.name == "ruby" && content.match?(/\A(?:else|elsif|rescue|ensure)\b/))
      end
      caret = Selection.new(0, selection.begin, selection.begin, nil)
      @editor.buffer.edit(replacements, kind: :vim, before_selections: before, selections: [caret])
      @editor.select(normal_offset(first_nonblank(first)))
    end

    def indent_rows(range, outdent: false, before: @editor.selections, amount: 1)
      selection = normalized_line_range(range)
      first, last = row_at(selection.begin), row_at(selection.end)
      last -= 1 if last > first && selection.end == line_start(last)
      edits = (first..last).filter_map do |row|
        line = @editor.buffer.line(row)
        next if line.empty?
        result = outdent ? line.sub(/\A(?:\t{1,#{amount}}| {1,#{@editor.tab_size * amount}})/, "") : (@editor.use_tabs ? "\t" * amount : " " * (@editor.tab_size * amount)) + line
        [line_start(row)...line_end(row), result]
      end
      @editor.buffer.edit(edits, kind: :vim, before_selections: before) unless edits.empty?
    end
  end
end

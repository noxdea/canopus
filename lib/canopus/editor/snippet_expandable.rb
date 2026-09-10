# frozen_string_literal: true

require "securerandom"

module Canopus
  module Editor::SnippetExpandable
    SnippetField = Struct.new(:first, :last, :range, :parents, :index, :order)
    private_constant :SnippetField

    def snippet_variables(workspace_root: nil, clipboard: nil, now: Time.now, selection: primary, cursor_index: @selections.index(selection) || 0)
      point = @buffer.rope.point_at(selection.start)
      line = @buffer.line(point.row).delete_suffix("\n").delete_suffix("\r")
      column = @buffer.rope.byteslice(@buffer.rope.line_start(point.row), selection.start - @buffer.rope.line_start(point.row)).to_s.length
      word = line[0...column][/\w*\z/] + line[column..][/\A\w*/]
      path = @buffer.path
      root = workspace_root && File.expand_path(workspace_root)
      comments = case language_document.definition.name
      when "ruby" then ["=begin", "=end"]
      when "html", "markdown" then ["<!--", "-->"]
      when "javascript", "typescript", "rust", "go", "c", "cpp", "json", "css" then ["/*", "*/"]
      else ["", ""]
      end
      variables = {
        "TM_SELECTED_TEXT" => @buffer.rope.byteslice(selection.range).to_s,
        "TM_CURRENT_LINE" => line, "TM_CURRENT_WORD" => word,
        "TM_LINE_INDEX" => point.row.to_s, "TM_LINE_NUMBER" => (point.row + 1).to_s,
        "TM_FILENAME" => path && File.basename(path), "TM_FILENAME_BASE" => path && File.basename(path, File.extname(path)),
        "TM_DIRECTORY" => path && File.dirname(path), "TM_FILEPATH" => path,
        "RELATIVE_FILEPATH" => path && (root ? snippet_relative_path(path, root) : File.basename(path)),
        "CLIPBOARD" => clipboard, "WORKSPACE_NAME" => root && File.basename(root), "WORKSPACE_FOLDER" => root,
        "CURSOR_INDEX" => cursor_index.to_s, "CURSOR_NUMBER" => (cursor_index + 1).to_s,
        "CURRENT_MILLISECOND" => (now.nsec / 1_000_000).to_s.rjust(3, "0"),
        "CURRENT_SECONDS_UNIX" => now.to_i.to_s, "CURRENT_MILLISECONDS_UNIX" => (now.to_r * 1000).floor.to_s,
        "CURRENT_TIMEZONE_OFFSET" => now.strftime("%:z"),
        "CURRENT_TIMEZONE_NAME" => ENV["TZ"]&.match?(/\A(?:UTC|[A-Za-z_]+\/[A-Za-z_\/+-]+)\z/) ? ENV["TZ"] : nil,
        "RANDOM" => SecureRandom.random_number(1_000_000).to_s.rjust(6, "0"), "RANDOM_HEX" => SecureRandom.hex(3), "UUID" => SecureRandom.uuid,
        "BLOCK_COMMENT_START" => comments[0], "BLOCK_COMMENT_END" => comments[1],
        "LINE_COMMENT" => language_document.definition.comment == comments[0] ? "" : language_document.definition.comment
      }
      {"YEAR" => "%Y", "YEAR_SHORT" => "%y", "MONTH" => "%m", "MONTH_NAME" => "%B", "MONTH_NAME_SHORT" => "%b",
        "DATE" => "%d", "DAY_NAME" => "%A", "DAY_NAME_SHORT" => "%a", "HOUR" => "%H", "MINUTE" => "%M", "SECOND" => "%S"}.each do |name, format|
        variables["CURRENT_#{name}"] = now.strftime(format)
      end
      variables
    end

    def insert_snippet(source, variables: {}, workspace_root: nil, clipboard: nil)
      raise Error, "snippet variables must be a Hash" unless variables.is_a?(Hash)
      # Parse every cursor expansion before changing text or disposing a live session.
      snippets = @selections.each_with_index.map do |selection, index|
        builtins = snippet_variables(workspace_root: workspace_root, clipboard: clipboard, selection: selection, cursor_index: index)
        Snippet.new(source, variables: builtins.merge(variables.transform_keys(&:to_s)))
      end
      starts, delta = [], 0
      @selections.zip(snippets).each do |selection, snippet|
        starts << selection.start + delta
        delta += snippet.text.bytesize - selection.range.size
      end
      replace_selections(snippets.map(&:text), kind: :snippet)
      clear_snippet
      @snippet_instances = snippets.zip(starts).map do |snippet, start|
        fields, mirrors = {}, []
        snippet.occurrences.each do |occurrence|
          field = snippet_field(start + occurrence.range.begin...start + occurrence.range.end, occurrence.parents, occurrence.index)
          if occurrence.transform
            mirrors << {index: occurrence.index, field: field, transform: occurrence.transform}
          else
            (fields[occurrence.index] ||= []) << field
          end
        end
        mirrors.each { |mirror| fields[mirror[:index]] ||= [mirror[:field]] }
        fields[0] ||= [snippet_field(start + snippet.text.bytesize...start + snippet.text.bytesize)]
        {snippet: snippet, fields: fields, mirrors: mirrors}
      end
      @snippet_order = @snippet_instances.flat_map { |instance| instance[:fields].keys }.uniq.sort_by { |index| index.zero? ? Float::INFINITY : index }
      @snippet_position = -1
      @snippet_subscription = @buffer.on_edit { |patch| snippet_edited(patch) }
      next_snippet
      snippets.last
    end

    def snippet_active? = !@snippet_instances.nil?

    def snippet_choices
      return nil unless snippet_active?
      @snippet_instances.lazy.map { |instance| instance[:snippet].choices[@snippet_order[@snippet_position]] }.find(&:itself)
    end

    def choose_snippet(value)
      choices = snippet_choices
      return false unless choices
      value = choices[value] if value.is_a?(Integer) && value >= 0
      return false unless choices.include?(value)
      snippet_select(@snippet_order[@snippet_position])
      replace_selections(value, kind: :snippet_choice)
      true
    end

    def next_snippet = snippet_move(1)
    def previous_snippet = snippet_move(-1)

    def clear_snippet
      active = @snippet_instances
      @snippet_subscription&.detach
      @snippet_subscription = nil
      snippet_fields.each { |field| snippet_release(field) } if @snippet_instances
      @snippet_instances = @snippet_order = @snippet_position = nil
      set_selections(@selections) if active
      nil
    end

    private

    def snippet_relative_path(path, root)
      file_parts, root_parts = path.split(File::SEPARATOR), root.split(File::SEPARATOR)
      return path if File::ALT_SEPARATOR && file_parts.first != root_parts.first
      while !file_parts.empty? && file_parts.first == root_parts.first
        file_parts.shift
        root_parts.shift
      end
      ([".."] * root_parts.length + file_parts).join(File::SEPARATOR)
    end

    def snippet_field(range, parents = [], index = 0)
      @snippet_field_order = (@snippet_field_order || 0) + 1
      SnippetField.new(@buffer.anchor(range.begin, bias: :right), @buffer.anchor(range.end, bias: range.size.zero? ? :right : :left), range, parents, index, @snippet_field_order)
    end

    def snippet_fields
      @snippet_instances.flat_map { |instance| instance[:fields].values.flatten + instance[:mirrors].map { |mirror| mirror[:field] } }.uniq(&:object_id)
    end

    def snippet_release(field)
      @buffer.release_anchor(field.first)
      @buffer.release_anchor(field.last)
    end

    def snippet_range(field) = @buffer.resolve(field.first)...@buffer.resolve(field.last)

    def snippet_move(direction)
      return false unless snippet_active?
      position = @snippet_position + direction
      return false if position < 0 || position >= @snippet_order.length
      snippet_transform if @snippet_position >= 0
      while position >= 0 && position < @snippet_order.length
        index = @snippet_order[position]
        if @snippet_instances.any? { |instance| instance[:fields][index]&.any? }
          @snippet_position = position
          snippet_select(index)
          clear_snippet if index.zero?
          reveal_cursor
          return true
        end
        position += direction
      end
      false
    end

    def snippet_select(index)
      active = @snippet_instances.flat_map { |instance| instance[:fields][index] || [] }
      active_ids = active.to_h { |field| [field.object_id, true] }
      ancestors = active.flat_map(&:parents).to_h { |number| [number, true] }
      # Only the active placeholders and their enclosing placeholders grow at
      # both edges. Adjacent/empty future fields must move past newly typed text.
      snippet_fields.each do |field|
        range = snippet_range(field)
        enclosing = active_ids[field.object_id] || (ancestors[field.index] && active.any? { |other| other.parents.include?(field.index) && range.begin <= other.range.begin && range.end >= other.range.end })
        snippet_release(field)
        field.first = @buffer.anchor(range.begin, bias: enclosing ? :left : :right)
        field.last = @buffer.anchor(range.end, bias: enclosing || range.size.zero? ? :right : :left)
        field.range = range
      end
      set_selections(active.map do |field|
        range = snippet_range(field)
        selection = Selection.new(@next_selection, range.begin, range.end, nil)
        @next_selection += 1
        selection
      end)
    end

    def snippet_transform
      index = @snippet_order[@snippet_position]
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.25
      replacements = @snippet_instances.flat_map do |instance|
        source = instance[:fields][index]&.first
        next [] unless source
        value = @buffer.rope.byteslice(snippet_range(source)).to_s
        instance[:mirrors].filter_map do |mirror|
          next unless mirror[:index] == index
          range = snippet_range(mirror[:field])
          replacement = mirror[:transform].apply(value)
          raise Error, "snippet transforms exceeded execution limit" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          [range, replacement, mirror[:field]] unless @buffer.rope.byteslice(range).to_s == replacement
        end
      end.sort_by { |range, _text, _field| range.begin }
      return if replacements.empty?
      @snippet_applying = true
      @snippet_replacements = replacements
      @buffer.edit(replacements.map { |range, text, _field| [range, text] }, kind: :snippet_transform)
      delta = 0
      replacements.each do |range, text, field|
        start = range.begin + delta
        snippet_reanchor(field, start...start + text.bytesize)
        delta += text.bytesize - range.size
      end
    ensure
      @snippet_applying = false
      @snippet_replacements = nil
    end

    def snippet_reanchor(field, range, first_bias: :left, last_bias: :right)
      snippet_release(field)
      field.first = @buffer.anchor(range.begin, bias: first_bias)
      field.last = @buffer.anchor(range.end, bias: last_bias)
      field.range = range
    end

    def snippet_map_offset(patch, offset, bias)
      delta = 0
      patch.edits.each do |edit|
        first, last = edit.old_range.begin, edit.old_range.end
        break if offset < first || (offset == first && bias == :left)
        if offset >= last
          delta += edit.new_text.bytesize - edit.old_range.size
        else
          return bias == :left ? edit.new_range.begin : edit.new_range.end
        end
      end
      offset + delta
    end

    def snippet_edited(patch)
      if patch.is_a?(Patch::Composite) || patch.is_a?(Patch::Reload)
        clear_snippet
        return
      end
      unless @snippet_applying
        index = @snippet_order[@snippet_position]
        edits = patch.edits.dup
        active_fields = @snippet_instances.flat_map { |instance| instance[:fields][index] || [] }
        @snippet_instances.each do |instance|
          active = (instance[:fields][index] || []).map(&:range)
          removed = []
          discard = lambda do |field|
            range = field.range
            field.parents.include?(index) && active.any? { |outer| outer.begin <= range.begin && outer.end >= range.end } &&
              patch.edits.any? { |edit| edit.old_range.size.positive? && edit.old_range.begin <= range.begin && edit.old_range.end >= range.end }
          end
          instance[:fields].each do |number, fields|
            next if number == index || number.zero?
            fields.delete_if { |field| discard.call(field) && (removed << field) }
          end
          instance[:mirrors].delete_if { |mirror| mirror[:index] != index && discard.call(mirror[:field]) && (removed << mirror[:field]) }
          removed.uniq(&:object_id).each { |field| snippet_release(field) }
        end
        # Multiple empty mirrors occupy one byte offset, but each insertion has
        # its own new range. A generic point anchor cannot distinguish them.
        precise = active_fields.sort_by { |field| field.range.begin }.filter_map do |field|
          matching = edits.index { |edit| edit.old_range == field.range }
          [field, edits.delete_at(matching).new_range] if matching
        end
      end
      snippet_fields.each do |field|
        range = field.range
        first_bias, last_bias = field.first.bias, field.last.bias
        if @snippet_applying
          enclosing = @snippet_replacements.any? { |old, _text, changed| changed.parents.include?(field.index) && range.begin <= old.begin && range.end >= old.end }
          first_bias, last_bias = enclosing ? [:left, :right] : [:right, :left]
          if range.size.zero? && !enclosing
            following = @snippet_replacements.any? { |old, _text, changed| old.begin == range.begin && changed.order > field.order }
            first_bias = last_bias = following ? :left : :right
          end
        end
        first = snippet_map_offset(patch, range.begin, first_bias)
        last = snippet_map_offset(patch, range.end, last_bias)
        snippet_reanchor(field, [first, last].min...last, first_bias: field.first.bias, last_bias: field.last.bias)
      end
      precise&.each { |field, range| snippet_reanchor(field, range) }
    end
  end
end

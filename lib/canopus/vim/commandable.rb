# frozen_string_literal: true

module Canopus
  module Vim::Commandable
    private

    def command_key(key)
      @command << key
      case key
      when "esc"
        @command_line = nil
        @operator = nil
        @command.clear
      when "backspace" then @command_line = @command_line.grapheme_clusters[0...-1].join
      when "enter"
        command, @command_line = @command_line, nil
        if @command_type == ":"
          ex(command)
        else
          @search = command unless command.empty?
          @search_direction = @command_type == "/" ? 1 : -1
          target = search_target(count: @search_count || 1)
          @search_count = nil
          if target
            @operator ? operate_motion(target) : move_to(target)
          else
            @operator = nil
          end
        end
        @command.clear
      else @command_line << key if key.grapheme_clusters.length == 1
      end
    rescue RegexpError, Error => error
      @message = error.message
      @operator = nil
    end

    def search_target(reverse: false, count: 1)
      return if !@search || @search.empty?
      matches = @editor.search(Regexp.new(@search))
      return if matches.empty?
      direction = (@search_direction || 1) * (reverse ? -1 : 1)
      offset = cursor_position
      count.times do
        match = direction == 1 ? (matches.find { |range| range.begin > offset } || matches.first) : (matches.reverse.find { |range| range.begin < offset } || matches.last)
        offset = match.begin
      end
      offset
    rescue RegexpError => error
      @message = error.message
      nil
    end

    def search_next(reverse: false, count: 1)
      target = search_target(reverse: reverse, count: count)
      move_to(target) if target
    end

    def ex(command)
      if command.match?(/\A\d+\z/)
        move_to(first_nonblank((command.to_i - 1).clamp(0, last_row)))
      elsif command.match?(/\A(?:%|'\<,'\>)?s[^\w\s]/)
        substitute_command(command)
      elsif command.start_with?("set ")
        command.delete_prefix("set ").split.each do |option|
          case option
          when "relativenumber", "rnu" then @editor.relative_line_numbers = true
          when "norelativenumber", "nornu" then @editor.relative_line_numbers = false
          when /\A(?:tabstop|ts|shiftwidth|sw)=(\d+)\z/
            value = Regexp.last_match(1).to_i
            raise Error, "tabstop must be positive" unless value.positive?
            @editor.tab_size = value
            @editor.display_map.tab_size = value
          when "expandtab", "et" then @editor.use_tabs = false
          when "noexpandtab", "noet" then @editor.use_tabs = true
          end
        end
      elsif command == "w" || command.start_with?("w ")
        @on_command ? @on_command.call(command) : @editor.buffer.save(command.length > 2 ? command[2..] : @editor.buffer.path)
      elsif command == "registers" || command == "reg"
        @message = @registers.map { |name, entry| "\"#{name} #{entry.first.inspect}" }.join("\n")
      else
        @on_command&.call(command)
      end
    end

    def substitute_command(command)
      selected = command.start_with?("'<,'>")
      selected_rows = [row_at(@visual_anchor), row_at(@visual_head)].minmax if selected && @visual_anchor
      all = command.start_with?("%")
      command = command.delete_prefix("%").delete_prefix("'<,'>")
      delimiter = command[1]
      parts, value, escaped = [], +"", false
      command[2..].each_char do |char|
        if escaped
          value << (char == delimiter ? char : "\\#{char}")
          escaped = false
        elsif char == "\\"
          escaped = true
        elsif char == delimiter && parts.length < 2
          parts << value
          value = +""
        else
          value << char
        end
      end
      parts << value
      raise Error, "invalid substitute command" if parts.length < 2
      pattern, replacement, flags = parts
      flags ||= ""
      pattern = @search if pattern.empty?
      raise Error, "no previous search" unless pattern
      regex = Regexp.new(pattern, flags.include?("i") ? Regexp::IGNORECASE : nil)
      @search = pattern
      rows = if all
        0..last_row
      elsif selected_rows
        selected_rows[0]..selected_rows[1]
      else
        row_at(cursor_position)..row_at(cursor_position)
      end
      last_changed = nil
      changes = rows.filter_map do |row|
        original = @editor.buffer.line(row)
        replacer = lambda do |_matched|
          match = Regexp.last_match
          replacement.gsub(/\\([0-9&\\])|&/) do |token|
            if token == "&"
              match[0]
            elsif token == "\\&" || token == "\\\\"
              token[1]
            else
              match[token[1].to_i] || ""
            end
          end
        end
        result = flags.include?("g") ? original.gsub(regex, &replacer) : original.sub(regex, &replacer)
        unless result == original
          last_changed = row
          [line_start(row)...line_end(row), result]
        end
      end
      @editor.buffer.edit(changes, kind: :vim) unless changes.empty?
      @mode = :normal if selected
      @editor.select(normal_offset(first_nonblank(last_changed))) if last_changed
    end
  end
end

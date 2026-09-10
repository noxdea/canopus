# frozen_string_literal: true

module Canopus
  class Vim
    OPERATORS = %w[d c y > < = gu gU g~].freeze
    VISUAL_MODES = %i[visual visual_line visual_block].freeze
    attr_reader :mode, :registers, :marks, :macros, :command_line, :status
    attr_accessor :on_command

    def initialize(editor)
      @editor, @mode = editor, :normal
      @registers, @marks, @macros = {}, {}, {}
      @count, @command, @last_change = +"", [], []
      @register, @status, @play_depth = '"', "NORMAL", 0
    end

    def cursor_position = visual? ? @visual_head : @editor.primary.head

    # A pane losing focus must not keep a shared buffer's undo transaction open.
    # Return to Normal mode, retaining marks, registers and the last change.
    def deactivate
      %i[insert replace].include?(@mode) ? insert_key("esc") : escape
      @command_line = nil
      @status = "NORMAL"
      self
    end

    def dispose
      end_group
      (@marks.values + [@block_insert_start]).compact.uniq.each { |anchor| @editor.buffer.release_anchor(anchor) }
      @marks.clear
      @block_insert_start = nil
    end

    def feed(key)
      @message = nil
      key = "esc" if key == "\e"
      key = "enter" if ["\r", "\n"].include?(key)
      @macros[@recording] << key if @recording && !(key == "q" && @mode == :normal && !@prefix)
      return command_key(key) if @command_line
      return insert_key(key) if %i[insert replace].include?(@mode)
      @visual_keys << key if visual? && @visual_keys
      @command << key
      return escape if %w[esc ctrl-c].include?(key)
      return prefix_key(key) if @prefix
      if key.match?(/\A\d\z/) && (key != "0" || !@count.empty?)
        @count << key
        return
      end
      explicit = !@count.empty?
      count = explicit ? @count.to_i.clamp(1, 10_000) : 1
      @count.clear
      return operate_key(key, count, explicit) if @operator
      if visual? && (%w[d c y > < = x s D C Y].include?(key))
        return operate_visual({"x" => "d", "s" => "c", "D" => "d", "C" => "c", "Y" => "y"}.fetch(key, key), count: count)
      end
      if visual? && %w[i a].include?(key)
        @prefix, @prefix_count = key, count
        return
      end
      case key
      when "i", "a", "I", "A", "o", "O", "R"
        enter_insert(key, count)
      when "v", "V", "ctrl-v"
        requested = {"v" => :visual, "V" => :visual_line, "ctrl-v" => :visual_block}.fetch(key)
        if @mode == requested
          escape
        else
          @visual_anchor = @visual_head = cursor_position unless visual?
          @mode = requested
          @visual_keys = @command.dup
          update_visual
          @command.clear
        end
      when "d", "c", "y", ">", "<", "="
        @operator, @operator_count, @operator_explicit = key, count, explicit
      when "g", "f", "F", "t", "T", "m", "'", "`", '"', "@", "r"
        @prefix, @prefix_count, @prefix_explicit = key, count, explicit
      when "q"
        if @recording
          save_macro_register(@recording)
          @recording = nil
          @command.clear
        else
          @prefix = "q"
        end
      when "x", "X", "s"
        first = cursor_position
        endpoint = horizontal(first, key == "X" ? -count : count, insertion: true)
        operate(key == "s" ? "c" : "d", [first, endpoint].min...[first, endpoint].max)
      when "D", "C", "Y", "S"
        if %w[Y S].include?(key)
          operate(key == "Y" ? "y" : "c", line_range(count), linewise: true)
        else
          ending = line_end([row_at(cursor_position) + count - 1, last_row].min)
          operate(key == "D" ? "d" : "c", cursor_position...ending)
        end
      when "p", "P" then paste(key == "p", count)
      when "u", "ctrl-r"
        groups = @macro_groups || 0
        groups.times { @editor.buffer.end_undo_group }
        begin
          count.times { key == "u" ? @editor.undo : @editor.redo }
        ensure
          groups.times { @editor.buffer.begin_undo_group }
        end
        @editor.select(normal_offset(@editor.primary.head))
        @command.clear
      when "."
        change = @last_change.dup
        @command.clear
        count.times { replay(change) }
      when "J" then join_lines(count)
      when "~"
        if visual?
          operate_visual("g~")
        else
          first = cursor_position
          ending = horizontal(first, count, insertion: true)
          operate("g~", first...ending, destination: normal_offset(ending))
        end
      when ":", "/", "?"
        @command_line, @command_type = +"", key
        @command_line = +"'<,'>" if key == ":" && visual?
      when "n", "N"
        search_next(reverse: key == "N", count: count)
        @command.clear
      when "*", "#"
        range = text_object("w", inner: true, count: 1)
        if range
          @search = "\\b#{Regexp.escape(@editor.buffer.rope.byteslice(range).to_s)}\\b"
          @search_direction = key == "*" ? 1 : -1
          search_next(count: count)
        end
        @command.clear
      else
        move(key, count, explicit: explicit)
        @command.clear
      end
    rescue Error
      end_group
      @mode, @operator, @prefix = :normal, nil, nil
      raise
    ensure
      @status = @message || (@command_line ? "#{@command_type}#{@command_line}" : @mode.to_s.upcase)
    end

    private

    def visual? = VISUAL_MODES.include?(@mode)
    def start_group
      return if @insert_group
      @editor.buffer.begin_undo_group
      @insert_group = true
    end
    def end_group
      return unless @insert_group
      @editor.buffer.end_undo_group
      @insert_group = false
    end

    def escape
      position = cursor_position
      @last_visual = [@mode, @visual_anchor, @visual_head] if visual?
      @mode, @operator, @prefix, @count, @command = :normal, nil, nil, +"", []
      @register = '"'
      @editor.select(normal_offset(position))
    end

    def insert_key(key)
      @change_keys << key
      if @insert_register
        @insert_register = false
        value = @registers[key]&.first
        @editor.replace_selections(value, kind: :vim_insert) if value
        return
      end
      case key
      when "esc", "ctrl-c"
        recorded = @change_keys.dup
        if @insert_count > 1
          keys = recorded.drop(@insert_prefix_length)[0...-1]
          repeats, @insert_count = @insert_count - 1, 1
          repeats.times { keys.each { |item| insert_key(item) } }
        end
        position = if @block_insert_start
          @block_insert_keep_start ? @editor.buffer.resolve(@block_insert_start) : @editor.selections.first.head
        else
          @editor.primary.head
        end
        position = previous_offset(position) if !@block_insert_keep_start && position > line_start(row_at(position))
        @editor.buffer.release_anchor(@block_insert_start) if @block_insert_start
        @block_insert_start = nil
        @block_insert_keep_start = false
        @mode = :normal
        @editor.select(normal_offset(position))
        end_group
        @last_change = recorded
        @command.clear
      when "ctrl-r" then @insert_register = true
      when "backspace"
        if @mode == :replace && @replace_stack.last && @replace_stack.last[1] == @editor.primary.head
          first, ending, original = @replace_stack.pop
          @editor.select(first, ending)
          @editor.replace_selections(original, kind: :vim_insert)
          @editor.select(first)
        else
          @editor.delete_backward
        end
      when "delete" then @editor.delete_forward
      when "left", "right", "up", "down" then @editor.move(key.to_sym)
      when "enter" then @editor.insert_text("\n")
      when "tab" then @editor.insert_text(@editor.use_tabs ? "\t" : " " * @editor.tab_size)
      else
        return unless key.grapheme_clusters.length == 1
        auto_pairs = @editor.auto_pairs
        begin
          @editor.auto_pairs = false
          if @mode == :replace
            first = @editor.primary.head
            ending = horizontal(first, 1, insertion: true)
            original = @editor.buffer.rope.byteslice(first...ending).to_s
            @editor.select(first, ending)
            @replace_stack << [first, first + key.bytesize, original]
          end
          @editor.insert_text(key)
        ensure
          @editor.auto_pairs = auto_pairs
        end
      end
    end

    def enter_insert(key, count = 1)
      start_group
      if @mode == :visual_block && %w[I A].include?(key)
        return enter_block_insert(key, count)
      end
      @change_keys, @insert_count, @replace_stack = @command.dup, count, []
      @insert_prefix_length = @change_keys.length
      case key
      when "a" then @editor.select(horizontal(cursor_position, 1, insertion: true))
      when "I" then @editor.select(first_nonblank(row_at(cursor_position)))
      when "A" then @editor.select(line_end(row_at(cursor_position)))
      when "o"
        @editor.select(line_end(row_at(cursor_position)))
        @editor.insert_text("\n")
      when "O"
        row = row_at(cursor_position)
        indent = @editor.buffer.line(row)[/\A[ \t]*/]
        first = line_start(row)
        @editor.select(first)
        @editor.replace_selections(indent + @editor.buffer.line_ending, kind: :vim_insert)
        @editor.select(first + indent.bytesize)
      end
      @mode = key == "R" ? :replace : :insert
      @command.clear
    end

    def prefix_key(key)
      prefix, @prefix = @prefix, nil
      count = @prefix_count || 1
      case prefix
      when "g"
        if %w[u U ~].include?(key)
          return operate_visual("g#{key}") if visual?
          @operator, @operator_count, @operator_explicit = "g#{key}", count, @prefix_explicit
          return
        elsif key == "g"
          move("gg", count, explicit: true)
        elsif %w[e E].include?(key)
          move("g#{key}", count)
        elsif key == "v" && @last_visual
          @mode, @visual_anchor, @visual_head = @last_visual
          @visual_anchor, @visual_head = normal_offset(@visual_anchor), normal_offset(@visual_head)
          @visual_keys = ["g", "v"]
          update_visual
        end
      when "m"
        @editor.buffer.release_anchor(@marks[key]) if @marks[key]
        @marks[key] = @editor.buffer.anchor(cursor_position, bias: :left) if key.match?(/\A[a-zA-Z]\z/)
      when "'", "`"
        if @marks[key]
          target = @editor.buffer.resolve(@marks[key])
          target = first_nonblank(row_at(target)) if prefix == "'"
          return operate_motion(target, inclusive: false, linewise: prefix == "'") if @operator
          move_to(target)
        else
          @operator = nil
        end
      when '"'
        @register = key
        return
      when "q"
        if key.match?(/\A[a-zA-Z]\z/)
          @recording = key.downcase
          @macros[@recording] = [] unless key.match?(/[A-Z]/) && @macros[@recording]
        end
      when "@"
        name = key == "@" ? @last_macro : key.downcase
        @last_macro = name
        @command.clear
        keys = @macros[name] || register_keys(register_entry(name)&.first.to_s)
        replay(keys, group: true, count: count)
      when "f", "F", "t", "T"
        target = find_character(key, prefix, count)
        if target
          @last_find = [key, prefix]
          return operate_motion(target, inclusive: %w[f t].include?(prefix)) if @operator
          move_to(target)
        else
          @operator = nil
        end
      when "r"
        return replace_visual(key) if visual?
        if key.grapheme_clusters.length == 1 || key == "enter"
          first = cursor_position
          ending = horizontal(first, count, insertion: true)
          if @editor.buffer.rope.byteslice(first...ending).to_s.grapheme_clusters.length == count
            @editor.select(first, ending)
            @editor.replace_selections(key == "enter" ? @editor.buffer.line_ending : key * count, kind: :vim)
            @editor.select(normal_offset(key == "enter" ? first + @editor.buffer.line_ending.bytesize : previous_offset(first + key.bytesize * count)))
            finish_change
          end
        end
      when "i", "a"
        range = text_object(key, inner: prefix == "i", count: count)
        if range
          if visual?
            @visual_anchor, @visual_head = range.begin, previous_offset(range.end)
            update_visual
          else
            operate(@operator, range, linewise: key == "p", destination: @operator == "y" ? range.begin : nil)
          end
        else
          @operator = nil
        end
        return
      when "operator_g"
        if %w[g e E].include?(key)
          return operate_key("g#{key}", count, @prefix_explicit, multiplied: true)
        end
        @operator = nil
      end
      @command.clear
    end

    def operate_key(key, count, explicit = false, multiplied: false)
      count *= @operator_count unless multiplied
      if key == @operator || (%w[gu gU g~].include?(@operator) && key == @operator[-1])
        operate(@operator, line_range(count), linewise: true)
      elsif %w[i a f F t T ' `].include?(key)
        @prefix, @prefix_count = key, count
      elsif key == "g"
        @prefix, @prefix_count, @prefix_explicit = "operator_g", count, explicit || @operator_explicit
      elsif %w[/ ?].include?(key)
        @command_line, @command_type, @search_count = +"", key, count
      else
        effective = @operator == "c" && %w[w W].include?(key) && !character_at(cursor_position).match?(/\s/) ? (key == "w" ? "ce" : "cE") : key
        motion = motion_target(effective, count, explicit: explicit || @operator_explicit)
        if motion
          operate_motion(*motion)
        else
          @operator = nil
          @command.clear
        end
      end
    end

    def operate_motion(target, options = {}, inclusive: options.fetch(:inclusive, false), linewise: options.fetch(:linewise, false))
      first, last = [cursor_position, target].minmax
      if linewise
        ending_row = row_at(last)
        ending = ending_row + 1 < @editor.buffer.line_count ? line_start(ending_row + 1) : @editor.buffer.rope.bytesize
        destination = first if %w[y gu gU g~].include?(@operator)
        return operate(@operator, line_start(row_at(first))...ending, linewise: true, destination: destination)
      end
      if inclusive
        last = next_offset(last)
      elsif first == last && %w[gu gU g~].include?(@operator)
        last = next_offset(last)
      elsif !linewise && target > cursor_position && row_at(target) > row_at(cursor_position) && target == line_start(row_at(target))
        if cursor_position <= first_nonblank(row_at(cursor_position))
          linewise = true
        else
          last = line_end(row_at(target) - 1)
        end
      end
      operate(@operator, first...last, linewise: linewise)
    end

    def finish_change
      @last_change = @command.dup unless @command.empty?
      @command.clear
    end

    def replay(keys, group: false, count: 1)
      raise Error, "macro recursion limit" if @play_depth >= 10
      @replay_remaining = 10_000 if @play_depth.zero?
      @play_depth += 1
      @editor.buffer.begin_undo_group if group
      @macro_groups = (@macro_groups || 0) + 1 if group
      begin
        count.times do
          keys.each do |key|
            raise Error, "macro execution limit" if @replay_remaining.zero?
            @replay_remaining -= 1
            feed(key)
          end
        end
      ensure
        @editor.buffer.end_undo_group if group
        @macro_groups -= 1 if group
        @play_depth -= 1
      end
    end
  end
end

require_relative "vim/motionable"
require_relative "vim/text_object_selectable"
require_relative "vim/operator_capable"
require_relative "vim/commandable"
Canopus::Vim.include Canopus::Vim::Motionable
Canopus::Vim.include Canopus::Vim::TextObjectSelectable
Canopus::Vim.include Canopus::Vim::OperatorCapable
Canopus::Vim.include Canopus::Vim::Commandable

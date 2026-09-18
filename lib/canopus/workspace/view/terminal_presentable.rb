# frozen_string_literal: true

require "uri"

module Canopus
  module Workspace::View::TerminalPresentable
    ANSI_COLORS = %w[#1b1d23 #e06c75 #98c379 #e5c07b #61afef #c678dd #56b6c2 #abb2bf #5c6370 #ff7a85 #b5e890 #ffdb8a #82c7ff #e79aff #79dce7 #ffffff].freeze
    attr_reader :terminal_bounds, :terminal_selection
    Link = Data.define(:kind, :target, :line, :column)

    def terminal_link_at(point)
      return unless @terminal_bounds&.contains?(point) && displayed_terminal
      position = terminal_source_point(point)
      return unless position
      column, row = position
      cells = terminal_row(row)
      column -= 1 while column.positive? && cells[column].width.zero?
      cell = cells[column]
      return terminal_link(cell.hyperlink, explicit: true) if cell.hyperlink
      # ponytail: bare-link detection stays within one screen row; OSC 8 links
      # retain their metadata across wrapping and do not have this limit.
      text = cells.map(&:text).join
      offset = cells.first(column).sum { |value| value.text.bytesize }
      text.to_enum(:scan, /[^\s<>"'`]+/).each do
        match = Regexp.last_match
        first = text[0...match.begin(0)].bytesize
        next unless offset >= first && offset < first + match[0].bytesize
        value = match[0].sub(/[.,;]+\z/, "")
        value = value.delete_prefix("(").delete_suffix(")") if value.start_with?("(")
        value = value.delete_suffix(")") if value.count(")") > value.count("(")
        return terminal_link(value)
      end
      nil
    end

    # This is intentionally an explicit user gesture, never an output handler.
    def terminal_open_link(point, modifiers:)
      return false if (modifiers & %w[cmd ctrl]).empty?
      link = terminal_link_at(point)
      return false unless link
      if link.kind == :url
        return false unless @workspace.window&.respond_to?(:open_url)
        @workspace.window.open_url(link.target)
      else
        editor = @workspace.open(link.target)
        if link.line
          row = (link.line - 1).clamp(0, editor.buffer.line_count - 1)
          value = editor.buffer.line(row)
          prefix = value.each_char.take((link.column.to_i - 1).clamp(0, value.length)).join
          editor.select(editor.buffer.rope.line_start(row) + prefix.bytesize)
          editor.reveal_cursor
        end
        @workspace.window&.request_frame
      end
      true
    end

    def terminal_color(value, fallback)
      return @theme[fallback] if value.nil?
      return format("#%02x%02x%02x", *value) if value.is_a?(Array)
      return ANSI_COLORS[value] if value < 16
      return format("#%02x%02x%02x", *Array.new(3, 8 + (value - 232) * 10)) if value >= 232
      index = value - 16
      ramp = [0, 95, 135, 175, 215, 255]
      format("#%02x%02x%02x", ramp[index / 36], ramp[index / 6 % 6], ramp[index % 6])
    end
    def terminal_point(point)
      grid = displayed_terminal.grid
      position = terminal_source_point(point)
      return unless position
      column, row = position
      [column, (row - grid.scrollback.length).clamp(0, grid.rows - 1)]
    end
    def terminal_scroll(delta)
      map = terminal_row_map
      maximum = [map[:visible] - displayed_terminal.grid.rows, 0].max
      @terminal_scroll = ((@terminal_scroll || 0) - delta).clamp(0, maximum)
      @terminal_selection = nil
    end
    def terminal_select(point, extend: false)
      position = terminal_source_point(point)
      return unless position
      column, row = position
      index = [row, column]
      @terminal_selection = extend && @terminal_selection ? [@terminal_selection.first, index] : [index, index]
    end
    def terminal_selected_text
      return "" unless @terminal_selection
      first, last = @terminal_selection.sort
      map = terminal_row_map
      from_row = terminal_display_for_source(map, first.first)
      to_row = terminal_display_for_source(map, last.first)
      return "" unless from_row && to_row
      (from_row..to_row).map do |display_row|
        row = terminal_source_for_display(map, display_row)
        cells = terminal_row(row)
        from = row == first.first ? first.last : 0
        to = row == last.first ? last.last : cells.length - 1
        cells[from..to].to_a.map(&:text).join.rstrip
      end.join("\n")
    end

    def terminal_command(direction)
      terminal = displayed_terminal
      return false unless terminal&.respond_to?(:commands) && !terminal.grid.alternate?
      map = terminal_row_map(terminal)
      maximum = [map[:visible] - terminal.grid.rows, 0].max
      first_display = maximum - (@terminal_scroll || 0).floor
      current = map[:base] + terminal_source_for_display(map, first_display)
      commands = terminal.commands.select { |command| command.prompt_row >= map[:base] }
      command = if direction == :previous
        commands.reverse.find { |item| @terminal_scroll.to_i.zero? ? item.prompt_row <= current : item.prompt_row < current }
      elsif direction == :next
        commands.find { |item| item.prompt_row > current }
      else
        raise ArgumentError, "invalid terminal command direction"
      end
      terminal_command_jump(command)
    end

    def terminal_command_jump(command)
      return false unless command && displayed_terminal && !displayed_terminal.grid.alternate?
      map = terminal_row_map
      source = command.prompt_row - map[:base]
      display = terminal_display_for_source(map, source)
      return false unless display
      maximum = [map[:visible] - displayed_terminal.grid.rows, 0].max
      @terminal_scroll = maximum - [display, maximum].min
      @terminal_selection = nil
      true
    end

    def terminal_toggle_command(command = nil)
      terminal = displayed_terminal
      return false unless terminal&.respond_to?(:commands) && !terminal.grid.alternate?
      map = terminal_row_map(terminal)
      unless command
        maximum = [map[:visible] - terminal.grid.rows, 0].max
        first = maximum - (@terminal_scroll || 0).floor
        last = [first + terminal.grid.rows - 1, map[:visible] - 1].min
        current = map[:base] + terminal_source_for_display(map, last)
        command = terminal.commands.reverse.find { |item| item.prompt_row <= current && terminal_fold_interval(item, map) }
      end
      return false unless command && terminal_fold_interval(command, map)
      folds = terminal_folds(terminal)
      folds[command.id] ? folds.delete(command.id) : folds[command.id] = true
      @terminal_selection = nil
      terminal_command_jump(command)
      true
    end

    def focus_terminal(terminal)
      return terminal if @terminal_owner.equal?(terminal)
      store_terminal_state if @terminal_owner
      @terminal_owner = terminal
      state = terminal&.instance_variable_get(:@canopus_terminal_view_state)
      @terminal_scroll = state&.fetch(:scroll, 0) || 0
      @terminal_selection = state&.[](:selection)
      @terminal_bounds = state&.[](:bounds)
      @terminal_visible_rows = state&.[](:visible_rows)
      @terminal_first = state&.fetch(:first, 0) || 0
      @terminal_first_display = state&.fetch(:first_display, 0) || 0
      @terminal_cell_width = state&.[](:cell_width)
      @terminal_line_height = state&.[](:line_height)
      @terminal_font_size = state&.[](:font_size)
      terminal
    end

    private
    def store_terminal_state
      @terminal_owner.instance_variable_set(:@canopus_terminal_view_state,
        {scroll: @terminal_scroll || 0, selection: @terminal_selection,
        bounds: @terminal_bounds, visible_rows: @terminal_visible_rows, first: @terminal_first || 0,
        first_display: @terminal_first_display || 0, cell_width: @terminal_cell_width,
        line_height: @terminal_line_height, font_size: @terminal_font_size})
    end

    def terminal_visual_point(point)
      grid = displayed_terminal.grid
      column = ((point.x - @terminal_bounds.x) / @terminal_cell_width).floor.clamp(0, grid.columns - 1)
      row = ((point.y - @terminal_bounds.y) / (@terminal_line_height || @line_height)).floor.clamp(0, grid.rows - 1)
      [column, row]
    end

    def terminal_source_point(point)
      column, row = terminal_visual_point(point)
      source = @terminal_visible_rows ? @terminal_visible_rows[row] : @terminal_first.to_i + row
      [column, source] if source
    end

    def terminal_folds(terminal)
      terminal.instance_variable_get(:@canopus_command_folds) ||
        terminal.instance_variable_set(:@canopus_command_folds, {})
    end

    def terminal_fold_interval(command, map)
      range = command.output_range
      return unless range && range.begin.is_a?(Integer) && range.end.is_a?(Integer)
      first = [range.begin, command.prompt_row + 1, map[:base]].max - map[:base]
      last = [range.end - 1, map[:base] + map[:length] - 1].min - map[:base]
      [first, last] if first <= last
    end

    def terminal_row_map(terminal = displayed_terminal)
      grid = terminal.grid
      base = grid.scrollback.total - grid.scrollback.length
      length = grid.scrollback.length + grid.rows
      map = {base: base, length: length}
      return map.merge(intervals: [], visible: length) if grid.alternate?
      commands = terminal.respond_to?(:commands) ? terminal.commands : []
      commands = commands.select { |command| command.prompt_row.between?(base, base + length - 1) }
      folds = terminal_folds(terminal)
      ids = commands.to_h { |command| [command.id, true] }
      folds.delete_if { |id| !ids.key?(id) }
      intervals = commands.filter_map { |command| terminal_fold_interval(command, map) if folds[command.id] }
        .sort_by(&:first).each_with_object([]) do |interval, merged|
          if merged.last && interval.first <= merged.last.last + 1
            merged.last[1] = [merged.last.last, interval.last].max
          else
            merged << interval
          end
        end
      map.merge(intervals: intervals, visible: length - intervals.sum { |first, last| last - first + 1 })
    end

    def terminal_source_for_display(map, display)
      return unless display.between?(0, map[:visible] - 1)
      source = display
      map[:intervals].each do |first, last|
        break if source < first
        source += last - first + 1
      end
      source
    end

    def terminal_display_for_source(map, source)
      return unless source.between?(0, map[:length] - 1)
      hidden = 0
      map[:intervals].each do |first, last|
        return if source.between?(first, last)
        break if source < first
        hidden += last - first + 1
      end
      source - hidden
    end

    def terminal_link(value, explicit: false)
      return if value.empty? || value.bytesize > 8192 || value.match?(/[\x00-\x1f\x7f]/)
      if value.match?(/\Ahttps?:\/\//i)
        uri = URI.parse(value)
        return Link.new(:url, value, nil, nil) if %w[http https].include?(uri.scheme.downcase) && uri.host && !uri.host.empty?
        return
      end
      line = column = nil
      if value.start_with?("file://")
        uri = URI.parse(value)
        return unless [nil, "", "localhost"].include?(uri.host)
        value = URI::RFC2396_PARSER.unescape(uri.path).force_encoding("UTF-8")
        return unless value.start_with?("/") && value.valid_encoding? && !value.include?("\0")
        if (location = uri.fragment&.match(/\AL?(\d+)(?:[:C](\d+))?\z/))
          line, column = location[1].to_i, location[2]&.to_i
        end
        value = value.delete_prefix("/") if RUBY_PLATFORM.match?(/mingw|mswin/) && value.match?(%r{\A/[A-Za-z]:/})
      elsif value.match?(%r{\A[a-z][a-z0-9+.-]*:}i) && !value.match?(%r{\A[A-Za-z]:[\\/]})
        # Reject executable/custom URI schemes; path:line below is still valid.
        return if explicit || !value.match?(/:\d+(?::\d+)?\z/)
      end
      if (location = value.match(/\A(.+?)(?::(\d+)(?::(\d+))?|\((\d+)(?:,(\d+))?\))\z/))
        value, line, column = location[1], (location[2] || location[4]).to_i, (location[3] || location[5])&.to_i
      end
      directory = displayed_terminal.respond_to?(:cwd) ? displayed_terminal.cwd : displayed_terminal.vt.cwd
      directory = @workspace.root unless directory && File.directory?(directory)
      path = File.expand_path(value, directory)
      Link.new(:file, path, line, column) if File.file?(path)
    rescue URI::InvalidURIError, ArgumentError, SystemCallError
      nil
    end

    def terminal_font(cell)
      return unless cell.attributes[:italic] && @cx.text_system
      system = @cx.text_system
      return unless system.respond_to?(:font_db) && system.respond_to?(:font)
      key = [system.font_db.object_id, system.font.family, cell.attributes[:bold] ? 700 : 400]
      @terminal_italic_fonts ||= {}
      @terminal_italic_fonts[key] ||= system.font_db.find(family: key[1], weight: key[2], style: :italic)
    end

    def terminal_row(index)
      grid = displayed_terminal.grid
      index < grid.scrollback.length ? grid.scrollback[index] : grid.cells[index - grid.scrollback.length]
    end
    def displayed_terminal = @terminal_owner || @workspace.terminal
    def render_terminal(bounds)
      fill(bounds, :panel)
      active = @workspace.terminal
      unless active
        focus_terminal(nil)
        text("No terminals — Ctrl+Shift+` to create one", bounds.x + 12, bounds.y + 8, color: :muted, size: 12)
        return
      end
      render_pty_tabs(bounds, entries: @workspace.terminals, active: active,
        title: ->(item) { @workspace.terminal_title(item) }, prefix: :terminal)
      body = Zaniah::Bounds.new(bounds.x, bounds.y + 28, bounds.width, [bounds.height - 28, 0].max)
      render_terminal_layout(@workspace.terminal_layout || {terminal: active}, body)
      focus_terminal(active)
    end

    def render_task_output(bounds)
      render_pty_panel(bounds, entries: @workspace.task_outputs, active: @workspace.task_output,
        title: ->(item) { @workspace.task_output_title(item) }, prefix: :task_output,
        empty: "No task output — run task with Cmd/Ctrl+Shift+B") { |item| item.terminal }
    end

    def render_pty_panel(bounds, entries:, active:, title:, prefix:, empty:, &terminal_for)
      fill(bounds, :panel)
      terminal = active && terminal_for.call(active)
      unless terminal
        focus_terminal(nil)
        text(empty, bounds.x + 12, bounds.y + 8, color: :muted, size: 12)
        return
      end
      render_pty_tabs(bounds, entries: entries, active: active, title: title, prefix: prefix)
      focus_terminal(terminal)
      body = Zaniah::Bounds.new(bounds.x, bounds.y + 28, bounds.width, [bounds.height - 28, 0].max)
      render_terminal_content(terminal, body, prefix)
      store_terminal_state
    end

    def render_pty_tabs(bounds, entries:, active:, title:, prefix:)
      x = bounds.x
      entries.each_with_index do |current, index|
        label = title.call(current)
        width = [[label.length * 7.5 + 42, 100].max, 220].min
        tab = Zaniah::Bounds.new(x, bounds.y, width, 28)
        fill(tab, :active_tab) if current.equal?(active)
        text(label, tab.x + 10, tab.y + 6, color: current.equal?(active) ? :foreground : :muted, size: 12)
        tab_action = prefix == :terminal ? :terminal_tab : :task_output_tab
        region(tab, role: :tab, label: label, action: [tab_action, index])
        close = Zaniah::Bounds.new(tab.right - 25, tab.y, 25, tab.height)
        running = prefix == :task_output && @workspace.task_runner.running?(current)
        text(running ? "■" : "×", close.x + 6, close.y + 5, color: :muted, size: 12)
        close_action = prefix == :terminal ? :terminal_close : :task_output_close
        region(close, role: :button, label: "#{running ? 'Stop' : 'Close'} #{label}", action: [close_action, index])
        x += width
      end
    end

    def render_terminal_layout(node, bounds)
      if node[:terminal]
        focus_terminal(node[:terminal])
        render_terminal_content(node[:terminal], bounds, :terminal)
        store_terminal_state
        return
      end
      horizontal = node[:direction] == :horizontal
      ratio = node.fetch(:ratio, 0.5)
      node[:children].each_with_index do |child, index|
        start, fraction = index.zero? ? [0, ratio] : [ratio, 1 - ratio]
        part = if horizontal
          Zaniah::Bounds.new(bounds.x + bounds.width * start, bounds.y, bounds.width * fraction, bounds.height)
        else
          Zaniah::Bounds.new(bounds.x, bounds.y + bounds.height * start, bounds.width, bounds.height * fraction)
        end
        render_terminal_layout(child, part)
      end
      divider = horizontal ?
        Zaniah::Bounds.new(bounds.x + bounds.width * ratio - 2, bounds.y, 4, bounds.height) :
        Zaniah::Bounds.new(bounds.x, bounds.y + bounds.height * ratio - 2, bounds.width, 4)
      fill(divider, :border)
      region(divider, role: :separator, label: "Resize terminal split", action: [:split_resize, node, bounds])
    end

    def render_terminal_content(terminal, bounds, prefix)
      @terminal_font_size = @workspace.settings["terminal"]["font_size"] || @font_size
      @terminal_line_height = (@terminal_font_size * @workspace.settings["terminal"]["line_height"]).ceil
      @terminal_cell_width = @cx.text_system&.layout_line("M", size: @terminal_font_size)&.width || @terminal_font_size * 0.6
      columns = [(bounds.width - 24) / @terminal_cell_width, @workspace.settings["terminal"]["min_cols"]].max.floor
      rows = [(bounds.height - 12) / @terminal_line_height, @workspace.settings["terminal"]["min_rows"]].max.floor
      prefix == :terminal ? @workspace.resize_terminal(columns, rows, terminal: terminal) : @workspace.resize_task_output(columns, rows)
      grid = terminal.grid
      @terminal_bounds = Zaniah::Bounds.new(bounds.x + 12, bounds.y + 4,
        columns * @terminal_cell_width, rows * @terminal_line_height).intersect(bounds)
      map = terminal_row_map(terminal)
      maximum = [map[:visible] - rows, 0].max
      @terminal_scroll = (@terminal_scroll || 0).clamp(0, maximum)
      @terminal_first_display = maximum - @terminal_scroll.floor
      @terminal_visible_rows = rows.times.map { |row| terminal_source_for_display(map, @terminal_first_display + row) }
      @terminal_first = @terminal_visible_rows.compact.first || 0
      selection = @terminal_selection&.sort
      command_regions = []
      @scene.clip(@terminal_bounds) do
        rows.times do |row|
          source_row = @terminal_visible_rows[row]
          next unless source_row
          cells = terminal_row(source_row)
          cells.each_with_index do |cell, column|
            next if cell.width.zero?
            x, y = @terminal_bounds.x + column * @terminal_cell_width, @terminal_bounds.y + row * @terminal_line_height
            foreground = terminal_color(cell.foreground, :foreground)
            background = terminal_color(cell.background, :panel)
            foreground, background = background, foreground if cell.attributes[:inverse]
            rect = Zaniah::Bounds.new(x, y, cell.width * @terminal_cell_width, @terminal_line_height)
            fill(rect, background) if background != @theme[:panel]
            position = [source_row, column]
            fill(rect, :selection) if selection && (position <=> selection.first) >= 0 && (position <=> selection.last) <= 0
            next if cell.attributes[:hidden]
            foreground = Zaniah::Color.parse(foreground).opacity(0.6) if cell.attributes[:dim]
            unless cell.text.strip.empty?
              font = terminal_font(cell)
              text(cell.text, x, y, color: foreground, size: @terminal_font_size, font: font)
              text(cell.text, x + 0.5, y, color: foreground, size: @terminal_font_size, font: font) if cell.attributes[:bold]
            end
            if cell.attributes[:underline] || cell.hyperlink
              fill(Zaniah::Bounds.new(x, y + @terminal_line_height - 2, rect.width, 1), terminal_color(cell.attributes[:underline_color], :foreground))
            end
            fill(Zaniah::Bounds.new(x, y + @terminal_line_height / 2, rect.width, 1), foreground) if cell.attributes[:strikethrough]
          end
        end
        if prefix == :terminal && terminal.respond_to?(:commands) && !grid.alternate?
          terminal.commands.each do |command|
            source_row = command.prompt_row - map[:base]
            display_row = terminal_display_for_source(map, source_row)
            next unless display_row
            row = display_row - @terminal_first_display
            next unless row.between?(0, rows - 1)
            y = @terminal_bounds.y + row * @terminal_line_height
            fill(Zaniah::Bounds.new(@terminal_bounds.x, y, @terminal_bounds.width, 1), :border)
            foldable = terminal_fold_interval(command, map)
            marker = foldable ? (terminal_folds(terminal)[command.id] ? "▸ " : "▾ ") : ""
            label = marker + (command.exit_status.zero? ? "✓" : "exit #{command.exit_status}")
            width = label.length * 7 + 8
            text(label, @terminal_bounds.right - width + 4, y, color: command.exit_status.zero? ? :muted : :error, size: 10)
            command_regions << [Zaniah::Bounds.new(@terminal_bounds.right - width, y, width, @terminal_line_height), command] if foldable
          end
        end
        blinking = @workspace.settings["terminal"]["blinking"]
        if grid.cursor_visible && @terminal_scroll.zero? &&
            (blinking == "off" || @cursor_visible || !@workspace.terminal_composition&.text.to_s.empty?)
          cursor_source = grid.scrollback.length + grid.cursor_y
          cursor_display = terminal_display_for_source(map, cursor_source)
          cursor_row = cursor_display && cursor_display - @terminal_first_display
          if cursor_row&.between?(0, rows - 1)
            x = @terminal_bounds.x + grid.cursor_x * @terminal_cell_width
            y = @terminal_bounds.y + cursor_row * @terminal_line_height
            cursor = case @workspace.settings["terminal"]["cursor_shape"]
            when "bar" then Zaniah::Bounds.new(x, y, 2, @terminal_line_height)
            when "underline" then Zaniah::Bounds.new(x, y + @terminal_line_height - 2, @terminal_cell_width, 2)
            else Zaniah::Bounds.new(x, y, @terminal_cell_width, @terminal_line_height)
            end
            fill(cursor, "#e9a66166")
            composition = @workspace.terminal_composition
            if composition && !composition.text.empty?
              layout = text(composition.text, x, y, color: :accent, size: @terminal_font_size)
              fill(Zaniah::Bounds.new(x, y + @terminal_line_height - 2, layout&.width || 20, 1), :accent)
              @cx.window.ime_state = Zaniah::Bounds.new(x, y, 2, @terminal_line_height)
            end
          end
        end
      end
      if terminal.respond_to?(:status) && terminal.status
        code = terminal.status.exited? ? terminal.status.exitstatus : "signal #{terminal.status.termsig}"
        hint = prefix == :terminal ? "Process exited with #{code} — press Enter to restart" : "Task exited with #{code}"
        text(hint, @terminal_bounds.x + 4,
          [@terminal_bounds.bottom - @terminal_line_height, @terminal_bounds.y].max, color: :muted, size: 11)
      end
      if prefix == :terminal && terminal.equal?(@workspace.terminal)
        fill(Zaniah::Bounds.new(bounds.x, bounds.y, bounds.width, 2), :accent)
      end
      action = prefix == :terminal ? [prefix, terminal] : [prefix]
      region(@terminal_bounds, role: :terminal, label: prefix == :terminal ? "Terminal" : "Task output", action: action)
      command_regions.each do |bounds, command|
        region(bounds, role: :button, label: "Toggle command output", action: [:terminal_command, command, terminal])
      end
    end
  end
end

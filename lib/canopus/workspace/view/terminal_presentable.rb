# frozen_string_literal: true

require "uri"

module Canopus
  module Workspace::View::TerminalPresentable
    ANSI_COLORS = %w[#1b1d23 #e06c75 #98c379 #e5c07b #61afef #c678dd #56b6c2 #abb2bf #5c6370 #ff7a85 #b5e890 #ffdb8a #82c7ff #e79aff #79dce7 #ffffff].freeze
    attr_reader :terminal_bounds, :terminal_selection
    Link = Data.define(:kind, :target, :line, :column)

    def terminal_link_at(point)
      return unless @terminal_bounds&.contains?(point) && @workspace.terminal
      column, row = terminal_point(point)
      cells = terminal_row(@terminal_first + row)
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
      grid = @workspace.terminal.grid
      column = ((point.x - @terminal_bounds.x) / @terminal_cell_width).floor.clamp(0, grid.columns - 1)
      row = ((point.y - @terminal_bounds.y) / (@terminal_line_height || @line_height)).floor.clamp(0, grid.rows - 1)
      [column, row]
    end
    def terminal_scroll(delta)
      @terminal_scroll = ((@terminal_scroll || 0) - delta).clamp(0, @workspace.terminal.grid.scrollback.length)
      @terminal_selection = nil
    end
    def terminal_select(point, extend: false)
      column, row = terminal_point(point)
      index = [@terminal_first + row, column]
      @terminal_selection = extend && @terminal_selection ? [@terminal_selection.first, index] : [index, index]
    end
    def terminal_selected_text
      return "" unless @terminal_selection
      first, last = @terminal_selection.sort
      (first.first..last.first).map do |row|
        cells = terminal_row(row)
        from = row == first.first ? first.last : 0
        to = row == last.first ? last.last : cells.length - 1
        cells[from..to].to_a.map(&:text).join.rstrip
      end.join("\n")
    end

    private
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
      directory = @workspace.terminal.vt.cwd
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
      grid = @workspace.terminal.grid
      index < grid.scrollback.length ? grid.scrollback[index] : grid.cells[index - grid.scrollback.length]
    end
    def render_terminal(bounds)
      fill(bounds, :panel)
      @terminal_bounds = nil
      terminal = @workspace.terminal
      unless terminal
        text("No terminals — Ctrl+Shift+` to create one", bounds.x + 12, bounds.y + 8, color: :muted, size: 12)
        return
      end
      if @terminal_owner != terminal
        @terminal_owner, @terminal_scroll, @terminal_selection = terminal, 0, nil
      end
      x = bounds.x
      @workspace.terminals.each_with_index do |current, index|
        label = @workspace.terminal_title(current)
        width = [[label.length * 7.5 + 42, 100].max, 220].min
        tab = Zaniah::Bounds.new(x, bounds.y, width, 28)
        fill(tab, :active_tab) if current.equal?(terminal)
        text(label, tab.x + 10, tab.y + 6, color: current.equal?(terminal) ? :foreground : :muted, size: 12)
        region(tab, role: :tab, label: label, action: [:terminal_tab, index])
        close = Zaniah::Bounds.new(tab.right - 25, tab.y, 25, tab.height)
        text("×", close.x + 6, close.y + 5, color: :muted, size: 12)
        region(close, role: :button, label: "Close #{label}", action: [:terminal_close, index])
        x += width
      end
      @terminal_font_size = @workspace.settings["terminal"]["font_size"] || @font_size
      @terminal_line_height = (@terminal_font_size * @workspace.settings["terminal"]["line_height"]).ceil
      @terminal_cell_width = @cx.text_system&.layout_line("M", size: @terminal_font_size)&.width || @terminal_font_size * 0.6
      columns = [(bounds.width - 24) / @terminal_cell_width, @workspace.settings["terminal"]["min_cols"]].max.floor
      rows = [(bounds.height - 40) / @terminal_line_height, @workspace.settings["terminal"]["min_rows"]].max.floor
      @workspace.resize_terminal(columns, rows)
      grid = terminal.grid
      @terminal_bounds = Zaniah::Bounds.new(bounds.x + 12, bounds.y + 32, columns * @terminal_cell_width, rows * @terminal_line_height).intersect(bounds)
      @terminal_scroll = (@terminal_scroll || 0).clamp(0, grid.scrollback.length)
      @terminal_first = grid.scrollback.length - @terminal_scroll.floor
      selection = @terminal_selection&.sort
      @scene.clip(@terminal_bounds) do
        rows.times do |row|
          cells = terminal_row(@terminal_first + row)
          cells.each_with_index do |cell, column|
            next if cell.width.zero?
            x, y = @terminal_bounds.x + column * @terminal_cell_width, @terminal_bounds.y + row * @terminal_line_height
            foreground = terminal_color(cell.foreground, :foreground)
            background = terminal_color(cell.background, :panel)
            foreground, background = background, foreground if cell.attributes[:inverse]
            rect = Zaniah::Bounds.new(x, y, cell.width * @terminal_cell_width, @terminal_line_height)
            fill(rect, background) if background != @theme[:panel]
            position = [@terminal_first + row, column]
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
        blinking = @workspace.settings["terminal"]["blinking"]
        if grid.cursor_visible && @terminal_scroll.zero? &&
            (blinking == "off" || @cursor_visible || !@workspace.terminal_composition&.text.to_s.empty?)
          x = @terminal_bounds.x + grid.cursor_x * @terminal_cell_width
          y = @terminal_bounds.y + grid.cursor_y * @terminal_line_height
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
      if terminal.respond_to?(:status) && terminal.status
        code = terminal.status.exited? ? terminal.status.exitstatus : "signal #{terminal.status.termsig}"
        text("Process exited with #{code} — press Enter to restart", @terminal_bounds.x + 4,
          [@terminal_bounds.bottom - @terminal_line_height, @terminal_bounds.y].max, color: :muted, size: 11)
      end
      region(@terminal_bounds, role: :terminal, label: "Terminal", action: [:terminal])
    end
  end
end

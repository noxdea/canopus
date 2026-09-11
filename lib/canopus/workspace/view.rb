# frozen_string_literal: true

module Canopus
  # A viewport is one element; only visible document rows become draw commands.
  class Workspace::View < Zaniah::Element
    attr_reader :editor_bounds, :row_layouts, :regions, :accessibility
    attr_accessor :keymap
    def initialize(workspace)
      super()
      @workspace = workspace
      @editor_bounds, @row_layouts, @regions, @accessibility = {}, {}, [], []
      @project_scroll = 0
      reset_blink
      @revealed_cursors, @line_widths, @code_caches = {}, {}, {}
      @frame_diagnostics = {}
    end
    def reset_blink(now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
      @blink_started, @cursor_visible = now, true
    end
    def cursor_visible? = @cursor_visible
    def tick(now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
      expired = @workspace.expire_notifications(now)
      visible = ((now - @blink_started) / 0.5).floor.even?
      return expired if visible == @cursor_visible
      @cursor_visible = visible
      true
    end
    def paint(bounds, _state, _prepaint, cx)
      @cx, @theme, @scene = cx, @workspace.theme, cx.scene
      @viewport_bounds = bounds
      @painted_palette = @workspace.palette
      @font_size = @workspace.settings["font_size"]
      @line_height = (@font_size * 1.55).ceil
      @line_height = 20 if @cx.window.is_a?(Zaniah::Platform::TUI::Window)
      @regions.clear
      @row_layouts.clear
      @editor_bounds.clear
      @accessibility.clear
      @frame_diagnostics.clear
      visible_editors = @workspace.panes.map(&:active)
      @revealed_cursors.delete_if { |editor, _| !visible_editors.include?(editor) }
      @line_widths.delete_if { |editor, _| !visible_editors.include?(editor) }
      @code_caches.delete_if { |editor, _| !visible_editors.include?(editor) }
      fill(bounds, :background)
      bottom_panel = @workspace.docks[:bottom][:visible] && @workspace.panels.values.any? { |side, _| side == :bottom }
      bottom = @workspace.terminal_visible || bottom_panel ? [bounds.height * 0.7, @workspace.docks[:bottom][:size]].min : 0
      sidebar = @workspace.show_project && @workspace.docks[:left][:visible] && bounds.width >= 620 ? [@workspace.docks[:left][:size], bounds.width * 0.4].min : 0
      right = @workspace.docks[:right][:visible] && bounds.width >= 620 ? [@workspace.docks[:right][:size], bounds.width * 0.4].min : 0
      body = Zaniah::Bounds.new(sidebar, 0, bounds.width - sidebar - right, [bounds.height - 26 - bottom, 0].max)
      if sidebar.positive?
        left_panels = @workspace.panels.values.any? { |side, _| side == :left }
        project_height = left_panels ? (bounds.height - 26) * 0.6 : bounds.height - 26
        paint_project(Zaniah::Bounds.new(0, 0, sidebar, project_height))
        paint_panels(:left, Zaniah::Bounds.new(0, project_height, sidebar, bounds.height - 26 - project_height)) if left_panels
      end
      paint_layout(@workspace.layout, body)
      if bottom.positive?
        area = Zaniah::Bounds.new(sidebar, body.height, body.width, bottom)
        @workspace.terminal_visible ? paint_terminal(area) : paint_panels(:bottom, area)
      end
      paint_panels(:right, Zaniah::Bounds.new(bounds.width - right, 0, right, bounds.height - 26)) if right.positive?
      region(Zaniah::Bounds.new(sidebar - 3, 0, 6, body.height), role: :separator, label: "Resize left dock", action: [:dock_resize, :left, bounds]) if sidebar.positive?
      region(Zaniah::Bounds.new(bounds.width - right - 3, 0, 6, body.height), role: :separator, label: "Resize right dock", action: [:dock_resize, :right, bounds]) if right.positive?
      region(Zaniah::Bounds.new(body.x, body.bottom - 3, body.width, 6), role: :separator, label: "Resize bottom dock", action: [:dock_resize, :bottom, bounds]) if bottom.positive?
      paint_status(Zaniah::Bounds.new(0, bounds.height - 26, bounds.width, 26))
      paint_hover(bounds) if @workspace.hover_card && !@workspace.hover_card.empty?
      paint_palette(bounds) if @workspace.palette
      paint_notifications(bounds) unless @workspace.notifications.empty?
      if @workspace.performance
        stats = @workspace.performance.statistics
        label = "#{stats[:last_frame_ms]&.round(2) || 'n/a'} ms | #{stats[:last_allocations] || 'n/a'} objects | #{stats[:last_draw_calls] || 'n/a'} draws"
        @scene.layer(2_000_000) do
          area = Zaniah::Bounds.new([bounds.right - 360, 0].max, 3, [bounds.width, 356].min, 24)
          fill(area, :panel)
          text(label, area.x + 8, area.y + 4, color: :accent, size: 11)
        end
      end
    end
    def hit(point)
      return unless @painted_palette.equal?(@workspace.palette)
      @regions.reverse_each { |bounds, action| return action if bounds.contains?(point) }
      nil
    end
    def offset_at(editor, point)
      bounds = @editor_bounds.fetch(editor)
      row = (((point.y - bounds.y) / @line_height) + editor.scroll_y).floor.clamp(0, editor.display_map.row_count - 1)
      value = editor.display_map.row(row).text
      layout = @row_layouts[[editor, row]] || @cx.text_system&.layout_line(value, size: @font_size)
      x = point.x - bounds.x - gutter(editor) + editor.scroll_x
      byte = layout ? layout.index_for_x(x) : (x / (@font_size * 0.6)).round.clamp(0, value.length)
      column = layout ? value.byteslice(0, byte).length : byte
      editor.display_map.to_buffer(DisplayPoint.new(row, column))
    end
    def project_scroll(delta)
      @project_scroll = [@project_scroll + delta, 0].max
    end

    private
    def paint_notifications(bounds)
      @scene.layer(1_500_000) do
        width = [420, bounds.width - 16].min
        @workspace.notifications.reverse_each.with_index do |item, index|
          area = Zaniah::Bounds.new(bounds.right - width - 8, bounds.bottom - 88 - index * 58, width, 50)
          fill(area, :panel)
          fill(Zaniah::Bounds.new(area.x, area.y, 3, area.height), :accent)
          @scene.clip(area) { text(item[:text].lines.first.to_s, area.x + 12, area.y + 16, size: 12) }
          close = Zaniah::Bounds.new(area.right - 28, area.y, 28, area.height)
          fill(close, :panel)
          text("×", close.x + 6, close.y + 14, color: :muted)
          @accessibility << {role: :alert, label: item[:text], bounds: area}
          region(close, role: :button, label: "Dismiss notification", action: [:dismiss_notification, item[:id]])
        end
      end
    end
    def fill(bounds, color)
      @scene.quad(bounds.x, bounds.y, bounds.width, bounds.height, color: color.is_a?(Symbol) ? @theme[color] : color)
    end
    def text(value, x, y, color: :foreground, size: @font_size, font: nil)
      color = @theme[color] if color.is_a?(Symbol)
      value = value.to_s.encode(Encoding::UTF_8)
      line = @cx.text_system&.layout_line(value, size: size, font: font)
      @cx.text_system&.paint_line(@scene, line, x: x, y: y + line.ascent, color: color) if line
      @cx.window.text_runs << [x, y, value, color]
      line
    end
    def region(bounds, role:, label:, action:)
      bounds = bounds.intersect(@viewport_bounds)
      bounds = bounds.intersect(@scene.current_clip) if @scene.current_clip
      return if bounds.width <= 0 || bounds.height <= 0
      @regions << [bounds, action]
      @accessibility << {role: role, label: label, bounds: bounds}
    end
    def paint_project(bounds)
      fill(bounds, :panel)
      text(File.basename(@workspace.root), 16, 12, color: :foreground, size: 13)
      text("Files", 16, 43, color: :muted, size: 12)
      files = @workspace.project_tree.visible
      status = @workspace.git_status
      count = [(bounds.height - 76) / 24, 0].max.floor
      @project_scroll = @project_scroll.clamp(0, [files.length - count, 0].max)
      @scene.clip(bounds) do
        files.slice(@project_scroll.floor, count).to_a.each_with_index do |entry, index|
          path = entry.path
          row = Zaniah::Bounds.new(0, 70 + index * 24, bounds.width, 24)
          active = @workspace.editor&.buffer&.path == File.expand_path(path, @workspace.root)
          fill(row, :active_tab) if active
          x = 16 + entry.depth * 12
          if @cx.window.is_a?(Zaniah::Platform::TUI::Window)
            label = entry.directory ? "#{entry.expanded ? '−' : '+'} #{entry.name}" : entry.name
          else
            icon = @workspace.icon_theme.texture(path, directory: entry.directory, expanded: entry.expanded, scale: @cx.window.scale_factor, color: @theme[active ? :foreground : :muted])
            @scene.sprite(x, row.y + 3, 16, 16, texture: icon)
            x += 22
            label = entry.name
          end
          text(label, x, row.y + 3, color: active ? :foreground : :muted, size: 12)
          if (change = status[path])
            text(change.strip, bounds.right - 30, row.y + 3, color: change.include?("D") ? :error : :accent, size: 11)
          end
          region(row, role: :treeitem, label: path, action: [entry.directory ? :directory : :file, path])
        end
      end
      fill(Zaniah::Bounds.new(bounds.right - 1, 0, 1, bounds.height), :border)
    end
    def paint_panels(side, bounds)
      fill(bounds, :panel)
      panels = @workspace.panels.select { |_, (position, _)| position == side }.to_a
      return if panels.empty?
      panels.each_with_index do |(name, (_, render)), index|
        height = bounds.height / panels.length
        area = Zaniah::Bounds.new(bounds.x + 8, bounds.y + height * index, [bounds.width - 16, 0].max, height)
        text(name, area.x + 4, area.y + 10, color: :muted, size: 12)
        key = [name, @workspace.editor&.buffer&.object_id, @workspace.editor&.buffer&.version, @theme.object_id]
        @panel_cache ||= {}
        @panel_cache.clear if @panel_cache.length > 50
        element = @panel_cache[key] ||= render.call
        element = Zaniah::Text.new(element.to_s, color: @theme[:foreground]) unless element.is_a?(Zaniah::Element)
        root = element.request_layout(@cx)
        Zaniah::Layout::Engine.new.compute(root, x: area.x, y: area.y + 34, width: area.width, height: [area.height - 34, 0].max)
        @scene.clip(area) do
          element.prepaint(root.bounds, nil, @cx)
          element.paint(root.bounds, nil, nil, @cx)
        end
      rescue StandardError => error
        text(error.message, area.x, area.y + 34, color: :error, size: 12)
      end
    end
    def paint_layout(node, bounds)
      return paint_pane(node[:pane], bounds) if node[:pane]
      horizontal = node[:direction] == :horizontal
      ratio = node.fetch(:ratio, 0.5)
      node[:children].each_with_index do |child, index|
        start, fraction = index.zero? ? [0, ratio] : [ratio, 1 - ratio]
        part = if horizontal
          Zaniah::Bounds.new(bounds.x + bounds.width * start, bounds.y, bounds.width * fraction, bounds.height)
        else
          Zaniah::Bounds.new(bounds.x, bounds.y + bounds.height * start, bounds.width, bounds.height * fraction)
        end
        paint_layout(child, part)
      end
      divider = horizontal ? Zaniah::Bounds.new(bounds.x + bounds.width * ratio - 2, bounds.y, 4, bounds.height) : Zaniah::Bounds.new(bounds.x, bounds.y + bounds.height * ratio - 2, bounds.width, 4)
      fill(divider, :border)
      region(divider, role: :separator, label: "Resize split", action: [:split_resize, node, bounds])
    end
    def paint_pane(pane, bounds)
      region(bounds, role: :group, label: "Pane", action: [:pane, pane])
      fill(Zaniah::Bounds.new(bounds.x, bounds.y, bounds.width, 34), :panel)
      @scene.clip(bounds) do
        x = bounds.x
        pane.editors.each do |editor|
          name = editor.buffer.path ? File.basename(editor.buffer.path) : "Untitled"
          name += " *" if editor.buffer.dirty?
          name = "[#{name}]" if pane.pinned.include?(editor)
          width = [[name.length * 7.5 + 30, 100].max, 240].min
          tab = Zaniah::Bounds.new(x, bounds.y, width, 34)
          fill(tab, :active_tab) if pane.active.equal?(editor)
          if pane.active.equal?(editor) && pane == @workspace.active_pane
            fill(Zaniah::Bounds.new(x, bounds.y, width, 2), :accent)
          end
          text(name, x + 14, bounds.y + 10, color: pane.active.equal?(editor) ? :foreground : :muted, size: 12)
          region(tab, role: :tab, label: name, action: [:tab, pane, editor])
          close = Zaniah::Bounds.new(tab.right - 26, tab.y, 26, tab.height)
          text(editor.buffer.dirty? ? "●" : "×", close.x + 6, close.y + 9, color: :muted, size: 12)
          region(close, role: :button, label: "Close #{name}", action: [:tab_close, pane, editor])
          x += width
        end
      end
      editor = pane.active
      unless editor
        text("Open a file or create a new one", bounds.x + 24, bounds.y + 58, color: :muted, size: 14)
        text("Cmd/Ctrl+P  Open    Cmd/Ctrl+N  New", bounds.x + 24, bounds.y + 84, color: :muted, size: 11)
        fill(Zaniah::Bounds.new(bounds.right - 1, bounds.y, 1, bounds.height), :border)
        return
      end
      area = Zaniah::Bounds.new(bounds.x, bounds.y + 34, bounds.width, [bounds.height - 34, 0].max)
      @editor_bounds[editor] = area
      region(area, role: :textbox, label: editor.buffer.path || "Untitled document", action: [:editor, pane, editor])
      paint_editor(editor, area, pane == @workspace.active_pane)
      fill(Zaniah::Bounds.new(bounds.right - 1, bounds.y, 1, bounds.height), :border)
    end
    def gutter(editor) = [editor.buffer.line_count.to_s.length * @font_size * 0.6 + 24, 52].max
    def paint_editor(editor, bounds, active)
      @selection_spans = {}
      editor.viewport_rows = [(bounds.height / @line_height).floor, 1].max
      map, first = editor.display_map, editor.scroll_y.floor
      last = [first + editor.viewport_rows + 1, map.row_count].min
      hunks = @workspace.git_hunks(editor.buffer)
      cursor_offset = @workspace.settings["vim_mode"] && active ? @workspace.vim.cursor_position : editor.primary.head
      cursor = map.to_display(cursor_offset)
      if map.wrap_map.width && !editor.buffer.read_only
        width = [bounds.width - gutter(editor) - 16, 1].max
        if @cx.window.is_a?(Zaniah::Platform::TUI::Window)
          map.wrap_width = [(width / 8).floor, 1].max
        elsif (system = @cx.text_system)
          begin
            map.wrap_pixels(width, typesetter: system, font_size: @font_size)
          rescue Zaniah::TextSystem::Typesetter::CopyError => error
            map.wrap_width = nil
            @workspace.message = "Soft wrap disabled: #{error.message}"
          end
        end
        last = [first + editor.viewport_rows + 1, map.row_count].min
        cursor = map.to_display(cursor_offset)
      end
      cursor_row = map.row(cursor.row)
      cursor_line = @cx.text_system&.layout_line(cursor_row.text, size: @font_size)
      brackets = []
      if active && editor.buffer.rope.bytesize <= 1 << 20 && !editor.buffer.read_only
        column = cursor.column
        column -= 1 unless "()[]{}".include?(cursor_row.text[column].to_s) && !cursor_row.text[column].to_s.empty?
        if column >= 0 && (character = cursor_row.text[column]) && "()[]{}".include?(character)
          range = editor.language_document.bracket_at(map.to_buffer(DisplayPoint.new(cursor.row, column)))
          brackets = [map.to_display(range.begin), map.to_display(range.end - 1)] if range
        end
      end
      reveal_key = [cursor_offset, editor.buffer.version, bounds.width]
      if active && @revealed_cursors[editor] != reveal_key
        x = column_x(cursor_row.text, cursor_line, cursor.column)
        visible_width = [bounds.width - gutter(editor) - 18, 1].max
        editor.scroll(dx: x < editor.scroll_x ? x - editor.scroll_x : [x - editor.scroll_x - visible_width, 0].max)
        @revealed_cursors[editor] = reveal_key
      end
      left = bounds.x + gutter(editor) - editor.scroll_x
      measured_width = cursor_line&.width || cursor_row.text.length * @font_size * 0.6
      @scene.clip(bounds) do
        (first...last).each do |index|
          row = map.row(index)
          y = bounds.y + (index - editor.scroll_y) * @line_height + 4
          fill(Zaniah::Bounds.new(bounds.x, y - 2, bounds.width, @line_height), :current_line) if cursor.row == index
          source_row = map.source_row(index)
          change = hunks.find { |hunk| (source_row + 1).between?([hunk.new_start, 1].max, [hunk.new_start + hunk.new_count - 1, hunk.new_start].max) }
          if change
            color = change.new_count.zero? ? @theme[:error] : change.old_count.zero? ? "#80b987" : @theme[:accent]
            fill(Zaniah::Bounds.new(bounds.x + 2, y - 1, 3, @line_height), color)
            region(Zaniah::Bounds.new(bounds.x, y - 1, 10, @line_height), role: :button, label: "Toggle Git hunk", action: [:git_hunk, editor, source_row]) if row.kind == :text
          end
          number = editor.relative_line_numbers ? (source_row - editor.buffer.rope.point_at(editor.primary.head).row).abs : source_row + 1
          number = source_row + 1 if number.zero?
          text(number, bounds.x + 12, y, color: cursor.row == index ? :foreground : :muted, size: @font_size - 1) if row.kind == :text
          line = @cx.text_system&.layout_line(row.text, size: @font_size)
          measured_width = [measured_width, line&.width || row.text.length * @font_size * 0.6].max
          @row_layouts[[editor, index]] = line
          paint_selections(editor, index, row, line, left, y)
          brackets.each do |point|
            next unless point.row == index
            x = column_x(row.text, line, point.column)
            width = [column_x(row.text, line, point.column + 1) - x, 4].max
            fill(Zaniah::Bounds.new(left + x, y + @line_height - 2, width, 2), :accent)
          end
          if row.kind == :text && line
            spans = code_spans(editor, source_row, row)
            @cx.text_system.paint_line(@scene, line, x: left, y: y + line.ascent, color: @theme[:foreground], spans: spans)
            @cx.window.text_runs << [left, y, row.text, @theme[:foreground]]
          else
            color = if row.kind == :git_diff
              row.text.start_with?("+") ? "#80b987" : row.text.start_with?("-") ? :error : :muted
            else
              row.kind == :text ? :foreground : :error
            end
            text(row.text, left, y, color: color)
          end
          paint_diagnostics(editor, index, row, line, left, y) if row.kind == :text
          if cursor.row == index && active
            x = left + column_x(row.text, line, cursor.column)
            width = @workspace.settings["vim_mode"] && @workspace.vim.mode != :insert ? @font_size * 0.6 : 1.5
            fill(Zaniah::Bounds.new(x, y, width, @line_height - 2), width > 2 ? "#e9a66177" : :cursor) if @cursor_visible || editor.composition
            @cx.window.ime_state = Zaniah::Bounds.new(x, y, 2, @line_height)
            if editor.composition && !editor.composition.text.empty?
              composition = text(editor.composition.text, x, y, color: :accent)
              fill(Zaniah::Bounds.new(x, y + @line_height - 2, composition&.width || 20, 1), :accent)
            end
          end
        end
      end
      previous_width = @line_widths[editor]
      measured_width = [measured_width, previous_width.last].max if previous_width && previous_width.first == editor.buffer.version
      @line_widths[editor] = [editor.buffer.version, measured_width]
      paint_scrollbars(editor, bounds, measured_width, hunks)
    end
    def paint_scrollbars(editor, bounds, content_width, hunks)
      track = Zaniah::Bounds.new(bounds.right - 9, bounds.y, 9, [bounds.height - 9, 0].max)
      total = editor.display_map.row_count
      maximum = [total - editor.viewport_rows, 0].max
      if maximum.positive? && track.height.positive?
        height = [24, track.height * editor.viewport_rows / total].max.clamp(0, track.height)
        thumb = Zaniah::Bounds.new(track.x + 2, track.y + (track.height - height) * editor.scroll_y / maximum, 5, height)
        fill(thumb, :muted)
        hunks.first(500).each do |hunk|
          y = track.y + track.height * [hunk.new_start - 1, 0].max / [editor.buffer.line_count, 1].max
          fill(Zaniah::Bounds.new(track.x, y, 3, 2), :accent)
        end
        frame_diagnostics(editor.buffer).first(500).each do |diagnostic|
          row = diagnostic.dig("range", "start", "line")
          next unless row.is_a?(Integer) && row >= 0
          y = track.y + track.height * row / [editor.buffer.line_count, 1].max
          fill(Zaniah::Bounds.new(track.x + 5, y, 4, 2), :error)
        end
        region(track, role: :scrollbar, label: "Vertical scroll", action: [:scrollbar, editor, :vertical, track, thumb, maximum])
      end
      track = Zaniah::Bounds.new(bounds.x + gutter(editor), bounds.bottom - 9, [bounds.width - gutter(editor) - 9, 0].max, 9)
      maximum = [content_width - track.width + 12, 0].max
      if maximum.positive? && track.width.positive?
        width = [24, track.width * track.width / (content_width + 12)].max.clamp(0, track.width)
        thumb = Zaniah::Bounds.new(track.x + (track.width - width) * [editor.scroll_x / maximum, 1].min, track.y + 2, width, 5)
        fill(thumb, :muted)
        region(track, role: :scrollbar, label: "Horizontal scroll", action: [:scrollbar, editor, :horizontal, track, thumb, maximum])
      end
    end
    def column_x(value, line, column)
      line ? line.x_for_index(value[0, column].to_s.bytesize) : column * @font_size * 0.6
    end
    def code_spans(editor, source_row, row)
      return [] if editor.buffer.rope.respond_to?(:lazy?) && editor.buffer.rope.lazy?
      raw = editor.language_document.tokens_for(source_row)
      semantic_state = @workspace.semantic_styles&.[](editor.buffer)
      semantic_state = nil unless semantic_state && semantic_state.first == editor.buffer.version
      cache = @code_caches[editor] ||= {}
      cached = cache[row.object_id]
      return cached[3] if cached && cached[4].equal?(row) && cached[0] == raw && cached[1].equal?(@theme) && cached[2].equal?(semantic_state)
      offset = 0
      tokens = raw.map do |token, value|
        start = offset
        offset += value.bytesize
        [start, offset, @theme.token_color(token)]
      end
      spans, index, byte = [], 0, 0
      semantic = @workspace.semantic_spans_for(editor.buffer, source_row)
      row.text.each_codepoint.with_index do |character, column|
        length = character < 0x80 ? 1 : character < 0x800 ? 2 : character < 0x10000 ? 3 : 4
        original = row.offsets[column]
        index += 1 while index < tokens.length && original >= tokens[index][1]
        color = tokens[index] && original >= tokens[index][0] ? tokens[index][2] : @theme[:foreground]
        overlay = semantic.find { |first, last, _| original >= first && original < last }
        color = overlay[2] if overlay
        if spans.last && spans.last[2] == color
          spans.last[1] += length
        else
          spans << [byte, byte + length, color]
        end
        byte += length
      end
      cache.shift if cache.length >= 512
      spans.each(&:freeze).freeze
      cache[row.object_id] = [raw, @theme, semantic_state, spans, row]
      spans
    end
    def paint_diagnostics(editor, index, row, line, left, y)
      frame_diagnostics(editor.buffer).each do |diagnostic|
        range = diagnostic["range"]
        first = editor.display_map.to_display(LSP::Protocol.offset(editor.buffer.rope, range.fetch("start")))
        last = editor.display_map.to_display(LSP::Protocol.offset(editor.buffer.rope, range.fetch("end")))
        next unless index.between?(first.row, last.row)
        from = index == first.row ? first.column : 0
        to = index == last.row ? last.column : row.text.length
        x = column_x(row.text, line, from)
        width = [column_x(row.text, line, to) - x, 6].max
        @scene.underline(left + x, y + @line_height - 2, width, color: @theme[:error], wave: true)
      rescue RangeError, KeyError
        next # Stale server positions must not break a frame after a local edit.
      end
    end
    def frame_diagnostics(buffer)
      @frame_diagnostics[buffer] ||= @workspace.diagnostics_for(buffer)
    end
    def paint_selections(editor, index, row, line, left, y)
      editor.selections.each do |selection|
        next if selection.empty?
        if editor.buffer.rope.respond_to?(:lazy?)
          base = editor.buffer.rope.line_start(index)
          first = selection.start - base
          last = selection.end - base
          next if last < row.offsets.first || first > row.offsets.last
          from = row.offsets.bsearch_index { |offset| offset >= first } || row.text.length
          to = row.offsets.bsearch_index { |offset| offset >= last } || row.text.length
          x = column_x(row.text, line, from)
          fill(Zaniah::Bounds.new(left + x, y - 1, column_x(row.text, line, to) - x, @line_height), :selection)
          next
        end
        span = selection_span(editor, selection, index)
        next unless span
        before = selection_span(editor, selection, index - 1)
        after = selection_span(editor, selection, index + 1)
        x, right = span
        # Only exposed convex corners are rounded; no alpha-overlapping bridge
        # and no convex hull that would highlight unselected source text.
        radii = [before && x >= before[0] && x < before[1] ? 0 : 3,
          before && right > before[0] && right <= before[1] ? 0 : 3,
          after && right > after[0] && right <= after[1] ? 0 : 3,
          after && x >= after[0] && x < after[1] ? 0 : 3]
        @scene.quad(left + x, y - 1, right - x, @line_height, color: @theme[:selection], radius: radii)
      end
    end
    def selection_span(editor, selection, index)
      cache = @selection_spans[selection] ||= {first: editor.display_map.to_display(selection.start), last: editor.display_map.to_display(selection.end)}
      return cache[index] if cache.key?(index)
      first, last = cache.values_at(:first, :last)
      return unless index.between?(first.row, last.row)
      row = editor.display_map.row(index)
      return unless row.kind == :text
      line = @cx.text_system&.layout_line(row.text, size: @font_size)
      from = index == first.row ? first.column : 0
      to = index == last.row ? last.column : row.text.length + 1
      x = column_x(row.text, line, from)
      right = column_x(row.text, line, [to, row.text.length].min)
      right += @font_size * 0.6 if to > row.text.length
      cache[index] = right > x ? [x, right] : nil
    end
    def paint_terminal(bounds)
      render_terminal(bounds)
    end
    def paint_status(bounds)
      fill(bounds, :status)
      editor = @workspace.editor
      return unless editor
      point = editor.buffer.rope.point_at(editor.primary.head)
      mode = @workspace.settings["vim_mode"] ? @workspace.vim.mode.to_s : "edit"
      left = "#{mode}    #{@workspace.message}"
      branch = @workspace.git&.branch
      left = "#{branch}    #{left}" if branch
      left = ":#{@workspace.vim.command_line}" if @workspace.settings["vim_mode"] && @workspace.vim.command_line
      diagnostics = frame_diagnostics(editor.buffer).length
      language = editor.language_document.definition.name
      lsp = @workspace.clients[language]
      right = "#{diagnostics.zero? ? '' : "!#{diagnostics}  "}#{language}#{lsp ? " LSP:#{lsp.state}" : ''}   #{point.row + 1}:#{point.column + 1}   #{editor.use_tabs ? 'Tab' : 'Spaces'}:#{editor.tab_size}   #{editor.buffer.encoding.name}"
      @scene.clip(bounds) do
        text(left, 12, bounds.y + 6, color: :foreground, size: 12)
        text(right, [bounds.width - right.length * 7.2 - 16, bounds.width * 0.5].max, bounds.y + 6, color: :muted, size: 12)
      end
    end
    def paint_hover(bounds)
      require_relative "../markdown"
      source = @workspace.hover_card
      if @hover_source != source || @hover_markup != @workspace.hover_markup
        @hover_document = Markdown.new(source, markup: @workspace.hover_markup != false)
        @hover_source = source.dup.freeze
        @hover_markup = @workspace.hover_markup
      end
      lines = @hover_document.rows
      width = [[lines.map { |row| row.sum { |run| Unicode::DisplayWidth.of(run.text, emoji: :rgi) } }.max.to_i * 7.8 + 24, 180].max, bounds.width - 32].min
      box = Zaniah::Bounds.new([bounds.width - width - 24, 8].max, 64, width, lines.length * 20 + 20)
      fill(box, :panel)
      @scene.quad(box.x, box.y, box.width, box.height, color: "#0000", radius: 5, border_width: 1, border_color: @theme[:border])
      @scene.clip(box) do
        lines.each_with_index do |runs, index|
          x, y = box.x + 12, box.y + 10 + index * 20
          runs.each do |run|
            color = case run.style
            when :heading, :link then :accent
            when :quote then :muted
            when :code then @theme.token_color("Literal.String")
            when String then @theme.token_color(run.style)
            else :foreground
            end
            system = @cx.text_system
            font = if system.respond_to?(:font_db) && [:heading, :strong, :emphasis].include?(run.style)
              system.font_db.find(family: @workspace.settings["font_family"], weight: run.style == :emphasis ? 400 : 700, style: run.style == :emphasis ? :italic : :normal)
            end
            layout = text(run.text, x, y, color: color, size: 13, font: font)
            run_width = layout&.width || Unicode::DisplayWidth.of(run.text, emoji: :rgi) * 8
            if run.style == :link && run.url&.match?(/\Ahttps?:\/\//i)
              region(Zaniah::Bounds.new(x, y, run_width, 20), role: :link, label: run.text, action: [:hover_link, run.url])
            end
            x += run_width
          end
        end
      end
    end
    def confirmation_width(value, size = 11)
      @cx.text_system&.layout_line(value, size: size)&.width || Unicode::DisplayWidth.of(value, emoji: :rgi) * 8
    end
    def confirmation_lines(value, width)
      lines, line = [], +""
      value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).scrub.each_grapheme_cluster do |grapheme|
        # Show control characters and over-wide graphemes as readable escapes;
        # never silently clip part of a target filename.
        escaped = grapheme.match?(/[\x00-\x1f\x7f]/) || confirmation_width(grapheme) > width
        pieces = escaped ? grapheme.codepoints.map { |point| "\\u{#{point.to_s(16)}}" }.join.each_char : [grapheme]
        pieces.each do |piece|
          if !line.empty? && confirmation_width(line + piece) > width
            lines << line
            line = +""
          end
          line << piece
        end
      end
      lines << line unless line.empty?
      lines
    end
    def paint_workspace_edit(bounds, palette)
      require "unicode/display_width"
      compact = bounds.width < 360 || bounds.height < 240
      margin, padding = compact ? [4, 4] : [16, 12]
      width = [bounds.width - margin * 2, 600].min
      inner_width = width - padding * 2
      sources = [palette[:query], *palette.fetch(:details, [])]
      cache_key = [inner_width, @cx.text_system, sources]
      if palette[:detail_wrap_key] != cache_key
        palette[:detail_lines] = sources.flat_map { |source| confirmation_lines(source, inner_width) }
        palette[:detail_lines] = [""] if palette[:detail_lines].empty?
        palette[:detail_wrap_key] = [inner_width, @cx.text_system, sources.map(&:dup)]
      end
      lines = palette[:detail_lines]
      rows = [lines.length, 8, [((bounds.height - margin * 2 - padding * 2 - 62) / 18).floor, 1].max].min
      palette[:detail_rows] = rows
      palette[:details_scroll] = palette.fetch(:details_scroll, 0).clamp(0, [lines.length - rows, 0].max)
      start = palette[:details_scroll]
      box = Zaniah::Bounds.new((bounds.width - width) / 2, margin, width, padding * 2 + 62 + rows * 18)
      fill(bounds, "#0007")
      @scene.quad(box.x, box.y, box.width, box.height, color: @theme[:panel], radius: 5, border_width: 1, border_color: @theme[:border])
      @scene.clip(box) do
        heading = compact ? "#{start + 1}/#{lines.length}" : "#{start + 1}–#{start + rows} / #{lines.length}   PageUp / PageDown"
        text(heading, box.x + padding, box.y + padding, color: :muted, size: 11)
        visible = lines.slice(start, rows)
        visible.each_with_index { |value, index| text(value, box.x + padding, box.y + padding + 18 + index * 18, size: 11) }
        @accessibility << {role: :text, label: visible.join("\n"), bounds: box}
        palette[:matches].each_with_index do |match, index|
          row = Zaniah::Bounds.new(box.x + padding, box.y + padding + 18 + rows * 18 + index * 22, inner_width, 22)
          fill(row, :active_tab) if index == palette[:index]
          label = compact ? ["Apply", "Cancel"].fetch(index) : match
          @scene.clip(row) { text(label, row.x + 2, row.y + 2, size: 11) }
          region(row, role: :option, label: match, action: [:palette, index])
        end
      end
    end
    def shortcut_labels
      return {} unless @keymap
      context = {"Editor" => !!@workspace.editor,
        "vim_mode" => @workspace.settings["vim_mode"] && @workspace.editor ? @workspace.vim.mode.to_s : false}
      seen, labels = {}, {}
      @keymap.bindings.reverse_each do |binding|
        next unless binding.predicate.call(context)
        next if seen.keys.any? { |keys| keys.first(binding.keys.length) == binding.keys || binding.keys.first(keys.length) == keys }
        seen[binding.keys] = true
        next if !RUBY_PLATFORM.include?("darwin") && binding.keys.any? { |key| key.split("-").include?("cmd") }
        labels[binding.action] ||= binding.keys.join("  ") if binding.action
      end
      labels
    end
    def paint_palette(bounds)
      palette = @workspace.palette
      return paint_workspace_edit(bounds, palette) if palette[:kind] == :workspace_edit
      matches = palette[:matches]
      shortcuts = palette[:kind] == :commands ? shortcut_labels : {}
      preview = palette[:kind] == :files && matches[palette[:index]] && bounds.width >= 850
      width = [bounds.width - 32, preview ? 900 : 600].min
      height = [90 + matches.length * 28, preview ? 330 : 0].max
      box = Zaniah::Bounds.new((bounds.width - width) / 2, [50, bounds.height * 0.1].min, width, [height, bounds.height - 80].min)
      list_width = preview ? width * 0.52 : width
      fill(bounds, "#0007")
      @scene.shadow(box.x, box.y, box.width, box.height, color: "#0008", blur: 14)
      @scene.quad(box.x, box.y, box.width, box.height, color: @theme[:panel], radius: 8, border_width: 1, border_color: @theme[:border])
      labels = {commands: "Command palette", files: "Open file", search: "Find in buffer", save_as: "Save as", confirm_close: "Unsaved changes"}
      title = labels.fetch(palette[:kind], palette[:kind].to_s)
      if palette[:search_options]
        title += "  Ctrl+Alt " + {regexp: "R:regex", case_sensitive: "C:case", whole_word: "W:word", selection_only: "S:selection"}.filter_map do |key, label|
          "#{label}=#{palette[:search_options][key] ? 'on' : 'off'}" unless key == :selection_only && palette[:kind] == :project_search
        end.join(" ")
      end
      @scene.clip(box) { text(title, box.x + 16, box.y + 12, color: :muted, size: palette[:search_options] ? 10 : 12) }
      text(palette[:query].empty? ? "Type here…" : palette[:query], box.x + 16, box.y + 36, color: palette[:query].empty? ? :muted : :foreground)
      @scene.clip(box) do
        matches.each_with_index do |match, index|
          row = Zaniah::Bounds.new(box.x + 6, box.y + 74 + index * 28, list_width - 12, 28)
          fill(row, :active_tab) if index == palette[:index]
          @scene.clip(row) { text(match, row.x + 10, row.y + 5, size: 13) }
          if palette[:kind] == :commands
            shortcut = shortcuts[match]
            if shortcut
              label = shortcut.tr("-", " ")
              x = row.right - label.length * 6.5 - 10
              fill(Zaniah::Bounds.new(x - 4, row.y + 2, row.right - x, 24), index == palette[:index] ? :active_tab : :panel)
              text(label, x, row.y + 6, color: :muted, size: 11)
            end
          end
          region(row, role: :option, label: match, action: [:palette, index])
        end
        if preview
          area = Zaniah::Bounds.new(box.x + list_width, box.y + 74, width - list_width, box.height - 80)
          fill(Zaniah::Bounds.new(area.x, area.y, 1, area.height), :border)
          @scene.clip(area) do
            @workspace.file_preview(matches[palette[:index]]).first((area.height / 18).floor).each_with_index do |line, index|
              text("#{index + 1}  #{line}", area.x + 12, area.y + index * 18, color: :muted, size: 11)
            end
          end
        end
      end
    end
  end
end

require_relative "view/terminal_presentable"
Canopus::Workspace::View.include Canopus::Workspace::View::TerminalPresentable

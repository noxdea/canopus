# frozen_string_literal: true

module Canopus
  # A viewport is one element; only visible document rows become draw commands.
  class Workspace::View < Zaniah::Element
    attr_reader :editor_bounds, :minimap_bounds, :row_layouts, :regions, :accessibility
    attr_accessor :keymap
    def initialize(workspace)
      super()
      @workspace = workspace
      @editor_bounds, @minimap_bounds, @row_layouts, @regions, @accessibility = {}, {}, {}, [], []
      @project_scroll = 0
      reset_blink
      @revealed_cursors, @line_widths, @code_caches = {}, {}, {}
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
      @children.clear
      @viewport_bounds = bounds
      @painted_palette = @workspace.palette
      @font_size = @workspace.settings["font_size"]
      @line_height = (@font_size * 1.55).ceil
      @line_height = 20 if @cx.window.is_a?(Zaniah::Platform::TUI::Window)
      @frame_id = @frame_id.to_i + 1
      @workspace.minimap.begin_frame(@frame_id, text_system: @cx.text_system, font_size: @font_size,
        font_family: @workspace.settings["font_family"], scale_factor: @cx.window.scale_factor)
      @regions.clear
      @row_layouts.clear
      @overlay_rows = []
      @editor_bounds.clear
      @minimap_bounds.clear
      @accessibility.clear
      visible_editors = @workspace.panes.map(&:active)
      @revealed_cursors.delete_if { |editor, _| !visible_editors.include?(editor) }
      @line_widths.delete_if { |editor, _| !visible_editors.include?(editor) }
      @code_caches.delete_if { |editor, _| !visible_editors.include?(editor) }
      fill(bounds, :background)
      left_panels = drawable_panels(:left)
      bottom_panels = drawable_panels(:bottom)
      bottom_visible = @workspace.docks[:bottom][:visible] && (@workspace.terminal_visible || !bottom_panels.empty?)
      bottom = bottom_visible ? [bounds.height * 0.7, @workspace.docks[:bottom][:size]].min : 0
      left_visible = @workspace.docks[:left][:visible] && (@workspace.show_project || !left_panels.empty?)
      sidebar = left_visible && bounds.width >= 620 ? [@workspace.docks[:left][:size], bounds.width * 0.4].min : 0
      right = @workspace.docks[:right][:visible] && !drawable_panels(:right).empty? && bounds.width >= 620 ? [@workspace.docks[:right][:size], bounds.width * 0.4].min : 0
      body = Zaniah::Bounds.new(sidebar, 0, bounds.width - sidebar - right, [bounds.height - 26 - bottom, 0].max)
      if sidebar.positive?
        project_height = if @workspace.show_project
          left_panels.empty? ? bounds.height - 26 : (bounds.height - 26) * 0.6
        else 0
        end
        paint_project(Zaniah::Bounds.new(0, 0, sidebar, project_height)) if project_height.positive?
        paint_panels(:left, Zaniah::Bounds.new(0, project_height, sidebar, bounds.height - 26 - project_height)) unless left_panels.empty?
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
    def minimap_scroll(editor, point)
      entry = @minimap_bounds[editor]
      return false unless entry && @workspace.panes.include?(entry[:pane]) && entry[:pane].active.equal?(editor)

      bounds = entry[:bounds]
      fraction = ((point.y - bounds.y).to_f / [bounds.height, 1].max).clamp(0, 1)
      source_row = (fraction * editor.buffer.line_count).floor.clamp(0, editor.buffer.line_count - 1)
      display_row = editor.display_map.to_display(editor.buffer.rope.line_start(source_row)).row
      target = (display_row - editor.viewport_rows / 2.0).clamp(0, [editor.display_map.row_count - editor.viewport_rows, 0].max)
      editor.scroll(dy: target - editor.scroll_y)
      true
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
      panels = drawable_panels(side)
      return if panels.empty?
      panels.each_with_index do |definition, index|
        height = bounds.height / panels.length
        area = Zaniah::Bounds.new(bounds.x + 8, bounds.y + height * index, [bounds.width - 16, 0].max, height)
        text(definition.title, area.x + 4, area.y + 10, color: :muted, size: 12)
        if definition.badge
          badge = Zaniah::Text.new(ui_text(definition.badge), size: 11, color: @theme[:accent])
            .w(36).h(22).test_id("syrma:panel:#{instrumentation_component(definition.id)}:badge")
          paint_element(badge, Zaniah::Bounds.new(area.right - 40, area.y + 5, 36, 22))
        end
        key = [definition.id, @workspace.editor&.buffer&.object_id, @workspace.editor&.buffer&.version, @theme.object_id]
        @panel_cache ||= {}
        @panel_cache.clear if @panel_cache.length > 50
        element = @panel_cache[key] ||= definition.build.call
        element = Zaniah::Text.new(ui_text(element), color: @theme[:foreground]) unless element.is_a?(Zaniah::Element)
        panel = Zaniah::Div.new.w(area.width).h([area.height - 34, 0].max)
          .test_id("syrma:panel:#{instrumentation_component(definition.id)}").child(element)
        @scene.clip(area) do
          paint_element(panel, Zaniah::Bounds.new(area.x, area.y + 34, area.width, [area.height - 34, 0].max))
        end
      rescue StandardError => error
        text(error.message, area.x, area.y + 34, color: :error, size: 12)
      end
    end
    def drawable_panels(side)
      @workspace.panels.active(side).reject { |definition| %w[terminal explorer search].include?(definition.id) }
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
      minimap = @workspace.minimap_settings(editor)
      minimap_width = if minimap["enabled"] && !@cx.window.is_a?(Zaniah::Platform::TUI::Window) &&
          area.height.positive? && area.width >= minimap["width"] + gutter(editor) + 80
        minimap["width"]
      else 0
      end
      editor_area = Zaniah::Bounds.new(area.x, area.y, area.width - minimap_width, area.height)
      minimap_area = Zaniah::Bounds.new(editor_area.right, area.y, minimap_width, area.height)
      breadcrumbs = @workspace.breadcrumb_context(editor)
      breadcrumb_height = breadcrumbs && editor_area.height >= @line_height * 2 ? @line_height : 0
      content = Zaniah::Bounds.new(editor_area.x, editor_area.y + breadcrumb_height, editor_area.width,
        [editor_area.height - breadcrumb_height, 0].max)
      decorations = prepare_editor_map(editor, content)
      sticky = prepare_sticky_scroll(editor, content)
      sticky_height = sticky.length * @line_height
      body = Zaniah::Bounds.new(content.x, content.y + sticky_height, content.width,
        [content.height - sticky_height, 0].max)
      @editor_bounds[editor] = body
      region(body, role: :textbox, label: editor.buffer.path || "Untitled document", action: [:editor, pane, editor])
      overview = paint_editor(editor, body, pane == @workspace.active_pane, decorations)
      paint_sticky_scroll(editor, pane,
        Zaniah::Bounds.new(content.x, content.y, content.width, sticky_height), sticky) unless sticky.empty?
      paint_breadcrumbs(editor, pane,
        Zaniah::Bounds.new(editor_area.x, editor_area.y, editor_area.width, breadcrumb_height), breadcrumbs) if breadcrumb_height.positive?
      paint_minimap(editor, pane, minimap_area, overview, minimap) if minimap_width.positive?
      fill(Zaniah::Bounds.new(bounds.right - 1, bounds.y, 1, bounds.height), :border)
    end
    def gutter(editor) = [editor.buffer.line_count.to_s.length * @font_size * 0.6 + 24, 52].max
    def prepare_editor_map(editor, bounds)
      map = editor.display_map
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
      end
      prepare_editor_decorations(editor, bounds)
    end
    def prepare_editor_decorations(editor, bounds)
      map = editor.display_map
      rows = [(bounds.height / @line_height).floor, 1].max
      first = editor.scroll_y.clamp(0, [map.row_count - rows, 0].max).floor
      last = [first + rows + 1, map.row_count].min
      decorations = decorations_for_display_rows(editor, map, first, last)
      overlays = decorations.select { |item| %i[inline block].include?(item.kind) }
      if map.set_overlays(overlays, font: @cx.text_system.respond_to?(:font) ? @cx.text_system.font : nil,
        font_size: @font_size, line_height: @line_height)
        first = editor.scroll_y.clamp(0, [map.row_count - rows, 0].max).floor
        last = [first + rows + 1, map.row_count].min
        decorations = (decorations + decorations_for_display_rows(editor, map, first, last)).uniq.sort_by(&:priority).freeze
        overlays = decorations.select { |item| %i[inline block].include?(item.kind) }
        map.set_overlays(overlays, font: @cx.text_system.respond_to?(:font) ? @cx.text_system.font : nil,
          font_size: @font_size, line_height: @line_height)
      end
      decorations
    end
    def prepare_sticky_scroll(editor, bounds)
      rows = [(bounds.height / @line_height).floor, 1].max
      sticky, scroll = [], editor.scroll_y
      loop do
        candidate = @workspace.sticky_context(editor, scroll.floor)
        candidate = candidate.last([[rows - 1, 0].max, candidate.length].min)
        viewport = [rows - candidate.length, 1].max
        clamped = scroll.clamp(0, [editor.display_map.row_count - viewport, 0].max)
        break sticky = candidate if candidate == sticky && clamped == scroll
        sticky, scroll = candidate, clamped
      end
      editor.viewport_rows = [rows - sticky.length, 1].max
      editor.scroll(dy: scroll - editor.scroll_y)
      sticky
    end
    def paint_editor(editor, bounds, active, decorations = nil)
      @selection_spans = {}
      editor.viewport_rows = [(bounds.height / @line_height).floor, 1].max
      editor.scroll
      map, first = editor.display_map, editor.scroll_y.floor
      last = [first + editor.viewport_rows + 1, map.row_count].min
      cursor_offset = @workspace.settings["vim_mode"] && active ? @workspace.vim.cursor_position : editor.primary.head
      cursor = map.to_display(cursor_offset)
      decorations ||= decorations_for_display_rows(editor, map, first, last)
      if map.set_overlays(decorations.select { |item| %i[inline block].include?(item.kind) },
        font: @cx.text_system.respond_to?(:font) ? @cx.text_system.font : nil,
        font_size: @font_size, line_height: @line_height)
        editor.scroll
        first = editor.scroll_y.floor
        last = [first + editor.viewport_rows + 1, map.row_count].min
        cursor = map.to_display(cursor_offset)
        decorations = (decorations + decorations_for_display_rows(editor, map, first, last)).uniq.sort_by(&:priority).freeze
      end
      gutter_items = decorations.select { |item| item.kind == :gutter }
      highlight_items = decorations.select { |item| item.kind == :highlight }
      line_items = decorations.select { |item| item.kind == :line }
      foreground_items, guide_items = highlight_items.partition do |item|
        item.style.is_a?(Hash) && item.style[:foreground]
      end
      guide_items, highlight_items = guide_items.partition do |item|
        item.style.is_a?(Hash) && item.style[:guide]
      end
      foreground_by_row = foreground_items.group_by { |item| map.to_display(item.range.begin).row }
      guides_by_row = guide_items.map { |item| [item, map.to_display(item.range.begin)] }
        .group_by { |_item, point| point.row }
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
          source_row = map.source_row(index)
          fill(Zaniah::Bounds.new(bounds.x, y - 2, bounds.width, @line_height), :current_line) if cursor.row == index
          paint_line_decorations(editor, source_row, y, bounds, line_items)
          gutter_items.each do |item|
            style = item.style.is_a?(Hash) ? item.style : {color: item.style, rows: 1}
            next unless source_row.between?(item.row, item.row + style.fetch(:rows, 1) - 1)

            marker = Zaniah::Bounds.new(bounds.x + 2, y - 1, 3, @line_height)
            paint_instrumented_fill(marker, style.fetch(:color, :accent),
              "syrma:decoration:gutter:#{source_row}:#{instrumentation_component(item.source)}")
            if row.kind == :text && item.on_click
              region(Zaniah::Bounds.new(bounds.x, y - 1, 10, @line_height), role: :button,
                label: item.content.to_s, action: [:decoration, item.on_click, editor, source_row])
            end
          end
          number = editor.relative_line_numbers ? (source_row - editor.buffer.rope.point_at(editor.primary.head).row).abs : source_row + 1
          number = source_row + 1 if number.zero?
          text(number, bounds.x + 12, y, color: cursor.row == index ? :foreground : :muted, size: @font_size - 1) if row.kind == :text
          line, paint_overlays = prepare_inline_overlays(editor, row, left, y,
            [bounds.width - gutter(editor), 1].max)
          line ||= @cx.text_system&.layout_line(row.text, size: @font_size)
          measured_width = [measured_width, line&.width || row.text.length * @font_size * 0.6].max
          @row_layouts[[editor, index]] = line
          paint_highlights(editor, index, row, line, left, y, highlight_items)
          brackets.each do |point|
            next unless point.row == index
            x = column_x(row.text, line, point.column)
            width = [column_x(row.text, line, point.column + 1) - x, 4].max
            fill(Zaniah::Bounds.new(left + x, y + @line_height - 2, width, 2), :accent)
          end
          if row.kind == :text && line && @cx.text_system
            spans = code_spans(editor, source_row, row, foreground_by_row[index] || [])
            @cx.text_system.paint_line(@scene, line, x: left, y: y + line.ascent, color: @theme[:foreground], spans: spans)
            @cx.window.text_runs << [left, y, row.text, @theme[:foreground]]
          elsif row.kind == :overlay_block
            paint_block_overlay(editor, row.metadata, left, y, [bounds.width - gutter(editor), 1].max) if row.metadata
          elsif row.kind != :overlay_block_continuation
            color = if row.kind == :git_diff
              row.text.start_with?("+") ? "#80b987" : row.text.start_with?("-") ? :error : :muted
            else
              row.kind == :text ? :foreground : :error
            end
            text(row.text, left, y, color: color)
          end
          paint_whitespace(editor, map, index, source_row, row, line, left, y, bounds) if row.kind == :text
          paint_overlays&.call
          paint_indent_guides(row, line, left, y, guides_by_row[index] || [])
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
      overview = @workspace.decorations.items_for(editor.buffer, 0...editor.buffer.line_count)
      paint_scrollbars(editor, bounds, measured_width, overview)
      overview
    end
    def paint_sticky_scroll(editor, pane, bounds, symbols)
      fill(bounds, :panel)
      left = bounds.x + gutter(editor) - editor.scroll_x
      generation = @workspace.document_symbol_generation(editor)
      @scene.clip(bounds) do
        symbols.each_with_index do |symbol, index|
          y = bounds.y + index * @line_height
          row = editor.buffer.rope.point_at(symbol.selection.begin).row
          text(row + 1, bounds.x + 12, y + 4, color: :muted, size: @font_size - 1)
          text(symbol.name, left, y + 4, color: :foreground)
          area = Zaniah::Bounds.new(bounds.x, y, bounds.width, @line_height)
          region(area, role: :button, label: "Go to #{symbol.name}",
            action: [:sticky, pane, editor, symbol.selection.begin, editor.buffer.version, generation])
        end
      end
      fill(Zaniah::Bounds.new(bounds.x, bounds.bottom - 1, bounds.width, 1), :border)
    end
    def paint_breadcrumbs(editor, pane, bounds, context)
      fill(bounds, :panel)
      items = context[:items].first(3)
      slot = bounds.width / items.length
      @scene.clip(bounds) do
        items.each_with_index do |item, index|
          area = Zaniah::Bounds.new(bounds.x + slot * index, bounds.y, slot, bounds.height)
          inset = index.zero? ? 8 : 20
          text("›", area.x + 5, area.y + 3, color: :muted, size: 12) unless index.zero?
          label = clip_breadcrumb(item[:label], [area.width - inset - 6, 0].max, 12)
          next if label.empty?

          text(label, area.x + inset, area.y + 3, color: :foreground, size: 12)
          region(area, role: :button, label: "Choose siblings for #{item[:label]}",
            action: [:breadcrumb, pane, editor, item, context])
        end
      end
      fill(Zaniah::Bounds.new(bounds.x, bounds.bottom - 1, bounds.width, 1), :border)
    end
    def paint_minimap(editor, pane, bounds, overview, settings)
      fill(bounds, :panel)
      @minimap_bounds[editor] = {pane: pane, bounds: bounds}.freeze
      rows = minimap_rows(editor.buffer.line_count, bounds.height)
      @scene.clip(bounds) do
        rows.each do |row|
          texture = @workspace.minimap.texture(editor.buffer, row, width: bounds.width.to_i)
          next unless texture

          y = bounds.y + bounds.height * row / [editor.buffer.line_count, 1].max
          @scene.sprite(bounds.x, y, bounds.width, 2, texture: texture, color: @theme[:muted])
        end
        paint_minimap_markers(editor, bounds, overview, settings)
        paint_minimap_viewport(editor, bounds)
      end
      region(bounds, role: :scrollbar, label: "Document minimap", action: [:minimap, pane, editor])
      fill(Zaniah::Bounds.new(bounds.x, bounds.y, 1, bounds.height), :border)
      @cx.window.request_frame if @workspace.minimap.pending?
    end
    def minimap_rows(line_count, height)
      count = [[(height / 2).floor, line_count, Minimap::ENTRY_LIMIT].min, 1].max
      return [0] if count == 1

      count.times.map { |index| index * (line_count - 1) / (count - 1) }.uniq
    end
    def paint_minimap_markers(editor, bounds, overview, settings)
      pixels = {}
      overview.each_with_index do |item, index|
        break if index >= 10_000
        if item.source == :git && item.row
          style = item.style.is_a?(Hash) ? item.style : {color: item.style, rows: 1}
          minimap_marker(pixels, bounds, editor.buffer.line_count, item.row, style.fetch(:rows, 1), style.fetch(:color, :accent))
        elsif settings["show_diagnostics"] && item.source == :diagnostics && item.range
          row = editor.buffer.rope.point_at(item.range.begin).row
          style = item.style.is_a?(Hash) ? item.style : {color: item.style}
          minimap_marker(pixels, bounds, editor.buffer.line_count, row, 1, style.fetch(:color, :error))
        end
      end
      @workspace.minimap.search_rows(editor.buffer, editor.buffer.version).each do |row|
        minimap_marker(pixels, bounds, editor.buffer.line_count, row, 1, :accent)
      end
      pixels.each { |y, color| fill(Zaniah::Bounds.new(bounds.right - 5, y, 5, 1), color) }
    end
    def minimap_marker(pixels, bounds, line_count, row, count, color)
      first = (bounds.y + bounds.height * row / [line_count, 1].max).floor
      last = (bounds.y + bounds.height * (row + count) / [line_count, 1].max).ceil - 1
      first.clamp(bounds.y.ceil, bounds.bottom.ceil - 1).upto(last.clamp(bounds.y.ceil, bounds.bottom.ceil - 1)) do |y|
        pixels[y] = color
      end
    end
    def paint_minimap_viewport(editor, bounds)
      map = editor.display_map
      first = editor.scroll_y.floor.clamp(0, map.row_count - 1)
      last = [first + editor.viewport_rows - 1, map.row_count - 1].min
      top = bounds.y + bounds.height * map.source_row(first) / [editor.buffer.line_count, 1].max
      bottom = bounds.y + bounds.height * (map.source_row(last) + 1) / [editor.buffer.line_count, 1].max
      height = [bottom - top, 8].max.clamp(0, bounds.bottom - top)
      @scene.quad(bounds.x, top, bounds.width, height, color: "#ffffff12", border_width: 1, border_color: @theme[:accent])
    end
    def clip_breadcrumb(value, maximum, size)
      source = value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).scrub
      return "" unless maximum.positive?

      layout = @cx.text_system&.layout_line(source, size: size)
      width = layout&.width || Zaniah::Unicode.width(source) * size * 0.6
      return source if width <= maximum

      ellipsis = "…"
      ellipsis_width = @cx.text_system&.layout_line(ellipsis, size: size)&.width || size * 0.6
      return "" if ellipsis_width > maximum

      shown = +""
      bytes = 0
      shown_width = 0
      source.each_grapheme_cluster do |grapheme|
        bytes += grapheme.bytesize
        grapheme_width = layout ? layout.x_for_index(bytes) : shown_width + Zaniah::Unicode.width(grapheme) * size * 0.6
        break if grapheme_width + ellipsis_width > maximum
        shown << grapheme
        shown_width = grapheme_width
      end
      shown << ellipsis
    end
    def paint_scrollbars(editor, bounds, content_width, decorations)
      track = Zaniah::Bounds.new(bounds.right - 9, bounds.y, 9, [bounds.height - 9, 0].max)
      total = editor.display_map.row_count
      maximum = [total - editor.viewport_rows, 0].max
      if maximum.positive? && track.height.positive?
        height = [24, track.height * editor.viewport_rows / total].max.clamp(0, track.height)
        thumb = Zaniah::Bounds.new(track.x + 2, track.y + (track.height - height) * editor.scroll_y / maximum, 5, height)
        fill(thumb, :muted)
        decorations.select { |item| item.kind == :gutter }.first(500).each do |item|
          y = track.y + track.height * item.row / [editor.buffer.line_count, 1].max
          fill(Zaniah::Bounds.new(track.x, y, 3, 2), :accent)
        end
        decorations.select { |item| item.source == :diagnostics && item.kind == :highlight }.first(500).each do |item|
          row = editor.buffer.rope.point_at(item.range.begin).row
          style = item.style.is_a?(Hash) ? item.style : {}
          y = track.y + track.height * row / [editor.buffer.line_count, 1].max
          fill(Zaniah::Bounds.new(track.x + 5, y, 4, 2), style.fetch(:color, :error))
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
    def paint_whitespace(editor, map, index, source_row, row, line, left, y, bounds)
      settings = @workspace.settings
      language = settings["languages"].fetch(editor.language_document.definition.name, {})
      mode = language.fetch("render_whitespace", settings["render_whitespace"])
      ideographic = language.fetch("render_ideographic_space", settings["render_ideographic_space"])
      return if mode == "none" && !ideographic

      rope = editor.buffer.rope
      source_lines = {source_row => [rope.line_start(source_row), rope.line(source_row)]}
      byte = column = cells = 0
      row.text.each_grapheme_cluster do |grapheme|
        if grapheme == " " || grapheme == "　"
          offset = map.to_buffer(DisplayPoint.new(index, column))
          point = rope.point_at(offset)
          start, source = source_lines[point.row] ||= [rope.line_start(point.row), rope.line(point.row)]
          local = offset - start
          character = source.byteslice(local..)&.each_char&.first
          marker = whitespace_marker(character, mode, ideographic, source, local, offset, editor.selections)
          if marker && (character != "\t" || whitespace_origin?(map, index, column, offset))
            x = line ? line.x_for_index(byte) : cells * @font_size * 0.6
            right = line ? line.x_for_index(byte + grapheme.bytesize) : x + Zaniah::Unicode.width(grapheme) * @font_size * 0.6
            text(marker, left + x, y, color: :muted) if left + right > bounds.x + gutter(editor) && left + x < bounds.right
          end
        end
        byte += grapheme.bytesize
        column += grapheme.length
        cells += grapheme.ascii_only? ? grapheme.length : Zaniah::Unicode.width(grapheme)
      end
    end
    def whitespace_origin?(map, row, column, offset)
      point = map.to_display(offset)
      point == DisplayPoint.new(row, column) || column.zero? && point.row + 1 == row &&
        point.column == map.row(point.row).text.length
    end
    def whitespace_marker(character, mode, ideographic, source, local, offset, selections)
      return "□" if character == "　" && ideographic
      return unless character == " " || character == "\t"
      return unless mode == "all" ||
        mode == "boundary" && (character == "\t" || whitespace_boundary?(source, local)) ||
        mode == "selection" && selections.any? { |selection| !selection.empty? && selection.start < offset + character.bytesize && offset < selection.end }

      character == "\t" ? "→" : "·"
    end
    def whitespace_boundary?(source, offset)
      following = offset + 1
      offset.zero? || following == source.bytesize || whitespace_before?(source, offset) || whitespace_at?(source, following)
    end
    def whitespace_before?(source, offset)
      byte = source.getbyte(offset - 1)
      byte == 32 || byte == 9 || source.byteslice(offset - 3, 3) == "　"
    end
    def whitespace_at?(source, offset)
      byte = source.getbyte(offset)
      byte == 32 || byte == 9 || source.byteslice(offset, 3) == "　"
    end
    def decorations_for_display_rows(editor, map, first, last)
      rows = (first...last).flat_map do |index|
        row = map.row(index)
        ending = map.to_buffer(DisplayPoint.new(index, row.text.length))
        [map.source_row(index), editor.buffer.rope.point_at(ending).row]
      end
      rows.sort.uniq.slice_when { |left, right| right != left + 1 }.flat_map do |group|
        @workspace.decorations.items_for(editor.buffer, group.first...(group.last + 1), context: editor)
      end.uniq.sort_by(&:priority).freeze
    end
    def prepare_inline_overlays(editor, row, left, y, width)
      return [nil, nil] unless row.kind == :text && row.metadata.is_a?(Array) && !row.metadata.empty?

      overlay = Zaniah::Text.new(row.text, size: @font_size, color: "#0000", wrap: :none,
        line_height: @line_height).w(width)
      row.metadata.each do |placement|
        overlay.inline_overlay(offset: placement.offset,
          element: decoration_element(editor, placement.item, placement.width, placement.height)
            .test_id("syrma:decoration:inline:#{editor.buffer.rope.point_at(placement.item.range.begin).row}"),
          align: placement.align)
      end
      node = overlay.request_layout(@cx)
      Zaniah::Layout::Engine.new.compute(node, x: left, y: y, width: width, height: @line_height)
      overlay.prepaint(node.bounds, nil, @cx)
      row.metadata.zip(overlay.children).each do |placement, element|
        register_overlay_region(editor, placement.item, element.layout_node.bounds)
      end
      @overlay_rows << overlay
      child(overlay)
      paragraph = overlay.instance_variable_get(:@paragraph)
      painter = -> { overlay.children.each { |child| child.paint(child.layout_node.bounds, nil, nil, @cx) } }
      [paragraph.lines.first.layout, painter]
    end
    def paint_block_overlay(editor, block, left, y, width)
      overlay = Zaniah::Text.new(" ", size: @font_size, color: "#0000", wrap: :none,
        line_height: @line_height).w(width)
      overlay.block_overlay(line: 0, position: :above, height: block.height,
        element: decoration_element(editor, block.item, width, block.height))
      node = overlay.request_layout(@cx)
      Zaniah::Layout::Engine.new.compute(node, x: left, y: y, width: width, height: block.height + @line_height)
      overlay.prepaint(node.bounds, nil, @cx)
      register_overlay_region(editor, block.item, overlay.children.first.layout_node.bounds)
      overlay.children.each { |child| child.paint(child.layout_node.bounds, nil, nil, @cx) }
      @overlay_rows << overlay
      child(overlay)
    end
    def paint_line_decorations(editor, source_row, y, bounds, items)
      items.each do |item|
        row = item.row || (item.range && editor.buffer.rope.point_at(item.range.begin).row)
        next unless row == source_row

        style = item.style.is_a?(Hash) ? item.style : {color: item.style}
        area = Zaniah::Bounds.new(bounds.x + gutter(editor), y - 2,
          [bounds.width - gutter(editor), 1].max, @line_height)
        paint_instrumented_fill(area, style.fetch(:color, :current_line),
          "syrma:decoration:line:#{source_row}:#{instrumentation_component(item.source)}")
      end
    end
    def paint_instrumented_fill(bounds, color, test_id)
      color = @theme[color] if color.is_a?(Symbol)
      paint_element(Zaniah::Div.new.w(bounds.width).h(bounds.height).bg(color).test_id(test_id), bounds)
    end
    def paint_element(element, bounds)
      child(element)
      root = element.request_layout(@cx)
      Zaniah::Layout::Engine.new.compute(root, x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
      element.prepaint(root.bounds, nil, @cx)
      element.paint(root.bounds, nil, nil, @cx)
      element
    end
    def instrumentation_component(value) = value.to_s
    def ui_text(value) = value.to_s.encode(Encoding::UTF_8)
    def decoration_element(editor, item, width, height)
      style = item.style.is_a?(Hash) ? item.style : {}
      color = style.fetch(:color, item.style.is_a?(Symbol) ? item.style : :muted)
      color = @theme[color] if color.is_a?(Symbol)
      content = if item.content.respond_to?(:request_layout) && item.content.respond_to?(:paint)
        item.content
      else
        Zaniah::Text.new(ui_text(item.content), size: [@font_size - 2, 1].max, color: color)
      end
      element = Zaniah::Div.new.w(width).h(height).items_center.child(content)
      element.style(padding: [0, style.fetch(:padding_right, 0), 0, style.fetch(:padding_left, 0)])
      element.bg(style[:background]) if style[:background]
      element
    end
    def register_overlay_region(editor, item, bounds)
      return unless item.on_click
      offset = item.range&.begin || editor.buffer.rope.line_start(item.row)
      region(bounds, role: :button, label: item.content.to_s,
        action: [:decoration, item.on_click, editor, offset])
    end
    def code_spans(editor, source_row, row, highlight_items = [])
      return [] if editor.buffer.rope.respond_to?(:lazy?) && editor.buffer.rope.lazy?
      raw = editor.language_document.tokens_for(source_row)
      semantic_state = @workspace.semantic_styles&.[](editor.buffer)
      semantic_state = nil unless semantic_state && semantic_state.first == editor.buffer.version
      base = editor.buffer.rope.line_start(source_row)
      foreground = highlight_items.each_with_object({}) do |item, colors|
        style = item.style.is_a?(Hash) ? item.style : nil
        next unless item.range && style&.[](:foreground)
        next unless item.range.begin.between?(base + row.offsets.first, base + row.offsets.last)
        colors[item.range.begin - base] = @theme[style.fetch(:color)]
      end
      cache = @code_caches[editor] ||= {}
      cached = cache[row.object_id]
      return cached[4] if cached && cached[5].equal?(row) && cached[0] == raw && cached[1].equal?(@theme) &&
        cached[2].equal?(semantic_state) && cached[3] == foreground
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
        color = foreground[original] if foreground.key?(original)
        if spans.last && spans.last[2] == color
          spans.last[1] += length
        else
          spans << [byte, byte + length, color]
        end
        byte += length
      end
      cache.shift if cache.length >= 512
      spans.each(&:freeze).freeze
      cache[row.object_id] = [raw, @theme, semantic_state, foreground, spans, row]
      spans
    end
    def paint_highlights(editor, index, row, line, left, y, items)
      items.each do |item|
        range = item.range
        next unless range
        if editor.buffer.rope.respond_to?(:lazy?)
          base = editor.buffer.rope.line_start(index)
          first = range.begin - base
          last = range.end - base
          next if last < row.offsets.first || first > row.offsets.last
          from = row.offsets.bsearch_index { |offset| offset >= first } || row.text.length
          to = row.offsets.bsearch_index { |offset| offset >= last } || row.text.length
          x = column_x(row.text, line, from)
          width = column_x(row.text, line, to) - x
          paint_highlight(item, left + x, y, width)
          register_highlight_region(editor, item, left + x, y, width)
          next
        end
        span = highlight_span(editor, item, index)
        next unless span
        before = highlight_span(editor, item, index - 1)
        after = highlight_span(editor, item, index + 1)
        x, right = span
        # Only exposed convex corners are rounded; no alpha-overlapping bridge
        # and no convex hull that would highlight unselected source text.
        radii = [before && x >= before[0] && x < before[1] ? 0 : 3,
          before && right > before[0] && right <= before[1] ? 0 : 3,
          after && right > after[0] && right <= after[1] ? 0 : 3,
          after && x >= after[0] && x < after[1] ? 0 : 3]
        paint_highlight(item, left + x, y, right - x, radii: radii)
        register_highlight_region(editor, item, left + x, y, right - x)
      end
    end
    def register_highlight_region(editor, item, x, y, width)
      return unless item.on_click && width.positive?

      region(Zaniah::Bounds.new(x, y - 1, width, @line_height), role: :link, label: item.content.to_s,
        action: [:decoration, item.on_click, editor, item.range.begin])
    end
    def paint_indent_guides(row, line, left, y, items)
      items.each do |item, point|
        style = item.style
        x = column_x(row.text, line, point.column)
        color = style.fetch(:color, :muted)
        color = @theme[color] if color.is_a?(Symbol)
        if @cx.window.is_a?(Zaniah::Platform::TUI::Window)
          column = [point.column - 1, 0].max
          text("│", left + column_x(row.text, line, column), y, color: color)
        else
          @scene.quad(left + x, y - 1, style[:active] ? 2 : 1, @line_height, color: color)
        end
      end
    end
    def paint_highlight(item, x, y, width, radii: 0)
      style = item.style.is_a?(Hash) ? item.style : {}
      color = style.fetch(:color, item.style.is_a?(Symbol) ? item.style : :selection)
      color = @theme[color] if color.is_a?(Symbol)
      if style[:underline]
        @scene.underline(x, y + @line_height - 2, [width, 6].max, color: color,
          thickness: style.fetch(:thickness, 1), wave: style[:underline] == :wave)
      else
        @scene.quad(x, y - 1, width, @line_height, color: color, radius: radii)
      end
    end
    def highlight_span(editor, item, index)
      cache = @selection_spans[item] ||= {first: editor.display_map.to_display(item.range.begin), last: editor.display_map.to_display(item.range.end)}
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
      minimum = item.style.is_a?(Hash) && item.style[:underline] && (!item.on_click || to > from) ? 6 : 0
      right = [right, x + minimum].max
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
      diagnostics = @workspace.decorations.items_for(editor.buffer, 0...editor.buffer.line_count)
        .count { |item| item.source == :diagnostics && item.kind == :highlight }
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
      context = @workspace.palette&.dig(:command_context) || @workspace.command_context
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
            command_index = palette[:indices] ? palette[:indices][index] : index
            shortcut = shortcuts[palette[:command_definitions][command_index].id]
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

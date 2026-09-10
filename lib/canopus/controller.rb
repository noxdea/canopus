# frozen_string_literal: true

require_relative "workspace/view"

module Canopus
  class Controller
    SHORTCUTS = {"cmd-s" => "file.save", "ctrl-s" => "file.save", "cmd-n" => "file.new", "ctrl-n" => "file.new",
      "cmd-w" => "file.close", "ctrl-w" => "file.close", "cmd-p" => "file.find", "ctrl-p" => "file.find",
      "cmd-shift-p" => "command.palette", "ctrl-shift-p" => "command.palette", "cmd-z" => "edit.undo", "ctrl-z" => "edit.undo",
      "cmd-shift-z" => "edit.redo", "ctrl-shift-z" => "edit.redo", "cmd-a" => "edit.select_all", "ctrl-a" => "edit.select_all",
      "cmd-d" => "edit.select_next", "ctrl-d" => "edit.select_next", "cmd-f" => "search.buffer", "ctrl-f" => "search.buffer",
      "cmd-shift-l" => "edit.select_all_occurrences", "ctrl-shift-l" => "edit.select_all_occurrences",
      "alt-up" => "edit.move_line_up", "alt-down" => "edit.move_line_down",
      "cmd-shift-f" => "search.project", "ctrl-shift-f" => "search.project", "cmd-alt-f" => "search.replace", "ctrl-h" => "search.replace",
      "cmd-/" => "edit.toggle_comment", "ctrl-/" => "edit.toggle_comment", "cmd-b" => "view.project", "ctrl-b" => "view.project",
      "ctrl-`" => "view.terminal", "cmd-\\" => "pane.split_right", "ctrl-\\" => "pane.split_right",
      "ctrl-space" => "language.completion", "f12" => "language.definition", "shift-f12" => "language.references",
      "f2" => "language.rename", "alt-enter" => "language.codeAction", "cmd-shift-o" => "language.outline",
      "ctrl-shift-o" => "language.outline", "cmd-k" => "language.hover", "ctrl-k" => "language.hover"}.freeze
    attr_reader :workspace, :view, :window, :keymap
    def initialize(workspace, window)
      @workspace, @window, @view = workspace, window, Workspace::View.new(workspace)
      workspace.window = window
      reload_keymap
      window.draw { workspace.drain; @view }
      window.on_input { |event| input(event) }
      window.on_close { close_requested }
      window.on_appearance { |_| workspace.apply_settings if workspace.settings["theme"] == "auto" } if window.respond_to?(:on_appearance)
      window.on_tick do
        data = workspace.terminal&.read
        window.request_frame if data && !data.empty?
        workspace.drain
        workspace.poll_changes
        workspace.poll_settings
        reload_keymap
        workspace.poll_git_changes
        poll_display_maps
        poll_language_documents
        poll_scroll
        window.request_frame if @view.tick
      end
      @clipboard, @terminal_focus = "", false
      workspace.new_buffer unless workspace.editor
    end
    def input(event)
      case event
      when Zaniah::Input::KeyUp, Zaniah::Input::MouseDown, Zaniah::Input::FileDrop
        @suppress_key_text = false
      when Zaniah::Input::Composition
        unless @workspace.palette
          @composing = !event.text.empty?
          @suppress_key_text = false if @composing
        end
      when Zaniah::Input::TextInput
        @composing = false
        suppressed, @suppress_key_text = @suppress_key_text, false
        return if suppressed
      end
      cancel_scroll if event.is_a?(Zaniah::Input::KeyDown) || event.is_a?(Zaniah::Input::TextInput) || event.is_a?(Zaniah::Input::MouseDown)
      @view.reset_blink unless event.is_a?(Zaniah::Input::MouseMove)
      return if palette_input(event)
      case event
      when Zaniah::Input::FileDrop
        event.paths.each { |path| @workspace.open(path) if File.file?(path) }
      when Zaniah::Input::TextInput
        input_text(event.text)
      when Zaniah::Input::Composition
        @workspace.editor.composition = event
      when Zaniah::Input::KeyDown
        key(event.keystroke)
      when Zaniah::Input::MouseDown
        mouse_down(event)
      when Zaniah::Input::MouseMove
        mouse_move(event) if @drag
        resize_drag(event.position) if @resize_drag
        scroll_drag(event.position) if @scroll_drag
        if @terminal_drag
          @terminal_drag == :selection ? @view.terminal_select(event.position, extend: true) : terminal_mouse(event, :move)
        elsif !(@drag || @resize_drag || @scroll_drag || @drag_file || @drag_tab) &&
            @workspace.terminal_visible && @workspace.terminal&.vt&.modes&.[](1003) && @view.hit(event.position)&.first == :terminal
          terminal_mouse(event, :move)
        end
      when Zaniah::Input::MouseUp
        @resize_drag = nil
        @scroll_drag = nil
        if @drag_file
          path, origin = @drag_file
          target = @view.hit(event.position)
          if target&.first == :directory && (event.position.x - origin.x).abs + (event.position.y - origin.y).abs > 10
            @workspace.rename_project_entry(path, File.join(target[1], File.basename(path)))
          end
          @drag_file = nil
        end
        terminal_mouse(event, :release) if @terminal_drag && @terminal_drag != :selection
        @terminal_drag = nil
        if @drag_tab
          from, editor, origin = @drag_tab
          if (event.position.x - origin.x).abs + (event.position.y - origin.y).abs > 10
            target = @view.hit(event.position)
            if target && [:editor, :tab, :pane].include?(target.first)
              @workspace.move_tab(from: from, to: target[1], editor: editor, index: target.first == :tab ? target[1].editors.index(target[2]) : nil)
            end
          end
          @drag_tab = nil
        end
        @drag = nil
      when Zaniah::Input::ScrollWheel
        scroll(event)
      end
      @window.request_frame
    rescue StandardError => error
      @workspace.message = error.message
      @window.request_frame
    end
    def input_text(text)
      if @workspace.palette
        return if [:workspace_edit, :confirm_close, :trash_file].include?(@workspace.palette[:kind])
        @workspace.palette[:query] << text
        @workspace.update_palette
      elsif @terminal_focus && @workspace.terminal_visible
        @workspace.terminal.write(text)
      elsif @workspace.settings["vim_mode"]
        text.each_grapheme_cluster { |character| @workspace.vim.feed(character) }
      else
        @workspace.editor.composition = nil
        @workspace.editor.insert_text(text)
      end
    end
    def key(stroke)
      @suppress_key_text = false
      reload_keymap
      stroke = Zaniah::Input::Keystroke.normalize(stroke)
      return palette_key(stroke) if @workspace.palette
      return if @composing && (stroke.split("-") & %w[ctrl cmd]).empty?
      return @workspace.settings_completions if stroke == "ctrl-space" && @workspace.settings_document?(@workspace.editor.buffer)
      if ["cmd-q", "ctrl-q"].include?(stroke)
        return @window.close
      end
      if @terminal_focus && @workspace.terminal_visible && stroke != "ctrl-`"
        if ["cmd-v", "ctrl-shift-v"].include?(stroke)
          return @workspace.terminal.paste(@window.respond_to?(:clipboard) ? @window.clipboard.to_s : @clipboard)
        elsif ["cmd-c", "ctrl-shift-c"].include?(stroke)
          @clipboard = @view.terminal_selected_text
          @window.clipboard = @clipboard if @window.respond_to?(:clipboard=)
          return
        end
        parts = stroke.split("-")
        name = parts.pop
        return if (name.length == 1 || name == "space") && (parts & %w[ctrl alt cmd]).empty?
        name = {"esc" => "escape", "pageup" => "page_up", "pagedown" => "page_down", "space" => " "}.fetch(name, name)
        return @workspace.terminal.key(name, control: parts.include?("ctrl"), alt: parts.include?("alt"), shift: parts.include?("shift"))
      end
      mode = @workspace.settings["vim_mode"] ? @workspace.vim.mode.to_s : false
      action = @keymap.dispatch(stroke, context: {"Editor" => true, "vim_mode" => mode})
      if action
        # Native adapters deliver text separately after printable key down.
        # Cocoa also sends an empty Composition before that ordinary commit.
        @suppress_key_text = stroke.match?(/\A(?:(?:alt|shift)-)*(?:space|[^\x00-\x1f\x7f])\z/)
        return action == :pending ? nil : @workspace.call(action)
      end
      if ["cmd-c", "ctrl-c", "cmd-x", "ctrl-x", "cmd-v", "ctrl-v"].include?(stroke) && !(@workspace.settings["vim_mode"] && stroke == "ctrl-v")
        return clipboard(stroke.split("-").last)
      end
      if ["tab", "shift-tab"].include?(stroke) && @workspace.editor.snippet_active?
        stroke == "tab" ? @workspace.editor.next_snippet : @workspace.editor.previous_snippet
        return @workspace.show_snippet_choices
      end
      parts = stroke.split("-")
      name = parts.pop
      if @workspace.settings["vim_mode"]
        @workspace.vim.feed(stroke) if name.length > 1 || parts.include?("ctrl")
        return
      end
      editor = @workspace.editor
      shift = parts.include?("shift")
      movement = {"left" => :left, "right" => :right, "up" => :up, "down" => :down,
        "home" => :line_start, "end" => :line_end, "pageup" => :page_up, "pagedown" => :page_down}[name]
      if movement
        movement = {left: :word_left, right: :word_right}.fetch(movement, movement) if parts.include?("alt") || parts.include?("ctrl")
        movement = {left: :line_start, right: :line_end, up: :file_start, down: :file_end}.fetch(movement, movement) if parts.include?("cmd")
        editor.move(movement, extend: shift)
      else
        case name
        when "backspace" then editor.delete_backward
        when "delete" then editor.delete_forward
        when "enter" then editor.insert_text("\n")
        when "tab" then shift ? editor.indent(outdent: true) : (editor.next_snippet || editor.insert_text(editor.use_tabs ? "\t" : " " * editor.tab_size))
        when "esc" then @workspace.dismiss_hover; editor.clear_snippet; editor.composition = nil; editor.select(editor.primary.head)
        end
      end
    end
    def tick
      reload_keymap
      @window.tick
    end
    def cancel_scroll = @scroll_motion = nil
    def poll_language_documents
      visible = @workspace.panes.filter_map(&:active)
      @language_viewports ||= {}
      @language_viewports.delete_if { |editor, _| !visible.include?(editor) }
      inactive = @workspace.panes.flat_map(&:editors).uniq - visible
      @language_poll_index = (@language_poll_index || -1) + 1
      candidates = visible + (inactive.empty? ? [] : [inactive[@language_poll_index % inactive.length]])
      candidates.each do |editor|
        document = editor.language_document
        if visible.include?(editor)
          map = editor.display_map
          first = editor.scroll_y.floor.clamp(0, map.row_count - 1)
          last = [first + editor.viewport_rows, first + 255, map.row_count - 1].min
          cached = @language_viewports[editor]
          # The persistent display tree changes on edits, folds, blocks and
          # completed wrap batches. Idle polls need not walk every visible row.
          unless cached && cached[0].equal?(document) && cached[1].equal?(map.tree) &&
              cached[2] == editor.buffer.version && cached[3] == first && cached[4] == last
            document.request(rows: (first..last).map { |row| map.source_row(row) }.uniq)
            @language_viewports[editor] = [document, map.tree, editor.buffer.version, first, last]
          end
        end
        changed = document.poll
        @workspace.language_ready(editor, document)
        @window.request_frame if changed
      rescue StandardError => error
        @workspace.message = "Language analysis: #{error.message}"
      end
    end
    def poll_scroll(now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      return false unless @scroll_motion
      editor, vx, vy, time = @scroll_motion
      friction = @workspace.settings["scroll_friction"]
      if @workspace.palette || friction.zero? || !@workspace.panes.any? { |pane| pane.active.equal?(editor) }
        cancel_scroll
        return false
      end
      elapsed = now - time
      return false unless elapsed.positive?
      # Exact exponential integration makes motion independent of frame rate.
      decay = Math.exp(-friction * elapsed)
      x, y = editor.scroll_x, editor.scroll_y
      editor.scroll(dx: vx * (1 - decay) / friction, dy: vy * (1 - decay) / friction)
      vx = editor.scroll_x == x ? 0 : vx * decay
      vy = editor.scroll_y == y ? 0 : vy * decay
      @scroll_motion = vx.abs < 0.2 && vy.abs < 0.01 ? nil : [editor, vx, vy, now]
      changed = editor.scroll_x != x || editor.scroll_y != y
      @window.request_frame if changed
      changed
    end
    def poll_display_maps
      visible = @workspace.panes.filter_map(&:active)
      inactive = @workspace.panes.flat_map(&:editors) - visible
      targets = visible.map { |editor| [editor, [224 / [visible.length, 1].max, 1].max] }
      unless inactive.empty?
        @layout_poll_index = ((@layout_poll_index || -1) + 1) % inactive.length
        targets << [inactive[@layout_poll_index], 32]
      end
      targets.each do |editor, limit|
        map = editor.display_map
        next unless map.pending?
        top = editor.scroll_y
        first = top.floor.clamp(0, map.row_count - 1)
        anchor = map.to_buffer(DisplayPoint.new(first, 0))
        cursor_was_visible = map.to_display(editor.primary.head).row.between?(first, first + editor.viewport_rows - 1)
        next unless map.poll(max_lines: limit)
        editor.scroll(dy: map.to_display(anchor).row + top % 1 - editor.scroll_y)
        editor.reveal_cursor if @workspace.editor.equal?(editor) && cursor_was_visible
        @window.request_frame
      rescue StandardError => error
        @workspace.message = "Background layout failed: #{error.message}"
      end
    end
    def close_requested
      if @discard_close || @workspace.buffers.values.none?(&:dirty?)
        @workspace.palette = nil
        return true
      end
      @workspace.palette = {kind: :confirm_close, query: "Save changes before closing?", index: 0, matches: ["Save all", "Discard changes", "Cancel"]}
      @window.request_frame
      false
    end

    private
    def reload_keymap
      language = @workspace.editor&.language_document&.definition&.name
      groups = @workspace.settings["languages"].dig(language, "keymap") || @workspace.settings["keymap"]
      return if @keymap_groups.equal?(groups)
      unless @keymap_groups == groups
        replacement = Zaniah::Input::Keymap.new
        SHORTCUTS.each { |keys, action| replacement.bind(keys, action) }
        groups.each do |group|
          group.fetch("bindings").each { |keys, action| replacement.bind(keys, action, context: group.fetch("context")) }
        end
        @keymap = replacement
        @view.keymap = replacement
      end
      @keymap_groups = groups
    end
    def palette_input(event)
      return false unless @workspace.palette
      @drag = @resize_drag = @scroll_drag = @terminal_drag = @drag_file = @drag_tab = nil
      case event
      when Zaniah::Input::KeyDown then key(event.keystroke)
      when Zaniah::Input::TextInput then input_text(event.text)
      when Zaniah::Input::MouseDown then mouse_down(event)
      end
      @window.request_frame
      true
    end
    def clipboard(operation)
      editor = @workspace.editor
      if operation == "v"
        value = @window.respond_to?(:clipboard) ? @window.clipboard : @clipboard
        editor.insert_text(value.to_s, auto_indent: false)
      else
        value = editor.selections.map { |selection| editor.buffer.rope.byteslice(selection.range).to_s }.join("\n")
        @clipboard = value
        @window.clipboard = value if @window.respond_to?(:clipboard=)
        editor.replace_selections("", kind: :cut) if operation == "x"
      end
    end
    def palette_key(stroke)
      palette = @workspace.palette
      if palette[:search_options] && (option = {"ctrl-alt-r" => :regexp, "ctrl-alt-c" => :case_sensitive, "ctrl-alt-w" => :whole_word, "ctrl-alt-s" => :selection_only}[stroke])
        return if option == :selection_only && palette[:kind] == :project_search
        palette[:search_options][option] = !palette[:search_options][option]
        return
      end
      case stroke
      when "tab", "shift-tab"
        if palette[:kind] == :snippet_choices
          @workspace.palette_accept
          stroke == "tab" ? @workspace.editor.next_snippet : @workspace.editor.previous_snippet
          @workspace.show_snippet_choices
        end
      when "esc"
        @workspace.palette = nil
      when "up" then palette[:index] = [palette[:index] - 1, 0].max
      when "down" then palette[:index] = [palette[:index] + 1, [palette[:matches].length - 1, 0].max].min
      when "pageup", "pagedown"
        if palette[:kind] == :workspace_edit
          step = palette.fetch(:detail_rows, 8)
          maximum = [palette.fetch(:detail_lines, []).length - step, 0].max
          palette[:details_scroll] = (palette.fetch(:details_scroll, 0) + (stroke == "pageup" ? -step : step)).clamp(0, maximum)
        end
      when "backspace"
        return if [:workspace_edit, :confirm_close, :trash_file].include?(palette[:kind])
        palette[:query] = palette[:query].grapheme_clusters[0...-1].join
        @workspace.update_palette
      when "enter"
        if palette[:kind] == :workspace_edit
          result = if palette[:index].zero?
            begin
              @workspace.apply_workspace_edit(palette[:edit], confirmed: true)
            rescue StandardError => error
              {"applied" => false, "failureReason" => error.message}
            end
          else
            {"applied" => false, "failureReason" => "User cancelled"}
          end
          palette[:response]&.fulfill(result.slice("applied", "failureReason", "failedChange"))
          @workspace.palette = nil if @workspace.palette.equal?(palette)
          if result["applied"]
            palette[:on_applied]&.call
          elsif result["failureReason"] != "User cancelled"
            @workspace.message = result["failureReason"].to_s
          end
        elsif palette[:kind] == :confirm_close
          case palette[:index]
          when 0
            dirty = @workspace.buffers.values.flat_map { |buffer| buffer.is_a?(MultiBuffer) ? buffer.excerpts.map(&:buffer) : [buffer] }.uniq.select(&:dirty?)
            raise Error, "Save untitled documents first, then close again" if dirty.any? { |buffer| !buffer.path }
            dirty.each { |buffer| @workspace.save_buffer(buffer) }
            @workspace.palette = nil
            @window.close
          when 1 then @discard_close = true; @window.close
          else @workspace.palette = nil
          end
        else
          @workspace.palette_accept
        end
      end
    end
    def mouse_down(event)
      action = @view.hit(event.position)
      return unless action
      kind, *args = action
      return if @workspace.palette && (kind != :palette || event.button != :left)
      if [:file, :directory].include?(kind)
        @workspace.selected_project_path = args.first
        @drag_file = [args.first, event.position] if event.button == :left
        if event.button == :right
          @workspace.palette = {kind: :commands, query: +"", index: 0, matches: %w[project.new_file project.new_folder project.rename project.trash]}
          return
        end
      end
      @terminal_focus = kind == :terminal
      case kind
      when :git_hunk then @workspace.toggle_git_hunk(args[0], row: args[1]) if event.button == :left
      when :hover_link
        return unless event.button == :left
        uri = URI.parse(args.first)
        @window.open_url(uri.to_s) if %w[http https].include?(uri.scheme) && uri.host && @window.respond_to?(:open_url)
      when :dismiss_notification then @workspace.dismiss_notification(args.first)
      when :pane then @workspace.focus(args.first)
      when :split_resize, :dock_resize then @resize_drag = action
      when :scrollbar
        editor, direction, track, thumb, maximum = args
        coordinate = direction == :vertical ? event.position.y : event.position.x
        start = direction == :vertical ? thumb.y : thumb.x
        length = direction == :vertical ? thumb.height : thumb.width
        grab = coordinate.between?(start, start + length) ? coordinate - start : length / 2.0
        @scroll_drag = [editor, direction, track, thumb, maximum, grab]
        scroll_drag(event.position)
      when :terminal
        return if event.button == :left && @view.terminal_open_link(event.position, modifiers: event.modifiers)
        tracking = [1000, 1002, 1003].any? { |mode| @workspace.terminal.vt.modes[mode] }
        if tracking && !event.modifiers.map(&:to_s).include?("shift")
          @terminal_drag = event.button
          terminal_mouse(event, :press)
        else
          @terminal_drag = :selection
          @view.terminal_select(event.position)
        end
      when :file then @workspace.open(args.first)
      when :directory then @workspace.project_tree.toggle(args.first)
      when :tab
        pane, editor = args
        @workspace.activate_tab(pane, editor)
        @drag_tab = [pane, editor, event.position]
      when :editor
        pane, editor = args
        @workspace.focus(pane)
        position = @view.offset_at(editor, event.position)
        modifiers = event.modifiers.map(&:to_s)
        anchor = modifiers.include?("shift") ? editor.primary.anchor : position
        editor.select(anchor, position, add: modifiers.include?("alt"))
        if event.click_count == 2
          editor.move(:word_left)
          editor.move(:word_right, extend: true)
        elsif event.click_count >= 3
          editor.move(:line_start)
          editor.move(:down, extend: true)
        end
        @drag = [editor, editor.primary.anchor, event.position, modifiers.include?("alt") && modifiers.include?("shift")]
      when :palette
        @workspace.palette[:index] = args.first
        palette_key("enter")
      end
    end
    def mouse_move(event)
      editor, anchor, _origin, rectangle = @drag
      offset = @view.offset_at(editor, event.position)
      rectangle ? editor.rectangle(editor.display_map.to_display(anchor), editor.display_map.to_display(offset)) : editor.select(anchor, offset)
    end
    def scroll(event)
      cancel_scroll
      raise ArgumentError, "scroll deltas must be finite" unless [event.delta.x, event.delta.y].all? { |value| value.is_a?(Numeric) && value.finite? }
      action = @view.hit(event.position)
      if [:editor, :scrollbar].include?(action&.first)
        editor = action.first == :editor ? action.last : action[1]
        editor.scroll(dx: event.delta.x, dy: event.delta.y / 20.0)
        # Cocoa already supplies native momentum deltas (numeric NSEvent phase).
        # Other backends get a bounded decaying tail; zero friction disables it.
        if !event.phase.is_a?(Numeric) && @workspace.settings["scroll_friction"].positive?
          @scroll_motion = [editor, event.delta.x * 10, event.delta.y / 2.0, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
        end
      elsif [:file, :directory].include?(action&.first)
        @view.project_scroll(event.delta.y / 24.0)
      elsif action&.first == :terminal
        if [1000, 1002, 1003].any? { |mode| @workspace.terminal.vt.modes[mode] }
          column, row = @view.terminal_point(event.position)
          @workspace.terminal.mouse(button: event.delta.y.positive? ? :wheel_down : :wheel_up, column: column, row: row)
        else
          @view.terminal_scroll(event.delta.y / 20.0)
        end
      end
    end
    def scroll_drag(point)
      editor, direction, track, thumb, maximum, grab = @scroll_drag
      if direction == :vertical
        fraction = (point.y - track.y - grab) / [track.height - thumb.height, 1].max
        editor.scroll(dy: fraction.clamp(0, 1) * maximum - editor.scroll_y)
      else
        fraction = (point.x - track.x - grab) / [track.width - thumb.width, 1].max
        editor.scroll(dx: fraction.clamp(0, 1) * maximum - editor.scroll_x)
      end
    end
    def terminal_mouse(event, action)
      column, row = @view.terminal_point(event.position)
      modifiers = event.modifiers.map(&:to_s)
      @workspace.terminal.mouse(button: @terminal_drag, column: column, row: row, action: action,
        shift: modifiers.include?("shift"), alt: modifiers.include?("alt"), control: modifiers.include?("ctrl"))
    end
    def resize_drag(point)
      kind, target, bounds = @resize_drag
      if kind == :split_resize
        value = target[:direction] == :horizontal ? (point.x - bounds.x).to_f / bounds.width : (point.y - bounds.y).to_f / bounds.height
        target[:ratio] = value.clamp(0.1, 0.9)
      else
        size = case target
        when :left then point.x - bounds.x
        when :right then bounds.right - point.x
        when :bottom then bounds.bottom - 26 - point.y
        end
        @workspace.docks[target][:size] = size.clamp(80, target == :bottom ? bounds.height * 0.7 : bounds.width * 0.4)
      end
    end
  end
end

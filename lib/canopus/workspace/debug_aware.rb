# frozen_string_literal: true

module Canopus
  class Workspace
    module DebugAware
      BreakpointClick = Data.define(:workspace) do
        def call(editor, row) = workspace.toggle_breakpoint(editor, row)
        def right_click(editor, row) = workspace.show_breakpoint_menu(editor, row)
      end
      private_constant :BreakpointClick

      def initialize_breakpoints
        @breakpoints = Debug::Breakpoints.new(root: @root) do |_path|
          @decorations.invalidate(:breakpoint)
          @window&.request_frame
        end
        @breakpoint_click = BreakpointClick.new(self)
        @decorations.register(:breakpoint) { |buffer, rows, current| breakpoint_decorations(buffer, rows, current) }
      end

      def breakpoint_decorations(buffer, rows, current = nil)
        return [] unless breakpoint_buffer?(buffer)
        last = [rows.end, buffer.line_count].min
        entries = @breakpoints.for_path(buffer.path).filter_map do |entry|
          row = entry.line - 1
          [row, entry] if row.between?(rows.begin, last - 1)
        end.to_h
        requested = current.is_a?(Editor) && current.buffer.equal?(buffer) ? (rows.begin...last) : entries.keys.sort
        requested.map do |row|
          entry = entries[row]
          state = entry ? (entry.enabled ? "Enabled" : "Disabled") : "Set"
          details = entry && [entry.condition, entry.hit_condition, entry.log_message].compact
          label = "#{state} breakpoint on line #{row + 1}"
          label += ": #{details.join(', ')}" if details && !details.empty?
          color = entry ? (entry.enabled ? :error : :muted) : "#0000"
          style = {color: color, gutter_offset: 7, gutter_width: 3, hit_offset: 7, hit_width: 4}
          Decoration::Item.new(:gutter, nil, row, label, style, 20, :breakpoint, @breakpoint_click)
        end
      end

      def toggle_breakpoint(current, row)
        return unless breakpoint_row?(current, row)
        @breakpoints.toggle(current.buffer.path, row + 1)
      end

      def show_breakpoint_menu(current, row)
        return unless breakpoint_row?(current, row)
        path, line = current.buffer.path, row + 1
        entry = @breakpoints.for_path(path).find { |item| item.line == line }
        actions = if entry
          [[:condition, "Edit condition"], [:hit_condition, "Edit hit count"],
            [:log_message, "Edit log message"], [:enabled, entry.enabled ? "Disable breakpoint" : "Enable breakpoint"],
            [:remove, "Remove breakpoint"]]
        else
          [[:add, "Add breakpoint"], [:condition, "Add conditional breakpoint"],
            [:hit_condition, "Add hit-count breakpoint"], [:log_message, "Add logpoint"]]
        end
        self.palette = {kind: :breakpoint_actions, query: +"", index: 0, matches: actions.map(&:last),
                        actions: actions.map(&:first),
                        breakpoint: {path: path, line: line, buffer: current.buffer,
                                     version: current.buffer.version, entry: entry}}
      end

      def accept_breakpoint_palette
        state = @palette.fetch(:breakpoint)
        unless breakpoint_palette_current?(state)
          self.palette = nil
          self.message = "Buffer changed; open the breakpoint menu again"
          return
        end
        if @palette[:kind] == :breakpoint_edit
          value = @palette[:query].empty? ? nil : @palette[:query]
          entry = breakpoint_entry(state)
          options = {@palette.fetch(:field) => value}
          self.palette = nil
          return entry ? @breakpoints.update(state[:path], state[:line], **options) :
            @breakpoints.add(state[:path], state[:line], **options)
        end

        action = @palette.fetch(:actions).fetch(@palette[:index])
        entry = breakpoint_entry(state)
        case action
        when :add
          self.palette = nil
          @breakpoints.add(state[:path], state[:line])
        when :remove
          self.palette = nil
          @breakpoints.remove(state[:path], state[:line])
        when :enabled
          raise Error, "breakpoint does not exist" unless entry
          self.palette = nil
          @breakpoints.update(state[:path], state[:line], enabled: !entry.enabled)
        else
          value = entry&.public_send(action)
          self.palette = {kind: :breakpoint_edit, query: +(value || ""), index: 0, matches: [],
                          breakpoint: state, field: action}
        end
      end

      def attach_breakpoints(buffer)
        @breakpoints.attach(buffer) if breakpoint_buffer?(buffer)
      end

      def relocate_breakpoints(buffer)
        @breakpoints.detach(buffer)
        attach_breakpoints(buffer)
        @decorations.invalidate(:breakpoint, buffer: buffer)
      end

      def detach_breakpoints(buffer) = @breakpoints.detach(buffer)

      private

      def breakpoint_entry(state)
        @breakpoints.for_path(state.fetch(:path)).find { |entry| entry.line == state.fetch(:line) }
      end

      def breakpoint_palette_current?(state)
        buffer = state[:buffer]
        buffer.is_a?(Buffer) && @buffers.value?(buffer) && buffer.version == state[:version] &&
          buffer.path == state[:path] && breakpoint_entry(state).equal?(state[:entry])
      end

      def breakpoint_buffer?(buffer)
        path = buffer.respond_to?(:path) && buffer.path
        path && path.start_with?(root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}")
      end

      def breakpoint_row?(current, row)
        current.is_a?(Editor) && breakpoint_buffer?(current.buffer) && row.is_a?(Integer) && row.between?(0, current.buffer.line_count - 1)
      end
    end
  end
end

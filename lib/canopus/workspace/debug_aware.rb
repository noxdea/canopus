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
          @debug_panel&.refresh_breakpoints
          @window&.request_frame
        end
        @breakpoint_click = BreakpointClick.new(self)
        @decorations.register(:breakpoint) { |buffer, rows, current| breakpoint_decorations(buffer, rows, current) }
        @debug_generation = 0
        @debug_session = @debug_thread = @debug_position = nil
        @debug_panel = Debug::Panel.new(breakpoints: @breakpoints,
          post: ->(&block) { post(&block) },
          select_frame: ->(session, frame) { select_debug_frame(session, frame) },
          select_breakpoint: ->(entry) { select_debug_breakpoint(entry) },
          report: ->(text) { notify(text) }, request_frame: -> { @window&.request_frame })
        @decorations.register(:debug_position) { |buffer, rows| debug_position_decorations(buffer, rows) }
      end

      attr_reader :debug_session, :debug_position, :debug_panel

      def debug_tree = @debug_panel.tree
      def debug_watches = @debug_panel.watches

      def add_debug_watch(expression) = @debug_panel.add_watch(expression)
      def remove_debug_watch(expression) = @debug_panel.remove_watch(expression)

      def show_debug_watch_add
        self.palette = {kind: :debug_watch_add, query: +"", index: 0, matches: []}
      end

      def show_debug_watch_remove
        if debug_watches.empty?
          self.message = "No debug watch expressions"
          return false
        end
        self.palette = {kind: :debug_watch_remove, query: +"", index: 0,
          matches: debug_watches.dup, items: debug_watches}
        update_palette
      end

      def accept_debug_watch_palette
        state = @palette
        self.palette = nil
        if state[:kind] == :debug_watch_add
          add_debug_watch(state[:query])
        else
          index = state[:indices] ? state[:indices][state[:index]] : state[:index]
          expression = index && state[:items][index]
          expression && remove_debug_watch(expression)
        end
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

      def start_debugging(configuration = nil)
        loader = Debug::Configuration.new(root: @root, settings: @settings)
        if configuration.nil?
          configurations = loader.configurations
          raise Error, "no debug configurations are available" if configurations.empty?
          if configurations.length > 1
            self.palette = {kind: :debug_configurations, query: +"", index: 0,
              matches: configurations.map { |item| item.fetch("name") }, items: configurations}
            return nil
          end
          configuration = configurations.first
        end
        context = debug_configuration_context
        resolved = loader.resolve(configuration, **context)
        adapter = loader.adapter(resolved.fetch("type"), **context)
        stop_debugging if @debug_session
        generation = @debug_generation += 1
        session = build_debug_session(configuration: resolved, adapter: adapter)
        session.on(:stopped) { |frame| post { handle_debug_stop(session, generation, frame) } }
        session.on(:continued) { post { handle_debug_continue(session, generation) } }
        session.on(:terminated) { post { finish_debug_session(session, generation) } }
        session.on(:error) { |error| post { report_debug_error(session, generation, error) } }
        @debug_session = session
        @debug_thread = Thread.new do
          session.start
          post { notify("Debug session started: #{resolved.fetch('name')}") if current_debug_session?(session, generation) }
        rescue StandardError => error
          post { fail_debug_session(session, generation, error) }
        end
        @debug_thread.report_on_exception = false
        session
      end

      def stop_debugging
        session, thread = @debug_session, @debug_thread
        @debug_generation += 1
        @debug_session = @debug_thread = nil
        @debug_panel.clear
        clear_debug_position
        failure = nil
        begin
          session&.close
        rescue StandardError => error
          failure = error
        ensure
          thread.join if thread && thread != Thread.current
        end
        raise failure if failure

        session
      end

      def debug_position_decorations(buffer, rows)
        position = @debug_position
        return [] unless position && buffer.path == position[:path] && rows.cover?(position[:row])

        [Decoration::Item.new(:line, nil, position[:row], nil, "#f9758333", 10, :debug_position, nil)]
      end

      private

      def build_debug_session(configuration:, adapter:)
        Debug::Session.new(root: @root, configuration: configuration, adapter: adapter,
          breakpoints: @breakpoints)
      end

      def debug_configuration_context
        current = editor
        return {} unless current && current.buffer.path

        selection = current.primary
        {file: current.buffer.path,
         line_number: current.buffer.rope.point_at(selection.head).row + 1,
         selected_text: selection.empty? ? nil : current.buffer.rope.byteslice(selection.range).to_s}
      end

      def show_debug_frame(session, generation, frame)
        return unless current_debug_session?(session, generation)

        source = frame.source
        path = source && (source["path"] || source[:path])
        show_debug_location(path, frame.line)
      rescue StandardError => error
        clear_debug_position
        notify("Debug stop could not be shown: #{error.message}")
      end

      def show_debug_location(path, line, highlight: true)
        path = debug_source_path(path)
        raise Error, "debug location has an invalid line" unless line.is_a?(Integer) && line.positive?

        current = open(path)
        raise Error, "debug location is outside the file" if line > current.buffer.line_count

        if highlight
          @debug_position = {path: current.buffer.path, row: line - 1}.freeze
          @decorations.invalidate(:debug_position)
        end
        current.select(current.buffer.rope.line_start(line - 1))
        current.reveal_cursor
        @window&.request_frame
        true
      end

      def handle_debug_stop(session, generation, frame)
        return unless current_debug_session?(session, generation)

        @debug_panel.stopped(session, frame)
        @panels.show("debug")
        show_debug_frame(session, generation, frame)
      end

      def handle_debug_continue(session, generation)
        return unless current_debug_session?(session, generation)

        @debug_panel.continued(session)
        clear_debug_position
      end

      def select_debug_frame(session, frame)
        return false unless @debug_session.equal?(session) && !@closed

        show_debug_frame(session, @debug_generation, frame)
        true
      end

      def select_debug_breakpoint(entry)
        show_debug_location(entry.path, entry.line, highlight: false)
      rescue StandardError => error
        notify("Breakpoint could not be shown: #{error.message}")
        false
      end

      def debug_source_path(value)
        valid = value.is_a?(String) && value.valid_encoding? &&
          (value.encoding == Encoding::UTF_8 || value.ascii_only?) && value.bytesize.between?(1, 65_536) &&
          !value.match?(/[\x00-\x1f\x7f]/)
        raise Error, "debug stack frame has an invalid source" unless valid

        path = File.realpath(File.expand_path(value, @root))
        boundary = @root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}"
        raise Error, "debug stack frame is outside the workspace" unless path.start_with?(boundary)
        raise Error, "debug stack frame source is not a file" unless File.file?(path)

        path
      rescue SystemCallError => error
        raise Error, "invalid debug stack frame source: #{error.message}"
      end

      def finish_debug_session(session, generation)
        return unless current_debug_session?(session, generation)

        @debug_session = @debug_thread = nil
        @debug_generation += 1
        @debug_panel.clear
        clear_debug_position
        session.close
        notify("Debug session ended")
      end

      def fail_debug_session(session, generation, error)
        return unless current_debug_session?(session, generation)

        @debug_session = @debug_thread = nil
        @debug_generation += 1
        @debug_panel.clear
        clear_debug_position
        session.close
        notify(error.message)
      end

      def report_debug_error(session, generation, error)
        notify(error.message) if current_debug_session?(session, generation)
      end

      def current_debug_session?(session, generation)
        @debug_session.equal?(session) && @debug_generation == generation && !@closed
      end

      def clear_debug_position
        return unless @debug_position

        @debug_position = nil
        @decorations.invalidate(:debug_position)
        @window&.request_frame
      end

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

# frozen_string_literal: true

module Canopus
  class Workspace
    module DebugAware
      DEBUG_HOVER_EXPRESSION_LIMIT = 256
      DEBUG_HOVER_TEXT_LIMIT = 4_096
      DEBUG_HOVER_SCOPE_LIMIT = 16
      DEBUG_HOVER_VARIABLE_LIMIT = 256
      DEBUG_HOVER_TOKEN_LIMIT = 4_096
      DEBUG_HOVER_ROW_LIMIT = 256
      DEBUG_HOVER_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/n
      DEBUG_HOVER_DIRECT_NAME = /\A(?:@@?|\$)[A-Za-z_][A-Za-z0-9_]*\z/n
      DEBUG_HOVER_DIRECT_TOKENS = %w[Name.Variable.Instance Name.Variable.Class Name.Variable.Global].freeze

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
        @debug_console = Debug::Console.new(post: ->(&block) { post(&block) },
          request_frame: -> { @window&.request_frame })
        @decorations.register(:debug_position) { |buffer, rows| debug_position_decorations(buffer, rows) }
      end

      attr_reader :debug_session, :debug_position, :debug_panel, :debug_console

      def debug_tree = @debug_panel.tree
      def debug_console_tree = @debug_console.tree
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

      def show_debug_console
        raise Error, "debug session is not stopped" unless @debug_session && @debug_panel.selected_frame

        @panels.show("debug_console")
        self.palette = {kind: :debug_console, query: +"", index: 0, matches: []}
      end

      def accept_debug_console_palette
        expression = @palette.fetch(:query)
        self.palette = nil
        @debug_console.evaluate(expression)
      end

      def debug_hover(current = editor, offset = current&.primary&.head)
        session, frame = @debug_session, @debug_panel.selected_frame
        unless session && frame && debug_hover_editor?(current) && offset.is_a?(Integer)
          clear_debug_hover
          return false
        end
        candidate = debug_hover_expression(current, offset)
        unless candidate
          clear_debug_hover
          return false
        end
        expression, direct = candidate
        key = [session, @debug_generation, frame.id, current, current.buffer.version, expression].freeze
        return true if @debug_hover_key == key

        clear_debug_hover
        token = @debug_hover_token = Object.new.freeze
        @debug_hover_key = key
        direct ? request_debug_hover_evaluate(token, key) : request_debug_hover_scopes(token, key)
        true
      rescue StandardError
        clear_debug_hover
        false
      end

      def dismiss_hover
        clear_debug_hover
        super
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
        session.on(:output) { |event| handle_debug_output(session, generation, event) }
        session.on(:terminated) { post { finish_debug_session(session, generation) } }
        session.on(:error) { |error| post { report_debug_error(session, generation, error) } }
        @debug_session = session
        @debug_console.attach(session)
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
        @debug_console.detach
        clear_debug_hover
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
        @debug_console.stopped(session, frame)
        clear_debug_hover
        @panels.show("debug")
        show_debug_frame(session, generation, frame)
      end

      def handle_debug_continue(session, generation)
        return unless current_debug_session?(session, generation)

        @debug_panel.continued(session)
        @debug_console.continued(session)
        clear_debug_hover
        clear_debug_position
      end

      def handle_debug_output(session, generation, event)
        @debug_console.output(session, event) if current_debug_session?(session, generation)
      end

      def select_debug_frame(session, frame)
        return false unless @debug_session.equal?(session) && !@closed

        @debug_console.stopped(session, frame)
        clear_debug_hover
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
        @debug_console.detach
        clear_debug_hover
        clear_debug_position
        session.close
        notify("Debug session ended")
      end

      def fail_debug_session(session, generation, error)
        return unless current_debug_session?(session, generation)

        @debug_session = @debug_thread = nil
        @debug_generation += 1
        @debug_panel.clear
        @debug_console.detach
        clear_debug_hover
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

      def debug_hover_editor?(current)
        return false unless current.is_a?(Editor) && current.equal?(editor)

        path = current.buffer.path
        boundary = @root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}"
        path.is_a?(String) && path.start_with?(boundary)
      end

      def debug_hover_expression(current, offset)
        document, buffer = current.language_document, current.buffer
        return unless document.background? && document.definition.name == "ruby"

        size = buffer.rope.bytesize
        return unless offset.between?(0, size)
        point = buffer.rope.point_at(offset)
        return unless document.tokens_current?(point.row)

        local = offset - buffer.rope.line_start(point.row)
        cursor = 0
        tokens = document.tokens_for(point.row)
        index = tokens.index do |_name, text|
          first, cursor = cursor, cursor + text.bytesize
          local >= first && local < cursor
        end
        return unless index

        name, value = tokens.fetch(index)
        direct = DEBUG_HOVER_DIRECT_TOKENS.include?(name) && value.match?(DEBUG_HOVER_DIRECT_NAME)
        return unless direct || (name == "Name" && value.match?(DEBUG_HOVER_NAME))
        return if value.bytesize > DEBUG_HOVER_EXPRESSION_LIMIT || debug_hover_call_token?(tokens, index) ||
          debug_hover_string_interpolation?(document, point.row, tokens, index)

        [value.dup.freeze, direct].freeze
      end

      def debug_hover_call_token?(tokens, index)
        significant = ->(name, _text) { !name.start_with?("Text", "Comment") }
        before = tokens[0...index].reverse.find { |token| significant.call(*token) }&.last
        after = tokens[(index + 1)..]&.find { |token| significant.call(*token) }&.last
        [".", "&.", "::"].include?(before) || after&.match?(/\A(?:\.|&\.|::|\(|\[)/)
      end

      def debug_hover_string_interpolation?(document, row, tokens, index)
        depth = 0
        remaining = DEBUG_HOVER_TOKEN_LIMIT
        first = [row - DEBUG_HOVER_ROW_LIMIT + 1, 0].max
        row.downto(first) do |current_row|
          break unless document.tokens_current?(current_row)

          values = current_row == row ? tokens.first(index) : document.tokens_for(current_row)
          return true if (remaining -= values.length).negative?

          values.reverse_each do |name, text|
            next unless name == "Literal.String.Interpol"

            if text == "}"
              depth += 1
            elsif text.end_with?("{")
              return true if depth.zero?
              depth -= 1
            end
          end
        end
        false
      end

      def request_debug_hover_scopes(token, key)
        session, _generation, frame_id = key
        future = @debug_hover_request = session.scopes(frame_id)
        future.on_complete do |scopes, error|
          post do
            next unless @debug_hover_token.equal?(token)
            next clear_debug_hover unless debug_hover_current?(token, key)
            next clear_debug_hover if error

            values = scopes.first(DEBUG_HOVER_SCOPE_LIMIT).reject do |scope|
              scope.variables_reference.zero? || scope.expensive
            end
            request_debug_hover_variables(token, key, values, 0)
          end
        end
      rescue StandardError
        clear_debug_hover if @debug_hover_token.equal?(token)
        false
      end

      def request_debug_hover_variables(token, key, scopes, index)
        return clear_debug_hover unless debug_hover_current?(token, key)
        return clear_debug_hover unless (scope = scopes[index])

        session, = key
        future = @debug_hover_request = session.variables(scope.variables_reference)
        future.on_complete do |variables, error|
          post do
            next unless @debug_hover_token.equal?(token)
            next clear_debug_hover unless debug_hover_current?(token, key)

            expression = key.last
            if !error && variables.first(DEBUG_HOVER_VARIABLE_LIMIT).any? { |variable| variable.name == expression }
              request_debug_hover_evaluate(token, key)
            else
              request_debug_hover_variables(token, key, scopes, index + 1)
            end
          end
        end
      rescue StandardError
        clear_debug_hover if @debug_hover_token.equal?(token)
        false
      end

      def request_debug_hover_evaluate(token, key)
        return clear_debug_hover unless debug_hover_current?(token, key)

        session, _generation, frame_id, _current, _version, expression = key
        future = @debug_hover_request = session.evaluate(expression, frame_id: frame_id, context: "hover")
        future.on_complete do |variable, error|
          post { accept_debug_hover(token, key, variable, error) }
        end
      rescue StandardError
        clear_debug_hover if @debug_hover_token.equal?(token)
        false
      end

      def debug_hover_current?(token, key)
        return false unless @debug_hover_token.equal?(token) && @debug_hover_key == key

        session, generation, frame_id, current, version, = key
        frame = @debug_panel.selected_frame
        current_debug_session?(session, generation) && frame&.id == frame_id &&
          current.equal?(editor) && current.buffer.version == version
      end

      def accept_debug_hover(token, key, variable, error)
        return unless @debug_hover_token.equal?(token)
        return clear_debug_hover unless debug_hover_current?(token, key)

        @debug_hover_request = nil
        return clear_debug_hover if error

        expression = key.last
        value = bounded_debug_hover_text(variable.respond_to?(:value) ? variable.value : nil)
        type = bounded_debug_hover_text(variable.respond_to?(:type) ? variable.type : nil)
        @hover_card = bounded_debug_hover_text("#{expression} = #{value}#{type.empty? ? "" : " · #{type}"}")
        @hover_markup = false
        @debug_hover_visible = true
        @window&.request_frame
        true
      end

      def bounded_debug_hover_text(value)
        value.to_s.byteslice(0, DEBUG_HOVER_TEXT_LIMIT).to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
          .gsub(/[\x00-\x1f\x7f]+/, " ").strip
      end

      def clear_debug_hover
        changed = @debug_hover_request || @debug_hover_key || @debug_hover_visible
        @debug_hover_request&.cancel
        @debug_hover_request = @debug_hover_token = @debug_hover_key = nil
        @hover_card = nil if @debug_hover_visible
        @debug_hover_visible = false
        @window&.request_frame if changed
        nil
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

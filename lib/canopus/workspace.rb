# frozen_string_literal: true

require "json"
require "fileutils"
sadr_path = ENV["SADR_PATH"]
sadr_root = File.expand_path("../..", __dir__)
sadr_path ? require(File.expand_path("lib/sadr", File.expand_path(sadr_path, sadr_root))) : require("sadr")
require_relative "settings"
require_relative "theme"
require_relative "vim"
require_relative "pane"
require_relative "project/tree"
require_relative "command"
require_relative "panel"
require_relative "decoration"
require_relative "provider"
require_relative "minimap"
require_relative "diagnostics"

module Canopus
  class Workspace
    ClosedTab = Data.define(:path, :selections, :scroll_x, :scroll_y, :pane_id, :index)
    LANGUAGE_SERVER_CAPABILITIES = {
      "completion" => "completionProvider", "diagnostics" => nil, "codeAction" => "codeActionProvider",
      "formatting" => "documentFormattingProvider", "definition" => "definitionProvider",
      "typeDefinition" => "typeDefinitionProvider", "implementation" => "implementationProvider",
      "hover" => "hoverProvider", "signatureHelp" => "signatureHelpProvider", "references" => "referencesProvider",
      "rename" => "renameProvider", "documentSymbol" => "documentSymbolProvider", "codeLens" => "codeLensProvider",
      "inlayHint" => "inlayHintProvider", "semanticTokens" => "semanticTokensProvider",
      "documentHighlight" => "documentHighlightProvider", "foldingRange" => "foldingRangeProvider",
      "selectionRange" => "selectionRangeProvider", "callHierarchy" => "callHierarchyProvider",
      "typeHierarchy" => "typeHierarchyProvider", "documentLink" => "documentLinkProvider",
      "linkedEditingRange" => "linkedEditingRangeProvider", "workspaceSymbol" => "workspaceSymbolProvider"
    }.freeze
    attr_reader :panes, :active_pane, :buffers, :actions, :commands, :settings, :theme, :project, :clients, :root, :docks, :panels, :decorations, :providers, :minimap, :diagnostics, :breakpoints
    attr_reader :terminals, :active_terminal_index
    attr_accessor :window, :terminal_composition, :selected_project_path, :performance
    attr_reader :message, :palette

    def initialize(root: Dir.pwd, settings: nil)
      @root = File.realpath(root)
      @settings = settings || Settings.new(Settings.user_path, File.join(@root, ".canopus", "settings.jsonc"))
      @main_queue = Queue.new
      @panes, @buffers = [Pane.new], {}
      @active_pane = @panes.first
      @layout = {pane: @active_pane}
      @theme = Theme.new(name: @settings["theme"])
      @actions = @commands = Command::Registry.new
      @clients, @vim_states = {}, {}
      @message = ""
      @project = Project.new(@root) if defined?(Project)
      dock = @settings["dock"]
      @docks = %i[left right bottom].to_h do |side|
        value = dock.fetch(side.to_s)
        [side, {visible: value["visible"], size: value["size"]}]
      end
      @panels = Panel::Registry.new(@docks)
      @panels.restore(dock.fetch("panels"))
      @panels.register(Panel::Definition.new("terminal", "Terminal", nil, :bottom, -> { terminal }, nil))
      @panels.register(Panel::Definition.new("search", "Search", nil, :left, -> { palette_open(:project_search) }, nil))
      @panels.register(Panel::Definition.new("explorer", "Explorer", nil, :left, -> { project_tree }, nil))
      @panels.register(Panel::Definition.new("hierarchy", "Hierarchy", nil, :right, -> { hierarchy_tree }, nil), visible: false)
      @panels.register(Panel::Definition.new("problems", "Problems", nil, :right, -> { problems_tree }, nil), visible: false)
      @panels.register(Panel::Definition.new("debug", "Debug", nil, :left, -> { debug_tree }, nil), visible: false)
      @panels.hide("hierarchy")
      @decorations = Decoration::Registry.new
      @decorations.register(:selection_match) do |buffer, rows, current|
        selections = current.is_a?(Editor) && current.buffer.equal?(buffer) ? current.selections : buffer.selections
        selections.filter_map do |selection|
          next if selection.empty?
          first = buffer.rope.point_at(selection.start).row
          last = buffer.rope.point_at(selection.end).row
          next if last < rows.begin || first >= rows.end

          Decoration::Item.new(:highlight, selection.range, nil, nil, :selection, 100, :selection_match, nil)
        end
      end
      @decorations.register(:git) { |buffer, rows| git_decorations(buffer, rows) }
      @decorations.register(:diagnostics) { |buffer, rows| diagnostic_decorations(buffer, rows) }
      @decorations.register(:document_highlight) { |buffer, rows, current| document_highlight_decorations(buffer, rows, current) }
      @decorations.register(:document_link) { |buffer, rows, current| document_link_decorations(buffer, rows, current) }
      @decorations.register(:inlay_hint) { |buffer, rows| inlay_hint_decorations(buffer, rows) }
      @decorations.register(:code_lens) { |buffer, rows| code_lens_decorations(buffer, rows) }
      @decorations.register(:bracket) { |buffer, rows, current| bracket_decorations(buffer, rows, current) }
      initialize_breakpoints
      @minimap = Minimap.new
      @diagnostics = Diagnostics::Registry.new do |uri|
        @window ? post { diagnostics_changed(uri) } : diagnostics_changed(uri)
      end
      @providers = Provider::Registry.new
      @providers.register_completion(:lsp, priority: 100) { |buffer, offset, context| lsp_completions(buffer, offset, context) }
      @languages, @terminals = {}, []
      @active_terminal_index = 0
      @closed_tabs, @terminal_names = [], {}
      register_actions
    end
    def editor = @active_pane.active
    def show_project = @panels.visible?("explorer")
    def show_project=(visible)
      visible ? @panels.show("explorer") : @panels.hide("explorer")
    end
    def terminal_visible = @panels.visible?("terminal") && @docks[:bottom][:visible]
    def terminal_visible=(visible)
      visible ? @panels.show("terminal") : @panels.hide("terminal")
    end
    def terminal = @terminals[@active_terminal_index]
    def terminal=(value)
      @terminals.each { |item| item.close if !item.equal?(value) && item.respond_to?(:close) }
      @terminal_names.clear
      @terminal_sizes&.clear
      @terminal_resize_times&.clear
      @terminals = value ? [value] : []
      @active_terminal_index = 0
      value
    end
    def palette=(value)
      if @workspace_symbol_request && value&.dig(:workspace_symbol_generation) != @workspace_symbol_generation
        cancel_workspace_symbol_search
      end
      previous, @palette = @palette, @closed ? nil : value
      rename = previous&.dig(:kind) == :rename && previous[:rename]
      if rename && !previous.equal?(@submitting_rename_palette) && !rename.equal?(@palette&.dig(:rename))
        release_rename_snapshot(rename)
      end
      response = previous&.dig(:response)
      unless response.nil? || response.equal?(@palette&.dig(:response))
        response.fulfill({"applied" => false, "failureReason" => value ? "Replaced by another dialog" : "User cancelled"})
      end
      value&.dig(:response)&.fulfill({"applied" => false, "failureReason" => "Workspace closed"}) if @closed
      @palette
    end
    def plugins = @plugins ||= Plugins::Registry.new(self)
    def files
      return @files if @files
      @project_entries = @project ? @project.files(include_directories: true).to_a : []
      @files = @project_entries.reject { |path| path.end_with?("/") }
    end
    def message=(value)
      @message = value.to_s
      notify(@message) unless @message.empty?
      @message
    end
    def notify(text, now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      @notifications ||= []
      @notification_id = (@notification_id || 0) + 1
      @notifications << {id: @notification_id, text: text.to_s.slice(0, 2_000), expires: now + 6}
      @notifications.shift while @notifications.length > 3
      @window&.request_frame
      @notification_id
    end
    def notifications = @notifications || []
    def dismiss_notification(id)
      @notifications&.reject! { |item| item[:id] == id }
      @window&.request_frame
    end
    def expire_notifications(now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
      !!@notifications&.reject! { |item| item[:expires] <= now }
    end
    def refresh_files
      @files = @project_tree = @project_entries = nil
      @finder_index = nil
      if @palette && @palette[:kind] == :files
        @palette.delete(:search)
        update_palette
      end
    end
    def layout = @layout
    def vim = @vim_states[editor] ||= Vim.new(editor).tap { |state| state.on_command = ->(command) { ex_command(command) } }
    def open(path)
      absolute = canonical_path(path)
      buffer = @buffers[absolute] ||= File.file?(absolute) ? Buffer.open(absolute) : Buffer.new("", path: absolute)
      @vim_states[editor]&.deactivate unless editor&.buffer.equal?(buffer)
      opened = @active_pane.open(buffer)
      attach_breakpoints(buffer)
      @recent_files ||= []
      @recent_files.delete(absolute)
      @recent_files.unshift(absolute)
      @recent_files.pop if @recent_files.length > 100
      @finder_index = nil
      opened.language = definition_for(absolute)
      apply_editor_settings(opened)
      @project_tree&.reveal(absolute.delete_prefix(@root + File::SEPARATOR))
      invalidate_hidden_selection_ranges
      @window&.request_frame
      opened
    end
    def canonical_path(path)
      absolute = File.expand_path(path, @root)
      return File.realpath(absolute) if File.file?(absolute)
      parent, pieces = File.dirname(absolute), [File.basename(absolute)]
      until File.directory?(parent)
        pieces.unshift(File.basename(parent))
        parent = File.dirname(parent)
      end
      File.join(File.realpath(parent), *pieces)
    end
    def save_buffer(buffer = editor.buffer, path: buffer.path)
      if buffer.is_a?(MultiBuffer)
        buffer.excerpts.map(&:buffer).uniq.each { |source| save_buffer(source) if source.dirty? }
        return buffer
      end
      target = path && canonical_path(path)
      raise Error, "Choose a path before saving" unless target
      existing = @buffers[target]
      raise Error, "Destination is already open in another buffer" if existing && !existing.equal?(buffer)
      previous = buffer.path
      @running_save_actions ||= {}.compare_by_identity
      unless @running_save_actions.key?(buffer)
        @running_save_actions[buffer] = true
        begin
          run_save_actions(buffer) if previous
        rescue StandardError => error
          notify("Save actions failed: #{error.message}")
        ensure
          @running_save_actions.delete(buffer)
        end
      end
      result = buffer.save(target)
      if previous != buffer.path
        relocate_breakpoints(buffer)
        invalidate_hierarchy(buffer)
        invalidate_prepare_rename(buffer)
        invalidate_document_links(buffer)
        invalidate_linked_editing_ranges(buffer)
        invalidate_git
        # Close the old URI before registering this buffer under its new path.
        @opened_lsp_documents&.keys&.each do |client, document|
          next unless document.equal?(buffer)
          begin
            close_language_document(client, document, uri: Sadr::Protocol.uri(previous)) if previous
          rescue StandardError => error
            @message = "File saved; language server close failed: #{error.message}"
          end
        end
        @buffers.delete_if { |_, value| value.equal?(buffer) }
        @buffers[buffer.path] = buffer
        @panes.each do |pane|
          pane.editors.each do |current|
            next unless current.buffer.equal?(buffer)
            current.language = definition_for(buffer.path)
            apply_editor_settings(current)
          end
        end
        refresh_files
      end
      @opened_lsp_documents&.each_key do |client, document|
        next unless document.equal?(buffer)
        begin
          client.save(Sadr::Protocol.uri(buffer.path))
        rescue StandardError => error
          self.message = "File saved; language server notification failed: #{error.message}"
        end
      end
      result
    end
    def new_buffer
      @vim_states[editor]&.deactivate
      buffer = Buffer.new
      @buffers[buffer.object_id] = buffer
      opened = @active_pane.open(buffer)
      apply_editor_settings(opened)
      invalidate_hidden_selection_ranges
      opened
    end
    def focus(pane)
      raise Error, "pane is not in workspace" unless @panes.include?(pane)
      @vim_states[editor]&.deactivate unless pane.equal?(@active_pane)
      @active_pane = pane
      @window&.request_frame
    end
    def activate_tab(pane, tab)
      raise Error, "tab is not in pane" unless pane.editors.include?(tab)
      @vim_states[editor]&.deactivate unless tab.equal?(editor)
      focus(pane)
      pane.activate(pane.editors.index(tab))
      invalidate_hidden_selection_ranges
    end
    def split(direction = :horizontal)
      raise ArgumentError, "invalid split" unless [:horizontal, :vertical].include?(direction)
      pane = Pane.new
      if editor
        opened = pane.open(editor.buffer)
        opened.language = editor.language_document.definition
        apply_editor_settings(opened)
      end
      replace = lambda do |node|
        if node[:pane] == @active_pane
          {direction: direction, children: [node, {pane: pane}]}
        elsif node[:children]
          node.merge(children: node[:children].map { |child| replace.call(child) })
        else node
        end
      end
      @layout = replace.call(@layout)
      @panes << pane
      focus(pane)
      pane
    end
    def close_editor(current = editor, discard: false)
      raise Error, "buffer has unsaved changes" if current.buffer.dirty? && !discard
      pane = @panes.find { |item| item.editors.include?(current) }
      raise Error, "editor is not in workspace" unless pane
      closed = if current.buffer.path && !current.buffer.dirty?
        ClosedTab.new(current.buffer.path, current.selections.map { |selection| [selection.anchor, selection.head] },
          current.scroll_x, current.scroll_y, pane.object_id, pane.editors.index(current))
      end
      sources = current.buffer.is_a?(MultiBuffer) ? current.buffer.excerpts.map(&:buffer).uniq : []
      @vim_states.delete(current)&.dispose
      @sticky_fallback_cache&.delete(current)
      @sticky_context_cache&.clear
      invalidate_document_highlights(editor: current)
      invalidate_folding_ranges(editor: current)
      invalidate_selection_ranges(editor: current)
      invalidate_hierarchy(editor: current)
      invalidate_prepare_rename(editor: current)
      invalidate_document_links(editor: current)
      invalidate_linked_editing_ranges(editor: current)
      invalidate_brackets(current.buffer)
      pane.close(current, discard: discard, activate: @settings["tabs"]["activate_on_close"].to_sym)
      release_buffer(current.buffer, discard: discard)
      sources.each { |source| release_buffer(source, discard: discard) }
      remember_closed_tab(closed) if closed
      close_empty_pane(pane) if pane.editors.empty?
    end

    def request_close(editors = [editor])
      pending = editors.compact.uniq.select { |current| @panes.any? { |pane| pane.editors.include?(current) } }
      while (current = pending.shift)
        if current.buffer.dirty? && @settings["tabs"]["confirm_on_close_dirty"]
          self.palette = {kind: :confirm_tab_close, query: "Save changes to #{File.basename(current.buffer.path || 'Untitled')}?",
            index: 0, matches: ["Save", "Don't Save", "Cancel"], editor: current, remaining: pending,
            refs: buffer_refs(current.buffer)}
          return false
        end
        close_editor(current, discard: current.buffer.dirty?)
      end
      true
    end

    def resolve_tab_close(choice)
      prompt = @palette
      return unless prompt&.dig(:kind) == :confirm_tab_close
      current = prompt[:editor]
      self.palette = nil
      return false if choice == :cancel
      unless buffer_refs(current.buffer) == prompt[:refs]
        self.message = "Close cancelled because the document is now open elsewhere"
        return false
      end
      if choice == :save && !current.buffer.path
        self.palette = {kind: :save_as, query: +"", index: 0, matches: [], after_save: {editor: current, remaining: prompt[:remaining]}}
        return false
      end
      save_buffer(current.buffer) if choice == :save
      close_editor(current, discard: choice == :discard)
      request_close(prompt[:remaining])
    end

    def reopen_closed
      while (closed = @closed_tabs.pop)
        next unless File.file?(closed.path)
        pane = @panes.find { |item| item.object_id == closed.pane_id } || @active_pane
        focus(pane)
        current = open(closed.path)
        pane.editors.delete(current)
        pane.editors.insert(closed.index.clamp(0, pane.editors.length), current)
        pane.active_index = pane.editors.index(current)
        closed.selections.each_with_index do |(anchor, head), index|
          current.select(anchor.clamp(0, current.buffer.rope.bytesize), head.clamp(0, current.buffer.rope.bytesize), add: index.positive?)
        end
        current.scroll(dx: closed.scroll_x, dy: closed.scroll_y)
        return current
      end
      nil
    end

    def buffer_refs(path_or_buffer)
      buffer = path_or_buffer.is_a?(Buffer) ? path_or_buffer : @buffers[canonical_path(path_or_buffer)]
      return [] unless buffer
      refs = @panes.flat_map { |pane| pane.editors.filter_map { |current| [:editor, current.object_id] if current.buffer.equal?(buffer) } }
      @buffers.values.grep(MultiBuffer).each do |multi|
        refs << [:multi_buffer, multi.object_id] if multi.excerpts.any? { |excerpt| excerpt.buffer.equal?(buffer) }
      end
      refs.sort_by { |kind, id| [kind.to_s, id] }
    end
    def clear_vim_states
      @vim_states.each_value(&:dispose)
      @vim_states.clear
    end
    def move_tab(from:, to:, editor: from.active, index: nil)
      raise Error, "unknown pane" unless @panes.include?(from) && @panes.include?(to)
      raise Error, "tab is not in pane" unless from.editors.include?(editor)
      index ||= to.editors.length
      raise Error, "invalid tab position" unless index.is_a?(Integer) && index.between?(0, to.editors.length)
      index -= 1 if from.equal?(to) && from.editors.index(editor) < index
      pinned = from.pinned.include?(editor)
      @vim_states[self.editor]&.deactivate unless editor.equal?(self.editor)
      from.detach(editor)
      to.editors.insert(index, editor)
      to.active_index = index
      to.pin(editor) if pinned
      focus(to)
      invalidate_hidden_selection_ranges
    end

    def new_terminal(cwd: terminal_working_directory)
      options = @settings["terminal"]
      created = Tarazed::PTY.new(command: options["shell"] || ENV.fetch("SHELL", "/bin/sh"), cwd: cwd,
        columns: 100, rows: 12, env: options["env"], scrollback: options["scrollback_lines"],
        queue_limit_bytes: options["queue_limit_bytes"])
      @terminals << created
      @active_terminal_index = @terminals.length - 1
      self.terminal_visible = true
      resize_terminal(*@terminal_dimensions, final: true) if @terminal_dimensions
      @window&.request_frame
      created
    end

    def activate_terminal(index)
      raise IndexError, "terminal tab outside panel" unless index.is_a?(Integer) && index.between?(0, @terminals.length - 1)
      @active_terminal_index = index
      resize_terminal(*@terminal_dimensions, final: true) if @terminal_dimensions
      @window&.request_frame
      terminal
    end

    def move_terminal(from, to)
      raise IndexError, "terminal tab outside panel" unless from.is_a?(Integer) && from.between?(0, @terminals.length - 1) && to.is_a?(Integer) && to.between?(0, @terminals.length - 1)
      current = @terminals.delete_at(from)
      @terminals.insert(to, current)
      @active_terminal_index = to
      current
    end

    def request_terminal_close(index = @active_terminal_index)
      current = @terminals[index]
      return unless current
      if @settings["terminal"]["confirm_close_running"] && current.respond_to?(:busy?) && current.busy?
        self.palette = {kind: :confirm_terminal_close, query: "A process is still running in this terminal.", index: 1,
          matches: ["Close terminal", "Cancel"], terminal: current}
        return false
      end
      close_terminal(index)
    end

    def close_terminal(index = @active_terminal_index)
      active = terminal
      current = @terminals.delete_at(index)
      return unless current
      @terminal_names.delete(current)
      @terminal_sizes&.delete(current)
      @terminal_resize_times&.delete(current)
      current.close if current.respond_to?(:close)
      @active_terminal_index = if current.equal?(active)
        [index, @terminals.length - 1].min.clamp(0, @terminals.length)
      else
        @terminals.index(active) || 0
      end
      self.terminal_visible = false if @terminals.empty? && @settings["terminal"]["hide_when_empty"]
      @window&.request_frame
      current
    end

    def restart_terminal(index = @active_terminal_index)
      current = @terminals[index]
      return unless current
      cwd = current.vt.cwd || (current.respond_to?(:initial_cwd) ? current.initial_cwd : @root)
      name = @terminal_names[current]
      close_terminal(index)
      replacement = new_terminal(cwd: File.directory?(cwd) ? cwd : @root)
      move_terminal(@terminals.length - 1, index) if index < @terminals.length - 1
      rename_terminal(name, replacement) if name
      replacement
    end

    def terminal_title(current = terminal)
      return "Terminal" unless current
      title = @terminal_names[current] || current.vt.title.to_s.then { |value| value.empty? ? nil : value } ||
        current.vt.cwd&.then { |cwd| File.basename(cwd).empty? ? cwd : File.basename(cwd) } ||
        (current.respond_to?(:foreground_process_name) ? current.foreground_process_name : nil) ||
        (current.respond_to?(:command_name) ? current.command_name : nil) || "shell"
      title.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).scrub.slice(0, 200)
    end

    def rename_terminal(name, current = terminal)
      return unless current
      value = name.to_s.strip
      value.empty? ? @terminal_names.delete(current) : @terminal_names[current] = value.slice(0, 200)
    end

    def drain_terminals(now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      return false if @terminals.empty?
      remaining = @settings["terminal"]["max_bytes_per_frame"]
      deadline = now + 0.004
      changed = false
      order = @terminals.rotate(@terminal_poll_index.to_i % @terminals.length)
      @terminal_poll_index = @terminal_poll_index.to_i + 1
      order.each do |current|
        break if remaining <= 0 || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        method = current.method(:read)
        keywords = method.parameters.any? { |kind, _| [:key, :keyreq, :keyrest].include?(kind) }
        data = keywords ? current.read(max_bytes: remaining, max_seconds: [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max) : current.read
        changed ||= !!(data && !data.empty?)
        remaining -= data.bytesize if data
      end
      reap_exited_terminals
      @window&.request_frame if changed || @terminals.any? { |current| current.respond_to?(:pending?) && current.pending? }
      changed
    end

    def resize_terminal(columns, rows, final: false, now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      minimum = @settings["terminal"]
      dimensions = [[columns.to_i, minimum["min_cols"]].max, [rows.to_i, minimum["min_rows"]].max]
      @terminal_dimensions = dimensions
      return if @terminals.empty?
      final ||= @terminal_resize_final
      @terminal_resize_final = false
      wait = minimum["resize_debounce_ms"] / 1000.0
      @terminals.each do |current|
        previous = (@terminal_resize_times ||= {})[current]
        next if !final && previous && now - previous < wait
        next if (@terminal_sizes ||= {})[current] == dimensions
        current.resize(columns: dimensions.first, rows: dimensions.last)
        @terminal_sizes[current] = dimensions
        @terminal_resize_times[current] = now
      end
    end

    def flush_terminal_resize
      resize_terminal(*@terminal_dimensions, final: true) if @terminal_dimensions
      @terminal_resize_final = true
    end

    def toggle_dock(side)
      dock = @docks.fetch(side)
      dock[:visible] = !dock[:visible]
    end
    def register_panel(name, side: :left, &render)
      definition = @panels.register(Panel::Definition.new(name, name.to_s, nil, side, render, nil))
      register_action("panel.#{name}") { @panels.show(definition.id) }
      definition
    end
    def register_action(name, description: name, category: name.to_s.split(".", 2).first, condition: "", keybinding: Command::DEFAULT_KEYBINDINGS[name.to_s], &block)
      @commands.register(Command::Definition.new(name.to_s, description, category, condition, block, keybinding))
    end
    def definition_for(path)
      @languages.values.find { |definition| definition.extensions.include?(File.extname(path.to_s)) || definition.extensions.include?(File.basename(path.to_s)) } || Language.for_path(path)
    end
    def register_language(name, extensions:, lexer: "plaintext", comment: "#", indent_open: "[\\[{(]\\s*$", indent_close: "^\\s*[\\]})]", servers: [])
      raise ArgumentError, "language extensions must be strings" unless extensions.is_a?(Array) && extensions.all? { |extension| extension.is_a?(String) }
      @languages[name] = Language::Definition.new(name, lexer, extensions.freeze, comment, Regexp.new(indent_open), Regexp.new(indent_close), servers)
      @panes.each do |pane|
        pane.editors.each do |current|
          current.language = definition_for(current.buffer.path)
          apply_editor_settings(current)
        end
      end
    end
    def command_context(terminal: false)
      {"Terminal" => terminal, "Editor" => !!editor,
       "vim_mode" => @settings["vim_mode"] && editor ? vim.mode.to_s : false}
    end
    def call(name, *args, context: nil)
      context ||= @active_command_context || command_context
      previous, @active_command_context = @active_command_context, context
      @commands.call(name, *args, context: context)
      @window&.request_frame
    rescue StandardError => error
      @message = error.message
      @window&.request_frame
    ensure
      @active_command_context = previous
    end

    def theme=(theme)
      @theme = theme.is_a?(Theme) ? theme : Theme.new(name: theme)
      @window&.request_frame
    end
    def palette_open(kind, command_ids: nil, context: nil)
      self.palette = {kind: kind, query: +"", index: 0, matches: []}
      if kind == :commands
        @palette[:command_context] = context || @active_command_context || command_context
        @palette[:command_ids] = command_ids if command_ids
      end
      if [:search, :replace_query, :project_search].include?(kind)
        @palette[:search_options] = {regexp: false, case_sensitive: true, whole_word: false, selection_only: false}
        @palette[:selection] = editor.primary.range unless editor.primary.empty?
        @palette[:editor], @palette[:version] = editor, editor.buffer.version
      end
      update_palette
    end
    def show_snippet_choices(current = editor)
      choices = current.snippet_choices
      return unless choices
      self.palette = {kind: :snippet_choices, editor: current, query: +"", index: 0, matches: choices.dup}
    end
    def update_palette
      return unless @palette
      if @palette[:kind] == :commands
        context = @palette.fetch(:command_context)
        definitions = @commands.each(context: context).to_a
        ids = @palette[:command_ids]
        definitions = definitions.select { |definition| ids.include?(definition.id) } if ids
        @palette[:command_definitions] = definitions
        session = @palette[:search] ||= Spica::Index.new(definitions.map(&:title)).session
        session.query = @palette[:query]
        matches = session.matches(12)
        @palette[:indices] = matches.map(&:index)
        @palette[:matches] = matches.map(&:candidate)
        @palette[:index] = @palette[:index].clamp(0, [@palette[:matches].length - 1, 0].max)
        return
      end
      if @palette[:kind] == :completion
        labels = @palette[:all_matches] ||= @palette[:matches].dup
        candidates = @palette[:items].map do |item|
          item.is_a?(Provider::Completion) ? item.filter_text || item.label : item["filterText"] || item.fetch("label")
        end
        groups = @palette[:completion_indices] ||= candidates.each_with_index.each_with_object({}) do |(candidate, index), grouped|
          (grouped[candidate] ||= []) << index
        end
        session = @palette[:search] ||= Spica::Index.new(groups.keys, tie_break: :index).session
        session.query = @palette[:query]
        matches = session.matches(12)
        @palette[:indices] = matches.flat_map { |match| groups.fetch(match.candidate) }.first(12)
        @palette[:matches] = @palette[:indices].map { |index| labels.fetch(index) }
        @palette[:index] = 0
        return
      end
      if @palette[:kind] == :workspace_symbol_results
        labels = @palette.fetch(:all_matches)
        if @palette[:query].empty?
          @palette[:indices] = (0...[labels.length, 12].min).to_a
          @palette[:matches] = @palette[:indices].map { |index| labels.fetch(index) }
        else
          session = @palette[:search] ||= @palette.fetch(:workspace_symbol_index).session
          session.query = @palette[:query]
          groups = @palette.fetch(:workspace_symbol_groups)
          @palette[:indices] = session.matches(12).flat_map { |match| groups.fetch(match.candidate) }.first(12)
          @palette[:matches] = @palette[:indices].map { |index| labels.fetch(index) }
        end
        @palette[:index] = 0
        return
      end
      if [:locations, :symbols, :code_actions, :outline, :branches, :settings_keys, :snippet_choices,
          :breadcrumbs, :hierarchy_roots, :language_servers, :debug_configurations, :debug_watch_remove].include?(@palette[:kind])
        labels = @palette[:all_matches] ||= @palette[:matches].dup
        index = @palette[:kind] == :language_servers ? Spica::Index.new(labels, tie_break: :index) : Spica::Index.new(labels)
        session = @palette[:search] ||= index.session
        session.query = @palette[:query]
        matches = session.matches(12)
        @palette[:indices] = matches.map(&:index)
        @palette[:matches] = matches.map(&:candidate)
        @palette[:index] = 0
        return
      end
      @palette[:search] ||= case @palette[:kind]
      when :files
        @finder_index ||= Spica::Index.new(((@recent_files || []).select { |path| File.file?(path) }.map { |path| path.delete_prefix(@root + File::SEPARATOR) } + files).uniq, tie_break: :index)
        @finder_index.session
      end
      @palette[:matches] = if @palette[:search]
        @palette[:search].query = @palette[:query]
        @palette[:search].matches(12).map(&:candidate)
      else []
      end
      @palette[:index] = @palette[:index].clamp(0, [@palette[:matches].length - 1, 0].max)
    end
    def palette_accept
      return accept_breakpoint_palette if [:breakpoint_actions, :breakpoint_edit].include?(@palette[:kind])
      return accept_debug_watch_palette if [:debug_watch_add, :debug_watch_remove].include?(@palette[:kind])
      search_state = @palette.slice(:search_options, :selection, :editor, :version)
      after_save = @palette[:after_save]
      if @palette[:kind] == :snippet_choices
        current = @palette
        self.palette = nil
        return @panes.any? { |pane| pane.editors.include?(current[:editor]) } && current[:editor].choose_snippet(current[:matches][current[:index]])
      elsif [:completion, :locations, :symbols, :code_actions, :workspace_symbol_results].include?(@palette[:kind])
        current = @palette
        self.palette = nil
        index = current[:indices] ? current[:indices][current[:index]] : current[:index]
        return accept_language_result(current, index) if index
      elsif @palette[:kind] == :outline
        current = @palette
        index = @palette[:indices] ? @palette[:indices][@palette[:index]] : @palette[:index]
        symbol = index && @palette[:items][index]
        self.palette = nil
        if symbol && current[:editor].equal?(editor) && current[:version] == editor.buffer.version && current[:document].equal?(editor.language_document)
          editor.select(symbol.selection.begin)
          editor.reveal_cursor
        end
        return
      elsif @palette[:kind] == :breadcrumbs
        current = @palette
        index = current[:indices] ? current[:indices][current[:index]] : current[:index]
        self.palette = nil
        return accept_breadcrumb_palette(current, index)
      elsif @palette[:kind] == :hierarchy_roots
        current = @palette
        index = current[:indices] ? current[:indices][current[:index]] : current[:index]
        self.palette = nil
        return accept_hierarchy_root(current, index)
      elsif @palette[:kind] == :language_servers
        current = @palette
        index = current[:indices] ? current[:indices][current[:index]] : current[:index]
        server = index && current[:items][index]
        self.palette = nil
        return restart_language_server(server[:language], server[:index]) if server
      elsif @palette[:kind] == :debug_configurations
        current = @palette
        index = current[:indices] ? current[:indices][current[:index]] : current[:index]
        configuration = index && current[:items][index]
        self.palette = nil
        return start_debugging(configuration.fetch("name")) if configuration
      elsif @palette[:kind] == :problem_filter
        query = @palette[:query]
        self.palette = nil
        return apply_problem_filter(query)
      elsif @palette[:kind] == :rename && @palette[:rename]
        current = @submitting_rename_palette = @palette
        begin
          self.palette = nil
        ensure
          @submitting_rename_palette = nil
        end
        return rename_prepared(current[:rename], current[:query])
      end
      selected = @palette[:matches][@palette[:index]]
      selected_command = if @palette[:kind] == :commands && selected
        index = @palette[:indices] ? @palette[:indices][@palette[:index]] : @palette[:index]
        @palette[:command_definitions][index]
      end
      command_context = @palette[:command_context]
      kind, query, pattern = @palette.values_at(:kind, :query, :pattern)
      self.palette = nil
      if kind == :files && selected
        open(selected)
      elsif kind == :commands && selected_command
        call(selected_command.id, context: command_context)
      elsif kind == :search
        pattern, options = search_query(query, search_state)
        matches = editor.search(pattern, **options)
        @minimap.record_search(editor.buffer, editor.buffer.version, matches)
        editor.select(matches.first.begin, matches.first.end) unless matches.empty?
        @message = "#{matches.length} matches"
      elsif kind == :project_search
        search_project(query, **search_state.fetch(:search_options, {}).reject { |key, _| key == :selection_only })
      elsif kind == :replace_query
        search_query(query, search_state) # Validate before accepting replacement text.
        self.palette = {kind: :replace_value, query: +"", pattern: query, index: 0, matches: [], **search_state}
      elsif kind == :replace_value
        expression, options = search_query(pattern, search_state)
        @message = "#{replace_in_buffer(expression, query, **options)} replacements (unsaved)"
      elsif kind == :save_as
        current = after_save&.dig(:editor)
        save_buffer(current&.buffer || editor.buffer, path: query)
        if current
          close_editor(current)
          request_close(after_save[:remaining])
        end
      elsif kind == :rename
        language_request(:rename, name: query)
      elsif kind == :workspace_symbols
        language_request(:workspace_symbols, query: query)
      elsif kind == :create_file || kind == :create_folder
        create_project_entry(query, directory: kind == :create_folder)
      elsif kind == :rename_file
        rename_project_entry(@selected_project_path, query)
      elsif kind == :trash_file && selected == "Move to trash"
        trash_project_entry(@selected_project_path)
      elsif kind == :branches && selected
        checkout_branch(selected)
      elsif kind == :settings_keys && selected
        editor.insert_text("#{JSON.generate(selected)}: #{JSON.generate(Settings::DEFAULTS.fetch(selected))}", auto_indent: false)
      end
    end
    def search_query(query, state)
      if state[:editor] && (!state[:editor].equal?(editor) || state[:version] != editor.buffer.version)
        raise Error, "Document changed; open search again"
      end
      options = state.fetch(:search_options, {})
      pattern = options[:regexp] ? Regexp.new(query, options[:case_sensitive] == false ? Regexp::IGNORECASE : 0, timeout: 0.25) : query
      search_options = options.slice(:case_sensitive, :whole_word)
      if options[:selection_only]
        raise Error, "Select text before opening search" unless state[:selection]
        search_options[:range] = state[:selection]
      end
      [pattern, search_options]
    end
    def connect_server(language, command)
      options = normalize_server_configuration(command)
      (@client_lock ||= Mutex.new).synchronize { ensure_language_server(language, options) }
    end
    def drain
      if @main_queue
        loop do
          callback = @main_queue.pop(true)
          begin
            callback.call unless @closed
          rescue StandardError => error
            @message = error.message
          end
        end
      end
    rescue ThreadError
      nil
    end
    def close
      @closed = true
      cancel_workspace_symbol_search
      cancel_completion_requests
      cancel_project_search
      invalidate_hierarchy
      invalidate_document_highlights
      invalidate_folding_ranges
      invalidate_selection_ranges
      invalidate_prepare_rename
      invalidate_document_links
      invalidate_linked_editing_ranges
      invalidate_inlay_hints
      @inlay_hint_requests&.clear
      invalidate_code_lenses
      invalidate_sticky_symbols
      @sticky_symbol_requests&.clear
      @palette&.dig(:response)&.fulfill({"applied" => false, "failureReason" => "Workspace closed"})
      self.palette = nil
      @plugins&.close
      failure = nil
      cleanup = lambda do |&operation|
        operation.call
      rescue StandardError => error
        failure ||= error
      end
      cleanup.call { stop_debugging }
      cleanup.call { @breakpoints.close }
      cleanup.call { @minimap.close }
      cleanup.call { @watcher&.close }
      cleanup.call { stop_language_servers }
      terminal_closers = @terminals.filter_map do |current|
        Thread.new { current.close } if current.respond_to?(:close)
      end
      terminal_closers.each { |thread| cleanup.call { thread.join } }
      @terminals.clear
      cleanup.call { clear_vim_states }
      @panes.each { |pane| pane.editors.each { |current| cleanup.call { current.dispose } } }
      @buffers.each_value { |buffer| cleanup.call { buffer.close } }
      raise failure if failure
    end

    private
    def register_actions
      register_action("file.new") { new_buffer }
      register_action("file.save") { editor.buffer.path || editor.buffer.is_a?(MultiBuffer) ? save_buffer : palette_open(:save_as) }
      register_action("file.close") { request_close }
      register_action("tab.close") { request_close }
      register_action("tab.close_others") { request_close(@active_pane.editors.reject { |current| current.equal?(editor) }) }
      register_action("tab.close_right") { request_close(@active_pane.editors.drop(@active_pane.active_index + 1)) }
      register_action("tab.close_saved") { request_close(@active_pane.editors.reject { |current| current.buffer.dirty? }) }
      register_action("tab.close_all") { request_close(@active_pane.editors.dup) }
      register_action("tab.reopen_closed") { reopen_closed }
      register_action("pane.close") { request_close(@active_pane.editors.dup) }
      register_action("debug.buffer_refs") { self.message = buffer_refs(editor.buffer).map { |kind, id| "#{kind}:#{id}" }.join(", ") }
      register_action("debug.start", description: "Start Debugging") { start_debugging }
      register_action("debug.stop", description: "Stop Debugging") { stop_debugging }
      register_action("debug.watch.add", description: "Add Debug Watch") { show_debug_watch_add }
      register_action("debug.watch.remove", description: "Remove Debug Watch") { show_debug_watch_remove }
      register_action("file.find") { palette_open(:files) }
      register_action("project.new_file") { project_prompt(:create_file) }
      register_action("project.new_folder") { project_prompt(:create_folder) }
      register_action("project.rename") { project_prompt(:rename_file) }
      register_action("project.trash") { project_prompt(:trash_file) }
      register_action("git.diff") { show_git_diff }
      register_action("git.toggle_hunk") { toggle_git_hunk }
      register_action("git.blame") { show_git_blame }
      register_action("git.revert_hunk") { revert_current_hunk }
      register_action("git.branches") { self.palette = {kind: :branches, query: +"", index: 0, matches: git ? git.branches : []} }
      register_action("command.palette") { palette_open(:commands) }
      register_action("pane.split_right") { split(:horizontal) }
      register_action("pane.split_down") { split(:vertical) }
      register_action("pane.next") { focus(@panes[(@panes.index(@active_pane) + 1) % @panes.length]) }
      register_action("tab.pin") { @active_pane.pin }
      register_action("tab.back") { @vim_states[editor]&.deactivate; @active_pane.back; invalidate_hidden_selection_ranges }
      register_action("tab.forward") { @vim_states[editor]&.deactivate; @active_pane.forward; invalidate_hidden_selection_ranges }
      register_action("edit.undo") { editor.undo }
      register_action("edit.redo") { editor.redo }
      register_action("edit.select_all") { editor.select_all }
      register_action("edit.select_next") { editor.select_next_occurrence }
      register_action("edit.select_all_occurrences") { editor.select_next_occurrence(all: true) }
      register_action("edit.duplicate_line") { editor.duplicate_lines }
      %i[up down].each do |direction|
        register_action("edit.move_line_#{direction}") { editor.move_lines(direction); editor.reveal_cursor }
        register_action("editor.paragraph_#{direction}") { editor.move(:"paragraph_#{direction}") }
      end
      register_action("edit.toggle_comment") { editor.toggle_comment(prefix: editor.language_document.definition.comment) }
      register_action("language.outline") { show_outline }
      register_action("language.workspace_symbols", description: "Workspace Symbols") { palette_open(:workspace_symbols) }
      %i[completion hover definition typeDefinition implementation references formatting codeAction signatureHelp documentSymbol inlayHint codeLens diagnostic semantic_tokens].each do |kind|
        register_action("language.#{kind}") { language_request(kind) }
      end
      register_action("language.rename") { prepare_rename }
      register_action("language.linked_editing") { linked_editing_range }
      register_action("language.call_hierarchy") { show_call_hierarchy }
      register_action("language.type_hierarchy") { show_type_hierarchy }
      register_action("language.expand_selection") { expand_selection }
      register_action("language.shrink_selection") { shrink_selection }
      register_action("editor.fold") { fold_current }
      register_action("editor.unfold") { editor.display_map.unfold(editor.primary.head) }
      register_action("edit.indent") { editor.indent }
      register_action("edit.outdent") { editor.indent(outdent: true) }
      register_action("search.buffer") { palette_open(:search) }
      register_action("search.project") { @panels.fetch("search").build.call }
      register_action("search.replace") { palette_open(:replace_query) }
      register_action("settings.open") { open_settings }
      register_action("settings.complete") { settings_completions }
      register_action("language.diagnostics") { show_diagnostics }
      register_action("language.restart_server") { show_language_server_restart }
      register_action("view.project") { @panels.toggle("explorer") }
      register_action("panel.explorer") { @panels.toggle("explorer") }
      register_action("panel.search") { @panels.fetch("search").build.call }
      register_action("panel.terminal") { @terminals.empty? ? new_terminal : @panels.toggle("terminal") }
      register_action("panel.hierarchy") { @panels.toggle("hierarchy") if @hierarchy_state }
      register_action("panel.problems") { @panels.toggle("problems") }
      register_action("panel.debug") { @panels.toggle("debug") }
      register_action("problems.filter") { show_problem_filter }
      [:left, :right, :bottom].each { |side| register_action("view.dock_#{side}") { toggle_dock(side) } }
      register_action("view.wrap") { editor.display_map.wrap_width = editor.display_map.wrap_map.width ? nil : 100 }
      register_action("view.theme") { self.theme = @theme.name.include?("Dark") ? "Canopus Light" : "Canopus Dark" }
      register_action("view.vim") do
        @settings.merge!("vim_mode" => !@settings["vim_mode"])
        clear_vim_states unless @settings["vim_mode"]
      end
      register_action("view.terminal") do
        @terminals.empty? ? new_terminal : @panels.toggle("terminal")
      end
      register_action("terminal.toggle") { call("view.terminal") }
      register_action("terminal.new") { new_terminal }
      register_action("terminal.close") { request_terminal_close }
      register_action("terminal.restart") { restart_terminal }
      register_action("terminal.next") { activate_terminal((@active_terminal_index + 1) % @terminals.length) unless @terminals.empty? }
      register_action("terminal.prev") { activate_terminal((@active_terminal_index - 1) % @terminals.length) unless @terminals.empty? }
      9.times { |index| register_action("terminal.select_#{index + 1}") { activate_terminal(index) if index < @terminals.length } }
      register_action("terminal.rename") { self.palette = {kind: :terminal_rename, query: +"", index: 0, matches: []} if terminal }
      register_action("terminal.clear") { terminal&.grid&.reset }
    end
    def encode_layout(node)
      node[:pane] ? {pane: @panes.index(node[:pane])} : {direction: node[:direction], ratio: node.fetch(:ratio, 0.5), children: node[:children].map { |child| encode_layout(child) }}
    end
    def project_prompt(kind)
      path = @selected_project_path || editor.buffer.path&.delete_prefix(@root + File::SEPARATOR) || ""
      @selected_project_path = path
      query = if kind == :rename_file || kind == :trash_file
        path
      else
        directory = File.directory?(File.join(@root, path)) ? path : File.dirname(path)
        directory == "." || directory.empty? ? "" : directory + "/"
      end
      self.palette = {kind: kind, query: +query, index: 0, matches: kind == :trash_file ? ["Move to trash", "Cancel"] : []}
    end
    def decode_layout(node, depth = 0, panes: @panes)
      raise Error, "session layout too deep" if depth > 32
      if node.key?("pane")
        {pane: panes.fetch(node["pane"])}
      else
        direction = node.fetch("direction").to_sym
        raise Error, "invalid split direction" unless [:horizontal, :vertical].include?(direction)
        children = node.fetch("children")
        raise Error, "split must contain two panes" unless children.is_a?(Array) && children.length == 2
        ratio = node.fetch("ratio", 0.5)
        raise Error, "invalid split ratio" unless ratio.is_a?(Numeric) && ratio.between?(0.1, 0.9)
        {direction: direction, ratio: ratio, children: children.map { |child| decode_layout(child, depth + 1, panes: panes) }}
      end
    end
    def ex_command(command)
      case command
      when "w" then call("file.save")
      when /\Aw / then save_buffer(path: command.delete_prefix("w "))
      when "q" then call("file.close")
      when "q!" then close_editor(discard: true)
      when "wq" then call("file.save"); call("file.close")
      when "split", "sp" then split(:vertical)
      when "vsplit", "vs" then split(:horizontal)
      else open(command.delete_prefix("e ")) if command.start_with?("e ")
      end
    end

    def remember_closed_tab(closed)
      limit = @settings["tabs"]["reopen_history_limit"]
      return if limit.zero?
      @closed_tabs << closed
      @closed_tabs.shift while @closed_tabs.length > limit
    end

    def release_buffer(buffer, discard: false)
      return unless buffer_refs(buffer).empty?
      return if buffer.dirty? && !discard
      @minimap.release(buffer)
      invalidate_sticky_symbols(buffer)
      close_language_documents(buffer)
      detach_breakpoints(buffer)
      @buffers.delete_if { |_, current| current.equal?(buffer) }
      buffer.close
    end

    def close_empty_pane(pane)
      return unless @settings["tabs"]["close_empty_pane"] && @panes.length > 1
      sibling = nil
      collapse = lambda do |node|
        return nil if node[:pane].equal?(pane)
        return node if node[:pane]
        children = node[:children].map { |child| collapse.call(child) }
        sibling ||= layout_pane(children.compact.first) if children.any?(&:nil?)
        children.compact!
        children.length == 1 ? children.first : node.merge(children: children)
      end
      @layout = collapse.call(@layout)
      @panes.delete(pane)
      @active_pane = sibling || @panes.first if @active_pane.equal?(pane)
    end

    def layout_pane(node) = node&.dig(:pane) || layout_pane(node&.dig(:children)&.first)

    def terminal_working_directory
      value = @settings["terminal"]["working_directory"]
      path = case value
      when "project" then @root
      when "current_file" then editor&.buffer&.path ? File.dirname(editor.buffer.path) : @root
      when "home" then Dir.home
      else File.expand_path(value, @root)
      end
      raise Error, "terminal working directory does not exist" unless File.directory?(path)
      path
    end

    def reap_exited_terminals
      policy = @settings["terminal"]["close_on_exit"]
      @terminals.dup.each do |current|
        next unless current.respond_to?(:alive?) && !current.alive?
        clean = !current.respond_to?(:status) || current.status&.success?
        close_terminal(@terminals.index(current)) if policy == "always" || (policy == "clean" && clean)
      end
    end
  end
end

require_relative "workspace/session_persistable"
require_relative "workspace/project_tree_editable"
require_relative "workspace/file_change_aware"
require_relative "workspace/language_server_configurable"
require_relative "workspace/language_aware"
require_relative "workspace/hierarchy_aware"
require_relative "workspace/problems_aware"
require_relative "workspace/git_aware"
require_relative "workspace/project_searchable"
require_relative "workspace/settings_aware"
require_relative "workspace/file_previewable"
require_relative "workspace/debug_aware"
Canopus::Workspace.include Canopus::Workspace::SessionPersistable
Canopus::Workspace.include Canopus::Workspace::ProjectTreeEditable
Canopus::Workspace.include Canopus::Workspace::FileChangeAware
Canopus::Workspace.include Canopus::Workspace::LanguageServerConfigurable
Canopus::Workspace.include Canopus::Workspace::LanguageAware
Canopus::Workspace.include Canopus::Workspace::HierarchyAware
Canopus::Workspace.include Canopus::Workspace::ProblemsAware
Canopus::Workspace.include Canopus::Workspace::GitAware
Canopus::Workspace.include Canopus::Workspace::ProjectSearchable
Canopus::Workspace.include Canopus::Workspace::SettingsAware
Canopus::Workspace.include Canopus::Workspace::FilePreviewable
Canopus::Workspace.include Canopus::Workspace::DebugAware

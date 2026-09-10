# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "settings"
require_relative "theme"
require_relative "vim"
require_relative "lsp"
require_relative "pane"
require_relative "project/tree"

module Canopus
  class Workspace
    attr_reader :panes, :active_pane, :buffers, :actions, :settings, :theme, :project, :clients, :root, :docks, :panels
    attr_accessor :window, :show_project, :terminal, :terminal_visible, :selected_project_path, :performance
    attr_reader :message, :palette

    def initialize(root: Dir.pwd, settings: nil)
      @root = File.realpath(root)
      @settings = settings || Settings.new(Settings.user_path, File.join(@root, ".canopus", "settings.jsonc"))
      @panes, @buffers = [Pane.new], {}
      @active_pane = @panes.first
      @layout = {pane: @active_pane}
      @theme = Theme.new(name: @settings["theme"])
      @actions, @clients, @vim_states = Zaniah::Input::ActionRegistry.new, {}, {}
      @show_project, @message = true, ""
      @project = Project.new(@root) if defined?(Project)
      @docks = {left: {visible: true, size: 220}, right: {visible: false, size: 260}, bottom: {visible: false, size: 220}}
      @panels, @languages = {}, {}
      register_actions
    end
    def editor = @active_pane.active
    def palette=(value)
      previous, @palette = @palette, @closed ? nil : value
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
      @recent_files ||= []
      @recent_files.delete(absolute)
      @recent_files.unshift(absolute)
      @recent_files.pop if @recent_files.length > 100
      @finder_index = nil
      opened.language = definition_for(absolute)
      apply_editor_settings(opened)
      @project_tree&.reveal(absolute.delete_prefix(@root + File::SEPARATOR))
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
      result = buffer.save(target)
      if previous != buffer.path
        invalidate_git
        # Close the old URI before registering this buffer under its new path.
        @opened_lsp_documents&.keys&.each do |client, document|
          next unless document.equal?(buffer)
          @opened_lsp_documents.delete([client, document])
          begin
            client.close_document(LSP::Protocol.uri(previous)) if previous
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
          client.save_document(LSP::Protocol.uri(buffer.path))
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
      opened
    end
    def focus(pane)
      raise Error, "pane is not in workspace" unless @panes.include?(pane)
      @vim_states[editor]&.deactivate unless pane.equal?(@active_pane)
      @active_pane = pane
      new_buffer unless editor
      @window&.request_frame
    end
    def activate_tab(pane, tab)
      raise Error, "tab is not in pane" unless pane.editors.include?(tab)
      @vim_states[editor]&.deactivate unless tab.equal?(editor)
      focus(pane)
      pane.activate(pane.editors.index(tab))
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
      @vim_states.delete(current)&.dispose
      pane.close(current, discard: discard)
      remaining = @panes.flat_map(&:editors).any? { |item| item.buffer.equal?(current.buffer) }
      remaining ||= @buffers.values.grep(MultiBuffer).any? { |multi| multi.excerpts.any? { |excerpt| excerpt.buffer.equal?(current.buffer) } }
      unless remaining
        close_language_documents(current.buffer)
        @buffers.delete_if { |_, buffer| buffer.equal?(current.buffer) }
        current.buffer.close
      end
      new_buffer unless editor
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
    end
    def toggle_dock(side)
      dock = @docks.fetch(side)
      dock[:visible] = !dock[:visible]
    end
    def register_panel(name, side: :left, &render)
      raise ArgumentError, "invalid dock side" unless @docks.key?(side)
      @panels[name] = [side, render]
      register_action("panel.#{name}") { @docks[side][:visible] = true }
    end
    def register_action(name, description: name, &block) = @actions.register(name, description: description, &block)
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
    def call(name, *args)
      @actions.call(name, *args)
      @window&.request_frame
    rescue StandardError => error
      @message = error.message
      @window&.request_frame
    end

    def theme=(theme)
      @theme = theme.is_a?(Theme) ? theme : Theme.new(name: theme)
      @window&.request_frame
    end
    def palette_open(kind)
      self.palette = {kind: kind, query: +"", index: 0, matches: []}
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
      if [:completion, :locations, :symbols, :code_actions, :outline, :branches, :settings_keys, :snippet_choices].include?(@palette[:kind])
        labels = @palette[:all_matches] ||= @palette[:matches].dup
        session = @palette[:search] ||= Spica::Index.new(labels).session
        session.query = @palette[:query]
        matches = session.matches(12)
        @palette[:indices] = matches.map(&:index)
        @palette[:matches] = matches.map(&:candidate)
        @palette[:index] = 0
        return
      end
      @palette[:search] ||= case @palette[:kind]
      when :commands then Spica::Index.new(@actions.entries.keys).session
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
      search_state = @palette.slice(:search_options, :selection, :editor, :version)
      if @palette[:kind] == :snippet_choices
        current = @palette
        self.palette = nil
        return @panes.any? { |pane| pane.editors.include?(current[:editor]) } && current[:editor].choose_snippet(current[:matches][current[:index]])
      elsif [:completion, :locations, :symbols, :code_actions].include?(@palette[:kind])
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
      end
      selected = @palette[:matches][@palette[:index]]
      kind, query, pattern = @palette.values_at(:kind, :query, :pattern)
      self.palette = nil
      if kind == :files && selected
        open(selected)
      elsif kind == :commands && selected
        call(selected)
      elsif kind == :search
        pattern, options = search_query(query, search_state)
        matches = editor.search(pattern, **options)
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
        save_buffer(path: query)
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
      options = normalize_server_options({"command" => command})
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
      cancel_project_search
      @palette&.dig(:response)&.fulfill({"applied" => false, "failureReason" => "Workspace closed"})
      self.palette = nil
      @plugins&.close
      @watcher&.close
      stop_language_servers
      @terminal&.close
      clear_vim_states
      @panes.each { |pane| pane.editors.each(&:dispose) }
      @buffers.each_value(&:close)
    end

    private
    def register_actions
      register_action("file.new") { new_buffer }
      register_action("file.save") { editor.buffer.path || editor.buffer.is_a?(MultiBuffer) ? save_buffer : palette_open(:save_as) }
      register_action("file.close") { close_editor }
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
      register_action("tab.back") { @vim_states[editor]&.deactivate; @active_pane.back }
      register_action("tab.forward") { @vim_states[editor]&.deactivate; @active_pane.forward }
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
      register_action("language.workspace_symbols") { palette_open(:workspace_symbols) }
      %i[completion hover definition typeDefinition implementation references formatting codeAction signatureHelp documentSymbol inlayHint codeLens diagnostic semantic_tokens].each do |kind|
        register_action("language.#{kind}") { language_request(kind) }
      end
      register_action("language.rename") { self.palette = {kind: :rename, query: +"", index: 0, matches: []} }
      register_action("editor.fold") { fold_current }
      register_action("editor.unfold") { editor.display_map.unfold(editor.primary.head) }
      register_action("edit.indent") { editor.indent }
      register_action("edit.outdent") { editor.indent(outdent: true) }
      register_action("search.buffer") { palette_open(:search) }
      register_action("search.project") { palette_open(:project_search) }
      register_action("search.replace") { palette_open(:replace_query) }
      register_action("settings.open") { open_settings }
      register_action("settings.complete") { settings_completions }
      register_action("language.diagnostics") { show_diagnostics }
      register_action("view.project") { @show_project = !@show_project }
      [:left, :right, :bottom].each { |side| register_action("view.dock_#{side}") { toggle_dock(side) } }
      register_action("view.wrap") { editor.display_map.wrap_width = editor.display_map.wrap_map.width ? nil : 100 }
      register_action("view.theme") { self.theme = @theme.name.include?("Dark") ? "Canopus Light" : "Canopus Dark" }
      register_action("view.vim") do
        @settings.merge!("vim_mode" => !@settings["vim_mode"])
        clear_vim_states unless @settings["vim_mode"]
      end
      register_action("view.terminal") do
        @terminal ||= Terminal::PTY.new(cwd: @root, columns: 100, rows: 12)
        @terminal_visible = !@terminal_visible
      end
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
  end
end

require_relative "workspace/session_persistable"
require_relative "workspace/project_tree_editable"
require_relative "workspace/file_change_aware"
require_relative "workspace/language_server_configurable"
require_relative "workspace/language_aware"
require_relative "workspace/git_aware"
require_relative "workspace/project_searchable"
require_relative "workspace/settings_aware"
require_relative "workspace/file_previewable"
Canopus::Workspace.include Canopus::Workspace::SessionPersistable
Canopus::Workspace.include Canopus::Workspace::ProjectTreeEditable
Canopus::Workspace.include Canopus::Workspace::FileChangeAware
Canopus::Workspace.include Canopus::Workspace::LanguageServerConfigurable
Canopus::Workspace.include Canopus::Workspace::LanguageAware
Canopus::Workspace.include Canopus::Workspace::GitAware
Canopus::Workspace.include Canopus::Workspace::ProjectSearchable
Canopus::Workspace.include Canopus::Workspace::SettingsAware
Canopus::Workspace.include Canopus::Workspace::FilePreviewable

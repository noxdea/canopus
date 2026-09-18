# frozen_string_literal: true

module Canopus
  module Workspace::SettingsAware
    def icon_theme
      require_relative "../icon_theme"
      @icon_theme ||= IconTheme.new(@settings["icon_theme"] && File.expand_path(@settings["icon_theme"], @root))
    end
    def settings_path = File.join(@root, ".canopus", "settings.jsonc")
    def open_settings
      FileUtils.mkdir_p(File.dirname(settings_path))
      current = open(settings_path)
      current.buffer.edit([[0...0, "// Project settings override user settings.\n{\n  \"tab_size\": #{@settings['tab_size']}\n}\n"]], kind: :settings) if current.buffer.rope.empty?
      @message = "Edit JSONC and save; Ctrl-Space completes setting names"
      current
    end
    def settings_completions
      raise Error, "Open a settings document first" unless settings_document?(editor.buffer)
      self.palette = {kind: :settings_keys, query: +"", index: 0, matches: Settings::DEFAULTS.keys}
    end
    def settings_browse(changed_only: false)
      fields = settings_gui_fields(changed_only: changed_only)
      labels = fields.map { |field| "#{field[:path].join(".")} = #{JSON.generate(field[:value])}" }
      self.palette = {kind: :settings_gui, query: +"", index: 0, matches: labels, fields: fields,
        settings_file: settings_path, changed_only: changed_only}
    end
    def settings_gui(changed_only: false) = settings_browse(changed_only: changed_only)
    def settings_document?(buffer)
      buffer.path && (buffer.path == settings_path || @settings.paths.any? { |path| File.expand_path(path) == buffer.path })
    end
    def configure_text_system(cache_dir: @window.text_system&.cache_dir)
      database = Zaniah::TextSystem::FontDB.new
      system = Zaniah::TextSystem::Renderer.new(font_db: database, font: database.find(family: @settings["font_family"]), cache_dir: cache_dir)
      system.scale_factor = @window.scale_factor
      old, @window.text_system = @window.text_system, system
      old&.close
      @applied_font_family = @settings["font_family"]
      system
    end
    def apply_settings
      reset_auto_save
      cancel_workspace_symbol_search
      self.palette = nil if @palette&.dig(:kind) == :workspace_symbol_results
      servers = language_server_settings_plan
      clear_vim_states unless @settings["vim_mode"]
      name = @settings["theme"]
      if name == "auto"
        name = @window&.respond_to?(:appearance) && @window.appearance == :light ? "Canopus Light" : "Canopus Dark"
      end
      target_theme = File.file?(File.expand_path(name, @root)) ? Theme.load(File.expand_path(name, @root)) : Theme.new(name: name)
      if @applied_icon_theme != @settings["icon_theme"]
        require_relative "../icon_theme"
        @icon_theme = IconTheme.new(@settings["icon_theme"] && File.expand_path(@settings["icon_theme"], @root))
      end
      @panes.each do |pane|
        pane.editors.each do |current|
          apply_editor_settings(current)
        end
      end
      self.theme = target_theme
      if @window&.text_system && !@window.is_a?(Zaniah::Platform::TUI::Window) && @applied_font_family != @settings["font_family"]
        configure_text_system
      end
      @applied_font_family = @settings["font_family"]
      @applied_icon_theme = @settings["icon_theme"]
      invalidate_diagnostics
      invalidate_document_highlights
      invalidate_document_links
      invalidate_folding_ranges
      invalidate_selection_ranges
      invalidate_hierarchy
      invalidate_prepare_rename
      invalidate_linked_editing_ranges
      invalidate_inlay_hints
      invalidate_code_lenses
      invalidate_brackets
      @decorations.invalidate(:blame)
      reload_language_servers(servers)
      @window&.request_frame
    end
    def poll_settings(force: false)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if !force && @last_settings_poll && now - @last_settings_poll < 1
      @last_settings_poll = now
      state = @settings.paths.map do |path|
        stat = File.stat(path)
        [path, stat.mtime, stat.size, stat.ino]
      rescue Errno::ENOENT
        [path, nil]
      end
      return if state == @settings_state && !force
      initial = !defined?(@settings_state)
      @settings_state = state
      return if initial && !force
      previous_paths = @settings.paths
      replacement = @settings.reload
      old, @settings = @settings, replacement
      publish_settings_diagnostics(previous_paths | @settings.paths)
      apply_settings
      errors = @settings.paths.filter_map { |path| Settings.file_diagnostics(path)&.last }.flatten
      @message = errors.empty? ? "Settings reloaded" : "Settings unchanged: #{errors.first.message}"
    rescue StandardError => error
      @settings = old if old
      publish_settings_diagnostics(@settings.paths) if @settings
      @message = "Settings unchanged: #{error.message}"
    end

    private

    def settings_gui_fields(changed_only: false)
      defaults = Settings::SCHEMA_MODEL.defaults
      Settings::SCHEMA_MODEL.fields.filter_map do |field|
        path = field.path
        next unless path.all? { |part| part.is_a?(String) && part != "*" }

        value = path.reduce(@settings.values) { |current, key| current.is_a?(Hash) ? current[key] : nil }
        default = path.reduce(defaults) { |current, key| current.is_a?(Hash) ? current[key] : nil }
        next if changed_only && value == default

        {path: path, value: value, default: default, description: field.description}.freeze
      end
    end

    def publish_settings_diagnostics(paths)
      paths.uniq.each do |path|
        uri = Sadr::Protocol.uri(File.expand_path(path))
        @diagnostics.publish(:settings, uri, settings_diagnostics(path))
      rescue StandardError
        @diagnostics.publish(:settings, uri, [], notify: false) rescue nil
      end
    end

    def settings_diagnostics(path)
      parsed = Settings.file_diagnostics(path)
      return [] unless parsed

      document, diagnostics = parsed
      diagnostics.filter_map do |diagnostic|
        range = diagnostic.range
        start_position = document.utf16_position_at(range&.begin || 0)
        end_position = document.utf16_position_at(range&.end || range&.begin || 0)
        {
          "range" => {
            "start" => {"line" => start_position[0], "character" => start_position[1]},
            "end" => {"line" => end_position[0], "character" => end_position[1]}
          },
          "severity" => Diagnostics::SEVERITIES.fetch(diagnostic.severity, 2),
          "message" => diagnostic.message.to_s,
          "source" => "settings"
        }
      rescue EncodingError, RangeError
        nil
      end
    end

    def apply_editor_settings(current)
      values = settings_for_editor(current)
      current.tab_size = values["tab_size"]
      current.use_tabs = values["use_tabs"]
      current.closing_pairs = values["auto_pairs"].to_h.freeze
      current.display_map.tab_size = current.tab_size
      current.display_map.wrap_width = values["soft_wrap"] ? 100 : nil unless current.buffer.read_only
    end
  end
end

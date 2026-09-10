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
      replacement = @settings.reload
      old, @settings = @settings, replacement
      apply_settings
      @message = "Settings reloaded"
    rescue StandardError => error
      @settings = old if old
      @message = "Settings unchanged: #{error.message}"
    end

    private
    def apply_editor_settings(current)
      values = @settings.for_language(current.language_document.definition.name)
      current.tab_size = values["tab_size"]
      current.use_tabs = values["use_tabs"]
      current.display_map.tab_size = current.tab_size
      current.display_map.wrap_width = values["soft_wrap"] ? 100 : nil unless current.buffer.read_only
    end
  end
end

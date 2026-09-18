# frozen_string_literal: true

require "editor_config"

module Canopus
  module Workspace::EditorConfigurable
    EDITORCONFIG_MAX_BYTES = 64 * 1024
    EDITORCONFIG_CACHE_LIMIT = 1_024

    # Return settings with the file's EditorConfig properties inserted before
    # the project settings layer.
    def settings_for_path(path, language: nil)
      settings = editorconfig_settings(path)
      language ? settings.for_language(language) : settings
    end

    def settings_for_editor(editor)
      settings_for_path(editor.buffer.path, language: editor.language_document.definition.name)
    end

    def invalidate_editorconfig
      @editorconfig_cache&.clear
      nil
    end

    def prepare_editorconfig_save(buffer, path)
      return if buffer.read_only
      values = settings_for_path(path)
      buffer.trim_trailing_whitespace if values["trim_trailing_whitespace"]
      buffer.ensure_final_newline if values["insert_final_newline"]
    end

    private

    def editorconfig_settings(path)
      return @settings unless @settings["editorconfig"] && path
      properties = editorconfig_properties(path)
      return @settings if properties.empty?

      layers = @settings.layers.dup
      project_path = File.expand_path(File.join(@root, ".canopus", "settings.jsonc"))
      index = layers.index do |layer|
        next false unless layer.is_a?(String)
        candidate = File.expand_path(layer)
        candidate = File.realpath(candidate) if File.exist?(candidate)
        candidate == project_path
      end
      layers.insert(index || layers.length, properties)
      Settings.new(*layers)
    rescue StandardError => error
      @message = "EditorConfig ignored: #{error.message}"
      @settings
    end

    def editorconfig_properties(path)
      absolute = File.expand_path(path, @root)
      absolute = File.realpath(absolute) if File.exist?(absolute)
      return {} unless absolute == @root || absolute.start_with?(@root + File::SEPARATOR)
      relative = absolute.delete_prefix(@root + File::SEPARATOR)
      return {} if relative.empty?

      @editorconfig_cache ||= {}
      return @editorconfig_cache[absolute] if @editorconfig_cache.key?(absolute)

      raw = EditorConfig.load(relative) do |candidate|
        editorconfig_file(candidate)
      end
      properties = map_editorconfig(EditorConfig.preprocess(raw))
      @editorconfig_cache[absolute] = properties.freeze
      @editorconfig_cache.shift if @editorconfig_cache.length > EDITORCONFIG_CACHE_LIMIT
      properties
    rescue ArgumentError, EncodingError, IOError, SystemCallError
      @editorconfig_cache[absolute] = {}.freeze if defined?(@editorconfig_cache) && absolute
      {}
    end

    def editorconfig_file(candidate)
      absolute = File.expand_path(candidate, @root)
      real = File.realpath(absolute)
      return unless real == @root || real.start_with?(@root + File::SEPARATOR)
      return unless absolute == @root || absolute.start_with?(@root + File::SEPARATOR)
      stat = File.lstat(absolute)
      return unless stat.file? && !stat.symlink? && stat.size <= EDITORCONFIG_MAX_BYTES

      source = File.binread(absolute)
      return unless source.force_encoding(Encoding::UTF_8).valid_encoding?

      source
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, IOError, SystemCallError
      nil
    end

    def map_editorconfig(properties)
      values = {}
      style = properties[EditorConfig::INDENT_STYLE]
      values["use_tabs"] = style == EditorConfig::TAB if [EditorConfig::SPACE, EditorConfig::TAB].include?(style)

      size = properties[EditorConfig::INDENT_SIZE]
      size = properties[EditorConfig::TAB_WIDTH] if size.nil? || size == EditorConfig::TAB
      values["tab_size"] = size.to_i if size&.match?(/\A[1-9]\d*\z/) && size.to_i <= 16

      {EditorConfig::TRIM_TRAILING_WHITESPACE => "trim_trailing_whitespace",
       EditorConfig::INSERT_FINAL_NEWLINE => "insert_final_newline"}.each do |source, target|
        value = properties[source]
        values[target] = value == EditorConfig::TRUE if [EditorConfig::TRUE, EditorConfig::FALSE].include?(value)
      end

      length = properties[EditorConfig::MAX_LINE_LENGTH]
      values["max_line_length"] = length.to_i if length&.match?(/\A[1-9]\d*\z/) && length.to_i <= 1_000_000
      values
    end
  end
end

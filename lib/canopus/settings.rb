# frozen_string_literal: true

require "json"
require "kochab"

module Canopus
  class Settings
    DEFAULTS = {"font_size" => 14, "tab_size" => 4, "use_tabs" => false, "soft_wrap" => false, "vim_mode" => false, "keymap" => [].freeze,
      "scroll_friction" => 12,
      "theme" => "Canopus Dark", "font_family" => nil, "icon_theme" => nil, "languages" => {}, "language_servers" => {},
      "tabs" => {"activate_on_close" => "history", "close_on_middle_click" => true, "close_empty_pane" => true,
        "reopen_history_limit" => 20, "confirm_on_close_dirty" => true}.freeze,
      "dock" => {"bottom" => {"size" => 280, "visible" => false}.freeze}.freeze,
      "terminal" => {"shell" => nil, "working_directory" => "project", "env" => {}.freeze, "scrollback_lines" => 10_000,
        "font_size" => nil, "line_height" => 1.2, "copy_on_select" => false, "blinking" => "terminal_controlled", "cursor_shape" => "block",
        "close_on_exit" => "clean", "confirm_close_running" => true, "confirm_multiline_paste" => true,
        "restore_on_startup" => false, "hide_when_empty" => false, "max_bytes_per_frame" => 262_144,
        "queue_limit_bytes" => 8_388_608, "resize_debounce_ms" => 100, "min_rows" => 4, "min_cols" => 20}.freeze}.freeze
    SCHEMA = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "object", "properties" => {
      "font_size" => {"type" => "number", "minimum" => 6, "maximum" => 96},
      "tab_size" => {"type" => "integer", "minimum" => 1, "maximum" => 16},
      "scroll_friction" => {"type" => "number", "minimum" => 0, "maximum" => 100},
      "soft_wrap" => {"type" => "boolean"}, "vim_mode" => {"type" => "boolean"},
      "use_tabs" => {"type" => "boolean"},
      "keymap" => {"type" => "array", "maxItems" => 128, "items" => {"type" => "object", "required" => ["bindings"], "properties" => {
        "context" => {"type" => "string", "maxLength" => 256},
        "bindings" => {"type" => "object", "maxProperties" => 1024, "additionalProperties" => {"type" => ["string", "null"]}}}}},
      "theme" => {"type" => "string"}, "font_family" => {"type" => ["string", "null"]},
      "icon_theme" => {"type" => ["string", "null"]},
      "tabs" => {"type" => "object"}, "terminal" => {"type" => "object"}, "dock" => {"type" => "object"},
      "languages" => {"type" => "object", "additionalProperties" => {"$ref" => "#"}},
      "language_servers" => {"type" => "object"}}}.freeze
    attr_reader :values, :errors, :layers
    def self.schema = SCHEMA
    def self.user_path
      File.join(ENV["XDG_CONFIG_HOME"] || File.expand_path("~/.config"), "canopus", "settings.jsonc")
    end
    def initialize(*layers)
      @values, @errors = DEFAULTS.dup, []
      @layers = layers.compact
      layers.compact.each { |layer| merge!(layer.is_a?(String) ? parse_file(layer) : layer) }
      validate!
    end
    def [](key) = @values[key.to_s]
    def paths = @layers.grep(String)
    def reload = self.class.new(*@layers)
    def for_language(language) = Settings.new(@values, @values.fetch("languages", {}).fetch(language, {}))
    def merge!(layer)
      raise Error, "settings must be an object" unless layer.is_a?(Hash)
      previous = @values
      @values = merge(@values, layer)
      validate!
      self
    rescue StandardError
      @values = previous if previous
      raise
    end
    def set_file(path, key, value)
      source = File.file?(path) ? File.read(path) : "{}\n"
      doc = Kochab.parse(source)
      raise Error, "cannot edit invalid settings" unless doc.valid?
      replacement = Kochab.apply(source, doc.set([key.to_s], value))
      Settings.new(Kochab.parse(replacement).value)
      FileUtils.mkdir_p(File.dirname(path))
      Tempfile.create([".settings-", ".json"], File.dirname(path)) do |file|
        file.write(replacement)
        file.flush
        file.fsync
        file.close
        raise SaveConflict, "settings changed during save" if File.file?(path) && File.read(path) != source
        File.rename(file.path, path)
      end
    end
    private
    def parse_file(path)
      return {} unless File.file?(path)
      document = Kochab.parse(File.read(path))
      @errors.concat(document.errors)
      raise Error, "invalid settings: #{path}" unless document.valid?
      document.value
    end
    def merge(left, right)
      left.merge(right) { |_, old, new| old.is_a?(Hash) && new.is_a?(Hash) ? merge(old, new) : new }
    end
    def validate!
      {"font_size" => 6..96, "tab_size" => 1..16, "scroll_friction" => 0..100}.each do |key, range|
        value = @values[key]
        raise Error, "invalid #{key}" unless value.is_a?(Numeric) && range.cover?(value)
      end
      raise Error, "tab_size must be an integer" unless @values["tab_size"].is_a?(Integer)
      %w[soft_wrap vim_mode use_tabs].each { |key| raise Error, "#{key} must be true or false" unless [true, false].include?(@values[key]) }
      validate_keymap!
      %w[languages language_servers].each { |key| raise Error, "#{key} must be an object" unless @values[key].is_a?(Hash) }
      raise Error, "theme must be a string" unless @values["theme"].is_a?(String)
      raise Error, "font_family must be a string or null" unless @values["font_family"].nil? || @values["font_family"].is_a?(String)
      raise Error, "icon_theme must be a string or null" unless @values["icon_theme"].nil? || @values["icon_theme"].is_a?(String)
      validate_tabs!
      validate_terminal!
      validate_dock!
      @values["languages"] = @values["languages"].to_h do |name, layer|
        raise Error, "language settings must be objects" unless name.is_a?(String) && layer.is_a?(Hash)
        raise Error, "language settings cannot contain nested languages" if layer.key?("languages")
        checked = Settings.new(@values.merge("languages" => {}), layer)
        [name, layer.key?("keymap") ? layer.merge("keymap" => checked["keymap"]) : layer]
      end
    end
    def validate_keymap!
      groups = @values["keymap"]
      raise Error, "keymap must be an array of at most 128 groups" unless groups.is_a?(Array) && groups.length <= 128
      count = 0
      @values["keymap"] = groups.map do |group|
        raise Error, "keymap groups require a bindings object" unless group.is_a?(Hash) && group["bindings"].is_a?(Hash)
        context = group.fetch("context", "")
        raise Error, "keymap context must be a string of at most 256 bytes" unless context.is_a?(String) && context.bytesize <= 256
        Zaniah::Input::ContextPredicate.new(context)
        bindings = group["bindings"].to_h do |keys, action|
          count += 1
          raise Error, "keymap exceeds 1024 bindings" if count > 1024
          raise Error, "invalid keymap key sequence" unless keys.is_a?(String) && keys.bytesize.between?(1, 256) && !keys.strip.empty?
          keys.split.each { |key| Zaniah::Input::Keystroke.normalize(key) }
          raise Error, "keymap action must be a string or null" unless action.nil? || (action.is_a?(String) && action.bytesize.between?(1, 256))
          [keys.dup.freeze, action&.dup&.freeze]
        end.freeze
        {"context" => context.dup.freeze, "bindings" => bindings}.freeze
      end.freeze
    rescue ArgumentError => error
      raise Error, "invalid keymap: #{error.message}"
    end

    def validate_tabs!
      tabs = @values["tabs"]
      raise Error, "tabs must be an object" unless tabs.is_a?(Hash)
      raise Error, "invalid tabs.activate_on_close" unless %w[history neighbour left right].include?(tabs["activate_on_close"])
      %w[close_on_middle_click close_empty_pane confirm_on_close_dirty].each do |key|
        raise Error, "tabs.#{key} must be true or false" unless [true, false].include?(tabs[key])
      end
      limit = tabs["reopen_history_limit"]
      raise Error, "invalid tabs.reopen_history_limit" unless limit.is_a?(Integer) && limit.between?(0, 1000)
    end

    def validate_terminal!
      terminal = @values["terminal"]
      raise Error, "terminal must be an object" unless terminal.is_a?(Hash)
      raise Error, "invalid terminal.shell" unless terminal["shell"].nil? || terminal["shell"].is_a?(String) ||
        (terminal["shell"].is_a?(Array) && terminal["shell"].all? { |value| value.is_a?(String) })
      raise Error, "invalid terminal.working_directory" unless terminal["working_directory"].is_a?(String)
      raise Error, "invalid terminal.env" unless terminal["env"].is_a?(Hash) && terminal["env"].all? { |key, value| key.is_a?(String) && (value.nil? || value.is_a?(String)) }
      raise Error, "invalid terminal.font_size" unless terminal["font_size"].nil? || terminal["font_size"].is_a?(Numeric) && terminal["font_size"].between?(6, 96)
      raise Error, "invalid terminal.line_height" unless terminal["line_height"].is_a?(Numeric) && terminal["line_height"].between?(0.5, 4)
      %w[confirm_close_running confirm_multiline_paste copy_on_select restore_on_startup hide_when_empty].each do |key|
        raise Error, "terminal.#{key} must be true or false" unless [true, false].include?(terminal[key])
      end
      raise Error, "invalid terminal.close_on_exit" unless %w[never clean always].include?(terminal["close_on_exit"])
      raise Error, "invalid terminal.blinking" unless %w[off on terminal_controlled].include?(terminal["blinking"])
      raise Error, "invalid terminal.cursor_shape" unless %w[block bar underline].include?(terminal["cursor_shape"])
      {"scrollback_lines" => 0..1_000_000, "max_bytes_per_frame" => 1..16_777_216,
       "queue_limit_bytes" => 65_536..268_435_456, "resize_debounce_ms" => 0..10_000,
       "min_rows" => 1..1000, "min_cols" => 1..1000}.each do |key, range|
        value = terminal[key]
        raise Error, "invalid terminal.#{key}" unless value.is_a?(Integer) && range.cover?(value)
      end
    end

    def validate_dock!
      dock = @values["dock"]
      bottom = dock["bottom"] if dock.is_a?(Hash)
      raise Error, "invalid dock.bottom" unless bottom.is_a?(Hash) && bottom["size"].is_a?(Numeric) && bottom["size"].positive? && [true, false].include?(bottom["visible"])
    end
  end
end

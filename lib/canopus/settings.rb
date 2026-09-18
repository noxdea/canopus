# frozen_string_literal: true

require "json"
require "kochab"

module Canopus
  class Settings
    DEFAULTS = {"font_size" => 14, "tab_size" => 4, "use_tabs" => false, "soft_wrap" => false, "vim_mode" => false, "keymap" => [].freeze,
      "scroll_friction" => 12,
      "theme" => "Canopus Dark", "font_family" => nil, "icon_theme" => nil, "languages" => {}, "language_servers" => {},
      "debug_adapters" => {}.freeze,
      "tabs" => {"activate_on_close" => "history", "close_on_middle_click" => true, "close_empty_pane" => true,
        "reopen_history_limit" => 20, "confirm_on_close_dirty" => true}.freeze,
      "diagnostics" => {"inline" => true, "inline_max_length" => 80, "severity" => "warning"}.freeze,
      "inlay_hints" => {"enabled" => true, "parameter_names" => true, "types" => true, "max_length" => 30}.freeze,
      "code_lens" => {"enabled" => true}.freeze,
      "bracket_colorization" => true,
      "indent_guides" => {"enabled" => true, "active" => true}.freeze,
      "render_whitespace" => "boundary", "render_ideographic_space" => true,
      "sticky_scroll" => {"enabled" => true, "max_lines" => 5}.freeze,
      "breadcrumbs" => {"enabled" => true}.freeze,
      "minimap" => {"enabled" => false, "width" => 100, "show_diagnostics" => true}.freeze,
      "format_on_save" => false, "code_actions_on_save" => [].freeze, "format_on_save_timeout" => 2_000,
      "git" => {"inline_blame" => "off", "autofetch" => false, "autofetch_interval" => 180}.freeze,
      "recovery" => {"enabled" => true, "interval" => 5_000}.freeze,
      "dock" => {"left" => {"size" => 220, "visible" => true}.freeze,
        "right" => {"size" => 260, "visible" => false}.freeze,
        "bottom" => {"size" => 280, "visible" => false}.freeze,
        "panels" => {"explorer" => {"size" => 220, "visible" => true}.freeze,
          "search" => {"size" => 220, "visible" => false}.freeze,
          "terminal" => {"size" => 280, "visible" => false}.freeze}.freeze}.freeze,
      "terminal" => {"shell" => nil, "working_directory" => "project", "env" => {}.freeze, "scrollback_lines" => 10_000,
        "profiles" => {}.freeze, "default_profile" => nil,
        "font_size" => nil, "line_height" => 1.2, "copy_on_select" => false, "blinking" => "terminal_controlled", "cursor_shape" => "block",
        "close_on_exit" => "clean", "confirm_close_running" => true, "confirm_multiline_paste" => true,
        "restore_on_startup" => false, "hide_when_empty" => false, "shell_integration" => true, "max_bytes_per_frame" => 262_144,
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
      "tabs" => {"type" => "object"}, "terminal" => {"type" => "object", "properties" => {
        "shell_integration" => {"type" => "boolean"}, "default_profile" => {"type" => ["string", "null"]},
        "profiles" => {"type" => "object", "additionalProperties" => {"$ref" => "#/$defs/terminal_profile"}}}},
      "diagnostics" => {"type" => "object", "required" => %w[inline inline_max_length severity], "properties" => {
        "inline" => {"type" => "boolean"}, "inline_max_length" => {"type" => "integer", "minimum" => 1, "maximum" => 10_000},
        "severity" => {"type" => "string", "enum" => %w[error warning information hint]}}},
      "inlay_hints" => {"type" => "object", "required" => %w[enabled parameter_names types max_length], "properties" => {
        "enabled" => {"type" => "boolean"}, "parameter_names" => {"type" => "boolean"}, "types" => {"type" => "boolean"},
        "max_length" => {"type" => "integer", "minimum" => 1, "maximum" => 10_000}}},
      "code_lens" => {"type" => "object", "required" => ["enabled"], "properties" => {
        "enabled" => {"type" => "boolean"}}},
      "bracket_colorization" => {"type" => "boolean"},
      "indent_guides" => {"type" => "object", "required" => %w[enabled active], "properties" => {
        "enabled" => {"type" => "boolean"}, "active" => {"type" => "boolean"}}},
      "render_whitespace" => {"type" => "string", "enum" => %w[none boundary selection all]},
      "render_ideographic_space" => {"type" => "boolean"},
      "sticky_scroll" => {"type" => "object", "required" => %w[enabled max_lines], "properties" => {
        "enabled" => {"type" => "boolean"}, "max_lines" => {"type" => "integer", "minimum" => 1, "maximum" => 20}}},
      "breadcrumbs" => {"type" => "object", "required" => ["enabled"], "properties" => {
        "enabled" => {"type" => "boolean"}}},
      "minimap" => {"type" => "object", "required" => %w[enabled width show_diagnostics], "properties" => {
        "enabled" => {"type" => "boolean"}, "width" => {"type" => "integer", "minimum" => 40, "maximum" => 400},
        "show_diagnostics" => {"type" => "boolean"}}},
      "format_on_save" => {"type" => "boolean"},
      "code_actions_on_save" => {"type" => "array", "maxItems" => 64, "uniqueItems" => true,
        "items" => {"type" => "string", "minLength" => 1, "maxLength" => 256}},
      "format_on_save_timeout" => {"type" => "integer", "minimum" => 1, "maximum" => 60_000},
      "git" => {"type" => "object", "additionalProperties" => false,
        "required" => %w[inline_blame autofetch autofetch_interval], "properties" => {
          "inline_blame" => {"type" => "string", "enum" => %w[off cursor all]},
          "autofetch" => {"type" => "boolean"},
          "autofetch_interval" => {"type" => "integer", "minimum" => 10, "maximum" => 86_400}}},
      "recovery" => {"type" => "object", "additionalProperties" => false,
        "required" => %w[enabled interval], "properties" => {
          "enabled" => {"type" => "boolean"},
          "interval" => {"type" => "integer", "minimum" => 100, "maximum" => 3_600_000}}},
      "dock" => {"type" => "object", "properties" => {
        "left" => {"$ref" => "#/$defs/dock"}, "right" => {"$ref" => "#/$defs/dock"},
        "bottom" => {"$ref" => "#/$defs/dock"}, "panels" => {"type" => "object", "maxProperties" => 1000,
          "additionalProperties" => {"$ref" => "#/$defs/panel"}}}},
      "languages" => {"type" => "object", "additionalProperties" => {"allOf" => [
        {"$ref" => "#"}, {"properties" => {"languages" => false, "debug_adapters" => false, "recovery" => false}}
      ]}},
      "language_servers" => {"type" => "object", "additionalProperties" => {"anyOf" => [
        {"type" => "null"}, {"$ref" => "#/$defs/language_server"},
        {"type" => "array", "minItems" => 1, "items" => {"type" => "string", "minLength" => 1}},
        {"type" => "array", "minItems" => 1, "maxItems" => 16,
          "items" => {"$ref" => "#/$defs/language_server"}}
      ]}},
      "debug_adapters" => {"type" => "object", "maxProperties" => 64,
        "propertyNames" => {"type" => "string", "minLength" => 1, "maxLength" => 128,
          "pattern" => "^[A-Za-z0-9_.-]+$"},
        "additionalProperties" => {"$ref" => "#/$defs/debug_adapter"}}}, "$defs" => {
        "language_server" => {"type" => "object", "additionalProperties" => false,
          "required" => ["command"], "properties" => {
            "command" => {"type" => "array", "minItems" => 1,
              "items" => {"type" => "string", "minLength" => 1}},
            "env" => {"type" => "object", "additionalProperties" => {"type" => ["string", "null"]}},
            "initialization_options" => {}, "configuration" => {"type" => "object"},
            "features" => {"type" => "array", "minItems" => 1, "uniqueItems" => true,
              "items" => {"type" => "string", "enum" => %w[completion diagnostics codeAction formatting definition typeDefinition implementation hover signatureHelp references rename documentSymbol codeLens inlayHint semanticTokens documentHighlight foldingRange selectionRange callHierarchy typeHierarchy documentLink linkedEditingRange workspaceSymbol]}}
          }},
        "debug_adapter" => {"type" => "object", "additionalProperties" => false,
          "required" => %w[command transport], "properties" => {
            "command" => {"type" => "array", "minItems" => 1, "maxItems" => 32,
              "items" => {"type" => "string", "minLength" => 1, "maxLength" => 4096,
                "pattern" => "^(?![\\s\\S]*[\\u0000-\\u001f\\u007f])[\\s\\S]+$"}},
            "transport" => {"type" => "string", "enum" => %w[stdio tcp]}}},
        "terminal_profile" => {"type" => "object", "additionalProperties" => false,
          "properties" => {
            "command" => {"anyOf" => [{"type" => "string", "minLength" => 1},
              {"type" => "array", "minItems" => 1, "items" => {"type" => "string"}}]},
            "path" => {"type" => "string", "minLength" => 1},
            "args" => {"type" => "array", "items" => {"type" => "string"}},
            "env" => {"type" => "object", "additionalProperties" => {"type" => ["string", "null"]}}}},
        "dock" => {"type" => "object", "required" => %w[size visible], "properties" => {
          "size" => {"type" => "number", "exclusiveMinimum" => 0}, "visible" => {"type" => "boolean"}}},
        "panel" => {"type" => "object", "required" => %w[size visible], "properties" => {
          "size" => {"type" => "number", "exclusiveMinimum" => 0}, "visible" => {"type" => "boolean"}}}}}.freeze
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
      %w[soft_wrap vim_mode use_tabs render_ideographic_space format_on_save].each { |key| raise Error, "#{key} must be true or false" unless [true, false].include?(@values[key]) }
      raise Error, "invalid render_whitespace" unless %w[none boundary selection all].include?(@values["render_whitespace"])
      validate_keymap!
      %w[languages language_servers].each { |key| raise Error, "#{key} must be an object" unless @values[key].is_a?(Hash) }
      raise Error, "theme must be a string" unless @values["theme"].is_a?(String)
      raise Error, "font_family must be a string or null" unless @values["font_family"].nil? || @values["font_family"].is_a?(String)
      raise Error, "icon_theme must be a string or null" unless @values["icon_theme"].nil? || @values["icon_theme"].is_a?(String)
      validate_tabs!
      validate_terminal!
      validate_diagnostics!
      validate_inlay_hints!
      validate_code_lens!
      validate_structural_guides!
      validate_sticky_scroll!
      validate_breadcrumbs!
      validate_minimap!
      validate_save_actions!
      validate_git!
      validate_recovery!
      validate_language_server_keys!
      snapshot_language_servers!
      validate_debug_adapters!
      validate_dock!
      @values["languages"] = @values["languages"].to_h do |name, layer|
        raise Error, "language settings must be objects" unless name.is_a?(String) && layer.is_a?(Hash)
        raise Error, "language settings cannot contain nested languages" if layer.key?("languages")
        %w[debug_adapters recovery].each do |key|
          raise Error, "#{key} is a global setting" if layer.key?(key) || layer.key?(key.to_sym)
        end
        checked = Settings.new(@values.merge("languages" => {}), layer)
        layer = layer.merge("keymap" => checked["keymap"]) if layer.key?("keymap")
        layer = layer.merge("code_actions_on_save" => checked["code_actions_on_save"]) if layer.key?("code_actions_on_save")
        layer = layer.merge("language_servers" => checked["language_servers"]) if layer.key?("language_servers")
        [name, layer]
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
      validate_terminal_profiles!(terminal)
      raise Error, "invalid terminal.font_size" unless terminal["font_size"].nil? || terminal["font_size"].is_a?(Numeric) && terminal["font_size"].between?(6, 96)
      raise Error, "invalid terminal.line_height" unless terminal["line_height"].is_a?(Numeric) && terminal["line_height"].between?(0.5, 4)
      %w[confirm_close_running confirm_multiline_paste copy_on_select restore_on_startup hide_when_empty shell_integration].each do |key|
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

    def validate_terminal_profiles!(terminal)
      profiles = terminal["profiles"]
      raise Error, "terminal.profiles must be an object" unless profiles.is_a?(Hash) && profiles.length <= 100
      profiles.each do |name, profile|
        valid_name = name.is_a?(String) && name.valid_encoding? && name.bytesize.between?(1, 128) && name == name.strip
        raise Error, "invalid terminal profile name" unless valid_name
        unless profile.is_a?(Hash) && profile.keys.all? { |key| %w[command path args env].include?(key) }
          raise Error, "invalid terminal profile #{name}"
        end
        command = profile["command"]
        path, args, env = profile.values_at("path", "args", "env")
        valid_command = command.nil? || command.is_a?(String) && !command.empty? ||
          command.is_a?(Array) && command.first.is_a?(String) && !command.first.empty? &&
            command.all? { |value| value.is_a?(String) }
        raise Error, "invalid terminal profile command #{name}" unless valid_command
        raise Error, "terminal profile #{name} cannot use command with path or args" if command && (path || args)
        raise Error, "terminal profile #{name} args require path" if args && !path
        raise Error, "invalid terminal profile path #{name}" unless path.nil? || path.is_a?(String) && !path.empty?
        raise Error, "invalid terminal profile args #{name}" unless args.nil? || args.is_a?(Array) && args.all? { |value| value.is_a?(String) }
        valid_env = env.nil? || env.is_a?(Hash) && env.all? { |key, value| key.is_a?(String) && (value.nil? || value.is_a?(String)) }
        raise Error, "invalid terminal profile env #{name}" unless valid_env
      end
      default = terminal["default_profile"]
      unless default.nil? || default.is_a?(String) && profiles.key?(default)
        raise Error, "terminal.default_profile must name a configured profile"
      end
    end

    def validate_git!
      git = @values["git"]
      raise Error, "git must be an object" unless git.is_a?(Hash)
      raise Error, "invalid git.inline_blame" unless %w[off cursor all].include?(git["inline_blame"])
      raise Error, "git.autofetch must be true or false" unless [true, false].include?(git["autofetch"])
      interval = git["autofetch_interval"]
      raise Error, "invalid git.autofetch_interval" unless interval.is_a?(Integer) && interval.between?(10, 86_400)
    end

    def validate_recovery!
      recovery = @values["recovery"]
      raise Error, "recovery must be an object" unless recovery.is_a?(Hash)
      raise Error, "recovery.enabled must be true or false" unless [true, false].include?(recovery["enabled"])
      interval = recovery["interval"]
      raise Error, "invalid recovery.interval" unless interval.is_a?(Integer) && interval.between?(100, 3_600_000)
    end

    def validate_diagnostics!
      diagnostics = @values["diagnostics"]
      raise Error, "diagnostics must be an object" unless diagnostics.is_a?(Hash)
      raise Error, "diagnostics.inline must be true or false" unless [true, false].include?(diagnostics["inline"])
      length = diagnostics["inline_max_length"]
      raise Error, "invalid diagnostics.inline_max_length" unless length.is_a?(Integer) && length.between?(1, 10_000)
      unless %w[error warning information hint].include?(diagnostics["severity"])
        raise Error, "invalid diagnostics.severity"
      end
    end

    def validate_inlay_hints!
      hints = @values["inlay_hints"]
      raise Error, "inlay_hints must be an object" unless hints.is_a?(Hash)
      %w[enabled parameter_names types].each do |key|
        raise Error, "inlay_hints.#{key} must be true or false" unless [true, false].include?(hints[key])
      end
      length = hints["max_length"]
      raise Error, "invalid inlay_hints.max_length" unless length.is_a?(Integer) && length.between?(1, 10_000)
    end

    def validate_code_lens!
      lens = @values["code_lens"]
      raise Error, "code_lens must be an object" unless lens.is_a?(Hash)
      raise Error, "code_lens.enabled must be true or false" unless [true, false].include?(lens["enabled"])
    end

    def validate_structural_guides!
      unless [true, false].include?(@values["bracket_colorization"])
        raise Error, "bracket_colorization must be true or false"
      end
      guides = @values["indent_guides"]
      raise Error, "indent_guides must be an object" unless guides.is_a?(Hash)
      %w[enabled active].each do |key|
        raise Error, "indent_guides.#{key} must be true or false" unless [true, false].include?(guides[key])
      end
    end

    def validate_sticky_scroll!
      sticky = @values["sticky_scroll"]
      raise Error, "sticky_scroll must be an object" unless sticky.is_a?(Hash)
      raise Error, "sticky_scroll.enabled must be true or false" unless [true, false].include?(sticky["enabled"])
      unless sticky["max_lines"].is_a?(Integer) && sticky["max_lines"].between?(1, 20)
        raise Error, "invalid sticky_scroll.max_lines"
      end
    end

    def validate_breadcrumbs!
      breadcrumbs = @values["breadcrumbs"]
      unless breadcrumbs.is_a?(Hash) && [true, false].include?(breadcrumbs["enabled"])
        raise Error, "breadcrumbs.enabled must be true or false"
      end
    end

    def validate_minimap!
      minimap = @values["minimap"]
      raise Error, "minimap must be an object" unless minimap.is_a?(Hash)
      %w[enabled show_diagnostics].each do |key|
        raise Error, "minimap.#{key} must be true or false" unless [true, false].include?(minimap[key])
      end
      raise Error, "invalid minimap.width" unless minimap["width"].is_a?(Integer) && minimap["width"].between?(40, 400)
    end

    def validate_save_actions!
      actions = @values["code_actions_on_save"]
      valid = actions.is_a?(Array) && actions.length <= 64 && actions.uniq.length == actions.length && actions.all? do |action|
        action.is_a?(String) && action.valid_encoding? && action.bytesize.between?(1, 256) &&
          action == action.strip && !action.match?(/[\x00-\x1f\x7f]/)
      end
      raise Error, "invalid code_actions_on_save" unless valid
      @values["code_actions_on_save"] = actions.map { |action| action.dup.freeze }.freeze
      timeout = @values["format_on_save_timeout"]
      raise Error, "invalid format_on_save_timeout" unless timeout.is_a?(Integer) && timeout.between?(1, 60_000)
    end

    def snapshot_language_servers!
      snapshot = JSON.parse(JSON.generate(@values["language_servers"]))
      freeze_value = lambda do |value|
        value.each { |key, child| key.freeze; freeze_value.call(child) } if value.is_a?(Hash)
        value.each { |child| freeze_value.call(child) } if value.is_a?(Array)
        value.freeze
      end
      @values["language_servers"] = freeze_value.call(snapshot)
    rescue JSON::GeneratorError, JSON::ParserError, JSON::NestingError
      raise Error, "invalid language_servers"
    end

    def validate_language_server_keys!
      @values["language_servers"].each do |name, value|
        raise Error, "language server names must be strings" unless name.is_a?(String)
        options = value.is_a?(Array) ? value.select { |item| item.is_a?(Hash) } : value.is_a?(Hash) ? [value] : []
        options.each do |option|
          raise Error, "language server option keys must be strings" unless option.keys.all? { |key| key.is_a?(String) }
          env = option["env"]
          raise Error, "language server env keys must be strings" if env.is_a?(Hash) && !env.keys.all? { |key| key.is_a?(String) }
        end
      end
    end

    def validate_debug_adapters!
      adapters = @values["debug_adapters"]
      raise Error, "debug_adapters must be an object of at most 64 adapters" unless adapters.is_a?(Hash) && adapters.length <= 64
      adapters.each do |type, options|
        valid_type = type.is_a?(String) && type.valid_encoding? && type.bytesize.between?(1, 128) &&
          type.match?(/\A[A-Za-z0-9_.-]+\z/)
        raise Error, "invalid debug adapter type" unless valid_type
        unless options.is_a?(Hash) && options.keys.all? { |key| key.is_a?(String) } &&
          (options.keys - %w[command transport]).empty?
          raise Error, "invalid debug adapter options for #{type}"
        end
        command = options["command"]
        valid_command = command.is_a?(Array) && command.length.between?(1, 32) && command.all? do |argument|
          argument.is_a?(String) && argument.valid_encoding? && argument.bytesize.between?(1, 4096) &&
            !argument.match?(/[\x00-\x1f\x7f]/)
        end
        raise Error, "invalid debug adapter command for #{type}" unless valid_command
        raise Error, "invalid debug adapter transport for #{type}" unless %w[stdio tcp].include?(options["transport"])
      end
      serialized = JSON.generate(adapters)
      raise Error, "debug_adapters exceeds 1 MiB" if serialized.bytesize > 1_048_576
      snapshot = JSON.parse(serialized)
      freeze_value = lambda do |value|
        value.each { |key, child| key.freeze; freeze_value.call(child) } if value.is_a?(Hash)
        value.each { |child| freeze_value.call(child) } if value.is_a?(Array)
        value.freeze
      end
      @values["debug_adapters"] = freeze_value.call(snapshot)
    rescue JSON::GeneratorError, JSON::ParserError, JSON::NestingError
      raise Error, "invalid debug_adapters"
    end

    def validate_dock!
      dock = @values["dock"]
      raise Error, "dock must be an object" unless dock.is_a?(Hash)
      %w[left right bottom].each { |side| validate_dock_state!(dock[side], "dock.#{side}") }
      panels = dock["panels"]
      raise Error, "dock.panels must be an object" unless panels.is_a?(Hash) && panels.length <= 1_000
      panels.each do |id, state|
        raise Error, "invalid panel id" unless id.is_a?(String) && id.bytesize.between?(1, 256)
        validate_dock_state!(state, "dock.panels.#{id}")
      end
    end

    def validate_dock_state!(state, name)
      valid_size = state.is_a?(Hash) && state["size"].is_a?(Numeric) && state["size"].finite? && state["size"].positive?
      raise Error, "invalid #{name}" unless valid_size && [true, false].include?(state["visible"])
    end
  end
end

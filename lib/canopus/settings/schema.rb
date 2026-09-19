# frozen_string_literal: true

require "kochab"

module Canopus
  class Settings
    module Schema
      DEFAULT_AUTO_PAIRS = [["(", ")"], ["[", "]"], ["{", "}"], ['"', '"'], ["'", "'"]].map(&:freeze).freeze
      DEFAULT_VALUES = {
        "font_size" => 14, "tab_size" => 4, "use_tabs" => false, "soft_wrap" => false, "vim_mode" => false, "keymap" => [],
        "auto_pairs" => DEFAULT_AUTO_PAIRS, "scroll_friction" => 12,
        "theme" => "Canopus Dark", "font_family" => nil, "icon_theme" => nil, "languages" => {}, "language_servers" => {},
        "debug_adapters" => {},
        "tabs" => {"activate_on_close" => "history", "close_on_middle_click" => true, "close_empty_pane" => true,
          "reopen_history_limit" => 20, "confirm_on_close_dirty" => true},
        "diagnostics" => {"inline" => true, "inline_max_length" => 80, "severity" => "warning"},
        "inlay_hints" => {"enabled" => true, "parameter_names" => true, "types" => true, "max_length" => 30},
        "code_lens" => {"enabled" => true}, "bracket_colorization" => true,
        "indent_guides" => {"enabled" => true, "active" => true},
        "render_whitespace" => "boundary", "render_ideographic_space" => true,
        "sticky_scroll" => {"enabled" => true, "max_lines" => 5}, "breadcrumbs" => {"enabled" => true},
        "minimap" => {"enabled" => false, "width" => 100, "show_diagnostics" => true},
        "auto_save" => "off", "auto_save_delay" => 1_000,
        "editorconfig" => true, "trim_trailing_whitespace" => nil, "insert_final_newline" => nil, "max_line_length" => nil,
        "persistent_undo" => {"enabled" => true, "max_entries" => 1_000, "expire_days" => 30},
        "format_on_save" => false, "code_actions_on_save" => [], "format_on_save_timeout" => 2_000,
        "git" => {"inline_blame" => "off", "autofetch" => false, "autofetch_interval" => 180},
        "plugins" => {"enabled" => true, "sandbox" => "auto", "directories" => [], "disabled" => [],
          "limits" => {"memory_mb" => 256, "request_timeout_ms" => 2_000}, "settings" => {}},
        "recovery" => {"enabled" => true, "interval" => 5_000},
        "dock" => {"left" => {"size" => 220, "visible" => true}, "right" => {"size" => 260, "visible" => false},
          "bottom" => {"size" => 280, "visible" => false},
          "panels" => {"explorer" => {"size" => 220, "visible" => true}, "search" => {"size" => 220, "visible" => false},
            "terminal" => {"size" => 280, "visible" => false}}},
        "terminal" => {"shell" => nil, "working_directory" => "project", "env" => {}, "scrollback_lines" => 10_000,
          "profiles" => {}, "default_profile" => nil, "font_size" => nil, "line_height" => 1.2, "copy_on_select" => false,
          "blinking" => "terminal_controlled", "cursor_shape" => "block", "close_on_exit" => "clean",
          "confirm_close_running" => true, "confirm_multiline_paste" => true, "restore_on_startup" => false,
          "hide_when_empty" => false, "shell_integration" => true, "max_bytes_per_frame" => 262_144,
          "queue_limit_bytes" => 8_388_608, "resize_debounce_ms" => 100, "min_rows" => 4, "min_cols" => 20}
      }.freeze

      NULL_TYPES = {
        %w[terminal shell] => ["string", "array", "null"],
        %w[terminal default_profile] => ["string", "null"],
        %w[terminal font_size] => ["number", "null"],
        %w[font_family] => ["string", "null"], %w[icon_theme] => ["string", "null"],
        %w[trim_trailing_whitespace] => ["boolean", "null"], %w[insert_final_newline] => ["boolean", "null"],
        %w[max_line_length] => ["integer", "null"]
      }.freeze

      BASE_SCHEMA = {"$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "object", "properties" => {
        "font_size" => {"type" => "number", "minimum" => 6, "maximum" => 96},
        "tab_size" => {"type" => "integer", "minimum" => 1, "maximum" => 16},
        "scroll_friction" => {"type" => "number", "minimum" => 0, "maximum" => 100},
        "soft_wrap" => {"type" => "boolean"}, "vim_mode" => {"type" => "boolean"}, "use_tabs" => {"type" => "boolean"},
        "auto_pairs" => {"type" => "array", "maxItems" => 64, "items" => {"type" => "array", "minItems" => 2, "maxItems" => 2, "items" => {"type" => "string"}}},
        "keymap" => {"type" => "array", "maxItems" => 128, "items" => {"type" => "object", "required" => ["bindings"], "properties" => {
          "context" => {"type" => "string", "maxLength" => 256},
          "bindings" => {"type" => "object", "maxProperties" => 1024, "additionalProperties" => {"type" => ["string", "null"]}}}}},
        "theme" => {"type" => "string"}, "font_family" => {"type" => ["string", "null"]}, "icon_theme" => {"type" => ["string", "null"]},
        "tabs" => {"type" => "object", "properties" => {
          "activate_on_close" => {"type" => "string", "enum" => %w[history neighbour left right]},
          "close_on_middle_click" => {"type" => "boolean"}, "close_empty_pane" => {"type" => "boolean"},
          "reopen_history_limit" => {"type" => "integer", "minimum" => 0, "maximum" => 1000},
          "confirm_on_close_dirty" => {"type" => "boolean"}}},
        "terminal" => {"type" => "object", "properties" => {
          "shell" => {"type" => ["string", "array", "null"]}, "working_directory" => {"type" => "string"},
          "env" => {"type" => "object", "additionalProperties" => {"type" => ["string", "null"]}},
          "scrollback_lines" => {"type" => "integer", "minimum" => 0, "maximum" => 1_000_000},
          "shell_integration" => {"type" => "boolean"}, "default_profile" => {"type" => ["string", "null"]},
          "profiles" => {"type" => "object", "additionalProperties" => {"$ref" => "#/$defs/terminal_profile"}},
          "font_size" => {"type" => ["number", "null"], "minimum" => 6, "maximum" => 96},
          "line_height" => {"type" => "number", "minimum" => 0.5, "maximum" => 4}, "copy_on_select" => {"type" => "boolean"},
          "blinking" => {"type" => "string", "enum" => %w[off on terminal_controlled]},
          "cursor_shape" => {"type" => "string", "enum" => %w[block bar underline]},
          "close_on_exit" => {"type" => "string", "enum" => %w[never clean always]},
          "confirm_close_running" => {"type" => "boolean"}, "confirm_multiline_paste" => {"type" => "boolean"},
          "restore_on_startup" => {"type" => "boolean"}, "hide_when_empty" => {"type" => "boolean"},
          "max_bytes_per_frame" => {"type" => "integer", "minimum" => 1, "maximum" => 16_777_216},
          "queue_limit_bytes" => {"type" => "integer", "minimum" => 65_536, "maximum" => 268_435_456},
          "resize_debounce_ms" => {"type" => "integer", "minimum" => 0, "maximum" => 10_000},
          "min_rows" => {"type" => "integer", "minimum" => 1, "maximum" => 1000},
          "min_cols" => {"type" => "integer", "minimum" => 1, "maximum" => 1000}}},
        "diagnostics" => {"type" => "object", "required" => %w[inline inline_max_length severity], "properties" => {
          "inline" => {"type" => "boolean"}, "inline_max_length" => {"type" => "integer", "minimum" => 1, "maximum" => 10_000},
          "severity" => {"type" => "string", "enum" => %w[error warning information hint]}}},
        "inlay_hints" => {"type" => "object", "required" => %w[enabled parameter_names types max_length], "properties" => {
          "enabled" => {"type" => "boolean"}, "parameter_names" => {"type" => "boolean"}, "types" => {"type" => "boolean"},
          "max_length" => {"type" => "integer", "minimum" => 1, "maximum" => 10_000}}},
        "code_lens" => {"type" => "object", "required" => ["enabled"], "properties" => {"enabled" => {"type" => "boolean"}}},
        "bracket_colorization" => {"type" => "boolean"},
        "indent_guides" => {"type" => "object", "required" => %w[enabled active], "properties" => {"enabled" => {"type" => "boolean"}, "active" => {"type" => "boolean"}}},
        "render_whitespace" => {"type" => "string", "enum" => %w[none boundary selection all]}, "render_ideographic_space" => {"type" => "boolean"},
        "sticky_scroll" => {"type" => "object", "required" => %w[enabled max_lines], "properties" => {"enabled" => {"type" => "boolean"}, "max_lines" => {"type" => "integer", "minimum" => 1, "maximum" => 20}}},
        "breadcrumbs" => {"type" => "object", "required" => ["enabled"], "properties" => {"enabled" => {"type" => "boolean"}}},
        "minimap" => {"type" => "object", "required" => %w[enabled width show_diagnostics], "properties" => {"enabled" => {"type" => "boolean"}, "width" => {"type" => "integer", "minimum" => 40, "maximum" => 400}, "show_diagnostics" => {"type" => "boolean"}}},
        "auto_save" => {"type" => "string", "enum" => %w[off after_delay on_focus_change]}, "auto_save_delay" => {"type" => "integer", "minimum" => 100, "maximum" => 3_600_000},
        "editorconfig" => {"type" => "boolean"}, "trim_trailing_whitespace" => {"type" => ["boolean", "null"]}, "insert_final_newline" => {"type" => ["boolean", "null"]},
        "max_line_length" => {"type" => ["integer", "null"], "minimum" => 1, "maximum" => 1_000_000},
        "persistent_undo" => {"type" => "object", "additionalProperties" => false, "required" => %w[enabled max_entries expire_days], "properties" => {
          "enabled" => {"type" => "boolean"}, "max_entries" => {"type" => "integer", "minimum" => 1, "maximum" => 10_000}, "expire_days" => {"type" => "integer", "minimum" => 1, "maximum" => 3_650}}},
        "format_on_save" => {"type" => "boolean"}, "code_actions_on_save" => {"type" => "array", "maxItems" => 64, "uniqueItems" => true, "items" => {"type" => "string", "minLength" => 1, "maxLength" => 256}},
        "format_on_save_timeout" => {"type" => "integer", "minimum" => 1, "maximum" => 60_000},
        "git" => {"type" => "object", "additionalProperties" => false, "required" => %w[inline_blame autofetch autofetch_interval], "properties" => {
          "inline_blame" => {"type" => "string", "enum" => %w[off cursor all]}, "autofetch" => {"type" => "boolean"}, "autofetch_interval" => {"type" => "integer", "minimum" => 10, "maximum" => 86_400}}},
        "plugins" => {"type" => "object", "additionalProperties" => false, "required" => ["sandbox"], "properties" => {
          "enabled" => {"type" => "boolean"}, "sandbox" => {"type" => "string", "enum" => %w[off auto required]},
          "directories" => {"type" => "array", "maxItems" => 64, "items" => {"type" => "string", "minLength" => 1}},
          "disabled" => {"type" => "array", "maxItems" => 256, "uniqueItems" => true, "items" => {"type" => "string", "minLength" => 1, "maxLength" => 128, "pattern" => "^[A-Za-z0-9_.-]+$"}},
          "limits" => {"type" => "object", "additionalProperties" => false, "properties" => {
            "memory_mb" => {"type" => "integer", "minimum" => 1, "maximum" => 4096},
            "request_timeout_ms" => {"type" => "integer", "minimum" => 1, "maximum" => 60_000}}},
          "settings" => {"type" => "object"}}},
        "recovery" => {"type" => "object", "additionalProperties" => false, "required" => %w[enabled interval], "properties" => {"enabled" => {"type" => "boolean"}, "interval" => {"type" => "integer", "minimum" => 100, "maximum" => 3_600_000}}},
        "dock" => {"type" => "object", "properties" => {"left" => {"$ref" => "#/$defs/dock"}, "right" => {"$ref" => "#/$defs/dock"}, "bottom" => {"$ref" => "#/$defs/dock"}, "panels" => {"type" => "object", "maxProperties" => 1000, "additionalProperties" => {"$ref" => "#/$defs/panel"}}}},
        "languages" => {"type" => "object", "additionalProperties" => {"allOf" => [{"$ref" => "#"}, {"properties" => {"languages" => false, "debug_adapters" => false, "recovery" => false, "auto_save" => false, "auto_save_delay" => false, "persistent_undo" => false}}]}},
        "language_servers" => {"type" => "object", "additionalProperties" => {"anyOf" => [{"type" => "null"}, {"$ref" => "#/$defs/language_server"}, {"type" => "array", "minItems" => 1, "items" => {"type" => "string", "minLength" => 1}}, {"type" => "array", "minItems" => 1, "maxItems" => 16, "items" => {"$ref" => "#/$defs/language_server"}}]}},
        "debug_adapters" => {"type" => "object", "maxProperties" => 64, "propertyNames" => {"type" => "string", "minLength" => 1, "maxLength" => 128, "pattern" => "^[A-Za-z0-9_.-]+$"}, "additionalProperties" => {"$ref" => "#/$defs/debug_adapter"}}},
        "$defs" => {
          "language_server" => {"type" => "object", "additionalProperties" => false, "required" => ["command"], "properties" => {"command" => {"type" => "array", "minItems" => 1, "items" => {"type" => "string", "minLength" => 1}}, "env" => {"type" => "object", "additionalProperties" => {"type" => ["string", "null"]}}, "initialization_options" => {}, "configuration" => {"type" => "object"}, "features" => {"type" => "array", "minItems" => 1, "uniqueItems" => true, "items" => {"type" => "string", "enum" => %w[completion diagnostics codeAction formatting definition typeDefinition implementation hover signatureHelp references rename documentSymbol codeLens inlayHint semanticTokens documentHighlight foldingRange selectionRange callHierarchy typeHierarchy documentLink linkedEditingRange workspaceSymbol]}}}},
          "debug_adapter" => {"type" => "object", "additionalProperties" => false, "required" => %w[command transport], "properties" => {"command" => {"type" => "array", "minItems" => 1, "maxItems" => 32, "items" => {"type" => "string", "minLength" => 1, "maxLength" => 4096, "pattern" => "^(?![\\s\\S]*[\\u0000-\\u001f\\u007f])[\\s\\S]+$"}}, "transport" => {"type" => "string", "enum" => %w[stdio tcp]}}},
          "terminal_profile" => {"type" => "object", "additionalProperties" => false, "properties" => {"command" => {"anyOf" => [{"type" => "string", "minLength" => 1}, {"type" => "array", "minItems" => 1, "items" => {"type" => "string"}}]}, "path" => {"type" => "string", "minLength" => 1}, "args" => {"type" => "array", "items" => {"type" => "string"}}, "env" => {"type" => "object", "additionalProperties" => {"type" => ["string", "null"]}}}},
          "dock" => {"type" => "object", "required" => %w[size visible], "properties" => {"size" => {"type" => "number", "exclusiveMinimum" => 0}, "visible" => {"type" => "boolean"}}},
          "panel" => {"type" => "object", "required" => %w[size visible], "properties" => {"size" => {"type" => "number", "exclusiveMinimum" => 0}, "visible" => {"type" => "boolean"}}}
        }
      }.freeze

      def self.copy(value)
        case value
        when Hash then value.to_h { |key, child| [key, copy(child)] }
        when Array then value.map { |child| copy(child) }
        else value
        end
      end

      def self.inferred(value, path)
        return {"type" => NULL_TYPES.fetch(path, "null")} if value.nil?

        type = case value
               when true, false then "boolean"
               when Integer then "integer"
               when Numeric then "number"
               when String then "string"
               when Array then "array"
               when Hash then "object"
               else "any"
               end
        result = {"type" => type}
        result["items"] = value.empty? ? {"type" => "any"} : inferred(value.first, path + [0]) if value.is_a?(Array)
        result
      end

      def self.annotate(node, defaults, path = [])
        result = copy(node)
        unless path.empty?
          result["description"] ||= "#{path.join(".")} setting"
          result["default"] = copy(defaults)
        end
        if defaults.is_a?(Hash)
          properties = result["properties"] ||= {}
          defaults.each do |name, value|
            properties[name] = annotate(properties.fetch(name, inferred(value, path + [name])), value, path + [name])
          end
        elsif defaults.is_a?(Array) && result["items"].is_a?(Hash) && !defaults.empty?
          result["items"] = annotate(result["items"], defaults.first, path + [0])
        end
        result
      end

      def self.deep_freeze(value)
        case value
        when Hash
          value.each { |key, child| deep_freeze(key); deep_freeze(child) }
        when Array
          value.each { |child| deep_freeze(child) }
        end
        value.freeze
      end

      def self.describe_nodes(node, path = [])
        result = copy(node)
        result["description"] ||= "#{path.join(".")} setting" unless path.empty?
        if result["properties"].is_a?(Hash)
          result["properties"] = result["properties"].to_h do |name, child|
            [name, describe_nodes(child, path + [name])]
          end
        end
        result["items"] = describe_nodes(result["items"], path + [0]) if result["items"].is_a?(Hash)
        result["additionalProperties"] = describe_nodes(result["additionalProperties"], path + ["*"]) if result["additionalProperties"].is_a?(Hash)
        if result["$defs"].is_a?(Hash)
          result["$defs"] = result["$defs"].to_h { |name, child| [name, describe_nodes(child, path + [name])] }
        end
        result
      end

      def self.kochab_input(schema)
        result = copy(schema)
        result.dig("properties", "languages", "additionalProperties")["$ref"] = "#"
        result
      end

      JSON_SCHEMA = describe_nodes(annotate(BASE_SCHEMA, DEFAULT_VALUES)).freeze
      KOCHAB_SCHEMA = Kochab::Schema.from_json_schema(kochab_input(JSON_SCHEMA))
      DEFAULTS = deep_freeze(KOCHAB_SCHEMA.defaults)
    end
  end
end

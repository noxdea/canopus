# frozen_string_literal: true

require "json"
require "rexml/document"

module Canopus
  class Theme
    module Import
      COLOR_KEYS = {
        "editor.background" => :background, "editor.foreground" => :foreground,
        "sideBar.background" => :panel, "panel.background" => :panel,
        "panel.border" => :border, "editorGroup.border" => :border,
        "tab.activeBackground" => :active_tab, "descriptionForeground" => :muted,
        "focusBorder" => :accent, "editor.selectionBackground" => :selection,
        "editorCursor.foreground" => :cursor, "editor.lineHighlightBackground" => :current_line,
        "statusBar.background" => :status, "errorForeground" => :error,
        "editorError.foreground" => :"diagnostic.error", "problemsErrorIcon.foreground" => :"diagnostic.error",
        "editorWarning.foreground" => :"diagnostic.warning", "problemsWarningIcon.foreground" => :"diagnostic.warning",
        "editorInfo.foreground" => :"diagnostic.information", "problemsInfoIcon.foreground" => :"diagnostic.information",
        "editorHint.foreground" => :"diagnostic.hint", "editorIndentGuide.background" => :"indent.guide",
        "editorIndentGuide.activeBackground" => :"indent.guide.active",
        "editorBracketHighlight.foreground1" => :"bracket.1", "editorBracketHighlight.foreground2" => :"bracket.2",
        "editorBracketHighlight.foreground3" => :"bracket.3", "editorBracketHighlight.foreground4" => :"bracket.4",
        "editorBracketHighlight.foreground5" => :"bracket.5", "editorBracketHighlight.foreground6" => :"bracket.6",
        "editorIndentGuide.background1" => :"indent.guide", "editorIndentGuide.activeBackground1" => :"indent.guide.active"
      }.freeze
      TOKEN_KEYS = {
        "comment" => "Comment", "keyword" => "Keyword", "entity.name.type" => "Name.Class", "entity.name.class" => "Name.Class",
        "entity.name.function" => "Name.Function", "string" => "Literal.String",
        "constant.numeric" => "Literal.Number", "keyword.operator" => "Operator",
        "markup.heading" => "Generic.Heading", "invalid" => "Error"
      }.freeze

      module_function

      def vscode(data, warnings: nil)
        colors = map_colors(data.fetch("colors", {}), warnings)
        syntax = {}
        Array(data["tokenColors"]).each do |entry|
          next unless entry.is_a?(Hash)

          settings = entry["settings"]
          color = settings.is_a?(Hash) && settings["foreground"]
          next unless color
          scopes = entry["scope"].to_s.split(/[,;]/).map(&:strip)
          scopes.each do |scope|
            key = TOKEN_KEYS.keys.find { |prefix| scope == prefix || scope.start_with?(prefix + ".") }
            if key
              syntax[TOKEN_KEYS.fetch(key)] = {"color" => color}
            elsif warnings
              warnings << "unsupported token scope: #{scope}"
            end
          end
        end
        new_theme(data["name"], colors, syntax)
      end

      def tm_theme(xml, warnings: nil)
        values = plist(REXML::Document.new(xml).root.elements[1])
        colors = map_colors(values.fetch("colors", {}), warnings)
        syntax = {}
        Array(values["settings"]).each do |entry|
          next unless entry.is_a?(Hash)

          settings = entry["settings"]
          if entry["scope"].to_s.empty? && settings.is_a?(Hash)
            colors[:foreground] ||= settings["foreground"] if settings["foreground"].is_a?(String)
            colors[:background] ||= settings["background"] if settings["background"].is_a?(String)
            colors[:cursor] ||= settings["caret"] if settings["caret"].is_a?(String)
            next
          end
          color = settings.is_a?(Hash) && settings["foreground"]
          next unless color
          scope = entry["scope"].to_s
          key = TOKEN_KEYS.keys.find { |prefix| scope == prefix || scope.start_with?(prefix + ".") }
          if key
            syntax[TOKEN_KEYS.fetch(key)] = {"color" => color}
          elsif warnings
            warnings << "unsupported token scope: #{scope}"
          end
        end
        new_theme(values["name"], colors, syntax)
      rescue REXML::ParseException => error
        raise Canopus::Error, "invalid tmTheme: #{error.message}"
      end

      def load(path, warnings: nil)
        raise Canopus::Error, "theme exceeds 1 MiB" if File.size(path) > 1_048_576

        source = File.read(path)
        if File.extname(path).downcase == ".tmtheme"
          tm_theme(source, warnings: warnings)
        else
          data = JSON.parse(source)
          vscode(data, warnings: warnings)
        end
      rescue JSON::ParserError => error
        raise Canopus::Error, "invalid theme JSON: #{error.message}"
      end

      def map_colors(values, warnings)
        return {} unless values.is_a?(Hash)

        values.each_with_object({}) do |(key, value), result|
          mapped = COLOR_KEYS[key]
          if mapped && value.is_a?(String)
            result[mapped] = value
          elsif warnings
            warnings << "unsupported theme color: #{key}"
          end
        end
      end

      def new_theme(name, colors, syntax)
        Canopus::Theme.new(name: name.to_s.empty? ? "Imported" : name, colors: colors, syntax: syntax)
      end

      def plist(element)
        return {} unless element
        return element.elements.each_with_object({}) do |child, result|
          next unless child.name == "key"
          value = child.next_element
          result[child.text.to_s] = plist(value)
        end if element.name == "dict"
        return element.elements.map { |child| plist(child) } if element.name == "array"
        return element.text.to_s if %w[string integer real].include?(element.name)
        element.name == "true"
      end
    end
  end
end

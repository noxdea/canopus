# frozen_string_literal: true

module Canopus
  class Theme
    SYNTAX = {"Comment" => "#8f9cae", "Keyword" => "#eaa4c5", "Name.Class" => "#e5cb92", "Name.Function" => "#8ac6df",
      "Literal.String" => "#b6d49c", "Literal.Number" => "#dab38d", "Operator" => "#a7bbdb", "Generic.Heading" => "#e5cb92", "Error" => "#f97583"}.freeze
    LIGHT_SYNTAX = {"Comment" => "#626e7a", "Keyword" => "#853057", "Name.Class" => "#795500", "Name.Function" => "#075b80",
      "Literal.String" => "#356224", "Literal.Number" => "#854b16", "Operator" => "#375780", "Generic.Heading" => "#795500", "Error" => "#aa2438"}.freeze
    DARK = {background: "#161b22", foreground: "#d6dde6", panel: "#10151c", border: "#2c3644",
      active_tab: "#222d3b", muted: "#728399", accent: "#e9a661", selection: "#34547799",
      cursor: "#f4e4c1", current_line: "#ffffff06", error: "#f97583", status: "#202a36",
      :"diagnostic.error" => "#f97583", :"diagnostic.warning" => "#e3b341",
      :"diagnostic.information" => "#58a6ff", :"diagnostic.hint" => "#8b949e",
      :"bracket.1" => "#ffd866", :"bracket.2" => "#ab9df2", :"bracket.3" => "#78dce8",
      :"bracket.4" => "#a9dc76", :"bracket.5" => "#fc9867", :"bracket.6" => "#ff6188",
      :"indent.guide" => "#394657", :"indent.guide.active" => "#7c91aa"}.freeze
    LIGHT = DARK.merge(background: "#faf8f3", foreground: "#293440", panel: "#eeece6", border: "#cecac1",
      active_tab: "#fff", muted: "#6d7780", selection: "#93bdd477", current_line: "#00000006",
      cursor: "#34465a", status: "#e3e2dc", :"diagnostic.error" => "#aa2438",
      :"diagnostic.warning" => "#8a6116", :"diagnostic.information" => "#0969da",
      :"diagnostic.hint" => "#57606a", :"bracket.1" => "#8a5a00", :"bracket.2" => "#6f42c1",
      :"bracket.3" => "#096b7a", :"bracket.4" => "#3f6f20", :"bracket.5" => "#a34318",
      :"bracket.6" => "#b42355", :"indent.guide" => "#c4c9cf", :"indent.guide.active" => "#73808c").freeze
    attr_reader :colors, :syntax, :name
    def initialize(name: "Canopus Dark", colors: {}, syntax: {})
      @name, @syntax = name, syntax
      @colors = (name.match?(/light/i) ? LIGHT : DARK).merge(colors.transform_keys(&:to_sym))
      @colors.each_value { |color| Zaniah::Color.parse(color) }
      @token_mapping = (name.match?(/light/i) ? LIGHT_SYNTAX : SYNTAX).merge(@syntax.transform_values { |value| value.is_a?(Hash) ? value["color"] : value }.compact)
      @token_mapping.each_value { |color| Zaniah::Color.parse(color) }
      @token_cache = {}
    end
    def [](key) = @colors.fetch(key)
    def token_color(token)
      name = token.respond_to?(:qualname) ? token.qualname : token.to_s
      @token_cache[name] ||= begin
        key = @token_mapping.keys.select { |prefix| name == prefix || name.start_with?(prefix + ".") }.max_by(&:length)
        key ? @token_mapping[key] : self[:foreground]
      end
    end
    def self.load(path, warnings: nil)
      if File.extname(path).downcase == ".tmtheme"
        require_relative "theme/import"
        return Import.load(path, warnings: warnings)
      end

      data = Kochab.parse(File.read(path), strict: false).value
      if data.is_a?(Hash) && (data.key?("colors") || data.key?("tokenColors"))
        require_relative "theme/import"
        return Import.vscode(data, warnings: warnings)
      end

      theme = data.fetch("themes", [data]).first
      style = theme.fetch("style", {})
      map = {"editor.background" => :background, "editor.foreground" => :foreground,
        "panel.background" => :panel, "border" => :border, "text.muted" => :muted,
        "status_bar.background" => :status, "editor.active_line.background" => :current_line,
        "diagnostic.error" => :"diagnostic.error", "diagnostic.warning" => :"diagnostic.warning",
        "diagnostic.information" => :"diagnostic.information", "diagnostic.hint" => :"diagnostic.hint",
        "bracket.1" => :"bracket.1", "bracket.2" => :"bracket.2", "bracket.3" => :"bracket.3",
        "bracket.4" => :"bracket.4", "bracket.5" => :"bracket.5", "bracket.6" => :"bracket.6",
        "indent.guide" => :"indent.guide", "indent.guide.active" => :"indent.guide.active"}
      colors = style.each_with_object({}) { |(key, value), result| result[map[key]] = value if map[key] }
      new(name: theme.fetch("name", "Imported"), colors: colors, syntax: style.fetch("syntax", {}))
    end
  end
end

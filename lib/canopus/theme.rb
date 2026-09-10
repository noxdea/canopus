# frozen_string_literal: true

module Canopus
  class Theme
    SYNTAX = {"Comment" => "#8f9cae", "Keyword" => "#eaa4c5", "Name.Class" => "#e5cb92", "Name.Function" => "#8ac6df",
      "Literal.String" => "#b6d49c", "Literal.Number" => "#dab38d", "Operator" => "#a7bbdb", "Generic.Heading" => "#e5cb92", "Error" => "#f97583"}.freeze
    LIGHT_SYNTAX = {"Comment" => "#626e7a", "Keyword" => "#853057", "Name.Class" => "#795500", "Name.Function" => "#075b80",
      "Literal.String" => "#356224", "Literal.Number" => "#854b16", "Operator" => "#375780", "Generic.Heading" => "#795500", "Error" => "#aa2438"}.freeze
    DARK = {background: "#161b22", foreground: "#d6dde6", panel: "#10151c", border: "#2c3644",
      active_tab: "#222d3b", muted: "#728399", accent: "#e9a661", selection: "#34547799",
      cursor: "#f4e4c1", current_line: "#ffffff06", error: "#f97583", status: "#202a36"}.freeze
    LIGHT = DARK.merge(background: "#faf8f3", foreground: "#293440", panel: "#eeece6", border: "#cecac1",
      active_tab: "#fff", muted: "#6d7780", selection: "#93bdd477", current_line: "#00000006",
      cursor: "#34465a", status: "#e3e2dc").freeze
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
    def self.load(path)
      data = Kochab.parse(File.read(path), strict: false).value
      theme = data.fetch("themes", [data]).first
      style = theme.fetch("style", {})
      map = {"editor.background" => :background, "editor.foreground" => :foreground,
        "panel.background" => :panel, "border" => :border, "text.muted" => :muted,
        "status_bar.background" => :status, "editor.active_line.background" => :current_line}
      colors = style.each_with_object({}) { |(key, value), result| result[map[key]] = value if map[key] }
      new(name: theme.fetch("name", "Imported"), colors: colors, syntax: style.fetch("syntax", {}))
    end
  end
end

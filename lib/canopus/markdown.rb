# frozen_string_literal: true

require "rouge"
require "unicode/display_width"

module Canopus
  # Bounded hover content. Rouge already understands Markdown and fenced code;
  # HTML and images remain text and never fetch resources or execute anything.
  class Markdown
    Run = Data.define(:text, :style, :url)
    attr_reader :rows

    def initialize(source, width: 72, max_rows: 18, markup: true)
      raise ArgumentError, "invalid hover dimensions" unless width.is_a?(Integer) && width.positive? && max_rows.is_a?(Integer) && max_rows.positive?
      source = source.to_s.byteslice(0, 65_536).to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).scrub
      tokens = markup ? Rouge::Lexer.find("markdown").new.lex(source).map { |token, value| [token.qualname, value] } : [["Text", source]]
      @rows, column, index = [[]], 0, 0
      while index < tokens.length && @rows.length <= max_rows
        kind, value = tokens[index]
        style, url = :text, nil
        if markup && value == "[" && tokens[index + 1]&.first == "Name.Variable" && tokens[index + 2]&.last == "](" && tokens[index + 3]&.first == "Literal.String.Other" && tokens[index + 4]&.last == ")"
          value, url, style = tokens[index + 1].last, tokens[index + 3].last, :link
          index += 4
        elsif markup
          case kind
          when "Generic.Heading", "Generic.Subheading"
            value, style = value.sub(/\A\#{1,6}\s*/, ""), :heading
          when "Generic.Strong" then value, style = value[2...-2], :strong
          when "Generic.Emph" then value, style = value[1...-1], :emphasis
          when "Literal.String.Backtick" then value, style = value.sub(/\A`+/, "").sub(/`+\z/, ""), :code
          when "Generic.Traceback" then value, style = value.sub(/\A>\s?/, "│ "), :quote
          when "Punctuation"
            if value.match?(/\A(?:`{3,}|~{3,})\z/)
              index += 1 if tokens[index + 1]&.first == "Name.Label"
              value = ""
            end
          else
            style = kind unless kind == "Text"
          end
        end
        value.to_s.each_grapheme_cluster do |grapheme|
          if grapheme.include?("\n")
            @rows << []
            column = 0
            break if @rows.length > max_rows
            next
          end
          cells = Unicode::DisplayWidth.of(grapheme, emoji: :rgi)
          if column.positive? && column + cells > width
            @rows << []
            column = 0
            break if @rows.length > max_rows
          end
          previous = @rows.last.last
          if previous && previous.style == style && previous.url == url
            previous.text << grapheme
          else
            @rows.last << Run.new(+grapheme, style, url)
          end
          column += cells
        end
        index += 1
      end
      @rows = @rows.first(max_rows)
      @rows.pop while @rows.length > 1 && @rows.last.empty?
      @rows.each { |row| row.each { |run| run.text.freeze }; row.freeze }.freeze
    end
  end
end

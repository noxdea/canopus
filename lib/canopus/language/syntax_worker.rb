# frozen_string_literal: true

require "antares"
require_relative "../../canopus"

module Canopus
  module Language
    # Fixed ProcessPool handler. This state never lives on the UI thread.
    module SyntaxWorker
      MAX_DOCUMENTS = 4
      MAX_CACHE_BYTES = 4 << 20
      MAX_SYMBOLS = 10_000
      MAX_BRACKETS = 8192

      def self.call(request)
        source = request.fetch("source")
        unless source.is_a?(String) && source.valid_encoding? && source.encoding == Encoding::UTF_8 && source.bytesize <= BackgroundAnalysis::SOURCE_LIMIT
          raise ArgumentError, "language snapshot must be bounded UTF-8"
        end
        first_row, last_row, base_line, base = request.values_at("first", "last", "base_line", "base")
        unless [first_row, last_row, base_line, base].all? { |value| value.is_a?(Integer) && value >= 0 } &&
            base_line <= first_row && last_row >= first_row && last_row - first_row < BackgroundAnalysis::ROW_LIMIT
          raise ArgumentError, "language token range exceeds limit"
        end
        @documents ||= {}
        key = [request.fetch("id"), base, request.fetch("name"), request.fetch("lexer"), request.fetch("complete")]
        cached = @documents.delete(key)
        if cached
          buffer, document, previous = cached
          update(buffer, previous, source) unless previous == source
        else
          buffer = Buffer.new(source)
          definition = Language::Definition.new(request.fetch("name"), request.fetch("lexer"), [], "", /\A\z/, /\A\z/, [])
          document = Document.new(buffer, definition: definition, background: false)
        end
        @documents[key] = [buffer, document, source]
        while @documents.length > MAX_DOCUMENTS || @documents.values.sum { |entry| entry[2].bytesize } > MAX_CACHE_BYTES
          _, discarded = @documents.shift
          discarded[1].dispose
        end
        first = request.fetch("first") - request.fetch("base_line")
        last = [request.fetch("last") - request.fetch("base_line"), buffer.line_count - 1].min
        highlighter = document.highlighter(strategy: request.fetch("complete") ? nil : :window,
          window_context: request.fetch("complete") ? nil : request.fetch("context"))
        rows = first <= last ? highlighter.tokens_in(first..last) : []
        budget = 65_536
        tokens = (request.fetch("first")..request.fetch("last")).map.with_index do |row, index|
          pairs = rows[index] || []
          if pairs.length > 4096 || pairs.length > budget || pairs.sum { |_, text| text.bytesize } > BackgroundAnalysis::LINE_LIMIT
            local = row - request.fetch("base_line")
            plain = local < buffer.line_count ? BackgroundAnalysis.line(buffer.rope, local) : ""
            values = [["Text", plain]]
          else
            values = pairs.map { |token, text| [token.qualname, text] }
          end
          budget -= values.length
          [row, values]
        end
        syntax = analyze(document, request.fetch("base"), request.fetch("complete")) if request.fetch("syntax")
        complete = request.fetch("complete") && (!syntax || !syntax.delete("truncated"))
        {"tokens" => tokens, "syntax" => syntax, "complete" => complete}
      end

      def self.update(buffer, previous, source)
        first, shared = 0, [previous.bytesize, source.bytesize].min
        first += 4096 while first + 4096 <= shared && previous.byteslice(first, 4096) == source.byteslice(first, 4096)
        first += 1 while first < shared && previous.getbyte(first) == source.getbyte(first)
        first -= 1 while first.positive? && previous.getbyte(first)&.&(0xc0) == 0x80
        tail = 0
        tail += 4096 while tail + 4096 <= shared - first && previous.byteslice(previous.bytesize - tail - 4096, 4096) == source.byteslice(source.bytesize - tail - 4096, 4096)
        tail += 1 while tail < shared - first && previous.getbyte(previous.bytesize - tail - 1) == source.getbyte(source.bytesize - tail - 1)
        tail -= 1 while tail.positive? && previous.getbyte(previous.bytesize - tail)&.&(0xc0) == 0x80
        buffer.edit([[first...(previous.bytesize - tail), source.byteslice(first, source.bytesize - first - tail)]])
        buffer.history.clear
      end

      def self.analyze(document, base, complete)
        all_symbols = document.outline
        outline = all_symbols.first(MAX_SYMBOLS).map do |symbol|
          [symbol.name, symbol.kind.to_s, base + symbol.range.begin, base + symbol.range.end,
            base + symbol.selection.begin, base + symbol.selection.end, symbol.depth]
        end
        diagnostics = complete ? document.diagnostics.first(1000).map { |item| [base + item[:range].begin, base + item[:range].end, item[:message]] } : []
        all_brackets = document.__send__(:bracket_ranges).values.uniq
        brackets = all_brackets.first(MAX_BRACKETS).map { |range| [base + range.begin, base + range.end] }
        folds = document.fold_ranges.first(MAX_SYMBOLS).map { |range| [base + range.begin, base + range.end] }
        {"outline" => outline, "diagnostics" => diagnostics, "brackets" => brackets, "folds" => folds,
          "truncated" => all_symbols.length > MAX_SYMBOLS || all_brackets.length > MAX_BRACKETS || (complete && document.diagnostics.length > 1000)}
      end
    end
  end
end

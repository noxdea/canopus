# frozen_string_literal: true

canopus_root = File.expand_path("../../..", __dir__)
if defined?(Gem::Specification)
  Gem::Specification.find_all_by_name("canopus")
    .find { |specification| File.expand_path(specification.full_gem_path) == canopus_root }&.activate
end
antares_path = ENV["ANTARES_PATH"]
antares_path ? require(File.expand_path("lib/antares", File.expand_path(antares_path, canopus_root))) : require("antares")
require_relative "../../canopus"

module Canopus
  module Language
    # Fixed ProcessPool handler. This state never lives on the UI thread.
    module SyntaxWorker
      MAX_DOCUMENTS = 4
      MAX_CACHE_BYTES = 4 << 20
      MAX_SYMBOLS = 10_000
      MAX_BRACKETS = 8192
      MAX_SELECTIONS = 256
      MAX_SELECTION_RANGES = 10_000

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
          window_context: request.fetch("complete") ? nil : request.fetch("context"),
          max_seconds: request.fetch("complete") ? 2 : nil)
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
        selections = selection_ranges(document, buffer, request)
        syntax = analyze(document, request.fetch("base"), request.fetch("base_line"), request.fetch("complete")) if request.fetch("syntax")
        complete = request.fetch("complete") && (!syntax || !syntax.delete("truncated"))
        {"tokens" => tokens, "syntax" => syntax, "selections" => selections, "complete" => complete}
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

      def self.selection_ranges(document, buffer, request)
        positions = request.fetch("selections", [])
        seen = {}
        unless positions.is_a?(Array) && positions.length <= MAX_SELECTIONS && positions.all? do |value|
          value.is_a?(Array) && value.length == 3 && value[0].is_a?(Integer) && value[0].between?(0, MAX_SELECTIONS - 1) &&
            !seen[value[0]] && (seen[value[0]] = true) && value.drop(1).all? { |item| item.is_a?(Integer) && item >= 0 }
        end
          raise ArgumentError, "invalid selection positions"
        end

        total = 0
        positions.map do |index, row, column|
          local_row = row - request.fetch("base_line")
          point = Denebola::Point.new(local_row, column)
          cursor = buffer.rope.offset_at(point)
          candidates = document.highlighter.structure.selection_ranges(local_row, column).map do |region|
            first = buffer.rope.offset_at(Denebola::Point.new(region.start_line, region.start_column || 0))
            last = buffer.rope.offset_at(Denebola::Point.new(region.end_line,
              region.end_column || buffer.line(region.end_line).length))
            [first, last]
          end.uniq.sort_by { |first, last| [last - first, -first] }
          ranges = candidates.each_with_object([]) do |(first, last), nested|
            next unless first <= cursor && cursor <= last
            next if nested.last && !(first <= nested.last[0] && nested.last[1] <= last)
            total += 1
            raise Error, "too many Antares selection ranges" if total > MAX_SELECTION_RANGES
            nested << [first, last]
          end
          raise Error, "Antares selection range is too deep" if ranges.length > MAX_SELECTIONS
          [index, ranges.map { |first, last| [request.fetch("base") + first, request.fetch("base") + last] }]
        end
      end

      def self.analyze(document, base, base_line, complete)
        all_symbols = document.outline
        outline = all_symbols.first(MAX_SYMBOLS).map do |symbol|
          [symbol.name, symbol.kind.to_s, base + symbol.range.begin, base + symbol.range.end,
            base + symbol.selection.begin, base + symbol.selection.end, symbol.depth]
        end
        diagnostics = complete ? document.diagnostics.first(1000).map { |item| [base + item[:range].begin, base + item[:range].end, item[:message]] } : []
        all_brackets = document.brackets
        brackets = all_brackets.first(MAX_BRACKETS).map do |pair|
          [base + pair.open_range.begin, base + pair.open_range.end, base_line + pair.open_row,
            base + pair.close_range.begin, base + pair.close_range.end, base_line + pair.close_row, pair.depth]
        end
        all_regions = document.structure_regions
        structure_regions = all_regions.first(MAX_SYMBOLS).map do |region|
          [base_line + region[:start_line], base_line + region[:end_line], region[:kind].to_s]
        end
        folds = document.fold_ranges.first(MAX_SYMBOLS).map { |range| [base + range.begin, base + range.end] }
        {"outline" => outline, "diagnostics" => diagnostics, "brackets" => brackets,
          "structure_regions" => structure_regions, "folds" => folds,
          "truncated" => all_symbols.length > MAX_SYMBOLS || all_brackets.length > MAX_BRACKETS ||
            all_regions.length > MAX_SYMBOLS || (complete && document.diagnostics.length > 1000)}
      end
    end
  end
end

# frozen_string_literal: true

module Canopus
  module Language
    class Document
      attr_reader :buffer, :definition
      def initialize(buffer, definition: Language.for_path(buffer.path), background: true)
        @buffer, @definition, @syntax_version = buffer, definition, -1
        @background = BackgroundAnalysis.new(self) if background
        @subscription = buffer.on_edit { |patch| invalidate(patch) }
      end
      def dispose
        @subscription.detach
        @background&.dispose
      end
      def background? = !!@background
      def pending? = @background ? @background.pending? : false
      def analysis_error = @background&.analysis_error
      def poll = @background ? @background.poll : false
      def request(first_line: nil, last_line: nil, rows: nil, syntax: false)
        @background&.request(first_line: first_line, last_line: last_line, rows: rows, syntax: syntax)
        self
      end
      def syntax_complete? = @background ? @background.syntax_complete? : true
      def syntax_ready? = @background ? @background.syntax_ready? : true
      def tokens_current?(row) = @background ? @background.tokens_current?(row) : true
      def tokens_for(row)
        return @background.tokens_for(row) if @background
        highlighter.tokens_for(row)
      end
      # Explicit synchronous escape hatch. Asynchronous UI paths never call this.
      def highlighter(strategy: nil, window_context: nil, max_seconds: nil)
        return @highlighter if @highlighter
        require "antares" unless defined?(Antares::Highlighter)
        large = @buffer.rope.bytesize > 1 << 20
        @highlighter = Antares::Highlighter.new(lexer: Rouge::Lexer.find(@definition.lexer).new,
          lines: ->(row) { @buffer.rope.byteslice(@buffer.rope.line_start(row), (row + 1 < @buffer.line_count ? @buffer.rope.line_start(row + 1) : @buffer.rope.bytesize) - @buffer.rope.line_start(row)).to_s },
          line_count: -> { @buffer.line_count }, strategy: strategy || (large ? :window : :auto),
          window_context: window_context || (@buffer.rope.bytesize > 10 << 20 ? 0 : 500),
          max_seconds: max_seconds || 0.25)
      end
      def invalidate(patch)
        @background&.invalidate(patch)
        return unless @highlighter
        if patch.is_a?(Patch::Composite) || patch.is_a?(Patch::Reload)
          @highlighter = nil
        else
          first = patch.edits.map { |edit| patch.before.point_at(edit.old_range.begin).row }.min
          old_last = patch.edits.map { |edit| patch.before.point_at(edit.old_range.end).row }.max
          new_last = patch.edits.map { |edit| patch.after.point_at(edit.new_range.end).row }.max
          @highlighter.edit(from_line: first, removed: old_last - first + 1, inserted: new_last - first + 1)
        end
      end
      # Explicit local Prism API; use outline/diagnostics for nonblocking UI work.
      def ruby_syntax
        return nil unless @definition.name == "ruby"
        if @syntax_version != @buffer.version
          require "prism"
          @syntax = Prism.parse(@buffer.text)
          @syntax_version = @buffer.version
        end
        @syntax
      end
      def outline
        return @background.outline if @background
        return [] unless ruby_syntax
        symbols, stack = [], [[ruby_syntax.value, 0]]
        until stack.empty?
          node, depth = stack.pop
          kind = case node
          when Prism::DefNode then :method
          when Prism::ClassNode then :class
          when Prism::ModuleNode then :module
          end
          if kind
            name = kind == :method ? node.name.to_s : node.constant_path.slice
            location = kind == :method ? node.name_loc : node.constant_path.location
            symbols << Symbol.new(name, kind, node.location.start_offset...node.location.end_offset,
              location.start_offset...location.end_offset, depth)
          end
          node.compact_child_nodes.reverse_each { |child| stack << [child, depth + (kind ? 1 : 0)] }
        end
        symbols
      end
      def diagnostics
        return @background.diagnostics if @background
        return [] unless ruby_syntax
        ruby_syntax.errors.map { |error| {range: error.location.start_offset...error.location.end_offset, message: error.message, severity: 1} }
      end
      def fold_ranges
        return @background.fold_ranges if @background
        outline.filter_map { |symbol| symbol.range if @buffer.rope.point_at(symbol.range.end).row > @buffer.rope.point_at(symbol.range.begin).row }
      end
      def indent_for(offset, tab_size: 4, use_tabs: false)
        row = @buffer.rope.point_at(offset).row
        before = @buffer.rope.byteslice(@buffer.rope.line_start(row), offset - @buffer.rope.line_start(row)).to_s
        indentation = before[/\A[ \t]*/]
        indentation += use_tabs ? "\t" : " " * tab_size if @definition.indent_open.match?(before)
        indentation
      end
      def bracket_at(offset)
        return @background.bracket_at(offset) if @background
        bracket_ranges[offset]
      end
      def brackets(rows = nil)
        rows = bracket_rows(rows) if rows
        return @background.brackets(rows) if @background
        values = structure_brackets
        rows ? values.select { |pair| pair.close_row >= rows.begin && pair.open_row < rows.end } : values.dup
      end
      def structure_regions
        return @background.structure_regions if @background
        highlighter.structure.fold_regions.map do |region|
          {start_line: region.start_line, end_line: region.end_line, kind: region.kind}.freeze
        end.freeze
      end

      private
      def bracket_rows(rows)
        unless rows.is_a?(Range) && rows.begin.is_a?(Integer) && rows.end.is_a?(Integer) && rows.begin >= 0
          raise ArgumentError, "bracket rows must be a nonnegative integer range"
        end
        last = rows.exclude_end? ? rows.end : rows.end + 1
        raise RangeError, "bracket rows outside document" if last < rows.begin || last > @buffer.line_count
        rows.begin...last
      end

      def bracket_ranges
        return @bracket_ranges if @bracket_ranges_version == @buffer.version

        @bracket_ranges = structure_brackets.each_with_object({}) do |pair, ranges|
          range = (pair.open_range.begin...pair.close_range.end).freeze
          ranges[pair.open_range.begin] = ranges[pair.close_range.begin] = range
        end
        @bracket_ranges_version = @buffer.version
        @bracket_ranges
      end

      def structure_brackets
        return @structure_brackets if @structure_brackets_version == @buffer.version

        boundaries = {}
        byte_offset = lambda do |row, column|
          positions = boundaries[row] ||= @buffer.line(row).each_char.each_with_object([0]) do |character, values|
            values << values.last + character.bytesize
          end
          @buffer.rope.line_start(row) + positions.fetch(column)
        end
        @structure_brackets = highlighter.structure.brackets.map do |pair|
          opening = byte_offset.call(pair.open_line, pair.open_column)
          closing = byte_offset.call(pair.close_line, pair.close_column)
          Bracket.new((opening...opening + 1).freeze, (closing...closing + 1).freeze,
            pair.open_line, pair.close_line, pair.depth).freeze
        end.freeze
        @structure_brackets_version = @buffer.version
        @structure_brackets
      end
    end
  end
end

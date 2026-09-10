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
      def highlighter(strategy: nil, window_context: nil)
        return @highlighter if @highlighter
        require "antares"
        large = @buffer.rope.bytesize > 1 << 20
        @highlighter = Antares::Highlighter.new(lexer: Rouge::Lexer.find(@definition.lexer).new,
          lines: ->(row) { @buffer.rope.byteslice(@buffer.rope.line_start(row), (row + 1 < @buffer.line_count ? @buffer.rope.line_start(row + 1) : @buffer.rope.bytesize) - @buffer.rope.line_start(row)).to_s },
          line_count: -> { @buffer.line_count }, strategy: strategy || (large ? :window : :auto),
          window_context: window_context || (@buffer.rope.bytesize > 10 << 20 ? 0 : 500))
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

      private
      def bracket_ranges
        return @brackets if @brackets_version == @buffer.version
        pairs = {"(" => ")", "[" => "]", "{" => "}"}
        tokens = if @definition.name == "ruby"
          require "prism"
          Prism.lex(@buffer.text).value.filter_map do |token, _state|
            next unless %w[PARENTHESIS_LEFT PARENTHESIS_RIGHT BRACKET_LEFT BRACKET_RIGHT BRACE_LEFT BRACE_RIGHT].include?(token.type.to_s)
            [token.location.start_offset, token.value]
          end
        else
          require "rouge"
          collected, byte = [], 0
          Rouge::Lexer.find(@definition.lexer).new.lex(@buffer.text).each do |token, value|
            unless token.qualname.start_with?("Literal.String", "Comment")
              value.b.scan(/[()\[\]{}]/n) { |character| collected << [byte + Regexp.last_match.begin(0), character] }
            end
            byte += value.bytesize
          end
          collected
        end
        stack, @brackets = [], {}
        tokens.each do |position, character|
          if pairs.key?(character)
            stack << [position, character]
          elsif stack.last && pairs[stack.last[1]] == character
            opening = stack.pop[0]
            range = (opening...position + character.bytesize).freeze
            @brackets[opening] = @brackets[position] = range
          else
            stack.clear
          end
        end
        @brackets_version = @buffer.version
        @brackets
      end
    end
  end
end

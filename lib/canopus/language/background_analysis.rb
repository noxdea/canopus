# frozen_string_literal: true

module Canopus
  module Language
    class BackgroundAnalysis
      EMPTY = [].freeze
      SOURCE_LIMIT = 2 << 20
      LINE_LIMIT = 16 << 10
      ROW_LIMIT = 256
      CACHE_ROWS = 512
      Snapshot = Data.define(:rope, :version, :id, :name, :lexer, :first, :last, :syntax)
      attr_reader :analysis_error

      def initialize(document)
        @document, @buffer = document, document.buffer
        @id = "#{Process.pid}:#{object_id}"
        @tokens, @stale, @provisional, @generation = {}, {}, {}, 0
        @syntax_rows = {}
        @disabled = @buffer.rope.respond_to?(:lazy?) && @buffer.rope.lazy?
      end

      def tokens_for(row)
        validate_row(row)
        return @tokens[row] if @tokens.key?(row)
        unless @disabled || @disposed || @explicit_rows
          first, last = @range || [row, row]
          if row < first
            first, last = row, [last, row + ROW_LIMIT - 1].min
          elsif row > last
            first, last = [first, row - ROW_LIMIT + 1].max, row
          end
          request(first_line: first, last_line: last)
        end
        return @stale[row] if @stale.key?(row)
        return @provisional[row] if @provisional.key?(row)
        @provisional.shift if @provisional.length >= CACHE_ROWS
        @provisional[row] = [["Text", self.class.line(@buffer.rope, row)].freeze].freeze
      end

      def request(first_line: nil, last_line: nil, rows: nil, syntax: false)
        return if @disabled || @disposed
        if rows
          unless rows.is_a?(Array) && rows.length.between?(1, ROW_LIMIT) && first_line.nil? && last_line.nil?
            raise ArgumentError, "language rows must contain 1..#{ROW_LIMIT} entries without a range"
          end
          rows.each { |row| validate_row(row) }
          rows = rows.uniq.sort.freeze
          @explicit_rows = true
        elsif first_line || last_line || !@rows
          first = first_line || @range&.first || 0
          last = last_line || @range&.last || first
          validate_row(first)
          validate_row(last)
          raise ArgumentError, "inverted language range" if last < first
          rows = (first..[last, first + ROW_LIMIT - 1].min).to_a.freeze
          @explicit_rows = false
        else
          rows = @rows
        end
        changed = rows != @rows || (syntax && !@want_syntax)
        if rows != @rows && !syntax_complete?
          @syntax = nil
          @syntax_rows.clear
        end
        @want_syntax ||= syntax
        if changed
          @job&.cancel
          @job = nil
          @generation += 1
          @failed = false
          @analysis_error = nil
        end
        @rows, @range = rows, [rows.first, rows.last].freeze
        @dirty = !@failed && missing_work?
        self
      end

      def pending? = !@disposed && !@disabled && (!!@job || !!@dirty)
      def tokens_current?(row) = @tokens.key?(row)
      def syntax_ready? = !!@syntax
      def syntax_complete? = !!(@syntax && @syntax[:complete])
      def outline = (request(syntax: true); @syntax ? @syntax[:outline] : EMPTY)
      def diagnostics = (request(syntax: true); @syntax ? @syntax[:diagnostics] : EMPTY)
      def fold_ranges = (request(syntax: true); @syntax ? @syntax[:folds] : EMPTY)
      def bracket_at(offset) = (request(syntax: true); @syntax && @syntax[:brackets][offset])

      def invalidate(patch)
        @job&.cancel
        @job = @syntax = nil
        @syntax_rows.clear
        if patch.is_a?(Patch::Reload)
          @tokens.clear
          @stale.clear
        else
          (patch.is_a?(Patch::Composite) ? patch.patches : [patch]).each { |item| retain_unchanged_rows(item) }
        end
        @provisional.clear
        @generation += 1
        @failed = false
        @analysis_error = nil
        @disabled = @buffer.rope.respond_to?(:lazy?) && @buffer.rope.lazy?
        @rows = @rows&.map { |row| [row, @buffer.line_count - 1].min }&.uniq&.freeze
        @range = [@rows.first, @rows.last].freeze if @rows
        @dirty = !!@rows && !@disabled
      end

      def poll
        return false unless pending?
        changed = false
        if @job&.future&.done?
          job, @job = @job, nil
          result = job.future.await(timeout: 0)
          if @submitted_version == @buffer.version && @submitted_generation == @generation
            result[:tokens].each { |row, tokens| @tokens[row] = tokens; @stale.delete(row) }
            while @tokens.length > CACHE_ROWS
              @tokens.delete(@tokens.each_key.find { |row| !@rows.include?(row) })
            end
            @stale.shift while @stale.length + @tokens.length > CACHE_ROWS
            if result[:syntax]
              @syntax = result[:syntax]
              result[:tokens].each_key { |row| @syntax_rows[row] = true }
            end
            @dirty = missing_work?
            changed = true
          end
        end
        if @dirty && !@job
          @scheduler ||= Scheduler.acquire
          # A folded viewport can contain distant source rows. Fill one missing
          # contiguous run at a time without paint changing/cancelling its job.
          missing = @rows.select { |row| row_needed?(row) }
          missing = @rows if missing.empty?
          first = last = missing.first
          missing.drop(1).each do |row|
            break unless row == last + 1
            last = row
          end
          snapshot = Snapshot.new(@buffer.rope, @buffer.version, @id,
            @document.definition.name, @document.definition.lexer, first, last, !!(@want_syntax && !syntax_complete?))
          if (@job = @scheduler.submit(snapshot, prior_syntax: @syntax))
            @submitted_version, @submitted_generation = @buffer.version, @generation
          end
        end
        changed
      rescue StandardError => error
        @job&.cancel
        @job = nil
        @failed, @dirty = true, false
        @analysis_error = error
        raise
      end

      def dispose
        return if @disposed
        @disposed = true
        @job&.cancel
        @job = nil
        Scheduler.release(@scheduler) if @scheduler
        @scheduler = nil
        @tokens.clear
        @stale.clear
        @provisional.clear
        @syntax_rows.clear
        @syntax = nil
        @analysis_error = nil
      end

      def self.line(rope, row)
        first = rope.line_start(row)
        last = row + 1 < rope.line_count ? rope.line_start(row + 1) : rope.bytesize
        ending = boundary(rope, [last, first + LINE_LIMIT].min)
        rope.byteslice(first, ending - first).to_s.freeze
      end

      def self.boundary(rope, offset)
        rope.point_at(offset)
        offset
      rescue RangeError
        offset -= 1
        retry
      end

      def self.prepare(snapshot, job)
        rope, first, last = snapshot.rope, snapshot.first, snapshot.last
        complete = rope.bytesize <= 1 << 20
        from, to, context = 0, rope.bytesize, 0
        unless complete
          context = rope.bytesize <= 10 << 20 ? 500 : 0
          start_row = [first - context, 0].max
          finish_row = [last + context + 1, rope.line_count].min
          requested_end = last + 1 < rope.line_count ? rope.line_start(last + 1) : rope.bytesize
          while start_row < first && requested_end - rope.line_start(start_row) > SOURCE_LIMIT
            job.check!
            start_row += 1
          end
          from = rope.line_start(start_row)
          to = finish_row < rope.line_count ? rope.line_start(finish_row) : rope.bytesize
          to = boundary(rope, [to, from + SOURCE_LIMIT].min)
        end
        # A capped snapshot may end before later requested rows, or exactly at
        # the start of a row whose content was not copied. Never cache that row
        # as an empty, supposedly current token result; the next batch reads it.
        end_row = rope.point_at(to).row
        end_row -= 1 if to < rope.bytesize && rope.line_start(end_row) == to
        last = [last, end_row].min
        job.check!
        source = rope.byteslice(from, to - from).to_s.freeze
        {"id" => snapshot.id, "version" => snapshot.version, "name" => snapshot.name,
          "lexer" => snapshot.lexer, "source" => source, "base" => from,
          "base_line" => rope.point_at(from).row, "first" => first, "last" => last,
          "syntax" => snapshot.syntax, "complete" => complete, "context" => context}.freeze
      end

      def self.decode(response, prior_syntax: nil)
        tokens = response.fetch("tokens").to_h do |row, pairs|
          [row, pairs.map { |name, value| [name.freeze, value.freeze].freeze }.freeze]
        end.freeze
        raw = response["syntax"]
        syntax = if raw
          outline = raw.fetch("outline").map do |name, kind, first, last, start, finish, depth|
            Language::Symbol.new(name.freeze, kind.to_sym, (first...last).freeze, (start...finish).freeze, depth)
          end.freeze
          brackets = {}
          raw.fetch("brackets").each do |first, last|
            range = (first...last).freeze
            brackets[first] = brackets[last - 1] = range
          end
          {outline: outline, diagnostics: raw.fetch("diagnostics").map { |first, last, message| {range: (first...last).freeze, message: message.freeze, severity: 1}.freeze }.freeze,
            folds: raw.fetch("folds").map { |first, last| (first...last).freeze }.freeze,
            brackets: brackets.freeze, complete: response.fetch("complete")}.freeze
        end
        syntax = merge_syntax(prior_syntax, syntax) if prior_syntax && syntax && !syntax[:complete]
        {tokens: tokens, syntax: syntax}.freeze
      end

      # Decoding and bounded merging happen on a preparation thread, never in
      # paint/poll. Overlapping context windows must not duplicate symbols.
      def self.merge_syntax(previous, current)
        return previous if previous[:complete]
        outlines = (previous[:outline] + current[:outline]).uniq { |item| [item.name, item.kind, item.range, item.selection] }
        brackets = (previous[:brackets].values + current[:brackets].values).uniq.first(8192)
        {outline: outlines.sort_by { |item| item.selection.begin }.first(10_000).freeze,
          diagnostics: (previous[:diagnostics] + current[:diagnostics]).uniq.first(1000).freeze,
          folds: (previous[:folds] + current[:folds]).uniq.sort_by(&:begin).first(10_000).freeze,
          brackets: brackets.each_with_object({}) { |range, result| result[range.begin] = result[range.end - 1] = range }.freeze,
          complete: false}.freeze
      end

      private
      def row_needed?(row) = !@tokens.key?(row) || (@want_syntax && !syntax_complete? && !@syntax_rows.key?(row))
      def missing_work? = @rows.any? { |row| row_needed?(row) }

      def retain_unchanged_rows(patch)
        return if patch.edits.empty?
        changes = patch.edits.map do |edit|
          first, last = patch.before.point_at(edit.old_range.begin).row, patch.before.point_at(edit.old_range.end).row
          inserted = patch.after.point_at(edit.new_range.end).row - patch.after.point_at(edit.new_range.begin).row
          [first, last, inserted - (last - first)]
        end
        earliest = changes.map(&:first).min
        fresh, stale = {}, {}
        [@stale, @tokens].each do |cache|
          cache.each do |row, tokens|
            next if changes.any? { |first, last, _| row.between?(first, last) }
            shift = changes.sum { |_, last, delta| row > last ? delta : 0 }
            destination = cache.equal?(@tokens) && row < earliest ? fresh : stale
            destination[row + shift] = tokens
          end
        end
        @tokens, @stale = fresh, stale
      end
      def validate_row(row)
        raise RangeError, "language row outside buffer" unless row.is_a?(Integer) && row >= 0 && row < @buffer.line_count
      end
    end
  end
end

require_relative "background_analysis/job"
require_relative "background_analysis/scheduler"

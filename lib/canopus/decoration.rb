# frozen_string_literal: true

module Canopus
  module Decoration
    KINDS = %i[inline block gutter highlight line].freeze
    Item = Data.define(:kind, :range, :row, :content, :style, :priority, :source, :on_click)

    class Registry
      CACHE_LIMIT = 256

      attr_reader :version

      def initialize
        @suppliers, @generations, @cache = {}, Hash.new(0), {}
        @lock, @version = Mutex.new, 0
      end

      def register(source, &supplier)
        raise ArgumentError, "decoration supplier required" unless supplier

        source = normalize_source(source)
        @lock.synchronize do
          @suppliers[source] = supplier
          invalidate_locked(source)
        end
        source
      end

      def unregister(source)
        source = normalize_source(source)
        @lock.synchronize do
          supplier = @suppliers.delete(source)
          invalidate_locked(source) if supplier
          supplier
        end
      end

      def items_for(buffer, row_range, context: nil)
        first, last = normalize_rows(row_range)
        state = [buffer.respond_to?(:version) ? buffer.version : nil,
          context&.object_id,
          context&.respond_to?(:selections) ? context.selections : buffer.respond_to?(:selections) ? buffer.selections : nil,
          context&.respond_to?(:tab_size) ? context.tab_size : nil,
          context&.respond_to?(:language_document) ? context.language_document.object_id : nil]
        suppliers = @lock.synchronize do
          @suppliers.map { |source, supplier| [source, supplier, @generations[source]] }
        end
        items = suppliers.flat_map do |source, supplier, generation|
          key = [source, buffer.object_id, state, first, last]
          cached = @lock.synchronize { @cache[key] }
          next cached if cached

          supplied = if supplier.arity == 2
            supplier.call(buffer, first...last)
          else
            supplier.call(buffer, first...last, context)
          end
          raise TypeError, "decoration supplier must return an array" unless supplied.is_a?(Array)
          supplied = supplied.map { |item| normalize_item(item, source) }.freeze
          @lock.synchronize do
            if @suppliers[source].equal?(supplier) && @generations[source] == generation
              @cache.shift while @cache.length >= CACHE_LIMIT
              @cache[key] = supplied
            end
          end
          supplied
        end
        items.sort_by { |item| item.priority }.freeze
      end

      def invalidate(source, buffer: nil, rows: nil)
        source = normalize_source(source)
        row_bounds = normalize_rows(rows) if rows
        @lock.synchronize do
          @version += 1
          @generations[source] += 1
          if buffer || row_bounds
            @cache.delete_if do |key, _|
              same_source = key[0] == source
              same_buffer = !buffer || key[1] == buffer.object_id
              overlaps = !row_bounds || (key[3] < row_bounds[1] && row_bounds[0] < key[4])
              same_source && same_buffer && overlaps
            end
          else
            @cache.delete_if { |key, _| key[0] == source }
          end
        end
        nil
      end

      private

      def invalidate_locked(source)
        @generations[source] += 1
        @version += 1
        @cache.delete_if { |key, _| key[0] == source }
      end

      def normalize_source(source)
        valid = source.is_a?(Symbol) && !source.to_s.empty? && !source.to_s.include?(":") &&
          !source.to_s.match?(/[\x00-\x1f\x7f]/)
        raise ArgumentError, "invalid decoration source" unless valid

        source
      end

      def normalize_rows(rows)
        unless rows.is_a?(Range) && rows.begin.is_a?(Integer) && rows.end.is_a?(Integer) && rows.begin >= 0
          raise ArgumentError, "decoration rows must be a nonnegative integer range"
        end
        last = rows.exclude_end? ? rows.end : rows.end + 1
        raise ArgumentError, "decoration row range is reversed" if last < rows.begin

        [rows.begin, last]
      end

      def normalize_item(item, source)
        raise TypeError, "decoration supplier must return items" unless item.is_a?(Item)
        raise ArgumentError, "invalid decoration kind" unless KINDS.include?(item.kind)
        unless item.priority.is_a?(Numeric) && item.priority.finite?
          raise ArgumentError, "decoration priority must be finite"
        end
        unless item.row.nil? || (item.row.is_a?(Integer) && item.row >= 0)
          raise ArgumentError, "decoration row must be nonnegative"
        end
        unless item.range.nil? || (item.range.is_a?(Range) && item.range.begin.is_a?(Integer) && item.range.end.is_a?(Integer))
          raise ArgumentError, "decoration range must contain integer offsets"
        end
        raise ArgumentError, "decoration click handler must be callable" unless item.on_click.nil? || item.on_click.respond_to?(:call)
        item.source == source ? item : item.with(source: source)
      end
    end
  end
end

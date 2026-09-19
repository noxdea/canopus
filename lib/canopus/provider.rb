# frozen_string_literal: true

module Canopus
  module Provider
    Completion = Data.define(:label, :insert_text, :kind, :detail, :documentation,
      :sort_text, :filter_text, :additional_edits, :source)

    class Registry
      MAX_PROVIDERS = 64
      MAX_ITEMS = 10_000
      MAX_STRING = 65_536
      PROVIDER_TIMEOUT = 0.2

      def initialize
        @completion, @inline, @sequence = {}, {}, 0
      end

      def register_completion(source, priority:, &supplier)
        source = normalize_source(source)
        raise ArgumentError, "completion priority must be finite" unless priority.is_a?(Numeric) && priority.real? && priority.finite?
        raise ArgumentError, "completion supplier required" unless supplier
        raise ArgumentError, "too many completion providers" if !@completion.key?(source) && @completion.length >= MAX_PROVIDERS

        @sequence += 1
        @completion[source] = [priority, @sequence, supplier]
        source
      end

      def complete(buffer, offset, context)
        validate_position(buffer, offset)
        query = completion_query(context)
        ranked, jobs = [], []
        @completion.to_a.each do |source, details|
          thread = Thread.new { resolve(details.last.call(buffer, offset, context)) }
          thread.report_on_exception = false
          jobs << [source, details, thread]
        end
        jobs.sort_by! { |_source, (priority, registration, _supplier), _thread| [-priority, registration] }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PROVIDER_TIMEOUT
        jobs.each do |source, (priority, registration, _supplier), thread|
          break if ranked.length == MAX_ITEMS
          begin
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            unless !thread.alive? || remaining.positive? && thread.join(remaining)
              raise RuntimeError, "completion provider timed out"
            end
            supplied = thread.value
            raise TypeError, "completion supplier must return an array" unless supplied.is_a?(Array)
            raise ArgumentError, "completion provider returned too many items" if supplied.length > MAX_ITEMS
            supplied = supplied.first(MAX_ITEMS - ranked.length)

            ranked.concat(supplied.each_with_index.map do |item, index|
              completion = normalize_completion(item, source, buffer)
              score = Spica.score(query, completion.filter_text || completion.label)
              [completion, score, priority, registration, index]
            end)
          rescue StandardError => error
            provider_error(context, source, error)
          end
        end

        ranked.sort_by! { |completion, score, priority, registration, index| [-score, -priority, completion.sort_text || completion.label, registration, index] }
        ranked.uniq! { |completion, _score, _priority, _registration, _index| [completion.label, completion.insert_text] }
        ranked.map!(&:first)
        ranked.freeze
      ensure
        jobs&.each do |_source, _details, thread|
          thread.kill if thread.alive?
          begin
            thread.join
          rescue StandardError
            nil
          end
        end
      end

      def register_inline_completion(source, &supplier)
        source = normalize_source(source)
        raise ArgumentError, "inline completion supplier required" unless supplier
        raise ArgumentError, "too many inline completion providers" if !@inline.key?(source) && @inline.length >= MAX_PROVIDERS

        @sequence += 1
        @inline[source] = [@sequence, supplier]
        source
      end

      def inline_completion(buffer, offset)
        validate_position(buffer, offset)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PROVIDER_TIMEOUT
        @inline.sort_by { |_source, (registration, _supplier)| registration }.each do |_source, (_registration, supplier)|
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break unless remaining.positive?
          thread = Thread.new { resolve(supplier.call(buffer, offset)) }
          thread.report_on_exception = false
          begin
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break unless !thread.alive? || remaining.positive? && thread.join(remaining)
            value = thread.value
            next if value.nil?
            return normalize_string(value, "inline completion")
          rescue StandardError
            next
          ensure
            thread.kill if thread.alive?
            begin
              thread.join
            rescue StandardError
              nil
            end
          end
        end
        nil
      end

      private

      def resolve(value)
        value.respond_to?(:await) ? value.await(timeout: PROVIDER_TIMEOUT) : value
      end

      def completion_query(context)
        value = context.respond_to?(:[]) && (context[:query] || context["query"])
        value.nil? ? "" : normalize_string(value, "completion query", maximum: 256)
      end

      def normalize_completion(item, source, buffer)
        raise TypeError, "completion provider must return completions" unless item.is_a?(Completion)

        label = normalize_string(item.label, "completion label")
        raise ArgumentError, "completion label must not be empty" if label.empty?
        insert_text = item.insert_text.nil? ? label : normalize_string(item.insert_text, "completion insertion")
        detail = normalize_optional_string(item.detail, "completion detail")
        documentation = normalize_optional_string(item.documentation, "completion documentation")
        sort_text = normalize_optional_string(item.sort_text, "completion sort text")
        filter_text = normalize_optional_string(item.filter_text, "completion filter text")
        kind = item.kind
        unless kind.nil? || kind.is_a?(Integer) || kind.is_a?(Symbol) || kind.is_a?(String)
          raise TypeError, "invalid completion kind"
        end
        kind = normalize_string(kind, "completion kind") if kind.is_a?(String)
        edits = item.additional_edits || []
        raise TypeError, "completion additional edits must be an array" unless edits.is_a?(Array)
        raise ArgumentError, "too many completion additional edits" if edits.length > 1_000
        edits = edits.map do |entry|
          unless entry.is_a?(Array) && entry.length == 2 && entry[0].is_a?(Range) && entry[1].is_a?(String) &&
              entry[0].begin.is_a?(Integer) && entry[0].end.is_a?(Integer) && entry[0].begin >= 0 && entry[0].end >= entry[0].begin &&
              entry[0].end <= buffer.rope.bytesize
            raise TypeError, "invalid completion additional edit"
          end
          buffer.rope.point_at(entry[0].begin)
          buffer.rope.point_at(entry[0].end)
          [(entry[0].begin...entry[0].end).freeze, normalize_string(entry[1], "completion additional edit")].freeze
        end.freeze

        Completion.new(label, insert_text, kind, detail, documentation, sort_text, filter_text, edits, source)
      end

      def normalize_optional_string(value, name)
        value.nil? ? nil : normalize_string(value, name)
      end

      def normalize_string(value, name, maximum: MAX_STRING)
        utf8 = value.is_a?(String) && value.valid_encoding? &&
          (value.encoding == Encoding::UTF_8 || value.encoding.ascii_compatible? && value.ascii_only?)
        unless utf8 && value.bytesize <= maximum && !value.include?("\0")
          raise ArgumentError, "invalid #{name}"
        end
        value.dup.freeze
      end

      def normalize_source(source)
        valid = source.is_a?(Symbol) && !source.to_s.empty? && !source.to_s.include?(":") &&
          !source.to_s.match?(/[\x00-\x1f\x7f]/)
        raise ArgumentError, "invalid provider source" unless valid
        source
      end

      def validate_position(buffer, offset)
        size = buffer.respond_to?(:rope) && buffer.rope.respond_to?(:bytesize) ? buffer.rope.bytesize : nil
        unless offset.is_a?(Integer) && size.is_a?(Integer) && offset.between?(0, size)
          raise ArgumentError, "invalid provider buffer offset"
        end
      end

      def provider_error(context, source, error)
        return unless context.is_a?(Hash) && context[:errors].is_a?(Array) && context[:errors].length < MAX_PROVIDERS
        message = error.message.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).slice(0, 4_096).freeze
        context[:errors] << [source, message].freeze
      end
    end
  end
end

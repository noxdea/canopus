# frozen_string_literal: true

require "set"
require "zaniah/ui"

module Canopus
  module Debug
    class Console
      ITEM_LIMIT = 1_000
      TEXT_LIMIT = 4_096
      PENDING_LIMIT = 16
      OUTPUT_QUEUE_LIMIT = ITEM_LIMIT

      attr_reader :tree, :entries, :selected_frame

      def initialize(post:, request_frame:)
        raise ArgumentError, "debug console callbacks must be callable" unless [post, request_frame].all? { |item| item.respond_to?(:call) }

        @post, @request_frame = post, request_frame
        @generation = @sequence = 0
        @pending = Set.new
        @output_lock = Mutex.new
        @output_generation = 0
        @output_queue = []
        @output_flush_pending = false
        @entries = [].freeze
        @tree = Zaniah::UI::TreeView.new(nodes, height: 320)
      end

      def attach(session)
        reset_requests
        reset_output(session)
        @selected_frame = nil
        @entries = [].freeze
        refresh
        self
      end

      def stopped(session, frame)
        return false unless @session.equal?(session)

        reset_requests
        @selected_frame = frame
        true
      end

      def continued(session)
        return false unless @session.equal?(session)

        reset_requests
        @selected_frame = nil
        true
      end

      def clear
        detach
        @entries = [].freeze
        refresh
        nil
      end

      def detach
        reset_requests
        reset_output(nil)
        @selected_frame = nil
        nil
      end

      def output(session, event)
        return false unless output_session?(session)
        rows = output_rows(event)
        return false if rows.empty?

        schedule = false
        generation = @output_lock.synchronize do
          next unless @session.equal?(session)

          room = OUTPUT_QUEUE_LIMIT - @output_queue.length
          @output_queue.concat(rows.first(room)) if room.positive?
          unless @output_flush_pending
            @output_flush_pending = schedule = true
          end
          @output_generation
        end
        return false unless generation

        @post.call { flush_output(session, generation) } if schedule
        true
      end

      def evaluate(expression)
        expression = checked_expression(expression)
        raise Error, "debug session is not stopped" unless active?
        raise Error, "too many pending debug evaluations" if @pending.length >= PENDING_LIMIT

        generation, session, frame = @generation, @session, @selected_frame
        append("> #{expression}")
        future = session.evaluate(expression, frame_id: frame.id, context: "repl")
        @pending.add(future)
        future.on_complete do |variable, error|
          @post.call do
            @pending.delete(future)
            next unless generation == @generation && @session.equal?(session) && @selected_frame.equal?(frame)

            if error
              append("Error: #{bounded_text(error.message)}")
            else
              append(result_label(variable))
            end
          end
        end
        future
      end

      private

      def active? = !!(@session && @selected_frame)

      def nodes
        return [{id: [:debug_console_status, :empty].freeze, label: "No debug output", value: nil}.freeze] if @entries.empty?

        @entries.map { |entry| {id: [:debug_console, entry[:id]].freeze, label: entry[:label], value: nil}.freeze }.freeze
      end

      def append(label)
        append_rows([bounded_text(label)])
      end

      def append_rows(rows)
        @sequence += 1
        added = rows.each_with_index.map do |label, index|
          {id: @sequence + index, label: bounded_line(label).freeze}.freeze
        end
        @sequence += added.length - 1
        @entries = [*@entries, *added].last(ITEM_LIMIT).freeze
        refresh
      end

      def refresh
        @tree.replace(nodes)
        @request_frame.call
      end

      def output_rows(event)
        return [] unless event.is_a?(Hash)

        output = event["output"] || event[:output]
        return [] unless output.is_a?(String)
        output = bounded_output(output)
        return [] if output.empty?

        category = event["category"] || event[:category]
        category = bounded_text(category) if category.is_a?(String)
        source = event["source"] || event[:source]
        source = source_label(source)
        line = event["line"] || event[:line]
        line = nil unless line.is_a?(Integer) && line.between?(1, 0x7fff_ffff)
        location = source && line ? "#{source}:#{line}" : source
        prefix = [category, location].compact.reject(&:empty?)
        prefix = prefix.empty? ? "" : "[#{prefix.join(" ")}] "
        rows = output.split("\n", -1)
        rows.pop if output.end_with?("\n")
        rows[0] = "#{prefix}#{rows[0]}" unless prefix.empty?
        rows.first(OUTPUT_QUEUE_LIMIT).map { |row| bounded_line(row).freeze }.freeze
      end

      def source_label(source)
        return unless source.is_a?(Hash)

        value = source["name"] || source[:name]
        unless value.is_a?(String) && !value.empty?
          path = source["path"] || source[:path]
          return unless path.is_a?(String)

          value = bounded_text(path).tr("\\", "/").split("/").last
        end
        value = bounded_text(value).tr("\\", "/")
        value.include?("/") ? value.split("/").last : value
      end

      def result_label(variable)
        value = variable.respond_to?(:value) ? variable.value : nil
        type = variable.respond_to?(:type) ? variable.type : nil
        text = bounded_text(value)
        type = bounded_text(type) if type
        type && !type.empty? ? "#{text} · #{type}" : text
      end

      def checked_expression(value)
        valid = value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding? &&
          value.bytesize.between?(1, TEXT_LIMIT) && !value.include?("\0") && !value.strip.empty?
        raise ArgumentError, "invalid debug expression" unless valid

        value.dup.freeze
      end

      def bounded_text(value)
        value.to_s.byteslice(0, TEXT_LIMIT).to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
          .gsub(/[\x00-\x1f\x7f]+/, " ").gsub(/\s+/, " ").strip
      end

      def bounded_output(value)
        value.byteslice(0, TEXT_LIMIT).to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
          .gsub(/\r\n?/, "\n").gsub(/[\x00-\x09\x0b\x0c\x0e-\x1f\x7f]+/, " ")
      end

      def bounded_line(value)
        value.to_s.byteslice(0, TEXT_LIMIT).to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
      end

      def output_session?(session) = @output_lock.synchronize { @session.equal?(session) }

      def flush_output(session, generation)
        rows = @output_lock.synchronize do
          next unless generation == @output_generation && @session.equal?(session)

          values, @output_queue = @output_queue, []
          @output_flush_pending = false
          values
        end
        return false unless rows && !rows.empty?

        append_rows(rows)
        true
      end

      def reset_output(session)
        @output_lock.synchronize do
          @output_generation += 1
          @session = session
          @output_queue = []
          @output_flush_pending = false
        end
      end

      def reset_requests
        @generation += 1
        pending, @pending = @pending, Set.new
        pending.each(&:cancel)
      end
    end
  end
end

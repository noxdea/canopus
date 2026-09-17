# frozen_string_literal: true

module Canopus
  module Task
    class Runner
      Output = Data.define(:id, :label, :terminal, :presentation)
      MAX_OUTPUTS = 32
      MAX_CLOSERS = 32
      STOP_GRACE_SECONDS = 0.25

      attr_reader :active_index

      def initialize(scrollback:, queue_limit_bytes:, terminal_factory: nil, report: nil)
        unless scrollback.is_a?(Integer) && scrollback.between?(0, 1_000_000)
          raise ArgumentError, "invalid task scrollback limit"
        end
        unless queue_limit_bytes.is_a?(Integer) && queue_limit_bytes.between?(65_536, 268_435_456)
          raise ArgumentError, "invalid task queue limit"
        end
        @scrollback, @queue_limit_bytes = scrollback, queue_limit_bytes
        @terminal_factory = terminal_factory || ->(**options) { Tarazed::PTY.new(**options) }
        @report = report || ->(_error) {}
        @entries, @completed = [], {}
        @close_threads = {}.compare_by_identity
        @closed_outputs = {}.compare_by_identity
        @eof_outputs = {}.compare_by_identity
        @blocked_outputs = {}.compare_by_identity
        @active_index = @sequence = @poll_index = 0
      end

      def entries = @entries.dup.freeze
      def active = @entries[@active_index]
      def terminal = active&.terminal

      def run(task)
        raise Error, "task runner is closed" if @closed
        validate_task!(task)
        reap_closers
        previous = @entries.find { |entry| entry.label == task.fetch("label") }
        evicted = previous || eviction_candidate
        ensure_closer_capacity! if evicted && !@closed_outputs.key?(evicted)
        dimensions = @dimensions || [100, 12]
        terminal = @terminal_factory.call(command: task.fetch("command"), cwd: task.fetch("cwd"),
          env: task.fetch("env", {}),
          columns: dimensions.first, rows: dimensions.last, scrollback: @scrollback,
          queue_limit_bytes: @queue_limit_bytes)
        @sequence += 1
        entry = Output.new(@sequence, task.fetch("label"), terminal, task.fetch("presentation")).freeze
        if evicted
          index = @entries.index { |current| current.equal?(evicted) }
          close_later(evicted)
          @completed.delete(evicted.id)
          @eof_outputs.delete(evicted)
          @blocked_outputs.delete(evicted)
          @entries[index] = entry
          @closed_outputs.delete(evicted) unless @close_threads.key?(evicted)
          @active_index = index
        else
          @entries << entry
          @active_index = @entries.length - 1
        end
        entry
      rescue StandardError
        terminal&.close unless @entries.any? { |entry| entry.terminal.equal?(terminal) }
        raise
      end

      def activate(index)
        unless index.is_a?(Integer) && index.between?(0, @entries.length - 1)
          raise IndexError, "task output tab outside panel"
        end
        @active_index = index
        active
      end

      def remove(index = @active_index)
        entry = @entries[index]
        return unless entry

        close_later(entry)
        @entries.delete_at(index)
        @completed.delete(entry.id)
        @eof_outputs.delete(entry)
        @blocked_outputs.delete(entry)
        @closed_outputs.delete(entry) unless @close_threads.key?(entry)
        @active_index = [index, @entries.length - 1].min.clamp(0, @entries.length)
        entry
      end

      def stop(entry = active)
        return false unless entry && @entries.any? { |current| current.equal?(entry) }
        return false unless running?(entry)

        close_later(entry, interrupt: true)
        true
      end

      def running?(entry = active)
        return false unless entry && !@closed_outputs.key?(entry)
        terminal = entry.terminal
        !terminal.respond_to?(:alive?) || terminal.alive?
      rescue IOError, SystemCallError
        false
      end

      def completed
        @entries.filter_map do |entry|
          next if @completed[entry.id] || running?(entry) || !@eof_outputs.key?(entry)
          @completed[entry.id] = true
          entry
        end
      end

      def drain(max_bytes:, max_seconds: 0.004)
        raise ArgumentError, "task drain limit must be positive" unless max_bytes.is_a?(Integer) && max_bytes.positive?
        unless max_seconds.is_a?(Numeric) && max_seconds.finite? && max_seconds >= 0
          raise ArgumentError, "task drain budget must be nonnegative and finite"
        end
        reap_closers
        candidates = @entries.reject { |entry| @eof_outputs.key?(entry) }
          .select { |entry| !@closed_outputs.key?(entry) || @blocked_outputs.key?(entry) }
        return false if candidates.empty?

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + max_seconds
        remaining, changed = max_bytes, false
        order = candidates.rotate(@poll_index % candidates.length)
        @poll_index += 1
        order.each do |entry|
          break if remaining <= 0 || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          if @blocked_outputs.key?(entry)
            ready = !block_given? || yield(entry, "".b, remaining_time(deadline)) != false
            if ready
              @blocked_outputs.delete(entry)
              if @closed_outputs.key?(entry) && !@close_threads.key?(entry)
                @eof_outputs[entry] = true
                next
              end
            else
              next
            end
          end
          next if @closed_outputs.key?(entry)
          next if remaining_time(deadline).zero?
          current = entry.terminal
          method = current.method(:read)
          keywords = method.parameters.any? { |kind, _| [:key, :keyreq, :keyrest].include?(kind) }
          data = if keywords
            current.read(max_bytes: remaining,
              max_seconds: [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)
          else
            current.read
          end
          ready = !block_given? || yield(entry, data, remaining_time(deadline)) != false
          @blocked_outputs[entry] = true unless ready
          @eof_outputs[entry] = true if data.nil? && ready
          changed ||= !!(data && !data.empty?)
          remaining -= data.bytesize if data
        end
        changed
      end

      def pending?
        reap_closers
        @entries.any? do |entry|
          next running?(entry) if @eof_outputs.key?(entry)
          if @closed_outputs.key?(entry)
            next @blocked_outputs.key?(entry) || @close_threads.key?(entry)
          end
          @blocked_outputs.key?(entry) || !running?(entry) ||
            entry.terminal.respond_to?(:pending?) && entry.terminal.pending?
        end
      end

      def resize(columns, rows)
        dimensions = [columns.to_i, rows.to_i]
        return if dimensions.any? { |value| value <= 0 }
        @dimensions = dimensions
        @entries.each do |entry|
          next if @closed_outputs.key?(entry) || (@sizes ||= {}.compare_by_identity)[entry.terminal] == dimensions
          entry.terminal.resize(columns: dimensions.first, rows: dimensions.last)
          @sizes[entry.terminal] = dimensions
        end
      end

      def close
        return if @closed
        @closed = true
        begin
          @close_threads.each_value(&:join)
          reap_closers
          @entries.each do |entry|
            next if @closed_outputs.key?(entry)
            begin
              close_later(entry)
            rescue StandardError => error
              record_close_error(error)
              close_now(entry)
            end
          end
        ensure
          @close_threads.each_value do |thread|
            thread.join
          rescue StandardError => error
            record_close_error(error)
          end
          @entries.each { |entry| close_now(entry) unless @closed_outputs.key?(entry) }
          @entries.clear
          @close_threads.clear
          @closed_outputs.clear
          @completed.clear
          @eof_outputs.clear
          @blocked_outputs.clear
          @sizes&.clear
        end
        raise @close_error if @close_error
        nil
      end

      private

      def remaining_time(deadline)
        [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
      end

      def validate_task!(task)
        environment = task.is_a?(Hash) ? task.fetch("env", {}) : nil
        valid = task.is_a?(Hash) && task["label"].is_a?(String) && !task["label"].empty? &&
          task["command"].is_a?(Array) && !task["command"].empty? && task["command"].all? { |part| part.is_a?(String) } &&
          task["cwd"].is_a?(String) && task["presentation"].is_a?(Hash) && valid_environment?(environment)
        raise ArgumentError, "resolved task required" unless valid
      end

      def valid_environment?(environment)
        return false unless environment.is_a?(Hash) && environment.length <= 4_096

        bytes = 0
        environment.all? do |key, value|
          next false unless key.is_a?(String) && key.ascii_only? && key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          next false unless value.nil? || value.is_a?(String) && value.valid_encoding? && !value.include?("\0")

          bytes += key.bytesize + value.to_s.bytesize
          bytes <= 1_048_576
        end
      end

      def eviction_candidate
        return if @entries.length < MAX_OUTPUTS
        entry = @entries.find { |candidate| @eof_outputs.key?(candidate) && !running?(candidate) }
        raise Error, "at most #{MAX_OUTPUTS} task outputs may run at once" unless entry
        entry
      end

      def ensure_closer_capacity!
        reap_closers
        raise Error, "too many task processes are still closing" if @close_threads.length >= MAX_CLOSERS
      end

      def close_later(entry, interrupt: false)
        return @close_threads[entry] if @closed_outputs.key?(entry)
        ensure_closer_capacity!
        thread = Thread.new do
          Thread.current.report_on_exception = false
          terminal = entry.terminal
          begin
            if interrupt && (!terminal.respond_to?(:alive?) || terminal.alive?)
              terminal.signal("INT") if terminal.respond_to?(:signal)
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STOP_GRACE_SECONDS
              sleep(0.01) while terminal.respond_to?(:alive?) && terminal.alive? &&
                Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
            end
          ensure
            terminal.close if terminal.respond_to?(:close)
          end
        rescue StandardError => error
          record_close_error(error)
        end
        @close_threads[entry] = thread
        @closed_outputs[entry] = true
        thread
      end

      def close_now(entry)
        entry.terminal.close if entry.terminal.respond_to?(:close)
      rescue StandardError => error
        record_close_error(error)
      ensure
        @closed_outputs[entry] = true
      end

      def record_close_error(error)
        @close_error ||= error
        @report.call(error)
      rescue StandardError => report_error
        @close_error ||= report_error
      end

      def reap_closers
        @close_threads.delete_if do |entry, thread|
          next false unless thread.join(0)
          @sizes&.delete(entry.terminal)
          retained = @entries.any? { |current| current.equal?(entry) }
          if retained
            @eof_outputs[entry] = true unless @blocked_outputs.key?(entry)
          else
            @closed_outputs.delete(entry)
            @eof_outputs.delete(entry)
            @blocked_outputs.delete(entry)
          end
          true
        end
      end
    end
  end
end

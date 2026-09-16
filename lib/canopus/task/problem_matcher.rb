# frozen_string_literal: true

module Canopus
  module Task
    class ProblemMatcher
      MAX_LINE_BYTES = 65_536
      MAX_PENDING_BYTES = 65_536
      MAX_BUFFER_BYTES = (16 << 20) + MAX_PENDING_BYTES
      MAX_DIAGNOSTICS = 1_000
      MATCH_TIMEOUT_SECONDS = 0.002
      ANSI = /\e(?:\[[0-?]*[ -\/]*[@-~]|\][^\a]*(?:\a|\e\\))/n

      def initialize(definition, root:, &on_change)
        @definition = definition
        @root = File.realpath(root)
        patterns = definition.fetch("pattern")
        patterns = [patterns] unless patterns.is_a?(Array)
        @patterns = patterns.map { |pattern| compile(pattern.fetch("regexp")) }
        @watch = definition["background"]
        @begins = compile(@watch.fetch("begins_pattern")) if @watch
        @ends = compile(@watch.fetch("ends_pattern")) if @watch
        @active = !@watch || @watch.fetch("active_on_start", false)
        @on_change = on_change
        @pending = +"".b
        @cursor = 0
        @diagnostics = {}
        @diagnostic_count = 0
        @sequence = []
        @disabled = @discarding_line = @dirty = false
      rescue SystemCallError, TypeError => error
        raise Error, "invalid problem matcher: #{error.message}"
      end

      def diagnostics
        @snapshot ||= @diagnostics.to_h { |uri, values| [uri, values.dup.freeze] }.freeze
      end

      def pending? = !@disabled && !@pending.index("\n", @cursor).nil?

      def feed(bytes, max_seconds: 0.004)
        raise Error, "problem matcher input must be a string" unless bytes.is_a?(String)
        unless max_seconds.is_a?(Numeric) && max_seconds.finite? && max_seconds >= 0
          raise ArgumentError, "problem matcher budget must be nonnegative and finite"
        end
        return false if @disabled

        append(bytes.b)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + max_seconds
        while (newline = @pending.index("\n", @cursor))
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raw = @pending.byteslice(@cursor, newline - @cursor)
          raw = raw.delete_suffix("\r")
          consume(raw)
          break if @disabled
          @cursor = newline + 1
        end
        unless pending?
          if @pending.bytesize - @cursor > MAX_PENDING_BYTES
            @pending.clear
            @cursor = 0
            @discarding_line = true
            @sequence.clear
          else
            compact_pending
          end
        end
        notify_changed
      end

      def finish
        return diagnostics if @disabled
        return diagnostics if pending?
        raw = @pending.byteslice(@cursor..)
        consume(raw) unless raw.nil? || raw.empty? || @discarding_line
        @pending.clear
        @cursor = 0
        @sequence.clear
        @discarding_line = false
        notify_changed
        diagnostics
      end

      private

      def compile(source) = Regexp.new(source, timeout: MATCH_TIMEOUT_SECONDS)

      def append(bytes)
        if @discarding_line
          newline = bytes.index("\n")
          return if newline.nil?
          bytes = bytes.byteslice(newline + 1..) || +"".b
          @discarding_line = false
        end
        compact_pending if @cursor.positive? && @pending.bytesize + bytes.bytesize > MAX_BUFFER_BYTES
        raise Error, "problem matcher buffer exceeds 16 MiB" if @pending.bytesize + bytes.bytesize > MAX_BUFFER_BYTES
        @pending << bytes
      end

      def compact_pending
        return unless @cursor.positive?
        @pending = @pending.byteslice(@cursor..) || +"".b
        @cursor = 0
      end

      def consume(raw)
        return false if raw.bytesize > MAX_LINE_BYTES
        line = raw.gsub(ANSI, "").force_encoding(Encoding::UTF_8).scrub
        if @watch
          begins = match?(@begins, line)
          return false if @disabled
          if begins
            @active = true
            @sequence.clear
            return clear_diagnostics
          end
          ends = match?(@ends, line)
          return false if @disabled
          if ends
            @active = false
            @sequence.clear
            return false
          end
        end
        return false unless @active

        pattern_index = @sequence.length
        pattern = @patterns.fetch(pattern_index)
        match = safe_match(pattern, line)
        return false if @disabled
        unless match
          @sequence.clear
          return false if pattern_index.zero?
          pattern_index = 0
          match = safe_match(@patterns.first, line)
          return false if @disabled
        end
        return false unless match

        source_pattern = @definition.fetch("pattern")
        source_pattern = source_pattern.fetch(pattern_index) if source_pattern.is_a?(Array)
        @sequence << captures(source_pattern, match)
        return false if @sequence.length < @patterns.length

        fields = @sequence.each_with_object({}) { |values, merged| merged.merge!(values) }
        @sequence.clear
        diagnostic = build(fields)
        return false unless diagnostic
        return false if @diagnostic_count >= MAX_DIAGNOSTICS

        uri, value = diagnostic
        (@diagnostics[uri] ||= []) << value
        @diagnostic_count += 1
        changed
      end

      def match?(pattern, line) = !safe_match(pattern, line).nil?

      def safe_match(pattern, line)
        Canopus.with_regexp_timeout(pattern) { pattern.match(line) }
      rescue Regexp::TimeoutError
        disable
        nil
      end

      def disable
        @disabled = true
        @pending.clear
        @cursor = 0
        @sequence.clear
        @discarding_line = false
      end

      def captures(pattern, match)
        %w[file line column end_line end_column severity message].each_with_object({}) do |name, values|
          index = pattern[name]
          values[name] = match[index] if index && match[index]
        end
      end

      def build(fields)
        path = matched_path(fields["file"])
        line = positive_integer(fields["line"])
        return unless path && line

        column = positive_integer(fields["column"]) || 1
        end_line = positive_integer(fields["end_line"]) || line
        end_column = positive_integer(fields["end_column"]) || (end_line == line ? column + 1 : 1)
        return if end_line < line || end_line == line && end_column < column

        message = fields["message"].to_s.strip
        return if message.empty? || message.bytesize > Diagnostics::MESSAGE_LIMIT
        severity = {"error" => 1, "warning" => 2, "info" => 3, "information" => 3, "hint" => 4}
          .fetch(fields["severity"].to_s.downcase, 1)
        owner = @definition.fetch("owner")
        uri = Sadr::Protocol.uri(path)
        start_position = {"line" => line - 1, "character" => column - 1}.freeze
        end_position = {"line" => end_line - 1, "character" => end_column - 1}.freeze
        value = {"range" => {"start" => start_position, "end" => end_position}.freeze,
          "severity" => severity, "source" => owner, "message" => message.freeze}.freeze
        [uri, value]
      rescue Sadr::Error
        nil
      end

      def matched_path(value)
        return unless value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, 4_096) && !value.include?("\0")
        kind, base = @definition.fetch("file_location")
        path = kind == "relative" ? File.expand_path(value, base) : File.expand_path(value)
        return unless File.file?(path)
        path = File.realpath(path)
        return unless path == @root || path.start_with?(@root + File::SEPARATOR)
        path
      rescue SystemCallError
        nil
      end

      def positive_integer(value)
        return unless value.is_a?(String) && value.match?(/\A\d{1,10}\z/)
        number = value.to_i
        number if number.between?(1, 2_147_483_647)
      end

      def clear_diagnostics
        return false if @diagnostics.empty?
        @diagnostics.clear
        @diagnostic_count = 0
        changed
      end

      def changed
        @snapshot = nil
        @dirty = true
        true
      end

      def notify_changed
        return false unless @dirty
        @dirty = false
        @on_change&.call(self)
        true
      end
    end
  end
end

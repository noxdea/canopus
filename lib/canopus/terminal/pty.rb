# frozen_string_literal: true

require "io/console"
require "shellwords"

module Canopus
  module Terminal
    class PTY
      attr_reader :reader, :writer, :pid, :grid, :vt, :status, :initial_cwd, :command_name

      def initialize(command: ENV.fetch("SHELL", "/bin/sh"), cwd: Dir.pwd, columns: 80, rows: 24, env: {}, scrollback: 10_000,
        queue_limit_bytes: 8_388_608)
        raise ArgumentError, "terminal queue limit must be a positive integer" unless queue_limit_bytes.is_a?(Integer) && queue_limit_bytes.positive?
        @initial_cwd = File.expand_path(cwd)
        @command_name = File.basename(Array(command).first.to_s)
        @grid = Grid.new(columns: columns, rows: rows, scrollback: scrollback)
        if RUBY_PLATFORM.match?(/mswin|mingw/)
          require "zaniah/platform/windows/terminal"
          command = nil if command == "/bin/sh"
          @native = Zaniah::Platform::Windows::Terminal.new(command: command, cwd: cwd, columns: columns, rows: rows, env: env)
          @pid = @native.pid
          @vt = VT.new(grid) { |bytes| write(bytes) }
          return
        end
        require "pty"
        arguments = command.is_a?(Array) ? command : Shellwords.split(command)
        raise ArgumentError, "terminal command required" if arguments.empty?
        @reader, @writer, @pid = ::PTY.spawn({"TERM" => "xterm-256color", "COLORTERM" => "truecolor"}.merge(env), *arguments, chdir: cwd)
        @reader.binmode
        @writer.binmode
        @writer.sync = true
        @vt = VT.new(grid) { |bytes| write(bytes) }
        resize(columns: columns, rows: rows)
        @queue, @queue_bytes, @queue_limit_bytes = [], 0, queue_limit_bytes
        @queue_lock, @queue_ready = Mutex.new, ConditionVariable.new
        start_reader
      end

      # nil means EOF; an empty String means that no data was ready yet.
      def read(timeout: 0, max_bytes: 65_536, max_seconds: nil)
        raise ArgumentError, "terminal read limit must be a positive integer" unless max_bytes.is_a?(Integer) && max_bytes.positive?
        raise ArgumentError, "terminal read timeout must be nonnegative" unless timeout.is_a?(Numeric) && timeout >= 0
        raise ArgumentError, "terminal parse budget must be nonnegative" unless max_seconds.nil? || max_seconds.is_a?(Numeric) && max_seconds >= 0
        return nil if @eof
        if @native
          data = @native.read_available(limit: max_bytes)
          data ? vt.feed(data) : @eof = true
          return data
        end
        deadline = max_seconds && Process.clock_gettime(Process::CLOCK_MONOTONIC) + [max_seconds, 0].max
        data = +"".b
        loop do
          break if data.bytesize >= max_bytes || deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          piece = @queue_lock.synchronize do
            @queue_ready.wait(@queue_lock, timeout) if data.empty? && @queue.empty? && !@reader_eof && timeout.positive?
            if @queue.empty?
              @eof = true if @reader_eof
              nil
            else
              chunk = @queue.shift
              take = [max_bytes - data.bytesize, chunk.bytesize, 16_384].min
              result = chunk.byteslice(0, take)
              @queue.unshift(chunk.byteslice(take..)) if take < chunk.bytesize
              @queue_bytes -= take
              @queue_ready.broadcast
              result
            end
          end
          break unless piece
          vt.feed(piece)
          data << piece
        end
        @eof && data.empty? ? nil : data
      end

      def pending? = @native ? false : @queue_lock.synchronize { !@queue.empty? }

      def write(bytes) = @native ? @native.write(bytes) : writer.write(bytes)
      def paste(text) = write(vt.paste(text))
      def key(name, **modifiers) = write(vt.key(name, **modifiers))
      def mouse(**event) = write(vt.mouse(**event))

      def resize(columns:, rows:)
        dimensions = [columns, rows]
        return self if @pty_size == dimensions
        grid.resize(columns: columns, rows: rows) unless grid.columns == columns && grid.rows == rows
        @native ? @native.resize(columns, rows) : reader.winsize = [rows, columns]
        @pty_size = dimensions
        self
      end

      def busy?
        !@native && alive? && reader.tcgetpgrp != pid
      rescue IOError, SystemCallError, NoMethodError
        false
      end

      def foreground_process_name(now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
        return @foreground_name if @foreground_checked && now - @foreground_checked < 1
        @foreground_checked = now
        group = reader.tcgetpgrp unless @native
        value = if group && group != pid && File.file?("/proc/#{group}/comm")
          File.read("/proc/#{group}/comm")
        elsif group && group != pid
          IO.popen(["ps", "-o", "comm=", "-p", group.to_s], &:read)
        end
        @foreground_name = value&.strip&.then { |name| File.basename(name) unless name.empty? }
      rescue IOError, SystemCallError, NoMethodError
        @foreground_name = nil
      end

      def signal(name = "INT")
        return @native.write("\x03") if @native && name == "INT"
        return @native.close if @native
        Process.kill(name, -pid)
      rescue Errno::ESRCH
        false
      end

      def alive?
        return @native.alive? if @native
        return false if @status
        result = Process.waitpid2(pid, Process::WNOHANG)
        @status = result.last if result
        !result
      rescue Errno::ECHILD
        false
      end

      def close
        return @native.close if @native
        @closing = true
        @queue_lock.synchronize { @queue_ready.broadcast }
        signal("HUP") if alive?
        reader.close unless reader.closed?
        writer.close unless writer.closed?
        # A shell may trap HUP: reap it after a short grace period.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        while alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep 0.01
        end
        if alive?
          signal("KILL")
          _, @status = Process.waitpid2(pid)
        end
        @reader_thread&.join(0.2)
        @eof = true
        self
      rescue Errno::ECHILD, IOError
        self
      end

      private

      def start_reader
        @reader_thread = Thread.new do
          loop do
            data = reader.readpartial(65_536)
            @queue_lock.synchronize do
              @queue_ready.wait(@queue_lock) while !@closing && @queue_bytes >= @queue_limit_bytes
              break if @closing
              @queue << data
              @queue_bytes += data.bytesize
              @queue_ready.broadcast
            end
          end
        rescue Errno::EIO, EOFError, IOError
          nil
        ensure
          @queue_lock.synchronize do
            @reader_eof = true
            @queue_ready.broadcast
          end
        end
      end
    end
  end
end

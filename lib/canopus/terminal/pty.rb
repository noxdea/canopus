# frozen_string_literal: true

require "io/console"
require "shellwords"

module Canopus
  module Terminal
    class PTY
      attr_reader :reader, :writer, :pid, :grid, :vt, :status

      def initialize(command: ENV.fetch("SHELL", "/bin/sh"), cwd: Dir.pwd, columns: 80, rows: 24, env: {}, scrollback: 10_000)
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
      end

      # nil means EOF; an empty String means that no data was ready yet.
      def read(timeout: 0, max_bytes: 65_536)
        return nil if @eof
        if @native
          data = @native.read_available(limit: max_bytes)
          data ? vt.feed(data) : @eof = true
          return data
        end
        return "" unless IO.select([reader], nil, nil, timeout)
        data = reader.read_nonblock(max_bytes, exception: false)
        return "" if data == :wait_readable
        if data.nil?
          @eof = true
        else
          vt.feed(data)
        end
        data
      rescue Errno::EIO, EOFError
        @eof = true
        nil
      end

      def write(bytes) = @native ? @native.write(bytes) : writer.write(bytes)
      def paste(text) = write(vt.paste(text))
      def key(name, **modifiers) = write(vt.key(name, **modifiers))
      def mouse(**event) = write(vt.mouse(**event))

      def resize(columns:, rows:)
        grid.resize(columns: columns, rows: rows)
        @native ? @native.resize(columns, rows) : reader.winsize = [rows, columns]
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
        signal("HUP") if alive?
        reader.close unless reader.closed?
        writer.close unless writer.closed?
        # A shell may trap HUP: reap it after a short grace period.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
        while alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep 0.01
        end
        if alive?
          signal("KILL")
          _, @status = Process.waitpid2(pid)
        end
        @eof = true
        self
      rescue Errno::ECHILD
        self
      end
    end
  end
end

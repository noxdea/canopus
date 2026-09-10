# frozen_string_literal: true

module Canopus
  module LSP
    class Transport
      MAX_MESSAGE = 32 << 20
      attr_reader :stderr_lines, :pid
      def initialize(command, cwd: nil, env: {}, &receive)
        raise ArgumentError, "command must be a nonempty argument array" unless command.is_a?(Array) && !command.empty? && command.all? { |part| part.is_a?(String) && !part.include?("\0") }
        raise ArgumentError, "receiver required" unless receive
        options = cwd ? {chdir: cwd} : {}
        @stdin, @stdout, @stderr, @process = Open3.popen3(env, *command, **options)
        @stdin.binmode
        @stdout.binmode
        @pid, @write_lock, @stderr_lines = @process.pid, Mutex.new, []
        @reader = Thread.new do
          begin
            loop do
              message = self.class.read_message(@stdout)
              break unless message
              receive.call(message, nil)
            end
            receive.call(nil, Error.new("language server closed stdout")) unless @closing
          rescue StandardError => error
            begin
              receive.call(nil, error) unless @closing
            rescue StandardError
              nil
            end
          end
        end
        @logger = Thread.new do
          while (line = @stderr.gets("\n", 8192))
            @stderr_lines << line.scrub.byteslice(0, 8192).scrub("")
            @stderr_lines.shift if @stderr_lines.length > 200
          end
        rescue IOError
          nil
        end
      end
      def self.read_message(io)
        headers, count = {}, 0
        loop do
          line = io.gets("\r\n", 8193)
          return nil if line.nil? && headers.empty?
          raise Error, "truncated or oversized LSP header" unless line && line.end_with?("\r\n") && line.bytesize <= 8192
          break if line == "\r\n"
          count += line.bytesize
          raise Error, "oversized LSP headers" if count > 16384
          raise Error, "non-ASCII LSP header" unless line.ascii_only?
          key, value = line.strip.split(":", 2)
          raise Error, "invalid LSP header" unless value && key.match?(/\A[A-Za-z][A-Za-z0-9-]*\z/)
          key = key.downcase
          raise Error, "duplicate LSP header" if headers.key?(key)
          headers[key] = value.strip
        end
        raw_length = headers["content-length"]
        raise Error, "missing or invalid Content-Length" unless raw_length&.match?(/\A\d+\z/)
        length = Integer(raw_length, 10)
        raise Error, "oversized LSP message" unless length.between?(1, MAX_MESSAGE)
        charset = headers["content-type"]&.match(/charset\s*=\s*"?([^;"\s]+)/i)&.[](1)
        raise Error, "unsupported LSP character encoding" if charset && !%w[utf-8 utf8].include?(charset.downcase)
        body = io.read(length)
        raise Error, "truncated LSP body" unless body && body.bytesize == length
        body.force_encoding(Encoding::UTF_8)
        raise Error, "invalid LSP UTF-8 body" unless body.valid_encoding?
        validate_message(JSON.parse(body))
      rescue JSON::ParserError => error
        raise Error, "invalid LSP JSON: #{error.message.byteslice(0, 256)}"
      end
      def self.validate_message(message)
        raise Error, "invalid JSON-RPC message" unless message.is_a?(Hash) && message["jsonrpc"] == "2.0"
        if message.key?("method")
          raise Error, "invalid JSON-RPC method" unless message["method"].is_a?(String) && !message["method"].empty?
          raise Error, "invalid JSON-RPC parameters" if message.key?("params") && !message["params"].is_a?(Hash) && !message["params"].is_a?(Array)
          raise Error, "request contains a response" if message.key?("result") || message.key?("error")
        else
          raise Error, "invalid JSON-RPC response" unless message.key?("id") && (message.key?("result") ^ message.key?("error"))
          if message.key?("error")
            error = message["error"]
            raise Error, "invalid JSON-RPC error" unless error.is_a?(Hash) && error["code"].is_a?(Integer) && error["message"].is_a?(String)
          end
        end
        id = message["id"]
        raise Error, "invalid JSON-RPC id" if message.key?("id") && !id.is_a?(Integer) && !id.is_a?(String) && !(id.nil? && !message.key?("method"))
        message
      end
      def write(message)
        raise Error, "expected JSON-RPC object" unless message.is_a?(Hash)
        normalized = message.transform_keys(&:to_s)
        normalized["error"] = normalized["error"].transform_keys(&:to_s) if normalized["error"].is_a?(Hash)
        self.class.validate_message(normalized)
        body = JSON.generate(message).b
        raise Error, "oversized LSP message" unless body.bytesize.between?(1, MAX_MESSAGE)
        @write_lock.synchronize do
          @stdin.write("Content-Length: #{body.bytesize}\r\n\r\n")
          @stdin.write(body)
          @stdin.flush
        end
      rescue IOError, Errno::EPIPE => error
        raise Error, "language server write failed: #{error.message}"
      end
      def alive? = @process.alive?
      def close
        return if @closing
        @closing = true
        @stdin.close unless @stdin.closed?
        unless @process.join(1)
          Process.kill("TERM", @pid) rescue Errno::ESRCH
          unless @process.join(1)
            Process.kill("KILL", @pid) rescue Errno::ESRCH
            @process.join
          end
        end
        [@stdout, @stderr].each { |io| io.close unless io.closed? }
        [@reader, @logger].each do |thread|
          next if thread == Thread.current
          thread.kill unless thread.join(1)
        end
      end
    end
  end
end

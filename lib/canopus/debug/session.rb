# frozen_string_literal: true

require "socket"
require "tempfile"
require_relative "../error"

module Canopus
  module Debug
    class Session
      DEFAULT_TIMEOUT = 10
      CONNECT_INTERVAL = 0.05

      attr_reader :client

      def initialize(root:, configuration:, adapter:, breakpoints:, client: nil, timeout: DEFAULT_TIMEOUT)
        @root = File.realpath(root)
        @configuration = configuration
        @adapter = adapter
        @breakpoints = breakpoints
        @client = client
        @timeout = timeout
        unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
          raise ArgumentError, "debug session timeout must be positive and finite"
        end
        @handlers = {}
        @lock = Mutex.new
        @closed = false
      rescue SystemCallError, TypeError => error
        raise Error, "invalid debug session: #{error.message}"
      end

      def on(event, &handler)
        raise ArgumentError, "debug event handler required" unless handler

        @lock.synchronize { (@handlers[event.to_sym] ||= []) << handler }
        handler
      end

      def stopped_thread_id = @lock.synchronize { @stopped_thread_id }

      def stack_frames(levels: 100)
        client, thread_id = inspection_state
        client.stack_trace(thread_id, start: 0, levels: levels)
      end

      def scopes(frame_id) = inspection_client.scopes(frame_id)
      def variables(reference) = inspection_client.variables(reference)
      def evaluate(expression, frame_id:, context: "watch") = inspection_client.evaluate(expression, frame_id: frame_id, context: context)

      def start
        deadline = monotonic_time + @timeout
        initialized = Queue.new
        client = @client || build_client(deadline)
        install_client(client)
        client.on(:initialized) { initialized << true }
        client.on(:stopped) { |event| stopped(client, event) }
        client.on(:continued) { clear_stopped_thread; emit(:continued) }
        client.on(:output) { |event| emit(:output, event) }
        client.on(:terminated) { clear_stopped_thread; emit(:terminated) }
        client.on(:exited) { clear_stopped_thread; emit(:terminated) }

        capabilities = client.start(adapter_id: adapter_id, timeout: remaining(deadline))
        request = request_start(client)
        wait_for_initialized(initialized, request, deadline)
        set_breakpoints(client, capabilities, deadline)
        if capabilities["supportsConfigurationDoneRequest"]
          client.configuration_done.await(timeout: remaining(deadline))
        end
        request.await(timeout: remaining(deadline))
        self
      rescue StandardError => error
        begin
          request.await(timeout: 0) if request&.done?
        rescue StandardError => start_error
          error = start_error
        end
        begin
          close
        rescue StandardError
          nil
        end
        raise debug_error(error)
      end

      def close
        client, waiter, log = @lock.synchronize do
          next if @closed

          @closed = true
          [@client, @process, @log]
        end
        return nil unless client || waiter || log

        failure = nil
        begin
          client&.close
        rescue StandardError => error
          failure = error
        ensure
          begin
            stop_process(waiter)
          rescue StandardError => error
            failure ||= error
          ensure
            begin
              log&.close!
            rescue StandardError => error
              failure ||= error
            end
          end
        end
        raise debug_error(failure) if failure
        nil
      end

      private

      def inspection_state
        @lock.synchronize do
          raise Error, "debug session is not stopped" if @closed || !@client || !@stopped_thread_id

          [@client, @stopped_thread_id]
        end
      end

      def inspection_client = inspection_state.first

      def clear_stopped_thread = @lock.synchronize { @stopped_thread_id = nil }

      def build_client(deadline)
        command = @adapter.fetch("command")
        case @adapter.fetch("transport")
        when "stdio"
          Megrez::Session.stdio(command: command, env: debug_environment,
            cwd: @configuration["cwd"] || @root)
        when "tcp"
          build_tcp_client(command, deadline)
        else
          raise Error, "unsupported debug adapter transport"
        end
      end

      def build_tcp_client(command, deadline)
        unless File.basename(command.first) == "rdbg"
          raise Error, "tcp debug adapters currently require rdbg"
        end
        raise Error, "rdbg tcp adapters only support launch" unless @configuration["request"] == "launch"

        host, port = "127.0.0.1", available_port
        arguments = command.map { |argument| argument == "--open" ? "--open=vscode" : argument }
        arguments << "--open=vscode" unless arguments.any? { |argument| argument.start_with?("--open=") }
        arguments.concat(["--host", host, "--port", port.to_s])
        if @configuration["request"] == "launch" && @configuration["program"]
          arguments.concat(["--", @configuration.fetch("program"), *@configuration.fetch("args", [])])
        end
        log = Tempfile.new(["canopus-debug-", ".log"])
        pid = Process.spawn(debug_environment, *arguments, chdir: @configuration["cwd"] || @root,
          out: log, err: log)
        waiter = Process.detach(pid)
        rejected = @lock.synchronize do
          if @closed
            true
          else
            @log, @process = log, waiter
            false
          end
        end
        if rejected
          stop_process(waiter)
          log.close!
          raise Error, "debug session is closed"
        end
        connect_tcp(host, port, deadline)
      rescue SystemCallError => error
        log&.close! unless defined?(@log) && @log.equal?(log)
        raise Error, "debug adapter spawn failed: #{error.message}"
      end

      def connect_tcp(host, port, deadline)
        loop do
          raise Error, "debug session is closed" if closed?
          if @process&.join(0)
            raise Error, "debug adapter exited before accepting DAP#{adapter_log}"
          end
          begin
            return Megrez::Session.tcp(host: host, port: port,
              connect_timeout: [remaining(deadline), 0.2].min)
          rescue Megrez::Error
            raise if monotonic_time >= deadline

            sleep([CONNECT_INTERVAL, remaining(deadline)].min)
          end
        end
      end

      def install_client(client)
        rejected = @lock.synchronize do
          if @closed
            true
          else
            @client = client
            false
          end
        end
        if rejected
          client.close
          raise Error, "debug session is closed"
        end
      end

      def request_start(client)
        arguments = @configuration.reject { |key, _| %w[name type request].include?(key) }
        if @adapter["transport"] == "tcp" && File.basename(@adapter.fetch("command").first) == "rdbg"
          arguments = arguments.reject { |key, _| %w[program args cwd env].include?(key) }.merge("localfs" => true)
        end
        @configuration.fetch("request") == "launch" ? client.launch(arguments) : client.attach(arguments)
      end

      def wait_for_initialized(queue, request, deadline)
        loop do
          initialized = queue.pop(true)
          request.await(timeout: 0) if request.done?
          return initialized
        rescue ThreadError
          request.await(timeout: 0) if request.done?
          raise Error, "debug adapter did not initialize" if monotonic_time >= deadline
          raise Error, "debug session is closed" if closed?

          sleep([CONNECT_INTERVAL, remaining(deadline)].min)
        end
      end

      def set_breakpoints(client, capabilities, deadline)
        @breakpoints.entries.select(&:enabled).group_by(&:path).sort.each do |path, entries|
          validate_breakpoint_capabilities!(entries, capabilities)
          source = File.join(@root, path)
          values = entries.map do |entry|
            Megrez::SourceBreakpoint.new(line: entry.line, column: nil,
              condition: capabilities["supportsConditionalBreakpoints"] ? entry.condition : nil,
              hit_condition: capabilities["supportsHitConditionalBreakpoints"] ? entry.hit_condition : nil,
              log_message: capabilities["supportsLogPoints"] ? entry.log_message : nil)
          end
          client.set_breakpoints(source, values).await(timeout: remaining(deadline))
        end
      end

      def validate_breakpoint_capabilities!(entries, capabilities)
        requirements = {
          condition: "supportsConditionalBreakpoints",
          hit_condition: "supportsHitConditionalBreakpoints",
          log_message: "supportsLogPoints"
        }
        requirements.each do |field, capability|
          if !capabilities[capability] && entries.any? { |entry| !entry.public_send(field).nil? }
            raise Error, "debug adapter does not support #{field.to_s.tr('_', ' ')}"
          end
        end
      end

      def stopped(client, event)
        thread_id = event["threadId"] || event[:threadId]
        raise Error, "debug stop event has no thread" unless thread_id.is_a?(Integer) && thread_id.positive?

        generation = client.generation
        frame = client.stack_trace(thread_id, start: 0, levels: 1).await(timeout: @timeout).first
        raise Error, "debug stop event has no stack frame" unless frame
        return unless client.state == :stopped && client.generation == generation

        accepted = @lock.synchronize do
          next false if @closed || client.state != :stopped || client.generation != generation

          @stopped_thread_id = thread_id
          true
        end
        return unless accepted

        emit(:stopped, frame)
      rescue StandardError => error
        return if generation && (client.state != :stopped || client.generation != generation)

        emit(:error, debug_error(error))
      end

      def emit(event, value = nil)
        handlers = @lock.synchronize { @closed ? [] : (@handlers[event] || []).dup }
        handlers.each { |handler| handler.call(value) }
      end

      def debug_environment
        value = @configuration.fetch("env", {})
        valid = value.is_a?(Hash) && value.all? do |key, item|
          key.is_a?(String) && (item.nil? || item.is_a?(String))
        end
        raise Error, "debug environment must contain string values" unless valid

        ENV.each_key.grep(/\ABUNDLE/).to_h { |key| [key, nil] }
          .merge("RUBYOPT" => nil, "RUBYLIB" => nil)
          .merge(value)
      end

      def adapter_id
        File.basename(@adapter.fetch("command").first) == "rdbg" ? "rdbg" : @configuration.fetch("type")
      end

      def available_port
        server = TCPServer.new("127.0.0.1", 0)
        server.local_address.ip_port
      ensure
        server&.close
      end

      def stop_process(waiter)
        return unless waiter
        return if waiter.join(0)

        Process.kill(Gem.win_platform? ? "KILL" : "TERM", waiter.pid)
        return if waiter.join(1)

        return if Gem.win_platform?

        Process.kill("KILL", waiter.pid)
        waiter.join(1)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def adapter_log
        return "" unless @log

        @log.flush
        text = File.binread(@log.path, 2_048).force_encoding(Encoding::UTF_8).scrub.strip
        text.empty? ? "" : ": #{text}"
      rescue IOError, SystemCallError
        ""
      end

      def remaining(deadline)
        value = deadline - monotonic_time
        raise Megrez::Timeout, "debug session timed out" unless value.positive?

        value
      end

      def closed? = @lock.synchronize { @closed }
      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def debug_error(error)
        return error if error.is_a?(Error)

        Error.new("debug session failed: #{error.message}")
      end
    end
  end
end

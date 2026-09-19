# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

# Separate-process execution isolates crashes and accidental global state.
# Saiph adds an OS sandbox when the host backend supports the requested policy.
module Canopus
  module Plugins
    class IsolatedRuntime
      WORKER = <<~'RUBY'
    require "json"
    require "stringio"
    require "open3"
    protocol = STDOUT
    $stdout = StringIO.new
    class PluginAPI
      attr_reader :edits, :messages
      def initialize(context, permissions)
        @context, @permissions, @edits, @messages = context, permissions, [], []
      end
      def permit!(name)
        normalized = name.to_s == "process" ? "exec" : name.to_s
        raise "plugin requires #{name}" unless @permissions.include?(normalized)
      end
      def text
        permit!("read_buffer")
        @context.fetch("text") { raise @context.fetch("text_error", "buffer text is not available") }
      end
      def files
        permit!("read_project")
        @context.fetch("files")
      end
      def replace(range, text)
        permit!("edit_buffer")
        @edits << [range.begin, range.end + (range.exclude_end? ? 0 : 1), text]
      end
      def notify(message) = @messages << message.to_s
      def run(command)
        permit!("exec")
        raise "command must be an argument array" unless command.is_a?(Array) && !command.empty?
        Open3.capture3(*command, chdir: @context.fetch("root"))
      end
      def http_get(url)
        permit!("network")
        require "net/http"
        uri = URI(url)
        raise "HTTP or HTTPS URL required" unless %w[http https].include?(uri.scheme)
        body = +""
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 5) do |http|
          http.request_get(uri.request_uri) do |response|
            response.read_body do |chunk|
              raise "plugin HTTP response exceeds 1 MiB" if body.bytesize + chunk.bytesize > 1 << 20
              body << chunk
            end
          end
        end
        body
      end
    end
    class PluginDefinition
      attr_reader :actions, :panels, :languages, :servers
      def initialize
        @actions, @panels, @languages, @servers = {}, {}, {}, {}
      end
      def register_action(name, description: name, &block) = @actions[name] = [description, block]
      def register_panel(name, side: :right, &block) = @panels[name] = [side, block]
      def register_language(name, **options) = @languages[name] = options
      def configure_lsp(language, command) = @servers[language] = command
    end
    begin
      bootstrap = JSON.parse(STDIN.gets || raise("missing plugin source"))
      definition = PluginDefinition.new
      definition.instance_eval(bootstrap.fetch("source"), bootstrap.fetch("path"), 1)
      protocol.puts(JSON.generate(actions: definition.actions.transform_values(&:first), panels: definition.panels.transform_values(&:first), languages: definition.languages, servers: definition.servers))
      protocol.flush
      STDIN.each_line do |line|
        begin
          request = JSON.parse(line)
          api = PluginAPI.new(request.fetch("context"), bootstrap.fetch("permissions"))
          table = request["kind"] == "panel" ? definition.panels : definition.actions
          result = table.fetch(request.fetch("name"))[1].call(api)
          protocol.puts(JSON.generate(result: result.is_a?(String) ? result : nil, edits: api.edits, messages: api.messages))
        rescue StandardError, ScriptError => error
          protocol.puts(JSON.generate(error: "#{error.class}: #{error.message}"))
        end
        protocol.flush
        $stdout.truncate(0)
        $stdout.rewind
      end
    rescue StandardError, ScriptError => error
      protocol.puts(JSON.generate(error: "#{error.class}: #{error.message}"))
      protocol.flush
    end
  RUBY

      def initialize(workspace, source, path, permissions, timeout: 2)
        @workspace, @plugin_id = workspace, path
        @permissions, @timeout = permissions.map { |permission| permission.to_s == "process" ? "exec" : permission.to_s }.uniq, timeout
        @panel_lock = Mutex.new
        @panel_cache, @panel_refreshed, @panel_refreshing, @panel_threads = {}, {}, {}, {}
        @closed = false
        start_process
        @input.sync = true
        @output.binmode
        @pending, @lock = +"".b, Mutex.new
        @input.puts(JSON.generate(source: source, path: path, permissions: @permissions))
        manifest = response
        servers = manifest.fetch("servers")
        if !servers.empty? && !@permissions.include?("exec")
          raise Canopus::Plugins::PermissionDenied, "plugin requires process to configure language servers"
        end
        manifest.fetch("actions").each do |name, description|
          workspace.register_action(name, description: description) { invoke(:action, name) }
        end
        manifest.fetch("panels").each do |name, side|
          workspace.register_panel(name, side: side.to_sym, cache: false) { panel_element(name) }
        end
        @panel_names = manifest.fetch("panels").keys
        manifest.fetch("languages").each { |name, options| workspace.register_language(name, **options.transform_keys(&:to_sym)) }
        servers.each { |language, command| workspace.configure_plugin_language_server(@plugin_id, language, command) }
      rescue StandardError
        close
        raise
      end
      def invoke(kind, name)
        @lock.synchronize do
          raise Canopus::Error, "plugin runtime is closed" if @closed
          buffer = @workspace.editor&.buffer
          version = buffer&.version
          context = {root: @workspace.root}
          if @permissions.include?("read_buffer")
            if buffer && buffer.rope.bytesize <= Plugins::BUFFER_CONTEXT_LIMIT
              context[:text] = buffer.text
            else
              context[:text_error] = "plugin buffer text exceeds 1 MiB"
            end
          end
          context[:files] = @workspace.files if @permissions.include?("read_project")
          @input.puts(JSON.generate(kind: kind, name: name, context: context))
          result = response
          edits = result.fetch("edits")
          unless edits.empty?
            raise Canopus::Plugins::PermissionDenied, "plugin requires edit_buffer" unless @permissions.include?("edit_buffer")
            raise Canopus::Error, "buffer changed while plugin was running" unless buffer && buffer.version == version
            buffer.edit(edits.map { |first, last, text| [first...last, text] }, kind: :plugin)
          end
          @workspace.message = result.fetch("messages").last.to_s unless result.fetch("messages").empty?
          refresh_panels if kind == :action
          result["result"]
        end
      rescue IOError, Errno::EPIPE, EOFError => error
        raise Canopus::Error, "plugin process ended: #{error.message}"
      end
      def close
        threads = @panel_lock.synchronize do
          @closed = true
          @panel_threads.keys
        end
        threads.each do |thread|
          next if thread.equal?(Thread.current)
          thread.kill
          thread.join(0.2)
        end
        @input&.close unless @input&.closed?
        if @process && !@process.join(0.2)
          Process.kill("KILL", @pid) rescue Errno::ESRCH
          @process.join
        end
        @output&.close unless @output&.closed?
      end
  private
      def panel_element(name)
        request_panel_refresh(name)
        Zaniah::Text.new(@panel_lock.synchronize { @panel_cache.fetch(name, "") })
      end

      def request_panel_refresh(name)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @panel_lock.synchronize do
          return if @closed || @panel_refreshing[name]
          return if @panel_refreshed[name] && now - @panel_refreshed[name] < 0.25

          @panel_refreshing[name] = true
        end
        thread = Thread.new do
          @panel_lock.synchronize do
            if @closed
              @panel_refreshing.delete(name)
              next
            end
            @panel_threads[Thread.current] = true
          end
          begin
            result = invoke(:panel, name)
            @panel_lock.synchronize do
              @panel_cache[name] = result.to_s
              @panel_refreshed[name] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
            @workspace.window&.request_frame
          rescue StandardError => error
            @workspace.message = error.message unless @closed
          ensure
            @panel_lock.synchronize do
              @panel_refreshing.delete(name)
              @panel_threads.delete(Thread.current)
            end
          end
        end
        thread
      end

      def refresh_panels
        @panel_names&.each do |name|
          visible = %i[left right bottom].any? { |side| @workspace.panels.active(side).any? { |definition| definition.id == name } }
          request_panel_refresh(name) if visible
        end
      end

      def start_process
        command = [RbConfig.ruby, "-e", WORKER]
        mode = @workspace.settings["plugins"].fetch("sandbox", "auto")
        return start_open3(command) if mode == "off"

        start_saiph(command)
      rescue StandardError => error
        raise unless defined?(Saiph::Unsupported) && error.is_a?(Saiph::Unsupported)

        raise Canopus::Error, "plugin sandbox is required: #{error.message}" if mode == "required"

        @workspace.message = "Plugin OS sandbox disabled: #{error.message}"
        start_open3(command)
      end

      def start_open3(command)
        @input, @output, @process = Open3.popen2(*command)
        @pid = @process.pid
      end

      def start_saiph(command)
        load_saiph
        child_input, input = IO.pipe
        output, child_output = IO.pipe
        @pid = Saiph.spawn(command, policy: sandbox_policy, in: child_input, out: child_output)
        child_input.close
        child_output.close
        @input, @output = input, output
        @process = Process.detach(@pid)
      rescue Exception
        child_input&.close unless child_input&.closed?
        child_output&.close unless child_output&.closed?
        input&.close unless input&.closed?
        output&.close unless output&.closed?
        raise
      end

      def sandbox_policy
        load_saiph
        Saiph::Policy.new(
          @permissions.include?("read_project") ? [@workspace.root] : [],
          @permissions.include?("write_project") ? [@workspace.root] : [],
          @permissions.include?("network"),
          @permissions.include?("exec"),
          []
        )
      end

      def load_saiph
        return if defined?(Saiph::Policy)

        saiph_path = ENV["SAIPH_PATH"]
        saiph_root = File.expand_path("../..", __dir__)
        saiph_path ? require(File.expand_path("lib/saiph", File.expand_path(saiph_path, saiph_root))) : require("saiph")
      end

      def response
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
        loop do
          if (ending = @pending.index("\n"))
            result = JSON.parse(@pending.slice!(0, ending + 1))
            raise Canopus::Error, result["error"] if result["error"]
            return result
          end
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0 || !IO.select([@output], nil, nil, remaining)
            close
            raise Canopus::Error, "plugin exceeded #{@timeout} second response limit"
          end
          chunk = @output.read_nonblock(65_536)
          @pending << chunk
          raise Canopus::Error, "plugin response exceeds 1MB" if @pending.bytesize > 1 << 20
        end
      end
    end
  end
end

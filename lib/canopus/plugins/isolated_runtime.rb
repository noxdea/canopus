# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

# Separate-process execution isolates crashes and accidental global state.
# It is NOT an OS sandbox: Ruby plugins remain trusted executable code.
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
        raise "plugin requires #{name}" unless @permissions.include?(name)
      end
      def text
        permit!("read_buffer")
        @context.fetch("text")
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
        permit!("process")
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
        @workspace, @permissions, @timeout = workspace, permissions, timeout
        @input, @output, @process = Open3.popen2(RbConfig.ruby, "-e", WORKER)
        @input.sync = true
        @output.binmode
        @pending, @lock = +"".b, Mutex.new
        @input.puts(JSON.generate(source: source, path: path, permissions: permissions))
        manifest = response
        manifest.fetch("actions").each do |name, description|
          workspace.register_action(name, description: description) { invoke(:action, name) }
        end
        manifest.fetch("panels").each do |name, side|
          workspace.register_panel(name, side: side.to_sym) { Zaniah::Text.new(invoke(:panel, name).to_s) }
        end
        manifest.fetch("languages").each { |name, options| workspace.register_language(name, **options.transform_keys(&:to_sym)) }
        workspace.settings.merge!("language_servers" => manifest.fetch("servers"))
      rescue StandardError
        close
        raise
      end
      def invoke(kind, name)
        @lock.synchronize do
          buffer = @workspace.editor.buffer
          version = buffer.version
          context = {root: @workspace.root}
          context[:text] = buffer.text if @permissions.include?("read_buffer")
          context[:files] = @workspace.files if @permissions.include?("read_project")
          @input.puts(JSON.generate(kind: kind, name: name, context: context))
          result = response
          edits = result.fetch("edits")
          unless edits.empty?
            raise Canopus::Plugins::PermissionDenied, "plugin requires edit_buffer" unless @permissions.include?("edit_buffer")
            raise Canopus::Error, "buffer changed while plugin was running" unless buffer.version == version
            buffer.edit(edits.map { |first, last, text| [first...last, text] }, kind: :plugin)
          end
          @workspace.message = result.fetch("messages").last.to_s unless result.fetch("messages").empty?
          result["result"]
        end
      rescue IOError, Errno::EPIPE, EOFError => error
        raise Canopus::Error, "plugin process ended: #{error.message}"
      end
      def close
        @input&.close unless @input&.closed?
        if @process && !@process.join(0.2)
          Process.kill("KILL", @process.pid) rescue Errno::ESRCH
          @process.join
        end
        @output&.close unless @output&.closed?
      end
  private
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

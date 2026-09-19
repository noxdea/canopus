# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "tempfile"
require "timeout"
require "uri"

module Canopus
  module Plugins
    # Canopus vocabulary on top of the generic out-of-process host.
    class Host
      API_VERSION = 2

      attr_reader :runtime

      def initialize(workspace, sandbox: true, limits: {})
        require_gienah
        @workspace = workspace
        @sandbox = sandbox
        @runtime = Gienah::Host.new(api_version: API_VERSION, sandbox: sandbox, limits: limits)
        @surfaces = {}
        @subscriptions = {}
        @decorations = {}
        @completion_sources = {}
        @status_items = {}
        @storage_lock = Mutex.new
        @activation_threads = {}
        @subscribed_instances = {}
        @selection_subscriptions = {}
        @selection_threads = {}
        @event_lock = Mutex.new
        register_buffer_api
        register_workspace_api
        register_ui_api
        @runtime.on_contribution { |id, contributes| register_contributions(id, contributes) }
        @workspace_event_subscription = @workspace.on_plugin_event { |method, payload| handle_workspace_event(method, payload) }
        @runtime.on_error do |error, instance|
          cleanup_instance(instance.id) if instance&.state == :failed
          @workspace.message = error.message
        end
      end

      def discover(directories) = @runtime.discover(directories)
      def add(manifest) = @runtime.add(manifest)

      def activate(id, reason:)
        raise PermissionDenied, "workspace is not trusted" unless @workspace.trust.trusted?

        @runtime.activate(id, reason: reason)
      end

      def deactivate(id)
        cleanup_instance(id)
        @runtime.deactivate(id)
      end
      def instances = @runtime.instances
      def shutdown
        @activation_threads.values.each { |thread| thread.kill unless thread.equal?(Thread.current) }
        @activation_threads.clear
        @workspace_event_subscription&.detach
        @selection_threads.each_value { |thread| thread.kill unless thread.equal?(Thread.current) }
        @selection_threads.clear
        @selection_subscriptions.each_value { |_editor, subscription| subscription.detach }
        @selection_subscriptions.clear
        @subscriptions.each_value(&:detach)
        @subscriptions.clear
        @subscribed_instances.clear
        @runtime.shutdown
      end

      def status_items
        @status_items.dup
      end

      private

      def require_gienah
        path = ENV["GIENAH_PATH"]
        if path
          require File.expand_path("lib/gienah", File.expand_path(path))
        else
          require "gienah"
        end
      end

      def expose(name, capability: nil, &handler)
        @runtime.expose(name, capability: capability) { |instance, params| handler.call(instance, normalize_params(params)) }
      end

      def register_buffer_api
        expose("buffer/text", capability: "buffer.read") do |_instance, params|
          buffer = current_buffer
          range = params["range"]
          unless range
            text = buffer.text
            raise Error, "buffer text exceeds 1 MiB; request a range" if text.bytesize > Plugins::BUFFER_CONTEXT_LIMIT
            next text
          end
          first = Integer(range.fetch("start"))
          last = Integer(range.fetch("end"))
          raise ArgumentError, "invalid buffer text range" unless first >= 0 && last >= first && last <= buffer.rope.bytesize
          buffer.text.byteslice(first, last - first).to_s
        end
        expose("buffer/info", capability: "buffer.read") do |_instance, _params|
          buffer = current_buffer
          {"path" => buffer.path, "version" => buffer.version, "bytes" => buffer.rope.bytesize, "read_only" => buffer.read_only}
        end
        expose("buffer/selection", capability: "buffer.read") do |_instance, _params|
          @workspace.editor&.selections.to_a.map { |selection| {"anchor" => selection.anchor, "head" => selection.head} }
        end
        expose("buffer/edit", capability: "buffer.edit") do |_instance, params|
          buffer = current_buffer
          expected = params["version"]
          raise Error, "buffer version is required" unless expected.is_a?(Integer) && expected == buffer.version
          changes = Array(params["changes"])
          raise ArgumentError, "changes must be an Array" unless changes.all? { |change| change.is_a?(Hash) }
          edits = changes.map do |change|
            first = change.fetch("start")
            last = change.fetch("end")
            text = change.fetch("text")
            unless first.is_a?(Integer) && last.is_a?(Integer) && first >= 0 && last >= first && last <= buffer.rope.bytesize && text.is_a?(String)
              raise ArgumentError, "invalid buffer edit"
            end
            [first...last, text]
          end
          buffer.edit(edits, kind: :plugin)
          {"version" => buffer.version}
        end
        expose("buffer/subscribe", capability: "buffer.read") do |instance, params|
          buffer = current_buffer
          requested_uri = params["uri"]
          actual_uri = buffer.path && Sadr::Protocol.uri(buffer.path)
          raise ArgumentError, "buffer URI does not match the active buffer" if requested_uri && requested_uri != actual_uri
          key = [instance.id, buffer.object_id]
          @subscribed_instances[instance.id] = instance
          @subscriptions[key] ||= buffer.on_edit do
            notify_buffer_event(instance, buffer, "buffer/didChange", buffer_change_params(buffer))
          rescue StandardError
            nil
          end
          attach_selection_listener(@workspace.editor) if @workspace.editor&.buffer.equal?(buffer)
          {"version" => buffer.version}
        end
      end

      def register_workspace_api
        expose("workspace/root", capability: "workspace.read") { |_instance, _params| @workspace.root }
        expose("workspace/files", capability: "workspace.read") { |_instance, _params| @workspace.files }
        expose("workspace/open", capability: "ui.command") { |_instance, params| @workspace.open(params.fetch("path")).path }
        expose("workspace/search", capability: "workspace.read") do |_instance, params|
          query = String(params.fetch("query"))
          raise ArgumentError, "search query must not be empty" if query.empty?
          @workspace.files.filter_map do |path|
            next unless File.file?(path)
            next unless File.read(path, 1 << 20, encoding: "UTF-8").include?(query)
            path
          rescue ArgumentError, EncodingError
            nil
          end.first(1_000)
        end
        expose("workspace/notify") { |_instance, params| @workspace.notify(params.fetch("text")); nil }
        expose("storage/get") do |instance, params|
          storage_read(instance.id).fetch(String(params.fetch("key")), nil)
        end
        expose("storage/set") do |instance, params|
          key = storage_key(params.fetch("key"))
          value = params.fetch("value")
          encoded = JSON.generate(value)
          raise ArgumentError, "storage value exceeds 1 MiB" if encoded.bytesize > (1 << 20)
          storage_update(instance.id) { |values| values[key] = value }
          nil
        end
        expose("process/exec") do |instance, params|
          raise PermissionDenied, "plugin requires process.exec" unless instance.granted?("process.exec")
          command = params.fetch("command")
          raise ArgumentError, "command must be a nonempty Array" unless command.is_a?(Array) && !command.empty? && command.all? { |part| part.is_a?(String) && !part.empty? && !part.include?("\0") }
          timeout_ms = Integer(params.fetch("timeout_ms", 5_000))
          raise ArgumentError, "timeout_ms must be between 1 and 30000" unless timeout_ms.between?(1, 30_000)
          output, error, status = execute_process(command, instance, timeout_ms / 1_000.0)
          {"stdout" => output.byteslice(0, 1 << 20).to_s, "stderr" => error.byteslice(0, 1 << 20).to_s,
            "status" => status.exitstatus, "signaled" => status.signaled?}
        end
        expose("net/fetch") do |instance, params|
          uri = URI(String(params.fetch("url")))
          raise ArgumentError, "HTTP or HTTPS URL required" unless %w[http https].include?(uri.scheme) && uri.host
          raise PermissionDenied, "plugin requires net:#{uri.host}" unless instance.granted?("net:#{uri.host}")
          body = +""
          status = nil
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 5) do |http|
            http.request_get(uri.request_uri) do |response|
              status = response.code.to_i
              response.read_body do |chunk|
                raise Error, "plugin HTTP response exceeds 1 MiB" if body.bytesize + chunk.bytesize > (1 << 20)
                body << chunk
              end
            end
          end
          {"status" => status, "body" => body}
        end
        expose("ui/status", capability: "ui.statusbar") do |instance, params|
          id = String(params.fetch("id"))
          raise ArgumentError, "invalid status item id" unless id.match?(/\A[a-zA-Z0-9_-]{1,64}\z/)
          key = [instance.id, id]
          if params["remove"]
            @status_items.delete(key)
            @workspace.plugin_status_items.delete(key) if @workspace.respond_to?(:plugin_status_items)
          else
            text = String(params.fetch("text"))
            raise ArgumentError, "status item text is too long" if text.bytesize > 1_024
            @status_items[key] = {text: text, priority: Integer(params.fetch("priority", 0)), command: params["command"]}
            @workspace.plugin_status_items[key] = @status_items[key] if @workspace.respond_to?(:plugin_status_items)
          end
          @workspace.window&.request_frame
          nil
        end
        expose("ui/quick_pick", capability: "ui.command") { |_instance, params| queue_plugin_dialog(:quick_pick, params) }
        expose("ui/input", capability: "ui.command") { |_instance, params| queue_plugin_dialog(:input, params) }
        expose("ui/confirm", capability: "ui.command") { |_instance, params| queue_plugin_dialog(:confirm, params) }
        expose("lsp/configure", capability: "process.exec") do |instance, params|
          language = params.fetch("language")
          command = params.fetch("command")
          raise ArgumentError, "command must be a nonempty Array" unless command.is_a?(Array) && !command.empty? && command.all?(String)
          @workspace.configure_plugin_language_server(instance.id, language, command)
        end
        expose("language/register", capability: "language.define") do |_instance, params|
          @workspace.register_language(params.fetch("name"), extensions: Array(params.fetch("extensions")),
            lexer: params.fetch("lexer", "plaintext"), comment: params.fetch("comment", "#"), servers: Array(params.fetch("servers", [])))
          nil
        end
      end

      def register_ui_api
        expose("ui/render", capability: "ui.panel") do |instance, params|
          surface = surface_for(instance.id, params.fetch("panel"))
          surface.replace(params.fetch("tree"))
          @workspace.window&.request_frame
          nil
        end
        expose("ui/patch", capability: "ui.panel") do |instance, params|
          surface_for(instance.id, params.fetch("panel")).apply(params.fetch("patches"))
          @workspace.window&.request_frame
          nil
        end
        expose("decoration/publish", capability: "ui.decoration") do |instance, params|
          source = decoration_source(instance.id, params.fetch("source"))
          items = Array(params.fetch("items"))
          @decorations[source] = items
          @workspace.decorations.register(source) { |buffer, _rows, _context| decoration_items(items, source, buffer) }
          @workspace.decorations.invalidate(source)
          source.to_s
        end
        expose("decoration/clear", capability: "ui.decoration") do |instance, params|
          source = decoration_source(instance.id, params.fetch("source"))
          @decorations.delete(source)
          @workspace.decorations.unregister(source)
          nil
        end
        expose("completion/register", capability: "completion.provide") do |instance, params|
          source = completion_source(instance.id, params.fetch("source"))
          unless @completion_sources.key?(source)
            @completion_sources[source] = true
            @workspace.providers.register_completion(source, priority: Integer(params.fetch("priority", 0))) do |buffer, offset, context|
              response = instance.call("completion/provide", {"offset" => offset, "version" => buffer.version, "context" => context}).await(timeout: 0.2)
              Array(response).map { |item| completion_item(item, source) }
            end
          end
          source.to_s
        end
      end

      def register_contributions(id, contributes)
        Array(contributes["commands"]).each do |entry|
          next unless entry.is_a?(Hash) && entry["id"] && entry["title"]

          @workspace.register_action(entry["id"], description: entry["title"]) do
            instance = activate(id, reason: "onCommand:#{entry['id']}")
            instance&.call(entry["id"], {}).then { |_value, error| @workspace.message = error.message if error }
          end
        end
        Array(contributes["panels"]).each do |entry|
          next unless entry.is_a?(Hash) && entry["id"]

          side = entry.fetch("dock", "right").to_sym
          panel_id = entry["id"]
          title = String(entry.fetch("title", panel_id))
          @workspace.register_panel(panel_id, title: title, side: side, cache: false) { panel_element(id, panel_id) }
        end
      end

      def surface_for(plugin_id, panel_id)
        key = [plugin_id.to_s, panel_id.to_s]
        @surfaces[key] ||= Zaniah::Describe::Surface.new(
          vocabulary: Vocabulary.build,
          on_event: ->(event_id, payload) {
            instance = @runtime.instances.find { |candidate| candidate.id == plugin_id }
            instance&.notify("ui/event", {"panel" => panel_id, "id" => event_id, "payload" => payload})
          }
        )
      end

      def panel_element(plugin_id, panel_id)
        instance = @runtime.instances.find { |candidate| candidate.id == plugin_id }
        unless instance
          activate_panel_async(plugin_id, panel_id)
          return Zaniah::Div.new.flex_col.gap(1).children([Zaniah::UI::Badge.new(plugin_id.to_s), Zaniah::Text.new("Loading #{panel_id}…")])
        end
        surface = surface_for(plugin_id, panel_id)
        element = surface.element || Zaniah::Text.new("Loading #{panel_id}…")
        Zaniah::Div.new.flex_col.gap(1).children([Zaniah::UI::Badge.new(instance.manifest.name), element])
      rescue StandardError => error
        @workspace.message = error.message
        Zaniah::Text.new("Plugin unavailable")
      end

      def decoration_source(plugin_id, source)
        value = String(source)
        raise ArgumentError, "invalid decoration source" unless value.match?(/\A[a-zA-Z0-9_-]{1,64}\z/)
        "plugin_#{plugin_id}_#{value}".to_sym
      end

      def decoration_items(items, source, buffer)
        items.map do |item|
          raise ArgumentError, "decoration item must be an object" unless item.is_a?(Hash)
          range = if item["range"]
            first = Integer(item["range"].fetch("start"))
            last = Integer(item["range"].fetch("end"))
            raise ArgumentError, "decoration range is outside the buffer" unless first >= 0 && last >= first && last <= buffer.rope.bytesize
            first...last
          end
          Decoration::Item.new(item.fetch("kind").to_sym, range, item["row"], item["content"], item["style"],
            item.fetch("priority", 0), source, nil)
        end
      end

      def completion_source(plugin_id, source)
        value = String(source)
        raise ArgumentError, "invalid completion source" unless value.match?(/\A[a-zA-Z0-9_-]{1,64}\z/)
        "plugin_#{plugin_id}_#{value}".to_sym
      end

      def completion_item(item, source)
        raise ArgumentError, "completion item must be an object" unless item.is_a?(Hash)
        Provider::Completion.new(item.fetch("label"), item["insert_text"], item["kind"], item["detail"], item["documentation"],
          item["sort_text"], item["filter_text"], [], source)
      end

      def handle_workspace_event(method, payload)
        case method
        when "buffer/didOpen", "buffer/didSave"
          attach_selection_listener(@workspace.editor) if @workspace.editor&.buffer.equal?(payload)
          notify_buffer_event(nil, payload, method, buffer_event_params(payload))
        when "buffer/didClose"
          notify_buffer_event(nil, payload, method, buffer_event_params(payload))
          detach_buffer(payload)
        when "workspace/didChangeFiles", "settings/didChange"
          @subscribed_instances.values.dup.each do |instance|
            instance.notify(method, payload)
          rescue StandardError
            nil
          end
        end
      rescue StandardError => error
        @workspace.message = error.message
      end

      def buffer_event_params(buffer)
        {"uri" => buffer.path && Sadr::Protocol.uri(buffer.path), "version" => buffer.version}
      end

      def buffer_change_params(buffer)
        transaction = buffer.history.last
        changes = transaction.patch.edits.map do |edit|
          range = Sadr::Protocol.range(buffer.rope, edit.old_range)
          {"range" => {"start" => {"line" => range.start.line, "character" => range.start.character},
            "end" => {"line" => range.end.line, "character" => range.end.character}}, "text" => edit.new_text}
        end
        buffer_event_params(buffer).merge("changes" => changes)
      end

      def notify_buffer_event(instance, buffer, method, params)
        targets = if instance
          [instance]
        else
          @subscriptions.keys.filter_map { |id, object_id| @subscribed_instances[id] if object_id == buffer.object_id }
        end
        targets.uniq.each do |target|
          target.notify(method, params)
        rescue StandardError
          nil
        end
      end

      def attach_selection_listener(editor)
        return unless editor
        key = editor.object_id
        return if @selection_subscriptions.key?(key)

        subscription = editor.on_selection { queue_selection_event(editor) }
        @selection_subscriptions[key] = [editor, subscription]
      rescue StandardError
        nil
      end

      def queue_selection_event(editor)
        key = editor.object_id
        @event_lock.synchronize do
          return if @selection_threads[key]&.alive?

          thread = Thread.new do
            sleep 0.1
            selections = editor.selections.map { |selection| {"anchor" => selection.anchor, "head" => selection.head} }
            notify_buffer_event(nil, editor.buffer, "selection/didChange", buffer_event_params(editor.buffer).merge("selections" => selections))
          ensure
            @event_lock.synchronize { @selection_threads.delete(key) if @selection_threads[key].equal?(Thread.current) }
          end
          thread.report_on_exception = false
          @selection_threads[key] = thread
        end
      end

      def detach_buffer(buffer)
        @subscriptions.keys.select { |_id, object_id| object_id == buffer.object_id }.each do |key|
          @subscriptions.delete(key)&.detach
        end
        @selection_subscriptions.keys.each do |key|
          editor, subscription = @selection_subscriptions[key]
          next unless editor.buffer.equal?(buffer)

          subscription.detach
          @selection_subscriptions.delete(key)
        end
      end

      def cleanup_instance(id)
        @subscriptions.keys.select { |instance_id, _object_id| instance_id == id.to_s }.each do |key|
          @subscriptions.delete(key)&.detach
        end
        @subscribed_instances.delete(id.to_s)
      end

      def current_buffer
        @workspace.editor&.buffer || raise(Error, "no active buffer")
      end

      def normalize_params(params)
        raise ArgumentError, "params must be an object" unless params.is_a?(Hash)

        params.transform_keys(&:to_s)
      end

      def activate_panel_async(plugin_id, panel_id)
        key = [plugin_id.to_s, panel_id.to_s]
        return if @activation_threads[key]&.alive?

        @activation_threads[key] = Thread.new do
          begin
            instance = activate(plugin_id, reason: "onPanel:#{panel_id}")
            instance&.notify("ui/activate", {"panel" => panel_id})
          rescue StandardError => error
            @workspace.message = error.message
          ensure
            @activation_threads.delete(key)
            @workspace.window&.request_frame
          end
        end
        @activation_threads[key].report_on_exception = false
      end

      def queue_plugin_dialog(kind, params)
        raise ArgumentError, "dialog parameters must be an object" unless params.is_a?(Hash)
        @workspace.plugin_dialogs ||= [] if @workspace.respond_to?(:plugin_dialogs=)
        @workspace.plugin_dialogs << {kind: kind, params: params.dup.freeze}.freeze if @workspace.respond_to?(:plugin_dialogs)
        @workspace.window&.request_frame
        nil
      end

      def storage_path(plugin_id)
        File.join(@workspace.root, ".canopus", "plugin-storage", "#{Digest::SHA256.hexdigest(plugin_id.to_s)}.json")
      end

      def storage_key(value)
        key = String(value)
        raise ArgumentError, "storage key must be 1..128 bytes" unless key.bytesize.between?(1, 128) && !key.include?("\0")
        key
      end

      def storage_read(plugin_id)
        path = storage_path(plugin_id)
        value = @storage_lock.synchronize { File.file?(path) ? JSON.parse(File.read(path)) : {} }
        raise Error, "plugin storage is not an object" unless value.is_a?(Hash)
        value
      rescue JSON::ParserError => error
        raise Error, "invalid plugin storage: #{error.message}"
      end

      def storage_update(plugin_id)
        path = storage_path(plugin_id)
        @storage_lock.synchronize do
          values = File.file?(path) ? JSON.parse(File.read(path)) : {}
          raise Error, "plugin storage is not an object" unless values.is_a?(Hash)
          yield(values)
          FileUtils.mkdir_p(File.dirname(path))
          Tempfile.create([".storage-", ".json"], File.dirname(path), perm: 0o600) do |file|
            file.write(JSON.generate(values))
            file.flush
            file.fsync
            file.close
            File.chmod(0o600, file.path)
            File.rename(file.path, path)
          end
        end
      end

      def execute_process(command, instance, timeout)
        return Timeout.timeout(timeout) { Open3.capture3(*command, chdir: @workspace.root) } unless @sandbox

        load_saiph
        raise PermissionDenied, "plugin process sandbox is unavailable" unless Saiph.available?

        output_reader, output_writer = IO.pipe
        error_reader, error_writer = IO.pipe
        pid = Saiph.spawn(command, policy: process_policy(instance), chdir: @workspace.root,
          in: File::NULL, out: output_writer, err: error_writer)
        output_writer.close
        error_writer.close
        output_thread = Thread.new { read_process_output(output_reader) }
        error_thread = Thread.new { read_process_output(error_reader) }
        status = Timeout.timeout(timeout) { Process.waitpid2(pid).last }
        [output_thread.value, error_thread.value, status]
      rescue Timeout::Error
        begin
          Process.kill("TERM", pid) if pid
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.wait(pid) if pid
        rescue Errno::ECHILD
          nil
        end
        raise
      ensure
        [output_writer, error_writer, output_reader, error_reader].each { |io| io&.close unless io&.closed? }
      end

      def process_policy(instance)
        load_saiph
        reads = instance.granted?("workspace.read") ? [@workspace.root] : []
        network = instance.manifest.capabilities.any? { |capability| capability.start_with?("net:") }
        Saiph::Policy.new(reads, [], network, true, [])
      end

      def read_process_output(io)
        output = +""
        loop do
          chunk = io.readpartial(16 * 1024)
          output << chunk if output.bytesize < (1 << 20)
        end
      rescue EOFError, IOError
        output
      end

      def load_saiph
        return if defined?(Saiph::Policy)

        path = ENV["SAIPH_PATH"]
        root = File.expand_path("../..", __dir__)
        path ? require(File.expand_path("lib/saiph", File.expand_path(path, root))) : require("saiph")
      end
    end
  end
end

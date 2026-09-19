# frozen_string_literal: true

module Canopus
  module Plugins
    # Canopus vocabulary on top of the generic out-of-process host.
    class Host
      API_VERSION = 2

      attr_reader :runtime

      def initialize(workspace, sandbox: true, limits: {})
        require_gienah
        @workspace = workspace
        @runtime = Gienah::Host.new(api_version: API_VERSION, sandbox: sandbox, limits: limits)
        @surfaces = {}
        @subscriptions = {}
        @decorations = {}
        @completion_sources = {}
        register_buffer_api
        register_workspace_api
        register_ui_api
        @runtime.on_contribution { |id, contributes| register_contributions(id, contributes) }
        @runtime.on_error { |error, _instance| @workspace.message = error.message }
      end

      def discover(directories) = @runtime.discover(directories)
      def add(manifest) = @runtime.add(manifest)

      def activate(id, reason:)
        raise PermissionDenied, "workspace is not trusted" unless @workspace.trust.trusted?

        @runtime.activate(id, reason: reason)
      end

      def deactivate(id) = @runtime.deactivate(id)
      def instances = @runtime.instances
      def shutdown = @runtime.shutdown

      private

      def require_gienah
        path = ENV["GIENAH_PATH"]
        if path
          root = File.expand_path("../..", __dir__)
          require File.expand_path("lib/gienah", File.expand_path(path, root))
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
          next buffer.text unless range
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
        expose("buffer/subscribe", capability: "buffer.read") do |instance, _params|
          buffer = current_buffer
          key = [instance.id, buffer.object_id]
          @subscriptions[key] ||= buffer.on_edit do
            transaction = buffer.history.last
            changes = transaction.patch.edits.map do |edit|
              range = Sadr::Protocol.range(buffer.rope, edit.old_range)
              {"range" => {"start" => {"line" => range.start.line, "character" => range.start.character},
                "end" => {"line" => range.end.line, "character" => range.end.character}}, "text" => edit.new_text}
            end
            instance.notify("buffer/didChange", {"uri" => buffer.path && Sadr::Protocol.uri(buffer.path), "version" => buffer.version, "changes" => changes})
          rescue StandardError
            nil
          end
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
          @workspace.decorations.register(source) { |_buffer, _rows, _context| decoration_items(items, source) }
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
          @workspace.register_panel(panel_id, side: side, cache: false) { panel_element(id, panel_id) }
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
          instance = activate(plugin_id, reason: "onPanel:#{panel_id}")
          instance&.notify("ui/activate", {"panel" => panel_id})
        end
        surface = surface_for(plugin_id, panel_id)
        surface.element || Zaniah::Text.new("Loading #{panel_id}…")
      rescue StandardError => error
        @workspace.message = error.message
        Zaniah::Text.new("Plugin unavailable")
      end

      def decoration_source(plugin_id, source)
        value = String(source)
        raise ArgumentError, "invalid decoration source" unless value.match?(/\A[a-zA-Z0-9_-]{1,64}\z/)
        "plugin_#{plugin_id}_#{value}".to_sym
      end

      def decoration_items(items, source)
        items.map do |item|
          raise ArgumentError, "decoration item must be an object" unless item.is_a?(Hash)
          range = item["range"] && (Integer(item["range"]["start"])...Integer(item["range"]["end"]))
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

      def current_buffer
        @workspace.editor&.buffer || raise(Error, "no active buffer")
      end

      def normalize_params(params)
        raise ArgumentError, "params must be an object" unless params.is_a?(Hash)

        params.transform_keys(&:to_s)
      end
    end
  end
end

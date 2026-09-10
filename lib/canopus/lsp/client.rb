# frozen_string_literal: true

module Canopus
  module LSP
    class Client
      attr_reader :capabilities, :transport, :diagnostics, :state, :errors, :server_info, :position_encoding
      def initialize(command:, root: Dir.pwd, dispatch: ->(&block) { block.call }, restart: true, env: {}, initialization_options: nil, configuration: {})
        @command, @root, @dispatch, @restart = command, File.expand_path(root), dispatch, restart
        @env, @initialization_options, @configuration = env, initialization_options, configuration
        @pending, @handlers, @documents, @diagnostics, @semantic = {}, {}, {}, {}, {}
        @sequence, @lock, @state, @restarts, @epoch = 0, Mutex.new, :stopped, 0, 0
        @errors, @capabilities = [], {}
      end
      def start(timeout: 10)
        raise Error, "language server is already started" if [:starting, :running].include?(@state)
        @closing = false
        @state = :starting
        epoch = (@epoch += 1)
        @semantic.clear
        @transport = Transport.new(@command, cwd: @root, env: @env) { |message, error| receive(message, error, epoch) }
        result = request("initialize", {processId: Process.pid, rootUri: Protocol.uri(@root),
          clientInfo: {name: "Canopus", version: (defined?(Canopus::VERSION) ? Canopus::VERSION : "0.1.0")},
          workspaceFolders: [{uri: Protocol.uri(@root), name: File.basename(@root)}], initializationOptions: @initialization_options,
          capabilities: {general: {positionEncodings: ["utf-16"]},
            window: {workDoneProgress: true},
            textDocument: {synchronization: {dynamicRegistration: false, didSave: true},
              completion: {completionItem: {snippetSupport: true, documentationFormat: %w[markdown plaintext], resolveSupport: {properties: %w[documentation detail additionalTextEdits]}}},
              hover: {contentFormat: %w[markdown plaintext]},
              signatureHelp: {signatureInformation: {documentationFormat: %w[markdown plaintext], parameterInformation: {labelOffsetSupport: true}}},
              documentSymbol: {hierarchicalDocumentSymbolSupport: true},
              codeAction: {codeActionLiteralSupport: {codeActionKind: {valueSet: %w[quickfix refactor refactor.extract refactor.inline refactor.rewrite source source.organizeImports]}}, resolveSupport: {properties: ["edit"]}},
              publishDiagnostics: {relatedInformation: true, versionSupport: true},
              diagnostic: {dynamicRegistration: false, relatedDocumentSupport: false},
              inlayHint: {dynamicRegistration: false}, codeLens: {dynamicRegistration: false},
              semanticTokens: {requests: {full: {delta: true}}, tokenTypes: %w[namespace type class enum interface struct typeParameter parameter variable property enumMember event function method macro keyword modifier comment string number regexp operator decorator], tokenModifiers: %w[declaration definition readonly static deprecated abstract async modification documentation defaultLibrary], formats: ["relative"], overlappingTokenSupport: false, multilineTokenSupport: false}},
            workspace: {applyEdit: true, configuration: true, workspaceFolders: true,
              workspaceEdit: {documentChanges: true, resourceOperations: %w[create rename delete], failureHandling: "abort"}}}}).await(timeout: timeout)
        raise Error, "invalid initialize result" unless result.is_a?(Hash) && result["capabilities"].is_a?(Hash)
        @capabilities, @server_info = result["capabilities"], result["serverInfo"]
        sync = @capabilities["textDocumentSync"]
        mode = sync.is_a?(Hash) ? sync.fetch("change", 0) : sync
        raise Error, "invalid text document synchronization mode" unless mode.nil? || [0, 1, 2].include?(mode)
        @position_encoding = @capabilities.fetch("positionEncoding", "utf-16")
        raise Error, "server selected unadvertised position encoding #{@position_encoding}" unless @position_encoding == "utf-16"
        semantic = @capabilities["semanticTokensProvider"]
        raise Error, "missing semantic token legend" if semantic && (!semantic.is_a?(Hash) || !semantic["legend"].is_a?(Hash))
        Protocol.semantic_tokens([], legend: semantic["legend"]) if semantic.is_a?(Hash)
        notify("initialized", {})
        @state = :running
        self
      rescue StandardError => error
        @transport&.close if epoch
        fail_pending(error) if epoch
        @state = :failed if epoch
        raise
      end
      def request(method, params = {})
        id = @lock.synchronize { @sequence += 1 }
        future = Future.new(id, on_error: method(:report_error)) { |number| cancel(number) }
        @lock.synchronize { @pending[id] = future }
        raise Error, "language server is not connected" unless @transport&.alive?
        @transport.write(jsonrpc: "2.0", id: id, method: method.to_s, params: params)
        future
      rescue StandardError => error
        @lock.synchronize { @pending.delete(id) }
        future.fulfill(error: error)
        future
      end
      def notify(method, params = {})
        raise Error, "language server is not connected" unless @transport&.alive?
        @transport.write(jsonrpc: "2.0", method: method.to_s, params: params)
      end
      def on(method, &handler)
        raise ArgumentError, "handler required" unless handler
        @handlers[method.to_s] = handler
      end
      def supports?(capability) = !!@capabilities[capability.to_s]
      def workspace_symbols(query) = request("workspace/symbol", {query: query})
      def resolve_completion(item) = request("completionItem/resolve", item)
      def resolve_code_action(action) = request("codeAction/resolve", action)
      def resolve_code_lens(lens) = request("codeLens/resolve", lens)
      def execute_command(command, arguments: []) = request("workspace/executeCommand", {command: command, arguments: arguments})

      def open_document(buffer, language_id:)
        raise Error, "LSP document needs a path" unless buffer.path
        uri = Protocol.uri(buffer.path)
        @documents[uri]&.last&.detach
        subscription = buffer.on_edit { |patch| change_document(uri, buffer, patch) }
        @documents[uri] = [buffer, language_id, subscription]
        notify("textDocument/didOpen", {textDocument: {uri: uri, languageId: language_id, version: buffer.version, text: buffer.text}}) if open_close?
        uri
      end
      def close_document(uri)
        @documents.delete(uri)&.last&.detach
        @diagnostics.delete(uri)
        @semantic.delete(uri)
        notify("textDocument/didClose", {textDocument: {uri: uri}}) if open_close?
      end
      def save_document(uri)
        sync = @capabilities["textDocumentSync"]
        save = sync.is_a?(Hash) ? sync["save"] : sync.is_a?(Integer) && sync.positive?
        return unless save
        params = {textDocument: {uri: uri}}
        params[:text] = @documents.fetch(uri).first.text if save.is_a?(Hash) && save["includeText"]
        notify("textDocument/didSave", params)
      end
      def at(method, buffer, offset, **params)
        request("textDocument/#{method}", {textDocument: {uri: Protocol.uri(buffer.path)}, position: Protocol.position(buffer.rope, offset), **params})
      end
      %w[completion hover definition typeDefinition implementation references rename signatureHelp].each do |method|
        define_method(method) { |buffer, offset, **params| at(method, buffer, offset, **params) }
      end
      %w[documentSymbol formatting codeAction inlayHint codeLens diagnostic].each do |method|
        define_method(method) { |buffer, **params| request("textDocument/#{method}", {textDocument: {uri: Protocol.uri(buffer.path)}, **params}) }
      end
      def semantic_tokens(buffer)
        uri = Protocol.uri(buffer.path)
        version = buffer.version
        provider = @capabilities["semanticTokensProvider"]
        return [] unless provider.is_a?(Hash) && provider["full"]
        previous = @semantic[uri]
        delta = previous && previous[0] && provider["full"].is_a?(Hash) && provider["full"]["delta"]
        method = delta ? "textDocument/semanticTokens/full/delta" : "textDocument/semanticTokens/full"
        params = {textDocument: {uri: uri}}
        params[:previousResultId] = previous[0] if delta
        result = request(method, params).await
        return [] unless result && buffer.version == version
        raise Error, "invalid semantic token result" unless result.is_a?(Hash) && (!result.key?("resultId") || result["resultId"].is_a?(String))
        raise Error, "unexpected semantic token delta" if !delta && !result.key?("data")
        data = result["data"] || Protocol.semantic_delta(previous[1], result["edits"])
        tokens = Protocol.semantic_tokens(data, legend: provider["legend"])
        @semantic[uri] = [result["resultId"], data]
        tokens
      end
      def apply_text_edits(buffer, edits)
        changes = edits.map do |edit|
          raise Error, "invalid LSP text edit" unless edit.is_a?(Hash) && edit["range"].is_a?(Hash) && edit["newText"].is_a?(String) && edit["newText"].valid_encoding?
          range = edit.fetch("range")
          [Protocol.offset(buffer.rope, range.fetch("start"))...Protocol.offset(buffer.rope, range.fetch("end")), edit.fetch("newText")]
        end
        buffer.edit(changes, kind: :lsp)
      end
      def stop
        @closing = true
        begin
          request("shutdown").await(timeout: 2) if @state == :running
          notify("exit") if @transport&.alive?
        rescue Error
          nil
        ensure
          @epoch += 1
          @documents.each_value { |_, _, subscription| subscription.detach }
          @documents.clear
          @semantic.clear
          @diagnostics.clear
          @transport&.close
          fail_pending(Error.new("language server stopped"))
          @state = :stopped
        end
      end

      private
      def open_close?
        sync = @capabilities["textDocumentSync"]
        sync.is_a?(Hash) ? sync["openClose"] : sync.is_a?(Integer) && sync.positive?
      end
      def change_document(uri, buffer, patch)
        sync = @capabilities["textDocumentSync"]
        mode = sync.is_a?(Hash) ? sync["change"] : sync
        return unless [1, 2].include?(mode)
        changes = if mode == 2 && patch.is_a?(Patch)
          patch.edits.reverse.map { |edit| {range: Protocol.range(patch.before, edit.old_range), text: edit.new_text} }
        else
          [{text: buffer.text}]
        end
        notify("textDocument/didChange", {textDocument: {uri: uri, version: buffer.version}, contentChanges: changes})
      rescue Error => error
        report_error(error)
      end
      def cancel(id)
        @lock.synchronize { @pending.delete(id) }
        notify("$/cancelRequest", {id: id})
      rescue Error
        nil
      end
      def fail_pending(error)
        pending = @lock.synchronize { values = @pending.values; @pending.clear; values }
        pending.each { |future| future.fulfill(error: error) }
      end
      def report_error(error)
        bounded = Error.new("#{error.class}: #{error.message}".scrub.byteslice(0, 2048).scrub(""))
        @lock.synchronize do
          @errors << bounded
          @errors.shift if @errors.length > 200
        end
        @dispatch.call do
          begin
            @handlers["error"]&.call(bounded)
          rescue StandardError
            nil
          end
        end
      rescue StandardError
        nil
      end
      def receive(message, error, epoch = @epoch)
        return unless epoch == @epoch
        if error
          running = @state == :running
          @state = :failed
          fail_pending(Error.new(error.message))
          report_error(error)
          restart_server if running && @restart && !@closing && @restarts < 3
        elsif message.key?("id") && !message.key?("method")
          future = @lock.synchronize { @pending.delete(message["id"]) }
          future&.fulfill(message["result"], error: message["error"] && ServerError.new(message["error"]))
        elsif message["method"]
          method, params = message["method"], message.fetch("params", {})
          @dispatch.call do
            next unless epoch == @epoch && !@closing
            begin
              if method == "textDocument/publishDiagnostics"
                raise Error, "invalid diagnostics notification" unless params.is_a?(Hash) && params["uri"].is_a?(String) && params["diagnostics"].is_a?(Array)
                document = @documents[params["uri"]]
                version = params["version"]
                raise Error, "invalid diagnostic version" if !version.nil? && !version.is_a?(Integer)
                next if document && version && version < document.first.version
                @diagnostics[params["uri"]] = Protocol.diagnostics(params["diagnostics"])
              end
              known = @handlers.key?(method)
              result = @handlers[method]&.call(params)
              next unless message.key?("id")
              unless known
                known = true
                result = case method
                when "workspace/configuration"
                  params.fetch("items").map do |item|
                    section = item["section"]
                    section ? @configuration.dig(*section.split(".")) : @configuration
                  end
                when "workspace/workspaceFolders"
                  [{uri: Protocol.uri(@root), name: File.basename(@root)}]
                when "window/workDoneProgress/create", "workspace/semanticTokens/refresh", "workspace/inlayHint/refresh", "workspace/codeLens/refresh", "workspace/diagnostic/refresh"
                  @semantic.clear if method == "workspace/semanticTokens/refresh"
                  nil
                else
                  known = false
                  nil
                end
              end
              if !known
                reply(message["id"], epoch, error: {code: -32601, message: "unsupported client request #{method}"})
              elsif result.is_a?(Future)
                result.then do |value, failure|
                  failure ? reply(message["id"], epoch, error: {code: -32603, message: failure.message.byteslice(0, 2048).scrub}) : reply(message["id"], epoch, value: value)
                end
              else
                reply(message["id"], epoch, value: result)
              end
            rescue StandardError => failure
              report_error(failure)
              reply(message["id"], epoch, error: {code: -32603, message: "client request handler failed"}) if message.key?("id")
            end
          end
        end
      rescue StandardError => failure
        report_error(failure)
        reply(message["id"], epoch, error: {code: -32603, message: "client dispatch failed"}) if message&.key?("id") && message.key?("method")
      end
      def reply(id, epoch, value: nil, error: nil)
        return unless epoch == @epoch && !@closing
        response = {jsonrpc: "2.0", id: id}
        error ? response[:error] = error : response[:result] = value
        @transport.write(response)
      rescue StandardError => failure
        report_error(failure)
      end
      def restart_server
        return if @restart_thread&.alive?
        previous = @transport
        @restart_thread = Thread.new do
          previous.close
          until @closing || @restarts >= 3
            @restarts += 1
            sleep(0.2 * @restarts)
            break if @closing
            begin
              start
              @documents.values.dup.each { |buffer, language, _| open_document(buffer, language_id: language) }
              break
            rescue StandardError => failure
              report_error(failure)
            end
          end
        end
      end
    end
  end
end

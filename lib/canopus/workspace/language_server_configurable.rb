# frozen_string_literal: true

module Canopus
  module Workspace::LanguageServerConfigurable
    private

    def normalize_server_options(value)
      value = {"command" => value} if value.is_a?(Array)
      unless value.is_a?(Hash) && (value.keys - %w[command env initialization_options configuration]).empty?
        raise Error, "language server must be an argument array or command/options object"
      end
      command, env = value["command"], value.fetch("env", {})
      unless command.is_a?(Array) && !command.empty? && command.first.is_a?(String) && !command.first.empty? &&
          command.all? { |part| part.is_a?(String) && part.valid_encoding? && !part.include?("\0") }
        raise Error, "language server command must be a nonempty argument array without NUL bytes"
      end
      unless env.is_a?(Hash) && env.all? { |key, item| key.is_a?(String) && !key.empty? && !key.match?(/[=\0]/) && (item.nil? || item.is_a?(String) && !item.include?("\0")) }
        raise Error, "language server env must map names to strings or null"
      end
      configuration = value.fetch("configuration", {})
      raise Error, "language server configuration must be an object" unless configuration.is_a?(Hash)
      encoded = JSON.generate(value)
      raise Error, "language server options exceed 1 MiB" if encoded.bytesize > 1 << 20
      snapshot = JSON.parse(encoded)
      freeze_value = lambda do |item|
        item.each { |key, child| key.freeze; freeze_value.call(child) } if item.is_a?(Hash)
        item.each { |child| freeze_value.call(child) } if item.is_a?(Array)
        item.freeze
      end
      freeze_value.call(snapshot)
      {command: snapshot.fetch("command"), env: snapshot.fetch("env", {}).freeze,
        initialization_options: snapshot["initialization_options"], configuration: snapshot.fetch("configuration", {}).freeze}.freeze
    rescue JSON::GeneratorError, JSON::ParserError => error
      raise Error, "invalid language server options: #{error.message}"
    end

    def language_server_options(language)
      values = @settings.for_language(language)
      configured = values["language_servers"][language]
      if configured.nil?
        definition = @languages[language] || Language::DEFINITIONS.find { |item| item.name == language }
        configured = definition&.servers&.find { |candidate| Language.executable?(candidate.first) }
      end
      normalize_server_options(configured) unless configured.nil?
    end

    def language_server_settings_plan
      # Validate every layer before any client is stopped, including settings
      # for languages which have not opened a server yet.
      [@settings.values, *@settings["languages"].values].each do |layer|
        layer.fetch("language_servers", {}).each do |name, value|
          raise Error, "language server names must be strings" unless name.is_a?(String)
          normalize_server_options(value) unless value.nil?
        end
      end
      (@client_options || {}).keys.to_h { |language| [language, language_server_options(language)] }.freeze
    end

    def reload_language_servers(targets)
      return if @closed || targets.empty?
      return if targets.all? { |language, options| @client_options[language] == options } && !@language_reload_job&.alive?
      (@language_reload_lock ||= Mutex.new).synchronize do
        @language_reload_targets = targets
        return if @language_reload_job&.alive?
        @language_reload_job = Thread.new do
          loop do
            pending = @language_reload_lock.synchronize do
              values, @language_reload_targets = @language_reload_targets, nil
              @language_reload_job = nil unless values
              values
            end
            break unless pending
            pending.each do |language, options|
              break if @closed
              (@client_lock ||= Mutex.new).synchronize { ensure_language_server(language, options) unless @closed }
            rescue StandardError => error
              post { @message = "Language server settings: #{error.message}" }
            end
          end
        end
      end
    end

    def ensure_language_server(language, options)
      raise Error, "Workspace closed" if @closed
      @client_options ||= {}
      previous, client = @client_options[language], @clients[language]
      if client && previous && options && previous.except(:configuration) == options.except(:configuration)
        client.notify("workspace/didChangeConfiguration", {settings: options[:configuration]}) if previous[:configuration] != options[:configuration]
        @client_options[language] = options
        return client
      end
      return if !client && previous == options && options.nil?
      if client
        @clients.delete(language)
        (@retired_language_clients ||= ObjectSpace::WeakMap.new)[client] = true
        @opened_lsp_documents&.keys&.each do |key|
          next unless key.first.equal?(client)
          @opened_lsp_documents.delete(key)
          client.close_document(LSP::Protocol.uri(key.last.path)) if key.last.path
        rescue LSP::Error
          nil
        end
        client.stop
        post do
          @semantic_styles&.delete_if { |buffer, _| definition_for(buffer.path).name == language }
          @panes.flat_map(&:editors).each do |current|
            next unless current.language_document.definition.name == language
            map = current.display_map
            map.block_map.blocks.keys.each { |id| map.remove_block(id) if id.is_a?(Array) && id.first == :inlay }
          end
          self.palette = nil if @palette&.dig(:client).equal?(client)
          @hover_card = nil
          @window&.request_frame
        end
      end
      if Thread.current.equal?(@language_reload_job)
        options = @language_reload_lock.synchronize do
          @language_reload_targets&.key?(language) ? @language_reload_targets[language] : options
        end
      end
      @client_options[language] = options
      return unless options
      raise Error, "Workspace closed" if @closed
      dispatcher = ->(&block) { @window ? (@main_queue ||= Queue.new) << block : block.call }
      replacement = LSP::Client.new(**options, root: @root, dispatch: dispatcher)
      replacement.on("error") { |error| @message = error.message if @clients[language].equal?(replacement) }
      replacement.on("workspace/configuration") do |params|
        configured = @client_options.fetch(language).fetch(:configuration)
        values = @settings.for_language(language).values
        params.fetch("items").map do |item|
          section = item["section"]
          next configured unless section
          value = configured.dig(*section.split("."))
          value = values.dig(*section.split(".")) if value.nil?
          value.nil? ? {} : value
        end
      end
      replacement.on("workspace/applyEdit") do |params|
        future = LSP::Future.new(nil)
        if @closed || @retired_language_clients&.[](replacement)
          future.fulfill({"applied" => false, "failureReason" => "Language server stopped"})
        else
          confirm_workspace_edit(params.fetch("edit"), label: params.fetch("label", "Apply language server changes?"), response: future)
          @palette[:client] = replacement
        end
        future
      end
      replacement.on("textDocument/publishDiagnostics") { |_| @window&.request_frame }
      (@starting_language_clients ||= {})[language] = replacement
      begin
        replacement.start
        raise Error, "Workspace closed" if @closed
        @clients[language] = replacement
        @opened_lsp_documents ||= {}
        @buffers.values.uniq.each do |buffer|
          next unless buffer.path && !buffer.read_only && definition_for(buffer.path).name == language
          replacement.open_document(buffer, language_id: language)
          @opened_lsp_documents[[replacement, buffer]] = true
        end
        replacement
      rescue StandardError
        replacement.stop
        @clients.delete(language) if @clients[language].equal?(replacement)
        @opened_lsp_documents&.delete_if { |(owner, _), _| owner.equal?(replacement) }
        raise
      ensure
        @starting_language_clients.delete(language)
      end
    end

    def stop_language_servers
      @starting_language_clients&.values&.each(&:stop)
      (@client_lock ||= Mutex.new).synchronize do
        @clients.each_value(&:stop)
        @clients.clear
      end
      @language_reload_job&.join
    end
  end
end

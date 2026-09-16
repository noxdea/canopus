# frozen_string_literal: true

module Canopus
  module Workspace::LanguageServerConfigurable
    def language_server_states(language)
      options = server_options_list(@client_options&.[](language))
      language_client_list(language).each_with_index.map do |client, index|
        command = options.dig(index, :command) || []
        {language: language, index: index, name: File.basename(command.first.to_s), state: client.state}.freeze
      end.freeze
    end

    def show_language_server_restart
      language = editor.language_document.definition.name
      items = language_server_states(language)
      self.palette = {kind: :language_servers, query: +"", index: 0,
        matches: items.map { |item| "#{item[:name]} (#{item[:state]})" }, items: items}
      update_palette
    end

    def restart_language_server(language, index)
      (@client_lock ||= Mutex.new).synchronize do
        options = server_options_list(@client_options&.[](language) || language_server_options(language))
        clients = language_client_list(language).dup
        option = options.fetch(index)
        current = clients.fetch(index)
        replacement = start_language_client(language, option, index: index)
        replacements = clients.dup
        replacements[index] = replacement
        store_language_clients(language, replacements)
        begin
          open_language_client_documents(language, replacement)
        rescue StandardError
          store_language_clients(language, clients)
          cleanup_language_clients(language, [replacement])
          raise
        end
        retire_language_client(language, current)
        @message = "Restarted #{File.basename(option.fetch(:command).first)}"
        replacement
      end
    end

    private

    def normalize_server_options(value)
      legacy = value.is_a?(Array)
      value = {"command" => value} if legacy
      allowed = %w[command env initialization_options configuration features]
      unless value.is_a?(Hash) && (value.keys - allowed).empty?
        raise Error, "language server must be an argument array or command/options object"
      end
      command, env, features = value["command"], value.fetch("env", {}), value["features"]
      unless command.is_a?(Array) && !command.empty? && command.first.is_a?(String) && !command.first.empty? &&
          command.all? { |part| part.is_a?(String) && part.valid_encoding? && !part.include?("\0") }
        raise Error, "language server command must be a nonempty argument array without NUL bytes"
      end
      unless env.is_a?(Hash) && env.all? { |key, item| key.is_a?(String) && !key.empty? && !key.match?(/[=\0]/) && (item.nil? || item.is_a?(String) && !item.include?("\0")) }
        raise Error, "language server env must map names to strings or null"
      end
      configuration = value.fetch("configuration", {})
      raise Error, "language server configuration must be an object" unless configuration.is_a?(Hash)
      if features && (!features.is_a?(Array) || features.empty? || features.length > Workspace::LANGUAGE_SERVER_CAPABILITIES.length ||
          features.uniq.length != features.length || !features.all? { |feature| Workspace::LANGUAGE_SERVER_CAPABILITIES.key?(feature) })
        raise Error, "language server features must be unique supported feature names"
      end
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
        initialization_options: snapshot["initialization_options"], configuration: snapshot.fetch("configuration", {}).freeze,
        features: snapshot["features"], legacy: legacy}.freeze
    rescue JSON::GeneratorError, JSON::ParserError, JSON::NestingError => error
      raise Error, "invalid language server options: #{error.message}"
    end

    def normalize_server_configuration(value)
      if value.is_a?(Array) && value.any? { |item| item.is_a?(Hash) }
        unless value.length.between?(1, 16) && value.all? { |item| item.is_a?(Hash) }
          raise Error, "language server list must contain 1 to 16 option objects"
        end
        return value.map { |item| normalize_server_options(item) }.freeze
      end
      normalize_server_options(value)
    end

    def server_options_list(options) = options.nil? ? [] : options.is_a?(Array) ? options : [options]

    def language_client_list(language)
      return @language_clients[language].compact if @language_clients&.key?(language)
      client = @clients[language]
      client ? [client] : []
    end

    def language_client_active?(client)
      @language_clients ? @language_clients.values.any? { |clients| clients.include?(client) } : @clients.value?(client)
    end

    def language_server_feature?(option, client, feature)
      return true unless option
      return option[:features].include?(feature) if option[:features]
      return true if option[:legacy]

      capability = Workspace::LANGUAGE_SERVER_CAPABILITIES.fetch(feature)
      capability.nil? || !!client.capabilities[capability]
    end

    def language_server_option(language, client)
      index = language_client_list(language).index(client)
      index && server_options_list(@client_options&.[](language))[index]
    end

    def store_language_clients(language, clients)
      @language_clients ||= {}
      if clients.empty?
        @language_clients.delete(language)
        @clients.delete(language)
      else
        @language_clients[language] = clients.freeze
        @clients[language] = clients.first
      end
    end

    def language_server_options(language)
      values = @settings.for_language(language)
      configured = values["language_servers"][language]
      if configured.nil?
        definition = @languages[language] || Language::DEFINITIONS.find { |item| item.name == language }
        configured = definition&.servers&.find { |candidate| Language.executable?(candidate.first) }
      end
      normalize_server_configuration(configured) unless configured.nil?
    end

    def language_server_settings_plan
      [@settings.values, *@settings["languages"].values].each do |layer|
        layer.fetch("language_servers", {}).each do |name, value|
          raise Error, "language server names must be strings" unless name.is_a?(String)
          normalize_server_configuration(value) unless value.nil?
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

    def ensure_language_server(language, options, timeout: nil)
      raise Error, "Workspace closed" if @closed
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout if timeout
      @client_options ||= {}
      previous = server_options_list(@client_options[language])
      requested = server_options_list(options)
      clients = language_client_list(language)
      reusable = clients.length == requested.length && previous.length == requested.length &&
        requested.each_index.all? do |index|
          previous[index].except(:configuration, :features, :legacy) == requested[index].except(:configuration, :features, :legacy)
        end
      if reusable
        changed_features = requested.each_index.select do |index|
          previous[index].values_at(:features, :legacy) != requested[index].values_at(:features, :legacy)
        end
        requested.each_index do |index|
          clients[index].did_change_configuration(requested[index][:configuration]) if previous[index][:configuration] != requested[index][:configuration]
        end
        @client_options[language] = options
        store_language_clients(language, clients)
        changed_features.each do |index|
          clear_diagnostics = language_server_feature?(previous[index], clients[index], "diagnostics") &&
            !language_server_feature?(requested[index], clients[index], "diagnostics")
          invalidate_language_client_features(language, clients[index], clear_diagnostics: clear_diagnostics)
        end
        return @clients[language]
      end
      return if clients.empty? && @client_options[language] == options && options.nil?

      store_language_clients(language, [])
      retire_language_clients(language, clients)
      if Thread.current.equal?(@language_reload_job)
        options = @language_reload_lock.synchronize do
          @language_reload_targets&.key?(language) ? @language_reload_targets[language] : options
        end
        requested = server_options_list(options)
      end
      replacements = []
      begin
        requested.each_with_index do |option, index|
          remaining = deadline && deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Sadr::Timeout, "language server startup timed out" if remaining && remaining <= 0
          replacements << start_language_client(language, option, index: index, timeout: remaining)
        end
        @client_options[language] = options
        store_language_clients(language, replacements)
        replacements.each { |client| open_language_client_documents(language, client) }
      rescue StandardError
        store_language_clients(language, [])
        cleanup_language_clients(language, replacements)
        raise
      end
      replacements.first
    end

    def retire_language_clients(language, clients)
      failure = nil
      clients.each do |client|
        retire_language_client(language, client)
      rescue StandardError => error
        failure ||= error
      end
      raise failure if failure
    end

    def cleanup_language_clients(language, clients)
      clients.each do |client|
        retire_language_client(language, client)
      rescue StandardError
        begin
          stop_language_client(client)
        rescue StandardError
          nil
        end
      end
    end

    def retire_language_client(language, client)
      retiring_language_clients[client] = true
      invalidate_language_client_features(language, client)
      (@retired_language_clients ||= ObjectSpace::WeakMap.new)[client] = true
      @opened_lsp_documents&.keys&.each do |owner, buffer|
        next unless owner.equal?(client)
        close_language_document(client, buffer) if buffer.path
      rescue Sadr::Error
        forget_language_document(client, buffer)
      end
      stop_language_client(client)
      @window&.request_frame
    end

    def retiring_language_clients
      @retiring_language_clients ||= {}.compare_by_identity
    end

    def stop_language_client(client)
      retiring_language_clients[client] = true
      client.stop
      retiring_language_clients.delete(client)
    end

    def invalidate_language_client_features(language, client, clear_diagnostics: false)
      invalidate_document_highlights(client: client)
      invalidate_document_links(client: client)
      invalidate_folding_ranges(client: client)
      invalidate_selection_ranges(client: client)
      invalidate_hierarchy(client: client)
      invalidate_prepare_rename(client: client)
      invalidate_linked_editing_ranges(client: client)
      invalidate_inlay_hints(client: client)
      invalidate_code_lenses(client: client)
      invalidate_sticky_symbols(client: client)
      clear_language_client_diagnostics(client) if clear_diagnostics
      @completion_generation = @completion_generation.to_i + 1
      @semantic_styles&.delete_if { |buffer, _| definition_for(buffer.path).name == language }
      self.palette = nil if %i[completion locations symbols code_actions].include?(@palette&.dig(:kind)) ||
        @palette&.dig(:client).equal?(client) || @palette&.dig(:item_clients)&.include?(client)
      @hover_card = nil
      @window&.request_frame
    end

    def start_language_client(language, options, index:, timeout: nil)
      raise Error, "Workspace closed" if @closed
      dispatcher = ->(&block) { @window ? (@main_queue ||= Queue.new) << block : block.call }
      replacement = Sadr::Client.new(**options.except(:features, :legacy), root: @root, dispatch: dispatcher)
      replacement.on("error") { |error| @message = error.message if language_client_active?(replacement) }
      replacement.on("workspace/configuration") do |params|
        current = language_server_option(language, replacement)
        configured = (current || options).fetch(:configuration)
        values = @settings.for_language(language).values
        params.fetch("items").map do |item|
          section = item["section"]
          next configured unless section
          value = configured.dig(*section.split("."))
          value = values.dig(*section.split(".")) if value.nil?
          value.nil? ? {} : value
        end
      end
      replacement.on("workspace/applyEdit") { |params| handle_language_workspace_edit(replacement, params) }
      replacement.on("textDocument/publishDiagnostics") { |params| accept_diagnostic_notification(replacement, params) }
      replacement.on("workspace/inlayHint/refresh") { invalidate_inlay_hints(client: replacement) }
      replacement.on("workspace/codeLens/refresh") { invalidate_code_lenses(client: replacement) }
      key = [language, index]
      (@starting_language_clients ||= {})[key] = replacement
      begin
        timeout ? replacement.start(timeout: timeout) : replacement.start
        raise Error, "Workspace closed" if @closed
        replacement
      rescue StandardError => error
        begin
          stop_language_client(replacement)
        rescue StandardError
          nil
        end
        @opened_lsp_documents&.keys&.each do |owner, buffer|
          forget_language_document(owner, buffer) if owner.equal?(replacement)
        end
        raise error
      ensure
        @starting_language_clients.delete(key)
      end
    end

    def open_language_client_documents(language, client)
      @opened_lsp_documents ||= {}
      @buffers.values.uniq.each do |buffer|
        next unless buffer.path && !buffer.read_only && definition_for(buffer.path).name == language
        open_language_document(client, buffer, language) unless @opened_lsp_documents[[client, buffer]]
      end
      client
    end

    def handle_language_workspace_edit(client, params)
      future = Sadr::Future.new(nil)
      if @closed || @retired_language_clients&.[](client)
        future.fulfill({"applied" => false, "failureReason" => "Language server stopped"})
      elsif @save_action_clients&.key?(client)
        begin
          edit = params.fetch("edit")
          raise Error, "save-time code actions cannot change workspace resources" if resource_workspace_edit?(edit)
          result = apply_workspace_edit(edit)
          (@save_action_errors ||= {})[client] = result["failureReason"].to_s unless result["applied"]
          future.fulfill(result)
        rescue StandardError => error
          (@save_action_errors ||= {})[client] = error.message
          future.fulfill({"applied" => false, "failureReason" => error.message})
        end
      else
        confirm_workspace_edit(params.fetch("edit"), label: params.fetch("label", "Apply language server changes?"), response: future)
        @palette[:client] = client
      end
      future
    end

    def stop_language_servers
      starting = @starting_language_clients&.values&.uniq || []
      starting.each do |client|
        stop_language_client(client)
      rescue StandardError
        nil
      end
      resyncs = @language_document_resyncs&.values || []
      (@client_lock ||= Mutex.new).synchronize do
        @language_document_subscriptions&.each_value(&:detach)
        @language_document_subscriptions&.clear
        @opened_lsp_documents&.clear
        active = @language_clients ? @language_clients.values.flatten : @clients.values
        clients = [*active, *retiring_language_clients.keys].compact.uniq
        clients.each do |client|
          stop_language_client(client)
        rescue StandardError
          nil
        end
        @language_clients&.clear
        @clients.clear
      end
      resyncs.each { |thread| thread.join unless thread.equal?(Thread.current) }
      @language_document_resyncs&.clear
      @language_reload_job&.join
    end
  end
end

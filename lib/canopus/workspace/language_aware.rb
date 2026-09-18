# frozen_string_literal: true

module Canopus
  module Workspace::LanguageAware
    DIAGNOSTIC_SEVERITIES = {"error" => 1, "warning" => 2, "information" => 3, "hint" => 4}.freeze
    DIAGNOSTIC_COLORS = {1 => :"diagnostic.error", 2 => :"diagnostic.warning",
      3 => :"diagnostic.information", 4 => :"diagnostic.hint"}.freeze
    CODE_LENS_REQUEST_LIMIT = 64
    DOCUMENT_HIGHLIGHT_LIMIT = 10_000
    DOCUMENT_HIGHLIGHT_REQUEST_LIMIT = 64
    DOCUMENT_LINK_LIMIT = 10_000
    DOCUMENT_LINK_REQUEST_LIMIT = 64
    DOCUMENT_LINK_RESOLVE_LIMIT = 32
    DOCUMENT_LINK_URI_LIMIT = 16_384
    DOCUMENT_LINK_TEXT_LIMIT = 4_096
    FOLDING_RANGE_LIMIT = 10_000
    FOLDING_RANGE_REQUEST_LIMIT = 64
    SELECTION_RANGE_LIMIT = 10_000
    SELECTION_RANGE_POSITION_LIMIT = 256
    SELECTION_RANGE_DEPTH_LIMIT = 256
    SELECTION_RANGE_REQUEST_LIMIT = 64
    PREPARE_RENAME_REQUEST_LIMIT = 1
    RENAME_VALUE_LIMIT = 4096
    LINKED_EDITING_RANGE_LIMIT = 256
    LINKED_EDITING_REQUEST_LIMIT = 1
    LINKED_EDITING_PATTERN_LIMIT = 4_096
    DOCUMENT_HIGHLIGHT_STYLES = {
      1 => {color: :selection}.freeze,
      2 => {color: :accent, underline: true, thickness: 2}.freeze,
      3 => {color: :muted, underline: true}.freeze
    }.freeze
    DOCUMENT_LINK_STYLE = {color: :accent, underline: true}.freeze
    CODE_LENS_RESOLVE_LIMIT = 32
    INDENT_GUIDE_LIMIT = 4096
    STICKY_SYMBOL_LIMIT = 10_000
    STICKY_DEPTH_LIMIT = 64
    STICKY_REQUEST_LIMIT = 16
    WORKSPACE_SYMBOL_LIMIT = 10_000
    WORKSPACE_SYMBOL_QUERY_LIMIT = 256
    WORKSPACE_SYMBOL_TIMEOUT = 10
    WORKSPACE_SYMBOL_LABEL_BYTES = 512
    WORKSPACE_SYMBOL_PREVIEW_BYTES = 512
    WORKSPACE_SYMBOL_UTF16_CHUNK_BYTES = 64 * 1024
    BREADCRUMB_CONTAINER_KINDS = [2, 3, 4, 5, 10, 11, 23].freeze
    BREADCRUMB_CALLABLE_KINDS = [6, 9, 12].freeze

    attr_reader :hover_card, :hover_markup, :semantic_styles
    def dismiss_hover = @hover_card = nil
    def close_language_documents(buffer = nil)
      invalidate_hierarchy(buffer)
      @opened_lsp_documents&.keys&.each do |key|
        client, document = key
        next if buffer && !document.equal?(buffer)
        begin
          close_language_document(client, document) if document.path
        rescue StandardError => error
          forget_language_document(client, document)
          self.message = "Language server close failed: #{error.message}"
        end
      end
    end
    def semantic_spans_for(buffer, row)
      saved = @semantic_styles && @semantic_styles[buffer]
      return [] unless saved && saved.first == buffer.version
      base = buffer.rope.line_start(row)
      map = {"class" => "Name.Class", "type" => "Name.Class", "function" => "Name.Function", "method" => "Name.Function",
        "keyword" => "Keyword", "comment" => "Comment", "string" => "Literal.String", "number" => "Literal.Number"}
      saved.last.filter_map do |token|
        next unless token[:line] == row
        first = buffer.rope.offset_at_utf16_point(Denebola::Point.new(row, token[:character]))
        last = buffer.rope.offset_at_utf16_point(Denebola::Point.new(row, token[:character] + token[:length]))
        [first - base, last - base, @theme.token_color(map.fetch(token[:name], "Name"))]
      end
    end

    def post(&block)
      @main_queue << block
      @window&.request_frame
    end
    def language_clients(buffer = editor.buffer, feature: nil, timeout: nil)
      raise Error, "language servers are disabled for large read-only documents" if buffer.read_only
      language = definition_for(buffer.path)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout if timeout
      (@client_lock ||= Mutex.new).synchronize do
        options = language_server_options(language.name)
        raise Error, "No language server configured for #{language.name}" unless options
        remaining = deadline && deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Sadr::Timeout, "language server startup timed out" if remaining && remaining <= 0
        ensure_language_server(language.name, options, timeout: remaining)
        clients = language_client_list(language.name)
        @opened_lsp_documents ||= {}
        clients.each do |client|
          open_language_document(client, buffer, language.name) unless @opened_lsp_documents[[client, buffer]]
        end
        route_language_clients(language.name, clients, feature)
      end
    end

    def language_client(buffer = editor.buffer, feature: nil, timeout: nil)
      client = language_clients(buffer, feature: feature, timeout: timeout).first
      raise Error, "No language server supports #{feature}" if !client && feature
      client || raise(Error, "No language server configured for #{definition_for(buffer.path).name}")
    end
    def language_request(kind, **options)
      return request_workspace_symbols(options.fetch(:query, "")) if kind == :workspace_symbols

      current, buffer, offset = editor, editor.buffer, editor.primary.head
      if kind == :inlayHint
        requested = request_visible_inlay_hints(current)
        @message = "#{kind}…" if requested
        return requested
      end
      return request_completions(current, buffer, offset) if kind == :completion

      version = buffer.version
      (@language_jobs ||= []) << Thread.new do
        begin
          feature = language_request_feature(kind)
          language_name = definition_for(buffer.path).name
          aggregate = %i[codeAction diagnostic].include?(kind)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10 if aggregate
          clients = language_clients(buffer, feature: feature,
            timeout: deadline && deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
          uri = Sadr::Protocol.uri(buffer.path)
          position = Sadr::Protocol.position(buffer.rope, offset)
          raise Error, "No language server supports #{feature}" if clients.empty?
          if kind == :codeAction
            pending = clients.map do |owner|
              [owner, owner.code_action(uri, Sadr::Protocol.range(buffer.rope, current.primary.range),
                {diagnostics: diagnostics_for(buffer)}), nil]
            rescue StandardError => error
              [owner, nil, error]
            end
            pairs, failures, successes = [], [], 0
            pending.each do |owner, future, failure|
              if failure
                failures << failure
                next
              end
              begin
                result = language_request_await(future, deadline)
                successes += 1
                pairs.concat(Array(result).map { |item| [item, owner] })
              rescue StandardError => error
                failures << error
              end
            end
            raise failures.first if successes.zero? && !failures.empty?
            pairs = deduplicate_client_items(pairs)
            client, result, item_clients = clients.first, pairs.map(&:first), pairs.map(&:last)
          elsif kind == :diagnostic
            pending = clients.map do |owner|
              [owner, owner.diagnostic(uri), nil]
            rescue StandardError => error
              [owner, nil, error]
            end
            failures, successes = [], 0
            results = pending.filter_map do |owner, future, failure|
              if failure
                failures << failure
                next
              end
              begin
                value = language_request_await(future, deadline)
                successes += 1
                [owner, value]
              rescue StandardError => error
                failures << error
                nil
              end
            end
            raise failures.first if successes.zero? && !failures.empty?
            client, result = clients.first, results
          else
            client = clients.first
            result = case kind
            when :hover, :definition, :typeDefinition, :implementation, :signatureHelp
              method = {typeDefinition: :type_definition, signatureHelp: :signature_help}.fetch(kind, kind)
              client.public_send(method, uri, position).await(timeout: 10)
            when :references then client.references(uri, position, include_declaration: true).await(timeout: 10)
            when :rename then client.rename(uri, position, options.fetch(:name)).await(timeout: 10)
            when :formatting then client.formatting(uri, {tabSize: current.tab_size, insertSpaces: !current.use_tabs}).await(timeout: 10)
            when :documentSymbol then client.document_symbol(uri).await(timeout: 10)
            when :codeLens then client.code_lens(uri).await(timeout: 10)
            when :semantic_tokens then client.semantic_tokens(uri, version: buffer.version)
            when :workspace_symbols then client.workspace_symbols(options.fetch(:query, "")).await(timeout: 10)
            else raise Error, "unknown language request #{kind}"
            end
          end
          post do
            routed = route_language_clients(language_name, language_client_list(language_name), feature)
            if %i[codeAction diagnostic].include?(kind)
              next unless clients == routed
            else
              next unless routed.first.equal?(client)
            end
            next unless @panes.any? { |pane| pane.editors.include?(current) }
            if buffer.version == version
              if kind == :diagnostic
                result.each { |owner, value| display_language_result(kind, value, owner, current) }
              else
                display_language_result(kind, result, client, current, item_clients: item_clients)
              end
            else
              @message = "Document changed; request #{kind} again"
            end
          end
        rescue StandardError => error
          post { @message = error.message unless client && @retired_language_clients&.[](client) }
        ensure
          cancel_language_requests(pending)
        end
      end
      @language_jobs.reject! { |thread| !thread.alive? }
      @message = "#{kind}…"
    end

    def language_request_feature(kind)
      {diagnostic: "diagnostics", semantic_tokens: "semanticTokens", workspace_symbols: "workspaceSymbol"}.fetch(kind, kind.to_s)
    end

    def route_language_clients(language, clients, feature)
      return clients if feature.nil?
      feature = feature.to_s
      options = server_options_list(@client_options&.[](language))
      clients.each_with_index.filter_map do |client, index|
        client if language_server_feature?(options[index], client, feature)
      end
    end

    def language_request_await(future, deadline)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Sadr::Timeout, "language server request timed out" if remaining <= 0
      future.await(timeout: remaining)
    end

    def cancel_language_requests(pending)
      Array(pending).each do |_client, future, _failure|
        future.cancel if future&.respond_to?(:cancel) && (!future.respond_to?(:done?) || !future.done?)
      end
    end

    def deduplicate_client_items(pairs)
      seen = {}
      pairs.each_with_object([]) do |pair, values|
        item = pair.first
        next if seen.key?(item)
        seen[item] = true
        values << pair
      end
    end

    def active_language_client(language, feature)
      route_language_clients(language, language_client_list(language), feature).first
    end
    private :language_request_feature, :route_language_clients, :active_language_client,
      :language_request_await, :cancel_language_requests, :deduplicate_client_items

    def request_workspace_symbols(query)
      valid = query.is_a?(String) && query.valid_encoding? && query.bytesize.between?(1, WORKSPACE_SYMBOL_QUERY_LIMIT) &&
        !query.match?(/[\0\r\n]/) && !query.strip.empty?
      raise Error, "workspace symbol query must be 1 to #{WORKSPACE_SYMBOL_QUERY_LIMIT} bytes" unless valid

      cancel_workspace_symbol_search
      generation = @workspace_symbol_generation = @workspace_symbol_generation.to_i + 1
      query = query.dup.freeze
      request = {generation: generation, futures: [], clients: []}
      (@workspace_symbol_lock ||= Mutex.new).synchronize { @workspace_symbol_request = request }
      empty = [].freeze
      self.palette = {kind: :workspace_symbol_results, query: +"", index: 0, matches: empty, items: empty,
        all_matches: empty, indices: empty, workspace_symbol_groups: {}.freeze,
        workspace_symbol_index: Spica::Index.new(empty, tie_break: :index), workspace_symbol_generation: generation}
      job = Thread.new do
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WORKSPACE_SYMBOL_TIMEOUT
        clients = workspace_symbol_clients
        (@workspace_symbol_lock ||= Mutex.new).synchronize do
          request[:clients] = clients if @workspace_symbol_request.equal?(request)
        end
        pending = clients.filter_map do |client|
          next unless workspace_symbol_request_current?(request)
          entry = begin
            [client, client.workspace_symbols(query), nil]
          rescue StandardError => error
            [client, nil, error]
          end
          tracked = (@workspace_symbol_lock ||= Mutex.new).synchronize do
            if @workspace_symbol_request.equal?(request)
              request[:futures] << entry
              true
            end
          end
          cancel_language_requests([entry]) unless tracked
          entry if tracked
        end
        symbols, seen, successes = [], {}, 0
        pending.each do |client, future, failure|
          next if failure || !workspace_symbol_request_current?(request)
          begin
            response = language_request_await(future, deadline)
            next if client.respond_to?(:running?) && !client.running?
            values = normalize_workspace_symbols(response)
            successes += 1
            values.each do |symbol|
              break if symbols.length >= WORKSPACE_SYMBOL_LIMIT
              next if seen.key?(symbol)
              seen[symbol] = true
              symbols << symbol
            end
          rescue StandardError
            nil
          end
        end
        if successes.zero? && workspace_symbol_request_current?(request)
          fallback_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WORKSPACE_SYMBOL_TIMEOUT
          symbols = workspace_symbol_fallback(query, generation, fallback_deadline)
        end
        next unless workspace_symbol_request_current?(request)
        symbols = deduplicate_workspace_symbols(symbols).first(WORKSPACE_SYMBOL_LIMIT).freeze
        prepared = prepare_workspace_symbol_palette(symbols, generation)
        post do
          install_workspace_symbol_palette(request, prepared)
        end
      rescue StandardError => error
        post { @message = error.message if workspace_symbol_request_current?(request) }
      ensure
        cancel_language_requests(pending)
        (@workspace_symbol_lock ||= Mutex.new).synchronize do
          request[:futures].clear if @workspace_symbol_request.equal?(request)
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      @message = "Searching workspace symbols…"
      job
    end

    def cancel_workspace_symbol_search
      request = futures = nil
      (@workspace_symbol_lock ||= Mutex.new).synchronize do
        request = @workspace_symbol_request
        if request
          @workspace_symbol_request = nil
          @workspace_symbol_generation = @workspace_symbol_generation.to_i + 1
          futures = request[:futures].dup
          request[:futures].clear
        end
      end
      cancel_language_requests(futures) if request
      nil
    end

    def workspace_symbol_clients
      (@client_lock ||= Mutex.new).synchronize do
        configured = if @language_clients&.any?
          @language_clients
        else
          @clients.to_h { |language, client| [language, [client]] }
        end
        configured.flat_map do |language, clients|
          route_language_clients(language, clients, "workspaceSymbol")
        end.select { |client| !client.respond_to?(:running?) || client.running? }.uniq
      end
    end

    def normalize_workspace_symbols(value)
      return [] if value.nil?
      raise Error, "invalid workspace symbol response" unless value.is_a?(Array)
      raise Error, "too many workspace symbols" if value.length > WORKSPACE_SYMBOL_LIMIT

      value.filter_map do |symbol|
        raise Error, "invalid workspace symbol" unless symbol.is_a?(Hash)
        name, kind, container = symbol.values_at("name", "kind", "containerName")
        valid_name = name.is_a?(String) && name.valid_encoding? && name.bytesize.between?(1, 4_096)
        valid_container = container.nil? || container.is_a?(String) && container.valid_encoding? && container.bytesize <= 4_096
        raise Error, "invalid workspace symbol" unless valid_name && kind.is_a?(Integer) && kind.between?(1, 26) && valid_container

        location = symbol["location"]
        next unless location.is_a?(Hash) && location["range"]
        uri = location["uri"]
        Sadr::Protocol.path(uri)
        range = Sadr::Protocol.range_value(location["range"])
        normalized = {"name" => name.dup.freeze, "kind" => kind,
          "location" => {"uri" => uri.dup.freeze, "range" => {
            "start" => {"line" => range.start.line, "character" => range.start.character}.freeze,
            "end" => {"line" => range.end.line, "character" => range.end.character}.freeze
          }.freeze}.freeze}
        normalized["containerName"] = container.dup.freeze if container
        normalized.freeze
      rescue Sadr::Error, KeyError, TypeError
        nil
      end
    end

    def deduplicate_workspace_symbols(symbols)
      seen = {}
      symbols.each_with_object([]) do |symbol, values|
        next if seen.key?(symbol)
        seen[symbol] = true
        values << symbol
      end
    end

    def workspace_symbol_cancelled?(generation, deadline)
      @closed || generation != @workspace_symbol_generation ||
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    end

    def workspace_symbol_request_current?(request)
      return false if @closed || request[:generation] != @workspace_symbol_generation ||
        !@workspace_symbol_request.equal?(request)
      request[:clients].none? { |client| @retired_language_clients&.[](client) }
    end

    def prepare_workspace_symbol_palette(items, generation)
      labels = items.map do |item|
        location = item.fetch("location")
        path = Sadr::Protocol.path(location.fetch("uri"))
        container = item["containerName"]
        name = bounded_workspace_symbol_text(item.fetch("name"), 256)
        container = bounded_workspace_symbol_text(container, 128) if container
        basename = bounded_workspace_symbol_text(File.basename(path), 96)
        label = "#{name}#{container ? " — #{container}" : ""} #{basename}:#{location.dig('range', 'start', 'line') + 1}".freeze
        bounded_workspace_symbol_text(label, WORKSPACE_SYMBOL_LABEL_BYTES)
      end
      groups = labels.each_with_index.each_with_object({}) do |(label, index), values|
        (values[label] ||= []) << index
      end
      groups.each_value(&:freeze)
      groups.freeze
      visible = [items.length, 12].min
      # Index construction is worker-safe; its mutable, thread-confined Session is created by update_palette.
      {kind: :workspace_symbol_results, query: +"", index: 0, matches: labels.first(visible).freeze,
       all_matches: labels.freeze, items: items, indices: (0...visible).to_a.freeze,
       workspace_symbol_groups: groups, workspace_symbol_index: Spica::Index.new(groups.keys, tie_break: :index),
       workspace_symbol_generation: generation}
    end

    def bounded_workspace_symbol_text(value, maximum)
      return value if value.frozen? && value.bytesize <= maximum
      return value.dup.freeze if value.bytesize <= maximum
      result = +""
      value.each_grapheme_cluster do |cluster|
        break if result.bytesize + cluster.bytesize + "…".bytesize > maximum
        result << cluster
      end
      result << "…" if maximum >= "…".bytesize
      result.freeze
    end

    def display_workspace_symbols(prepared)
      query = if @palette&.dig(:kind) == :workspace_symbol_results &&
          @palette[:workspace_symbol_generation] == prepared[:workspace_symbol_generation]
        @palette.fetch(:query).dup
      else
        +""
      end
      prepared = prepared.merge(query: query)
      self.palette = prepared
      update_palette unless query.empty?
      count = prepared.fetch(:items).length
      @message = count.zero? ? "No workspace symbols found" : "#{count} workspace symbols"
    end

    def install_workspace_symbol_palette(request, prepared)
      (@workspace_symbol_lock ||= Mutex.new).synchronize do
        return false unless workspace_symbol_request_current?(request)
        display_workspace_symbols(prepared)
        true
      end
    end
    private :workspace_symbol_clients, :normalize_workspace_symbols, :deduplicate_workspace_symbols,
      :workspace_symbol_cancelled?, :workspace_symbol_request_current?, :prepare_workspace_symbol_palette,
      :bounded_workspace_symbol_text, :display_workspace_symbols, :install_workspace_symbol_palette

    def run_save_actions(buffer)
      language = definition_for(buffer.path)
      values = @settings.for_language(language.name)
      kinds = values["code_actions_on_save"]
      return false unless values["format_on_save"] || !kinds.empty?
      return false unless language_server_options(language.name)

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + values["format_on_save_timeout"] / 1_000.0
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Sadr::Timeout, "save actions timed out" if remaining <= 0
      clients = language_clients(buffer, timeout: remaining)
      raise Sadr::Timeout, "save actions timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      buffer.begin_undo_group
      ran = false
      begin
        formatter = route_language_clients(language.name, clients, "formatting").find do |client|
          capability = client.capabilities["documentFormattingProvider"]
          capability == true || capability.is_a?(Hash)
        end
        if values["format_on_save"] && formatter
          version = buffer.version
          edits = save_action_await(formatter.formatting(Sadr::Protocol.uri(buffer.path),
            {tabSize: values["tab_size"], insertSpaces: !values["use_tabs"]}), deadline)
          raise Error, "document changed while awaiting save formatting" unless buffer.version == version
          apply_save_format(buffer, version, edits)
          ran = true
        end
        action_clients = route_language_clients(language.name, clients, "codeAction").select do |client|
          provider = client.capabilities["codeActionProvider"]
          provider == true || provider.is_a?(Hash)
        end
        unless action_clients.empty?
          kinds.each { |kind| ran = run_code_action_on_save(action_clients, buffer, kind, deadline) || ran }
        end
        ran
      ensure
        buffer.end_undo_group
        clients.each { |client| @save_action_errors&.delete(client) }
      end
    end

    def save_action_await(future, deadline)
      unless future.respond_to?(:done?) && future.respond_to?(:await)
        raise Error, "language server request did not return a future"
      end
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining <= 0
          future.cancel if !future.done? && future.respond_to?(:cancel)
          raise Sadr::Timeout, "save actions timed out"
        end
        break if future.done?
        drain
        sleep([remaining, 0.001].min) unless future.done?
      end
      drain
      future.await(timeout: 0)
    end

    def apply_save_format(buffer, version, edits)
      edits ||= []
      raise Error, "invalid formatting response" unless edits.is_a?(Array)
      edit = {"documentChanges" => [{"textDocument" => {
        "uri" => Sadr::Protocol.uri(buffer.path), "version" => version
      }, "edits" => edits}]}
      result = apply_workspace_edit(edit)
      raise Error, result["failureReason"].to_s unless result["applied"]
    end

    def run_code_action_on_save(clients, buffer, kind, deadline)
      version = buffer.version
      range = Sadr::Protocol.range(buffer.rope, 0...buffer.rope.bytesize)
      pending = clients.map do |client|
        [client, client.code_action(Sadr::Protocol.uri(buffer.path), range,
          {diagnostics: diagnostics_for(buffer), only: [kind], triggerKind: 2}), nil]
      rescue StandardError => error
        [client, nil, error]
      end
      failures, successes = [], 0
      actions = pending.flat_map do |client, future, failure|
        if failure
          failures << failure
          next []
        end
        begin
          result = save_action_await(future, deadline)
          successes += 1
          Array(result).map { |action| [action, client] }
        rescue StandardError => error
          failures << error
          []
        end
      end
      raise failures.first if successes.zero? && !failures.empty?
      actions = deduplicate_client_items(actions)
      raise Error, "document changed while awaiting save code actions" unless buffer.version == version
      raise Error, "invalid code action response" unless actions.all? { |action, _client| action.is_a?(Hash) }
      candidates = actions.reject { |action, _client| action["disabled"] }
      selected = candidates.find { |action, _client| action["kind"] == kind } ||
        candidates.find { |action, _client| action["kind"].is_a?(String) && action["kind"].start_with?("#{kind}.") } ||
        candidates.find { |action, _client| !action.key?("kind") }
      return false unless selected
      action, client = selected

      provider = client.capabilities["codeActionProvider"]
      if provider.is_a?(Hash) && provider["resolveProvider"] && !action.key?("edit") && !action["command"].is_a?(String)
        resolved = save_action_await(client.resolve_code_action(action), deadline)
        raise Error, "invalid resolved code action" unless resolved.nil? || resolved.is_a?(Hash)
        action = action.merge(resolved || {})
        raise Error, "document changed while resolving save code action" unless buffer.version == version
      end
      if action["edit"]
        result = apply_workspace_edit(action["edit"])
        raise Error, result["failureReason"].to_s unless result["applied"]
      end
      command = action["command"]
      command = action if command.is_a?(String)
      if command
        raise Error, "invalid code action command" unless command.is_a?(Hash)
        @save_action_errors&.delete(client)
        active = @save_action_clients ||= Hash.new(0)
        active[client] += 1
        begin
          request = client.execute_command(command.fetch("command"), arguments: command.fetch("arguments", []))
          save_action_await(request, deadline)
        ensure
          active[client] -= 1
          active.delete(client) if active[client].zero?
        end
        raise Error, @save_action_errors.delete(client) if @save_action_errors&.key?(client)
      end
      true
    ensure
      cancel_language_requests(pending)
    end
    private :save_action_await, :apply_save_format, :run_code_action_on_save

    def prepare_rename(current = editor)
      self.palette = nil
      invalidate_prepare_rename
      unless current && current.buffer.path
        self.palette = {kind: :rename, query: +"", index: 0, matches: []}
        return true
      end

      snapshot = rename_snapshot(current)
      language, client = snapshot.values_at(:language, :client)
      unless client || language_server_options(language)
        return open_rename_palette(snapshot, "")
      end
      return open_rename_palette(snapshot, "") if client && !snapshot[:prepare_supported]

      requests = @prepare_rename_requests ||= {}
      if requests.length >= PREPARE_RENAME_REQUEST_LIMIT
        release_rename_snapshot(snapshot)
        @message = "Too many rename requests"
        return false
      end
      id = @prepare_rename_request_id = @prepare_rename_request_id.to_i + 1
      requests[id] = snapshot
      start_prepare_rename(id, snapshot)
      @message = "Preparing rename…"
      nil
    rescue StandardError => error
      @prepare_rename_requests&.delete_if { |_id, request| request.equal?(snapshot) }
      release_rename_snapshot(snapshot) if snapshot
      @message = error.message
      false
    end

    def rename_prepared(snapshot, name)
      unless valid_rename_value?(name) && name.bytesize <= RENAME_VALUE_LIMIT
        release_rename_snapshot(snapshot)
        @message = "Invalid rename value"
        return false
      end
      unless rename_snapshot_valid?(snapshot)
        release_rename_snapshot(snapshot)
        @message = "Rename cancelled because the document changed"
        return false
      end

      requests = @prepare_rename_requests ||= {}
      if requests.length >= PREPARE_RENAME_REQUEST_LIMIT
        release_rename_snapshot(snapshot)
        @message = "Too many rename requests"
        return false
      end
      id = @prepare_rename_request_id = @prepare_rename_request_id.to_i + 1
      requests[id] = snapshot
      start_prepared_rename(id, snapshot, name.dup.freeze)
      @message = "rename…"
      nil
    rescue StandardError => error
      @prepare_rename_requests&.delete_if { |_id, request| request.equal?(snapshot) }
      release_rename_snapshot(snapshot)
      @message = error.message
      false
    end

    def invalidate_prepare_rename(buffer = nil, client: nil, editor: nil)
      @prepare_rename_requests&.delete_if do |_id, snapshot|
        matches = (!buffer || snapshot[:buffer].equal?(buffer)) && (!editor || snapshot[:editor].equal?(editor)) &&
          (!client || snapshot[:client]&.equal?(client))
        if matches
          snapshot[:future]&.cancel
          release_rename_snapshot(snapshot)
        end
        matches
      end
      snapshot = @palette&.dig(:kind) == :rename && @palette[:rename]
      if snapshot && (!buffer || snapshot[:buffer].equal?(buffer)) && (!editor || snapshot[:editor].equal?(editor)) &&
          (!client || snapshot[:client]&.equal?(client))
        self.palette = nil
      end
      nil
    end

    def request_completions(current, buffer, offset)
      cancel_completion_requests
      version = buffer.version
      generation = @completion_generation = (@completion_generation || 0) + 1
      context = {editor: current, version: version, generation: generation,
        query: completion_query(buffer, offset), metadata: {}, errors: []}
      job = Thread.new do
        completions = @providers.complete(buffer, offset, context)
        post do
          next unless generation == @completion_generation
          next unless @panes.any? { |pane| pane.editors.include?(current) }
          if buffer.version == version
            display_completions(completions, current, context)
          else
            @message = "Document changed; request completion again"
          end
        end
      rescue StandardError => error
        post { @message = error.message }
      end
      (@completion_jobs ||= []) << job
      (@language_jobs ||= []) << job
      @completion_jobs.reject! { |thread| !thread.alive? }
      @language_jobs.reject! { |thread| !thread.alive? }
      @message = "completion…"
    end

    def cancel_completion_requests
      @completion_generation = (@completion_generation || 0) + 1
      jobs = @completion_jobs&.dup || []
      jobs.each do |thread|
        thread.kill if thread.alive?
        begin
          thread.join
        rescue StandardError
          nil
        end
      end
      @completion_jobs&.clear
      @language_jobs&.reject! { |thread| jobs.include?(thread) || !thread.alive? }
    end

    def lsp_completions(buffer, offset, context)
      responses = if context.key?(:lsp_result)
        [[context[:client], context[:lsp_result]]]
      else
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        clients = language_clients(buffer, feature: "completion",
          timeout: deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
        uri = Sadr::Protocol.uri(buffer.path)
        position = Sadr::Protocol.position(buffer.rope, offset)
        pending = clients.map do |client|
          [client, client.completion(uri, position), nil]
        rescue StandardError => error
          [client, nil, error]
        end
        begin
          pending.filter_map do |client, future, failure|
            if failure
              context[:errors] << [:lsp, failure.message.to_s.slice(0, 4_096).freeze] if context[:errors].length < 64
              next
            end
            begin
              [client, language_request_await(future, deadline)]
            rescue StandardError => error
              context[:errors] << [:lsp, error.message.to_s.slice(0, 4_096).freeze] if context[:errors].length < 64
              nil
            end
          end
        ensure
          cancel_language_requests(pending)
        end
      end
      context[:client] = responses.first&.first
      responses.flat_map do |client, result|
        lsp_completion_items(result).map do |item|
          text_edit = item["textEdit"]
          if text_edit
            range = text_edit.is_a?(Hash) && (text_edit["range"] || text_edit["replace"] || text_edit["insert"])
            unless range.is_a?(Hash) && text_edit["newText"].is_a?(String) && text_edit["newText"].valid_encoding?
              raise Error, "invalid completion text edit"
            end
            Sadr::Protocol.offset(buffer.rope, range.fetch("start"))
            Sadr::Protocol.offset(buffer.rope, range.fetch("end"))
          end
          insertion = text_edit && text_edit["newText"] || item["insertText"] || item.fetch("label")
          documentation = item["documentation"]
          documentation = documentation["value"] if documentation.is_a?(Hash)
          additional = item.fetch("additionalTextEdits", []).map do |entry|
            raise Error, "invalid completion additional edit" unless entry.is_a?(Hash)
            range = entry.fetch("range")
            [Sadr::Protocol.offset(buffer.rope, range.fetch("start"))...Sadr::Protocol.offset(buffer.rope, range.fetch("end")), entry.fetch("newText")]
          end
          completion = Provider::Completion.new(item.fetch("label"), insertion, item["kind"], item["detail"], documentation,
            item["sortText"], item["filterText"], additional, :lsp)
          context[:metadata][completion] ||= {item: item, client: client}
          completion
        end
      end
    end
    private :request_completions, :cancel_completion_requests, :lsp_completions
    def diagnostics_for(buffer)
      return [] unless buffer.path
      uri = Sadr::Protocol.uri(buffer.path)
      local = @diagnostics.for_uri(uri).reject { |entry| entry.source == :lsp }.map(&:diagnostic)
      clients = [*(@language_clients || {}).values.flatten, *(@lsp_diagnostics || {}).keys].uniq
      lsp = clients.flat_map do |client|
        next [] unless @opened_lsp_documents&.key?([client, buffer]) &&
          @diagnostic_versions&.dig(client, uri) == buffer.version
        @lsp_diagnostics.fetch(client).fetch(uri, [])
      end.uniq
      local + lsp
    end

    def document_highlight_decorations(buffer, rows, current)
      return [] unless current.is_a?(Editor) && current.buffer.equal?(buffer)

      client = active_language_client(current.language_document.definition.name, "documentHighlight")
      key = document_highlight_key(client, current, buffer)
      value = (@document_highlight_cache || {})[key]
      value.is_a?(Array) ? value.select { |item| diagnostic_item_visible?(buffer, item, rows) } : []
    end

    def request_document_highlights(current)
      requests = @document_highlight_requests ||= {}
      requests.delete_if do |editor, entry|
        hidden = @panes.none? { |pane| pane.active.equal?(editor) }
        entry[:future]&.cancel if hidden
        hidden
      end
      buffer = current.buffer
      return false unless buffer.path && !buffer.read_only && @panes.any? { |pane| pane.active.equal?(current) }

      language = current.language_document.definition.name
      client = active_language_client(language, "documentHighlight")
      key = document_highlight_key(client, current, buffer)
      cache = @document_highlight_cache ||= {}
      return false if cache.key?(key)

      pending = requests[current]
      if pending && pending[:buffer].equal?(buffer) && pending[:version] == buffer.version &&
          pending[:head] == current.primary.head && (!client || !pending[:client] || pending[:client].equal?(client))
        return false
      end
      invalidate_document_highlights(editor: current) if pending || cache.keys.any? { |entry| entry[1].equal?(current) }
      unless client || language_server_options(language)
        cache_document_highlights(key, false)
        return false
      end
      return false if requests.length >= DOCUMENT_HIGHLIGHT_REQUEST_LIMIT

      request = {client: client, editor: current, buffer: buffer, version: buffer.version,
        head: current.primary.head, rope: buffer.rope, uri: Sadr::Protocol.uri(buffer.path)}
      requests[current] = request
      @decorations.invalidate(:document_highlight, buffer: buffer)
      @window&.request_frame
      job = Thread.new do
        begin
          owner = language_client(buffer, feature: "documentHighlight")
          request[:client] = owner
          supported = document_highlight_supported?(owner)
          valid = document_highlight_request_valid?(request, owner)
          future = owner.document_highlight(request[:uri], Sadr::Protocol.position(request[:rope], request[:head])) if supported && valid
          request[:future] = future
          result = future.await(timeout: 10) if future && document_highlight_request_valid?(request, owner)
          future&.cancel unless document_highlight_request_valid?(request, owner)
          highlights = supported && valid ? normalize_document_highlights(request[:rope], result) : false
          post do
            next unless @document_highlight_requests&.[](current).equal?(request)
            @document_highlight_requests.delete(current)
            next unless document_highlight_result_valid?(request, owner)

            cache_document_highlights(document_highlight_key(owner, current, buffer,
              request[:version], request[:head], supported), highlights)
          end
        rescue StandardError => error
          post do
            next unless @document_highlight_requests&.[](current).equal?(request)
            @document_highlight_requests.delete(current)
            next unless owner ? document_highlight_result_valid?(request, owner) : document_highlight_editor_valid?(request)

            cache_document_highlights(document_highlight_key(owner, current, buffer,
              request[:version], request[:head]), false)
            @message = error.message unless owner && @retired_language_clients&.[](owner)
          end
        ensure
          worker = Thread.current
          post { @language_jobs&.delete(worker) }
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      true
    end

    def invalidate_document_highlights(buffer = nil, client: nil, editor: nil)
      buffer ||= editor&.buffer
      @document_highlight_cache&.delete_if do |key, _value|
        (!buffer || key[2].equal?(buffer)) && (!client || key[0]&.equal?(client)) && (!editor || key[1].equal?(editor))
      end
      @document_highlight_requests&.delete_if do |current, entry|
        matches = (!buffer || entry[:buffer].equal?(buffer)) && (!client || entry[:client]&.equal?(client)) &&
          (!editor || current.equal?(editor))
        entry[:future]&.cancel if matches
        matches
      end
      @decorations.invalidate(:document_highlight, buffer: buffer)
      @window&.request_frame unless @closed
      nil
    end

    def document_link_decorations(buffer, rows, current)
      return [] unless current.is_a?(Editor) && current.buffer.equal?(buffer)

      client = active_language_client(current.language_document.definition.name, "documentLink")
      cache = (@document_link_cache || {})[document_link_key(client, current, buffer)]
      return [] unless cache.is_a?(Hash)

      cache[:entries].filter_map do |entry|
        next unless diagnostic_item_visible?(buffer, entry[:decoration], rows)

        entry[:decoration]
      end
    end

    def request_document_links(current)
      requests = @document_link_requests ||= {}
      requests.delete_if do |editor, request|
        hidden = @panes.none? { |pane| pane.active.equal?(editor) }
        request[:future]&.cancel if hidden
        hidden
      end
      buffer = current.buffer
      return false unless buffer.path && !buffer.read_only && @panes.any? { |pane| pane.active.equal?(current) }

      language = current.language_document.definition.name
      client = active_language_client(language, "documentLink")
      key = document_link_key(client, current, buffer)
      return false if (@document_link_cache ||= {}).key?(key)

      pending = requests[current]
      if pending && pending[:buffer].equal?(buffer) && pending[:version] == buffer.version &&
          pending[:document].equal?(current.language_document) &&
          (!client || !pending[:client] || pending[:client].equal?(client)) &&
          (!pending[:client] || pending[:supported] == document_link_supported?(client) &&
            pending[:resolve] == document_link_resolve_supported?(client))
        return false
      end
      invalidate_document_links(editor: current) if pending || @document_link_cache.keys.any? { |entry| entry[1].equal?(current) }
      unless client || language_server_options(language)
        cache_document_links(key, false)
        return false
      end
      return false if requests.length >= DOCUMENT_LINK_REQUEST_LIMIT

      request = {client: client, editor: current, buffer: buffer, version: buffer.version,
        rope: buffer.rope, uri: Sadr::Protocol.uri(buffer.path), language: language,
        document: current.language_document,
        supported: client && document_link_supported?(client),
        resolve: client && document_link_resolve_supported?(client)}
      requests[current] = request
      @decorations.invalidate(:document_link, buffer: buffer)
      job = Thread.new do
        begin
          owner = language_client(buffer, feature: "documentLink")
          if request[:client]
            next unless request[:client].equal?(owner)
          else
            request[:client] = owner
            request[:supported] = document_link_supported?(owner)
            request[:resolve] = document_link_resolve_supported?(owner)
          end
          supported, resolve = request.values_at(:supported, :resolve)
          valid = document_link_request_valid?(request, owner)
          future = owner.document_link(request[:uri]) if supported && valid
          request[:future] = future
          result = future.await(timeout: 10) if future && document_link_request_valid?(request, owner)
          future&.cancel unless document_link_request_valid?(request, owner)
          links = supported && valid ? normalize_document_links(request[:rope], result, resolve: resolve) : false
          post do
            next unless @document_link_requests&.[](current).equal?(request)
            @document_link_requests.delete(current)
            next unless document_link_result_valid?(request, owner)

            cache_document_links(document_link_key(owner, current, buffer, request[:version], supported, resolve), links)
          end
        rescue StandardError => error
          post do
            next unless @document_link_requests&.[](current).equal?(request)
            @document_link_requests.delete(current)
            next unless owner ? document_link_result_valid?(request, owner) : document_link_editor_valid?(request)

            cache_document_links(document_link_key(owner, current, buffer, request[:version]), false)
            @message = error.message unless owner && @retired_language_clients&.[](owner)
          end
        ensure
          worker = Thread.current
          post { @language_jobs&.delete(worker) }
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      true
    end

    def invalidate_document_links(buffer = nil, client: nil, editor: nil)
      buffer ||= editor&.buffer
      @document_link_cache&.delete_if do |key, cache|
        matches = (!buffer || key[2].equal?(buffer)) && (!client || key[0]&.equal?(client)) &&
          (!editor || key[1].equal?(editor))
        cache[:entries].each { |entry| entry[:future]&.cancel } if matches && cache.is_a?(Hash)
        matches
      end
      @document_link_requests&.delete_if do |current, request|
        matches = (!buffer || request[:buffer].equal?(buffer)) && (!client || request[:client]&.equal?(client)) &&
          (!editor || current.equal?(editor))
        request[:future]&.cancel if matches
        matches
      end
      @decorations.invalidate(:document_link, buffer: buffer)
      @window&.request_frame unless @closed
      nil
    end

    def linked_editing_range(current = editor)
      invalidate_linked_editing_ranges
      buffer = current.buffer
      unless buffer.path && !buffer.read_only
        @message = "Linked editing is not available here"
        return false
      end

      snapshot = linked_editing_snapshot(current)
      language, client = snapshot.values_at(:language, :client)
      unless client || language_server_options(language)
        release_linked_editing_snapshot(snapshot)
        @message = "Linked editing is not available here"
        return false
      end
      if client && !snapshot[:supported]
        release_linked_editing_snapshot(snapshot)
        @message = "Language server does not support linked editing"
        return false
      end
      requests = @linked_editing_requests ||= {}
      if requests.length >= LINKED_EDITING_REQUEST_LIMIT
        release_linked_editing_snapshot(snapshot)
        @message = "Too many linked editing requests"
        return false
      end

      id = @linked_editing_request_id = @linked_editing_request_id.to_i + 1
      requests[id] = snapshot
      start_linked_editing_request(id, snapshot)
      @message = "Loading linked ranges…"
      nil
    rescue StandardError => error
      @linked_editing_requests&.delete_if { |_id, request| request.equal?(snapshot) }
      release_linked_editing_snapshot(snapshot) if snapshot
      @message = error.message
      false
    end

    def invalidate_linked_editing_ranges(buffer = nil, client: nil, editor: nil)
      @linked_editing_requests&.delete_if do |_id, snapshot|
        matches = (!buffer || snapshot[:buffer].equal?(buffer)) && (!client || snapshot[:client]&.equal?(client)) &&
          (!editor || snapshot[:editor].equal?(editor))
        if matches
          snapshot[:future]&.cancel
          release_linked_editing_snapshot(snapshot)
        end
        matches
      end
      nil
    end

    def diagnostic_decorations(buffer, rows)
      state = [buffer.version, @diagnostic_generation || 0, @settings["diagnostics"]]
      cached = @diagnostic_decoration_cache&.[](buffer)
      unless cached && cached.first == state
        cached = [state, build_diagnostic_decorations(buffer).freeze]
        (@diagnostic_decoration_cache ||= {})[buffer] = cached
      end
      cached.last.select { |item| diagnostic_item_visible?(buffer, item, rows) }
    end

    def invalidate_diagnostics(buffer = nil)
      @diagnostic_generation = (@diagnostic_generation || 0) + 1
      buffer ? @diagnostic_decoration_cache&.delete(buffer) : @diagnostic_decoration_cache&.clear
      @decorations.invalidate(:diagnostics, buffer: buffer)
    end
    def resource_workspace_edit?(edit)
      edit.is_a?(Hash) && edit["documentChanges"].is_a?(Array) && edit["documentChanges"].any? { |change| change.is_a?(Hash) && change["kind"] }
    end
    def confirm_workspace_edit(edit, label: "Apply language server changes?", response: nil, on_applied: nil)
      raise Error, "invalid workspace edit" unless edit.is_a?(Hash)
      changes = edit.fetch("documentChanges", [])
      raise Error, "invalid documentChanges" unless changes.is_a?(Array) && changes.length <= 10_000
      details = Array(edit["documentChanges"]).filter_map do |change|
        next unless change.is_a?(Hash) && change["kind"]
        paths = change["kind"] == "rename" ? change.values_at("oldUri", "newUri") : [change["uri"]]
        raise Error, "resource URI is too long" unless paths.all? { |uri| uri.is_a?(String) && uri.bytesize <= 16_384 }
        suffix = change.dig("options", "overwrite") ? " (overwrite; backup retained)" : ""
        "#{change['kind']}: #{paths.map { |uri| Sadr::Protocol.path(uri) }.join(' → ')}#{suffix}"
      end
      self.palette = {kind: :workspace_edit, query: label.to_s.slice(0, 1_024), index: details.empty? ? 0 : 1, matches: ["Apply changes", "Cancel"],
        edit: edit, response: response, on_applied: on_applied, details: details}
      @window&.request_frame
      @palette
    end
    def apply_workspace_edit(edit, confirmed: false)
      raise Error, "invalid workspace edit" unless edit.is_a?(Hash)
      if resource_workspace_edit?(edit)
        raise Error, "Resource changes require a file-operation confirmation" unless confirmed
        require_relative "edit/plan"
        return Workspace::Edit::Plan.new(self, edit).apply
      end
      # LSP prefers documentChanges when both representations are supplied.
      documents = if edit.key?("documentChanges")
        changes = edit["documentChanges"]
        raise Error, "invalid documentChanges" unless changes.is_a?(Array)
        changes.map do |change|
          raise Error, "invalid document change" unless change.is_a?(Hash)
          raise Error, "Resource changes require a file-operation confirmation" if change["kind"]
          [change.fetch("textDocument"), change.fetch("edits")]
        end
      else
        changes = edit.fetch("changes", {})
        raise Error, "invalid workspace changes" unless changes.is_a?(Hash)
        changes.map { |uri, edits| [{"uri" => uri}, edits] }
      end
      pending, snapshots, originals = {}, {}, {}
      plans = documents.map do |document, edits|
        raise Error, "invalid text document edit" unless document.is_a?(Hash) && edits.is_a?(Array)
        path = canonical_path(Sadr::Protocol.path(document.fetch("uri")))
        raise Error, "language server edit is outside project" unless path.start_with?(@root + File::SEPARATOR)
        actual = File.exist?(path) ? File.realpath(path) : path
        raise Error, "language server edit follows a link outside project" unless actual.start_with?(@root + File::SEPARATOR)
        buffer = @buffers[path] || (pending[path] ||= Buffer.open(path))
        raise Error, "cannot edit a read-only document" if buffer.read_only
        originals[buffer] ||= [buffer.rope, buffer.version]
        rope, version = snapshots.fetch(buffer) { originals.fetch(buffer) }
        requested_version = document["version"]
        unless requested_version.nil? || (requested_version.is_a?(Integer) && requested_version == version)
          raise Error, "language server edit has stale document version"
        end
        changes = edits.map do |entry|
          unless entry.is_a?(Hash) && entry["range"].is_a?(Hash) && entry["newText"].is_a?(String) && entry["newText"].valid_encoding?
            raise Error, "invalid LSP text edit"
          end
          range = entry.fetch("range")
          [Sadr::Protocol.offset(rope, range.fetch("start"))...Sadr::Protocol.offset(rope, range.fetch("end")), entry.fetch("newText")]
        end
        # Repeated TextDocumentEdits address the preceding staged snapshot.
        snapshots[buffer] = [rope.apply_edits(changes), version + (changes.empty? ? 0 : 1)]
        [buffer, changes]
      end
      unless originals.all? { |buffer, (rope, version)| buffer.rope.equal?(rope) && buffer.version == version }
        raise Error, "document changed while preparing language server edits"
      end
      @buffers.merge!(pending)
      grouped = []
      originals.each_key { |buffer| buffer.begin_undo_group; grouped << buffer }
      plans.each { |buffer, changes| buffer.edit(changes, kind: :lsp) }
      {"applied" => true}
    ensure
      grouped&.reverse_each(&:end_undo_group)
      pending&.each { |path, buffer| buffer.close unless @buffers[path].equal?(buffer) }
    end

    def display_completions(completions, current, context)
      metadata = context.fetch(:metadata)
      language = current.language_document.definition.name
      active = route_language_clients(language, language_client_list(language), "completion")
      completions = completions.reject do |completion|
        client = metadata[completion]&.fetch(:client)
        client && !active.include?(client)
      end
      return if completions.empty? && context[:client] && !active.include?(context[:client])
      if completions.empty? && (failure = context.fetch(:errors).first)
        @message = failure.last
        self.palette = nil
        return
      end
      self.palette = {kind: :completion, query: +"", index: 0, matches: completions.map(&:label), items: completions,
        completion_metadata: metadata, completion_generation: context[:generation], editor: current, version: current.buffer.version}
      update_palette
    end

    def accept_provider_completion(completion, current)
      raise Error, "invalid completion" unless completion.is_a?(Provider::Completion)
      value = completion.insert_text || completion.label
      snippet = completion.source == :snippet || completion.kind == :snippet
      variables = current.snippet_variables(workspace_root: @root, clipboard: @window.respond_to?(:clipboard) ? @window.clipboard : nil) if snippet
      expanded = snippet ? Snippet.new(value, variables: variables).text : value
      range = current.primary.range
      additional = completion.additional_edits.map do |entry|
        raise ArgumentError, "invalid completion additional edit" unless entry.is_a?(Array) && entry.length == 2
        entry
      end.sort_by { |edit| edit.first.begin }
      current.buffer.rope.apply_edits((additional + [[range, expanded]]).sort_by { |edit| edit.first.begin })
      current.buffer.begin_undo_group
      begin
        current.select(range.begin, range.end)
        current.buffer.edit(additional, kind: :completion) unless additional.empty?
        snippet ? current.insert_snippet(value, variables: variables) : current.insert_text(value, auto_indent: false, pair: false)
      ensure
        current.buffer.end_undo_group
      end
      show_snippet_choices(current) if snippet
    end
    private :display_completions, :accept_provider_completion

    def accept_language_result(palette, index)
      item = palette[:items][index]
      return unless item
      current = palette[:editor]
      raise Error, "Document was closed; request again" if current && !@panes.any? { |pane| pane.editors.include?(current) }
      if current && palette[:version] && current.buffer.version != palette[:version]
        raise Error, "Document changed; request #{palette[:kind]} again"
      end
      completion = item if item.is_a?(Provider::Completion)
      metadata = palette[:completion_metadata]&.[](completion)
      item = metadata[:item] if metadata
      client = metadata&.fetch(:client) || palette[:item_clients]&.[](index) || palette[:client]
      raise Error, "Language server settings changed; request again" if client && @retired_language_clients&.[](client)
      provider, resolver = case palette[:kind]
      when :completion then ["completionProvider", :resolve_completion]
      when :code_actions then palette[:lens] ? ["codeLensProvider", :resolve_code_lens] : ["codeActionProvider", :resolve_code_action]
      end
      capability = client&.capabilities&.fetch(provider, nil) if provider && client.respond_to?(:capabilities)
      if !palette[:resolved] && capability.is_a?(Hash) && capability["resolveProvider"]
        (@language_jobs ||= []) << Thread.new do
          resolved = client.public_send(resolver, item).await(timeout: 10)
          post do
            next if palette[:completion_generation] && palette[:completion_generation] != @completion_generation
            items = palette[:items].dup
            items[index] = item.merge(resolved || {})
            accept_language_result(palette.merge(items: items, resolved: true, client: client), index)
          end
        rescue StandardError => error
          post { @message = error.message }
        end
        return
      end
      case palette[:kind]
      when :completion
        editor = palette[:editor]
        return accept_provider_completion(completion, editor) if completion && !metadata
        text_edit = item["textEdit"]
        range = if text_edit
          range = text_edit["range"] || text_edit["replace"] || text_edit.fetch("insert")
          Sadr::Protocol.offset(editor.buffer.rope, range.fetch("start"))...Sadr::Protocol.offset(editor.buffer.rope, range.fetch("end"))
        else
          editor.primary.range
        end
        value = text_edit ? text_edit.fetch("newText") : item["insertText"] || item.fetch("label")
        snippet = item["insertTextFormat"] == 2
        variables = editor.snippet_variables(workspace_root: @root, clipboard: @window.respond_to?(:clipboard) ? @window.clipboard : nil) if snippet
        expanded = snippet ? Snippet.new(value, variables: variables).text : value
        additional = item.fetch("additionalTextEdits", []).map do |entry|
          [Sadr::Protocol.offset(editor.buffer.rope, entry.fetch("range").fetch("start"))...Sadr::Protocol.offset(editor.buffer.rope, entry.fetch("range").fetch("end")), entry.fetch("newText")]
        end.sort_by { |entry| entry.first.begin }
        editor.buffer.rope.apply_edits((additional + [[range, expanded]]).sort_by { |entry| entry.first.begin })
        editor.buffer.begin_undo_group
        begin
          editor.select(range.begin, range.end)
          editor.buffer.edit(additional, kind: :completion) unless additional.empty?
          snippet ? editor.insert_snippet(value, variables: variables) : editor.insert_text(value, auto_indent: false, pair: false)
        ensure
          editor.buffer.end_undo_group
        end
        show_snippet_choices(editor) if snippet
        command = item["command"]
        client.execute_command(command.fetch("command"), arguments: command.fetch("arguments", [])) if command && client
      when :locations, :symbols, :workspace_symbol_results
        location = item["location"] || item
        jump_to_language_location(location)
      when :code_actions
        raise Error, item["disabled"]["reason"].to_s if item["disabled"]
        run_command = lambda do
          command = item["command"]
          if command
            command = item if command.is_a?(String)
            client.execute_command(command.fetch("command"), arguments: command.fetch("arguments", []))
          end
        end
        return confirm_workspace_edit(item["edit"], label: item.fetch("title", "Apply code action?"), on_applied: run_command) if resource_workspace_edit?(item["edit"])
        apply_workspace_edit(item["edit"]) if item["edit"]
        run_command.call
      end
    end
    def show_diagnostics
      entries = @diagnostics.all
      labels = entries.map do |entry|
        row = entry.diagnostic.dig("range", "start", "line")
        "#{File.basename(Sadr::Protocol.path(entry.uri))}:#{row + 1} #{entry.diagnostic['message']}"
      end
      items = entries.map { |entry| {"uri" => entry.uri, "range" => entry.diagnostic.fetch("range")} }
      self.palette = {kind: :locations, query: +"", index: 0, matches: labels, items: items}
      update_palette
    end
    def show_outline
      if editor.language_document.definition.name == "ruby"
        document = editor.language_document
        symbols = document.outline
        self.palette = {kind: :outline, query: +"", index: 0, matches: symbols.map { |symbol| "#{'  ' * symbol.depth}#{symbol.name}" }, items: symbols,
          editor: editor, document: document, version: editor.buffer.version, loading: !document.syntax_ready?, partial: !document.syntax_complete?}
        @message = @palette[:loading] ? "Analyzing outline…" : @palette[:partial] ? "Outline (visible region only)" : "Outline"
      else
        language_request(:documentSymbol)
      end
    end
    def expand_selection(current = editor)
      state = @selection_range_states&.[](current)
      if state && selection_range_state_valid?(current, state)
        return apply_selection_expansion(current, state)
      end
      invalidate_selection_ranges(editor: current) if state || @pending_selection_ranges&.key?(current)

      selections = current.selections.dup.freeze
      unless selections.length.between?(1, SELECTION_RANGE_POSITION_LIMIT)
        @message = "Too many selections to expand"
        return false
      end
      document, buffer, version = current.language_document, current.buffer, current.buffer.version
      heads = selections.map(&:head).freeze
      language = document.definition.name
      client = active_language_client(language, "selectionRange")
      pending = {document: document, buffer: buffer, version: version, selections: selections,
        heads: heads, source: :lsp, client: client, supported: selection_range_supported?(client)}
      unless buffer.path && !buffer.read_only && (client || language_server_options(language))
        return selection_with_antares(current, pending)
      end
      unless selection_range_supported?(client) || !client
        return selection_with_antares(current, pending)
      end

      (@pending_selection_ranges ||= {})[current] = pending
      unless request_selection_ranges(buffer, version, client, heads)
        @pending_selection_ranges.delete(current)
        return selection_with_antares(current, pending)
      end
      @message = "Loading selection ranges…"
      nil
    end

    def shrink_selection(current = editor)
      state = @selection_range_states&.[](current)
      unless state && selection_range_state_valid?(current, state) && !state[:history].empty?
        invalidate_selection_ranges(editor: current)
        @message = "No smaller selection"
        return false
      end

      previous, chains = state[:history].pop
      current.set_selections(previous, merge: false)
      state[:current] = previous
      state[:chains] = chains
      current.reveal_cursor
      @message = "Selection shrunk"
      @window&.request_frame
      true
    end

    def fold_current
      current, document = editor, editor.language_document
      buffer, version, cursor = current.buffer, current.buffer.version, current.primary.head
      language = document.definition.name
      client = active_language_client(language, "foldingRange")
      key = folding_range_key(client, buffer, version)
      cache = @folding_range_cache ||= {}
      return cache[key] == false ? fold_with_antares(current, document, version, cursor) :
        apply_fold(current, cache[key], cursor) if cache.key?(key)

      unless buffer.path && !buffer.read_only && (client || language_server_options(language))
        return fold_with_antares(current, document, version, cursor)
      end
      unless folding_range_supported?(client) || !client
        cache_folding_ranges(key, false)
        return fold_with_antares(current, document, version, cursor)
      end

      (@pending_folds ||= {})[current] = {document: document, buffer: buffer, version: version,
        cursor: cursor, source: :lsp, client: client}
      unless request_folding_ranges(buffer, version, client)
        @pending_folds.delete(current)
        return fold_with_antares(current, document, version, cursor)
      end
      @message = "Loading fold ranges…"
    end
    def language_ready(current, document)
      if @palette&.dig(:kind) == :outline && @palette[:editor].equal?(current) && @palette[:document].equal?(document)
        if @palette[:version] != current.buffer.version || (!@palette[:loading] && !document.syntax_ready?)
          @palette[:version], @palette[:loading] = current.buffer.version, true
          @palette[:items], @palette[:matches] = [], []
          @palette.delete(:all_matches)
          @palette.delete(:search)
          @palette.delete(:indices)
          document.request(syntax: true)
        elsif document.syntax_ready? && (@palette[:loading] || !@palette[:items].equal?(document.outline))
          symbols = document.outline
          @palette[:items] = symbols
          @palette[:matches] = symbols.map { |symbol| "#{'  ' * symbol.depth}#{symbol.name}" }
          @palette.delete(:all_matches)
          @palette.delete(:search)
          @palette[:loading], @palette[:partial] = false, !document.syntax_complete?
          update_palette
          @message = @palette[:partial] ? "Outline (visible region only)" : "Outline"
          @window&.request_frame
        elsif @palette[:loading] && !document.pending?
          @palette[:loading] = false
          @message = "Outline analysis unavailable"
        end
      end
      pending = @pending_folds&.[](current)
      if pending && pending[:source] == :antares
        unless pending_fold_valid?(current, pending, document)
          @pending_folds.delete(current)
        else
          return if !document.syntax_ready? && document.pending?
          @pending_folds.delete(current)
          if document.syntax_ready?
            apply_fold(current, document.fold_ranges, pending[:cursor])
          else
            @message = "Fold analysis unavailable"
          end
        end
      end

      pending = @pending_selection_ranges&.[](current)
      return unless pending && pending[:source] == :antares
      unless pending_selection_range_valid?(current, pending, document)
        @pending_selection_ranges.delete(current)
        return
      end
      chains = document.selection_ranges(pending[:heads])
      return if !chains && document.pending?
      @pending_selection_ranges.delete(current)
      if chains
        apply_selection_ranges(current, pending,
          normalize_antares_selection_ranges(pending[:buffer].rope, pending[:heads], chains))
      else
        @message = "Selection analysis unavailable"
      end
    end

    def invalidate_folding_ranges(buffer = nil, client: nil, editor: nil)
      affected = []
      unless editor && !buffer && !client
        @folding_range_cache&.delete_if do |key, _value|
          matches = (!buffer || key[1].equal?(buffer)) && (!client || key[0]&.equal?(client))
          affected << key[1] if matches
          matches
        end
        @folding_range_requests&.delete_if do |_id, request|
          matches = (!buffer || request[:buffer].equal?(buffer)) && (!client || request[:client]&.equal?(client))
          if matches
            affected << request[:buffer]
            request[:future]&.cancel
          end
          matches
        end
      end
      @pending_folds&.delete_if do |current, pending|
        (!buffer || pending[:buffer].equal?(buffer)) && (!editor || current.equal?(editor)) &&
          (!client || pending[:client]&.equal?(client) || affected.any? { |item| item.equal?(pending[:buffer]) })
      end
      nil
    end

    def invalidate_selection_ranges(buffer = nil, client: nil, editor: nil)
      affected = []
      unless editor && !buffer && !client
        @selection_range_requests&.delete_if do |_id, request|
          matches = (!buffer || request[:buffer].equal?(buffer)) && (!client || request[:client]&.equal?(client))
          if matches
            affected << request[:buffer]
            request[:future]&.cancel
          end
          matches
        end
      end
      @pending_selection_ranges&.delete_if do |current, pending|
        (!buffer || pending[:buffer].equal?(buffer)) && (!editor || current.equal?(editor)) &&
          (!client || pending[:client]&.equal?(client) || affected.any? { |item| item.equal?(pending[:buffer]) })
      end
      @selection_range_states&.delete_if do |current, state|
        (!buffer || state[:buffer].equal?(buffer)) && (!editor || current.equal?(editor)) &&
          (!client || state[:client]&.equal?(client) || affected.any? { |item| item.equal?(state[:buffer]) })
      end
      cancel_unused_selection_range_requests
      nil
    end

    def invalidate_hidden_selection_ranges
      visible = @panes.filter_map(&:active)
      @pending_selection_ranges&.delete_if do |current, _pending|
        !visible.include?(current)
      end
      cancel_unused_selection_range_requests
      @prepare_rename_requests&.values&.select { |snapshot| !visible.include?(snapshot[:editor]) }&.each do |snapshot|
        invalidate_prepare_rename(editor: snapshot[:editor])
      end
      snapshot = @palette&.dig(:kind) == :rename && @palette[:rename]
      invalidate_prepare_rename(editor: snapshot[:editor]) if snapshot && !visible.include?(snapshot[:editor])
      @document_link_requests&.keys&.reject { |current| visible.include?(current) }&.each do |current|
        invalidate_document_links(editor: current)
      end
      @document_link_cache&.keys&.map { |key| key[1] }&.uniq&.reject { |current| visible.include?(current) }&.each do |current|
        invalidate_document_links(editor: current)
      end
      @linked_editing_requests&.values&.select { |request| !visible.include?(request[:editor]) }&.each do |request|
        invalidate_linked_editing_ranges(editor: request[:editor])
      end
      @hierarchy_prepare_requests&.values&.select { |request| !visible.include?(request[:editor]) }&.each do |request|
        invalidate_hierarchy(editor: request[:editor])
      end
      nil
    end
    private :invalidate_hidden_selection_ranges

    private

    def rename_snapshot(current)
      buffer, offset = current.buffer, current.primary.head
      language = current.language_document.definition.name
      client = active_language_client(language, "rename")
      snapshot = {editor: current, buffer: buffer, version: buffer.version, rope: buffer.rope,
        selections: current.selections, offset: offset, uri: Sadr::Protocol.uri(buffer.path),
        position: Sadr::Protocol.position(buffer.rope, offset), language: language,
        client: client, prepare_supported: prepare_rename_supported?(client)}
      unless Sadr::Protocol.offset(snapshot[:rope], snapshot[:position]) == offset
        raise Error, "invalid rename position"
      end
      snapshot[:selection_subscription] = current.on_selection do
        invalidate_prepare_rename(editor: current) unless current.selections == snapshot[:selections]
      end
      snapshot[:edit_subscription] = buffer.on_edit { invalidate_prepare_rename(buffer) }
      snapshot
    end

    def start_prepare_rename(id, snapshot)
      job = Thread.new do
        begin
          owner = language_client(snapshot[:buffer], feature: "rename")
          unless @prepare_rename_requests&.[](id).equal?(snapshot) && rename_editor_valid?(snapshot)
            next
          end
          snapshot[:client] = owner
          snapshot[:prepare_supported] = prepare_rename_supported?(owner)
          unless snapshot[:prepare_supported]
            post do
              next unless take_rename_request(id, snapshot) && rename_snapshot_valid?(snapshot)
              open_rename_palette(snapshot, "")
            end
            next
          end

          future = owner.prepare_rename(snapshot[:uri], snapshot[:position])
          snapshot[:future] = future
          result = future.await(timeout: 10) if prepare_rename_request_valid?(id, snapshot, owner)
          unless prepare_rename_request_valid?(id, snapshot, owner)
            future.cancel
            next
          end
          placeholder = normalize_prepare_rename(snapshot[:rope], snapshot[:offset], result)
          post do
            next unless take_rename_request(id, snapshot)
            unless rename_snapshot_valid?(snapshot)
              release_rename_snapshot(snapshot)
              next
            end
            if placeholder.nil?
              release_rename_snapshot(snapshot)
              @message = "Rename is not available here"
            else
              open_rename_palette(snapshot, placeholder)
            end
          end
        rescue StandardError => error
          post do
            next unless take_rename_request(id, snapshot)
            valid = rename_editor_valid?(snapshot) && !@retired_language_clients&.[](owner)
            release_rename_snapshot(snapshot)
            @message = error.message if valid
          end
        ensure
          worker = Thread.current
          post do
            release_rename_snapshot(snapshot) if take_rename_request(id, snapshot)
            @language_jobs&.delete(worker)
          end
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      true
    end

    def start_prepared_rename(id, snapshot, name)
      job = Thread.new do
        begin
          owner = language_client(snapshot[:buffer], feature: "rename")
          unless snapshot[:client]&.equal?(owner) && prepare_rename_request_valid?(id, snapshot, owner)
            raise Error, "Rename cancelled because the language server changed"
          end
          future = owner.rename(snapshot[:uri], snapshot[:position], name)
          snapshot[:future] = future
          result = future.await(timeout: 10) if prepare_rename_request_valid?(id, snapshot, owner)
          unless prepare_rename_request_valid?(id, snapshot, owner)
            future.cancel
            next
          end
          post do
            next unless take_rename_request(id, snapshot)
            valid = rename_snapshot_valid?(snapshot)
            release_rename_snapshot(snapshot)
            display_language_result(:rename, result, owner, snapshot[:editor]) if valid
          end
        rescue StandardError => error
          post do
            next unless take_rename_request(id, snapshot)
            valid = rename_editor_valid?(snapshot) && !@retired_language_clients&.[](owner)
            release_rename_snapshot(snapshot)
            @message = error.message if valid
          end
        ensure
          worker = Thread.current
          post { @language_jobs&.delete(worker) }
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      true
    end

    def prepare_rename_request_valid?(id, snapshot, owner)
      @prepare_rename_requests&.[](id).equal?(snapshot) && rename_snapshot_valid?(snapshot) &&
        snapshot[:client].equal?(owner) && @opened_lsp_documents&.key?([owner, snapshot[:buffer]])
    end

    def rename_snapshot_valid?(snapshot)
      client = active_language_client(snapshot[:language], "rename")
      rename_editor_valid?(snapshot) && client.equal?(snapshot[:client]) &&
        prepare_rename_supported?(client) == snapshot[:prepare_supported]
    end

    def rename_editor_valid?(snapshot)
      current, buffer = snapshot.values_at(:editor, :buffer)
      !@closed && current.buffer.equal?(buffer) && buffer.version == snapshot[:version] &&
        current.selections == snapshot[:selections] && current.primary.head == snapshot[:offset] &&
        buffer.path && Sadr::Protocol.uri(buffer.path) == snapshot[:uri] &&
        @panes.any? { |pane| pane.active.equal?(current) }
    end

    def take_rename_request(id, snapshot)
      @prepare_rename_requests&.delete(id).equal?(snapshot)
    end

    def open_rename_palette(snapshot, placeholder)
      unless rename_snapshot_valid?(snapshot)
        release_rename_snapshot(snapshot)
        return false
      end
      self.palette = {kind: :rename, query: +placeholder, index: 0, matches: [], rename: snapshot}
      true
    end

    def release_rename_snapshot(snapshot)
      snapshot&.delete(:selection_subscription)&.detach
      snapshot&.delete(:edit_subscription)&.detach
      snapshot&.delete(:future)
      nil
    end

    def prepare_rename_supported?(client)
      provider = client.capabilities["renameProvider"] if client&.respond_to?(:capabilities)
      provider.is_a?(Hash) && (provider["prepareProvider"] == true || provider[:prepareProvider] == true)
    end

    def valid_rename_value?(value)
      value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding? && !value.include?("\0")
    end

    def cancel_unused_selection_range_requests
      @selection_range_requests&.delete_if do |_id, request|
        used = (@pending_selection_ranges || {}).values.any? do |pending|
          pending[:source] == :lsp && pending[:buffer].equal?(request[:buffer]) &&
            pending[:version] == request[:version] && pending[:heads] == request[:heads] &&
            (!pending[:client] || !request[:client] || pending[:client].equal?(request[:client]))
        end
        request[:future]&.cancel unless used
        !used
      end
      nil
    end

    def request_selection_ranges(buffer, version, client, heads)
      requests = @selection_range_requests ||= {}
      pending = requests.values.any? do |request|
        request[:buffer].equal?(buffer) && request[:version] == version && request[:heads] == heads &&
          (!client || !request[:client] || request[:client].equal?(client))
      end
      return true if pending
      return false if requests.length >= SELECTION_RANGE_REQUEST_LIMIT

      @selection_range_request_id = @selection_range_request_id.to_i + 1
      id = @selection_range_request_id
      request = {client: client, buffer: buffer, version: version, rope: buffer.rope,
        heads: heads, uri: Sadr::Protocol.uri(buffer.path)}
      requests[id] = request
      job = Thread.new do
        begin
          owner = language_client(buffer, feature: "selectionRange")
          request[:client] = owner
          supported = selection_range_supported?(owner)
          valid = selection_range_request_valid?(id, request, owner)
          positions = request[:heads].map { |offset| Sadr::Protocol.position(request[:rope], offset) }
          future = owner.selection_range(request[:uri], positions) if supported && valid
          request[:future] = future
          result = future.await(timeout: 10) if future && selection_range_request_valid?(id, request, owner)
          future&.cancel unless selection_range_request_valid?(id, request, owner)
          chains = supported && valid ? normalize_selection_ranges(request[:rope], request[:heads], result) : false
          chains = false if chains.nil?
          post do
            next unless @selection_range_requests&.delete(id).equal?(request)
            accepted = selection_range_result_valid?(request, owner) &&
              selection_range_supported?(owner) == supported
            finish_pending_selection_ranges(buffer, version, heads, accepted ? chains : false, owner)
          end
        rescue StandardError
          post do
            next unless @selection_range_requests&.delete(id).equal?(request)
            finish_pending_selection_ranges(buffer, version, heads, false, owner)
          end
        ensure
          worker = Thread.current
          post { @language_jobs&.delete(worker) }
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      true
    end

    def finish_pending_selection_ranges(buffer, version, heads, chains, owner)
      (@pending_selection_ranges || {}).dup.each do |current, pending|
        next unless pending[:buffer].equal?(buffer) && pending[:version] == version &&
          pending[:heads] == heads && pending[:source] == :lsp
        @pending_selection_ranges.delete(current)
        next unless pending_selection_range_valid?(current, pending)

        pending[:client] = owner
        pending[:supported] = selection_range_supported?(owner)
        if chains == false
          selection_with_antares(current, pending)
        else
          apply_selection_ranges(current, pending, chains)
        end
      end
    end

    def selection_with_antares(current, pending)
      document = pending[:document]
      chains = document.selection_ranges(pending[:heads])
      if chains
        return apply_selection_ranges(current, pending,
          normalize_antares_selection_ranges(pending[:buffer].rope, pending[:heads], chains))
      end

      client = active_language_client(document.definition.name, "selectionRange")
      pending = pending.merge(source: :antares, client: client,
        supported: selection_range_supported?(client))
      (@pending_selection_ranges ||= {})[current] = pending
      @message = "Analyzing selection ranges…"
      nil
    rescue StandardError
      @pending_selection_ranges&.delete(current)
      @message = "Selection analysis unavailable"
      false
    end

    def apply_selection_ranges(current, pending, chains)
      return false unless pending_selection_range_valid?(current, pending)

      state = {document: pending[:document], buffer: pending[:buffer], version: pending[:version],
        client: pending[:client], supported: pending[:supported], chains: chains,
        current: pending[:selections], history: []}
      (@selection_range_states ||= {})[current] = state
      apply_selection_expansion(current, state)
    end

    def apply_selection_expansion(current, state)
      pairs = state[:current].zip(state[:chains]).map do |selection, chain|
        range = chain.find do |candidate|
          candidate.begin <= selection.start && selection.end <= candidate.end &&
            (candidate.begin < selection.start || selection.end < candidate.end)
        end
        expanded = if !range
          selection
        elsif selection.reversed?
          Selection.new(selection.id, range.end, range.begin, nil)
        else
          Selection.new(selection.id, range.begin, range.end, nil)
        end
        [expanded, chain]
      end.each_with_index.sort_by { |(selection, _chain), index| [selection.start, index] }.map!(&:first)
      expanded = pairs.map(&:first).freeze
      if expanded == state[:current]
        @message = "No larger selection"
        return false
      end

      state[:history] << [state[:current], state[:chains]].freeze
      state[:current] = expanded
      state[:chains] = pairs.map(&:last).freeze
      current.set_selections(expanded, merge: false)
      current.reveal_cursor
      @message = "Selection expanded"
      @window&.request_frame
      true
    end

    def pending_selection_range_valid?(current, pending, document = pending[:document])
      !@closed && current.language_document.equal?(document) && current.buffer.equal?(pending[:buffer]) &&
        current.buffer.version == pending[:version] && current.selections == pending[:selections] &&
        @panes.any? { |pane| pane.active.equal?(current) }
    end

    def selection_range_state_valid?(current, state)
      client = active_language_client(current.language_document.definition.name, "selectionRange")
      !@closed && client.equal?(state[:client]) && selection_range_supported?(client) == state[:supported] &&
        current.language_document.equal?(state[:document]) && current.buffer.equal?(state[:buffer]) &&
        current.buffer.version == state[:version] && current.selections == state[:current] &&
        @panes.any? { |pane| pane.active.equal?(current) }
    end

    def selection_range_supported?(client)
      provider = client.capabilities["selectionRangeProvider"] if client&.respond_to?(:capabilities)
      provider == true || provider.is_a?(Hash)
    end

    def selection_range_result_valid?(request, owner)
      selection_range_context_valid?(request) && language_client_active?(owner) &&
        @opened_lsp_documents&.key?([owner, request[:buffer]])
    end

    def selection_range_request_valid?(id, request, owner)
      @selection_range_requests&.[](id).equal?(request) && selection_range_result_valid?(request, owner)
    end

    def selection_range_context_valid?(request)
      buffer = request[:buffer]
      !@closed && buffer.version == request[:version] && buffer.path &&
        Sadr::Protocol.uri(buffer.path) == request[:uri] &&
        @panes.any? { |pane| pane.editors.any? { |current| current.buffer.equal?(buffer) } }
    end

    def request_folding_ranges(buffer, version, client)
      requests = @folding_range_requests ||= {}
      pending = requests.values.any? do |request|
        request[:buffer].equal?(buffer) && request[:version] == version &&
          (!client || !request[:client] || request[:client].equal?(client))
      end
      return true if pending
      return false if requests.length >= FOLDING_RANGE_REQUEST_LIMIT

      @folding_range_request_id = @folding_range_request_id.to_i + 1
      id = @folding_range_request_id
      request = {client: client, buffer: buffer, version: version, rope: buffer.rope,
        uri: Sadr::Protocol.uri(buffer.path)}
      requests[id] = request
      job = Thread.new do
        begin
          owner = language_client(buffer, feature: "foldingRange")
          request[:client] = owner
          supported = folding_range_supported?(owner)
          valid = folding_range_request_valid?(id, request, owner)
          future = owner.folding_range(request[:uri]) if supported && valid
          request[:future] = future
          result = future.await(timeout: 10) if future && folding_range_request_valid?(id, request, owner)
          future&.cancel unless folding_range_request_valid?(id, request, owner)
          ranges = supported && valid ? normalize_folding_ranges(request[:rope], result) : false
          ranges = false if ranges.nil?
          post do
            next unless @folding_range_requests&.delete(id).equal?(request)
            accepted = folding_range_result_valid?(request, owner) &&
              folding_range_supported?(owner) == supported
            cache_folding_ranges(folding_range_key(owner, buffer, version, supported), ranges) if accepted
            ranges = false unless accepted
            finish_pending_folds(buffer, version, ranges)
          end
        rescue StandardError
          post do
            next unless @folding_range_requests&.delete(id).equal?(request)
            accepted = owner ? folding_range_result_valid?(request, owner) : fold_context_valid?(request)
            cache_folding_ranges(folding_range_key(owner, buffer, version), false) if accepted
            finish_pending_folds(buffer, version, false)
          end
        ensure
          worker = Thread.current
          post { @language_jobs&.delete(worker) }
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      true
    end

    def finish_pending_folds(buffer, version, ranges)
      (@pending_folds || {}).dup.each do |current, pending|
        next unless pending[:buffer].equal?(buffer) && pending[:version] == version && pending[:source] == :lsp
        @pending_folds.delete(current)
        next unless pending_fold_valid?(current, pending)

        if ranges == false
          fold_with_antares(current, pending[:document], version, pending[:cursor])
        else
          apply_fold(current, ranges, pending[:cursor])
        end
      end
    end

    def fold_with_antares(current, document, version, cursor)
      ranges = document.fold_ranges
      return apply_fold(current, ranges, cursor) if document.syntax_ready?

      (@pending_folds ||= {})[current] = {document: document, buffer: current.buffer, version: version,
        cursor: cursor, source: :antares,
        client: active_language_client(document.definition.name, "foldingRange")}
      @message = "Analyzing fold ranges…"
      nil
    end

    def apply_fold(current, ranges, cursor)
      row = current.buffer.rope.point_at(cursor).row
      range = ranges.select do |item|
        first = current.buffer.rope.point_at(item.begin).row
        last = current.buffer.rope.point_at(item.end).row
        row.between?(first, last)
      end.min_by { |item| [item.end - item.begin, -item.begin] }
      current.display_map.fold(range) if range
      @message = range ? "Folded" : "No fold at cursor"
      @window&.request_frame
      range
    end

    def pending_fold_valid?(current, pending, document = pending[:document])
      !@closed && current.language_document.equal?(document) && current.buffer.equal?(pending[:buffer]) &&
        current.buffer.version == pending[:version] && current.primary.head == pending[:cursor] &&
        @panes.any? { |pane| pane.active.equal?(current) }
    end

    def folding_range_supported?(client)
      provider = client.capabilities["foldingRangeProvider"] if client&.respond_to?(:capabilities)
      provider == true || provider.is_a?(Hash)
    end

    def folding_range_key(client, buffer, version = buffer.version,
      supported = folding_range_supported?(client))
      [client, buffer, version, supported]
    end

    def folding_range_result_valid?(request, owner)
      fold_context_valid?(request) && language_client_active?(owner) &&
        @opened_lsp_documents&.key?([owner, request[:buffer]])
    end

    def folding_range_request_valid?(id, request, owner)
      @folding_range_requests&.[](id).equal?(request) && folding_range_result_valid?(request, owner)
    end

    def fold_context_valid?(request)
      buffer = request[:buffer]
      !@closed && buffer.version == request[:version] && buffer.path &&
        Sadr::Protocol.uri(buffer.path) == request[:uri] &&
        @panes.any? { |pane| pane.editors.any? { |current| current.buffer.equal?(buffer) } }
    end

    def cache_folding_ranges(key, ranges)
      cache = @folding_range_cache ||= {}
      cache.delete_if { |entry, _value| entry[0].equal?(key[0]) && entry[1].equal?(key[1]) }
      cache.shift while cache.length >= FOLDING_RANGE_REQUEST_LIMIT
      cache[key] = ranges
    end

    def cache_inlay_hints(client, buffer, version, rows, result, id, settings)
      raise Error, "invalid inlay hints" unless result.nil? || result.is_a?(Array)
      hints = result || []
      raise Error, "too many inlay hints" if hints.length > 10_000

      items = build_inlay_hint_decorations(buffer, hints, settings).freeze
      raise Error, "inlay hint is outside its requested range" unless items.all? { |item| rows.cover?(item.row) }
      cache = @inlay_hint_cache ||= {}
      cache.delete_if do |key, _|
        key[0].equal?(client) && key[1].equal?(buffer) && key[2] == version && key[3] == rows.begin && key[4] == rows.end
      end
      cache.shift while cache.length >= 64
      cache[[client, buffer, version, rows.begin, rows.end]] = [id, items].freeze
      @decorations.invalidate(:inlay_hint, buffer: buffer)
      @window&.request_frame
    end

    def build_inlay_hint_decorations(buffer, hints, settings)
      sequence = 0
      hints.flat_map do |hint|
        unless hint.is_a?(Hash) && hint["position"].is_a?(Hash) && [nil, 1, 2].include?(hint["kind"]) &&
            [nil, true, false].include?(hint["paddingLeft"]) && [nil, true, false].include?(hint["paddingRight"])
          raise Error, "invalid inlay hint"
        end
        next [] if hint["kind"] == 1 && !settings["types"] || hint["kind"] == 2 && !settings["parameter_names"]

        position = Sadr::Protocol.position_value(hint.fetch("position"))
        offset = Sadr::Protocol.offset(buffer.rope, position)
        raise Error, "invalid inlay hint position" unless Sadr::Protocol.position(buffer.rope, offset) == position
        row = buffer.rope.point_at(offset).row
        parts = truncate_inlay_label(hint.fetch("label"), settings["max_length"]).reject { |label, _location| label.empty? }
        parts.each_with_index.map do |(label, location), index|
          validate_inlay_location(location) if location
          click = location && ->(_editor, _offset) { jump_to_language_location(location) }
          left = index.zero? && hint["paddingLeft"]
          right = index == parts.length - 1 && hint["paddingRight"]
          style = {color: :muted, padding_left: left ? 4 : 0, padding_right: right ? 4 : 0,
            cells: Zaniah::Unicode.width(label) + (left ? 1 : 0) + (right ? 1 : 0)}
          sequence += 1
          Decoration::Item.new(:inline, offset...offset, row, label, style, 20 + sequence, :inlay_hint, click)
        end
      rescue KeyError, RangeError, TypeError, Sadr::Error => error
        raise Error, "invalid inlay hint: #{error.message}"
      end
    end

    def truncate_inlay_label(label, maximum)
      parts = label.is_a?(String) ? [{"value" => label}] : label
      unless parts.is_a?(Array) && parts.length <= 10_000 &&
          parts.all? { |part| part.is_a?(Hash) && part["value"].is_a?(String) && part["value"].valid_encoding? }
        raise Error, "invalid inlay hint label"
      end

      clusters = []
      parts.each_with_index do |part, index|
        part["value"].each_grapheme_cluster do |cluster|
          clusters << [cluster, part["location"], index]
          break if clusters.length > maximum
        end
        break if clusters.length > maximum
      end
      if clusters.length > maximum
        omitted = clusters[maximum - 1]
        clusters = clusters.first(maximum - 1)
        clusters << ["…", omitted[1], omitted[2]]
      end
      clusters.chunk_while { |left, right| left[2] == right[2] }
        .map { |group| [group.map(&:first).join, group.first[1]] }
    end

    def validate_inlay_location(location)
      raise Error, "invalid inlay hint location" unless location.is_a?(Hash)
      Sadr::Protocol.path(location.fetch("uri"))
      Sadr::Protocol.range_value(location.fetch("range"))
    rescue KeyError, Sadr::Error
      raise Error, "invalid inlay hint location"
    end

    def jump_to_language_location(location)
      path = Sadr::Protocol.path(location["uri"] || location.fetch("targetUri"))
      opened = open(path)
      range = location["range"] || location.fetch("targetSelectionRange")
      opened.select(Sadr::Protocol.offset(opened.buffer.rope, range.fetch("start")))
      opened.reveal_cursor
    end

    def build_diagnostic_decorations(buffer)
      settings = @settings["diagnostics"]
      maximum = DIAGNOSTIC_SEVERITIES.fetch(settings["severity"])
      diagnostics = diagnostics_for(buffer).filter_map do |diagnostic|
        severity = diagnostic.fetch("severity", 1)
        next if severity > maximum

        range = diagnostic.fetch("range")
        first = Sadr::Protocol.offset(buffer.rope, range.fetch("start"))
        last = Sadr::Protocol.offset(buffer.rope, range.fetch("end"))
        next if last < first

        row = buffer.rope.point_at(first).row
        [diagnostic, first...last, row, severity]
      rescue KeyError, RangeError, TypeError
        nil
      end
      highlights = diagnostics.map do |_diagnostic, range, _row, severity|
        Decoration::Item.new(:highlight, range, nil, nil,
          {color: DIAGNOSTIC_COLORS.fetch(severity), underline: :wave}, 5 - severity, :diagnostics, nil)
      end
      return highlights unless settings["inline"]

      inlines = diagnostics.group_by { |entry| entry[2] }.map do |row, entries|
        diagnostic, _range, _row, severity = entries.min_by { |entry| entry[3] }
        message = diagnostic.fetch("message").encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
          .gsub(/\s+/, " ").strip
        message = "#{message} (+#{entries.length - 1})" if entries.length > 1
        message = truncate_diagnostic_message(message, settings["inline_max_length"])
        offset = buffer.rope.line_start(row) + buffer.rope.line(row).bytesize
        Decoration::Item.new(:inline, offset...offset, row, message,
          {color: DIAGNOSTIC_COLORS.fetch(severity), padding_left: 8}, 10 + severity, :diagnostics, nil)
      end
      highlights + inlines
    end

    def truncate_diagnostic_message(message, maximum)
      clusters = message.scan(/\X/)
      clusters.length > maximum ? clusters.first(maximum - 1).join + "…" : message
    end

    def diagnostic_item_visible?(buffer, item, rows)
      first = item.row || buffer.rope.point_at(item.range.begin).row
      last = item.kind == :highlight ? buffer.rope.point_at(item.range.end).row : first
      last >= rows.begin && first < rows.end
    rescue RangeError
      false
    end

    def accept_diagnostic_notification(client, params)
      uri = params.fetch("uri")
      entry = @opened_lsp_documents&.keys&.find do |owner, buffer|
        owner.equal?(client) && buffer.path && Sadr::Protocol.uri(buffer.path) == uri
      end
      return unless entry

      buffer = entry.last
      version = params["version"]
      return if version && version != buffer.version
      language = definition_for(buffer.path).name
      return unless route_language_clients(language, language_client_list(language), "diagnostics").include?(client)

      diagnostics = snapshot_lsp_diagnostics(params.fetch("diagnostics"))
      documents = ((@lsp_diagnostics ||= {})[client] ||= {})
      previous = documents[uri]
      documents[uri] = diagnostics
      publish_lsp_diagnostics(uri)
      (@diagnostic_versions ||= {}).tap { |versions| (versions[client] ||= {})[uri] = buffer.version }
      invalidate_diagnostics(buffer)
      @window&.request_frame
    rescue ArgumentError, KeyError, Sadr::Error
      if defined?(documents) && documents
        previous ? documents[uri] = previous : documents.delete(uri)
        @lsp_diagnostics.delete(client) if documents.empty?
      end
      nil
    end

    def snapshot_lsp_diagnostics(diagnostics)
      Sadr::Protocol.diagnostics(diagnostics)
      values = JSON.parse(JSON.generate(diagnostics))
      freeze_value = lambda do |value|
        value.each { |key, child| key.freeze; freeze_value.call(child) } if value.is_a?(Hash)
        value.each { |child| freeze_value.call(child) } if value.is_a?(Array)
        value.freeze
      end
      freeze_value.call(values)
    rescue JSON::GeneratorError, JSON::ParserError, JSON::NestingError
      raise ArgumentError, "invalid diagnostics"
    end
    private :snapshot_lsp_diagnostics

    def cache_code_lenses(client, buffer, version, result, generation)
      raise Error, "invalid code lenses" unless result.nil? || result.is_a?(Array)
      lenses = result || []
      raise Error, "too many code lenses" if lenses.length > 10_000

      entries = lenses.each_with_index.map { |lens, index| validate_code_lens_entry(buffer, lens, index) }.freeze
      cache = @code_lens_cache ||= {}
      cache.delete_if { |key, _| key[0].equal?(client) && key[1].equal?(buffer) && key[2] == version }
      cache.shift while cache.length >= 64
      cache[[client, buffer, version]] = {generation: generation, entries: entries}
      @decorations.invalidate(:code_lens, buffer: buffer)
      @window&.request_frame
    end

    def validate_code_lens_entry(buffer, value, index)
      raise Error, "invalid code lens" unless value.is_a?(Hash)
      encoded = JSON.generate(value)
      raise Error, "code lens exceeds 1 MiB" if encoded.bytesize > 1 << 20
      lens = JSON.parse(encoded)
      range = Sadr::Protocol.range_value(lens.fetch("range"))
      first = Sadr::Protocol.offset(buffer.rope, range.start)
      last = Sadr::Protocol.offset(buffer.rope, range.end)
      unless last >= first && Sadr::Protocol.position(buffer.rope, first) == range.start &&
          Sadr::Protocol.position(buffer.rope, last) == range.end
        raise Error, "invalid code lens range"
      end
      command = validate_code_lens_command(lens["command"])
      disabled = lens["disabled"] || command&.[]("disabled")
      unless disabled.nil? || disabled.is_a?(Hash) && bounded_code_lens_string(disabled["reason"], "disabled reason", empty: true)
        raise Error, "invalid code lens disabled reason"
      end
      {lens: lens.freeze, range: range, row: range.start.line, index: index, command: command,
       disabled: !!disabled, state: command ? :ready : :unresolved}
    rescue JSON::GeneratorError, JSON::ParserError, JSON::NestingError, KeyError, RangeError, TypeError, Sadr::Error => error
      raise Error, "invalid code lens: #{error.message}"
    end

    def validate_code_lens_command(command)
      return unless command
      raise Error, "invalid code lens command" unless command.is_a?(Hash)
      title = bounded_code_lens_string(command["title"], "command title")
      title = title.gsub(/\s+/, " ").strip
      raise Error, "invalid code lens command title" if title.empty?
      title = truncate_diagnostic_message(title, 120).freeze
      name = bounded_code_lens_string(command["command"], "command name")
      arguments = command.fetch("arguments", [])
      raise Error, "too many code lens arguments" unless arguments.is_a?(Array) && arguments.length <= 1_000
      raise Error, "code lens arguments exceed 1 MiB" if JSON.generate(arguments).bytesize > 1 << 20
      command.merge("title" => title, "command" => name, "arguments" => arguments.freeze).freeze
    rescue JSON::GeneratorError, JSON::NestingError => error
      raise Error, "invalid code lens arguments: #{error.message}"
    end

    def bounded_code_lens_string(value, name, empty: false)
      valid = value.is_a?(String) && value.valid_encoding? && value.bytesize <= 4_096 && !value.include?("\0")
      valid &&= !value.empty? unless empty
      raise Error, "invalid code lens #{name}" unless valid
      value.freeze
    end

    def resolve_code_lens_entry(key, cache, entry)
      client, buffer, version = key
      provider = client.capabilities["codeLensProvider"]
      unless provider.is_a?(Hash) && provider["resolveProvider"]
        entry[:state] = :unavailable
        return
      end
      entry[:state] = :resolving
      generation = cache[:generation]
      job = Thread.new do
        begin
          result = client.resolve_code_lens(entry[:lens]).await(timeout: 10)
          post do
            current = @code_lens_cache&.[](key)
            next unless current.equal?(cache) && current[:generation] == generation &&
              buffer.version == version && language_client_active?(client)

            begin
              resolved = validate_code_lens_entry(buffer, entry[:lens].merge(result || {}), entry[:index])
              raise Error, "resolved code lens moved" unless resolved[:range] == entry[:range]
              entry.replace(resolved)
              entry[:state] = :unavailable unless entry[:command]
              @decorations.invalidate(:code_lens, buffer: buffer)
              @window&.request_frame
            rescue StandardError => error
              entry[:state] = :failed
              @message = error.message
              @decorations.invalidate(:code_lens, buffer: buffer)
              @window&.request_frame
            end
          end
        rescue StandardError => error
          post do
            current = @code_lens_cache&.[](key)
            if current.equal?(cache) && current[:generation] == generation
              entry[:state] = :failed
              @message = error.message unless @retired_language_clients&.[](client)
              @decorations.invalidate(:code_lens, buffer: buffer)
              @window&.request_frame
            end
          end
        ensure
          worker = Thread.current
          post { @language_jobs&.delete(worker) }
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
    end

    def execute_code_lens(key, generation, command)
      client, buffer, version = key
      cache = @code_lens_cache&.[](key)
      return false unless cache && cache[:generation] == generation &&
        buffer.version == version && language_client_active?(client) && @settings.for_language(definition_for(buffer.path).name)["code_lens"]["enabled"]

      request = begin
        client.execute_command(command.fetch("command"), arguments: command.fetch("arguments", []))
      rescue StandardError => error
        post { @message = error.message unless @retired_language_clients&.[](client) }
        return true
      end
      job = Thread.new do
        request.await(timeout: 10)
      rescue StandardError => error
        post { @message = error.message unless @retired_language_clients&.[](client) }
      ensure
        worker = Thread.current
        post { @language_jobs&.delete(worker) }
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      true
    end

    public

    def inlay_hint_decorations(buffer, rows)
      active = (@language_clients || {}).values.flatten
      active = @clients.values if active.empty?
      cache = (@inlay_hint_cache || {}).select do |key, _entry|
        key[1].equal?(buffer) && key[2] == buffer.version && active.include?(key[0])
      end
      covered = []
      cache.sort_by { |_key, entry| -entry.first }.flat_map do |key, entry|
        items = entry.last.select { |item| rows.cover?(item.row) && covered.none? { |range| range.cover?(item.row) } }
        covered << (key[3]...key[4])
        items
      end.sort_by { |item| [item.range.begin, item.priority] }.freeze
    end

    def request_inlay_hints(current, visible_rows, start: false)
      @language_jobs&.reject! { |thread| !thread.alive? }
      buffer = current.buffer
      return false unless buffer.path && !buffer.read_only
      unless visible_rows.is_a?(Range) && visible_rows.begin.is_a?(Integer) && visible_rows.end.is_a?(Integer)
        raise ArgumentError, "inlay hint rows must be an integer range"
      end
      first = visible_rows.begin.clamp(0, buffer.line_count)
      last = (visible_rows.exclude_end? ? visible_rows.end : visible_rows.end + 1).clamp(first, buffer.line_count)
      return false if first == last

      language = current.language_document.definition.name
      client = active_language_client(language, "inlayHint")
      return false unless client || start
      return false if client && !client.capabilities["inlayHintProvider"]
      settings = @settings.for_language(language)["inlay_hints"]
      return false unless settings["enabled"]
      unless client
        options = language_server_options(language)
        attempts = @inlay_hint_start_attempts ||= {}
        return false if attempts.key?(language) && attempts[language] == options
        attempts[language] = options
        return false unless options
      end

      requested = [first - 50, 0].max...[last + 50, buffer.line_count].min
      cached = (@inlay_hint_cache || {}).keys.any? do |key|
        (!client || key[0].equal?(client)) && key[1].equal?(buffer) && key[2] == buffer.version &&
          key[3] <= first && key[4] >= last
      end
      pending = (@inlay_hint_requests || {}).values.any? do |entry|
        entry[:buffer].equal?(buffer) && entry[:version] == buffer.version && entry[:generation] == @inlay_hint_generation.to_i &&
          (!client || !entry[:client] || entry[:client].equal?(client)) && entry[:range].begin <= first && entry[:range].end >= last
      end
      return false if cached || pending

      @inlay_hint_request_id = @inlay_hint_request_id.to_i + 1
      id, version, generation = @inlay_hint_request_id, buffer.version, @inlay_hint_generation.to_i
      rope = buffer.rope
      byte_range = rope.line_start(requested.begin)...(requested.end == buffer.line_count ? rope.bytesize : rope.line_start(requested.end))
      protocol_range = Sadr::Protocol.range(rope, byte_range)
      (@inlay_hint_requests ||= {})[id] = {client: client, buffer: buffer, version: version, generation: generation, range: requested}
      job = Thread.new do
        begin
          owner = language_client(buffer, feature: "inlayHint")
          supported = owner.capabilities["inlayHintProvider"]
          valid = buffer.version == version && @inlay_hint_generation.to_i == generation && language_client_active?(owner)
          result = owner.inlay_hint(Sadr::Protocol.uri(buffer.path), protocol_range).await(timeout: 10) if supported && valid
          post do
            @inlay_hint_requests&.delete(id)
            @language_jobs&.reject! { |thread| !thread.alive? }
            next unless supported && valid && @inlay_hint_generation.to_i == generation && language_client_active?(owner)
            next unless buffer.version == version && @panes.any? { |pane| pane.editors.any? { |editor| editor.buffer.equal?(buffer) } }

            cache_inlay_hints(owner, buffer, version, requested, result, id, settings)
          end
        rescue StandardError => error
          post do
            @inlay_hint_requests&.delete(id)
            @language_jobs&.reject! { |thread| !thread.alive? }
            @message = error.message unless owner && @retired_language_clients&.[](owner)
          end
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      true
    end

    def request_visible_inlay_hints(current = editor)
      @inlay_hint_start_attempts&.delete(current.language_document.definition.name)
      map = current.display_map
      first = current.scroll_y.floor.clamp(0, map.row_count - 1)
      last = [first + current.viewport_rows, map.row_count - 1].min
      visible_inlay_hint_ranges(current, first...(last + 1)).map do |rows|
        request_inlay_hints(current, rows, start: true)
      end.any?
    end

    def visible_inlay_hint_ranges(current, display_rows)
      visible_language_ranges(current, display_rows, gap: 101)
    end

    def invalidate_inlay_hints(buffer = nil, client: nil)
      @inlay_hint_generation = @inlay_hint_generation.to_i + 1
      @inlay_hint_cache&.delete_if do |key, _|
        (!buffer || key[1].equal?(buffer)) && (!client || key[0].equal?(client))
      end
      @decorations.invalidate(:inlay_hint, buffer: buffer)
      @window&.request_frame unless @closed
      nil
    end

    def code_lens_decorations(buffer, rows)
      active = (@language_clients || {}).values.flatten
      active = @clients.values if active.empty?
      caches = (@code_lens_cache || {}).select do |key, _cache|
        key[1].equal?(buffer) && key[2] == buffer.version && active.include?(key[0])
      end
      caches.flat_map do |key, cache|
        cache[:entries].filter_map do |entry|
          next unless rows.cover?(entry[:row])
          command = entry[:command]
          next unless command

          click = unless entry[:disabled]
            ->(_editor, _offset) { execute_code_lens(key, cache[:generation], command) }
          end
          Decoration::Item.new(:block, nil, entry[:row], command.fetch("title"),
            {position: :above, color: entry[:disabled] ? :muted : :accent},
            30 + entry[:index], :code_lens, click)
        end
      end.sort_by { |item| [item.row, item.priority] }.freeze
    end

    private def resolve_visible_code_lenses(key, cache, rows)
      return unless cache[:entries].any? { |entry| rows.cover?(entry[:row]) && entry[:state] == :unresolved }

      client = key.first
      resolving = (@code_lens_cache || {}).sum do |candidate, value|
        candidate.first.equal?(client) ? value[:entries].count { |entry| entry[:state] == :resolving } : 0
      end
      cache[:entries].each do |entry|
        next unless rows.cover?(entry[:row]) && entry[:state] == :unresolved
        break if resolving >= CODE_LENS_RESOLVE_LIMIT

        resolve_code_lens_entry(key, cache, entry)
        resolving += 1
      end
    end

    def request_code_lenses(current, visible_rows, start: false)
      @language_jobs&.reject! { |thread| !thread.alive? }
      buffer = current.buffer
      return false unless buffer.path && !buffer.read_only
      unless visible_rows.is_a?(Range) && visible_rows.begin.is_a?(Integer) && visible_rows.end.is_a?(Integer)
        raise ArgumentError, "code lens rows must be an integer range"
      end
      first = visible_rows.begin.clamp(0, buffer.line_count)
      last = (visible_rows.exclude_end? ? visible_rows.end : visible_rows.end + 1).clamp(first, buffer.line_count)
      return false if first == last

      language = current.language_document.definition.name
      client = active_language_client(language, "codeLens")
      return false unless client || start
      provider = client&.capabilities&.[]("codeLensProvider")
      return false if client && provider != true && !provider.is_a?(Hash)
      return false unless @settings.for_language(language)["code_lens"]["enabled"]
      cached = (@code_lens_cache || {}).find do |key, _cache|
        client && key[0].equal?(client) && key[1].equal?(buffer) && key[2] == buffer.version
      end
      generation = @code_lens_generation.to_i
      pending = (@code_lens_requests || {}).values.any? do |entry|
        entry[:buffer].equal?(buffer) && entry[:version] == buffer.version &&
          (!client || !entry[:client] || entry[:client].equal?(client))
      end
      if cached
        resolve_visible_code_lenses(*cached, first...last)
        return false
      end
      return false if pending || (@code_lens_requests || {}).length >= CODE_LENS_REQUEST_LIMIT
      unless client
        options = language_server_options(language)
        attempts = @code_lens_start_attempts ||= {}
        return false if attempts.key?(language) && attempts[language] == options
        attempts[language] = options
        return false unless options
      end

      @code_lens_request_id = @code_lens_request_id.to_i + 1
      id, version = @code_lens_request_id, buffer.version
      request = {client: client, buffer: buffer, version: version, generation: generation}
      (@code_lens_requests ||= {})[id] = request
      job = Thread.new do
        begin
          owner = language_client(buffer, feature: "codeLens")
          request[:client] = owner
          capability = owner.capabilities["codeLensProvider"]
          supported = capability == true || capability.is_a?(Hash)
          valid = buffer.version == version && language_client_active?(owner) && @code_lens_requests&.[](id).equal?(request)
          result = owner.code_lens(Sadr::Protocol.uri(buffer.path)).await(timeout: 10) if supported && valid
          post do
            pending = @code_lens_requests&.delete(id)
            @language_jobs&.reject! { |thread| !thread.alive? }
            next unless pending.equal?(request) && supported && valid && language_client_active?(owner)
            next unless buffer.version == version && @panes.any? { |pane| pane.editors.any? { |editor| editor.buffer.equal?(buffer) } }

            begin
              cache_code_lenses(owner, buffer, version, result, generation)
            rescue StandardError => error
              cache_code_lenses(owner, buffer, version, [], generation)
              @message = error.message
            end
          end
        rescue StandardError => error
          post do
            pending = @code_lens_requests&.delete(id)
            @language_jobs&.reject! { |thread| !thread.alive? }
            @code_lens_start_attempts&.delete(language) unless client
            if pending.equal?(request) && owner && language_client_active?(owner) && buffer.version == version &&
                @panes.any? { |pane| pane.editors.any? { |editor| editor.buffer.equal?(buffer) } }
              cache_code_lenses(owner, buffer, version, [], generation)
            end
            @message = error.message if pending.equal?(request) && !(owner && @retired_language_clients&.[](owner))
          end
        ensure
          worker = Thread.current
          post { @language_jobs&.delete(worker) }
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      true
    end

    def request_visible_code_lenses(current = editor)
      @code_lens_start_attempts&.delete(current.language_document.definition.name)
      map = current.display_map
      first = current.scroll_y.floor.clamp(0, map.row_count - 1)
      last = [first + current.viewport_rows, map.row_count - 1].min
      visible_code_lens_ranges(current, first...(last + 1)).map do |rows|
        request_code_lenses(current, rows, start: true)
      end.any?
    end

    def visible_code_lens_ranges(current, display_rows)
      visible_language_ranges(current, display_rows, gap: 1)
    end

    def invalidate_code_lenses(buffer = nil, client: nil)
      @code_lens_generation = @code_lens_generation.to_i + 1
      @code_lens_cache&.delete_if do |key, _|
        (!buffer || key[1].equal?(buffer)) && (!client || key[0].equal?(client))
      end
      @code_lens_requests&.delete_if do |_id, entry|
        (!buffer || entry[:buffer].equal?(buffer)) && (!client || entry[:client]&.equal?(client))
      end
      @decorations.invalidate(:code_lens, buffer: buffer)
      @window&.request_frame unless @closed
      nil
    end

    def bracket_decorations(buffer, rows, current)
      return [] unless current.is_a?(Editor) && current.buffer.equal?(buffer)
      return [] if buffer.rope.respond_to?(:lazy?) && buffer.rope.lazy?

      values = @settings.for_language(current.language_document.definition.name)
      colorize = values["bracket_colorization"]
      guides = values["indent_guides"]
      return [] unless colorize || guides["enabled"]

      items = colorize ? current.language_document.brackets(rows).flat_map do |pair|
        style = {color: :"bracket.#{pair.depth % 6 + 1}", foreground: true}.freeze
        [pair.open_row, pair.close_row].zip([pair.open_range, pair.close_range]).filter_map do |row, range|
          Decoration::Item.new(:highlight, range, row, nil, style, 15 + pair.depth, :bracket, nil) if rows.cover?(row)
        end
      end : []
      return items.freeze unless guides["enabled"]

      active = active_structure_guide(current, guides["active"])
      first = rows.begin.clamp(0, buffer.line_count)
      last = (rows.exclude_end? ? rows.end : rows.end + 1).clamp(first, buffer.line_count)
      guide_count = 0
      (first...last).each do |row|
        start = buffer.rope.line_start(row)
        indentation_offsets(buffer.line(row), current.tab_size, limit: INDENT_GUIDE_LIMIT - guide_count).each do |column, offset|
          highlighted = active && row > active[:start_line] && row <= active[:end_line] && column == active[:column]
          style = {guide: true, active: !!highlighted,
            color: highlighted ? :"indent.guide.active" : :"indent.guide"}.freeze
          items << Decoration::Item.new(:highlight, (start + offset...start + offset), row, nil,
            style, highlighted ? 13 : 2, :bracket, nil)
          guide_count += 1
        end
        # ponytail: one viewport never needs more than this; paginate if deeply indented generated files become common.
        break if guide_count >= INDENT_GUIDE_LIMIT
      end
      items.freeze
    end

    def invalidate_brackets(buffer = nil)
      @decorations.invalidate(:bracket, buffer: buffer)
      @window&.request_frame unless @closed
      nil
    end

    def sticky_scroll_enabled?(current)
      language_setting(current, "sticky_scroll", "enabled")
    end

    def breadcrumbs_enabled?(current)
      language_setting(current, "breadcrumbs", "enabled")
    end

    def sticky_context(current, display_row)
      return [] unless sticky_scroll_enabled?(current)

      map = current.display_map
      first = display_row.clamp(0, map.row_count - 1)
      entry = document_symbol_entry(current)
      return [] unless entry
      top = map.to_buffer(DisplayPoint.new(first, 0))
      maximum = language_setting(current, "sticky_scroll", "max_lines")
      context_key = [entry[:generation], map.tree.object_id, first, top, maximum]
      contexts = @sticky_context_cache ||= {}
      return contexts[context_key] if contexts.key?(context_key)

      result = document_symbol_chain(current, top)
        .select { |symbol| map.to_display(symbol.selection.begin).row < first }
        .last(maximum).freeze
      contexts.shift while contexts.length >= 256
      contexts[context_key] = result
    end

    # Returns cached symbols containing the byte offset, outermost first. This
    # never asks a language server or parser to do work and is safe during paint.
    def document_symbol_chain(current, offset)
      entry = document_symbol_entry(current)
      return [] unless entry && offset.is_a?(Integer) && offset.between?(0, current.buffer.rope.bytesize)

      result = []
      parent_id = nil
      while (symbol = containing_document_symbol(entry, parent_id, offset))
        result << symbol
        parent_id = symbol.id
      end
      result.freeze
    end

    # Breadcrumb navigation consumes the already-indexed sibling list.
    # Generation invalidates navigation as soon as its cache is replaced.
    def document_symbol_siblings(current, symbol, generation:)
      entry = document_symbol_entry(current)
      return [] unless entry && entry[:generation] == generation && entry[:by_id][symbol.id].equal?(symbol)

      entry[:children][symbol.parent_id] || []
    end

    def document_symbol_generation(current)
      document_symbol_entry(current)&.dig(:generation)
    end

    def breadcrumb_context(current)
      return unless breadcrumbs_enabled?(current)
      path = current.buffer.path
      return unless path

      entry = document_symbol_entry(current)
      chain = entry ? document_symbol_chain(current, current.primary.head) : []
      symbols = if chain.any? { |symbol| symbol.kind == :structure }
        chain.last(2)
      else
        container = chain.reverse.find { |symbol| BREADCRUMB_CONTAINER_KINDS.include?(symbol.kind) }
        callable = chain.reverse.find { |symbol| BREADCRUMB_CALLABLE_KINDS.include?(symbol.kind) }
        [container, callable].compact.uniq.sort_by(&:depth)
      end
      prefix = @root + File::SEPARATOR
      relative = path.start_with?(prefix) ? path.delete_prefix(prefix) : File.basename(path)
      project_path = relative if path.start_with?(prefix)
      items = [{kind: :path, label: relative.freeze, value: project_path&.freeze}.freeze]
      items.concat(symbols.map { |symbol| {kind: :symbol, label: symbol.name, value: symbol}.freeze })
      {buffer: current.buffer, document: current.language_document, path: path, version: current.buffer.version,
       client: active_language_client(current.language_document.definition.name, "documentSymbol"),
       generation: entry&.dig(:generation), items: items.freeze}.freeze
    end

    def minimap_settings(current)
      @settings["minimap"].merge(
        @settings["languages"].fetch(current.language_document.definition.name, {}).fetch("minimap", {})
      )
    end

    def show_breadcrumb_menu(pane, current, item, context)
      return false unless breadcrumb_context_valid?(pane, current, context) && context[:items].any? { |entry| entry.equal?(item) }

      activate_tab(pane, current)
      if item[:kind] == :path
        source = item[:value]
        return false unless source
        directory = File.dirname(source)
        values = files.select { |path| File.dirname(path) == directory }
        labels = values
      else
        source = item[:value]
        values = document_symbol_siblings(current, source, generation: context[:generation])
          .select { |symbol| breadcrumb_symbol_category(symbol) == breadcrumb_symbol_category(source) }
        labels = breadcrumb_symbol_labels(current.buffer, values)
      end
      return false if values.empty?

      self.palette = {kind: :breadcrumbs, query: +"", index: 0, matches: labels, items: values,
        breadcrumb_kind: item[:kind], breadcrumb_source: item, breadcrumb_context: context,
        breadcrumb_editor: current, breadcrumb_pane: pane}
      update_palette
      true
    end

    def refresh_sticky_fallback(current, document = current.language_document)
      return [] unless (sticky_scroll_enabled?(current) || breadcrumbs_enabled?(current)) &&
        document.equal?(current.language_document) && document.syntax_ready?

      buffer = current.buffer
      regions = document.structure_regions
      cached = @sticky_fallback_cache&.[](current)
      return cached.last[:symbols] if cached && cached[0] == buffer.version && cached[1].equal?(document) && cached[2].equal?(regions)

      rope = buffer.rope
      drafts = regions.first(STICKY_SYMBOL_LIMIT).filter_map do |region|
        first, last, kind = region.values_at(:start_line, :end_line, :kind)
        next unless %i[block region].include?(kind) && first.is_a?(Integer) && last.is_a?(Integer) &&
          first >= 0 && last > first && last < buffer.line_count

        start = rope.line_start(first)
        finish = last + 1 < buffer.line_count ? rope.line_start(last + 1) : rope.bytesize
        label = sticky_source_label(rope, first)
        label = "Line #{first + 1}" if label.empty?
        [truncate_diagnostic_message(label, 256).freeze, (start...finish).freeze, (start...start).freeze]
      end.uniq { |_name, range, _selection| [range.begin, range.end] }
        .sort_by { |_name, range, _selection| [range.begin, -range.end] }
      parents = []
      values = drafts.each_with_index.map do |(name, range, selection), id|
        parents.pop until parents.empty? || strictly_contains?(parents.last.range, range)
        parent = parents.last
        symbol = Language::DocumentSymbol.new(id, name, :structure, range, selection,
          parent ? parent.depth + 1 : 0, parent&.id)
        parents << symbol
        symbol
      end.freeze
      entry = sticky_cache_entry(buffer, buffer.version, nil, values)
      @sticky_fallback_cache ||= {}
      @sticky_fallback_cache[current] = [buffer.version, document, regions, entry]
      @sticky_context_cache&.clear
      values
    end

    def request_sticky_symbols(current)
      return false unless sticky_scroll_enabled?(current) || breadcrumbs_enabled?(current)

      buffer = current.buffer
      return false unless buffer.path && !buffer.read_only
      language = current.language_document.definition.name
      client = active_language_client(language, "documentSymbol")
      cache = @sticky_symbol_cache || {}
      return false if client && cache.key?([client, buffer, buffer.version])
      return false if client && !client.capabilities["documentSymbolProvider"]

      requests = @sticky_symbol_requests ||= {}
      return false if requests.values.any? { |entry| entry[:buffer].equal?(buffer) && entry[:version] == buffer.version }
      return false if requests.length >= STICKY_REQUEST_LIMIT
      unless client
        options = language_server_options(language)
        attempts = @sticky_symbol_start_attempts ||= {}
        return false if attempts.key?(language) && attempts[language] == options
        attempts[language] = options
        return false unless options
      end

      id = @sticky_symbol_request_id = @sticky_symbol_request_id.to_i + 1
      request = {client: client, buffer: buffer, version: buffer.version,
        rope: buffer.rope, uri: Sadr::Protocol.uri(buffer.path)}
      requests[id] = request
      job = Thread.new do
        begin
          owner = language_client(buffer, feature: "documentSymbol")
          request[:client] = owner
          supported = !!owner.capabilities["documentSymbolProvider"]
          active = @sticky_symbol_requests&.[](id).equal?(request) && buffer.version == request[:version] && language_client_active?(owner)
          future = owner.document_symbol(request[:uri]) if supported && active
          request[:future] = future
          if future && @sticky_symbol_requests&.[](id).equal?(request)
            symbols = normalize_document_symbols(request[:rope], future.await(timeout: 10), request[:uri])
          else
            future&.cancel
            symbols = false
          end
          post do
            pending = @sticky_symbol_requests&.delete(id)
            next unless pending.equal?(request) && buffer.version == request[:version] && language_client_active?(owner) &&
              buffer.path && Sadr::Protocol.uri(buffer.path) == request[:uri] &&
              @opened_lsp_documents&.key?([owner, buffer]) &&
              @panes.any? { |pane| pane.editors.any? { |editor| editor.buffer.equal?(buffer) } }

            cache_sticky_symbols(owner, buffer, request[:version], symbols)
          end
        rescue StandardError => error
          post do
            pending = @sticky_symbol_requests&.delete(id)
            if pending.equal?(request) && owner && buffer.version == request[:version] && language_client_active?(owner) &&
                buffer.path && Sadr::Protocol.uri(buffer.path) == request[:uri] && @opened_lsp_documents&.key?([owner, buffer])
              cache_sticky_symbols(owner, buffer, request[:version], false)
              @message = error.message unless @retired_language_clients&.[](owner)
            end
          end
        ensure
          worker = Thread.current
          post { @language_jobs&.delete(worker) }
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      true
    end

    def invalidate_sticky_symbols(buffer = nil, client: nil)
      @sticky_symbol_cache&.delete_if do |key, _|
        (!buffer || key[1].equal?(buffer)) && (!client || key[0].equal?(client))
      end
      @sticky_symbol_requests&.delete_if do |_id, entry|
        matches = (!buffer || entry[:buffer].equal?(buffer)) && (!client || entry[:client]&.equal?(client))
        entry[:future]&.cancel if matches
        matches
      end
      @sticky_fallback_cache&.delete_if { |editor, _| editor.buffer.equal?(buffer) } if buffer
      @sticky_fallback_cache&.clear unless buffer || client
      @sticky_context_cache&.clear
      @sticky_symbol_start_attempts&.clear unless buffer || client
      @window&.request_frame unless @closed
      nil
    end

    private

    def containing_document_symbol(entry, parent_id, offset)
      siblings = entry[:children][parent_id] || []
      index = siblings.bsearch_index { |candidate| candidate.range.begin > offset } || siblings.length
      candidate = siblings[index - 1] if index.positive?
      candidate if candidate && offset < candidate.range.end
    end

    def breadcrumb_context_valid?(pane, current, context)
      return false if @closed || !context.is_a?(Hash) || !@panes.include?(pane) || !pane.active.equal?(current)
      return false unless context[:buffer].equal?(current.buffer) && context[:document].equal?(current.language_document) &&
        context[:path] == current.buffer.path && context[:version] == current.buffer.version

      entry = document_symbol_entry(current)
      active_client = active_language_client(current.language_document.definition.name, "documentSymbol")
      return false unless context[:client].equal?(active_client) && context[:generation] == entry&.dig(:generation)
      client = context[:client]
      !client || language_client_active?(client) && client.running? && @opened_lsp_documents&.key?([client, current.buffer])
    end

    def breadcrumb_symbol_category(symbol)
      return :container if BREADCRUMB_CONTAINER_KINDS.include?(symbol.kind)
      return :callable if BREADCRUMB_CALLABLE_KINDS.include?(symbol.kind)

      symbol.kind
    end

    def breadcrumb_symbol_labels(buffer, symbols)
      labels = symbols.map do |symbol|
        point = buffer.rope.point_at(symbol.selection.begin)
        "#{symbol.name} — #{point.row + 1}:#{point.column + 1}"
      end
      duplicates = labels.tally
      labels.each_with_index.map { |label, index| duplicates[label] > 1 ? "#{label} ##{symbols[index].id}" : label }.freeze
    end

    def accept_breadcrumb_palette(state, index)
      item = index && state[:items][index]
      context = state[:breadcrumb_context]
      current = state[:breadcrumb_editor]
      pane = state[:breadcrumb_pane]
      return false unless item && breadcrumb_context_valid?(pane, current, context)

      if state[:breadcrumb_kind] == :path
        source = state.dig(:breadcrumb_source, :value)
        return false unless item.is_a?(String) && source && File.dirname(item) == File.dirname(source)
        absolute = @project.path(item)
        return false unless File.file?(absolute)
        activate_tab(pane, current)
        open(item)
      else
        source = state.dig(:breadcrumb_source, :value)
        siblings = document_symbol_siblings(current, source, generation: context[:generation])
        return false unless item.is_a?(Language::DocumentSymbol) && siblings.any? { |symbol| symbol.equal?(item) } &&
          breadcrumb_symbol_category(item) == breadcrumb_symbol_category(source)
        activate_tab(pane, current)
        current.select(item.selection.begin)
        current.reveal_cursor
      end
      true
    end

    def document_symbol_entry(current)
      buffer = current.buffer
      client = active_language_client(current.language_document.definition.name, "documentSymbol")
      key = [client, buffer, buffer.version]
      cache = @sticky_symbol_cache || {}
      return cache[key] if client && cache.key?(key) && cache[key]

      fallback = @sticky_fallback_cache&.[](current)
      fallback.last if fallback && fallback[0] == buffer.version && fallback[1].equal?(current.language_document)
    end

    def language_setting(current, group, key)
      defaults = @settings[group]
      override = @settings["languages"].fetch(current.language_document.definition.name, {}).fetch(group, {})
      override.fetch(key, defaults.fetch(key))
    end

    def sticky_source_label(rope, row)
      first = rope.line_start(row)
      last = row + 1 < rope.line_count ? rope.line_start(row + 1) : rope.bytesize
      ending = [last, first + 4_096].min
      begin
        rope.point_at(ending)
      rescue RangeError
        ending -= 1
        retry
      end
      rope.byteslice(first, ending - first).to_s
        .sub(/(?:\r\n|[\r\n\u2028\u2029])\z/, "").strip
    end

    def normalize_document_symbols(rope, result, uri)
      raise Error, "invalid document symbols" unless result.nil? || result.is_a?(Array)
      raise Error, "too many document symbols" if result && result.length > STICKY_SYMBOL_LIMIT
      items = Array(result)
      raise Error, "invalid document symbol" if items.any? { |item| !item.is_a?(Hash) }
      flat = items.first&.key?("location")
      if items.any? { |item| item.key?("location") != flat }
        raise Error, "invalid mixed document symbols"
      end
      return normalize_flat_document_symbols(rope, items, uri) if flat

      stack = items.reverse.map { |item| [item, 0, nil] }
      symbols, seen = [], {}.compare_by_identity
      until stack.empty?
        item, depth, parent_id = stack.pop
        raise Error, "too many document symbols" if symbols.length >= STICKY_SYMBOL_LIMIT
        raise Error, "document symbol nesting exceeds #{STICKY_DEPTH_LIMIT}" if depth > STICKY_DEPTH_LIMIT
        raise Error, "invalid document symbol" unless item.is_a?(Hash)
        raise Error, "cyclic document symbols" if seen.key?(item)
        seen[item] = true

        name = bounded_sticky_string(item["name"], "name")
        kind = sticky_symbol_kind(item["kind"])
        bounded_sticky_string(item["detail"], "detail", optional: true)
        range = strict_symbol_range(rope, item["range"])
        selection = strict_symbol_range(rope, item["selectionRange"])
        unless range.begin <= selection.begin && selection.end <= range.end
          raise Error, "document symbol selection is outside its range"
        end
        parent = symbols[parent_id] if parent_id
        unless !parent || parent.range.begin <= range.begin && range.end <= parent.range.end
          raise Error, "document symbol is outside its parent"
        end
        id = symbols.length
        symbols << Language::DocumentSymbol.new(id, name, kind, range, selection, depth, parent_id)
        children = item.fetch("children", [])
        raise Error, "invalid document symbol children" unless children.is_a?(Array)
        raise Error, "too many document symbols" if symbols.length + stack.length + children.length > STICKY_SYMBOL_LIMIT
        children.reverse_each { |child| stack << [child, depth + 1, id] }
      end
      validate_document_symbol_siblings!(symbols)
    rescue KeyError, RangeError, TypeError, ArgumentError, Sadr::Error => error
      raise Error, "invalid document symbols: #{error.message}"
    end

    def normalize_flat_document_symbols(rope, items, uri)
      drafts = items.each_with_index.map do |item, index|
        lookup_name = bounded_sticky_string(item["name"], "name", truncate: false)
        name = truncate_diagnostic_message(lookup_name, 256).freeze
        kind = sticky_symbol_kind(item["kind"])
        container = bounded_sticky_string(item["containerName"], "container name", optional: true, truncate: false)
        location = item["location"]
        raise Error, "invalid document symbol location" unless location.is_a?(Hash)
        bounded_sticky_string(location["uri"], "URI", maximum: 16_384)
        raise Error, "document symbol belongs to another document" unless location["uri"] == uri
        range = strict_symbol_range(rope, location["range"])
        {name: name, lookup_name: lookup_name, kind: kind, selection: range, container: container, index: index}
      end.sort_by { |draft| [draft[:selection].begin, -draft[:selection].end, draft[:index]] }

      parents, seen = [], Hash.new { |hash, name| hash[name] = [] }
      drafts.each_with_index do |draft, id|
        parents.pop until parents.empty? || strictly_contains?(drafts[parents.last][:selection], draft[:selection])
        parent_id = draft[:container] && seen[draft[:container]].last
        parent_id ||= parents.last
        draft[:id], draft[:parent_id] = id, parent_id
        draft[:depth] = parent_id ? drafts[parent_id][:depth] + 1 : 0
        raise Error, "document symbol nesting exceeds #{STICKY_DEPTH_LIMIT}" if draft[:depth] > STICKY_DEPTH_LIMIT
        parents << id
        seen[draft[:lookup_name]] << id
      end

      following = []
      scopes = Array.new(drafts.length)
      (drafts.length - 1).downto(0) do |id|
        draft = drafts[id]
        following.pop while following.any? && drafts[following.last][:depth] > draft[:depth]
        finish = following.empty? ? rope.bytesize : drafts[following.last][:selection].begin
        finish = draft[:selection].end unless finish > draft[:selection].begin
        scopes[id] = (draft[:selection].begin...finish).freeze
        following << id
      end
      symbols = drafts.map do |draft|
        Language::DocumentSymbol.new(draft[:id], draft[:name], draft[:kind], scopes[draft[:id]], draft[:selection],
          draft[:depth], draft[:parent_id])
      end
      validate_document_symbol_siblings!(symbols)
    end

    def sticky_symbol_kind(value)
      raise Error, "invalid document symbol kind" unless value.is_a?(Integer) && value.between?(1, 26)

      value
    end

    def strictly_contains?(outer, inner)
      outer.begin <= inner.begin && inner.end <= outer.end && outer != inner
    end

    def validate_document_symbol_siblings!(symbols)
      by_id = symbols.to_h { |symbol| [symbol.id, symbol] }
      symbols.each do |symbol|
        parent = by_id[symbol.parent_id]
        next unless parent
        unless parent.range.begin <= symbol.range.begin && symbol.range.end <= parent.range.end
          raise Error, "document symbol is outside its parent"
        end
      end
      symbols.group_by(&:parent_id).each_value do |siblings|
        siblings.sort_by { |symbol| [symbol.range.begin, symbol.range.end, symbol.id] }.each_cons(2) do |left, right|
          raise Error, "overlapping document symbol siblings" if left.range.end > right.range.begin
        end
      end
      symbols.freeze
    end

    def bounded_sticky_string(value, name, optional: false, maximum: 4_096, truncate: true)
      return if optional && value.nil?
      unless value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, maximum) && !value.include?("\0")
        raise Error, "invalid document symbol #{name}"
      end
      value = value.dup.freeze
      truncate ? truncate_diagnostic_message(value, 256).freeze : value
    end

    def strict_symbol_range(rope, value)
      strict_language_range(rope, value, "document symbol")
    end

    def strict_language_range(rope, value, label, allow_empty: true)
      range = Sadr::Protocol.range_value(value)
      first = Sadr::Protocol.offset(rope, range.start)
      last = Sadr::Protocol.offset(rope, range.end)
      unless last >= first && (allow_empty || last > first) && Sadr::Protocol.position(rope, first) == range.start &&
          Sadr::Protocol.position(rope, last) == range.end
        raise Error, "invalid #{label} range"
      end
      (first...last).freeze
    end

    def normalize_prepare_rename(rope, offset, result)
      return if result.nil?

      keys = result.keys.map(&:to_s) if result.is_a?(Hash) && result.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }
      raise Error, "invalid prepare rename response" if keys && keys.uniq.length != keys.length
      value = ->(key) { result.key?(key) ? result[key] : result[key.to_sym] }
      placeholder = if keys == ["defaultBehavior"]
        behavior = value.call("defaultBehavior")
        raise Error, "invalid prepare rename default behavior" unless behavior == true || behavior == false
        point = rope.point_at(offset)
        line_start = rope.line_start(point.row)
        line_end = point.row + 1 < rope.line_count ? rope.line_start(point.row + 1) : rope.bytesize
        before = rope.byteslice(line_start...offset).to_s[/[[:alnum:]_]*\z/].to_s
        after = rope.byteslice(offset...line_end).to_s[/\A[[:alnum:]_]*/].to_s
        before + after
      elsif keys&.sort == %w[placeholder range]
        range = strict_language_range(rope, value.call("range"), "prepare rename", allow_empty: false)
        raise Error, "invalid prepare rename position" unless range.cover?(offset)
        value.call("placeholder")
      elsif result.is_a?(Sadr::Range_) || keys&.sort == %w[end start]
        range = strict_language_range(rope, result, "prepare rename", allow_empty: false)
        raise Error, "invalid prepare rename position" unless range.cover?(offset)
        rope.byteslice(range).to_s
      else
        raise Error, "invalid prepare rename response"
      end
      unless valid_rename_value?(placeholder) && placeholder.bytesize <= RENAME_VALUE_LIMIT
        raise Error, "invalid prepare rename placeholder"
      end
      placeholder.dup.freeze
    rescue KeyError, RangeError, TypeError, ArgumentError, Sadr::Error => error
      raise Error, "invalid prepare rename response: #{error.message}"
    end

    def normalize_document_highlights(rope, result)
      raise Error, "invalid document highlights" unless result.nil? || result.is_a?(Array)
      raise Error, "too many document highlights" if result && result.length > DOCUMENT_HIGHLIGHT_LIMIT

      Array(result).map do |item|
        raise Error, "invalid document highlight" unless item.is_a?(Hash)
        kind = item.fetch("kind", 1)
        raise Error, "invalid document highlight kind" unless DOCUMENT_HIGHLIGHT_STYLES.key?(kind)
        range = strict_language_range(rope, item.fetch("range"), "document highlight", allow_empty: false)
        Decoration::Item.new(:highlight, range, nil, nil, DOCUMENT_HIGHLIGHT_STYLES.fetch(kind), 20, :document_highlight, nil)
      end.freeze
    rescue KeyError, RangeError, TypeError, ArgumentError, Sadr::Error => error
      raise Error, "invalid document highlights: #{error.message}"
    end

    def normalize_document_links(rope, result, resolve:)
      raise Error, "invalid document links" unless result.nil? || result.is_a?(Array)
      raise Error, "too many document links" if result && result.length > DOCUMENT_LINK_LIMIT

      links = Array(result).each_with_index.map do |value, index|
        validate_document_link_entry(rope, value, index, resolve: resolve)
      end.sort_by { |entry| [entry[:range].begin, entry[:range].end] }
      links.each_cons(2) do |left, right|
        raise Error, "overlapping document links" if left[:range].end > right[:range].begin
      end
      links.freeze
    rescue JSON::GeneratorError, JSON::ParserError, JSON::NestingError, KeyError, RangeError, TypeError,
      ArgumentError, Sadr::Error => error
      raise Error, "invalid document links: #{error.message}"
    end

    def validate_document_link_entry(rope, value, index, resolve:)
      raise Error, "invalid document link" unless value.is_a?(Hash)
      encoded = JSON.generate(value)
      raise Error, "document link exceeds 1 MiB" if encoded.bytesize > 1 << 20
      link = JSON.parse(encoded)
      range = strict_language_range(rope, link.fetch("range"), "document link", allow_empty: false)
      target = document_link_target(link["target"]) if link.key?("target")
      raise Error, "document link has no target" unless target || resolve
      tooltip = link["tooltip"]
      unless tooltip.nil? || bounded_document_link_text?(tooltip)
        raise Error, "invalid document link tooltip"
      end
      {link: link.freeze, range: range, target: target, tooltip: tooltip&.dup&.freeze,
       index: index, state: target ? :ready : :unresolved}
    end

    def normalize_linked_editing_ranges(rope, offset, selection, result)
      return if result.nil?
      unless result.is_a?(Hash) && result.keys.all? { |key| key.is_a?(String) } &&
          (result.keys - %w[ranges wordPattern]).empty? && result["ranges"].is_a?(Array)
        raise Error, "invalid linked editing response"
      end
      values = result.fetch("ranges")
      raise Error, "too many linked editing ranges" if values.length > LINKED_EDITING_RANGE_LIMIT
      ranges = values.map do |value|
        strict_language_range(rope, value, "linked editing", allow_empty: false)
      end.sort_by { |range| [range.begin, range.end] }
      ranges.each_cons(2) do |left, right|
        raise Error, "overlapping linked editing ranges" if left.end > right.begin
      end
      return {ranges: [].freeze, source: nil, pattern: nil}.freeze if ranges.empty?
      source = ranges.find do |range|
        selection.empty? ? range.cover?(offset) : range.begin <= selection.start && selection.end <= range.end
      end
      unless source && source.begin <= selection.start && selection.end <= source.end
        raise Error, "linked editing ranges do not contain the selection"
      end
      pattern = result["wordPattern"]
      if pattern
        unless pattern.is_a?(String) && pattern.encoding == Encoding::UTF_8 && pattern.valid_encoding? &&
            pattern.bytesize.between?(1, LINKED_EDITING_PATTERN_LIMIT) && !pattern.include?("\0")
          raise Error, "invalid linked editing word pattern"
        end
        Regexp.new(pattern)
      end
      {ranges: ranges.freeze, source: source, pattern: pattern&.dup&.freeze}.freeze
    rescue RegexpError, KeyError, RangeError, TypeError, ArgumentError, Sadr::Error => error
      raise Error, "invalid linked editing response: #{error.message}"
    end

    def normalize_folding_ranges(rope, result)
      return nil if result.nil?
      raise Error, "invalid folding ranges" unless result.is_a?(Array)
      raise Error, "too many folding ranges" if result.length > FOLDING_RANGE_LIMIT

      result.map do |item|
        raise Error, "invalid folding range" unless item.is_a?(Hash)
        first_row, last_row = item.fetch("startLine"), item.fetch("endLine")
        unless first_row.is_a?(Integer) && last_row.is_a?(Integer) &&
            first_row.between?(0, 0x7fffffff) && last_row.between?(first_row, 0x7fffffff) &&
            last_row < rope.line_count
          raise Error, "invalid folding range lines"
        end
        first = folding_position(rope, first_row, item["startCharacter"], item.key?("startCharacter"))
        last = folding_position(rope, last_row, item["endCharacter"], item.key?("endCharacter"))
        raise Error, "invalid folding range bounds" unless first < last
        (first...last).freeze
      end.uniq.sort_by { |range| [range.begin, -range.end] }.freeze
    rescue KeyError, RangeError, TypeError, ArgumentError, Sadr::Error => error
      raise Error, "invalid folding ranges: #{error.message}"
    end

    def normalize_selection_ranges(rope, positions, result)
      return nil if result.nil?
      unless result.is_a?(Array) && result.length == positions.length
        raise Error, "invalid selection ranges"
      end

      total = 0
      result.zip(positions).map do |root, position|
        node, child, depth, ranges = root, nil, 0, []
        loop do
          unless node.is_a?(Hash) && depth < SELECTION_RANGE_DEPTH_LIMIT
            raise Error, "invalid selection range chain"
          end
          range = strict_language_range(rope, node.fetch("range"), "selection")
          unless range.begin <= position && position <= range.end &&
              (!child || range.begin <= child.begin && child.end <= range.end)
            raise Error, "invalid selection range nesting"
          end
          ranges << range unless ranges.last == range
          total += 1
          raise Error, "too many selection ranges" if total > SELECTION_RANGE_LIMIT
          break unless node.key?("parent")
          node, child, depth = node["parent"], range, depth + 1
        end
        ranges.freeze
      end.freeze
    rescue KeyError, RangeError, TypeError, ArgumentError, Sadr::Error => error
      raise Error, "invalid selection ranges: #{error.message}"
    end

    def normalize_antares_selection_ranges(rope, positions, result)
      unless result.is_a?(Array) && result.length == positions.length
        raise Error, "invalid Antares selection ranges"
      end
      total = 0
      result.zip(positions).map do |ranges, position|
        child = nil
        unless ranges.is_a?(Array) && ranges.length <= SELECTION_RANGE_DEPTH_LIMIT
          raise Error, "invalid Antares selection range chain"
        end
        ranges.map do |range|
          unless range.is_a?(Range) && range.exclude_end? && range.begin.is_a?(Integer) && range.end.is_a?(Integer) &&
              range.begin >= 0 && range.end >= range.begin
            raise Error, "invalid Antares selection range"
          end
          rope.point_at(range.begin)
          rope.point_at(range.end)
          unless range.begin <= position && position <= range.end &&
              (!child || range.begin <= child.begin && child.end <= range.end)
            raise Error, "invalid Antares selection range nesting"
          end
          child = range
          total += 1
          raise Error, "too many Antares selection ranges" if total > SELECTION_RANGE_LIMIT
          range.freeze
        end.uniq.freeze
      end.freeze
    rescue RangeError, TypeError, ArgumentError => error
      raise Error, "invalid Antares selection ranges: #{error.message}"
    end

    def folding_position(rope, row, character, present)
      point = if !present
        Sadr::Protocol.position(rope, rope.line_start(row) + rope.line(row).bytesize)
      else
        raise Error, "invalid folding range character" unless character.is_a?(Integer) && character.between?(0, 0x7fffffff)
        Sadr::Position.new(line: row, character: character)
      end
      offset = Sadr::Protocol.offset(rope, point)
      raise Error, "invalid folding range character" unless Sadr::Protocol.position(rope, offset) == point
      offset
    end

    def document_link_target(value)
      unless bounded_document_link_text?(value, maximum: DOCUMENT_LINK_URI_LIMIT)
        raise Error, "invalid document link target"
      end
      uri = URI::DEFAULT_PARSER.parse(value)
      case uri.scheme&.downcase
      when "http", "https"
        raise Error, "invalid document link target" unless uri.host && !uri.host.empty?
      when "file"
        Sadr::Protocol.path(value)
      else
        raise Error, "unsafe document link target"
      end
      value.dup.freeze
    rescue URI::InvalidURIError => error
      raise Error, "invalid document link target: #{error.message}"
    end

    def bounded_document_link_text?(value, maximum: DOCUMENT_LINK_TEXT_LIMIT)
      value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding? &&
        value.bytesize.between?(1, maximum) && !value.include?("\0")
    end

    def document_link_supported?(client)
      provider = client.capabilities["documentLinkProvider"] if client&.respond_to?(:capabilities)
      provider == true || provider.is_a?(Hash)
    end

    def document_link_resolve_supported?(client)
      provider = client.capabilities["documentLinkProvider"] if client&.respond_to?(:capabilities)
      provider.is_a?(Hash) && (provider["resolveProvider"] == true || provider[:resolveProvider] == true)
    end

    def document_link_key(client, current, buffer, version = buffer.version,
      supported = document_link_supported?(client), resolve = document_link_resolve_supported?(client),
      document = current.language_document)
      [client, current, buffer, version, supported, resolve, document]
    end

    def document_link_result_valid?(request, owner)
      document_link_editor_valid?(request) && request[:client].equal?(owner) &&
        active_language_client(request[:language], "documentLink").equal?(owner) &&
        request[:supported] == document_link_supported?(owner) &&
        request[:resolve] == document_link_resolve_supported?(owner) &&
        @opened_lsp_documents&.key?([owner, request[:buffer]])
    end

    def document_link_editor_valid?(request)
      current, buffer = request.values_at(:editor, :buffer)
      !@closed && current.buffer.equal?(buffer) && buffer.version == request[:version] &&
        current.language_document.equal?(request[:document]) &&
        buffer.path && Sadr::Protocol.uri(buffer.path) == request[:uri] &&
        @panes.any? { |pane| pane.active.equal?(current) }
    end

    def document_link_request_valid?(request, owner)
      @document_link_requests&.[](request[:editor]).equal?(request) && document_link_result_valid?(request, owner)
    end

    def cache_document_links(key, links)
      cache = @document_link_cache ||= {}
      cache.delete_if { |entry, value| entry[1].equal?(key[1]) && (cancel_document_link_cache(value); true) }
      cache.shift while cache.length >= DOCUMENT_LINK_REQUEST_LIMIT
      if links == false
        cache[key] = false
      else
        holder = {entries: links}
        links.each do |entry|
          label = entry[:tooltip] || entry[:target] || "Open document link"
          entry[:decoration] = Decoration::Item.new(:highlight, entry[:range], nil, label,
            DOCUMENT_LINK_STYLE, 18, :document_link,
            ->(current, offset) { activate_document_link(key, holder, entry, current, offset) })
        end
        cache[key] = holder
      end
      @decorations.invalidate(:document_link, buffer: key[2])
      @window&.request_frame unless @closed
      links
    end

    def cancel_document_link_cache(cache)
      cache[:entries].each { |entry| entry[:future]&.cancel } if cache.is_a?(Hash)
      nil
    end

    def document_link_cache_valid?(key, cache)
      client, current, buffer, version, supported, resolve, document = key
      @document_link_cache&.[](key).equal?(cache) && !@closed && buffer.version == version &&
        current.buffer.equal?(buffer) && current.language_document.equal?(document) && language_client_active?(client) &&
        document_link_supported?(client) == supported && document_link_resolve_supported?(client) == resolve &&
        @panes.any? { |pane| pane.active.equal?(current) }
    end

    def activate_document_link(key, cache, entry, current, offset)
      return false unless current.equal?(key[1]) && entry[:range].cover?(offset) && document_link_cache_valid?(key, cache)
      return open_document_link(entry[:target]) if entry[:target]
      return false unless key[5] && entry[:state] == :unresolved
      resolving = (@document_link_cache || {}).values.sum do |value|
        value.is_a?(Hash) ? value[:entries].count { |candidate| candidate[:state] == :resolving } : 0
      end
      if resolving >= DOCUMENT_LINK_RESOLVE_LIMIT
        @message = "Too many document links are resolving"
        return false
      end

      entry[:state] = :resolving
      client, buffer = key.values_at(0, 2)
      job = Thread.new do
        begin
          future = client.resolve_document_link(entry[:link])
          entry[:future] = future
          result = future.await(timeout: 10) if document_link_cache_valid?(key, cache)
          unless document_link_cache_valid?(key, cache)
            future.cancel
            next
          end
          resolved = validate_document_link_entry(buffer.rope, result, entry[:index], resolve: false)
          raise Error, "resolved document link moved" unless resolved[:range] == entry[:range]
          post do
            next unless document_link_cache_valid?(key, cache) && entry[:state] == :resolving
            entry.update(resolved)
            entry.delete(:future)
            open_document_link(entry[:target])
          end
        rescue StandardError => error
          post do
            next unless document_link_cache_valid?(key, cache) && entry[:state] == :resolving
            entry.delete(:future)
            entry[:state] = :failed
            @message = error.message unless @retired_language_clients&.[](client)
          end
        ensure
          worker = Thread.current
          post { @language_jobs&.delete(worker) }
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      true
    rescue StandardError => error
      @message = error.message
      false
    end

    def open_document_link(target)
      uri = URI::DEFAULT_PARSER.parse(document_link_target(target))
      if %w[http https].include?(uri.scheme.downcase)
        raise Error, "Opening URLs is unavailable" unless @window&.respond_to?(:open_url)
        @window.open_url(target)
      else
        path = canonical_path(Sadr::Protocol.path(target))
        raise Error, "Document link target is not a file" unless File.file?(path)
        open(path).tap { |current| current.select(0); current.reveal_cursor }
      end
      true
    rescue URI::InvalidURIError, SystemCallError, Sadr::Error => error
      raise Error, "Cannot open document link: #{error.message}"
    end

    def linked_editing_snapshot(current)
      buffer, offset = current.buffer, current.primary.head
      language = current.language_document.definition.name
      client = active_language_client(language, "linkedEditingRange")
      snapshot = {editor: current, buffer: buffer, version: buffer.version, rope: buffer.rope,
        selections: current.selections, selection: current.primary, offset: offset,
        uri: Sadr::Protocol.uri(buffer.path), position: Sadr::Protocol.position(buffer.rope, offset),
        language: language, document: current.language_document,
        client: client, supported: linked_editing_supported?(client)}
      unless Sadr::Protocol.offset(snapshot[:rope], snapshot[:position]) == offset
        raise Error, "invalid linked editing position"
      end
      snapshot[:selection_subscription] = current.on_selection do
        invalidate_linked_editing_ranges(editor: current) unless current.selections == snapshot[:selections]
      end
      snapshot[:edit_subscription] = buffer.on_edit { invalidate_linked_editing_ranges(buffer) }
      snapshot
    end

    def start_linked_editing_request(id, snapshot)
      job = Thread.new do
        begin
          owner = language_client(snapshot[:buffer], feature: "linkedEditingRange")
          unless @linked_editing_requests&.[](id).equal?(snapshot) && linked_editing_editor_valid?(snapshot)
            next
          end
          snapshot[:client] = owner
          snapshot[:supported] = linked_editing_supported?(owner)
          unless snapshot[:supported]
            post do
              next unless take_linked_editing_request(id, snapshot)
              release_linked_editing_snapshot(snapshot)
              @message = "Language server does not support linked editing" if linked_editing_editor_valid?(snapshot)
            end
            next
          end

          future = owner.linked_editing_range(snapshot[:uri], snapshot[:position])
          snapshot[:future] = future
          result = future.await(timeout: 10) if linked_editing_request_valid?(id, snapshot, owner)
          unless linked_editing_request_valid?(id, snapshot, owner)
            future.cancel
            next
          end
          linked = normalize_linked_editing_ranges(snapshot[:rope], snapshot[:offset], snapshot[:selection], result)
          post do
            next unless take_linked_editing_request(id, snapshot)
            valid = linked_editing_snapshot_valid?(snapshot)
            release_linked_editing_snapshot(snapshot)
            if valid && linked && !linked[:ranges].empty?
              apply_linked_editing_ranges(snapshot, linked)
            elsif valid
              @message = "Linked editing is not available here"
            end
          end
        rescue StandardError => error
          post do
            next unless take_linked_editing_request(id, snapshot)
            valid = linked_editing_editor_valid?(snapshot) && !@retired_language_clients&.[](owner)
            release_linked_editing_snapshot(snapshot)
            @message = error.message if valid
          end
        ensure
          worker = Thread.current
          post do
            release_linked_editing_snapshot(snapshot) if take_linked_editing_request(id, snapshot)
            @language_jobs&.delete(worker)
          end
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      true
    end

    def apply_linked_editing_ranges(snapshot, linked)
      source, selection = linked[:source], snapshot[:selection]
      anchor, head = selection.anchor - source.begin, selection.head - source.begin
      selections = linked[:ranges].each_with_index.map do |range, index|
        unless anchor.between?(0, range.size) && head.between?(0, range.size)
          raise Error, "linked editing ranges do not match the selection"
        end
        first, last = range.begin + anchor, range.begin + head
        [first, last].each do |offset|
          position = Sadr::Protocol.position(snapshot[:rope], offset)
          raise Error, "invalid linked editing selection boundary" unless Sadr::Protocol.offset(snapshot[:rope], position) == offset
        end
        Selection.new(index, first, last, nil)
      end
      snapshot[:editor].set_selections(selections, merge: false)
      snapshot[:editor].reveal_cursor
      @message = "Linked ranges selected"
      @window&.request_frame
      true
    end

    def linked_editing_supported?(client)
      provider = client.capabilities["linkedEditingRangeProvider"] if client&.respond_to?(:capabilities)
      provider == true || provider.is_a?(Hash)
    end

    def linked_editing_editor_valid?(snapshot)
      current, buffer = snapshot.values_at(:editor, :buffer)
      !@closed && current.buffer.equal?(buffer) && buffer.version == snapshot[:version] &&
        current.language_document.equal?(snapshot[:document]) &&
        current.selections == snapshot[:selections] && current.primary.head == snapshot[:offset] &&
        buffer.path && Sadr::Protocol.uri(buffer.path) == snapshot[:uri] &&
        @panes.any? { |pane| pane.active.equal?(current) }
    end

    def linked_editing_snapshot_valid?(snapshot)
      client = active_language_client(snapshot[:language], "linkedEditingRange")
      linked_editing_editor_valid?(snapshot) && client.equal?(snapshot[:client]) &&
        linked_editing_supported?(client) == snapshot[:supported]
    end

    def linked_editing_request_valid?(id, snapshot, owner)
      @linked_editing_requests&.[](id).equal?(snapshot) && linked_editing_snapshot_valid?(snapshot) &&
        snapshot[:client].equal?(owner) && @opened_lsp_documents&.key?([owner, snapshot[:buffer]])
    end

    def take_linked_editing_request(id, snapshot)
      @linked_editing_requests&.delete(id).equal?(snapshot)
    end

    def release_linked_editing_snapshot(snapshot)
      snapshot&.delete(:selection_subscription)&.detach
      snapshot&.delete(:edit_subscription)&.detach
      snapshot&.delete(:future)
      nil
    end

    def document_highlight_supported?(client)
      provider = client.capabilities["documentHighlightProvider"] if client&.respond_to?(:capabilities)
      provider == true || provider.is_a?(Hash)
    end

    def document_highlight_key(client, current, buffer, version = buffer.version,
      head = current.primary.head, supported = document_highlight_supported?(client))
      [client, current, buffer, version, head, supported]
    end

    def document_highlight_result_valid?(request, owner)
      buffer = request[:buffer]
      document_highlight_editor_valid?(request) && language_client_active?(owner) &&
        @opened_lsp_documents&.key?([owner, buffer])
    end

    def document_highlight_editor_valid?(request)
      current, buffer = request.values_at(:editor, :buffer)
      !@closed && current.buffer.equal?(buffer) && buffer.version == request[:version] &&
        current.primary.head == request[:head] && buffer.path && Sadr::Protocol.uri(buffer.path) == request[:uri] &&
        @panes.any? { |pane| pane.active.equal?(current) }
    end

    def document_highlight_request_valid?(request, owner)
      @document_highlight_requests&.[](request[:editor]).equal?(request) && document_highlight_result_valid?(request, owner)
    end

    def cache_document_highlights(key, highlights)
      cache = @document_highlight_cache ||= {}
      cache.delete_if { |entry, _value| entry[1].equal?(key[1]) }
      cache.shift while cache.length >= DOCUMENT_HIGHLIGHT_REQUEST_LIMIT
      cache[key] = highlights
      @decorations.invalidate(:document_highlight, buffer: key[2])
      @window&.request_frame unless @closed
      highlights
    end

    def cache_sticky_symbols(client, buffer, version, symbols)
      cache = @sticky_symbol_cache ||= {}
      cache.delete_if { |key, _| key[0].equal?(client) && key[1].equal?(buffer) }
      cache.shift while cache.length >= 64
      cache[[client, buffer, version]] = symbols == false ? false : sticky_cache_entry(buffer, version, client, symbols)
      @sticky_context_cache&.clear
      @window&.request_frame unless @closed
      symbols
    end

    def sticky_cache_entry(buffer, version, client, symbols)
      generation = @sticky_symbol_generation = @sticky_symbol_generation.to_i + 1
      by_id = symbols.to_h { |symbol| [symbol.id, symbol] }.freeze
      children = symbols.group_by(&:parent_id).transform_values do |values|
        values.sort_by { |symbol| [symbol.range.begin, symbol.range.end, symbol.id] }.freeze
      end.freeze
      {buffer: buffer, version: version, client: client, generation: generation,
       symbols: symbols.freeze, by_id: by_id, children: children}.freeze
    end

    def active_structure_guide(current, enabled)
      return unless enabled
      row = current.buffer.rope.point_at(current.primary.head).row
      region = current.language_document.structure_regions.lazy
        .select { |item| item[:kind] == :block && item[:start_line] <= row && row <= item[:end_line] }
        .min_by { |item| [item[:end_line] - item[:start_line], -item[:start_line]] }
      return unless region

      indentation = indentation_offsets(current.buffer.line(region[:start_line]), current.tab_size).last&.first || 0
      region.merge(column: indentation + current.tab_size)
    end

    def indentation_offsets(line, tab_size, limit: INDENT_GUIDE_LIMIT)
      return [] unless limit.positive?
      offsets, column, byte, target = [], 0, 0, tab_size
      line.each_byte do |character|
        break unless character == 32 || character == 9
        column += character == 9 ? tab_size - column % tab_size : 1
        byte += 1
        while target <= column
          offsets << [target, byte]
          return offsets if offsets.length >= limit
          target += tab_size
        end
      end
      offsets
    end

    def visible_language_ranges(current, display_rows, gap:)
      map = current.display_map
      rows = display_rows.flat_map do |index|
        row = map.row(index)
        ending = map.to_buffer(DisplayPoint.new(index, row.text.length))
        [map.source_row(index), current.buffer.rope.point_at(ending).row]
      end
      rows.sort.uniq.slice_when { |left, right| right - left > gap }
        .map { |group| group.first...(group.last + 1) }
    end

    def open_language_document(client, buffer, language_id)
      uri = Sadr::Protocol.uri(buffer.path)
      key = [client, buffer]
      @language_document_subscriptions&.delete(key)&.detach
      (@language_document_subscriptions ||= {})[key] = buffer.on_edit do |patch|
        invalidate_document_highlights(buffer)
        invalidate_document_links(buffer)
        invalidate_folding_ranges(buffer)
        invalidate_selection_ranges(buffer)
        invalidate_prepare_rename(buffer)
        invalidate_linked_editing_ranges(buffer)
        invalidate_inlay_hints(buffer)
        invalidate_code_lenses(buffer)
        invalidate_sticky_symbols(buffer)
        sync_language_document(client, uri, buffer, patch)
      end
      (@opened_lsp_documents ||= {})[key] = true
      client.open(Sadr::Document.new(uri: uri, language_id: language_id, version: buffer.version, text: buffer.text))
      uri
    rescue StandardError
      @opened_lsp_documents&.delete(key) if defined?(key)
      @language_document_subscriptions&.delete(key)&.detach if defined?(key)
      raise
    end

    def close_language_document(client, buffer, uri: Sadr::Protocol.uri(buffer.path))
      forget_language_document(client, buffer, uri: uri)
      client.close(uri)
    end

    def forget_language_document(client, buffer, uri: buffer.path && Sadr::Protocol.uri(buffer.path))
      key = [client, buffer]
      @opened_lsp_documents&.delete(key)
      @language_document_subscriptions&.delete(key)&.detach
      clear_client_diagnostics(client, uri) if uri
      invalidate_diagnostics(buffer)
      invalidate_document_highlights(buffer, client: client)
      invalidate_document_links(buffer, client: client)
      invalidate_folding_ranges(buffer, client: client)
      invalidate_selection_ranges(buffer, client: client)
      invalidate_prepare_rename(buffer, client: client)
      invalidate_linked_editing_ranges(buffer, client: client)
      invalidate_inlay_hints(buffer, client: client)
      invalidate_code_lenses(buffer, client: client)
      invalidate_sticky_symbols(buffer, client: client)
    end

    def sync_language_document(client, uri, buffer, patch)
      clear_client_diagnostics(client, uri)
      changes = if patch.is_a?(Patch)
        patch.edits.reverse.map do |edit|
          Sadr::ContentChange.new(range: Sadr::Protocol.range(patch.before, edit.old_range), text: edit.new_text)
        end
      else
        [Sadr::ContentChange.new(range: nil, text: buffer.text)]
      end
      client.change(uri, buffer.version, changes)
    rescue Sadr::Error => error
      self.message = "Language server change failed: #{error.message}"
      resync_language_document(client, uri, buffer)
    end

    def publish_lsp_diagnostics(uri)
      clients = [*(@language_clients || {}).values.flatten, *(@lsp_diagnostics || {}).keys].uniq
      values = clients.flat_map { |client| @lsp_diagnostics&.dig(client, uri) || [] }.uniq
      @diagnostics.publish(:lsp, uri, values)
    end

    def clear_language_client_diagnostics(client)
      (@lsp_diagnostics&.dig(client)&.keys || []).dup.each { |uri| clear_client_diagnostics(client, uri) }
    end

    def clear_client_diagnostics(client, uri)
      if (documents = @lsp_diagnostics&.[](client))
        documents.delete(uri)
        @lsp_diagnostics.delete(client) if documents.empty?
      end
      if (versions = @diagnostic_versions&.[](client))
        versions.delete(uri)
        @diagnostic_versions.delete(client) if versions.empty?
      end
      publish_lsp_diagnostics(uri)
    end
    private :publish_lsp_diagnostics, :clear_client_diagnostics, :clear_language_client_diagnostics

    def resync_language_document(client, uri, buffer)
      key = [client, buffer]
      jobs = @language_document_resyncs ||= {}
      return if jobs[key]&.alive?

      # ponytail: poll until Sadr exposes a restart-complete callback.
      jobs[key] = Thread.new do
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 35
        until @closed || @retired_language_clients&.[](client) || !@opened_lsp_documents&.[](key)
          if client.running?
            version = buffer.version
            text = buffer.text
            next unless version == buffer.version

            client.change(uri, version, [Sadr::ContentChange.new(range: nil, text: text)])
            break
          end
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.01
        end
      rescue Sadr::Error => error
        self.message = "Language server resync failed: #{error.message}" unless error.message == "document version must increase"
      ensure
        jobs.delete(key) if jobs[key].equal?(Thread.current)
      end
    end

    def completion_query(buffer, offset)
      line = buffer.rope.byteslice(buffer.rope.line_start(buffer.rope.point_at(offset).row)...offset).to_s
      line[/[[:alnum:]_]*\z/].to_s.each_grapheme_cluster.to_a.last(64).join
    end

    def lsp_completion_items(result)
      items = result.is_a?(Hash) ? result.fetch("items", []) : result.nil? ? [] : result
      defaults = result.is_a?(Hash) ? result.fetch("itemDefaults", {}) : {}
      raise Error, "invalid completion result" unless items.is_a?(Array) && defaults.is_a?(Hash)
      raise Error, "too many completion items" if items.length > Provider::Registry::MAX_ITEMS

      items.map do |item|
        raise Error, "invalid completion item" unless item.is_a?(Hash)
        merged = defaults.reject { |key, _| key == "editRange" }.merge(item)
        if defaults["editRange"] && !merged["textEdit"]
          range = defaults["editRange"]
          raise Error, "invalid completion edit range" unless range.is_a?(Hash)
          text = item["textEditText"] || item["insertText"] || item.fetch("label")
          merged["textEdit"] = (range.key?("start") ? {"range" => range} : range).merge("newText" => text)
        end
        merged.freeze
      end
    rescue KeyError => error
      raise Error, "invalid completion result: #{error.message}"
    end

    def display_language_result(kind, result, client, current, item_clients: nil)
      case kind
      when :completion
        generation = @completion_generation = (@completion_generation || 0) + 1
        context = {editor: current, version: current.buffer.version, generation: generation,
          query: completion_query(current.buffer, current.primary.head),
          lsp_result: result, client: client, metadata: {}, errors: []}
        display_completions(@providers.complete(current.buffer, current.primary.head, context), current, context)
      when :hover, :signatureHelp
        contents = result && (result["contents"] || result["signatures"]&.map { |signature| signature["label"] })
        @hover_markup = kind == :hover && !(contents.is_a?(Hash) && contents["kind"] == "plaintext")
        @hover_card = (contents.is_a?(Hash) ? [contents] : Array(contents)).map do |part|
          if part.is_a?(Hash)
            part["language"] ? "```#{part['language']}\n#{part['value']}\n```" : part["value"]
          else
            part
          end
        end.compact.join("\n")
      when :definition, :typeDefinition, :implementation, :references, :workspace_symbols
        items = result.is_a?(Hash) ? [result] : Array(result)
        labels = items.map do |item|
          location = item["location"] || item
          uri = location["uri"] || location["targetUri"]
          range = location["range"] || location["targetSelectionRange"]
          "#{item['name']} #{File.basename(Sadr::Protocol.path(uri))}:#{range.fetch('start').fetch('line') + 1}"
        end
        self.palette = {kind: :locations, query: +"", index: 0, matches: labels, items: items}
      when :rename
        if resource_workspace_edit?(result)
          confirm_workspace_edit(result, label: "Apply rename and file operations?")
        elsif result
          apply_workspace_edit(result)
        end
      when :formatting then current.buffer.edit(Sadr::Protocol.text_edits(current.buffer.rope, result || []), kind: :lsp)
      when :codeAction, :codeLens
        items = Array(result)
        self.palette = {kind: :code_actions, query: +"", index: 0, matches: items.map { |item| item["title"] || item.dig("command", "title") || "Code lens" },
          items: items, client: client, item_clients: item_clients, editor: current, version: current.buffer.version, lens: kind == :codeLens}
        update_palette
      when :documentSymbol
        symbols = []
        collect = lambda do |items, depth|
          items.each do |item|
            symbols << item.merge("_depth" => depth)
            collect.call(item.fetch("children", []), depth + 1)
          end
        end
        collect.call(Array(result), 0)
        uri = Sadr::Protocol.uri(current.buffer.path)
        self.palette = {kind: :symbols, query: +"", index: 0, matches: symbols.map { |symbol| "#{'  ' * symbol['_depth']}#{symbol['name']}" },
          items: symbols.map { |symbol| symbol.merge("uri" => uri, "range" => symbol["selectionRange"] || symbol["range"]) }}
      when :diagnostic
        if result
          uri = Sadr::Protocol.uri(current.buffer.path)
          accept_diagnostic_notification(client, {"uri" => uri, "version" => current.buffer.version,
            "diagnostics" => result.fetch("items", [])})
        end
      when :semantic_tokens
        types = client.capabilities.dig("semanticTokensProvider", "legend", "tokenTypes") || []
        @semantic_styles ||= {}
        @semantic_styles[current.buffer] = [current.buffer.version, result.map { |token| token.to_h.merge(name: types[token[:type]]) }]
      end
      @window&.request_frame
    end
  end
end

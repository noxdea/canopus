# frozen_string_literal: true

module Canopus
  module Workspace::LanguageAware
    DIAGNOSTIC_SEVERITIES = {"error" => 1, "warning" => 2, "information" => 3, "hint" => 4}.freeze
    DIAGNOSTIC_COLORS = {1 => :"diagnostic.error", 2 => :"diagnostic.warning",
      3 => :"diagnostic.information", 4 => :"diagnostic.hint"}.freeze
    CODE_LENS_REQUEST_LIMIT = 64
    CODE_LENS_RESOLVE_LIMIT = 32
    INDENT_GUIDE_LIMIT = 4096

    attr_reader :hover_card, :hover_markup, :semantic_styles
    def dismiss_hover = @hover_card = nil
    def close_language_documents(buffer = nil)
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
      (@main_queue ||= Queue.new) << block
      @window&.request_frame
    end
    def language_client(buffer = editor.buffer)
      raise Error, "language servers are disabled for large read-only documents" if buffer.read_only
      language = definition_for(buffer.path)
      (@client_lock ||= Mutex.new).synchronize do
        options = language_server_options(language.name)
        raise Error, "No language server configured for #{language.name}" unless options
        client = ensure_language_server(language.name, options)
        @opened_lsp_documents ||= {}
        unless @opened_lsp_documents[[client, buffer]]
          open_language_document(client, buffer, language.name)
        end
        client
      end
    end
    def language_request(kind, **options)
      current, buffer, offset = editor, editor.buffer, editor.primary.head
      if kind == :inlayHint
        requested = request_visible_inlay_hints(current)
        @message = "#{kind}…" if requested
        return requested
      end

      version = buffer.version
      (@language_jobs ||= []) << Thread.new do
        begin
          client = language_client(buffer)
          uri = Sadr::Protocol.uri(buffer.path)
          position = Sadr::Protocol.position(buffer.rope, offset)
          result = case kind
          when :completion, :hover, :definition, :typeDefinition, :implementation, :signatureHelp
            method = {typeDefinition: :type_definition, signatureHelp: :signature_help}.fetch(kind, kind)
            client.public_send(method, uri, position).await(timeout: 10)
          when :references then client.references(uri, position, include_declaration: true).await(timeout: 10)
          when :rename then client.rename(uri, position, options.fetch(:name)).await(timeout: 10)
          when :formatting then client.formatting(uri, {tabSize: current.tab_size, insertSpaces: !current.use_tabs}).await(timeout: 10)
          when :codeAction
            client.code_action(uri, Sadr::Protocol.range(buffer.rope, current.primary.range), {diagnostics: diagnostics_for(buffer)}).await(timeout: 10)
          when :documentSymbol then client.document_symbol(uri).await(timeout: 10)
          when :codeLens then client.code_lens(uri).await(timeout: 10)
          when :diagnostic then client.diagnostic(uri).await(timeout: 10)
          when :semantic_tokens then client.semantic_tokens(uri, version: buffer.version)
          when :workspace_symbols then client.workspace_symbols(options.fetch(:query, "")).await(timeout: 10)
          else raise Error, "unknown language request #{kind}"
          end
          post do
            next unless @clients.value?(client)
            next unless @panes.any? { |pane| pane.editors.include?(current) }
            if buffer.version == version
              display_language_result(kind, result, client, current)
            else
              @message = "Document changed; request #{kind} again"
            end
          end
        rescue StandardError => error
          post { @message = error.message unless client && @retired_language_clients&.[](client) }
        end
      end
      @language_jobs.reject! { |thread| !thread.alive? }
      @message = "#{kind}…"
    end
    def diagnostics_for(buffer)
      return [] if !buffer.path || @clients.empty?
      uri = Sadr::Protocol.uri(buffer.path)
      @clients.values.flat_map do |client|
        key = [client, buffer]
        next [] unless @opened_lsp_documents&.key?(key)
        version = @diagnostic_versions&.dig(client, uri)
        next [] if version && version != buffer.version

        client.diagnostics.fetch(uri, [])
      end
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
    def accept_language_result(palette, index)
      item = palette[:items][index]
      return unless item
      current = palette[:editor]
      raise Error, "Document was closed; request again" if current && !@panes.any? { |pane| pane.editors.include?(current) }
      if current && palette[:version] && current.buffer.version != palette[:version]
        raise Error, "Document changed; request #{palette[:kind]} again"
      end
      client = palette[:client]
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
            items = palette[:items].dup
            items[index] = item.merge(resolved || {})
            accept_language_result(palette.merge(items: items, resolved: true), index)
          end
        rescue StandardError => error
          post { @message = error.message }
        end
        return
      end
      case palette[:kind]
      when :completion
        editor = palette[:editor]
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
          snippet ? editor.insert_snippet(value, variables: variables) : editor.insert_text(value, auto_indent: false)
        ensure
          editor.buffer.end_undo_group
        end
        show_snippet_choices(editor) if snippet
        command = item["command"]
        client.execute_command(command.fetch("command"), arguments: command.fetch("arguments", [])) if command && client
      when :locations, :symbols
        location = item["location"] || item
        jump_to_language_location(location)
      when :code_actions
        raise Error, item["disabled"]["reason"].to_s if item["disabled"]
        run_command = lambda do
          command = item["command"]
          if command
            command = item if command.is_a?(String)
            palette[:client].execute_command(command.fetch("command"), arguments: command.fetch("arguments", []))
          end
        end
        return confirm_workspace_edit(item["edit"], label: item.fetch("title", "Apply code action?"), on_applied: run_command) if resource_workspace_edit?(item["edit"])
        apply_workspace_edit(item["edit"]) if item["edit"]
        run_command.call
      end
    end
    def show_diagnostics
      items, labels = [], []
      @buffers.each_value.uniq.each do |buffer|
        next unless buffer.path
        diagnostics_for(buffer).each do |diagnostic|
          row = diagnostic.dig("range", "start", "line")
          next unless row.is_a?(Integer)
          labels << "#{File.basename(buffer.path)}:#{row + 1} #{diagnostic['message']}"
          items << {"uri" => Sadr::Protocol.uri(buffer.path), "range" => diagnostic.fetch("range")}
        end
      end
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
    def fold_current
      current, document = editor, editor.language_document
      ranges = document.fold_ranges
      if document.syntax_ready?
        range = ranges.reverse.find { |item| item.cover?(current.primary.head) }
        current.display_map.fold(range) if range
      else
        @pending_fold = [current, document, current.buffer.version, current.primary.head]
        @message = "Analyzing fold ranges…"
      end
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
      return unless @pending_fold && @pending_fold[0].equal?(current)
      _, requested_document, version, cursor = @pending_fold
      unless current.equal?(editor) && requested_document.equal?(document) && version == current.buffer.version && cursor == current.primary.head
        @pending_fold = nil
        return
      end
      return if !document.syntax_ready? && document.pending?
      @pending_fold = nil
      if document.syntax_ready?
        range = document.fold_ranges.reverse.find { |item| item.cover?(cursor) }
        current.display_map.fold(range) if range
        @message = range ? "Folded" : "No fold at cursor"
        @window&.request_frame
      else
        @message = "Fold analysis unavailable"
      end
    end

    private

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

      (@diagnostic_versions ||= {}).tap { |versions| (versions[client] ||= {})[uri] = buffer.version }
      invalidate_diagnostics(buffer)
      @window&.request_frame
    rescue KeyError, Sadr::Error
      nil
    end

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
              buffer.version == version && @clients.value?(client)

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
        buffer.version == version && @clients.value?(client) && @settings.for_language(definition_for(buffer.path).name)["code_lens"]["enabled"]

      job = Thread.new do
        client.execute_command(command.fetch("command"), arguments: command.fetch("arguments", [])).await(timeout: 10)
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
      active = @clients.values
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
      client = @clients[language]
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
          owner = language_client(buffer)
          supported = owner.capabilities["inlayHintProvider"]
          valid = buffer.version == version && @inlay_hint_generation.to_i == generation && @clients.value?(owner)
          result = owner.inlay_hint(Sadr::Protocol.uri(buffer.path), protocol_range).await(timeout: 10) if supported && valid
          post do
            @inlay_hint_requests&.delete(id)
            @language_jobs&.reject! { |thread| !thread.alive? }
            next unless supported && valid && @inlay_hint_generation.to_i == generation && @clients.value?(owner)
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
      active = @clients.values
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
      client = @clients[language]
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
          owner = language_client(buffer)
          request[:client] = owner
          capability = owner.capabilities["codeLensProvider"]
          supported = capability == true || capability.is_a?(Hash)
          valid = buffer.version == version && @clients.value?(owner) && @code_lens_requests&.[](id).equal?(request)
          result = owner.code_lens(Sadr::Protocol.uri(buffer.path)).await(timeout: 10) if supported && valid
          post do
            pending = @code_lens_requests&.delete(id)
            @language_jobs&.reject! { |thread| !thread.alive? }
            next unless pending.equal?(request) && supported && valid && @clients.value?(owner)
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
            if pending.equal?(request) && owner && @clients.value?(owner) && buffer.version == version &&
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

    private

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
      client.open(Sadr::Document.new(uri: uri, language_id: language_id, version: buffer.version, text: buffer.text))
      key = [client, buffer]
      @language_document_subscriptions&.delete(key)&.detach
      (@language_document_subscriptions ||= {})[key] = buffer.on_edit do |patch|
        invalidate_inlay_hints(buffer)
        invalidate_code_lenses(buffer)
        sync_language_document(client, uri, buffer, patch)
      end
      (@opened_lsp_documents ||= {})[key] = true
      uri
    end

    def close_language_document(client, buffer, uri: Sadr::Protocol.uri(buffer.path))
      forget_language_document(client, buffer, uri: uri)
      client.close(uri)
    end

    def forget_language_document(client, buffer, uri: buffer.path && Sadr::Protocol.uri(buffer.path))
      key = [client, buffer]
      @opened_lsp_documents&.delete(key)
      @language_document_subscriptions&.delete(key)&.detach
      if uri && (versions = @diagnostic_versions&.[](client))
        versions.delete(uri)
        @diagnostic_versions.delete(client) if versions.empty?
      end
      invalidate_diagnostics(buffer)
      invalidate_inlay_hints(buffer)
      invalidate_code_lenses(buffer)
    end

    def sync_language_document(client, uri, buffer, patch)
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

    def display_language_result(kind, result, client, current)
      case kind
      when :completion
        items = result.is_a?(Hash) ? result.fetch("items", []) : Array(result)
        defaults = result.is_a?(Hash) ? result.fetch("itemDefaults", {}) : {}
        items = items.map do |item|
          merged = defaults.reject { |key, _| key == "editRange" }.merge(item)
          if defaults["editRange"] && !merged["textEdit"]
            range = defaults["editRange"]
            merged["textEdit"] = (range.key?("start") ? {"range" => range} : range).merge("newText" => item["textEditText"] || item["insertText"] || item.fetch("label"))
          end
          merged
        end
        self.palette = {kind: :completion, query: +"", index: 0, matches: items.map { |item| item.fetch("label") }, items: items, editor: current, client: client, version: current.buffer.version}
        update_palette
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
        self.palette = {kind: :code_actions, query: +"", index: 0, matches: items.map { |item| item["title"] || item.dig("command", "title") || "Code lens" }, items: items, client: client, editor: current, version: current.buffer.version, lens: kind == :codeLens}
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
          client.diagnostics[uri] = result.fetch("items", [])
          accept_diagnostic_notification(client, {"uri" => uri, "version" => current.buffer.version})
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

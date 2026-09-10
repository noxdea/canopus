# frozen_string_literal: true

module Canopus
  module Workspace::LanguageAware
    attr_reader :hover_card, :hover_markup, :semantic_styles
    def dismiss_hover = @hover_card = nil
    def close_language_documents(buffer = nil)
      @opened_lsp_documents&.keys&.each do |key|
        client, document = key
        next if buffer && !document.equal?(buffer)
        @opened_lsp_documents.delete(key)
        begin
          client.close_document(LSP::Protocol.uri(document.path)) if document.path
        rescue StandardError => error
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
          client.open_document(buffer, language_id: language.name)
          @opened_lsp_documents[[client, buffer]] = true
        end
        client
      end
    end
    def language_request(kind, **options)
      current, buffer, offset = editor, editor.buffer, editor.primary.head
      version = buffer.version
      (@language_jobs ||= []) << Thread.new do
        begin
          client = language_client(buffer)
          result = case kind
          when :completion, :hover, :definition, :typeDefinition, :implementation, :signatureHelp
            client.public_send(kind, buffer, offset).await
          when :references then client.references(buffer, offset, context: {includeDeclaration: true}).await
          when :rename then client.rename(buffer, offset, newName: options.fetch(:name)).await
          when :formatting then client.formatting(buffer, options: {tabSize: current.tab_size, insertSpaces: !current.use_tabs}).await
          when :codeAction
            client.codeAction(buffer, range: LSP::Protocol.range(buffer.rope, current.primary.range), context: {diagnostics: diagnostics_for(buffer)}).await
          when :documentSymbol, :codeLens, :diagnostic then client.public_send(kind, buffer).await
          when :inlayHint then client.inlayHint(buffer, range: LSP::Protocol.range(buffer.rope, 0...buffer.rope.bytesize)).await
          when :semantic_tokens then client.semantic_tokens(buffer)
          when :workspace_symbols then client.workspace_symbols(options.fetch(:query, "")).await
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
      uri = LSP::Protocol.uri(buffer.path)
      @clients.values.flat_map { |client| client.diagnostics.fetch(uri, []) }
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
        "#{change['kind']}: #{paths.map { |uri| LSP::Protocol.path(uri) }.join(' → ')}#{suffix}"
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
        path = canonical_path(LSP::Protocol.path(document.fetch("uri")))
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
          [LSP::Protocol.offset(rope, range.fetch("start"))...LSP::Protocol.offset(rope, range.fetch("end")), entry.fetch("newText")]
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
          resolved = client.public_send(resolver, item).await
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
          LSP::Protocol.offset(editor.buffer.rope, range.fetch("start"))...LSP::Protocol.offset(editor.buffer.rope, range.fetch("end"))
        else
          editor.primary.range
        end
        value = text_edit ? text_edit.fetch("newText") : item["insertText"] || item.fetch("label")
        snippet = item["insertTextFormat"] == 2
        variables = editor.snippet_variables(workspace_root: @root, clipboard: @window.respond_to?(:clipboard) ? @window.clipboard : nil) if snippet
        expanded = snippet ? Snippet.new(value, variables: variables).text : value
        additional = item.fetch("additionalTextEdits", []).map do |entry|
          [LSP::Protocol.offset(editor.buffer.rope, entry.fetch("range").fetch("start"))...LSP::Protocol.offset(editor.buffer.rope, entry.fetch("range").fetch("end")), entry.fetch("newText")]
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
        path = LSP::Protocol.path(location["uri"] || location.fetch("targetUri"))
        opened = open(path)
        range = location["range"] || location.fetch("targetSelectionRange")
        opened.select(LSP::Protocol.offset(opened.buffer.rope, range.fetch("start")))
        opened.reveal_cursor
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
          items << {"uri" => LSP::Protocol.uri(buffer.path), "range" => diagnostic.fetch("range")}
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
          "#{item['name']} #{File.basename(LSP::Protocol.path(uri))}:#{range.fetch('start').fetch('line') + 1}"
        end
        self.palette = {kind: :locations, query: +"", index: 0, matches: labels, items: items}
      when :rename
        if resource_workspace_edit?(result)
          confirm_workspace_edit(result, label: "Apply rename and file operations?")
        elsif result
          apply_workspace_edit(result)
        end
      when :formatting then client.apply_text_edits(current.buffer, result || [])
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
        uri = LSP::Protocol.uri(current.buffer.path)
        self.palette = {kind: :symbols, query: +"", index: 0, matches: symbols.map { |symbol| "#{'  ' * symbol['_depth']}#{symbol['name']}" },
          items: symbols.map { |symbol| symbol.merge("uri" => uri, "range" => symbol["selectionRange"] || symbol["range"]) }}
      when :diagnostic
        client.diagnostics[LSP::Protocol.uri(current.buffer.path)] = result.fetch("items", []) if result
      when :semantic_tokens
        types = client.capabilities.dig("semanticTokensProvider", "legend", "tokenTypes") || []
        @semantic_styles ||= {}
        @semantic_styles[current.buffer] = [current.buffer.version, result.map { |token| token.merge(name: types[token[:type]]) }]
      when :inlayHint
        hints = result || []
        raise Error, "invalid inlay hints" unless hints.is_a?(Array)
        raise Error, "too many inlay hints" if hints.length > 10_000
        blocks = hints.map do |hint|
          raise Error, "invalid inlay hint" unless hint.is_a?(Hash) && hint["position"].is_a?(Hash)
          label = hint["label"]
          if label.is_a?(Array)
            raise Error, "invalid inlay hint label" unless label.all? { |part| part.is_a?(Hash) && part["value"].is_a?(String) && part["value"].valid_encoding? }
            label = label.map { |part| part["value"] }.join
          end
          row = hint["position"]["line"]
          raise Error, "invalid inlay hint" unless label.is_a?(String) && label.valid_encoding? && row.is_a?(Integer) && row.between?(0, current.buffer.line_count - 1)
          [row, label]
        end
        map = current.display_map
        map.block_map.blocks.keys.each { |id| map.remove_block(id) if id.is_a?(Array) && id.first == :inlay }
        blocks.each_with_index { |(row, label), index| map.insert_block([:inlay, index], row: row, text: label, kind: :inlay) }
      end
      @window&.request_frame
    end
  end
end

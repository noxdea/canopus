# frozen_string_literal: true

require "set"
require "zaniah/ui"

module Canopus
  module Workspace::HierarchyAware
    HIERARCHY_ITEM_LIMIT = 1_000
    HIERARCHY_TOTAL_LIMIT = 10_000
    HIERARCHY_DEPTH_LIMIT = 32
    HIERARCHY_REQUEST_LIMIT = 64
    HIERARCHY_TEXT_LIMIT = 4_096
    HIERARCHY_URI_LIMIT = 16_384
    HIERARCHY_ITEM_BYTES_LIMIT = 1 << 20

    def hierarchy_tree
      @hierarchy_tree ||= Zaniah::UI::TreeView.new([], height: 320).on_select do |value, _event, _context|
        select_hierarchy_item(value)
      end
    end

    def show_call_hierarchy(current = editor) = show_hierarchy(:call, current)
    def show_type_hierarchy(current = editor) = show_hierarchy(:type, current)

    def show_hierarchy(kind, current = editor)
      raise ArgumentError, "invalid hierarchy kind" unless %i[call type].include?(kind)

      self.palette = nil
      invalidate_hierarchy
      unless current&.buffer&.path
        @message = "Save the document before requesting a hierarchy"
        return false
      end

      snapshot = hierarchy_snapshot(kind, current)
      if snapshot[:client] && !snapshot[:capability]
        release_hierarchy_snapshot(snapshot)
        @message = "#{hierarchy_title(kind)} is not supported by this language server"
        return false
      end
      requests = @hierarchy_prepare_requests ||= {}
      id = @hierarchy_prepare_request_id = @hierarchy_prepare_request_id.to_i + 1
      requests[id] = snapshot
      start_hierarchy_prepare(id, snapshot)
      @message = "Preparing #{hierarchy_title(kind).downcase}…"
      nil
    rescue StandardError => error
      @hierarchy_prepare_requests&.delete_if { |_id, request| request.equal?(snapshot) }
      release_hierarchy_snapshot(snapshot) if snapshot
      @message = error.message
      false
    end

    def accept_hierarchy_root(palette, index)
      state = palette[:hierarchy]
      item = index && palette[:items]&.[](index)
      unless item && hierarchy_context_valid?(state)
        @message = "Hierarchy context changed; request again"
        return false
      end

      install_hierarchy(state, item)
    end

    def invalidate_hierarchy(buffer = nil, client: nil, editor: nil)
      invalidated = false
      @hierarchy_prepare_requests&.delete_if do |_id, snapshot|
        matches = (!buffer || snapshot[:buffer].equal?(buffer)) &&
          (!client || snapshot[:client]&.equal?(client)) && (!editor || snapshot[:editor].equal?(editor))
        if matches
          snapshot[:future]&.cancel
          release_hierarchy_snapshot(snapshot)
          invalidated = true
        end
        matches
      end

      candidate = @palette&.dig(:kind) == :hierarchy_roots && @palette[:hierarchy]
      candidate_matches = candidate && (!buffer || candidate[:buffer].equal?(buffer)) &&
        (!client || candidate[:client]&.equal?(client)) && (!editor || candidate[:editor].equal?(editor))
      self.palette = nil if candidate_matches

      state = @hierarchy_state
      clear_state = state && (!buffer || state[:buffer].equal?(buffer)) &&
        (!client || state[:client].equal?(client)) && (!editor || state[:editor].equal?(editor))
      if clear_state
        cancel_hierarchy_children(state)
        @hierarchy_state = nil
        hierarchy_tree.replace([])
        @panels.hide("hierarchy") if @panels.key?("hierarchy")
        invalidated = true
      end
      @hierarchy_generation = @hierarchy_generation.to_i + 1 if invalidated || candidate_matches
      @window&.request_frame unless @closed
      nil
    end

    private

    def hierarchy_snapshot(kind, current)
      buffer, offset = current.buffer, current.primary.head
      language = current.language_document.definition.name
      client = active_language_client(language, kind == :call ? "callHierarchy" : "typeHierarchy")
      generation = @hierarchy_generation = @hierarchy_generation.to_i + 1
      snapshot = {kind: kind, generation: generation, editor: current,
        document: current.language_document, buffer: buffer, version: buffer.version,
        selections: current.selections, offset: offset, rope: buffer.rope,
        uri: Sadr::Protocol.uri(buffer.path), position: Sadr::Protocol.position(buffer.rope, offset),
        language: language, client: client, capability: hierarchy_capability(client, kind)}
      unless Sadr::Protocol.offset(snapshot[:rope], snapshot[:position]) == offset
        raise Error, "invalid hierarchy position"
      end
      snapshot[:selection_subscription] = current.on_selection do
        invalidate_hierarchy(editor: current) unless current.selections == snapshot[:selections]
      end
      snapshot[:edit_subscription] = buffer.on_edit { invalidate_hierarchy(buffer) }
      snapshot
    end

    def start_hierarchy_prepare(id, snapshot)
      job = Thread.new do
        begin
          feature = snapshot[:kind] == :call ? "callHierarchy" : "typeHierarchy"
          owner = language_client(snapshot[:buffer], feature: feature)
          unless @hierarchy_prepare_requests&.[](id).equal?(snapshot) && hierarchy_editor_valid?(snapshot)
            next
          end
          if snapshot[:client] && !snapshot[:client].equal?(owner)
            raise Error, "Hierarchy cancelled because the language server changed"
          end
          snapshot[:client] = owner
          snapshot[:capability] = hierarchy_capability(owner, snapshot[:kind])
          unless snapshot[:capability]
            post do
              next unless take_hierarchy_prepare(id, snapshot)
              valid = hierarchy_editor_valid?(snapshot)
              release_hierarchy_snapshot(snapshot)
              @message = "#{hierarchy_title(snapshot[:kind])} is not supported by this language server" if valid
            end
            next
          end

          method = snapshot[:kind] == :call ? :prepare_call_hierarchy : :prepare_type_hierarchy
          future = owner.public_send(method, snapshot[:uri], snapshot[:position])
          snapshot[:future] = future
          result = future.await(timeout: 10) if hierarchy_prepare_valid?(id, snapshot, owner)
          unless hierarchy_prepare_valid?(id, snapshot, owner)
            future.cancel
            next
          end
          roots = normalize_hierarchy_items(result)
          post do
            next unless take_hierarchy_prepare(id, snapshot)
            unless hierarchy_context_valid?(snapshot)
              release_hierarchy_snapshot(snapshot)
              next
            end
            release_hierarchy_snapshot(snapshot)
            if roots.empty?
              @message = "No #{hierarchy_title(snapshot[:kind]).downcase} is available here"
            elsif roots.length == 1
              install_hierarchy(snapshot, roots.first)
            else
              self.palette = {kind: :hierarchy_roots, query: +"", index: 0,
                matches: roots.map { |item| hierarchy_label(item) }, items: roots, hierarchy: snapshot}
              update_palette
            end
          end
        rescue StandardError => error
          post do
            next unless take_hierarchy_prepare(id, snapshot)
            valid = hierarchy_editor_valid?(snapshot) && !(owner && @retired_language_clients&.[](owner))
            release_hierarchy_snapshot(snapshot)
            @message = error.message if valid
          end
        ensure
          worker = Thread.current
          post do
            release_hierarchy_snapshot(snapshot) if take_hierarchy_prepare(id, snapshot)
            @language_jobs&.delete(worker)
          end
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      true
    end

    def install_hierarchy(state, root)
      return false unless hierarchy_context_valid?(state)

      state[:remaining] = HIERARCHY_TOTAL_LIMIT - 1
      state[:node_id] = 0
      @hierarchy_state = state
      directions = hierarchy_directions(state[:kind]).map do |direction, label|
        id = next_hierarchy_node_id(state)
        {id: id, label: label, value: nil,
         children: ->(_value) { request_hierarchy_children(state, id, root, direction,
           [hierarchy_item_key(root)].to_set, 1) }}
      end
      item = {id: next_hierarchy_node_id(state), label: hierarchy_label(root),
        value: {generation: state[:generation], item: root}.freeze, children: directions.freeze}
      hierarchy_tree.replace([item.freeze])
      @panels.show("hierarchy")
      @message = hierarchy_title(state[:kind])
      @window&.request_frame
      true
    end

    def request_hierarchy_children(state, node_id, item, direction, ancestry, depth)
      return [] unless hierarchy_state_valid?(state)
      if (@hierarchy_child_requests || {}).length >= HIERARCHY_REQUEST_LIMIT
        return [hierarchy_status_node(state, "Too many pending hierarchy requests")]
      end

      id = @hierarchy_child_request_id = @hierarchy_child_request_id.to_i + 1
      request = {state: state, node_id: node_id, item: item, direction: direction,
        ancestry: ancestry, depth: depth, client: state[:client], capability: state[:capability]}
      (@hierarchy_child_requests ||= {})[id] = request
      placeholder = hierarchy_status_node(state, "Loading…")
      job = Thread.new do
        begin
          next unless hierarchy_child_valid?(id, request)
          future = hierarchy_followup_future(request[:client], state[:kind], direction, item)
          request[:future] = future
          result = future.await(timeout: 10) if hierarchy_child_valid?(id, request)
          unless hierarchy_child_valid?(id, request)
            future.cancel
            next
          end
          values = normalize_hierarchy_followup(state[:kind], direction, result, within: item)
          post do
            next unless take_hierarchy_child(id, request) && hierarchy_state_valid?(state)
            children = hierarchy_children(state, values, direction, ancestry, depth)
            hierarchy_tree.replace_children(node_id,
              children.empty? ? [hierarchy_status_node(state, "No results")] : children)
          end
        rescue StandardError => error
          post do
            next unless take_hierarchy_child(id, request) && hierarchy_state_valid?(state)
            hierarchy_tree.replace_children(node_id, [hierarchy_status_node(state, "Unavailable")])
            @message = error.message unless @retired_language_clients&.[](request[:client])
          end
        ensure
          worker = Thread.current
          post do
            @hierarchy_child_requests&.delete(id) if @hierarchy_child_requests&.[](id).equal?(request)
            @language_jobs&.delete(worker)
          end
        end
      end
      (@language_jobs ||= []) << job
      @language_jobs.reject! { |thread| !thread.alive? }
      [placeholder]
    end

    def hierarchy_children(state, values, direction, ancestry, depth)
      unique = {}
      values.each do |item|
        key = hierarchy_item_key(item)
        unique[key] ||= item unless ancestry.include?(key)
      end
      count = [unique.length, state[:remaining]].min
      state[:remaining] -= count
      unique.first(count).map do |key, item|
        id = next_hierarchy_node_id(state)
        node = {id: id, label: hierarchy_label(item),
          value: {generation: state[:generation], item: item}.freeze}
        if depth < HIERARCHY_DEPTH_LIMIT && state[:remaining].positive?
          branch = ancestry.dup.add(key).freeze
          node[:children] = ->(_value) { request_hierarchy_children(state, id, item, direction, branch, depth + 1) }
        end
        node.freeze
      end.freeze
    end

    def hierarchy_followup_future(client, kind, direction, item)
      method = if kind == :call
        direction == :incoming ? :call_hierarchy_incoming_calls : :call_hierarchy_outgoing_calls
      else
        direction == :supertypes ? :type_hierarchy_supertypes : :type_hierarchy_subtypes
      end
      client.public_send(method, item)
    end

    def normalize_hierarchy_followup(kind, direction, result, within:)
      return normalize_hierarchy_items(result) if kind == :type
      raise Error, "invalid call hierarchy" unless result.nil? || result.is_a?(Array)
      raise Error, "too many call hierarchy items" if result && result.length > HIERARCHY_ITEM_LIMIT

      key = direction == :incoming ? "from" : "to"
      Array(result).map do |call|
        raise Error, "invalid call hierarchy item" unless call.is_a?(Hash) && call.keys.all? { |name| name.is_a?(String) }
        ranges = call.fetch("fromRanges")
        unless ranges.is_a?(Array) && ranges.length <= HIERARCHY_ITEM_LIMIT
          raise Error, "invalid call hierarchy ranges"
        end
        target = normalize_hierarchy_item(call.fetch(key))
        outer = direction == :incoming ? target.fetch("range") : within.fetch("range")
        ranges.each do |range|
          edge = Sadr::Protocol.range_value(range)
          parent = Sadr::Protocol.range_value(outer)
          unless (hierarchy_position(parent.start) <=> hierarchy_position(edge.start)) <= 0 &&
              (hierarchy_position(edge.end) <=> hierarchy_position(parent.end)) <= 0
            raise Error, "call hierarchy range is outside its item"
          end
        end
        target
      end.freeze
    rescue JSON::GeneratorError, JSON::ParserError, JSON::NestingError, KeyError, TypeError,
      ArgumentError, Sadr::Error => error
      raise Error, "invalid call hierarchy: #{error.message}"
    end

    def normalize_hierarchy_items(result)
      raise Error, "invalid hierarchy items" unless result.nil? || result.is_a?(Array)
      raise Error, "too many hierarchy items" if result && result.length > HIERARCHY_ITEM_LIMIT

      Array(result).map { |item| normalize_hierarchy_item(item) }.freeze
    rescue JSON::GeneratorError, JSON::ParserError, JSON::NestingError, KeyError, TypeError,
      ArgumentError, Sadr::Error => error
      raise Error, "invalid hierarchy items: #{error.message}"
    end

    def normalize_hierarchy_item(value)
      raise Error, "invalid hierarchy item" unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) }
      encoded = JSON.generate(value)
      raise Error, "hierarchy item exceeds 1 MiB" if encoded.bytesize > HIERARCHY_ITEM_BYTES_LIMIT
      item = JSON.parse(encoded)
      hierarchy_text(item.fetch("name"), "name")
      kind = item.fetch("kind")
      raise Error, "invalid hierarchy kind" unless kind.is_a?(Integer) && kind.between?(1, 26)
      uri = hierarchy_text(item.fetch("uri"), "URI", maximum: HIERARCHY_URI_LIMIT)
      Sadr::Protocol.path(uri)
      range = Sadr::Protocol.range_value(item.fetch("range"))
      selection = Sadr::Protocol.range_value(item.fetch("selectionRange"))
      unless (hierarchy_position(range.start) <=> hierarchy_position(selection.start)) <= 0 &&
          (hierarchy_position(selection.end) <=> hierarchy_position(range.end)) <= 0
        raise Error, "hierarchy selection is outside its range"
      end
      hierarchy_text(item["detail"], "detail", empty: true) if item.key?("detail")
      unless !item.key?("tags") || item["tags"].is_a?(Array) && item["tags"].all? { |tag| tag == 1 }
        raise Error, "invalid hierarchy tags"
      end
      freeze_hierarchy_value(item)
    end

    def hierarchy_text(value, label, maximum: HIERARCHY_TEXT_LIMIT, empty: false)
      valid = value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding? &&
        value.bytesize <= maximum && !value.include?("\0")
      valid &&= !value.empty? unless empty
      raise Error, "invalid hierarchy #{label}" unless valid
      value
    end

    def freeze_hierarchy_value(value)
      value.each { |key, child| key.freeze; freeze_hierarchy_value(child) } if value.is_a?(Hash)
      value.each { |child| freeze_hierarchy_value(child) } if value.is_a?(Array)
      value.freeze
    end

    def hierarchy_position(position) = [position.line, position.character]

    def hierarchy_item_key(item)
      range = item.fetch("selectionRange")
      [item.fetch("uri"), item.fetch("kind"), item.fetch("name"),
       range.fetch("start").fetch("line"), range.fetch("start").fetch("character"),
       range.fetch("end").fetch("line"), range.fetch("end").fetch("character")].freeze
    end

    def hierarchy_label(item)
      path = Sadr::Protocol.path(item.fetch("uri"))
      line = item.dig("selectionRange", "start", "line") + 1
      detail = item["detail"].to_s.gsub(/\s+/, " ").strip
      label = [item.fetch("name").gsub(/\s+/, " ").strip, detail].reject(&:empty?).join(" — ")
      value = "#{label} · #{File.basename(path)}:#{line}"
      value.length > 200 ? value.each_char.first(199).join + "…" : value
    end

    def hierarchy_directions(kind)
      kind == :call ? [[:incoming, "Incoming calls"], [:outgoing, "Outgoing calls"]] :
        [[:supertypes, "Supertypes"], [:subtypes, "Subtypes"]]
    end

    def hierarchy_title(kind) = kind == :call ? "Call hierarchy" : "Type hierarchy"

    def hierarchy_capability(client, kind)
      return unless client&.respond_to?(:capabilities)
      provider = client.capabilities[kind == :call ? "callHierarchyProvider" : "typeHierarchyProvider"]
      return true if provider == true
      JSON.generate(provider) if provider.is_a?(Hash)
    rescue JSON::GeneratorError, JSON::NestingError
      nil
    end

    def hierarchy_editor_valid?(snapshot)
      current, buffer = snapshot.values_at(:editor, :buffer)
      !@closed && current.language_document.equal?(snapshot[:document]) && current.buffer.equal?(buffer) &&
        buffer.version == snapshot[:version] && current.selections == snapshot[:selections] &&
        current.primary.head == snapshot[:offset] && buffer.path && Sadr::Protocol.uri(buffer.path) == snapshot[:uri] &&
        @panes.any? { |pane| pane.active.equal?(current) }
    end

    def hierarchy_context_valid?(state)
      return false unless state && hierarchy_editor_valid?(state)
      feature = state[:kind] == :call ? "callHierarchy" : "typeHierarchy"
      client = active_language_client(state[:language], feature)
      client.equal?(state[:client]) && hierarchy_capability(client, state[:kind]) == state[:capability]
    end

    def hierarchy_prepare_valid?(id, snapshot, owner)
      @hierarchy_prepare_requests&.[](id).equal?(snapshot) && hierarchy_context_valid?(snapshot) &&
        snapshot[:client].equal?(owner) && @opened_lsp_documents&.key?([owner, snapshot[:buffer]])
    end

    def hierarchy_state_valid?(state)
      client = state[:client]
      !@closed && @hierarchy_state.equal?(state) && state[:generation] == @hierarchy_generation &&
        active_language_client(state[:language], state[:kind] == :call ? "callHierarchy" : "typeHierarchy").equal?(client) &&
        hierarchy_capability(client, state[:kind]) == state[:capability]
    end

    def hierarchy_child_valid?(id, request)
      @hierarchy_child_requests&.[](id).equal?(request) && hierarchy_state_valid?(request[:state]) &&
        request[:client].equal?(request[:state][:client]) && request[:capability] == request[:state][:capability]
    end

    def take_hierarchy_prepare(id, snapshot) = @hierarchy_prepare_requests&.delete(id).equal?(snapshot)
    def take_hierarchy_child(id, request) = @hierarchy_child_requests&.delete(id).equal?(request)

    def release_hierarchy_snapshot(snapshot)
      snapshot&.delete(:selection_subscription)&.detach
      snapshot&.delete(:edit_subscription)&.detach
      snapshot&.delete(:future)
      nil
    end

    def cancel_hierarchy_children(state = nil)
      @hierarchy_child_requests&.delete_if do |_id, request|
        matches = !state || request[:state].equal?(state)
        request[:future]&.cancel if matches
        matches
      end
      nil
    end

    def next_hierarchy_node_id(state)
      state[:node_id] += 1
      [:hierarchy, state[:generation], state[:node_id]].freeze
    end

    def hierarchy_status_node(state, label)
      {id: next_hierarchy_node_id(state), label: label, value: nil}.freeze
    end

    def select_hierarchy_item(value)
      state = @hierarchy_state
      return false unless value.is_a?(Hash) && state && value[:generation] == state[:generation] && hierarchy_state_valid?(state)

      item = value[:item]
      path = Sadr::Protocol.path(item.fetch("uri"))
      raise Error, "Hierarchy target is not a file" unless File.file?(path)
      target = open(path)
      position = Sadr::Protocol.range_value(item.fetch("selectionRange")).start
      offset = Sadr::Protocol.offset(target.buffer.rope, position)
      unless Sadr::Protocol.position(target.buffer.rope, offset) == position
        raise Error, "Hierarchy target position is no longer valid"
      end
      target.select(offset)
      target.reveal_cursor
      true
    rescue Error, KeyError, RangeError, TypeError, SystemCallError, Sadr::Error => error
      @message = "Cannot open hierarchy item: #{error.message}"
      false
    end
  end
end

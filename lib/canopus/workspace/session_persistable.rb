# frozen_string_literal: true

module Canopus
  module Workspace::SessionPersistable
    def save_session(path)
      records = {}
      record = lambda do |buffer|
        id = buffer.object_id.to_s
        return id if records.key?(id)
        records[id] = if buffer.is_a?(MultiBuffer)
          {excerpts: buffer.excerpts.map do |excerpt|
            {buffer: record.call(excerpt.buffer), first: excerpt.buffer.resolve(excerpt.first),
              last: excerpt.buffer.resolve(excerpt.last), title: excerpt.title}
          end}
        else
          {path: buffer.path, draft: buffer.dirty? || !buffer.path ? buffer.text : nil,
            digest: buffer.disk_digest, encoding: buffer.encoding.name, bom: buffer.bom.unpack1("H*"), read_only: buffer.read_only}
        end
        id
      end
      state = {version: 2, root: @root, layout: encode_layout(@layout), recent_files: @recent_files || [],
        active_pane: @panes.index(@active_pane), docks: @docks,
        terminals: @terminals.map { |current| {cwd: current.vt.cwd || (current.respond_to?(:initial_cwd) ? current.initial_cwd : @root), title: @terminal_names[current]} },
        active_terminal: @active_terminal_index, terminal_visible: !!@terminal_visible,
        panes: @panes.map do |pane|
          {active: pane.active_index, tabs: pane.editors.map do |current|
            {buffer_id: record.call(current.buffer), cursor: current.primary.head, pinned: pane.pinned.include?(current),
              selections: current.selections.map { |selection| {anchor: selection.anchor, head: selection.head} },
              scroll_x: current.scroll_x, scroll_y: current.scroll_y}
          end}
        end, buffers: records}
      state[:background_buffers] = @buffers.values.select(&:dirty?).map { |buffer| record.call(buffer) }
      FileUtils.mkdir_p(File.dirname(path))
      Tempfile.create([".session-", ".json"], File.dirname(path)) do |file|
        file.write(JSON.pretty_generate(state))
        file.flush
        file.fsync
        file.close
        File.rename(file.path, path)
      end
    end

    def restore_session(path)
      data = JSON.parse(File.read(path))
      raise Error, "unsupported session" unless [1, 2].include?(data["version"]) && data["panes"].is_a?(Array) && data["panes"].length.between?(1, 100)
      records = data.fetch("buffers", {})
      raise Error, "invalid session buffers" unless records.is_a?(Hash) && records.length <= 10_000
      loaded, restored_buffers, restored_panes = {}, {}, []
      load_buffer = lambda do |id|
        return loaded[id] if loaded.key?(id)
        entry = records.fetch(id)
        raise Error, "invalid session buffer" unless entry.is_a?(Hash)
        if entry["excerpts"]
          excerpts = entry["excerpts"]
          raise Error, "invalid session excerpts" unless excerpts.is_a?(Array) && excerpts.length <= 10_000
          sources = excerpts.map do |excerpt|
            source_id = excerpt.fetch("buffer")
            raise Error, "nested or cyclic excerpt source" if records.fetch(source_id).key?("excerpts")
            source = load_buffer.call(source_id)
            raise Error, "excerpt source no longer exists" unless source
            first, last = excerpt.values_at("first", "last")
            raise Error, "invalid excerpt range" unless first.is_a?(Integer) && last.is_a?(Integer) && first <= last
            [source, first...last, excerpt["title"]]
          end
          buffer = MultiBuffer.new(excerpts: sources)
        elsif entry["draft"]
          buffer = Buffer.new(entry["draft"], path: entry["path"], draft: true, disk_digest: entry["digest"],
            encoding: Encoding.find(entry.fetch("encoding", "UTF-8")), bom: [entry.fetch("bom", "")].pack("H*"), read_only: entry.fetch("read_only", false))
        elsif entry["path"] && File.file?(entry["path"])
          buffer = Buffer.open(entry["path"])
        end
        loaded[id] = buffer
        if buffer
          key = buffer.path ? canonical_path(buffer.path) : buffer.object_id
          if restored_buffers.key?(key)
            buffer.close
            raise Error, "duplicate session buffer path"
          end
          restored_buffers[key] = buffer
        end
        buffer
      end
      data["panes"].each do |saved|
        pane = Pane.new
        restored_panes << pane
        tabs = saved.fetch("tabs")
        raise Error, "invalid session tabs" unless tabs.is_a?(Array) && tabs.length <= 1000
        tabs.each do |tab|
          if data["version"] == 1
            tab["buffer_id"] = tab["path"] || "draft:#{tab.object_id}"
            records[tab["buffer_id"]] ||= tab
          end
          buffer = load_buffer.call(tab.fetch("buffer_id"))
          next unless buffer
          current = pane.open(buffer)
          current.language = definition_for(buffer.path)
          apply_editor_settings(current)
          if tab["selections"]
            selections = tab["selections"]
            raise Error, "invalid session selections" unless selections.is_a?(Array) && selections.length.between?(1, 10_000)
            selections.each_with_index do |selection, index|
              anchor, head = selection.values_at("anchor", "head")
              raise Error, "invalid session cursor" unless anchor.is_a?(Integer) && head.is_a?(Integer)
              current.select(anchor, head, add: index.positive?)
            end
          else
            begin
              current.select(tab.fetch("cursor", 0).clamp(0, buffer.rope.bytesize))
            rescue RangeError
              current.select(0)
            end
          end
          coordinates = [tab.fetch("scroll_x", 0), tab.fetch("scroll_y", 0)]
          raise Error, "invalid session scroll position" unless coordinates.all? { |value| value.is_a?(Numeric) && value.finite? && value >= 0 }
          current.scroll(dx: coordinates.first, dy: coordinates.last)
          pane.pin(current) if tab["pinned"]
        end
        pane.active_index = saved.fetch("active", 0).clamp(0, [pane.editors.length - 1, 0].max)
      end
      restored_layout = decode_layout(data.fetch("layout"), panes: restored_panes)
      layout_panes, pending = [], [restored_layout]
      until pending.empty?
        node = pending.pop
        node[:pane] ? layout_panes << node[:pane] : pending.concat(node[:children])
      end
      raise Error, "session layout must include each pane exactly once" unless layout_panes.length == restored_panes.length && layout_panes.uniq.length == restored_panes.length
      background = data.fetch("background_buffers", [])
      raise Error, "invalid background buffers" unless background.is_a?(Array) && background.length <= 10_000
      background.each { |id| load_buffer.call(id) }
      restored_docks = @docks.transform_values(&:dup)
      data.fetch("docks", {}).each do |side, value|
        next unless restored_docks.key?(side.to_sym)
        raise Error, "invalid session dock" unless value.is_a?(Hash) && [true, false].include?(value["visible"]) && value["size"].is_a?(Numeric) && value["size"].finite? && value["size"].positive?
        restored_docks[side.to_sym] = {visible: value["visible"], size: value["size"].clamp(40, 4000)}
      end
      active = data.fetch("active_pane", 0)
      raise Error, "invalid active pane" unless active.is_a?(Integer) && active.between?(0, restored_panes.length - 1)
      terminal_records = validate_session_terminals(data) if @settings["terminal"]["restore_on_startup"]
      clear_vim_states
      close_language_documents
      @panes.each { |pane| pane.editors.each(&:dispose) }
      @buffers.each_value(&:close)
      @panes, @buffers, @layout, @docks = restored_panes, restored_buffers, restored_layout, restored_docks
      @active_pane = @panes[active]
      @recent_files = Array(data["recent_files"]).select { |item| item.is_a?(String) && File.file?(item) }.first(100)
      restore_terminals(data, terminal_records) if terminal_records
      self
    rescue StandardError
      unless @panes.equal?(restored_panes)
        restored_panes&.each { |pane| pane.editors.each(&:dispose) }
        restored_buffers&.each_value(&:close)
      end
      raise
    end

    private

    def validate_session_terminals(data)
      records = data.fetch("terminals", [])
      raise Error, "invalid session terminals" unless records.is_a?(Array) && records.length <= 100 && records.all? { |item| item.is_a?(Hash) && item["cwd"].is_a?(String) }
      active = data.fetch("active_terminal", 0)
      raise Error, "invalid active terminal" unless records.empty? || active.is_a?(Integer) && active.between?(0, records.length - 1)
      records
    end

    def restore_terminals(data, records)
      old, old_index, old_visible = @terminals, @active_terminal_index, @terminal_visible
      @terminals = []
      records.each do |record|
        cwd = File.directory?(record["cwd"]) ? record["cwd"] : @root
        created = new_terminal(cwd: cwd)
        rename_terminal(record["title"], created) if record["title"].is_a?(String)
      end
      @active_terminal_index = @terminals.empty? ? 0 : data.fetch("active_terminal", 0)
      @terminal_visible = !!data["terminal_visible"] && !@terminals.empty?
      old.each { |current| current.close if current.respond_to?(:close) }
    rescue StandardError
      @terminals.each { |current| current.close if current.respond_to?(:close) }
      @terminals = old
      @active_terminal_index, @terminal_visible = old_index, old_visible
      @message = "Session restored; terminals could not start"
    end
  end
end

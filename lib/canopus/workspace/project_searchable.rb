# frozen_string_literal: true

module Canopus
  module Workspace::ProjectSearchable
    SearchSource = Data.define(:buffer, :version, :rope, :encoding, :bom, :digest, :line_ending, :dirty, :read_only)
    SearchPreparation = Struct.new(:sources, :buffers, :editor, :count, :settings) do
      def close
        editor&.dispose
        editor&.buffer&.close
        buffers.each_value(&:close)
      end
    end
    private_constant :SearchSource, :SearchPreparation

    # Capture immutable open-buffer snapshots on the foreground. File IO,
    # scanning and the complete private result Editor are prepared off-thread.
    def search_project(query, regexp: false, case_sensitive: true, whole_word: false, async: true)
      raise Error, "Workspace closed" if @closed
      raise Error, "Search query cannot be empty" if query.empty?
      expression = regexp ? query : Regexp.escape(query)
      expression = "\\b(?:#{expression})\\b" if whole_word
      pattern = Regexp.new(expression, case_sensitive ? 0 : Regexp::IGNORECASE, timeout: 0.25)
      cancel_project_search
      @message = "Searching project…" if async
      prepare_project_search(pattern, @search_generation, search_sources, settings: search_editor_settings, async: async)
    end

    def cancel_project_search
      prepared = (@search_prepare_lock ||= Mutex.new).synchronize do
        @search_generation = (@search_generation || 0) + 1
        saved, @search_prepared = @search_prepared, nil
        saved
      end
      prepared&.close
      nil
    end

    def replace_in_buffer(pattern, replacement, **options)
      if editor.buffer.is_a?(MultiBuffer)
        changes = editor.replacement_edits(pattern, replacement, **options).select do |range, _text|
          editor.buffer.excerpts.any? { |excerpt| range.begin >= excerpt.view_start && range.end <= excerpt.view_end }
        end
        editor.edit(changes, kind: :replace_all)
        changes.length
      else
        editor.replace_all(pattern, replacement, **options)
      end
    end

    private

    def search_sources
      @buffers.values.each_with_object({}) do |buffer, sources|
        path = buffer.path
        next unless path&.start_with?(@root + File::SEPARATOR)
        sources[path] = SearchSource.new(buffer, buffer.version, buffer.rope, buffer.encoding,
          buffer.bom, buffer.disk_digest, buffer.line_ending, buffer.dirty?, buffer.read_only)
      end.freeze
    end

    def search_cancelled?(generation) = @closed || generation != @search_generation

    def search_editor_settings
      settings = @settings.for_language("text")
      [settings["tab_size"], settings["use_tabs"], settings["soft_wrap"]].freeze
    end

    def prepare_project_search(pattern, generation, sources, settings:, paths: nil, async: true)
      work = lambda do
        prepared = nil
        paths ||= search_project_paths(pattern, generation)
        next if search_cancelled?(generation)
        prepared = build_search_preparation(pattern, generation, sources, paths, settings)
        next unless prepared
        if async
          accepted = @search_prepare_lock.synchronize do
            @search_prepared = prepared unless search_cancelled?(generation)
          end
          if accepted
            prepared = nil # Queued callbacks must not retain disposed private buffers.
            queue_search_install(pattern, generation, paths)
          end
        else
          result = install_search_preparation(prepared, pattern, generation, paths, async: false)
          prepared = nil
          result
        end
      rescue StandardError => error
        raise unless async
        queue_search_error(generation, error.message)
      ensure
        prepared&.close
      end
      async ? @search_job = Thread.new(&work) : work.call
    end

    def search_project_paths(pattern, generation)
      project_search_matches(pattern, cancelled: -> { search_cancelled?(generation) }).map(&:path).uniq.freeze
    end

    def workspace_symbol_fallback(query, generation, deadline)
      matches = project_search_matches(query, ignore_case: true,
        cancelled: -> { workspace_symbol_cancelled?(generation, deadline) })
      cancelled = -> { workspace_symbol_cancelled?(generation, deadline) }
      lines, paths, symbols = {}.compare_by_identity, {}, []
      matches.each do |match|
        break if cancelled.call
        symbol = fallback_workspace_symbol(match, lines: lines, paths: paths, cancelled: cancelled)
        symbols << symbol if symbol
      end
      symbols.freeze
    end

    def project_search_matches(pattern, ignore_case: false, cancelled:)
      Alkaid::Search.new(@root, pattern: pattern, ignore_case: ignore_case, ignore: @project.ignore_matcher, workers: 4,
        max_file_size: 10 * 1024 * 1024, max_matches: 10_000, hidden: true, cancelled: cancelled).run
    end

    def fallback_workspace_symbol(match, lines: {}.compare_by_identity, paths: {}, cancelled: -> { false })
      absolute = if paths.key?(match.path)
        paths[match.path]
      else
        paths[match.path] = File.realpath(File.join(@root, match.path))
      end
      prefix = @root.end_with?(File::SEPARATOR) ? @root : @root + File::SEPARATOR
      return unless absolute.start_with?(prefix)

      range = match.ranges.first
      state = lines[match.line] ||= {valid: match.line.valid_encoding?, offset: 0, units: 0}
      return unless state[:valid] && range && range.begin >= 0 && range.end <= match.line.bytesize &&
        match.line_number.positive? && !cancelled.call
      first = workspace_symbol_utf16_column(match.line, range.begin, state, cancelled)
      last = workspace_symbol_utf16_column(match.line, range.end, state, cancelled)
      return unless first && last
      preview = fallback_workspace_symbol_preview(match.line, range)
      return if preview.empty?
      {"name" => preview.freeze, "kind" => 13, "containerName" => match.path.dup.freeze,
        "location" => {"uri" => Sadr::Protocol.uri(absolute).freeze, "range" => {
          "start" => {"line" => match.line_number - 1, "character" => first}.freeze,
          "end" => {"line" => match.line_number - 1, "character" => last}.freeze
        }.freeze}.freeze}.freeze
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, EncodingError
      nil
    end

    def workspace_symbol_utf16_column(line, target, state, cancelled)
      offset, units = target < state[:offset] ? [0, 0] : state.values_at(:offset, :units)
      update = offset == state[:offset]
      while offset < target
        return if cancelled.call
        finish = [offset + Workspace::LanguageAware::WORKSPACE_SYMBOL_UTF16_CHUNK_BYTES, target].min
        if finish < target
          finish -= 1 while finish > offset && line.getbyte(finish)&.between?(0x80, 0xBF)
        end
        return if finish <= offset
        units += line.byteslice(offset, finish - offset).encode(Encoding::UTF_16LE).bytesize / 2
        offset = finish
      end
      state[:offset], state[:units] = offset, units if update
      units
    end

    def fallback_workspace_symbol_preview(line, range)
      first = [range.begin - 96, 0].max
      first += 1 while first < range.begin && line.getbyte(first)&.between?(0x80, 0xBF)
      last = [first + Workspace::LanguageAware::WORKSPACE_SYMBOL_PREVIEW_BYTES, line.bytesize].min
      last -= 1 while last > range.begin && line.getbyte(last)&.between?(0x80, 0xBF)
      preview = line.byteslice(first, last - first).to_s.gsub(/\s+/, " ").strip
      bounded_workspace_symbol_text(preview, Workspace::LanguageAware::WORKSPACE_SYMBOL_PREVIEW_BYTES)
    end

    def build_search_preparation(pattern, generation, sources, paths, settings)
      prepared = SearchPreparation.new(sources, {}, nil, 0, settings)
      excerpts = []
      candidates = paths.map { |relative| File.join(@root, relative) } | sources.keys
      candidates.sort.each do |candidate|
        return if search_cancelled?(generation)
        path = sources.key?(candidate) ? candidate : File.realpath(candidate)
        next unless path.start_with?(@root + File::SEPARATOR)
        next if prepared.buffers.key?(path) # Canonical aliases share one source.
        snapshot = sources[path]
        next if snapshot && (snapshot.read_only || snapshot.rope.bytesize > 10 << 20)
        next if !snapshot && File.size(path) > 10 << 20
        buffer = if snapshot
          # Nonempty text supplies the source's original line-ending metadata;
          # rope: shares the immutable snapshot, without materializing its text.
          Buffer.new(snapshot.line_ending, path: path, rope: snapshot.rope, encoding: snapshot.encoding,
            bom: snapshot.bom, disk_digest: snapshot.digest, draft: snapshot.dirty)
        else
          Buffer.open(path)
        end
        prepared.buffers[path] = buffer
        if buffer.read_only || buffer.rope.bytesize > 10 << 20
          prepared.buffers.delete(path)
          buffer.close
          next
        end
        ranges, matches = search_excerpt_ranges(buffer.rope, pattern, 10_000 - prepared.count, generation)
        return if search_cancelled?(generation)
        prepared.count += matches
        relative = path.delete_prefix(@root + File::SEPARATOR)
        ranges.each { |range| excerpts << [buffer, range, "#{relative}:#{buffer.rope.point_at(range.begin).row + 1}"] }
        break if prepared.count >= 10_000
      rescue Errno::ENOENT, Errno::EACCES
        next
      end
      projection = MultiBuffer.new(excerpts: excerpts)
      return if search_cancelled?(generation)
      prepared.editor = Editor.new(projection, tab_size: settings[0], wrap_width: settings[2] ? 100 : nil)
      prepared.editor.use_tabs = settings[1]
      result, prepared = prepared, nil
      result
    ensure
      projection&.close if prepared && !prepared.editor
      prepared&.close
    end

    def search_excerpt_ranges(rope, pattern, limit, generation)
      ranges, count = [], 0
      Canopus.with_regexp_timeout(pattern) do
        rope.to_s.to_enum(:scan, pattern).each do
          break if search_cancelled?(generation)
          match = Regexp.last_match
          row, last_row = rope.point_at(match.bytebegin(0)).row, rope.point_at(match.byteend(0)).row
          first = rope.line_start([row - 1, 0].max)
          last = last_row + 2 < rope.line_count ? rope.line_start(last_row + 2) : rope.bytesize
          ranges.last && first <= ranges.last.end ? ranges[-1] = ranges.last.begin...[ranges.last.end, last].max : ranges << (first...last)
          count += 1
          break if count >= limit
        end
      end
      [ranges, count]
    end

    def queue_search_install(pattern, generation, paths)
      post do
        prepared = @search_prepare_lock.synchronize do
          next if search_cancelled?(generation)
          saved, @search_prepared = @search_prepared, nil
          saved
        end
        install_search_preparation(prepared, pattern, generation, paths) if prepared
      rescue StandardError => error
        @message = error.message unless search_cancelled?(generation)
      end
    end

    def queue_search_error(generation, message)
      post { @message = message unless search_cancelled?(generation) }
    end

    def install_search_preparation(prepared, pattern, generation, paths, async: true)
      return if search_cancelled?(generation)
      current = search_sources
      settings = search_editor_settings
      unchanged = settings == prepared.settings && current.keys == prepared.sources.keys && current.all? do |path, source|
        before = prepared.sources.fetch(path)
        source.buffer.equal?(before.buffer) && source.version == before.version && source.rope.equal?(before.rope) && source.read_only == before.read_only
      end
      unless unchanged
        prepared.close
        prepared = nil
        return prepare_project_search(pattern, generation, current, settings: settings, paths: paths, async: async)
      end
      projection = prepared.editor.buffer
      bound = prepared.sources.empty? ? {} : projection.excerpts.to_h { |excerpt| [excerpt.buffer, true] }
      replacements = prepared.sources.each_with_object({}) do |(path, source), result|
        clone = prepared.buffers[path]
        result[clone] = source.buffer if clone && bound.key?(clone)
      end
      projection.attach_sources(replacements)
      prepared.buffers.each { |path, buffer| @buffers[path] ||= buffer unless prepared.sources.key?(path) }
      @buffers[projection.object_id] = projection
      @active_pane.editors << prepared.editor
      @active_pane.activate(@active_pane.editors.length - 1)
      invalidate_hidden_selection_ranges
      @message = "#{prepared.count} matches — edit excerpts, then Save to save source files"
      @window&.request_frame
      prepared = nil
      projection
    ensure
      prepared&.close
    end
  end
end

# frozen_string_literal: true

module Canopus
  module Workspace::GitConflictResolution
    MERGE_MAX_BYTES = 1 << 20
    MERGE_MAX_LINES = 2_000
    CONFLICT_MODES = [0o100644, 0o100755, 0o120000].freeze
    CONFLICT_CHOICES = %i[ours theirs both manual].freeze

    GitConflictContent = Data.define(:raw, :text, :encoding, :bom, :mode)
    GitConflictCapture = Data.define(:conflict, :contents)
    GitConflictPrepared = Data.define(:capture, :result, :reason)
    GitConflictView = Data.define(:session, :role, :region)
    GitConflictSession = Struct.new(:prepared, :result, :panes, :buffers, :editors, :choices, :mode,
      keyword_init: true)

    def show_git_conflicts(path = nil, async: !!@window)
      state = git_state
      raise Error, "Not a Git repository" unless state
      raise Error, "Conflict resolution already in progress" if @git_conflict_resolve_job
      path = safe_git_diff_path(path) if path
      raise Error, "Finish the current manual conflict edit first" if git_conflict_editing?

      generation = @git_conflict_generation = (@git_conflict_generation || 0) + 1
      work = -> { prepare_git_conflict(capture_git_conflict(state, path)) }
      return install_git_conflict(work.call) unless @window && async

      @message = "Loading merge conflict…"
      worker = Thread.new do
        current = Thread.current
        prepared = work.call
        post { finish_git_conflict_load(current, generation, prepared, nil) } unless @closed
      rescue StandardError => error
        post { finish_git_conflict_load(current, generation, nil, error) } unless @closed
      end
      (@git_conflict_load_jobs ||= []) << worker
      worker
    end

    alias_method :show_git_conflict, :show_git_conflicts

    def resolve_git_conflict(choice, content: nil, mode: nil, async: !!@window, expected: nil)
      raise ArgumentError, "invalid conflict choice" unless CONFLICT_CHOICES.include?(choice)
      raise ArgumentError, "content is only accepted for manual resolution" if content && choice != :manual
      if mode && !%i[both manual].include?(choice)
        raise ArgumentError, "mode is only accepted for both or manual resolution"
      end
      session = @git_conflict_session
      raise Error, "Open a merge conflict first" unless session
      raise Error, "Merge conflict view is stale" if expected && !expected.equal?(session)
      raise Error, "Conflict resolution already in progress" if @git_conflict_resolve_job
      if session.prepared.reason && !%i[ours theirs].include?(choice)
        raise Error, "#{session.prepared.reason}; choose ours or theirs"
      end
      unless mode.nil? || CONFLICT_MODES.include?(mode)
        raise ArgumentError, "invalid conflict resolution mode"
      end
      if session.mode && mode && session.mode != mode
        raise Error, "Conflict resolution mode changed"
      end
      session.mode ||= mode

      if session.result&.conflicts&.any?
        region = session.result.regions.first
        resolution = case choice
        when :ours then :ours
        when :theirs then :theirs
        when :both then :ours_then_theirs
        else
          content = session.buffers.fetch(:ours).text if content.nil?
          validate_manual_conflict_text(content)
        end
        resolved = Porrima::Merge.resolve(session.result, region.index, resolution)
        unless resolved.resolved?
          session.result = resolved
          session.choices << choice
          install_git_conflict_region(session)
          return session.editors.fetch(:ours)
        end
        content = Porrima::Merge.to_resolved_text(resolved)
      elsif session.result
        content = choice == :manual ? (content || session.buffers.fetch(:ours).text) :
          Porrima::Merge.to_resolved_text(session.result)
      elsif choice == :manual
        raise Error, "Manual resolution requires content" unless content.is_a?(String)
      end

      arguments = git_conflict_resolution_arguments(session, choice, content, session.mode)
      schedule_git_conflict_resolution(session, arguments, async: async)
    end

    def git_conflict_decorations(buffer, rows)
      view = buffer.instance_variable_get(:@git_conflict_view)
      return [] unless view && view.session.equal?(@git_conflict_session)

      first = [rows.begin, 0].max
      last = [rows.exclude_end? ? rows.end : rows.end + 1, buffer.line_count].min
      items = (first...last).map do |row|
        Decoration::Item.new(:line, nil, row, nil, {color: "#f9758326"}.freeze,
          10, :merge_conflict, nil)
      end
      return items unless view.role == :ours && rows.cover?(0)

      choices = view.session.prepared.reason ? %i[ours theirs] : CONFLICT_CHOICES
      choices.each_with_index do |choice, index|
        label = {ours: "Use ours", theirs: "Use theirs", both: "Use both", manual: "Use manual edit"}.fetch(choice)
        click = lambda do |_current, _offset|
          resolve_git_conflict(choice, expected: view.session)
        rescue StandardError => error
          self.message = "Merge conflict: #{error.message}"
        end
        items << Decoration::Item.new(:block, nil, 0, label,
          {height: 20, position: :above, color: :accent, padding_left: index * 8}.freeze,
          20 + index, :merge_conflict, click)
      end
      items
    end

    def close_git
      @git_conflict_generation = (@git_conflict_generation || 0) + 1
      jobs = Array(@git_conflict_load_jobs).compact.reject { |thread| thread.equal?(Thread.current) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.1
      jobs.each do |thread|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break unless remaining.positive?
        thread.join(remaining)
      end
      jobs.each { |thread| thread.kill if thread.alive? }
      jobs.each(&:join)
      @git_conflict_resolve_job&.join unless @git_conflict_resolve_job.equal?(Thread.current)
      @git_conflict_load_jobs&.clear
      @git_conflict_session = nil
      super
    end

    private

    def capture_git_conflict(state, path = nil)
      state.synchronize do |repository|
        conflicts = repository.conflicts
        conflict = path ? conflicts.find { |entry| entry.path == path } : conflicts.first
        raise Error, "No merge conflict for #{path}" if path && !conflict
        next unless conflict

        contents = %i[base ours theirs].to_h do |role|
          entry = conflict.public_send(role)
          raw = if entry && entry.mode != 0o160000
            type, value = repository.object(entry.oid)
            raise Thuban::CorruptObject, "conflict entry is not a blob" unless type == "blob"
            value.dup.freeze
          end
          [role, GitConflictContent.new(raw, nil, nil, nil, entry&.mode)]
        end.freeze
        GitConflictCapture.new(conflict, contents)
      end
    end

    def prepare_git_conflict(capture)
      return unless capture

      raw_contents = capture.contents.values.filter_map(&:raw)
      if raw_contents.sum(&:bytesize) > MERGE_MAX_BYTES
        return GitConflictPrepared.new(capture, nil, "Conflict exceeds 1 MiB; choose a complete side".freeze)
      end
      decoded = capture.contents.transform_values do |content|
        next content unless content.raw
        text, encoding, bom = Buffer.decode_bytes(content.raw)
        raise EncodingError unless content.raw == bom + text.encode(encoding).b
        content.with(text: text.freeze, encoding: encoding, bom: bom.dup.freeze)
      rescue EncodingError, Error
        content
      end.freeze
      capture = capture.with(contents: decoded)
      present = decoded.values.select(&:raw)
      reason = if present.any? { |entry| entry.text.nil? }
        "Binary or undecodable conflict; choose a complete side"
      elsif present.sum { |entry| entry.text.count("\n") + 1 } > MERGE_MAX_LINES
        "Conflict exceeds 2,000 lines; choose a complete side"
      elsif present.any? { |entry| entry.text.match?(/\r(?!\n)|[\u2028\u2029]/) }
        "Conflict uses unsupported line separators; choose a complete side"
      elsif present.map { |entry| [entry.encoding, entry.bom] }.uniq.length > 1
        "Conflict encodings differ; choose a complete side"
      end
      return GitConflictPrepared.new(capture, nil, reason.freeze) if reason

      values = decoded.transform_values { |entry| entry.text || "" }
      result = Porrima::Merge.three_way(base: values.fetch(:base), ours: values.fetch(:ours),
        theirs: values.fetch(:theirs))
      GitConflictPrepared.new(capture, result, nil)
    end

    def finish_git_conflict_load(worker, generation, prepared, error)
      @git_conflict_load_jobs&.delete(worker)
      return unless generation == @git_conflict_generation
      return self.message = "Merge conflict: #{error.message}" if error

      install_git_conflict(prepared)
    end

    def install_git_conflict(prepared, panes: nil)
      unless prepared
        cleanup_git_conflict_session(@git_conflict_session)
        @git_conflict_session = nil
        self.message = "No merge conflicts"
        return nil
      end

      panes ||= @git_conflict_session&.panes
      if @git_conflict_session && (!panes || panes.length != 3 || panes.uniq.length != 3 ||
          panes.any? { |pane| !@panes.include?(pane) })
        cleanup_git_conflict_session(@git_conflict_session)
        panes = nil
      else
        cleanup_git_conflict_buffers(@git_conflict_session) if @git_conflict_session
      end
      panes ||= create_git_conflict_panes
      session = GitConflictSession.new(prepared: prepared, result: prepared.result, panes: panes,
        buffers: {}, editors: {}, choices: [], mode: nil)
      @git_conflict_session = session
      install_git_conflict_region(session)
      self.message = "Resolve #{scm_display_path(prepared.capture.conflict.path)}"
      session.editors.fetch(:ours)
    end

    def create_git_conflict_panes
      panes = [@active_pane]
      2.times do
        focus(panes.last)
        pane = split(:horizontal)
        if (duplicate = pane.active)
          pane.close(duplicate, discard: true)
          release_buffer(duplicate.buffer, discard: true)
        end
        panes << pane
      end
      panes.freeze
    end

    def install_git_conflict_region(session)
      cleanup_git_conflict_buffers(session)
      region = session.result&.regions&.first
      conflict = region&.conflict
      contents = if conflict
        {base: conflict.base, ours: conflict.ours, theirs: conflict.theirs}
      elsif session.result
        captured = session.prepared.capture.contents
        {base: captured.fetch(:base).text || "", ours: Porrima::Merge.to_resolved_text(session.result),
          theirs: captured.fetch(:theirs).text || ""}
      else
        session.prepared.capture.contents.transform_values do |entry|
          entry.text || (entry.raw ? "[binary content unavailable]\n" : "[deleted]\n")
        end
      end
      source = File.join(@root, session.prepared.capture.conflict.path)
      definition = definition_for(source)
      %i[base ours theirs].each_with_index do |role, index|
        editable = role == :ours && (session.result || session.prepared.reason.nil?)
        label = "#{scm_display_path(File.basename(source))} [#{role}]"
        buffer = Buffer.new(contents.fetch(role), read_only: !editable)
        buffer.instance_variable_set(:@display_name, label.freeze)
        buffer.instance_variable_set(:@git_conflict_view, GitConflictView.new(session, role, region))
        @buffers[buffer.object_id] = buffer
        current = session.panes.fetch(index).open(buffer)
        current.language = definition
        apply_editor_settings(current)
        session.buffers[role] = buffer
        session.editors[role] = current
      end
      @decorations.invalidate(:merge_conflict)
      focus(session.panes.fetch(1))
      invalidate_hidden_selection_ranges
      @window&.request_frame
      session.editors.fetch(:ours)
    end

    def git_conflict_resolution_arguments(session, choice, content, mode)
      capture = session.prepared.capture
      return {choice: choice} unless session.result
      choices = session.choices + [choice]
      %i[ours theirs].each do |role|
        side = capture.contents.fetch(role)
        return {choice: role} if side.raw.nil? && content.empty? && choices.all?(role)
      end
      raw = encode_git_conflict_text(capture, content)
      if %i[ours theirs].include?(choice) && choices.all?(choice)
        selected = capture.contents.fetch(choice)
        return {choice: choice} if selected.raw == raw && (mode.nil? || mode == selected.mode)
      end
      matching = %i[ours theirs].select do |role|
        side = capture.contents.fetch(role)
        side.raw == raw && (mode.nil? || mode == side.mode)
      end
      return {choice: matching.first} if matching.one?
      selected_role = %i[ours theirs].find { |role| choices.all?(role) }
      selected_side_mode = selected_role && capture.conflict.public_send(selected_role)&.mode
      selected_mode = mode || (selected_side_mode if CONFLICT_MODES.include?(selected_side_mode)) ||
        git_conflict_mode(capture.conflict)
      {choice: :manual, content: raw, mode: selected_mode}
    end

    def encode_git_conflict_text(capture, text)
      text = validate_manual_conflict_text(text)
      codec = capture.contents.values.find(&:raw)
      codec ? codec.bom + text.encode(codec.encoding).b : text.b
    rescue EncodingError => error
      raise Error, "Cannot encode conflict resolution: #{error.message}"
    end

    def validate_manual_conflict_text(text)
      raise Error, "Manual resolution requires UTF-8 text" unless text.is_a?(String) && text.valid_encoding? && !text.include?("\0")
      text.encode(Encoding::UTF_8)
    rescue EncodingError
      raise Error, "Manual resolution requires UTF-8 text"
    end

    def git_conflict_mode(conflict)
      modes = [conflict.ours, conflict.theirs].compact.map(&:mode).select { |value| CONFLICT_MODES.include?(value) }.uniq
      raise Error, "Conflict resolution mode is ambiguous" unless modes.length == 1
      modes.first
    end

    def schedule_git_conflict_resolution(session, arguments, async:)
      state = git_state
      generation = @git_conflict_generation = (@git_conflict_generation || 0) + 1
      work = lambda do
        path = state.synchronize do |repository|
          repository.resolve_conflict(session.prepared.capture.conflict, **arguments)
        end
        prepared = prepare_git_conflict(capture_git_conflict(state))
        snapshot = state.capture rescue nil
        [path, prepared, snapshot].freeze
      end
      set_git_conflict_buffer_locked(session, true)
      unless @window && async
        result = work.call
        finish_git_conflict_resolution(session, generation, result, nil)
        return result.first
      end

      self.message = "Resolving merge conflict…"
      @git_conflict_resolve_job = Thread.new do
        current = Thread.current
        result = work.call
        post { finish_git_conflict_resolution(session, generation, result, nil, current) } unless @closed
      rescue StandardError => error
        post { finish_git_conflict_resolution(session, generation, nil, error, current) } unless @closed
      end
    rescue StandardError => error
      set_git_conflict_buffer_locked(session, false)
      invalidate_git if error.is_a?(Thuban::RefLockError)
      raise
    end

    def finish_git_conflict_resolution(session, generation, result, error, worker = nil)
      @git_conflict_resolve_job = nil if !worker || @git_conflict_resolve_job.equal?(worker)
      return unless generation == @git_conflict_generation && session.equal?(@git_conflict_session)
      if error
        set_git_conflict_buffer_locked(session, false)
        invalidate_git if error.is_a?(Thuban::RefLockError)
        self.message = "Merge conflict: #{error.message}"
        return
      end

      path, prepared, snapshot = result
      panes = session.panes
      invalidate_git
      install_git_snapshot(git_state, snapshot) if snapshot
      if prepared
        install_git_conflict(prepared, panes: panes)
      else
        cleanup_git_conflict_session(session)
        @git_conflict_session = nil
        self.message = "Resolved #{scm_display_path(path)}; no merge conflicts remain"
      end
      path
    end

    def cleanup_git_conflict_buffers(session)
      return unless session
      session.editors.to_a.each do |role, current|
        pane = session.panes[%i[base ours theirs].index(role)]
        pane.close(current, discard: true) if pane && pane.editors.include?(current)
        release_buffer(current.buffer, discard: true)
      end
      session.buffers.clear
      session.editors.clear
    end

    def cleanup_git_conflict_session(session)
      return unless session
      cleanup_git_conflict_buffers(session)
      session.panes.drop(1).reverse_each { |pane| close_empty_pane(pane) if @panes.include?(pane) && pane.editors.empty? }
      focus(session.panes.first) if @panes.include?(session.panes.first)
      @decorations.invalidate(:merge_conflict)
    end

    def git_conflict_editing?
      session = @git_conflict_session
      session && session.buffers.fetch(:ours, nil)&.dirty?
    end

    def set_git_conflict_buffer_locked(session, locked)
      buffer = session&.buffers&.fetch(:ours, nil)
      return unless buffer && session.result

      buffer.instance_variable_set(:@read_only, locked)
      @window&.request_frame
    end
  end
end

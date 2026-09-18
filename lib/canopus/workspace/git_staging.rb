# frozen_string_literal: true

require "zaniah/ui"

module Canopus
  module Workspace::GitStaging
    SCM_SECTIONS = {staged: "Staged", unstaged: "Changes", untracked: "Untracked"}.freeze
    SCM_DIFF_MAX_BYTES = 10 << 20
    SCM_DIFF_MAX_LINES = 200_000
    SCM_DIFF_BUDGET = Porrima::Budget.new(max_bytes: 1 << 20, max_lines: 2_000)
    SCM_COMMIT_SUBJECT_GUIDE = 50
    SCM_COMMIT_BODY_GUIDE = 72
    SCMContent = Data.define(:exists, :raw, :text, :encoding, :bom, :mode)
    SCMDiffSnapshot = Data.define(:path, :kind, :head, :index_entries, :worktree, :conflicted, :before, :after,
      :diff, :hunks, :lines, :hunk_rows, :line_rows)

    def scm_tree
      return @scm_tree if @scm_tree

      @scm_tree = Zaniah::UI::TreeView.new(scm_nodes, height: 600).on_select do |change, event, _context|
        select_scm_change(change, event)
      end
      SCM_SECTIONS.each_key { |kind| @scm_tree.expand([:scm_section, kind]) }
      refresh_scm
      @scm_tree
    end

    def scm_panel
      @scm_commit_message ||= +""
      @scm_commit_input ||= Zaniah::UI::TextArea.new(@scm_commit_message, rows: 5,
        label: "Commit message", placeholder: "Subject\n\nBody").on_change do |value|
        @scm_commit_message = value
      end
      @scm_commit_amend ||= false
      @scm_commit_amend_control ||= Zaniah::UI::Checkbox.new("Amend", value: @scm_commit_amend).on_change do |value, *, **|
        @scm_commit_amend = value
      end
      @scm_commit_button ||= Zaniah::UI::Button.new("Commit").on_click { submit_scm_commit }
      guide = Zaniah::UI::Label.new(
        "Subject guide: #{SCM_COMMIT_SUBJECT_GUIDE} columns · Body guide: #{SCM_COMMIT_BODY_GUIDE} columns",
        tone: :muted, size: :xs, wrap: :word
      )
      controls = Zaniah::Div.new.flex_row.items_center.gap(8)
        .children([@scm_commit_amend_control, @scm_commit_button])
      Zaniah::Div.new.flex_col.gap(8).p(4)
        .children([@scm_commit_input, guide, controls, scm_tree.flex_1])
    end

    def commit_git(message = nil, amend: nil)
      message = message.nil? ? @scm_commit_message.to_s : String(message)
      amend = !!@scm_commit_amend if amend.nil?
      raise ArgumentError, "amend must be true or false" unless [true, false].include?(amend)
      raise Error, "Enter a commit message" if message.strip.empty?
      raise Error, "Git commit already in progress" if @git_commit_job&.alive?

      state = git_state
      raise Error, "Not a Git repository" unless state
      snapshot = state.snapshot
      snapshot ||= state.capture unless @window
      raise Error, "Git status is still loading; try again" unless snapshot
      raise Error, "Cannot commit from a detached HEAD" unless snapshot.branch
      staged = snapshot.entries.any? { |_, code| !code.start_with?(" ", "?") }
      raise Error, "Stage changes before committing" unless amend || staged

      submitted = message.dup.freeze
      set_scm_commit_busy(true)
      @git_commit_job = Thread.new do
        oid = state.synchronize(snapshot: snapshot, index_lock: true) do |repository|
          current = repository.commit
          raise Error, "Cannot amend an unborn branch" if amend && !current

          author = amend ? current.signature(role: :author) : repository.signature(role: :author)
          committer = repository.signature(role: :committer)
          repository.commit!(message: submitted, author: author, committer: committer, amend: amend)
        end
        latest = state.capture rescue nil
        worker = Thread.current
        post { finish_git_commit(worker, state, latest, submitted, oid, nil) } unless @closed
      rescue StandardError => error
        latest = state.capture rescue nil
        worker = Thread.current
        post { finish_git_commit(worker, state, latest, submitted, nil, error) } unless @closed
      end
    end

    def refresh_scm
      entries = git_status
      @scm_tree&.replace(scm_nodes(entries))
      @panels.badge("scm", entries.empty? ? nil : entries.length) if @panels&.key?("scm")
      @window&.request_frame
      nil
    end

    def stage_git_file(path = nil)
      path ||= selected_scm_path(:unstaged, :untracked)
      state = git_state
      raise Error, "Not a Git repository" unless state

      state.synchronize do |repository|
        index = repository.index
        absolute = repository.worktree_path(path)
        if File.exist?(absolute) || File.symlink?(absolute)
          stat = File.lstat(absolute)
          if stat.directory?
            entry = index[path] || repository.tree[path]
            raise Error, "Git submodule is not initialized: #{path}" unless entry&.mode == 0o160000
            nested = submodule_repository(absolute)
            raise Error, "Git submodule is not initialized: #{path}" unless nested
            oid = nested.head
            raise Error, "Git submodule has no HEAD: #{path}" unless oid
            index.stage(path, oid, 0o160000, stat: stat)
          else
            content = repository.worktree_content(path)
            mode = scm_file_mode(repository, stat, index[path] || repository.tree[path])
            index.stage(path, repository.write_blob(content), mode, stat: stat)
          end
        else
          index.remove(path)
        end
        index.write
      end
      refresh_after_index_write
      path
    rescue Thuban::RefLockError
      refresh_after_index_write
      raise
    end

    def stage_git_hunk(index = nil, buffer: editor.buffer, row: nil)
      change_scm_hunk(:stage, index, buffer, row)
    end

    def unstage_git_hunk(index = nil, buffer: editor.buffer, row: nil)
      change_scm_hunk(:unstage, index, buffer, row)
    end

    def stage_git_line(index = nil, buffer: editor.buffer, row: nil)
      change_scm_line(:stage, index, buffer, row)
    end

    def unstage_git_line(index = nil, buffer: editor.buffer, row: nil)
      change_scm_line(:unstage, index, buffer, row)
    end

    def unstage_git_file(path = nil)
      path ||= selected_scm_path(:staged)
      state = git_state
      raise Error, "Not a Git repository" unless state

      state.synchronize do |repository|
        index = repository.index
        if (entry = repository.tree[path])
          index.stage(path, entry.oid, entry.mode)
        else
          index.remove(path)
        end
        index.write
      end
      refresh_after_index_write
      path
    rescue Thuban::RefLockError
      refresh_after_index_write
      raise
    end

    def show_scm_diff(change = @scm_selection)
      raise Error, "Select a changed file" unless change.is_a?(Hash) && SCM_SECTIONS.key?(change[:kind])

      path, kind = change.values_at(:path, :kind)
      state = git_state
      raise Error, "Not a Git repository" unless state
      capture = state.synchronize { |repository| capture_scm_diff(repository, path, kind) }
      snapshot, text = materialize_scm_diff(capture)
      buffer = Buffer.new(text, read_only: true)
      buffer.instance_variable_set(:@scm_diff_snapshot, snapshot)
      @decorations.invalidate(:scm_diff, buffer: buffer)
      @buffers[buffer.object_id] = buffer
      document = @active_pane.open(buffer)
      document.language = Language::Definition.new("diff", "diff", [], "", /\A\z/, /\A\z/, [])
      invalidate_hidden_selection_ranges
      document
    end

    def scm_diff_decorations(buffer, rows)
      snapshot = buffer.instance_variable_get(:@scm_diff_snapshot)
      return [] unless snapshot&.diff && !snapshot.conflicted

      action = snapshot.kind == :staged ? :unstage : :stage
      verb = action == :stage ? "Stage" : "Unstage"
      line_items = snapshot.line_rows.filter_map do |display_row, index|
        next unless rows.cover?(display_row)

        click = ->(current, row) { change_scm_line(action, index, current.buffer, row) }
        Decoration::Item.new(:gutter, nil, display_row, "#{verb} line",
          {color: :accent, gutter_offset: 2, gutter_width: 3, hit_width: 10}.freeze,
          1, :scm_diff, click)
      end
      hunk_items = snapshot.hunk_rows.filter_map do |display_row, index|
        next unless rows.cover?(display_row) && !snapshot.line_rows.key?(display_row)

        click = ->(current, row) { change_scm_hunk(action, index, current.buffer, row) }
        Decoration::Item.new(:gutter, nil, display_row, "#{verb} hunk",
          {color: :muted, gutter_offset: 2, gutter_width: 3, hit_width: 10}.freeze,
          2, :scm_diff, click)
      end
      line_items + hunk_items
    end

    private

    def submit_scm_commit
      commit_git
    rescue StandardError => error
      self.message = error.message
    end

    def set_scm_commit_busy(value)
      @scm_commit_input&.disabled(value)
      @scm_commit_amend_control&.disabled(value)
      @scm_commit_button&.loading(value)
      @window&.request_frame
    end

    def finish_git_commit(worker, state, snapshot, submitted, oid, error)
      @git_commit_job = nil if @git_commit_job.equal?(worker)
      set_scm_commit_busy(false)
      invalidate_git
      install_git_snapshot(state, snapshot) if snapshot
      if error
        self.message = "Git commit: #{error.message}"
        return
      end

      if @scm_commit_message == submitted
        @scm_commit_input ? @scm_commit_input.clear : @scm_commit_message = +""
      end
      self.message = "Committed #{oid[0, 8]}"
    end

    def capture_scm_diff(repository, path, kind)
      head_oid = repository.head
      index = repository.index
      head_entry = repository.tree(head_oid || "HEAD")[path]
      index_entry = index[path]
      worktree = scm_worktree_content(repository, path, index_entry || head_entry)
      head = scm_entry_content(repository, head_entry)
      staged = scm_entry_content(repository, index_entry)
      before, after = case kind
      when :staged then [head, staged]
      when :unstaged then [staged, worktree]
      else [scm_content(false, nil, nil), worktree]
      end
      entries = scm_index_entries(index, path)
      conflicted = index.entries.any? { |entry| entry.path == path && !entry.stage.zero? }
      metadata = [path.dup.freeze, kind, head_oid&.dup&.freeze, entries, worktree, conflicted]
      display_path = scm_display_path(path)
      if [head_entry, index_entry].compact.any? { |entry| entry.mode == 0o160000 }
        raw_before, raw_after = gitlink_diff(repository, path, kind, head_entry, index_entry)
        return [metadata.freeze, before, after, display_path.freeze,
          [raw_before.freeze, raw_after.freeze].freeze].freeze
      end
      [metadata.freeze, before, after, display_path.freeze, nil].freeze
    end

    def materialize_scm_diff(capture)
      metadata, before, after, display_path, gitlink_pair = capture
      if gitlink_pair
        snapshot = SCMDiffSnapshot.new(*metadata, before, after, nil, [].freeze, [].freeze, {}.freeze, {}.freeze)
        text = Porrima.unified(*gitlink_pair, old_name: "a/#{display_path}", new_name: "b/#{display_path}")
        return [snapshot, text, gitlink_pair]
      end
      unless before.text && after.text
        snapshot = SCMDiffSnapshot.new(*metadata, before, after, nil, [].freeze, [].freeze, {}.freeze, {}.freeze)
        return [snapshot, "Binary file changed: #{display_path}\n", [nil, nil].freeze]
      end
      if (reason = scm_diff_budget_reason(before.text, after.text))
        snapshot = SCMDiffSnapshot.new(*metadata, before, after, nil, [].freeze, [].freeze, {}.freeze, {}.freeze)
        return [snapshot, "Diff unavailable: #{display_path} #{scm_diff_budget_description(reason)}\n",
          [before.text, after.text].freeze]
      end

      diff = Porrima.diff(before.text, after.text, budget: before.text == after.text ? nil : SCM_DIFF_BUDGET)
      diff.edits
      diff.marks
      diff.rows
      diff.stat
      hunks, lines, hunk_rows, line_rows = scm_diff_targets(diff, before, after)
      snapshot = SCMDiffSnapshot.new(*metadata, before, after, diff, hunks, lines, hunk_rows, line_rows)
      text = diff.to_unified(old_name: "a/#{display_path}", new_name: "b/#{display_path}")
      text << "@@ metadata @@\n #{scm_metadata_change(before, after)}\n" if diff.empty? && !hunks.empty?
      [snapshot, text, [before.text, after.text].freeze]
    end

    def scm_diff_budget_reason(before, after)
      return :bytes if before.bytesize + after.bytesize > SCM_DIFF_MAX_BYTES
      lines = ->(text) { text.count("\n") + (!text.empty? && !text.end_with?("\n") ? 1 : 0) }
      return :lines if lines.call(before) + lines.call(after) > SCM_DIFF_MAX_LINES
      :line_endings if before != after && [before, after].any? { |text| text.match?(/\r(?!\n)|[\u2028\u2029]/) }
    end

    def scm_diff_budget_description(reason)
      return "exceeds 10 MiB" if reason == :bytes
      return "exceeds 200,000 lines" if reason == :lines
      "uses unsupported line separators"
    end

    def scm_display_path(path)
      !path.valid_encoding? || path.match?(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/) ? path.dump[1...-1] : path
    end

    def scm_metadata_change(before, after)
      return "new empty file (mode #{after.mode.to_s(8)})" unless before.exists
      return "deleted empty file (mode #{before.mode.to_s(8)})" unless after.exists

      "mode #{before.mode.to_s(8)} -> #{after.mode.to_s(8)}"
    end

    def scm_entry_content(repository, entry)
      raw = entry && entry.mode != 0o160000 ? repository.object(entry.oid).last : nil
      scm_content(!entry.nil?, raw, entry&.mode)
    end

    def scm_worktree_content(repository, path, baseline = nil)
      absolute = repository.worktree_path(path)
      exists = File.exist?(absolute) || File.symlink?(absolute)
      return scm_content(false, nil, nil) unless exists

      stat = File.lstat(absolute)
      mode = scm_file_mode(repository, stat, baseline)
      raw = stat.file? || stat.symlink? ? repository.worktree_content(path) : nil
      scm_content(true, raw, mode)
    rescue Errno::ENOENT, Errno::ENOTDIR
      scm_content(false, nil, nil)
    end

    def scm_content(exists, raw, mode)
      raw = raw&.dup&.freeze
      raise EncodingError if raw && raw.bytesize > SCM_DIFF_MAX_BYTES
      text, encoding, bom = Buffer.decode_bytes(raw.to_s)
      detection = Buffer.send(:detect_bytes, raw.to_s)
      raise EncodingError if raw && bom.empty? && encoding != Encoding::UTF_8 && detection.confidence < 0.9
      raise EncodingError if raw && raw != bom + text.encode(encoding).b

      SCMContent.new(exists, raw, text.freeze, encoding, bom.dup.freeze, mode)
    rescue EncodingError, Error
      SCMContent.new(exists, raw, nil, nil, nil, mode)
    end

    def scm_file_mode(repository, stat, baseline)
      return 0o120000 if stat.symlink?
      return 0o040000 unless stat.file?
      unless repository.filemode?
        return baseline.mode if [0o100644, 0o100755].include?(baseline&.mode)
        return 0o100644
      end

      (stat.mode & 0o100).positive? ? 0o100755 : 0o100644
    end

    def scm_index_entries(index, path)
      index.entries.select { |entry| entry.path == path }.map do |entry|
        entry.members.map { |member| value = entry.public_send(member); value.is_a?(String) ? value.dup.freeze : value }.freeze
      end.freeze
    end

    def scm_diff_targets(diff, before, after)
      hunks = diff.hunks.dup
      synthetic = diff.empty? && (before.exists != after.exists || before.mode != after.mode)
      if synthetic
        edit = Porrima::Hunk.new(old_start: 0, old_count: 0, new_start: 0, new_count: 0, edits: [].freeze).freeze
        return [[edit].freeze, [edit].freeze, {2 => 0, 3 => 0}.freeze, {}.freeze]
      end

      lines = []
      hunk_rows = {}
      line_rows = {}
      display_row = 2
      hunks.each_with_index do |hunk, hunk_index|
        header_row = display_row
        hunk_rows[header_row] = hunk_index
        display_row += 1
        unit_by_edit = {}
        index = 0
        while index < hunk.edits.length
          if hunk.edits[index].kind == :equal
            index += 1
            next
          end
          changed = []
          while index < hunk.edits.length && hunk.edits[index].kind != :equal
            changed << hunk.edits[index]
            index += 1
          end
          deleted = changed.select { |edit| edit.kind == :delete }
          inserted = changed.select { |edit| edit.kind == :insert }
          [deleted.length, inserted.length].max.times do |offset|
            old, new = deleted[offset], inserted[offset]
            old_start = old ? old.old_line : new.old_line - 1
            new_start = new ? new.new_line : old.new_line - 1 + inserted.length
            edits = [old, new].compact.freeze
            unit = Porrima::Hunk.new(old_start: old_start, old_count: old ? 1 : 0,
              new_start: new_start, new_count: new ? 1 : 0, edits: edits).freeze
            unit_index = lines.length
            lines << unit
            edits.each { |edit| unit_by_edit[edit.object_id] = unit_index }
          end
        end
        hunk.edits.each do |edit|
          hunk_rows[display_row] = hunk_index
          line_rows[display_row] = unit_by_edit.fetch(edit.object_id) unless edit.kind == :equal
          display_row += 1
          unless edit.text.end_with?("\n")
            hunk_rows[display_row] = hunk_index
            line_rows[display_row] = unit_by_edit.fetch(edit.object_id) unless edit.kind == :equal
            display_row += 1
          end
        end
      end
      [hunks.freeze, lines.freeze, hunk_rows.freeze, line_rows.freeze]
    end

    def change_scm_hunk(action, index, buffer, row)
      snapshot = scm_snapshot_for(buffer, action)
      row ||= buffer.rope.point_at(editor.primary.head).row
      index ||= snapshot.hunk_rows[row]
      raise Error, "Place the cursor in a Git hunk" unless index

      apply_scm_change(snapshot, action, snapshot.hunks.fetch(index))
    end

    def change_scm_line(action, index, buffer, row)
      snapshot = scm_snapshot_for(buffer, action)
      row ||= buffer.rope.point_at(editor.primary.head).row
      index ||= snapshot.line_rows[row]
      raise Error, "Place the cursor on a changed line" unless index

      apply_scm_change(snapshot, action, snapshot.lines.fetch(index))
    end

    def scm_snapshot_for(buffer, action)
      snapshot = buffer.instance_variable_get(:@scm_diff_snapshot)
      raise Error, "Open an SCM diff first" unless snapshot
      allowed = action == :stage ? %i[unstaged untracked] : %i[staged]
      raise Error, "This diff cannot be #{action}d" unless allowed.include?(snapshot.kind)
      raise Error, "Merge conflicts cannot be partially staged" if snapshot.conflicted
      raise Error, "Binary files and submodules cannot be partially staged" unless snapshot.diff
      snapshot
    end

    def apply_scm_change(snapshot, action, hunk)
      state = git_state
      raise Error, "Not a Git repository" unless state

      state.synchronize do |repository|
        index = repository.index
        validate_scm_snapshot!(repository, index, snapshot)
        source, target = action == :stage ? [snapshot.before, snapshot.after] : [snapshot.after, snapshot.before]
        text = action == :stage ? Porrima.apply(source.text, hunk) : Porrima.revert(source.text, hunk)
        exists = text == target.text ? target.exists : text == source.text ? source.exists : target.exists || !text.empty?
        if exists
          raw = if text == target.text && target.exists
            target.raw
          elsif text == source.text && source.exists
            source.raw
          else
            codec = source.exists ? source : target
            codec.bom + text.encode(codec.encoding).b
          end
          mode = text == target.text && target.exists ? target.mode : source.mode || target.mode
          raise Error, "Cannot partially stage this file type" unless [0o100644, 0o100755, 0o120000].include?(mode)
          index.stage(snapshot.path, repository.write_blob(raw), mode)
        else
          index.remove(snapshot.path)
        end
        validate_scm_worktree_and_head!(repository, snapshot)
        index.write
      end
      refresh_after_index_write
      snapshot.path
    rescue Thuban::RefLockError
      refresh_after_index_write
      raise
    end

    def validate_scm_snapshot!(repository, index, snapshot)
      stale = repository.head != snapshot.head || scm_index_entries(index, snapshot.path) != snapshot.index_entries ||
        scm_worktree_signature(scm_worktree_content(repository, snapshot.path, snapshot.worktree)) != scm_worktree_signature(snapshot.worktree)
      raise Error, "Git diff is stale; reopen it before staging" if stale
    end

    def validate_scm_worktree_and_head!(repository, snapshot)
      stale = repository.head != snapshot.head ||
        scm_worktree_signature(scm_worktree_content(repository, snapshot.path, snapshot.worktree)) != scm_worktree_signature(snapshot.worktree)
      raise Error, "Git diff is stale; reopen it before staging" if stale
    end

    def scm_worktree_signature(content) = [content.exists, content.raw, content.mode]

    def gitlink_diff(repository, path, kind, head, staged)
      case kind
      when :staged
        [gitlink_entry_text(head), gitlink_entry_text(staged)]
      when :unstaged
        [gitlink_entry_text(staged), gitlink_worktree_text(repository, path)]
      else
        ["", gitlink_worktree_text(repository, path)]
      end
    end

    def gitlink_entry_text(entry)
      return "" unless entry
      return "Subproject commit #{entry.oid}\n" if entry.mode == 0o160000

      "Git object #{entry.oid} (mode #{entry.mode.to_s(8)})\n"
    end

    def gitlink_worktree_text(repository, path)
      absolute = repository.worktree_path(path)
      return "" unless File.exist?(absolute) || File.symlink?(absolute)
      return "Submodule path is not a directory\n" unless File.directory?(absolute) && !File.symlink?(absolute)

      nested = submodule_repository(absolute)
      return "Submodule is not initialized\n" unless nested
      oid = nested.head
      oid ? "Subproject commit #{oid}\n" : "Submodule has no HEAD\n"
    rescue ArgumentError, Thuban::CorruptObject, SystemCallError
      "Submodule is unavailable\n"
    end

    def submodule_repository(absolute)
      nested = Thuban::Repository.new(absolute)
      return unless nested.root && File.realpath(nested.root) == File.realpath(absolute)

      nested
    rescue ArgumentError, SystemCallError
      nil
    end

    def scm_nodes(entries = git_status)
      grouped = SCM_SECTIONS.to_h { |kind, _| [kind, []] }
      entries.sort.each do |path, code|
        change = ->(kind) { {path: path, kind: kind, code: code}.freeze }
        grouped[:untracked] << scm_file_node(change.call(:untracked)) if code == "??"
        grouped[:staged] << scm_file_node(change.call(:staged)) if code.getbyte(0) != 32 && code.getbyte(0) != 63
        grouped[:unstaged] << scm_file_node(change.call(:unstaged)) if code.getbyte(1) != 32 && code.getbyte(1) != 63
      end
      SCM_SECTIONS.map do |kind, label|
        children = grouped.fetch(kind).freeze
        {id: [:scm_section, kind].freeze, label: "#{label} (#{children.length})".freeze,
         value: nil, children: children}.freeze
      end.freeze
    end

    def scm_file_node(change)
      path, kind, code = change.values_at(:path, :kind, :code)
      mark = kind == :untracked ? "?" : kind == :staged ? code[0] : code[1]
      {id: [:scm_file, kind, path].freeze, label: "#{mark} #{scm_display_path(path)}".freeze, value: change}.freeze
    end

    def select_scm_change(change, event = nil)
      return false unless change.is_a?(Hash) && SCM_SECTIONS.key?(change[:kind])

      @scm_selection = change
      if event&.click_count.to_i >= 2
        change[:kind] == :staged ? unstage_git_file(change[:path]) : stage_git_file(change[:path])
      else
        show_scm_diff(change)
      end
      true
    end

    def selected_scm_path(*kinds)
      change = @scm_selection
      raise Error, "Select a #{kinds == [:staged] ? 'staged' : 'changed'} file" unless change.is_a?(Hash) && kinds.include?(change[:kind])
      change.fetch(:path)
    end

    def refresh_after_index_write
      invalidate_git
      refresh_scm
    end
  end
end

# frozen_string_literal: true

require_relative "../git/state"

module Canopus
  module Workspace::GitAware
    def git
      return @git if defined?(@git)
      @git = Thuban::Repository.new(@root)
      @git = nil unless @git.root
      @git
    rescue ArgumentError
      @git = nil
    end
    def git_status
      state = git_state
      return {} unless state
      return state.snapshot.entries if state.snapshot
      if @window
        unless @git_status_job&.alive?
          generation = @git_generation ||= 0
          @git_status_job = Thread.new do
            snapshot = state.capture
            post { install_git_snapshot(state, snapshot) if generation == @git_generation } unless @closed
          rescue StandardError => error
            post { @message = "Git status: #{error.message}" } unless @closed
          end
        end
        {}
      else
        install_git_snapshot(state, state.capture).entries
      end
    end
    def invalidate_git
      @git_generation = (@git_generation || 0) + 1
      @git_state&.invalidate
      @decorations.invalidate(:git)
      @panes.each do |pane|
        pane.editors.each do |current|
          current.display_map.block_map.blocks.values.each { |block| current.display_map.remove_block(block.id) if block.kind == :git_diff }
        end
      end
      nil
    end
    def poll_git_changes(now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      return if @last_git_poll && now - @last_git_poll < 1
      @last_git_poll = now
      state = git_state
      return unless state
      unless @git_poll_job&.alive?
        generation = @git_generation ||= 0
        @git_poll_job = Thread.new do
          identity = state.identity
          post { install_git_identity(identity) if generation == @git_generation } unless @closed
        rescue StandardError => error
          post { @message = "Git: #{error.message}" } unless @closed
        end
      end
      nil
    end
    def git_relative_path(buffer = editor.buffer)
      raise Error, "Current document is not in a Git repository" unless git && buffer.path && buffer.path.start_with?(git.root + File::SEPARATOR)
      buffer.path.delete_prefix(git.root + File::SEPARATOR)
    end
    def git_diff(buffer = editor.buffer, async: true)
      return unless git && buffer.path && buffer.path.start_with?(git.root + File::SEPARATOR) && buffer.rope.bytesize < 10 << 20
      path = git_relative_path(buffer)
      state = git_state
      key = [buffer.object_id, path, buffer.version, state.snapshot&.head]
      cached = state.cached_diff(key)
      return cached if cached
      if @window && async
        @git_diff_jobs ||= {}
        unless @git_diff_jobs[buffer]&.alive?
          snapshot = buffer.rope
          generation = @git_generation ||= 0
          @git_diff_jobs[buffer] = Thread.new do
            before = Buffer.decode_bytes(state.synchronize { |repository| repository.blob(path, reference: key.last || "HEAD") }.to_s).first
            diff = Porrima.diff(before, snapshot.to_s, context: 0)
            diff.hunks
            diff.marks
            post do
              if generation == @git_generation
                state.store_diff(key, diff)
                @decorations.invalidate(:git, buffer: buffer)
              end
            end unless @closed
          rescue StandardError => error
            post { @message = "Git diff: #{error.message}" } unless @closed
          end
        end
        nil
      else
        before = Buffer.decode_bytes(state.synchronize { |repository| repository.blob(path, reference: key.last || "HEAD") }.to_s).first
        diff = Porrima.diff(before, buffer.text, context: 0)
        diff.hunks
        diff.marks
        state.store_diff(key, diff)
      end
    end
    def git_hunks(buffer = editor.buffer, async: true) = git_diff(buffer, async: async)&.hunks || []
    def git_gutter_marks(buffer = editor.buffer) = git_diff(buffer)&.marks || []
    def git_decorations(buffer, rows)
      git_gutter_marks(buffer).filter_map do |mark|
        first = [mark.new_line, 1].max - 1
        count = mark.kind == :removed ? 1 : mark.count
        next if first + count <= rows.begin || first >= rows.end

        color = mark.kind == :removed ? :error : mark.kind == :added ? "#80b987" : :accent
        style = {color: color, rows: count, hit_width: 7}.freeze
        click = ->(current, row) { toggle_git_hunk(current, row: row) }
        Decoration::Item.new(:gutter, nil, first, "Toggle Git hunk", style, 0, :git, click)
      end
    end
    def show_git_diff
      path = git_relative_path
      before = Buffer.decode_bytes(git_state.synchronize { |repository| repository.blob(path) }.to_s).first
      buffer = Buffer.new(Porrima.unified(before, editor.buffer.text, old_name: "a/#{path}", new_name: "b/#{path}"), read_only: true)
      @buffers[buffer.object_id] = buffer
      @active_pane.open(buffer).language = Language::Definition.new("diff", "diff", [], "", /\A\z/, /\A\z/, [])
      invalidate_hidden_selection_ranges
    end
    def toggle_git_hunk(current = editor, row: nil)
      row ||= current.buffer.rope.point_at(current.primary.head).row
      hunk = git_diff(current.buffer, async: false)&.hunk_at(new_line: row + 1)
      raise Error, "No change at the cursor" unless hunk
      id = [:git_hunk, current.buffer.path, current.buffer.version, git_state.snapshot&.head, hunk.old_start, hunk.new_start]
      map = current.display_map
      if map.block_map.blocks.key?(id)
        map.remove_block(id)
        expanded = false
      else
        # Keep inline previews bounded; the full diff remains available in its
        # own document for large hunks and unusually long source lines.
        lines = ["@@ -#{hunk.old_start},#{hunk.old_count} +#{hunk.new_start},#{hunk.new_count} @@"]
        hunk.edits.first(200).each do |edit|
          body = edit.text.delete_suffix("\n").delete_suffix("\r")
          lines << "#{edit.kind == :delete ? '-' : edit.kind == :insert ? '+' : ' '}#{body.slice(0, 500)}#{body.length > 500 ? '…' : ''}"
        end
        lines << "… #{hunk.edits.length - 200} more lines; open git.diff for the full change" if hunk.edits.length > 200
        map.insert_block(id, row: [hunk.new_start - 1, 0].max.clamp(0, current.buffer.line_count - 1), text: lines.join("\n"), kind: :git_diff)
        expanded = true
      end
      @window&.request_frame
      expanded
    end
    def show_git_blame
      path = git_relative_path
      lines = git_state.synchronize { |repository| repository.blame(path) }
      @hover_card = lines.map { |line| "#{line.commit.to_s[0, 8]} #{line.author} #{line.text}" }.join
    end
    def revert_current_hunk
      row = editor.buffer.rope.point_at(editor.primary.head).row + 1
      hunk = git_diff(async: false)&.hunk_at(new_line: row)
      raise Error, "No change at the cursor" unless hunk
      replacement = Porrima.revert(editor.buffer.text, hunk)
      editor.buffer.edit([[0...editor.buffer.rope.bytesize, replacement]], kind: :revert_hunk)
    end
    def checkout_branch(name)
      raise Error, "Save or discard all buffer changes before switching branches" if @buffers.values.any?(&:dirty?)
      raise Error, "Not a Git repository" unless git_state
      git_state.synchronize { |repository| repository.checkout(name) }
      invalidate_git
      refresh_files
      @buffers.values.each { |buffer| buffer.reload if buffer.path && File.file?(buffer.path) && !buffer.read_only }
      @message = "Switched to #{name}"
    end

    private

    def git_state
      return @git_state if defined?(@git_state)
      @git_state = Git::State.new(git) if git
    end

    def install_git_snapshot(state, snapshot)
      state.install(snapshot)
      @git_identity = snapshot.identity
      refresh_scm if @scm_tree
      snapshot
    end

    def install_git_identity(identity)
      initial = !defined?(@git_identity)
      changed = !initial && @git_identity != identity
      @git_identity = identity
      return unless changed

      invalidate_git
      refresh_scm if @scm_tree
      @window&.request_frame
    end

    def git_branches
      state = git_state
      state ? state.synchronize { |repository| repository.branches } : []
    end

    def close_git
      [@git_status_job, @git_poll_job, @git_commit_job, *@git_diff_jobs&.values].compact.uniq.each do |thread|
        thread.join unless thread.equal?(Thread.current)
      end
      @git_diff_jobs&.clear
      nil
    end
  end
end

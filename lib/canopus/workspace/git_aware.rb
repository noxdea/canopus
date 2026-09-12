# frozen_string_literal: true

module Canopus
  module Workspace::GitAware
    def git
      return @git if defined?(@git)
      @git = Thuban::Repository.new(@root)
      @git = nil unless @git.root
    rescue ArgumentError
      @git = nil
    end
    def git_status
      return @git_status if @git_status
      return {} unless git
      if @window
        unless @git_status_job&.alive?
          generation = @git_generation
          @git_status_job = Thread.new do
            status = git.status.to_h { |entry| [entry.path, entry.code] }
            post { @git_status = status if generation == @git_generation } unless @closed
          rescue StandardError => error
            post { @message = "Git status: #{error.message}" } unless @closed
          end
        end
        {}
      else
        @git_status = git.status.to_h { |entry| [entry.path, entry.code] }
      end
    end
    def invalidate_git
      @git_generation = (@git_generation || 0) + 1
      @git_status = @git_diff_cache = nil
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
      return unless git
      index = File.join(git.git_dir, "index")
      stat = File.stat(index) if File.file?(index)
      state = [git.head, git.branch, stat&.mtime, stat&.size, stat&.ino]
      return if @git_state == state
      initial = !defined?(@git_state)
      @git_state = state
      return if initial
      invalidate_git
      @window&.request_frame
    rescue SystemCallError, ArgumentError => error
      @message = "Git: #{error.message}"
    end
    def git_relative_path(buffer = editor.buffer)
      raise Error, "Current document is not in a Git repository" unless git && buffer.path && buffer.path.start_with?(git.root + File::SEPARATOR)
      buffer.path.delete_prefix(git.root + File::SEPARATOR)
    end
    def git_diff(buffer = editor.buffer, async: true)
      return unless git && buffer.path && buffer.path.start_with?(git.root + File::SEPARATOR) && buffer.rope.bytesize < 10 << 20
      path = git_relative_path(buffer)
      @git_diff_cache ||= {}
      key = [buffer.object_id, path, buffer.version, git.head]
      @git_diff_cache.clear if @git_diff_cache.length > 20
      return @git_diff_cache[key] if @git_diff_cache.key?(key)
      if @window && async
        @git_diff_jobs ||= {}
        unless @git_diff_jobs[buffer]&.alive?
          snapshot = buffer.rope
          @git_diff_jobs[buffer] = Thread.new do
            before = Buffer.decode_bytes(git.blob(path, reference: key.last || "HEAD").to_s).first
            diff = Porrima.diff(before, snapshot.to_s, context: 0)
            diff.hunks
            diff.marks
            post { (@git_diff_cache ||= {})[key] = diff } unless @closed
          rescue StandardError => error
            post { @message = "Git diff: #{error.message}" } unless @closed
          end
        end
        nil
      else
        before = Buffer.decode_bytes(git.blob(path).to_s).first
        diff = Porrima.diff(before, buffer.text, context: 0)
        diff.hunks
        diff.marks
        @git_diff_cache[key] = diff
      end
    end
    def git_hunks(buffer = editor.buffer, async: true) = git_diff(buffer, async: async)&.hunks || []
    def git_gutter_marks(buffer = editor.buffer) = git_diff(buffer)&.marks || []
    def show_git_diff
      path = git_relative_path
      before = Buffer.decode_bytes(git.blob(path).to_s).first
      buffer = Buffer.new(Porrima.unified(before, editor.buffer.text, old_name: "a/#{path}", new_name: "b/#{path}"), read_only: true)
      @buffers[buffer.object_id] = buffer
      @active_pane.open(buffer).language = Language::Definition.new("diff", "diff", [], "", /\A\z/, /\A\z/, [])
    end
    def toggle_git_hunk(current = editor, row: nil)
      row ||= current.buffer.rope.point_at(current.primary.head).row
      hunk = git_diff(current.buffer, async: false)&.hunk_at(new_line: row + 1)
      raise Error, "No change at the cursor" unless hunk
      id = [:git_hunk, current.buffer.path, current.buffer.version, git.head, hunk.old_start, hunk.new_start]
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
      lines = git.blame(path)
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
      raise Error, "Not a Git repository" unless git
      git.checkout(name)
      invalidate_git
      refresh_files
      @buffers.values.each { |buffer| buffer.reload if buffer.path && File.file?(buffer.path) && !buffer.read_only }
      @message = "Switched to #{name}"
    end
  end
end

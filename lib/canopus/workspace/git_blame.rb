# frozen_string_literal: true

module Canopus
  module Workspace::GitBlame
    BLAME_MAX_BYTES = 1 << 20
    BLAME_MAX_LINES = 20_000
    BLAME_CACHE_LIMIT = 16
    BLAME_BUDGET = Porrima::Budget.new(max_bytes: 2 << 20, max_lines: BLAME_MAX_LINES)

    GitBlameLine = Data.define(:commit, :author, :original_line, :path)
    GitBlameSnapshot = Data.define(:key, :lines, :reason)

    def git_blame_decorations(buffer, rows, current = nil)
      mode = @settings["git"]["inline_blame"]
      return [] if mode == "off" || !buffer.path || buffer.rope.bytesize > BLAME_MAX_BYTES ||
        buffer.line_count > BLAME_MAX_LINES
      text = buffer.text
      return [] unless git_blame_text_supported?(text)

      path = safe_git_diff_path(git_relative_path(buffer))
      key = [buffer.object_id, buffer.version, @git_generation.to_i, path].freeze
      snapshot = (@git_blame_cache ||= {})[key]
      unless snapshot
        requested = request_git_blame(buffer, path, key, text.dup.freeze)
        snapshot = requested if requested.is_a?(GitBlameSnapshot)
        return [] unless snapshot
      end
      return [] if snapshot.reason

      visible = rows.begin...[rows.end, buffer.line_count].min
      selected = if mode == "cursor"
        return [] unless current.is_a?(Editor) && current.buffer.equal?(buffer)
        row = buffer.rope.point_at(current.primary.head).row
        visible.cover?(row) ? [row] : []
      else
        visible.to_a
      end
      selected.filter_map do |row|
        next if row == buffer.line_count - 1 && buffer.line(row).empty?
        git_blame_decoration(buffer, row, snapshot.lines[row])
      end
    rescue Error
      []
    end

    def invalidate_git_blame(buffer = nil)
      @git_blame_generation = (@git_blame_generation || 0) + 1
      if buffer
        @git_blame_cache&.delete_if { |key, _| key[0] == buffer.object_id }
      else
        @git_blame_cache&.clear
      end
      @decorations.invalidate(:blame, buffer: buffer)
      nil
    end

    def invalidate_git
      invalidate_git_blame
      super
    end

    def close_git
      @git_blame_generation = (@git_blame_generation || 0) + 1
      jobs = [*@git_blame_jobs&.values].compact.uniq.reject { |thread| thread.equal?(Thread.current) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.1
      jobs.each do |thread|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break unless remaining.positive?
        thread.join(remaining)
      end
      jobs.each { |thread| thread.kill if thread.alive? }
      jobs.each(&:join)
      @git_blame_jobs&.clear
      super
    end

    private

    def request_git_blame(buffer, path, key, text)
      @git_blame_jobs ||= {}
      return if @git_blame_jobs[buffer]&.alive?

      generation = @git_blame_generation ||= 0
      work = lambda do
        capture = git_state.synchronize do |repository|
          raw = repository.blob(path)
          if raw && raw.bytesize <= BLAME_MAX_BYTES
            committed = Buffer.decode_bytes(raw).first
            git_blame_text_supported?(committed) ? [committed, repository.blame(path)].freeze : [nil, nil].freeze
          else
            [nil, nil].freeze
          end
        end
        materialize_git_blame(key, text, *capture)
      end
      return install_git_blame(buffer, work.call) unless @window

      @git_blame_jobs[buffer] = Thread.new do
        current = Thread.current
        snapshot = work.call
        post { finish_git_blame(current, generation, buffer, snapshot, nil) } unless @closed
      rescue StandardError => error
        post { finish_git_blame(current, generation, buffer, nil, error) } unless @closed
      end
    rescue StandardError => error
      install_git_blame(buffer, GitBlameSnapshot.new(key, [].freeze,
        safe_git_history_text(error.message, 200).freeze).freeze)
    end

    def git_blame_text_supported?(text)
      text.bytesize <= BLAME_MAX_BYTES && text.count("\n") + 1 <= BLAME_MAX_LINES &&
        !text.match?(/\r(?!\n)|[\u2028\u2029]/)
    end

    def materialize_git_blame(key, text, committed, blamed)
      return GitBlameSnapshot.new(key, [].freeze, "Blame unavailable for large or missing content".freeze).freeze unless committed
      reason = scm_diff_budget_reason(committed, text)
      return GitBlameSnapshot.new(key, [].freeze, "Blame unavailable: #{scm_diff_budget_description(reason)}".freeze).freeze if reason

      lines = Array.new(text.lines.length)
      if committed == text
        blamed.each_with_index { |line, index| lines[index] = copy_git_blame_line(line) }
      else
        Porrima.diff(committed, text, budget: BLAME_BUDGET).edits.each do |edit|
          next unless edit.kind == :equal
          lines[edit.new_line - 1] = copy_git_blame_line(blamed[edit.old_line - 1])
        end
      end
      GitBlameSnapshot.new(key, lines.freeze, nil).freeze
    rescue Porrima::BudgetExceeded
      GitBlameSnapshot.new(key, [].freeze, "Blame unavailable: diff budget exceeded".freeze).freeze
    end

    def copy_git_blame_line(line)
      return unless line
      GitBlameLine.new(line.commit.to_s.dup.freeze, safe_git_history_text(line.author, 100).freeze,
        line.original_line, line.path.to_s.dup.freeze).freeze
    end

    def git_blame_decoration(buffer, row, line)
      source = buffer.line(row)
      body = source.delete_suffix("\n").delete_suffix("\r")
      offset = buffer.rope.line_start(row) + body.bytesize
      content = if line
        "  #{line.author} · #{line.commit[0, 8]}"
      else
        "  Uncommitted changes"
      end
      Decoration::Item.new(:inline, offset...offset, row, content.freeze,
        {color: :muted, padding_left: 8, cells: Zaniah::Unicode.width(content)}.freeze,
        90, :blame, nil)
    end

    def install_git_blame(buffer, snapshot)
      cache = @git_blame_cache ||= {}
      cache.shift while cache.length >= BLAME_CACHE_LIMIT
      cache[snapshot.key] = snapshot
      @decorations.invalidate(:blame, buffer: buffer)
      @window&.request_frame
      snapshot
    end

    def finish_git_blame(worker, generation, buffer, snapshot, error)
      @git_blame_jobs&.delete(buffer) if @git_blame_jobs&.[](buffer).equal?(worker)
      return unless generation == @git_blame_generation
      if error
        self.message = "Git blame: #{safe_git_history_text(error.message, 200)}"
      else
        install_git_blame(buffer, snapshot)
      end
    end
  end
end

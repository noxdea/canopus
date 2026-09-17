# frozen_string_literal: true

require "unicode/display_width"

module Canopus
  module Workspace::GitDiffView
    MAX_DIFF_BYTES = 10 << 20
    MAX_HISTORY = 200
    MAX_HISTORY_SCAN = 20_000
    MAX_PATH_BYTES = 4_096
    MAX_REVISION_BYTES = 1_024
    SIDE_COLUMN_WIDTH = 160
    DIFF_BUDGET = Porrima::Budget.new(max_bytes: 1 << 20, max_lines: 2_000)
    DELETED_STYLE = {color: "#f9758344"}.freeze
    INSERTED_STYLE = {color: "#80b98744"}.freeze

    GitDiffSource = Data.define(:path, :before_label, :after_label, :diff, :snapshot, :metadata, :unavailable)
    GitDiffView = Data.define(:source, :mode, :highlights, :hunk_rows, :line_rows)
    GitHistoryEntry = Data.define(:oid, :parent, :subject, :author, :time, :path)

    def show_scm_diff(change = @scm_selection, mode: :inline, async: !!@window)
      sections = Workspace::GitStaging::SCM_SECTIONS
      raise Error, "Select a changed file" unless change.is_a?(Hash) && sections.key?(change[:kind])

      state = git_state
      raise Error, "Not a Git repository" unless state
      path = safe_git_diff_path(change.fetch(:path))
      mode = normalize_git_diff_mode(mode)
      schedule_git_diff(mode: mode, async: async) do
        capture = state.synchronize { |repository| capture_scm_diff(repository, path, change.fetch(:kind)) }
        snapshot, fallback, pair = materialize_scm_diff(capture)
        metadata = scm_metadata_change(snapshot.before, snapshot.after) if snapshot.diff&.empty? && !snapshot.hunks.empty?
        unavailable = if pair.compact.empty?
          git_diff_unavailable(path, snapshot.before.text, snapshot.after.text,
            byte_values: [snapshot.before.raw, snapshot.after.raw]) || fallback
        end
        build_git_diff_source(path, pair.first, pair.last, snapshot: snapshot, metadata: metadata,
          diff: snapshot.diff, unavailable: unavailable)
      end
    end

    def show_git_diff(mode: :inline, async: !!@window)
      current = editor
      path = safe_git_diff_path(git_relative_path(current.buffer))
      after_size = current.buffer.rope.bytesize
      after = after_size <= MAX_DIFF_BYTES ? current.buffer.text.dup.freeze : nil
      state = git_state
      raise Error, "Not a Git repository" unless state
      mode = normalize_git_diff_mode(mode)
      schedule_git_diff(mode: mode, async: async) do
        raw = state.synchronize { |repository| repository.blob(path) }
        before = decode_git_diff_content(raw)
        unavailable = git_diff_unavailable(path, before, after, byte_values: [raw, after_size])
        build_git_diff_source(path, before, after, unavailable: unavailable)
      end
    end

    def compare_git_revisions(before, after, path: nil, mode: :inline, async: !!@window)
      state = git_state
      raise Error, "Not a Git repository" unless state
      path = safe_git_diff_path(git_diff_target_path(path))
      before = validate_git_revision(before, allow_nil: true)
      after = validate_git_revision(after)
      mode = normalize_git_diff_mode(mode)
      schedule_git_diff(mode: mode, async: async) do
        captured = state.synchronize do |repository|
          left_commit = resolve_git_revision(repository, before)
          right_commit = resolve_git_revision(repository, after)
          left, left_text = revision_file_content(repository, left_commit, path)
          right, right_text = revision_file_content(repository, right_commit, path)
          metadata = scm_metadata_change(left, right) if left_text == right_text &&
            (left.exists != right.exists || left.mode != right.mode)
          unavailable = git_diff_unavailable(path, left_text, right_text, byte_values: [left.raw, right.raw])
          [left_text, right_text, metadata, unavailable].freeze
        end
        build_git_diff_source(path, captured[0], captured[1], snapshot: nil, metadata: captured[2],
          unavailable: captured[3], before_label: revision_label(path, before), after_label: revision_label(path, after))
      end
    end

    def show_git_revision_diff(before, after, **options) = compare_git_revisions(before, after, **options)
    def show_revision_diff(before, after, **options) = compare_git_revisions(before, after, **options)

    def toggle_git_diff_mode(current = editor, async: !!@window)
      view = current&.buffer&.instance_variable_get(:@git_diff_view)
      raise Error, "Open a Git diff first" unless view

      mode = view.mode == :inline ? :side_by_side : :inline
      pane = @panes.find { |candidate| candidate.editors.include?(current) }
      schedule_git_diff(mode: mode, async: async, pane: pane, replacing: current) { view.source }
    end

    alias_method :toggle_scm_diff_mode, :toggle_git_diff_mode

    def git_file_history(path = nil, revision: "HEAD", limit: 100)
      state = git_state
      raise Error, "Not a Git repository" unless state
      path = safe_git_diff_path(git_diff_target_path(path))
      revision = validate_git_revision(revision)
      unless limit.is_a?(Integer) && limit.between?(1, MAX_HISTORY)
        raise ArgumentError, "history limit must be between 1 and #{MAX_HISTORY}"
      end

      state.synchronize { |repository| collect_git_file_history(repository, path, revision, limit) }
    end

    def show_git_file_history(path = nil, revision: "HEAD", limit: 100, async: !!@window)
      path = safe_git_diff_path(git_diff_target_path(path))
      revision = validate_git_revision(revision)
      if @window && async
        generation = @git_history_generation = (@git_history_generation || 0) + 1
        palette_generation = @palette_generation.to_i
        @message = "Loading Git history…"
        worker = Thread.new do
          current_worker = Thread.current
          entries = git_file_history(path, revision: revision, limit: limit)
          post { finish_git_history(current_worker, generation, palette_generation, path, entries, nil) } unless @closed
        rescue StandardError => error
          post { finish_git_history(current_worker, generation, palette_generation, path, nil, error) } unless @closed
        end
        (@git_history_jobs ||= []) << worker
        return worker
      end

      install_git_history(path, git_file_history(path, revision: revision, limit: limit))
    end

    def show_git_revision_compare(path = nil)
      path = safe_git_diff_path(git_diff_target_path(path))
      self.palette = {kind: :git_revision_compare, query: +"", index: 0, matches: [], path: path}
    end

    def scm_diff_decorations(buffer, rows)
      view = buffer.instance_variable_get(:@git_diff_view)
      return super unless view

      items = view.highlights.select do |item|
        row = buffer.rope.point_at(item.range.begin).row
        rows.cover?(row)
      end
      snapshot = view.source.snapshot
      return items unless snapshot&.diff && !snapshot.conflicted

      action = snapshot.kind == :staged ? :unstage : :stage
      verb = action == :stage ? "Stage" : "Unstage"
      view.line_rows.each do |display_row, index|
        next unless rows.cover?(display_row)
        click = ->(current, row) { change_scm_line(action, index, current.buffer, row) }
        items << Decoration::Item.new(:gutter, nil, display_row, "#{verb} line",
          {color: :accent, gutter_offset: 2, gutter_width: 3, hit_width: 10}.freeze,
          1, :scm_diff, click)
      end
      view.hunk_rows.each do |display_row, index|
        next unless rows.cover?(display_row) && !view.line_rows.key?(display_row)
        click = ->(current, row) { change_scm_hunk(action, index, current.buffer, row) }
        items << Decoration::Item.new(:gutter, nil, display_row, "#{verb} hunk",
          {color: :muted, gutter_offset: 2, gutter_width: 3, hit_width: 10}.freeze,
          2, :scm_diff, click)
      end
      items
    end

    def close_git
      @git_view_generation = (@git_view_generation || 0) + 1
      @git_history_generation = (@git_history_generation || 0) + 1
      jobs = [*@git_view_jobs, *@git_history_jobs].compact.uniq.reject { |thread| thread.equal?(Thread.current) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.1
      jobs.each do |thread|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break unless remaining.positive?
        thread.join(remaining)
      end
      jobs.each { |thread| thread.kill if thread.alive? }
      jobs.each(&:join)
      @git_view_jobs&.clear
      @git_history_jobs&.clear
      super
    end

    private

    def schedule_git_diff(mode:, async:, pane: @active_pane, replacing: nil, &capture)
      generation = @git_view_generation = (@git_view_generation || 0) + 1
      work = -> { materialize_git_diff(capture.call, mode) }
      return install_git_diff(*work.call, pane: pane, replacing: replacing) unless @window && async

      @message = "Loading Git diff…"
      worker = Thread.new do
        current_worker = Thread.current
        result = work.call
        post { finish_git_diff(current_worker, generation, result, nil, pane, replacing) } unless @closed
      rescue StandardError => error
        post { finish_git_diff(current_worker, generation, nil, error, pane, replacing) } unless @closed
      end
      (@git_view_jobs ||= []) << worker
      worker
    end

    def finish_git_diff(worker, generation, result, error, pane, replacing)
      @git_view_jobs&.delete(worker)
      return unless generation == @git_view_generation
      if error
        self.message = "Git diff: #{error.message}"
      else
        install_git_diff(*result, pane: pane, replacing: replacing)
      end
    end

    def install_git_diff(text, view, pane:, replacing:)
      return unless @panes.include?(pane)
      return if replacing && !pane.editors.include?(replacing)

      buffer = Buffer.new(text, read_only: true)
      buffer.instance_variable_set(:@git_diff_view, view)
      buffer.instance_variable_set(:@scm_diff_snapshot, view.source.snapshot)
      @decorations.invalidate(:scm_diff, buffer: buffer)
      @buffers[buffer.object_id] = buffer
      pinned = replacing && pane.pinned.include?(replacing)
      document = pane.open(buffer)
      document.language = Language::Definition.new("diff", "diff", [], "", /\A\z/, /\A\z/, [])
      apply_editor_settings(document)
      pane.pin(document) if pinned
      close_editor(replacing) if replacing
      invalidate_hidden_selection_ranges
      @window&.request_frame
      document
    rescue StandardError
      @buffers.delete(buffer&.object_id)
      buffer&.close
      raise
    end

    def build_git_diff_source(path, before, after, snapshot: nil, metadata: nil, diff: nil, unavailable: nil,
      before_label: nil, after_label: nil)
      display = scm_display_path(path)
      if !unavailable && before && after && (reason = scm_diff_budget_reason(before, after))
        unavailable = "Diff unavailable: #{scm_display_path(path)} #{scm_diff_budget_description(reason)}\n"
      end
      unless unavailable
        diff ||= Porrima.diff(before, after, budget: before == after ? nil : DIFF_BUDGET)
        diff.edits
        diff.hunks
        diff.rows
        diff.stat
      end
      GitDiffSource.new(path.dup.freeze, (before_label || "a/#{display}").freeze,
        (after_label || "b/#{display}").freeze, diff, unavailable ? nil : snapshot,
        metadata&.dup&.freeze, unavailable&.dup&.freeze).freeze
    rescue Porrima::BudgetExceeded
      retry_source = "Diff unavailable: #{scm_display_path(path)} exceeds the diff budget\n"
      GitDiffSource.new(path.dup.freeze, (before_label || "a/#{display}").freeze,
        (after_label || "b/#{display}").freeze, nil, nil, metadata&.dup&.freeze,
        retry_source.freeze).freeze
    end

    def materialize_git_diff(source, mode)
      if source.unavailable
        view = GitDiffView.new(source, mode, [].freeze, {}.freeze, {}.freeze).freeze
        return [source.unavailable, view]
      end

      mode == :inline ? render_inline_git_diff(source) : render_side_by_side_git_diff(source)
    end

    def render_inline_git_diff(source)
      output = +"--- #{source.before_label}\n+++ #{source.after_label}\n"
      highlights = []
      spans = inline_spans(source.diff)
      source.diff.hunks.each do |hunk|
        output << "@@ -#{hunk.old_start},#{hunk.old_count} +#{hunk.new_start},#{hunk.new_count} @@\n"
        hunk.edits.each do |edit|
          output << {equal: " ", delete: "-", insert: "+"}.fetch(edit.kind)
          base = output.bytesize
          output << edit.text
          record_inline_highlights(highlights, base, edit.text, spans[edit.object_id], edit.kind)
          output << "\n\\ No newline at end of file\n" unless edit.text.end_with?("\n")
        end
      end
      if source.metadata
        output << "@@ metadata @@\n #{source.metadata}\n"
      end
      snapshot = source.snapshot
      hunk_rows = snapshot ? snapshot.hunk_rows : {}.freeze
      line_rows = snapshot ? snapshot.line_rows : {}.freeze
      view = GitDiffView.new(source, :inline, highlights.freeze, hunk_rows, line_rows).freeze
      [output, view]
    end

    def render_side_by_side_git_diff(source)
      groups = source.diff.hunks.map { |hunk| paired_hunk_rows(hunk) }
      tab_size = git_diff_tab_size
      old_digits = [source.diff.hunks.map { |hunk| hunk.old_start + hunk.old_count }.max.to_i.to_s.length, 1].max
      new_digits = [source.diff.hunks.map { |hunk| hunk.new_start + hunk.new_count }.max.to_i.to_s.length, 1].max
      left_width = groups.flatten(1).map do |old, new|
        marker = side_line_ending_marker(old, new)
        side_display_width(side_text(old, old_digits, "-") + marker, tab_size)
      end.max.to_i.clamp(1, SIDE_COLUMN_WIDTH)
      output = +"#{source.before_label} │ #{source.after_label}\n"
      highlights, hunk_rows, line_rows = [], {}, {}
      unit_by_edit = staging_units(source.snapshot)
      display_row = 1
      groups.each_with_index do |pairs, hunk_index|
        hunk = source.diff.hunks.fetch(hunk_index)
        hunk_rows[display_row] = hunk_index if source.snapshot
        output << "@@ -#{hunk.old_start},#{hunk.old_count} +#{hunk.new_start},#{hunk.new_count} @@\n"
        display_row += 1
        pairs.each do |old, new|
          hunk_rows[display_row] = hunk_index if source.snapshot
          index = (old && unit_by_edit[old.object_id]) || (new && unit_by_edit[new.object_id])
          line_rows[display_row] = index if index
          old_spans, new_spans = old.equal?(new) ? [nil, nil] : Porrima::Inline.refine(old&.text.to_s, new&.text.to_s)
          old_prefix = side_prefix(old, old_digits, old.equal?(new) ? " " : "-", side: :old)
          old_body = diff_line_body(old&.text)
          old_marker = side_line_ending_marker(old, new)
          output << old_prefix
          old_base = output.bytesize
          old_body, old_ranges = fit_side_body(old_body, old_spans, old&.kind,
            side_display_width(old_prefix, tab_size), left_width, tab_size, old_marker)
          output << old_body
          padding = [left_width - side_display_width(old_prefix + old_body, tab_size), 0].max
          output << " " * padding << " │ "
          new_prefix = side_prefix(new, new_digits, old.equal?(new) ? " " : "+", side: :new)
          output << new_prefix
          new_base = output.bytesize
          new_body = diff_line_body(new&.text)
          new_marker = side_line_ending_marker(new, old)
          new_body, new_ranges = fit_side_body(new_body, new_spans, new&.kind,
            side_display_width(new_prefix, tab_size), SIDE_COLUMN_WIDTH, tab_size, new_marker)
          output << new_body << "\n"
          display_row += 1
          next if old.equal?(new)

          old_ranges.each do |range|
            highlights << Decoration::Item.new(:highlight, (old_base + range.begin...old_base + range.end).freeze,
              nil, nil, DELETED_STYLE, 0, :scm_diff, nil)
          end
          new_ranges.each do |range|
            highlights << Decoration::Item.new(:highlight, (new_base + range.begin...new_base + range.end).freeze,
              nil, nil, INSERTED_STYLE, 0, :scm_diff, nil)
          end
        end
      end
      if source.metadata
        hunk_rows[display_row] = 0 if source.snapshot
        output << "@@ metadata @@\n"
        display_row += 1
        hunk_rows[display_row] = 0 if source.snapshot
        output << source.metadata << "\n"
      end
      view = GitDiffView.new(source, :side_by_side, highlights.freeze,
        hunk_rows.freeze, line_rows.freeze).freeze
      [output, view]
    end

    def inline_spans(diff)
      diff.hunks.each_with_object({}) do |hunk, result|
        paired_hunk_rows(hunk).each do |old, new|
          next if old.equal?(new)
          old_spans, new_spans = Porrima::Inline.refine(old&.text.to_s, new&.text.to_s)
          result[old.object_id] = old_spans if old
          result[new.object_id] = new_spans if new
        end
      end
    end

    def paired_hunk_rows(hunk)
      rows = []
      index = 0
      while index < hunk.edits.length
        edit = hunk.edits[index]
        if edit.kind == :equal
          rows << [edit, edit]
          index += 1
          next
        end
        changed = []
        while index < hunk.edits.length && hunk.edits[index].kind != :equal
          changed << hunk.edits[index]
          index += 1
        end
        deleted = changed.select { |item| item.kind == :delete }
        inserted = changed.select { |item| item.kind == :insert }
        [deleted.length, inserted.length].max.times { |offset| rows << [deleted[offset], inserted[offset]] }
      end
      rows
    end

    def record_inline_highlights(items, base, text, spans, kind)
      return unless spans && kind != :equal
      record_highlights(items, base, diff_line_body(text).bytesize, spans, kind)
    end

    def fit_side_body(body, spans, kind, column, width, tab_size, marker = "")
      highlighted = []
      offset = 0
      spans&.each do |span|
        ending = offset + span.text.bytesize
        highlighted << (offset...ending) if span.kind == kind
        offset = ending
      end
      content_width = [width - side_display_width(marker, tab_size), column].max
      output, ranges, source_offset, highlighted_index, truncated = +"", [], 0, 0, false
      body.each_grapheme_cluster do |grapheme|
        display = grapheme == "\t" ? " " * (tab_size - column % tab_size) : grapheme
        grapheme_width = Unicode::DisplayWidth.of(display, emoji: :rgi)
        ending = source_offset + grapheme.bytesize
        if column + grapheme_width > content_width - (ending < body.bytesize ? 1 : 0)
          truncated = true
          break
        end
        start = output.bytesize
        output << display
        highlighted_index += 1 while highlighted[highlighted_index] && highlighted[highlighted_index].end <= source_offset
        range = highlighted[highlighted_index]
        if range && range.begin < ending
          if ranges.last&.end == start
            ranges[-1] = (ranges.last.begin...output.bytesize)
          else
            ranges << (start...output.bytesize)
          end
        end
        source_offset = ending
        column += grapheme_width
      end
      output << "…" if truncated
      unless marker.empty?
        start = output.bytesize
        output << marker
        ranges << (start...output.bytesize) if kind == :delete || kind == :insert
      end
      [output, ranges.freeze]
    end

    def side_display_width(text, tab_size)
      column = 0
      text.each_grapheme_cluster do |grapheme|
        column += grapheme == "\t" ? tab_size - column % tab_size : Unicode::DisplayWidth.of(grapheme, emoji: :rgi)
      end
      column
    end

    def git_diff_tab_size = @settings.for_language("diff")["tab_size"]

    def record_highlights(items, base, limit, spans, kind)
      offset = 0
      spans.each do |span|
        ending = [offset + span.text.bytesize, limit].min
        if span.kind == kind && ending > offset
          style = kind == :delete ? DELETED_STYLE : INSERTED_STYLE
          items << Decoration::Item.new(:highlight, (base + offset...base + ending).freeze,
            nil, nil, style, 0, :scm_diff, nil)
        end
        offset += span.text.bytesize
      end
    end

    def side_text(edit, digits, marker)
      side_prefix(edit, digits, marker, side: :old) + diff_line_body(edit&.text)
    end

    def side_prefix(edit, digits, marker, side:)
      number = edit && (side == :new ? edit.new_line : edit.old_line)
      "#{number ? number.to_s.rjust(digits) : ' ' * digits} #{edit ? marker : ' '} "
    end

    def diff_line_body(text) = text.to_s.delete_suffix("\n").delete_suffix("\r")

    def side_line_ending_marker(edit, peer)
      return "" unless edit
      ending = git_line_ending(edit.text)
      other = git_line_ending(peer&.text)
      return " [no newline]" if ending == :none
      return "" unless peer && ending != other
      " [#{ending.to_s.upcase}]"
    end

    def git_line_ending(text)
      return :crlf if text&.end_with?("\r\n")
      return :lf if text&.end_with?("\n")
      return :cr if text&.end_with?("\r")
      :none
    end

    def staging_units(snapshot)
      return {} unless snapshot
      snapshot.lines.each_with_index.each_with_object({}) do |(unit, index), result|
        unit.edits.each { |edit| result[edit.object_id] = index }
      end
    end

    def decode_git_diff_content(raw)
      return "" unless raw
      return nil if raw.bytesize > MAX_DIFF_BYTES
      scm_content(true, raw, nil).text
    end

    def git_diff_unavailable(path, before, after, byte_values:)
      return "Diff unavailable: #{scm_display_path(path)} exceeds 10 MiB\n" if
        byte_values.compact.sum { |value| value.respond_to?(:bytesize) ? value.bytesize : value.to_i } > MAX_DIFF_BYTES
      return "Binary file changed: #{scm_display_path(path)}\n" unless before && after
    end

    def revision_file_content(repository, commit, path)
      entry = commit && repository.tree(commit.oid)[path]
      return [scm_content(false, nil, nil), ""] unless entry
      if entry.mode == 0o160000
        text = "Subproject commit #{entry.oid}\n"
        content = Workspace::GitStaging::SCMContent.new(true, text.b.freeze, text.freeze,
          Encoding::UTF_8, "".b.freeze, entry.mode).freeze
        return [content, text]
      end
      content = scm_entry_content(repository, entry)
      [content, content.text]
    end

    def revision_label(path, revision) = "#{scm_display_path(path)}@#{revision || '(empty)'}"

    def normalize_git_diff_mode(mode)
      return :inline if mode == :inline || mode == "inline"
      return :side_by_side if [:side_by_side, :"side-by-side", "side_by_side", "side-by-side"].include?(mode)
      raise ArgumentError, "Git diff mode must be :inline or :side_by_side"
    end

    def git_diff_target_path(path)
      return path if path
      view = editor&.buffer&.instance_variable_get(:@git_diff_view)
      view ? view.source.path : git_relative_path
    end

    def safe_git_diff_path(path)
      valid = path.is_a?(String) && path.bytesize.between?(1, MAX_PATH_BYTES) && !path.include?("\0")
      raise Error, "Invalid Git path" unless valid
      pieces = path.split("/", -1)
      windows = Gem.win_platform?
      drive = path.bytesize > 1 && ((65..90).cover?(path.getbyte(0)) || (97..122).cover?(path.getbyte(0))) && path.getbyte(1) == 58
      unsafe = path.start_with?("/") || drive || pieces.any? do |piece|
        windows_stem = piece.split(".", 2).first.sub(/[ ]+\z/, "") if windows
        windows_reserved = windows_stem&.match?(
          /\A(?:con(?:in\$|out\$)?|prn|aux|nul|clock\$|com[0-9¹²³]|lpt[0-9¹²³])\z/i
        )
        windows_git_alias = piece.match?(/\A\.?git~[0-9]+\z/i) if windows
        ["", ".", ".."].include?(piece) || piece.casecmp?(".git") || windows &&
          (piece.end_with?(".", " ") || piece.match?(/[\x01-\x1f<>:"|?*\\]/) || windows_reserved || windows_git_alias)
      end
      raise Error, "Unsafe Git path: #{scm_display_path(path)}" if unsafe
      repository = git
      raise Error, "Not a Git repository" unless repository
      repository.worktree_path(path)
      path.dup.freeze
    rescue ArgumentError
      raise Error, "Unsafe Git path: #{scm_display_path(path)}"
    end

    def validate_git_revision(revision, allow_nil: false)
      return if allow_nil && revision.nil?
      unless revision.is_a?(String) && revision.valid_encoding? && revision.bytesize.between?(1, MAX_REVISION_BYTES) &&
          !revision.match?(/[\x00-\x20\\]/)
        raise Error, "Invalid Git revision"
      end
      revision.dup.freeze
    end

    def resolve_git_revision(repository, revision)
      return unless revision
      repository.commit(revision) || raise(Error, "Unknown Git revision: #{revision}")
    rescue ArgumentError => error
      raise Error, "Invalid Git revision #{revision}: #{error.message}"
    end

    def collect_git_file_history(repository, path, revision, limit)
      resolve_git_revision(repository, revision)
      trees = {}
      tree = lambda do |oid|
        value = trees.delete(oid) || repository.tree(oid)
        trees[oid] = value
        trees.shift while trees.length > 2
        value
      end
      history = []
      scanned = 0
      current_path = path
      repository.each_commit(revision, limit: MAX_HISTORY_SCAN) do |commit|
        scanned += 1
        current_tree = tree.call(commit.oid)
        current = current_tree[current_path]
        parent = commit.parents.first
        parent_tree = tree.call(parent) if parent
        previous = parent_tree&.[](current_path)
        rename_candidates = if current && !previous && parent_tree
          parent_tree.each_value.select do |entry|
            same_git_tree_entry?(current, entry) && !same_git_tree_entry?(entry, current_tree[entry.path])
          end
        else
          []
        end
        renamed_from = rename_candidates.one? ? rename_candidates.first.path : nil
        next if !renamed_from && same_git_tree_entry?(current, previous)
        signature = commit.signature(role: :author)
        subject = safe_git_history_text(commit.message.to_s.lines.first, 200)
        author = safe_git_history_text(signature.name, 100)
        history << GitHistoryEntry.new(commit.oid.dup.freeze, parent&.dup&.freeze, subject.freeze,
          author.freeze, signature.time, current_path.dup.freeze).freeze
        current_path = renamed_from if renamed_from
        break if history.length >= limit
        break if rename_candidates.length > 1
      end
      raise Error, "Git history scan exceeded #{MAX_HISTORY_SCAN} commits" if scanned == MAX_HISTORY_SCAN && history.length < limit
      history.freeze
    end

    def same_git_tree_entry?(left, right)
      return !left && !right unless left && right
      left.oid == right.oid && left.mode == right.mode
    end

    def git_history_label(entry)
      subject = safe_git_history_text(entry.subject, 200)
      author = safe_git_history_text(entry.author, 100)
      author = author.empty? ? "" : " · #{author}"
      "#{entry.oid[0, 8]} #{subject}#{author}"
    end

    def safe_git_history_text(value, limit)
      value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        .gsub(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+/, " ").strip.slice(0, limit)
    end

    def install_git_history(path, entries)
      self.palette = {kind: :git_file_history, query: +"", index: 0,
        matches: entries.map { |entry| git_history_label(entry) }, items: entries, path: path}
      update_palette
      @palette
    end

    def finish_git_history(worker, generation, palette_generation, path, entries, error)
      @git_history_jobs&.delete(worker)
      return unless generation == @git_history_generation && palette_generation == @palette_generation.to_i
      error ? self.message = "Git history: #{error.message}" : install_git_history(path, entries)
    end
  end
end

# frozen_string_literal: true

module Canopus
  # Editable, nonoverlapping source excerpts with protected headings.
  class MultiBuffer < Buffer
    Excerpt = Struct.new(:buffer, :first, :last, :title, :view_start, :view_end)
    attr_reader :excerpts
    def initialize(excerpts: [])
      super("")
      @excerpts, @source_subscriptions, @multi_undo, @multi_redo = [], {}, [], []
      validate_excerpt_ranges(excerpts)
      @building = true
      excerpts.each { |buffer, range, title| add_excerpt(buffer, range, title: title) }
      @building = false
      refresh
    end
    def add_excerpt(buffer, range, title: nil)
      raise Error, "excerpt source must be a regular buffer" unless buffer.is_a?(Buffer) && !buffer.is_a?(MultiBuffer)
      ending = range.end + (range.exclude_end? ? 0 : 1)
      buffer.rope.byteslice(range.begin, ending - range.begin)
      overlap = !@building && @excerpts.any? do |excerpt|
        excerpt.buffer.equal?(buffer) && range.begin <= buffer.resolve(excerpt.last) && ending >= buffer.resolve(excerpt.first)
      end
      raise Error, "excerpts of the same buffer must be disjoint and nonadjacent" if overlap
      label = title || "#{buffer.path || 'Untitled'}:#{buffer.rope.point_at(range.begin).row + 1}"
      @excerpts << Excerpt.new(buffer, buffer.anchor(range.begin, bias: :left), buffer.anchor(ending, bias: :right), label.to_s.freeze)
      @source_subscriptions[buffer] ||= buffer.on_edit { refresh unless @syncing }
      refresh unless @building
      self
    end

    # Attach a privately prepared projection to live sources on the foreground
    # thread. Source ropes must be the exact immutable snapshots used to build
    # it; caller additionally validates workspace identity/version before this.
    # No text rebuild, regex scan or disk IO occurs here.
    def attach_sources(replacements)
      raise Error, "cannot attach an edited projection" unless @multi_undo.empty? && @multi_redo.empty?
      return self if replacements.empty?
      replacements.each do |source, target|
        raise Error, "unknown excerpt source" unless @source_subscriptions.key?(source)
        raise Error, "excerpt source must be a regular buffer" unless target.is_a?(Buffer) && !target.is_a?(MultiBuffer)
        raise Error, "source buffer is read-only" if target.read_only
        raise Error, "excerpt source snapshot changed" unless source.rope.equal?(target.rope)
      end
      targets = @source_subscriptions.keys.map { |source| replacements.fetch(source, source) }
      raise Error, "excerpt source aliases would overlap" unless targets.uniq.length == targets.length
      anchors = []
      subscriptions = {}
      replacements.each do |source, target|
        subscriptions[target] = target.on_edit { refresh unless @syncing } unless source.equal?(target)
      end
      @excerpts.each do |excerpt|
        target = replacements[excerpt.buffer]
        next unless target && !target.equal?(excerpt.buffer)
        entry = [excerpt, target, target.copy_anchor(excerpt.buffer, excerpt.first)]
        anchors << entry
        entry << target.copy_anchor(excerpt.buffer, excerpt.last)
      end
      committed = true
      anchors.each do |excerpt, target, first, last|
        excerpt.buffer.release_anchor(excerpt.first)
        excerpt.buffer.release_anchor(excerpt.last)
        excerpt.buffer, excerpt.first, excerpt.last = target, first, last
      end
      @source_subscriptions = @source_subscriptions.to_h do |source, subscription|
        target = replacements.fetch(source, source)
        if source.equal?(target)
          [source, subscription]
        else
          subscription.detach
          [target, subscriptions.fetch(target)]
        end
      end
      self
    rescue StandardError
      unless committed
        subscriptions&.each_value(&:detach)
        anchors&.each do |_, target, first, last|
          target.release_anchor(first)
          target.release_anchor(last) if last
        end
      end
      raise
    end
    def dirty? = @excerpts.any? { |excerpt| excerpt.buffer.dirty? }
    def begin_undo_group
      @multi_undo_start = @multi_undo.length unless @undo_group_depth&.positive?
      @excerpts.map(&:buffer).uniq.each(&:begin_undo_group)
      super
    end
    def end_undo_group
      super
      @excerpts.map(&:buffer).uniq.each(&:end_undo_group)
    end
    def edit(changes, **options)
      return super if @refreshing
      return if changes.empty?
      @rope.apply_edits(changes)
      grouped = changes.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(range, text), result|
        ending = range.end + (range.exclude_end? ? 0 : 1)
        excerpt = @excerpts.find { |item| range.begin >= item.view_start && ending <= item.view_end }
        raise Error, "search-result headings cannot be edited" unless excerpt
        raise Error, "source buffer is read-only" if excerpt.buffer.read_only
        start = excerpt.buffer.resolve(excerpt.first)
        result[excerpt.buffer] << [(start + range.begin - excerpt.view_start)...(start + ending - excerpt.view_start), text]
      end
      patches = grouped.to_h do |buffer, edits|
        [buffer, Patch.new(buffer.rope, buffer.rope.apply_edits(edits), edits)]
      end
      checkpoints = grouped.keys.to_h { |buffer| [buffer, buffer.send(:edit_checkpoint)] }
      before = grouped.keys.to_h { |buffer| [buffer, buffer.rope] }
      @syncing = true
      applied = []
      begin
        grouped.each do |buffer, edits|
          begin
            buffer.edit(edits, kind: :multi_buffer)
          ensure
            # A source may mutate and then raise. Conversely a pre-commit
            # failure must never undo an unrelated previous source edit.
            applied << buffer unless buffer.rope.equal?(before.fetch(buffer))
          end
        end
        result = super(changes, **options)
        rebuild_text
        after = grouped.keys.to_h { |buffer| [buffer, buffer.rope] }
        if @undo_group_depth&.positive? && @multi_undo.length > @multi_undo_start
          previous = @multi_undo.last
          previous[0] = before.merge(previous.first)
          previous[1] = previous.last.merge(after)
        else
          @multi_undo << [before, after]
        end
        @multi_redo.clear
        result
      rescue StandardError
        applied.reverse_each do |buffer|
          buffer.send(:restore_edit, checkpoints.fetch(buffer), patches.fetch(buffer).inverse)
        rescue StandardError
          # Preserve the original application error, and still restore the
          # other sources. Notification failures are isolated by Buffer.
        end
        raise
      ensure
        @syncing = false
      end
    end
    def undo
      raise Error, "end the undo group before undo" if @undo_group_depth&.positive?
      group = @multi_undo.last
      return false unless group
      raise Error, "source changed since this excerpt edit" unless group.last.all? { |buffer, snapshot| buffer.rope.equal?(snapshot) }
      @syncing = true
      group.last.keys.reverse_each(&:undo)
      super
      @multi_redo << @multi_undo.pop
      rebuild_text
      true
    ensure
      @syncing = false
    end
    def redo
      raise Error, "end the undo group before redo" if @undo_group_depth&.positive?
      group = @multi_redo.last
      return false unless group
      raise Error, "source changed since this excerpt edit" unless group.first.all? { |buffer, snapshot| buffer.rope.equal?(snapshot) }
      @syncing = true
      group.first.keys.each(&:redo)
      super
      @multi_undo << @multi_redo.pop
      rebuild_text
      true
    ensure
      @syncing = false
    end
    def save(path = nil, force: false)
      raise Error, "Save excerpt files individually to choose new paths" if path
      @excerpts.map(&:buffer).uniq.each { |buffer| buffer.save(force: force) if buffer.dirty? }
      self
    end
    def close
      @source_subscriptions.each_value(&:detach)
      @excerpts.each do |excerpt|
        excerpt.buffer.release_anchor(excerpt.first)
        excerpt.buffer.release_anchor(excerpt.last)
      end
    end

    private
    # Validate grouped, sorted intervals once. Repeated add_excerpt overlap
    # scans made a 10,000-excerpt constructor quadratic in excerpt count.
    def validate_excerpt_ranges(excerpts)
      excerpts.group_by(&:first).each do |buffer, entries|
        raise Error, "excerpt source must be a regular buffer" unless buffer.is_a?(Buffer) && !buffer.is_a?(MultiBuffer)
        previous_end = nil
        entries.sort_by { |_, range, _| range.begin }.each do |_, range, _|
          ending = range.end + (range.exclude_end? ? 0 : 1)
          buffer.rope.byteslice(range.begin, ending - range.begin)
          raise Error, "excerpts of the same buffer must be disjoint and nonadjacent" if previous_end && range.begin <= previous_end
          previous_end = ending
        end
      end
    end

    def rebuild_text
      text = +""
      @excerpts.each do |excerpt|
        text << "#{excerpt.title}\n"
        excerpt.view_start = text.bytesize
        first, last = excerpt.buffer.resolve(excerpt.first), excerpt.buffer.resolve(excerpt.last)
        text << excerpt.buffer.rope.byteslice(first...last).to_s
        excerpt.view_end = text.bytesize
        text << "\n\n"
      end
      text
    end
    def refresh
      normalize_excerpts
      text = rebuild_text
      @refreshing = true
      edit([[0...@rope.bytesize, text]], kind: :source_refresh)
      @saved_rope = @rope
      @history.clear
      @redo.clear
      @multi_undo.clear
      @multi_redo.clear
    ensure
      @refreshing = false
    end

    # External source edits can collapse previously disjoint anchored ranges.
    # Keep their union once, under the earliest heading, so every displayed byte
    # still has one editable source location. No source text is discarded.
    def normalize_excerpts
      removed = {}.compare_by_identity
      @excerpts.each_with_index.group_by { |excerpt, _| excerpt.buffer }.each do |buffer, values|
        group, first, last = [], nil, nil
        values.sort_by { |excerpt, _| buffer.resolve(excerpt.first) }.each do |entry|
          excerpt = entry.first
          start, ending = buffer.resolve(excerpt.first), buffer.resolve(excerpt.last)
          if last && start > last
            merge_excerpts(buffer, group, first, last, removed)
            group = []
          end
          first = start if group.empty?
          last = group.empty? ? ending : [last, ending].max
          group << entry
        end
        merge_excerpts(buffer, group, first, last, removed)
      end
      @excerpts.reject! { |excerpt| removed.key?(excerpt) }
    end

    def merge_excerpts(buffer, entries, first, last, removed)
      return if entries.length < 2
      keeper = entries.min_by(&:last).first
      entries.each do |excerpt, _|
        buffer.release_anchor(excerpt.first)
        buffer.release_anchor(excerpt.last)
        removed[excerpt] = true unless excerpt.equal?(keeper)
      end
      keeper.first = buffer.anchor(first, bias: :left)
      keeper.last = buffer.anchor(last, bias: :right)
    end
  end
end

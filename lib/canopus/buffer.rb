# frozen_string_literal: true

require "digest"
require "tempfile"

module Canopus
  class Buffer
    Transaction = Struct.new(:before, :after, :before_selections, :after_selections, :patch, :kind, :time)
    Anchor = Data.define(:id, :bias)
    attr_reader :rope, :path, :encoding, :line_ending, :version, :history, :read_only, :disk_digest, :bom, :notification_errors
    attr_accessor :selections

    def self.open(path, large_file_threshold: 100 << 20)
      if File.size(path) >= large_file_threshold
        require_relative "lazy_rope"
        rope = LazyRope.new(path)
        return new("", path: path, read_only: true, rope: rope)
      end
      raw = File.binread(path)
      text, encoding, bom = decode_bytes(raw)
      new(text, path: path, encoding: encoding, bom: bom, disk_digest: Digest::SHA256.hexdigest(raw))
    rescue EncodingError => error
      raise Error, "cannot decode #{path}: #{error.message}"
    end

    # Decode worktree files and historical Git blobs by the same rules.
    # @return [Array(String, Encoding, String)] UTF-8 text, source encoding, BOM
    def self.decode_bytes(raw)
      raw = raw.b unless raw.encoding == Encoding::BINARY
      bom, encoding = if raw.start_with?("\xEF\xBB\xBF".b)
        ["\xEF\xBB\xBF".b, Encoding::UTF_8]
      elsif raw.start_with?("\xFF\xFE".b)
        ["\xFF\xFE".b, Encoding::UTF_16LE]
      elsif raw.start_with?("\xFE\xFF".b)
        ["\xFE\xFF".b, Encoding::UTF_16BE]
      elsif raw.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        ["".b, Encoding::UTF_8]
      else
        ["".b, Encoding::Windows_31J]
      end
      text = raw.byteslice(bom.bytesize..).force_encoding(encoding).encode(Encoding::UTF_8)
      raise Error, "binary file contains NUL bytes" if text.include?("\0")
      [text, encoding, bom]
    end

    def initialize(text = "", path: nil, encoding: Encoding::UTF_8, bom: "".b, disk_digest: nil, read_only: false, draft: false, rope: nil)
      @rope = rope || Denebola::Rope.new(text)
      @path = path && File.expand_path(path)
      @encoding, @bom, @disk_digest = encoding, bom, disk_digest
      @saved_rope, @version, @history, @redo = @rope, 0, [], []
      @saved_rope = nil if draft
      @listeners, @anchors, @next_anchor, @selections = [], {}, 0, []
      @notification_errors = [].freeze
      @line_ending = text[/\r\n|\n|\r|\u2028|\u2029/] || "\n"
      @line_ending = if rope.respond_to?(:line_ending)
        rope.line_ending
      elsif rope && text.empty?
        snapshot_line_ending(rope)
      else
        @line_ending
      end
      @read_only = read_only
    end
    def text = rope.to_s
    def relocate(path) = @path = File.expand_path(path)
    def close = (@rope.close if @rope.respond_to?(:close))
    def line(row) = rope.line(row)
    def line_count = rope.line_count
    def dirty? = !@rope.equal?(@saved_rope)
    def reload(force: false)
      raise SaveConflict, "buffer has unsaved changes" if dirty? && !force
      raise Error, "buffer has no file path" unless @path
      if @rope.respond_to?(:lazy?) && @rope.lazy?
        fresh = Buffer.open(@path, large_file_threshold: 0)
        old = @rope
        apply_snapshot(fresh.rope, Patch::Reload.new(old, fresh.rope))
        old.close
      else
        fresh = Buffer.open(@path)
        raise Error, "file grew beyond the editable limit; reopen it read-only" if fresh.read_only
        before, after = text, fresh.text
        if before != after
          first, shared = 0, [before.bytesize, after.bytesize].min
          first += 4096 while first + 4096 <= shared && before.byteslice(first, 4096) == after.byteslice(first, 4096)
          first += 1 while first < shared && before.getbyte(first) == after.getbyte(first)
          first -= 1 while first.positive? && before.getbyte(first)&.&(0xc0) == 0x80
          last = 0
          last += 4096 while last + 4096 <= shared - first && before.byteslice(before.bytesize - last - 4096, 4096) == after.byteslice(after.bytesize - last - 4096, 4096)
          last += 1 while last < shared - first && before.getbyte(before.bytesize - last - 1) == after.getbyte(after.bytesize - last - 1)
          last -= 1 while last.positive? && before.getbyte(before.bytesize - last)&.&(0xc0) == 0x80
          edit([[first...(before.bytesize - last), after.byteslice(first, after.bytesize - first - last)]], kind: :reload)
        end
      end
      @saved_rope = @rope
      @disk_digest, @encoding, @bom, @line_ending = fresh.disk_digest, fresh.encoding, fresh.bom, fresh.line_ending
      self
    ensure
      fresh&.close unless fresh&.rope.equal?(@rope)
    end
    # Notifications observe an already committed edit (including undo/redo).
    # A listener's StandardError is reported, not raised as an edit failure;
    # remaining listeners still run. Keep only the latest 32 bounded messages.
    def on_edit(&listener)
      @listeners << listener
      Zaniah::Subscription.new { @listeners.delete(listener) }
    end
    def anchor(offset, bias: :right)
      raise ArgumentError, "bias must be :left or :right" unless bias == :left || bias == :right
      @rope.point_at(offset)
      anchor = Anchor.new(@next_anchor, bias)
      @next_anchor += 1
      @anchors[anchor] = offset
      anchor
    end
    def resolve(anchor) = @anchors.fetch(anchor)
    def release_anchor(anchor) = @anchors.delete(anchor)

    # Copy a registered position only from the exact same immutable snapshot.
    # This avoids repeating a rope lookup for privately prepared excerpts.
    def copy_anchor(source, anchor)
      raise ArgumentError, "anchor source must be a regular buffer" unless source.is_a?(Buffer) && !source.is_a?(MultiBuffer)
      raise ArgumentError, "anchor source snapshot differs" unless source.rope.equal?(@rope)
      offset = source.resolve(anchor)
      copied = Anchor.new(@next_anchor, anchor.bias)
      @next_anchor += 1
      @anchors[copied] = offset
      copied
    end

    def begin_undo_group
      @undo_group_depth ||= 0
      @undo_group_start = @history.length if @undo_group_depth.zero?
      @undo_group_depth += 1
      self
    end
    def end_undo_group
      raise Error, "no undo group is open" unless @undo_group_depth&.positive?
      @undo_group_depth -= 1
      @undo_group_start = nil if @undo_group_depth.zero?
      self
    end

    def edit(changes, kind: :edit, selections: nil, before_selections: @selections, time: Process.clock_gettime(Process::CLOCK_MONOTONIC), group: false)
      raise Error, "buffer is read-only" if @read_only
      return if changes.empty?
      before, after = @rope, @rope.apply_edits(changes)
      patch = Patch.new(before, after, changes)
      # Direct edits (formatting, LSP, excerpt sources) have no Editor to supply
      # the post-edit cursor positions. Preserve explicit selection overrides.
      selections ||= before_selections.map do |selection|
        selection.with(anchor: patch.map_offset(selection.anchor), head: patch.map_offset(selection.head))
      end
      transaction = Transaction.new(before, after, before_selections.dup.freeze, selections.dup.freeze, patch, kind, time)
      previous = @history.last
      explicit_group = @undo_group_depth&.positive?
      merge = explicit_group ? @history.length > @undo_group_start : group && previous && previous.kind == kind && time - previous.time < 0.3 && previous.after_selections == before_selections
      if merge && previous && previous.after.equal?(before)
        previous.after, previous.after_selections, previous.time = after, transaction.after_selections, time
        previous.patch = previous.patch.compose(patch)
      else
        @history << transaction
      end
      @redo.clear
      @selections = selections
      apply_snapshot(after, patch)
      patch
    end
    def undo
      raise Error, "end the undo group before undo" if @undo_group_depth&.positive?
      transaction = @history.pop
      return false unless transaction
      @redo << transaction
      @selections = transaction.before_selections.dup
      apply_snapshot(transaction.before, transaction.patch.inverse)
      true
    end
    def redo
      raise Error, "end the undo group before redo" if @undo_group_depth&.positive?
      transaction = @redo.pop
      return false unless transaction
      @history << transaction
      @selections = transaction.after_selections.dup
      apply_snapshot(transaction.after, transaction.patch)
      true
    end

    # Encode first, write and fsync a sibling temporary file, atomically rename.
    def save(path = @path, force: false)
      raise Error, "no file path" unless path
      raise Error, "buffer is read-only" if @read_only
      destination = File.expand_path(path)
      destination = File.realpath(destination) if File.symlink?(destination)
      original = File.file?(destination) ? File.binread(destination) : nil
      same_file = @path && (File.expand_path(path) == @path || (File.exist?(@path) && File.exist?(destination) && File.identical?(@path, destination)))
      if !force && same_file && @disk_digest && (!original || Digest::SHA256.hexdigest(original) != @disk_digest)
        raise SaveConflict, "file changed on disk: #{path}"
      end
      raise SaveConflict, "destination exists: #{path}" if !force && original && (!same_file || !@disk_digest)
      encoded = @bom + text.encode(@encoding).b
      Tempfile.create([".canopus-", ".tmp"], File.dirname(destination), binmode: true) do |file|
        file.chmod(File.stat(destination).mode & 0o777) if original
        file.write(encoded)
        file.flush
        file.fsync
        file.close
        current = File.file?(destination) ? File.binread(destination) : nil
        raise SaveConflict, "file changed during save: #{path}" if !force && current != original
        File.rename(file.path, destination)
      end
      @path = File.expand_path(path)
      @saved_rope, @disk_digest = @rope, Digest::SHA256.hexdigest(encoded)
      self
    rescue EncodingError => error
      raise Error, "cannot save using #{@encoding}: #{error.message}"
    end

    def trim_trailing_whitespace
      changes = []
      rope.line_count.times do |row|
        value = rope.line(row)
        whitespace = value[/[ \t]+\z/]
        next unless whitespace
        ending = rope.line_start(row) + value.bytesize
        changes << [(ending - whitespace.bytesize)...ending, ""]
      end
      edit(changes, kind: :format)
    end

    private
    def snapshot_line_ending(rope)
      return "\n" if rope.line_count < 2
      ending = rope.line_start(1)
      first = [ending - 3, 0].max
      begin
        tail = rope.byteslice(first, ending - first).to_s
      rescue RangeError
        first += 1 # The three-byte suffix can start inside the preceding glyph.
        retry
      end
      tail[/(?:\r\n|[\r\n\u2028\u2029])\z/] || "\n"
    end

    # MultiBuffer prepares all source edits first. If a source implementation
    # raises during application, restore its in-memory edit state without
    # consuming an older undo entry or leaving the aborted edit in redo.
    def edit_checkpoint
      history = @history.dup
      history[-1] = history.last.dup unless history.empty? # Grouping only mutates the last entry.
      {rope: @rope, history: history, redo: @redo.dup,
        selections: @selections, anchors: @anchors.dup}
    end

    def restore_edit(checkpoint, inverse)
      @rope = checkpoint.fetch(:rope)
      @history.replace(checkpoint.fetch(:history))
      @redo.replace(checkpoint.fetch(:redo))
      @selections = checkpoint.fetch(:selections)
      anchors = checkpoint.fetch(:anchors)
      @anchors.each do |anchor, offset|
        # An observer may create/release anchors (e.g. merge its excerpts).
        # Preserve their lifetime, while restoring surviving pre-edit anchors
        # exactly, including positions inside a deleted span.
        @anchors[anchor] = anchors.fetch(anchor) { inverse.map_offset(offset, bias: anchor.bias) }
      end
      # Observers may have seen the failed source's mutation. Announce its
      # compensation with a newer version; arbitrary callback side effects
      # cannot be undone by the buffer.
      @version += 1
      notify_edit(inverse)
    end

    def apply_snapshot(snapshot, patch)
      @rope = snapshot
      @anchors.each { |anchor, offset| @anchors[anchor] = patch.map_offset(offset, bias: anchor.bias) }
      @version += 1
      notify_edit(patch)
    end

    def notify_edit(patch)
      @listeners.dup.each do |listener|
        listener.call(patch)
      rescue StandardError => error
        message = "#{error.class}: #{error.message}".encode(Encoding::UTF_8, invalid: :replace, undef: :replace).byteslice(0, 2048).scrub("")
        @notification_errors = [*@notification_errors.last(31), Error.new(message)].freeze
        begin
          warn "Canopus buffer notification failed: #{message}"
        rescue StandardError
          # A broken stderr cannot turn an already committed edit into failure.
        end
      end
    end
  end
end

# frozen_string_literal: true

require "json"
require "fileutils"
require "objspace"
require "tempfile"
require_relative "../error"
require_relative "../buffer"

module Canopus
  module Debug
    class Breakpoints
      Entry = Data.define(:path, :line, :condition, :hit_condition, :log_message, :enabled)
      VERSION = 2
      RELATIVE_PATH = File.join(".canopus", "breakpoints.json")
      MAX_BYTES = 1_048_576
      MAX_ENTRIES = 10_000
      MAX_PATH_BYTES = 4_096
      MAX_CONDITION_BYTES = 4_096
      MAX_HIT_CONDITION_BYTES = 4_096
      MAX_LOG_MESSAGE_BYTES = 4_096
      MAX_LINE = 2_147_483_647
      SAVE_DELAY = 0.02
      UNSET = Object.new.freeze
      private_constant :SAVE_DELAY, :UNSET

      attr_reader :root, :entries

      def initialize(root:, &on_change)
        @root = canonical_root(root)
        @on_change = on_change
        @attachments = {}
        @closed = false
        @entries = load_entries
        @state_lock = Mutex.new
        @save_lock, @save_wake = Mutex.new, ConditionVariable.new
        @save_generation = @saved_generation = 0
        @pending_save = @save_error = nil
        @saving = @save_stopping = false
        @save_worker = Thread.new { save_loop }
        @save_worker.name = "canopus-breakpoints"
      end

      def for_path(path)
        relative = normalize_path(path)
        entries.select { |entry| entry.path == relative }.freeze
      end

      def add(path, line, condition: nil, hit_condition: nil, log_message: nil, enabled: true)
        @state_lock.synchronize do
          ensure_open!
          entry = build_entry(path, line, condition, hit_condition, log_message, enabled)
          existing = entries.find { |item| item.path == entry.path && item.line == entry.line }
          return existing if existing == entry
          replacement = entries.reject { |item| item.path == entry.path && item.line == entry.line }
          commit([*replacement, entry], changed_path: entry.path)
          entry
        end
      end

      def remove(path, line)
        @state_lock.synchronize do
          ensure_open!
          relative, line = normalize_path(path), validate_line(line)
          replacement = entries.reject { |entry| entry.path == relative && entry.line == line }
          return false if replacement.length == entries.length
          commit(replacement, changed_path: relative)
          true
        end
      end

      def toggle(path, line, condition: nil, hit_condition: nil, log_message: nil, enabled: true)
        existing = for_path(path).find { |entry| entry.line == line }
        return nil if existing && remove(path, line)
        add(path, line, condition: condition, hit_condition: hit_condition, log_message: log_message, enabled: enabled)
      end

      def update(path, line, new_line: line, condition: UNSET, hit_condition: UNSET, log_message: UNSET, enabled: UNSET)
        @state_lock.synchronize do
          ensure_open!
          relative, line = normalize_path(path), validate_line(line)
          current = entries.find { |entry| entry.path == relative && entry.line == line }
          raise Error, "breakpoint does not exist" unless current
          condition = current.condition if condition.equal?(UNSET)
          hit_condition = current.hit_condition if hit_condition.equal?(UNSET)
          log_message = current.log_message if log_message.equal?(UNSET)
          enabled = current.enabled if enabled.equal?(UNSET)
          replacement = build_entry(relative, new_line, condition, hit_condition, log_message, enabled)
          collision = entries.any? { |entry| !entry.equal?(current) && entry.path == relative && entry.line == replacement.line }
          raise Error, "breakpoint already exists" if collision
          return current if current == replacement
          commit(entries.map { |entry| entry.equal?(current) ? replacement : entry }, changed_path: relative)
          replacement
        end
      end

      def attach(buffer)
        @state_lock.synchronize do
          ensure_open!
          raise Error, "breakpoints require a file-backed buffer" unless buffer.is_a?(Buffer) && buffer.path
          return self if @attachments.key?(buffer)
          path = normalize_path(buffer.path)
          ensure_attachment_path_available!(buffer, path)
          attachment = {snapshots: ObjectSpace::WeakMap.new, states: {}.compare_by_identity,
                        path: path, revision: 0, gc_count: GC.count}
          store_snapshot(attachment, buffer.rope, entries_for(path))
          subscription = buffer.on_edit { |patch| edited(buffer, patch) }
          attachment[:subscription] = subscription
          @attachments[buffer] = attachment
        end
        self
      end

      def detach(buffer)
        attachment = @state_lock.synchronize { @attachments.delete(buffer) }
        attachment&.fetch(:subscription)&.detach
        flush if attachment
        !attachment.nil?
      end

      def close
        attachments = @state_lock.synchronize do
          return nil if @closed
          @closed = true
          values = @attachments.values
          @attachments.clear
          values
        end
        attachments.each { |attachment| attachment.fetch(:subscription).detach }
        flush
        nil
      ensure
        stop_save_worker if attachments
      end

      def flush
        target = @save_lock.synchronize { @save_generation }
        @save_lock.synchronize do
          until @saved_generation >= target
            if !@saving && !@pending_save && @save_error && @save_error.first >= target
              raise @save_error.last
            end
            @save_wake.wait(@save_lock)
          end
        end
        self
      end

      def error
        @save_lock.synchronize { @save_error&.last }
      end

      private

      def edited(buffer, patch)
        @state_lock.synchronize do
          attachment = @attachments[buffer]
          return unless attachment
          begin
            path = normalize_path(buffer.path)
            unless path == attachment.fetch(:path)
              ensure_attachment_path_available!(buffer, path)
              relocate_attachment(attachment, patch.before, path)
            end
            revision = attachment.fetch(:revision)
            snapshots = attachment.fetch(:snapshots)
            saved = snapshots[patch.after]
            mapped = saved && saved[0] == revision ? saved[1] : map_entries(entries_for(path), patch)
            current = entries_for(path)
            if mapped != current
              @entries = sorted_entries([*entries.reject { |entry| entry.path == path }, *mapped])
              schedule_save(@entries)
              notify_change(path)
            end
            store_snapshot(attachment, patch.after, mapped)
          rescue StandardError
            @attachments.delete(buffer)
            attachment.fetch(:subscription).detach
            raise
          end
        end
      end

      def map_entries(items, patch)
        if patch.is_a?(Patch::Composite)
          return patch.patches.reduce(items) { |current, child| map_entries(current, child) }
        end
        seen = {}
        mapped = items.filter_map do |entry|
          mapped_entry = map_entry(entry, patch)
          next unless mapped_entry
          key = [mapped_entry.path, mapped_entry.line]
          next if seen[key]
          seen[key] = true
          mapped_entry
        end
        mapped == items ? items : mapped.freeze
      end

      def map_entry(entry, patch)
        row = entry.line - 1
        return entry if row >= patch.before.line_count
        start = patch.before.line_start(row)
        content_end = start + patch.before.line(row).bytesize
        full_end = row + 1 < patch.before.line_count ? patch.before.line_start(row + 1) : patch.before.bytesize
        identity_end = content_end == start ? full_end : content_end
        if identity_end > start
          covered, replacement = line_change(patch.edits, start, identity_end)
          return mapped_entry(entry, patch.after, replacement) if covered && replacement
          return if covered
        end
        return if deleted_final_empty_line?(patch, row, start)
        position = patch.map_offset(start, bias: :right)
        mapped_entry(entry, patch.after, position)
      end

      def line_change(edits, start, ending)
        cursor, replacement, delta = start, nil, 0
        edits.sort_by { |edit| [edit.old_range.begin, edit.old_range.end] }.each do |edit|
          break if cursor >= ending && edit.old_range.begin > ending
          new_start = edit.old_range.begin + delta
          relevant = if edit.old_range.begin == edit.old_range.end
            edit.old_range.begin.between?(start, ending)
          else
            edit.old_range.begin < ending && edit.old_range.end > start
          end
          replacement ||= new_start if relevant && !edit.new_text.empty?
          if edit.old_range.end > cursor
            return [false, nil] if edit.old_range.begin > cursor
            cursor = edit.old_range.end
          end
          delta += edit.new_text.bytesize - (edit.old_range.end - edit.old_range.begin)
        end
        [cursor >= ending, replacement]
      end

      def deleted_final_empty_line?(patch, row, start)
        return false unless row == patch.before.line_count - 1 && row.positive? && start == patch.before.bytesize
        break_start = patch.before.line_start(row - 1) + patch.before.line(row - 1).bytesize
        return true if deletions_cover?(patch.edits, break_start, start)
        replacement = patch.edits.find do |edit|
          edit.old_range.begin <= break_start && edit.old_range.end >= start && !edit.new_text.empty?
        end
        replacement && !replacement.new_text.match?(/(?:\r\n|[\r\n\u2028\u2029])\z/)
      end

      def deletions_cover?(edits, start, ending)
        cursor = start
        edits.each do |edit|
          next unless edit.new_text.empty? && edit.old_range.end > cursor
          return false if edit.old_range.begin > cursor
          cursor = [cursor, edit.old_range.end].max
          return true if cursor >= ending
        end
        false
      end

      def mapped_entry(entry, rope, position)
        position = position.clamp(0, rope.bytesize)
        line = rope.point_at(position).row + 1
        line == entry.line ? entry : Entry.new(entry.path, line, entry.condition,
          entry.hit_condition, entry.log_message, entry.enabled)
      end

      def commit(values, changed_path:)
        snapshot = sorted_entries(values)
        persist_now(snapshot)
        @entries = snapshot
        refresh_attachments(changed_path)
        notify_change(changed_path)
      end

      def sorted_entries(values)
        raise Error, "too many breakpoints" if values.length > MAX_ENTRIES
        values.sort_by { |entry| [entry.path, entry.line] }.freeze
      end

      def refresh_attachments(changed_path)
        @attachments.each do |buffer, attachment|
          next unless attachment.fetch(:path) == changed_path
          attachment[:revision] += 1
          store_snapshot(attachment, buffer.rope, entries_for(changed_path))
        end
      end

      def relocate_attachment(attachment, rope, path)
        attachment[:path] = path
        attachment[:revision] += 1
        store_snapshot(attachment, rope, entries_for(path))
      end

      def ensure_attachment_path_available!(buffer, path)
        duplicate = @attachments.any? do |candidate, attachment|
          !candidate.equal?(buffer) && attachment.fetch(:path) == path
        end
        raise Error, "breakpoint path is already attached" if duplicate
      end

      def store_snapshot(attachment, rope, items)
        state = [attachment.fetch(:revision), items].freeze
        states = attachment.fetch(:states)
        snapshots = attachment.fetch(:snapshots)
        existing = snapshots[rope]
        if existing == state
          prune_snapshot_states(attachment)
          return
        end
        if existing
          replacement = ObjectSpace::WeakMap.new
          snapshots.each_pair { |key, value| replacement[key] = value unless key.equal?(rope) }
          attachment[:snapshots] = snapshots = replacement
          states.delete(existing)
        end
        states[state] = true # WeakMap values are also weak on Ruby 3.1.
        snapshots[rope] = state
        prune_snapshot_states(attachment)
      end

      def prune_snapshot_states(attachment)
        count = GC.count
        return if count == attachment.fetch(:gc_count)
        attachment[:gc_count] = count
        snapshots = attachment.fetch(:snapshots)
        states = attachment.fetch(:states)
        live = {}.compare_by_identity
        snapshots.each_value { |value| live[value] = true }
        states.delete_if { |value, _| !live.key?(value) }
      end

      def entries_for(path)
        entries.select { |entry| entry.path == path }.freeze
      end

      def schedule_save(snapshot)
        @save_lock.synchronize do
          @save_generation += 1
          @pending_save = [@save_generation, snapshot]
          @save_wake.broadcast
        end
      end

      def persist_now(snapshot)
        generation = @save_lock.synchronize do
          @save_wake.wait(@save_lock) while @saving || @pending_save
          @save_generation += 1
          @saving = true
          @save_generation
        end
        failure = nil
        begin
          persist(snapshot)
        rescue StandardError => error
          failure = error
        ensure
          finish_save(generation, failure)
        end
        raise failure if failure
      end

      def save_loop
        loop do
          job = next_save
          break unless job
          generation, snapshot = job
          failure = nil
          begin
            persist(snapshot)
          rescue StandardError => error
            failure = error
          ensure
            finish_save(generation, failure)
          end
        end
      end

      def next_save
        @save_lock.synchronize do
          @save_wake.wait(@save_lock) until @save_stopping || @pending_save
          return if @save_stopping && !@pending_save
          deadline = monotonic_time + SAVE_DELAY
          loop do
            remaining = deadline - monotonic_time
            break unless remaining.positive? && !@save_stopping
            pending = @pending_save
            @save_wake.wait(@save_lock, remaining)
            deadline = monotonic_time + SAVE_DELAY unless pending.equal?(@pending_save)
          end
          job = @pending_save
          @pending_save = nil
          @saving = true
          job
        end
      end

      def finish_save(generation, failure)
        @save_lock.synchronize do
          @saving = false
          if failure
            @save_error = [generation, failure]
          else
            @saved_generation = generation
            @save_error = nil
          end
          @save_wake.broadcast
        end
      end

      def stop_save_worker
        @save_lock.synchronize do
          @save_stopping = true
          @save_wake.broadcast
        end
        @save_worker.join
      end

      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def build_entry(path, line, condition, hit_condition = nil, log_message = nil, enabled = true)
        path = normalize_path(path)
        line = validate_line(line)
        unless condition.nil? || valid_text?(condition, MAX_CONDITION_BYTES)
          raise Error, "invalid breakpoint condition"
        end
        unless hit_condition.nil? || valid_text?(hit_condition, MAX_HIT_CONDITION_BYTES)
          raise Error, "invalid breakpoint hit condition"
        end
        unless log_message.nil? || valid_text?(log_message, MAX_LOG_MESSAGE_BYTES)
          raise Error, "invalid breakpoint log message"
        end
        raise Error, "invalid breakpoint enabled state" unless enabled == true || enabled == false
        Entry.new(path.dup.freeze, line, condition&.dup&.freeze,
          hit_condition&.dup&.freeze, log_message&.dup&.freeze, enabled)
      end

      def validate_line(line)
        raise Error, "invalid breakpoint line" unless line.is_a?(Integer) && line.between?(1, MAX_LINE)
        line
      end

      def valid_text?(value, maximum)
        value.is_a?(String) && value.valid_encoding? &&
          (value.encoding == Encoding::UTF_8 || value.ascii_only?) &&
          value.bytesize.between?(1, maximum) && !value.match?(/[\x00-\x1f\x7f]/)
      end

      def normalize_path(value)
        raise Error, "invalid breakpoint path" unless valid_text?(value, MAX_PATH_BYTES)
        path = File.expand_path(value, root)
        if File.exist?(path)
          path = File.realpath(path)
        else
          ancestor, suffix = path, []
          until File.exist?(ancestor) || File.symlink?(ancestor) || File.dirname(ancestor) == ancestor
            suffix.unshift(File.basename(ancestor))
            ancestor = File.dirname(ancestor)
          end
          path = File.join(File.realpath(ancestor), *suffix)
        end
        prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
        raise Error, "breakpoint path is outside the workspace" unless path.start_with?(prefix)
        raise Error, "breakpoint path must not be a directory" if File.directory?(path)
        relative = path.delete_prefix(prefix)
        relative = relative.tr(File::ALT_SEPARATOR, "/") if File::ALT_SEPARATOR
        raise Error, "breakpoint path is too long" if relative.bytesize > MAX_PATH_BYTES
        relative.freeze
      rescue SystemCallError, ArgumentError => error
        raise Error, "invalid breakpoint path: #{error.message}"
      end

      def canonical_root(value)
        path = File.realpath(value)
        raise Error, "breakpoint root must be a directory" unless File.directory?(path)
        path.freeze
      rescue SystemCallError, TypeError => error
        raise Error, "invalid breakpoint root: #{error.message}"
      end

      def load_entries
        _, path = storage_paths
        return [].freeze unless File.exist?(path)
        raise Error, "breakpoint file must be a regular file" unless File.file?(path)
        raise Error, "breakpoint file exceeds 1 MiB" if File.size(path) > MAX_BYTES
        source = File.binread(path, MAX_BYTES + 1).force_encoding(Encoding::UTF_8)
        raise Error, "invalid breakpoint file" unless source.valid_encoding? && source.bytesize <= MAX_BYTES
        document = JSON.parse(source)
        validate_document(document)
      rescue JSON::ParserError, JSON::NestingError
        raise Error, "invalid breakpoint file"
      rescue SystemCallError => error
        raise Error, "cannot read breakpoint file: #{error.message}"
      end

      def validate_document(document)
        unless document.is_a?(Hash) && document.keys.sort == %w[breakpoints version] && [1, VERSION].include?(document["version"])
          raise Error, "unsupported breakpoint file"
        end
        version = document["version"]
        values = document["breakpoints"]
        raise Error, "invalid breakpoint list" unless values.is_a?(Array) && values.length <= MAX_ENTRIES
        loaded = values.map do |value|
          keys = version == 1 ? %w[condition line path] : %w[condition enabled hit_condition line log_message path]
          unless value.is_a?(Hash) && value.keys.sort == keys
            raise Error, "invalid breakpoint entry"
          end
          build_entry(value["path"], value["line"], value["condition"],
            value["hit_condition"], value["log_message"], version == 1 ? true : value["enabled"])
        end
        keys = loaded.map { |entry| [entry.path, entry.line] }
        raise Error, "duplicate breakpoint" unless keys.uniq.length == keys.length
        loaded.sort_by { |entry| [entry.path, entry.line] }.freeze
      end

      def persist(snapshot)
        directory, path = storage_paths(create: true)
        payload = JSON.generate("version" => VERSION, "breakpoints" => snapshot.map do |entry|
          {"path" => entry.path, "line" => entry.line, "condition" => entry.condition,
           "hit_condition" => entry.hit_condition, "log_message" => entry.log_message, "enabled" => entry.enabled}
        end)
        raise Error, "breakpoint file exceeds 1 MiB" if payload.bytesize > MAX_BYTES
        Tempfile.create([".breakpoints-", ".json"], directory, mode: File::RDWR, perm: 0o600) do |file|
          file.write(payload)
          file.flush
          file.fsync
          file.close
          File.rename(file.path, path)
        end
      rescue JSON::GeneratorError, SystemCallError => error
        raise Error, "cannot save breakpoints: #{error.message}"
      end

      def storage_paths(create: false)
        directory = File.join(root, ".canopus")
        raise Error, "breakpoint directory must not be a symlink" if File.symlink?(directory)
        FileUtils.mkdir_p(directory) if create && !File.exist?(directory)
        if File.exist?(directory) && (!File.directory?(directory) || File.realpath(directory) != directory)
          raise Error, "invalid breakpoint directory"
        end
        path = File.join(directory, "breakpoints.json")
        raise Error, "breakpoint file must not be a symlink" if File.symlink?(path)
        [directory, path]
      end

      def ensure_open!
        raise Error, "breakpoint registry is closed" if @closed
      end

      def notify_change(path) = @on_change&.call(path)
    end
  end
end

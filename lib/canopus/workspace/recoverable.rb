# frozen_string_literal: true

require "securerandom"

module Canopus
  module Workspace::Recoverable
    MAX_DRAFT_BYTES = 10 << 20
    MAX_SNAPSHOT_BYTES = 64 << 20
    SNAPSHOT_OVERHEAD_BYTES = 4 << 20
    JSON_ESCAPE_FACTOR = 6

    def recovery_directory = File.join(@root, ".canopus", "recovery")

    def recovery_candidates
      return [] unless @settings["recovery"]["enabled"] && recovery_directory_safe?
      ignored = @ignored_recovery_candidates || []
      Dir.glob(File.join(recovery_directory, "*.json")).reject do |path|
        path == @recovery_path || ignored.include?(path) || recovery_candidate_locked?(path) || !valid_recovery_candidate?(path)
      end.sort_by { |path| -File.mtime(path).to_f }
    rescue SystemCallError
      []
    end

    def offer_recovery
      return false if @palette || !(candidate = recovery_candidates.first)
      time = File.mtime(candidate).getlocal.strftime("%Y-%m-%d %H:%M:%S")
      self.palette = {kind: :recovery, query: "Recover unsaved changes from #{time}?", index: 0,
        matches: ["Restore", "Discard"], candidate: candidate}
      true
    rescue SystemCallError
      false
    end

    def resolve_recovery(choice)
      prompt = @palette
      return false unless prompt&.dig(:kind) == :recovery
      candidate = prompt.fetch(:candidate)
      self.palette = nil
      unless !recovery_candidate_locked?(candidate) && valid_recovery_candidate?(candidate)
        raise Error, "recovery snapshot is no longer safe to read"
      end
      if choice == :restore
        open_paths = @panes.flat_map { |pane| pane.editors.filter_map { |current| current.buffer.path } }.uniq
        restore_session(candidate)
        open_paths.each { |path| open(path) }
        discard_recovery(candidate) if !@settings["recovery"]["enabled"] || poll_recovery(force: true)
        self.message = "Recovered unsaved changes"
      else
        raise Error, "recovery snapshot is no longer safe to discard" unless discard_recovery(candidate)
        self.message = "Discarded recovered changes"
      end
      true
    rescue StandardError => error
      (@ignored_recovery_candidates ||= []) << candidate if candidate
      notify("Recovery ignored: #{error.message}")
      false
    end

    def poll_recovery(now: Process.clock_gettime(Process::CLOCK_MONOTONIC), force: false)
      recovery = @settings["recovery"]
      return false if @closed
      interval = recovery["interval"] / 1000.0
      return false if !force && @last_recovery_poll && now - @last_recovery_poll < interval
      @last_recovery_poll = now
      (@recovery_mutex ||= Mutex.new).synchronize do
        dirty = recovery_buffers.select(&:dirty?)
        eligible = dirty.reject { |buffer| buffer.rope.bytesize > MAX_DRAFT_BYTES }
        state = [recovery["enabled"], *dirty.map { |buffer| [buffer.object_id, buffer.version, buffer.path] }]
        return false if !force && state == @recovery_state
        if !recovery["enabled"] || eligible.empty?
          remove_recovery_snapshot
          notify("Crash recovery skipped #{dirty.length} buffer(s) larger than 10 MiB") if recovery["enabled"] && !dirty.empty?
          @recovery_state = state
          return false
        end
        if recovery_snapshot_too_large?(eligible)
          remove_recovery_snapshot
          notify("Crash recovery drafts exceeded the 64 MiB snapshot budget and were not retained")
          @recovery_state = state
          return false
        end
        ensure_recovery_storage
        save_session(@recovery_path, max_draft_bytes: MAX_DRAFT_BYTES)
        if File.size(@recovery_path) > MAX_SNAPSHOT_BYTES
          remove_recovery_snapshot
          notify("Crash recovery snapshot exceeded 64 MiB and was not retained")
          @recovery_state = state
          return false
        end
        notify("Crash recovery skipped #{dirty.length - eligible.length} buffer(s) larger than 10 MiB") if dirty.length != eligible.length
        @recovery_state = state
        true
      end
    rescue StandardError => error
      notify("Crash recovery failed: #{error.message}")
      false
    end

    def close_recovery(clean: true)
      (@recovery_mutex ||= Mutex.new).synchronize do
        remove_recovery_snapshot if clean
        @recovery_lock&.close
        @recovery_lock = nil
        remove_recovery_lock if clean
      end
    end

    def preserve_recovery! = @preserve_recovery = true

    private

    def recovery_buffers
      @buffers.values.flat_map { |buffer| buffer.is_a?(MultiBuffer) ? buffer.excerpts.map(&:buffer) : buffer }.uniq
    end

    def ensure_recovery_storage
      parent = File.dirname(recovery_directory)
      raise Error, "recovery path is a symbolic link" if File.symlink?(parent) || File.symlink?(recovery_directory)
      FileUtils.mkdir_p(parent)
      begin
        Dir.mkdir(recovery_directory, 0o700) unless File.directory?(recovery_directory)
      rescue Errno::EEXIST
        raise unless File.directory?(recovery_directory)
      end
      File.chmod(0o700, recovery_directory)
      ignore = File.join(recovery_directory, ".gitignore")
      begin
        File.open(ignore, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("*\n") }
      rescue Errno::EEXIST
        nil
      end
      initialize_recovery_lock
    end

    def initialize_recovery_lock
      token = @recovery_token ||= "#{Process.pid}-#{SecureRandom.hex(12)}"
      @recovery_path ||= File.join(recovery_directory, "#{token}.json")
      @recovery_lock_path ||= File.join(recovery_directory, "#{token}.lock")
      return if @recovery_lock
      raise Error, "recovery lock is a symbolic link" if File.symlink?(@recovery_lock_path)
      flags = File::RDWR | File::CREAT
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      @recovery_lock = File.open(@recovery_lock_path, flags, 0o600)
      raise Error, "recovery lock is already held" unless @recovery_lock.flock(File::LOCK_EX | File::LOCK_NB)
    end

    def valid_recovery_candidate?(path)
      return false unless recovery_path_safe?(path) && File.file?(path) && File.size(path) <= MAX_SNAPSHOT_BYTES
      data = JSON.parse(File.binread(path))
      buffers = data["buffers"]
      [1, 2].include?(data["version"]) && data["root"] == @root && buffers.is_a?(Hash) &&
        buffers.length <= 10_000 && buffers.any? { |_, value| value.is_a?(Hash) && value["draft"].is_a?(String) }
    rescue JSON::ParserError, JSON::NestingError, SystemCallError
      false
    end

    def recovery_candidate_locked?(path)
      return true unless recovery_path_safe?(path)
      lock_path = path.sub(/\.json\z/, ".lock")
      return true if File.symlink?(lock_path)
      return false unless File.file?(lock_path)
      File.open(lock_path, File::RDWR) do |lock|
        acquired = lock.flock(File::LOCK_EX | File::LOCK_NB)
        lock.flock(File::LOCK_UN) if acquired
        !acquired
      end
    rescue Errno::EACCES, Errno::EAGAIN
      true
    rescue SystemCallError
      false
    end

    def discard_recovery(path)
      return false unless recovery_path_safe?(path) && !recovery_candidate_locked?(path)
      lock_path = path.sub(/\.json\z/, ".lock")
      return false if File.symlink?(lock_path)
      File.delete(path) if File.file?(path)
      File.delete(lock_path) if File.file?(lock_path)
      true
    end

    def recovery_snapshot_too_large?(buffers)
      SNAPSHOT_OVERHEAD_BYTES + buffers.sum { |buffer| buffer.rope.bytesize * JSON_ESCAPE_FACTOR } > MAX_SNAPSHOT_BYTES
    end

    def remove_recovery_snapshot
      File.delete(@recovery_path) if @recovery_path && recovery_path_safe?(@recovery_path) && File.file?(@recovery_path)
    end

    def remove_recovery_lock
      return unless @recovery_lock_path && recovery_directory_safe? && File.dirname(@recovery_lock_path) == recovery_directory
      File.delete(@recovery_lock_path) if !File.symlink?(@recovery_lock_path) && File.file?(@recovery_lock_path)
    end

    def recovery_path_safe?(path)
      recovery_directory_safe? && File.dirname(File.expand_path(path)) == recovery_directory && !File.symlink?(path)
    end

    def recovery_directory_safe?
      parent = File.dirname(recovery_directory)
      !File.symlink?(parent) && !File.symlink?(recovery_directory) && File.directory?(recovery_directory)
    end
  end
end

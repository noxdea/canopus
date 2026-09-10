# frozen_string_literal: true

module Canopus
  module Workspace::FileChangeAware
    def start_watching
      return if @watcher || !@project
      native = begin
        Zaniah::Platform.watch(@root)
      rescue LoadError, Zaniah::Error, SystemCallError
        nil
      end
      @watcher = @project.watcher(native: native)
      @last_watch = 0
    end
    def poll_changes
      return unless @watcher
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if now - @last_watch < (@watcher.backend == :native ? 0.05 : 1.0)
      @last_watch = now
      events = @watcher.poll
      invalidate_git unless events.empty?
      refresh_files unless events.empty?
      events.each do |event|
        path = File.expand_path(event.path, @root)
        buffer = @buffers[path]
        next unless buffer
        if event.type == :deleted
          @message = "File was deleted on disk: #{event.path}"
        elsif buffer.dirty?
          @message = "File changed on disk; unsaved edits preserved: #{event.path}"
        else
          buffer.reload
        end
      rescue SaveConflict, SystemCallError, Error => error
        @message = error.message
      end
      @window&.request_frame unless events.empty?
    end
  end
end

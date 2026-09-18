# frozen_string_literal: true

module Canopus
  module Workspace::AutoSavable
    def poll_auto_save(now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      return false if @closed
      mode = @settings["auto_save"]
      delay = @settings["auto_save_delay"]
      current = editor&.buffer
      config = [mode, delay]
      if @auto_save_config != config
        reset_auto_save
        @auto_save_config = config
        @auto_save_focus_buffer = current
        return false unless mode == "after_delay"
      end

      case mode
      when "on_focus_change"
        previous, @auto_save_focus_buffer = @auto_save_focus_buffer, current
        return false unless previous && !previous.equal?(current)
        saved = false
        auto_save_sources(previous).each { |buffer| saved = auto_save_buffer(buffer) || saved }
        saved
      when "after_delay"
        buffers = auto_save_buffers
        @auto_save_pending ||= {}.compare_by_identity
        @auto_save_pending.delete_if { |buffer, _| !buffers.include?(buffer) }
        attempted = false
        buffers.each do |buffer|
          unless auto_save_eligible?(buffer)
            @auto_save_pending.delete(buffer)
            next
          end
          version = buffer.version
          state = @auto_save_pending[buffer]
          if !state || state[0] != version
            @auto_save_pending[buffer] = [version, now + delay / 1_000.0, false]
            next
          end
          next if state[2] || now < state[1]
          state[2] = true
          attempted = auto_save_buffer(buffer) || attempted
        end
        attempted
      else
        reset_auto_save
        @auto_save_config = config
        @auto_save_focus_buffer = current
        false
      end
    end

    def reset_auto_save
      @auto_save_pending&.clear
      @auto_save_focus_buffer = nil
      nil
    end

    private

    def auto_save_buffers
      @buffers.values.flat_map { |buffer| auto_save_sources(buffer) }.uniq
    end

    def auto_save_sources(buffer)
      buffer.is_a?(MultiBuffer) ? buffer.excerpts.map(&:buffer).uniq : [buffer]
    end

    def auto_save_eligible?(buffer)
      buffer.path && !buffer.read_only && buffer.dirty?
    end

    def auto_save_buffer(buffer)
      return false unless auto_save_eligible?(buffer)
      save_buffer(buffer)
      true
    rescue StandardError => error
      notify("Auto-save failed: #{error.message}")
      false
    end
  end
end

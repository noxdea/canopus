# frozen_string_literal: true

module Canopus
  class Pane
    attr_reader :editors, :pinned
    attr_accessor :active_index
    def initialize
      @editors, @pinned, @active_index, @past, @future = [], [], 0, [], []
    end
    def active = @editors[@active_index]
    def open(buffer)
      existing = @editors.index { |editor| editor.buffer.equal?(buffer) }
      if existing
        activate(existing)
      else
        @editors << Editor.new(buffer)
        activate(@editors.length - 1)
      end
      active
    end
    def activate(index)
      raise IndexError, "tab outside pane" unless index.is_a?(Integer) && index.between?(0, @editors.length - 1)
      @past << active if active && @active_index != index
      @active_index = index
      @future.clear
    end
    def pin(editor = active)
      @pinned << editor unless @pinned.include?(editor)
    end
    def close(editor = active, discard: false)
      raise Error, "buffer has unsaved changes" if editor.buffer.dirty? && !discard
      @pinned.delete(editor)
      @editors.delete(editor)
      @past.delete(editor)
      @future.delete(editor)
      @active_index = [@active_index, @editors.length - 1].min.clamp(0, @editors.length)
      editor.dispose
    end
    def detach(editor)
      raise Error, "tab is not in pane" unless @editors.include?(editor)
      active = self.active
      @pinned.delete(editor)
      @editors.delete(editor)
      @past.delete(editor)
      @future.delete(editor)
      @active_index = @editors.index(active) || [@active_index, @editors.length - 1].min.clamp(0, @editors.length)
    end
    def back
      previous = @past.pop
      return unless previous && @editors.include?(previous)
      @future << active
      @active_index = @editors.index(previous)
    end
    def forward
      following = @future.pop
      return unless following && @editors.include?(following)
      @past << active
      @active_index = @editors.index(following)
    end
  end
end

# frozen_string_literal: true

module Canopus
  class Patch
    Edit = Data.define(:old_range, :new_range, :old_text, :new_text)
    attr_reader :edits, :before, :after
    def initialize(before, after, changes)
      @before, @after = before, after
      delta = 0
      @edits = changes.sort_by { |range, _| range.begin }.map do |range, text|
        ending = range.end + (range.exclude_end? ? 0 : 1)
        old = range.begin...ending
        start = range.begin + delta
        delta += text.bytesize - (ending - range.begin)
        Edit.new(old, start...(start + text.bytesize), before.byteslice(old).to_s.freeze, text.dup.freeze)
      end.freeze
    end
    def map_offset(offset, bias: :right)
      Denebola::Anchor.new(offset, bias: bias).transform(@edits.map { |e| [e.old_range, e.new_text] }).offset
    end
    def inverse = Patch.new(after, before, edits.map { |e| [e.new_range, e.old_text] })
    def compose(other) = Composite.new([self, other])
  end
end

require_relative "patch/composite"
require_relative "patch/reload"

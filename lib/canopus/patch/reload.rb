# frozen_string_literal: true

class Canopus::Patch::Reload
  attr_reader :before, :after
  def initialize(before, after) = (@before, @after = before, after)
  def edits = []
  def map_offset(offset, bias: :right)
    position = offset.clamp(0, after.bytesize)
    begin
      after.point_at(position)
      position
    rescue RangeError
      position -= 1
      retry if position >= 0
      raise
    end
  end
end

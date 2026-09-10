# frozen_string_literal: true

class Canopus::Patch::Composite
  attr_reader :patches
  def initialize(patches) = @patches = patches.freeze
  def before = patches.first.before
  def after = patches.last.after
  def edits = patches.flat_map(&:edits)
  def map_offset(offset, bias: :right) = patches.reduce(offset) { |position, patch| patch.map_offset(position, bias: bias) }
  def inverse = self.class.new(patches.reverse.map(&:inverse))
  def compose(other) = self.class.new([*patches, other])
end

# frozen_string_literal: true

class Canopus::DisplayMap::Summary < Struct.new(:source_rows, :display_rows, :pending_rows)
  def initialize(source_rows, display_rows, pending_rows)
    super
    freeze
  end
  ZERO = new(0, 0, 0)
  def self.zero = ZERO
  def +(other)
    return other if source_rows.zero?
    return self if other.source_rows.zero?
    Canopus::DisplayMap::Summary.new(source_rows + other.source_rows, display_rows + other.display_rows, pending_rows + other.pending_rows)
  end
  def project_combined(dimension, other)
    case dimension
    when :source_rows then source_rows + other.source_rows
    when :display_rows then display_rows + other.display_rows
    when :pending_rows then pending_rows + other.pending_rows
    else raise ArgumentError, "unknown display summary dimension: #{dimension}"
    end
  end
end

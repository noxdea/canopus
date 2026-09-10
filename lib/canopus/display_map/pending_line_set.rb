# frozen_string_literal: true

class Canopus::DisplayMap::PendingLineSet < Struct.new(:display_rows, :summary)
  def initialize(display_rows)
    super(display_rows, Canopus::DisplayMap::Summary.new(1, display_rows, 1))
    freeze
  end
  def rows = nil
end

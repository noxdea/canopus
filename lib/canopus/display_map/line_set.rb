# frozen_string_literal: true

class Canopus::DisplayMap::LineSet < Struct.new(:rows, :summary)
  def initialize(rows)
    super(rows, Canopus::DisplayMap::Summary.new(1, rows.length, 0))
    freeze
  end
end

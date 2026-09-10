# frozen_string_literal: true

module Canopus
  Selection = Data.define(:id, :anchor, :head, :goal) do
    def start = [anchor, head].min
    def end = [anchor, head].max
    def range = self.start...self.end
    def empty? = anchor == head
    def reversed? = head < anchor
  end
end

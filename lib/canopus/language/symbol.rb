# frozen_string_literal: true

module Canopus
  module Language
    Symbol = Data.define(:name, :kind, :range, :selection, :depth)
    DocumentSymbol = Data.define(:id, :name, :kind, :range, :selection, :depth, :parent_id)
  end
end

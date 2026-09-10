# frozen_string_literal: true

module Canopus
  module Language
    Definition = Data.define(:name, :lexer, :extensions, :comment, :indent_open, :indent_close, :servers)
  end
end

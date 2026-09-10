# frozen_string_literal: true

module Canopus
  module Terminal
    Cell = Struct.new(:text, :width, :foreground, :background, :attributes, :hyperlink, keyword_init: true)
  end
end

# frozen_string_literal: true

require_relative "terminal/cell"
require_relative "terminal/scrollback"
require_relative "terminal/grid"
require_relative "terminal/vt"
require_relative "terminal/pty"

module Canopus
  module Terminal
    # Renderers consume Grid#cells; VT only mutates screen state and emits replies.
  end
end

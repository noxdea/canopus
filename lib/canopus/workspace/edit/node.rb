# frozen_string_literal: true

module Canopus
  module Workspace::Edit
    Node = Struct.new(:origin, :path, :kind, :exists, :buffer, :rope, :version, :edits, :reset, keyword_init: true)
    private_constant :Node
  end
end

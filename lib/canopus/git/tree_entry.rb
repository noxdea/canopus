# frozen_string_literal: true

module Canopus
  module Git
    TreeEntry = Struct.new(:path, :oid, :mode, keyword_init: true)
  end
end

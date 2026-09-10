# frozen_string_literal: true

module Canopus
  module Git
    Commit = Struct.new(:oid, :tree, :parents, :author, :committer, :message, keyword_init: true)
  end
end

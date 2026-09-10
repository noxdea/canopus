# frozen_string_literal: true

module Canopus
  Project = Class.new
end

require_relative "../search_worker"

Canopus::Project.const_get(:SearchWorker, false).run

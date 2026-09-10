# frozen_string_literal: true

module Canopus
  module Plugins; end
end

require_relative "plugins/permission_denied"
require_relative "plugins/api"
require_relative "plugins/local_runtime"
require_relative "plugins/isolated_runtime"
require_relative "plugins/registry"

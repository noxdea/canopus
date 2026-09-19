# frozen_string_literal: true

module Canopus
  module Plugins
    BUFFER_CONTEXT_LIMIT = 1 << 20
    PERMISSIONS = %w[read_buffer edit_buffer read_project write_project exec process network].freeze
    autoload :PermissionDenied, "canopus/plugins/permission_denied"
    autoload :API, "canopus/plugins/api"
    autoload :LocalRuntime, "canopus/plugins/local_runtime"
    autoload :IsolatedRuntime, "canopus/plugins/isolated_runtime"
    autoload :Host, "canopus/plugins/host"
    autoload :Registry, "canopus/plugins/registry"
  end
end

# frozen_string_literal: true

module Canopus
  module Plugins
    class Registry
      PERMISSIONS = %w[read_buffer edit_buffer read_project process network].freeze

      def initialize(workspace)
        @workspace, @loaded = workspace, []
      end

      def load(path, trusted: false, permissions: [], isolated: true, timeout: 2)
        raise PermissionDenied, "plugins execute Ruby code; explicitly mark this plugin trusted" unless trusted
        permissions = permissions.map(&:to_s)
        raise PermissionDenied, "unknown plugin permission" unless (permissions - PERMISSIONS).empty?
        source = File.read(path, 256 * 1024 + 1, encoding: "UTF-8")
        raise Error, "plugin source exceeds 256KB" if source.bytesize > 256 * 1024
        plugin = if isolated
          IsolatedRuntime.new(@workspace, source, path, permissions, timeout: timeout)
        else
          LocalRuntime.new(@workspace, source, path, permissions)
        end
        @loaded << plugin
        plugin
      end

      def close = @loaded.each(&:close)
    end
  end
end

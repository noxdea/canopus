# frozen_string_literal: true

require "open3"

module Canopus
  module Plugins
    class API
      def initialize(workspace, permissions)
        @workspace, @permissions = workspace, permissions
      end
      def permit!(permission)
        raise Canopus::Plugins::PermissionDenied, "plugin requires #{permission}" unless @permissions.include?(permission)
      end
      def text
        permit!("read_buffer")
        @workspace.editor.buffer.text.dup.freeze
      end
      def replace(range, text)
        permit!("edit_buffer")
        @workspace.editor.buffer.edit([[range, text]], kind: :plugin)
      end
      def files
        permit!("read_project")
        @workspace.files.dup.freeze
      end
      def notify(message) = @workspace.message = message.to_s
      def run(command)
        permit!("process")
        raise ArgumentError, "command must be a nonempty argument array" unless command.is_a?(Array) && !command.empty?
        Open3.capture3(*command, chdir: @workspace.root)
      end
      def http_get(url)
        permit!("network")
        require "net/http"
        uri = URI(url)
        raise ArgumentError, "HTTP or HTTPS URL required" unless %w[http https].include?(uri.scheme)
        body = +""
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 5) do |http|
          http.request_get(uri.request_uri) do |response|
            response.read_body do |chunk|
              raise Canopus::Error, "plugin HTTP response exceeds 1 MiB" if body.bytesize + chunk.bytesize > 1 << 20
              body << chunk
            end
          end
        end
        body
      end
    end
  end
end

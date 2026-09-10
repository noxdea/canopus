# frozen_string_literal: true

module Canopus
  module Plugins
    class LocalRuntime
      def initialize(workspace, source, path, permissions)
        @workspace, @api = workspace, Canopus::Plugins::API.new(workspace, permissions)
        instance_eval(source, path, 1)
      end
      def register_action(name, description: name, &block)
        raise ArgumentError, "action callback required" unless block
        @workspace.register_action(name, description: description) { block.call(@api) }
      end
      def register_panel(name, side: :right, &block)
        raise ArgumentError, "panel callback required" unless block
        @workspace.register_panel(name, side: side) { block.call(@api) }
      end
      def register_language(name, **options) = @workspace.register_language(name, **options)
      def configure_lsp(language, command)
        @workspace.settings.merge!("language_servers" => {language => command})
      end
      def close; end
    end
  end
end

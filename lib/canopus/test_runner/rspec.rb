# frozen_string_literal: true

module Canopus
  module TestRunner
    class RSpec
      MAX_NODES = 100_000
      MAX_GROUP_DEPTH = 32
      MAX_NAME_BYTES = 4_096
      GROUPS = %i[describe context feature fdescribe xdescribe fcontext xcontext].freeze
      EXAMPLES = %i[it specify example scenario fit focus fspecify xit xspecify xexample fexample fscenario xscenario skip].freeze

      def candidate?(path)
        TestRunner.framework_for(path) == :rspec
      end

      def discover(root, path:, limit:, cancelled:)
        require "prism"
        path = path.dup.freeze
        tests, visited = [], 0
        stack = [[root, [].freeze]]
        until stack.empty? || tests.length >= limit
          break if cancelled.call
          node, groups = stack.pop
          break if (visited += 1) > MAX_NODES

          if node.is_a?(Prism::DefNode)
            next
          elsif node.is_a?(Prism::CallNode)
            if group_call?(node) && groups.length < MAX_GROUP_DEPTH && (group = argument_name(node))
              stack << [node.block.body, [*groups, group].freeze] if node.block.body
              next
            elsif !groups.empty? && EXAMPLES.include?(node.name) && !node.receiver && (name = argument_name(node))
              add(tests, path, name, groups, node)
              next
            end
            next if node.block
          end
          node.compact_child_nodes.reverse_each { |child| stack << [child, groups] }
        end
        tests.freeze
      end

      private

      def group_call?(node)
        return false unless GROUPS.include?(node.name) && node.block
        return true unless node.receiver

        (node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)) &&
          node.receiver.full_name.delete_prefix("::") == "RSpec"
      end

      def argument_name(node) = name(node.arguments&.arguments&.first)

      def name(node)
        value = case node
        when Prism::StringNode, Prism::SymbolNode then node.unescaped
        when Prism::ConstantReadNode, Prism::ConstantPathNode then node.full_name
        end
        return unless value

        value = value.to_s.encode(Encoding::UTF_8)
        return unless value.valid_encoding? && !value.include?("\0") && value.bytesize <= MAX_NAME_BYTES
        value.freeze
      rescue EncodingError
        nil
      end

      def add(tests, path, name, groups, node)
        tests << Test.new(:rspec, path, name, groups,
          node.location.start_line, node.location.start_column, node.location.start_offset)
      end
    end
  end
end

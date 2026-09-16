# frozen_string_literal: true

module Canopus
  module TestRunner
    class Minitest
      MAX_NODES = 100_000
      MAX_GROUP_DEPTH = 32
      MAX_NAME_BYTES = 4_096
      SPEC_GROUPS = %i[describe context].freeze
      SPEC_TESTS = %i[it specify].freeze

      def candidate?(path)
        TestRunner.framework_for(path) == :minitest
      end

      def discover(root, path:, limit:, cancelled:)
        require "prism"
        path = path.dup.freeze
        tests, visited = [], 0
        stack = [[root, [].freeze, :none]]
        until stack.empty? || tests.length >= limit
          break if cancelled.call
          node, groups, scope = stack.pop
          break if (visited += 1) > MAX_NODES

          case node
          when Prism::ClassNode
            group = name(node.constant_path)
            children = group && groups.length < MAX_GROUP_DEPTH ? [*groups, group].freeze : groups
            stack << [node.body, children, :class] if node.body
          when Prism::ModuleNode
            stack << [node.body, groups, :none] if node.body
          when Prism::SingletonClassNode
            next
          when Prism::DefNode
            method_name = name(node.name.to_s)
            add(tests, path, method_name, groups, node) if scope == :class && !node.receiver && method_name&.start_with?("test_")
          when Prism::CallNode
            if group_call?(node) && groups.length < MAX_GROUP_DEPTH && (group = argument_name(node))
              stack << [node.block.body, [*groups, group].freeze, :spec] if node.block.body
            elsif test_call?(node, scope) && (test_name = argument_name(node))
              add(tests, path, test_name, groups, node)
            else
              push_children(stack, node, groups, scope) unless node.block
            end
          else
            push_children(stack, node, groups, scope)
          end
        end
        tests.freeze
      end

      private

      def group_call?(node) = SPEC_GROUPS.include?(node.name) && node.block && !node.receiver
      def test_call?(node, scope)
        return false unless node.block && !node.receiver

        (scope == :class && node.name == :test) || (scope == :spec && SPEC_TESTS.include?(node.name))
      end

      def push_children(stack, node, groups, scope)
        node.compact_child_nodes.reverse_each { |child| stack << [child, groups, scope] }
      end

      def argument_name(node) = name(node.arguments&.arguments&.first)

      def name(node)
        value = case node
        when String then node
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
        tests << Test.new(:minitest, path, name, groups,
          node.location.start_line, node.location.start_column, node.location.start_offset)
      end
    end
  end
end

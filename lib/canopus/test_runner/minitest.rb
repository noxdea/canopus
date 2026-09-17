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
        stack = [[root, [].freeze, :none, nil]]
        until stack.empty? || tests.length >= limit
          break if cancelled.call
          node, groups, scope, spec_count = stack.pop
          break if (visited += 1) > MAX_NODES

          case node
          when Prism::ClassNode
            group = name(node.constant_path, rootless: true)
            children = group && groups.length < MAX_GROUP_DEPTH ? [*groups, group].freeze : groups
            class_scope = spec_class?(node) ? :spec_class : :class
            stack << [node.body, children, class_scope, class_scope == :spec_class ? [0] : nil] if node.body
          when Prism::ModuleNode
            group = name(node.constant_path, rootless: true)
            children = group && groups.length < MAX_GROUP_DEPTH ? [*groups, group].freeze : groups
            stack << [node.body, children, :none, nil] if node.body
          when Prism::SingletonClassNode
            next
          when Prism::DefNode
            method_name = name(node.name.to_s)
            if [:class, :spec_class].include?(scope) && !node.receiver && method_name&.start_with?("test_")
              add(tests, path, method_name, groups, node, method_name)
            end
          when Prism::CallNode
            if group_call?(node) && groups.length < MAX_GROUP_DEPTH && (group = group_name(node))
              parent = [:spec, :spec_class].include?(scope) ? groups : []
              stack << [node.block.body, [*parent, group].freeze, :spec, [0]] if node.block.body
            elsif spec_test_call?(node, scope)
              selector = format("test_%04d_%s", spec_count[0] += 1, (test_name = literal_argument_name(node)))
              add(tests, path, test_name, groups, node, selector) if test_name
            elsif class_test_call?(node, scope) && (test_name = literal_argument_name(node))
              add(tests, path, test_name, groups, node, "test_#{test_name.gsub(/\s+/, "_")}")
            else
              push_children(stack, node, groups, scope, spec_count) unless node.block
            end
          else
            push_children(stack, node, groups, scope, spec_count)
          end
        end
        tests.freeze
      end

      private

      def group_call?(node) = SPEC_GROUPS.include?(node.name) && node.block && !node.receiver
      def spec_test_call?(node, scope)
        [:spec, :spec_class].include?(scope) && SPEC_TESTS.include?(node.name) && !node.receiver
      end
      def class_test_call?(node, scope)
        [:class, :spec_class].include?(scope) && node.name == :test && node.block && !node.receiver
      end

      def spec_class?(node)
        superclass = name(node.superclass)
        superclass&.delete_prefix("::") == "Minitest::Spec"
      end

      def push_children(stack, node, groups, scope, spec_count)
        node.compact_child_nodes.reverse_each { |child| stack << [child, groups, scope, spec_count] }
      end

      def literal_argument_name(node)
        argument = node.arguments&.arguments&.first
        name(argument) if argument.is_a?(Prism::StringNode) || argument.is_a?(Prism::SymbolNode)
      end

      def group_name(node)
        arguments = node.arguments&.arguments
        return if !arguments || arguments.empty?

        parts = arguments.map { |argument| name(argument, rootless: true) }
        parts.join("::").freeze if parts.all?
      end

      def name(node, rootless: false)
        value = case node
        when String then node
        when Prism::StringNode, Prism::SymbolNode then node.unescaped
        when Prism::ConstantReadNode, Prism::ConstantPathNode then node.full_name
        end
        return unless value

        value = value.to_s.encode(Encoding::UTF_8)
        value = value.delete_prefix("::") if rootless
        return unless value.valid_encoding? && !value.include?("\0") && value.bytesize <= MAX_NAME_BYTES
        value.freeze
      rescue EncodingError
        nil
      end

      def add(tests, path, name, groups, node, selector)
        tests << Test.new(:minitest, path, name, groups,
          node.location.start_line, node.location.start_column, node.location.start_offset, selector.freeze)
      end
    end
  end
end

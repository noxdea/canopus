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
        stack = [[root, [].freeze, "".freeze, false]]
        until stack.empty? || tests.length >= limit
          break if cancelled.call
          node, groups, full_description, parent_module = stack.pop
          break if (visited += 1) > MAX_NODES

          if node.is_a?(Prism::DefNode)
            next
          elsif node.is_a?(Prism::CallNode)
            if group_call?(node) && groups.length < MAX_GROUP_DEPTH && (details = group_name(node))
              group, last_module = details
              separator = !full_description.empty? && !(parent_module && group.match?(/\A(?:#|::|\.)/)) ? " " : ""
              nested_description = "#{full_description}#{separator}#{group}".freeze
              stack << [node.block.body, [*groups, group].freeze, nested_description, last_module] if node.block.body
              next
            elsif !groups.empty? && EXAMPLES.include?(node.name) && !node.receiver && (name = literal_name(node.arguments&.arguments&.first))
              add(tests, path, name, groups, full_description, node)
              next
            end
            next if node.block
          end
          node.compact_child_nodes.reverse_each do |child|
            stack << [child, groups, full_description, parent_module]
          end
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

      def group_name(node)
        arguments = node.arguments&.arguments&.dup
        return if !arguments || arguments.empty?

        arguments.pop if arguments.last.is_a?(Prism::KeywordHashNode) || arguments.last.is_a?(Prism::HashNode)
        arguments.pop while arguments.length > 1 && arguments.last.is_a?(Prism::SymbolNode)
        return unless arguments.length.between?(1, 2)

        first = name(arguments.first, rootless: true)
        second = name(arguments[1], rootless: true) if arguments.length == 2
        return unless first && !first.empty? && (arguments.length == 1 || second && !second.empty?)
        return [first, constant?(arguments.first)].freeze if arguments.length == 1

        separator = constant?(arguments.first) && second.match?(/\A(?:#|::|\.)/) ? "" : " "
        ["#{first}#{separator}#{second}".freeze, constant?(arguments.last)].freeze
      end

      def literal_name(node)
        name(node) if node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)
      end

      def constant?(node) = node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      def name(node, rootless: false)
        value = case node
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

      def add(tests, path, name, groups, full_description, node)
        selector = "#{full_description} #{name}".freeze
        tests << Test.new(:rspec, path, name, groups,
          node.location.start_line, node.location.start_column, node.location.start_offset, selector)
      end
    end
  end
end

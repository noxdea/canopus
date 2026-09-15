# frozen_string_literal: true

module Canopus
  module Command
    Definition = Data.define(:id, :title, :category, :when, :run, :keybinding)

    DEFAULT_KEYBINDINGS = {
      "file.save" => {"cmd-s" => "", "ctrl-s" => ""}.freeze,
      "file.new" => {"cmd-n" => "", "ctrl-n" => ""}.freeze,
      "tab.close" => {"cmd-w" => "", "ctrl-w" => ""}.freeze,
      "tab.close_all" => {"cmd-alt-w" => "", "ctrl-alt-w" => ""}.freeze,
      "tab.reopen_closed" => {"cmd-shift-t" => "", "ctrl-shift-t" => ""}.freeze,
      "file.find" => {"cmd-p" => "", "ctrl-p" => ""}.freeze,
      "command.palette" => {"cmd-shift-p" => "", "ctrl-shift-p" => ""}.freeze,
      "edit.undo" => {"cmd-z" => "", "ctrl-z" => ""}.freeze,
      "edit.redo" => {"cmd-shift-z" => "", "ctrl-shift-z" => ""}.freeze,
      "edit.select_all" => {"cmd-a" => "", "ctrl-a" => ""}.freeze,
      "edit.select_next" => {"cmd-d" => "", "ctrl-d" => ""}.freeze,
      "search.buffer" => {"cmd-f" => "", "ctrl-f" => ""}.freeze,
      "edit.select_all_occurrences" => {"cmd-shift-l" => "", "ctrl-shift-l" => ""}.freeze,
      "edit.move_line_up" => {"alt-shift-up" => ""}.freeze,
      "edit.move_line_down" => {"alt-shift-down" => ""}.freeze,
      "language.expand_selection" => {"alt-up" => ""}.freeze,
      "language.shrink_selection" => {"alt-down" => ""}.freeze,
      "search.project" => {"cmd-shift-f" => "", "ctrl-shift-f" => ""}.freeze,
      "search.replace" => {"cmd-alt-f" => "", "ctrl-h" => ""}.freeze,
      "edit.toggle_comment" => {"cmd-/" => "", "ctrl-/" => ""}.freeze,
      "view.project" => {"cmd-b" => "", "ctrl-b" => ""}.freeze,
      "view.terminal" => {"ctrl-`" => ""}.freeze,
      "pane.split_right" => {"cmd-\\" => "", "ctrl-\\" => ""}.freeze,
      "language.completion" => {"ctrl-space" => ""}.freeze,
      "language.definition" => {"f12" => ""}.freeze,
      "language.references" => {"shift-f12" => ""}.freeze,
      "language.rename" => {"f2" => ""}.freeze,
      "language.codeAction" => {"alt-enter" => ""}.freeze,
      "language.outline" => {"cmd-shift-o" => "", "ctrl-shift-o" => ""}.freeze,
      "language.hover" => {"cmd-k" => "", "ctrl-k" => ""}.freeze,
      "terminal.toggle" => {"ctrl-`" => "Terminal"}.freeze,
      "terminal.new" => {"ctrl-shift-`" => ""}.freeze,
      "terminal.close" => {"cmd-w" => "Terminal", "ctrl-w" => "Terminal"}.freeze,
      "terminal.copy" => {"cmd-c" => "Terminal", "ctrl-shift-c" => "Terminal"}.freeze,
      "terminal.paste" => {"cmd-v" => "Terminal", "ctrl-shift-v" => "Terminal"}.freeze,
      "terminal.next" => {"ctrl-shift-]" => "Terminal"}.freeze,
      "terminal.prev" => {"ctrl-shift-[" => "Terminal"}.freeze,
      "terminal.clear" => {"cmd-k" => "Terminal"}.freeze,
      **(1..9).to_h { |index| ["terminal.select_#{index}", {"cmd-#{index}" => "Terminal"}.freeze] }
    }.freeze

    class Registry
      attr_reader :version

      def initialize
        @definitions, @predicates, @version = {}, {}, 0
      end

      def register(definition, description: definition.to_s, category: definition.to_s.split(".", 2).first,
        condition: "", keybinding: nil, &run)
        definition = Definition.new(definition.to_s, description, category, condition, run, keybinding) unless definition.is_a?(Definition)
        definition = normalize(definition)
        predicate = Zaniah::Input::ContextPredicate.new(definition.when)
        @definitions[definition.id] = definition
        @predicates[definition.id] = predicate
        @version += 1
        definition
      end

      def resolve(id, context: {})
        id = id.to_s
        definition = @definitions[id]
        definition if definition && @predicates.fetch(id).call(context)
      end

      def call(id, *arguments, context: {})
        definition = resolve(id, context: context)
        raise KeyError, "command unavailable: #{id}" unless definition
        definition.run.call(*arguments)
      end

      def each(context: nil)
        return enum_for(__method__, context: context) unless block_given?
        @definitions.each_value { |definition| yield definition if context.nil? || resolve(definition.id, context: context) }
        self
      end

      def entries(context: nil) = each(context: context).to_h { |definition| [definition.id, definition.title] }.freeze

      private

      def normalize(definition)
        raise ArgumentError, "command definition required" unless definition.is_a?(Definition)
        id, title, category, condition, run, keybinding = definition.deconstruct
        raise ArgumentError, "command id must not be empty" unless id.is_a?(String) && !id.empty?
        raise ArgumentError, "command title must be a string" unless title.is_a?(String)
        raise ArgumentError, "command category must be a string" unless category.is_a?(String)
        raise ArgumentError, "command condition must be a string" unless condition.is_a?(String)
        raise ArgumentError, "command runner must be callable" unless run.respond_to?(:call)
        keybinding = normalize_keybinding(keybinding)
        Definition.new(id.dup.freeze, title.dup.freeze, category.dup.freeze, condition.dup.freeze, run, keybinding)
      end

      def normalize_keybinding(keybinding)
        return if keybinding.nil?
        return keybinding.dup.freeze if keybinding.is_a?(String) && !keybinding.empty?
        unless keybinding.is_a?(Hash) && keybinding.all? { |keys, condition| keys.is_a?(String) && !keys.empty? && condition.is_a?(String) }
          raise ArgumentError, "command keybinding must be a string, binding map, or nil"
        end
        keybinding.to_h { |keys, condition| [keys.dup.freeze, condition.dup.freeze] }.freeze
      end
    end
  end
end

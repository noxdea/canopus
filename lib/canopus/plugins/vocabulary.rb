# frozen_string_literal: true

module Canopus
  module Plugins
    module Vocabulary
      module_function

      def build
        Zaniah::Describe::Vocabulary.build do
          node :column, props: {gap: :integer}, children: :many do |props, children|
            Zaniah::Div.new.flex_col.style(gap: props.fetch(:gap, 0)).children(children)
          end
          node :row, props: {gap: :integer}, children: :many do |props, children|
            Zaniah::Div.new.flex_row.style(gap: props.fetch(:gap, 0)).children(children)
          end
          node :text, props: {value: :string}, children: :none do |props|
            Zaniah::Text.new(props.fetch(:value))
          end
          node :button, props: {label: :string, on_click: :handler}, children: :none do |props|
            Zaniah::UI::Button.new(props.fetch(:label)).on_click { |event, _context| props.fetch(:on_click).call(event) }
          end
          node :list, props: {items: :array}, children: :none do |props|
            Zaniah::Div.new.flex_col.children(Array(props.fetch(:items)).map { |item| Zaniah::Text.new(String(item)) })
          end
        end
      end
    end
  end
end

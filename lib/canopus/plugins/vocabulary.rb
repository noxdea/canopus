# frozen_string_literal: true

module Canopus
  module Plugins
    module Vocabulary
      module_function

      def build
        require "zaniah/ui"
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
          node :spacer, props: {size: :number}, children: :none do |props|
            Zaniah::UI::Spacer.new(props[:size])
          end
          node :scroll, props: {axis: %i[vertical horizontal both]}, children: :one do |props, children|
            axis = props.fetch(:axis, :vertical)
            Zaniah::ScrollView.new(axis: axis == :both ? :both : axis).child(children.first)
          end
          node :divider, props: {axis: %i[horizontal vertical]}, children: :none do |props|
            Zaniah::UI::Divider.new(axis: props.fetch(:axis, :horizontal))
          end
          node :icon, props: {name: %i[check close search menu info warning], label: :string}, children: :none do |props|
            Zaniah::UI::Icon.new(props.fetch(:name), label: props[:label])
          end
          node :badge, props: {value: :string, variant: %i[neutral accent success warning danger]}, children: :none do |props|
            Zaniah::UI::Badge.new(props.fetch(:value), variant: props.fetch(:variant, :neutral))
          end
          node :progress, props: {value: :number, min: :number, max: :number, label: :string}, children: :none do |props|
            Zaniah::UI::ProgressBar.new(value: props[:value], min: props.fetch(:min, 0), max: props.fetch(:max, 100), label: props[:label])
          end
          node :code, props: {value: :string}, children: :none do |props|
            Zaniah::Text.new(props.fetch(:value)).style(font_family: :monospace)
          end
          node :checkbox, props: {label: :string, value: :boolean, on_change: :handler}, children: :none do |props|
            Zaniah::UI::Checkbox.new(props.fetch(:label), value: props.fetch(:value, false))
              .on_change { |value, _event, _context| props.fetch(:on_change).call(value) }
          end
          node :text_field, props: {value: :string, placeholder: :string, on_change: :handler}, children: :none do |props|
            Zaniah::UI::TextField.new(props.fetch(:value, ""), placeholder: props[:placeholder])
              .on_change { |value, _context| props.fetch(:on_change).call(value) }
          end
          node :select, props: {items: :array, value: :any, label: :string, on_change: :handler}, children: :none do |props|
            Zaniah::UI::Select.new(props.fetch(:items), value: props[:value], label: props.fetch(:label, "Select"))
              .on_change { |value, _event, _context| props.fetch(:on_change).call(value) }
          end
          node :tree, props: {items: :array}, children: :none do |props|
            Zaniah::UI::TreeView.new(Array(props.fetch(:items)))
          end
          node :section, props: {title: :string}, children: :many do |props, children|
            Zaniah::Div.new.flex_col.gap(2).children([Zaniah::UI::Label.new(props.fetch(:title)), *children])
          end
        end
      end
    end
  end
end

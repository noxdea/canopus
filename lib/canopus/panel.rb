# frozen_string_literal: true

module Canopus
  module Panel
    Definition = Data.define(:id, :title, :icon, :dock, :build, :badge)

    class Registry
      DOCKS = %i[left right bottom].freeze

      attr_reader :docks

      def initialize(docks)
        @docks = docks
        @definitions, @states = {}, {}
      end

      def register(definition, visible: true, size: nil)
        definition = normalize(definition)
        raise ArgumentError, "panel visibility must be true or false" unless [true, false].include?(visible)
        size ||= @docks.fetch(definition.dock)[:size]
        raise ArgumentError, "invalid panel size" unless size.is_a?(Numeric) && size.finite? && size.positive?
        @definitions[definition.id] = definition
        @states[definition.id] ||= {visible: visible, size: size}
        definition
      end

      def fetch(id) = @definitions.fetch(id.to_s)
      def key?(id) = @definitions.key?(id.to_s)
      def visible?(id)
        definition = fetch(id)
        !!@states.fetch(definition.id)[:visible]
      end

      def show(id)
        definition = fetch(id)
        state = @states.fetch(definition.id)
        state[:visible] = true
        dock = @docks.fetch(definition.dock)
        dock[:size], dock[:visible] = state[:size], true
        definition
      end

      def hide(id)
        definition = fetch(id)
        state = @states.fetch(definition.id)
        state[:size], state[:visible] = @docks.fetch(definition.dock)[:size], false
        @docks.fetch(definition.dock)[:visible] = false if active(definition.dock).empty?
        definition
      end

      def toggle(id) = visible?(id) ? hide(id) : show(id)

      def active(dock)
        raise ArgumentError, "invalid dock side" unless DOCKS.include?(dock)
        @definitions.each_value.select { |definition| definition.dock == dock && visible?(definition.id) }
      end

      def badge(id, value)
        definition = fetch(id).with(badge: value)
        @definitions[definition.id] = definition
      end

      def resize(dock, size)
        raise ArgumentError, "invalid dock size" unless size.is_a?(Numeric) && size.finite? && size.positive?
        @docks.fetch(dock)[:size] = size
        active(dock).each { |definition| @states.fetch(definition.id)[:size] = size }
        size
      end

      def state
        @states.to_h { |id, value| [id, {"visible" => value[:visible], "size" => value[:size]}] }
      end

      def restore(state, docks: nil)
        raise ArgumentError, "panel state must be an object" unless state.is_a?(Hash) && state.length <= 1_000
        restored = state.each_with_object({}) do |(id, value), result|
          id = id.to_s
          valid = value.is_a?(Hash) && [true, false].include?(value["visible"]) &&
            value["size"].is_a?(Numeric) && value["size"].finite? && value["size"].positive?
          raise ArgumentError, "invalid panel state: #{id}" if @definitions.key?(id) && !valid
          next unless valid
          result[id] = {visible: value["visible"], size: value["size"]}
        end
        @docks.replace(docks.transform_values(&:dup)) if docks
        @states.merge!(restored)
        self
      end

      private

      def normalize(definition)
        raise ArgumentError, "panel definition required" unless definition.is_a?(Definition)
        id, title, icon, dock, build, badge = definition.deconstruct
        raise ArgumentError, "panel id must not be empty" unless !id.to_s.empty?
        raise ArgumentError, "panel title must be a string" unless title.is_a?(String)
        raise ArgumentError, "invalid dock side" unless DOCKS.include?(dock)
        raise ArgumentError, "panel builder must be callable" unless build.respond_to?(:call)
        Definition.new(id.to_s.dup.freeze, title.dup.freeze, icon, dock, build, badge)
      end
    end
  end
end

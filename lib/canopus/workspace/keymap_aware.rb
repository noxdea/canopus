# frozen_string_literal: true

require "set"

module Canopus
  module Workspace::KeymapAware
    KEYMAP_PRESETS = %w[vscode sublime jetbrains emacs].freeze

    def keymap_gui
      entries = keymap_gui_entries
      self.palette = {kind: :keymap_gui, query: +"", index: 0,
        matches: entries.map { |entry| entry[:label] }, entries: entries, settings_file: settings_path}
    end

    def keymap_presets
      self.palette = {kind: :keymap_presets, query: +"", index: 0, matches: KEYMAP_PRESETS}
    end

    private

    def keymap_gui_entries
      collisions = keymap_collisions
      @commands.each.map do |definition|
        bindings = definition.keybinding.is_a?(String) ? [definition.keybinding] : definition.keybinding&.keys || []
        collision = bindings.any? { |keys| collisions.include?([keys, definition.when]) }
        label = "#{definition.title} [#{definition.id}] — #{bindings.join(", ")}"
        label = "⚠ #{label}" if collision
        {id: definition.id, label: label, keys: bindings.first.to_s, default: bindings.first.to_s, collision: collision}.freeze
      end
    end

    def keymap_collisions
      values = Hash.new { |hash, key| hash[key] = [] }
      @commands.each do |definition|
        bindings = definition.keybinding.is_a?(String) ? {definition.keybinding => ""} : definition.keybinding || {}
        bindings.each_key { |keys| values[[keys, definition.when]] << definition.id }
      end
      @settings["keymap"].each do |group|
        group.fetch("bindings").each_key { |keys| values[[keys, group.fetch("context")]] << :settings }
      end
      values.filter_map { |key, ids| key if ids.length > 1 }.to_set
    end

    def apply_keymap_binding(entry, keys)
      keys = keys.strip
      raise Error, "key binding must not be empty" if keys.empty?
      keys.split.each { |key| Zaniah::Input::Keystroke.normalize(key) }
      groups = @settings["keymap"].map { |group| JSON.parse(JSON.generate(group)) }
      group = groups.find { |item| item.fetch("context", "").empty? } || groups.unshift({"context" => "", "bindings" => {}}).first
      group.fetch("bindings")[keys] = entry.fetch(:id)
      @settings.set_file(settings_path, "keymap", groups)
      poll_settings(force: true)
    end

    def load_keymap_preset(name)
      raise Error, "unknown keymap preset" unless KEYMAP_PRESETS.include?(name)
      path = File.expand_path("../../../assets/keymaps/#{name}.jsonc", __dir__)
      document = Kochab.parse(File.read(path))
      raise Error, "invalid keymap preset #{name}" unless document.valid? && document.value.is_a?(Hash)
      @settings.set_file(settings_path, "keymap", document.value.fetch("keymap"))
      poll_settings(force: true)
    rescue Errno::ENOENT, KeyError
      raise Error, "invalid keymap preset #{name}"
    end
  end
end

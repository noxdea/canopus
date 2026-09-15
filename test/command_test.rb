# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class CommandTest < Minitest::Test
  def test_registry_resolves_and_runs_definitions_with_keymap_context
    calls = []
    registry = Canopus::Command::Registry.new
    definition = Canopus::Command::Definition.new(
      "test.run", "Run test", "test", "Editor && vim_mode == normal", ->(value) { calls << value }, "f8"
    )

    registered = registry.register(definition)
    assert registered.frozen?
    assert_equal({"test.run" => "Run test"}, registry.entries)
    assert_empty registry.entries(context: {"Editor" => false})
    assert_nil registry.resolve("test.run", context: {"Editor" => true, "vim_mode" => "insert"})
    assert_raises(KeyError) { registry.call("test.run", 1, context: {"Editor" => false}) }

    context = {"Editor" => true, "vim_mode" => "normal"}
    assert_same registered, registry.resolve("test.run", context: context)
    assert_equal "f8", registered.keybinding
    registry.call("test.run", 2, context: context)
    assert_equal [2], calls

    registry.register("legacy", description: "Legacy action") { calls << :legacy }
    registry.call("legacy")
    assert_equal [2, :legacy], calls
  end

  def test_workspace_palette_and_keymap_share_registered_definition
    Dir.mktmpdir("canopus-command-") do |root|
      workspace = Canopus::Workspace.new(root: root, settings: Canopus::Settings.new)
      window = Zaniah::Platform.open_window(backend: :headless, width: 400, height: 300)
      controller = Canopus::Controller.new(workspace, window)
      calls = []
      workspace.register_action("test.context", description: "Context action",
        condition: "Editor && vim_mode == normal", keybinding: "f8") { calls << :run }

      workspace.palette_open(:commands)
      refute_includes workspace.palette[:matches], "Context action"
      workspace.palette = nil
      controller.input(Zaniah::Input::KeyDown.new("f8", false))
      assert_empty calls

      workspace.settings.merge!("vim_mode" => true)
      controller.input(Zaniah::Input::KeyDown.new("f8", false))
      assert_equal [:run], calls
      workspace.palette_open(:commands)
      workspace.palette[:query] << "Context"
      workspace.update_palette
      assert_includes workspace.palette[:matches], "Context action"
      workspace.palette[:index] = workspace.palette[:matches].index("Context action")
      workspace.palette_accept
      assert_equal %i[run run], calls
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end

  def test_registry_rejects_invalid_definitions
    registry = Canopus::Command::Registry.new
    invalid = Canopus::Command::Definition.new("", "Invalid", "test", "", -> {}, nil)
    assert_raises(ArgumentError) { registry.register(invalid) }
    malformed = Canopus::Command::Definition.new("test.invalid", "Invalid", "test", "Editor && (", -> {}, nil)
    assert_raises(ArgumentError) { registry.register(malformed) }
    refute_includes registry.entries, "test.invalid"
  end
end

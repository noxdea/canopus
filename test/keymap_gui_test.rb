# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class KeymapGuiTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-keymap-gui-")
    @workspace = Canopus::Workspace.new(root: @root)
  end

  def teardown
    @workspace.close
    FileUtils.remove_entry(@root)
  end

  def test_command_keymap_gui_lists_bindings_and_allows_assignment
    @workspace.keymap_gui
    assert_equal :keymap_gui, @workspace.palette[:kind]
    index = @workspace.palette[:entries].index { |entry| entry[:id] == "file.save" }
    refute_nil index
    @workspace.palette[:index] = index
    @workspace.palette_accept
    assert_equal :keymap_edit, @workspace.palette[:kind]
    @workspace.palette[:query] = "ctrl-alt-s"
    @workspace.palette_accept

    keymap = Canopus::Settings.new(@workspace.settings_path)["keymap"]
    assert_equal "file.save", keymap.first["bindings"]["ctrl-alt-s"]
  end

  def test_keymap_presets_are_packaged_and_loadable
    @workspace.keymap_presets
    assert_equal %w[vscode sublime jetbrains emacs], @workspace.palette[:matches]
    @workspace.palette[:index] = 0
    @workspace.palette_accept
    assert_includes File.read(@workspace.settings_path), '"keymap"'
  end

  def test_keymap_gui_marks_binding_collisions
    @workspace.settings.merge!("keymap" => [{"bindings" => {"cmd-s" => "file.new"}}])
    @workspace.keymap_gui
    entry = @workspace.palette[:entries].find { |item| item[:id] == "file.save" }
    assert entry[:collision]
    assert_match(/⚠/, entry[:label])
  end
end

# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"

class WorkspaceSettingsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-settings-ui-")
    @workspace = Canopus::Workspace.new(root: @root)
    @workspace.new_buffer
  end
  def teardown
    @workspace.close
    FileUtils.remove_entry(@root)
  end
  def test_edit_complete_save_reload_and_invalid_rollback
    @workspace.call("settings.open")
    buffer = @workspace.editor.buffer
    assert buffer.dirty?
    @workspace.call("file.save")
    assert File.file?(@workspace.settings_path)
    File.write(@workspace.settings_path, "{\"tab_size\":2,\"theme\":\"Canopus Light\"}")
    @workspace.poll_settings(force: true)
    assert_equal 2, @workspace.editor.tab_size
    assert_equal "Canopus Light", @workspace.theme.name
    File.write(@workspace.settings_path, "{\"tab_size\":0}")
    @workspace.poll_settings(force: true)
    assert_equal 2, @workspace.settings["tab_size"]
    assert_match(/unchanged/, @workspace.message)
    @workspace.settings_completions
    @workspace.palette[:query] = "wrap"
    @workspace.update_palette
    assert_equal ["soft_wrap"], @workspace.palette[:matches]
  end
  def test_language_layer_is_applied_and_validated
    @workspace.settings.merge!("languages" => {"ruby" => {"tab_size" => 2, "use_tabs" => true}})
    editor = @workspace.open("new.rb")
    assert_equal 2, editor.tab_size
    assert editor.use_tabs
    assert_raises(Canopus::Error) { Canopus::Settings.new("languages" => {"ruby" => {"tab_size" => 0}}) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("theme" => 123) }
    assert_equal "integer", Canopus::Settings.schema.dig("properties", "tab_size", "type")
  end

  def test_keymap_values_are_bounded_validated_and_snapshotted
    groups = [{"context" => "Editor && !vim_mode", "bindings" => {"ctrl-k ctrl-s" => "file.save", "cmd-s" => nil}}]
    settings = Canopus::Settings.new("keymap" => groups)
    groups.first["bindings"]["ctrl-k ctrl-s"] = "file.new"
    assert_equal "file.save", settings["keymap"].first["bindings"]["ctrl-k ctrl-s"]
    assert settings["keymap"].first["bindings"].frozen?
    assert_raises(Canopus::Error) { settings.merge!("keymap" => [{"context" => "Editor && (", "bindings" => {}}]) }
    assert_raises(Canopus::Error) { settings.merge!("keymap" => [{"bindings" => {"unknown-key" => "file.save"}}]) }
    assert_raises(Canopus::Error) { settings.merge!("keymap" => [{"bindings" => {"f1" => 123}}]) }
    assert_raises(Canopus::Error) { settings.merge!("keymap" => Array.new(129) { {"bindings" => {}} }) }
    assert_equal "file.save", settings["keymap"].first["bindings"]["ctrl-k ctrl-s"]
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SettingsGuiTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-settings-gui-")
    @workspace = Canopus::Workspace.new(root: @root)
  end

  def teardown
    @workspace.close
    FileUtils.remove_entry(@root)
  end

  def test_schema_palette_searches_all_and_changed_settings
    @workspace.settings_browse
    assert_equal :settings_gui, @workspace.palette[:kind]
    assert_includes @workspace.palette[:matches], 'font_size = 14'

    @workspace.settings.merge!("theme" => "Canopus Light")
    @workspace.settings_browse(changed_only: true)
    assert_equal ["theme"], @workspace.palette[:fields].map { |field| field[:path] }
  end

  def test_palette_edit_writes_nested_setting_and_reloads
    @workspace.settings_browse
    index = @workspace.palette[:fields].index { |field| field[:path] == ["tabs", "activate_on_close"] }
    @workspace.palette[:index] = index
    @workspace.palette_accept
    assert_equal :settings_edit, @workspace.palette[:kind]
    @workspace.palette[:query] = '"left"'
    @workspace.palette_accept

    assert_equal "left", @workspace.settings["tabs"]["activate_on_close"]
    assert_includes File.read(@workspace.settings_path), '"activate_on_close": "left"'
  end
end

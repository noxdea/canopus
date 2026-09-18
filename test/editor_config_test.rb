# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class EditorConfigTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-editorconfig-")
    @user = File.join(@root, "user.jsonc")
    File.write(@user, '{"tab_size":8,"use_tabs":true}')
    FileUtils.mkdir_p(File.join(@root, ".canopus"))
    File.write(File.join(@root, ".canopus", "settings.jsonc"), '{"max_line_length":80}')
    File.write(File.join(@root, ".editorconfig"), <<~CONFIG)
      root = true
      [*.rb]
      indent_style = space
      indent_size = 2
      trim_trailing_whitespace = true
      insert_final_newline = true
      max_line_length = 100
    CONFIG
    File.write(File.join(@root, "sample.rb"), "value  ")
    @workspace = Canopus::Workspace.new(root: @root, settings: Canopus::Settings.new(@user, File.join(@root, ".canopus", "settings.jsonc")))
  end

  def teardown
    @workspace.close
    FileUtils.remove_entry(@root)
  end

  def test_editorconfig_is_between_user_and_project_layers
    editor = @workspace.open("sample.rb")
    assert_equal 2, editor.tab_size
    refute editor.use_tabs
    values = @workspace.settings_for_editor(editor)
    assert_equal 80, values["max_line_length"]
    assert_equal true, values["trim_trailing_whitespace"]
    assert_equal true, values["insert_final_newline"]
  end

  def test_editorconfig_save_rules_are_applied
    editor = @workspace.open("sample.rb")
    @workspace.save_buffer(editor.buffer)
    assert_equal "value\n", File.read(File.join(@root, "sample.rb"))
  end

  def test_cache_is_invalidated_when_editorconfig_changes
    editor = @workspace.open("sample.rb")
    assert_equal 2, @workspace.settings_for_editor(editor)["tab_size"]
    File.write(File.join(@root, ".editorconfig"), "root = true\n[*.rb]\nindent_size = 6\n")
    @workspace.invalidate_editorconfig
    @workspace.apply_settings
    assert_equal 6, editor.tab_size
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class EditorSettingsLifecycleTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-settings-")
    @settings = Canopus::Settings.new("tab_size" => 6, "use_tabs" => true, "soft_wrap" => true,
      "languages" => {"dialect" => {"tab_size" => 2}, "ruby" => {"tab_size" => 3, "use_tabs" => false, "soft_wrap" => false}})
    @workspace = Canopus::Workspace.new(root: @root, settings: @settings)
  end

  def teardown
    @workspace.close
    FileUtils.remove_entry(@root)
  end

  def assert_settings(editor, name:, tab_size:, use_tabs:, wrap:)
    assert_equal name, editor.language_document.definition.name
    assert_equal tab_size, editor.tab_size
    assert_equal tab_size, editor.display_map.tab_map.tab_size
    assert_equal use_tabs, editor.use_tabs
    wrap.nil? ? assert_nil(editor.display_map.wrap_map.width) : assert_equal(wrap, editor.display_map.wrap_map.width)
  end

  def test_both_split_actions_apply_global_settings_to_untitled_editors
    first = @workspace.new_buffer
    %w[pane.split_right pane.split_down].each do |action|
      @workspace.call(action)
      current = @workspace.editor
      refute_same first, current
      assert_same first.buffer, current.buffer
      assert_settings(current, name: "text", tab_size: 6, use_tabs: true, wrap: 100)
    end
    assert_empty @workspace.message
  end

  def test_split_keeps_plugin_definition_and_its_language_settings
    @workspace.register_language("dialect", extensions: [".dialect"], lexer: "ruby")
    first = @workspace.open("example.dialect")
    definition = first.language_document.definition
    @workspace.call("pane.split_right")
    assert_same definition, @workspace.editor.language_document.definition
    assert_same first.buffer, @workspace.editor.buffer
    assert_settings(@workspace.editor, name: "dialect", tab_size: 2, use_tabs: true, wrap: 100)
  end

  def test_split_honors_language_overrides_that_disable_global_flags
    @workspace.open("example.rb")
    @workspace.call("pane.split_down")
    assert_settings(@workspace.editor, name: "ruby", tab_size: 3, use_tabs: false, wrap: nil)
  end

  def test_restore_applies_current_settings_and_registered_plugin_language_to_all_tabs
    @workspace.register_language("dialect", extensions: [".dialect"], lexer: "ruby")
    @workspace.open("example.dialect").insert_text("content", auto_indent: false)
    @workspace.split
    @workspace.open("example.rb").insert_text("puts :ok", auto_indent: false)
    path = File.join(@root, "session.json")
    @workspace.save_session(path)
    @settings.merge!("languages" => {"dialect" => {"tab_size" => 5}})
    @workspace.restore_session(path)
    @workspace.panes.flat_map(&:editors).each do |editor|
      if editor.buffer.path.end_with?(".dialect")
        assert_settings(editor, name: "dialect", tab_size: 5, use_tabs: true, wrap: 100)
      else
        assert_settings(editor, name: "ruby", tab_size: 3, use_tabs: false, wrap: nil)
      end
    end
    assert_same @workspace.panes[0].editors[0].buffer, @workspace.panes[1].editors[0].buffer
  end

  def test_late_plugin_registration_reapplies_settings_to_restored_and_split_editors
    @workspace.open("example.dialect").insert_text("content", auto_indent: false)
    @workspace.split
    path = File.join(@root, "session.json")
    @workspace.save_session(path)
    @workspace.restore_session(path)
    @workspace.panes.flat_map(&:editors).each do |editor|
      assert_settings(editor, name: "text", tab_size: 6, use_tabs: true, wrap: 100)
    end
    # CLI restores before loading plugins. Registering the language must update
    # both its lexer and per-language editor settings without another reload.
    @workspace.register_language("dialect", extensions: [".dialect"], lexer: "ruby")
    @workspace.panes.flat_map(&:editors).each do |editor|
      assert_settings(editor, name: "dialect", tab_size: 2, use_tabs: true, wrap: 100)
    end
  end

  def test_restore_and_split_preserve_the_read_only_no_wrap_policy
    buffer = Canopus::Buffer.new("read only", read_only: true)
    @workspace.buffers[buffer.object_id] = buffer
    @workspace.active_pane.open(buffer)
    @workspace.split
    assert @workspace.editor.buffer.read_only
    assert_settings(@workspace.editor, name: "text", tab_size: 6, use_tabs: true, wrap: nil)
    path = File.join(@root, "session.json")
    @workspace.save_session(path)
    @workspace.restore_session(path)
    @workspace.panes.flat_map(&:editors).each do |editor|
      assert editor.buffer.read_only
      assert_settings(editor, name: "text", tab_size: 6, use_tabs: true, wrap: nil)
    end
  end
end

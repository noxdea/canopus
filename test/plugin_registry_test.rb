# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class PluginRegistryTest < Minitest::Test
  def with_plugin(source)
    Dir.mktmpdir("canopus-plugin-") do |directory|
      path = File.join(directory, "plugin.rb")
      File.write(path, source)
      workspace = Canopus::Workspace.new(root: directory)
      workspace.new_buffer.insert_text("hello 日本")
      begin
        yield workspace, path
      ensure
        workspace.close
      end
    end
  end
  def test_explicit_trust_and_permissions_are_required
    with_plugin('register_action("read") { |api| api.notify(api.text) }') do |workspace, path|
      assert_raises(Canopus::Plugins::PermissionDenied) { workspace.plugins.load(path) }
      workspace.plugins.load(path, trusted: true)
      workspace.call("read")
      assert_includes workspace.message, "read_buffer"
    end
  end
  def test_isolated_and_local_plugins_use_the_same_api
    [true, false].each do |isolated|
      with_plugin('register_action("replace") { |api| api.replace(0...5, "hi"); api.notify("done") }') do |workspace, path|
        workspace.plugins.load(path, trusted: true, permissions: [:edit_buffer], isolated: isolated)
        workspace.call("replace")
        assert_equal "hi 日本", workspace.editor.buffer.text
        assert_equal "done", workspace.message
        workspace.editor.undo
        assert_equal "hello 日本", workspace.editor.buffer.text
      end
    end
  end
  def test_crash_and_infinite_loop_do_not_take_down_editor
    with_plugin('register_action("crash") { exit! 7 }') do |workspace, path|
      workspace.plugins.load(path, trusted: true)
      workspace.call("crash")
      assert_includes workspace.message, "ended"
      workspace.editor.insert_text("!")
      assert_equal "hello 日本!", workspace.editor.buffer.text
    end
    with_plugin('register_action("hang") { loop {} }') do |workspace, path|
      workspace.plugins.load(path, trusted: true)
      workspace.call("hang")
      assert_includes workspace.message, "response limit"
    end
  end

  def test_http_api_checks_permission_and_scheme_in_both_modes
    [true, false].each do |isolated|
      with_plugin('register_action("fetch") { |api| api.notify(api.http_get("file:///etc/hosts")) }') do |workspace, path|
        workspace.plugins.load(path, trusted: true, isolated: isolated)
        workspace.call("fetch")
        assert_includes workspace.message, "requires network"
      end
      with_plugin('register_action("fetch") { |api| api.notify(api.http_get("file:///etc/hosts")) }') do |workspace, path|
        workspace.plugins.load(path, trusted: true, permissions: [:network], isolated: isolated)
        workspace.call("fetch")
        assert_includes workspace.message, "HTTP or HTTPS URL required"
      end
    end
  end
end

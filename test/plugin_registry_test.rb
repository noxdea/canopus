# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "saiph"

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
        workspace.plugins.load(path, trusted: true, isolated: isolated, timeout: 10)
        workspace.call("fetch")
        assert_includes workspace.message, "requires network"
      end
      with_plugin('register_action("fetch") { |api| api.notify(api.http_get("file:///etc/hosts")) }') do |workspace, path|
        workspace.plugins.load(path, trusted: true, permissions: [:network], isolated: isolated, timeout: 10)
        workspace.call("fetch")
        assert_includes workspace.message, "HTTP or HTTPS URL required"
      end
    end
  end

  def test_sandbox_policy_maps_project_permissions
    with_plugin('register_action("noop") { |_api| "ok" }') do |workspace, _path|
      runtime = Canopus::Plugins::IsolatedRuntime.allocate
      runtime.instance_variable_set(:@workspace, workspace)
      runtime.instance_variable_set(:@permissions, %w[read_project write_project network exec])
      policy = runtime.send(:sandbox_policy)
      assert_equal [workspace.root], policy.read_paths
      assert_equal [workspace.root], policy.write_paths
      assert policy.network
      assert policy.exec
    end
  end

  def test_required_sandbox_rejects_unsupported_backend
    skip if Saiph.available?

    with_plugin('register_action("noop") { |_api| "ok" }') do |workspace, path|
      workspace.settings.merge!("plugins" => {"sandbox" => "required"})
      error = assert_raises(Canopus::Error) { workspace.plugins.load(path, trusted: true) }
      assert_includes error.message, "sandbox is required"
    end
  end

  def test_plugin_disable_state_is_atomic_and_scoped_to_gem_names
    with_plugin('register_action("noop") { |_api| "ok" }') do |workspace, _path|
      Dir.mktmpdir("canopus-plugin-state-") do |directory|
        state = File.join(directory, "plugins.json")
        registry = Canopus::Plugins::Registry.new(workspace, state_path: state)
        registry.disable("canopus-plugin-demo")
        assert registry.disabled?("canopus-plugin-demo")
        assert_raises(ArgumentError) { registry.disable("demo") }
        restored = Canopus::Plugins::Registry.new(workspace, state_path: state)
        assert restored.disabled?("canopus-plugin-demo")
        restored.enable("canopus-plugin-demo")
        refute restored.disabled?("canopus-plugin-demo")
      end
    end
  end
end

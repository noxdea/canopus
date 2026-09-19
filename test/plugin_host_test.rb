# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "tmpdir"

class PluginHostTest < Minitest::Test
  def test_host_discovers_and_activates_a_manifest_plugin
    Dir.mktmpdir("canopus-gienah-") do |root|
      previous_state_home = ENV["XDG_STATE_HOME"]
      ENV["XDG_STATE_HOME"] = File.join(root, "state")
      File.write(File.join(root, "plugin.json"), JSON.generate(
        "id" => "host-test", "name" => "Host test", "version" => "0.1.0", "api_version" => 2,
        "entry" => "plugin.rb", "capabilities" => ["buffer.read"], "activation" => ["onCommand:host.test"]
      ))
      File.write(File.join(root, "plugin.rb"), <<~RUBY)
        require "gienah"
        Gienah::Plugin.export("test") { Gienah::Plugin.call("buffer/text") }
        Gienah::Plugin.run
      RUBY
      workspace = Canopus::Workspace.new(root: root)
      workspace.new_buffer.insert_text("hello")
      workspace.toggle_workspace_trust
      host = workspace.plugin_host
      manifests = host.discover([root])
      assert_equal ["host-test"], manifests.map(&:id)
      instance = host.activate("host-test", reason: "onCommand:host.test")
      assert_equal :ready, instance.state
      assert_equal "hello", instance.call("test").await(timeout: 2)
      host.shutdown
    ensure
      workspace&.close
      ENV["XDG_STATE_HOME"] = previous_state_home
    end
  end

  def test_host_storage_and_declarative_ui_are_available_to_plugins
    Dir.mktmpdir("canopus-gienah-api-") do |root|
      previous_state_home = ENV["XDG_STATE_HOME"]
      ENV["XDG_STATE_HOME"] = File.join(root, "state")
      File.write(File.join(root, "plugin.json"), JSON.generate(
        "id" => "api-test", "name" => "API test", "version" => "0.1.0", "api_version" => 2,
        "entry" => "plugin.rb", "capabilities" => ["buffer.read", "ui.panel"],
        "activation" => ["onStartup"], "contributes" => {"panels" => [{"id" => "api", "title" => "API", "dock" => "right"}]}
      ))
      File.write(File.join(root, "plugin.rb"), <<~RUBY)
        require "gienah"
        Gienah::Plugin.export("exercise") do
          Gienah::Plugin.call("storage/set", "key" => "value", "value" => "ok")
          Gienah::Plugin.call("ui/render", "panel" => "api", "tree" => {
            "type" => "column", "props" => {}, "children" => [{"type" => "text", "props" => {"value" => "ready"}, "children" => []}]
          })
          Gienah::Plugin.call("storage/get", "key" => "value")
        end
        Gienah::Plugin.run
      RUBY
      workspace = Canopus::Workspace.new(root: root)
      workspace.toggle_workspace_trust
      host = workspace.plugin_host
      host.discover([root])
      instance = host.activate("api-test", reason: "onStartup")
      assert_equal "ok", instance.call("exercise").await(timeout: 2)
      assert workspace.panels.key?("api")
    ensure
      workspace&.close
      ENV["XDG_STATE_HOME"] = previous_state_home
    end
  end
end

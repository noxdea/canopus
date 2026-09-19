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

  def test_host_limits_full_text_and_routes_events_to_subscribers
    Dir.mktmpdir("canopus-gienah-events-") do |root|
      previous_state_home = ENV["XDG_STATE_HOME"]
      ENV["XDG_STATE_HOME"] = File.join(root, "state")
      %w[event-a event-b].each do |id|
        directory = File.join(root, id)
        Dir.mkdir(directory)
        File.write(File.join(directory, "plugin.json"), JSON.generate(
          "id" => id, "name" => id, "version" => "0.1.0", "api_version" => 2,
          "entry" => "plugin.rb", "capabilities" => ["buffer.read"], "activation" => ["onStartup"]
        ))
        File.write(File.join(directory, "plugin.rb"), <<~RUBY)
          require "gienah"
          $events = Hash.new(0)
          Gienah::Plugin.on("buffer/didChange") { |_params| $events["change"] += 1 }
          Gienah::Plugin.on("selection/didChange") { |_params| $events["selection"] += 1 }
          Gienah::Plugin.export("subscribe") { Gienah::Plugin.call("buffer/subscribe") }
          Gienah::Plugin.export("counts") { $events }
          Gienah::Plugin.run
        RUBY
      end
      workspace = Canopus::Workspace.new(root: root)
      workspace.new_buffer.insert_text("hello")
      workspace.toggle_workspace_trust
      host = workspace.plugin_host
      host.discover([root])
      subscribed = host.activate("event-a", reason: "onStartup")
      unsubscribed = host.activate("event-b", reason: "onStartup")
      subscribed.call("subscribe").await(timeout: 2)

      workspace.editor.insert_text("!")
      assert wait_for(timeout: 2) { subscribed.call("counts").await(timeout: 2).fetch("change", 0) == 1 }
      assert_equal 0, unsubscribed.call("counts").await(timeout: 2).fetch("change", 0)

      workspace.editor.select(0)
      assert wait_for(timeout: 2) { subscribed.call("counts").await(timeout: 2).fetch("selection", 0) >= 1 }
    ensure
      workspace&.close
      ENV["XDG_STATE_HOME"] = previous_state_home
    end
  end

  def test_host_rejects_unbounded_full_text_requests
    Dir.mktmpdir("canopus-gienah-limit-") do |root|
      previous_state_home = ENV["XDG_STATE_HOME"]
      ENV["XDG_STATE_HOME"] = File.join(root, "state")
      File.write(File.join(root, "plugin.json"), JSON.generate(
        "id" => "limit-test", "name" => "Limit test", "version" => "0.1.0", "api_version" => 2,
        "entry" => "plugin.rb", "capabilities" => ["buffer.read"], "activation" => ["onStartup"]
      ))
      File.write(File.join(root, "plugin.rb"), <<~RUBY)
        require "gienah"
        Gienah::Plugin.export("text") { Gienah::Plugin.call("buffer/text") }
        Gienah::Plugin.run
      RUBY
      workspace = Canopus::Workspace.new(root: root)
      workspace.new_buffer.buffer.edit([[0...0, "x" * (Canopus::Plugins::BUFFER_CONTEXT_LIMIT + 1)]])
      workspace.toggle_workspace_trust
      host = workspace.plugin_host
      host.discover([root])
      instance = host.activate("limit-test", reason: "onStartup")
      error = assert_raises(Gienah::Error) { instance.call("text").await(timeout: 2) }
      assert_includes error.message, "buffer text exceeds 1 MiB"
    ensure
      workspace&.close
      ENV["XDG_STATE_HOME"] = previous_state_home
    end
  end

  def test_host_process_exec_runs_inside_the_plugin_sandbox
    require "saiph"
    skip("OS sandbox unavailable") unless Saiph.available?

    Dir.mktmpdir("canopus-gienah-process-") do |root|
      previous_state_home = ENV["XDG_STATE_HOME"]
      ENV["XDG_STATE_HOME"] = File.join(root, "state")
      File.write(File.join(root, "plugin.json"), JSON.generate(
        "id" => "process-test", "name" => "Process test", "version" => "0.1.0", "api_version" => 2,
        "entry" => "plugin.rb", "capabilities" => ["process.exec"], "activation" => ["onStartup"]
      ))
      File.write(File.join(root, "plugin.rb"), <<~RUBY)
        require "gienah"
        require "rbconfig"
        Gienah::Plugin.export("run") do
          Gienah::Plugin.call("process/exec", "command" => [RbConfig.ruby, "-e", "print 'ok'"])
        end
        Gienah::Plugin.run
      RUBY
      workspace = Canopus::Workspace.new(root: root)
      workspace.toggle_workspace_trust
      host = workspace.plugin_host
      host.discover([root])
      instance = host.activate("process-test", reason: "onStartup")
      result = instance.call("run").await(timeout: 5)
      assert_equal "ok", result.fetch("stdout")
      assert_equal 0, result.fetch("status")
    ensure
      workspace&.close
      ENV["XDG_STATE_HOME"] = previous_state_home
    end
  end

  private

  def wait_for(timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
    true
  end
end

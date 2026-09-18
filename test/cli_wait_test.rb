# frozen_string_literal: true

require_relative "test_helper"
require "canopus/cli"
require "stringio"
require "tmpdir"

class CLIWaitTest < Minitest::Test
  def test_wait_closes_only_after_every_target_tab_is_closed
    Dir.mktmpdir("canopus-wait-") do |root|
      first, second, unrelated = %w[first.rb second.rb unrelated.rb].map { |name| File.join(root, name) }
      [first, second, unrelated].each { |path| File.write(path, "") }
      alternate_first = File.join(root, ".", "first.rb")
      workspace = Canopus::Workspace.new(root: root)
      first_path, second_path = [first, second].map { |path| workspace.canonical_path(path) }
      window = Zaniah::Platform.open_window(backend: :headless)
      checks = []
      window.define_singleton_method(:run) do
        extra = workspace.open(unrelated)
        workspace.close_editor(extra)
        tick
        checks << closed?
        workspace.close_editor(workspace.panes.flat_map(&:editors).find { |editor| editor.buffer.path == first_path })
        tick
        checks << closed?
        workspace.close_editor(workspace.panes.flat_map(&:editors).find { |editor| editor.buffer.path == second_path })
        tick
        checks << closed?
      end

      error = StringIO.new
      Zaniah::Platform.stub(:open_window, window) do
        Canopus::Workspace.stub(:new, ->(*) { workspace }) do
          assert_equal 0, Canopus::CLI.main(["--project", root, "--wait", alternate_first, second], output: StringIO.new, error: error), error.string
        end
      end
      assert_equal [false, false, true], checks
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end

  def test_cancelled_dirty_close_keeps_waiting
    Dir.mktmpdir("canopus-wait-") do |root|
      target = File.join(root, "target.rb")
      File.write(target, "")
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.open(target)
      window = Zaniah::Platform.open_window(backend: :headless)
      Canopus::Controller.new(workspace, window).wait_for([target])
      editor.insert_text("dirty")

      refute workspace.request_close([editor])
      workspace.resolve_tab_close(:cancel)
      window.tick
      refute window.closed?
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end

  def test_wait_keeps_running_while_a_target_is_open_in_another_pane
    Dir.mktmpdir("canopus-wait-") do |root|
      target = File.join(root, "target.rb")
      File.write(target, "")
      workspace = Canopus::Workspace.new(root: root)
      first = workspace.open(target)
      workspace.split
      second = workspace.editor
      window = Zaniah::Platform.open_window(backend: :headless)
      Canopus::Controller.new(workspace, window).wait_for([target])

      workspace.close_editor(first)
      window.tick
      refute window.closed?
      workspace.close_editor(second)
      window.tick
      assert window.closed?
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end

  def test_unrelated_dirty_close_prompt_is_not_reopened_each_tick
    Dir.mktmpdir("canopus-wait-") do |root|
      target, unrelated = %w[target.rb unrelated.rb].map { |name| File.join(root, name) }
      [target, unrelated].each { |path| File.write(path, "") }
      workspace = Canopus::Workspace.new(root: root)
      target_editor = workspace.open(target)
      unrelated_editor = workspace.open(unrelated)
      unrelated_editor.insert_text("dirty")
      window = Zaniah::Platform.open_window(backend: :headless)
      Canopus::Controller.new(workspace, window).wait_for([target])

      workspace.close_editor(target_editor)
      window.tick
      prompt = workspace.palette
      assert_equal :confirm_close, prompt[:kind]
      window.tick
      assert_same prompt, workspace.palette
      workspace.palette = nil
      window.tick
      assert_nil workspace.palette
      refute window.closed?
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end
end

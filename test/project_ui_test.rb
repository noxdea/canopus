# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class ProjectUITest < Minitest::Test
  def with_workspace
    Dir.mktmpdir("canopus-project-ui-") do |directory|
      workspace = Canopus::Workspace.new(root: directory)
      workspace.new_buffer
      begin
        yield workspace, directory
      ensure
        workspace.close
      end
    end
  end
  def test_tree_expansion_and_empty_directories
    with_workspace do |workspace, _|
      workspace.create_project_entry("src", directory: true)
      assert_equal ["src"], workspace.project_tree.visible.map(&:path)
      workspace.create_project_entry("src/a.rb")
      # Opening the new file reveals its parent without an extra click.
      assert_equal ["src", "src/a.rb"], workspace.project_tree.visible.map(&:path)
      workspace.project_tree.toggle("src")
      assert_equal ["src"], workspace.project_tree.visible.map(&:path)
    end
  end
  def test_rename_keeps_open_buffer_and_deletion_is_recoverable
    with_workspace do |workspace, directory|
      workspace.create_project_entry("old.rb")
      editor = workspace.editor
      editor.insert_text("hello")
      editor.buffer.save
      workspace.rename_project_entry("old.rb", "new.rb")
      assert_equal File.join(File.realpath(directory), "new.rb"), editor.buffer.path
      assert_same editor.buffer, workspace.open("new.rb").buffer
      editor.insert_text("!")
      assert_raises(Canopus::Error) { workspace.trash_project_entry("new.rb") }
      editor.buffer.save
      trash = workspace.trash_project_entry("new.rb")
      assert File.file?(trash)
      assert_equal "hello!", File.read(trash)
      refute File.exist?(File.join(directory, "new.rb"))
      assert_empty workspace.files
    end
  end
  def test_filesystem_operations_reject_escape_and_overwrite
    with_workspace do |workspace, directory|
      workspace.create_project_entry("existing.rb")
      workspace.create_project_entry("another.rb")
      assert_raises(Canopus::Error) { workspace.rename_project_entry("existing.rb", "another.rb") }
      assert_raises(ArgumentError) { workspace.create_project_entry("../escape.rb") }
      assert_raises(Canopus::Error) { workspace.trash_project_entry(".") }
      unless RUBY_PLATFORM.match?(/mswin|mingw/)
        Dir.mktmpdir("canopus-outside-") do |outside|
          File.symlink(outside, File.join(directory, "link"))
          assert_raises(Canopus::Error) { workspace.create_project_entry("link/escape.rb") }
          assert_empty Dir.children(outside)
          trash = workspace.trash_project_entry("link")
          assert File.symlink?(trash)
          assert File.directory?(outside)
        end
      end
    end
  end
  def test_registered_panel_and_language_are_connected
    with_workspace do |workspace, directory|
      workspace.register_language("custom", extensions: [".custom"], lexer: "ruby", comment: "#")
      workspace.create_project_entry("source.custom")
      assert_equal "custom", workspace.editor.language_document.definition.name
      workspace.register_panel("Inspector", side: :right) { "Visible panel content" }
      workspace.call("panel.Inspector")
      window = Zaniah::Platform.open_window(width: 800, height: 300)
      controller = Canopus::Controller.new(workspace, window)
      controller.tick
      assert window.text_runs.any? { |_, _, text, _| text == "Visible panel content" }
      assert_operator controller.view.editor_bounds.values.first.width, :<, 600
      window.close
    end
  end
end

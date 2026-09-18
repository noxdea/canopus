# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class PersistentUndoTest < Minitest::Test
  def test_saved_history_survives_workspace_close_and_preserves_composite_steps
    Dir.mktmpdir("canopus-persistent-undo-") do |root|
      path = File.join(root, "sample.txt")
      File.write(path, "abc")
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.open(path)
      editor.buffer.begin_undo_group
      editor.edit([[0...1, "x"]])
      editor.edit([[1...2, "y"]])
      editor.buffer.end_undo_group
      workspace.save_buffer(editor.buffer)
      workspace.close

      restored = Canopus::Workspace.new(root: root)
      buffer = restored.open(path).buffer
      assert_equal "xyc", buffer.text
      assert_equal 1, buffer.history.length
      assert_instance_of Canopus::Patch::Composite, buffer.history.last.patch
      assert_equal 2, buffer.history.last.patch.patches.length
      assert buffer.undo
      assert_equal "abc", buffer.text
      restored.close
    end
  end

  def test_dirty_buffers_and_changed_files_are_not_restored
    Dir.mktmpdir("canopus-persistent-undo-") do |root|
      path = File.join(root, "sample.txt")
      File.write(path, "abc")
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.open(path)
      editor.edit([[0...1, "x"]])
      workspace.close

      restored = Canopus::Workspace.new(root: root)
      assert_empty restored.open(path).buffer.history
      restored.close

      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.open(path)
      editor.edit([[0...1, "x"]])
      workspace.save_buffer(editor.buffer)
      workspace.close
      record = Dir[File.join(root, ".canopus", "undo", "*.json")].fetch(0)
      File.write(path, "changed")

      restored = Canopus::Workspace.new(root: root)
      assert_empty restored.open(path).buffer.history
      restored.close
      File.write(record, "not json")
    end
  end

  def test_corrupt_records_are_ignored_and_settings_are_validated
    assert_equal({"enabled" => true, "max_entries" => 1_000, "expire_days" => 30}, Canopus::Settings.new["persistent_undo"])
    assert_raises(Canopus::Error) { Canopus::Settings.new("persistent_undo" => {"enabled" => true, "max_entries" => 0, "expire_days" => 30}) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("languages" => {"ruby" => {"persistent_undo" => {}}}) }
  end

  def test_symlinked_open_path_does_not_create_a_record
    Dir.mktmpdir("canopus-persistent-undo-") do |root|
      target = File.join(root, "target.txt")
      link = File.join(root, "link.txt")
      File.write(target, "abc")
      File.symlink(target, link)
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.open(link)
      editor.edit([[0...1, "x"]])
      workspace.save_buffer(editor.buffer)
      workspace.close
      assert_empty Dir[File.join(root, ".canopus", "undo", "*.json")]
    end
  end
end

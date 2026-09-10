# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class WorkspaceEditTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("canopus-workspace-edit-")
    @workspace = Canopus::Workspace.new(root: @directory)
    @path = File.join(@directory, "a.rb")
    File.binwrite(@path, "ab\ncd")
    @editor = @workspace.open(@path)
  end

  def teardown
    @workspace.close
    FileUtils.remove_entry(@directory)
  end

  def change(row, first, last, text, version: nil, path: @path)
    {"textDocument" => {"uri" => Canopus::LSP::Protocol.uri(path), "version" => version},
     "edits" => [{"range" => {"start" => {"line" => row, "character" => first}, "end" => {"line" => row, "character" => last}}, "newText" => text}]}
  end

  def apply(*documents) = @workspace.apply_workspace_edit({"documentChanges" => documents})

  def test_repeated_document_changes_use_staged_utf16_offsets_and_one_undo
    assert_equal({"applied" => true}, apply(change(0, 0, 1, "日😀"), change(1, 0, 1, "X")))
    assert_equal "日😀b\nXd", @editor.buffer.text
    assert_equal 2, @editor.buffer.version
    assert_equal 1, @editor.buffer.history.length
    assert @editor.undo
    assert_equal "ab\ncd", @editor.buffer.text
    assert @editor.redo
    assert_equal "日😀b\nXd", @editor.buffer.text
    assert_equal "ab\ncd", File.binread(@path)
  end

  def test_repeated_document_versions_are_checked_against_each_staged_version
    assert_raises(Canopus::Error) { apply(change(0, 0, 1, "xyz", version: 0), change(1, 0, 1, "X", version: 0)) }
    assert_equal "ab\ncd", @editor.buffer.text
    assert_equal 0, @editor.buffer.version
    assert_empty @editor.buffer.history
    apply(change(0, 0, 1, "xyz", version: 0), change(1, 0, 1, "X", version: 1))
    assert_equal "xyzb\nXd", @editor.buffer.text
  end

  def test_document_changes_take_precedence_over_unversioned_changes
    document = change(0, 0, 1, "Y")
    ignored = {document.fetch("textDocument").fetch("uri") => change(0, 0, 1, "WRONG").fetch("edits")}
    @workspace.apply_workspace_edit({"changes" => ignored, "documentChanges" => [document]})
    assert_equal "Yb\ncd", @editor.buffer.text
    assert_equal 1, @editor.buffer.version
  end

  def test_invalid_later_document_never_changes_or_registers_earlier_buffers
    second = File.join(@directory, "b.rb")
    File.write(second, "original")
    original_registry = @workspace.buffers.dup
    assert_raises(RangeError) do
      apply(change(0, 0, 1, "new", path: second), change(50, 0, 1, "invalid"))
    end
    assert_equal original_registry, @workspace.buffers
    assert_equal "ab\ncd", @editor.buffer.text
    assert_equal "original", File.read(second)
  end

  def test_new_unsaved_document_can_receive_edits_without_a_disk_file
    path = File.join(@directory, "not-yet-saved.rb")
    editor = @workspace.open(path)
    apply(change(0, 0, 0, "draft", version: 0, path: path))
    assert_equal "draft", editor.buffer.text
    assert editor.buffer.dirty?
    refute File.exist?(path)
  end

  def test_staged_newlines_are_available_to_later_ranges
    apply(change(0, 0, 0, "first\n", version: 0), change(2, 0, 1, "X", version: 1))
    assert_equal "first\nab\nXd", @editor.buffer.text
  end

  def test_resource_operations_and_read_only_edits_are_rejected_without_mutation
    assert_raises(Canopus::Error) do
      apply(change(0, 0, 1, "new"), {"kind" => "delete", "uri" => Canopus::LSP::Protocol.uri(@path)})
    end
    @editor.buffer.instance_variable_set(:@read_only, true)
    assert_raises(Canopus::Error) { apply(change(0, 0, 1, "new")) }
    assert_equal "ab\ncd", @editor.buffer.text
  end
end

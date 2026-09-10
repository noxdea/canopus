# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class WorkspaceResourceEditTest < Minitest::Test
  def setup
    @directory = File.realpath(Dir.mktmpdir("canopus-resource-edit-"))
    @workspace = Canopus::Workspace.new(root: @directory)
  end

  def teardown
    @workspace.close
    FileUtils.remove_entry(@directory)
  end

  def path(name) = File.join(@directory, name)
  def uri(name) = Canopus::LSP::Protocol.uri(path(name))
  def create(name, **options) = {"kind" => "create", "uri" => uri(name), "options" => options.transform_keys(&:to_s)}
  def rename(from, to, **options) = {"kind" => "rename", "oldUri" => uri(from), "newUri" => uri(to), "options" => options.transform_keys(&:to_s)}
  def delete(name, **options) = {"kind" => "delete", "uri" => uri(name), "options" => options.transform_keys(&:to_s)}
  def text(name, value, row: 0, column: 0, version: nil)
    {"textDocument" => {"uri" => uri(name), "version" => version},
     "edits" => [{"range" => {"start" => {"line" => row, "character" => column}, "end" => {"line" => row, "character" => column}}, "newText" => value}]}
  end
  def apply(*changes) = @workspace.apply_workspace_edit({"documentChanges" => changes}, confirmed: true)

  def test_creation_rename_and_text_are_preflighted_in_protocol_order
    edit = {"documentChanges" => [create("a.rb"), text("a.rb", "日本", version: 0), rename("a.rb", "b.rb"), text("b.rb", "!", column: 2, version: 1)]}
    assert_raises(Canopus::Error) { @workspace.apply_workspace_edit(edit) }
    refute File.exist?(path("a.rb"))
    result = @workspace.apply_workspace_edit(edit, confirmed: true)
    assert_equal true, result["applied"], result.inspect
    refute File.exist?(path("a.rb"))
    assert_equal "", File.read(path("b.rb"))
    buffer = @workspace.buffers.fetch(path("b.rb"))
    assert_equal "日本!", buffer.text
    assert buffer.dirty?
    assert_equal 1, buffer.history.length
    buffer.undo
    assert_equal "", buffer.text
  end

  def test_recursive_directory_rename_preserves_dirty_open_buffers
    Dir.mkdir(path("old"))
    File.write(path("old/a.rb"), "source")
    editor = @workspace.open("old/a.rb")
    editor.insert_text("draft ")
    result = apply(rename("old", "new"), text("new/a.rb", "!", column: 12, version: 1))
    assert result["applied"], result.inspect
    assert_equal "draft source!", editor.buffer.text
    assert_equal path("new/a.rb"), editor.buffer.path
    assert_same editor.buffer, @workspace.open("new/a.rb").buffer
    assert_equal "source", File.read(path("new/a.rb"))
    refute File.exist?(path("old"))
  end

  def test_delete_is_recoverable_and_requires_recursive_permission
    Dir.mkdir(path("folder"))
    File.write(path("folder/a.rb"), "valuable")
    editor = @workspace.open("folder/a.rb")
    assert_raises(Canopus::Error) { apply(delete("folder")) }
    assert File.exist?(path("folder/a.rb"))
    result = apply(delete("folder", recursive: true))
    assert result["applied"], result.inspect
    refute File.exist?(path("folder"))
    assert_equal "valuable", File.read(File.join(result.fetch("recoveryPaths").first, "a.rb"))
    refute @workspace.panes.flat_map(&:editors).include?(editor)
    assert_includes @workspace.message, "backups"
  end

  def test_overwrite_keeps_backup_and_resets_clean_open_document
    File.write(path("a.rb"), "previous")
    buffer = @workspace.open("a.rb").buffer
    result = apply(create("a.rb", overwrite: true, ignoreIfExists: true), text("a.rb", "new", version: 1))
    assert result["applied"], result.inspect
    assert_equal "previous", File.read(result.fetch("recoveryPaths").first)
    assert_equal "", File.read(path("a.rb"))
    assert_equal "new", buffer.text
    assert buffer.dirty?
    assert_equal 2, buffer.version
  end

  def test_invalid_later_text_has_no_filesystem_or_registry_side_effects
    before = @workspace.buffers.dup
    assert_raises(RangeError) { apply(create("first.rb"), text("first.rb", "wrong", row: 50)) }
    refute File.exist?(path("first.rb"))
    refute File.exist?(path(".canopus"))
    assert_equal before, @workspace.buffers
  end

  def test_dirty_delete_overwrite_and_open_rename_destinations_are_rejected
    File.write(path("a.rb"), "disk")
    editor = @workspace.open("a.rb")
    editor.insert_text("draft")
    assert_raises(Canopus::Error) { apply(delete("a.rb")) }
    assert_raises(Canopus::Error) { apply(create("a.rb", overwrite: true)) }
    other = @workspace.open("b.rb")
    other.insert_text("keep")
    assert_raises(Canopus::Error) { apply(rename("a.rb", "b.rb", overwrite: true)) }
    assert_equal "disk", File.read(path("a.rb"))
    assert_equal "keep", other.buffer.text
    assert_raises(Canopus::Error) { apply(text("a.rb", "more"), delete("a.rb")) }
  end

  def test_parent_symlinks_and_protected_metadata_are_rejected_but_link_deletion_is_safe
    Dir.mktmpdir do |outside|
      File.write(File.join(outside, "keep.txt"), "keep")
      File.symlink(outside, path("linked"))
      assert_raises(Canopus::Error) { apply(create("linked/new.rb")) }
      assert_raises(Canopus::Error) { apply(create(".git/config")) }
      result = apply(delete("linked"))
      assert result["applied"], result.inspect
      assert File.symlink?(result.fetch("recoveryPaths").first)
      assert_equal "keep", File.read(File.join(outside, "keep.txt"))
    end
  end

  def test_ignore_flags_do_not_modify_resources
    File.write(path("a.rb"), "original")
    File.write(path("b.rb"), "destination")
    result = apply(create("a.rb", ignoreIfExists: true), rename("a.rb", "b.rb", ignoreIfExists: true), delete("absent", ignoreIfNotExists: true))
    assert result["applied"], result.inspect
    assert_equal "original", File.read(path("a.rb"))
    assert_equal "destination", File.read(path("b.rb"))
    refute File.exist?(path(".canopus"))
  end

  def test_io_failure_rolls_back_earlier_rename_without_losing_files
    File.write(path("a.rb"), "original")
    require "canopus/workspace/edit/plan"
    plan = Canopus::Workspace::Edit::Plan.new(@workspace, {"documentChanges" => [rename("a.rb", "b.rb"), create("c.rb")]})
    plan.singleton_class.prepend(Module.new do
      def execute_resource(operation)
        raise IOError, "injected write failure" if operation[:kind] == :create
        super
      end
    end)
    result = plan.apply
    refute result["applied"]
    assert_equal 1, result["failedChange"]
    assert_equal "original", File.read(path("a.rb"))
    refute File.exist?(path("b.rb"))
    refute File.exist?(path("c.rb"))
  end

  def test_confirmation_lists_targets_and_defaults_to_cancel
    future = Canopus::LSP::Future.new(nil)
    @workspace.confirm_workspace_edit({"documentChanges" => [create("a.rb", overwrite: true)]}, response: future)
    assert_equal 1, @workspace.palette[:index]
    assert_includes @workspace.palette[:details].first, path("a.rb")
    assert_includes @workspace.palette[:details].first, "overwrite"
    refute File.exist?(path("a.rb"))
    @workspace.confirm_workspace_edit({"documentChanges" => [create("b.rb")]})
    assert_equal false, future.await["applied"]
  end

  def test_created_children_follow_later_directory_renames
    Dir.mkdir(path("old"))
    result = apply(create("old/new.rb"), text("old/new.rb", "draft"), rename("old", "new"), text("new/new.rb", "!", column: 5, version: 1))
    assert result["applied"], result.inspect
    assert_equal "draft!", @workspace.buffers.fetch(path("new/new.rb")).text
    assert_equal "", File.read(path("new/new.rb"))
    refute File.exist?(path("old"))
  end

  def test_directory_creation_and_delete_after_rename_are_ordered
    mkdir = create("old").merge("uri" => uri("old") + "/")
    result = apply(mkdir, create("old/new.rb"), rename("old", "new"), delete("new", recursive: true))
    assert result["applied"], result.inspect
    refute File.exist?(path("old"))
    refute File.exist?(path("new"))
    assert File.file?(File.join(result.fetch("recoveryPaths").first, "new.rb"))
  end

  def test_changed_files_abort_before_writes_and_keep_preexisting_content
    File.write(path("a.rb"), "original")
    require "canopus/workspace/edit/plan"
    plan = Canopus::Workspace::Edit::Plan.new(@workspace, {"documentChanges" => [rename("a.rb", "b.rb")]})
    File.write(path("a.rb"), "external writer")
    result = plan.apply
    refute result["applied"]
    assert_includes result["failureReason"], "changed"
    assert_equal "external writer", File.read(path("a.rb"))
    refute File.exist?(path("b.rb"))
  end

  def test_confirmation_resolves_request_and_only_runs_code_action_command_after_success
    window = Zaniah::Platform.open_window(backend: :headless, width: 300, height: 200)
    controller = Canopus::Controller.new(@workspace, window)
    future = Canopus::LSP::Future.new(nil)
    @workspace.confirm_workspace_edit({"documentChanges" => [create("cancelled.rb")]}, response: future)
    controller.input(Zaniah::Input::KeyDown.new("enter", false))
    assert_equal false, future.await["applied"]
    refute File.exist?(path("cancelled.rb"))

    accepted = Canopus::LSP::Future.new(nil)
    @workspace.confirm_workspace_edit({"documentChanges" => [create("accepted.rb")]}, response: accepted)
    controller.input(Zaniah::Input::KeyDown.new("up", false))
    controller.input(Zaniah::Input::KeyDown.new("enter", false))
    assert_equal true, accepted.await["applied"]
    assert File.exist?(path("accepted.rb"))

    commands = []
    client = Object.new
    client.define_singleton_method(:execute_command) { |command, **args| commands << [command, args] }
    item = {"title" => "Create Ruby file", "edit" => {"documentChanges" => [create("created.rb")]}, "command" => {"command" => "after.create"}}
    @workspace.accept_language_result({kind: :code_actions, items: [item], client: client}, 0)
    assert_equal :workspace_edit, @workspace.palette[:kind]
    assert_empty commands
    controller.input(Zaniah::Input::KeyDown.new("up", false))
    controller.input(Zaniah::Input::KeyDown.new("enter", false))
    assert File.exist?(path("created.rb"))
    assert_equal [["after.create", {arguments: []}]], commands
    assert_nil @workspace.palette
  ensure
    window&.on_close { true }
    window&.close
  end

  def test_overwrite_then_io_failure_restores_original_and_keeps_new_file_recoverable
    File.write(path("a.rb"), "original")
    require "canopus/workspace/edit/plan"
    plan = Canopus::Workspace::Edit::Plan.new(@workspace, {"documentChanges" => [create("a.rb", overwrite: true), create("fail.rb")]})
    plan.singleton_class.prepend(Module.new do
      def execute_resource(operation)
        raise IOError, "injected failure" if operation[:path].end_with?("fail.rb")
        super
      end
    end)
    result = plan.apply
    refute result["applied"]
    assert_equal "original", File.read(path("a.rb"))
    assert_equal 1, result["recoveryPaths"].length
    assert_equal "", File.read(result["recoveryPaths"].first)
    assert_includes result["failureReason"], path(".canopus/trash")
  end

  def test_bounds_protected_paths_and_ancestor_moves_fail_before_writing
    require "canopus/workspace/edit/plan"
    assert_raises(Canopus::Error) { apply(*Array.new(10_001) { delete("missing", ignoreIfNotExists: true) }) }
    assert_raises(Canopus::Error) { apply(create("x" * 16_384)) }
    assert_raises(Canopus::Error) { apply(create(".GIT")) }
    Dir.mkdir(path("outer"))
    Dir.mkdir(path("outer/inner"))
    assert_raises(Canopus::Error) { apply(rename("outer/inner", "outer", overwrite: true)) }
    assert File.directory?(path("outer/inner"))
    refute File.exist?(path(".canopus"))
  end

  def test_backup_supports_long_filenames_without_overwriting_or_truncating_content
    name = "a" * 240 + ".rb"
    File.write(path(name), "full contents")
    result = apply(delete(name))
    assert result["applied"], result.inspect
    assert_equal "full contents", File.read(result.fetch("recoveryPaths").first)
  end

  def test_unicode_and_reserved_characters_round_trip_through_resource_uris
    result = apply(create("日本 😀.rb"), rename("日本 😀.rb", "changed # %.rb"), text("changed # %.rb", "body"))
    assert result["applied"], result.inspect
    assert File.file?(path("changed # %.rb"))
    assert_equal "body", @workspace.buffers.fetch(path("changed # %.rb")).text
  end
end

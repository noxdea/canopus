# frozen_string_literal: true
require_relative "test_helper"

class GitHunkViewTest < Minitest::Test
  Repository = Struct.new(:root, :before) do
    def head = "fixture"
    def branch = "main"
    def status = []
    def git_dir = File.join(root, ".git")
    def blob(path, **) = path == "example.rb" ? before.dup : nil
  end

  def setup
    @directory = Dir.mktmpdir("canopus-hunk-")
    File.binwrite(File.join(@directory, "example.rb"), "first\nchanged\nlast\n")
    @workspace = Canopus::Workspace.new(root: @directory)
    @repository = Repository.new(@workspace.root, "first\noriginal\nlast\n")
    @workspace.instance_variable_set(:@git, @repository)
    @editor = @workspace.open("example.rb")
    @editor.select(6)
  end

  def teardown
    @workspace.close
    @window&.close
    FileUtils.remove_entry(@directory)
  end

  def test_toggle_preview_and_discard_after_edit_or_head_invalidation
    original = @editor.buffer.text
    assert_instance_of Porrima::Diff, @workspace.git_diff(async: false)
    assert_equal [{new_line: 2, kind: :modified, count: 1}], @workspace.git_gutter_marks.map(&:to_h)
    @workspace.call("git.toggle_hunk")
    map = @editor.display_map
    assert map.block_map.blocks.values.any? { |block| block.kind == :git_diff }, @workspace.message
    lines = (0...map.row_count).map { |row| map.row(row).text }
    assert_includes lines, "-original"
    assert_includes lines, "+changed"
    assert_equal original, @editor.buffer.text
    refute @editor.buffer.dirty?
    @workspace.call("git.toggle_hunk")
    assert_equal @editor.buffer.line_count, map.row_count
    @workspace.call("git.toggle_hunk")
    @editor.insert_text("x")
    assert_empty map.block_map.blocks
    @editor.undo
    assert_equal original, @editor.buffer.text
    @workspace.call("git.toggle_hunk")
    @workspace.invalidate_git
    assert_empty map.block_map.blocks
  end

  def test_gutter_click_routes_to_the_matching_editor_without_editing_it
    @workspace.git_hunks(async: false)
    @window = Zaniah::Platform::Headless::Window.new(width: 640, height: 240)
    controller = Canopus::Controller.new(@workspace, @window)
    controller.tick
    bounds, action = controller.view.regions.find { |_, target| target.first == :git_hunk }
    assert_equal [:git_hunk, @editor, 1], action
    point = Zaniah::Point.new(bounds.x + 6, bounds.y + 1)
    assert_equal action, controller.view.hit(point)
    controller.input(Zaniah::Input::MouseDown.new(point, :left, [], 1))
    assert @editor.display_map.block_map.blocks.values.any? { |block| block.kind == :git_diff }
    refute @editor.buffer.dirty?
  end

  def test_deleted_last_line_and_large_hunk_previews_are_bounded
    @repository.before = "first\nchanged\nlast\nremoved\n"
    assert @workspace.toggle_git_hunk(row: 2)
    assert @editor.display_map.block_map.blocks.values.first.text.include?("-removed")
    @workspace.invalidate_git
    @repository.before = ("old " + "日" * 1_000 + "\n") * 250
    assert @workspace.toggle_git_hunk(row: 0)
    block = @editor.display_map.block_map.blocks.values.first
    assert_operator block.text.lines.length, :<=, 202
    assert block.text.valid_encoding?
    assert_includes block.text, "more lines"
  end

  def test_historical_blob_encodings_use_the_same_decoder_as_files
    [[Encoding::Windows_31J, "".b], [Encoding::UTF_16LE, "\xff\xfe".b], [Encoding::UTF_8, "\xef\xbb\xbf".b]].each do |encoding, bom|
      source = "first\n日本\nlast\n"
      @repository.before = (bom + source.encode(encoding).b).freeze
      @workspace.invalidate_git
      hunk = @workspace.git_hunks(async: false).first
      assert_equal "日本\n", hunk.old_text
      @workspace.toggle_git_hunk(row: 1)
      assert_includes @editor.display_map.block_map.blocks.values.first.text, "-日本"
      @workspace.revert_current_hunk
      assert_equal source, @editor.buffer.text
      @editor.undo
      assert_equal "first\nchanged\nlast\n", @editor.buffer.text
    end
  end

  def test_save_as_invalidates_the_path_specific_diff_and_expanded_preview
    @workspace.toggle_git_hunk
    @workspace.save_buffer(path: File.join(@directory, "new.rb"))
    assert_empty @editor.display_map.block_map.blocks
    hunk = @workspace.git_hunks(async: false).first
    assert_empty hunk.old_text
    @workspace.revert_current_hunk
    assert_empty @editor.buffer.text
    @editor.undo
    assert_equal "first\nchanged\nlast\n", @editor.buffer.text
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class GitPartialStagingTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-git-partial-")
    git("init", "-q")
    git("config", "user.name", "Canopus Test")
    git("config", "user.email", "canopus@example.invalid")
    write("mixed.txt", (1..12).map { |line| "base #{line}\n" }.join)
    write("delete.txt", "one\ntwo\n")
    write("projection.txt", "a\nb\nc\nd\n")
    write("addition.txt", "a\nd\n")
    write("executable.sh", "one\ntwo\nthree\n")
    File.chmod(0o755, File.join(@root, "executable.sh"))
    git("add", ".")
    git("commit", "-qm", "initial")
    @workspace = Canopus::Workspace.new(root: @root)
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root)
  end

  def test_stages_and_unstages_one_hunk_against_external_git
    changed = lines("mixed.txt")
    changed[1] = "worktree 2\n"
    changed[9] = "worktree 10\n"
    write("mixed.txt", changed.join)

    diff = show(:unstaged, "mixed.txt")
    @workspace.stage_git_hunk(0, buffer: diff.buffer)
    assert_includes git("diff", "--cached", "--", "mixed.txt"), "+worktree 2"
    refute_includes git("diff", "--cached", "--", "mixed.txt"), "+worktree 10"
    assert_includes git("diff", "--", "mixed.txt"), "+worktree 10"

    staged = show(:staged, "mixed.txt")
    @workspace.unstage_git_hunk(0, buffer: staged.buffer)
    assert_empty git("diff", "--cached", "--", "mixed.txt")
    assert_includes git("status", "--porcelain=v1"), " M mixed.txt"
  end

  def test_modified_pair_is_one_line_unit_and_ignores_unsaved_buffer_text
    write("mixed.txt", "worktree 1\nworktree 2\n" + lines("mixed.txt").drop(2).join)
    source = @workspace.open("mixed.txt")
    source.insert_text("unsaved ", auto_indent: false)
    diff = show(:unstaged, "mixed.txt")

    @workspace.stage_git_line(1, buffer: diff.buffer)

    staged = git("show", ":mixed.txt")
    assert_equal "base 1\nworktree 2\n", staged.lines.first(2).join
    refute_includes staged, "unsaved"
    assert_includes git("diff", "--", "mixed.txt"), "+worktree 1"
  end

  def test_add_delete_no_final_newline_and_empty_file_keep_distinct_existence
    write("added.txt", "added")
    File.unlink(File.join(@root, "delete.txt"))
    write("empty.txt", "")

    added = show(:untracked, "added.txt")
    @workspace.stage_git_line(0, buffer: added.buffer)
    assert_equal "added", git("show", ":added.txt")

    deleted = show(:unstaged, "delete.txt")
    @workspace.stage_git_hunk(0, buffer: deleted.buffer)
    assert_includes git("diff", "--cached", "--name-status"), "D\tdelete.txt"

    empty = show(:untracked, "empty.txt")
    @workspace.stage_git_hunk(0, buffer: empty.buffer)
    assert_equal "", git("show", ":empty.txt")
    assert_includes git("diff", "--cached", "--name-status"), "A\tempty.txt"
  end

  def test_line_projection_places_unpaired_insertions_and_deletions_correctly
    write("addition.txt", "a\nx\ny\nd\n")
    added = show(:unstaged, "addition.txt")
    @workspace.stage_git_line(1, buffer: added.buffer)
    assert_equal "a\ny\nd\n", git("show", ":addition.txt")

    write("projection.txt", "a\nx\nd\n")
    git("add", "projection.txt")
    @workspace.invalidate_git
    @workspace.refresh_scm
    removed = show(:staged, "projection.txt")
    @workspace.unstage_git_line(1, buffer: removed.buffer)
    assert_equal "a\nx\nc\nd\n", git("show", ":projection.txt")
  end

  def test_unstages_one_modified_line_without_changing_the_worktree
    changed = lines("mixed.txt")
    changed[1] = "staged 2\n"
    changed[2] = "staged 3\n"
    write("mixed.txt", changed.join)
    git("add", "mixed.txt")

    diff = show(:staged, "mixed.txt")
    @workspace.unstage_git_line(1, buffer: diff.buffer)

    index = git("show", ":mixed.txt")
    assert_equal "staged 2\nbase 3\n", index.lines[1, 2].join
    assert_equal changed.join, File.binread(File.join(@root, "mixed.txt"))
    assert_includes git("diff", "--cached", "--", "mixed.txt"), "+staged 2"
    refute_includes git("diff", "--cached", "--", "mixed.txt"), "+staged 3"
    assert_includes git("diff", "--", "mixed.txt"), "+staged 3"
  end

  def test_mixed_path_uses_the_index_baseline_and_preserves_mode
    original_mode = git("ls-files", "--stage", "executable.sh").split.first
    staged = lines("executable.sh")
    staged[0] = "already staged\n"
    write("executable.sh", staged.join)
    File.chmod(0o755, File.join(@root, "executable.sh"))
    git("add", "executable.sh")
    worktree = staged.dup
    worktree[1] = "selected\n"
    worktree[2] = "left unstaged\n"
    write("executable.sh", worktree.join)
    File.chmod(0o755, File.join(@root, "executable.sh"))

    diff = show(:unstaged, "executable.sh")
    @workspace.stage_git_line(0, buffer: diff.buffer)

    assert_equal "already staged\nselected\nthree\n", git("show", ":executable.sh")
    assert_equal original_mode, git("ls-files", "--stage", "executable.sh").split.first
    assert_includes git("diff", "--", "executable.sh"), "+left unstaged"
  end

  def test_partial_staging_preserves_index_mode_when_core_filemode_is_false
    git("update-index", "--chmod=+x", "executable.sh")
    git("commit", "--allow-empty", "-qm", "mark executable")
    git("config", "core.filemode", "false")
    write("executable.sh", "changed\ntwo\nthree\n")
    @workspace.invalidate_git
    @workspace.refresh_scm

    diff = show(:unstaged, "executable.sh")
    @workspace.stage_git_line(0, buffer: diff.buffer)

    assert_equal "100755", git("ls-files", "--stage", "executable.sh").split.first
    assert_equal "changed\ntwo\nthree\n", git("show", ":executable.sh")
  end

  def test_rejects_stale_index_worktree_and_head_without_touching_current_index
    write("mixed.txt", lines("mixed.txt").tap { |value| value[1] = "changed\n" }.join)

    diff = show(:unstaged, "mixed.txt")
    git("add", "mixed.txt")
    index = File.binread(File.join(@root, ".git", "index"))
    error = assert_raises(Canopus::Error) { @workspace.stage_git_hunk(0, buffer: diff.buffer) }
    assert_match(/stale/, error.message)
    assert_equal index, File.binread(File.join(@root, ".git", "index"))

    git("reset", "-q", "HEAD", "mixed.txt")
    diff = show(:unstaged, "mixed.txt")
    write("mixed.txt", "external\n")
    index = File.binread(File.join(@root, ".git", "index"))
    assert_raises(Canopus::Error) { @workspace.stage_git_hunk(0, buffer: diff.buffer) }
    assert_equal index, File.binread(File.join(@root, ".git", "index"))

    write("mixed.txt", "head candidate\n")
    diff = show(:unstaged, "mixed.txt")
    git("commit", "--allow-empty", "-qm", "advance head")
    index = File.binread(File.join(@root, ".git", "index"))
    assert_raises(Canopus::Error) { @workspace.stage_git_hunk(0, buffer: diff.buffer) }
    assert_equal index, File.binread(File.join(@root, ".git", "index"))
  end

  def test_diff_rows_are_clickable_and_commands_are_registered
    write("mixed.txt", lines("mixed.txt").tap { |value| value[1] = "changed\n" }.join)
    diff = show(:unstaged, "mixed.txt")
    items = @workspace.scm_diff_decorations(diff.buffer, 0...diff.buffer.line_count)

    assert items.any? { |item| item.content == "Stage hunk" && item.on_click }
    line = items.find { |item| item.content == "Stage line" && item.on_click }
    assert line
    %w[git.stage_hunk git.unstage_hunk git.stage_line git.unstage_line].each do |command|
      assert @workspace.commands.resolve(command)
    end
    line.on_click.call(diff, line.row)
    assert_includes git("diff", "--cached", "--", "mixed.txt"), "+changed"
  end

  def test_control_characters_in_paths_do_not_shift_diff_actions
    skip "Windows forbids newlines in file names" if Gem.win_platform?

    path = "odd\nname.txt"
    write(path, "base\n")
    git("add", path)
    git("commit", "-qm", "add unusual path")
    write(path, "changed\n")
    @workspace.invalidate_git
    @workspace.refresh_scm

    diff = show(:unstaged, path)
    actions = @workspace.scm_diff_decorations(diff.buffer, 0...diff.buffer.line_count)
    changed_rows = diff.buffer.text.lines.each_index.select do |row|
      line = diff.buffer.text.lines[row]
      (line.start_with?("+", "-")) && !line.start_with?("+++", "---")
    end

    assert_includes diff.buffer.text, "odd\\nname.txt"
    assert_equal changed_rows, actions.select { |item| item.content == "Stage line" }.map(&:row)
  end

  def test_invalid_utf8_paths_are_escaped_for_display
    path = "odd-\xff.txt".b.force_encoding(Encoding::UTF_8)

    assert_equal 'odd-\xFF.txt', @workspace.send(:scm_display_path, path)
  end

  def test_non_roundtrip_encoding_is_not_partially_staged
    path = "noncanonical.txt"
    original = "one\n".b + "\xFA\x4A\n".b + "three\n".b
    write(path, original)
    git("add", path)
    git("commit", "-qm", "add noncanonical encoding")
    write(path, original.sub("one", "changed"))
    @workspace.invalidate_git
    @workspace.refresh_scm

    diff = show(:unstaged, path)

    assert_equal "Binary file changed: #{path}\n", diff.buffer.text
    assert_raises(Canopus::Error) { @workspace.stage_git_hunk(0, buffer: diff.buffer) }
    assert_equal original, git("show", ":#{path}")
  end

  def test_empty_file_diff_describes_metadata_and_keeps_hunk_clickable
    write("empty-visible.txt", "")
    @workspace.invalidate_git
    @workspace.refresh_scm

    diff = show(:untracked, "empty-visible.txt")
    actions = @workspace.scm_diff_decorations(diff.buffer, 0...diff.buffer.line_count)

    assert_includes diff.buffer.text, "new empty file (mode 100644)"
    assert_equal [2, 3], actions.select { |item| item.content == "Stage hunk" }.map(&:row)
  end

  private

  def show(kind, path)
    @workspace.show_scm_diff(scm_change(kind, path))
  end

  def scm_change(kind, path)
    groups = @workspace.scm_tree.instance_variable_get(:@source)
    groups.find { |node| node.fetch(:id).last == kind }.fetch(:children)
      .find { |node| node.dig(:value, :path) == path }.fetch(:value)
  end

  def lines(path) = File.binread(File.join(@root, path)).lines
  def write(path, content) = File.binwrite(File.join(@root, path), content)

  def git(*arguments)
    output, error, status = Open3.capture3("git", "-C", @root, *arguments, binmode: true)
    raise error unless status.success?
    output
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class GitStagingTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-git-staging-")
    git("init", "-q")
    git("config", "user.name", "Canopus Test")
    git("config", "user.email", "canopus@example.invalid")
    %w[tracked.txt mixed.txt removed.txt].each { |path| File.binwrite(File.join(@root, path), "base\n") }
    git("add", ".")
    git("commit", "-qm", "initial")

    File.binwrite(File.join(@root, "tracked.txt"), "changed\n")
    File.binwrite(File.join(@root, "mixed.txt"), "staged\n")
    git("add", "mixed.txt")
    File.binwrite(File.join(@root, "mixed.txt"), "worktree\n")
    File.binwrite(File.join(@root, "binary.dat"), "\0\xffraw\r\n".b)
    File.unlink(File.join(@root, "removed.txt"))
    @workspace = Canopus::Workspace.new(root: @root)
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root)
  end

  def test_panel_groups_each_status_column_and_keeps_mixed_paths_twice
    tree = @workspace.scm_tree
    groups = tree.instance_variable_get(:@source).to_h { |node| [node.fetch(:id).last, node.fetch(:children)] }

    assert_equal %w[mixed.txt], groups.fetch(:staged).map { |node| node.dig(:value, :path) }
    assert_equal %w[mixed.txt removed.txt tracked.txt], groups.fetch(:unstaged).map { |node| node.dig(:value, :path) }
    assert_equal %w[binary.dat], groups.fetch(:untracked).map { |node| node.dig(:value, :path) }
    assert_equal 4, @workspace.panels.fetch("scm").badge
    assert @workspace.commands.resolve("git.stage")
    assert @workspace.commands.resolve("git.unstage")

    @workspace.call("panel.scm")
    assert @workspace.panels.visible?("scm")
  end

  def test_selected_diff_uses_index_and_saved_worktree_not_the_open_buffer
    change = scm_change(:unstaged, "mixed.txt")
    editor = @workspace.open("mixed.txt")
    editor.insert_text("unsaved ", auto_indent: false)

    document = @workspace.show_scm_diff(change)

    assert_instance_of Canopus::Editor, document
    assert_includes @workspace.editor.buffer.text, "-staged"
    assert_includes @workspace.editor.buffer.text, "+worktree"
    refute_includes @workspace.editor.buffer.text, "unsaved"
  end

  def test_stage_writes_raw_disk_bytes_and_deletions_for_external_git
    binary = scm_change(:untracked, "binary.dat")
    @workspace.send(:select_scm_change, binary)
    @workspace.call("git.stage")
    @workspace.stage_git_file("removed.txt")

    assert_equal "\0\xffraw\r\n".b, git("show", ":binary.dat").b
    assert_includes git("diff", "--cached", "--name-status"), "D\tremoved.txt"
    assert_equal "base\n", git("show", "HEAD:removed.txt")
  end

  def test_unstage_restores_head_and_turns_a_new_add_back_into_untracked
    @workspace.unstage_git_file("mixed.txt")
    assert_equal "base\n", git("show", ":mixed.txt")
    assert_equal "worktree\n", File.binread(File.join(@root, "mixed.txt"))
    assert_includes git("status", "--porcelain=v1"), " M mixed.txt"

    @workspace.stage_git_file("binary.dat")
    @workspace.unstage_git_file("binary.dat")
    assert_includes git("status", "--porcelain=v1"), "?? binary.dat"
  end

  def test_stage_updates_an_initialized_submodule_gitlink
    submodule, = create_submodule
    File.binwrite(File.join(submodule, "dependency.txt"), "two\n")
    git_in(submodule, "add", "dependency.txt")
    git_in(submodule, "commit", "-qm", "update")
    nested_head = git_in(submodule, "rev-parse", "HEAD").strip

    @workspace.stage_git_file("vendor/dependency")

    assert_equal nested_head, git("ls-files", "--stage", "vendor/dependency").split[1]
    assert_includes git("diff", "--cached", "--name-only"), "vendor/dependency"
  end

  def test_submodule_diff_compares_gitlink_oids_without_reading_them_as_blobs
    submodule, initial_head = create_submodule
    File.binwrite(File.join(submodule, "dependency.txt"), "two\n")
    git_in(submodule, "add", "dependency.txt")
    git_in(submodule, "commit", "-qm", "update")
    nested_head = git_in(submodule, "rev-parse", "HEAD").strip

    @workspace.show_scm_diff(scm_change(:unstaged, "vendor/dependency"))

    assert_includes @workspace.editor.buffer.text, "-Subproject commit #{initial_head}"
    assert_includes @workspace.editor.buffer.text, "+Subproject commit #{nested_head}"

    @workspace.stage_git_file("vendor/dependency")
    @workspace.show_scm_diff(scm_change(:staged, "vendor/dependency"))
    assert_includes @workspace.editor.buffer.text, "-Subproject commit #{initial_head}"
    assert_includes @workspace.editor.buffer.text, "+Subproject commit #{nested_head}"
  end

  def test_uninitialized_submodule_diff_is_safe_and_stage_leaves_index_unchanged
    submodule, = create_submodule
    File.rename(File.join(submodule, ".git"), File.join(submodule, ".git-disabled"))

    @workspace.show_scm_diff(scm_change(:unstaged, "vendor/dependency"))
    assert_includes @workspace.editor.buffer.text, "+Submodule is not initialized"
    index_before = File.binread(File.join(@root, ".git", "index"))

    error = assert_raises(Canopus::Error) { @workspace.stage_git_file("vendor/dependency") }

    assert_match(/not initialized/, error.message)
    assert_equal index_before, File.binread(File.join(@root, ".git", "index"))
  end

  def test_stale_index_error_is_preserved_and_status_is_reloaded
    repository = @workspace.git
    stale = repository.index
    stale.define_singleton_method(:write) { raise Thuban::RefLockError, "Git index changed since it was read" }
    calls = 0
    repository.define_singleton_method(:index) do
      calls += 1
      calls == 1 ? stale : Thuban::Repository.instance_method(:index).bind(self).call
    end

    error = assert_raises(Thuban::RefLockError) { @workspace.stage_git_file("tracked.txt") }

    assert_match(/index changed/, error.message)
    assert_equal " M", @workspace.git_status.fetch("tracked.txt")
  end

  def test_full_staging_preserves_index_mode_when_core_filemode_is_false
    git("update-index", "--chmod=+x", "tracked.txt")
    git("commit", "-qm", "mark executable")
    git("config", "core.filemode", "false")
    File.binwrite(File.join(@root, "tracked.txt"), "restaged\n")
    @workspace.invalidate_git

    @workspace.stage_git_file("tracked.txt")

    assert_equal "100755", git("ls-files", "--stage", "tracked.txt").split.first
    assert_equal "restaged\n", git("show", ":tracked.txt")
  end

  private

  def scm_change(kind, path)
    groups = @workspace.scm_tree.instance_variable_get(:@source)
    groups.find { |node| node.fetch(:id).last == kind }.fetch(:children)
      .find { |node| node.dig(:value, :path) == path }.fetch(:value)
  end

  def create_submodule
    git("reset", "-q")
    submodule = File.join(@root, "vendor", "dependency")
    FileUtils.mkdir_p(submodule)
    git_in(submodule, "init", "-q")
    git_in(submodule, "config", "user.name", "Canopus Test")
    git_in(submodule, "config", "user.email", "canopus@example.invalid")
    File.binwrite(File.join(submodule, "dependency.txt"), "one\n")
    git_in(submodule, "add", "dependency.txt")
    git_in(submodule, "commit", "-qm", "initial")
    initial_head = git_in(submodule, "rev-parse", "HEAD").strip
    git("add", "vendor/dependency")
    git("commit", "-qm", "add submodule")
    [submodule, initial_head]
  end

  def git(*arguments)
    git_in(@root, *arguments)
  end

  def git_in(directory, *arguments)
    output, error, status = Open3.capture3("git", "-C", directory, *arguments, binmode: true)
    raise error unless status.success?
    output
  end
end

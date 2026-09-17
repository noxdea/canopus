# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class GitCommitTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-git-commit-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Original Author")
    git("config", "user.email", "original@example.invalid")
    write("tracked.txt", "initial\n")
    git("add", ".")
    git("commit", "-qm", "Initial")
    @initial = git("rev-parse", "HEAD").strip
    @workspace = Canopus::Workspace.new(root: @root)
  end

  def teardown
    @workspace&.close
    @window&.on_close { true }
    @window&.close unless @window&.closed?
    FileUtils.remove_entry(@root)
  end

  def test_commits_staged_changes_in_background_and_refreshes_scm_state
    write("tracked.txt", "committed\n")
    git("add", "tracked.txt")
    set_message("Update tracked file")

    commit_and_wait

    assert_equal "Update tracked file", git("show", "-s", "--format=%s", "HEAD").strip
    assert_equal "committed\n", git("show", "HEAD:tracked.txt")
    refute_equal @initial, git("rev-parse", "HEAD").strip
    assert_empty @workspace.git_status
    assert_empty commit_input.value
    assert_match(/Committed [0-9a-f]{8}/, @workspace.message)
  end

  def test_amend_preserves_original_author_and_uses_current_committer
    git("config", "user.name", "Current User")
    git("config", "user.email", "current@example.invalid")
    set_message("Reword initial commit")

    commit_and_wait(amend: true)

    assert_equal "Reword initial commit", git("show", "-s", "--format=%s", "HEAD").strip
    assert_equal "Original Author|original@example.invalid|Current User|current@example.invalid",
      git("show", "-s", "--format=%an|%ae|%cn|%ce", "HEAD").strip
    assert_empty git("show", "-s", "--format=%P", "HEAD").strip
  end

  def test_validation_rejects_blank_clean_detached_bare_and_duplicate_commits
    assert_raises(Canopus::Error) { @workspace.commit_git(" \n ") }
    assert_raises(Canopus::Error) { @workspace.commit_git("Nothing staged") }

    git("checkout", "--detach", "-q")
    @workspace.invalidate_git
    assert_raises(Canopus::Error) { @workspace.commit_git("Detached", amend: true) }

    git("checkout", "-q", "main")
    write("tracked.txt", "staged\n")
    git("add", "tracked.txt")
    @workspace.invalidate_git
    repository = @workspace.git
    original = repository.method(:commit!)
    started, release = Queue.new, Queue.new
    repository.define_singleton_method(:commit!) do |**options|
      started << true
      release.pop
      original.call(**options)
    end
    job = @workspace.commit_git("First")
    started.pop
    assert_raises(Canopus::Error) { @workspace.commit_git("Second") }
    release << true
    job.join
    @workspace.drain

    bare = Dir.mktmpdir("canopus-bare-")
    git_in(bare, "init", "--bare", "-q")
    workspace = Canopus::Workspace.new(root: bare)
    assert_raises(Canopus::Error) { workspace.commit_git("Bare") }
  ensure
    workspace&.close
    FileUtils.remove_entry(bare) if bare && File.exist?(bare)
  end

  def test_commit_does_not_save_or_change_an_unsaved_buffer
    write("tracked.txt", "staged on disk\n")
    git("add", "tracked.txt")
    editor = @workspace.open("tracked.txt")
    editor.insert_text("unsaved ", auto_indent: false)
    before = editor.buffer.text.dup

    commit_and_wait("Commit disk snapshot")

    assert_equal "staged on disk\n", git("show", "HEAD:tracked.txt")
    assert_equal "staged on disk\n", File.binread(File.join(@root, "tracked.txt"))
    assert_equal before, editor.buffer.text
    assert editor.buffer.dirty?
  end

  def test_stale_index_is_rejected_without_clearing_the_message
    write("tracked.txt", "staged\n")
    git("add", "tracked.txt")
    set_message("Keep this message")
    @workspace.git_status
    write("external.txt", "external\n")
    git("add", "external.txt")

    commit_and_wait

    assert_equal @initial, git("rev-parse", "HEAD").strip
    assert_equal "Keep this message", commit_input.value
    assert_match(/HEAD or index changed/, @workspace.message)
    assert_equal "A ", @workspace.git_status.fetch("external.txt")
  end

  def test_stale_head_is_rejected_without_overwriting_the_external_commit
    write("tracked.txt", "staged\n")
    git("add", "tracked.txt")
    set_message("Do not apply")
    @workspace.git_status
    git("commit", "-qm", "External commit")
    external = git("rev-parse", "HEAD").strip

    commit_and_wait

    assert_equal external, git("rev-parse", "HEAD").strip
    assert_equal "External commit", git("show", "-s", "--format=%s", "HEAD").strip
    assert_equal "Do not apply", commit_input.value
    assert_match(/HEAD or index changed/, @workspace.message)
  end

  def test_success_is_reported_when_the_post_commit_refresh_fails
    write("tracked.txt", "staged\n")
    git("add", "tracked.txt")
    set_message("Commit despite refresh failure")
    @workspace.git_status
    state = @workspace.instance_variable_get(:@git_state)
    state.define_singleton_method(:capture) { raise IOError, "refresh failed" }

    commit_and_wait

    assert_equal "Commit despite refresh failure", git("show", "-s", "--format=%s", "HEAD").strip
    assert_empty commit_input.value
    assert_match(/Committed [0-9a-f]{8}/, @workspace.message)
    assert_nil state.snapshot
  end

  def test_commit_holds_the_standard_index_lock_against_external_staging
    write("tracked.txt", "staged\n")
    git("add", "tracked.txt")
    @workspace.git_status
    repository = @workspace.git
    original = repository.method(:commit!)
    started, release = Queue.new, Queue.new
    repository.define_singleton_method(:commit!) do |**options|
      started << true
      release.pop
      original.call(**options)
    end
    job = @workspace.commit_git("Locked snapshot")
    started.pop
    write("external.txt", "external\n")

    _output, error, status = Open3.capture3("git", "-C", @root, "add", "external.txt", binmode: true)
    refute status.success?
    assert_match(/index\.lock/, error)
    release << true
    assert job.join(3), "Git commit timed out"
    @workspace.drain

    assert_equal "staged\n", git("show", "HEAD:tracked.txt")
    assert_raises(RuntimeError) { git("show", "HEAD:external.txt") }
    assert_includes git("status", "--porcelain=v1"), "?? external.txt"
  end

  def test_panel_uses_native_controls_and_shows_non_enforcing_column_guides
    panel = @workspace.scm_panel
    input, guide, controls, tree = panel.children

    assert_instance_of Zaniah::UI::TextArea, input
    assert_equal "Subject guide: 50 columns · Body guide: 72 columns", guide.text
    assert_instance_of Zaniah::UI::Checkbox, controls.children.first
    assert_instance_of Zaniah::UI::Button, controls.children.last
    assert_same @workspace.scm_tree, tree
    assert @workspace.commands.resolve("git.commit")
  end

  def test_focused_commit_input_receives_key_text_and_composition_without_editing_document
    @window = Zaniah::Platform.open_window(backend: :headless, width: 900, height: 500)
    Canopus::Controller.new(@workspace, @window)
    @workspace.panels.show("scm")
    @window.tick
    input = commit_input
    @window.dispatcher.focus(input.focus_handle)
    document = @workspace.editor

    @window.input(Zaniah::Input::KeyDown.new("a", false))
    @window.input(Zaniah::Input::TextInput.new("draft"))
    @window.input(Zaniah::Input::KeyDown.new("backspace", false))
    @window.input(Zaniah::Input::Composition.new("に", [0, 0]))

    assert_equal "draf", input.value
    assert_equal "に", input.buffer.composition.text
    assert_empty document.buffer.text
    assert_nil document.composition
  end

  def test_clicking_the_editor_returns_input_focus_from_the_commit_message
    @window = Zaniah::Platform.open_window(backend: :headless, width: 900, height: 500)
    controller = Canopus::Controller.new(@workspace, @window)
    @workspace.panels.show("scm")
    @window.tick
    input = commit_input
    @window.dispatcher.focus(input.focus_handle)
    editor = @workspace.editor
    region = controller.view.regions.find { |_, action| action.first == :editor }.first
    point = Zaniah::Point.new(region.x + 1, region.y + 1)

    @window.input(Zaniah::Input::MouseDown.new(point, :left, [], 1))
    @window.input(Zaniah::Input::MouseUp.new(point, :left, []))
    @window.input(Zaniah::Input::TextInput.new("X"))

    assert_nil @window.dispatcher.focused
    assert_empty input.value
    assert_equal "X", editor.buffer.text
  end

  def test_focused_commit_button_handles_enter_without_editing_the_document
    @window = Zaniah::Platform.open_window(backend: :headless, width: 900, height: 500)
    Canopus::Controller.new(@workspace, @window)
    @workspace.panels.show("scm")
    @window.tick
    button = @workspace.instance_variable_get(:@scm_commit_button)
    @window.dispatcher.focus(button.focus_handle)
    document = @workspace.editor

    @window.input(Zaniah::Input::KeyDown.new("enter", false))

    assert_empty document.buffer.text
    assert_equal "Enter a commit message", @workspace.message
  end

  def test_close_waits_for_the_commit_job
    write("tracked.txt", "staged\n")
    git("add", "tracked.txt")
    repository = @workspace.git
    original = repository.method(:commit!)
    started, release = Queue.new, Queue.new
    repository.define_singleton_method(:commit!) do |**options|
      started << true
      release.pop
      original.call(**options)
    end
    job = @workspace.commit_git("Wait for commit")
    started.pop

    closer = Thread.new { @workspace.close }
    refute closer.join(0.05), "close returned before the Git commit finished"
    release << true
    assert closer.join(3), "workspace close did not join the Git commit"
    closer.value
    refute_predicate job, :alive?
    @workspace = nil
  end

  private

  def set_message(message)
    @workspace.instance_variable_set(:@scm_commit_message, message.dup)
    commit_input
  end

  def commit_input = @workspace.scm_panel.children.first

  def commit_and_wait(message = nil, amend: nil)
    job = @workspace.commit_git(message, amend: amend)
    assert job.join(3), "Git commit timed out"
    @workspace.drain
    job
  end

  def write(path, content) = File.binwrite(File.join(@root, path), content)
  def git(*arguments) = git_in(@root, *arguments)

  def git_in(directory, *arguments)
    output, error, status = Open3.capture3("git", "-C", directory, *arguments, binmode: true)
    raise error unless status.success?
    output
  end
end

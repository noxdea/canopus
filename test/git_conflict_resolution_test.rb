# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "timeout"

class GitConflictResolutionTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-git-conflicts-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Canopus Test")
    git("config", "user.email", "canopus@example.invalid")
    write("seed.txt", "seed\n")
    git("add", ".")
    git("commit", "-qm", "Initial")
    @workspace = Canopus::Workspace.new(root: @root)
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root)
  end

  def test_three_panes_resolve_multiple_regions_and_advance_to_the_next_file
    install_conflict("alpha.txt", base: "top\none\nmiddle\ntwo\nbottom\n",
      ours: "top\nours-one\nmiddle\nours-two\nbottom\n",
      theirs: "top\ntheirs-one\nmiddle\ntheirs-two\nbottom\n")
    install_conflict("beta.txt", base: "base\n", ours: "ours\n", theirs: "theirs\n")

    editor = @workspace.show_git_conflicts("alpha.txt")
    assert_equal 3, @workspace.panes.length
    views = @workspace.panes.map { |pane| pane.active.buffer.instance_variable_get(:@git_conflict_view) }
    assert_equal %i[base ours theirs], views.map(&:role)
    assert views.all? { |view| view.region.is_a?(Porrima::Merge::Region) }
    assert_predicate views[0].session.buffers.fetch(:base), :read_only
    refute_predicate views[1].session.buffers.fetch(:ours), :read_only
    assert_predicate views[2].session.buffers.fetch(:theirs), :read_only
    decorations = @workspace.git_conflict_decorations(editor.buffer, 0...editor.buffer.line_count)
    assert decorations.any? { |item| item.kind == :line }
    assert_equal ["Use ours", "Use theirs", "Use both", "Use manual edit"],
      decorations.select { |item| item.kind == :block }.map(&:content)
    %w[git.conflicts git.conflict.ours git.conflict.theirs git.conflict.both git.conflict.manual].each do |command|
      assert @workspace.commands.resolve(command)
    end

    next_region = @workspace.resolve_git_conflict(:ours)
    assert_equal "ours-two\n", next_region.buffer.text
    next_region.buffer.edit([[0...next_region.buffer.rope.bytesize, "manual-two\n"]], kind: :typing)
    assert_equal "alpha.txt", @workspace.resolve_git_conflict(:manual)
    assert_equal "top\nours-one\nmiddle\nmanual-two\nbottom\n", git("show", ":alpha.txt")
    assert_equal "beta.txt", current_conflict.path
    assert_equal 3, @workspace.panes.length

    assert_equal "beta.txt", @workspace.resolve_git_conflict(:both)
    assert_empty @workspace.git.conflicts
    assert_equal "ours\ntheirs\n", git("show", ":beta.txt")
    assert_equal 1, @workspace.panes.length
  end

  def test_clean_text_binary_delete_and_mode_conflicts_fail_safe
    install_conflict("clean.txt", base: "base\n", ours: "same\n", theirs: "same\n")
    editor = @workspace.show_git_conflicts("clean.txt")
    assert_equal "same\n", editor.buffer.text
    assert_nil editor.buffer.instance_variable_get(:@git_conflict_view).region
    assert_equal "clean.txt", @workspace.resolve_git_conflict(:ours)
    assert_equal "same\n", git("show", ":clean.txt")

    install_conflict("binary.dat", base: "base\0".b, ours: "ours\0".b, theirs: "theirs\0".b)
    editor = @workspace.show_git_conflicts("binary.dat")
    assert_predicate editor.buffer, :read_only
    assert_match(/binary content unavailable/, editor.buffer.text)
    assert_raises(Canopus::Error) { @workspace.resolve_git_conflict(:both) }
    refute_empty git("ls-files", "-u", "--", "binary.dat")
    assert_equal "binary.dat", @workspace.resolve_git_conflict(:ours)
    assert_equal "ours\0".b, git("show", ":binary.dat").b

    install_conflict("deleted.txt", base: "base\n", ours: nil, theirs: "changed\n")
    assert_equal "", @workspace.show_git_conflicts("deleted.txt").buffer.text
    assert_equal "deleted.txt", @workspace.resolve_git_conflict(:ours)
    refute File.exist?(File.join(@root, "deleted.txt"))
    assert_empty git("ls-files", "--stage", "--", "deleted.txt")

    install_conflict("mode.txt", base: "base\n", ours: "ours\n", theirs: "theirs\n",
      ours_mode: 0o100644, theirs_mode: 0o100755)
    @workspace.show_git_conflicts("mode.txt")
    assert_raises(Canopus::Error) { @workspace.resolve_git_conflict(:both) }
    refute_empty git("ls-files", "-u", "--", "mode.txt")
    assert_equal "mode.txt", @workspace.resolve_git_conflict(:both, mode: 0o100644)
    assert_equal "100644", git("ls-files", "--stage", "--", "mode.txt").split.first
  end

  def test_fallback_allows_only_complete_sides
    install_conflict("encoding.txt", base: "x\n", ours: "\xC3\xA9\n".b, theirs: "\x82\xA0\n".b)
    editor = @workspace.show_git_conflicts("encoding.txt")
    before = File.binread(File.join(@root, ".git", "index"))

    assert_predicate editor.buffer, :read_only
    assert_equal ["Use ours", "Use theirs"],
      @workspace.git_conflict_decorations(editor.buffer, 0...editor.buffer.line_count)
        .select { |item| item.kind == :block }.map(&:content)
    assert_raises(Canopus::Error) { @workspace.resolve_git_conflict(:both) }
    assert_equal before, File.binread(File.join(@root, ".git", "index"))
    refute_empty git("ls-files", "-u", "--", "encoding.txt")
  end

  def test_oversized_conflict_is_rejected_before_decoding
    module_type = Canopus::Workspace::GitConflictResolution
    content = module_type::GitConflictContent.new("x" * (module_type::MERGE_MAX_BYTES + 1), nil, nil, nil, 0o100644)
    capture = module_type::GitConflictCapture.new(nil, {base: content, ours: content.with(raw: nil),
      theirs: content.with(raw: nil)}.freeze)

    prepared = Canopus::Buffer.stub(:decode_bytes, ->(*) { flunk "oversized content was decoded" }) do
      @workspace.send(:prepare_git_conflict, capture)
    end

    assert_match(/exceeds 1 MiB/, prepared.reason)
    assert_nil prepared.result
  end

  def test_clean_three_way_merge_keeps_non_overlapping_changes
    install_conflict("clean-merge.txt", base: "a\nb\nc\n", ours: "A\nb\nc\n", theirs: "a\nb\nC\n",
      ours_mode: 0o100644, theirs_mode: 0o100755)

    editor = @workspace.show_git_conflicts("clean-merge.txt")

    assert_equal "A\nb\nC\n", editor.buffer.text
    assert_equal "clean-merge.txt", @workspace.resolve_git_conflict(:ours)
    assert_equal "A\nb\nC\n", git("show", ":clean-merge.txt")
    assert_equal "100644", git("ls-files", "--stage", "--", "clean-merge.txt").split.first
  end

  def test_complete_side_and_manual_mode_are_not_lost_when_bytes_match
    install_conflict("same.txt", base: "base\n", ours: "same\n", theirs: "same\n",
      ours_mode: 0o100644, theirs_mode: 0o100755)
    @workspace.show_git_conflicts("same.txt")
    assert_equal "same.txt", @workspace.resolve_git_conflict(:theirs)
    assert_equal "100755", git("ls-files", "--stage", "--", "same.txt").split.first

    install_conflict("manual-mode.txt", base: "base\n", ours: "ours\n", theirs: "theirs\n")
    @workspace.show_git_conflicts("manual-mode.txt")
    assert_equal "manual-mode.txt", @workspace.resolve_git_conflict(:manual, content: "ours\n", mode: 0o100755)
    assert_equal "100755", git("ls-files", "--stage", "--", "manual-mode.txt").split.first
  end

  def test_stale_worktree_is_rejected_without_losing_the_resolution_view
    install_conflict("stale.txt", base: "base\n", ours: "ours\n", theirs: "theirs\n")
    editor = @workspace.show_git_conflicts("stale.txt")
    index = File.binread(File.join(@root, ".git", "index"))
    write("stale.txt", "external edit\n")

    assert_raises(Thuban::RefLockError) { @workspace.resolve_git_conflict(:ours) }
    assert_equal index, File.binread(File.join(@root, ".git", "index"))
    assert_equal "external edit\n", File.binread(File.join(@root, "stale.txt"))
    assert_equal editor.buffer, @workspace.panes[1].active.buffer
    refute_empty git("ls-files", "-u", "--", "stale.txt")
  end

  def test_next_conflict_recreates_a_closed_conflict_pane
    install_conflict("first.txt", base: "base\n", ours: "ours\n", theirs: "theirs\n")
    install_conflict("second.txt", base: "base\n", ours: "ours\n", theirs: "theirs\n")
    @workspace.show_git_conflicts("first.txt")
    @workspace.close_editor(@workspace.panes.last.active)

    assert_equal "first.txt", @workspace.resolve_git_conflict(:ours)

    assert_equal 3, @workspace.panes.length
    assert_equal %i[base ours theirs], @workspace.panes.map { |pane|
      pane.active.buffer.instance_variable_get(:@git_conflict_view)&.role
    }
    assert_equal "second.txt", current_conflict.path
  end

  def test_close_cancels_a_read_only_conflict_load
    install_conflict("slow.txt", base: "base\n", ours: "ours\n", theirs: "theirs\n")
    repository = @workspace.git
    original = repository.method(:conflicts)
    repository.define_singleton_method(:conflicts) { sleep 5; original.call }
    @workspace.window = Object.new.tap { |window| window.define_singleton_method(:request_frame) {} }
    @workspace.show_git_conflicts

    Timeout.timeout(1) { @workspace.close }
    @workspace = nil
  end

  def test_async_resolution_locks_the_manual_buffer_until_completion
    install_conflict("async.txt", base: "base\n", ours: "ours\n", theirs: "theirs\n")
    editor = @workspace.show_git_conflicts("async.txt")
    editor.buffer.edit([[0...editor.buffer.rope.bytesize, "chosen\n"]], kind: :typing)
    repository = @workspace.git
    original = repository.method(:resolve_conflict)
    started, release = Queue.new, Queue.new
    repository.define_singleton_method(:resolve_conflict) do |*arguments, **options|
      started << true
      release.pop
      original.call(*arguments, **options)
    end
    @workspace.window = Object.new.tap { |window| window.define_singleton_method(:request_frame) {} }

    job = @workspace.resolve_git_conflict(:manual)
    started.pop

    assert_predicate editor.buffer, :read_only
    assert_raises(Canopus::Error) { editor.buffer.edit([[editor.buffer.rope.bytesize...editor.buffer.rope.bytesize, "late\n"]]) }
    release << true
    assert job.join(3), "conflict resolution timed out"
    @workspace.drain
    assert_equal "chosen\n", git("show", ":async.txt")
  ensure
    release << true if release
    job&.join(3)
  end

  def test_failed_async_resolution_restores_manual_editing
    install_conflict("async-stale.txt", base: "base\n", ours: "ours\n", theirs: "theirs\n")
    editor = @workspace.show_git_conflicts("async-stale.txt")
    editor.buffer.edit([[0...editor.buffer.rope.bytesize, "chosen\n"]], kind: :typing)
    repository = @workspace.git
    original = repository.method(:resolve_conflict)
    started, release = Queue.new, Queue.new
    repository.define_singleton_method(:resolve_conflict) do |*arguments, **options|
      started << true
      release.pop
      original.call(*arguments, **options)
    end
    @workspace.window = Object.new.tap { |window| window.define_singleton_method(:request_frame) {} }
    job = @workspace.resolve_git_conflict(:manual)
    started.pop
    write("async-stale.txt", "external\n")
    release << true
    assert job.join(3), "conflict resolution timed out"

    @workspace.drain

    refute_predicate editor.buffer, :read_only
    assert_equal editor.buffer, @workspace.panes[1].active.buffer
    assert_match(/changed since it was read/, @workspace.message)
    refute_empty git("ls-files", "-u", "--", "async-stale.txt")
  ensure
    release << true if release
    job&.join(3)
  end

  private

  def current_conflict
    @workspace.panes[1].active.buffer.instance_variable_get(:@git_conflict_view).session.prepared.capture.conflict
  end

  def install_conflict(path, base:, ours:, theirs:, base_mode: 0o100644, ours_mode: 0o100644,
    theirs_mode: 0o100644)
    entries = [[1, base, base_mode], [2, ours, ours_mode], [3, theirs, theirs_mode]].filter_map do |stage, content, mode|
      next unless content
      oid = git_with_input("hash-object", "-w", "--stdin", input: content).strip
      "#{mode.to_s(8)} #{oid} #{stage}\t#{path}\n"
    end
    git_with_input("update-index", "--index-info", input: entries.join)
    worktree = if ours&.include?("\0") || theirs&.include?("\0")
      (ours || theirs).b
    else
      "<<<<<<< ours\n#{ours}=======\n#{theirs}>>>>>>> theirs\n"
    end
    write(path, worktree)
    @workspace.invalidate_git
  end

  def write(path, content)
    absolute = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, content)
  end

  def git(*arguments) = git_with_input(*arguments)

  def git_with_input(*arguments, input: "")
    output, error, status = Open3.capture3("git", "-C", @root, *arguments, stdin_data: input, binmode: true)
    raise error unless status.success?
    output
  end
end

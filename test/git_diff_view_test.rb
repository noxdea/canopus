# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "timeout"

class GitDiffViewTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-git-diff-view-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Canopus Test")
    git("config", "user.email", "canopus@example.invalid")
    write("example.txt", "hello old world\n")
    write("binary.dat", "\0old".b)
    write("utf16.txt", "\xFF\xFE".b + "old text\n".encode(Encoding::UTF_16LE).b)
    git("add", ".")
    git("commit", "-qm", "Initial")
    @initial = git("rev-parse", "HEAD").strip
    write("example.txt", "hello new world\n")
    write("binary.dat", "\0new".b)
    write("utf16.txt", "\xFF\xFE".b + "new text\n".encode(Encoding::UTF_16LE).b)
    git("add", ".")
    git("commit", "-qm", "Update words")
    @updated = git("rev-parse", "HEAD").strip
    write("example.txt", "hello newest world\n")
    @workspace = Canopus::Workspace.new(root: @root)
  end

  def teardown
    @workspace&.close
    @window&.on_close { true }
    @window&.close unless @window&.closed?
    FileUtils.remove_entry(@root)
  end

  def test_inline_words_toggle_to_side_by_side_and_release_the_old_buffer
    inline = @workspace.show_scm_diff(scm_change(:unstaged, "example.txt"))
    assert_includes inline.buffer.text, "-hello new world"
    assert_includes inline.buffer.text, "+hello newest world"
    assert_equal %w[new newest], highlighted_text(inline).sort
    count = @workspace.buffers.length

    side = @workspace.toggle_git_diff_mode(inline)

    assert_includes side.buffer.text, "│"
    assert_includes side.buffer.text, "hello new world"
    assert_includes side.buffer.text, "hello newest world"
    assert_equal %w[new newest], highlighted_text(side).sort
    assert_equal count, @workspace.buffers.length
    refute_includes @workspace.buffers.values, inline.buffer
    assert @workspace.scm_diff_decorations(side.buffer, 0...side.buffer.line_count)
      .any? { |item| item.content == "Stage line" }
  end

  def test_revision_comparison_and_file_history_palette
    diff = @workspace.compare_git_revisions(@initial, @updated, path: "example.txt")
    assert_includes diff.buffer.text, "example.txt@#{@initial}"
    assert_includes diff.buffer.text, "-hello old world"
    assert_includes diff.buffer.text, "+hello new world"

    history = @workspace.git_file_history("example.txt")
    assert_equal ["Update words", "Initial"], history.map(&:subject)
    write("unrelated.txt", "unrelated\n")
    git("add", "unrelated.txt")
    git("commit", "-qm", "Unrelated")
    assert_equal ["Update words"], @workspace.git_file_history("example.txt", limit: 1).map(&:subject)
    palette = @workspace.show_git_file_history
    assert_equal :git_file_history, palette[:kind]
    @workspace.palette_accept
    assert_nil @workspace.palette
    assert_includes @workspace.editor.buffer.text, "+hello new world"

    compare_palette = @workspace.show_git_revision_compare
    compare_palette[:query] << "#{@initial}..#{@updated}"
    compared = @workspace.palette_accept
    assert_includes compared.buffer.text, "example.txt@#{@initial}"

    invalid = Canopus::Workspace::GitDiffView::GitHistoryEntry.new("a" * 40, nil, "subject", "\xFF".b, 0, "example.txt")
    shown = @workspace.send(:install_git_history, "example.txt", [invalid])
    assert_predicate shown.fetch(:matches).first, :valid_encoding?
  end

  def test_binary_large_invalid_revision_and_unsafe_path_are_bounded
    binary = @workspace.compare_git_revisions(@initial, @updated, path: "binary.dat")
    assert_equal "Binary file changed: binary.dat\n", binary.buffer.text

    utf16 = @workspace.compare_git_revisions(@initial, @updated, path: "utf16.txt")
    assert_includes utf16.buffer.text, "-old text"
    assert_includes utf16.buffer.text, "+new text"

    source = @workspace.send(:build_git_diff_source, "example.txt", "a" * (10 << 20), "b", snapshot: Object.new)
    text, = @workspace.send(:materialize_git_diff, source, :inline)
    assert_match(/exceeds 10 MiB/, text)
    assert_nil source.snapshot

    lines = @workspace.send(:build_git_diff_source, "example.txt", "\n" * 100_001, "\n" * 100_000)
    assert_match(/exceeds 200,000 lines/, lines.unavailable)
    assert_nil lines.diff

    identical_text = "same\n" * 1_001
    identical = @workspace.send(:build_git_diff_source, "example.txt", identical_text, identical_text)
    assert_predicate identical.diff, :empty?
    assert_equal 0, identical.diff.stat.deletions
    assert_equal 0, identical.diff.stat.insertions

    content = Canopus::Workspace::GitStaging::SCMContent
    metadata_before = content.new(true, nil, identical_text, Encoding::UTF_8, "".b, 0o100644)
    metadata_after = content.new(true, nil, identical_text, Encoding::UTF_8, "".b, 0o100755)
    metadata_capture = [["example.txt", :unstaged, @updated, [].freeze, metadata_after, false].freeze,
      metadata_before, metadata_after, "example.txt", nil].freeze
    metadata_snapshot, metadata_text = @workspace.send(:materialize_scm_diff, metadata_capture)
    assert_predicate metadata_snapshot.diff, :empty?
    assert_includes metadata_text, "mode 100644 -> 100755"
    refute_match(/^[-+]same$/, metadata_text)

    before = content.new(true, nil, "a" * (6 << 20), Encoding::UTF_8, "".b, 0o100644)
    after = content.new(true, nil, "b" * (6 << 20), Encoding::UTF_8, "".b, 0o100644)
    capture = [["example.txt", :unstaged, @updated, [].freeze, after, false].freeze,
      before, after, "example.txt", nil].freeze
    Porrima.stub(:diff, ->(*) { flunk "oversized SCM content reached Porrima" }) do
      _snapshot, unavailable = @workspace.send(:materialize_scm_diff, capture)
      assert_match(/exceeds 10 MiB/, unavailable)
    end
    assert_raises(Canopus::Error) do
      @workspace.compare_git_revisions("missing", "HEAD", path: "example.txt")
    end
    assert_raises(Canopus::Error) do
      @workspace.compare_git_revisions(@initial, @updated, path: "../example.txt")
    end
    assert_raises(Canopus::Error) do
      @workspace.compare_git_revisions(@initial, @updated, path: "C:/example.txt")
    end
    assert_raises(Canopus::Error) do
      @workspace.compare_git_revisions("HEAD\nmain", @updated, path: "example.txt")
    end
    [".GIT/config"].each do |path|
      assert_raises(Canopus::Error, path) do
        @workspace.compare_git_revisions(@initial, @updated, path: path)
      end
    end
    Gem.stub(:win_platform?, true) do
      [".git./config", ".git /config", "GIT~1/config", "dir./file", "dir /file", "file:stream", "file?",
       "foo\\bar", "CON", "CONIN$", "CONOUT$", "CON .txt", "aux.txt", "AUX  .log", "COM1/data",
       "NUL.txt", "LPT0.txt", "LPT².log"].each do |path|
        assert_raises(Canopus::Error, path) do
          @workspace.compare_git_revisions(@initial, @updated, path: path)
        end
      end
    end
  end

  def test_side_by_side_keeps_the_separator_fixed_for_tabs_and_long_lines
    settings = @workspace.settings
    original = settings.method(:for_language)
    settings_calls = 0
    settings.define_singleton_method(:for_language) do |language|
      settings_calls += 1
      original.call(language)
    end
    before = "plain\n\told value\n#{'x' * 200} old\n"
    after = "plain\n\tnew value\n#{'x' * 200} new\n"
    source = @workspace.send(:build_git_diff_source, "example.txt", before, after)

    text, = @workspace.send(:materialize_git_diff, source, :side_by_side)
    left_columns = text.lines.drop(1).filter_map do |line|
      left, separator = line.split(" │ ", 2)
      next unless separator
      refute_includes left, "\t"
      Unicode::DisplayWidth.of(left, emoji: :rgi)
    end

    assert_equal [160], left_columns.uniq
    assert_includes text, "… │"
    assert_equal 1, settings_calls
  end

  def test_diff_headers_escape_unicode_line_separators_without_shifting_actions
    path = "odd\u2028name.txt"
    write(path, "base\n")
    git("add", path)
    git("commit", "-qm", "Add unusual path", "--", path)
    write(path, "changed\n")

    editor = @workspace.show_scm_diff(scm_change(:unstaged, path))
    refute_includes editor.buffer.text, path
    assert_includes editor.buffer.text, 'odd\u2028name.txt'
    actions = @workspace.scm_diff_decorations(editor.buffer, 0...editor.buffer.line_count)
      .select { |item| item.content == "Stage line" }

    refute_empty actions
    actions.each { |item| assert_match(/\A[-+]/, editor.buffer.line(item.row)) }
  end

  def test_changed_non_lf_line_separators_disable_unsafe_row_actions
    path = "unusual-lines.txt"
    write(path, "a\u2028old\nz\n")
    git("add", path)
    git("commit", "-qm", "Add unusual lines", "--", path)
    write(path, "a\u2028new\nz\n")
    change = scm_change(:unstaged, path)

    %i[inline side_by_side].each do |mode|
      editor = @workspace.show_scm_diff(change, mode: mode)
      assert_match(/uses unsupported line separators/, editor.buffer.text)
      assert_empty @workspace.scm_diff_decorations(editor.buffer, 0...editor.buffer.line_count)
    end
    bare_cr = @workspace.send(:build_git_diff_source, path, "old\rvalue", "new\rvalue")
    assert_match(/uses unsupported line separators/, bare_cr.unavailable)
  end

  def test_side_by_side_expands_both_tabs_and_marks_line_endings
    before = "\told value\r\n\tleft eof"
    after = "\tnew value\n\tright eof\n"
    source = @workspace.send(:build_git_diff_source, "example.txt", before, after)

    text, view = @workspace.send(:materialize_git_diff, source, :side_by_side)
    highlights = view.highlights.map { |item| text.byteslice(item.range) }

    refute_includes text, "\t"
    assert_includes text, "[CRLF]"
    assert_includes text, "[LF]"
    assert_includes text, "[no newline]"
    assert_includes highlights, "old"
    assert_includes highlights, "new"
    assert highlights.all?(&:valid_encoding?)
  end

  def test_history_follows_an_unambiguous_rename_and_stops_at_an_ambiguous_one
    write("rename-before.txt", "same\n")
    git("add", "rename-before.txt")
    git("commit", "-qm", "Add rename source")
    git("mv", "rename-before.txt", "rename-after.txt")
    git("commit", "-qm", "Rename source")

    assert_equal ["Rename source", "Add rename source"],
      @workspace.git_file_history("rename-after.txt").map(&:subject)
    palette = @workspace.show_git_file_history("rename-after.txt")
    palette[:index] = 1
    historical = @workspace.palette_accept
    assert_includes historical.buffer.text, "+same"

    write("copy-source.txt", "copied\n")
    git("add", "copy-source.txt")
    git("commit", "-qm", "Add copy source")
    FileUtils.cp(File.join(@root, "copy-source.txt"), File.join(@root, "copied.txt"))
    git("add", "copied.txt")
    git("commit", "-qm", "Copy source")
    assert_equal ["Copy source"], @workspace.git_file_history("copied.txt").map(&:subject)

    write("copy-one.txt", "duplicate\n")
    write("copy-two.txt", "duplicate\n")
    git("add", "copy-one.txt", "copy-two.txt")
    git("commit", "-qm", "Add duplicate sources")
    git("rm", "-q", "copy-one.txt", "copy-two.txt")
    write("copy-target.txt", "duplicate\n")
    git("add", "copy-target.txt")
    git("commit", "-qm", "Ambiguous move")

    assert_equal ["Ambiguous move"], @workspace.git_file_history("copy-target.txt").map(&:subject)
  end

  def test_history_labels_remove_format_and_separator_controls
    unsafe = "alpha\u0007beta\u202Egamma\u2060delta\u2028epsilon\u2029zeta"

    assert_equal "alpha beta gamma delta epsilon zeta",
      @workspace.send(:safe_git_history_text, unsafe, 100)
  end

  def test_large_adversarial_diff_uses_the_linear_fallback
    before = (["anchor\n"] + 3_000.times.map { |index| "old-#{index}\n" }).join
    after = (3_000.times.map { |index| "new-#{index}\n" } + ["anchor\n"]).join
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    source = Timeout.timeout(1.5) do
      @workspace.send(:build_git_diff_source, "example.txt", before, after)
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - elapsed
    assert_operator elapsed, :<, 1.5
    assert_equal 3_001, source.diff.stat.deletions
    assert_equal 3_001, source.diff.stat.insertions
  end

  def test_scm_diff_calculation_runs_outside_the_git_mutex
    change = scm_change(:unstaged, "example.txt")
    state = @workspace.send(:git_state)
    synchronize = state.method(:synchronize)
    locked = false
    state.define_singleton_method(:synchronize) do |**options, &operation|
      synchronize.call(**options) do |repository|
        locked = true
        operation.call(repository)
      ensure
        locked = false
      end
    end
    diff = Porrima.method(:diff)
    observed = []

    Porrima.stub(:diff, lambda { |*arguments, **options|
      observed << locked
      diff.call(*arguments, **options)
    }) do
      @workspace.show_scm_diff(change)
      @workspace.compare_git_revisions(@initial, @updated, path: "example.txt")
    end

    assert_operator observed.length, :>=, 2
    assert_equal [false], observed.uniq
  end

  def test_close_does_not_wait_for_or_install_a_slow_diff
    @window = Zaniah::Platform.open_window(backend: :headless, width: 700, height: 400)
    Canopus::Controller.new(@workspace, @window)
    materialize = @workspace.method(:materialize_git_diff)
    started, release = Queue.new, Queue.new
    @workspace.define_singleton_method(:materialize_git_diff) do |*arguments|
      started << true
      release.pop
      materialize.call(*arguments)
    end
    job = @workspace.compare_git_revisions(@initial, @updated, path: "example.txt")
    started.pop
    current = @workspace
    count = current.buffers.length
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    current.close
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - elapsed
    release << true
    assert job.join(3), "slow diff did not finish"

    assert_operator elapsed, :<, 0.5
    assert_equal count, current.buffers.length
    assert current.instance_variable_get(:@main_queue).empty?
    @workspace = nil
  ensure
    release << true if release
    job&.join(3)
  end

  def test_window_requests_run_in_the_background_and_commands_are_registered
    @window = Zaniah::Platform.open_window(backend: :headless, width: 700, height: 400)
    Canopus::Controller.new(@workspace, @window)
    before = @workspace.editor

    job = @workspace.compare_git_revisions(@initial, @updated, path: "example.txt")
    assert_instance_of Thread, job
    assert_same before, @workspace.editor
    assert job.join(3), "Git diff timed out"
    @workspace.drain
    refute_same before, @workspace.editor
    assert_includes @workspace.editor.buffer.text, "+hello new world"
    assert_empty @workspace.instance_variable_get(:@git_view_jobs)

    history_job = @workspace.show_git_file_history("example.txt")
    assert_instance_of Thread, history_job
    assert history_job.join(3), "Git history timed out"
    @workspace.drain
    assert_equal :git_file_history, @workspace.palette[:kind]
    assert_empty @workspace.instance_variable_get(:@git_history_jobs)

    original = @workspace.method(:git_file_history)
    started, release = Queue.new, Queue.new
    @workspace.define_singleton_method(:git_file_history) do |*arguments, **options|
      started << true
      release.pop
      original.call(*arguments, **options)
    end
    stale_job = @workspace.show_git_file_history("example.txt")
    started.pop
    @workspace.palette_open(:commands)
    release << true
    assert stale_job.join(3), "stale Git history timed out"
    @workspace.drain
    assert_equal :commands, @workspace.palette[:kind]
    %w[git.diff.toggle_mode git.compare_revisions git.file_history].each do |command|
      assert @workspace.commands.resolve(command)
    end
  end

  private

  def highlighted_text(editor)
    @workspace.scm_diff_decorations(editor.buffer, 0...editor.buffer.line_count)
      .select { |item| item.kind == :highlight }
      .map { |item| editor.buffer.rope.byteslice(item.range).to_s }
  end

  def scm_change(kind, path)
    @workspace.scm_tree.instance_variable_get(:@source)
      .find { |node| node.fetch(:id).last == kind }.fetch(:children)
      .find { |node| node.dig(:value, :path) == path }.fetch(:value)
  end

  def write(path, content) = File.binwrite(File.join(@root, path), content)

  def git(*arguments)
    output, error, status = Open3.capture3("git", "-C", @root, *arguments, binmode: true)
    raise error unless status.success?
    output
  end
end

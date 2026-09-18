# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class GitBlameTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-git-blame-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Alice")
    git("config", "user.email", "alice@example.invalid")
    git("config", "core.autocrlf", "false")
    write("example.txt", "alpha\nbeta\ngamma\n")
    git("add", ".")
    git("commit", "-qm", "Initial")
    git("config", "user.name", "Bob")
    git("config", "user.email", "bob@example.invalid")
    write("example.txt", "alpha\nBETA\ngamma\n")
    git("add", ".")
    git("commit", "-qm", "Change beta")
    @workspace = Canopus::Workspace.new(root: @root)
    @editor = @workspace.open("example.txt")
  end

  def teardown
    @workspace&.close
    @window&.on_close { true }
    @window&.close unless @window&.closed?
    FileUtils.remove_entry(@root)
  end

  def test_modes_and_dirty_line_mapping
    assert_empty decorations

    @workspace.settings.merge!("git" => {"inline_blame" => "all"})
    clean = decorations
    assert_equal 3, clean.length
    assert_includes clean[0].content, "Alice"
    assert_includes clean[1].content, "Bob"

    @editor.select(0)
    @editor.insert_text("new\n")
    dirty = decorations
    assert_equal 4, dirty.length
    assert_equal "  Uncommitted changes", dirty[0].content
    assert_includes dirty[1].content, "Alice"
    assert_includes dirty[2].content, "Bob"

    @workspace.settings.merge!("git" => {"inline_blame" => "cursor"})
    @editor.select(@editor.buffer.rope.line_start(2))
    cursor = decorations
    assert_equal 1, cursor.length
    assert_equal 2, cursor.first.row
    assert_includes cursor.first.content, "Bob"
  end

  def test_blame_is_computed_off_the_ui_thread_and_cached_by_version
    @workspace.settings.merge!("git" => {"inline_blame" => "all"})
    @window = Zaniah::Platform.open_window(backend: :headless, width: 640, height: 240)
    Canopus::Controller.new(@workspace, @window)

    assert_empty decorations
    job = @workspace.instance_variable_get(:@git_blame_jobs).fetch(@editor.buffer)
    assert job.join(3), "Git blame timed out"
    @workspace.drain
    assert_equal 3, decorations.length
    assert_empty @workspace.instance_variable_get(:@git_blame_jobs)

    @editor.select(0)
    @editor.insert_text("dirty\n")
    assert_empty decorations
    changed = @workspace.instance_variable_get(:@git_blame_jobs).fetch(@editor.buffer)
    refute_same job, changed
    assert changed.join(3), "dirty Git blame timed out"
    @workspace.drain
    assert_equal "  Uncommitted changes", decorations.first.content
  end

  def test_oversized_buffers_do_not_start_blame
    @workspace.settings.merge!("git" => {"inline_blame" => "all"})
    large = Canopus::Buffer.new("x" * ((1 << 20) + 1), path: File.join(@root, "example.txt"))

    assert_empty @workspace.git_blame_decorations(large, 0...1, @editor)
    assert_nil @workspace.instance_variable_get(:@git_blame_jobs)
  ensure
    large&.close
  end

  def test_head_with_too_many_lines_is_rejected_before_blame
    write("many.txt", "x\n" * Canopus::Workspace::GitBlame::BLAME_MAX_LINES)
    git("add", "many.txt")
    git("commit", "-qm", "Many lines")
    write("many.txt", "short\n")
    editor = @workspace.open("many.txt")
    @workspace.settings.merge!("git" => {"inline_blame" => "all"})
    repository = @workspace.git
    blame_calls = 0
    repository.define_singleton_method(:blame) { |_| blame_calls += 1; [] }

    assert_empty @workspace.git_blame_decorations(editor.buffer, 0...editor.buffer.line_count, editor)
    assert_equal 0, blame_calls
  end

  def test_non_lf_line_separators_are_not_attributed
    %W[\r \u2028 \u2029].each_with_index do |separator, index|
      path = "separator-#{index}.txt"
      write(path, ["one", "two", ""].join(separator))
      git("add", path)
      git("commit", "-qm", "Separator #{index}")
      editor = @workspace.open(path)
      @workspace.settings.merge!("git" => {"inline_blame" => "all"})

      assert_empty @workspace.git_blame_decorations(editor.buffer, 0...editor.buffer.line_count, editor)
    end
  end

  def test_clean_crlf_lines_are_attributed
    git("config", "core.autocrlf", "true")
    write("crlf.txt", "one\r\ntwo\r\n")
    git("add", "crlf.txt")
    git("commit", "-qm", "CRLF lines")
    assert_equal "one\ntwo\n", git("show", "HEAD:crlf.txt")
    editor = @workspace.open("crlf.txt")
    @workspace.settings.merge!("git" => {"inline_blame" => "all"})

    decorations = @workspace.git_blame_decorations(editor.buffer, 0...editor.buffer.line_count, editor)
    assert_equal 2, decorations.length
    assert decorations.all? { |item| item.content.include?("Bob") }
  end

  private

  def decorations
    @workspace.git_blame_decorations(@editor.buffer, 0...@editor.buffer.line_count, @editor)
  end

  def write(path, contents) = File.binwrite(File.join(@root, path), contents)

  def git(*arguments)
    output, error, status = Open3.capture3("git", "-C", @root, *arguments)
    raise "git #{arguments.join(' ')}: #{error}" unless status.success?
    output
  end
end

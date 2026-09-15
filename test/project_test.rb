# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
gem "minitest", "~> 5.0"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../lib/canopus/project"

class ProjectTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("canopus-project-")
    @project = Canopus::Project.new(@directory)
  end

  def teardown = FileUtils.remove_entry(@directory)

  def write(path, text)
    absolute = File.join(@directory, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, text)
  end

  def test_nested_ignores_negations_and_pruned_directories
    write(".gitignore", "*.log\n/build/\n!important.log\n**/cache/\nlocked/\n!locked/keep.txt\n")
    write(".ignore", "*.generated\n")
    write("lib/.gitignore", "!debug.log\n/private.txt\n")
    %w[app.rb trace.log important.log build/out.rb lib/build/keep.rb lib/debug.log lib/private.txt lib/cache/data.txt locked/keep.txt test/cache/data.txt generated.generated].each { |path| write(path, "x") }
    assert_equal %w[.gitignore .ignore app.rb important.log lib/.gitignore lib/build/keep.rb lib/debug.log], @project.files.to_a
    assert @project.ignored?("locked/keep.txt")
    refute @project.ignored?("lib/debug.log")
  end

  def test_ignore_globs_match_git_oracle
    _, error, status = Open3.capture3("git", "init", "-q", @directory)
    assert status.success?, error
    patterns = "# comment\n\\#literal\n\\!literal\n*.log\n!important.log\n/only.txt\na/**/b.txt\n**/cache/\n[ab]?.tmp\nspace\\ \ntrailing   \n[[:digit:]].number\n[!a-c].inverse\n[z-a].bad\n"
    write(".gitignore", patterns)
    paths = ["#literal", "!literal", "x.log", "important.log", "only.txt", "sub/only.txt", "a/b.txt", "a/x/y/b.txt", "cache/x", "sub/cache/x", "ab.tmp", "c.tmp", "space ", "trailing", "good.txt", "1.number", "x.number", "a.inverse", "z.inverse", "z.bad"]
    paths.each { |path| write(path, "x") }
    paths.each do |path|
      _, _, git_status = Open3.capture3("git", "-C", @directory, "check-ignore", "--no-index", "-q", "--", path)
      assert_equal git_status.success?, @project.ignored?(path), path
    end
  end

  def test_file_filters_and_symlink_cycles
    write("lib/a.rb", "日本 apple\napple apple\n")
    write("b.txt", "apple\n")
    write("binary.rb", "apple\0ignored")
    write("large.rb", "apple" * 500)
    File.symlink(@directory, File.join(@directory, "lib", "loop"))
    assert_equal %w[binary.rb lib/a.rb], @project.files(extensions: ["rb"], max_size: 100).to_a
    assert_equal 4, @project.files(follow_symlinks: true).count
  end

  def test_replace_is_atomic_and_watcher_reconciles_ignore_changes
    write("one.txt", "red red\n")
    write("omit.txt", "red\n")
    write(".ignore", "omit.txt\n")
    watcher = @project.watcher
    assert_equal({"one.txt" => 2}, @project.replace("red", "blue"))
    assert_equal "blue blue\n", File.read(File.join(@directory, "one.txt"))
    assert_equal "red\n", File.read(File.join(@directory, "omit.txt"))
    assert_equal [["one.txt", :modified]], watcher.poll.map { |event| [event.path, event.type] }
    write("two.txt", "new")
    assert_equal :created, watcher.poll.first.type
    write(".ignore", "omit.txt\ntwo.txt\n")
    assert_equal [[".ignore", :modified], ["two.txt", :deleted]], watcher.poll.map { |event| [event.path, event.type] }
    File.unlink(File.join(@directory, "one.txt"))
    assert_equal :deleted, watcher.poll.first.type
    watcher.close
    assert_raises(ArgumentError) { @project.path("../outside") }
  end

  def test_replace_keeps_search_visibility_binary_size_and_symlink_rules
    write(".hidden.txt", "red\n")
    write(".canopus/trash/deleted.txt", "red\n")
    write("binary.txt", "red\0ignored")
    write("large.txt", "red" * 100)
    File.symlink(File.join(@directory, ".hidden.txt"), File.join(@directory, "link.txt")) unless Gem.win_platform?

    assert_equal({".hidden.txt" => 1}, @project.replace("red", "blue", max_size: 100))
    assert_equal "blue\n", File.read(File.join(@directory, ".hidden.txt"))
    assert_equal "red\n", File.read(File.join(@directory, ".canopus/trash/deleted.txt"))
    assert_equal "red\0ignored", File.binread(File.join(@directory, "binary.txt"))
    assert_equal "red" * 100, File.read(File.join(@directory, "large.txt"))
  end
end

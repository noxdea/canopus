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

  def test_cycles_file_filters_binary_and_utf8_offsets
    write("lib/a.rb", "日本 apple\napple apple\n")
    write("b.txt", "apple\n")
    write("binary.rb", "apple\0ignored")
    write("large.rb", "apple" * 500)
    File.symlink(@directory, File.join(@directory, "lib", "loop"))
    assert_equal %w[lib/a.rb], @project.search("apple", extensions: ["rb"], max_size: 100).map(&:path).uniq
    hits = @project.search("apple", extensions: ["rb"], max_size: 100, workers: 2)
    assert_equal [1, 2, 2], hits.map(&:line)
    assert_equal [4, 1, 7], hits.map(&:column)
    assert_equal [7, 13, 19], hits.map(&:byte_offset)
    assert_equal 4, @project.files(follow_symlinks: true).count
    assert_equal hits, @project.search("APPLE", extensions: ["rb"], max_size: 100, case_sensitive: false)
  end

  def test_replace_is_atomic_and_watcher_reconciles_ignore_changes
    write("one.txt", "red red\n")
    watcher = @project.watcher
    assert_equal({"one.txt" => 2}, @project.replace("red", "blue"))
    assert_equal "blue blue\n", File.read(File.join(@directory, "one.txt"))
    assert_equal [["one.txt", :modified]], watcher.poll.map { |event| [event.path, event.type] }
    write("two.txt", "new")
    assert_equal :created, watcher.poll.first.type
    write(".ignore", "two.txt\n")
    assert_equal [[".ignore", :created], ["two.txt", :deleted]], watcher.poll.map { |event| [event.path, event.type] }
    File.unlink(File.join(@directory, "one.txt"))
    assert_equal :deleted, watcher.poll.first.type
    watcher.close
    assert_raises(ArgumentError) { @project.path("../outside") }
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class GitHistoryTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-git-history-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "History Test")
    git("config", "user.email", "history@example.invalid")
    write("base.txt", "base\n")
    git("add", ".")
    git("commit", "-qm", "Initial")
    git("checkout", "-qb", "topic")
    write("topic.txt", "topic\n")
    git("add", ".")
    git("commit", "-qm", "Topic path")
    git("checkout", "-q", "main")
    write("main.txt", "main\n")
    git("add", ".")
    git("commit", "-qm", "Main path")
    git("merge", "-q", "--no-ff", "topic", "-m", "Merge topic")
    6.times { |index| write("search-#{index}.txt", "#{index}\n") }
    git("add", ".")
    git("commit", "-qm", "Add searchable files")
    @workspace = Canopus::Workspace.new(root: @root)
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root)
  end

  def test_commit_graph_preserves_parents_and_searches_message_author_and_every_path
    entries = @workspace.git_commit_history

    assert_equal "Add searchable files", entries.first.subject
    assert_equal "History Test", entries.first.author
    assert_equal 6, entries.first.paths.length
    merge = entries.find { |entry| entry.subject == "Merge topic" }
    assert_equal 2, merge.parents.length
    assert_match(/●/, merge.graph)
    assert entries.all?(&:frozen?)

    palette = @workspace.show_git_commit_history
    palette[:query].replace("search-5.txt")
    @workspace.update_palette
    assert_equal 1, palette[:matches].length
    assert_includes palette[:matches].first, "Add searchable files"
  end

  def test_selecting_commit_and_path_opens_its_diff
    @workspace.show_git_commit_history
    paths = @workspace.palette_accept

    assert_equal :git_commit_paths, paths[:kind]
    index = paths[:items].index("search-3.txt")
    paths[:index] = index
    diff = @workspace.palette_accept

    assert_includes diff.buffer.text, "+3"
    assert_includes diff.buffer.text, "search-3.txt"
  end

  def test_history_limits_are_bounded
    assert_raises(ArgumentError) { @workspace.git_commit_history(limit: 0) }
    assert_raises(ArgumentError) { @workspace.git_commit_history(limit: 201) }
    assert_raises(Canopus::Error) { @workspace.git_commit_history(revision: "HEAD\nmain") }
  end

  def test_every_bounded_parent_follows_its_children
    tree = git("rev-parse", "HEAD^{tree}").strip
    base = git("rev-list", "--max-parents=0", "HEAD").strip
    descendant = commit_tree(tree, parents: [base], message: "Descendant")
    merge = commit_tree(tree, parents: [base, descendant], message: "Redundant merge")

    entries = @workspace.git_commit_history(revision: merge)
    indices = entries.each_with_index.to_h { |entry, index| [entry.oid, index] }
    entries.each_with_index do |entry, child_index|
      entry.parents.each do |parent|
        assert_operator indices.fetch(parent), :>, child_index if indices.key?(parent)
      end
    end
  end

  private

  def write(path, contents) = File.binwrite(File.join(@root, path), contents)

  def git(*arguments)
    output, error, status = Open3.capture3("git", "-C", @root, *arguments)
    raise "git #{arguments.join(' ')}: #{error}" unless status.success?
    output
  end

  def commit_tree(tree, parents:, message:)
    arguments = ["commit-tree", tree]
    parents.each { |parent| arguments.concat(["-p", parent]) }
    git(*arguments, "-m", message).strip
  end
end

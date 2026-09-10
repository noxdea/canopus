# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
gem "minitest", "~> 5.0"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../lib/canopus/git"

class GitTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("canopus-git-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Fixture Author")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "core.autocrlf", "false")
    git("config", "maintenance.auto", "false")
    write("text.txt", "first\nsecond\nthird\n")
    git("add", ".")
    git("commit", "-qm", "Initial text")
    @first = git("rev-parse", "HEAD").strip
    @repository = Canopus::Git::Repository.new(@directory)
  end

  def teardown = FileUtils.remove_entry(@directory)

  def git(*arguments, input: "")
    output, error, status = Open3.capture3("git", "-C", @directory, *arguments, stdin_data: input, binmode: true)
    assert status.success?, "git #{arguments.join(' ')}: #{error}"
    output
  end

  def write(path, contents)
    absolute = File.join(@directory, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, contents)
  end

  def test_loose_objects_refs_index_and_status
    assert_equal @first, @repository.head
    assert_equal "main", @repository.branch
    assert_equal ["main"], @repository.branches
    assert_equal "first\nsecond\nthird\n", @repository.blob("text.txt")
    assert_empty @repository.status
    write("text.txt", "first\nchanged\nthird\n")
    write("new.txt", "new")
    assert_equal({"new.txt" => "??", "text.txt" => " M"}, @repository.status.to_h { |entry| [entry.path, entry.code] })
    File.symlink("missing.txt", File.join(@directory, "dangling"))
    assert_equal "??", @repository.status.find { |entry| entry.path == "dangling" }.code
    git("add", "text.txt")
    File.unlink(File.join(@directory, "text.txt"))
    assert_equal "MD", @repository.status.find { |entry| entry.path == "text.txt" }.code
    git("tag", "-a", "v1", "-m", "Version one", @first)
    git("pack-refs", "--all")
    assert_equal @first, @repository.commit("v1").oid
    assert_equal @first, @repository.resolve("main")
    assert_raises(ArgumentError) { @repository.resolve("../../config") }
  end

  def test_myers_hunks_revert_and_blame
    write("text.txt", "first\nchanged\nthird\nnew\n")
    hunks = @repository.diff("text.txt", context: 0)
    assert_equal 2, hunks.length
    assert_equal [2, 1, 2, 1], [hunks.first.old_start, hunks.first.old_count, hunks.first.new_start, hunks.first.new_count]
    @repository.revert_hunk("text.txt", hunks.last)
    assert_equal "first\nchanged\nthird\n", File.read(File.join(@directory, "text.txt"))
    git("add", ".")
    git("commit", "-qm", "Change middle line")
    second = @repository.head
    blame = @repository.blame("text.txt")
    assert_equal [@first, second, @first], blame.map(&:commit)
    assert_equal [1, 2, 3], blame.map(&:original_line)
    git("mv", "text.txt", "renamed.txt")
    git("commit", "-qm", "Rename text")
    assert_equal [@first, second, @first], @repository.blame("renamed.txt").map(&:commit)
  end

  def test_packed_objects_and_both_delta_encodings
    12.times do |number|
      write("large.txt", (1..400).map { |line| "#{line}: persistent text #{line == number + 1 ? number : 0}\n" }.join)
      git("add", ".")
      git("commit", "-qm", "Revise text #{number}")
    end
    all = git("rev-list", "--objects", "--all").lines.map { |line| line.split.first }
    expected = all.to_h { |oid| [oid, [git("cat-file", "-t", oid).strip, git("cat-file", "-p", oid)]] }
    # cat-file -p prints a tree; use the raw type request for the byte oracle.
    expected.each { |oid, object| object[1] = git("cat-file", object[0], oid) }
    %w[--delta-base-offset --no-delta-base-offset].each do |encoding|
      packed = git("pack-objects", "--stdout", "--revs", "--all", "--window=50", "--depth=50", encoding)
      pack_path = File.join(@directory, "fixture.pack")
      File.binwrite(pack_path, packed)
      git("index-pack", pack_path)
      pack = Canopus::Git::Pack.new(pack_path.sub(/\.pack$/, ".idx"))
      expected.each do |oid, object|
        assert_equal object.map(&:b), pack.read(oid) { |base| @repository.odb.read(base) }.map(&:b), "#{encoding}: #{oid}"
      end
      File.unlink(pack_path.sub(/\.pack$/, ".idx"))
    end
    git("gc", "--aggressive", "--prune=now")
    expected.each { |oid, object| assert_equal object.map(&:b), @repository.odb.read(oid).map(&:b) }
  end

  def test_index_version_four_and_git_worktree
    %w[a/b/one.txt a/b/two.txt a/c/three.txt].each { |path| write(path, path) }
    git("add", ".")
    git("update-index", "--index-version=4")
    assert_equal 4, @repository.index.version
    assert_equal %w[a/b/one.txt a/b/two.txt a/c/three.txt text.txt], @repository.index.entries.map(&:path)
    git("commit", "-qm", "Add nested paths")
    linked = File.join(@directory, "linked")
    git("worktree", "add", "-q", "-b", "linked", linked)
    other = Canopus::Git::Repository.new(linked)
    assert_equal @repository.head, other.head
    assert_equal "linked", other.branch
    assert_empty other.status
  end

  def test_checkout_preserves_untracked_and_rejects_dirty_or_colliding_files
    git("checkout", "-qb", "other")
    write("text.txt", "other content\n")
    write("added.txt", "added")
    git("add", ".")
    git("commit", "-qm", "Other branch text")
    git("checkout", "-q", "main")
    write("untracked.txt", "keep")
    assert_equal "other", @repository.checkout("other")
    assert_equal "other content\n", File.read(File.join(@directory, "text.txt"))
    assert_equal "keep", File.read(File.join(@directory, "untracked.txt"))
    assert_equal "other", git("branch", "--show-current").strip
    assert_equal "?? untracked.txt\n", git("status", "--porcelain")
    @repository.checkout("main")
    write("added.txt", "collision")
    assert_raises(ArgumentError) { @repository.checkout("other") }
    assert_equal "main", @repository.branch
    assert_equal "collision", File.read(File.join(@directory, "added.txt"))
    write("text.txt", "dirty")
    assert_raises(ArgumentError) { @repository.checkout("other") }
  end

  def test_corruption_is_reported
    index_path = File.join(@directory, ".git", "index")
    bytes = File.binread(index_path)
    bytes.setbyte(20, bytes.getbyte(20) ^ 1)
    File.binwrite(index_path, bytes)
    assert_raises(Canopus::Git::CorruptObject) { @repository.index }
    assert_raises(Canopus::Git::CorruptObject) { Canopus::Git::Pack.apply_delta("abc", "\x03\x04\x91\x01\x04".b) }
  end

  def test_checkout_handles_file_directory_transitions_and_ignored_collisions
    git("checkout", "-qb", "directory")
    File.unlink(File.join(@directory, "text.txt"))
    write("text.txt/nested.txt", "nested")
    git("add", ".")
    git("commit", "-qm", "Replace file with directory")
    git("checkout", "-q", "main")
    @repository.checkout("directory")
    assert_equal "nested", File.read(File.join(@directory, "text.txt", "nested.txt"))
    @repository.checkout("main")
    assert_equal "first\nsecond\nthird\n", File.read(File.join(@directory, "text.txt"))
    @repository.checkout("directory")
    write(".git/info/exclude", "*.secret\n")
    write("text.txt/keep.secret", "ignored but preserved")
    assert_raises(ArgumentError) { @repository.checkout("main") }
    assert_equal "ignored but preserved", File.read(File.join(@directory, "text.txt", "keep.secret"))
    assert_equal "directory", @repository.branch
  end

  def test_blame_handles_deep_histories_without_ruby_recursion
    tree = @repository.commit.tree
    parent = @first
    1500.times do |number|
      contents = "tree #{tree}\nparent #{parent}\nauthor Fixture Author <fixture@example.invalid> #{number} +0000\ncommitter Fixture Author <fixture@example.invalid> #{number} +0000\n\nUnchanged text #{number}\n"
      oid = Canopus::Git::ObjectDatabase.hash("commit", contents)
      write(".git/objects/#{oid[0, 2]}/#{oid[2..]}", Zlib::Deflate.deflate("commit #{contents.bytesize}\0" + contents))
      parent = oid
    end
    write(".git/refs/heads/main", "#{parent}\n")
    assert_equal [@first, @first, @first], @repository.blame("text.txt").map(&:commit)
  end

  def test_diff_fuzz_is_shortest_and_reversible
    random = Random.new(839)
    150.times do
      a = Array.new(random.rand(12)) { "#{random.rand(5)}\n" }
      b = Array.new(random.rand(12)) { "#{random.rand(5)}\n" }
      edits = Canopus::Git::Diff.edits(a, b)
      assert_equal a, edits.reject { |edit| edit.kind == :insert }.map(&:text)
      assert_equal b, edits.reject { |edit| edit.kind == :delete }.map(&:text)
      lengths = Array.new(a.length + 1) { Array.new(b.length + 1, 0) }
      a.each_index { |i| b.each_index { |j| lengths[i + 1][j + 1] = a[i] == b[j] ? lengths[i][j] + 1 : [lengths[i][j + 1], lengths[i + 1][j]].max } }
      assert_equal a.length + b.length - 2 * lengths[-1][-1], edits.count { |edit| edit.kind != :equal }
      restored = b.join
      Canopus::Git::Diff.hunks(a.join, b.join, context: 0).reverse_each { |hunk| restored = Canopus::Git::Diff.revert(restored, hunk) }
      assert_equal a.join, restored
    end
  end

  def test_completely_replaced_large_file_skips_myers_search
    before = Array.new(20_000) { |index| "old #{index}\n" }
    after = Array.new(20_000) { |index| "new #{index}\n" }
    Canopus::Git::Diff.stub(:bisect, ->(*) { flunk "disjoint lines do not need Myers search" }) do
      edits = Canopus::Git::Diff.edits(before, after)
      assert_equal before, edits.select { |edit| edit.kind == :delete }.map(&:text)
      assert_equal after, edits.select { |edit| edit.kind == :insert }.map(&:text)
    end
  end
end

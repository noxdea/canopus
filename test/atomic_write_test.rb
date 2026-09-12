# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "tmpdir"

class AtomicWriteTest < Minitest::Test
  %i[buffer session settings project].each do |writer|
    define_method("test_#{writer}_closes_temporary_file_before_replacing_destination") do
      with_destination(writer) do |path|
        with_closed_temporary_rename do
          write_with(writer, path)
        end
        refute_equal original(writer), File.binread(path)
        assert_equal [File.basename(path)], Dir.children(File.dirname(path))
      end
    end

    define_method("test_#{writer}_preserves_destination_when_rename_fails") do
      with_destination(writer) do |path|
        with_closed_temporary_rename(fail_rename: true) do
          assert_raises(Errno::EACCES) { write_with(writer, path) }
        end
        assert_equal original(writer), File.binread(path)
        assert_equal [File.basename(path)], Dir.children(File.dirname(path))
      end
    end
  end

  private

  def original(writer) = writer == :settings ? "{\"tab_size\": 4}\n" : "red\n"

  def with_destination(writer)
    Dir.mktmpdir("canopus-atomic-") do |directory|
      path = File.join(directory, "document.txt")
      File.binwrite(path, original(writer))
      yield path
    end
  end

  def write_with(writer, path)
    case writer
    when :buffer
      buffer = Canopus::Buffer.open(path)
      buffer.edit([[0...3, "blue"]])
      buffer.save
    when :session
      workspace = Canopus::Workspace.new(root: File.dirname(path), settings: Canopus::Settings.new)
      workspace.new_buffer
      workspace.save_session(path)
    when :settings
      Canopus::Settings.new.set_file(path, "tab_size", 2)
    when :project
      Canopus::Project.new(File.dirname(path)).replace("red", "blue", workers: 1)
    end
  ensure
    workspace&.close
    buffer&.close
  end

  # Exercise the Windows sharing constraint on every host, without replacing the
  # actual same-directory rename or Tempfile cleanup on the successful path.
  def with_closed_temporary_rename(fail_rename: false)
    create, rename = Tempfile.method(:create), File.method(:rename)
    temporary = {}
    renames = 0
    create_file = lambda do |*args, **options, &block|
      create.call(*args, **options) do |file|
        temporary[file.path] = file
        block.call(file)
      end
    end
    replace_file = lambda do |source, destination|
      assert temporary.fetch(source).closed?, "temporary file must be closed before rename"
      assert_equal File.dirname(destination), File.dirname(source)
      assert File.file?(destination), "replacement must not unlink the destination first"
      renames += 1
      raise Errno::EACCES, destination if fail_rename
      rename.call(source, destination)
    end
    Tempfile.stub(:create, create_file) do
      File.stub(:rename, replace_file) { yield }
    end
    assert_equal 1, renames
  end
end

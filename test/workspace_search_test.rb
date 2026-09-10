# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"

class WorkspaceSearchTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-search-ui-")
    File.binwrite(File.join(@root, "a.rb"), "日本 target\nline\ntarget\n")
    File.binwrite(File.join(@root, "b.rb"), "target\n")
    @workspace = Canopus::Workspace.new(root: @root)
    @workspace.new_buffer
  end
  def teardown
    @workspace.close
    FileUtils.remove_entry(@root)
  end
  def test_search_merges_nearby_excerpts_edits_sources_and_saves
    result = @workspace.search_project("target", async: false)
    assert_instance_of Canopus::MultiBuffer, result
    assert_equal 2, result.excerpts.length
    assert_equal 3, @workspace.replace_in_buffer("target", "done")
    assert_equal "target\n", File.read(File.join(@root, "b.rb"))
    @workspace.call("file.save")
    assert_nil @workspace.palette
    assert_equal "done\n", File.read(File.join(@root, "b.rb"))
    assert_equal "日本 done\nline\ndone\n", File.read(File.join(@root, "a.rb"))
    assert result.undo
    assert_includes result.text, "target"
  end
  def test_search_includes_unsaved_and_excludes_removed_matches
    buffer = @workspace.open("a.rb").buffer
    buffer.edit([[0...buffer.rope.bytesize, "unsaved token\n"]])
    result = @workspace.search_project("token", async: false)
    assert_equal 1, result.excerpts.length
    assert_same buffer, result.excerpts.first.buffer
    assert_equal 1, @workspace.search_project("target", async: false).excerpts.length
  end
  def test_replace_palette_keeps_search_pattern
    @workspace.open("b.rb")
    @workspace.call("search.replace")
    @workspace.palette[:query] = "target"
    @workspace.palette_accept
    @workspace.palette[:query] = "changed"
    @workspace.palette_accept
    assert_equal "changed\n", @workspace.editor.buffer.text
  end
  def test_search_session_preserves_excerpt_links_and_unsaved_sources
    source = @workspace.open("a.rb").buffer
    source.edit([[0...0, "# unsaved\n"]])
    result = @workspace.search_project("target", async: false)
    @workspace.split
    session = File.join(@root, "session.json")
    @workspace.save_session(session)
    @workspace.restore_session(session)
    restored = @workspace.editor.buffer
    assert_instance_of Canopus::MultiBuffer, restored
    assert_equal 2, restored.excerpts.length
    assert_same restored, @workspace.panes.first.active.buffer
    assert_equal 3, @workspace.replace_in_buffer("target", "kept")
    assert_equal "日本 target\nline\ntarget\n", File.read(File.join(@root, "a.rb"))
    reopened = @workspace.open("a.rb").buffer
    assert_same reopened, restored.excerpts.first.buffer
    assert_includes reopened.text, "# unsaved"
    assert_includes reopened.text, "kept"
  end
end

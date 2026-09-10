# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SearchPreparationTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-search-preparation-")
    File.write(File.join(@root, "a.txt"), "target\npadding\n")
    File.write(File.join(@root, "b.txt"), "target\n")
    @workspace = Canopus::Workspace.new(root: @root)
    @workspace.new_buffer
  end

  def teardown
    @workspace.close
    @workspace.instance_variable_get(:@search_job)&.join(3)
    FileUtils.remove_entry(@root)
  end

  def prepare(query = "target")
    job = @workspace.search_project(query)
    assert job.join(3), "search preparation did not finish"
    @workspace.instance_variable_get(:@search_prepared)
  end

  def finish
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    loop do
      @workspace.instance_variable_get(:@search_job)&.join(0.02)
      @workspace.drain
      return @workspace.editor.buffer if @workspace.editor.buffer.is_a?(Canopus::MultiBuffer)
      raise "search did not install: #{@workspace.message}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end
  end

  def test_io_scanning_projection_and_editor_construction_never_run_in_foreground
    opening = Canopus::Buffer.method(:open)
    projection = Canopus::MultiBuffer.method(:new)
    editor = Canopus::Editor.method(:new)
    scan = @workspace.method(:search_excerpt_ranges)
    realpath = File.method(:realpath)
    guard = ->(method) do
      lambda do |*arguments, **options|
        raise "foreground preparation: #{method.name}" if Thread.current == Thread.main
        method.call(*arguments, **options)
      end
    end
    Canopus::Buffer.stub(:open, guard.call(opening)) do
      Canopus::MultiBuffer.stub(:new, guard.call(projection)) do
        Canopus::Editor.stub(:new, guard.call(editor)) do
          File.stub(:realpath, guard.call(realpath)) do
            @workspace.stub(:search_excerpt_ranges, guard.call(scan)) do
              prepare
              assert_equal 2, finish.excerpts.length
            end
          end
        end
      end
    end
  end

  def test_dirty_source_snapshot_is_private_and_changed_version_is_reprepared
    source = @workspace.open("a.txt").buffer
    source.edit([[0...source.rope.bytesize, "unsaved target\r\n"]])
    source.define_singleton_method(:anchor) do |*arguments, **options|
      raise "background touched live anchors" unless Thread.current == Thread.main
      super(*arguments, **options)
    end
    source.define_singleton_method(:on_edit) do |&callback|
      raise "background subscribed to live buffer" unless Thread.current == Thread.main
      super(&callback)
    end
    listeners = source.instance_variable_get(:@listeners).length
    anchors = source.instance_variable_get(:@anchors).dup
    prepared = prepare
    clone = prepared.buffers.fetch(source.path)
    refute_same source, clone
    assert_same source.rope, clone.rope
    assert_predicate clone, :dirty?
    assert_equal anchors, source.instance_variable_get(:@anchors)
    assert_equal listeners, source.instance_variable_get(:@listeners).length
    source.edit([[0...source.rope.bytesize, "changed without match\r\n"]])
    result = finish
    assert_equal ["b.txt"], result.excerpts.map { |excerpt| File.basename(excerpt.buffer.path) }
    assert_same source, @workspace.buffers.fetch(source.path)
    assert_equal "changed without match\r\n", source.text
    assert prepared.editor.display_map.instance_variable_get(:@disposed)
  end

  def test_newly_opened_dirty_buffer_is_not_overwritten_by_prepared_disk_copy
    prepare
    source = @workspace.open("a.txt").buffer
    source.edit([[0...source.rope.bytesize, "new target\n"]])
    result = finish
    excerpt = result.excerpts.find { |entry| entry.buffer.path == source.path }
    assert_same source, excerpt.buffer
    assert_includes result.text, "new target"
    assert_predicate source, :dirty?
  end

  def test_version_change_after_undo_is_checked_even_when_rope_identity_matches
    source = @workspace.open("a.txt").buffer
    before = prepare
    source.edit([[0...0, "x"]])
    source.undo
    assert_same before.sources.fetch(source.path).rope, source.rope
    @workspace.drain
    refute @workspace.editor.buffer.is_a?(Canopus::MultiBuffer)
    result = finish
    assert_same source, result.excerpts.first.buffer
  end

  def test_cancelled_and_closed_queued_preparations_release_only_private_state
    source = @workspace.open("a.txt").buffer
    history = source.history.dup
    prepared = prepare
    @workspace.cancel_project_search
    assert_nil @workspace.instance_variable_get(:@search_prepared)
    assert_empty prepared.editor.buffer.excerpts.first.buffer.instance_variable_get(:@anchors)
    @workspace.drain
    assert_same source, @workspace.editor.buffer
    assert_equal history, source.history
    pending = prepare
    @workspace.close
    @workspace.drain
    assert_nil @workspace.instance_variable_get(:@search_prepared)
    assert pending.editor.display_map.instance_variable_get(:@disposed)
    assert_raises(Canopus::Error) { @workspace.search_project("target") }
  end

  def test_close_while_worker_is_scanning_cleans_up_after_cancellation
    entered, release = Queue.new, Queue.new
    original = @workspace.method(:search_excerpt_ranges)
    @workspace.define_singleton_method(:search_excerpt_ranges) do |*args|
      entered << true
      release.pop
      original.call(*args)
    end
    job = @workspace.search_project("target")
    entered.pop
    @workspace.close
    release << true
    assert job.join(3)
    assert_nil @workspace.instance_variable_get(:@search_prepared)
    @workspace.drain
    refute @workspace.buffers.values.any? { |buffer| buffer.is_a?(Canopus::MultiBuffer) }
  end

  def test_stale_error_cannot_replace_newer_search_result_message
    entered, release = Queue.new, Queue.new
    original = @workspace.project.method(:search)
    @workspace.project.define_singleton_method(:search) do |pattern, **options|
      if pattern.source == "obsolete"
        entered << true
        release.pop
        raise "old search failed"
      end
      original.call(pattern, **options)
    end
    old = @workspace.search_project("obsolete")
    entered.pop
    prepare
    release << true
    assert old.join(3)
    finish
    assert_match(/2 matches/, @workspace.message)
    refute_match(/old search failed/, @workspace.message)
  end

  def test_settings_changes_reprepare_layout_before_installing
    settings = [2, false, false]
    @workspace.define_singleton_method(:search_editor_settings) { settings.dup.freeze }
    prepared = prepare
    assert_equal 2, prepared.editor.tab_size
    settings.replace([8, true, true])
    finish
    assert_equal 8, @workspace.editor.tab_size
    assert @workspace.editor.use_tabs
    assert_equal 100, @workspace.editor.display_map.wrap_map.width
  end

  def test_canonical_aliases_share_one_source
    skip "symlinks unavailable" if Gem.win_platform?
    File.symlink("a.txt", File.join(@root, "alias.txt"))
    matches = ["a.txt", "alias.txt"].map { |path| Canopus::Project::Search::Match.new(path: path) }
    @workspace.project.stub(:search, matches) do
      prepare
      result = finish
      assert_equal 1, result.excerpts.length
      assert_equal File.realpath(File.join(@root, "a.txt")), result.excerpts.first.buffer.path
    end
  end

  def test_an_open_read_only_source_is_not_replaced_by_an_editable_disk_copy
    path = File.realpath(File.join(@root, "a.txt"))
    source = Canopus::Buffer.new("target\n", path: path, read_only: true)
    @workspace.buffers[path] = source
    prepare
    result = finish
    assert_equal ["b.txt"], result.excerpts.map { |excerpt| File.basename(excerpt.buffer.path) }
    assert_same source, @workspace.buffers.fetch(path)
  end

  def test_attachment_error_is_reported_without_installing_or_leaking_private_state
    source = @workspace.open("a.txt").buffer
    prepared = prepare
    source.define_singleton_method(:on_edit) { |&_| raise "cannot attach search results" }
    @workspace.drain
    assert_equal "cannot attach search results", @workspace.message
    assert_same source, @workspace.editor.buffer
    assert prepared.editor.display_map.instance_variable_get(:@disposed)
    assert_empty prepared.editor.buffer.excerpts.first.buffer.instance_variable_get(:@anchors)
  end

  def test_denebola_snapshot_constructor_preserves_line_endings_without_copying_rope
    ["\n", "\r\n", "\r", "\u2028", "\u2029"].each do |ending|
      rope = Denebola::Rope.new("日#{ending}second")
      snapshot = Canopus::Buffer.new(rope: rope)
      assert_same rope, snapshot.rope
      assert_equal ending, snapshot.line_ending
      assert_equal "日#{ending}second", snapshot.text
    end
    rope = Denebola::Rope.new("no newlines")
    assert_equal "\n", Canopus::Buffer.new(rope: rope).line_ending
    assert_equal "\r\n", Canopus::Buffer.new("\r\n", rope: rope).line_ending
  end
end

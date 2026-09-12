# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class CloseAndTerminalTabsTest < Minitest::Test
  class Terminal
    attr_reader :grid, :vt, :writes, :resizes, :reads

    def initialize(output = "")
      @grid = Canopus::Terminal::Grid.new(columns: 40, rows: 8)
      @vt = Canopus::Terminal::VT.new(@grid)
      @output, @writes, @resizes, @reads = output, +"", [], []
    end

    def read(max_bytes:, max_seconds:)
      @reads << [max_bytes, max_seconds]
      @output.slice!(0, max_bytes).to_s
    end

    def write(value) = @writes << value
    def key(name, **options) = write(@vt.key(name, **options))
    def paste(value) = write(@vt.paste(value))
    def resize(columns:, rows:)
      @resizes << [columns, rows]
      @grid.resize(columns: columns, rows: rows)
    end
    def close = @closed = true
    def closed? = @closed
    def busy? = false
  end

  def setup
    @root = Dir.mktmpdir("canopus-close-tabs-")
    @workspace = Canopus::Workspace.new(root: @root)
    @window = Zaniah::Platform.open_window(backend: :headless, width: 700, height: 500)
    @controller = Canopus::Controller.new(@workspace, @window)
  end

  def teardown
    @workspace.close
    @window.on_close { true }
    @window.close
    FileUtils.remove_entry(@root)
  end

  def test_close_releases_shared_buffers_only_after_the_last_reference_and_reopens_state
    path = File.join(@root, "a.rb")
    File.binwrite(path, "one\ntwo\n")
    first = @workspace.open(path)
    first.select(4, 7)
    @workspace.split
    second = @workspace.editor
    assert_equal 2, @workspace.buffer_refs(path).length

    @workspace.close_editor(second)
    assert_equal 1, @workspace.panes.length
    assert_equal 1, @workspace.buffer_refs(path).length
    @workspace.close_editor(first)
    assert_empty @workspace.buffer_refs(path)

    reopened = @workspace.reopen_closed
    assert_equal "one\ntwo\n", reopened.buffer.text
    assert_equal [4, 7], [reopened.primary.anchor, reopened.primary.head]
  end

  def test_dirty_close_is_non_blocking_and_cancel_or_discard_is_explicit
    current = @workspace.editor
    current.insert_text("unsaved")
    refute @workspace.request_close
    assert_equal :confirm_tab_close, @workspace.palette[:kind]
    @workspace.resolve_tab_close(:cancel)
    assert_includes @workspace.active_pane.editors, current

    @workspace.request_close
    @workspace.resolve_tab_close(:discard)
    refute_includes @workspace.active_pane.editors, current
    refute @workspace.buffers.values.any?(&:dirty?)
    assert_nil @workspace.editor

    @controller.input_text("new")
    assert_equal "new", @workspace.editor.buffer.text
  end

  def test_closing_a_search_projection_releases_its_unreferenced_sources
    path = File.join(@root, "source.rb")
    File.write(path, "match\n")
    source = Canopus::Buffer.open(path)
    projection = Canopus::MultiBuffer.new(excerpts: [[source, 0...5, "source.rb:1"]])
    @workspace.buffers[path] = source
    @workspace.buffers[projection.object_id] = projection
    current = @workspace.active_pane.open(projection)

    assert_equal [[:multi_buffer, projection.object_id]], @workspace.buffer_refs(source)
    @workspace.close_editor(current)
    refute_includes @workspace.buffers.values, projection
    refute_includes @workspace.buffers.values, source
  end

  def test_terminal_tabs_route_keys_share_a_frame_budget_and_throttle_resize
    first, second = Terminal.new("a" * 100), Terminal.new("b" * 100)
    @workspace.terminal = first
    @workspace.terminals << second
    @workspace.activate_terminal(1)
    @workspace.terminal_visible = true
    @controller.instance_variable_set(:@terminal_focus, true)

    @controller.key("ctrl-c")
    assert_equal "\x03", second.writes
    @workspace.drain_terminals(now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    budget = @workspace.settings["terminal"]["max_bytes_per_frame"]
    assert_equal budget, first.reads.first.first
    assert_equal budget - 100, second.reads.first.first

    @workspace.resize_terminal(80, 24, now: 0)
    @workspace.resize_terminal(81, 25, now: 0.05)
    @workspace.resize_terminal(82, 26, now: 0.11)
    assert_equal [[80, 24], [82, 26]], second.resizes
    @workspace.resize_terminal(83, 27, now: 0.12)
    @workspace.flush_terminal_resize
    assert_equal [83, 27], second.resizes.last

    @controller.key("cmd-w")
    assert second.closed?
    assert_same first, @workspace.terminal
  end
end

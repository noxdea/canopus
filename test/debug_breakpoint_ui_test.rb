# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class DebugBreakpointUiTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-breakpoint-ui-")
    @path = File.join(@root, "example.rb")
    File.write(@path, "first\nsecond\nthird\n")
    @workspace = Canopus::Workspace.new(root: @root)
    @editor = @workspace.open(@path)
    @window = Zaniah::Platform::Headless::Window.new(width: 640, height: 240)
    @controller = Canopus::Controller.new(@workspace, @window)
    @controller.tick
  end

  def teardown
    @workspace&.close
    @window&.close
    FileUtils.remove_entry(@root) if File.exist?(@root)
  end

  def test_gutter_left_click_toggles_empty_and_existing_rows
    click_gutter(1, :left)
    assert_equal [2], @workspace.breakpoints.for_path(@path).map(&:line)
    @controller.tick
    item = breakpoint_item(1)
    assert_equal :error, item.style[:color]
    assert_equal "Enabled breakpoint on line 2", item.content
    assert @controller.view.accessibility.any? { |node| node[:label] == item.content && node[:role] == :button }

    click_gutter(1, :left)
    assert_empty @workspace.breakpoints.for_path(@path)
    assert_equal "#0000", breakpoint_item(1).style[:color]
  end

  def test_overview_only_contains_real_breakpoints_for_large_buffers
    large = File.join(@workspace.root, "large.rb")
    buffer = Canopus::Buffer.new("", path: large)
    buffer.define_singleton_method(:line_count) { 100_000 }

    assert_empty @workspace.decorations.items_for(buffer, 0...100_000)
    @workspace.breakpoints.add(large, 90_000)
    overview = @workspace.decorations.items_for(buffer, 0...100_000)
    assert_equal [89_999], overview.select { |item| item.source == :breakpoint }.map(&:row)
  end

  def test_right_click_edits_dap_fields_and_disabled_state
    click_gutter(1, :right)
    choose_action("Add conditional breakpoint", value: "value > 3")
    assert_equal "value > 3", entry.condition

    edit_action("Edit hit count", "5")
    edit_action("Edit log message", "value={value}")
    open_menu
    choose_action("Disable breakpoint")

    assert_equal ["value > 3", "5", "value={value}", false],
      [entry.condition, entry.hit_condition, entry.log_message, entry.enabled]
    assert_equal :muted, breakpoint_item(1).style[:color]
    @workspace.breakpoints.flush
    document = JSON.parse(File.read(File.join(@root, ".canopus", "breakpoints.json")))
    assert_equal 2, document["version"]
    assert_equal false, document["breakpoints"].first["enabled"]
  end

  def test_workspace_tracks_open_save_as_and_close_lifecycle
    @workspace.breakpoints.add(@path, 2)
    @editor.buffer.edit([[0...0, "before\n"]])
    assert_equal [3], @workspace.breakpoints.for_path(@path).map(&:line)

    target = File.join(@root, "renamed.rb")
    @workspace.breakpoints.add(target, 1)
    @workspace.save_buffer(@editor.buffer, path: target)
    @editor.buffer.edit([[0...0, "again\n"]])
    assert_equal [3], @workspace.breakpoints.for_path(@path).map(&:line)
    assert_equal [2], @workspace.breakpoints.for_path(target).map(&:line)

    @workspace.close
    assert_raises(Canopus::Error) { @workspace.breakpoints.add(target, 3) }
    @workspace = nil
  end

  def test_breakpoint_palette_rejects_an_edited_buffer_snapshot
    click_gutter(1, :right)
    @editor.buffer.edit([[0...0, "before\n"]])
    choose_action("Add breakpoint")

    assert_nil @workspace.palette
    assert_match(/open the breakpoint menu again/, @workspace.message)
    assert_empty @workspace.breakpoints.for_path(@path)
  end

  def test_breakpoint_palette_rejects_a_saved_as_path
    click_gutter(1, :right)
    target = File.join(@root, "renamed.rb")
    @workspace.save_buffer(@editor.buffer, path: target)
    choose_action("Add breakpoint")

    assert_nil @workspace.palette
    assert_empty @workspace.breakpoints.for_path(@path)
    assert_empty @workspace.breakpoints.for_path(target)
  end

  def test_breakpoint_edit_rejects_an_externally_removed_entry
    @workspace.breakpoints.add(@path, 2, condition: "original")
    open_menu
    choose_action("Edit condition")
    @workspace.breakpoints.remove(@path, 2)
    @controller.input(Zaniah::Input::TextInput.new("replacement"))
    @controller.input(Zaniah::Input::KeyDown.new("enter", false))

    assert_nil @workspace.palette
    assert_match(/open the breakpoint menu again/, @workspace.message)
    assert_empty @workspace.breakpoints.for_path(@path)
  end

  def test_empty_row_menu_rejects_an_externally_added_entry
    open_menu
    added = @workspace.breakpoints.add(@path, 2, condition: "external")
    choose_action("Add breakpoint")

    assert_nil @workspace.palette
    assert_same added, @workspace.breakpoints.for_path(@path).first
    assert_equal "external", added.condition
  end

  def test_close_continues_cleanup_after_breakpoint_failure
    terminal = Struct.new(:closed) { def close = self.closed = true }.new(false)
    watcher = Struct.new(:closed) { def close = self.closed = true }.new(false)
    @workspace.terminals << terminal
    @workspace.instance_variable_set(:@watcher, watcher)
    buffer, current = @editor.buffer, @editor
    buffer_closed = editor_disposed = minimap_closed = servers_stopped = false
    buffer.define_singleton_method(:close) { buffer_closed = true; super() }
    current.define_singleton_method(:dispose) { editor_disposed = true; super() }
    minimap = @workspace.minimap
    minimap_close = minimap.method(:close)
    minimap.define_singleton_method(:close) { minimap_closed = true; minimap_close.call }
    @workspace.define_singleton_method(:stop_language_servers) { servers_stopped = true }
    registry = @workspace.breakpoints
    registry_close = registry.method(:close)
    registry.define_singleton_method(:close) do
      registry_close.call
      raise Canopus::Error, "breakpoint close failed"
    end

    error = assert_raises(Canopus::Error) { @workspace.close }
    assert_equal "breakpoint close failed", error.message
    assert terminal.closed
    assert watcher.closed
    assert buffer_closed
    assert editor_disposed
    assert minimap_closed
    assert servers_stopped
    @workspace = nil
  end

  def test_session_restore_replaces_breakpoint_attachment_and_keeps_edit_tracking
    @workspace.breakpoints.add(@path, 2)
    session = File.join(@root, "session.json")
    original = @editor.buffer
    @workspace.save_session(session)

    @workspace.restore_session(session)
    restored = @workspace.editor.buffer
    refute_same original, restored
    restored.edit([[0...0, "before\n"]])

    assert_equal [3], @workspace.breakpoints.for_path(@path).map(&:line)
  end

  private

  def breakpoint_item(row)
    @workspace.decorations.items_for(@editor.buffer, row...(row + 1), context: @editor)
      .find { |item| item.source == :breakpoint && item.row == row }
  end

  def gutter_region(row)
    @controller.tick
    @controller.view.regions.find do |_bounds, action|
      action.first == :context_decoration && action[2].equal?(@editor) && action[3] == row &&
        action[1].respond_to?(:right_click)
    end
  end

  def click_gutter(row, button)
    bounds, = gutter_region(row)
    @controller.input(Zaniah::Input::MouseDown.new(Zaniah::Point.new(bounds.x + 1, bounds.y + 1), button, [], 1))
  end

  def open_menu
    click_gutter(1, :right)
    assert_equal :breakpoint_actions, @workspace.palette[:kind]
  end

  def choose_action(label, value: nil)
    index = @workspace.palette[:matches].index(label)
    refute_nil index, label
    @workspace.palette[:index] = index
    @controller.input(Zaniah::Input::KeyDown.new("enter", false))
    if value
      assert_equal :breakpoint_edit, @workspace.palette[:kind]
      @controller.input(Zaniah::Input::TextInput.new("#{value}x"))
      @controller.input(Zaniah::Input::KeyDown.new("backspace", false))
      assert_equal value, @workspace.palette[:query]
      @controller.input(Zaniah::Input::KeyDown.new("enter", false))
    end
  end

  def edit_action(label, value)
    open_menu
    choose_action(label, value: value)
  end

  def entry
    @workspace.breakpoints.for_path(@path).first
  end
end

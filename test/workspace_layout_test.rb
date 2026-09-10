# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"

class WorkspaceLayoutTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-layout-")
    @workspace = Canopus::Workspace.new(root: @root)
    @window = Zaniah::Platform.open_window(width: 800, height: 500)
    @controller = Canopus::Controller.new(@workspace, @window)
  end
  def teardown
    @workspace.close
    @window.on_close { true }
    @window.close
    FileUtils.remove_entry(@root)
  end
  def test_tab_reorder_preserves_pins_and_editor_identity
    pane = @workspace.active_pane
    first = @workspace.editor
    @workspace.new_buffer
    last = @workspace.new_buffer
    pane.pin(last)
    @workspace.move_tab(from: pane, to: pane, editor: last, index: 0)
    assert_same last, pane.editors.first
    target = @workspace.split
    @workspace.move_tab(from: pane, to: target, editor: first)
    assert_same first, target.active
    assert_includes pane.pinned, last
    refute_includes pane.editors, first
  end
  def test_split_drag_and_session_ratio
    @workspace.split
    @controller.tick
    divider = @controller.view.regions.find { |_, action| action.first == :split_resize }.first
    @controller.input(Zaniah::Input::MouseDown.new(position: Zaniah::Point.new(divider.x + 1, divider.y + 1), button: :left, modifiers: [], click_count: 1))
    @controller.input(Zaniah::Input::MouseMove.new(position: Zaniah::Point.new(650, 100), modifiers: []))
    assert_operator @workspace.layout[:ratio], :>, 0.6
    session = File.join(@root, "session.json")
    @workspace.save_session(session)
    ratio = @workspace.layout[:ratio]
    @workspace.restore_session(session)
    assert_equal ratio, @workspace.layout[:ratio]
  end
  def test_native_drop_opens_existing_files_only
    path = File.join(@root, "dropped.rb")
    File.write(path, "puts :drop")
    @controller.input(Zaniah::Input::FileDrop.new(paths: [path, File.join(@root, "missing.rb")], position: Zaniah::Point.new(20, 20)))
    assert_equal "puts :drop", @workspace.editor.buffer.text
    assert_empty @workspace.message
  end
  def test_scrollbar_drag_horizontal_reveal_and_blink
    editor = @workspace.editor
    editor.insert_text(("a" * 150 + "\n") * 100, auto_indent: false)
    editor.move(:file_start)
    @controller.tick
    area, action = @controller.view.regions.find { |_, item| item.first == :scrollbar && item[2] == :vertical }
    @controller.input(Zaniah::Input::MouseDown.new(position: Zaniah::Point.new(area.x + 4, area.bottom - 2), button: :left, modifiers: [], click_count: 1))
    assert_operator editor.scroll_y, :>, 60
    @controller.input(Zaniah::Input::MouseUp.new(position: Zaniah::Point.new(area.x + 4, area.bottom - 2), button: :left, modifiers: []))
    editor.move(:file_start)
    editor.move(:line_end)
    @controller.tick
    assert_operator editor.scroll_x, :>, 100
    assert @controller.view.regions.any? { |_, item| item.first == :scrollbar && item[2] == :horizontal }
    @controller.view.reset_blink(0)
    assert @controller.view.cursor_visible?
    assert @controller.view.tick(0.6)
    refute @controller.view.cursor_visible?
    refute @controller.view.tick(0.7)
    assert @controller.view.tick(1.1)
    assert @controller.view.cursor_visible?
  end
  def test_tab_switch_ends_vim_insert_transaction
    first = @workspace.editor
    state = @workspace.vim
    state.feed("i")
    state.feed("a")
    second = @workspace.new_buffer
    assert_equal :normal, state.mode
    @workspace.activate_tab(@workspace.active_pane, first)
    assert first.undo
    assert_equal "", first.buffer.text
    assert_same first, @workspace.editor
    @workspace.activate_tab(@workspace.active_pane, second)
    assert_same second, @workspace.editor
  end

  def test_notifications_are_bounded_accessible_dismissible_and_expire
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    4.times { |i| @workspace.notify("Message #{i}", now: now) }
    assert_equal 3, @workspace.notifications.length
    @controller.tick
    assert_equal 3, @controller.view.accessibility.count { |item| item[:role] == :alert }
    bounds, = @controller.view.regions.find { |_, action| action.first == :dismiss_notification }
    @controller.input(Zaniah::Input::MouseDown.new(position: Zaniah::Point.new(bounds.x + 2, bounds.y + 2), button: :left, modifiers: [], click_count: 1))
    assert_equal 2, @workspace.notifications.length
    @controller.view.reset_blink(now + 6)
    assert @controller.view.tick(now + 6)
    assert_empty @workspace.notifications
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TerminalMotionRoutingTest < Minitest::Test
  class Screen
    attr_reader :grid, :vt, :written
    def initialize
      @grid = Canopus::Terminal::Grid.new(columns: 40, rows: 4)
      @vt = Canopus::Terminal::VT.new(@grid)
      @written = +""
    end
    def resize(columns:, rows:) = @grid.resize(columns: columns, rows: rows)
    def mouse(**options) = @written << @vt.mouse(**options)
    def close; end
  end

  def setup
    @root = Dir.mktmpdir("canopus-terminal-motion-")
    @workspace = Canopus::Workspace.new(root: @root)
    @window = Zaniah::Platform.open_window(backend: :headless, width: 640, height: 500)
    @controller = Canopus::Controller.new(@workspace, @window)
    @terminal = @workspace.terminal = Screen.new
    @workspace.terminal_visible = true
    @window.render(@controller.view)
    bounds = @controller.view.terminal_bounds
    @point = Zaniah::Point.new(bounds.x + 1, bounds.y + 1)
  end

  def teardown
    @workspace.close
    @window.on_close { true }
    @window.close
    FileUtils.remove_entry(@root)
  end

  def tracking(mode)
    @terminal.vt.feed("\e[?#{mode}h\e[?1006h")
    @terminal.written.clear
  end

  def move(point = @point, modifiers: [])
    @controller.input(Zaniah::Input::MouseMove.new(point, modifiers))
  end

  def down(point = @point, modifiers: [])
    @controller.input(Zaniah::Input::MouseDown.new(point, :left, modifiers, 1))
  end

  def test_all_motion_mode_reports_hover_with_no_button_and_modifiers
    tracking(1003)
    move
    assert_equal "\e[<35;1;1M", @terminal.written
    refute @controller.instance_variable_get(:@terminal_focus)
    move(modifiers: %w[shift alt ctrl])
    assert_equal "\e[<35;1;1M\e[<63;1;1M", @terminal.written
  end

  def test_normal_and_button_motion_modes_do_not_report_hover
    [1000, 1002].each do |mode|
      tracking(mode)
      move
      assert_empty @terminal.written
      down
      assert_equal "\e[<0;1;1M", @terminal.written
      @terminal.written.clear
      move
      assert_equal(mode == 1002 ? "\e[<32;1;1M" : "", @terminal.written)
      @controller.input(Zaniah::Input::MouseUp.new(@point, :left, []))
      @terminal.written.clear
      move
      assert_empty @terminal.written
    end
  end

  def test_hover_is_restricted_to_the_visible_unobscured_terminal
    tracking(1003)
    move(Zaniah::Point.new(-1, -1))
    bounds = @controller.view.editor_bounds.fetch(@workspace.editor)
    move(Zaniah::Point.new(bounds.x + 60, bounds.y + 10))
    assert_empty @terminal.written
    @workspace.terminal_visible = false # Old painted bounds must not be used.
    move
    assert_empty @terminal.written
    @workspace.terminal_visible = true
    @controller.view.regions << [@controller.view.terminal_bounds, [:hover_link, "https://example.test"]]
    move
    assert_empty @terminal.written
  end

  def test_palette_and_shift_selection_take_priority_over_terminal_hover
    tracking(1003)
    @workspace.palette_open(:commands)
    move
    assert_empty @terminal.written
    @workspace.palette = nil
    down(modifiers: ["shift"])
    move
    assert_empty @terminal.written
    assert @controller.view.terminal_selection
  end

  def test_an_editor_drag_crossing_terminal_bounds_is_not_terminal_motion
    tracking(1003)
    @workspace.editor.insert_text("text")
    bounds = @controller.view.editor_bounds.fetch(@workspace.editor)
    down(Zaniah::Point.new(bounds.x + 60, bounds.y + 10))
    assert @controller.instance_variable_get(:@drag)
    move
    assert_empty @terminal.written
  end
end

# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"

class TerminalPresentationTest < Minitest::Test
  class FakeTerminal
    attr_reader :grid, :vt, :written
    def initialize
      @grid = Tarazed::Grid.new(columns: 40, rows: 4)
      @vt = Tarazed::VT.new(@grid)
      @written = +""
    end
    def resize(columns:, rows:) = @grid.resize(columns: columns, rows: rows)
    def write(bytes) = @written << bytes
    def key(name, **options) = write(@vt.key(name, **options))
    def paste(value) = write(@vt.paste(value))
    def mouse(**options) = write(@vt.mouse(**options))
    def commands = @vt.commands
    def cwd = @vt.cwd || "/tmp"
    def close; end
    def read = ""
  end
  def setup
    @root = Dir.mktmpdir("canopus-terminal-ui-")
    @workspace = Canopus::Workspace.new(root: @root)
    @window = Zaniah::Platform.open_window(width: 640, height: 500)
    @window.singleton_class.attr_accessor :clipboard
    @controller = Canopus::Controller.new(@workspace, @window)
    @terminal = @workspace.terminal = FakeTerminal.new
    @workspace.terminal_visible = true
    @terminal.vt.feed("\e[31;44mred\e[0m plain\n日本\n")
    @controller.tick
    bounds = @controller.view.terminal_bounds
    @point = Zaniah::Point.new(bounds.x + 1, bounds.y + 1)
  end
  def teardown
    @workspace.close
    @window.close
    FileUtils.remove_entry(@root)
  end
  def click
    @controller.input(Zaniah::Input::MouseDown.new(position: @point, button: :left, modifiers: [], click_count: 1))
    assert_empty @workspace.message
  end
  def test_terminal_colors_selection_and_control_keys
    view = @controller.view
    assert_equal "#ff0000", view.terminal_color(196, :foreground)
    assert_equal "#080808", view.terminal_color(232, :foreground)
    assert_equal "#010203", view.terminal_color([1, 2, 3], :foreground)
    click
    @controller.key("ctrl-c")
    @controller.key("esc")
    assert_equal "\x03\e", @terminal.written
    view.terminal_select(Zaniah::Point.new(@point.x + 18, @point.y), extend: true)
    assert_match(/\Are/, view.terminal_selected_text)
  end
  def test_mouse_reporting_and_bracketed_paste
    @terminal.vt.feed("\e[?1000h\e[?1006h\e[?2004h")
    click
    assert_equal "\e[<0;1;1M", @terminal.written
    @window.clipboard = "hello"
    @controller.key("cmd-v")
    assert @terminal.written.end_with?("\e[200~hello\e[201~")
  end

  def test_command_boundaries_and_exit_status_are_rendered
    @terminal.grid.reset
    @terminal.vt.feed("\e]133;A\e\\$ \e]133;B\e\\日本語\e]133;C\e\\\r\n失敗\r\n\e]133;D;7\a")
    @window.request_frame
    @controller.tick

    assert_includes @window.text_runs.map { |run| run[2] }, "▾ exit 7"
  end

  def test_command_status_badge_toggles_output_fold
    @terminal.grid.reset
    @terminal.vt.feed("\e]133;A\a$ \e]133;B\aecho\e]133;C\a\r\none\r\ntwo\r\nthree\e]133;D;0\a")
    @window.request_frame
    @controller.tick
    assert_includes @window.text_runs.map { |run| run[2] }.join, "one"
    bounds, = @controller.view.regions.find { |_, action| action.first == :terminal_command }

    point = Zaniah::Point.new(bounds.x + 1, bounds.y + 1)
    @controller.input(Zaniah::Input::MouseDown.new(position: point, button: :left, modifiers: [], click_count: 1))
    @controller.tick

    refute_includes @window.text_runs.map { |run| run[2] }.join, "one"
    assert_includes @window.text_runs.map { |run| run[2] }, "▸ ✓"
  end
end

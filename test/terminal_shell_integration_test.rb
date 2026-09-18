# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TerminalShellIntegrationTest < Minitest::Test
  class Session
    attr_reader :options, :grid, :vt, :inputs, :command_name

    def initialize(command_name: "bash", **options)
      @command_name, @options = command_name, options
      @grid = Tarazed::Grid.new(columns: 20, rows: 3, scrollback: 3)
      @vt = Tarazed::VT.new(@grid)
      @inputs = []
    end

    def input(value) = @inputs << value
    def commands = @vt.commands
    def clear_commands = @vt.clear_commands
    def cwd = "/tmp"
    def close; end
  end

  def setup
    @root = Dir.mktmpdir("canopus-shell-integration-")
    @workspace = Canopus::Workspace.new(root: @root)
  end

  def teardown
    @workspace.close
    FileUtils.remove_entry(@root)
  end

  def command(id, row, input, status, output_range: row..row)
    now = Time.now.freeze
    Tarazed::Command.new(id: id, prompt_row: row, input: input.freeze, output_range: output_range.freeze,
      exit_status: status, started_at: now, finished_at: now, cwd: "/tmp".freeze)
  end

  def test_new_terminal_uses_session_and_injects_supported_shell_snippet
    @workspace.close
    shell = "C:\\Program Files\\Git\\bin\\bash.exe --login"
    settings = Canopus::Settings.new("terminal" => {"shell" => shell})
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    command_name = "C:\\Program Files\\Git\\bin\\bash.exe"
    session = Session.new(command_name: command_name)
    options = nil
    factory = ->(**values) { options = values; session }

    Tarazed::Session.stub(:new, factory) do
      Tarazed::ShellIntegration.stub(:path, ->(current) do
        assert_equal command_name, current
        "/tmp/bash integration"
      end) do
        assert_same session, @workspace.new_terminal(cwd: @root)
      end
    end

    assert_equal shell, options[:command]
    assert_equal @root, options[:cwd]
    assert_equal 10_000, options[:scrollback_limit]
    refute options.key?(:scrollback)
    assert_equal [". /tmp/bash\\ integration\n"], session.inputs
  end

  def test_fish_uses_its_source_builtin
    @workspace.close
    settings = Canopus::Settings.new("terminal" => {"shell" => ["/usr/bin/fish", "--no-config"]})
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    session = Session.new(command_name: "/usr/bin/FISH.exe")

    Tarazed::Session.stub(:new, ->(**) { session }) do
      Tarazed::ShellIntegration.stub(:path, ->(shell) do
        assert_equal "/usr/bin/FISH.exe", shell
        "/tmp/fish integration"
      end) { @workspace.new_terminal(cwd: @root) }
    end

    assert_equal ["source /tmp/fish\\ integration\n"], session.inputs
  end

  def test_new_terminal_inherits_the_active_terminal_working_directory
    active = Session.new
    root = @root
    active.define_singleton_method(:cwd) { root }
    @workspace.terminal = active
    created = Session.new
    options = nil

    Tarazed::Session.stub(:new, ->(**values) { options = values; created }) do
      Tarazed::ShellIntegration.stub(:path, "/tmp/integration") { @workspace.new_terminal }
    end

    assert_equal @root, options[:cwd]
  end

  def test_unsupported_shell_keeps_a_working_unintegrated_session
    session = Session.new(command_name: "nu")
    Tarazed::Session.stub(:new, ->(**) { session }) do
      Tarazed::ShellIntegration.stub(:path, ->(*) { raise ArgumentError, "unsupported" }) do
        assert_same session, @workspace.new_terminal(cwd: @root)
      end
    end

    assert_empty session.inputs
    assert_same session, @workspace.terminal
  end

  def test_disabled_shell_integration_does_not_read_or_inject_a_snippet
    @workspace.close
    settings = Canopus::Settings.new("terminal" => {"shell_integration" => false})
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    session = Session.new

    Tarazed::Session.stub(:new, ->(**) { session }) do
      Tarazed::ShellIntegration.stub(:path, ->(*) { flunk "integration should stay disabled" }) do
        @workspace.new_terminal(cwd: @root)
      end
    end

    assert_empty session.inputs
  end

  def test_command_palettes_preserve_unicode_and_ignore_evicted_rows
    session = Session.new
    session.vt.feed("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n")
    base = session.grid.scrollback.total - session.grid.scrollback.length
    failed = command(2, base, "失敗\ncommand", 7)
    old = command(1, base - 1, "old", 1)
    ok = command(3, base + 1, "ok", 0)
    incomplete = command(4, base + 2, "running", nil)
    history = [old, failed, ok, incomplete]
    session.define_singleton_method(:commands) { history }
    @workspace.terminal = session

    context = @workspace.command_context(terminal: true)
    @workspace.call("terminal.commands", context: context)
    assert_equal [failed, ok, incomplete], @workspace.palette[:items]
    @workspace.call("terminal.commands.failed", context: context)

    assert_equal [failed], @workspace.palette[:items]
    assert_includes @workspace.palette[:matches], "exit 7  失敗 command"
    assert @workspace.palette[:matches].all?(&:valid_encoding?)
    assert_same failed, @workspace.palette_accept
    assert_nil @workspace.palette
  end

  def test_command_palette_preserves_duplicate_item_indices
    session = Session.new
    repeated = command(1, 0, "same", 0)
    duplicate = command(2, 1, "same", 0)
    distinct = command(3, 2, "different", 0)
    session.define_singleton_method(:commands) { [repeated, duplicate, distinct] }
    @workspace.terminal = session
    @workspace.show_terminal_commands
    @workspace.palette[:query] = "different"
    @workspace.update_palette

    assert_same distinct, @workspace.palette_accept
  end

  def test_navigation_uses_absolute_rows_after_scrollback_eviction
    session = Session.new
    session.vt.feed("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n")
    base = session.grid.scrollback.total - session.grid.scrollback.length
    current = command(2, base + 1, "日本語", 0)
    following = command(3, base + 2, "next", 0)
    history = [command(1, base - 1, "evicted", 1), current, following]
    session.define_singleton_method(:commands) { history }
    @workspace.terminal = session
    view = Object.new.extend(Canopus::Workspace::View::TerminalPresentable)
    view.instance_variable_set(:@workspace, @workspace)
    view.instance_variable_set(:@terminal_scroll, 0)

    assert view.terminal_command(:previous)
    assert_equal 1, view.instance_variable_get(:@terminal_scroll)
    assert view.terminal_command(:previous)
    assert_equal 2, view.instance_variable_get(:@terminal_scroll)
    refute view.terminal_command(:previous)
    assert view.terminal_command(:next)
    refute view.terminal_command_jump(command(9, base - 1, "gone", 1))
  end

  def test_alternate_screen_disables_command_navigation_and_folding
    session = Session.new
    current = command(1, 0, "vim", 0, output_range: 0..2)
    session.define_singleton_method(:commands) { [current] }
    @workspace.terminal = session
    view = Object.new.extend(Canopus::Workspace::View::TerminalPresentable)
    view.instance_variable_set(:@workspace, @workspace)
    view.instance_variable_set(:@terminal_scroll, 0)
    assert view.terminal_toggle_command(current)

    session.vt.feed("\e[?1049hfull screen")

    assert_empty view.send(:terminal_row_map)[:intervals]
    refute view.terminal_command(:previous)
    refute view.terminal_toggle_command(current)
    @workspace.show_terminal_commands
    assert_empty @workspace.palette[:items]

    session.vt.feed("\e[?1049l")
    assert_equal [[1, 1]], view.send(:terminal_row_map)[:intervals]
  end

  def test_clear_terminal_removes_command_history
    session = Session.new
    session.vt.feed("\e]133;A\a$ \e]133;B\aecho ok\e]133;C\a\r\nok\e]133;D;0\a")
    @workspace.terminal = session
    refute_empty session.commands

    @workspace.call("terminal.clear", context: @workspace.command_context(terminal: true))

    assert_empty session.commands
  end

  def test_folding_maps_selection_mouse_coordinates_and_eviction
    session = Session.new
    session.vt.feed("prompt\r\nhidden one\r\nhidden two\r\nhttps://example.com\r\ntail\r\n")
    base = session.grid.scrollback.total - session.grid.scrollback.length
    folded = command(1, base, "echo 日本", 0, output_range: base..base + 3)
    history = [folded]
    session.define_singleton_method(:commands) { history }
    @workspace.terminal = session
    view = Object.new.extend(Canopus::Workspace::View::TerminalPresentable)
    view.instance_variable_set(:@workspace, @workspace)
    view.instance_variable_set(:@terminal_scroll, 0)
    view.instance_variable_set(:@terminal_bounds, Zaniah::Bounds.new(0, 0, 200, 60))
    view.instance_variable_set(:@terminal_cell_width, 10)
    view.instance_variable_set(:@terminal_line_height, 20)

    assert view.terminal_toggle_command(folded)
    map = view.send(:terminal_row_map)
    assert_equal [[1, 2]], map[:intervals]
    assert_equal [0, 3, 4], 3.times.map { |row| view.send(:terminal_source_for_display, map, row) }
    view.instance_variable_set(:@terminal_visible_rows, [0, 3, 4])
    view.instance_variable_set(:@terminal_first, 0)
    assert_equal [0, 0], view.terminal_point(Zaniah::Point.new(1, 21))
    assert_equal "https://example.com", view.terminal_link_at(Zaniah::Point.new(1, 21)).target
    view.terminal_select(Zaniah::Point.new(1, 1))
    view.terminal_select(Zaniah::Point.new(199, 21), extend: true)
    assert_equal 2, view.terminal_selected_text.lines.length
    view.instance_variable_set(:@terminal_visible_rows, [3, 4, 5])
    assert_equal [0, session.grid.cursor_y], view.terminal_point(Zaniah::Point.new(1, 41))
    view.instance_variable_set(:@terminal_visible_rows, [0, nil, nil])
    assert_nil view.terminal_point(Zaniah::Point.new(1, 21))
    assert_nil view.terminal_link_at(Zaniah::Point.new(1, 21))
    assert_nil view.terminal_select(Zaniah::Point.new(1, 21))

    session.vt.feed("six\r\nseven\r\neight\r\n")
    assert_empty view.send(:terminal_row_map)[:intervals]
    refute view.terminal_toggle_command(folded)
  end

  def test_malformed_markers_are_ignored
    session = Session.new
    session.vt.feed("\e]133;D;wat\a\e]133;C\e\\\e]133;A\e\\\e]133;D;99999999999\a")

    assert_empty session.commands
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TerminalSplitProfileTest < Minitest::Test
  class Session
    attr_reader :options, :grid, :vt, :resizes, :written

    def initialize(**options)
      @options, @resizes, @written = options, [], +""
      @grid = Tarazed::Grid.new(columns: 40, rows: 8)
      @vt = Tarazed::VT.new(@grid)
    end

    def cwd = @options[:cwd]
    def close = @closed = true
    def closed? = @closed
    def resize(columns:, rows:)
      @resizes << [columns, rows]
      @grid.resize(columns: columns, rows: rows)
    end
    def read(**) = ""
    def write(value) = @written << value
    def key(name, **options) = write(@vt.key(name, **options))
    def paste(value) = write(@vt.paste(value))
    def mouse(**options) = write(@vt.mouse(**options))
    def commands = @vt.commands
    def busy? = false
    def command_name = Array(@options[:command]).first
    def input(*) = nil
  end

  def setup
    @root = Dir.mktmpdir("canopus-terminal-split-")
    @nested = File.join(@root, "nested")
    Dir.mkdir(@nested)
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root)
  end

  def settings(restore: false)
    Canopus::Settings.new("terminal" => {
      "shell_integration" => false, "restore_on_startup" => restore,
      "env" => {"BASE" => "yes", "CANOPUS" => "wrong"},
      "profiles" => {"login" => {"path" => "/bin/example", "args" => ["--login"],
        "env" => {"PROFILE" => "yes", "EDITOR" => "wrong"}}},
      "default_profile" => "login"
    })
  end

  def test_default_profile_merges_environment_and_protects_editor_variables
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    created = nil
    Tarazed::Session.stub(:new, ->(**options) { created = Session.new(**options) }) do
      @workspace.new_terminal(cwd: @nested)
    end

    assert_equal ["/bin/example", "--login"], created.options[:command]
    assert_equal({"BASE" => "yes", "PROFILE" => "yes", "CANOPUS" => "1", "EDITOR" => "canopus --wait"},
      created.options[:env])
    assert_equal "login", @workspace.terminal_profile(created)
  end

  def test_split_inherits_cwd_routes_focus_and_collapses_when_closed
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    created = []
    Tarazed::Session.stub(:new, ->(**options) { Session.new(**options).tap { |item| created << item } }) do
      first = @workspace.new_terminal(cwd: @nested)
      second = @workspace.split_terminal(:horizontal)

      assert_equal @nested, second.cwd
      assert_equal :horizontal, @workspace.terminal_layout[:direction]
      assert_equal [first, second], @workspace.terminal_layout[:children].map { |node| node[:terminal] }
      @workspace.activate_terminal(0)
      assert_same first, @workspace.terminal
      @workspace.close_terminal
      assert_equal({terminal: second}, @workspace.terminal_layout)
      assert_same second, @workspace.terminal
      assert first.closed?
    end
  end

  def test_session_restores_profile_and_nested_layout
    @workspace = Canopus::Workspace.new(root: @root, settings: settings(restore: true))
    path = File.join(@root, "session.json")
    created = []
    Tarazed::Session.stub(:new, ->(**options) { Session.new(**options).tap { |item| created << item } }) do
      @workspace.new_terminal(cwd: @nested)
      @workspace.split_terminal(:vertical)
      @workspace.split_terminal(:horizontal)
      @workspace.save_session(path)
      @workspace.restore_session(path)
    end

    assert_equal 3, @workspace.terminals.length
    assert_equal :vertical, @workspace.terminal_layout[:direction]
    assert_equal :horizontal, @workspace.terminal_layout[:children].last[:direction]
    assert_equal ["login"] * 3, @workspace.terminals.map { |terminal| @workspace.terminal_profile(terminal) }
  end

  def test_each_split_routes_mouse_focus_and_text_to_its_terminal
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    window = Zaniah::Platform.open_window(backend: :headless, width: 700, height: 500)
    controller = Canopus::Controller.new(@workspace, window)
    created = []
    Tarazed::Session.stub(:new, ->(**options) { Session.new(**options).tap { |item| created << item } }) do
      @workspace.new_terminal(cwd: @nested)
      @workspace.split_terminal(:horizontal)
    end
    controller.tick
    regions = controller.view.regions.select { |_, action| action.first == :terminal }
    assert_equal 2, regions.length
    assert controller.view.regions.any? { |_, action| action.first == :split_resize }

    regions.each_with_index do |(bounds, _), index|
      controller.input(Zaniah::Input::MouseDown.new(
        position: Zaniah::Point.new(bounds.x + 1, bounds.y + 1), button: :left, modifiers: [], click_count: 1
      ))
      controller.input_text(index.to_s)
      assert_same created[index], @workspace.terminal
      assert_equal index.to_s, created[index].written
    end
  ensure
    window&.on_close { true }
    window&.close
  end

  def test_command_regions_keep_their_terminal_when_command_ids_repeat
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    window = Zaniah::Platform.open_window(backend: :headless, width: 700, height: 500)
    controller = Canopus::Controller.new(@workspace, window)
    created = []
    Tarazed::Session.stub(:new, ->(**options) { Session.new(**options).tap { |item| created << item } }) do
      @workspace.new_terminal(cwd: @nested)
      @workspace.split_terminal(:horizontal)
    end
    sequence = "\e]133;A\a$ \e]133;B\aecho\e]133;C\a\r\none\r\n\e]133;D;0\a"
    created.each { |terminal| terminal.vt.feed(sequence) }
    controller.tick

    regions = controller.view.regions.select { |_, action| action.first == :terminal_command }
    assert_equal 2, regions.length
    assert_equal 1, regions.map { |_, action| action[1].id }.uniq.length
    assert_equal created, regions.map { |_, action| action[2] }

    bounds, = regions.find { |_, action| action[2].equal?(created.first) }
    controller.input(Zaniah::Input::MouseDown.new(
      position: Zaniah::Point.new(bounds.x + 1, bounds.y + 1), button: :left, modifiers: [], click_count: 1
    ))
    assert_same created.first, @workspace.terminal
  ensure
    window&.on_close { true }
    window&.close
  end

  def test_split_applies_new_pane_sizes_on_the_next_frame
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    window = Zaniah::Platform.open_window(backend: :headless, width: 700, height: 500)
    controller = Canopus::Controller.new(@workspace, window)
    created = []
    Tarazed::Session.stub(:new, ->(**options) { Session.new(**options).tap { |item| created << item } }) do
      @workspace.new_terminal(cwd: @nested)
      controller.tick
      full_width = created.first.resizes.last.first
      @workspace.split_terminal(:horizontal)
      controller.tick

      assert_operator created[0].resizes.last.first, :<, full_width
      assert_operator created[1].resizes.last.first, :<, full_width
    end
  ensure
    window&.on_close { true }
    window&.close
  end

  def test_profile_settings_reject_invalid_defaults_and_commands
    assert_raises(Canopus::Error) { Canopus::Settings.new("terminal" => {"default_profile" => "missing"}) }
    assert_raises(Canopus::Error) do
      Canopus::Settings.new("terminal" => {"profiles" => {"bad" => {"command" => [], "path" => "/bin/sh"}}})
    end
    assert_raises(Canopus::Error) do
      Canopus::Settings.new("terminal" => {"profiles" => {"bad" => {"command" => [""]}}})
    end
    assert_raises(Canopus::Error) do
      Canopus::Settings.new("terminal" => {"profiles" => {"bad" => {"args" => ["--login"]}}})
    end
  end

  def test_split_resize_keeps_each_terminal_dimensions
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    created = []
    Tarazed::Session.stub(:new, ->(**options) { Session.new(**options).tap { |item| created << item } }) do
      @workspace.new_terminal
      @workspace.split_terminal(:horizontal)
    end

    @workspace.resize_terminal(80, 20, terminal: created[0], now: 0)
    @workspace.resize_terminal(40, 20, terminal: created[1], now: 0)
    @workspace.activate_terminal(0)
    @workspace.flush_terminal_resize

    assert_equal [80, 20], created[0].resizes.last
    assert_equal [40, 20], created[1].resizes.last
  end

  def test_windows_uses_comspec_without_a_profile_or_shell
    @workspace = Canopus::Workspace.new(root: @root, settings: Canopus::Settings.new("terminal" => {"shell_integration" => false}))
    created = nil
    Gem.stub(:win_platform?, true) do
      ENV.stub(:fetch, ->(key, fallback) { key == "COMSPEC" ? "C:\\Windows\\System32\\cmd.exe" : fallback }) do
        Tarazed::Session.stub(:new, ->(**options) { created = Session.new(**options) }) { @workspace.new_terminal }
      end
    end

    assert_equal "C:\\Windows\\System32\\cmd.exe", created.options[:command]
  end

  def test_session_rejects_active_terminal_outside_the_layout
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    data = {"terminals" => [{"cwd" => @root}, {"cwd" => @root}], "active_terminal" => 1,
      "terminal_layout" => {"terminal" => 0}}

    assert_raises(Canopus::Error) { @workspace.send(:validate_session_terminals, data) }
  end
end

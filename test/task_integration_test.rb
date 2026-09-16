# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TaskIntegrationTest < Minitest::Test
  class Status
    def initialize(success) = @success = success
    def success? = @success
    def exited? = true
    def exitstatus = @success ? 0 : 1
    def termsig = nil
  end

  class Terminal
    attr_reader :grid, :vt, :writes, :signals, :options
    attr_accessor :alive, :status

    def initialize(**options)
      @options = options
      @grid = Tarazed::Grid.new(columns: options[:columns], rows: options[:rows], scrollback: options[:scrollback])
      @vt = Tarazed::VT.new(@grid)
      @writes, @signals = +"", []
      @alive = true
    end
    def read(max_bytes:, max_seconds:) = ""
    def pending? = false
    def alive? = @alive
    def write(value) = @writes << value
    def key(name, **options) = write(@vt.key(name, **options))
    def paste(value) = write(@vt.paste(value))
    def mouse(**options) = write(@vt.mouse(**options))
    def resize(columns:, rows:) = @grid.resize(columns: columns, rows: rows)
    def signal(name) = (@signals << name; finish(false); true)
    def finish(success)
      @alive = false
      @status = Status.new(success)
    end
    def close = (@closed = true; @alive = false; self)
    def closed? = !!@closed
  end

  def setup
    @root = Dir.mktmpdir("canopus-task-integration-")
    FileUtils.mkdir_p(File.join(@root, ".canopus"))
    File.write(File.join(@root, ".canopus", "tasks.jsonc"), JSON.generate("tasks" => [
      task("always", "always"), task("silent", "silent"), task("never", "never")
    ]))
    @workspace = Canopus::Workspace.new(root: @root)
    @workspace.task_runner.close
    @created = []
    runner = Canopus::Task::Runner.new(scrollback: 100, queue_limit_bytes: 65_536,
      terminal_factory: ->(**options) { Terminal.new(**options).tap { |terminal| @created << terminal } })
    @workspace.instance_variable_set(:@task_runner, runner)
    @window = Zaniah::Platform.open_window(backend: :headless, width: 700, height: 500)
    @window.singleton_class.attr_accessor :clipboard
    @controller = Canopus::Controller.new(@workspace, @window)
  end

  def teardown
    @workspace.close
    @window.on_close { true }
    @window.close
    FileUtils.remove_entry(@root)
  end

  def test_palette_keybinding_runs_argv_and_always_reveals_output
    @controller.key("ctrl-shift-b")
    assert_equal :tasks, @workspace.palette[:kind]
    assert_equal %w[always never silent], @workspace.palette[:matches].sort
    @workspace.palette[:index] = @workspace.palette[:matches].index("always")
    @workspace.palette_accept

    output = @workspace.task_output
    assert_equal "always", output.label
    assert_equal [RbConfig.ruby, "-e", "puts :always"], output.terminal.options[:command]
    assert_equal File.realpath(@root), output.terminal.options[:cwd]
    assert @workspace.task_output_visible
    refute @workspace.terminal_visible
  end

  def test_task_tabs_route_input_and_stop_without_touching_the_integrated_terminal
    first = @workspace.run_task("always")
    second = @workspace.run_task("silent")
    normal = Terminal.new(command: ["shell"], cwd: @root, columns: 40, rows: 8, scrollback: 10)
    @workspace.terminal = normal
    @workspace.show_task_output(second)
    first.terminal.vt.feed("\e[31mred\e[0m")
    @controller.tick

    tab = @controller.view.regions.find { |_bounds, action| action == [:task_output_tab, 0] }
    refute_nil tab
    click(tab.first)
    assert_same first, @workspace.task_output
    body = @controller.view.regions.find { |_bounds, action| action == [:task_output] }
    click(body.first)
    @controller.input_text("answer")
    assert_equal "answer", first.terminal.writes
    assert_empty normal.writes

    @controller.key("ctrl-c")
    wait_until { first.terminal.closed? }
    assert_equal ["INT"], first.terminal.signals
    assert_empty second.terminal.signals
    assert_empty normal.signals
  end

  def test_reveal_never_stays_hidden_and_silent_reveals_only_failure
    @workspace.run_task("never")
    refute @workspace.task_output_visible
    @created.last.finish(false)
    @workspace.drain_task_outputs
    refute @workspace.task_output_visible

    silent = @workspace.run_task("silent")
    refute @workspace.task_output_visible
    silent.terminal.finish(true)
    @workspace.drain_task_outputs
    refute @workspace.task_output_visible

    silent = @workspace.run_task("silent")
    silent.terminal.finish(false)
    @workspace.drain_task_outputs
    assert @workspace.task_output_visible
    assert_same silent, @workspace.task_output
  end

  def test_task_output_copy_and_paste_dispatch_to_the_focused_task_only
    output = @workspace.run_task("always")
    normal = Terminal.new(command: ["shell"], cwd: @root, columns: 40, rows: 8, scrollback: 10)
    @workspace.terminal = normal
    output.terminal.vt.feed("copy")
    @controller.tick
    body = @controller.view.regions.find { |_bounds, action| action == [:task_output] }.first
    click(body)
    point = Zaniah::Point.new(body.x + 1, body.y + 1)
    @controller.view.terminal_select(point)
    @controller.view.terminal_select(Zaniah::Point.new(point.x + 20, point.y), extend: true)

    @controller.key("cmd-c")
    assert_match(/cop/, @window.clipboard)
    @window.clipboard = "paste"
    @controller.key("cmd-v")
    assert_equal "paste", output.terminal.writes
    assert_empty normal.writes
  end

  private

  def task(label, reveal)
    {"label" => label, "command" => [RbConfig.ruby, "-e", "puts :#{label}"],
     "cwd" => "${workspaceFolder}", "presentation" => {"panel" => "output", "reveal" => reveal}}
  end

  def click(bounds)
    point = Zaniah::Point.new(bounds.x + 2, bounds.y + [bounds.height / 2, 2].max)
    @controller.input(Zaniah::Input::MouseDown.new(position: point, button: :left, modifiers: [], click_count: 1))
  end

  def wait_until
    100.times do
      return if yield
      Thread.pass
    end
    flunk "condition was not met"
  end
end

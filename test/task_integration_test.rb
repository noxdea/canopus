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
    attr_accessor :alive, :status, :output

    def initialize(**options)
      @options = options
      @grid = Tarazed::Grid.new(columns: options[:columns], rows: options[:rows], scrollback: options[:scrollback])
      @vt = Tarazed::VT.new(@grid)
      @writes, @signals = +"", []
      @output = +""
      @alive = true
    end
    def read(max_bytes:, max_seconds:)
      return nil if !@alive && @output.empty?
      value = @output.slice!(0, max_bytes).to_s
      @vt.feed(value)
      value
    end
    def pending? = !@output.empty?
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

  def test_problem_matcher_publishes_task_diagnostics_and_closing_output_clears_them
    source = File.join(@root, "example.rb")
    File.write(source, "puts :ok\n")
    File.write(File.join(@root, ".canopus", "tasks.jsonc"), JSON.generate(
      "problem_matchers" => {"ruby" => {"owner" => "ruby",
        "file_location" => ["relative", "${workspaceFolder}"],
        "pattern" => {"regexp" => "^(.+):(\\d+): (warning|error): (.+)$",
          "file" => 1, "line" => 2, "severity" => 3, "message" => 4}}},
      "tasks" => [task("diagnostics", "never").merge("problem_matcher" => "ruby")]))

    output = @workspace.run_task("diagnostics")
    output.terminal.output << "example.rb:1: error: broken\n"
    assert @workspace.drain_task_outputs
    @controller.tick

    entry = @workspace.diagnostics.all(source: :task).fetch(0)
    assert_equal Sadr::Protocol.uri(File.realpath(source)), entry.uri
    assert_equal "broken", entry.diagnostic["message"]
    assert_equal 1, @workspace.panels.fetch("problems").badge

    @workspace.close_task_output
    assert_empty @workspace.diagnostics.all(source: :task)
  end

  def test_stopped_task_finishes_problem_matcher_backlog_before_completion
    source = File.join(@root, "example.rb")
    File.write(source, "puts :ok\n")
    File.write(File.join(@root, ".canopus", "tasks.jsonc"), JSON.generate(
      "problem_matchers" => {"ruby" => {"owner" => "ruby",
        "file_location" => ["relative", "${workspaceFolder}"],
        "pattern" => {"regexp" => "^(.+):(\\d+): (.+)$",
          "file" => 1, "line" => 2, "message" => 3}}},
      "tasks" => [task("diagnostics", "never").merge("problem_matcher" => "ruby")]))

    output = @workspace.run_task("diagnostics")
    output.terminal.output << ("x\n" * 5_000) << "example.rb:1: final\n"
    assert @workspace.drain_task_outputs
    matcher = @workspace.instance_variable_get(:@task_matchers).fetch(output.id)
    assert matcher.pending?

    assert @workspace.stop_task(output)
    wait_until { output.terminal.closed? }
    20.times do
      @workspace.drain_task_outputs
      break if @workspace.instance_variable_get(:@task_finished)[output.id]
    end

    assert @workspace.instance_variable_get(:@task_finished)[output.id]
    assert_equal ["final"], @workspace.diagnostics.all(source: :task)
      .map { |entry| entry.diagnostic["message"] }
  end

  def test_task_diagnostics_batch_distinct_uris_and_skip_an_unchanged_snapshot
    directory = File.join(@root, "cases")
    FileUtils.mkdir_p(directory)
    input = 1_000.times.map do |index|
      path = File.join(directory, "#{index}.rb")
      File.write(path, "puts :ok\n")
      "cases/#{index}.rb:1: issue #{index}\n"
    end.join
    File.write(File.join(@root, ".canopus", "tasks.jsonc"), JSON.generate(
      "problem_matchers" => {"ruby" => {"owner" => "ruby",
        "file_location" => ["relative", "${workspaceFolder}"],
        "pattern" => {"regexp" => "^(.+):(\\d+): (.+)$",
          "file" => 1, "line" => 2, "message" => 3}}},
      "tasks" => [task("diagnostics", "never").merge("problem_matcher" => "ruby")]))

    output = @workspace.run_task("diagnostics")
    matcher = @workspace.instance_variable_get(:@task_matchers).fetch(output.id)
    @workspace.problems_tree
    refreshes = 0
    refresh = @workspace.method(:refresh_problems)
    @workspace.define_singleton_method(:refresh_problems) do
      refreshes += 1
      refresh.call
    end
    queue = @workspace.instance_variable_get(:@main_queue)
    version = @workspace.diagnostics.version

    assert matcher.feed(input, max_seconds: 5)
    assert_equal 1_000, @workspace.diagnostics.version - version
    assert_equal 1_000, @workspace.diagnostics.all(source: :task).length
    assert_equal 1, queue.size
    version = @workspace.diagnostics.version
    refute @workspace.send(:publish_task_diagnostics)
    assert_equal version, @workspace.diagnostics.version
    assert_equal 1, queue.size

    @workspace.drain
    assert_equal 1, refreshes
    assert_equal 0, queue.size
    refute @workspace.send(:publish_task_diagnostics)
    assert_equal 1, refreshes
    assert_equal 0, queue.size
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

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition was not met" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end
end

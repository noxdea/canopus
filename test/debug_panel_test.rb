# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class DebugPanelTest < Minitest::Test
  Registry = Struct.new(:entries)

  class Session
    attr_accessor :references, :stack_future
    attr_reader :variable_requests, :evaluations

    def initialize(frames)
      @frames = frames
      @references = {scope: 101, object: 202}
      @variable_requests, @evaluations = [], 0
      @sequence = 0
    end

    def stack_frames(levels:) = stack_future || complete(@frames.first(levels))

    def scopes(_frame_id)
      complete([Megrez::Scope.new(name: "Locals", variables_reference: references.fetch(:scope),
        expensive: false, presentation_hint: nil)])
    end

    def variables(reference)
      @variable_requests << reference
      values = case reference
      when references.fetch(:scope)
        [Megrez::Variable.new(name: "object", value: "#<Object>", type: "Object",
          variables_reference: references.fetch(:object), named_count: 1, indexed_count: nil, memory_reference: nil)]
      when references.fetch(:object)
        [Megrez::Variable.new(name: "name", value: '"new"', type: "String",
          variables_reference: 0, named_count: nil, indexed_count: nil, memory_reference: nil)]
      else []
      end
      complete(values)
    end

    def evaluate(expression, frame_id:)
      @evaluations += 1
      complete(Megrez::Variable.new(name: expression, value: @evaluations.to_s, type: "Integer",
        variables_reference: references.fetch(:object), named_count: 1, indexed_count: nil, memory_reference: nil))
    end

    def close = nil

    private

    def complete(value)
      @sequence += 1
      Megrez::Future.new(@sequence).fulfill(value)
    end
  end

  class DeferredSession
    attr_reader :requests

    def initialize
      @sequence = 0
      @requests = Hash.new { |hash, key| hash[key] = [] }
    end

    def stack_frames(levels:) = request(:stack, nil)
    def scopes(frame_id) = request(:scopes, frame_id)
    def variables(reference) = request(:variables, reference)
    def evaluate(expression, frame_id:) = request(:evaluate, [expression, frame_id])
    def close = nil

    def resolve(kind, key, value)
      future = @requests.fetch([kind, key]).find { |item| !item.done? }
      raise "no pending #{kind} request for #{key.inspect}" unless future

      future.fulfill(value)
    end

    private

    def request(kind, key)
      @sequence += 1
      Megrez::Future.new(@sequence).tap { |future| @requests[[kind, key]] << future }
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-debug-panel-")
    @source = File.join(@root, "app.rb")
    File.write(@source, "first\nsecond\n")
    @outside_root = Dir.mktmpdir("canopus-debug-panel-outside-")
    @outside = File.join(@outside_root, "outside.rb")
    File.write(@outside, "outside\n")
    @queue, @selected, @reports = [], [], []
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root) if File.exist?(@root)
    FileUtils.remove_entry(@outside_root) if File.exist?(@outside_root)
  end

  def test_variables_restore_name_paths_with_fresh_references_and_watches_reevaluate
    first = frame(1, "first", @source, 1)
    second = frame(2, "second", @source, 2)
    session = Session.new([first, second])
    panel = build_panel
    panel.add_watch("answer")

    panel.stopped(session, first)
    drain
    variables = loaded(panel.tree, Canopus::Debug::Panel::ROOT_VARIABLES)
    scope = variables.first
    panel.tree.expand(scope.fetch(:id))
    drain
    object = loaded(panel.tree, scope.fetch(:id)).first
    panel.tree.expand(object.fetch(:id))
    drain

    assert_equal ["name = \"new\" · String"], loaded(panel.tree, object.fetch(:id)).map { |node| node[:label] }
    assert_equal Set[
      [:variables, ["Locals", 0]],
      [:variables, ["Locals", 0], ["object", 0]]
    ], panel.expanded_paths
    refute_includes panel.expanded_paths.flatten, 101
    refute_includes panel.expanded_paths.flatten, 202
    assert_equal 1, session.evaluations

    session.references = {scope: 701, object: 802}
    panel.stopped(session, first)
    drain

    assert_includes session.variable_requests, 701
    assert_includes session.variable_requests, 802
    assert_equal 2, session.evaluations
    assert_equal ["first · app.rb:1", "second · app.rb:2"],
      loaded(panel.tree, Canopus::Debug::Panel::ROOT_STACK).map { |node| node[:label] }

    panel.remove_watch("answer")
    assert_empty panel.watches
  end

  def test_old_async_results_are_discarded_after_continue
    session = Session.new([frame(1, "old", @source, 1)])
    pending = Megrez::Future.new(99)
    session.stack_future = pending
    panel = build_panel

    panel.stopped(session, frame(1, "initial", @source, 1))
    panel.continued(session)
    pending.fulfill([frame(2, "late", @source, 2)])
    drain

    assert_equal ["Not stopped"],
      loaded(panel.tree, Canopus::Debug::Panel::ROOT_STACK).map { |node| node[:label] }
    assert_nil panel.selected_frame
  end

  def test_frame_switch_discards_queued_scope_and_watch_results
    first = frame(1, "first", @source, 1)
    second = frame(2, "second", @source, 2)
    session = DeferredSession.new
    panel = build_panel
    panel.add_watch("answer")
    panel.stopped(session, first)
    session.resolve(:stack, nil, [first, second])
    drain

    session.resolve(:scopes, 1, [scope("Old", 101)])
    session.resolve(:evaluate, ["answer", 1], variable("answer", "old", 0))
    panel.send(:load_scopes)
    cancelled = session.requests.fetch([:scopes, 1]).last
    old_second = loaded(panel.tree, Canopus::Debug::Panel::ROOT_STACK).last.fetch(:value)
    old_generation = old_second.fetch(:generation)
    panel.send(:select, old_second)
    assert_raises(Megrez::Cancelled) { cancelled.await(timeout: 0) }

    session.resolve(:scopes, 2, [scope("New", 201)])
    session.resolve(:evaluate, ["answer", 2], variable("answer", "new", 0))
    drain

    assert_equal ["New"], loaded(panel.tree, Canopus::Debug::Panel::ROOT_VARIABLES).map { |node| node[:label] }
    assert_equal ["answer = new · String"],
      loaded(panel.tree, Canopus::Debug::Panel::ROOT_WATCHES).map { |node| node[:label] }
    rebuilt = loaded(panel.tree, Canopus::Debug::Panel::ROOT_STACK)
    assert_operator rebuilt.first.dig(:value, :generation), :>, old_generation
    assert rebuilt.all? { |node| node.dig(:value, :generation) == rebuilt.first.dig(:value, :generation) }
  end

  def test_frame_switch_discards_queued_variable_results
    first = frame(1, "first", @source, 1)
    second = frame(2, "second", @source, 2)
    session = DeferredSession.new
    panel = build_panel
    panel.stopped(session, first)
    session.resolve(:stack, nil, [first, second])
    session.resolve(:scopes, 1, [scope("Locals", 101)])
    drain

    first_scope = loaded(panel.tree, Canopus::Debug::Panel::ROOT_VARIABLES).first
    panel.tree.expand(first_scope.fetch(:id))
    session.resolve(:scopes, 1, [scope("Locals", 101)])
    drain
    old_variables = session.requests.fetch([:variables, 101]).last
    old_variables.fulfill([variable("value", "old", 0)])
    second_value = loaded(panel.tree, Canopus::Debug::Panel::ROOT_STACK).last.fetch(:value)
    panel.send(:select, second_value)
    session.resolve(:scopes, 2, [scope("Locals", 201)])
    drain
    session.resolve(:scopes, 2, [scope("Locals", 201)])
    drain
    session.resolve(:variables, 201, [variable("value", "fresh", 0)])
    drain

    scope_node = loaded(panel.tree, Canopus::Debug::Panel::ROOT_VARIABLES).first
    assert_equal ["value = fresh · String"], loaded(panel.tree, scope_node.fetch(:id)).map { |node| node[:label] }
  end

  def test_removed_and_readded_watch_rejects_the_old_result
    session = DeferredSession.new
    panel = build_panel
    panel.stopped(session, frame(1, "first", @source, 1))
    panel.add_watch("answer")
    old = session.requests.fetch([:evaluate, ["answer", 1]]).last
    panel.remove_watch("answer")
    panel.add_watch("answer")
    current = session.requests.fetch([:evaluate, ["answer", 1]]).last

    current.fulfill(variable("answer", "current", 0))
    drain
    old.fulfill(variable("answer", "stale", 0))
    drain

    assert_equal ["answer = current · String"],
      loaded(panel.tree, Canopus::Debug::Panel::ROOT_WATCHES).map { |node| node[:label] }
  end

  def test_lazy_loaders_capture_paths_but_not_dap_responses
    panel = build_panel
    scopes = [scope("Locals", 101)]
    scope_loader = panel.send(:scope_nodes, scopes).first.fetch(:children)
    refute_captured scope_loader, scopes
    refute_captured scope_loader, scopes.first

    variables = [variable("object", "value", 202)]
    path = [["Locals", 0]].freeze
    variable_loader = panel.send(:variable_nodes, variables, path, :variables).first.fetch(:children)
    refute_captured variable_loader, variables
    refute_captured variable_loader, variables.first
  end

  def test_stack_and_dap_text_are_bounded_before_ui_storage
    first = frame(1, "界" * 10_000, "/#{"道" * 10_000}", 1)
    frames = [first] + Canopus::Debug::Panel::ITEM_LIMIT.times.map do |index|
      frame(index + 2, "frame #{index}", @source, 1)
    end
    session = DeferredSession.new
    panel = build_panel
    panel.stopped(session, first)
    session.resolve(:stack, nil, frames)
    drain

    stored = panel.instance_variable_get(:@stack_frames)
    label = loaded(panel.tree, Canopus::Debug::Panel::ROOT_STACK).first.fetch(:label)
    assert_equal Canopus::Debug::Panel::ITEM_LIMIT, stored.length
    assert label.valid_encoding?
    assert_operator label.bytesize, :<=, 603

    value = "界" * 100_000
    bounded = panel.send(:bounded_text, value)
    variable_label = panel.send(:variable_nodes, [variable("value", value, 0)], [], :variables).first.fetch(:label)
    assert_operator bounded.bytesize, :<=, Canopus::Debug::Panel::TEXT_LIMIT
    assert bounded.valid_encoding?
    assert variable_label.valid_encoding?
    assert_operator variable_label.bytesize, :<=, 603
  end

  def test_workspace_registers_commands_and_rejects_stack_sources_outside_the_root
    @workspace = Canopus::Workspace.new(root: @root)
    assert @workspace.panels.key?(:debug)
    assert @workspace.commands.resolve("debug.watch.add")
    assert @workspace.commands.resolve("debug.watch.remove")
    assert @workspace.commands.resolve("panel.debug")

    @workspace.call("debug.watch.add")
    @workspace.palette[:query].replace("answer")
    @workspace.palette_accept
    assert_equal ["answer"], @workspace.debug_watches

    safe = frame(1, "safe", @source, 1)
    outside = frame(2, "outside", @outside, 1)
    session = Session.new([safe, outside])
    @workspace.instance_variable_set(:@debug_session, session)
    generation = @workspace.instance_variable_get(:@debug_generation)
    @workspace.send(:handle_debug_stop, session, generation + 1, safe)
    @workspace.send(:handle_debug_stop, Session.new([safe]), generation, safe)
    assert_nil @workspace.debug_panel.selected_frame

    @workspace.debug_panel.stopped(session, safe)
    settle_workspace
    node = loaded(@workspace.debug_tree, Canopus::Debug::Panel::ROOT_STACK).last

    @workspace.debug_panel.send(:select, node.fetch(:value))

    refute_equal File.realpath(@outside), @workspace.editor&.buffer&.path
    assert @workspace.notifications.any? { |item| item[:text].include?("outside the workspace") }

    @workspace.call("debug.watch.remove")
    @workspace.palette_accept
    assert_empty @workspace.debug_watches
  end

  private

  def frame(id, name, path, line)
    Megrez::StackFrame.new(id: id, name: name, source: {"path" => path}.freeze,
      line: line, column: 1, presentation_hint: nil)
  end

  def scope(name, reference)
    Megrez::Scope.new(name: name, variables_reference: reference, expensive: false, presentation_hint: nil)
  end

  def variable(name, value, reference)
    Megrez::Variable.new(name: name, value: value, type: "String", variables_reference: reference,
      named_count: nil, indexed_count: nil, memory_reference: nil)
  end

  def refute_captured(loader, object)
    captured = loader.binding.local_variables.map { |name| loader.binding.local_variable_get(name) }
    refute captured.any? { |value| value.equal?(object) }
  end

  def build_panel
    entry = Canopus::Debug::Breakpoints::Entry.new("app.rb", 2, nil, nil, nil, true)
    Canopus::Debug::Panel.new(breakpoints: Registry.new([entry]),
      post: ->(&block) { @queue << block },
      select_frame: ->(_session, frame) { @selected << frame },
      select_breakpoint: ->(breakpoint) { @selected << breakpoint },
      report: ->(text) { @reports << text }, request_frame: -> {})
  end

  def loaded(tree, id) = tree.instance_variable_get(:@loaded).fetch(id)

  def drain
    @queue.shift.call until @queue.empty?
  end

  def settle_workspace
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    loop do
      @workspace.drain
      return if loaded(@workspace.debug_tree, Canopus::Debug::Panel::ROOT_STACK).length == 2
      raise "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.005
    end
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "timeout"

class SelectionRangeTest < Minitest::Test
  class Client
    attr_reader :capabilities, :requests, :stopped

    def initialize(*results, supported: true)
      @capabilities = {"selectionRangeProvider" => supported}
      @results, @requests = results, []
    end

    def start = self
    def stop = @stopped = true
    def running? = true
    def state = :running
    def on(*) = nil
    def open(*) = nil
    def change(*) = nil
    def close(*) = nil
    def did_change_configuration(*) = nil
    def diagnostics = {}
    def selection_range(uri, positions)
      @requests << [uri, positions]
      result = @results.shift
      result.respond_to?(:await) ? result : Sadr::Future.new(@requests.length).fulfill(result)
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-selection-range-")
    @path = File.join(@root, "source.rb")
    File.write(@path, "😀alpha beta\ndef call(value)\n  puts(value)\nend\n")
    settings = Canopus::Settings.new("language_servers" => {"ruby" => ["fake"]})
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    @editor = @workspace.open(@path)
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root)
  end

  def test_lsp_expands_all_selections_without_collapsing_and_shrinks_exact_history
    first = offset(0, 2)
    second = offset(0, 8)
    originals = [Canopus::Selection.new(10, first, first, 3), Canopus::Selection.new(11, second, second, nil)]
    @editor.set_selections(originals, merge: false)
    result = [chain(range(0, 2, 7), range(0, 0, 12)), chain(range(0, 8, 12), range(0, 0, 12))]

    with_client(Client.new(result, supported: {})) do |client|
      refute @workspace.expand_selection
      settle
      assert_equal [bytes(0, 2, 7), bytes(0, 8, 12)], @editor.selections.map(&:range)
      assert_equal [10, 11], @editor.selections.map(&:id)

      assert @workspace.expand_selection
      assert_equal [bytes(0, 0, 12), bytes(0, 0, 12)], @editor.selections.map(&:range)
      assert_equal [10, 11], @editor.selections.map(&:id)
      assert_equal 2, @editor.selections.length
      assert_equal 1, client.requests.length

      assert @workspace.shrink_selection
      assert_equal [bytes(0, 2, 7), bytes(0, 8, 12)], @editor.selections.map(&:range)
      assert @workspace.shrink_selection
      assert_equal originals, @editor.selections
      refute @workspace.shrink_selection
    end
  end

  def test_reversed_selection_keeps_direction_and_shrink_restores_goal
    original = Canopus::Selection.new(7, offset(1, 8), offset(1, 4), 9)
    @editor.set_selections([original], merge: false)
    result = [chain(range(1, 4, 8), range(1, 0, 15))]

    with_client(Client.new(result)) do
      @workspace.expand_selection
      settle
      expanded = @editor.primary
      assert expanded.reversed?
      assert_equal bytes(1, 0, 15), expanded.range
      assert @workspace.shrink_selection
      assert_equal original, @editor.primary
    end
  end

  def test_crossing_chains_keep_their_selection_identity_after_sorting
    first = offset(0, 4)
    second = offset(0, 8)
    originals = [Canopus::Selection.new(10, first, first, nil), Canopus::Selection.new(11, second, second, nil)]
    @editor.set_selections(originals, merge: false)
    result = [chain(range(0, 4, 7), range(0, 0, 10)), chain(range(0, 2, 9), range(0, 2, 12))]

    with_client(Client.new(result)) do |client|
      @workspace.expand_selection
      settle
      assert_equal [11, 10], @editor.selections.map(&:id)
      assert @workspace.expand_selection
      assert_equal [10, 11], @editor.selections.map(&:id)
      assert_equal [bytes(0, 0, 10), bytes(0, 2, 12)], @editor.selections.map(&:range)
      assert_equal 1, client.requests.length
      assert @workspace.shrink_selection
      assert_equal [11, 10], @editor.selections.map(&:id)
      assert @workspace.expand_selection
      assert_equal [10, 11], @editor.selections.map(&:id)
      assert_equal [bytes(0, 0, 10), bytes(0, 2, 12)], @editor.selections.map(&:range)
      assert_equal 1, client.requests.length
      assert @workspace.shrink_selection
      assert @workspace.shrink_selection
      assert_equal originals, @editor.selections
    end
  end

  def test_unsupported_nil_and_error_results_use_async_antares
    unsupported = Client.new(supported: false)
    activate(unsupported)
    @editor.select(offset(2, 7))
    @workspace.expand_selection
    settle
    assert_equal "value", @editor.buffer.rope.byteslice(@editor.primary.range).to_s
    assert_empty unsupported.requests

    @editor.select(offset(2, 7))
    nil_client = Client.new(nil)
    replace_client(nil_client)
    @workspace.expand_selection
    settle
    assert_equal "value", @editor.buffer.rope.byteslice(@editor.primary.range).to_s
    assert_equal 1, nil_client.requests.length

    @editor.select(offset(2, 7))
    failure = Sadr::Future.new(3).fulfill(error: Sadr::Error.new("selection failed"))
    error_client = Client.new(failure)
    replace_client(error_client)
    @workspace.expand_selection
    settle
    assert_equal "value", @editor.buffer.rope.byteslice(@editor.primary.range).to_s
  end

  def test_antares_expands_multiple_carets_together
    client = Client.new(supported: false)
    activate(client)
    selections = [Canopus::Selection.new(1, offset(1, 4), offset(1, 4), nil),
      Canopus::Selection.new(2, offset(2, 7), offset(2, 7), nil)]
    @editor.set_selections(selections, merge: false)

    @workspace.expand_selection
    settle

    assert_equal ["call", "value"], @editor.selections.map { |selection| @editor.buffer.rope.byteslice(selection.range).to_s }
    assert_equal 2, @editor.selections.length
  end

  def test_visible_splits_share_one_lsp_request_but_keep_independent_history
    cancelled = []
    future = Sadr::Future.new(1) { |id| cancelled << id }
    client = Client.new(future)
    activate(client)
    @editor.select(offset(0, 2))
    first_pane = @workspace.active_pane
    @workspace.split(:horizontal)
    second = @workspace.editor
    second.select(offset(0, 2))

    @workspace.expand_selection(@editor)
    @workspace.expand_selection(second)
    wait_for_lsp_future(client, 1)
    @workspace.focus(first_pane)
    other = File.join(@root, "split-other.rb")
    File.write(other, "other\n")
    @workspace.open(other)
    assert_empty cancelled
    future.fulfill([chain(range(0, 2, 7))])
    settle

    assert_equal 1, client.requests.length
    assert @editor.primary.empty?
    assert_equal bytes(0, 2, 7), second.primary.range
    assert @workspace.shrink_selection(second)
    assert second.primary.empty?
  end

  def test_external_ranges_are_utf16_exact_nested_and_bounded
    rope = @editor.buffer.rope
    position = offset(0, 2)
    normalize = ->(value) { @workspace.send(:normalize_selection_ranges, rope, [position], value) }
    assert_nil normalize.call(nil)
    assert_equal [[bytes(0, 2, 7), bytes(0, 0, 12)]],
      normalize.call([chain(range(0, 2, 7), range(0, 0, 12))])

    bad_values = ["bad", [], [nil], [chain(range(0, 1, 7))],
      [chain(range(0, 3, 7))], [chain(range(0, 2, 7), range(0, 3, 12))],
      [chain(range(0, 7, 2))], [chain(range(9, 0, 1))]]
    bad_values.each { |value| assert_raises(Canopus::Error, value.inspect) { normalize.call(value) } }

    deep = {"range" => range(0, 0, 12)}
    Canopus::Workspace::LanguageAware::SELECTION_RANGE_DEPTH_LIMIT.times do
      deep = {"range" => range(0, 0, 12), "parent" => deep}
    end
    assert_raises(Canopus::Error) { normalize.call([deep]) }
  end

  def test_edit_settings_close_and_client_retirement_cancel_or_drop_pending_results
    cancelled = []
    edit = Sadr::Future.new(1) { |id| cancelled << id }
    client = Client.new(edit)
    activate(client)
    @workspace.expand_selection
    wait_for_lsp_future(client, 1)
    @editor.insert_text("x", auto_indent: false)
    assert_equal [1], cancelled
    settle
    assert @editor.primary.empty?

    settings = Sadr::Future.new(2) { |id| cancelled << id }
    client.instance_variable_get(:@results) << settings
    @workspace.expand_selection
    wait_for_lsp_future(client, 2)
    @workspace.apply_settings
    assert_equal [1, 2], cancelled
    settle

    retiring = Sadr::Future.new(3) { |id| cancelled << id }
    client.instance_variable_get(:@results) << retiring
    @workspace.expand_selection
    wait_for_lsp_future(client, 3)
    replace_client(Client.new([]))
    assert_equal [1, 2, 3], cancelled
    assert client.stopped

    closing = Sadr::Future.new(4) { |id| cancelled << id }
    replacement = Client.new(closing)
    replace_client(replacement)
    @workspace.expand_selection
    wait_for_lsp_future(replacement, 1)
    @workspace.close
    @workspace = nil
    assert_equal [1, 2, 3, 4], cancelled
  end

  def test_stale_hidden_and_closed_editors_never_apply_delayed_results
    cancelled = []
    future = Sadr::Future.new(1) { |id| cancelled << id }
    client = Client.new(future)
    activate(client)
    @workspace.expand_selection
    wait_for_lsp_future(client, 1)
    other = File.join(@root, "other.rb")
    File.write(other, "other\n")
    @workspace.open(other)
    assert_equal [1], cancelled
    settle
    assert @editor.primary.empty?

    @workspace.activate_tab(@workspace.active_pane, @editor)
    delayed = Sadr::Future.new(2) { |id| cancelled << id }
    client.instance_variable_get(:@results) << delayed
    @workspace.expand_selection
    wait_for_lsp_future(client, 2)
    @workspace.close_editor(@editor, discard: true)
    assert_equal [1, 2], cancelled
    settle
    assert @editor.primary.empty?
  end

  def test_initial_client_startup_edit_is_rejected_and_timeout_is_bounded
    client = Client.new([chain(range(0, 0, 7))])
    original = @workspace.method(:language_client)
    started, release = Queue.new, Queue.new
    delayed = lambda do |buffer|
      started << true
      release.pop
      original.call(buffer)
    end
    with_client(client) do
      @workspace.stub(:language_client, delayed) do
        @workspace.expand_selection
        Timeout.timeout(3) { started.pop }
        @editor.insert_text("x", auto_indent: false)
        release << true
        settle
      end
    end
    assert_empty(@workspace.instance_variable_get(:@pending_selection_ranges) || {})

    timeouts = []
    timed = Object.new
    timed.define_singleton_method(:await) { |timeout:| timeouts << timeout; nil }
    timed.define_singleton_method(:cancel) { false }
    replace_client(Client.new(timed))
    @workspace.expand_selection
    settle
    assert_equal [10], timeouts
  end

  def test_failed_initial_client_startup_after_edit_clears_pending_state
    started, release = Queue.new, Queue.new
    failing = lambda do |_buffer|
      started << true
      release.pop
      raise Canopus::Error, "start failed"
    end
    @workspace.stub(:language_client, failing) do
      @workspace.expand_selection
      Timeout.timeout(3) { started.pop }
      @editor.insert_text("x", auto_indent: false)
      release << true
      settle
    end

    assert_empty(@workspace.instance_variable_get(:@pending_selection_ranges) || {})
    assert_empty(@workspace.instance_variable_get(:@selection_range_requests) || {})
    assert_empty(@workspace.instance_variable_get(:@language_jobs) || {})
  end

  def test_new_buffer_cancels_a_request_for_the_hidden_editor
    cancelled = []
    future = Sadr::Future.new(1) { |id| cancelled << id }
    client = Client.new(future)
    activate(client)
    @workspace.expand_selection
    wait_for_lsp_future(client, 1)

    @workspace.new_buffer

    assert_equal [1], cancelled
    assert_empty(@workspace.instance_variable_get(:@pending_selection_ranges) || {})
    settle
    assert_empty(@workspace.instance_variable_get(:@language_jobs) || {})
  end

  def test_request_limit_falls_back_and_capability_change_uses_lsp
    client = Client.new([chain(range(0, 0, 7))], supported: false)
    activate(client)
    @workspace.expand_selection
    settle
    assert_empty client.requests

    @editor.select(0)
    client.capabilities["selectionRangeProvider"] = {}
    @workspace.expand_selection
    settle
    assert_equal 1, client.requests.length

    @editor.select(offset(2, 7))
    @workspace.invalidate_selection_ranges(editor: @editor)
    requests = {}
    Canopus::Workspace::LanguageAware::SELECTION_RANGE_REQUEST_LIMIT.times do |id|
      requests[id] = {buffer: Canopus::Buffer.new("x"), version: 0, client: Object.new}
    end
    @workspace.instance_variable_set(:@selection_range_requests, requests)
    @workspace.expand_selection
    assert_equal :antares, @workspace.instance_variable_get(:@pending_selection_ranges).fetch(@editor).fetch(:source)
  ensure
    requests&.each_value { |request| request[:buffer].close }
  end

  def test_default_keys_reserve_alt_arrows_for_selection
    keys = Canopus::Command::DEFAULT_KEYBINDINGS
    assert_equal({"alt-up" => ""}, keys.fetch("language.expand_selection"))
    assert_equal({"alt-down" => ""}, keys.fetch("language.shrink_selection"))
    assert_equal({"alt-shift-up" => ""}, keys.fetch("edit.move_line_up"))
    assert_equal({"alt-shift-down" => ""}, keys.fetch("edit.move_line_down"))
  end

  private

  def point(line, character) = {"line" => line, "character" => character}
  def range(line, first, last) = {"start" => point(line, first), "end" => point(line, last)}
  def chain(*ranges)
    ranges.reverse_each.reduce(nil) do |parent, current|
      {"range" => current}.tap { |value| value["parent"] = parent if parent }
    end
  end
  def offset(line, character)
    Sadr::Protocol.offset(@editor.buffer.rope, Sadr::Position.new(line: line, character: character))
  end
  def bytes(line, first, last) = offset(line, first)...offset(line, last)

  def with_client(client)
    Sadr::Client.stub(:new, client) { yield client }
  end

  def activate(client)
    with_client(client) { @workspace.language_client(@editor.buffer) }
    client
  end

  def replace_client(client)
    Sadr::Client.stub(:new, client) do
      configured = @workspace.send(:normalize_server_options, ["fake"])
      @workspace.instance_variable_get(:@client_options)["ruby"] =
        @workspace.send(:normalize_server_options, ["retired", client.object_id.to_s])
      @workspace.send(:ensure_language_server, "ruby", configured)
    end
    client
  end

  def settle
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      @workspace.drain
      @workspace.panes.flat_map(&:editors).each do |current|
        document = current.language_document
        document.poll
        @workspace.language_ready(current, document)
      end
      jobs = @workspace.instance_variable_get(:@language_jobs) || []
      documents = @workspace.panes.flat_map(&:editors).map(&:language_document).uniq
      break unless jobs.any?(&:alive?) || documents.any?(&:pending?)
      raise "selection range did not settle" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.001
    end
    @workspace.drain
  end

  def wait_for_lsp_future(client, count)
    wait_until do
      requests = @workspace.instance_variable_get(:@selection_range_requests)&.values || []
      client.requests.length == count && requests.any? { |request| request[:future] }
    end
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.001 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    raise "selection range request did not start" unless yield
  end
end

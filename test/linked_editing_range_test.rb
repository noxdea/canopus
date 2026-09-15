# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class LinkedEditingRangeTest < Minitest::Test
  class Client
    attr_reader :capabilities, :requests, :stopped

    def initialize(*results, supported: true)
      @capabilities = {"linkedEditingRangeProvider" => supported}
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
    def linked_editing_range(uri, position)
      @requests << [uri, position]
      result = @results.shift
      result.respond_to?(:await) ? result : Sadr::Future.new(@requests.length).fulfill(result)
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-linked-editing-")
    @path = File.join(@root, "source.rb")
    File.write(@path, "tag middle tag\n")
    settings = Canopus::Settings.new("language_servers" => {"ruby" => ["fake"]})
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    @editor = @workspace.open(@path)
  end

  def teardown
    @workspace.close
    FileUtils.remove_entry(@root)
  end

  def test_maps_the_current_selection_to_each_linked_range
    result = linked(range(0, 3), range(11, 14), pattern: "[a-z]+")
    with_client(Client.new(result)) do |client|
      @editor.select(1)
      @workspace.call("language.linked_editing")
      settle

      assert_equal [[1, 1], [12, 12]], @editor.selections.map { |selection| [selection.anchor, selection.head] }
      assert_equal 1, client.requests.first.last.character
      assert_equal "Linked ranges selected", @workspace.message
    end

    replace_client(Client.new(result))
    @editor.select(0, 3)
    @workspace.linked_editing_range
    settle
    assert_equal [[0, 3], [11, 14]], @editor.selections.map { |selection| [selection.anchor, selection.head] }
  end

  def test_edit_caret_hide_retirement_and_supersede_cancel_pending_requests
    cancelled = []
    first = Sadr::Future.new(1) { |id| cancelled << id }
    client = Client.new(first)
    with_client(client) do
      @workspace.linked_editing_range
      wait_until { client.requests.length == 1 }
      @editor.select(1)
      assert_equal [1], cancelled

      second = Sadr::Future.new(2) { |id| cancelled << id }
      client.instance_variable_get(:@results) << second
      @workspace.linked_editing_range
      wait_until { client.requests.length == 2 }
      @editor.insert_text("x", auto_indent: false)
      assert_equal [1, 2], cancelled

      third = Sadr::Future.new(3) { |id| cancelled << id }
      client.instance_variable_get(:@results) << third
      @workspace.linked_editing_range
      wait_until { client.requests.length == 3 }
      other = File.join(@root, "other.rb")
      File.write(other, "other\n")
      @workspace.open(other)
      assert_equal [1, 2, 3], cancelled

      @workspace.activate_tab(@workspace.active_pane, @editor)
      fourth = Sadr::Future.new(4) { |id| cancelled << id }
      fifth = Sadr::Future.new(5) { |id| cancelled << id }
      client.instance_variable_get(:@results).push(fourth, fifth)
      @workspace.linked_editing_range
      wait_until { client.requests.length == 4 }
      @workspace.linked_editing_range
      wait_until { client.requests.length == 5 }
      assert_equal [1, 2, 3, 4], cancelled
      replace_client(Client.new(linked(range(0, 3), range(11, 14))))
      assert_equal [1, 2, 3, 4, 5], cancelled
    end
  end

  def test_unsupported_null_errors_and_timeout_are_bounded
    with_client(Client.new(supported: false)) do |client|
      refute @workspace.linked_editing_range
      assert_empty client.requests
      assert_match(/does not support/, @workspace.message)
    end

    replace_client(Client.new(nil))
    @workspace.linked_editing_range
    settle
    assert_equal "Linked editing is not available here", @workspace.message

    failure = Sadr::Future.new(2).fulfill(error: Sadr::Error.new("linked failed"))
    replace_client(Client.new(failure))
    @workspace.linked_editing_range
    settle
    assert_equal "linked failed", @workspace.message

    timed = Object.new
    timeouts = []
    timed.define_singleton_method(:await) { |timeout:| timeouts << timeout; linked(range(0, 3), range(11, 14)) }
    timed.define_singleton_method(:cancel) { false }
    replace_client(Client.new(timed))
    @workspace.linked_editing_range
    settle
    assert_equal [10], timeouts
  end

  def test_external_ranges_and_word_pattern_are_strict_and_bounded
    rope = @editor.buffer.rope
    selection = Canopus::Selection.new(0, 1, 1, nil)
    normalize = ->(value) { @workspace.send(:normalize_linked_editing_ranges, rope, 1, selection, value) }
    assert_nil normalize.call(nil)
    assert_empty normalize.call({"ranges" => []})[:ranges]
    assert_equal [0...3, 11...14], normalize.call(linked(range(0, 3), range(11, 14), pattern: "[a-z]+"))[:ranges]
    [
      {"ranges" => Array.new(257, range(0, 1))},
      linked(range(0, 3), range(2, 4)),
      linked(range(4, 7), range(11, 14)),
      linked(range(0, 3), range(11, 14), pattern: "["),
      linked(range(0, 3), range(11, 14), pattern: "x" * 4097),
      {"ranges" => [range(0, 3)], "extension" => true}
    ].each { |value| assert_raises(Canopus::Error) { normalize.call(value) } }
    assert_raises(Canopus::Error) do
      @workspace.send(:normalize_linked_editing_ranges, rope, 3,
        Canopus::Selection.new(0, 3, 3, nil), linked(range(0, 3), range(11, 14)))
    end
  end

  def test_settings_reload_and_workspace_close_cancel_requests
    cancelled = []
    pending = Sadr::Future.new(1) { |id| cancelled << id }
    with_client(Client.new(pending)) do |client|
      @workspace.linked_editing_range
      wait_until { client.requests.length == 1 }
      @workspace.apply_settings
      assert_equal [1], cancelled

      next_pending = Sadr::Future.new(2) { |id| cancelled << id }
      client.instance_variable_get(:@results) << next_pending
      @workspace.linked_editing_range
      wait_until { client.requests.length == 2 }
      @workspace.close
      assert_equal [1, 2], cancelled
    end
  end

  def test_language_change_discards_the_snapshot
    pending = Sadr::Future.new(1)
    with_client(Client.new(pending)) do |client|
      @workspace.linked_editing_range
      wait_until { client.requests.length == 1 }
      @editor.language = Canopus::Language::PLAIN
      pending.fulfill(linked(range(0, 3), range(11, 14)))
      settle

      assert_equal [[0, 0]], @editor.selections.map { |selection| [selection.anchor, selection.head] }
      refute_equal "Linked ranges selected", @workspace.message
    end
  end

  private

  def point(character) = {"line" => 0, "character" => character}
  def range(first, last) = {"start" => point(first), "end" => point(last)}
  def linked(*ranges, pattern: nil)
    {"ranges" => ranges}.tap { |value| value["wordPattern"] = pattern if pattern }
  end

  def with_client(client)
    Sadr::Client.stub(:new, client) { @workspace.language_client(@editor.buffer) }
    yield client
  end

  def replace_client(client)
    Sadr::Client.stub(:new, client) do
      configured = @workspace.send(:normalize_server_options, ["fake"])
      @workspace.instance_variable_get(:@client_options)["ruby"] =
        @workspace.send(:normalize_server_options, ["retired", client.object_id.to_s])
      @workspace.send(:ensure_language_server, "ruby", configured)
    end
  end

  def settle
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    loop do
      @workspace.drain
      jobs = @workspace.instance_variable_get(:@language_jobs) || []
      break unless jobs.any?(&:alive?)
      raise "linked editing did not settle" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.001
    end
    @workspace.drain
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.001 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    raise "linked editing request did not start" unless yield
  end
end

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

  def test_new_nonmarkup_client_without_support_keeps_the_existing_message
    client = Client.new(supported: false)
    Sadr::Client.stub(:new, client) do
      @workspace.linked_editing_range
      settle
    end

    assert_empty client.requests
    assert_equal "Language server does not support linked editing", @workspace.message
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

  def test_html_fallback_matches_either_side_nested_names_and_quoted_greater_than
    source = %(<DIV title=">"><div><DIV>body</div></DIV></div>)
    open_markup(source)

    run_linked_editing(byte_offset(source, "DIV", 0) + 1)
    assert_equal [byte_offset(source, "DIV", 0) + 1, byte_offset(source, "div", 2) + 1],
      @editor.selections.map(&:head)

    run_linked_editing(byte_offset(source, "div", 1) + 1)
    assert_equal [byte_offset(source, "DIV", 1) + 1, byte_offset(source, "div", 1) + 1],
      @editor.selections.map(&:head)
  end

  def test_xml_fallback_skips_special_markup_and_matches_unicode_exactly
    source = %(<?pi value=">"?><!DOCTYPE 日本 [<!ELEMENT 日本 ANY>]><!-- <日本> --><![CDATA[<日本>]]><日本 value=">"><子></子></日本>)
    open_markup(source, extension: ".xml")

    run_linked_editing(byte_offset(source, "日本", 4))
    assert_equal [byte_offset(source, "日本", 4), byte_offset(source, "日本", 5)], @editor.selections.map(&:head)

    source = "<Ä></ä>"
    open_markup(source, extension: ".xml")
    run_linked_editing(byte_offset(source, "Ä"))
    assert_equal "Linked editing is not available here", @workspace.message
  end

  def test_markup_fallback_ignores_void_and_self_closing_tags_and_rejects_ambiguity
    source = %(<root><br title=">"><leaf/></root>)
    open_markup(source)
    run_linked_editing(byte_offset(source, "root") + 1)
    assert_equal [byte_offset(source, "root", 0) + 1, byte_offset(source, "root", 1) + 1],
      @editor.selections.map(&:head)

    run_linked_editing(byte_offset(source, "br") + 1)
    assert_equal "Linked editing is not available here", @workspace.message

    ["<x><x></x>", "<ul><li>one<li>two</ul>", "<div><%= value %></div>"].each do |invalid|
      open_markup(invalid)
      run_linked_editing(byte_offset(invalid, invalid[/[A-Za-z]+/]))
      assert_equal "Linked editing is not available here", @workspace.message
    end

    explicit = "<html><body><p><span></span></p></body></html>"
    open_markup(explicit)
    run_linked_editing(byte_offset(explicit, "span") + 1)
    assert_equal [byte_offset(explicit, "span", 0) + 1, byte_offset(explicit, "span", 1) + 1],
      @editor.selections.map(&:head)
  end

  def test_markup_fallback_preserves_reversed_partial_selection_and_one_undo
    source = "<widget></widget>"
    open_markup(source, extension: ".xhtml")
    first = byte_offset(source, "widget")
    @editor.select(first + 4, first + 2)
    @workspace.linked_editing_range
    settle
    assert_equal [[first + 4, first + 2], [first + 13, first + 11]],
      @editor.selections.map { |selection| [selection.anchor, selection.head] }

    @editor.select(first, first + 6)
    @workspace.linked_editing_range
    settle
    @editor.insert_text("node", auto_indent: false)
    assert_equal "<node></node>", @editor.buffer.text
    assert @editor.undo
    assert_equal source, @editor.buffer.text
  end

  def test_nonmarkup_without_a_server_has_no_fallback
    path = File.join(@root, "plain.txt")
    File.write(path, "<tag></tag>")
    @editor = @workspace.open(path)
    @editor.select(2)

    refute @workspace.linked_editing_range
    assert_equal [[2, 2]], @editor.selections.map { |selection| [selection.anchor, selection.head] }
    assert_equal "Linked editing is not available here", @workspace.message
  end

  def test_html_fallback_keeps_lsp_priority_and_covers_unavailable_server_results
    source = "<tag></tag> other"
    open_configured_markup(source)
    result = linked(range(1, 4), range(7, 10), range(12, 17))
    with_client(Client.new(result)) do |client|
      run_linked_editing(2)
      assert_equal [2, 8, 13], @editor.selections.map(&:head)
      assert_equal 1, client.requests.length
    end

    clients = [Client.new(supported: false), Client.new(nil),
      Client.new(Sadr::Future.new(2).fulfill(error: Sadr::Error.new("failed")))]
    timeout = Object.new
    cancelled = false
    timeout.define_singleton_method(:await) { |timeout:| raise Sadr::Timeout, "timed out after #{timeout}" }
    timeout.define_singleton_method(:cancel) { cancelled = true }
    clients << Client.new(timeout)
    clients.each do |client|
      replace_client(client)
      run_linked_editing(2)
      assert_equal [2, 8], @editor.selections.map(&:head)
    end
    assert_empty clients.first.requests
    assert cancelled
  end

  def test_markup_fallback_discards_selection_edit_and_hidden_tab_snapshots
    %i[selection edit tab].each do |change|
      source = "<tag></tag>"
      open_markup(source)
      started, release = Queue.new, Queue.new
      original = @workspace.method(:markup_linked_editing_ranges)
      matcher = proc do |snapshot|
        started << true
        release.pop
        original.call(snapshot)
      end
      @workspace.stub(:markup_linked_editing_ranges, matcher) do
        @editor.select(2)
        @workspace.linked_editing_range
        started.pop
        case change
        when :selection then @editor.select(3)
        when :edit then @editor.insert_text("x", auto_indent: false)
        when :tab
          other = File.join(@root, "hidden-#{change}.txt")
          File.write(other, "other")
          @workspace.open(other)
        end
        release << true
        settle
      end
      assert_equal 1, @editor.selections.length
      refute_equal "Linked ranges selected", @workspace.message
    end
  end

  def test_markup_fallback_limits_fail_closed
    ["<#{"x" * 1_025}></#{"x" * 1_025}>",
      ("<x>" * 257) + ("</x>" * 257),
      ("<x/>" * 10_001) + "<tag></tag>",
      "<tag></tag>" + (" " * ((1 << 20) + 1))].each do |source|
      open_markup(source)
      run_linked_editing(source.b.index("tag".b) || 1)
      assert_equal "Linked editing is not available here", @workspace.message
    end
  end

  private

  def point(character) = {"line" => 0, "character" => character}
  def range(first, last) = {"start" => point(first), "end" => point(last)}
  def linked(*ranges, pattern: nil)
    {"ranges" => ranges}.tap { |value| value["wordPattern"] = pattern if pattern }
  end

  def open_markup(source, extension: ".html")
    @markup_index = @markup_index.to_i + 1
    path = File.join(@root, "markup-#{@markup_index}#{extension}")
    File.write(path, source)
    @editor = @workspace.open(path)
  end

  def open_configured_markup(source)
    @workspace.close
    settings = Canopus::Settings.new("language_servers" => {"html" => ["fake"]})
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    open_markup(source)
  end

  def run_linked_editing(offset)
    @editor.select(offset)
    @workspace.linked_editing_range
    settle
  end

  def byte_offset(source, value, occurrence = 0)
    offset = -1
    (occurrence + 1).times { offset = source.b.index(value.b, offset + 1) }
    offset
  end

  def with_client(client)
    Sadr::Client.stub(:new, client) { @workspace.language_client(@editor.buffer) }
    yield client
  end

  def replace_client(client)
    language = @editor.language_document.definition.name
    Sadr::Client.stub(:new, client) do
      configured = @workspace.send(:normalize_server_options, ["fake"])
      @workspace.instance_variable_get(:@client_options)[language] =
        @workspace.send(:normalize_server_options, ["retired", client.object_id.to_s])
      @workspace.send(:ensure_language_server, language, configured)
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

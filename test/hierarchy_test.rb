# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class HierarchyTest < Minitest::Test
  class Client
    attr_reader :capabilities, :prepare_call_requests, :prepare_type_requests,
      :incoming_requests, :outgoing_requests, :supertype_requests, :subtype_requests, :stopped

    def initialize(call: [], type: [], incoming: [], outgoing: [], supertypes: [], subtypes: [], supported: true)
      provider = supported ? {} : false
      @capabilities = {"callHierarchyProvider" => provider, "typeHierarchyProvider" => provider}
      @results = {call: call, type: type, incoming: incoming, outgoing: outgoing,
        supertypes: supertypes, subtypes: subtypes}
      @prepare_call_requests, @prepare_type_requests = [], []
      @incoming_requests, @outgoing_requests, @supertype_requests, @subtype_requests = [], [], [], []
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
    def prepare_call_hierarchy(uri, position) = request(:call, @prepare_call_requests, [uri, position])
    def prepare_type_hierarchy(uri, position) = request(:type, @prepare_type_requests, [uri, position])
    def call_hierarchy_incoming_calls(item) = request(:incoming, @incoming_requests, item)
    def call_hierarchy_outgoing_calls(item) = request(:outgoing, @outgoing_requests, item)
    def type_hierarchy_supertypes(item) = request(:supertypes, @supertype_requests, item)
    def type_hierarchy_subtypes(item) = request(:subtypes, @subtype_requests, item)

    private

    def request(kind, requests, value)
      requests << value
      result = @results.fetch(kind).shift
      result.respond_to?(:await) ? result : Sadr::Future.new(requests.length).fulfill(result || [])
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-hierarchy-")
    @source = File.join(@root, "source.rb")
    @target = File.join(@root, "target.rb")
    File.write(@source, "😀target\n")
    File.write(@target, "class Target\nend\n")
    settings = Canopus::Settings.new("language_servers" => {"ruby" => ["fake"]})
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    @editor = @workspace.open(@source)
    @editor.select(4)
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root)
  end

  def test_call_hierarchy_prepares_a_panel_and_loads_each_direction_without_blocking
    pending = Sadr::Future.new(40)
    root = item("target", @source, 2, 8)
    child = item("Target", @target, 6, 12, detail: "class")
    client = Client.new(call: [[root]], incoming: [pending], outgoing: [[]])
    activate(client)

    @workspace.show_call_hierarchy
    settle

    assert @workspace.panels.visible?(:hierarchy)
    assert_equal 2, client.prepare_call_requests.first.last.character
    tree = @workspace.hierarchy_tree
    root_node = tree.instance_variable_get(:@source).first
    incoming, outgoing = root_node.fetch(:children)
    assert_equal ["Incoming calls", "Outgoing calls"], [incoming[:label], outgoing[:label]]
    tree.expand(root_node[:id])
    tree.expand(incoming[:id])
    wait_until { client.incoming_requests.length == 1 }
    assert_equal "Loading…", tree.instance_variable_get(:@loaded).fetch(incoming[:id]).first[:label]

    pending.fulfill([
      {"from" => root, "fromRanges" => [root.fetch("selectionRange")]},
      {"from" => child, "fromRanges" => [child.fetch("selectionRange")]},
      {"from" => child, "fromRanges" => [child.fetch("selectionRange")]}
    ])
    settle

    children = tree.instance_variable_get(:@loaded).fetch(incoming[:id])
    assert_equal ["Target — class · target.rb:1"], children.map { |entry| entry[:label] }, @workspace.message
    assert @workspace.send(:select_hierarchy_item, children.first[:value])
    assert_equal File.realpath(@target), @workspace.editor.buffer.path
    assert_equal 6, @workspace.editor.primary.head

    tree.expand(outgoing[:id])
    settle
    assert_equal 1, client.outgoing_requests.length
    assert_equal "No results", tree.instance_variable_get(:@loaded).fetch(outgoing[:id]).first[:label]

    @workspace.close_editor(@editor, discard: true)
    refute @workspace.panels.visible?(:hierarchy)
  end

  def test_multiple_type_roots_use_the_palette_before_showing_lazy_type_directions
    first = item("First", @source, 2, 8)
    second = item("Target", @target, 6, 12)
    client = Client.new(type: [[first, second]], supertypes: [[first]])
    activate(client)

    @workspace.show_type_hierarchy
    settle

    assert_equal :hierarchy_roots, @workspace.palette[:kind]
    refute @workspace.panels.visible?(:hierarchy)
    @workspace.palette[:index] = 1
    @workspace.palette_accept

    assert @workspace.panels.visible?(:hierarchy)
    tree = @workspace.hierarchy_tree
    root = tree.instance_variable_get(:@source).first
    assert_match(/Target/, root[:label])
    assert_equal ["Supertypes", "Subtypes"], root[:children].map { |entry| entry[:label] }
    tree.expand(root[:id])
    tree.expand(root[:children].first[:id])
    settle
    assert_equal 1, client.supertype_requests.length
  end

  def test_external_items_require_bounded_local_locations_and_strict_call_ranges
    valid = item("target", @source, 2, 8)
    assert_equal [valid], @workspace.send(:normalize_hierarchy_items, [valid])

    invalid_utf8 = "x".b.force_encoding(Encoding::UTF_8)
    invalid_utf8.setbyte(0, 0xff)
    invalid = [
      valid.merge("name" => ""), valid.merge("name" => invalid_utf8), valid.merge("kind" => 27),
      valid.merge("uri" => "https://example.test/source.rb"),
      valid.merge("uri" => "file://remote/source.rb"),
      valid.merge("selectionRange" => range(0, 9)),
      valid.merge("data" => "x" * ((1 << 20) + 1))
    ]
    invalid.each do |value|
      assert_raises(Canopus::Error, value.inspect.byteslice(0, 80)) do
        @workspace.send(:normalize_hierarchy_items, [value])
      end
    end
    assert_raises(Canopus::Error) do
      @workspace.send(:normalize_hierarchy_followup, :call, :incoming,
        [{"from" => valid, "fromRanges" => [range(9, 10)]}], within: valid)
    end
    assert_equal [valid], @workspace.send(:normalize_hierarchy_followup, :call, :incoming,
      [{"from" => valid, "fromRanges" => [range(8, 8)]}], within: valid)
    assert_raises(Canopus::Error) do
      @workspace.send(:normalize_hierarchy_items,
        Array.new(Canopus::Workspace::HierarchyAware::HIERARCHY_ITEM_LIMIT + 1, valid))
    end
  end

  def test_prepare_is_cancelled_by_supersede_edit_hidden_tab_settings_and_close
    cancelled = []
    futures = (1..5).map { |id| Sadr::Future.new(id) { |value| cancelled << value } }
    client = Client.new(call: futures.dup)
    activate(client)

    @workspace.show_call_hierarchy
    wait_until { client.prepare_call_requests.length == 1 }
    @workspace.show_call_hierarchy
    wait_until { client.prepare_call_requests.length == 2 }
    assert_equal [1], cancelled

    @editor.select(5)
    assert_equal [1, 2], cancelled
    @editor.select(4)
    @workspace.show_call_hierarchy
    wait_until { client.prepare_call_requests.length == 3 }
    @editor.insert_text("x", auto_indent: false)
    assert_equal [1, 2, 3], cancelled

    @editor.select(4)
    @workspace.show_call_hierarchy
    wait_until { client.prepare_call_requests.length == 4 }
    other = File.join(@root, "other.rb")
    File.write(other, "other\n")
    @workspace.open(other)
    assert_equal [1, 2, 3, 4], cancelled

    @workspace.activate_tab(@workspace.active_pane, @editor)
    @workspace.show_call_hierarchy
    wait_until { client.prepare_call_requests.length == 5 }
    @workspace.apply_settings
    assert_equal [1, 2, 3, 4, 5], cancelled
    assert_empty(@workspace.instance_variable_get(:@hierarchy_prepare_requests) || {})

    closing = Sadr::Future.new(6) { |id| cancelled << id }
    client.instance_variable_get(:@results)[:call] << closing
    @workspace.show_call_hierarchy
    wait_until { client.prepare_call_requests.length == 6 }
    @workspace.close
    @workspace = nil
    assert_equal [1, 2, 3, 4, 5, 6], cancelled
  end

  def test_capability_change_and_startup_edit_discard_late_prepare_results
    pending = Sadr::Future.new(1)
    root = item("target", @source, 2, 8)
    client = Client.new(call: [pending, [root]])
    activate(client)
    @workspace.show_call_hierarchy
    wait_until { client.prepare_call_requests.length == 1 }
    client.capabilities["callHierarchyProvider"] = false
    pending.fulfill([root])
    settle
    refute @workspace.panels.visible?(:hierarchy)

    client.capabilities["callHierarchyProvider"] = {}
    original = @workspace.method(:language_client)
    started, release = Queue.new, Queue.new
    delayed = lambda do |buffer|
      started << true
      release.pop
      original.call(buffer)
    end
    @workspace.stub(:language_client, delayed) do
      @workspace.show_call_hierarchy
      started.pop
      @editor.insert_text("x", auto_indent: false)
      release << true
      settle
    end
    refute @workspace.panels.visible?(:hierarchy)
    assert_empty(@workspace.instance_variable_get(:@hierarchy_prepare_requests) || {})
  end

  def test_retirement_cancels_lazy_children_and_hides_the_panel
    pending = Sadr::Future.new(9) { |id| @cancelled = id }
    root = item("target", @source, 2, 8)
    client = Client.new(call: [[root]], incoming: [pending])
    activate(client)
    @workspace.show_call_hierarchy
    settle
    tree = @workspace.hierarchy_tree
    node = tree.instance_variable_get(:@source).first
    tree.expand(node[:id])
    tree.expand(node[:children].first[:id])
    wait_until { client.incoming_requests.length == 1 }

    replacement = Client.new
    replace_client(replacement)

    assert_equal 9, @cancelled
    refute @workspace.panels.visible?(:hierarchy)
    assert client.stopped
    pending.fulfill([])
    settle
    assert_empty tree.instance_variable_get(:@source)
  end

  def test_hierarchy_panel_does_not_restore_without_ephemeral_tree_state
    Dir.mktmpdir("canopus-hierarchy-session-") do |root|
      settings = Canopus::Settings.new("dock" => {"panels" => {
        "hierarchy" => {"visible" => true, "size" => 200}
      }})
      workspace = Canopus::Workspace.new(root: root, settings: settings)
      workspace.new_buffer
      refute workspace.panels.visible?(:hierarchy)

      workspace.panels.show(:hierarchy)
      session = File.join(root, "session.json")
      workspace.save_session(session)
      workspace.restore_session(session)

      refute workspace.panels.visible?(:hierarchy)
      refute workspace.docks[:right][:visible]
    ensure
      workspace&.close
    end
  end

  private

  def point(character, line: 0) = {"line" => line, "character" => character}
  def range(first, last, line: 0) = {"start" => point(first, line: line), "end" => point(last, line: line)}

  def item(name, path, first, last, detail: nil)
    value = {"name" => name, "kind" => 5, "uri" => Sadr::Protocol.uri(path),
      "range" => range(0, last), "selectionRange" => range(first, last), "data" => {"id" => name}}
    value["detail"] = detail if detail
    value
  end

  def with_client(client)
    Sadr::Client.stub(:new, client) { yield client }
  end

  def activate(client)
    with_client(client) { @workspace.language_client(@editor.buffer) }
    client
  end

  def replace_client(client)
    with_client(client) do
      configured = @workspace.send(:normalize_server_options, ["fake"])
      @workspace.instance_variable_get(:@client_options)["ruby"] =
        @workspace.send(:normalize_server_options, ["retired", client.object_id.to_s])
      @workspace.send(:ensure_language_server, "ruby", configured)
    end
  end

  def settle
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      @workspace.drain
      jobs = @workspace.instance_variable_get(:@language_jobs) || []
      break unless jobs.any?(&:alive?)
      raise "hierarchy request did not settle" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.001
    end
    @workspace.drain
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.001 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    raise "hierarchy request did not start" unless yield
  end
end

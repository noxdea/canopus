# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "timeout"

class FoldingRangeTest < Minitest::Test
  class Client
    attr_reader :capabilities, :requests, :stopped

    def initialize(*results, supported: true)
      @capabilities = {"foldingRangeProvider" => supported}
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
    def folding_range(uri)
      @requests << uri
      result = @results.shift
      result.respond_to?(:await) ? result : Sadr::Future.new(@requests.length).fulfill(result)
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-folding-range-")
    @path = File.join(@root, "source.rb")
    File.write(@path, "😀outer\n  inner\n    body\n  end\nend\n")
    settings = Canopus::Settings.new("language_servers" => {"ruby" => ["fake"]})
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    @editor = @workspace.open(@path)
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root)
  end

  def test_lsp_ranges_are_utf16_exact_cached_per_buffer_and_choose_the_innermost_fold
    result = [fold(0, 4), fold(1, 3, 2, 5)]
    client = Client.new(result, supported: {})
    with_client(client) do
      @editor.select(@editor.buffer.rope.line_start(2))
      10.times { @workspace.fold_current }
      settle
    end

    expected_inner = offset(1, 2)...offset(3, 5)
    assert_equal [expected_inner], @editor.display_map.fold_map.ranges
    assert_equal 1, client.requests.length

    @editor.display_map.unfold(@editor.buffer.rope.line_start(2))
    @workspace.split(:horizontal)
    second = @workspace.editor
    second.select(0)
    @workspace.fold_current
    expected_outer = line_end(0)...line_end(4)
    assert_equal [expected_outer], second.display_map.fold_map.ranges
    assert_equal 1, client.requests.length
  end

  def test_unsupported_nil_and_error_results_fall_back_to_async_antares
    unsupported = Client.new(supported: false)
    activate(unsupported)
    @workspace.fold_current
    assert_empty @editor.display_map.fold_map.ranges
    settle
    assert_equal [line_end(0)...line_end(3)], @editor.display_map.fold_map.ranges
    assert_empty unsupported.requests

    @editor.display_map.unfold(line_end(0))
    nil_client = Client.new(nil)
    replace_client(nil_client)
    @workspace.fold_current
    settle
    assert_equal 1, nil_client.requests.length
    assert_equal [line_end(0)...line_end(3)], @editor.display_map.fold_map.ranges

    @editor.display_map.unfold(line_end(0))
    error = Sadr::Future.new(3).fulfill(error: Sadr::Error.new("fold failed"))
    error_client = Client.new(error)
    replace_client(error_client)
    @workspace.fold_current
    settle
    @editor.display_map.unfold(line_end(0))
    @workspace.fold_current
    assert_equal 1, error_client.requests.length
    refute(@workspace.instance_variable_get(:@language_jobs)&.any?(&:alive?))
  end

  def test_external_ranges_are_strict_bounded_and_use_line_ends_for_missing_characters
    rope = @editor.buffer.rope
    normalize = ->(value) { @workspace.send(:normalize_folding_ranges, rope, value) }
    assert_nil normalize.call(nil)
    assert_equal [line_end(0)...line_end(4)], normalize.call([fold(0, 4)])
    assert_equal [offset(0, 2)...offset(1, 2)], normalize.call([fold(0, 1, 2, 2)])
    assert_equal [offset(0, 3)...offset(1, 0)], normalize.call([fold(0, 1, 3, 0)])
    assert_equal 1, normalize.call(Array.new(10_000) { fold(0, 4) }).length
    assert_raises(Canopus::Error) { normalize.call(Array.new(10_001, {})) }
    ["bad", [{}], [{"startLine" => 0}], [fold(-1, 1)], [fold(0, 6)], [fold(3, 2)],
      [fold(0, 1).merge("startCharacter" => nil)], [fold(0, 1, 0x80000000, 0)],
      [fold(0, 1, 1, 0)],
      [fold(0, 0, 0, 0)], [fold(0, 0, 2, 1)]].each do |value|
      assert_raises(Canopus::Error, value.inspect) { normalize.call(value) }
    end
  end

  def test_capability_change_invalidates_the_unsupported_cache
    client = Client.new([fold(0, 4)], supported: false)
    activate(client)
    @workspace.fold_current
    settle
    assert_empty client.requests

    @editor.display_map.unfold(line_end(0))
    client.capabilities["foldingRangeProvider"] = {}
    @workspace.fold_current
    settle
    assert_equal 1, client.requests.length
  end

  def test_client_retirement_clears_a_fallback_after_cache_eviction
    client = Client.new(supported: false)
    activate(client)
    @editor.language_document.stub(:fold_ranges, []) do
      @editor.language_document.stub(:syntax_ready?, false) do
        @workspace.fold_current
      end
    end
    @workspace.instance_variable_get(:@folding_range_cache).clear

    @workspace.invalidate_folding_ranges(client: client)

    assert_empty(@workspace.instance_variable_get(:@pending_folds) || {})
  end

  def test_edit_while_the_initial_client_is_starting_clears_the_stale_pending_fold
    client = Client.new([fold(0, 4)])
    original = @workspace.method(:language_client)
    started, release = Queue.new, Queue.new
    delayed = lambda do |buffer|
      started << true
      release.pop
      original.call(buffer)
    end

    with_client(client) do
      @workspace.stub(:language_client, delayed) do
        @workspace.fold_current
        Timeout.timeout(3) { started.pop }
        @editor.insert_text("x", auto_indent: false)
        release << true
        settle
      end
    end

    assert_empty(@workspace.instance_variable_get(:@pending_folds) || {})
    assert_empty @editor.display_map.fold_map.ranges
    assert_empty(@workspace.instance_variable_get(:@language_jobs) || [])
  end

  def test_edit_settings_and_workspace_close_cancel_futures_and_drop_stale_work
    cancelled = []
    edit = Sadr::Future.new(1) { |id| cancelled << id }
    client = Client.new(edit)
    activate(client)
    @workspace.fold_current
    wait_for_lsp_future(client, 1)
    @editor.insert_text("x", auto_indent: false)
    assert_equal [1], cancelled
    settle
    assert_empty @editor.display_map.fold_map.ranges

    settings = Sadr::Future.new(2) { |id| cancelled << id }
    client.instance_variable_get(:@results) << settings
    @workspace.fold_current
    wait_for_lsp_future(client, 2)
    @workspace.apply_settings
    assert_equal [1, 2], cancelled
    settle

    closing = Sadr::Future.new(3) { |id| cancelled << id }
    client.instance_variable_get(:@results) << closing
    @workspace.fold_current
    wait_for_lsp_future(client, 3)
    @workspace.close
    @workspace = nil
    assert_equal [1, 2, 3], cancelled
  end

  def test_closing_one_split_keeps_shared_request_but_never_applies_to_hidden_or_closed_editors
    cancelled = []
    future = Sadr::Future.new(1) { |id| cancelled << id }
    client = Client.new(future)
    activate(client)
    first_pane = @workspace.active_pane
    @workspace.split(:horizontal)
    closing = @workspace.editor
    closing.select(closing.buffer.rope.line_start(2))
    @workspace.fold_current
    wait_for_lsp_future(client, 1)
    @workspace.close_editor(closing)
    assert_empty cancelled
    future.fulfill([fold(0, 4)])
    settle
    assert_empty cancelled
    assert_empty closing.display_map.fold_map.ranges

    @workspace.focus(first_pane)
    @editor.select(0)
    @workspace.fold_current
    assert_equal 1, client.requests.length
    refute_empty @editor.display_map.fold_map.ranges

    @editor.display_map.unfold(line_end(0))
    @editor.buffer.edit([[0...0, "x"]])
    hidden = Sadr::Future.new(2)
    client.instance_variable_get(:@results) << hidden
    @workspace.fold_current
    wait_for_lsp_future(client, 2)
    other = File.join(@root, "other.rb")
    File.write(other, "other\n")
    @workspace.open(other)
    hidden.fulfill([fold(0, 4)])
    settle
    assert_empty @editor.display_map.fold_map.ranges
  end

  def test_client_retirement_cancels_request_and_timeout_is_bounded
    cancelled = []
    pending = Sadr::Future.new(1) { |id| cancelled << id }
    client = Client.new(pending)
    activate(client)
    @workspace.fold_current
    wait_for_lsp_future(client, 1)
    replace_client(Client.new([]))
    assert_equal [1], cancelled
    assert client.stopped
    settle

    timed = Object.new
    timeouts = []
    timed.define_singleton_method(:await) { |timeout:| timeouts << timeout; nil }
    timed.define_singleton_method(:cancel) { false }
    replace_client(Client.new(timed))
    @workspace.fold_current
    settle
    assert_equal [10], timeouts
  end

  def test_request_limit_falls_back_instead_of_leaving_a_pending_fold
    activate(Client.new([]))
    requests = {}
    Canopus::Workspace::LanguageAware::FOLDING_RANGE_REQUEST_LIMIT.times do |id|
      requests[id] = {buffer: Canopus::Buffer.new("x"), version: 0, client: Object.new}
    end
    @workspace.instance_variable_set(:@folding_range_requests, requests)
    @workspace.fold_current
    pending = @workspace.instance_variable_get(:@pending_folds)
    assert_equal :antares, pending.fetch(@editor).fetch(:source)
  ensure
    requests&.each_value { |request| request[:buffer].close }
  end

  private

  def fold(first, last, first_character = :missing, last_character = :missing)
    value = {"startLine" => first, "endLine" => last}
    value["startCharacter"] = first_character unless first_character == :missing
    value["endCharacter"] = last_character unless last_character == :missing
    value
  end

  def offset(line, character)
    Sadr::Protocol.offset(@editor.buffer.rope, Sadr::Position.new(line: line, character: character))
  end

  def line_end(row)
    @editor.buffer.rope.line_start(row) + @editor.buffer.line(row).bytesize
  end

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
      raise "folding range did not settle" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.001
    end
    @workspace.drain
  end

  def wait_for_lsp_future(client, count)
    wait_until do
      requests = @workspace.instance_variable_get(:@folding_range_requests)&.values || []
      client.requests.length == count && requests.any? { |request| request[:future] }
    end
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.001 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    raise "folding range request did not start" unless yield
  end
end

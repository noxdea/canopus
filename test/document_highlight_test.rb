# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class DocumentHighlightTest < Minitest::Test
  class Client
    attr_reader :capabilities, :requests, :stopped

    def initialize(*results, supported: true)
      @capabilities = {"documentHighlightProvider" => supported}
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
    def document_highlight(uri, position)
      @requests << [uri, position]
      result = @results.shift || []
      result.respond_to?(:await) ? result : Sadr::Future.new(@requests.length).fulfill(result)
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-document-highlight-")
    @path = File.join(@root, "source.rb")
    File.write(@path, "😀read write text\nsecond\n")
    settings = Canopus::Settings.new("language_servers" => {"ruby" => ["fake"]})
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    @editor = @workspace.open(@path)
    @window = Zaniah::Platform.open_window(backend: :headless, width: 640, height: 220)
    @controller = Canopus::Controller.new(@workspace, @window)
  end

  def teardown
    @workspace.close
    @window.on_close { true }
    @window.close
    FileUtils.remove_entry(@root)
  end

  def test_three_kinds_and_utf16_ranges_use_the_existing_decoration_path
    result = [highlight(0, 2, 6, 1), highlight(0, 7, 12, 2), highlight(0, 13, 17, 3)]
    with_client(Client.new(result)) do |client|
      @editor.select(4)
      @controller.poll_language_documents
      settle

      items = decorations(@editor, 0...1)
      assert_equal [4...8, 9...14, 15...19], items.map(&:range)
      assert_equal 3, items.map(&:style).uniq.length
      assert items.all? { |item| item.kind == :highlight && item.source == :document_highlight }
      assert_empty decorations(@editor, 1...2)
      assert_equal 2, client.requests.first.last.character

      @editor.display_map.wrap_width = 5
      @editor.display_map.fold(@editor.buffer.rope.line_start(1)...@editor.buffer.rope.bytesize)
      @window.request_frame
      @controller.tick
      assert @window.scene.quads.any?
    end
  end

  def test_split_editors_request_and_cache_their_own_carets
    client = Client.new([highlight(0, 2, 6, 1)], [highlight(0, 7, 12, 2)])
    with_client(client) do
      @editor.select(4)
      @workspace.split(:horizontal)
      second = @workspace.editor
      second.select(9)
      @controller.poll_language_documents
      settle

      assert_equal [2, 7], client.requests.map { |_uri, point| point.character }.sort
      assert_equal [4...8], decorations(@editor, 0...1).map(&:range)
      assert_equal [9...14], decorations(second, 0...1).map(&:range)
      assert_same @editor.buffer, second.buffer
    end
  end

  def test_cursor_change_deduplicates_cancels_and_rejects_stale_results
    cancelled = []
    first = Sadr::Future.new(1) { |id| cancelled << id }
    second = Sadr::Future.new(2)
    with_client(Client.new(first, second)) do |client|
      @editor.select(4)
      assert @workspace.request_document_highlights(@editor)
      wait_until { client.requests.length == 1 }
      5.times { refute @workspace.request_document_highlights(@editor) }

      @editor.select(9)
      assert @workspace.request_document_highlights(@editor)
      wait_until { client.requests.length == 2 }
      assert_equal [1], cancelled
      second.fulfill([highlight(0, 7, 12, 2)])
      settle

      assert_equal [9...14], decorations(@editor, 0...1).map(&:range)
      assert_empty(@workspace.instance_variable_get(:@document_highlight_requests) || {})
      refute @workspace.instance_variable_get(:@language_jobs)&.any?(&:alive?)
    end
  end

  def test_edit_close_and_client_retirement_cancel_pending_futures
    cancelled = []
    edit_future = Sadr::Future.new(1) { |id| cancelled << id }
    client = Client.new(edit_future)
    with_client(client) do
      assert @workspace.request_document_highlights(@editor)
      wait_until { client.requests.length == 1 }
      @editor.insert_text("x", auto_indent: false)
      assert_equal [1], cancelled
      assert_empty(@workspace.instance_variable_get(:@document_highlight_requests) || {})
      settle

      retirement_future = Sadr::Future.new(2) { |id| cancelled << id }
      client.instance_variable_get(:@results) << retirement_future
      assert @workspace.request_document_highlights(@editor)
      wait_until { client.requests.length == 2 }
      close_future = Sadr::Future.new(3) { |id| cancelled << id }
      replacement = Client.new(close_future)
      replace_client(replacement)
      assert_equal [1, 2], cancelled
      assert client.stopped

      assert @workspace.request_document_highlights(@editor)
      wait_until { replacement.requests.length == 1 }
      @workspace.close_editor(@editor, discard: true)
      assert_equal [1, 2, 3], cancelled
    end
  end

  def test_switching_tabs_cancels_the_hidden_editor_request
    cancelled = []
    pending = Sadr::Future.new(1) { |id| cancelled << id }
    with_client(Client.new(pending, [])) do |client|
      assert @workspace.request_document_highlights(@editor)
      wait_until { client.requests.length == 1 }

      other = File.join(@root, "other.rb")
      File.write(other, "other\n")
      current = @workspace.open(other)
      assert @workspace.request_document_highlights(current)
      settle

      assert_equal [1], cancelled
      assert_equal 2, client.requests.length
      assert_empty(@workspace.instance_variable_get(:@document_highlight_requests) || {})
    end
  end

  def test_unsupported_and_errors_are_negative_cached_and_timeout_is_bounded
    with_client(Client.new(supported: false)) do |client|
      assert @workspace.request_document_highlights(@editor)
      settle
      5.times { refute @workspace.request_document_highlights(@editor) }
      assert_empty client.requests
    end

    failure = Sadr::Future.new(4).fulfill(error: Sadr::Error.new("highlight failed"))
    error_client = Client.new(failure)
    replace_client(error_client)
    assert @workspace.request_document_highlights(@editor)
    settle
    refute @workspace.request_document_highlights(@editor)
    assert_equal 1, error_client.requests.length
    assert_equal "highlight failed", @workspace.message

    timed = Object.new
    timeouts = []
    timed.define_singleton_method(:await) { |timeout:| timeouts << timeout; [] }
    timed.define_singleton_method(:cancel) { false }
    replace_client(Client.new(timed))
    assert @workspace.request_document_highlights(@editor)
    settle
    assert_equal [10], timeouts
  end

  def test_capability_options_and_changes_invalidate_the_unsupported_cache
    client = Client.new([highlight(0, 2, 6, nil).tap { |item| item.delete("kind") }], supported: false)
    with_client(client) do
      assert @workspace.request_document_highlights(@editor)
      settle
      refute @workspace.request_document_highlights(@editor)
      assert_empty client.requests

      client.capabilities["documentHighlightProvider"] = {}
      assert @workspace.request_document_highlights(@editor)
      settle

      assert_equal 1, client.requests.length
      assert_equal [4...8], decorations(@editor, 0...1).map(&:range)
      assert_equal :selection, decorations(@editor, 0...1).first.style[:color]
    end
  end

  def test_external_response_validation_is_strict_and_bounded
    rope = @editor.buffer.rope
    normalize = ->(value) { @workspace.send(:normalize_document_highlights, rope, value) }
    assert_empty normalize.call(nil)
    assert_raises(Canopus::Error) { normalize.call(Array.new(10_001, {})) }
    ["bad", [{}], [{"kind" => 1}], [highlight(0, 2, 6, 0)],
      [highlight(0, 2, 2, 1)], [highlight(0, 6, 2, 1)], [highlight(5, 0, 1, 1)]].each do |value|
      assert_raises(Canopus::Error) { normalize.call(value) }
    end
    assert_raises(Canopus::Error) { normalize.call([highlight(0, 1, 2, 1)]) }
  end

  private

  def point(line, character) = {"line" => line, "character" => character}
  def highlight(line, first, last, kind)
    {"range" => {"start" => point(line, first), "end" => point(line, last)}, "kind" => kind}
  end

  def with_client(client, current = @editor)
    Sadr::Client.stub(:new, client) do
      @workspace.language_client(current.buffer)
    end
    yield client
  end

  def replace_client(client)
    Sadr::Client.stub(:new, client) do
      configured = @workspace.send(:normalize_server_options, ["fake"])
      @workspace.instance_variable_get(:@client_options)["ruby"] =
        @workspace.send(:normalize_server_options, ["retired", client.object_id.to_s])
      options = configured
      @workspace.send(:ensure_language_server, "ruby", options)
    end
  end

  def decorations(current, rows)
    @workspace.decorations.items_for(current.buffer, rows, context: current)
      .select { |item| item.source == :document_highlight }
  end

  def settle
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    loop do
      @workspace.drain
      jobs = @workspace.instance_variable_get(:@language_jobs) || []
      break unless jobs.any?(&:alive?)
      raise "document highlight did not settle" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.001
    end
    @workspace.drain
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.001 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    raise "document highlight request did not start" unless yield
  end
end

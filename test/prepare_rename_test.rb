# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class PrepareRenameTest < Minitest::Test
  class Client
    attr_reader :capabilities, :prepare_requests, :rename_requests, :stopped

    def initialize(*results, supported: true, rename_result: nil)
      @capabilities = {"renameProvider" => supported == true ? {"prepareProvider" => true} : supported}
      @results, @rename_result = results, rename_result
      @prepare_requests, @rename_requests = [], []
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
    def prepare_rename(uri, position)
      @prepare_requests << [uri, position]
      result = @results.shift
      result.respond_to?(:await) ? result : Sadr::Future.new(@prepare_requests.length).fulfill(result)
    end
    def rename(uri, position, name)
      @rename_requests << [uri, position, name]
      result = @rename_result
      result.respond_to?(:await) ? result : Sadr::Future.new(@rename_requests.length).fulfill(result)
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-prepare-rename-")
    @path = File.join(@root, "source.rb")
    File.write(@path, "😀target = target\n")
    settings = Canopus::Settings.new("language_servers" => {"ruby" => ["fake"]})
    @workspace = Canopus::Workspace.new(root: @root, settings: settings)
    @editor = @workspace.open(@path)
    @editor.select(4)
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root)
  end

  def test_range_prepares_the_dialog_and_submit_uses_the_exact_snapshot
    client = Client.new(range(0, 2, 8))
    activate(client)

    @workspace.prepare_rename
    settle

    assert_equal :rename, @workspace.palette[:kind]
    assert_equal "target", @workspace.palette[:query]
    assert_equal 2, client.prepare_requests.first.last.character
    @workspace.palette[:query].replace("renamed")
    @workspace.palette_accept
    settle

    assert_equal [[Sadr::Protocol.uri(@editor.buffer.path), Sadr::Position.new(line: 0, character: 2), "renamed"]], client.rename_requests
    assert_empty(@workspace.instance_variable_get(:@prepare_rename_requests) || {})
    refute(@workspace.instance_variable_get(:@language_jobs)&.any?(&:alive?))
  end

  def test_placeholder_and_both_default_behavior_values_are_supported_but_nil_refuses_rename
    client = Client.new({"range" => range(0, 2, 8), "placeholder" => "replacement"})
    activate(client)
    @workspace.prepare_rename
    settle
    assert_equal "replacement", @workspace.palette[:query]

    @workspace.palette = nil
    client.instance_variable_get(:@results) << {"defaultBehavior" => true}
    @workspace.prepare_rename
    settle
    assert_equal "target", @workspace.palette[:query]

    @workspace.palette = nil
    client.instance_variable_get(:@results) << {"defaultBehavior" => false}
    @workspace.prepare_rename
    settle
    assert_equal "target", @workspace.palette[:query]

    @workspace.palette = nil
    client.instance_variable_get(:@results) << nil
    @workspace.prepare_rename
    settle
    assert_nil @workspace.palette
    assert_equal "Rename is not available here", @workspace.message
  end

  def test_palette_cancel_detaches_the_selection_subscription_and_selection_return_value_is_stable
    client = Client.new(range(0, 2, 8), range(0, 2, 8))
    activate(client)
    @workspace.prepare_rename
    settle
    snapshot = @workspace.palette.fetch(:rename)
    assert snapshot[:selection_subscription]
    assert_equal @editor.selections, @editor.set_selections(@editor.selections)

    @workspace.palette = nil
    refute snapshot.key?(:selection_subscription)
    refute snapshot.key?(:edit_subscription)

    @workspace.prepare_rename
    settle
    replacement = @workspace.palette.fetch(:rename)
    @workspace.palette_open(:commands)
    refute replacement.key?(:selection_subscription)
    refute replacement.key?(:edit_subscription)

    notified = []
    failed = @editor.on_selection { raise "listener failed" }
    observed = @editor.on_selection { |selections| notified << selections }
    _output, error = capture_io { assert_equal @editor.selections, @editor.set_selections(@editor.selections) }
    assert_empty error
    result = nil
    _output, error = capture_io { result = @editor.select(5).selections }
    assert_equal @editor.selections, result
    assert_includes error, "selection notification failed"
    assert_equal [@editor.selections], notified
    failed.detach
    observed.detach
    assert_raises(ArgumentError) { @editor.on_selection }
  end

  def test_unsupported_and_unconfigured_languages_keep_the_existing_dialog_path
    unsupported = Client.new(supported: true)
    unsupported.capabilities["renameProvider"] = true
    activate(unsupported)
    @workspace.prepare_rename
    assert_equal :rename, @workspace.palette[:kind]
    assert_empty unsupported.prepare_requests
    @workspace.palette[:query].replace("next")
    @workspace.palette_accept
    settle
    assert_equal "next", unsupported.rename_requests.first.last

    root = Dir.mktmpdir("canopus-unconfigured-rename-")
    workspace = Canopus::Workspace.new(root: root, settings: Canopus::Settings.new)
    editor = workspace.open(File.join(root, "plain.txt"))
    editor.buffer.edit([[0...0, "name"]])
    workspace.prepare_rename
    assert_equal :rename, workspace.palette[:kind]
  ensure
    workspace&.close
    FileUtils.remove_entry(root) if root
  end

  def test_prepared_rename_keeps_resource_workspace_edit_confirmation
    created = File.join(@root, "created.rb")
    edit = {"documentChanges" => [{"kind" => "create", "uri" => Sadr::Protocol.uri(created)}]}
    client = Client.new(range(0, 2, 8), rename_result: edit)
    activate(client)
    @workspace.prepare_rename
    settle
    @workspace.palette[:query].replace("renamed")
    @workspace.palette_accept
    settle

    assert_equal :workspace_edit, @workspace.palette[:kind]
    refute File.exist?(created)
  end

  def test_submit_remains_bound_to_the_snapshot_and_cancels_on_cursor_change
    cancelled = []
    rename = Sadr::Future.new(9) { |id| cancelled << id }
    client = Client.new(range(0, 2, 8), rename_result: rename)
    activate(client)
    @workspace.prepare_rename
    settle
    @workspace.palette[:query].replace("renamed")
    @workspace.palette_accept
    wait_until { client.rename_requests.length == 1 }

    @editor.select(5)
    assert_equal [9], cancelled
    rename.fulfill({"changes" => {}})
    settle
    assert_empty(@workspace.instance_variable_get(:@prepare_rename_requests) || {})
    assert_nil @workspace.palette
  end

  def test_external_result_validation_is_utf16_exact_strict_and_bounded
    rope = @editor.buffer.rope
    normalize = ->(value) { @workspace.send(:normalize_prepare_rename, rope, 4, value) }
    assert_nil normalize.call(nil)
    assert_equal "target", normalize.call(range(0, 2, 8))
    assert_equal "name", normalize.call({"range" => range(0, 2, 8), "placeholder" => "name"})
    assert_equal "target", normalize.call({"defaultBehavior" => true})
    assert_equal "target", normalize.call({"defaultBehavior" => false})
    assert_equal "symbol", normalize.call({range: range(0, 2, 8), placeholder: "symbol"})
    assert_equal "target", normalize.call({defaultBehavior: true})
    assert_equal "target", normalize.call({defaultBehavior: false})
    assert_equal "target", @workspace.send(:normalize_prepare_rename, rope, 7, {defaultBehavior: true})
    assert_equal "target", normalize.call({start: {line: 0, character: 2}, end: {line: 0, character: 8}})

    invalid_utf8 = "x".b.force_encoding(Encoding::UTF_8)
    invalid_utf8.setbyte(0, 0xff)
    [range(0, 3, 8), range(0, 2, 2), range(0, 1, 8), range(0, 2, 99),
      {"range" => range(0, 2, 8)}, {"range" => range(0, 2, 8), "placeholder" => invalid_utf8},
      {"range" => range(0, 2, 8), "placeholder" => "x" * 4097},
      {"defaultBehavior" => "yes"}, {"defaultBehavior" => true, "extra" => true}, "bad"].each do |value|
      assert_raises(Canopus::Error, value.inspect) { normalize.call(value) }
    end
    assert_raises(Canopus::Error) do
      normalize.call({"range" => range(0, 2, 8), range: range(0, 2, 8), "placeholder" => "duplicate"})
    end
  end

  def test_edit_cursor_change_tab_hide_and_palette_cancel_abort_pending_or_prepared_work
    cancelled = []
    pending = Sadr::Future.new(1) { |id| cancelled << id }
    client = Client.new(pending)
    activate(client)
    @workspace.prepare_rename
    wait_until { client.prepare_requests.length == 1 }
    @editor.select(5)
    assert_equal [1], cancelled
    pending.fulfill(range(0, 2, 8))
    settle
    assert_nil @workspace.palette

    client.instance_variable_get(:@results) << range(0, 2, 8)
    @editor.select(4)
    @workspace.prepare_rename
    settle
    assert_equal :rename, @workspace.palette[:kind]
    @editor.insert_text("x", auto_indent: false)
    assert_nil @workspace.palette

    client.instance_variable_get(:@results) << Sadr::Future.new(2) { |id| cancelled << id }
    @workspace.prepare_rename
    wait_until { client.prepare_requests.length == 3 }
    other = File.join(@root, "other.rb")
    File.write(other, "other\n")
    @workspace.open(other)
    assert_equal [1, 2], cancelled
  end

  def test_settings_client_retirement_workspace_close_and_supersede_cancel_requests
    cancelled = []
    first = Sadr::Future.new(1) { |id| cancelled << id }
    second = Sadr::Future.new(2) { |id| cancelled << id }
    client = Client.new(first, second)
    activate(client)
    @workspace.prepare_rename
    wait_until { client.prepare_requests.length == 1 }
    @workspace.prepare_rename
    wait_until { client.prepare_requests.length == 2 }
    assert_equal [1], cancelled
    assert_operator @workspace.instance_variable_get(:@prepare_rename_requests).length,
      :<=, Canopus::Workspace::LanguageAware::PREPARE_RENAME_REQUEST_LIMIT
    @workspace.apply_settings
    assert_equal [1, 2], cancelled

    third = Sadr::Future.new(3) { |id| cancelled << id }
    client.instance_variable_get(:@results) << third
    @workspace.prepare_rename
    wait_until { client.prepare_requests.length == 3 }
    replace_client(Client.new)
    assert_equal [1, 2, 3], cancelled

    replacement = @workspace.clients.fetch("ruby")
    closing = Sadr::Future.new(4) { |id| cancelled << id }
    replacement.instance_variable_get(:@results) << closing
    @workspace.prepare_rename
    wait_until { replacement.prepare_requests.length == 1 }
    @workspace.close
    @workspace = nil
    assert_equal [1, 2, 3, 4], cancelled
  end

  def test_save_as_and_editor_close_cancel_pending_requests
    cancelled = []
    client = Client.new(Sadr::Future.new(5) { |id| cancelled << id }, Sadr::Future.new(6) { |id| cancelled << id })
    activate(client)
    @workspace.prepare_rename
    wait_until { client.prepare_requests.length == 1 }

    @workspace.save_buffer(@editor.buffer, path: File.join(@root, "renamed.rb"))
    settle
    assert_equal [5], cancelled

    @workspace.prepare_rename
    wait_until { client.prepare_requests.length == 2 }
    @workspace.close_editor(@editor)
    settle
    assert_equal [5, 6], cancelled
  end

  def test_server_errors_invalid_results_and_timeouts_are_explicit_without_a_dialog
    failure = Sadr::Future.new(1).fulfill(error: Sadr::Error.new("prepare failed"))
    timed = Object.new
    timeouts = []
    timed.define_singleton_method(:await) { |timeout:| timeouts << timeout; {"defaultBehavior" => "yes"} }
    timed.define_singleton_method(:cancel) { false }
    client = Client.new(failure, timed)
    activate(client)

    @workspace.prepare_rename
    settle
    assert_nil @workspace.palette
    assert_equal "prepare failed", @workspace.message

    @workspace.prepare_rename
    settle
    assert_nil @workspace.palette
    assert_includes @workspace.message, "invalid prepare rename"
    assert_equal [10], timeouts
  end

  def test_capability_changes_reject_the_stale_result_and_release_the_request
    pending = Sadr::Future.new(1)
    client = Client.new(pending)
    activate(client)
    @workspace.prepare_rename
    wait_until { client.prepare_requests.length == 1 }
    client.capabilities["renameProvider"]["prepareProvider"] = false
    pending.fulfill(range(0, 2, 8))
    settle

    assert_nil @workspace.palette
    assert_empty(@workspace.instance_variable_get(:@prepare_rename_requests) || {})
  end

  def test_edit_during_client_startup_leaves_no_stale_work
    client = Client.new(range(0, 2, 8))
    original = @workspace.method(:language_client)
    started, release = Queue.new, Queue.new
    delayed = lambda do |buffer|
      started << true
      release.pop
      original.call(buffer)
    end
    with_client(client) do
      @workspace.stub(:language_client, delayed) do
        @workspace.prepare_rename
        started.pop
        @editor.insert_text("x", auto_indent: false)
        release << true
        settle
      end
    end
    assert_nil @workspace.palette
    assert_empty(@workspace.instance_variable_get(:@prepare_rename_requests) || {})
  end

  private

  def point(line, character) = {"line" => line, "character" => character}
  def range(line, first, last) = {"start" => point(line, first), "end" => point(line, last)}

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
      raise "prepare rename did not settle" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.001
    end
    @workspace.drain
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.001 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    raise "prepare rename request did not start" unless yield
  end
end

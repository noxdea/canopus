# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "timeout"

class ProviderTest < Minitest::Test
  def completion(label, insert_text: label, source: nil, sort_text: nil, filter_text: nil, kind: nil, edits: [])
    Canopus::Provider::Completion.new(label, insert_text, kind, nil, nil, sort_text, filter_text, edits, source)
  end

  def test_completion_ranking_priority_deduplication_and_failures
    buffer = Canopus::Buffer.new("pri")
    registry = Canopus::Provider::Registry.new
    registry.register_completion(:low, priority: 1) { [completion("print", insert_text: "print", sort_text: "b"), completion("puts")] }
    registry.register_completion(:broken, priority: 50) { raise "broken provider" }
    registry.register_completion(:high, priority: 10) { [completion("print", insert_text: "print", sort_text: "z"), completion("private")] }
    errors = []

    results = registry.complete(buffer, 3, {query: "pri", errors: errors})

    assert_equal %w[print private puts], results.map(&:label)
    assert_equal %i[high high low], results.map(&:source)
    assert_equal :broken, errors.first.first
    assert results.frozen?
    assert results.all? { |item| item.label.frozen? && item.insert_text.frozen? }
  end

  def test_completion_accepts_an_awaitable_and_bounds_external_values
    buffer = Canopus::Buffer.new
    first, second = Sadr::Future.new(nil), Sadr::Future.new(nil)
    started = Queue.new
    registry = Canopus::Provider::Registry.new
    registry.register_completion(:first, priority: 1) { started << :first; first }
    registry.register_completion(:second, priority: 2) { started << :second; second }
    thread = Thread.new { registry.complete(buffer, 0, {query: ""}) }
    Timeout.timeout(1) { 2.times { started.pop } }
    first.fulfill([completion("one")])
    second.fulfill([completion("two")])

    assert_equal %w[two one], thread.value.map(&:label)
    assert_raises(ArgumentError) { registry.complete(buffer, 1, {}) }
    assert_raises(ArgumentError) { registry.register_completion(:bad, priority: Float::INFINITY) { [] } }
  end

  def test_inline_completion_uses_first_successful_provider
    buffer = Canopus::Buffer.new("x")
    registry = Canopus::Provider::Registry.new
    registry.register_inline_completion(:broken) { raise "unavailable" }
    registry.register_inline_completion(:empty) { nil }
    registry.register_inline_completion(:local) { "yz" }

    value = registry.inline_completion(buffer, 1)
    assert_equal "yz", value
    assert value.frozen?
  end

  def test_completion_cleanup_waits_for_provider_ensure
    buffer = Canopus::Buffer.new
    registry = Canopus::Provider::Registry.new
    started, cleaned = Queue.new, Queue.new
    registry.register_completion(:full, priority: 2) do
      started.pop
      Array.new(Canopus::Provider::Registry::MAX_ITEMS, completion("full"))
    end
    registry.register_completion(:slow, priority: 1) do
      started << true
      sleep
    ensure
      sleep 0.01
      cleaned << true
    end

    registry.complete(buffer, 0, {query: ""})

    assert cleaned.pop(true)
  end

  def test_workspace_routes_external_snippet_completion_through_the_registry
    Dir.mktmpdir("canopus-provider-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.new_buffer
      editor.insert_text("pri")
      seen = nil
      workspace.providers.register_completion(:snippet, priority: 200) do |buffer, offset, context|
        seen = [buffer, offset, context[:query]]
        [completion("print", insert_text: "print(${1:value})$0", source: :ignored)]
      end

      workspace.language_request(:completion)
      workspace.instance_variable_get(:@language_jobs).each(&:join)
      workspace.drain
      assert_equal [editor.buffer, 3, "pri"], seen
      assert_equal :snippet, workspace.palette[:items].first.source
      workspace.palette[:query] = "print"
      workspace.update_palette
      assert_equal ["print"], workspace.palette[:matches]
      workspace.palette_accept
      assert_equal "priprint(value)", editor.buffer.text
      assert_equal "value", editor.buffer.rope.byteslice(editor.primary.range).to_s
      workspace.close
    end
  end

  def test_workspace_discards_completion_after_document_changes
    Dir.mktmpdir("canopus-provider-stale-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.new_buffer
      future = Sadr::Future.new(nil)
      workspace.providers.register_completion(:slow, priority: 200) { future }
      workspace.language_request(:completion)
      editor.insert_text("changed")
      future.fulfill([completion("old")])
      workspace.instance_variable_get(:@language_jobs).each(&:join)
      workspace.drain

      assert_nil workspace.palette
      assert_match(/Document changed/, workspace.message)
      workspace.close
    end
  end

  def test_workspace_displays_the_error_when_every_provider_fails
    Dir.mktmpdir("canopus-provider-error-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      workspace.new_buffer

      workspace.language_request(:completion)
      workspace.instance_variable_get(:@language_jobs).each(&:join)
      workspace.drain

      assert_nil workspace.palette
      assert_equal "No language server configured for text", workspace.message
      workspace.close
    end
  end

  def test_workspace_close_cleans_up_completion_provider_threads
    Dir.mktmpdir("canopus-provider-close-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      workspace.new_buffer
      started, cleaned = Queue.new, Queue.new
      workspace.providers.register_completion(:slow, priority: 200) do
        started << true
        sleep
      ensure
        cleaned << true
      end
      workspace.language_request(:completion)
      Timeout.timeout(1) { started.pop }
      jobs = workspace.instance_variable_get(:@completion_jobs).dup

      workspace.close

      assert jobs.none?(&:alive?)
      assert cleaned.pop(true)
    end
  end

  def test_newer_completion_request_wins_at_the_same_document_version
    Dir.mktmpdir("canopus-provider-generation-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      workspace.new_buffer
      first, second = Sadr::Future.new(nil), Sadr::Future.new(nil)
      futures, lock, started = [first, second], Mutex.new, Queue.new
      workspace.providers.register_completion(:slow, priority: 200) do
        lock.synchronize { futures.shift }.tap { started << true }
      end

      workspace.language_request(:completion)
      Timeout.timeout(1) { started.pop }
      workspace.language_request(:completion)
      Timeout.timeout(1) { started.pop }
      second.fulfill([completion("new")])
      first.fulfill([completion("old")])
      workspace.instance_variable_get(:@language_jobs).each(&:join)
      workspace.drain

      assert_equal ["new"], workspace.palette[:matches]
      workspace.close
    end
  end

  def test_lsp_completion_keeps_its_edit_metadata_through_provider_ranking
    Dir.mktmpdir("canopus-provider-lsp-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.new_buffer
      editor.insert_text("old")
      item = {"label" => "new", "filterText" => "replacement", "textEdit" => {
        "range" => {"start" => {"line" => 0, "character" => 0}, "end" => {"line" => 0, "character" => 3}},
        "newText" => "new"
      }}

      workspace.send(:display_language_result, :completion, [item], nil, editor)
      assert_instance_of Canopus::Provider::Completion, workspace.palette[:items].first
      workspace.palette[:query] = "replace"
      workspace.update_palette
      assert_equal ["new"], workspace.palette[:matches]
      workspace.palette_accept
      assert_equal "new", editor.buffer.text
      workspace.close
    end
  end

  def test_lsp_duplicate_keeps_first_items_edit_metadata
    Dir.mktmpdir("canopus-provider-lsp-duplicate-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.new_buffer
      editor.insert_text("aa bb")
      range = lambda do |first, last|
        {"start" => {"line" => 0, "character" => first}, "end" => {"line" => 0, "character" => last}}
      end
      items = [
        {"label" => "x", "textEdit" => {"range" => range.call(0, 2), "newText" => "x"}},
        {"label" => "x", "textEdit" => {"range" => range.call(3, 5), "newText" => "x"}}
      ]

      workspace.send(:display_language_result, :completion, items, nil, editor)
      workspace.palette_accept

      assert_equal "x bb", editor.buffer.text
      workspace.close
    end
  end

  def test_completion_filter_keeps_items_with_the_same_filter_text
    Dir.mktmpdir("canopus-provider-filter-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.new_buffer
      items = [completion("first", filter_text: "shared"), completion("second", filter_text: "shared")]
      workspace.palette = {kind: :completion, query: "shared", index: 0,
        matches: items.map(&:label), items: items, editor: editor, version: editor.buffer.version}

      workspace.update_palette

      assert_equal %w[first second], workspace.palette[:matches]
      workspace.close
    end
  end

  def test_invalid_lsp_text_edit_is_rejected_before_display
    Dir.mktmpdir("canopus-provider-invalid-lsp-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.new_buffer

      workspace.send(:display_language_result, :completion, [{"label" => "x", "textEdit" => {}}], nil, editor)

      assert_nil workspace.palette
      assert_match(/invalid completion text edit/, workspace.message)
      workspace.close
    end
  end

  def test_retired_lsp_failure_does_not_replace_current_message
    Dir.mktmpdir("canopus-provider-retired-lsp-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.new_buffer
      client = Object.new
      workspace.instance_variable_set(:@retired_language_clients, {client => true})
      workspace.message = "current"

      workspace.send(:display_completions, [], editor,
        {metadata: {}, errors: [[:lsp, "obsolete"]], client: client, generation: 1})

      assert_equal "current", workspace.message
      assert_nil workspace.palette
      workspace.close
    end
  end

  def test_invalid_external_edit_boundary_is_rejected
    buffer = Canopus::Buffer.new("é")
    registry = Canopus::Provider::Registry.new
    errors = []
    registry.register_completion(:extension, priority: 1) { [completion("x", edits: [[1...1, "x"]])] }

    assert_empty registry.complete(buffer, 0, {errors: errors})
    assert_match(/splits a UTF-8 character/, errors.first.last)
  end

  def test_external_completion_groups_additional_edits_with_the_insertion
    Dir.mktmpdir("canopus-provider-edits-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.new_buffer
      editor.insert_text("abc old")
      editor.select(4, 7)
      workspace.providers.register_completion(:extension, priority: 200) do
        [completion("new", edits: [[0...0, "use "]])]
      end

      workspace.language_request(:completion)
      workspace.instance_variable_get(:@language_jobs).each(&:join)
      workspace.drain
      workspace.palette_accept
      assert_equal "use abc new", editor.buffer.text
      assert editor.undo
      assert_equal "abc old", editor.buffer.text
      workspace.close
    end
  end
end

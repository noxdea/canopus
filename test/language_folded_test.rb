# frozen_string_literal: true

require_relative "test_helper"
require "canopus/cli"
require "minitest/mock"

class LanguageFoldedTest < Minitest::Test
  BackgroundAnalysis = Canopus::Language.const_get(:BackgroundAnalysis, false)

  def setup
    @directory = Dir.mktmpdir("canopus-folded-language-")
    @workspace = Canopus::Workspace.new(root: @directory)
    @window = Zaniah::Platform.open_window(width: 640, height: 260)
    @controller = Canopus::Controller.new(@workspace, @window)
  end

  def teardown
    @workspace.close
    @window.on_close { true }
    @window.close
    FileUtils.remove_entry(@directory)
  end

  def open_source(source, name: "example.rb")
    File.binwrite(File.join(@directory, name), source)
    @workspace.open(name)
  end

  def settle(document, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while document.pending?
      yield if block_given?
      document.poll
      raise "folded language analysis timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.002
    end
  end

  def test_folded_viewport_paint_cannot_cancel_far_source_rows
    editor = open_source("class A\n" + "value = true\n" * 700 + "end\n")
    editor.display_map.fold(editor.buffer.rope.line_start(1)...editor.buffer.rope.line_start(600))
    editor.viewport_rows = 8
    rows = (0..8).map { |row| editor.display_map.source_row(row) }
    assert_equal [0, 1, 601, 602, 603, 604, 605, 606, 607], rows
    document = editor.language_document
    @controller.poll_language_documents
    generation = document.instance_variable_get(:@background).instance_variable_get(:@generation)
    settle(document) do
      @controller.poll_language_documents
      rows.each { |row| document.tokens_for(row) }
    end
    assert_equal generation, document.instance_variable_get(:@background).instance_variable_get(:@generation)
    rows.each do |row|
      assert document.tokens_current?(row), "source row #{row} was starved"
      assert document.tokens_for(row).any? { |name, _| name.start_with?("Keyword") }
    end
    @controller.poll_language_documents
    rows.reverse_each { |row| document.tokens_for(row) }
    refute document.pending?
  end

  def test_png_settle_final_paint_does_not_create_new_folded_work
    editor = open_source("class A\n" + "value = true\n" * 700 + "end\n")
    editor.display_map.fold(editor.buffer.rope.line_start(1)...editor.buffer.rope.line_start(600))
    @window.text_system = Zaniah::TextSystem::Renderer.new
    Canopus::CLI.send(:settle_export, @controller, @window, timeout: 10)
    document = editor.language_document
    refute document.pending?
    assert document.tokens_current?(0)
    assert document.tokens_current?(601)
    cache = @controller.view.instance_variable_get(:@code_caches).fetch(editor).values
    assert cache.any? { |value| value.first.equal?(document.tokens_for(601)) }
    3.times { @window.request_frame; @controller.tick; refute document.pending? }
  end

  def test_many_discrete_rows_are_bounded_and_all_become_current
    editor = open_source("value = true\n" * 900)
    document = editor.language_document
    rows = 256.times.map { |index| index * 3 }
    document.request(rows: rows)
    prepare = BackgroundAnalysis.method(:prepare)
    sizes = Queue.new
    BackgroundAnalysis.stub(:prepare, ->(*args) { prepare.call(*args).tap { |payload| sizes << payload.fetch("source").bytesize } }) do
      settle(document, timeout: 30) { rows.reverse_each { |row| document.tokens_for(row) } }
    end
    assert_equal 256, sizes.size
    assert_operator sizes.pop, :<=, BackgroundAnalysis::SOURCE_LIMIT until sizes.empty?
    rows.each { |row| assert document.tokens_current?(row) }
    state = document.instance_variable_get(:@background)
    assert_operator state.instance_variable_get(:@tokens).length, :<=, BackgroundAnalysis::CACHE_ROWS
    # Explicit viewport ownership also bounds work when more than 256 physical
    # rows fit on screen: callers outside that viewport receive provisional text.
    document.tokens_for(899)
    refute document.pending?
    assert_raises(ArgumentError) { document.request(rows: (0..256).to_a) }
    assert_raises(ArgumentError) { document.request(rows: []) }
    assert_raises(ArgumentError) { document.request(rows: [0], first_line: 0) }
    assert_raises(RangeError) { document.request(rows: [901]) }
  end

  def test_cache_eviction_preserves_an_old_still_visible_row
    document = open_source("value = true\n" * 900).language_document
    document.request(first_line: 0, last_line: 255)
    settle(document)
    original = document.tokens_for(0)
    document.request(first_line: 256, last_line: 511)
    settle(document)
    document.request(rows: [0, 800, 801, 802])
    settle(document)
    assert_same original, document.tokens_for(0)
    [0, 800, 801, 802].each { |row| assert document.tokens_current?(row) }
    refute document.pending?
  end

  def test_capped_input_does_not_cache_uncopied_rows_as_empty
    source = "#" + "x" * (BackgroundAnalysis::SOURCE_LIMIT - 2) + "\nclass AfterBoundary\nend\n"
    editor = open_source(source)
    document = editor.language_document
    snapshot = BackgroundAnalysis::Snapshot.new(editor.buffer.rope, 0, "boundary", "ruby", "ruby", 0, 3, false)
    request = BackgroundAnalysis.prepare(snapshot, BackgroundAnalysis::Job.new)
    assert_equal BackgroundAnalysis::SOURCE_LIMIT, request.fetch("source").bytesize
    assert_equal 0, request.fetch("last"), "the empty tail of a capped snapshot is not the next real line"
    document.request(rows: [0, 1, 2, 3])
    prepare = BackgroundAnalysis.method(:prepare)
    sizes = Queue.new
    BackgroundAnalysis.stub(:prepare, ->(*args) { prepare.call(*args).tap { |payload| sizes << payload.fetch("source").bytesize } }) do
      settle(document) { (0..3).each { |row| document.tokens_for(row) } }
    end
    assert_operator sizes.size, :>=, 2
    assert_operator sizes.pop, :<=, BackgroundAnalysis::SOURCE_LIMIT until sizes.empty?
    assert_equal "class AfterBoundary\n", document.tokens_for(1).map(&:last).join
    assert document.tokens_for(1).any? { |name, _| name.start_with?("Keyword") }
    assert_operator document.tokens_for(0).sum { |_, text| text.bytesize }, :<=, BackgroundAnalysis::LINE_LIMIT
    (0..3).each { |row| assert document.tokens_current?(row) }
  end

  def test_windowed_syntax_merges_discrete_ranges_even_if_tokens_were_already_cached
    source = "class First\nend\n" + "# filler line\n" * 90_000 + "class Last\nend\n"
    editor = open_source(source)
    document = editor.language_document
    rows = [0, 1, 90_002, 90_003]
    document.request(rows: rows)
    settle(document)
    document.request(syntax: true)
    settle(document)
    assert_equal ["First", "Last"], document.outline.map(&:name)
    assert document.syntax_ready?
    refute document.syntax_complete?
    refute document.pending?
    rows.each { |row| assert document.tokens_current?(row) }
  end

  def test_summary_merge_keeps_diagnostics_from_truncated_full_file_results
    diagnostics = 1001.times.map { |index| {range: index...(index + 1), message: "missing delimiter #{index}", severity: 1}.freeze }
    previous = {outline: [], diagnostics: diagnostics.first(1000), folds: [], brackets: {}, complete: false}
    current = previous.merge(diagnostics: diagnostics.last(1000))
    merged = BackgroundAnalysis.merge_syntax(previous, current)
    assert_equal diagnostics.first(1000), merged[:diagnostics]
    assert merged.frozen?
    assert merged[:diagnostics].frozen?
    refute merged[:complete]
  end
end

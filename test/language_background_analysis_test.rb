# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "tmpdir"

class LanguageBackgroundAnalysisTest < Minitest::Test
  BackgroundAnalysis = Canopus::Language.const_get(:BackgroundAnalysis, false)

  def setup = @documents = []
  def teardown = @documents.reverse_each(&:dispose)

  def document(source, name: "example.rb", **options)
    buffer = Canopus::Buffer.new(source, path: name)
    Canopus::Language::Document.new(buffer, **options).tap { |doc| @documents << doc }
  end

  def settle(doc, timeout: 10)
    changed = 0
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while doc.pending?
      changed += 1 if doc.poll
      raise "language calculation timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.005
    end
    changed
  end

  def test_paint_queries_do_not_parse_lex_copy_whole_buffer_or_start_threads
    doc = document("class 日本\nend\n")
    threads = Thread.list
    doc.stub(:highlighter, ->(*) { flunk "UI must not lex" }) do
      doc.stub(:ruby_syntax, ->(*) { flunk "UI must not parse" }) do
        doc.buffer.stub(:text, ->(*) { flunk "UI must not copy the whole buffer" }) do
          assert_equal [["Text", "class 日本\n"]], doc.tokens_for(0)
          assert_empty doc.outline
          assert_empty doc.diagnostics
          assert_empty doc.fold_ranges
          assert_nil doc.bracket_at(0)
        end
      end
    end
    assert_equal threads, Thread.list
    assert doc.background?
    assert doc.pending?
    refute doc.syntax_ready?
    refute doc.syntax_complete?
  end

  def test_actual_child_tokens_outline_diagnostics_folds_and_brackets_equal_sync_oracle
    source = "module 日本\n  class Example\n    def hello(name)\n      puts(name)\n    end\n  end\nend\n"
    doc = document(source)
    oracle = document(source, background: false)
    doc.request(first_line: 0, last_line: doc.buffer.line_count - 1, syntax: true)
    assert_equal 1, settle(doc)
    doc.buffer.line_count.times do |row|
      assert_equal oracle.tokens_for(row).map { |token, text| [token.qualname, text] }, doc.tokens_for(row)
    end
    assert_equal oracle.outline, doc.outline
    assert_equal oracle.diagnostics, doc.diagnostics
    assert_equal oracle.fold_ranges, doc.fold_ranges
    byte = source.b.index("(")
    assert_equal oracle.bracket_at(byte), doc.bracket_at(byte)
    assert_same doc.bracket_at(byte), doc.bracket_at(source.b.index(")"))
    assert doc.syntax_ready?
    assert doc.syntax_complete?
    refute doc.pending?
    refute doc.poll
  end

  def test_small_document_syntax_is_not_limited_to_256_token_rows
    doc = document("value = 1\n" * 600 + "class BeyondViewport\nend\n")
    doc.request(first_line: 0, last_line: 10, syntax: true)
    settle(doc)
    assert_equal ["BeyondViewport"], doc.outline.map(&:name)
    assert_operator doc.outline.first.range.begin, :>, 5000
    assert doc.syntax_complete?
    doc.tokens_for(256)
    settle(doc)
    refute_empty doc.tokens_for(256)
    refute doc.pending?
  end

  def test_non_ruby_brackets_and_tokens_ignore_strings_and_comments
    source = "call(\"[)\", value) // }\nconst 日本 = true;\n"
    doc = document(source, name: "example.js")
    oracle = document(source, name: "example.js", background: false)
    doc.request(first_line: 0, last_line: 2, syntax: true)
    settle(doc)
    assert_equal 4...17, doc.bracket_at(4)
    assert_nil doc.bracket_at(6)
    assert_nil doc.bracket_at(21)
    3.times { |row| assert_equal oracle.tokens_for(row).map { |token, text| [token.qualname, text] }, doc.tokens_for(row) }
    assert_empty doc.outline
  end

  def test_edits_discard_old_results_and_retained_syntax
    doc = document("class Old\nend\n" + "# filler\n" * 10_000)
    doc.request(first_line: 0, last_line: 2, syntax: true)
    doc.poll
    doc.buffer.edit([[6...9, "Latest"]])
    assert_empty doc.outline
    refute doc.syntax_ready?
    settle(doc)
    assert_equal ["Latest"], doc.outline.map(&:name)
    assert_equal "class Latest\n", doc.tokens_for(0).map(&:last).join
    assert doc.syntax_complete?
    doc.buffer.edit([[doc.buffer.rope.bytesize...doc.buffer.rope.bytesize, "def incomplete("]])
    settle(doc)
    refute_empty doc.diagnostics
    assert doc.syntax_ready?
  end

  def test_unchanged_rows_keep_proven_or_explicitly_stale_colors_across_line_edits
    doc = document("class A\n  value = true\n  other = false\nend\n")
    doc.request(first_line: 0, last_line: 4, syntax: true)
    settle(doc)
    first, later = doc.tokens_for(0), doc.tokens_for(3)
    insertion = doc.buffer.rope.line_start(1) + 2
    doc.buffer.edit([[insertion...insertion, "# inserted\n  "]])
    assert_same first, doc.tokens_for(0)
    assert doc.tokens_current?(0)
    assert_same later, doc.tokens_for(4)
    refute doc.tokens_current?(4)
    assert_equal "end\n", doc.tokens_for(4).map(&:last).join
    assert_equal "  # inserted\n", doc.tokens_for(1).map(&:last).join
    refute doc.syntax_ready?
    settle(doc)
    assert doc.tokens_current?(4)
    assert doc.syntax_ready?
    doc.buffer.undo
    assert_equal "end\n", doc.tokens_for(3).map(&:last).join
    refute doc.tokens_current?(3)
    settle(doc)
    assert doc.tokens_current?(3)
  end

  def test_rapid_replacements_keep_one_latest_job_and_two_global_slots
    doc = document("class C0\nend\n" + "# filler\n" * 5000)
    doc.request(first_line: 0, last_line: 2, syntax: true)
    20.times do |index|
      doc.poll
      body = "class C#{index + 1}\nend\n" + "# filler\n" * 5000
      doc.buffer.edit([[0...doc.buffer.rope.bytesize, body]])
      state = doc.instance_variable_get(:@background)
      scheduler = state.instance_variable_get(:@scheduler)
      assert_operator scheduler.instance_variable_get(:@jobs).length, :<=, 2
    end
    settle(doc)
    assert_equal ["C20"], doc.outline.map(&:name)
    refute doc.pending?
  end

  def test_multiple_documents_share_two_processes_and_shutdown_after_last_owner
    docs = Array.new(8) { |index| document("class C#{index}\nend\n") }
    spawn, pids = Process.method(:spawn), []
    threads = Thread.list
    Process.stub(:spawn, ->(*args, **options) { spawn.call(*args, **options).tap { |pid| pids << pid } }) do
      docs.each { |doc| doc.request(first_line: 0, last_line: 2, syntax: true) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      while docs.any?(&:pending?)
        docs.each(&:poll)
        raise "shared language scheduler timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.005
      end
      assert_operator pids.length, :<=, 2
      assert_operator pids.length, :>=, 1
      docs.each_with_index { |doc, index| assert_equal ["C#{index}"], doc.outline.map(&:name) }
      docs.first(7).each(&:dispose)
      assert docs.last.syntax_ready?
      docs.last.dispose
    end
    pids.each { |pid| assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) } }
    assert_empty Thread.list - threads
  end

  def test_dispose_during_preparation_or_running_request_is_bounded_and_idempotent
    [false, true].each do |wait_for_inner|
      doc = document("# a long but valid source line\n" * 30_000)
      doc.request(first_line: 0, last_line: 2, syntax: true)
      doc.poll
      if wait_for_inner
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        until doc.instance_variable_get(:@background).instance_variable_get(:@job).inner
          raise "worker did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.005
        end
      end
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      doc.dispose
      doc.dispose
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 3
      refute doc.pending?
      refute doc.poll
      refute doc.syntax_ready?
    end
  end

  def test_worker_failure_is_reported_once_without_retrying_every_paint
    definition = Canopus::Language::Definition.new("unknown", "not-a-lexer", [], "", /\A\z/, /\A\z/, [])
    doc = document("text\n", definition: definition)
    doc.request(first_line: 0, last_line: 1, syntax: true)
    error = assert_raises(StandardError) { settle(doc) }
    assert_same error, doc.analysis_error
    refute doc.pending?
    refute doc.syntax_ready?
    assert_equal "text\n", doc.tokens_for(0).map(&:last).join
    refute doc.pending?
    doc.request(first_line: 0, last_line: 1, syntax: true)
    assert_same error, doc.analysis_error
    refute doc.pending?
    doc.request(rows: [0])
    assert_nil doc.analysis_error
    assert doc.pending?
    retry_error = assert_raises(StandardError) { settle(doc) }
    assert_same retry_error, doc.analysis_error
    doc.buffer.edit([[0...0, "new "]])
    assert_nil doc.analysis_error
    assert doc.pending?
    assert_raises(StandardError) { settle(doc) }
    refute_nil doc.analysis_error
    doc.dispose
    assert_nil doc.analysis_error
  end

  def test_large_document_preparation_preserves_context_and_absolute_offsets
    source = ("#" + "x" * 100 + "\n") * 12_000
    doc = document(source)
    snapshot = BackgroundAnalysis::Snapshot.new(doc.buffer.rope, 0, "context", "ruby", "ruby", 6000, 6004, true)
    request = BackgroundAnalysis.prepare(snapshot, BackgroundAnalysis::Job.new)
    assert_equal 5500, request["base_line"]
    assert_equal 500, request["context"]
    assert_equal 1005, request["source"].lines.length
    assert_equal doc.buffer.rope.line_start(5500), request["base"]
    refute request["complete"]
    doc.request(first_line: 6000, last_line: 6004, syntax: true)
    settle(doc)
    assert doc.syntax_ready?
    refute doc.syntax_complete?
    assert_empty doc.diagnostics
  end

  def test_over_ten_megabytes_uses_visible_only_without_copying_whole_source
    doc = document(("#" + "x" * 100 + "\n") * 110_000)
    snapshot = BackgroundAnalysis::Snapshot.new(doc.buffer.rope, 0, "visible", "ruby", "ruby", 50_000, 50_002, true)
    request = BackgroundAnalysis.prepare(snapshot, BackgroundAnalysis::Job.new)
    assert_equal 50_000, request["base_line"]
    assert_equal 0, request["context"]
    assert_equal 3, request["source"].lines.length
    refute request["complete"]
  end

  def test_partial_syntax_is_invalidated_when_requested_window_changes
    doc = document("# filler line\n" * 90_000 + "class EndOfFile\nend\n")
    doc.request(first_line: 0, last_line: 2, syntax: true)
    settle(doc)
    assert doc.syntax_ready?
    assert_empty doc.outline
    doc.request(first_line: 90_000, last_line: 90_002, syntax: true)
    refute doc.syntax_ready?
    assert_empty doc.outline
    settle(doc)
    assert doc.syntax_ready?
    assert_equal ["EndOfFile"], doc.outline.map(&:name)
    refute doc.syntax_complete?
  end

  def test_giant_line_provisional_and_worker_snapshot_are_utf8_bounded
    doc = document("日" * 800_000 + "\nclass Visible\nend\n")
    provisional = doc.tokens_for(0).map(&:last).join
    assert provisional.valid_encoding?
    assert_operator provisional.bytesize, :<=, BackgroundAnalysis::LINE_LIMIT
    snapshot = BackgroundAnalysis::Snapshot.new(doc.buffer.rope, 0, "giant", "ruby", "ruby", 0, 0, true)
    request = BackgroundAnalysis.prepare(snapshot, BackgroundAnalysis::Job.new)
    assert request["source"].valid_encoding?
    assert_operator request["source"].bytesize, :<=, BackgroundAnalysis::SOURCE_LIMIT
    doc.request(first_line: 1, last_line: 3, syntax: true)
    settle(doc)
    assert_equal ["Visible"], doc.outline.map(&:name)
    assert_equal doc.buffer.rope.line_start(1) + 6, doc.outline.first.selection.begin
    refute doc.syntax_complete?
  end

  def test_lazy_read_only_documents_do_not_schedule_analysis
    Dir.mktmpdir("canopus-language-lazy-") do |root|
      path = File.join(root, "large.rb")
      File.binwrite(path, "class ReadOnly\nend\n")
      buffer = Canopus::Buffer.open(path, large_file_threshold: 0)
      doc = Canopus::Language::Document.new(buffer)
      @documents << doc
      assert_empty doc.outline
      doc.request(first_line: 0, last_line: 1, syntax: true)
      refute doc.pending?
      refute doc.poll
      assert_equal "class ReadOnly\n", doc.tokens_for(0).map(&:last).join
    ensure
      doc&.dispose
      buffer&.close
    end
  end
end

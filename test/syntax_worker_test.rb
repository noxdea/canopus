# frozen_string_literal: true

require_relative "test_helper"
require "canopus/language/syntax_worker"
require "open3"
require "rbconfig"

class SyntaxWorkerTest < Minitest::Test
  Worker = Canopus::Language::SyntaxWorker
  BackgroundAnalysis = Canopus::Language.const_get(:BackgroundAnalysis, false)

  def request(source, lexer, id, syntax: false)
    {"source" => source, "lexer" => lexer, "name" => lexer, "id" => id,
      "base" => 0, "base_line" => 0, "first" => 0, "last" => source.count("\n"),
      "version" => 0, "syntax" => syntax, "complete" => true, "context" => 0}
  end

  def test_unbundled_worker_boot_does_not_reload_strscan
    _, error, status = Open3.capture3({"RUBYOPT" => nil, "RUBYLIB" => nil}, RbConfig.ruby, "-Ilib", "-e",
      'require "canopus/language/syntax_worker"; require "antares"', chdir: File.expand_path("..", __dir__))
    assert status.success?, error
    refute_includes error, "already initialized constant StringScanner"
  end

  def test_persistent_lexer_caches_match_fresh_oracle_after_unicode_mutations
    sources = {"ruby" => "class Example\n  def method\n    \"日本\"\n  end\nend\n",
      "javascript" => "function hello() {\n  return '😀';\n}\n", "python" => "def hello():\n  return '日本'\n",
      "json" => "{\n  \"name\": \"日本\",\n  \"enabled\": true\n}\n"}
    sources.each do |lexer, original|
      variants = [original, "\n" + original, "\n" + original.sub("日本", "😀"), original, original + "\n"]
      variants.each do |source|
        payload = request(source, lexer, "oracle-#{lexer}")
        result = Worker.call(payload).fetch("tokens")
        buffer = Canopus::Buffer.new(source)
        definition = Canopus::Language::Definition.new(lexer, lexer, [], "", /\A\z/, /\A\z/, [])
        document = Canopus::Language::Document.new(buffer, definition: definition, background: false)
        expected = document.highlighter.tokens_in(0...buffer.line_count).map.with_index do |pairs, row|
          [row, pairs.map { |token, text| [token.qualname, text] }]
        end
        assert_equal expected, result, lexer
        document.dispose
      end
    end
  end

  def test_worker_cache_limits_and_history_retention
    9.times { |index| Worker.call(request("value #{index}\n", "plaintext", "cache-#{index}")) }
    cache = Worker.instance_variable_get(:@documents)
    assert_operator cache.length, :<=, Worker::MAX_DOCUMENTS
    assert_operator cache.values.sum { |entry| entry[2].bytesize }, :<=, Worker::MAX_CACHE_BYTES
    20.times { |index| Worker.call(request("value #{index}\n", "plaintext", "edits")) }
    cache.values.each { |buffer, _document, _source| assert_empty buffer.history }
  end

  def test_certified_incremental_lexer_reuses_state_instead_of_rebuilding_every_edit
    # Newline-ending callbacks admit checkpoints; indented JSON whitespace can
    # cross line boundaries and legitimately require a full scan.
    source = "{\n" + (0...120).map { |n| "\"field#{n}\":#{n},\n" }.join + "\"end\":true\n}\n"
    Worker.call(request(source, "json", "incremental"))
    original = Worker.instance_variable_get(:@documents).values.find { |entry| entry[2] == source }
    highlighter = original[1].highlighter
    suffix = highlighter.tokens_for(100)
    changed = source.sub('"field64":64', '"field64":99')
    Worker.call(request(changed, "json", "incremental"))
    cached = Worker.instance_variable_get(:@documents).values.find { |entry| entry[2] == changed }
    assert_same highlighter, cached[1].highlighter
    assert_same suffix, highlighter.tokens_for(100)
    assert_equal :incremental, highlighter.strategy
    assert_operator highlighter.last_scanned_lines, :<=, 3
    assert_empty cached[0].history
  end

  def test_bounded_syntax_summary_marks_truncation_instead_of_claiming_completeness
    source = "[]\n" * (Worker::MAX_BRACKETS + 1)
    payload = request(source, "json", "bracket-limit", syntax: true).merge("last" => 1)
    response = Worker.call(payload)
    assert_equal Worker::MAX_BRACKETS, response.fetch("syntax").fetch("brackets").length
    refute response.fetch("complete")
  end

  def test_long_line_token_payload_is_bounded_and_valid_utf8
    source = "日" * 20_000 + "\n"
    response = Worker.call(request(source, "plaintext", "long-line"))
    pairs = response.fetch("tokens").first.last
    assert_equal ["Text"], pairs.map(&:first)
    assert pairs.first.last.valid_encoding?
    assert_operator pairs.first.last.bytesize, :<=, BackgroundAnalysis::LINE_LIMIT
  end

  def test_worker_rejects_unbounded_or_invalid_snapshot_ranges
    payload = request("text\n", "plaintext", "invalid")
    [payload.merge("last" => BackgroundAnalysis::ROW_LIMIT), payload.merge("base_line" => 1),
      payload.merge("first" => -1), payload.merge("source" => "\xff".dup.force_encoding(Encoding::UTF_8)),
      payload.merge("source" => "x" * (BackgroundAnalysis::SOURCE_LIMIT + 1))].each do |invalid|
      assert_raises(ArgumentError) { Worker.call(invalid) }
    end
  end
end

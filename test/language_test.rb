# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class LanguageTest < Minitest::Test
  def test_ruby_outline_indent_diagnostics_and_brackets
    source = "module A\n  class B\n    def hello(name)\n      puts(name)\n    end\n  end\nend\n"
    buffer = Canopus::Buffer.new(source, path: "example.rb")
    doc = Canopus::Language::Document.new(buffer, background: false)
    assert_equal %w[A B hello], doc.outline.map(&:name)
    assert_equal [0, 1, 2], doc.outline.map(&:depth)
    assert_equal "  ", doc.indent_for(8, tab_size: 2)
    assert_equal [], doc.diagnostics
    parenthesis = source.index("(")
    assert_equal "(name)", source[doc.bracket_at(parenthesis)]
    buffer.edit([[source.bytesize...source.bytesize, "def incomplete("]])
    refute_empty doc.diagnostics
    doc.dispose
  end

  def test_snippet_mirrors_tabstops_and_utf8_offsets
    editor = Canopus::Editor.new
    editor.auto_pairs = false
    snippet = editor.insert_snippet('${1:日本} = $1; ${2|yes,no|}$0')
    assert_equal "日本 = 日本; yes", snippet.text
    assert_equal ["日本", "日本"], editor.selections.map { |selection| editor.buffer.rope.byteslice(selection.range).to_s }
    editor.insert_text("value")
    assert_equal "value = value; yes", editor.buffer.text
    assert editor.next_snippet
    assert_equal "yes", editor.buffer.rope.byteslice(editor.primary.range).to_s
    editor.insert_text("no")
    assert editor.next_snippet
    assert_equal editor.buffer.rope.bytesize, editor.primary.head
    refute editor.next_snippet
    editor.dispose
  end
  def test_non_ruby_brackets_skip_comments_and_strings_and_invalidate_cache
    buffer = Canopus::Buffer.new('call("[)", value) // }', path: "code.js")
    document = Canopus::Language::Document.new(buffer, background: false)
    assert_equal 4...17, document.bracket_at(4)
    assert_nil document.bracket_at(6)
    assert_nil document.bracket_at(21)
    assert_same document.bracket_at(4), document.bracket_at(16)
    buffer.edit([[4...5, "["]])
    assert_nil document.bracket_at(4)
    document.dispose
  end

  def test_snippet_nested_defaults_variables_escaping_and_validation
    snippet = Canopus::Snippet.new('${1:hello ${2:world}} $TM_FILENAME \\$literal', variables: {"TM_FILENAME" => "main.rb"})
    assert_equal "hello world main.rb $literal", snippet.text
    assert_equal [1, 2], snippet.tabstops.keys
    assert_raises(Canopus::Error) { Canopus::Snippet.new('${1:unterminated') }
  end

  def test_workspace_edit_preflight_preserves_all_buffers
    Dir.mktmpdir("canopus-language-") do |directory|
      paths = %w[a.rb b.rb].map { |name| File.join(directory, name) }
      paths.each { |path| File.write(path, "hello") }
      workspace = Canopus::Workspace.new(root: directory)
      first = workspace.open(paths.first).buffer
      second = workspace.open(paths.last).buffer
      changes = paths.to_h do |path|
        [Canopus::LSP::Protocol.uri(path), [{"range" => {"start" => {"line" => 0, "character" => 0}, "end" => {"line" => path == paths.first ? 0 : 500, "character" => 5}}, "newText" => "new"}]]
      end
      assert_raises(RangeError) { workspace.apply_workspace_edit({"changes" => changes}) }
      assert_equal "hello", first.text
      assert_equal "hello", second.text
      changes.values.last.first["range"]["end"]["line"] = 0
      assert_equal({"applied" => true}, workspace.apply_workspace_edit({"changes" => changes}))
      assert_equal ["new", "new"], [first.text, second.text]
      assert_equal ["hello", "hello"], paths.map { |path| File.read(path) }
      workspace.close
    end
  end

  def test_file_uri_roundtrip_reserved_characters
    path = File.expand_path("日本 #1%?test.rb")
    uri = Canopus::LSP::Protocol.uri(path)
    assert_includes uri, "%23"
    assert_includes uri, "%3F"
    assert_equal path, Canopus::LSP::Protocol.path(uri)
    assert_raises(Canopus::LSP::Error) { Canopus::LSP::Protocol.path("file://example.com/remote.rb") }
  end

  def test_future_callbacks_before_and_after_fulfillment
    future, values = Canopus::LSP::Future.new(1), []
    future.then { |value, error| values << [value, error] }
    future.fulfill(42)
    future.fulfill(99)
    future.then { |value, error| values << [value, error] }
    assert_equal [[42, nil], [42, nil]], values
  end

  def test_filtered_completion_preserves_original_item_mapping
    Dir.mktmpdir("canopus-completion-") do |directory|
      workspace = Canopus::Workspace.new(root: directory)
      editor = workspace.new_buffer
      workspace.palette = {kind: :completion, query: "beta", index: 0, matches: %w[alpha beta],
        items: [{"label" => "alpha", "insertText" => "A"}, {"label" => "beta", "insertText" => "B"}], editor: editor}
      workspace.update_palette
      workspace.palette_accept
      assert_equal "B", editor.buffer.text
      workspace.close
    end
  end
end

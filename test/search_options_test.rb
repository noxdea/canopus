# frozen_string_literal: true
require_relative "test_helper"

class SearchOptionsTest < Minitest::Test
  def test_replacement_matches_ruby_substitution_with_context_and_captures
    source = "日本 ab AB abc"
    patterns = [/(a)(b)/i, /(?<=a)b/, /a(?=b)/, /(?<first>a)(?<last>b)/i, /a(b)?/, /(?=b)/]
    replacements = ['X', '\\0', '\\1-\\2', '\\&', '\\+', '\\`', "\\'", '\\\\1', '\\q']
    patterns.each do |pattern|
      replacements.each do |replacement|
        editor = Canopus::Editor.new(Canopus::Buffer.new(source))
        editor.replace_all(pattern, replacement)
        assert_equal source.gsub(pattern, replacement), editor.buffer.text, [pattern, replacement].inspect
        editor.dispose
      end
    end
    editor = Canopus::Editor.new(Canopus::Buffer.new("word WORD words"))
    assert_equal 2, editor.replace_all("word", "ok", case_sensitive: false, whole_word: true)
    assert_equal "ok ok words", editor.buffer.text
    editor.dispose
  end

  def test_palette_options_keep_selection_and_regex_captures
    Dir.mktmpdir("canopus-search-options-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      window = Zaniah::Platform.open_window(width: 640, height: 260)
      controller = Canopus::Controller.new(workspace, window)
      workspace.editor.insert_text("日本 cat CAT cat")
      workspace.editor.select(7, 14)
      workspace.call("search.replace")
      %w[ctrl-alt-r ctrl-alt-c ctrl-alt-s].each { |key| controller.key(key) }
      controller.input_text("(cat)")
      controller.key("enter")
      controller.input_text('x\\1')
      controller.key("enter")
      assert_equal "日本 xcat xCAT cat", workspace.editor.buffer.text
      workspace.editor.undo
      assert_equal "日本 cat CAT cat", workspace.editor.buffer.text
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end

  def test_invalid_replacement_references_match_ruby_without_partial_edits
    ['\\k<>', '\\k<a', '\\k<missing>', '\\\\k<a', '\\\\\\k<a', '\\k', '\\k<'].each do |replacement|
      [/(?<a>a)/, /z/].each do |pattern|
        source = "aa"
        expected = begin
          source.gsub(pattern, replacement)
        rescue StandardError => error
          error
        end
        editor = Canopus::Editor.new(Canopus::Buffer.new(source))
        if expected.is_a?(Exception)
          assert_raises(expected.class) { editor.replace_all(pattern, replacement) }
          assert_equal source, editor.buffer.text
          assert_empty editor.buffer.history
        else
          editor.replace_all(pattern, replacement)
          assert_equal expected, editor.buffer.text
        end
        editor.dispose
      end
    end
  end

  def test_excerpt_replacement_restores_cursor_through_undo_and_redo
    Dir.mktmpdir("canopus-search-undo-") do |root|
      File.write(File.join(root, "match.txt"), "foo foo")
      workspace = Canopus::Workspace.new(root: root)
      buffer = workspace.search_project("foo", async: false)
      editor = workspace.editor
      editor.select(buffer.excerpts.first.view_end)
      before = editor.primary
      assert_equal 2, workspace.replace_in_buffer("foo", "X")
      after = editor.primary
      assert_equal "X X", buffer.excerpts.first.buffer.text
      assert editor.undo
      assert_equal before, editor.primary
      assert editor.redo
      assert_equal after, editor.primary
      assert_equal "X X", buffer.excerpts.first.buffer.text
      assert_equal buffer.excerpts.first.view_end, editor.primary.head
    ensure
      workspace&.close
    end
  end
end

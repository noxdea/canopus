# frozen_string_literal: true
require_relative "test_helper"

class CommentToggleTest < Minitest::Test
  def test_language_comment_actions_are_balanced_and_preserve_whitespace_and_history
    Dir.mktmpdir("canopus-comments-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      {"css" => ["/*", "*/"], "html" => ["<!--", "-->"], "md" => ["<!--", "-->"]}.each do |extension, (first, last)|
        source = "  body { color: red; }  \r\n\t日本\r\n"
        File.binwrite(File.join(root, "example.#{extension}"), source)
        editor = workspace.open("example.#{extension}")
        editor.select_all
        workspace.call("edit.toggle_comment")
        expected = "  #{first} body { color: red; } #{last}  \r\n\t#{first} 日本 #{last}\r\n"
        assert_equal expected, editor.buffer.text
        assert_equal "", editor.snippet_variables["LINE_COMMENT"]
        workspace.call("edit.toggle_comment")
        assert_equal source, editor.buffer.text
        editor.undo
        assert_equal expected, editor.buffer.text
        editor.undo
        assert_equal source, editor.buffer.text
      end
    ensure
      workspace&.close
    end
  end

  def test_empty_prefix_is_a_noop_and_unsafe_nested_closers_do_not_partially_edit
    editor = Canopus::Editor.new(Canopus::Buffer.new("  unchanged\n/* existing */"))
    editor.select_all
    editor.toggle_comment(prefix: "")
    assert_equal "  unchanged\n/* existing */", editor.buffer.text
    assert_raises(Canopus::Error) { editor.toggle_comment(prefix: "/*") }
    assert_equal "  unchanged\n/* existing */", editor.buffer.text
  ensure
    editor&.dispose
  end
end

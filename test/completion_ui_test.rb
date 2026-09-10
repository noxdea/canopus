# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"

class CompletionUITest < Minitest::Test
  def edit(first, last, text)
    {"range" => {"start" => {"line" => 0, "character" => first}, "end" => {"line" => 0, "character" => last}}, "newText" => text}
  end
  def test_completion_preflight_and_single_undo_include_additional_edits
    Dir.mktmpdir("canopus-completion-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.new_buffer
      editor.insert_text("abc def")
      item = {"label" => "value", "textEdit" => edit(4, 7, "${1:value}"), "insertTextFormat" => 2, "additionalTextEdits" => [edit(0, 0, "import ")]}
      palette = {kind: :completion, editor: editor, version: editor.buffer.version, items: [item]}
      workspace.accept_language_result(palette, 0)
      assert_equal "import abc value", editor.buffer.text
      assert_equal "value", editor.buffer.rope.byteslice(editor.primary.range).to_s
      assert editor.undo
      assert_equal "abc def", editor.buffer.text
      invalid = item.merge("additionalTextEdits" => [edit(4, 5, "bad")])
      assert_raises(ArgumentError) { workspace.accept_language_result(palette.merge(version: editor.buffer.version, items: [invalid]), 0) }
      assert_equal "abc def", editor.buffer.text
      workspace.close
    end
  end
  def test_async_resolve_rechecks_document_version
    Dir.mktmpdir("canopus-resolve-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      editor = workspace.new_buffer
      future = Canopus::LSP::Future.new(1)
      client = Object.new
      client.define_singleton_method(:capabilities) { {"completionProvider" => {"resolveProvider" => true}} }
      client.define_singleton_method(:resolve_completion) { |_| future }
      palette = {kind: :completion, editor: editor, client: client, version: editor.buffer.version, items: [{"label" => "resolved"}]}
      workspace.accept_language_result(palette, 0)
      editor.insert_text("new")
      future.fulfill({"insertText" => "old"})
      workspace.instance_variable_get(:@language_jobs).each(&:join)
      workspace.drain
      assert_equal "new", editor.buffer.text
      assert_match(/Document changed/, workspace.message)
      workspace.close
    end
  end

  def test_completion_choices_and_backwards_tab_navigation
    Dir.mktmpdir("canopus-choices-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      window = Zaniah::Platform.open_window(width: 640, height: 260)
      controller = Canopus::Controller.new(workspace, window)
      editor = workspace.editor
      item = {"label" => "choice", "insertText" => "${1|red,green,blue|} ${2:end} $WORKSPACE_NAME $0", "insertTextFormat" => 2}
      workspace.accept_language_result({kind: :completion, editor: editor, items: [item]}, 0)
      assert_equal :snippet_choices, workspace.palette[:kind]
      controller.input(Zaniah::Input::TextInput.new("green"))
      assert_equal ["green"], workspace.palette[:matches]
      controller.key("enter")
      assert_equal "green end #{File.basename(root)} ", editor.buffer.text
      controller.key("tab")
      assert_equal "end", editor.buffer.rope.byteslice(editor.primary.range).to_s
      controller.key("shift-tab")
      assert_equal :snippet_choices, workspace.palette[:kind]
      controller.key("esc")
      assert editor.snippet_active?
      controller.key("esc")
      refute editor.snippet_active?
      workspace.close
      window.on_close { true }
      window.close
    end
  end
end

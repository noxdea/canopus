# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"
require "canopus/cli"

class WorkspaceTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("canopus-workspace-")
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
  def key(value) = @controller.input(Zaniah::Input::KeyDown.new(value, false))
  def type(value) = @controller.input(Zaniah::Input::TextInput.new(value))

  def test_keymap_context_uses_current_vim_mode
    @controller.keymap.bind("f8", "pane.split_right", context: "Editor && vim_mode == normal")
    key("f8")
    assert_equal 1, @workspace.panes.length
    @workspace.settings.merge!("vim_mode" => true)
    key("f8")
    assert_equal 2, @workspace.panes.length
    type("i")
    assert_equal :insert, @workspace.vim.mode
    key("f8")
    assert_equal 2, @workspace.panes.length
    key("escape")
    key("f8")
    assert_equal 3, @workspace.panes.length
  end

  def test_new_documents_use_current_text_settings
    @workspace.settings.merge!("tab_size" => 2, "soft_wrap" => true)
    editor = @workspace.new_buffer
    assert_equal 2, editor.tab_size
    assert_equal 2, editor.display_map.tab_map.tab_size
    assert_equal 100, editor.display_map.wrap_map.width
    @workspace.call("view.wrap")
    assert_nil editor.display_map.wrap_map.width
  end

  def test_multicursor_and_line_movement_shortcuts_reach_editor_actions
    type("one one\ntwo")
    @workspace.editor.select(0, 3)
    key("cmd-shift-l")
    assert_equal [0...3, 4...7], @workspace.editor.selections.map(&:range)
    key("alt-down")
    assert_equal "two\none one", @workspace.editor.buffer.text
    assert_equal [4...7, 8...11], @workspace.editor.selections.map(&:range)
    key("cmd-z")
    assert_equal "one one\ntwo", @workspace.editor.buffer.text
  end

  def test_settings_keymap_replaces_old_bindings_and_updates_palette_labels
    @workspace.settings.merge!("keymap" => [{"bindings" => {"f8 f9" => "pane.split_right", "f12" => "file.new"}}])
    key("f8")
    assert_equal 1, @workspace.panes.length
    key("f9")
    assert_equal 2, @workspace.panes.length
    labels = @controller.view.send(:shortcut_labels)
    assert_equal "f8  f9", labels["pane.split_right"]
    assert_equal "f12", labels["file.new"]
    refute labels.key?("language.definition")
    @workspace.settings.merge!("keymap" => [{"context" => "Editor && vim_mode == normal", "bindings" => {"f8" => "pane.split_right"}}])
    key("f8")
    assert_equal 2, @workspace.panes.length
    @workspace.settings.merge!("vim_mode" => true)
    key("f8")
    assert_equal 3, @workspace.panes.length
    key("f9")
    assert_equal 3, @workspace.panes.length
  end

  def test_language_keymap_changes_with_the_active_document
    @workspace.settings.merge!("keymap" => [{"bindings" => {"f8" => "pane.split_right"}}],
      "languages" => {"ruby" => {"keymap" => [{"bindings" => {"f8" => "file.new"}}]}})
    ruby_editor = @workspace.open("new.rb")
    key("f8")
    refute_same ruby_editor, @workspace.editor
    assert_equal 1, @workspace.panes.length
    key("f8")
    assert_equal 2, @workspace.panes.length
  end

  def test_user_chord_overrides_default_single_key_without_stale_palette_hint
    @workspace.settings.merge!("keymap" => [{"bindings" => {"ctrl-k ctrl-s" => "pane.split_right"}}])
    requests = []
    @workspace.stub(:language_request, ->(kind, **) { requests << kind }) do
      key("ctrl-k")
      assert_empty requests
      assert_equal 1, @workspace.panes.length
      refute_equal "ctrl-k", @controller.view.send(:shortcut_labels)["language.hover"]
      key("ctrl-s")
      assert_equal 2, @workspace.panes.length
    end
  end

  def test_save_as_applies_the_new_language_settings_in_all_panes
    @workspace.settings.merge!("languages" => {"ruby" => {"tab_size" => 2, "use_tabs" => true, "soft_wrap" => true}})
    @workspace.split
    @workspace.save_buffer(path: "new.rb")
    @workspace.panes.each do |pane|
      assert_equal 2, pane.active.tab_size
      assert pane.active.use_tabs
      assert_equal 100, pane.active.display_map.wrap_map.width
    end
  end

  def test_png_export_settles_visible_language_results_before_final_paint
    File.write(File.join(@directory, "export.rb"), "class Example\nend\n")
    editor = @workspace.open("export.rb")
    @window.text_system = Zaniah::TextSystem::Renderer.new
    Canopus::CLI.send(:settle_export, @controller, @window, timeout: 5)
    document = editor.language_document
    refute document.pending?
    assert document.tokens_current?(0)
    assert document.tokens_for(0).any? { |name, _| name.start_with?("Keyword") }
    cached = @controller.view.instance_variable_get(:@code_caches).fetch(editor).values
    assert cached.any? { |value| value.first.equal?(document.tokens_for(0)) }
  end

  def test_png_export_times_out_instead_of_saving_unfinished_background_state
    @workspace.editor.language_document.stub(:pending?, true) do
      error = assert_raises(Canopus::Error) { Canopus::CLI.send(:settle_export, @controller, @window, timeout: 0) }
      assert_includes error.message, "PNG export timed out"
    end
  end

  def test_png_export_rejects_failed_background_work
    failure = RuntimeError.new("syntax worker failed")
    @workspace.editor.language_document.stub(:analysis_error, failure) do
      error = assert_raises(Canopus::Error) { Canopus::CLI.send(:settle_export, @controller, @window) }
      assert_equal "PNG export failed: syntax worker failed", error.message
    end
    @workspace.editor.display_map.stub(:layout_error, failure) do
      assert_raises(Canopus::Error) { Canopus::CLI.send(:settle_export, @controller, @window) }
    end
  end

  def test_diagnostics_are_collected_once_per_buffer_and_frame
    type("first\nsecond\nthird")
    @workspace.split
    calls = []
    @workspace.stub(:diagnostics_for, ->(buffer) { calls << buffer; [] }) do
      @controller.tick
      assert_equal [@workspace.editor.buffer], calls
      @window.request_frame
      @controller.tick
      assert_equal [@workspace.editor.buffer] * 2, calls
    end
  end

  def test_typing_selection_clipboard_history_and_keyup
    type("日本 hello")
    key("cmd-a")
    key("cmd-c")
    key("right")
    key("cmd-v")
    assert_equal "日本 hello日本 hello", @workspace.editor.buffer.text
    key("cmd-z")
    assert_equal "日本 hello", @workspace.editor.buffer.text
    @controller.input(Zaniah::Input::KeyUp.new("cmd-z"))
    assert_equal "日本 hello", @workspace.editor.buffer.text
    key("cmd-shift-z")
    assert_equal "日本 hello日本 hello", @workspace.editor.buffer.text
  end

  def test_split_shares_buffer_and_transforms_other_cursor
    type("hello")
    first = @workspace.editor
    @workspace.split
    second = @workspace.editor
    assert_same first.buffer, second.buffer
    second.select(0)
    type("big ")
    assert_equal 9, first.primary.head
    key("cmd-z")
    assert_equal "hello", first.buffer.text
    assert_equal 5, first.primary.head
  end

  def test_palette_opens_files_and_executes_commands
    File.binwrite(File.join(@directory, "hello.rb"), "puts :hello\n")
    key("cmd-p")
    type("hlrb")
    assert_equal ["hello.rb"], @workspace.palette[:matches]
    key("enter")
    assert_equal "puts :hello\n", @workspace.editor.buffer.text
    key("cmd-shift-p")
    type("pane.split_down")
    key("enter")
    assert_equal 2, @workspace.panes.length
  end

  def test_file_finder_keeps_recent_files_first_when_scores_tie
    File.write(File.join(@directory, "a.rb"), "")
    File.write(File.join(@directory, "long_recent_file.rb"), "")
    @workspace.open("long_recent_file.rb")
    @workspace.palette_open(:files)
    assert_equal ["long_recent_file.rb", "a.rb"], @workspace.palette[:matches]
  end

  def test_workspace_symbol_action_accepts_a_query
    @workspace.call("language.workspace_symbols")
    assert_equal :workspace_symbols, @workspace.palette[:kind]
    type("Example")
    requests = []
    @workspace.stub(:language_request, ->(kind, **options) { requests << [kind, options] }) { @workspace.palette_accept }
    assert_equal [[:workspace_symbols, {query: "Example"}]], requests
  end

  def test_session_draft_conflicts_and_shared_buffers
    path, session = File.join(@directory, "hello.rb"), File.join(@directory, "session.json")
    File.binwrite(path, "old\n")
    original = @workspace.open(path)
    original.insert_text("new ")
    @workspace.split
    @workspace.active_pane.pin
    @workspace.save_session(session)
    File.binwrite(path, "externally modified\n")
    @workspace.restore_session(session)
    restored = @workspace.editor
    assert restored.buffer.dirty?
    assert_equal "new old\n", restored.buffer.text
    assert_includes @workspace.active_pane.pinned, restored
    assert_same restored.buffer, @workspace.panes.first.editors.last.buffer
    assert_raises(Canopus::SaveConflict) { restored.buffer.save }
    assert_equal "externally modified\n", File.read(path)
  end

  def test_invalid_session_does_not_destroy_current_workspace
    type("keep this draft")
    original = @workspace.editor
    path = File.join(@directory, "bad.json")
    File.write(path, JSON.generate(version: 1, panes: [{tabs: []}], layout: {pane: 999}))
    assert_raises(IndexError) { @workspace.restore_session(path) }
    assert_same original, @workspace.editor
    type("!")
    assert_equal "keep this draft!", original.buffer.text
  end

  def test_save_as_reuses_the_buffer_and_rejects_an_open_destination
    original = @workspace.editor
    type("draft")
    @workspace.save_buffer(path: "saved.rb")
    assert_same original.buffer, @workspace.open("saved.rb").buffer
    assert_equal "ruby", original.language_document.definition.name
    assert_equal [original.buffer], @workspace.buffers.values
    another = @workspace.new_buffer
    another.insert_text("keep")
    assert_raises(Canopus::Error) { @workspace.save_buffer(path: "saved.rb") }
    assert_equal "draft", File.read(File.join(@directory, "saved.rb"))
    assert_equal "keep", another.buffer.text
    @workspace.settings.merge!("vim_mode" => true)
    @workspace.vim.feed(":")
    "w vim.rb".each_char { |char| @workspace.vim.feed(char) }
    @workspace.vim.feed("enter")
    assert_same another.buffer, @workspace.open("vim.rb").buffer
  end

  def test_session_preserves_selections_and_background_drafts
    type("日本 hello")
    original = @workspace.editor
    original.select(0, 6)
    original.select(7, 12, add: true)
    hidden = Canopus::Buffer.new("background", draft: true)
    @workspace.buffers[hidden.object_id] = hidden
    session = File.join(@directory, "session.json")
    @workspace.save_session(session)
    @workspace.restore_session(session)
    assert_equal [[0, 6], [7, 12]], @workspace.editor.selections.map { |selection| [selection.anchor, selection.head] }
    assert_includes @workspace.buffers.values.map(&:text), "background"
    data = JSON.parse(File.read(session))
    data["panes"] << data["panes"].first
    data["layout"] = {"direction" => "horizontal", "children" => [{"pane" => 0}, {"pane" => 0}]}
    File.write(session, JSON.generate(data))
    current = @workspace.editor
    assert_raises(Canopus::Error) { @workspace.restore_session(session) }
    assert_same current, @workspace.editor
  end

  def test_file_aliases_share_a_buffer_and_disconnected_lsp_does_not_prevent_close
    path = File.join(@directory, "real.rb")
    File.write(path, "original")
    File.symlink(path, File.join(@directory, "alias.rb"))
    original = @workspace.open(path)
    assert_same original.buffer, @workspace.open("alias.rb").buffer
    client = Object.new
    client.define_singleton_method(:close_document) { |_| raise IOError, "closed pipe" }
    @workspace.instance_variable_set(:@opened_lsp_documents, {[client, original.buffer] => true})
    @workspace.close_editor(original)
    refute_includes @workspace.buffers.values, original.buffer
    assert_empty @workspace.instance_variable_get(:@opened_lsp_documents)
    assert_match(/closed pipe/, @workspace.message)
  rescue NotImplementedError, Errno::EACCES
    skip "symlinks unavailable"
  end

  def test_rename_cannot_hide_an_unsaved_destination_and_saves_notify_lsp
    path = File.join(@directory, "old.rb")
    File.write(path, "old")
    original = @workspace.open(path)
    draft = @workspace.open("new.rb")
    draft.insert_text("precious draft")
    assert_raises(Canopus::Error) { @workspace.rename_project_entry("old.rb", "new.rb") }
    assert File.file?(path)
    assert_includes @workspace.buffers.values, draft.buffer
    assert_equal "precious draft", draft.buffer.text
    notifications = []
    client = Object.new
    client.define_singleton_method(:save_document) { |uri| notifications << uri }
    client.define_singleton_method(:close_document) { |_| }
    @workspace.instance_variable_set(:@opened_lsp_documents, {[client, original.buffer] => true})
    original.insert_text("saved ")
    @workspace.save_buffer(original.buffer)
    assert_equal [Canopus::LSP::Protocol.uri(File.realpath(path))], notifications
  end

  def test_new_path_cannot_overwrite_an_existing_file
    path = File.join(@directory, "created_elsewhere.rb")
    buffer = Canopus::Buffer.new("new", path: path)
    File.write(path, "precious")
    assert_raises(Canopus::SaveConflict) { buffer.save }
    assert_equal "precious", File.read(path)
  end
  def test_discarded_last_tab_does_not_remain_as_an_unsaved_hidden_buffer
    path = File.join(@directory, "discard.txt")
    File.write(path, "disk")
    current = @workspace.open(path)
    current.insert_text("unsaved")
    @workspace.close_editor(current, discard: true)
    refute @workspace.buffers.values.any?(&:dirty?)
    assert_equal "disk", @workspace.open(path).buffer.text
  end

  def test_settings_merge_is_validated_and_comments_survive
    settings = Canopus::Settings.new({"languages" => {"ruby" => {"tab_size" => 2}}})
    assert_equal 2, settings.for_language("ruby")["tab_size"]
    assert_raises(Canopus::Error) { settings.merge!("tab_size" => 0) }
    assert_equal 4, settings["tab_size"]
    path = File.join(@directory, "settings.jsonc")
    File.write(path, "{ // keep this\n  \"tab_size\": 4,\n}\n")
    settings.set_file(path, "tab_size", 2)
    assert_includes File.read(path), "// keep this"
    assert_equal 2, Canopus::Settings.new(path)["tab_size"]
  end

  def test_ui_layout_mouse_and_virtualization
    type((1..1000).map { |number| "line #{number}" }.join("\n"))
    @workspace.editor.select(0)
    @workspace.editor.scroll(dy: -2000)
    @controller.tick
    assert_operator @controller.view.row_layouts.length, :<, 30
    assert @controller.view.accessibility.any? { |node| node[:role] == :textbox }
    box = @controller.view.editor_bounds.fetch(@workspace.editor)
    point = Zaniah::Point.new(box.x + 70, box.y + 10)
    @controller.input(Zaniah::Input::MouseDown.new(point, :left, [], 1))
    assert_operator @workspace.editor.primary.head, :>, 0
    assert_operator @workspace.editor.primary.head, :<, 10
  end

  def test_close_requires_explicit_discard_and_vim_routes_text_once
    @workspace.settings.merge!("vim_mode" => true)
    key("i")
    type("i")
    type("abc")
    key("esc")
    key("x")
    type("x")
    assert_equal "ab", @workspace.editor.buffer.text
    assert_equal false, @window.close
    assert_equal :confirm_close, @workspace.palette[:kind]
    key("down")
    key("enter")
    assert @window.closed?
  end

  def test_tui_fragmented_utf8_arrow_and_paste
    tui = Zaniah::Platform.open_window(backend: :tui, output: StringIO.new)
    events = []
    tui.on_input { |event| events << event }
    "日".b.bytes.each { |byte| tui.feed_input(byte.chr) }
    tui.feed_input("\e[")
    tui.feed_input("D")
    tui.feed_input("\e[200~a\nb")
    tui.feed_input("\e[201~")
    assert_equal ["日", "left", "a\nb"], events.map { |event| event.respond_to?(:text) ? event.text : event.keystroke }
    tui.close
  end

  def test_cli_help_and_invalid_dimensions_do_not_open_windows
    output, error = StringIO.new, StringIO.new
    assert_equal 0, Canopus::CLI.main(["--help"], output: output, error: error)
    assert_includes output.string, "--headless"
    assert_equal 1, Canopus::CLI.main(["--size", "1x1"], output: output, error: error)
    assert_includes error.string, "dimensions"
  end
end

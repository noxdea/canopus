# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class KeymapTextInputTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-keymap-text-")
    @workspace = Canopus::Workspace.new(root: @root)
    @window = Zaniah::Platform.open_window(backend: :headless, width: 400, height: 300)
    @controller = Canopus::Controller.new(@workspace, @window)
  end

  def teardown
    @workspace.close
    @window.on_close { true }
    @window.close
    FileUtils.remove_entry(@root)
  end

  def bindings(values)
    @workspace.settings.merge!("keymap" => [{"bindings" => values}])
  end

  def key(stroke) = @controller.input(Zaniah::Input::KeyDown.new(stroke, false))
  def text(value) = @controller.input(Zaniah::Input::TextInput.new(value))
  def composition(value) = @controller.input(Zaniah::Input::Composition.new(value, [0, 0]))
  def press(stroke, value)
    key(stroke)
    text(value)
    @controller.input(Zaniah::Input::KeyUp.new(stroke))
  end

  def test_bound_printable_key_consumes_its_native_text_commit_once
    bindings("a" => "pane.split_right")
    key("a")
    composition("") # Cocoa emits this immediately before an ordinary commit.
    text("a")
    assert_equal 2, @workspace.panes.length
    assert_empty @workspace.editor.buffer.text
    text("independent commit")
    assert_equal "independent commit", @workspace.editor.buffer.text
  end

  def test_printable_chord_consumes_prefix_and_completion_but_not_a_mismatch
    bindings("g g" => "pane.split_right")
    press("g", "g")
    assert_equal 1, @workspace.panes.length
    assert_empty @workspace.editor.buffer.text
    press("g", "g")
    assert_equal 2, @workspace.panes.length
    assert_empty @workspace.editor.buffer.text
    press("g", "g")
    press("x", "x")
    assert_equal "x", @workspace.editor.buffer.text
  end

  def test_plain_shift_and_space_typing_are_unchanged
    press("a", "a")
    press("shift-a", "A")
    press("space", " ")
    press("shift-1", "!")
    assert_equal "aA !", @workspace.editor.buffer.text
    bindings("shift-a" => "pane.split_right", "space" => "pane.split_right")
    press("shift-a", "A")
    press("space", " ")
    assert_equal 3, @workspace.panes.length
    assert_equal "aA !", @workspace.editor.buffer.text
  end

  def test_next_keydown_and_keyup_clear_unused_suppression
    bindings("a" => "pane.split_right")
    key("a") # Some native key downs produce no text event.
    press("x", "x")
    key("a")
    @controller.input(Zaniah::Input::KeyUp.new("a"))
    text("commit")
    assert_equal "commitx", @workspace.editor.buffer.text
  end

  def test_nonprintable_and_control_actions_do_not_consume_unrelated_commits
    bindings("f8" => "pane.split_right", "ctrl-a" => "pane.split_right")
    key("f8")
    text("IME")
    key("ctrl-a")
    text("commit")
    assert_equal "commitIME", @workspace.editor.buffer.text
  end

  def test_a_binding_that_opens_a_palette_does_not_type_its_key_into_the_query
    bindings("p" => "command.palette")
    press("p", "p")
    assert_equal :commands, @workspace.palette[:kind]
    assert_empty @workspace.palette[:query]
    press("p", "p") # Palette typing must not dispatch editor bindings.
    press("shift-a", "A")
    assert_equal "pA", @workspace.palette[:query]
  end

  def test_active_ime_composition_keeps_its_key_events_and_commit_out_of_bindings
    bindings("a" => "pane.split_right")
    composition("あ")
    key("a") # Windows can still report key events while IMM is composing.
    composition("")
    text("日本")
    assert_equal 1, @workspace.panes.length
    assert_equal "日本", @workspace.editor.buffer.text
  end

  def test_new_ime_preedit_clears_unused_printable_suppression
    bindings("a" => "pane.split_right")
    key("a")
    composition("に")
    composition("")
    text("日本")
    assert_equal "日本", @workspace.editor.buffer.text
  end

  def test_committed_ime_text_ends_composition_without_an_extra_empty_event
    bindings("a" => "pane.split_right")
    composition("に")
    text("日本")
    press("a", "a")
    assert_equal 2, @workspace.panes.length
    assert_equal "日本", @workspace.editor.buffer.text
  end

  def test_default_vim_text_input_and_contextual_bindings_remain_distinct
    @workspace.settings.merge!("vim_mode" => true,
      "keymap" => [{"context" => "Editor && vim_mode == normal", "bindings" => {"g g" => "pane.split_right"}}])
    press("g", "g")
    press("g", "g")
    assert_equal 2, @workspace.panes.length
    press("i", "i")
    assert_equal :insert, @workspace.vim.mode
    press("g", "g")
    press("shift-a", "A")
    assert_equal "gA", @workspace.editor.buffer.text
    key("esc")
    assert_equal :normal, @workspace.vim.mode
  end
end

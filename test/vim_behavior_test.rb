# frozen_string_literal: true

require_relative "test_helper"

class VimBehaviorTest < Minitest::Test
  def state(text, **options)
    @editor = Canopus::Editor.new(Canopus::Buffer.new(text, **options))
    @vim = Canopus::Vim.new(@editor)
  end

  def feed(*keys) = keys.flatten.each { |key| @vim.feed(key) }

  def teardown
    @vim&.dispose
    @editor&.dispose
  end

  def test_reindent_uses_ruby_block_rules_and_is_one_undo_step
    original = "def hi\nputs :one\nif ok\nputs :two\nelse\nputs :three\nend\nend\n"
    state(original, path: "example.rb")
    feed(%w[= G])
    assert_equal "def hi\n    puts :one\n    if ok\n        puts :two\n    else\n        puts :three\n    end\nend\n", @editor.buffer.text
    assert_equal 0, @vim.cursor_position
    feed("u")
    assert_equal original, @editor.buffer.text
  end

  def test_reindent_json_selected_lines_uses_preceding_context
    state("{\n\"one\": {\n\"two\": 2\n}\n}", path: "example.json")
    feed(%w[j = G])
    assert_equal "{\n    \"one\": {\n        \"two\": 2\n    }\n}", @editor.buffer.text
    assert_equal 6, @vim.cursor_position
  end

  def test_reindent_respects_tabs
    state("int main() {\nif (ready) {\nwork();\n}\n}", path: "example.c")
    @editor.use_tabs = true
    feed(%w[= G])
    assert_equal "int main() {\n\tif (ready) {\n\t\twork();\n\t}\n}", @editor.buffer.text
  end

  def test_python_reindent_preserves_existing_logical_dedents
    state("def one():\n  if ready:\n    work()\n  else:\n    wait()\n\ndef two():\n  done()", path: "example.py")
    feed(%w[= G])
    assert_equal "def one():\n    if ready:\n        work()\n    else:\n        wait()\n\ndef two():\n    done()", @editor.buffer.text
  end

  def test_slow_insert_group_does_not_absorb_preceding_typing
    state("one")
    @editor.insert_text("!")
    time = 100.0
    Process.stub(:clock_gettime, ->(_clock) { time += 2.0 }) { feed(%w[i X Y esc]) }
    assert_equal "!XYone", @editor.buffer.text
    feed("u")
    assert_equal "!one", @editor.buffer.text
    feed("u")
    assert_equal "one", @editor.buffer.text
    feed("ctrl-r", "ctrl-r")
    assert_equal "!XYone", @editor.buffer.text
  end

  def test_block_change_is_one_undo_step_and_restores_all_rows
    state("abcd\n\tEF\nijkl")
    @editor.select(1)
    feed(%w[ctrl-v j j l c X Y esc])
    assert_equal "aXYd\n XY EF\niXYl", @editor.buffer.text
    assert_equal 2, @vim.cursor_position
    feed("u")
    assert_equal "abcd\n\tEF\nijkl", @editor.buffer.text
  end

  def test_macro_recursion_limit_unwinds_every_undo_group
    state("one two")
    @vim.macros["a"] = %w[@ a]
    error = assert_raises(Canopus::Error) { feed("@", "a") }
    assert_match(/recursion limit/, error.message)
    refute @editor.buffer.undo
    feed("x", "u")
    assert_equal "one two", @editor.buffer.text
  end

  def test_read_only_change_does_not_leave_an_open_group
    state("one two", read_only: true)
    assert_raises(Canopus::Error) { feed("c", "w") }
    assert_equal :normal, @vim.mode
    refute @editor.buffer.undo
    assert_equal "one two", @editor.buffer.text
  end

  def test_macro_playback_has_one_shared_nested_key_budget
    state("one two")
    @vim.macros["a"] = ["h"] * 10_001
    error = assert_raises(Canopus::Error) { feed("@", "a") }
    assert_match(/execution limit/, error.message)
    refute @editor.buffer.undo
    feed("x", "u")
    assert_equal "one two", @editor.buffer.text
  end

  def test_deactivate_closes_shared_buffer_history_and_preserves_marks
    state("one")
    feed(%w[m a i X])
    assert_equal :insert, @vim.mode
    assert_same @vim, @vim.deactivate
    assert_equal :normal, @vim.mode
    assert_equal "NORMAL", @vim.status
    assert @vim.marks.key?("a")
    assert @editor.buffer.undo
    assert_equal "one", @editor.buffer.text
    assert_same @vim, @vim.deactivate
  end

  def test_dispose_releases_marks_and_incomplete_insert_transaction
    state("one")
    feed(%w[m a i X])
    anchor = @vim.marks.fetch("a")
    @vim.dispose
    assert_empty @vim.marks
    assert_raises(KeyError) { @editor.buffer.resolve(anchor) }
    assert @editor.buffer.undo
    @vim.dispose
  end

  def test_visual_cursor_tracks_upward_active_edge_not_last_selection
    state("abcd\nefgh\nijkl")
    @editor.select(12)
    feed(%w[ctrl-v k h])
    assert_equal 6, @vim.cursor_position
    assert_equal 2, @editor.selections.length
    assert_operator @editor.primary.head, :>, @vim.cursor_position
    feed("esc")
    assert_equal 6, @vim.cursor_position
  end

  def test_invalid_search_is_reported_and_repeat_is_safe
    state("one")
    feed("/", "[", "enter")
    assert_match(/char-class/, @vim.status)
    feed("n")
    assert_match(/char-class/, @vim.status)
    assert_equal 0, @vim.cursor_position
  end

  def test_ex_callback_and_settings
    state("one")
    commands = []
    @vim.on_command = ->(command) { commands << command }
    feed(":", *"set ts=2 noet rnu".chars, "enter")
    assert_equal 2, @editor.tab_size
    assert @editor.use_tabs
    assert @editor.relative_line_numbers
    feed(":", "q", "enter")
    assert_equal ["q"], commands
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/canopus/vim"

class VimTest < Minitest::Test
  def state(text)
    editor = Canopus::Editor.new(Canopus::Buffer.new(text))
    [editor, Canopus::Vim.new(editor)]
  end
  def keys(vim, sequence) = Array(sequence).each { |key| vim.feed(key) }

  50.times do |n|
    ["x", "dw", "dd", ">>"].each do |command|
      define_method("test_counted_#{command.bytes.join('_')}_#{n + 1}") do
        count = n + 1
        text = case command
        when "x" then "a" * 60
        when "dw" then "word " * 60
        else "line\n" * 60
        end
        editor, vim = state(text)
        keys(vim, count.to_s.chars + command.chars)
        expected = case command
        when "x" then "a" * (60 - count)
        when "dw" then "word " * (60 - count)
        when "dd" then "line\n" * (60 - count)
        when ">>" then "    line\n" * count + "line\n" * (60 - count)
        end
        assert_equal expected, editor.buffer.text
        vim.feed("u")
        assert_equal text, editor.buffer.text
      end
    end
  end

  def test_change_word_dot_registers_and_paste
    editor, vim = state("one two three")
    keys(vim, %w[c w X esc])
    assert_equal "X two three", editor.buffer.text
    keys(vim, %w[w .])
    assert_equal "X X three", editor.buffer.text
    keys(vim, ['"', "a", "y", "w", "p"])
    assert vim.registers.key?("a")
    assert_includes editor.buffer.text, "X"
  end

  def test_text_objects_visual_lines_and_find
    editor, vim = state('before (inside) after')
    editor.select(10)
    keys(vim, %w[d i )])
    assert_equal 'before () after', editor.buffer.text
    editor, vim = state("abcd\nefgh\nijkl\n")
    keys(vim, %w[V j d])
    assert_equal "ijkl\n", editor.buffer.text
    editor, vim = state("abcd")
    keys(vim, %w[d f c])
    assert_equal "d", editor.buffer.text
    editor, vim = state("abc\ndef")
    keys(vim, %w[l d $])
    assert_equal "a\ndef", editor.buffer.text
  end

  def test_macros_marks_search_replace_and_modes
    editor, vim = state("aaa bbb aaa")
    keys(vim, %w[q a x q @ a])
    assert_equal "a bbb aaa", editor.buffer.text
    keys(vim, %w[m a w ' a])
    assert_equal 0, editor.primary.head
    keys(vim, ["/", "b", "b", "b", "enter"])
    assert_equal 2, editor.primary.head
    keys(vim, [":", *"%s/a/z/g".chars, "enter"])
    assert_equal "z bbb zzz", editor.buffer.text
    keys(vim, %w[0 R X Y esc])
    assert_equal :normal, vim.mode
    assert editor.buffer.text.start_with?("XY")
  end
end

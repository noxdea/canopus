# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
gem "minitest", "~> 5.0"
require "minitest/autorun"
require "rbconfig"
require_relative "../lib/canopus/terminal"

class TerminalTest < Minitest::Test
  def setup
    @grid = Canopus::Terminal::Grid.new(columns: 12, rows: 4, scrollback: 3)
    @vt = Canopus::Terminal::VT.new(@grid)
  end

  def test_streaming_utf8_wide_combining_wrap_and_scrollback
    "日本e\u0301\r\nline2\r\nline3\r\nline4\r\nline5".bytes.each { |byte| @vt.feed(byte.chr) }
    assert_equal ["line2", "line3", "line4", "line5"], @grid.lines
    assert_equal "日本é", @grid.scrollback[0].map(&:text).join.rstrip
    assert_equal [2, 0, 2, 0, 1], @grid.scrollback[0].first(5).map(&:width)
    assert @grid.scrollback.tree.check_invariants!
    @vt.feed("\e[2J\e[H123456789012X")
    assert_equal "123456789012", @grid.lines[0]
    assert_equal "X", @grid.lines[1]
    assert_equal [1, 1], [@grid.cursor_x, @grid.cursor_y]
  end

  def test_alternate_screen_attributes_osc_and_replies
    @vt.feed("main\e[?1049h\e[1;3;4;91;48;5;123mA\e[38:2::12:34:56mB")
    assert @grid.alternate?
    assert_equal 9, @grid[0, 0].foreground
    assert_equal 123, @grid[0, 0].background
    assert_equal({bold: true, italic: true, underline: 1}, @grid[0, 0].attributes)
    assert_equal [12, 34, 56], @grid[0, 1].foreground
    @vt.feed("\e]8;;https://example.invalid\e\\link\e]8;;\a\e]7;file:///tmp/a%20b\a\e]2;日本語\a\e[6n")
    assert_equal "/tmp/a b", @vt.cwd
    assert_equal "日本語", @vt.title
    assert_equal "https://example.invalid", @grid[0, 2].hyperlink
    assert_equal ["\e[1;7R"], @vt.replies
    @vt.feed("\e[?1049l")
    assert_equal "main", @grid.lines.first
    assert_equal [4, 0], [@grid.cursor_x, @grid.cursor_y]
    assert_nil @grid.foreground
  end

  def test_margins_editing_tabs_graphics_and_dcs
    @vt.feed("one\r\ntwo\r\nthree\r\nfour\e[2;3r\e[3;1H\n")
    assert_equal ["one", "three", "", "four"], @grid.lines
    assert_equal 0, @grid.scrollback.length
    @vt.feed("\e[r\e[H\e[2Kabcdef\e[1;3H\e[2P\e[2@XY")
    assert_equal "abXYef", @grid.lines[0]
    @vt.feed("\e[2;1H\e[2K\e(0lqk\e(B\t!")
    assert_equal "┌─┐     !", @grid.lines[1]
    @vt.feed("\eP$qm\e\\")
    assert_equal "\eP1$r0m\e\\", @vt.replies.last
    @vt.feed("\ePignored payload\e\\ok")
    assert_includes @grid.text, "ok"
  end

  def test_input_mouse_bracketed_paste_and_selection
    assert_equal "\e[A", @vt.key(:up)
    @vt.feed("\e[?1h\e[?2004h\e[?1002h\e[?1006h")
    assert_equal "\eOA", @vt.key(:up)
    assert_equal "\e[1;5D", @vt.key(:left, control: true)
    assert_equal "\x03", @vt.key("c", control: true)
    assert_equal "\e[200~hello\n\e[201~", @vt.paste("hello\n")
    assert_equal "\e[<0;3;4M", @vt.mouse(button: :left, column: 2, row: 3)
    assert_equal "\e[<0;3;4m", @vt.mouse(button: :left, column: 2, row: 3, action: :release)
    assert_equal "", @vt.mouse(button: nil, column: 2, row: 3, action: :move)
    @vt.feed("hello\r\nworld")
    assert_equal "ello\nwor", @grid.selection([1, 0], [3, 1])
    assert_equal "ello\nwor", @grid.selection([3, 1], [1, 0])
  end

  def test_resize_normalizes_wide_cells_and_limits_history
    @vt.feed("1234567890日")
    @grid.resize(columns: 11, rows: 4)
    assert_equal 1, @grid[0, 10].width
    10.times { @vt.feed("\r\nline") }
    assert_equal 3, @grid.scrollback.length
    @grid.resize(columns: 20, rows: 2)
    assert_equal 2, @grid.cells.length
    assert @grid.cells.all? { |row| row.length == 20 }
    assert @grid.cursor_y.between?(0, 1)
    assert @grid.scrollback.tree.check_invariants!
  end

  def test_pty_real_process_input_resize_and_cleanup
    child = <<~'RUBY'
      require "io/console"
      STDIN.binmode
      STDOUT.binmode
      STDOUT.sync = true
      STDOUT.write("\e[32mready\e[0m\r\n")
      answer = STDIN.gets.chomp
      STDOUT.write("reply:#{answer}\r\n#{STDOUT.winsize.join(' ')}\r\n")
    RUBY
    terminal = Canopus::Terminal::PTY.new(command: [RbConfig.ruby, "-e", child], columns: 40, rows: 8)
    output = +""
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until output.include?("ready")
      raise "PTY did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      output << terminal.read(timeout: 0.1).to_s
    end
    terminal.resize(columns: 50, rows: 10)
    terminal.write("hello\r")
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      chunk = terminal.read(timeout: 0.1)
      break unless chunk
      output << chunk
    end
    assert_includes output, "reply:hello"
    assert_includes output, "10 50"
    assert_includes terminal.grid.text, "ready"
    ready_row = terminal.grid.lines.index("ready")
    assert_equal 2, terminal.grid[ready_row, 0].foreground
    terminal.close
    refute terminal.alive?
  ensure
    terminal&.close
  end
end

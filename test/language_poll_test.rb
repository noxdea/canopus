# frozen_string_literal: true
require_relative "test_helper"

class LanguagePollTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-language-poll-")
    File.write(File.join(@root, "test.rb"), "class Example\n  def run\n  end\nend\n")
    @workspace = Canopus::Workspace.new(root: @root)
    @editor = @workspace.open("test.rb")
    @document = @editor.language_document
    @window = Zaniah::Platform.open_window(width: 640, height: 260)
    @controller = Canopus::Controller.new(@workspace, @window)
    @symbol = Canopus::Language::Symbol.new("Example", :class, 0...32, 6...13, 0)
  end

  def teardown
    @workspace.close
    @window.on_close { true }
    @window.close
    FileUtils.remove_entry(@root)
  end

  def test_idle_polls_reuse_viewport_rows_but_layout_and_scroll_changes_refresh_them
    @editor.edit([[0...@editor.buffer.rope.bytesize, ("line\n" * 100)]])
    @editor.viewport_rows = 2
    requests = []
    @document.stub(:request, ->(**options) { requests << options.fetch(:rows) }) do
      @document.stub(:poll, false) do
        5.times { @controller.poll_language_documents }
        assert_equal [[0, 1, 2]], requests
        @editor.scroll(dy: 1)
        @controller.poll_language_documents
        assert_equal [1, 2, 3], requests.last
        @editor.viewport_rows = 4
        @controller.poll_language_documents
        assert_equal [1, 2, 3, 4, 5], requests.last
        rope = @editor.buffer.rope
        @editor.display_map.fold(rope.line_start(2)...rope.line_start(6))
        @controller.poll_language_documents
        assert_equal [1, 2, 7, 8, 9], requests.last
        @editor.edit([[0...0, "new\n"]])
        @controller.poll_language_documents
        assert_equal 5, requests.length
        @editor.display_map.wrap_width = 2
        @controller.poll_language_documents
        assert_equal 6, requests.length
        @controller.poll_language_documents
        assert_equal 6, requests.length
      end
    end
  end

  def test_outline_refreshes_after_matching_analysis_without_losing_query
    ready = false
    @document.stub(:syntax_ready?, -> { ready }) do
      @document.stub(:outline, -> { ready ? [@symbol] : [] }) do
        @document.stub(:poll, -> { ready = true; true }) do
          @workspace.show_outline
          assert @workspace.palette[:loading]
          @workspace.palette[:query] = "Ex"
          @controller.poll_language_documents
          refute @workspace.palette[:loading]
          assert_equal "Ex", @workspace.palette[:query]
          assert_equal ["Example"], @workspace.palette[:matches]
          @workspace.palette_accept
          assert_equal 6, @editor.primary.head
        end
      end
    end
  end

  def test_stale_outline_cannot_jump_after_edit
    @document.stub(:syntax_ready?, true) do
      @document.stub(:outline, [@symbol]) { @workspace.show_outline }
    end
    @editor.edit([[0...@editor.buffer.rope.bytesize, "x"]])
    cursor = @editor.primary.head
    @workspace.palette_accept
    assert_equal cursor, @editor.primary.head
    assert_nil @workspace.palette
  end

  def test_partial_outline_refreshes_when_analysis_window_changes_without_edit
    symbols = [@symbol]
    @document.stub(:syntax_ready?, true) do
      @document.stub(:outline, -> { symbols }) do
        @workspace.show_outline
        symbols = [Canopus::Language::Symbol.new("run", :method, 16...28, 20...23, 1)]
        @workspace.language_ready(@editor, @document)
        assert_equal ["  run"], @workspace.palette[:matches]
        assert_same symbols, @workspace.palette[:items]
      end
    end
    @document.stub(:syntax_ready?, false) do
      @workspace.language_ready(@editor, @document)
      assert @workspace.palette[:loading]
      assert_empty @workspace.palette[:items]
    end
  end

  def test_pending_fold_is_applied_once_and_cancelled_if_cursor_moves
    ready = false
    @document.stub(:syntax_ready?, -> { ready }) do
      @document.stub(:pending?, -> { !ready }) do
        @document.stub(:fold_ranges, -> { ready ? [@symbol.range] : [] }) do
          @workspace.fold_current
          assert_empty @editor.display_map.fold_map.ranges
          ready = true
          @workspace.language_ready(@editor, @document)
          assert_equal [@symbol.range], @editor.display_map.fold_map.ranges
          @editor.display_map.unfold(0)
          ready = false
          @workspace.fold_current
          @editor.select(1)
          ready = true
          @workspace.language_ready(@editor, @document)
          assert_empty @editor.display_map.fold_map.ranges
        end
      end
    end
  end
end

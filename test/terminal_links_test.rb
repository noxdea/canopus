# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "canopus/workspace/view/terminal_presentable"

class TerminalLinksTest < Minitest::Test
  def with_view(text)
    Dir.mktmpdir("terminal-links-") do |directory|
      workspace = Canopus::Workspace.new(root: directory)
      grid = Canopus::Terminal::Grid.new(columns: 160, rows: 3)
      vt = Canopus::Terminal::VT.new(grid)
      vt.feed(text)
      workspace.terminal = Struct.new(:grid, :vt).new(grid, vt)
      urls = []
      window = Zaniah::Platform::Headless::Window.new
      window.define_singleton_method(:open_url) { |url| urls << url; true }
      workspace.window = window
      view = Object.new.extend(Canopus::Workspace::View::TerminalPresentable)
      {workspace: workspace, terminal_bounds: Zaniah::Bounds.new(0, 0, 1600, 60), terminal_cell_width: 10,
       line_height: 20, terminal_first: 0}.each { |key, value| view.instance_variable_set("@#{key}", value) }
      yield view, workspace, urls, directory
    ensure
      workspace.terminal = nil
      workspace.close
      window.close
    end
  end

  def test_osc8_and_detected_urls_require_modified_click
    with_view("\e]8;;https://example.com/a?q=1\e\\日本語\e]8;;\e\\ https://ruby-lang.org/.") do |view, _workspace, urls, _directory|
      point = Zaniah::Point.new(15, 5) # second half of a wide Japanese cell
      refute view.terminal_open_link(point, modifiers: [])
      assert_empty urls
      assert view.terminal_open_link(point, modifiers: ["cmd"])
      assert_equal ["https://example.com/a?q=1"], urls
      assert_equal "https://ruby-lang.org/", view.terminal_link_at(Zaniah::Point.new(100, 5)).target
    end
  end

  def test_existing_relative_path_opens_at_unicode_character_column
    with_view("source.rb:2:2") do |view, workspace, urls, directory|
      File.binwrite(File.join(directory, "source.rb"), "zero\n日本語\n")
      assert view.terminal_open_link(Zaniah::Point.new(15, 5), modifiers: ["ctrl"])
      assert_equal File.realpath(File.join(directory, "source.rb")), workspace.editor.buffer.path
      assert_equal "zero\n日".bytesize, workspace.editor.primary.head
      assert_empty urls
    end
  end

  def test_local_file_uri_supports_spaces_and_rejects_unsafe_schemes
    with_view("") do |view, workspace, _urls, directory|
      path = File.join(directory, "a b.rb")
      File.write(path, "file")
      File.write(File.join(directory, "javascript"), "must not be treated as a path")
      vt = workspace.terminal.vt
      uri = Canopus::LSP::Protocol.uri(path) + "#L1"
      vt.feed("\e]8;;#{uri}\e\\open\e]8;;\e\\")
      assert_equal path, view.terminal_link_at(Zaniah::Point.new(5, 5)).target
      %w[javascript:alert(1) javascript:123 file://remote/private ftp://example.com/file].each do |unsafe|
        vt.feed("\e[H\e]8;;#{unsafe}\e\\bad\e]8;;\e\\")
        refute view.terminal_open_link(Zaniah::Point.new(5, 5), modifiers: ["ctrl"])
      end
      assert_nil view.terminal_link_at(Zaniah::Point.new(-1, 0))
    end
  end

  def test_italic_cells_request_matching_real_font
    with_view("\e[1;3mA") do |view, workspace, _urls, _directory|
      queries, font = [], Object.new
      db = Object.new
      db.define_singleton_method(:find) { |**options| queries << options; font }
      system = Struct.new(:font_db, :font).new(db, Struct.new(:family).new("Example Mono"))
      view.instance_variable_set(:@cx, Struct.new(:text_system).new(system))
      2.times { assert_same font, view.send(:terminal_font, workspace.terminal.grid[0, 0]) }
      assert_equal [{family: "Example Mono", weight: 700, style: :italic}], queries
      view.instance_variable_set(:@cx, Struct.new(:text_system).new(Object.new))
      assert_nil view.send(:terminal_font, workspace.terminal.grid[0, 0])
    end
  end
end

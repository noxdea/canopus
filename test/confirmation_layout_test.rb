# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class ConfirmationLayoutTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-confirmation-")
    @workspace = Canopus::Workspace.new(root: @root, settings: Canopus::Settings.new)
    @window = Zaniah::Platform.open_window(width: 300, height: 300)
    @controller = Canopus::Controller.new(@workspace, @window)
    @workspace.configure_text_system
  end

  def teardown
    @workspace.close
    @window.on_close { true }
    @window.close
    FileUtils.remove_entry(@root)
  end

  def key(stroke) = @controller.input(Zaniah::Input::KeyDown.new(stroke, false))

  def test_every_cjk_target_character_can_be_read_by_paging_at_minimum_size
    @window.resize(100, 100)
    path = File.join(@root, "日本" * 40 + ".txt")
    @workspace.confirm_workspace_edit({"documentChanges" => [{"kind" => "delete", "uri" => Canopus::LSP::Protocol.uri(path)}]})
    @controller.tick
    palette = @workspace.palette
    lines = palette[:detail_lines]
    expected = [palette[:query], *palette[:details]].join
    assert_equal expected, lines.join
    assert lines.all? { |line| @window.text_system.layout_line(line, size: 11).width <= 84 }, "every line fits the measured 84px content width"
    visited = []
    loop do
      first, rows = palette.values_at(:details_scroll, :detail_rows)
      visited.concat((first...(first + rows)).to_a)
      visible = @controller.view.accessibility.reverse.find { |entry| entry[:role] == :text }
      assert_equal lines.slice(first, rows).join("\n"), visible[:label]
      buttons = @controller.view.regions.select { |_, action| action.first == :palette }
      assert_equal [[:palette, 0], [:palette, 1]], buttons.map(&:last)
      assert buttons.all? { |bounds, _| bounds.y >= 0 && bounds.bottom <= 100 && bounds.x >= 0 && bounds.right <= 100 && bounds.height == 22 }
      break if first + rows >= lines.length
      key("pagedown")
      @controller.tick
    end
    assert_equal (0...lines.length).to_a, visited.uniq
    key("pageup")
    @controller.tick
    assert_operator palette[:details_scroll], :<, lines.length - 1
    old_key = palette[:detail_wrap_key]
    @window.resize(640, 300)
    @controller.tick
    refute_equal old_key, palette[:detail_wrap_key]
    assert_equal expected, palette[:detail_lines].join
    assert_operator palette[:detail_lines].length, :<, lines.length
    assert palette[:detail_lines].all? { |line| @window.text_system.layout_line(line, size: 11).width <= 576 }
  end

  def test_hover_links_only_respond_inside_the_visible_hover_and_viewport
    @window.resize(200, 220)
    @workspace.send(:display_language_result, :hover,
      {"contents" => {"kind" => "markdown", "value" => "[#{'x' * 70}](https://example.invalid)"}}, nil, @workspace.editor)
    @controller.tick
    links = @controller.view.regions.select { |_, action| action.first == :hover_link }
    assert links.any?
    assert links.all? { |bounds, _| bounds.right <= 176 && bounds.bottom <= 220 }
    opened = []
    @window.define_singleton_method(:open_url) { |url| opened << url }
    click = ->(x, y) { @controller.input(Zaniah::Input::MouseDown.new(position: Zaniah::Point.new(x, y), button: :left, modifiers: [], click_count: 1)) }
    click.call(190, 75)
    assert_empty opened
    bounds = links.first.first
    click.call(bounds.x + 1, bounds.y + 1)
    assert_equal ["https://example.invalid"], opened
    clickable = @controller.view.accessibility.select { |entry| entry[:role] == :link }
    assert clickable.all? { |entry| entry[:bounds].right <= 176 }
  end
end

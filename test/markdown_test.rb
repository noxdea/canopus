# frozen_string_literal: true
require_relative "test_helper"
require "canopus/markdown"

class MarkdownTest < Minitest::Test
  def test_hover_markup_reuses_rouge_and_never_fetches_resources
    doc = Canopus::Markdown.new("# Title\n**bold** *italic* `code` [link](https://example.test)\n```ruby\nx = 1\n```\n![image](file:///etc/hosts)")
    runs = doc.rows.flatten
    assert_equal "Title", runs.find { |run| run.style == :heading }.text
    assert_equal "bold", runs.find { |run| run.style == :strong }.text
    assert_equal "italic", runs.find { |run| run.style == :emphasis }.text
    assert_equal "code", runs.find { |run| run.style == :code }.text
    assert_equal "https://example.test", runs.find { |run| run.text == "link" }.url
    assert runs.any? { |run| run.style == "Literal.Number.Integer" }
    assert doc.rows.frozen?
    assert runs.all? { |run| run.text.frozen? }
  end
  def test_unicode_wrapping_is_bounded_and_plain_text_keeps_markup
    doc = Canopus::Markdown.new("日本👨‍👩‍👧‍👦" * 100_000, width: 4, max_rows: 3)
    assert_equal 3, doc.rows.length
    assert doc.rows.flatten.all? { |run| run.text.valid_encoding? }
    assert_equal "**plain**", Canopus::Markdown.new("**plain**", markup: false).rows.flatten.map(&:text).join
  end
  def test_lsp_markup_kinds_and_safe_links_reach_the_view
    Dir.mktmpdir("canopus-hover-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      window = Zaniah::Platform.open_window(width: 640, height: 300)
      controller = Canopus::Controller.new(workspace, window)
      workspace.send(:display_language_result, :hover, {"contents" => {"kind" => "plaintext", "value" => "**plain**"}}, nil, workspace.editor)
      refute workspace.hover_markup
      assert_equal "**plain**", workspace.hover_card
      controller.tick
      assert window.text_runs.any? { |run| run[2] == "**plain**" }
      workspace.send(:display_language_result, :hover, {"contents" => {"kind" => "markdown", "value" => "[web](https://example.test) [unsafe](file:///etc/hosts)"}}, nil, workspace.editor)
      controller.tick
      links = controller.view.regions.select { |_, action| action.first == :hover_link }
      assert_equal 1, links.length
      opened = []
      window.define_singleton_method(:open_url) { |url| opened << url }
      bounds = links.first.first
      controller.input(Zaniah::Input::MouseDown.new(position: Zaniah::Point.new(bounds.x + 1, bounds.y + 1), button: :left, modifiers: [], click_count: 1))
      assert_equal ["https://example.test"], opened
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end
end

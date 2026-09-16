# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class DiagnosticDecorationTest < Minitest::Test
  class Client
    attr_reader :diagnostics
    def initialize = @diagnostics = {}
    def state = :running
    def stop = nil
  end

  def setup
    @root = Dir.mktmpdir("canopus-diagnostics-")
    @workspace = Canopus::Workspace.new(root: @root)
    @editor = @workspace.open("sample.rb")
    @editor.insert_text("a😀bc\nsecond\n", auto_indent: false)
    @buffer = @editor.buffer
    @client = Client.new
    @uri = Sadr::Protocol.uri(@buffer.path)
    @workspace.clients["ruby"] = @client
    @workspace.instance_variable_set(:@opened_lsp_documents, {[@client, @buffer] => true})
  end

  def teardown
    @workspace.close
    FileUtils.remove_entry(@root)
  end

  def diagnostic(message, severity:, row: 0, first: 0, last: 1)
    {"message" => message, "severity" => severity, "range" => {
      "start" => {"line" => row, "character" => first},
      "end" => {"line" => row, "character" => last}
    }}
  end

  def publish(values, version: @buffer.version)
    @client.diagnostics[@uri] = values
    @workspace.send(:accept_diagnostic_notification, @client,
      {"uri" => @uri, "version" => version, "diagnostics" => values})
  end

  def items(rows = 0...@buffer.line_count)
    @workspace.decorations.items_for(@buffer, rows, context: @editor)
      .select { |item| item.source == :diagnostics }
  end

  def test_severity_wave_inline_grouping_unicode_offsets_and_visible_rows
    publish([
      diagnostic("bad 😀", severity: 1, first: 1, last: 3),
      diagnostic("warning", severity: 2, first: 3, last: 4),
      diagnostic("information", severity: 3, row: 1)
    ])

    visible = items(0...1)
    highlights = visible.select { |item| item.kind == :highlight }
    inline = visible.select { |item| item.kind == :inline }
    assert_equal [5...6, 1...5], highlights.map(&:range)
    assert_equal [:"diagnostic.warning", :"diagnostic.error"], highlights.map { |item| item.style[:color] }
    assert_equal [3, 4], highlights.map(&:priority)
    assert highlights.all? { |item| item.style[:underline] == :wave }
    assert_equal 1, inline.length
    assert_equal "bad 😀 (+1)", inline.first.content
    assert_equal 7...7, inline.first.range
    assert_empty items(1...2)
  end

  def test_inline_can_be_disabled_and_severity_threshold_can_be_changed
    publish([diagnostic("error", severity: 1), diagnostic("warning", severity: 2, row: 1)])
    @workspace.settings.merge!("diagnostics" => {"inline" => false, "severity" => "error"})
    @workspace.apply_settings

    assert_equal [:highlight], items.map(&:kind)
    assert_equal :"diagnostic.error", items.first.style[:color]
  end

  def test_inline_truncation_keeps_grapheme_clusters_intact
    @workspace.settings.merge!("diagnostics" => {"inline_max_length" => 4})
    @workspace.apply_settings
    publish([diagnostic("A👩‍👩‍👧‍👦BCDE", severity: 1)])

    message = items.find { |item| item.kind == :inline }.content
    assert_equal "A👩‍👩‍👧‍👦B…", message
    assert message.valid_encoding?
    assert_equal 4, message.scan(/\X/).length
  end

  def test_edits_hide_stale_results_and_stale_notifications_cannot_restore_them
    current = @buffer.version
    publish([diagnostic("old", severity: 1)], version: current)
    refute_empty items

    @editor.insert_text("x", auto_indent: false)
    assert_empty items
    publish([diagnostic("stale", severity: 1)], version: current)
    assert_empty items
    publish([diagnostic("fresh", severity: 1, first: 1, last: 3)])
    assert_equal 1...5, items.find { |item| item.kind == :highlight }.range

    @workspace.send(:forget_language_document, @client, @buffer)
    assert_empty items
  end

  def test_invalid_server_positions_are_ignored
    publish([diagnostic("outside", severity: 1, row: 99), diagnostic("valid", severity: 1)])
    assert_equal 1, items.count { |item| item.kind == :highlight }
  end

  def test_view_uses_one_decoration_wave_and_inline_overlay
    publish([diagnostic("syntax error", severity: 1, first: 1, last: 3)])
    window = Zaniah::Platform.open_window(backend: :headless, width: 640, height: 220)
    window.text_system = Zaniah::TextSystem::Renderer.new
    controller = Canopus::Controller.new(@workspace, window)
    calls = []
    underline = window.scene.method(:underline)
    window.scene.define_singleton_method(:underline) do |*arguments, **options|
      calls << [arguments, options]
      underline.call(*arguments, **options)
    end

    window.render(controller.view)

    assert_equal 1, calls.length
    assert calls.first.last[:wave]
    assert_equal @workspace.theme[:"diagnostic.error"], calls.first.last[:color]
    assert_includes window.text_runs.map { |run| run[2] }, "syntax error"
  ensure
    window&.on_close { true }
    window&.close
  end

  def test_theme_exposes_and_imports_diagnostic_colors
    assert_match(/\A#[0-9a-f]+\z/i, @workspace.theme[:"diagnostic.warning"])
    path = File.join(@root, "theme.json")
    File.write(path, JSON.generate("name" => "Custom", "style" => {"diagnostic.hint" => "#123456"}))
    assert_equal "#123456", Canopus::Theme.load(path)[:"diagnostic.hint"]
  end
end

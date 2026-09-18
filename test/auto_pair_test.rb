# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "tmpdir"

class AutoPairTest < Minitest::Test
  def test_default_custom_disabled_and_literal_insertions
    editor = Canopus::Editor.new(Canopus::Buffer.new("日🙂 two"))
    editor.select(0, 7)
    editor.insert_text("(")
    assert_equal "(日🙂) two", editor.buffer.text

    editor.closing_pairs = {"「" => "」"}.freeze
    editor.select(0, 9)
    editor.select(13, 10, add: true)
    editor.insert_text("「")
    assert_equal "「(日🙂)」 「two」", editor.buffer.text
    assert_equal [12, 22], editor.selections.map(&:head)

    editor.closing_pairs = {}
    editor.select(0, editor.buffer.rope.bytesize)
    editor.insert_text("[")
    assert_equal "[", editor.buffer.text
    editor.select(0, 1)
    editor.closing_pairs = {"[" => "]"}
    editor.insert_text("[", pair: false)
    assert_equal "[", editor.buffer.text
    editor.select(1)
    editor.auto_pairs = false
    editor.insert_text("(")
    assert_equal "[(", editor.buffer.text
  ensure
    editor&.dispose
  end

  def test_settings_validate_snapshot_and_replace_pairs_per_language
    opener = +"「"
    pairs = [[opener, "」"], ["👨‍👩‍👧‍👦", "🌟"]]
    settings = Canopus::Settings.new("auto_pairs" => pairs,
      "languages" => {"ruby" => {"auto_pairs" => []}, "text" => {"auto_pairs" => [["<", ">"]]}})
    opener.replace("x")
    pairs << ["(", ")"]
    assert_equal [["「", "」"], ["👨‍👩‍👧‍👦", "🌟"]], settings["auto_pairs"]
    assert settings["auto_pairs"].frozen?
    assert settings["auto_pairs"].all? { |pair| pair.frozen? && pair.all?(&:frozen?) }
    assert_equal [], settings.for_language("ruby")["auto_pairs"]
    assert_equal [["<", ">"]], settings.for_language("text")["auto_pairs"]
    assert settings.for_language("text")["auto_pairs"].all? { |pair| pair.frozen? && pair.all?(&:frozen?) }

    invalid = [nil, Array.new(65) { ["(", ")"] }, [["("]], [["", ")"]], [["ab", ")"]], [["\n", ")"]],
      [["(".encode(Encoding::US_ASCII), ")"]],
      [["(", ")"], ["(", "]"]], [["\xFF".dup.force_encoding(Encoding::UTF_8), ")"]]]
    invalid.each { |value| assert_raises(Canopus::Error) { Canopus::Settings.new("auto_pairs" => value) } }
    assert_equal 64, Canopus::Settings.schema.dig("properties", "auto_pairs", "maxItems")
  end

  def test_workspace_applies_language_overrides_and_reloads_existing_editors
    Dir.mktmpdir("canopus-auto-pairs-") do |root|
      path = File.join(root, "settings.jsonc")
      File.write(path, JSON.generate("auto_pairs" => [["<", ">"]], "languages" => {"ruby" => {"auto_pairs" => []}}))
      workspace = Canopus::Workspace.new(root: root, settings: Canopus::Settings.new(path))
      text = workspace.new_buffer
      ruby = workspace.open("example.rb")
      assert_equal({"<" => ">"}, text.closing_pairs)
      assert_empty ruby.closing_pairs

      File.write(path, JSON.generate("auto_pairs" => [["«", "»"]],
        "languages" => {"ruby" => {"auto_pairs" => [["「", "」"]]}}))
      workspace.poll_settings(force: true)
      assert_equal({"«" => "»"}, text.closing_pairs)
      assert_equal({"「" => "」"}, ruby.closing_pairs)
      assert text.closing_pairs.frozen?
      assert ruby.closing_pairs.frozen?
    ensure
      workspace&.close
    end
  end

  def test_paste_and_completion_insert_openers_literally
    Dir.mktmpdir("canopus-auto-pairs-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      window = Zaniah::Platform.open_window(width: 640, height: 260)
      controller = Canopus::Controller.new(workspace, window)
      editor = workspace.editor
      controller.instance_variable_set(:@clipboard, "(")
      controller.key("cmd-v")
      assert_equal "(", editor.buffer.text

      item = {"label" => "(", "insertText" => "("}
      workspace.accept_language_result({kind: :completion, editor: editor, items: [item]}, 0)
      assert_equal "((", editor.buffer.text

      completion = Canopus::Provider::Completion.new("[", "[", nil, nil, nil, nil, nil, [], :test)
      workspace.accept_language_result({kind: :completion, editor: editor, items: [completion]}, 0)
      assert_equal "(([", editor.buffer.text

      insertion = "#{JSON.generate("auto_pairs")}: #{JSON.generate(Canopus::Settings::DEFAULTS.fetch("auto_pairs"))}"
      editor.closing_pairs = {insertion => "]"}
      workspace.palette = {kind: :settings_keys, query: +"", index: 0, matches: ["auto_pairs"]}
      workspace.palette_accept
      assert_equal "(([#{insertion}", editor.buffer.text
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end

  def test_vim_insert_and_replace_are_literal_without_mutating_pairs
    editor = Canopus::Editor.new(Canopus::Buffer.new("xy"))
    pairs = {"(" => ")", "\n" => "x", " " * editor.tab_size => "y"}.freeze
    editor.closing_pairs = pairs
    vim = Canopus::Vim.new(editor)
    %w[i ( enter tab esc l R ( esc].each { |key| vim.feed(key) }
    assert_equal "(\n        (y", editor.buffer.text
    %w[o esc].each { |key| vim.feed(key) }
    assert_equal "(\n        (y\n        ", editor.buffer.text
    assert_same pairs, editor.closing_pairs
  ensure
    vim&.dispose
    editor&.dispose
  end
end

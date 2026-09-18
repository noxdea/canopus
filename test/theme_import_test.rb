# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "tmpdir"

class ThemeImportTest < Minitest::Test
  def with_file(name, content)
    Dir.mktmpdir("canopus-theme-") do |directory|
      path = File.join(directory, name)
      File.write(path, content)
      yield path
    end
  end

  def test_imports_vscode_colors_and_token_scopes
    source = JSON.generate(
      "name" => "Imported",
      "colors" => {"editor.background" => "#101010", "editor.foreground" => "#f0f0f0", "unknown" => "#000000"},
      "tokenColors" => [{"scope" => "comment", "settings" => {"foreground" => "#888888"}}]
    )
    with_file("theme.json", source) do |path|
      warnings = []
      theme = Canopus::Theme.load(path, warnings: warnings)
      assert_equal "#101010", theme[:background]
      assert_equal "#888888", theme.token_color("Comment")
      assert_includes warnings, "unsupported theme color: unknown"
    end
  end

  def test_imports_tm_theme_plist
    source = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>name</key><string>Plist Theme</string>
        <key>settings</key><array><dict>
          <key>scope</key><string>keyword</string>
          <key>settings</key><dict><key>foreground</key><string>#ff00ff</string></dict>
        </dict></array>
      </dict></plist>
    XML
    with_file("theme.tmTheme", source) do |path|
      theme = Canopus::Theme.load(path)
      assert_equal "Plist Theme", theme.name
      assert_equal "#ff00ff", theme.token_color("Keyword")
    end
  end
end

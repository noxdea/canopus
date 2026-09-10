# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"
require "canopus/icon_theme"

class FinderIconsTest < Minitest::Test
  def test_mru_preview_does_not_open_or_overwrite_unsaved_buffers
    Dir.mktmpdir("canopus-finder-") do |root|
      %w[a.rb b.rb].each { |path| File.write(File.join(root, path), "puts :disk\n") }
      workspace = Canopus::Workspace.new(root: root)
      workspace.open("b.rb")
      editor = workspace.open("a.rb")
      editor.insert_text("# draft\n")
      workspace.palette_open(:files)
      assert_equal %w[a.rb b.rb], workspace.palette[:matches]
      search = workspace.palette[:search]
      workspace.palette[:query] = "b.r"
      workspace.update_palette
      assert_same search, workspace.palette[:search]
      assert_equal ["b.rb"], workspace.palette[:matches]
      workspace.palette[:query] = ""
      workspace.update_palette
      assert_equal %w[a.rb b.rb], workspace.palette[:matches]
      assert_equal ["# draft", "puts :disk"], workspace.file_preview("a.rb")
      assert_same editor, workspace.editor
      assert_equal ["puts :disk"], workspace.file_preview("b.rb")
      assert_equal "puts :disk\n", File.read(File.join(root, "a.rb"))
      workspace.close
    end
  end
  def test_svg_theme_and_safe_local_resource_boundary
    Dir.mktmpdir("canopus-icons-") do |root|
      File.write(File.join(root, "ruby.svg"), '<svg viewBox="0 0 16 16"><rect width="16" height="16" fill="currentColor"/></svg>')
      path = File.join(root, "theme.jsonc")
      File.write(path, JSON.generate("extensions" => {".rb" => "ruby.svg"}))
      theme = Canopus::IconTheme.new(path)
      texture = theme.texture("code.rb", color: "#ff0000")
      assert_equal [16, 16], [texture.width, texture.height]
      assert_equal [255, 0, 0, 255], texture.data.byteslice(0, 4).bytes
      assert_same texture, theme.texture("code.rb", color: "#ff0000")
      File.write(path, JSON.generate("file" => "../outside.svg"))
      assert_raises(SystemCallError, Canopus::Error) { Canopus::IconTheme.new(path) }
      assert_raises(Canopus::Error) { Canopus::Settings.new("icon_theme" => 1) }
    end
  end
end

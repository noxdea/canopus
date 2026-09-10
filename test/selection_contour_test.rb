# frozen_string_literal: true
require_relative "test_helper"

class SelectionContourTest < Minitest::Test
  def test_multiline_contour_rounds_only_exposed_corners_without_alpha_overlap
    Dir.mktmpdir("canopus-selection-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      window = Zaniah::Platform.open_window(width: 640, height: 260)
      controller = Canopus::Controller.new(workspace, window)
      editor = workspace.editor
      editor.insert_text("first line\nmiddle line\nlast line", auto_indent: false)
      editor.select(4, 26)
      document = editor.language_document
      document.stub(:poll, false) { controller.tick }
      color = Zaniah::Color.parse(workspace.theme[:selection]).to_a
      strips = window.scene.quads.each_slice(Zaniah::Scene::QUAD_STRIDE).select { |quad| quad[4, 4] == color }
      assert_equal 3, strips.length
      assert_equal [3, 3, 0, 0], strips[0][8, 4]
      assert_equal [3, 3, 3, 0], strips[1][8, 4]
      assert_equal [0, 0, 3, 3], strips[2][8, 4]
      strips.each_cons(2) { |first, last| assert_in_delta first[1] + first[3], last[1] }
      # First/last strips stop at their selected columns, not a full-line hull.
      assert_operator strips.first[0], :>, strips[1][0]
      assert_operator strips.last[0] + strips.last[2], :<, strips[1][0] + strips[1][2]
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end
end

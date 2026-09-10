# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class DisplayMapControllerTest < Minitest::Test
  def test_foreground_poll_preserves_scrolled_source_anchor_and_redraws
    Dir.mktmpdir("canopus-wrap-controller-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      window = Zaniah::Platform.open_window(width: 640, height: 260)
      controller = Canopus::Controller.new(workspace, window)
      editor = workspace.editor
      editor.buffer.edit([[0...0, ("日本 abcdefghijklmnopqrstuvwxyz\n" * 200)]])
      editor.display_map.dispose
      mapping = Canopus::DisplayMap.new(editor.buffer, wrap_width: 8, background_threshold: 0)
      editor.instance_variable_set(:@display_map, mapping)
      editor.select(0)
      editor.viewport_rows = 10
      editor.scroll(dy: 60.25)
      anchor = mapping.to_buffer(Canopus::DisplayPoint.new(60, 0))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      while mapping.pending?
        controller.poll_display_maps
        raise "controller did not apply background layout" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Thread.pass
      end
      assert_equal anchor, mapping.to_buffer(Canopus::DisplayPoint.new(editor.scroll_y.floor, 0))
      assert_in_delta 0.25, editor.scroll_y % 1
      assert_operator editor.scroll_y, :>, 60
      assert_equal 0, editor.primary.head
      assert_empty workspace.message
      controller.tick
      assert controller.view.regions.any? { |_, action| action.first == :editor }
    ensure
      workspace&.close
      window&.on_close { true }
      window&.close
    end
  end
end

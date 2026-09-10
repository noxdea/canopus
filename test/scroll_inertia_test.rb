# frozen_string_literal: true
require_relative "test_helper"

class ScrollInertiaTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-scroll-")
    @workspace = Canopus::Workspace.new(root: @root)
    @window = Zaniah::Platform.open_window(width: 640, height: 260)
    @controller = Canopus::Controller.new(@workspace, @window)
    @editor = @workspace.editor
    @editor.insert_text("line\n" * 300, auto_indent: false)
    @editor.move(:file_start)
    @controller.tick
    @point = Zaniah::Point.new(350, 100)
  end

  def teardown
    @workspace.close
    @window.on_close { true }
    @window.close
    FileUtils.remove_entry(@root)
  end

  def wheel(delta = 60, phase = :changed)
    @controller.input(Zaniah::Input::ScrollWheel.new(@point, Zaniah::Point.new(0, delta), phase, []))
    @controller.instance_variable_get(:@scroll_motion)&.last
  end

  def test_decay_is_frame_rate_independent_and_stops
    time = wheel
    assert_in_delta 3, @editor.scroll_y
    60.times { |i| @controller.poll_scroll(now: time + (i + 1) / 60.0) }
    sixty = @editor.scroll_y
    assert_operator sixty, :>, 3
    assert_operator sixty, :<=, 5.5
    refute @controller.poll_scroll(now: time + 2)
    @editor.scroll(dy: -1000)
    time = wheel
    120.times { |i| @controller.poll_scroll(now: time + (i + 1) / 120.0) }
    assert_in_delta sixty, @editor.scroll_y, 0.001
  end

  def test_native_momentum_is_not_doubled_and_setting_can_disable_animation
    assert_nil wheel(60, 8)
    refute @controller.poll_scroll
    assert_in_delta 3, @editor.scroll_y
    @workspace.settings.merge!("scroll_friction" => 0)
    assert_nil wheel
    assert_in_delta 6, @editor.scroll_y
    [-1, 101, Float::NAN, Float::INFINITY, "fast"].each do |value|
      assert_raises(Canopus::Error) { @workspace.settings.merge!("scroll_friction" => value) }
    end
  end

  def test_user_input_modal_and_document_boundaries_cancel_animation
    time = wheel
    @controller.input(Zaniah::Input::KeyDown.new("left", false))
    refute @controller.poll_scroll(now: time + 0.1)
    time = wheel
    @workspace.call("command.palette")
    refute @controller.poll_scroll(now: time + 0.1)
    @workspace.palette = nil
    @editor.scroll(dy: -1000)
    time = wheel(-60)
    refute @controller.poll_scroll(now: time + 0.1)
    assert_equal 0, @editor.scroll_y
  end
end

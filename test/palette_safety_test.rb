# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class PaletteSafetyTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-palette-")
    File.write(File.join(@root, "a.txt"), "a\n")
    @workspace = Canopus::Workspace.new(root: @root, settings: Canopus::Settings.new)
    @window = Zaniah::Platform.open_window(width: 640, height: 300)
    @controller = Canopus::Controller.new(@workspace, @window)
  end

  def teardown
    @workspace.close
    @window.on_close { true }
    @window.close
    FileUtils.remove_entry(@root)
  end

  def confirm(name = "created.txt")
    future = Canopus::LSP::Future.new(nil)
    edit = {"documentChanges" => [{"kind" => "create", "uri" => Canopus::LSP::Protocol.uri(File.join(@root, name))}]}
    @workspace.confirm_workspace_edit(edit, response: future)
    future
  end

  def key(stroke) = @controller.input(Zaniah::Input::KeyDown.new(stroke, false))
  def click(point, button = :left)
    @controller.input(Zaniah::Input::MouseDown.new(position: point, button: button, modifiers: [], click_count: 1))
  end

  def test_dialog_blocks_background_click_drag_scroll_composition_and_file_drop
    future = confirm
    @controller.tick
    bounds, = @controller.view.regions.find { |_, action| action.first == :file }
    point = Zaniah::Point.new(bounds.x + 2, bounds.y + 2)
    current = @workspace.editor
    @controller.instance_variable_set(:@drag, [current, 0, point, false])
    click(point, :right)
    click(point)
    @controller.input(Zaniah::Input::MouseMove.new(position: point, modifiers: []))
    @controller.input(Zaniah::Input::MouseUp.new(position: point, button: :left, modifiers: []))
    @controller.input(Zaniah::Input::ScrollWheel.new(position: point, delta: Zaniah::Point.new(0, 30), modifiers: [], phase: :changed))
    @controller.input(Zaniah::Input::Composition.new("draft", 0...1))
    @controller.input(Zaniah::Input::FileDrop.new([File.join(@root, "a.txt")], point))
    assert_equal :workspace_edit, @workspace.palette[:kind]
    assert_same current, @workspace.editor
    assert_nil current.composition
    assert_equal 0, current.scroll_y
    assert_nil @controller.instance_variable_get(:@drag)
    refute future.done?
    key("esc")
    assert_equal false, future.await["applied"]
    refute File.exist?(File.join(@root, "created.txt"))
  end

  def test_every_replacement_and_close_resolves_the_previous_response
    replacements = [
      -> { @workspace.palette = nil },
      -> { @workspace.palette_open(:commands) },
      -> { @workspace.call("language.rename") },
      -> { @workspace.call("git.branches") },
      -> { @workspace.show_diagnostics },
      -> { @workspace.send(:display_language_result, :completion, [{"label" => "x"}], nil, @workspace.editor) },
      -> { @workspace.open_settings; @workspace.settings_completions }
    ]
    replacements.each do |replace|
      future = confirm
      replace.call
      assert future.done?, replace.source_location.inspect
      assert_equal false, future.await["applied"]
    end
    future = confirm
    @workspace.editor.insert_text("dirty")
    refute @controller.close_requested
    assert_equal false, future.await["applied"]
    future = confirm
    @workspace.close
    assert_equal false, future.await["applied"]
    late = confirm("late.txt")
    assert_equal false, late.await["applied"]
    assert_nil @workspace.palette
  end

  def test_clean_window_close_resolves_confirmation
    future = confirm
    assert @controller.close_requested
    assert_equal false, future.await["applied"]
  end

  def test_stale_palette_regions_cannot_approve_a_new_confirmation
    @workspace.palette_open(:commands)
    @controller.tick
    bounds, = @controller.view.regions.find { |_, action| action == [:palette, 0] }
    future = confirm
    click(Zaniah::Point.new(bounds.x + 1, bounds.y + 1))
    refute future.done?
    assert_equal 1, @workspace.palette[:index]
    refute File.exist?(File.join(@root, "created.txt"))
  end

  def test_response_callback_can_open_a_following_confirmation
    first = confirm
    following = nil
    first.then { following = confirm("following.txt") }
    key("up")
    key("enter")
    assert_equal true, first.await["applied"]
    refute following.done?
    assert_equal :workspace_edit, @workspace.palette[:kind]
    assert_includes @workspace.palette[:details].first, "following.txt"
    key("esc")
    assert_equal false, following.await["applied"]
  end
end

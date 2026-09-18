# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class AutoSaveTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-auto-save-")
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root)
  end

  def test_after_delay_debounces_dirty_named_buffers
    path = File.join(@root, "file.txt")
    File.write(path, "before")
    @workspace = Canopus::Workspace.new(root: @root,
      settings: Canopus::Settings.new("auto_save" => "after_delay", "auto_save_delay" => 100))
    editor = @workspace.open(path)
    editor.insert_text("!")

    refute @workspace.poll_auto_save(now: 0)
    assert_equal "before", File.read(path)
    refute @workspace.poll_auto_save(now: 0.099)
    assert @workspace.poll_auto_save(now: 0.1)
    assert_equal "!before", File.read(path)
    refute editor.buffer.dirty?
    refute @workspace.poll_auto_save(now: 0.2)
  end

  def test_focus_change_saves_previous_buffer_once
    first = File.join(@root, "first.txt")
    second = File.join(@root, "second.txt")
    File.write(first, "one")
    File.write(second, "two")
    @workspace = Canopus::Workspace.new(root: @root,
      settings: Canopus::Settings.new("auto_save" => "on_focus_change"))
    first_editor = @workspace.open(first)
    refute @workspace.poll_auto_save(now: 0)
    first_editor.insert_text("!")
    @workspace.open(second)

    assert @workspace.poll_auto_save(now: 1)
    assert_equal "!one", File.read(first)
    refute first_editor.buffer.dirty?
    refute @workspace.poll_auto_save(now: 2)
  end

  def test_focus_change_saves_all_multi_buffer_sources
    first = File.join(@root, "first.txt")
    second = File.join(@root, "second.txt")
    third = File.join(@root, "third.txt")
    File.write(first, "one")
    File.write(second, "two")
    File.write(third, "three")
    @workspace = Canopus::Workspace.new(root: @root,
      settings: Canopus::Settings.new("auto_save" => "on_focus_change"))
    first_editor = @workspace.open(first)
    second_editor = @workspace.open(second)
    multi = Canopus::MultiBuffer.new(excerpts: [
      [first_editor.buffer, 0...first_editor.buffer.rope.bytesize, "first"],
      [second_editor.buffer, 0...second_editor.buffer.rope.bytesize, "second"]
    ])
    @workspace.buffers[multi.object_id] = multi
    @workspace.active_pane.open(multi)
    refute @workspace.poll_auto_save(now: 0)
    first_editor.insert_text("!")
    second_editor.insert_text("?")
    @workspace.open(third)

    assert @workspace.poll_auto_save(now: 1)
    assert_equal "!one", File.read(first)
    assert_equal "?two", File.read(second)
    refute first_editor.buffer.dirty?
    refute second_editor.buffer.dirty?
  end

  def test_auto_save_settings_are_global_and_bounded
    assert_equal "off", Canopus::Settings.new["auto_save"]
    assert_equal 1_000, Canopus::Settings.new["auto_save_delay"]
    assert_raises(Canopus::Error) { Canopus::Settings.new("auto_save" => "always") }
    assert_raises(Canopus::Error) { Canopus::Settings.new("auto_save_delay" => 99) }
    assert_raises(Canopus::Error) do
      Canopus::Settings.new("languages" => {"ruby" => {"auto_save" => "after_delay"}})
    end
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

class SettingsLayerTest < Minitest::Test
  def test_json_layers_match_hash_layer_composition
    first = {"font_size" => 16, "tabs" => {"close_on_middle_click" => false},
      "terminal" => {"env" => {"FIRST" => "1"}},
      "dock" => {"panels" => {"explorer" => {"visible" => false}}}}
    second = {"font_size" => 18, "tabs" => {"reopen_history_limit" => 42},
      "terminal" => {"env" => {"SECOND" => "2"}},
      "dock" => {"panels" => {"explorer" => {"size" => 240}}}}

    expected = Canopus::Settings.new(first, second).values
    Tempfile.create(["canopus-settings-layer-", ".jsonc"]) do |first_file|
      Tempfile.create(["canopus-settings-layer-", ".jsonc"]) do |second_file|
        first_file.write(JSON.generate(first))
        first_file.flush
        second_file.write(JSON.generate(second))
        second_file.flush
        assert_equal expected, Canopus::Settings.new(first_file.path, second_file.path).values
      end
    end
  end

  def test_invalid_json_layer_values_are_discarded_individually
    layer = {"font_size" => 18, "tab_size" => 0,
      "tabs" => {"close_on_middle_click" => false, "reopen_history_limit" => 1001}}
    Tempfile.create(["canopus-settings-layer-", ".jsonc"]) do |file|
      file.write(JSON.generate(layer))
      file.flush
      settings = Canopus::Settings.new(file.path)
      assert_equal 18, settings["font_size"]
      assert_equal Canopus::Settings::DEFAULTS["tab_size"], settings["tab_size"]
      assert_equal false, settings["tabs"]["close_on_middle_click"]
      assert_equal Canopus::Settings::DEFAULTS["tabs"]["reopen_history_limit"], settings["tabs"]["reopen_history_limit"]
    end
  end

  def test_reload_keeps_the_previous_value_for_an_invalid_file_key
    Tempfile.create(["canopus-settings-layer-", ".jsonc"]) do |file|
      file.write('{"tab_size":2}')
      file.flush
      settings = Canopus::Settings.new(file.path)
      file.rewind
      file.truncate(0)
      file.write('{"tab_size":0}')
      file.flush
      assert_equal 2, settings.reload["tab_size"]
    end
  end

  def test_reload_drops_a_valid_key_removed_from_a_file
    Tempfile.create(["canopus-settings-layer-", ".jsonc"]) do |file|
      file.write('{"tab_size":2,"theme":"Canopus Light"}')
      file.flush
      settings = Canopus::Settings.new(file.path)
      file.rewind
      file.truncate(0)
      file.write('{"theme":"Canopus Light"}')
      file.flush
      reloaded = settings.reload
      assert_equal Canopus::Settings::DEFAULTS["tab_size"], reloaded["tab_size"]
      assert_equal "Canopus Light", reloaded["theme"]
    end
  end
end

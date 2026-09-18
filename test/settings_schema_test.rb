# frozen_string_literal: true

require_relative "test_helper"

class SettingsSchemaTest < Minitest::Test
  def test_schema_model_exposes_the_single_settings_metadata_tree
    model = Canopus::Settings.schema_model

    assert_instance_of Kochab::Schema, model
    assert_equal Canopus::Settings::DEFAULTS, model.defaults
    Canopus::Settings::DEFAULTS.each_key do |key|
      field = model.describe([key])
      refute_nil field, key
      refute_nil field.description, key
    end
    assert_equal 14, model.describe(["font_size"]).default
    assert_equal ["off", "after_delay", "on_focus_change"], model.describe(["auto_save"]).enum
    assert_equal 1, model.describe(["tab_size"]).minimum
    assert_equal 16, model.describe(["tab_size"]).maximum
    assert_equal ["history", "neighbour", "left", "right"], model.describe(%w[tabs activate_on_close]).enum
  end

  def test_json_schema_remains_available_for_existing_consumers
    assert_equal "integer", Canopus::Settings.schema.dig("properties", "tab_size", "type")
    assert_equal Canopus::Settings.schema, Canopus::Settings::SCHEMA
  end
end

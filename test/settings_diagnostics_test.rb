# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SettingsDiagnosticsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-settings-diagnostics-")
    @workspace = Canopus::Workspace.new(root: @root)
  end

  def teardown
    @workspace.close
    FileUtils.remove_entry(@root)
  end

  def test_schema_diagnostics_are_published_with_file_ranges_and_cleared
    File.write(@workspace.settings_path, '{"tab_size":0}')
    @workspace.poll_settings(force: true)

    entries = @workspace.diagnostics.all(source: :settings)
    assert_equal 1, entries.length
    assert_equal "Must be at least 1", entries.first.diagnostic["message"]
    assert_equal 0, entries.first.diagnostic.dig("range", "start", "line")
    assert_equal 12, entries.first.diagnostic.dig("range", "start", "character")

    File.write(@workspace.settings_path, '{"tab_size":2}')
    @workspace.poll_settings(force: true)
    assert_empty @workspace.diagnostics.all(source: :settings)
  end

  def test_partial_nested_layers_do_not_report_missing_required_defaults
    File.write(@workspace.settings_path, '{"diagnostics":{"inline":false}}')
    @workspace.poll_settings(force: true)

    assert_empty @workspace.diagnostics.all(source: :settings)
  end
end

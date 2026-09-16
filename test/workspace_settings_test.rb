# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"

class WorkspaceSettingsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-settings-ui-")
    @workspace = Canopus::Workspace.new(root: @root)
    @workspace.new_buffer
  end
  def teardown
    @workspace.close
    FileUtils.remove_entry(@root)
  end
  def test_edit_complete_save_reload_and_invalid_rollback
    @workspace.call("settings.open")
    buffer = @workspace.editor.buffer
    assert buffer.dirty?
    @workspace.call("file.save")
    assert File.file?(@workspace.settings_path)
    File.write(@workspace.settings_path, "{\"tab_size\":2,\"theme\":\"Canopus Light\"}")
    @workspace.poll_settings(force: true)
    assert_equal 2, @workspace.editor.tab_size
    assert_equal "Canopus Light", @workspace.theme.name
    File.write(@workspace.settings_path, "{\"tab_size\":0}")
    @workspace.poll_settings(force: true)
    assert_equal 2, @workspace.settings["tab_size"]
    assert_match(/unchanged/, @workspace.message)
    @workspace.settings_completions
    @workspace.palette[:query] = "wrap"
    @workspace.update_palette
    assert_equal ["soft_wrap"], @workspace.palette[:matches]
  end
  def test_language_layer_is_applied_and_validated
    @workspace.settings.merge!("languages" => {"ruby" => {"tab_size" => 2, "use_tabs" => true}})
    editor = @workspace.open("new.rb")
    assert_equal 2, editor.tab_size
    assert editor.use_tabs
    assert_raises(Canopus::Error) { Canopus::Settings.new("languages" => {"ruby" => {"tab_size" => 0}}) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("theme" => 123) }
    assert_equal "integer", Canopus::Settings.schema.dig("properties", "tab_size", "type")
  end

  def test_diagnostic_settings_are_defaulted_and_validated
    assert_equal({"inline" => true, "inline_max_length" => 80, "severity" => "warning"}, @workspace.settings["diagnostics"])
    assert_equal "boolean", Canopus::Settings.schema.dig("properties", "diagnostics", "properties", "inline", "type")
    assert_raises(Canopus::Error) { Canopus::Settings.new("diagnostics" => {"inline" => "yes"}) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("diagnostics" => {"inline_max_length" => 0}) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("diagnostics" => {"severity" => "fatal"}) }
  end

  def test_inlay_hint_settings_are_defaulted_and_validated
    expected = {"enabled" => true, "parameter_names" => true, "types" => true, "max_length" => 30}
    assert_equal expected, @workspace.settings["inlay_hints"]
    assert_equal "boolean", Canopus::Settings.schema.dig("properties", "inlay_hints", "properties", "enabled", "type")
    assert_raises(Canopus::Error) { Canopus::Settings.new("inlay_hints" => {"enabled" => "yes"}) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("inlay_hints" => {"parameter_names" => nil}) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("inlay_hints" => {"types" => 1}) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("inlay_hints" => {"max_length" => 0}) }
  end

  def test_code_lens_settings_are_defaulted_and_validated
    assert_equal({"enabled" => true}, @workspace.settings["code_lens"])
    assert_equal "boolean", Canopus::Settings.schema.dig("properties", "code_lens", "properties", "enabled", "type")
    assert_raises(Canopus::Error) { Canopus::Settings.new("code_lens" => {"enabled" => "yes"}) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("code_lens" => []) }
  end

  def test_save_action_settings_are_defaulted_snapshotted_and_validated
    assert_equal false, @workspace.settings["format_on_save"]
    assert_equal [], @workspace.settings["code_actions_on_save"]
    assert_equal 2_000, @workspace.settings["format_on_save_timeout"]
    assert_equal "boolean", Canopus::Settings.schema.dig("properties", "format_on_save", "type")
    actions = ["source.organizeImports"]
    settings = Canopus::Settings.new("format_on_save" => true, "code_actions_on_save" => actions,
      "format_on_save_timeout" => 50)
    actions << "source.fixAll"
    assert_equal ["source.organizeImports"], settings["code_actions_on_save"]
    assert settings["code_actions_on_save"].frozen?
    language_actions = [+"source.fixAll"]
    settings = Canopus::Settings.new("languages" => {"ruby" => {"code_actions_on_save" => language_actions}})
    language_actions.first.replace("source.changed")
    language_actions << "source.organizeImports"
    assert_equal ["source.fixAll"], settings["languages"].dig("ruby", "code_actions_on_save")
    assert settings["languages"].dig("ruby", "code_actions_on_save").frozen?
    assert_raises(Canopus::Error) { Canopus::Settings.new("format_on_save" => "yes") }
    assert_raises(Canopus::Error) { Canopus::Settings.new("code_actions_on_save" => ["source.fixAll", "source.fixAll"]) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("code_actions_on_save" => ["bad\nkind"]) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("format_on_save_timeout" => 0) }
  end

  def test_keymap_values_are_bounded_validated_and_snapshotted
    groups = [{"context" => "Editor && !vim_mode", "bindings" => {"ctrl-k ctrl-s" => "file.save", "cmd-s" => nil}}]
    settings = Canopus::Settings.new("keymap" => groups)
    groups.first["bindings"]["ctrl-k ctrl-s"] = "file.new"
    assert_equal "file.save", settings["keymap"].first["bindings"]["ctrl-k ctrl-s"]
    assert settings["keymap"].first["bindings"].frozen?
    assert_raises(Canopus::Error) { settings.merge!("keymap" => [{"context" => "Editor && (", "bindings" => {}}]) }
    assert_raises(Canopus::Error) { settings.merge!("keymap" => [{"bindings" => {"unknown-key" => "file.save"}}]) }
    assert_raises(Canopus::Error) { settings.merge!("keymap" => [{"bindings" => {"f1" => 123}}]) }
    assert_raises(Canopus::Error) { settings.merge!("keymap" => Array.new(129) { {"bindings" => {}} }) }
    assert_equal "file.save", settings["keymap"].first["bindings"]["ctrl-k ctrl-s"]
  end

  def test_legacy_bottom_dock_settings_remain_valid
    legacy = {"dock" => {"bottom" => {"size" => 280, "visible" => false}}}
    settings = Canopus::Settings.new(JSON.parse(JSON.generate(legacy)))
    assert_equal legacy["dock"]["bottom"], settings["dock"]["bottom"]
    assert_equal({"size" => 220, "visible" => true}, settings["dock"]["left"])
    assert settings["dock"]["panels"]["explorer"]["visible"]
    assert_raises(Canopus::Error) { Canopus::Settings.new("dock" => {"panels" => {"terminal" => {"size" => 0}}}) }

    configured = Canopus::Settings.new("dock" => {"panels" => {
      "explorer" => {"size" => 310, "visible" => false},
      "future-panel" => {"size" => 200, "visible" => true}
    }})
    workspace = Canopus::Workspace.new(root: @root, settings: configured)
    begin
      refute workspace.show_project
      workspace.panels.show(:explorer)
      assert_equal 310, workspace.docks[:left][:size]
      refute workspace.panels.key?("future-panel")
      assert_equal({"visible" => true, "size" => 200}, workspace.panels.state["future-panel"])
    ensure
      workspace.close
    end
  end
end

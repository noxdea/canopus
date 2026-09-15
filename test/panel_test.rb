# frozen_string_literal: true

require_relative "test_helper"

class PanelTest < Minitest::Test
  def setup
    @docks = {left: {visible: true, size: 220}, right: {visible: false, size: 260},
      bottom: {visible: false, size: 280}}
    @registry = Canopus::Panel::Registry.new(@docks)
    @explorer = @registry.register(
      Canopus::Panel::Definition.new(:explorer, "Explorer", nil, :left, -> { :tree }, nil), visible: true
    )
    @terminal = @registry.register(
      Canopus::Panel::Definition.new(:terminal, "Terminal", nil, :bottom, -> { :shell }, nil), visible: false
    )
  end

  def test_visibility_size_and_badge_are_managed_by_the_registry
    assert_equal [@explorer], @registry.active(:left)
    assert_empty @registry.active(:bottom)

    @registry.show(:terminal)
    assert @docks[:bottom][:visible]
    assert_equal [@terminal], @registry.active(:bottom)
    @registry.resize(:bottom, 320)
    @registry.hide(:terminal)
    refute @docks[:bottom][:visible]
    @registry.show(:terminal)
    assert_equal 320, @docks[:bottom][:size]
    assert_equal 3, @registry.badge(:terminal, 3).badge
  end

  def test_unknown_state_is_forward_compatible_and_operations_still_require_registration
    state = @registry.state.merge("future-panel" => "state owned by a newer version")
    @registry.hide(:explorer)
    @registry.restore(state)
    assert @registry.visible?(:explorer)
    refute @registry.key?("future-panel")
    assert_raises(KeyError) { @registry.show("missing") }

    @registry.restore({"plugin" => {"visible" => false, "size" => 444}})
    refute @registry.key?("plugin")
    plugin = @registry.register(Canopus::Panel::Definition.new("plugin", "Plugin", nil, :right, -> {}, nil))
    refute @registry.visible?(plugin.id)
    @registry.show(plugin.id)
    assert_equal 444, @docks[:right][:size]
  end

  def test_invalid_definitions_and_known_state_are_rejected
    invalid = Canopus::Panel::Definition.new("bad", "Bad", nil, :center, -> {}, nil)
    assert_raises(ArgumentError) { @registry.register(invalid) }
    valid = Canopus::Panel::Definition.new("bad-size", "Bad", nil, :left, -> {}, nil)
    assert_raises(ArgumentError) { @registry.register(valid, size: 0) }
    assert_raises(ArgumentError) { @registry.restore({"terminal" => {"visible" => true, "size" => 0}}) }
  end
end

# frozen_string_literal: true
require_relative "test_helper"
require "open3"

class IsolationTest < Minitest::Test
  def test_clean_gem_uses_released_runtime_dependencies
    root = File.expand_path("..", __dir__)
    output, status = Open3.capture2e(Gem.ruby, "tools/check_dependencies.rb", "test/type/smoke.rb", chdir: root)
    assert status.success?, output
    assert_includes output, "runtime dependencies: alhena, antares, denebola, kochab, porrima, prism, rouge, spica, unicode-display_width, zaniah"
  end
end

# frozen_string_literal: true
require_relative "test_helper"
require "open3"
require "pathname"

class IsolationTest < Minitest::Test
  def test_clean_gem_uses_released_runtime_dependencies
    root = File.expand_path("..", __dir__)
    output, status = Open3.capture2e(Gem.ruby, "tools/check_dependencies.rb", "test/type/smoke.rb", chdir: root)
    assert status.success?, output
    assert_includes output, "runtime dependencies: alhena, alkaid, antares, denebola, kochab, megrez, porrima, prism, rouge, sadr, spica, tarazed, thuban, unicode-display_width, zaniah"
  end

  def test_cli_resolves_relative_alkaid_path_from_the_repository
    root = File.expand_path("..", __dir__)
    Dir.mktmpdir("canopus-alkaid-path-") do |directory|
      dependency = File.join(directory, "alkaid")
      marker = File.join(directory, "loaded")
      FileUtils.mkdir_p(File.join(dependency, "lib"))
      File.write(File.join(dependency, "lib", "alkaid.rb"), "File.binwrite(#{marker.inspect}, 'yes')\nmodule Alkaid; end\n")
      File.write(File.join(dependency, "alkaid.gemspec"), <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "alkaid"
          spec.version = "0.1.0"
          spec.summary = "path resolution fixture"
          spec.authors = ["test"]
          spec.files = ["lib/alkaid.rb"]
        end
      RUBY
      relative = Pathname(dependency).relative_path_from(Pathname(root)).to_s
      output, status = Open3.capture2e({"ALKAID_PATH" => relative}, Gem.ruby,
        File.join(root, "exe", "canopus"), "--version", chdir: directory)
      assert status.success?, output
      assert_equal Canopus::VERSION, output.lines.last.strip
      assert File.file?(marker), "CLI did not load Alkaid from ALKAID_PATH"
    end
  end
end

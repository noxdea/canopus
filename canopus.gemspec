# frozen_string_literal: true

require_relative "lib/canopus/version"

Gem::Specification.new do |spec|
  spec.name = "canopus"
  spec.version = Canopus::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]
  spec.summary = "A pure Ruby text editor with persistent buffers and language tools"
  spec.homepage = "https://github.com/noxdea/canopus"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir.chdir(__dir__) { Dir["{lib,sig,exe,assets,docs,examples,tools}/**/*", "README.md", "CHANGELOG.md", "LICENSE.txt"].select { |path| File.file?(path) } }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}).map { |path| File.basename(path) }
  spec.require_paths = ["lib"]
  spec.add_dependency "alhena", "~> 0.1.0"
  spec.add_dependency "antares", "~> 0.1.0"
  spec.add_dependency "denebola", "~> 0.1.0"
  spec.add_dependency "kochab", "~> 0.1.0"
  spec.add_dependency "porrima", "~> 0.1.0"
  spec.add_dependency "prism", "~> 1.0"
  spec.add_dependency "rouge", "~> 5.0"
  spec.add_dependency "spica", "~> 0.1.0"
  spec.add_dependency "thuban", "~> 0.1.0"
  spec.add_dependency "unicode-display_width", "~> 3.2"
  spec.add_dependency "zaniah", "~> 0.1.0"
end

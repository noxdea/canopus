# frozen_string_literal: true

require "tmpdir"
require "open3"
require_relative "package"
require "fileutils"

Dir.mktmpdir("canopus-package-") do |directory|
  %w[mac linux windows].each do |platform|
    output = File.join(directory, platform == "mac" ? "Canopus Test.app" : "Canopus #{platform}")
    launcher = CanopusPackage.build(platform: platform, output: output)
    metadata = JSON.parse(File.read(File.join(output, "package.json")))
    raise "runtime must not be bundled" unless metadata["bundled_ruby"] == false
    manifest = JSON.parse(File.read(File.join(output, "manifest.json")))
    raise "manifest algorithm" unless manifest["algorithm"] == "SHA-256"
    raise "manifest missing package metadata" unless manifest["files"].key?("package.json")
    if platform == "windows"
      raise "missing shortcut installer" unless File.file?(File.join(output, "Create-Shortcut.ps1"))
      raise "unsafe launcher argument forwarding" unless File.read(launcher).include?("%*")
      raise "Windows launcher requires unsupported YJIT" if File.read(launcher).include?("--yjit")
      next
    end
    output_text, status = Open3.capture2e(launcher, "--version")
    raise "packaged #{platform} executable failed: #{output_text}" unless status.success? && output_text.strip == metadata["version"]
    png = File.join(directory, "#{platform}.png")
    output_text, status = Open3.capture2e(launcher, "--headless", png, "--size", "320x200", "--project", directory)
    raise "packaged render failed: #{output_text}" unless status.success? && File.binread(png, 8) == "\x89PNG\r\n\x1a\n".b
    begin
      CanopusPackage.build(platform: platform, output: File.dirname(launcher))
      raise "existing output accepted"
    rescue ArgumentError
      # Existing packages are never overwritten implicitly.
    end
  end
end
Dir.mktmpdir("canopus-ruby-root-") do |directory|
  root = File.join(directory, "ruby")
  FileUtils.mkdir_p(File.join(root, "bin"))
  FileUtils.cp(RbConfig.ruby, File.join(root, "bin", "ruby"))
  output = File.join(directory, "bundled")
  CanopusPackage.build(platform: "linux", output: output, ruby_root: root)
  metadata = JSON.parse(File.read(File.join(output, "package.json")))
  raise "bundled runtime metadata" unless metadata["bundled_ruby"] && metadata["ruby"] == "runtime/bin/ruby"
  raise "bundled launcher path" unless File.read(File.join(output, "bin", "canopus")).include?("../runtime/bin/ruby")
end
puts "Package layouts, launchers, and headless rendering passed (Windows runtime not executed)."

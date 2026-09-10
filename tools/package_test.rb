# frozen_string_literal: true

require "tmpdir"
require "open3"
require_relative "package"

Dir.mktmpdir("canopus-package-") do |directory|
  %w[mac linux windows].each do |platform|
    output = File.join(directory, platform == "mac" ? "Canopus Test.app" : "Canopus #{platform}")
    launcher = CanopusPackage.build(platform: platform, output: output)
    metadata = JSON.parse(File.read(File.join(output, "package.json")))
    raise "runtime must not be bundled" unless metadata["bundled_ruby"] == false
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
puts "Package layouts, launchers, and headless rendering passed (Windows runtime not executed)."
